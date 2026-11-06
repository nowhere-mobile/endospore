package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// NWP-20261116-02 (h46 #10, decided 2026-10-28, option A): the cold-lock teardown STAGES its resume marker as
// .coldlock.tmp above THE WAIT and renames it to .coldlock at the point of no return. A marker that cannot be staged
// or committed hands the session to Q066's sign-out (a throwaway is kept), with the 2FA rekey unwound first. When that
// unwind fails, #7 (2026-11-02; NWP-20261125-07) answers h46 #10's sub-question: one more try at writing the marker in
// place, then the lock commits; if that write fails too, the session is signed out without the keep arm. Backlog row:
// "`coldLockTeardown` writes the `.coldlock` marker in place at the point of no return and drops its error, so a
// marker that cannot be written leaves a stopped session nothing can resume".
//
// Where these tests read the shared state: coldLockNext clears coldLockRevoking when the teardown goroutine ends, so
// a test reads it right after a DIRECT teardown call returns, or inside the worker during the unwind -- never after
// rearmIdle. The teardown's defer clears this lock's sign-out bar on every path, so the bar is read only during the
// unwind.

// cstSignOut replaces coldLockSignOut with a recorder that a test can wait on.
type cstSignOut struct {
	mu    sync.Mutex
	dests []string
	ch    chan struct{}
}

func (c *cstSignOut) calls() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.dests...)
}

