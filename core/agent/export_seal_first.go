package main

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// NWP-20260919-10: SEAL-THEN-ENUMERATE, AND THE PRIZE IS THAT THE RECOVERY CODE STOPS BEING REQUIRED.
//
// The CLI half of the export (`export-manifest`) runs OFF-HANDSET against a logged-off profile, ~~so on
// Endospore -- where the chooser hardens every new profile at create and enrollSE DROPS the pass slots --
// the bare vault opens by no keyslot at all and the 12-word recovery code is mandatory in practice. A
// customer who never kept their words cannot export, which is most of them.~~ *(⚠ SUPERSEDED 2026-10-08,
// NWP-20261008-08: since the 2026-10-06 opt-in tie -- docs/product-decisions.md, built in NWP-20261006-09 -- a
// new profile is pass-only and the CLI opens it by passphrase; a tied profile (one its user tied, or one tied at
// create before NWP-20261006-09, which stays tied until untied) has no pass slot and needs the 12 words. And
// nothing calls this verb yet (backlog NWP-20260918-12), so it has removed the requirement for no one.)*
//
// ✅ THIS VERB REMOVES THAT, by enumerating from INSIDE the live session: it passes seFromSession(dest), so
// the secure element opens the vault and no recovery code is involved. That is the whole point of doing it
// here rather than there. The cost is that the store must first be made to agree with the session -- hence
// seal, THEN enumerate.
//
// ⚠⚠ THE CONDITION THE WHOLE DESIGN TURNS ON: A SEAL CAN FINISH *PARTIAL* AND STILL SAY OK. The wire shape
// is `OK PARTIAL:<parts>` and #118's own comment says the suffix is built to be ignorable -- "the verb stays
// DONE, so the existing startsWith("DONE") reader completes the logoff exactly as before". A flow that
// checked the verb alone would enumerate over a STALE head for the scope that did not seal, and call the
// result a verified copy: the skew profile-export-restore.md §5 forbids, reached through the very mechanism
// meant to prevent it. ~~And PARTIAL is NORMAL right after a login (`sys=pending-placement`), i.e. exactly
// when someone would export.~~ *(Corrected 2026-10-08, NWP-20261008-07: pending-placement leaves the #sys head
// exactly as this session restored it -- the account is not in Android until its authenticator arrives -- so it is
// not a stale head, and sealPartsOf drops it as benign. A real partial, `apps=refused` say, still refuses here.)*
//
// ⚠ IT IS AN INTERLOCK, NOT A GATE -- deliberately, unlike NWP-20260919-09's restore-preflight. The caller
// cannot skip the check by not calling it, because the check lives on the only path that produces the
// manifest. A caller that never ran a backup is refused here rather than trusted to have looked.
//
// ⚠ AND "NOTHING FAILED" IS NOT "A SEAL HAPPENED". An idle session that never sealed reports a clean DONE by
// construction (composeSealStatus's default arm), so a verb that only checked for failure would happily
// enumerate a session whose live state was never written -- handing back a manifest of the PREVIOUS logoff's
// objects while the screen said the export was complete. lastSealOKAt is the evidence that one actually
// landed: documented "0 = never THIS DAEMON LIFETIME" and reset in markSession at every login, precisely so
// one identity's signals cannot be read as another's.

// exportSealState is why the manifest may not be produced yet, or "" when it may.
//
// Split out so the truth table is unit-testable without a session, a store or a seal -- the same reason
// composeSealStatus was split out of its handler.
func exportSealState(inFlight bool, runKind string, failed bool, failWhy, parts string, lastOKAt int64) string {
	switch {
	case inFlight || runKind != "":
		// Enumerating while a seal is writing is the NWP-20260829-33 race by another name: the heads move
		// underneath the walk, so the manifest names a mixture of two generations.
		return "BUSY"
	case failed:
		if s := sealFailSuffix(failWhy); s != "" {
			return "ERR-SEAL-FAILED " + s
		}
		return "ERR-SEAL-FAILED"
	case lastOKAt == 0:
		// See the header: nothing failed, and nothing happened either.
		return "ERR-NO-SEAL"
	case parts != "":
		// ⚠ THE ONE THIS DESIGN EXISTS FOR. The data scopes are stored and the seal "succeeded"; the named
		// scopes were NOT written, so their heads in the store are older than this session.
		return "ERR-SEAL-PARTIAL " + parts
	}
	return ""
}

