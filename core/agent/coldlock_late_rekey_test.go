package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// h56 #2 (decided 2026-11-03, option 3; NWP-20261126-01): a forward rekey that answered ERR-TIMEOUT left its roamd
// instance running, and the lock committed on a guess. coldLockAwaitLateRekey now waits, bounded, for that instance to
// end and reads its real reply from roamcred.res: OK commits, a never-moved refusal hands off with no unwind, and a
// reply still unknown at the bound signs the session out without the keep-on-save-failure arm (NWP-20261128-06).

// clrSetup records record as laneCred's abandoned op (nil: the daemon-start map), replaces workerState with a fake
// that answers states(n) for the n-th read of laneCred.svc and "stopped" for any other lane, and shrinks the poll.
// Call it AFTER clwSetup, so its Cleanup (which drains laneCred.slot) runs before clwSetup's waits for the teardown.
func clrSetup(t *testing.T, record *string, bound time.Duration, states func(n int32) string) *atomic.Int32 {
	t.Helper()
	if n := len(laneCred.slot); n != 0 {
		t.Fatalf("the shared cred slot is already held (%d) -- a previous test leaked it", n)
	}
	reads := &atomic.Int32{}
	prevState, prevBound, prevPoll := workerState, coldLockLateRekeyBound, coldLockLateRekeyPoll
	workerState = func(svc string) string {
		if svc != laneCred.svc {
			return "stopped"
		}
		return states(reads.Add(1))
	}
	coldLockLateRekeyBound, coldLockLateRekeyPoll = bound, time.Millisecond
	abandonedMu.Lock()
	if record == nil {
		abandonedOp = abandonedAtDaemonStart()
	} else {
		abandonedOp = map[string]string{laneCred.svc: *record}
	}
	abandonedMu.Unlock()
	t.Cleanup(func() {
		for len(laneCred.slot) > 0 {
			<-laneCred.slot
		}
		workerState, coldLockLateRekeyBound, coldLockLateRekeyPoll = prevState, prevBound, prevPoll
		abandonedMu.Lock()
		abandonedOp = abandonedAtDaemonStart()
		abandonedMu.Unlock()
	})
	return reads
}

func clrRekey() *string { s := "rekey"; return &s }

func clrStopsAfterTwo(n int32) string {
	if n <= 2 {
		return "running"
	}
	return "stopped"
}

func clrRes(t *testing.T, dest, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, laneCred.res), []byte(text+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func clrMarkerKey(t *testing.T, dest string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dest, ".coldlock"))
	if err != nil {
		t.Fatalf(".coldlock: %v", err)
	}
	if l := strings.Split(string(b), "\n"); len(l) > 3 {
		return l[3]
	}
	return ""
}

func clrCommitted(t *testing.T, dest string, so *cafSignOut) {
	t.Helper()
	if !clwExists(dest, ".coldlock") {
		t.Fatal("the lock did not commit")
	}
	if got := clrMarkerKey(t, dest); got != "fido2" {
		t.Errorf("marker key flag = %q, want fido2", got)
	}
	cafSignedOut(t, so, 0)
}

// clrSignedOutNoKeep pins the bound's end (h56 #2, NWP-20261128-06): no commit, no staged marker, one no-keep
// sign-out of dest with the sign-out bar already dropped, no plain sign-out, no idle re-arm, and .roamsession kept for
// the sign-out to read.
func clrSignedOutNoKeep(t *testing.T, dest string, so *cafSignOut, nk *cstNoKeep) {
	t.Helper()
	if clwExists(dest, ".coldlock") {
		t.Error("the lock committed over a rekey still unknown at the bound")
	}
	if clwExists(dest, ".coldlock.tmp") {
		t.Error(".coldlock.tmp was left behind: a revoke never leaves a staged marker")
	}
	if !clwExists(dest, ".roamsession") {
		t.Error(".roamsession was removed: the no-keep sign-out reads it")
	}
	select {
	case <-nk.ch:
	case <-time.After(2 * time.Second):
		t.Fatal("coldLockSignOutNoKeep was never called")
	}
	time.Sleep(50 * time.Millisecond)
	dests, bars, _ := nk.calls()
	if len(dests) != 1 || dests[0] != dest {
		t.Errorf("coldLockSignOutNoKeep calls = %v, want exactly one, of %s", dests, dest)
	}
	if len(bars) == 1 && bars[0] != "" {
		t.Errorf("sign-out bar at the no-keep sign-out = %q, want dropped", bars[0])
	}
	coldLockMu.Lock()
	bar := coldLockSignOutBar
	coldLockMu.Unlock()
	if bar != "" {
		t.Errorf("coldLockSignOutBar = %q after the teardown, want empty", bar)
	}
	cafSignedOut(t, so, 0)
	if got := rearmField(); got != "" {
		t.Errorf("idle re-arm queued for %q: the session ends, nothing re-arms", got)
	}
}