// cstSetup is clwSetup with the test's own profile name, the hooks this file replaces saved and restored, and a
// recorder for the sign-out.
func cstSetup(t *testing.T, profile string) (string, *clwRecorder, *clwHold, *cstSignOut) {
	t.Helper()
	dest, rec, hold := clwSetup(t)
	rearmClear(t)
	if err := markRoamSession(dest, profile, "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	prevStage, prevCommit, prevBefore, prevSignOut := coldLockStageMarker, coldLockCommitMarker, coldLockBeforeCommit, coldLockSignOut
	so := &cstSignOut{ch: make(chan struct{}, 4)}
	coldLockSignOut = func(d string) {
		so.mu.Lock()
		so.dests = append(so.dests, d)
		so.mu.Unlock()
		so.ch <- struct{}{}
	}
	resetBar := func() {
		coldLockMu.Lock()
		coldLockSignOutBar = ""
		coldLockMu.Unlock()
	}
	resetBar()
	t.Cleanup(func() {
		coldLockStageMarker, coldLockCommitMarker, coldLockBeforeCommit, coldLockSignOut = prevStage, prevCommit, prevBefore, prevSignOut
		resetBar()
	})
	return dest, rec, hold, so
}

// cstSignedOut waits (a hang guard of seconds, not a bound on elapsed time) for the one sign-out of dest.
func cstSignedOut(t *testing.T, so *cstSignOut, dest string) {
	t.Helper()
	select {
	case <-so.ch:
	case <-time.After(10 * time.Second):
		t.Fatal("coldLockSignOut never ran: the marker failure was not handed off to a sign-out")
	}
	if got := so.calls(); len(got) != 1 || got[0] != dest {
		t.Fatalf("coldLockSignOut calls = %q, want exactly one for %q", got, dest)
	}
}

// cstNoSignOut is called only after the teardown has returned or ended. The settle covers a goroutine start only.
func cstNoSignOut(t *testing.T, so *cstSignOut) {
	t.Helper()
	time.Sleep(200 * time.Millisecond)
	if got := so.calls(); len(got) != 0 {
		t.Fatalf("coldLockSignOut ran %d time(s), want none", len(got))
	}
}

// cstDirect calls the teardown directly, as Check A's rearm test does, and returns its answer. A call that parks
// for the RW slot (the hand-off is not above THE WAIT) fails the test. The cleanup, registered after clwSetup's, runs
// before it: it frees the slot and collects the call while the recorder still stands in for the worker.
func cstDirect(t *testing.T, hold *clwHold, dest, profile string) bool {
	t.Helper()
	done := make(chan bool, 1)
	go func() { done <- coldLockTeardown(dest, profile, "pw", "10", nil) }()
	t.Cleanup(func() {
		hold.give()
		select {
		case v := <-done:
			done <- v
		case <-time.After(10 * time.Second):
			t.Error("a direct coldLockTeardown call outlived the test")
		}
	})
	select {
	case survived := <-done:
		done <- survived // the cleanup reads it again
		return survived
	case <-time.After(10 * time.Second):
		t.Fatal("coldLockTeardown did not return -- it parked for the RW slot, so the hand-off is not above THE WAIT")
	}
	return false
}

func cstRevoking() bool {
	coldLockMu.Lock()
	defer coldLockMu.Unlock()
	return coldLockRevoking
}

// cstAtUnwind is the shared state as the second rekey (the 2FA unwind) saw it.
type cstAtUnwind struct {
	mu       sync.Mutex
	seen     bool
	revoking bool
	bar      string
}

func (a *cstAtUnwind) get() (bool, bool, string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.seen, a.revoking, a.bar
}

// cstUnwindAnswers makes the forward rekey answer OK and the unwind answer reply ("" = OK), capturing the state.
func cstUnwindAnswers(rec *clwRecorder, reply string) *cstAtUnwind {
	at := &cstAtUnwind{}
	rec.ret = func(op string, nth int) string {
		if op == "rekey" && nth == 2 {
			coldLockMu.Lock()
			revoking, bar := coldLockRevoking, coldLockSignOutBar
			coldLockMu.Unlock()
			at.mu.Lock()
			at.seen, at.revoking, at.bar = true, revoking, bar
			at.mu.Unlock()
			return reply
		}
		return ""
	}
	return at
}

// cstTornStage writes half the marker and fails as a full tmpfs does, so an ignored error is visible.
func cstTornStage(path string, b []byte) error {
	if err := os.WriteFile(path, b[:len(b)/2], 0o600); err != nil {
		return err
	}
	return fmt.Errorf("stage: %w", syscall.ENOSPC)
}

// cstMarker is the seven-line marker main writes at the point of no return.
func cstMarker(profile, pass, uid string, h []byte, needKey, pinFlag, slotSpec string) string {
	passWrap := base64.StdEncoding.EncodeToString(seal(coldWrapKey(profile, pass, h), []byte(pass)))
	return profile + "\n" + uid + "\n\n" + needKey + "\n" + pinFlag + "\n" + passWrap + "\n" + slotSpec + "\n"
}

func cstRead(t *testing.T, dest, f string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dest, f))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// cstNotCommitted checks the files of a lock that did not commit: no marker, no stage, .roamsession as before.
func cstNotCommitted(t *testing.T, dest string, roam []byte) {
	t.Helper()
	if clwExists(dest, ".coldlock") {
		t.Error(".coldlock exists: the lock committed a marker it could not stage")
	}
	if clwExists(dest, ".coldlock.tmp") {
		t.Error(".coldlock.tmp was left behind")
	}
	if got, err := os.ReadFile(filepath.Join(dest, ".roamsession")); err != nil || !bytes.Equal(got, roam) {
		t.Errorf(".roamsession changed or removed (err %v) -- the sign-out is the sign-out's to do", err)
	}
}

func cstOps(t *testing.T, rec *clwRecorder, want string) {
	t.Helper()
	if got := strings.Join(rec.ops(), " "); got != want {
		t.Errorf("ops = [%s], want [%s]", got, want)
	}
}

// S1. A stored, non-2FA session whose marker cannot be staged is signed out, above THE WAIT: the call returns while
// another holder keeps the RW slot.
func TestColdLockStageFailureStoredSessionSignsOut(t *testing.T) {
	dest, rec, hold, so := cstSetup(t, "stages1")
	coldLockStageMarker = cstTornStage
	roam := cstRead(t, dest, ".roamsession")
	hold.take()
	if !cstDirect(t, hold, dest, "stages1") {
		t.Fatal("the lock committed over a marker it could not stage")
	}
	if !cstRevoking() {
		t.Error("coldLockRevoking is false after the hand-off: a lock request arriving now would fold into a dead lock")
	}
	cstSignedOut(t, so, dest)
	cstNotCommitted(t, dest, roam)
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
	cstOps(t, rec, "armcred")
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s)", n)
	}
	hold.give()
}

