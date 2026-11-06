package main

// NWP-20260912-07 (NWP-20261010-10): A WEDGED SIGN-OUT NEEDS AN EXIT, AND THE EXIT NEEDS TO KNOW WHEN IT IS OWED.
//
// A seal guard that refuses keeps the session signed in (#86 Fix A) -- correctly: logind will not reap what it
// could not save. But exit 4 covers guards of two kinds. Some refuse because of something that will clear: the
// head moved while this seal was running (seal_cas.go), or the stored head could not be read (store or key
// failure). The rest refuse because of a fact about THIS SESSION that no retry changes: its copy of a scope
// shrank far below the stored head (the shrink guard), it never finished restoring that scope (the #72 receipt
// keystone), the stored head moved on since this session restored it (the sequential guard), the walk could not
// read paths (sealBlind), or the profile was deleted on this phone (the #144 fence). Live case, ticket
// NW-db441ee766cb, stallion, 2026-10-10: every seal refused `ERR-REFUSED PARTIAL:de=refused` (the #de shrink
// guard) while vault, #media, #sys and #apps sealed every cycle, and the only way out was a reboot that nothing
// on screen said was safe.
//
// THREE PIECES, AND ONLY THE FIRST CROSSES A PROCESS BOUNDARY:
//   - the push names its guard: `push` appends "<scope> <reason>" to $NOWHERE_STATE/seal.refusal-why before it
//     exits 4. Same bridge, same lifetime as the credit-reason stash (creditReasonFile): cleared when the worker
//     slot is taken for an `out`, consumed at the verdict. Scope labels only (progScopeOf), never the profile.
//     roamd is untouched -- its PARTIAL list already names the scope, and this names the guard beside it.
//   - the daemon records a refused SIGN-OUT (noteLogoffRefusal), bound to the session it refused, and serves it
//     to that session's chooser (GET-LOGOFF-REFUSAL), so the dialog can say whether a retry can help.
//   - END-UNSAVED ends that session WITHOUT a seal -- only when the refusal it is answering was deterministic,
//     only for the session it refused, and only for that session's own chooser.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- the agent side: which guard refused ----

// sealRefusedWhy names the guard that set sealRefused in pushProfile ("shrink", "no-receipt", ...). Set beside
// sealRefused at every guard and reset with it; a guard that forgets to set it reads as "unknown", which
// classifies as RETRY -- the side that never offers the destructive control.
var sealRefusedWhy string

// refusalReasonsFile is where a refusing push leaves its guard's name for the daemon, one "<scope> <reason>" line
// per refusal, in the tmpfs state dir.
const refusalReasonsFile = "seal.refusal-why"

// sealRefusalReasons is the push verb's whole verdict as reason tokens: the entry guard's, then the two that
// fire inside the deferred capFlush (the #144 fence and the stale-publish guard). Pure, so the mapping is tested
// without an os.Exit.
func sealRefusalReasons(refused bool, why string, fence, stale bool) []string {
	var out []string
	if refused {
		if why == "" {
			why = "unknown"
		}
		out = append(out, why)
	}
	if fence {
		out = append(out, "fence")
	}
	if stale {
		out = append(out, "stale")
	}
	return out
}

// stashRefusalReasons appends this push's reasons under its SCOPE label. Fail-soft and loud: a lost line only
// costs the dialog its certainty, and the daemon then treats the refusal as one a retry may clear. No-op
// off-device (NOWHERE_STATE unset).
func stashRefusalReasons(profile string, reasons []string) {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" || len(reasons) == 0 {
		return
	}
	scope := progScopeOf(profile) // a label, never the profile name
	var b strings.Builder
	for _, r := range reasons {
		b.WriteString(scope + " " + r + "\n")
	}
	f, err := os.OpenFile(filepath.Join(st, refusalReasonsFile), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err == nil {
		_, err = f.WriteString(b.String())
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[seal] refusal reason not stashed: %v\n", err)
	}
}

// clearRefusalReasons discards a stash nobody consumed, at the start of every `out` (under the worker slot) and
// at every session start -- the two boundaries clearCreditReason guards, for the same reasons.
func clearRefusalReasons() {
	if st := os.Getenv("NOWHERE_STATE"); st != "" {
		os.Remove(filepath.Join(st, refusalReasonsFile))
	}
}

// takeRefusalReasons consumes the stash: scope -> its reasons, in the order written, each once. A line that is
// not two plain tokens is dropped, so a damaged file can only lose certainty, never inject a reason. recordSeal is
// its one production caller, so every verdict -- periodic, manual or logoff -- is judged against its own guards.
func takeRefusalReasons() map[string][]string { return readRefusalReasons(true) }

// peekRefusalReasons reads the stash WITHOUT consuming it. noteLogoffRefusal peeks, because the recordSeal that
// logoffSealFailed runs a moment later must judge the very same verdict against the very same guards.
func peekRefusalReasons() map[string][]string { return readRefusalReasons(false) }

func readRefusalReasons(consume bool) map[string][]string {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return nil
	}
	p := filepath.Join(st, refusalReasonsFile)
	b, err := os.ReadFile(p)
	if consume {
		os.Remove(p)
	}
	if err != nil {
		return nil
	}
	out := map[string][]string{}
	for _, l := range strings.Split(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) != 2 || !refusalToken(f[0]) || !refusalToken(f[1]) {
			continue
		}
		dup := false
		for _, r := range out[f[0]] {
			dup = dup || r == f[1]
		}
		if !dup {
			out[f[0]] = append(out[f[0]], f[1])
		}
	}
	return out
}

func refusalToken(s string) bool {
	if s == "" || len(s) > 32 {
		return false
	}
	for _, c := range s {
		if (c < 'a' || c > 'z') && c != '-' {
			return false
		}
	}
	return true
}

// refusalReasonFinal is the classification, one guard at a time: true when a RETRY OF THIS SESSION'S SEAL CANNOT
// SUCCEED, because the refusal is about the session's own copy or identity rather than about the moment.
//
//	shrink             the shrink guard (both arms): this copy is drastically smaller than the stored head
//	no-receipt         #72 keystone: this session never completed restoring that head, and never will now
//	stale-base         the stored head is not the one this session restored (NOWHERE_SEQ_GUARD); re-reading it
//	                   changes nothing, because the receipt still names the old head
//	blind              the walk could not read paths; the same paths are unreadable on the next walk
//	deleted            the #144 fence refused at entry: a delete marker for this profile is on this phone (or cannot
//	                   be stat'ed, which fails closed), and it holds for the boot. Whether the profile is REALLY
//	                   deleted is the store's to say (logoffProfileDeleted)
//	apps-vanished      #apps would drop packages; best-effort, so it never blocks a sign-out on its own
//	locks-changed      no slot opens the stored head, and its keyslots are not the ones this session opened
//	                   (strandedReason, against the head restoreReceiptHead names): the sign-in was changed after
//	                   this phone signed in, and no slot this phone holds opens it
//	locks-changed-key  the same, and the stored head carries a security-key slot (a key can open it)
//	unlock-lost        no slot opens the stored head, and its keyslots are the ones this session opened: this phone
//	                   lost its own unlock material
//	unlock-lost-key    the same, with a security-key slot on the stored head
//
// The last four are final for THIS session's seal, not forever: the seals keep retrying underneath, and a later one
// that stores the vault withdraws the licence through reviewLogoffRefusal.
//
// RETRY, by elimination: "stale" (the head moved DURING the seal -- transient by construction, observed clearing
// twice on 2026-09-06), "fence" (the fence inside capFlush, which ALSO fires when the fence sequence moved during
// the push or a marker could not be stat'ed: a retry re-samples, and a real delete is then refused at entry as
// "deleted", which is final), "unreadable-head" (the store or the key failed; the agent's own line says retry),
// "mounts-unread" (the seal could not read the mount table whole: transient, so a retry re-reads it),
// "unfetched-unknown" and "unfetched-dropped" (NWP-20261124-06: the bare vault or #de seal cannot show it keeps,
// or would drop, a package whose data this session has not fetched; a retry cannot pass while the package stays
// unfetched, and the class is the fetch slice's to set when the unfetched list has a writer), "aftergate-no-carry"
// (NWP-20261128-03: the #media restore was split after the gate and the seal's carry did not run; every decline is
// transient or configuration, and END-UNSAVED must not be offered on a reason that is about keeping files), and
// anything unknown. Unknown is retry on purpose: offering a control that discards data on a reason this build
// cannot name would be the wrong way round.
func refusalReasonFinal(reason string) bool {
	switch reason {
	case "shrink", "no-receipt", "stale-base", "blind", "deleted", "apps-vanished",
		"locks-changed", "locks-changed-key", "unlock-lost", "unlock-lost-key":
		return true
	}
	return false
}

// logoffBlockingScopes are the scopes whose failure fails the sign-out (roamd's _push sets rc for these only;
// #sys, #apps and #keys are best-effort and never hold a session).
var logoffBlockingScopes = map[string]bool{"vault": true, "de": true, "media": true}

// finalScopes are the sign-out-BLOCKING scopes a verdict names as refused for a final reason.
func finalScopes(parts string, reasons map[string][]string) map[string]bool {
	out := map[string]bool{}
	for _, p := range strings.Split(parts, ",") {
		scope, cause, ok := strings.Cut(strings.TrimSpace(p), "=")
		if !ok || cause != "refused" || !logoffBlockingScopes[scope] {
			continue
		}
		for _, r := range reasons[scope] {
			if refusalReasonFinal(r) {
				out[scope] = true
			}
		}
	}
	return out
}

// logoffRefusalFinal is the sign-out's class: FINAL when at least one sign-out-BLOCKING scope was refused for a
// final reason, because then no retry can complete the sign-out, whatever the other scopes do.
func logoffRefusalFinal(parts string, reasons map[string][]string) bool {
	return len(finalScopes(parts, reasons)) > 0
}