// (a) The late reply is OK: the lock commits, the record is cleared, the reply is taken.
func TestColdLockLateRekeyLateOKCommits(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	reads := clrSetup(t, clrRekey(), time.Minute, clrStopsAfterTwo)
	clrRes(t, dest, "OK")
	cafRun(t, dest, rec, "ERR-TIMEOUT", true)
	clrCommitted(t, dest, so)
	if n := reads.Load(); n < 3 {
		t.Errorf("laneCred state read %d time(s), want at least 3 (two running, then stopped)", n)
	}
	if got := laneAbandonedOp(laneCred); got != "" {
		t.Errorf("laneCred record = %q, want cleared after the late reply was read", got)
	}
	if clwExists(dest, laneCred.res) {
		t.Error("roamcred.res is still there: the late reply was not taken")
	}
}

// (b) The late reply is a refusal: the keyguard never moved, so the lock hands off with no unwind.
func TestColdLockLateRekeyLateRefusalHandsOff(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	clrSetup(t, clrRekey(), time.Minute, clrStopsAfterTwo)
	clrRes(t, dest, "ERR-REKEY")
	cafRun(t, dest, rec, "ERR-TIMEOUT", true)
	cafHandedOff(t, dest, rec, so)
	cafSignedOut(t, so, 1)
	if got := rec.ops(); len(got) != 1 || got[0] != "rekey" {
		t.Errorf("ops = %v, want [rekey]: no unwind after a late refusal", got)
	}
	if got := laneAbandonedOp(laneCred); got != "" {
		t.Errorf("laneCred record = %q, want cleared after the late reply was read", got)
	}
}