// S2. A throwaway whose marker cannot be staged is kept: nothing to save, no sign-out.
func TestColdLockStageFailureThrowawayIsKept(t *testing.T) {
	dest, rec, hold, so := cstSetup(t, "stages2")
	markLocalSession(dest)
	coldLockStageMarker = cstTornStage
	roam := cstRead(t, dest, ".roamsession")
	if !cstDirect(t, hold, dest, "stages2") {
		t.Fatal("the lock committed over a marker it could not stage")
	}
	if !cstRevoking() {
		t.Error("coldLockRevoking is false after the hand-off")
	}
	cstNotCommitted(t, dest, roam)
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
	cstOps(t, rec, "armcred")
	cstNoSignOut(t, so)
}

// S3. A 2FA session whose marker cannot be staged unwinds the forward rekey (old=cred, new=unlockSecret) with the
// bar down, then is signed out.
func TestColdLockStageFailureFido2UnwindsTheRekey(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages3")
	clwFido2(t, dest)
	at := cstUnwindAnswers(rec, "")
	coldLockStageMarker = cstTornStage
	roam := cstRead(t, dest, ".roamsession")
	clwLock(t, dest, 1000)
	cstSignedOut(t, so, dest)
	rearmIdle(t)
	calls := rec.snapshot()
	if len(calls) != 2 || calls[0].op != "rekey" || calls[1].op != "rekey" {
		t.Fatalf("ops = %v, want [rekey rekey]: the forward rekey, then its unwind", rec.ops())
	}
	if calls[0].pass != "pw" || calls[0].seSecret == "" || calls[0].seSecret == "pw" {
		t.Fatalf("the forward rekey was old=%q new=%q, want old=pw new=the key-bound credential", calls[0].pass, calls[0].seSecret)
	}
	if calls[1].pass != calls[0].seSecret || calls[1].seSecret != "pw" {
		t.Errorf("the unwind was old=%q new=%q, want old=the key-bound credential new=pw", calls[1].pass, calls[1].seSecret)
	}
	seen, revoking, bar := at.get()
	if !seen || !revoking || bar != "" {
		t.Errorf("at the unwind: seen=%v coldLockRevoking=%v bar=%q, want true, true and \"\"", seen, revoking, bar)
	}
	cstNotCommitted(t, dest, roam)
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
}

// S4. The held corner (#7): the unwind fails, so the lock writes the marker in place and commits. No sign-out, and
// the session is not kept.
func TestColdLockStageFailureFido2UnwindFailsCommitsInPlace(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages4")
	clwFido2(t, dest)
	h, err := hex.DecodeString(strings.TrimSpace(string(cstRead(t, dest, ".fido2hmac"))))
	if err != nil {
		t.Fatal(err)
	}
	slotSpec := readFido2SlotsStash(dest)
	at := cstUnwindAnswers(rec, "ERR-REKEY")
	var mu sync.Mutex
	var staged []byte
	coldLockStageMarker = func(path string, b []byte) error {
		mu.Lock()
		staged = append([]byte(nil), b...)
		mu.Unlock()
		return cstTornStage(path, b)
	}
	clwLock(t, dest, 1000)
	rearmIdle(t)
	seen, revoking, bar := at.get()
	if !seen || !revoking || bar != "" {
		t.Errorf("at the unwind: seen=%v coldLockRevoking=%v bar=%q, want true, true and \"\"", seen, revoking, bar)
	}
	cstOps(t, rec, "rekey rekey btpark")
	mu.Lock()
	want := append([]byte(nil), staged...)
	mu.Unlock()
	if exp := cstMarker("stages4", "pw", "10", h, "fido2", "nopin", slotSpec); string(want) != exp {
		t.Fatalf("staged marker = %q, want %q", want, exp)
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("no .coldlock: the held corner must commit in place, as main does")
	}
	if got := cstRead(t, dest, ".coldlock"); !bytes.Equal(got, want) {
		t.Errorf(".coldlock = %q, want the staged bytes %q", got, want)
	}
	if clwExists(dest, ".coldlock.tmp") {
		t.Error(".coldlock.tmp was left behind")
	}
	if clwExists(dest, ".roamsession") {
		t.Error(".roamsession survived a committed lock")
	}
	cstNoSignOut(t, so)
}