// reviewLogoffRefusal re-judges the refusal on record against a LATER seal verdict, out, and the guards that seal
// named. The licence is a claim about the session ("these scopes cannot be sealed"), and every seal re-tests it:
//
//   - a seal verdict roamd wrote (OK, ERR-REFUSED, ERR-PUSH, ERR-NOCREDIT) keeps the licence only if EVERY scope
//     the record holds final is still refused for a final reason. A scope that sealed, failed for another reason,
//     or was refused only transiently has disproved it: a retry could now save what END-UNSAVED would discard.
//   - a skip or a busy slot (SKIP-*, BUSY) ran no seal, so it proves nothing either way.
//   - anything else (ERR-TIMEOUT and the like) ran a seal whose scopes cannot be read back, so the licence goes:
//     unknown is the side that never discards.
//
// It disarms only the record it judged, so a refusal recorded meanwhile is never cleared by an older verdict.
func reviewLogoffRefusal(out string, guards map[string][]string) {
	r := currentLogoffRefusal()
	if r == nil {
		return
	}
	keep := true
	switch v := sealVerb(out); {
	case strings.HasPrefix(v, "SKIP-") || v == workerBusy:
		return
	case v == "OK" || v == "ERR-REFUSED" || v == "ERR-PUSH" || v == "ERR-NOCREDIT":
		still := finalScopes(sealPartsOf(out), guards)
		for s := range finalScopes(r.parts, r.reasons) {
			keep = keep && still[s]
		}
	default:
		keep = false
	}
	if keep {
		return
	}
	logoffRefusalMu.Lock()
	if logoffRefusal == r {
		logoffRefusal = nil
	}
	logoffRefusalMu.Unlock()
	fmt.Fprintf(os.Stderr, "[logind] logout refusal user %s no longer holds: a later seal answered [%s] -- END-UNSAVED "+
		"is withdrawn until a sign-out is refused again (NWP-20261010-10)\n", r.uid, sealVerb(out))
}

// ---- the daemon side: when each scope last saved ----

var (
	scopeSavedMu sync.Mutex
	scopeSavedAt = map[string]int64{} // scope -> unix seconds of the last verdict that did NOT name it as failed
)

// sealedScopes are the scopes an `out` seals, in roamd's order.
var sealedScopes = []string{"vault", "de", "media", "sys", "apps"}

// noteScopesSaved records, for a verdict roamd's `out` wrote, every scope that verdict does not name as failed.
// roamd notes EVERY scope whose push did not exit 0 (`_note`), so an unnamed scope is one that sealed. Only the
// four verbs roamd's `out` writes count: a timeout, a busy slot or a skip says nothing about any scope.
func noteScopesSaved(out string, now int64) {
	switch sealVerb(out) {
	case "OK", "ERR-REFUSED", "ERR-PUSH", "ERR-NOCREDIT":
	default:
		return
	}
	failed := map[string]bool{}
	for _, p := range strings.Split(sealPartsOf(out), ",") {
		if s, _, ok := strings.Cut(strings.TrimSpace(p), "="); ok {
			failed[s] = true
		}
	}
	scopeSavedMu.Lock()
	for _, s := range sealedScopes {
		if !failed[s] {
			scopeSavedAt[s] = now
		}
	}
	scopeSavedMu.Unlock()
}

// verdictSavedAny reports whether a verdict roamd's `out` wrote landed at least one scope: one of the four verbs
// noteScopesSaved counts, naming fewer failed scopes than there are sealed scopes. A timeout, a busy slot or a skip
// saved nothing and says nothing.
func verdictSavedAny(out string) bool {
	switch sealVerb(out) {
	case "OK", "ERR-REFUSED", "ERR-PUSH", "ERR-NOCREDIT":
	default:
		return false
	}
	failed := map[string]bool{}
	for _, p := range strings.Split(sealPartsOf(out), ",") {
		if s, _, ok := strings.Cut(strings.TrimSpace(p), "="); ok {
			failed[s] = true
		}
	}
	return len(failed) < len(sealedScopes)
}

func resetScopeSavedAt() {
	scopeSavedMu.Lock()
	scopeSavedAt = map[string]int64{}
	scopeSavedMu.Unlock()
}

func scopeSavedSnapshot() map[string]int64 {
	scopeSavedMu.Lock()
	defer scopeSavedMu.Unlock()
	out := make(map[string]int64, len(scopeSavedAt))
	for k, v := range scopeSavedAt {
		out[k] = v
	}
	return out
}

// ---- the daemon side: the refused sign-out on record ----

// logoffRefusalRec is a refused sign-out, bound to the session it refused. In RAM only: a restarted daemon has
// none, and END-UNSAVED then answers ERR-NOTREFUSED until the user signs out again -- the safe direction.
type logoffRefusalRec struct {
	uid, name  string              // the session (the name never leaves this process)
	at         int64               // when the refused verdict landed
	parts      string              // roamd's PARTIAL list, benign parts dropped ("de=refused,apps=refused")
	reasons    map[string][]string // scope -> the guards that refused it, from the seal's stash
	final      bool                // logoffRefusalFinal
	askDeleted bool                // a guard said `deleted` or `fence`, so the STORE must say whether it is so

	// The store's answer (logoffProfileDeleted), under logoffRefusalMu: it arrives AFTER the record is published.
	deleted, deletedKnown bool
}

var (
	logoffRefusalMu sync.Mutex
	logoffRefusal   *logoffRefusalRec
)

func disarmLogoffRefusal() {
	logoffRefusalMu.Lock()
	logoffRefusal = nil
	logoffRefusalMu.Unlock()
}

func currentLogoffRefusal() *logoffRefusalRec {
	logoffRefusalMu.Lock()
	defer logoffRefusalMu.Unlock()
	return logoffRefusal
}

// licenses reports whether r licenses END-UNSAVED for the session (name, uid): it must be THAT session's
// refusal, and a final one.
func (r *logoffRefusalRec) licenses(name, uid string) bool {
	return r != nil && r.final && name != "" && r.name == name && uid != "" && r.uid == uid
}

// deletion is the store's answer so far: (deleted, known).
func (r *logoffRefusalRec) deletion() (bool, bool) {
	logoffRefusalMu.Lock()
	defer logoffRefusalMu.Unlock()
	return r.deleted, r.deletedKnown
}

func (r *logoffRefusalRec) setDeletion(deleted bool) {
	logoffRefusalMu.Lock()
	r.deleted, r.deletedKnown = deleted, true
	logoffRefusalMu.Unlock()
}

// stranded reports a refusal that names a stranded seal: a sign-out-blocking scope refused as locks-changed[-key]
// (the sign-in was changed on another phone) or unlock-lost[-key] (this phone lost its unlock material). Its
// END-UNSAVED cannot open the vault to save the wallet (#19 of 2026-10-22, NWP-20261114-06). reasons is set once,
// before the record is published, so no lock is needed. Nil-safe.
func (r *logoffRefusalRec) stranded() bool {
	if r == nil {
		return false
	}
	for scope, guards := range r.reasons {
		if !logoffBlockingScopes[scope] {
			continue
		}
		for _, g := range guards {
			switch g {
			case "locks-changed", "locks-changed-key", "unlock-lost", "unlock-lost-key":
				return true
			}
		}
	}
	return false
}

// logoffProfileDeleted asks the STORE whether the session's profile is deleted: its bare head is a tombstone
// (profileDeleted). It is asked only when a guard said `deleted` or `fence`, because those tokens are not proof:
// `fence` also fires when the fence sequence moves during a push or a fence marker cannot be stat'ed, and a live
// profile has carried stale fence markers before (NWP-20260921-06). A store error answers false -- the wallet is
// then saved and the copy stays the ordinary one. A variable so a test can answer for the store.
var logoffProfileDeleted = func(name, pass string) (deleted bool) {
	defer func() {
		if recover() != nil {
			deleted = false
		}
	}()
	return profileDeleted("s3", name, pass)
}

// profileGoneNow is the store's answer for r, asked NOW if the background lookup has not answered yet. Used where the
// answer decides an action (END-UNSAVED, RESTART-UNSAVED skip the wallet save only on it) -- both already wait on the
// store for the wallet, so this costs nothing the request was not already paying. False when nothing pointed at a delete.
func profileGoneNow(r *logoffRefusalRec, name, pass string) bool {
	if r == nil || !r.askDeleted || r.name != name {
		return false
	}
	if d, known := r.deletion(); known {
		return d
	}
	d := logoffProfileDeleted(name, pass)
	r.setDeletion(d)
	return d
}

// noteLogoffRefusal records the sign-out verdict out for the session (name, uid). It PEEKS at the seal's reason
// stash: recordSeal, run by logoffSealFailed straight after, consumes it and re-judges the same verdict. Anything
// but ERR-REFUSED records nothing and CHANGES nothing: recordSeal's review decides what that verdict does to a
// licence already on record (round 3: a fresh sign-out no longer disarms one up front). Logged without the profile
// name, with the class and each scope's guards, so a ticket says which kind of wedge it was.
//
// ⚠ NO STORE CALL ON THIS PATH (round 3). It runs BEFORE logoffSealFailed publishes FAILED, so a store lookup here
// held the "Saving…" screen for up to two 60 s lookups on a bad network. When a guard pointed at a delete, the store
// is asked on a goroutine instead; GET-LOGOFF-REFUSAL says DELETED once it has answered, and END-UNSAVED asks
// itself if it has not (profileGoneNow).
func noteLogoffRefusal(out, name, pass, uid string) {
	reasons := peekRefusalReasons()
	if sealVerb(out) != "ERR-REFUSED" {
		return
	}
	r := &logoffRefusalRec{uid: uid, name: name, at: time.Now().Unix(), parts: sealPartsOf(out),
		reasons: reasons}
	r.final = logoffRefusalFinal(r.parts, r.reasons)
	for _, rs := range reasons {
		for _, x := range rs {
			r.askDeleted = r.askDeleted || x == "deleted" || x == "fence"
		}
	}
	logoffRefusalMu.Lock()
	logoffRefusal = r
	logoffRefusalMu.Unlock()
	if r.askDeleted {
		ask := logoffProfileDeleted
		goSafe("logoff-deleted-check", func() { r.setDeletion(ask(name, pass)) })
	}
	class := "RETRY -- a retry may clear it"
	if r.final {
		class = "FINAL -- no retry can complete this sign-out; END-UNSAVED is offered"
	}
	fmt.Fprintf(os.Stderr, "[logind] logout refusal user %s: %s (guards: %s) (NWP-20261010-10)\n", uid, class, reasonsLog(reasons))
}

