package main

import (
	"testing"
	"time"
)

// NWP-20261017-13: the cold-lock teardown keeps the forward rekey's reply. After a DEFINITIVE refusal
// (ERR-REKEY / ERR-ARGS / ERR-REQ) the keyguard never moved, so a revoke has nothing to unwind; after OK, or after
// any reply that leaves it open (ERR-TIMEOUT), the unwind runs and a failed unwind declines the revoke.

// clwRekeyRun drives a 2FA lock whose forward rekey answers fwd and whose unwind (the second rekey, if it is made)
// answers unwind, with an authenticated unlock landing during the wait. It returns once the teardown has left the
// queue (aborted) or, for a declined revoke, once it has re-queued; the caller releases the seal as it needs.
func clwRekeyRun(t *testing.T, fwd, unwind string) (string, *clwRecorder, *clwHold) {
	t.Helper()
	dest, rec, hold := clwSetup(t)
	clwFido2(t, dest)
	rec.ret = func(op string, nth int) string {
		if op != "rekey" {
			return ""
		}
		if nth == 1 {
			return fwd
		}
		return unwind
	}
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the forward rekey never ran")
	}
	clwParked(t, p)
	if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
		t.Fatal("the unlock was rejected")
	}
	return dest, rec, hold
}

// (a) The forward rekey was refused outright: the keyguard still holds the typable secret, so there is nothing to
// unwind. Since NWP-20261031-06 the refusal never reaches Check B: the lock is revoked above the wait and handed to a
// sign-out (coldlock_armfail_test.go has the full hand-off), so no second rekey is made and no marker is written.
func TestColdLockForwardRekeyRefusedAbortsWithoutUnwind(t *testing.T) {
	for _, fwd := range []string{"ERR-REKEY", "ERR-ARGS", "ERR-REQ"} {
		t.Run(fwd, func(t *testing.T) {
			cafInstall(t)
			dest, rec, _ := clwSetup(t)
			cafRun(t, dest, rec, fwd, true)
			if got := rec.ops(); len(got) != 1 || got[0] != "rekey" {
				t.Errorf("ops = %v, want [rekey]: no unwind after a rekey that never landed", got)
			}
			if clwExists(dest, ".coldlock") {
				t.Error(".coldlock was written over a keyguard that never moved")
			}
			if !clwExists(dest, ".roamsession") {
				t.Error(".roamsession was removed -- the session did not continue")
			}
			if n := rec.stopCount(); n != 0 {
				t.Errorf("mediad was stopped %d time(s)", n)
			}
		})
	}
}

// (b) The forward rekey landed and the unwind succeeds: aborted after exactly one unwind.
func TestColdLockForwardRekeyOKUnwindsAndAborts(t *testing.T) {
	dest, rec, _ := clwRekeyRun(t, "", "")
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never left the queue")
	}
	if got := rec.ops(); len(got) != 2 || got[0] != "rekey" || got[1] != "rekey" {
		t.Errorf("ops = %v, want [rekey rekey]: forward, then exactly one unwind", got)
	}
	if clwExists(dest, ".coldlock") || !clwExists(dest, ".roamsession") {
		t.Errorf("an aborted lock touched state: coldlock=%v roamsession=%v",
			clwExists(dest, ".coldlock"), clwExists(dest, ".roamsession"))
	}
}

// clwRekeyDeclined finishes a declined revoke: the unwind failed, so the lock commits once the slot frees.
func clwRekeyDeclined(t *testing.T, dest string, rec *clwRecorder, hold *clwHold) {
	t.Helper()
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 2 }) {
		t.Fatal("the unwind was never attempted")
	}
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the declined lock never finished")
	}
	if got := rec.ops(); len(got) != 3 || got[0] != "rekey" || got[1] != "rekey" || got[2] != "btpark" {
		t.Errorf("ops = %v, want [rekey rekey btpark]", got)
	}
	if !clwExists(dest, ".coldlock") {
		t.Error("the declined revoke did not commit the lock")
	}
}

// (c) The forward rekey landed but the unwind fails: the revoke is declined and the lock commits.
func TestColdLockForwardRekeyOKFailedUnwindDeclinesTheRevoke(t *testing.T) {
	dest, rec, hold := clwRekeyRun(t, "", "ERR-REKEY")
	clwRekeyDeclined(t, dest, rec, hold)
}

// (d) A timed-out forward rekey may have landed after the stall: it still unwinds, and a failed unwind declines.
func TestColdLockForwardRekeyTimeoutStillUnwinds(t *testing.T) {
	dest, rec, hold := clwRekeyRun(t, "ERR-TIMEOUT", "ERR-REKEY")
	clwRekeyDeclined(t, dest, rec, hold)
}