// S5. A clean lock commits exactly main's seven-line marker, through the stage.
func TestColdLockStageCleanLockWritesTheSevenLineMarker(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages5")
	clwLock(t, dest, 0)
	rearmIdle(t)
	if !clwExists(dest, ".coldlock") {
		t.Fatal("a clean lock wrote no .coldlock")
	}
	if got, want := string(cstRead(t, dest, ".coldlock")), cstMarker("stages5", "pw", "10", nil, "nokey", "nopin", ""); got != want {
		t.Errorf(".coldlock = %q, want %q", got, want)
	}
	if clwExists(dest, ".coldlock.tmp") {
		t.Error(".coldlock.tmp was left behind by a committed lock")
	}
	if clwExists(dest, ".roamsession") {
		t.Error(".roamsession survived a committed lock")
	}
	cstOps(t, rec, "armcred btpark")
	cstNoSignOut(t, so)
}

// S6. The marker is staged above THE WAIT, and Check B's revoke (user present) removes it.
func TestColdLockStageCheckBRevokeRemovesTheStage(t *testing.T) {
	dest, rec, hold, _ := cstSetup(t, "stages6")
	roam := cstRead(t, dest, ".roamsession")
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	clwParked(t, p)
	if !clwExists(dest, ".coldlock.tmp") {
		t.Fatal("no .coldlock.tmp while the lock waits for the slot: the marker is not staged above THE WAIT")
	}
	lastPresentAt.Store(2000) // not rung: only Check B sees it
	hold.give()
	rearmIdle(t)
	cstNotCommitted(t, dest, roam)
	cstOps(t, rec, "armcred")
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot is still held (%d) after the revoke", n)
	}
}

// S7. The rename at the point of no return fails: .roamsession survives, the slot is released, the session is signed
// out.
func TestColdLockStageCommitFailureSignsOutAndReleasesTheSlot(t *testing.T) {
	dest, rec, hold, so := cstSetup(t, "stages7")
	var mu sync.Mutex
	renames := 0
	coldLockCommitMarker = func(old, new string) error {
		mu.Lock()
		renames++
		mu.Unlock()
		return &os.LinkError{Op: "rename", Old: old, New: new, Err: syscall.EIO}
	}
	roam := cstRead(t, dest, ".roamsession")
	if !cstDirect(t, hold, dest, "stages7") {
		t.Fatal("the lock committed over a marker it could not rename")
	}
	if !cstRevoking() {
		t.Error("coldLockRevoking is false after the hand-off")
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot is still held (%d) after the hand-off", n)
	}
	if v, _ := rwHolderOp.Load().(string); v != "" {
		t.Errorf("rwHolderOp = %q after the hand-off, want \"\"", v)
	}
	cstSignedOut(t, so, dest)
	mu.Lock()
	n := renames
	mu.Unlock()
	if n != 1 {
		t.Errorf("the commit rename ran %d time(s), want 1", n)
	}
	cstNotCommitted(t, dest, roam)
	cstOps(t, rec, "armcred")
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s)", n)
	}
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
}

// cstFailCommit makes the rename at the point of no return fail as an EIO does.
func cstFailCommit(old, new string) error {
	return &os.LinkError{Op: "rename", Old: old, New: new, Err: syscall.EIO}
}