func reasonsLog(reasons map[string][]string) string {
	if len(reasons) == 0 {
		return "none named"
	}
	keys := make([]string, 0, len(reasons))
	for k := range reasons {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b []string
	for _, k := range keys {
		b = append(b, k+"="+strings.Join(reasons[k], "+"))
	}
	return strings.Join(b, ",")
}

// ---- the daemon side: a media sweep that keeps failing ----

// mediaStuck counts this session's CONSECUTIVE media-sweep failures: a sign-out that answered FAILED MEDIA, or an
// END-UNSAVED that answered ERR-MEDIA. A verified sweep resets it. At two it licenses RESTART-UNSAVED.
//
// WHY A SECOND EXIT (round 3). Both of the others need a verified sweep: a sign-out will not seal over a mount, and
// END-UNSAVED will not tear down over one. A leftover that never detaches -- an unmount the policy denies, a path
// decoding bug like NWP-20260828-06, or a leftover from an EARLIER session, since the sweep's count is device-wide --
// then left the user no exit inside the app. A reboot is the complete amnesiac teardown (the boot wipe reaps the
// user) and needs neither a sweep nor removeUser, so that is the exit, never a seal over the mount.
type mediaStuckRec struct {
	uid, name string
	n         int
}

var (
	mediaStuckMu sync.Mutex
	mediaStuck   mediaStuckRec
)

// noteMediaSweepFailed counts one failed sweep for the session (name, uid); another session's count starts over.
func noteMediaSweepFailed(name, uid string) int {
	mediaStuckMu.Lock()
	defer mediaStuckMu.Unlock()
	if mediaStuck.uid != uid || mediaStuck.name != name {
		mediaStuck = mediaStuckRec{uid: uid, name: name}
	}
	mediaStuck.n++
	return mediaStuck.n
}

// noteMediaSweepOK ends a run of failures for the session: the count is of CONSECUTIVE failures.
func noteMediaSweepOK(name, uid string) {
	mediaStuckMu.Lock()
	if mediaStuck.uid == uid && mediaStuck.name == name {
		mediaStuck.n = 0
	}
	mediaStuckMu.Unlock()
}

func resetMediaStuck() {
	mediaStuckMu.Lock()
	mediaStuck = mediaStuckRec{}
	mediaStuckMu.Unlock()
}

// mediaStuckCount is the session's run of failed sweeps, 0 for any other session.
func mediaStuckCount(name, uid string) int {
	mediaStuckMu.Lock()
	defer mediaStuckMu.Unlock()
	if name == "" || uid == "" || mediaStuck.uid != uid || mediaStuck.name != name {
		return 0
	}
	return mediaStuck.n
}

// restartUnsavedAfter is how many consecutive failed sweeps license RESTART-UNSAVED: the second, so one transient
// failure is retried first.
const restartUnsavedAfter = 2

// ---- the daemon side: a store that cannot be reached ----

// pushStuck counts this session's CONSECUTIVE sign-outs whose verdict was ERR-PUSH and that saved no scope (the
// store was unreachable). Anything that lands a save resets it (recordSeal). At two it licenses END-UNSAVED with no
// wallet publish: with no network, the publish cannot succeed either, and the user has no other exit but a power-off
// that loses the same changes without a word (Q070, docs/product-decisions.md, 2026-10-20).
type pushStuckRec struct {
	uid, name string
	n         int
}

var (
	pushStuckMu sync.Mutex
	pushStuck   pushStuckRec
)

// notePushFailed counts one ERR-PUSH sign-out for the session (name, uid); another session's count starts over.
func notePushFailed(name, uid string) int {
	pushStuckMu.Lock()
	defer pushStuckMu.Unlock()
	if pushStuck.uid != uid || pushStuck.name != name {
		pushStuck = pushStuckRec{uid: uid, name: name}
	}
	pushStuck.n++
	return pushStuck.n
}

func resetPushStuck() {
	pushStuckMu.Lock()
	pushStuck = pushStuckRec{}
	pushStuckMu.Unlock()
}

// pushStuckCount is the session's run of unreachable-store sign-outs, 0 for any other session.
func pushStuckCount(name, uid string) int {
	pushStuckMu.Lock()
	defer pushStuckMu.Unlock()
	if name == "" || uid == "" || pushStuck.uid != uid || pushStuck.name != name {
		return 0
	}
	return pushStuck.n
}

// endUnsavedPushAfter is how many consecutive ERR-PUSH sign-outs license END-UNSAVED: the second, so one transient
// failure is retried first.
const endUnsavedPushAfter = 2

// ---- the wire ----

// sessionPeerUID is the peer-uid read the verbs below scope on, a variable so a test can present a caller.
var sessionPeerUID = peerUID

// sessionCaller reports whether conn's peer is an app of the session's own Android user -- the identity
// GET-SESSION-NAME scopes on (uid/100000 against the marker's uid). An unidentifiable peer fails closed.
func sessionCaller(conn net.Conn, uid string) bool {
	puid := sessionPeerUID(conn)
	return puid > 0 && uid != "" && strconv.Itoa(puid/100000) == uid
}

// restSavedAt is the OLDEST last save among the scopes not named, 0 when any of them has none on record -- so a
// chooser can never state a time the daemon cannot back.
func restSavedAt(named map[string]bool, saved map[string]int64) int64 {
	var rest int64
	for _, s := range sealedScopes {
		if named[s] {
			continue
		}
		if saved[s] == 0 {
			return 0
		}
		if rest == 0 || saved[s] < rest {
			rest = saved[s]
		}
	}
	return rest
}

// refusalGuard is the guard a SCOPE line names for one scope: its first final guard (refusalReasonFinal), else its
// first guard, else "" (no guard on record).
func refusalGuard(rs []string) string {
	if len(rs) == 0 {
		return ""
	}
	g := rs[0]
	for _, x := range rs {
		if refusalReasonFinal(x) {
			g = x
			break
		}
	}
	return g
}

// refusalScopeLines renders one `SCOPE <scope> <cause>[:<guard>] <saved>` line (no trailing newline) per
// scope=cause in parts whose two tokens pass refusalToken, in parts' order, and returns the scopes it named.
// saved may be nil, and every <saved> is then 0. NWP-20261113-08: the one renderer of these lines, shared by
// GET-LOGOFF-REFUSAL (formatLogoffRefusal) and SEAL-DELTA's scopes (recordSeal), so the two cannot drift.
func refusalScopeLines(parts string, reasons map[string][]string, saved map[string]int64) ([]string, map[string]bool) {
	var lines []string
	named := map[string]bool{}
	for _, p := range strings.Split(parts, ",") {
		scope, cause, ok := strings.Cut(strings.TrimSpace(p), "=")
		if !ok || !refusalToken(scope) || !refusalToken(cause) {
			continue
		}
		named[scope] = true
		tok := cause
		if rs := reasons[scope]; len(rs) > 0 {
			tok += ":" + refusalGuard(rs)
		}
		lines = append(lines, fmt.Sprintf("SCOPE %s %s %d", scope, tok, saved[scope]))
	}
	return lines, named
}

// formatLogoffRefusal is GET-LOGOFF-REFUSAL's reply, with save times read NOW (saved is scopeSavedSnapshot at the
// moment of asking, so a session kept open for an hour after the refusal is described as it is, not as it was).
// r is the refusal on record (nil for none), media the session's run of failed sweeps, push its run of unreachable-store
// sign-outs:
//
//	REFUSED <FINAL|RETRY> <unix seconds the refused verdict landed>        (only with a refusal)
//	SCOPE <scope> <cause>[:<guard>] <unix seconds that scope last saved; 0 = no save seen this session>
//	SAVED <unix seconds>
//	DELETED          (only once the store has confirmed the profile is deleted)
//	MEDIA <n>        (only when n > 0: consecutive failed media sweeps; RESTART-UNSAVED is licensed at 2)
//	PUSH <n>         (only when n > 0: consecutive sign-outs that could not reach the store and saved nothing;
//	                  END-UNSAVED is licensed at 2, with no wallet publish; an older chooser ignores the line)
//
// one SCOPE line per scope roamd named, in its order (refusalScopeLines). <cause> is roamd's (refused, failed, timeout,
// nocredit, unreachable); <guard> is refusalGuard's pick: the first final guard for the scope, else its first guard,
// else absent. SAVED is restSavedAt over the scopes roamd did NOT name -- all of them when there is no refusal.
func formatLogoffRefusal(r *logoffRefusalRec, media, push int, saved map[string]int64) string {
	var b strings.Builder
	named := map[string]bool{}
	if r != nil {
		class := "RETRY"
		if r.final {
			class = "FINAL"
		}
		fmt.Fprintf(&b, "REFUSED %s %d\n", class, r.at)
		var lines []string
		lines, named = refusalScopeLines(r.parts, r.reasons, saved)
		for _, l := range lines {
			b.WriteString(l + "\n")
		}
	}
	fmt.Fprintf(&b, "SAVED %d\n", restSavedAt(named, saved))
	if r != nil {
		if d, known := r.deletion(); known && d {
			b.WriteString("DELETED\n") // only when the STORE says so (logoffProfileDeleted), never on a guard token
		}
	}
	if media > 0 {
		fmt.Fprintf(&b, "MEDIA %d\n", media)
	}
	if push > 0 {
		fmt.Fprintf(&b, "PUSH %d\n", push)
	}
	return b.String()
}

// handleGetLogoffRefusal answers GET-LOGOFF-REFUSAL: the asking session's refused sign-out and/or its run of failed
// media sweeps and unreachable-store sign-outs, or NONE. NONE covers no session, a caller that is not the session's user, and nothing on record
// alike, as GET-SESSION-NAME does -- a distinct answer for "wrong user" would confirm that some session is live.
// Lock-free and store-free: it is asked the instant a sign-out fails.
func handleGetLogoffRefusal(conn net.Conn, dest string) {
	name, _, uid := readRoamSession(dest)
	if name == "" || uid == "" || !sessionCaller(conn, uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	r := currentLogoffRefusal()
	if r != nil && (r.uid != uid || r.name != name) {
		r = nil
	}
	media := mediaStuckCount(name, uid)
	push := pushStuckCount(name, uid)
	if r == nil && media == 0 && push == 0 {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprint(conn, formatLogoffRefusal(r, media, push, scopeSavedSnapshot()))
}

// ---- END-UNSAVED ----

// ksLogoffCredsFile is roamd's keystore-push stash (KS_CREDS="$STATE/ks-logoff-creds"): every `out` writes this
// session's name and passphrase there, and the reap's cleanstorage adopts it to seal the #keys dump keystore2
// writes at removeUser. TestEndUnsaved_KsCredsPathIsRoamds pins the two spellings together.
const ksLogoffCredsFile = "ks-logoff-creds"

// endUnsavedSlotWait bounds the wait for the RW worker slot. Every seal holds that slot while it runs, so holding
// it is what proves none is running; a longer wait answers BUSY rather than leave the button hanging.
var endUnsavedSlotWait = 10 * time.Second

// endUnsavedWallet makes the session's wallet durable before END-UNSAVED discards it. A variable so a test can
// observe the call and fail it; production is publishWalletBeforeDiscard.
var endUnsavedWallet = publishWalletBeforeDiscard

// endUnsavedWalletDrop takes the saved wallet out of the state tmpfs once the reap is queued (NWP-20261021-01): the
// landed sign-out's own by-value publish-and-drop. A variable so a test can observe it.
var endUnsavedWalletDrop = sealLogoutWalletAndDrop

// The END-UNSAVED time budget, from the moment the request is read (see handleEndUnsaved). The chooser's read
// timeout is 90 s; the daemon's socket deadline is 75 s; the last irreversible step must start by 70 s. The sweep
// is stop_mediad's bounded retries (about 20 s at worst), so 45 s leaves it room inside the 70.
const endUnsavedDeadline = 75 * time.Second

var (
	endUnsavedSweepBy  = 45 * time.Second
	endUnsavedCommitBy = 70 * time.Second
)

// endUnsavedSweep runs roamd's sweepmedia INSIDE the RW slot END-UNSAVED already holds -- runWorkerHeld's second
// sanctioned caller, beside coldLockDispatch -- and returns its reply ("OK" only when no media mount is left). A
// variable so a test can answer for the worker.
var endUnsavedSweep = func(dest, name, pass, uid string) string {
	return runWorkerHeld(laneRW, dest, "sweepmedia", name, pass, uid, "", "", "", "", nil)
}

// endUnsavedFallback starts #86 Fix B's reboot backstop for the reap END-UNSAVED queued. A variable so a test can
// see it is armed without arming a reboot.
var endUnsavedFallback = func(uid string) { goSafe("reap-or-reboot", func() { reapOrReboot(uid) }) }

// endUnsavedKickMediad revives the kept session's media after an undo (kickMediad), a variable so a test can see it.
var endUnsavedKickMediad = kickMediad

// walletNoDKErr is publishWalletBeforeDiscard's answer when no key resolved. errWalletNotRestored wins: a session
// that never read its stored wallet publishes none whatever the head says. Otherwise errWalletNoSlot ONLY when a
// vault head was read and no slot opens it (v != nil); with no head read (a missing head, or a store that answered
// nothing) the error stays a plain one, so the caller answers ERR-WALLET (NWP-20261114-06).
func walletNoDKErr(notRestored bool, v *vault) error {
	if notRestored {
		return fmt.Errorf("%w (no keyslot opens this profile's vault)", errWalletNotRestored)
	}
	if v != nil {
		return errWalletNoSlot
	}
	return errors.New("no keyslot opens this profile's vault")
}

// publishWalletBeforeDiscard publishes the session's wallet the way an "Add credits" does (handleClaim):
// sealWalletDurable, which returns only once the bytes have landed. THE WALLET IS THE ONE THING END-UNSAVED SAVES,
// because it is not this session's DATA, it is money: wallet.json lives in the tmpfs, blind tokens are bearer
// instruments the gateway cannot re-issue (#218), and every other publisher of it rides a seal (the capFlush fold)
// that this ending skips. A missing file has nothing to lose. gen is the wallet generation the handler read BEFORE the
// session's credentials (NWP-20261013-20): the retry below refuses a wallet that is no longer at it. A vault head
// that no slot this phone holds opens is errWalletNoSlot (walletNoDKErr, NWP-20261114-06).
func publishWalletBeforeDiscard(dest, name, pass string, se []byte, gen string) (err error) {
	wp := walletPathFor(dest)
	if _, serr := os.Stat(wp); serr != nil {
		if errors.Is(serr, fs.ErrNotExist) {
			return nil
		}
		return serr
	}
	// NWP-20261013-20: a session whose sign-in read of the wallet did not land publishes none. Read it once more (the
	// store may be back); landed, the publish below goes as usual. Still failing -- the read, or the key resolution
	// before it, which is a store read too -- errWalletNotRestored, and NOTHING is published: the caller ends the
	// session anyway and warns that credit added this session is lost (the decision of 2026-10-15). The stored wallet
	// is untouched either way.
	notRestored := walletNotRestored(wp, gen)
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("%v", r)
			if notRestored {
				err = fmt.Errorf("%w (the key read failed: %v)", errWalletNotRestored, r)
			}
		}
	}()
	dk, v := resolveDKVault("s3", name, pass, se)
	if dk == nil {
		return walletNoDKErr(notRestored, v)
	}
	if rerr := retryWalletRestore("s3", name, pass, dk, wp, gen); rerr != nil {
		return rerr
	}
	notRestored = false
	_, err = sealWalletDurable("s3", name, pass, dk, wp)
	return err
}

// endUnsavedCreditLost is the success reply of an END-UNSAVED or a RESTART-UNSAVED that went ahead without a wallet
// publish because the session never read its stored wallet (NWP-20261013-20, decided 2026-10-15 "Allow, warn"): the
// session ends as with OK, the stored wallet is untouched, and credit added during this session is lost. The chooser
// shows that warning on its ending screen. A distinct word, never OK, so no older reading can pass it for a clean end.
const endUnsavedCreditLost = "OK-CREDIT-LOST"

// okAsConn hands handleLogout a connection whose bare "OK" reply goes out as ok instead: END-UNSAVED's commit is
// handleLogout's throwaway branch, and that branch's reply is the one END-UNSAVED gives.
type okAsConn struct {
	net.Conn
	ok string
}

func (c okAsConn) Write(b []byte) (int, error) {
	if string(b) != "OK\n" {
		return c.Conn.Write(b)
	}
	if _, err := io.WriteString(c.Conn, c.ok+"\n"); err != nil {
		return 0, err
	}
	return len(b), nil
}

// sealAnnounced reports a seal that is running or queued for the worker slot: a logoff or manual seal
// (sealInFlight) or an announced periodic or promote run (sealRunKind). No expiry, unlike handleBackup's guard:
// a wedged run is exactly when a reap must not race it.
func sealAnnounced() bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return sealInFlight || sealRunKind != ""
}

