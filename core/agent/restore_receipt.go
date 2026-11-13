package main

// Restore-completion receipts (#72, the data-loss keystone).
//
// The threat: roam-in restores a profile in THREE phases -- CE/apps (the login gate), then DE and media as
// best-effort completeness (nowhere_roamd.sh `in`). Only the CE phase gates the login; a DE or media restore
// that FAILS or half-completes still logs in "OK". A later seal (periodic sync or logoff `out`) then pushes
// that phase's partial working set OVER the good store head -- silent data loss. This was PROVEN on profile b:
// a 46%-complete media restore's seal took a 2.8 GB map from 2313 chunks -> 187, destroying it. The per-ref
// shrink-count guard in pushProfile is only a NET (it catches a DRASTIC shrink; a 60%-complete restore sails
// through, and a genuine large deletion trips it falsely).
//
// The precise fix: a per-ref RECEIPT that certifies "THIS session holds a byte-complete copy of ref R" --
// written only when a restore of R fully completes (cdcRestore returns with no chunk error) OR a seal of R
// commits successfully. pushProfile then refuses to overwrite a NON-EMPTY existing head for a ref unless a
// receipt for that ref is present. So a phase whose restore failed writes NO receipt -> its seal is refused
// -> the good head survives, PER PHASE (a failed media restore blocks only the media seal, not CE/DE).
//
// Receipts live in the RAM state tmpfs (NOWHERE_STATE), so they are per-BOOT: a fresh (amnesiac) boot starts
// with none, and roam-in clears them at the start of each login (nowhere_roamd.sh) so a receipt reflects only
// what the CURRENT session actually restored. Off-device (host CLI / unit tests) NOWHERE_STATE is unset, so
// receiptDir() == "" and the whole gate is INERT -- existing create/push/restore behavior is unchanged.
//
// The check is EXISTENCE, not head-equality: a session advances its own head on every seal, so tying the
// receipt to a specific head hash would refuse the 2nd..Nth seal (and forces awkward per-seal / capFlush
// advancement). Existence is exactly the invariant we need: "this session fully holds ref R." The stored
// content is the head hash at receipt time; restoreReceiptHead reads it for the stale-base guard and the
// stranded-push verdict (see there), so it is no longer kept for diagnostics only.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// restoreReceiptDir is where per-ref completion receipts live, or "" when receipts are not in use (no roaming
// state dir -> host CLI / tests -> the seal gate is disabled and behavior is unchanged).
func restoreReceiptDir() string {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return ""
	}
	return filepath.Join(st, "restore-receipts")
}

// receiptFile maps a store ref (a hex sha256, already filename-safe) to its receipt path, or "" when disabled.
func receiptFile(ref string) string {
	d := restoreReceiptDir()
	if d == "" || ref == "" {
		return ""
	}
	return filepath.Join(d, ref)
}

// loginRosterFile maps a store ref to the LOGIN ROSTER: the head this session was GIVEN at login.
//
// ⚠ WHY THIS IS NOT THE RESTORE RECEIPT, WHICH IS WHAT IT USED TO BE. The receipt answers "do I hold a
// byte-complete copy of the current head", and every successful seal advances it (reanchorReceipt) --
// correctly, because the stale-base guard needs to know the head THIS handset last published.
//
// The #media carry asks a different question: "which rels did I ever RECEIVE?" -- the roster that separates
// another lineage’s file from one the user deleted. Reading that off the receipt was wrong in a way that
// only shows up on the SECOND cycle: a carried rel is in the head this handset just published, so the
// advanced receipt then claims the handset held it, the rel is absent locally, and the deletion arm fires.
// Measured: carry 1 -> present, next seal -> "1 deleted-here" -> gone. On two live handsets it was masked,
// because the handset that OWNS the file re-adds it every cycle; the loss only appears once that one signs
// out. Written to a distinct file so the two questions can never be confused again.
func loginRosterFile(ref string) string {
	d := restoreReceiptDir()
	if d == "" || ref == "" {
		return ""
	}
	return filepath.Join(d, "roster."+ref)
}

// writeLoginRoster records the head this session was given at LOGIN. Called only from the restore path,
// never from a seal -- that is the whole point. Published by temp + rename (publishReceiptFile), and the walked
// roster is removed only after the new roster landed: a failed write leaves the old roster and its walked
// roster together, the pair the carry was built on.
func writeLoginRoster(ref, head string) {
	f := loginRosterFile(ref)
	// ONE CONDITION. A `head == ""` arm was here and no mutation could convict it: loginRosterHead
	// TrimSpace-reads the file, so an empty roster and an absent one are already the same answer, and the
	// carry gates on that answer being "". A condition nothing can convict is one a reader trusts for the
	// wrong reason -- the same call made about the receipt check in NWP-20260908-04.
	if f == "" {
		return
	}
	if publishReceiptFile(f, []byte(head)) != nil {
		fmt.Fprintln(os.Stderr, "restore receipt not updated -- the previous one stands (#72)")
		return
	}
	// A new login roster always starts an empty walked roster: what the previous session walked is not
	// what this one was given.
	if w := walkedRosterFile(ref); w != "" {
		_ = os.Remove(w)
	}
}