// handleGetExportManifest backs GET-EXPORT-MANIFEST: the completeness index (NWP-20260919-08) built from
// inside a live session, and only when the store has been made to agree with that session.
//
// ⚠ IT TAKES NO NAME AND NO PASSPHRASE, for the reason footprint_list.go states at length: a verb over this
// socket that accepted an arbitrary (name, pass) would answer differently for a right and a wrong one, which
// is a profile-existence oracle reachable from the gate. It answers only for the profile already signed in.
//
// Reply: "NONE" | "LOCAL" | "BUSY" | "ERR-NO-SEAL" | "ERR-SEAL-PARTIAL <parts>" | "ERR-SEAL-FAILED [cause]"
// | "ERR-UNMEASURED" | "ERR-EXPORT <reason>" | "OK <len>\n<json>".
func handleGetExportManifest(conn net.Conn, dest string) {
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n") // nobody signed in
		return
	}
	if localOnlySession(dest) {
		fmt.Fprint(conn, "LOCAL\n") // a throwaway was never sealed; there is nothing in the store to export
		return
	}
	pendingReapMu.Lock()
	inFlight, runKind, failed, failWhy := sealInFlight, sealRunKind, sealFail, sealFailWhy
	pendingReapMu.Unlock()
	// sealParts, not sealPartial: recordSeal maintains it on EVERY path -- manual, logoff AND periodic --
	// whereas sealPartial is the SEAL-STATUS surface and is written only by the logoff and manual paths. A
	// periodic seal that finished partial must refuse this verb too, and only sealParts sees it.
	if why := exportSealState(inFlight, runKind, failed, failWhy, sealPartsGet(), lastSealOKAt.Load()); why != "" {
		fmt.Fprint(conn, why+"\n")
		return
	}
	// A full enumeration walks every scope's head, manifest and chunk list. Same deadline as GET-FOOTPRINT,
	// which does the same walk.
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	// ✅ seFromSession is the whole reason this verb exists off the CLI: the SE opens a hardened vault, so no
	// recovery code is needed ~~for an ordinary export~~ *(⚠ SUPERSEDED 2026-10-08, NWP-20261008-08: for a TIED
	// profile's export; a pass-only profile, every new one since the 2026-10-06 opt-in tie, needs no SE, and
	// nothing calls this verb yet)*. recEntropy is nil BECAUSE of that -- the 12 words
	// return to being the off-handset credential they are for.
	m, err := buildExportManifest("s3", name, pass, seFromSession(dest), nil)
	if err != nil {
		// buildExportManifest's refusals are all reasons the INDEX would be wrong, and a wrong index is
		// worse than none -- it makes a bad copy look verified. Keep the distinct shape GET-FOOTPRINT
		// already uses for the unmeasured case so existing readers of that verb are not surprised.
		if isUnmeasuredExport(err) {
			fmt.Fprint(conn, "ERR-UNMEASURED\n")
			return
		}
		fmt.Fprintf(conn, "ERR-EXPORT %s\n", oneLine(err.Error()))
		return
	}
	body, err := m.encode()
	if err != nil {
		fmt.Fprintf(conn, "ERR-EXPORT %s\n", oneLine(err.Error()))
		return
	}
	fmt.Fprintf(conn, "OK %d\n", len(body))
	conn.Write(body)
}

// isUnmeasuredExport keeps the daemon reply keyed to a SENTINEL rather than to prose, so rewording a
// message cannot silently change which wire verb a caller receives.
func isUnmeasuredExport(err error) bool { return errors.Is(err, errExportUnmeasured) }

// oneLine flattens an error onto a single wire line. This protocol is line-delimited, so an embedded
// newline would split one reply into two and desynchronise every later read on the connection.
func oneLine(s string) string {
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.TrimSpace(s)
}
