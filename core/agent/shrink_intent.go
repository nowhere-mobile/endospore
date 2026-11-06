package main

// Deliberate-shrink intent (DIA-20260804-03), the prerequisite for the storage-clearing screen.
//
// THE PROBLEM: pushProfile's shrink guard refuses a seal whose manifest has under 1/5 the chunks of the
// current head (main.go, "SHRINK GUARD"). That guard exists because a partial restore sealing over good
// data is silent loss -- proven on profile b, 2313 chunks -> 187, a 2.8 GB map destroyed. Its own comment
// already names the false positive: "a genuine large deletion trips it too".
//
// Clearing storage IS a genuine large deletion. It is the ONE action whose entire purpose is a drastic
// shrink. Without this file, a user told "you are over your plan, remove something" removes their largest
// app, logs off, and the seal is REFUSED: the old head survives, their footprint does not drop, and they
// are still over. Nothing in the UI would say so -- the refusal prints to the daemon log. That failure is
// worse than the guard it protects, because it lands on a user who is already blocked and has done exactly
// what we asked.
//
// THE FIX -- and why it is not "relax the guard": the guard cannot TELL a deliberate deletion from a broken
// capture by looking at the result, because they produce the identical shape (a short manifest). Rather
// than infer better, the deletion PATH declares itself: the user's clearing action records an intent, and
// the guard honours it for that scope. Nothing else in the system can set it, so a partial restore -- which
// declares nothing -- is refused exactly as before.
//
// SCOPE AND LIFETIME. Markers are keyed by the same per-scope ref the receipt gate uses (profileRefV2 of
// the scope-qualified name), so clearing app data does not open a hole in the media seal. They live in the
// RAM state tmpfs alongside restore receipts, which gives the right lifetime for free: a marker cannot
// outlive the session that set it, and an amnesiac boot starts with none. Off-device (NOWHERE_STATE unset,
// i.e. host CLI and unit tests) the whole mechanism is inert.
//
// The marker is cleared when a seal of that scope COMMITS, not when the guard reads it. Consuming it at the
// guard would lose the intent if the push then failed, and the retry -- the same deliberate deletion --
// would be refused with no way for the user to understand why.