// S8. A 2FA session whose rename fails releases the RW slot BEFORE the unwind (RF-001): a stalled unwind must not
// hold the queued seals and sign-ins behind it. Then the session is signed out.
func TestColdLockStageCommitFailureFido2UnwindsOutsideTheSlot(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages8")
	clwFido2(t, dest)
	at := cstUnwindAnswers(rec, "")
	coldLockCommitMarker = cstFailCommit
	roam := cstRead(t, dest, ".roamsession")
	clwLock(t, dest, 1000)
	cstSignedOut(t, so, dest)
	rearmIdle(t)
	calls := rec.snapshot()
	if len(calls) != 2 || calls[0].op != "rekey" || calls[1].op != "rekey" {
		t.Fatalf("ops = %v, want [rekey rekey]: the forward rekey, then its unwind", rec.ops())
	}
	if calls[1].slotLen != 0 || calls[1].rwHeld {
		t.Errorf("the unwind ran with the RW slot at %d (rwHeld=%v), want 0 and false: the slot is released before the hand-off", calls[1].slotLen, calls[1].rwHeld)
	}
	if calls[1].pass != calls[0].seSecret || calls[1].seSecret != "pw" {
		t.Errorf("the unwind was old=%q new=%q, want old=the key-bound credential new=pw", calls[1].pass, calls[1].seSecret)
	}
	if seen, revoking, bar := at.get(); !seen || !revoking || bar != "" {
		t.Errorf("at the unwind: seen=%v coldLockRevoking=%v bar=%q, want true, true and \"\"", seen, revoking, bar)
	}
	cstNotCommitted(t, dest, roam)
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot is still held (%d) after the hand-off", n)
	}
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
}

// S9. The held corner after a failed rename (#7): the unwind runs outside the slot, fails, and the lock takes the slot
// again, commits the marker in place and runs btpark inside the hold. No sign-out.
func TestColdLockStageCommitFailureFido2UnwindFailsRetakesTheSlot(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages9")
	clwFido2(t, dest)
	h, err := hex.DecodeString(strings.TrimSpace(string(cstRead(t, dest, ".fido2hmac"))))
	if err != nil {
		t.Fatal(err)
	}
	slotSpec := readFido2SlotsStash(dest)
	cstUnwindAnswers(rec, "ERR-REKEY")
	coldLockCommitMarker = cstFailCommit
	clwLock(t, dest, 1000)
	rearmIdle(t)
	cstOps(t, rec, "rekey rekey btpark")
	calls := rec.snapshot()
	if len(calls) == 3 {
		if calls[1].slotLen != 0 || calls[1].rwHeld {
			t.Errorf("the unwind ran with the RW slot at %d (rwHeld=%v), want 0 and false", calls[1].slotLen, calls[1].rwHeld)
		}
		if calls[2].slotLen != 1 || !calls[2].rwHeld {
			t.Errorf("btpark ran with the RW slot at %d (rwHeld=%v), want 1 and true: the held corner must take the slot again", calls[2].slotLen, calls[2].rwHeld)
		}
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("no .coldlock: the held corner must commit in place, as main does")
	}
	if got, want := string(cstRead(t, dest, ".coldlock")), cstMarker("stages9", "pw", "10", h, "fido2", "nopin", slotSpec); got != want {
		t.Errorf(".coldlock = %q, want %q", got, want)
	}
	if clwExists(dest, ".roamsession") {
		t.Error(".roamsession survived a committed lock")
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot is still held (%d) after the lock", n)
	}
	cstNoSignOut(t, so)
}

// cstNoKeep records coldLockSignOutNoKeep (#7, NWP-20261125-07): each call, and the bar and the RW slot it met.
type cstNoKeep struct {
	mu    sync.Mutex
	dests []string
	bars  []string
	slots []int
	ch    chan struct{}
}

func (c *cstNoKeep) calls() ([]string, []string, []int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.dests...), append([]string(nil), c.bars...), append([]int(nil), c.slots...)
}

// cstNoKeepSetup replaces coldLockWriteMarker with write (nil keeps the real one) and coldLockSignOutNoKeep with a
// recorder, restoring both after the test.
func cstNoKeepSetup(t *testing.T, write func(string, []byte) error) *cstNoKeep {
	t.Helper()
	prevWrite, prevNoKeep := coldLockWriteMarker, coldLockSignOutNoKeep
	nk := &cstNoKeep{ch: make(chan struct{}, 4)}
	if write != nil {
		coldLockWriteMarker = write
	}
	coldLockSignOutNoKeep = func(d string) {
		coldLockMu.Lock()
		bar := coldLockSignOutBar
		coldLockMu.Unlock()
		nk.mu.Lock()
		nk.dests = append(nk.dests, d)
		nk.bars = append(nk.bars, bar)
		nk.slots = append(nk.slots, len(laneRW.slot))
		nk.mu.Unlock()
		nk.ch <- struct{}{}
	}
	t.Cleanup(func() { coldLockWriteMarker, coldLockSignOutNoKeep = prevWrite, prevNoKeep })
	return nk
}