// (c) The instance still runs at the bound: the session signs out without the keep arm, the record and the reply
// file stay, and a stale staged marker is removed.
func TestColdLockLateRekeyStillRunningAtTheBoundSignsOutNoKeep(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	nk := cstNoKeepSetup(t, nil)
	clrSetup(t, clrRekey(), 20*time.Millisecond, func(int32) string { return "running" })
	clrRes(t, dest, "OK")
	if err := os.WriteFile(filepath.Join(dest, ".coldlock.tmp"), []byte("stale\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cafRun(t, dest, rec, "ERR-TIMEOUT", true)
	clrSignedOutNoKeep(t, dest, so, nk)
	if got := rec.ops(); len(got) != 1 || got[0] != "rekey" {
		t.Errorf("ops = %v, want [rekey]: no unwind at the bound", got)
	}
	if got := laneAbandonedOp(laneCred); got != "rekey" {
		t.Errorf("laneCred record = %q, want rekey kept: nothing was read", got)
	}
	if !clwExists(dest, laneCred.res) {
		t.Error("roamcred.res was taken while the instance still ran")
	}
}

// (d) A daemon-start record is not this rekey's: no wait, workerState never read for the cred lane, and the session
// signs out without the keep arm.
func TestColdLockLateRekeyDaemonStartRecordSignsOutNoKeep(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	nk := cstNoKeepSetup(t, nil)
	reads := clrSetup(t, nil, time.Minute, func(int32) string { return "stopped" })
	clrRes(t, dest, "ERR-REKEY")
	cafRun(t, dest, rec, "ERR-TIMEOUT", true)
	clrSignedOutNoKeep(t, dest, so, nk)
	if n := reads.Load(); n != 0 {
		t.Errorf("laneCred state read %d time(s), want 0", n)
	}
	if !clwExists(dest, laneCred.res) {
		t.Error("roamcred.res was taken under a daemon-start record")
	}
}

// (e) Another cred op holds the slot when the instance has stopped: no reply taken, the record untouched, and the
// session signs out without the keep arm.
func TestColdLockLateRekeySlotHeldAtStopSignsOutNoKeep(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	nk := cstNoKeepSetup(t, nil)
	clrSetup(t, clrRekey(), 100*time.Millisecond, func(int32) string { return "stopped" })
	clrRes(t, dest, "ERR-REKEY")
	laneCred.slot <- struct{}{}
	cafRun(t, dest, rec, "ERR-TIMEOUT", true)
	clrSignedOutNoKeep(t, dest, so, nk)
	if got := laneAbandonedOp(laneCred); got != "rekey" {
		t.Errorf("laneCred record = %q, want rekey kept", got)
	}
	if !clwExists(dest, laneCred.res) {
		t.Error("roamcred.res was taken without the slot")
	}
	<-laneCred.slot
}

// (f) Another cred op discarded the late reply and cleared the record while this waited for the slot: roamcred.res
// now holds that op's reply, which is not this rekey's and must not be read, so the session signs out without the
// keep arm.
func TestColdLockLateRekeyRecordClearedWhileWaitingSignsOutNoKeep(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	nk := cstNoKeepSetup(t, nil)
	reads := clrSetup(t, clrRekey(), time.Minute, func(int32) string { return "stopped" })
	clwFido2(t, dest)
	rec.ret = func(o string, nth int) string {
		if o == "rekey" && nth == 1 {
			return "ERR-TIMEOUT"
		}
		return ""
	}
	laneCred.slot <- struct{}{}
	clwLock(t, dest, 0)
	if !clwWaitFor(5*time.Second, func() bool { return reads.Load() > 0 }) {
		<-laneCred.slot
		t.Fatal("the teardown never read the cred lane's state")
	}
	clearLaneAbandoned(laneCred)
	clrRes(t, dest, "ERR-REKEY")
	<-laneCred.slot
	rearmIdle(t)
	clrSignedOutNoKeep(t, dest, so, nk)
	if !clwExists(dest, laneCred.res) {
		t.Error("roamcred.res was read after the record was cleared: another op's reply")
	}
}

// (g) The instance stopped without a reply: the session signs out without the keep arm, and the record stays for the
// next cred op's discard.
func TestColdLockLateRekeyStoppedWithoutReplySignsOutNoKeep(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	nk := cstNoKeepSetup(t, nil)
	clrSetup(t, clrRekey(), time.Minute, func(int32) string { return "stopped" })
	cafRun(t, dest, rec, "ERR-TIMEOUT", true)
	clrSignedOutNoKeep(t, dest, so, nk)
	if got := laneAbandonedOp(laneCred); got != "rekey" {
		t.Errorf("laneCred record = %q, want rekey kept: no reply was read", got)
	}
}

// (h) A throwaway still unknown at the bound: nothing to save, so it is kept -- no commit, no sign-out, no re-arm.
func TestColdLockLateRekeyThrowawayAtTheBoundIsKept(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	nk := cstNoKeepSetup(t, nil)
	markLocalSession(dest)
	clrSetup(t, clrRekey(), 20*time.Millisecond, func(int32) string { return "running" })
	cafRun(t, dest, rec, "ERR-TIMEOUT", true)
	if clwExists(dest, ".coldlock") {
		t.Error("the lock committed over a rekey still unknown at the bound")
	}
	if clwExists(dest, ".coldlock.tmp") {
		t.Error(".coldlock.tmp was left behind")
	}
	if !clwExists(dest, ".roamsession") {
		t.Error(".roamsession was removed: the throwaway was not kept")
	}
	time.Sleep(50 * time.Millisecond)
	if dests, _, _ := nk.calls(); len(dests) != 0 {
		t.Errorf("coldLockSignOutNoKeep calls = %v, want none: a throwaway has nothing to save", dests)
	}
	cafSignedOut(t, so, 0)
	if got := rearmField(); got != "" {
		t.Errorf("idle re-arm queued for %q, want none", got)
	}
}