// endUnsavedBlocked names what else is ending or locking this session, or "".
func endUnsavedBlocked(uid string) string {
	pendingReapMu.Lock()
	queued := pendingSwitchUID != "" || pendingReapUID != "" || pendingLockUID != ""
	pendingReapMu.Unlock()
	if queued {
		return "a teardown is already queued"
	}
	if logoffInFlight(uid) {
		return "a sign-out of this session is still running"
	}
	coldLockMu.Lock()
	cl := coldLockRunning
	coldLockMu.Unlock()
	if cl {
		return "a cold lock is running"
	}
	return ""
}

// handleEndUnsaved answers END-UNSAVED: end the live session WITHOUT sealing it, because its sign-out was refused
// by a guard no retry can satisfy. Replies:
//
//	OK              the session is discarded; the switch+reap is queued (handleLogout's throwaway branch replies)
//	NONE            no live session, or the caller is not that session's user
//	ERR-LOCAL       a throwaway or offline session: its ordinary sign-out already discards it
//	ERR-NOTREFUSED  no FINAL refusal of THIS session is on record (none, a retryable one, a later seal withdrew
//	                it, or this is a different session)
//	BUSY seal       a seal is running or queued (RESTART-UNSAVED: or one was announced while the wallet saved);
//	                nothing was changed
//	BUSY teardown   a sign-out, a cold lock or a teardown of this session is already running or queued; nothing
//	                was changed
//	BUSY rent       a rent payment is running (NWP-20261026-12); nothing was changed
//	BUSY slot       the worker slot stayed held; nothing was changed (the wallet save stands)
//	OK-CREDIT-LOST  as OK, but nothing published the wallet: the session never read its stored wallet (its sign-in
//	                read and the retry here both failed), so credit added this session is lost; the stored wallet is
//	                untouched (NWP-20261013-20); also a stranded session (a final refusal named locks-changed[-key]
//	                or unlock-lost[-key]) whose vault head no slot this phone holds opens (#19, Q016, NWP-20261114-06)
//	ERR-WALLET      the wallet could not be made durable first; nothing was changed
//	ERR-KEYS        the keystore-push stash could not be removed; nothing was changed
//	ERR-STATE       the session could not be marked local; the session is kept
//	ERR-MEDIA       the media sweep did not verify (a mount is left); the session is kept and its media revived
//	                (kickMediad); this counts toward RESTART-UNSAVED
//	ERR-SLOW        the time budget ran out before the commit; the session is kept (the wallet save stands)
//
// "The session is kept" means signed in and sealing as before, with one difference until its next `out`: the
// keystore-push stash is gone. Harmless -- every `out`, periodic ones included, rewrites it first thing.
//
// Every BUSY names its cause in one token (NWP-20261117-32), as Back up now's does (NWP-20261026-13). A bare BUSY
// comes only from the dispatcher (sessionMu held), so the chooser reads a bare BUSY and an unknown token as "busy".
// Every BUSY, ERR-WALLET, ERR-MEDIA and ERR-SLOW leave the refusal on record, so the chooser may offer the control
// again.
//
// WHAT IT DISCARDS, which the chooser's confirmation states: every scope's changes since its last successful
// save, and this session's Keystore changes (#keys). WHAT IT KEEPS: the stored copy, untouched. The wallet is
// saved first and, once the reap is queued, taken out of the state tmpfs by the landed sign-out's step
// (endUnsavedWalletDrop: a by-value publish and a generation+bytes-checked drop, NWP-20261021-01); an OK-CREDIT-LOST
// end and a profile the store says is deleted keep the file.
//
// ⚠ #keys IS NOT PUSHED, ON PURPOSE. #keys is sealed at the REAP, by cleanstorage adopting the stash every `out`
// writes. Left alone, the reap would seal THIS session's Keystore dump over the stored #keys -- the one store
// write the user was just told would not happen, and the WORST one to let through: the refusal says this phone's
// copy is wrong in some way the guards can see, and #keys is the scope they cannot (its push replaces the whole
// scope). An app whose data on this phone was destroyed (the reconcile lead on NWP-20260910-10) may have lost its
// keys with it, and pushing them would spread that loss to the stored copy every later sign-in restores. With the
// stash gone cleanstorage takes its credless arm: keys=notsealed, and the dump is destroyed. The stored #keys and
// the stored app data then both stand at their last save, as a power-off leaves them -- the outcome the field
// already took as its only escape. The cost is the cold lock's (NWP-20261005-17, priced by Chester): keys an app
// minted this session do not roam, so it may ask the user to sign in again.
//
// ⚠ ORDER. The checks that need nothing changed run first. The wallet goes next because it needs the session; the
// RW slot is taken after it and held to the end, so no seal is running when the reap is queued and any seal queued
// behind it meets the clobber guard (SKIP-REAPING) rather than a half-reaped user. Then, inside the time budget:
// the #keys stash goes, the session is marked local (so nothing re-mounts its media), and the VERIFIED media sweep
// runs -- the same sweepmedia the logoff runs before its seal. A sweep that leaves a mount, or a budget spent,
// undoes the local mark and keeps the session. Only then is the session handed to handleLogout, whose throwaway
// branch is the unsealed teardown the throwaway logout, the offline relogin and this share, and #86 Fix B's
// reboot backstop is armed exactly as for a logoff that lands; the wallet step starts after that backstop is armed.
func handleEndUnsaved(conn net.Conn, dest string) {
	// THE TIME BUDGET (review of NWP-20261010-10). The chooser reads this reply for 90 s (sendDaemon's
	// setSoTimeout) and, on a timeout, tells the user they are still signed in -- so the daemon must never tear down
	// after that. A socket deadline cannot enforce it: the wallet publish is a chain of storeHTTP calls that ignore
	// it. So the handler checks its own clock before each irreversible step: endUnsavedSweepBy before it changes
	// anything, endUnsavedCommitBy after the sweep, and it commits only inside both. Past either it undoes what it
	// changed and answers ERR-SLOW. 70 s + the commit (milliseconds) < the 75 s socket deadline < the chooser's 90 s.
	t0 := time.Now().Round(0) // WALL time, so a suspend counts (NWP-20260913-18)
	conn.SetDeadline(t0.Add(endUnsavedDeadline))
	wgen := walletGeneration(walletPathFor(dest)) // NWP-20261013-20: BEFORE the session read (publishWalletBeforeDiscard)
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" || !sessionCaller(conn, uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "ERR-LOCAL\n")
		return
	}
	r := currentLogoffRefusal()
	final := r.licenses(name, uid)
	// Q070: two sign-outs in a row that could not reach the store license the end too -- WITHOUT a wallet publish.
	push := !final && pushStuckCount(name, uid) >= endUnsavedPushAfter
	if !final && !push {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s refused: no final sign-out refusal of this session on record\n", uid)
		fmt.Fprint(conn, "ERR-NOTREFUSED\n")
		return
	}
	if sealAnnounced() {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: BUSY -- a seal is running or queued\n", uid)
		fmt.Fprint(conn, "BUSY seal\n")
		return
	}
	if why := endUnsavedBlocked(uid); why != "" {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: BUSY -- %s\n", uid, why)
		fmt.Fprint(conn, "BUSY teardown\n")
		return
	}
	if !holdRentForExit() {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: BUSY -- a rent payment is running (NWP-20261026-12)\n", uid)
		fmt.Fprint(conn, "BUSY rent\n")
		return
	}
	defer releaseRent() // every answer, OK included: after OK the session is local and maybePayRent refuses it
	wallet := "the store says the profile is deleted, so there was no wallet head to save"
	reply := conn        // handleLogout's reply, below, is this handler's
	creditLost := false  // NWP-20261013-20: the gate's notice is recorded only once the end is certain, below
	walletSaved := false // NWP-20261021-01: only a save that landed lets the file go, below
	if push {
		// No network: the publish below cannot land, and answering ERR-WALLET would keep the user here. A session
		// that never read its stored wallet and holds credit loses it, as the wallet-not-restored arm below says.
		wallet = "no wallet publish: the store could not be reached (two sign-outs in a row)"
		if parkedCreditUnsaved(walletPathFor(dest)) {
			reply = okAsConn{conn, endUnsavedCreditLost}
			creditLost = true
		}
	} else if !profileGoneNow(r, name, pass) {
		wallet = "the wallet was saved first"
		if err := endUnsavedWallet(dest, name, pass, seFromHex(readRoamSessionSE(dest)), wgen); errors.Is(err, errWalletNotRestored) {
			wallet = "the wallet was NOT saved: this session never read its stored wallet, so the credit it added is " +
				"lost and the stored wallet is untouched (NWP-20261013-20)"
			fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: the wallet read failed at sign-in and again now -- "+
				"ending anyway WITHOUT a wallet publish; credit added this session is lost (%s)\n", uid, endUnsavedCreditLost)
			reply = okAsConn{conn, endUnsavedCreditLost}
			creditLost = true
		} else if errors.Is(err, errWalletNoSlot) && final && r.stranded() {
			// #19 of 2026-10-22 (Q016): a session stranded by a security key enrolled on another phone, or by this
			// phone losing its unlock, cannot open the vault, so it ends WITHOUT the publish and warns that credit
			// added this session is lost. The file stays (walletSaved false); the stored wallet is untouched.
			wallet = "the wallet was NOT saved: no slot this phone holds opens the vault (the sign-in changed or this " +
				"phone lost its unlock), so the credit it added is lost and the stored wallet is untouched (NWP-20261114-06)"
			fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: no slot this phone holds opens the vault of a stranded "+
				"session -- ending anyway WITHOUT a wallet publish; credit added this session is lost (%s, NWP-20261114-06)\n",
				uid, endUnsavedCreditLost)
			reply = okAsConn{conn, endUnsavedCreditLost}
			creditLost = true
		} else if err != nil {
			fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: the wallet could not be saved first (%s) -- session kept\n", uid, logSafeErrText(err))
			fmt.Fprint(conn, "ERR-WALLET\n")
			return
		} else {
			walletSaved = true
		}
	}
	select {
	case laneRW.slot <- struct{}{}:
	case <-time.After(endUnsavedSlotWait):
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: BUSY -- the worker slot stayed held\n", uid)
		fmt.Fprint(conn, "BUSY slot\n")
		return
	}
	defer func() { <-laneRW.slot }()
	// Re-checked under the slot: the wallet publish took seconds, and in them a periodic seal may have answered
	// (reviewLogoffRefusal withdraws a licence a later seal disproved) or the session may have changed.
	if n2, _, u2 := readRoamSession(dest); n2 != name || u2 != uid ||
		(final && currentLogoffRefusal() != r) || (push && pushStuckCount(name, uid) < endUnsavedPushAfter) {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s refused: the refusal is no longer current\n", uid)
		fmt.Fprint(conn, "ERR-NOTREFUSED\n")
		return
	}
	dropSE := seFromHex(readRoamSessionSE(dest)) // read while the marker still stands: the throwaway branch removes it
	if why := endUnsavedBlocked(uid); why != "" {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: BUSY -- %s\n", uid, why)
		fmt.Fprint(conn, "BUSY teardown\n")
		return
	}
	// The budget, BEFORE anything changes: the wallet and the slot may have eaten it, and the sweep after this
	// point is bounded by stop_mediad's retries, not by the clock.
	if time.Since(t0) > endUnsavedSweepBy {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: ERR-SLOW -- %s spent before the sweep; nothing torn "+
			"down, the wallet save stands\n", uid, time.Since(t0).Round(time.Second))
		fmt.Fprint(conn, "ERR-SLOW\n")
		return
	}
	if err := os.Remove(filepath.Join(dest, ksLogoffCredsFile)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: the keystore-push stash could not be removed (%v) -- session kept\n", uid, err)
		fmt.Fprint(conn, "ERR-KEYS\n")
		return
	}
	// LOCAL before the sweep: kickMediad no-ops for a local session, so a periodic seal's post-seal kick cannot
	// bring an overlay back between the sweep and the reap. Undone below on any refusal.
	markLocalSession(dest)
	if !isLocalSession(dest) {
		// handleLogout would take the SEAL path for a session that is not local -- the opposite of what the user
		// confirmed. The stash is gone, which the next `out` rewrites; nothing else has changed.
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: the session could not be marked local -- session kept\n", uid)
		fmt.Fprint(conn, "ERR-STATE\n")
		return
	}
	undo := func(reply, why string) {
		clearLocalSession(dest)
		os.Remove(filepath.Join(dest, ".btlogoff")) // a verified sweep marks the logoff; a session that stays must not keep it
		// The sweep stopped mediad. The session stays, so give it its overlays back NOW: otherwise its apps see
		// un-stubbed directories until the next periodic seal's kick, about two minutes away.
		endUnsavedKickMediad(dest)
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: %s -- %s; session kept\n", uid, reply, why)
		fmt.Fprint(conn, reply+"\n")
	}
	// The logoff's own pre-seal teardown, VERIFIED: removeUser cannot delete through a live or dead FUSE mount, so
	// tearing down over one is an amnesia failure (and FILES_BUSY at key removal). stopMediad first, as the logoff
	// does; roamd's sweepmedia then detaches the overlays and answers OK only when /proc/mounts has none left.
	stopMediad(dest)
	if sw := endUnsavedSweep(dest, name, pass, uid); sw != "OK" {
		n := noteMediaSweepFailed(name, uid)
		undo("ERR-MEDIA", fmt.Sprintf("the media sweep did not verify [%s] (%d in a row)", sw, n))
		return
	}
	noteMediaSweepOK(name, uid)
	if time.Since(t0) > endUnsavedCommitBy {
		undo("ERR-SLOW", time.Since(t0).Round(time.Second).String()+" spent by the end of the sweep")
		return
	}
	disarmLogoffRefusal()
	clearSealBlindPkgs() // the blocked apps' names describe a session that is ending; do not leave them in the tmpfs
	why := "no network (ERR-PUSH x" + strconv.Itoa(pushStuckCount(name, uid)) + ")"
	if final {
		why = r.parts
	}
	fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: session discarded WITHOUT a seal (refused: %s) -- the "+
		"stored copy is untouched and #keys is not pushed; %s (NWP-20261010-10)\n", uid, why, wallet)
	resetPushStuck() // the committed end: nothing of this session's run outlives it
	// NWP-20261013-20: the reply is read by the session's own screen, and the reap switches to the gate within a moment,
	// so the gate shows the lost credit (noteCreditLost) -- recorded here, after every abort above, before the switch.
	if creditLost && walletHoldsCredit(walletPathFor(dest)) {
		noteCreditLost(dest)
	}
	handleLogout(reply, dest) // the throwaway branch: clears the markers, queues the switch+reap, replies OK (or OK-CREDIT-LOST)
	endUnsavedFallback(uid)   // #86 Fix B, as the logoff that lands: the reap must not silently not happen
	if walletSaved {
		// A goroutine, as at LOGOUT: a slow store must never hold the reply, sessionMu or the reap backstop.
		fmt.Fprintf(os.Stderr, "[logind] end-unsaved user %s: the saved wallet now leaves the state tmpfs (NWP-20261021-01)\n", uid)
		goSafe("end-unsaved-wallet", func() {
			endUnsavedWalletDrop(dest, name, pass, dropSE, wgen, uid)
			forgetSessionKeys("end-unsaved wallet published") // dn-1106 #1: the publish was the session's last use of its keys
		})
	}
}