// cstWrites counts the in-place writes and the paths they were handed.
type cstWrites struct {
	mu    sync.Mutex
	paths []string
}

func (w *cstWrites) record(path string) {
	w.mu.Lock()
	w.paths = append(w.paths, path)
	w.mu.Unlock()
}

func (w *cstWrites) got() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]string(nil), w.paths...)
}

// cstTornWrite writes half the marker in place and fails as a full tmpfs does.
func cstTornWrite(w *cstWrites) func(string, []byte) error {
	return func(path string, b []byte) error {
		w.record(path)
		if err := os.WriteFile(path, b[:len(b)/2], 0o600); err != nil {
			return err
		}
		return fmt.Errorf("write: %w", syscall.ENOSPC)
	}
}

// cstSignedOutNoKeep waits (a hang guard) for the one no-keep sign-out of dest, and checks what it met: the bar down
// and the RW slot free, so the real handleLogout it runs can claim the session and seal.
func cstSignedOutNoKeep(t *testing.T, nk *cstNoKeep, dest string) {
	t.Helper()
	select {
	case <-nk.ch:
	case <-time.After(10 * time.Second):
		t.Fatal("coldLockSignOutNoKeep never ran: a failed in-place write was not handed to the no-keep sign-out")
	}
	dests, bars, slots := nk.calls()
	if len(dests) != 1 || dests[0] != dest {
		t.Fatalf("coldLockSignOutNoKeep calls = %q, want exactly one for %q", dests, dest)
	}
	if bars[0] != "" || slots[0] != 0 {
		t.Errorf("the no-keep sign-out met bar=%q and RW slot %d, want \"\" and 0", bars[0], slots[0])
	}
}

// cstEndedNoKeep checks the files and the shared state once a held corner has handed off to the no-keep sign-out.
func cstEndedNoKeep(t *testing.T, dest string, roam []byte, rec *clwRecorder, so *cstSignOut, w *cstWrites) {
	t.Helper()
	cstNotCommitted(t, dest, roam)
	if got := w.got(); len(got) != 1 || got[0] != filepath.Join(dest, ".coldlock") {
		t.Errorf("in-place writes = %q, want exactly one, to .coldlock", got)
	}
	cstOps(t, rec, "rekey rekey") // no btpark: the sign-out's reap clears what the lock would have
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s): the lock went on past a failed in-place write", n)
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot is still held (%d) after the hand-off", n)
	}
	if v, _ := rwHolderOp.Load().(string); v != "" {
		t.Errorf("rwHolderOp = %q after the hand-off, want \"\"", v)
	}
	coldLockMu.Lock()
	bar := coldLockSignOutBar
	coldLockMu.Unlock()
	if bar != "" {
		t.Errorf("coldLockSignOutBar = %q after the hand-off, want \"\"", bar)
	}
	if got := nextReapAction(); got != "NONE" {
		t.Errorf("nextReapAction = %q, want NONE: no lock, no switch and no idle re-arm -- the sign-out ends the session", got)
	}
	cstNoSignOut(t, so) // coldLockSignOut keeps a session whose save fails: #7 rules it out here
}