import (
	"bufio"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// handleExpectShrink backs the EXPECT-SHRINK verb: the chooser calls it the moment the user confirms a
// storage-clearing action, BEFORE the data stops being captured. Purely local -- it writes marker files in
// the RAM state dir and touches no store, gateway or passphrase beyond deriving the scope refs.
//
// NOT in concurrentSafeCmd, unlike its read-only sibling GET-STORAGE-BREAKDOWN: that list is documented as
// pure reads only, and this WRITES state the seal path reads. It therefore waits behind an in-flight
// materialise. Acceptable: the caller is a single confirm tap that can retry, and getting this wrong in the
// other direction would race the seal.
func handleExpectShrink(conn net.Conn, dest string) {
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n") // nobody signed in
		return
	}
	if failed := markProfileShrinkIntent(name, pass); failed != nil {
		// Content-free: how many scopes, never a name or ref. ERR, not OK: the chooser changes the keep-set
		// only on OK, so a tap whose markers did not land says "Couldn't prepare that change" and the user
		// can retry -- the alternative is a seal the shrink guard then refuses.
		dlog("expect-shrink: %v", failed)
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprint(conn, "OK\n")
}

// handleExpectShrinkInferred backs the EXPECT-SHRINK-INFERRED verb (the arm's body, lifted from main.go): the
// payload line names the packages an inferred drop removed. "OK" | "NONE" | "ERR".
func handleExpectShrinkInferred(conn net.Conn, r *bufio.Reader, dest string) {
	pl, _ := r.ReadString('\n')
	pkgs := strings.Fields(strings.TrimRight(pl, "\r\n"))
	nm, ps, _ := readRoamSession(dest)
	if nm == "" || len(pkgs) == 0 {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	if err := markShrinkIntentInferred(profileRefV2(nm+"#apps", ps), pkgs); err != nil {
		dlog("expect-shrink-inferred: marker not written")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprint(conn, "OK\n")
}

// shrinkTarget is one marker a call means to write.
type shrinkTarget struct {
	path string
	body []byte
}

// THE LOCK. The seal is NOT in the login daemon: roamd runs every seal as its own `agent push` process
// (nowhere_roamd.sh), and the two share only the state directory on disk. So an in-memory mutex or counter protects
// nothing on a device. Every reader of a marker, every marker transaction, the recovery pass and the seal's
// commit-time clear take flock(2) on one lock file in the intent directory instead. The wait is bounded
// (shrinkLockWait) and a wait that expires FAILS CLOSED: a reader reports no authority, a transaction answers ERR,
// and a clear leaves the marker for the next seal (an armed marker outliving one seal costs a shrink the guard
// would otherwise have refused; consuming one mid-transaction would hand a rollback authority already spent).
const shrinkLockName = ".lock"

var shrinkLockWait = 5 * time.Second

// lockShrinkDir takes the intent directory's lock; create makes the directory first (a writer), otherwise a
// missing directory is an error (a reader has nothing to read). The returned func releases it.
var errShrinkBusy = fmt.Errorf("shrink-intent lock: held past the wait")

// shrinkLockWhy says, content-free, why the directory lock was not had: held by another process past the wait, or the
// directory itself (blocked, full, unreadable) refused it.
func shrinkLockWhy(err error) string {
	if err == errShrinkBusy {
		return "directory busy"
	}
	return "directory unavailable"
}

func lockShrinkDir(dir string, create bool) (func(), error) {
	if create {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, err
		}
	}
	f, err := os.OpenFile(filepath.Join(dir, shrinkLockName), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(shrinkLockWait)
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() { f.Close() }, nil // closing the descriptor releases the lock
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EINTR {
			f.Close()
			return nil, fmt.Errorf("shrink-intent lock: %v", err)
		}
		if time.Now().After(deadline) {
			f.Close()
			return nil, errShrinkBusy
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// genLine marks the per-write nonce a marker body ends with. Readers ignore it; the seal compares whole bodies, so a
// marker rewritten by a newer EXPECT is never the one an older seal authorized against, even when both say
// "deliberate". Bodies without it (written before this) are still read as they always were.
const genLine = "gen="

func withGen(body string) []byte {
	var n [8]byte
	if _, err := rand.Read(n[:]); err != nil {
		binary.LittleEndian.PutUint64(n[:], uint64(time.Now().UnixNano()))
	}
	return []byte(body + genLine + hex.EncodeToString(n[:]) + "\n")
}

var (
	shrinkWriteFile = os.WriteFile
	shrinkRename    = os.Rename
	shrinkRewrite   = os.WriteFile
	shrinkRemove    = os.Remove
	// shrinkPublish publishes a staged recovery record; shrinkDrop removes a recovery record. Separate from
	// shrinkRename / shrinkRemove, which act on the live markers.
	shrinkPublish = os.Rename
	shrinkDrop    = os.Remove
	// The directory reads recovery and the readers depend on, so a test can make them fail.
	shrinkReadDir = os.ReadDir
	shrinkLstat   = os.Lstat
)

// shrinkRestoreTries is how many times putting one marker back is attempted before it is counted lost.
const shrinkRestoreTries = 3

// shrinkStage writes body to a side file and renames it over path: the target is replaced whole or not at all. A
// write that fails after truncating (ENOSPC, EIO) damages only the side file, never the marker or its record.
func shrinkStage(path string, body []byte) error {
	side := path + ".new"
	if err := shrinkRewrite(side, body, 0o600); err != nil {
		os.Remove(side)
		return err
	}
	if err := shrinkRename(side, path); err != nil {
		os.Remove(side)
		return err
	}
	return nil
}

// restoreShrinkMarker puts one committed marker back to its snapshot: a remove when it was absent, else the
// staged previous body renamed into place, else the previous bytes staged and renamed. The whole step is retried,
// so a transient I/O error does not leave a half-changed marker. Reports whether the marker is back. ONLY the
// in-call rollback of commitShrinkMarkers uses this: it runs under the directory lock the seal's clear also takes,
// so the body it restores cannot have been spent meanwhile.
func restoreShrinkMarker(path string, existed bool, prev []byte) bool {
	for i := 0; i < shrinkRestoreTries; i++ {
		if !existed {
			if err := shrinkRemove(path); err == nil || os.IsNotExist(err) {
				return true
			}
			continue
		}
		if shrinkRename(path+shrinkOldSuffix, path) == nil || shrinkStage(path, prev) == nil {
			return true
		}
	}
	return false
}

// neutralizeShrinkMarker makes the live marker at f carry no authority: removed, else replaced (staged and renamed)
// by the consumed tombstone. Reports whether it did. Every place that changes a marker and its recovery record
// together calls this FIRST and drops the record only when it returned true, so a marker that could not be
// neutralised stays pending under the flag instead of being left armed with no record.
func neutralizeShrinkMarker(f string) bool {
	if err := shrinkRemove(f); err == nil || os.IsNotExist(err) {
		return true
	}
	return shrinkStage(f, []byte(consumedMarker)) == nil
}

// Recovery records and the transaction flag. While a transaction is open the intent directory holds a ".txn"
// flag file and every target has a recovery record next to its marker: <marker>.old holds the bytes it held
// before, <marker>.abs (empty) says it held none. The flag is the ONE commit point of the whole transaction:
// it is published before any marker changes and removed after every marker has, and while it exists every
// marker with a record is mid-transaction -- the readers (haveShrinkIntent, shrinkIntentProvenance) give
// it no authority, and recoverShrinkDir ends it. A single flag, not a record per marker, because
// records are retired one at a time: a per-marker indication would let an early-retired marker authorize while a
// later one failed and the call answered ERR. Records are meaningful only while the flag exists; without it they
// are garbage from a transaction that already committed and are swept.
const (
	shrinkOldSuffix = ".old"
	shrinkAbsSuffix = ".abs"
	shrinkTxnName   = ".txn"
)

// shrinkPending reports whether the marker at f is mid-transaction: the directory's flag exists AND the marker
// still has a recovery record. A marker without a record while the flag exists was never changed by the open
// transaction or was already put back to its snapshot, so it still means what it meant before; a changed marker
// always has its record, because records are dropped only after the marker is restored, neutralised, or after the
// flag is gone.
//
// Fails closed: a flag or record that cannot be looked at (anything but "does not exist") counts as there, so an
// unreadable directory never reads as a clean one.
func shrinkPending(f string) bool {
	if _, err := shrinkLstat(filepath.Join(filepath.Dir(f), shrinkTxnName)); err != nil {
		return !os.IsNotExist(err)
	}
	for _, suf := range []string{shrinkOldSuffix, shrinkAbsSuffix} {
		if _, err := shrinkLstat(f + suf); err == nil || !os.IsNotExist(err) {
			return true
		}
	}
	return false
}

// dropShrinkRecords removes both recovery records of a marker; reports whether none is left.
func dropShrinkRecords(f string) bool {
	ok := true
	for _, suf := range []string{shrinkOldSuffix, shrinkAbsSuffix} {
		if err := shrinkDrop(f + suf); err != nil && !os.IsNotExist(err) {
			ok = false
		}
	}
	return ok
}

// recoverShrinkMarker ends the unfinished transaction of one marker, and the rule is the same for every
// transaction but the one still running under the lock: a marker with a record ends ABSENT (or, if it cannot be
// removed, as the consumed tombstone), and the previous body is NEVER restored as authority. A record cannot
// say whether a seal spent its token between the failed call and now (the seal is a separate process, and it
// could be killed anywhere), so replaying it could hand a spent shrink back. The cost: a marker a failed
// transaction could not put back is lost, the user repeats the Stop-keeping tap, and the next seal of that scope is
// refused meanwhile (fail-safe).
//
// The marker is neutralised first and the records dropped only if that worked; a marker that could not be
// neutralised keeps them. Reports whether the marker is clear of its records. Only called while the flag exists; a
// record without the flag is garbage and is only dropped (recoverShrinkDir).
func recoverShrinkMarker(f string) bool {
	if !neutralizeShrinkMarker(f) {
		return false
	}
	return dropShrinkRecords(f)
}

// recoverShrinkDir ends an unfinished transaction in the intent directory: it removes staged .new files and, for
// every marker that has a record, applies recoverShrinkMarker's rule (the marker ends absent or as the tombstone,
// never as its previous body), and removes the flag once none is left. Without the flag the records are garbage of a
// committed transaction and are only removed.
// Returns how many markers (or, if only the flag refuses to go, one) still have an unfinished transaction. A
// directory that cannot be listed (EMFILE, ENOMEM, EIO) is one unfinished thing: nothing can be said about what it
// holds, so no caller may take it for clean.
func recoverShrinkDir(dir string) int {
	ents, err := shrinkReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		return 1
	}
	txn := false
	for _, e := range ents {
		if e.Name() == shrinkTxnName {
			txn = true
		}
	}
	left := 0
	for _, e := range ents {
		n := e.Name()
		switch {
		case strings.HasSuffix(n, ".new"):
			os.Remove(filepath.Join(dir, n))
		case strings.HasSuffix(n, shrinkOldSuffix), strings.HasSuffix(n, shrinkAbsSuffix):
			f := filepath.Join(dir, strings.TrimSuffix(strings.TrimSuffix(n, shrinkOldSuffix), shrinkAbsSuffix))
			// A record without the flag is garbage of a committed transaction, but one that cannot be dropped is
			// an unfinished cleanup: counted, so no later transaction (another profile's, another scope's) may
			// publish the flag and give that record a transaction to be replayed in.
			if !txn {
				if !dropShrinkRecords(f) {
					left++
				}
			} else if !recoverShrinkMarker(f) {
				left++
			}
		}
	}
	if txn && left == 0 {
		if err := shrinkDrop(filepath.Join(dir, shrinkTxnName)); err != nil && !os.IsNotExist(err) {
			left++
		}
	}
	return left
}

// recoverShrinkMarkers is the daemon-start pass over the intent directory (see recoverShrinkDir).
func recoverShrinkMarkers(dest string) int {
	dir := filepath.Join(dest, "shrink-intent")
	if _, err := os.Stat(dir); err != nil {
		return 0
	}
	unlock, err := lockShrinkDir(dir, false)
	if err != nil {
		return 1 // cannot take the lock: nothing was recovered, so say so
	}
	defer unlock()
	return recoverShrinkDir(dir)
}

// commitShrinkMarkers writes every target or none, and never truncates or rewrites a marker in place.
//
//  1. Snapshot: first end any unfinished transaction the directory is left in (recoverShrinkDir: the markers it
//     touched end absent, never restored -- a record of an earlier call would be overwritten by this one's), then read each
//     target. A directory that cannot be recovered, and anything but "absent" or a readable file, is an error
//     before a byte is written (a failed snapshot must not be mistaken for an absent marker, whose rollback is
//     a remove).
//  2. Stage: publish the transaction flag, then write each new body, and a recovery record per marker (its
//     previous body, or an empty .abs), to a side file next to it. Every byte of disk space the call needs is
//     spent here, while no marker has changed; ENOSPC lands here.
//  3. Commit: rename the new files over the markers. A rename allocates nothing, so a full tmpfs does not
//     fail it half way.
//  4. Failure in 3: put the previous bodies back by rename (or remove a marker that was absent), for the same
//     reason; a rename that still fails is answered with the previous bytes staged to a side file and renamed,
//     and the whole step is retried (restoreShrinkMarker). A forward rename cannot meet a marker path that is a
//     directory or unreadable: the snapshot in step 1 refuses those before anything is staged.
//  5. Retire: remove the flag. That is the one commit point; the records are garbage after it and dropped
//     without a verdict. If the flag cannot be removed the call rolls back and answers ERR.
//
// The error counts the failed targets and names none. The one case it cannot undo is a filesystem that
// refuses every retry of the restoring rename, the staged rewrite AND the remove: no code can undo a change
// the filesystem will not let it undo. What it can do is keep the call from granting authority. The flag and
// the recovery record of every marker not put back are KEPT, never deleted, and while the flag is there each of
// those markers authorizes nothing (shrinkPending). Recovery (the next call, the daemon-start pass) then ends them
// absent, per recoverShrinkMarker. The error counts those markers.
func commitShrinkMarkers(targets []shrinkTarget) error {
	if len(targets) == 0 {
		return nil
	}
	type staged struct {
		shrinkTarget
		existed bool
		prev    []byte
	}
	dir := filepath.Dir(targets[0].path)
	unlock, err := lockShrinkDir(dir, true)
	if err != nil {
		return fmt.Errorf("%d of %d shrink-intent markers not written (%s)", len(targets), len(targets), shrinkLockWhy(err))
	}
	defer unlock()
	txn := filepath.Join(dir, shrinkTxnName)
	st := make([]staged, len(targets))
	failed := 0
	// One flag per directory: a transaction left unfinished by ANY earlier call (this profile's, another's, the
	// logoff's inferred one) must be finished before this one may publish or remove the flag, or this call would
	// un-block markers an ERR-answered call changed. If recovery cannot finish it, this call writes nothing.
	if n := recoverShrinkDir(dir); n > 0 {
		return fmt.Errorf("%d of %d shrink-intent markers not written (%d earlier marker(s) still unrecovered)", len(targets), len(targets), n)
	}
	for i, t := range targets {
		st[i].shrinkTarget = t
		// A stale record of a committed transaction would be preferred by recovery over this call's own record
		// (.old over .abs) once the flag is published again: it must be gone before this call stages anything.
		if !dropShrinkRecords(t.path) {
			failed++
			continue
		}
		b, err := os.ReadFile(t.path)
		switch {
		case err == nil:
			st[i].existed, st[i].prev = true, b
		case !os.IsNotExist(err):
			failed++
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d of %d shrink-intent markers not written", failed, len(targets))
	}
	cleanup := func() {
		for _, s := range st {
			os.Remove(s.path + ".new")
			os.Remove(s.path + shrinkOldSuffix + ".new")
			os.Remove(s.path + shrinkAbsSuffix + ".new")
			dropShrinkRecords(s.path)
		}
		os.Remove(txn + ".new")
		shrinkDrop(txn) // a flag that stays is finished by recovery: nothing was committed, so it restores what is there
	}
	if shrinkWriteFile(txn+".new", nil, 0o600) != nil || shrinkPublish(txn+".new", txn) != nil {
		cleanup()
		return fmt.Errorf("%d of %d shrink-intent markers not written", len(targets), len(targets))
	}
	for i, t := range targets {
		rec, recBody := t.path+shrinkAbsSuffix, []byte(nil)
		if st[i].existed {
			rec, recBody = t.path+shrinkOldSuffix, st[i].prev
		}
		// The record is staged to a side file and published by rename: a crash or short write while it is
		// written leaves only a ".new" file (swept at daemon start), never a truncated live record that
		// recovery would write back over the marker.
		if shrinkWriteFile(rec+".new", recBody, 0o600) != nil || shrinkPublish(rec+".new", rec) != nil {
			failed++
			continue
		}
		if shrinkWriteFile(t.path+".new", t.body, 0o600) != nil {
			failed++
		}
	}
	if failed > 0 {
		cleanup()
		return fmt.Errorf("%d of %d shrink-intent markers not written", failed, len(targets))
	}
	// rollback puts every committed marker in st[:n] back. A marker that could not be put back keeps its record,
	// and then the flag stays too, so nothing in the directory authorizes until recovery finishes the job.
	rollback := func(n int) int {
		lost := 0
		keep := map[string]bool{}
		for _, d := range st[:n] {
			if !restoreShrinkMarker(d.path, d.existed, d.prev) {
				lost++
				keep[d.path] = true
			}
		}
		for _, d := range st {
			os.Remove(d.path + ".new")
			os.Remove(d.path + shrinkOldSuffix + ".new")
			os.Remove(d.path + shrinkAbsSuffix + ".new")
			if !keep[d.path] {
				dropShrinkRecords(d.path)
			}
		}
		if lost == 0 {
			shrinkDrop(txn) // best effort: a flag left over with no record is removed by the next recovery
		}
		return lost
	}
	for i, s := range st {
		if shrinkRename(s.path+".new", s.path) != nil {
			return fmt.Errorf("%d of %d shrink-intent markers not written (%d could not be put back)", len(st)-i, len(targets), rollback(i))
		}
	}
	if err := shrinkDrop(txn); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("%d of %d shrink-intent markers not written (%d could not be put back)", len(targets), len(targets), rollback(len(st)))
	}
	for _, s := range st {
		dropShrinkRecords(s.path) // garbage now: the flag is gone, so a record left here changes nothing
	}
	return nil
}

// shrinkIntentFile maps a store ref to its intent marker, or "" when the mechanism is disabled (no roaming
// state dir -> host CLI / tests -> the guard behaves exactly as it did before this file existed).
func shrinkIntentFile(ref string) string {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" || ref == "" {
		return ""
	}
	return filepath.Join(st, "shrink-intent", ref)
}

// markShrinkIntent records that the USER deliberately reduced what this scope will seal, so the next seal
// of it is expected to be much smaller. A marker that cannot be written is an ERROR the caller must
// surface: the user's tap is confirmed only on OK, so swallowing it would tell them the app was stopped while
// the next seal's guard refuses the drop. Inert (nil) off-device. A failed write restores the marker's previous
// bytes (or removes one that was absent); see commitShrinkMarkers for the one case that cannot be undone and how
// it is kept from granting authority.
func markShrinkIntent(ref string) error {
	f := shrinkIntentFile(ref)
	if f == "" {
		return nil
	}
	return commitShrinkMarkers([]shrinkTarget{{f, withGen("deliberate\n")}})
}

// shrinkIntent is one atomic reading of a scope's marker (readShrinkIntent). armed is false when there is no
// marker, when it is mid-transaction, or when it could not be read: no authority. token is the marker's whole body,
// the identity the seal's commit-time clear compares (clearShrinkIntentGen).
type shrinkIntent struct {
	armed    bool
	kind     string
	declared []string
	token    string
}

// readShrinkIntent reads the marker ONCE, under the directory lock, so a seal cannot see a marker exist and then
// find it changed or gone between two reads. Fails closed: a lock that cannot be had, a marker with an unfinished
// transaction (shrinkPending) and a marker that exists but cannot be read all report no authority.
func readShrinkIntent(ref string) shrinkIntent {
	f := shrinkIntentFile(ref)
	if f == "" {
		return shrinkIntent{}
	}
	unlock, err := lockShrinkDir(filepath.Dir(f), false)
	if err != nil {
		return shrinkIntent{}
	}
	defer unlock()
	if shrinkPending(f) {
		return shrinkIntent{} // an unfinished transaction: the marker is not trusted until it is recovered
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return shrinkIntent{}
	}
	// Authority only to a body whose first line is exactly "deliberate" or "inferred" and which ends in a newline.
	// An empty, truncated or unrecognised body (a write that died half way, the consumed tombstone) authorizes
	// nothing. This INVERTS the older "unrecognised reads as deliberate": the markers live on the RAM state tmpfs,
	// so no body written before the strict reader survives a reboot, and a body cut short must never read as whole-scope
	// user authority (it would upgrade a package-scoped inferred marker).
	if !strings.HasSuffix(string(b), "\n") {
		return shrinkIntent{}
	}
	in := shrinkIntent{armed: true, kind: "deliberate", token: string(b)}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	switch lines[0] {
	case "deliberate":
	case "inferred":
		in.kind = "inferred"
		for _, l := range lines[1:] {
			if !strings.HasPrefix(l, genLine) {
				in.declared = append(in.declared, l)
			}
		}
	default:
		return shrinkIntent{}
	}
	return in
}

// haveShrinkIntent reports whether the user asked for this scope to get smaller. A marker with an unfinished
// transaction (shrinkPending) reports false: a failed EXPECT-SHRINK that could not put it back must not leave
// it authorizing.
func haveShrinkIntent(ref string) bool { return readShrinkIntent(ref).armed }

// clearShrinkIntent re-arms the guard for a scope, called once its seal has committed. The shrink the user
// asked for is now the head, so any FURTHER drastic shrink in this session is once again the suspicious
// kind the guard is for.
func clearShrinkIntent(ref string) {
	clearShrinkIntentGen(ref, "", false)
}

// clearShrinkIntentGen is the seal's clear: with match set it consumes the marker only while its body is still the
// token the seal authorized against (shrinkIntent.token, read before the guard). A marker committed since was never
// part of the seal's walk and stays as it is: an armed one for the next seal, a pending one (a call that answered ERR
// left it under the flag) non-authorizing until recovery ends it. Under the directory lock, so it waits for a marker
// transaction in ANY process; a lock that cannot be had leaves the marker alone.
//
// The live marker is neutralised FIRST (removed, else replaced by the tombstone) and its records dropped only when
// that worked. A marker that can be neither removed nor tombstoned keeps its records, so while the flag exists it
// stays pending and authorizes nothing, whatever the seal was killed in the middle of.
func clearShrinkIntentGen(ref, token string, match bool) {
	f := shrinkIntentFile(ref)
	if f == "" {
		return
	}
	unlock, err := lockShrinkDir(filepath.Dir(f), false)
	if err != nil {
		return
	}
	defer unlock()
	if match {
		if b, err := os.ReadFile(f); err != nil || string(b) != token {
			return
		}
	}
	if neutralizeShrinkMarker(f) {
		dropShrinkRecords(f)
	}
}

// consumedMarker is the body a spent marker is replaced with when it cannot be removed (neutralizeShrinkMarker).
// readShrinkIntent gives it no authority (it is not "deliberate" or "inferred").
const consumedMarker = "consumed\n"

// markProfileShrinkIntent marks every scope a storage-clearing action can shrink, for the profile in the
// live session. All of them are marked rather than just the one the UI touched: dropping an app from the
// keep-set removes its CE data, its DE data AND its captured APK bytes (the base, #de and #apps scopes),
// and deleting photos hits #media. Marking only the obvious scope would let a seal of one of the others be
// refused, which is the failure this whole file exists to prevent.
//
// #keys is deliberately NOT marked: it is kilobytes of Keystore bundles, no clearing action targets it, and
// leaving its guard armed costs the user nothing.
//
// All or nothing (commitShrinkMarkers): if any scope fails, every scope's previous bytes are put back (or its marker
// removed when it held none), so a partial set cannot disarm the guard for the scopes that did land, nor overwrite an
// INFERRED #apps marker with user authority. If the filesystem refuses even the put-back, the affected markers keep
// their recovery records and authorize nothing until recovery finishes (commitShrinkMarkers). The error counts the
// failed scopes and names none.
func markProfileShrinkIntent(profile, pass string) error {
	if profile == "" {
		return nil
	}
	var targets []shrinkTarget
	for _, scope := range []string{profile, profile + "#de", profile + "#media", profile + "#apps"} {
		if f := shrinkIntentFile(profileRefV2(scope, pass)); f != "" {
			targets = append(targets, shrinkTarget{f, withGen("deliberate\n")})
		}
	}
	return commitShrinkMarkers(targets)
}

// ---- provenance (NWP-20260903-13) --------------------------------------------------------------------
//
// The marker content was written ("deliberate") but never read -- haveShrinkIntent is a pure stat --
// which made it a free, backward-compatible channel the day a second writer appeared. That day came:
// NWP-20260830-08 inferred play-stack orphan drops set the chooser clearedStorageThisSession flag, and
// the logoff re-declare then armed the SAME profile-wide user intent a deliberate clearing tap arms.
// Field cost (docs/backlog.md, the scope-head history row): in one logoff #sys REFUSED its destructive
// shrink while #apps sealed 3 pkgs -> 2 unchallenged, because the inferred drop had disarmed the guard
// exactly like a user choice. An inference must never carry a user authority: it gets its own verb, its
// own SCOPED marker (#apps only -- base/#de get walk-time sealDropped credit for drop-listed packages;
// #media is untouched by an app drop), and a verdict that vouches ONLY for the packages the drop named.

// markShrinkIntentInferred arms an INFERRED intent: content names the provenance and the packages the
// inference dropped, one per line. Lifetime, tmpfs residence and clear-on-commit are identical to the
// deliberate marker.
// A failed write returns the error and puts a previous marker (deliberate or inferred) back to the bytes it held;
// when the filesystem refuses even that, the marker keeps its recovery record and authorizes nothing until recovery
// finishes (commitShrinkMarkers).
func markShrinkIntentInferred(ref string, pkgs []string) error {
	f := shrinkIntentFile(ref)
	if f == "" || len(pkgs) == 0 {
		return nil
	}
	body := "inferred\n"
	for _, p := range pkgs {
		body += p + "\n"
	}
	return commitShrinkMarkers([]shrinkTarget{{f, withGen(body)}})
}

// shrinkIntentProvenance reads the marker kind and, for an inferred one, the declared packages. A marker that is
// mid-transaction, cannot be read, or holds a body readShrinkIntent does not recognise reports "inferred" with no packages, which
// shrinkIntentAllowed refuses on every shrink: never a user authority it was not shown to carry.
func shrinkIntentProvenance(ref string) (string, []string) {
	if shrinkIntentFile(ref) == "" {
		return "deliberate", nil
	}
	in := readShrinkIntent(ref)
	if !in.armed {
		return "inferred", nil
	}
	return in.kind, in.declared
}

// shrinkIntentAllowed is the guard verdict on an armed marker, PURE so the truth table is testable. A
// deliberate marker carries the user authority and allows the shrink outright (unchanged semantics). An
// inferred marker vouches ONLY for the packages the inference named: the shrink is allowed iff the
// packages that vanished from the manifest Pkg index (and are not merely deferred now -- a deferred rel
// first path segment is its package) are a subset of the declared set, and there was a measured index to
// compare against. No index means no verification, and unverifiable is refused. The []string return
// names the unexplained packages, for the refusal message.
func shrinkIntentAllowed(kind string, declared []string, oldPkg, newPkg map[string]int64, newDeferredRels []string) (bool, []string) {
	if kind != "inferred" {
		return true, nil
	}
	if len(oldPkg) == 0 {
		return false, nil // no Pkg index on the old head -> "not measured", nothing to verify against
	}
	present := pkgPresenceSet(newPkg, newDeferredRels)
	ok := map[string]bool{}
	for _, d := range declared {
		ok[d] = true
	}
	var unexplained []string
	missingAny := false
	for k := range oldPkg {
		if present[k] {
			continue
		}
		missingAny = true
		if !ok[k] {
			unexplained = append(unexplained, k)
		}
	}
	// No package vanished at all: the shrink came from somewhere the inference cannot speak for.
	if !missingAny {
		return false, nil
	}
	sort.Strings(unexplained)
	return len(unexplained) == 0, unexplained
}

// pkgPresenceSet is the set of packages a manifest still accounts for: the Pkg index keys (the essential
// region's per-package byte attribution) plus the first path segment of every deferred rel, since a package
// that moved wholly to the deferred tier is present, not gone.
//
// Lifted out of shrinkIntentAllowed by NWP-20260906-15 so the #apps presence guard asks the SAME question the
// shrink-intent verdict asks. Two copies of "which packages does this manifest still carry" that could answer
// differently is how a guard comes to refuse exactly what its neighbour allows.
//
// ⚠ An EMPTY Pkg index means "not measured", never "no packages" -- a pre-DIA-20260805-11 head carries none
// (chunkManifest.Pkg is omitempty). Callers must check len() before reading anything into a result here.
func pkgPresenceSet(pkg map[string]int64, deferredRels []string) map[string]bool {
	present := make(map[string]bool, len(pkg)+len(deferredRels))
	for k := range pkg {
		present[k] = true
	}
	for _, rel := range deferredRels {
		if i := strings.IndexByte(rel, '/'); i > 0 {
			present[rel[:i]] = true
		} else if rel != "" {
			present[rel] = true
		}
	}
	return present
}

// shrinkShortfallTop bounds the package list a shrink refusal prints: enough to name the culprit, which is
// almost always the first one or two, without turning one refusal into a package inventory.
const shrinkShortfallTop = 8

// shrinkShortfall names, for a shrink-guard REFUSAL, the packages the stored head carries that this walk carries
// LESS of, largest shortfall first, with the stored and walked sealed bytes of each (NWP-20261010-06). It returns
// a header and one entry per listed package; shrinkShortfallLog turns them into log lines.
//
// ⚠ THE GUARD ALREADY HELD THIS AND THREW IT AWAY. On NW-cebeb51558fd and again on NW-db441ee766cb (stallion,
// 2026-10-10) every #de seal was refused with "NONE >=1048576B" and no package named, while the stored head's Pkg
// index -- which names every package and its bytes -- sat in memory at the moment of the refusal.
//
// ⚠ ONE ENTRY PER LINE, NOT ONE LIST ON THE REFUSAL LINE. The issue reporter drops any line holding a drop keyword
// whole (issueDropKeywords), and package names are not ours to choose: a password manager in the list
// (com.nordpass.android.app.password.manager) would have deleted the REFUSAL ITSELF from the ticket. Split, a bad
// name costs its own entry and nothing else, and the [i/n] numbering makes even that loss visible as a gap -- as
// it does a block the report's 300-line tail or its size trim cut short.
//
// TAGS, and the one presence rule. "present" is pkgPresenceSet's -- the rule the shrink-intent verdict and the
// #apps presence guard use -- so a package this list calls "deferred now" can never be one an adjacent
// "unexplained: [...]" line names as vanished (inferred intents arm #apps only, main.go markShrinkIntentInferred,
// where both rules see "<pkg>/<file>" identically). Deferred BYTES are attributed with attrPkgForRel, the rule the
// Pkg index itself is built by, and compared head vs walk: deferredMap also carries forward old entries the walk
// never saw, so mere presence of a deferred rel says nothing about where the missing essential bytes went.
//   - "(deferred now)" / "(partly deferred)": present, and the package's deferred bytes GREW by at least its
//     shortfall. Raw against sealed, the guard's own one-directional bias (main.go, sealDropped).
//   - "(gone)": no essential bytes and no deferred growth that covers it; "; NB still deferred" adds what the
//     walk still carries for it in the deferred tier, which is not where the shortfall went.
//
// Bytes carry a "B" suffix: the issue reporter rewrites a bare run of 7+ digits to <num> (reIssueDigits).
//
// ⚠ AN EMPTY INDEX IS "NOT MEASURED", NEVER "NOTHING MISSING", and it is said out loud. measured is false for a
// NOWHERE_SEAL_FULL walk, whose whole-tree tar attributes nothing. withholdNames is set for #media, whose index
// can hold a user's own top-level folder (attrPkgForRel takes any dotted first component at the scope root, so
// "Therapy.Notes" indexes as a package): there the list says how many and how much, never which.
func shrinkShortfall(oldPkg, newPkg map[string]int64, oldDef, newDef map[string]deferredFile, measured, withholdNames bool) (string, []string) {
	if !measured {
		return "per-package shortfall NOT MEASURED -- this seal ran NOWHERE_SEAL_FULL=1, whose whole-tree tar attributes no bytes to any package", nil
	}
	if len(oldPkg) == 0 {
		return "per-package shortfall UNKNOWN -- the stored head carries no Pkg index: it was written before DIA-20260805-11 or by a NOWHERE_SEAL_FULL seal, or its scope holds no package-attributed bytes at all (a #media tree of only DCIM/Download is one). Nothing here can say which packages went; this does NOT mean none did", nil
	}
	defBytes := func(m map[string]deferredFile) map[string]int64 {
		out := map[string]int64{}
		for rel, d := range m {
			if p := attrPkgForRel(rel); p != "" {
				out[p] += d.Size
			}
		}
		return out
	}
	was, now := defBytes(oldDef), defBytes(newDef)
	rels := make([]string, 0, len(newDef))
	for rel := range newDef {
		rels = append(rels, rel)
	}
	present := pkgPresenceSet(newPkg, rels)
	type short struct {
		pkg      string
		had, has int64
	}
	var s []short
	for p, had := range oldPkg {
		if has := newPkg[p]; has < had {
			s = append(s, short{p, had, has})
		}
	}
	if len(s) == 0 {
		return fmt.Sprintf("no package is short -- all %d package(s) the stored head indexes hold at least their stored bytes, so the loss lies outside the per-package index", len(oldPkg)), nil
	}
	sort.Slice(s, func(i, j int) bool {
		if di, dj := s[i].had-s[i].has, s[j].had-s[j].has; di != dj {
			return di > dj
		}
		return s[i].pkg < s[j].pkg // deterministic, so a log and a test read the same
	})
	if withholdNames {
		return fmt.Sprintf("%d of the stored head's %d indexed name(s) are short in this walk, the largest by %dB; names WITHHELD on #media, where a top-level folder with a dot in its name indexes as a package and may be the user's own",
			len(s), len(oldPkg), s[0].had-s[0].has), nil
	}
	n := len(s)
	if n > shrinkShortfallTop {
		n = shrinkShortfallTop
	}
	entries := make([]string, 0, n)
	for _, x := range s[:n] {
		tag := ""
		growth := now[x.pkg] - was[x.pkg]
		switch {
		case present[x.pkg] && growth > 0 && growth >= x.had-x.has && x.has == 0:
			tag = " (deferred now)"
		case present[x.pkg] && growth > 0 && growth >= x.had-x.has:
			tag = " (partly deferred)"
		case x.has == 0 && now[x.pkg] > 0:
			tag = fmt.Sprintf(" (gone; %dB still deferred)", now[x.pkg])
		case x.has == 0:
			tag = " (gone)"
		}
		entries = append(entries, fmt.Sprintf("%s %dB->%dB%s", x.pkg, x.had, x.has, tag))
	}
	head := fmt.Sprintf("%d of the stored head's %d package(s) are short in this walk (sealed bytes head->walk); the largest %d follow one per line as [i/%d]",
		len(s), len(oldPkg), n, n)
	if more := len(s) - n; more > 0 {
		head += fmt.Sprintf(", +%d more not listed", more)
	}
	return head + "; a missing [i/n] did not reach this copy (the issue reporter's scrub drops a line, and its 300-line tail and size trim can cut a block)", entries
}

// shrinkRefusalNumbers is what every shrink refusal line carries itself: the comparison that brought control to
// the refusal (sealDropped + defMigrated against lost). Keyword-free by construction -- numbers and fixed words --
// so the issue scrub can never drop the refusal line for its sake. When the sealed bytes did not shrink at all the
// collapse is in chunk count only, and "vs -NB lost" would read as nonsense, so it says that instead.
func shrinkRefusalNumbers(sealDropped, defMigrated, lost, oldBytes, newBytes int64) string {
	if lost <= 0 {
		return fmt.Sprintf("the sealed bytes did not shrink (head %dB, walk %dB), so this is a chunk-count collapse only; dropped %dB + deferred-migrated %dB; per-package shortfall on the next line(s)",
			oldBytes, newBytes, sealDropped, defMigrated)
	}
	return fmt.Sprintf("dropped %dB + deferred-migrated %dB vs %dB lost, so neither accounts for it; per-package shortfall on the next line(s)",
		sealDropped, defMigrated, lost)
}

// deferredGrowth is the bytes that moved from the essential tier into the deferred one (#134): the deferred
// tier's raw size now minus what the stored head carried, clamped at 0. Only GROWTH counts -- a walk that also
// lost deferred entries gets no credit for them, and a negative must never offset sealDropped in the sum.
func deferredGrowth(oldDef, newDef map[string]deferredFile) int64 {
	var o, n int64
	for _, d := range oldDef {
		o += d.Size
	}
	for _, d := range newDef {
		n += d.Size
	}
	if g := n - o; g > 0 {
		return g
	}
	return 0
}

// shrinkWalkExplains is the ALLOWED arm of the pushProfile shrink guard: the walk itself accounts for the head
// shrinking when what it dropped (switched-off apps) plus what migrated to the deferred tier is positive and
// covers the bytes lost. The > 0 keeps a zero credit from allowing a chunk-count collapse where lost <= 0.
func shrinkWalkExplains(sealDropped, defMigrated, lost int64) bool {
	s := sealDropped + defMigrated
	return s > 0 && s >= lost
}

// shrinkShortfallLog renders shrinkShortfall's result as the log lines pushProfile prints after a refusal: one
// header line, then one line per entry, each carrying the profile tag so the lines pair with their refusal after
// the scrub. Kept separate from the printing so a test can push the exact lines through the issue scrub.
func shrinkShortfallLog(prof, head string, entries []string) []string {
	out := []string{fmt.Sprintf("push: profile %s shrink shortfall: %s", prof, head)}
	for i, e := range entries {
		out = append(out, fmt.Sprintf("push: profile %s shrink shortfall [%d/%d]: %s", prof, i+1, len(entries), e))
	}
	return out
}