// ---- RESTART-UNSAVED ----

// restartUnsavedReboot reboots the phone for RESTART-UNSAVED, through rebootNow like every reboot the daemon issues
// (it records the reason; reapOrReboot uses the same). A variable so a test can see it without a reboot.
var restartUnsavedReboot = func(uid string) {
	rebootNow("restart without saving: the media sweep failed repeatedly uid=" + uid)
}

// restartUnsavedWatchdog is how long the daemon waits, after asking for the reboot, before it asks once more, and
// again before it concludes the reboot did not happen (restartDidNotHappen) -- 60 s in all. restartUnsavedWait is that
// wait, a variable so a test can decide when it ends.
//
// ⚠ CLOCK_BOOTTIME (round 7). time.Sleep freezes across a suspend (the NWP-20260913-18 trap), while the chooser counts
// elapsedRealtime, which does not; so after a screen-off the two disagreed about how long the restart had been
// pending. Round 6 moved the wait to the wall clock, which fixes the suspend but not a clock SET: an NTP correction or
// a manual change backwards stretched the wait without bound, and for all of it the session stays marked local.
// bootNowMs is elapsedRealtime's own clock: it runs through a suspend and never jumps.
var restartUnsavedWatchdog = 30 * time.Second

var restartUnsavedWait = func() { sleepBootSteps(restartUnsavedWatchdog, time.Second) }