// loginRosterNone is the roster a sign-in records when it PROVED the #media scope had no head: "no head", as
// opposed to a roster that is missing (no sign-in note, a pre-flag session) which the carry cannot read as
// anything. It can never be a head, which is hex.
const loginRosterNone = "none"

// writeLoginRosterNone records the "no head at sign-in" roster for ref. Through writeLoginRoster, so the walked
// roster is reset exactly as at any sign-in.
func writeLoginRosterNone(ref string) { writeLoginRoster(ref, loginRosterNone) }

// proveNoMediaHead is nil only when a STRICT read of the head ladder proves there is no head: a failed read (a
// transport error, a 5xx, a 403) panics out of the probe and is returned as an error, never taken for absence.
// resolveKeyHeadForLogin's !ok is not proof of this: it also covers a head no keyslot opens.
func proveNoMediaHead(base, profile, pass string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = panicAsErr(r)
		}
	}()
	if _, head, _ := headRefWith(base, profile, pass, refProbeStrict); head != "" {
		return errors.New("the #media scope has a head")
	}
	return nil
}

// noteNoMediaHeadAtLogin is the whole sign-in behaviour for a #media scope that restored nothing: when (and only
// when) the scope is #media and the head is PROVEN absent, record the empty login roster so the session's seals
// run the essential carry against an empty restored set (the walked roster still separates this handset's own
// deletions from another handset's new files). It writes no restore receipt: the #72 gate defers to the carry for
// such a session (noHeadCarryMayExcuse).
func noteNoMediaHeadAtLogin(base, profile, pass string) bool {
	if !isSharedMediaScope(profile) || proveNoMediaHead(base, profile, pass) != nil {
		return false
	}
	writeLoginRosterNone(profileRefV2(profile, pass))
	fmt.Printf("restore: profile %s has no #media head -> empty login roster recorded (NWP-20261026-08)\n", logProfile(profile))
	return true
}

// noHeadCarryMayExcuse reports whether the #72 gate may wait for the carry: only a #media session whose sign-in PROVED
// there was no head, with the carry on. A real roster without a receipt (a failed or partial restore) never qualifies:
// that is exactly the session #72 exists to refuse.
func noHeadCarryMayExcuse(profile, ref string) bool {
	return mediaEssentialCarryOn(profile) && loginRosterHead(ref) == loginRosterNone
}

// walkedRosterFile maps a store ref to the WALKED ROSTER: the #media rels THIS session itself walked and
// published in a committed seal. It sits in the restore-receipts directory, so it has the receipts' lifetime
// (RAM state, parked away by roamd at every sign-in, gone at power-off), and is "" when receipts are off.
func walkedRosterFile(ref string) string {
	d := restoreReceiptDir()
	if d == "" || ref == "" {
		return ""
	}
	return filepath.Join(d, "walked."+ref)
}

// walkedDigest is the line a rel is recorded as: a keyed digest, never the name. The state tmpfs outlives a
// reboot-free sign-out, and a list of file names there would be the roster shape #39 forbids.
func walkedDigest(dk []byte, rel string) string {
	m := hmac.New(sha256.New, dk)
	m.Write([]byte("nowhere-walked-roster\x00" + rel))
	return hex.EncodeToString(m.Sum(nil))
}

func readWalkedDigests(f string) map[string]bool {
	set := map[string]bool{}
	if f == "" {
		return set
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return set
	}
	for _, ln := range strings.Split(string(b), "\n") {
		if ln = strings.TrimSpace(ln); ln != "" {
			set[ln] = true
		}
	}
	return set
}

// loadWalkedRoster returns a predicate over the walked roster. An absent or unreadable file answers false
// for every rel -- nothing walked, the conservative answer for a deletion: the rel then falls to the login
// roster or is carried, as before the walked roster existed.
func loadWalkedRoster(ref string, dk []byte) func(rel string) bool {
	set := readWalkedDigests(walkedRosterFile(ref))
	return func(rel string) bool { return set[walkedDigest(dk, rel)] }
}

