package main

import (
	"testing"
	"time"
)

// NWP-20261031-02: a cold lock a logoff revokes AFTER its reply ("OK LOCKING" has gone) leaves REARM <uid> on
// POLL-REAP until the gate acks it, and nothing else queues it. Row "A COLD LOCK REVOKED AT CHECK B CANNOT TELL THE
// CHOOSER, SO THAT FIRE'S IDLE ALARM IS STILL SPENT".

func rearmClear(t *testing.T) {
	t.Helper()
	reset := func() {
		pendingReapMu.Lock()
		pendingSwitchUID, pendingReapUID, pendingLockUID, pendingRearmUID = "", "", "", ""
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

func rearmField() string {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return pendingRearmUID
}

func rearmIdle(t *testing.T) {
	t.Helper()
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
}

// rearmCheckBRevoke runs an idle cold lock that waits behind a held RW slot, claims a logoff for uid 10 after the
// reply, then frees the slot so Check B revokes on the logoff.
func rearmCheckBRevoke(t *testing.T) string {
	t.Helper()
	rearmClear(t)
	dest, _, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	clwParked(t, p)
	seq := setLogoffInFlight("10")
	t.Cleanup(func() { clearLogoffInFlight("10", seq) })
	hold.give()
	rearmIdle(t)
	if clwExists(dest, ".coldlock") {
		t.Fatal("the lock committed -- this is not the revoked case")
	}
	return dest
}

// (a) Check B revoked by a logoff in flight.
func TestColdLockRearmCheckBLogoffQueuesIt(t *testing.T) {
	rearmCheckBRevoke(t)
	if got := nextReapAction(); got != "REARM 10" {
		t.Fatalf("nextReapAction = %q after a logoff-revoked cold lock, want REARM 10", got)
	}
	if got := nextReapAction(); got != "REARM 10" {
		t.Fatalf("second poll = %q, want REARM 10 redelivered until acked (#141)", got)
	}
}

// (b) A teardown in progress comes first; REARM follows once it is acked.
func TestColdLockRearmComesAfterSwitchAndLock(t *testing.T) {
	for _, tc := range []struct{ phase string }{{"SWITCH"}, {"LOCK"}} {
		t.Run(tc.phase, func(t *testing.T) {
			rearmCheckBRevoke(t)
			pendingReapMu.Lock()
			if tc.phase == "SWITCH" {
				pendingSwitchUID = "10"
			} else {
				pendingLockUID = "10"
			}
			pendingReapMu.Unlock()
			if got := nextReapAction(); got != tc.phase+" 10" {
				t.Fatalf("with %s queued = %q, want %s 10 first", tc.phase, got, tc.phase)
			}
			ackReapAction(tc.phase, "10")
			if got := nextReapAction(); got != "REARM 10" {
				t.Fatalf("after the %s ack = %q, want REARM 10", tc.phase, got)
			}
		})
	}
}

// (c) The ack is compare-and-clear on uid.
func TestColdLockRearmAckIsCompareAndClear(t *testing.T) {
	rearmCheckBRevoke(t)
	ackReapAction("REARM", "11")
	if got := nextReapAction(); got != "REARM 10" {
		t.Fatalf("after an ack for another uid = %q, want REARM 10 left queued", got)
	}
	ackReapAction("REARM", "10")
	if got := nextReapAction(); got != "NONE" {
		t.Fatalf("after the right ack = %q, want NONE", got)
	}
}

// (d) Check A's logoff arm queues it. Direct call: the pre-reply refusal in handleColdLock keeps a logoff that is
// already running out of the goroutine, so the arm is reached only when the logoff lands while the reply is in flight.
func TestColdLockRearmCheckALogoffQueuesIt(t *testing.T) {
	rearmClear(t)
	dest, _, _ := clwSetup(t)
	seq := setLogoffInFlight("10")
	t.Cleanup(func() { clearLogoffInFlight("10", seq) })
	if !coldLockTeardown(dest, "alice", "pw", "10", nil) {
		t.Fatal("Check A did not revoke on a logoff in flight")
	}
	if got := nextReapAction(); got != "REARM 10" {
		t.Fatalf("nextReapAction = %q after Check A's logoff arm, want REARM 10", got)
	}
}

// (e) A user-present revoke queues nothing: ACTION_USER_PRESENT already clears the gate's idle state.
func TestColdLockRearmUserPresentRevokeQueuesNothing(t *testing.T) {
	rearmClear(t)
	dest, _, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	clwParked(t, p)
	if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
		t.Fatal("the unlock was rejected")
	}
	hold.give()
	rearmIdle(t)
	if clwExists(dest, ".coldlock") {
		t.Fatal("the lock committed -- this is not the revoked case")
	}
	if got := rearmField(); got != "" {
		t.Fatalf("a user-present revoke queued REARM %q", got)
	}
	if got := nextReapAction(); got != "NONE" {
		t.Fatalf("nextReapAction = %q, want NONE", got)
	}
}

// (f) A committed lock queues nothing.
func TestColdLockRearmCommittedLockQueuesNothing(t *testing.T) {
	rearmClear(t)
	dest, _, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	clwParked(t, p)
	hold.give()
	rearmIdle(t)
	if !clwExists(dest, ".coldlock") {
		t.Fatal("the lock did not commit")
	}
	if got := rearmField(); got != "" {
		t.Fatalf("a committed lock queued REARM %q", got)
	}
}