// restartSleep is sleepBootSteps' nap, a variable so a test can stand a suspend in for it.
var restartSleep = time.Sleep

// sleepBootSteps returns once d of CLOCK_BOOTTIME has passed, re-reading it at least every step, so after a suspend
// the wait ends within one step of the wake (sleepUntilWall's 30 s naps would let a 30 s wait overrun by a whole nap).
// If the clock cannot be read (bootNowMs answers 0) it falls back to one plain sleep of d: bounded, if suspend-blind.
// If it stops being readable part-way, the rest of the wait -- as of the last good reading -- is one plain sleep too
// (round 9). Not a return: a wait cut short would let the watchdog give the session back while a real shutdown is
// still under way, which breaks "nothing seals before the reboot". The rest is counted from the last reading, so it
// errs long by at most one step. And not the old loop either: a reading of 0 counts as a deadline still far away,
// nap after nap, for ever. Either way it says so once.
func sleepBootSteps(d, step time.Duration) {
	start := bootNowMs()
	if start <= 0 {
		fmt.Fprintf(os.Stderr, "[logind] restart-unsaved: CLOCK_BOOTTIME unreadable -- waiting %s on the "+
			"suspend-blind clock instead (NWP-20261010-10)\n", d)
		restartSleep(d)
		return
	}
	deadline, last := start+d.Milliseconds(), start
	for {
		now := bootNowMs()
		if now <= 0 {
			rest := time.Duration(deadline-last) * time.Millisecond
			fmt.Fprintf(os.Stderr, "[logind] restart-unsaved: CLOCK_BOOTTIME became unreadable mid-wait -- waiting "+
				"the remaining %s on the suspend-blind clock (NWP-20261010-10)\n", rest)
			if rest > 0 {
				restartSleep(rest)
			}
			return
		}
		last = now
		rem := time.Duration(deadline-now) * time.Millisecond
		if rem <= 0 {
			return
		}
		if rem > step {
			rem = step
		}
		restartSleep(rem)
	}
}

// restartRetryBound bounds the watchdog's second reboot request: AOSP's `reboot` pause()s after it sets the property,
// so a call that "worked" on a shutdown that then stalls would otherwise hold the watchdog forever.
var restartRetryBound = 10 * time.Second

// restartReboots counts the reboot calls still running on their own goroutines (the handler's, and the watchdog's
// bounded retry). Nothing in the daemon waits on it -- a reboot that returns is either the end or a failure the
// watchdog already handles -- it exists so a test can wait for them before it puts its hooks back.
var restartReboots sync.WaitGroup

// restartHooks are the hooks a restart runs with, read ONCE, on the handler's goroutine. The watchdog and the reboot
// goroutines use this copy and never the package variables, which a test may put back while they still run.
type restartHooks struct {
	reboot func(uid string)
	wait   func()
	bound  time.Duration
}

func currentRestartHooks() restartHooks {
	return restartHooks{reboot: restartUnsavedReboot, wait: restartUnsavedWait, bound: restartRetryBound}
}

// rebootAsync runs h.reboot on its own goroutine, counted in restartReboots, and closes the returned channel when it
// returns or panics.
func (h restartHooks) rebootAsync(uid string) <-chan struct{} {
	done := make(chan struct{})
	restartReboots.Add(1)
	goSafe("restart-reboot", func() {
		defer restartReboots.Done()
		defer close(done)
		defer func() { recover() }() // a panicking reboot must not take the daemon or skip the watchdog's give-up
		h.reboot(uid)
	})
	return done
}

// The restart's outcome, for RESTART-STATUS (round 5): "" none, "PENDING" from OK until the watchdog gives up,
// "FAILED" once it has. Bound to the session (name and uid) it was asked for; reset at every session start.
var (
	restartMu                           sync.Mutex
	restartState, restartUID, restartNm string
)

func setRestartState(st, name, uid string) {
	restartMu.Lock()
	restartState, restartUID, restartNm = st, uid, name
	restartMu.Unlock()
}

func resetRestartState() { setRestartState("", "", "") }

// restartPending reports a restart asked for and not yet given up on. LOGOUT answers BUSY then (handleLogout): from
// the OK until the watchdog the session is marked local, and a sign-out would take the throwaway branch -- a reap
// without a seal the user did not confirm. The chooser treats that BUSY as an unanswered LOGOUT and reboots itself,
// which is the outcome the user DID confirm. PROMOTE and PROMOTE2 answer BUSY then too (promoteGuards, round 7): the
// local mark is the restart's, not a throwaway's, and "Save to your store" would fork a stored profile into a new one.
func restartPending() bool {
	restartMu.Lock()
	defer restartMu.Unlock()
	return restartState == "PENDING"
}