// recordWalkedRoster UNIONS the digests of rels into the walked roster (read, add, temp file + rename in the
// same directory). Best-effort: a roster we fail to write just leaves the old behaviour. No-op off-device.
func recordWalkedRoster(ref string, dk []byte, rels []string) {
	f := walkedRosterFile(ref)
	if f == "" || len(rels) == 0 {
		return
	}
	set := readWalkedDigests(f)
	for _, rel := range rels {
		set[walkedDigest(dk, rel)] = true
	}
	lines := make([]string, 0, len(set))
	for d := range set {
		lines = append(lines, d)
	}
	sort.Strings(lines)
	if os.MkdirAll(filepath.Dir(f), 0o700) != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(f), ".walked-")
	if err != nil {
		return
	}
	_, werr := tmp.WriteString(strings.Join(lines, "\n") + "\n")
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Chmod(tmp.Name(), 0o600) != nil || os.Rename(tmp.Name(), f) != nil {
		os.Remove(tmp.Name())
	}
}

// loginRosterHead returns the head this session was given at login, or "" when there is none -- which the
// carry treats as "no roster, carry nothing", the conservative direction.
func loginRosterHead(ref string) string {
	f := loginRosterFile(ref)
	if f == "" {
		return ""
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// publishReceiptFile writes b to f by temp + rename in f's directory, so f is always either the previous
// content or the new one: a reader's open fd keeps the old inode, and a failed write (a full state tmpfs)
// never leaves a truncated file behind. On any failure the temp is removed and f is left exactly as it was.
// The fixed ".tmp" name is safe: every reader opens a receipt by its exact name, nothing lists the
// directory, and roamd moves or removes the whole restore-receipts directory.
func publishReceiptFile(f string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(f), 0o700); err != nil {
		return err
	}
	tmp := f + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, f); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// writeRestoreReceipt records that THIS session holds a byte-complete copy of ref -- via a full restore at
// login, or a successful seal (reanchorReceipt). The existence gate checks only that the file is there, but
// head is NOT diagnostics only: restoreReceiptHead reads it for pushProfile's stale-base guard and for the
// stranded-push verdict. So it is published by temp + rename, never rewritten in place: an in-place write that
// failed on a full state tmpfs left an EMPTY receipt, which passed the gate while the guard read "" and was
// skipped. A failed write now leaves the previous receipt exactly as it was, and the existence gate and both
// readers keep reading it; a first write that never lands still means a later seal is refused (the safe
// direction). No-op off-device.
func writeRestoreReceipt(ref, head string) {
	f := receiptFile(ref)
	if f == "" {
		return
	}
	if publishReceiptFile(f, []byte(head+"\n")) != nil {
		fmt.Fprintln(os.Stderr, "restore receipt not updated -- the previous one stands (#72)")
	}
}

// restoreReceiptHead returns the head this session last KNEW for ref -- the head it restored at login,
// or the head it last published itself. Empty when there is no receipt, when receipts are off, or when
// the receipt predates this field.
//
// THE COMPARISON THE FILE HEADER ABOVE DECLINED TO MAKE, and the reason it is now makeable. That
// header says head-equality "would refuse the 2nd..Nth seal (and forces awkward per-seal / capFlush
// advancement)". The first half is only true if the receipt is NOT advanced -- and it already is:
// writeRestoreReceipt is called with the NEW head on every successful seal, so a session's own
// second seal finds the receipt equal to the head it just wrote. The "awkward advancement" the
// header feared is the real cost, and it is paid in putHead rather than at fifteen call sites.
func restoreReceiptHead(ref string) string {
	f := receiptFile(ref)
	if f == "" {
		return ""
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// seqGuardEnabled gates the sequential-overwrite REFUSAL. Detection is always computed and always
// logged; only the refusal is gated, and it is OFF by default.
//
// ⚠ THE DEFAULT IS OFF BECAUSE THE RESOLUTION IS A PRODUCT DECISION, NOT A TECHNICAL ONE. When the
// losing handset's tree has genuinely diverged there is no correct automatic answer: it either loses
// its own unsealed session or it overwrites the other handset's work. Today it silently does the
// second -- TWO losses, and the wrong one survives. Refusing makes it ONE loss, borne by the handset
// that diverged, which is almost certainly right; but "almost certainly" is not a basis for changing
// when a customer loses a session, and docs/product-decisions.md records that multi-device has never
// been decided. So: measure first, on a real pair of handsets, with the log line below.
func seqGuardEnabled() bool { return os.Getenv("NOWHERE_SEQ_GUARD") == "1" }

// haveRestoreReceipt reports whether THIS session has a completion receipt for ref.
func haveRestoreReceipt(ref string) bool {
	f := receiptFile(ref)
	if f == "" {
		return false
	}
	_, err := os.Stat(f)
	return err == nil
}
