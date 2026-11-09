package main

import (
	"sync"
	"testing"
	"time"
)

// NWP-20261031-06: a cold lock whose credential step did not land never commits (decision 2026-10-20, Q066): a
// stored session is handed to a sign-out, a throwaway is kept, and the gate's idle lock is re-armed.

// cafSignOut replaces coldLockSignOut with a recorder.
type cafSignOut struct {
	mu    sync.Mutex
	dests []string
}

func (c *cafSignOut) calls() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.dests...)
}

func cafInstall(t *testing.T) *cafSignOut {
	t.Helper()
	rec := &cafSignOut{}
	prev := coldLockSignOut
	coldLockSignOut = func(dest string) {
		rec.mu.Lock()
		rec.dests = append(rec.dests, dest)
		rec.mu.Unlock()
	}
	t.Cleanup(func() { coldLockSignOut = prev })
	rearmClear(t)
	return rec
}

// cafRun starts a lock whose armcred (or, for fido2, rekey) answers reply, and waits for the teardown to finish.
func cafRun(t *testing.T, dest string, rec *clwRecorder, reply string, fido2 bool) {
	t.Helper()
	op := "armcred"
	if fido2 {
		clwFido2(t, dest)
		op = "rekey"
	}
	rec.ret = func(o string, nth int) string {
		if o == op && nth == 1 {
			return reply
		}
		return ""
	}
	clwLock(t, dest, 0)
	rearmIdle(t)
}

func cafHandedOff(t *testing.T, dest string, rec *clwRecorder, so *cafSignOut) {
	t.Helper()
	if clwExists(dest, ".coldlock") {
		t.Error(".coldlock was written over a keyguard credential that did not arm")
	}
	if !clwExists(dest, ".roamsession") {
		t.Error(".roamsession was removed -- the sign-out is the sign-out's to do")
	}
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s)", n)
	}
	for _, o := range rec.ops() {
		if o == "btpark" {
			t.Error("btpark ran for a lock that never committed")
		}
	}
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
}

func cafSignedOut(t *testing.T, so *cafSignOut, want int) {
	t.Helper()
	if !clwWaitFor(2*time.Second, func() bool { return len(so.calls()) >= want }) {
		t.Fatalf("coldLockSignOut called %d time(s), want %d", len(so.calls()), want)
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(so.calls()); n != want {
		t.Errorf("coldLockSignOut called %d time(s), want %d", n, want)
	}
}

func TestColdLockArmFailStoredSessionSignsOut(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	cafRun(t, dest, rec, "OK NOTARMED", false)
	cafHandedOff(t, dest, rec, so)
	cafSignedOut(t, so, 1)
}

func TestColdLockArmFailThrowawayIsKept(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	markLocalSession(dest)
	cafRun(t, dest, rec, "OK NOTARMED", false)
	cafHandedOff(t, dest, rec, so)
	cafSignedOut(t, so, 0)
}

func TestColdLockArmFailLandedCommits(t *testing.T) {
	for _, reply := range []string{"OK ARMED", "OK"} {
		t.Run(reply, func(t *testing.T) {
			so := cafInstall(t)
			dest, rec, _ := clwSetup(t)
			cafRun(t, dest, rec, reply, false)
			if !clwExists(dest, ".coldlock") {
				t.Error("an armed credential did not commit the lock")
			}
			cafSignedOut(t, so, 0)
		})
	}
}

func TestColdLockArmFailTimeoutHandsOff(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	cafRun(t, dest, rec, "ERR-TIMEOUT", false)
	cafHandedOff(t, dest, rec, so)
	cafSignedOut(t, so, 1)
}

func TestColdLockArmFailFido2RefusedHandsOffWithoutUnwind(t *testing.T) {
	so := cafInstall(t)
	dest, rec, _ := clwSetup(t)
	cafRun(t, dest, rec, "ERR-REKEY", true)
	cafHandedOff(t, dest, rec, so)
	cafSignedOut(t, so, 1)
	if got := rec.ops(); len(got) != 1 || got[0] != "rekey" {
		t.Errorf("ops = %v, want [rekey]: no unwind after a rekey that never landed", got)
	}
}

// h56 #2 (NWP-20261126-01): ERR-WORKER-BUSY (nothing was written to roamcred.req) and ERR-UID (roamd's uid guard)
// mean the keyguard never moved: the lock hands off, with no unwind.
func TestColdLockArmFailFido2NeverMovedRepliesHandOff(t *testing.T) {
	for _, reply := range []string{"ERR-WORKER-BUSY", "ERR-UID"} {
		t.Run(reply, func(t *testing.T) {
			so := cafInstall(t)
			dest, rec, _ := clwSetup(t)
			cafRun(t, dest, rec, reply, true)
			cafHandedOff(t, dest, rec, so)
			cafSignedOut(t, so, 1)
			if got := rec.ops(); len(got) != 1 || got[0] != "rekey" {
				t.Errorf("ops = %v, want [rekey]: no unwind after a rekey that never moved", got)
			}
		})
	}
}

func TestColdLockArmFailLandedTable(t *testing.T) {
	for _, c := range []struct {
		needKey, arm, fwd string
		want              bool
	}{
		{"nokey", "OK ARMED", "", true},
		{"nokey", "OK", "", true},
		{"nokey", "OK NOTARMED", "", false},
		{"nokey", "ERR-TIMEOUT", "", false},
		{"nokey", "ERR-ARGS", "", false},
		{"nokey", "", "", false},
		{"fido2", "", "OK", true},
		{"fido2", "", "ERR-TIMEOUT", true},
		{"fido2", "", "", true},
		{"fido2", "", "ERR-REKEY", false},
		{"fido2", "", "ERR-ARGS", false},
		{"fido2", "", "ERR-REQ", false},
		{"fido2", "", "ERR-WORKER-BUSY", false},
		{"fido2", "", "ERR-UID", false},
	} {
		if got := coldLockArmLanded(c.needKey, c.arm, c.fwd); got != c.want {
			t.Errorf("coldLockArmLanded(%q, %q, %q) = %v, want %v", c.needKey, c.arm, c.fwd, got, c.want)
		}
	}
}

// The branch sits above THE WAIT: with the RW slot held it still hands off and returns at once.
func TestColdLockArmFailHandsOffWhileTheSlotIsHeld(t *testing.T) {
	so := cafInstall(t)
	dest, rec, hold := clwSetup(t)
	rec.ret = func(o string, nth int) string {
		if o == "armcred" {
			return "OK NOTARMED"
		}
		return ""
	}
	hold.take()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown queued for the RW slot instead of handing off")
	}
	cafSignedOut(t, so, 1)
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
}

// The default sign-out is serialised on sessionMu, as LOGOUT is.
func TestColdLockArmFailDefaultSignOutTakesSessionMu(t *testing.T) {
	dest := t.TempDir()
	sessionMu.Lock()
	released := false
	t.Cleanup(func() {
		if !released {
			sessionMu.Unlock()
		}
	})
	done := make(chan struct{})
	go func() { coldLockSignOut(dest); close(done) }()
	select {
	case <-done:
		t.Fatal("the sign-out ran while sessionMu was held -- it races ROAM-IN/PROMOTE/CLAIM")
	case <-time.After(200 * time.Millisecond):
	}
	sessionMu.Unlock()
	released = true
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the sign-out did not return after sessionMu was released")
	}
}