// handleRestartStatus answers RESTART-STATUS for the asking session: PENDING, FAILED or NONE (also for another
// user's caller, or another session on the same uid, as GET-SESSION-NAME does). Lock-free: the chooser polls it on its
// "Restarting…" screen.
func handleRestartStatus(conn net.Conn, dest string) {
	name, _, uid := readRoamSession(dest)
	restartMu.Lock()
	st, ru, rn := restartState, restartUID, restartNm
	restartMu.Unlock()
	if st == "" || uid == "" || ru != uid || rn != name || !sessionCaller(conn, uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(conn, "%s\n", st)
}

// ---- a restart pending across a daemon restart (round 6) ----

// restartMarkerFile records a pending restart in the state tmpfs: written with PENDING, removed when the watchdog
// gives the session back or finds it changed. A reboot wipes the tmpfs with it. If the DAEMON restarts while it exists
// -- the watchdog died with it, and the session would stay local forever: no seals, and a sign-out down the throwaway
// branch -- recoverRestartMarker gives the session back at the next start. It holds the uid and a SHA-256 of the
// profile name, never the name: the tmpfs file is not where a name belongs, and the hash is enough to tell "this
// session" from a later one on the same uid. A restart that loses credit adds a third line, the time of the notice it
// leaves for the gate after the boot (writeRestartMarkerTell, NWP-20261016-47).
const restartMarkerFile = "restart.pending"

func restartMarkerID(name string) string {
	sum := sha256.Sum256([]byte("nowhere-restart-marker\x00" + name))
	return hex.EncodeToString(sum[:])
}

// writeRestartMarker is written BEFORE the session is marked local (round 7): a local mark without a marker is a
// session no daemon restart can give back, so a failed write must stop the restart with nothing changed.
func writeRestartMarker(dest, name, uid string) error {
	return writeRestartMarkerTell(dest, name, uid, "")
}

// writeRestartMarkerTell is writeRestartMarker with a third line when tell is not "" (NWP-20261016-47): the time of the
// lost-credit notice this restart leaves for the gate after the boot (noteRestartCreditLost). The marker outlives the
// phone's uptime only through a reboot, so wherever it is removed with the phone still up the reboot did not happen,
// and removeRestartMarker takes that notice back by this stamp.
func writeRestartMarkerTell(dest, name, uid, tell string) error {
	body := uid + "\n" + restartMarkerID(name) + "\n"
	if tell != "" {
		body += tell + "\n"
	}
	return os.WriteFile(filepath.Join(dest, restartMarkerFile), []byte(body), 0o600)
}

// restartMarkerTell is the marker's third line, or "" (no marker, or a restart that tells nothing).
func restartMarkerTell(dest string) string {
	b, err := os.ReadFile(filepath.Join(dest, restartMarkerFile))
	if err != nil {
		return ""
	}
	if f := strings.Split(strings.TrimSpace(string(b)), "\n"); len(f) == 3 {
		return strings.TrimSpace(f[2])
	}
	return ""
}

// removeRestartMarker removes the marker, and with it the restart notice it carries (retractRestartCreditLost): a
// marker removed while the phone is up is a restart whose reboot did not happen.
func removeRestartMarker(dest string) {
	retractRestartCreditLost(restartMarkerTell(dest))
	os.Remove(filepath.Join(dest, restartMarkerFile))
}

// recoverRestartMarker runs once at daemon start. A marker left behind means a restart was pending when the daemon
// last ran and the phone did NOT reboot (the tmpfs survived). If the live session is the marked one and still local,
// it is given back -- the local mark goes, its media is revived -- and logged; the marker goes either way, and with it
// the restart's lost-credit notice (removeRestartMarker): the reboot it announced did not happen. The RW slot the dead
// watchdog held does not need releasing: it lived in the dead process.
func recoverRestartMarker(dest string) {
	b, err := os.ReadFile(filepath.Join(dest, restartMarkerFile))
	if err != nil {
		return
	}
	removeRestartMarker(dest)
	f := strings.Split(strings.TrimSpace(string(b)), "\n")
	name, _, uid := readRoamSession(dest)
	if (len(f) != 2 && len(f) != 3) || name == "" || f[0] != uid || f[1] != restartMarkerID(name) || !isLocalSession(dest) {
		fmt.Fprintf(os.Stderr, "[logind] restart-unsaved: a restart marker from before this daemon started does not match "+
			"the live session -- dropped, nothing given back (NWP-20261010-10)\n")
		return
	}
	clearLocalSession(dest)
	endUnsavedKickMediad(dest)
	fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: THE RESTART DID NOT HAPPEN -- the daemon restarted while it "+
		"was pending; the session is given back, signed in and sealing (NWP-20261010-10)\n", uid)
}

// handleRestartUnsaved answers RESTART-UNSAVED: discard the live session by REBOOTING, when the media sweep has
// failed restartUnsavedAfter times in a row for it (mediaStuck) -- the case where neither a sign-out nor END-UNSAVED
// can finish, because both need a verified sweep. The boot wipe is the complete amnesiac teardown: it reaps the user
// with no sweep and no removeUser, so a leftover mount does not matter. NEVER a seal over the mount.
//
// Same guards as END-UNSAVED (the session's own chooser, sessionMu by TryLock, no seal or teardown running, the RW
// slot held), licensed by the repeated sweep failure instead of a refusal. It saves the wallet durably first (unless
// the store says the profile is deleted) and aborts on failure -- except a session that never read its stored wallet,
// which publishes none and goes ahead with OK-CREDIT-LOST (NWP-20261013-20) and, when it holds credit, leaves the
// gate's lost-credit notice outside the state tmpfs for after the boot (noteRestartCreditLost, NWP-20261016-47) --
// drops the #keys stash, marks the session local, replies OK, then reboots. Replies as END-UNSAVED, with ERR-NOTSTUCK
// in place of ERR-NOTREFUSED; nothing changes on any reply but OK and OK-CREDIT-LOST, except the stash (see
// END-UNSAVED).
//
// ⚠ NOTHING SEALS BEFORE THE REBOOT, AND THAT IS ENFORCED, NOT ASSUMED. A periodic seal announced while the wallet
// was being saved answers BUSY seal at the re-check under the slot. On OK the RW slot is NOT released: every seal is an
// `out` through that slot, so none can start between the reply and the shutdown. The watchdog (restartDidNotHappen)
// owns it from before the reboot call, so it is released on every path, a panic in that call included.
//
// ⚠ A RESTART THAT DOES NOT HAPPEN IS NEVER SILENT (round 5). The watchdog asks for the reboot once more after
// restartUnsavedWatchdog, and only after a second wait gives up: RESTART-STATUS turns FAILED, which the chooser polls
// and says plainly; the session (only if it is still this one) is given back -- the local mark goes, its media is
// revived, the slot is released and periodic seals resume. Until then RESTART-STATUS says PENDING, LOGOUT answers
// BUSY (restartPending) and the chooser asks PowerManager for the reboot itself.
//
// ⚠ ACCEPTED TRADE-OFF (the round-3 review's note 7): the restart discards up to one sync interval of changes that a
// further periodic seal could still have saved to the scopes that were sealing. Waiting for that seal would put a
// seal back in front of a reboot whose whole point is that the media cannot be closed; the confirmation already
// lists those changes as discarded ("Anything you changed after <time>").
//
// ⚠ THE REBOOT ALSO CLEARS THE STATE TMPFS, which END-UNSAVED's reap does not: the sealed telephony inbox, the owner
// inbox and this session's pending copies live there, for EVERY profile (telephony_inbox.go, telephony_owner.go,
// telephony_ingest.go). The chooser's confirmation and its MEDIA copy say so in one STATIC sentence -- never a count,
// which would tell this session about other profiles' messages and break blind login.
func handleRestartUnsaved(conn net.Conn, dest string) {
	t0 := time.Now().Round(0)
	conn.SetDeadline(t0.Add(endUnsavedDeadline))
	wgen := walletGeneration(walletPathFor(dest)) // NWP-20261013-20: BEFORE the session read, as END-UNSAVED
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" || !sessionCaller(conn, uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "ERR-LOCAL\n")
		return
	}
	if mediaStuckCount(name, uid) < restartUnsavedAfter {
		fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s refused: the media sweep has not failed %d times in a row\n",
			uid, restartUnsavedAfter)
		fmt.Fprint(conn, "ERR-NOTSTUCK\n")
		return
	}
	if sealAnnounced() {
		fmt.Fprint(conn, "BUSY seal\n")
		return
	}
	if why := endUnsavedBlocked(uid); why != "" {
		fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: BUSY -- %s\n", uid, why)
		fmt.Fprint(conn, "BUSY teardown\n")
		return
	}
	if !holdRentForExit() {
		fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: BUSY -- a rent payment is running (NWP-20261026-12)\n", uid)
		fmt.Fprint(conn, "BUSY rent\n")
		return
	}
	defer releaseRent() // every answer, OK included: after OK restartPending keeps beginRent false until the watchdog settles
	ok, wallet := "OK", "the wallet was saved first"
	if r := currentLogoffRefusal(); !profileGoneNow(r, name, pass) {
		if err := endUnsavedWallet(dest, name, pass, seFromHex(readRoamSessionSE(dest)), wgen); errors.Is(err, errWalletNotRestored) {
			// NWP-20261013-20: as END-UNSAVED -- allowed, never a wallet publish, and the reply says the credit is lost.
			ok, wallet = endUnsavedCreditLost, "the wallet was NOT saved (its read failed at sign-in and again now; "+
				"credit added this session is lost, the stored wallet is untouched)"
			fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: the wallet read failed at sign-in and again now -- "+
				"restarting anyway WITHOUT a wallet publish; credit added this session is lost (%s)\n", uid, endUnsavedCreditLost)
		} else if err != nil {
			fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: the wallet could not be saved first (%s) -- nothing done\n", uid, logSafeErrText(err))
			fmt.Fprint(conn, "ERR-WALLET\n")
			return
		}
	}
	select {
	case laneRW.slot <- struct{}{}:
	case <-time.After(endUnsavedSlotWait):
		fmt.Fprint(conn, "BUSY slot\n")
		return
	}
	held := true // released on every answer but OK; on OK the watchdog owns it
	defer func() {
		if held {
			<-laneRW.slot
		}
	}()
	if n2, _, u2 := readRoamSession(dest); n2 != name || u2 != uid || mediaStuckCount(name, uid) < restartUnsavedAfter {
		restartRefused(conn, uid, "ERR-NOTSTUCK", "the session or its failed-sweep count changed while the wallet saved")
		return
	}
	// Re-checked under the slot: a periodic seal announced while the wallet was being saved is queued for this very
	// slot, and would otherwise run its `out` the moment the slot is free.
	if sealAnnounced() {
		restartRefused(conn, uid, "BUSY seal", "a seal was announced while the wallet saved")
		return
	}
	if why := endUnsavedBlocked(uid); why != "" {
		restartRefused(conn, uid, "BUSY teardown", why+" (re-checked under the slot)")
		return
	}
	if d := time.Since(t0); d > endUnsavedCommitBy {
		restartRefused(conn, uid, "ERR-SLOW", d.Round(time.Second).String()+" spent before anything changed; the wallet save stands")
		return
	}
	// NWP-20261016-47 (decided 2026-10-16, "warn and tell"): a restart that loses credit tells the gate after the boot.
	// Its reboot clears the state tmpfs where the gate's notice lives, so the notice goes to durable storage, stamped
	// now and carried in the marker below so a reboot that does not happen takes it back (removeRestartMarker).
	tell := ""
	if ok == endUnsavedCreditLost && walletHoldsCredit(walletPathFor(dest)) {
		tell = strconv.FormatInt(time.Now().Unix(), 10)
	}
	// The marker FIRST (round 7): a session marked local with no marker is one a daemon restart cannot give back, so
	// a failed write ends the restart here, before anything has changed. It goes again on every refusal below.
	if err := writeRestartMarkerTell(dest, name, uid, tell); err != nil {
		removeRestartMarker(dest) // a partial file must not linger for the next daemon start to read (round 8)
		restartRefused(conn, uid, "ERR-STATE", "the restart marker was not written ("+err.Error()+"); nothing changed")
		return
	}
	if err := os.Remove(filepath.Join(dest, ksLogoffCredsFile)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		removeRestartMarker(dest)
		restartRefused(conn, uid, "ERR-KEYS", "the keystore-push stash could not be removed ("+err.Error()+")")
		return
	}
	markLocalSession(dest) // syncLoop skips a local session, and the held slot stops any seal already queued
	if !isLocalSession(dest) {
		removeRestartMarker(dest)
		restartRefused(conn, uid, "ERR-STATE", "the session could not be marked local")
		return
	}
	clearSealBlindPkgs()
	// NWP-20261016-47: after the last refusal, so only a restart that goes ahead leaves the notice for after the boot.
	if tell != "" {
		noteRestartCreditLost(tell)
	}
	fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: rebooting WITHOUT a seal after %d failed media sweeps -- "+
		"the stored copy is untouched, #keys is not pushed, %s (NWP-20261010-10)\n",
		uid, mediaStuckCount(name, uid), wallet)
	setRestartState("PENDING", name, uid)
	// The hooks are read here, once (round 7): the watchdog and both reboot goroutines run on that copy.
	h := currentRestartHooks()
	// The watchdog takes the slot over BEFORE the reboot call (round 5, F3): whatever that call does -- returns,
	// fails, panics -- the slot is released by the watchdog's defer, never by this handler.
	held = false
	goSafe("restart-watchdog", func() { restartDidNotHappen(dest, name, uid, h) })
	fmt.Fprint(conn, ok+"\n")
	// ⚠ ASYNCHRONOUS (round 6). AOSP's reboot path can pause() after setting the property, so a synchronous call could
	// keep this handler -- and the sessionMu it runs under -- forever, and a LOGOUT after FAILED would then queue
	// behind it with no end. Nothing needs sessionMu held through the reboot: LOGOUT is refused by restartPending, the
	// slot (every seal) is held by the watchdog, and the marker and state are already written.
	h.rebootAsync(uid)
}