// S4a. The held corner's in-place write lands (#7): .coldlock holds the marker, the lock commits, no sign-out.
func TestColdLockStageFailureFido2InPlaceWriteCommits(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages4a")
	clwFido2(t, dest)
	h, err := hex.DecodeString(strings.TrimSpace(string(cstRead(t, dest, ".fido2hmac"))))
	if err != nil {
		t.Fatal(err)
	}
	slotSpec := readFido2SlotsStash(dest)
	w := &cstWrites{}
	nk := cstNoKeepSetup(t, func(path string, b []byte) error {
		w.record(path)
		return os.WriteFile(path, b, 0o600)
	})
	cstUnwindAnswers(rec, "ERR-REKEY")
	coldLockStageMarker = cstTornStage
	clwLock(t, dest, 1000)
	rearmIdle(t)
	cstOps(t, rec, "rekey rekey btpark")
	if got := w.got(); len(got) != 1 || got[0] != filepath.Join(dest, ".coldlock") {
		t.Errorf("in-place writes = %q, want exactly one, to .coldlock", got)
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("no .coldlock: the held corner's in-place write must commit the lock")
	}
	if got, want := string(cstRead(t, dest, ".coldlock")), cstMarker("stages4a", "pw", "10", h, "fido2", "nopin", slotSpec); got != want {
		t.Errorf(".coldlock = %q, want %q", got, want)
	}
	if clwExists(dest, ".roamsession") {
		t.Error(".roamsession survived a committed lock")
	}
	cstNoSignOut(t, so)
	if dests, _, _ := nk.calls(); len(dests) != 0 {
		t.Errorf("coldLockSignOutNoKeep ran %d time(s) after an in-place write that landed", len(dests))
	}
}

// S4b. The stage fails, the unwind fails and the in-place write fails too (#7): no marker, .roamsession kept for the
// sign-out, the slot released, the bar down, and the no-keep sign-out runs once -- never coldLockSignOut.
func TestColdLockStageFailureFido2InPlaceWriteFailsSignsOutNoKeep(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages4b")
	clwFido2(t, dest)
	w := &cstWrites{}
	nk := cstNoKeepSetup(t, cstTornWrite(w))
	cstUnwindAnswers(rec, "ERR-REKEY")
	coldLockStageMarker = cstTornStage
	roam := cstRead(t, dest, ".roamsession")
	clwLock(t, dest, 1000)
	cstSignedOutNoKeep(t, nk, dest)
	rearmIdle(t)
	cstEndedNoKeep(t, dest, roam, rec, so, w)
}

// S9b. As S4b, through the failed commit rename: the slot is taken again for the in-place write, which fails, so it
// is released and the no-keep sign-out runs.
func TestColdLockStageCommitFailureFido2InPlaceWriteFailsSignsOutNoKeep(t *testing.T) {
	dest, rec, _, so := cstSetup(t, "stages9b")
	clwFido2(t, dest)
	w := &cstWrites{}
	nk := cstNoKeepSetup(t, cstTornWrite(w))
	cstUnwindAnswers(rec, "ERR-REKEY")
	coldLockCommitMarker = cstFailCommit
	roam := cstRead(t, dest, ".roamsession")
	clwLock(t, dest, 1000)
	cstSignedOutNoKeep(t, nk, dest)
	rearmIdle(t)
	cstEndedNoKeep(t, dest, roam, rec, so, w)
}

// S10. The no-keep hand-off clears this lock's sign-out bar, in a coldLockMu hold, before it starts the sign-out
// (the B7b shape). The teardown's defer clears the bar too, so S4b and S9b cannot see a missing clear for certain:
// the sign-out's goroutine may start after that defer has run.
func TestColdLockStageNoKeepClearsTheBarSource(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "coldLockTeardown"))
	at := -1
	for i, l := range body {
		if strings.HasPrefix(strings.TrimSpace(l), `goSafe("coldlock-nokeep-signout"`) {
			at = i
			break
		}
	}
	if at < 0 {
		t.Fatal(`no goSafe("coldlock-nokeep-signout" in coldLockTeardown -- this test is stale`)
	}
	lock := -1
	for i := at; i >= 0; i-- {
		if strings.TrimSpace(body[i]) == "coldLockMu.Lock()" {
			lock = i
			break
		}
	}
	if lock < 0 {
		t.Fatal("no coldLockMu hold before the no-keep hand-off")
	}
	for i := lock + 1; i < at; i++ {
		s := strings.TrimSpace(body[i])
		if s == "coldLockMu.Unlock()" {
			break
		}
		if strings.HasPrefix(s, `coldLockSignOutBar = ""`) {
			return
		}
	}
	t.Error(`the no-keep hand-off's coldLockMu hold does not clear coldLockSignOutBar before goSafe("coldlock-nokeep-signout" ` +
		"-- the sign-out's handleLogout can meet the bar and answer BUSY COLDLOCK")
}