// restartRefused answers a RESTART-UNSAVED refusal and logs it, as END-UNSAVED logs its own: the uid, the reply and
// why, never a profile name. Every refusal after the slot is taken goes through it; the session is kept on each.
func restartRefused(conn net.Conn, uid, reply, why string) {
	fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: %s -- %s; session kept (NWP-20261010-10)\n", uid, reply, why)
	fmt.Fprintf(conn, "%s\n", reply)
}

// restartDidNotHappen is RESTART-UNSAVED's watchdog, and it owns the RW slot the restart kept: its defer releases it on
// every path. On a phone that is shutting down it never gets to act. Still alive after restartUnsavedWatchdog (boot
// time), it asks for the reboot ONCE more, bounded by restartRetryBound; still alive after a second wait, the reboot
// did not happen. Then, in this order (round 6):
//  1. if the live session is still the one the restart was asked for, it is given back -- the local mark goes and its
//     media is revived, as END-UNSAVED's undo does -- and only THEN does RESTART-STATUS turn FAILED, so restartPending
//     can never go false while the local mark still stands;
//  2. if the session changed (round 5, F2: a later throwaway on the same uid, the NWP-20261010-07 hazard), its marks
//     are left alone and the state goes back to NONE -- a FAILED for a session that is gone would describe nobody.
//
// The marker goes either way. Seals resume when the slot is released. The session is then signed in as before, minus
// the #keys stash, which its next `out` rewrites.
//
// NWP-20261014-66: it runs under goSafe, and a recover is not an undo. A panic before the give-back (a hook, a log
// write) would leave the session marked local, RESTART-STATUS PENDING and the marker on disk -- a session that never
// seals and whose LOGOUT answers BUSY until power-off, which is worse than the daemon crash it replaced (that at least
// ran recoverRestartMarker at the next start). So the give-back also runs from a defer when the body did not reach it.
func restartDidNotHappen(dest, name, uid string, h restartHooks) {
	defer func() { <-laneRW.slot }()
	settled := false
	defer func() {
		if !settled {
			fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: the restart watchdog failed before it settled -- "+
				"giving the session back (NWP-20261014-66)\n", uid)
			restartGiveBack(dest, name, uid)
		}
	}()
	h.wait()
	fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: still running after asking for the restart -- asking "+
		"once more (NWP-20261010-10)\n", uid)
	select {
	case <-h.rebootAsync(uid):
	case <-time.After(h.bound):
		fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: the second reboot request has not returned in %s -- "+
			"not waiting on it (NWP-20261010-10)\n", uid, h.bound)
	}
	h.wait()
	settled = true
	restartGiveBack(dest, name, uid)
}

// restartGiveBack is restartDidNotHappen's ending, after the second wait or from its panic defer: the marker goes, and
// the session -- only if it is still the one the restart was asked for -- is given back and RESTART-STATUS turns FAILED.
func restartGiveBack(dest, name, uid string) {
	removeRestartMarker(dest)
	if n2, _, u2 := readRoamSession(dest); n2 != name || u2 != uid {
		resetRestartState()
		fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: THE RESTART DID NOT HAPPEN, and the live session is no "+
			"longer the one it was asked for -- its marks are left alone (NWP-20261010-10)\n", uid)
		return
	}
	clearLocalSession(dest)
	endUnsavedKickMediad(dest)
	setRestartState("FAILED", name, uid)
	fmt.Fprintf(os.Stderr, "[logind] restart-unsaved user %s: THE RESTART DID NOT HAPPEN -- asked twice; the session is "+
		"given back, signed in and sealing (NWP-20261010-10)\n", uid)
}

// errMediaSweep is the logoff's verdict when roamd's sweepmedia did not verify (a media mount was left), so the
// seal never ran. SEAL-STATUS reports it as "FAILED MEDIA" (sealFailSuffix); a chooser older than that reads a
// plain FAILED, which is what it was.
const errMediaSweep = "ERR-MEDIA-SWEEP"

// logoffSweepFailed is logoffSealFailed for a logoff that never reached its seal: the SEAL-STATUS fields, so the
// logging-off screen un-sticks and names the media, and one more failed sweep for RESTART-UNSAVED's count. It does
// NOT call recordSeal, because no seal ran -- the last seal's verdict, the scope save times and any refused sign-out
// on record (its licence included) all still describe the session.
func logoffSweepFailed(name, uid string) {
	pendingReapMu.Lock()
	sealInFlight = false
	if sealRunKind == "logoff" { // NWP-20260901-26: compare-and-clear, see clearSealRunIf
		sealRunKind = ""
	}
	sealFail = true
	sealFailWhy = errMediaSweep
	pendingReapMu.Unlock()
	noteMediaSweepFailed(name, uid)
}

// dropLogoffBTMarker removes roamd's #154 logoff marker for a sign-out that did not happen (round 3). roamd
// honours it only on a logoff's own `out` now, so a stale one cannot wipe a live user's Bluetooth; this keeps the
// tmpfs from carrying one at all.
func dropLogoffBTMarker(dest string) { os.Remove(filepath.Join(dest, ".btlogoff")) }

// clearSealBlindPkgs drops the published blind-package list. Once per `out` (runWorkerHeld), at every session
// start (resetSealStatus) and when END-UNSAVED or RESTART-UNSAVED commits -- never per push, which let the #sys and
// #apps pushes wipe a data scope's list before the chooser asked for it (NWP-20261010-10).
func clearSealBlindPkgs() { os.Remove(sealBlindPkgPath()) }
