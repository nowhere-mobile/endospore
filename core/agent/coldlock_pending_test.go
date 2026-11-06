package main

import (
	"testing"
	"time"
)

// NWP-20261022-25: GET-COLDLOCK-PENDING names the session a running teardown is locking, but only while no unlock
// can revoke it. Every reply here goes through the daemon's own dispatcher (handleLogin), as the gate's does.

func pendingReply(t *testing.T, dest string) string {
	t.Helper()
	return driveLogin(t, dest, "GET-COLDLOCK-PENDING\n")
}

func getColdLockReply(t *testing.T, dest string) string {
	t.Helper()
	return driveLogin(t, dest, "GET-COLDLOCK\n")
}

// pendingClearUID runs after clwSetup's cleanup (cleanups are LIFO), which resets coldLockRunning without knowing
// the uid field.
func pendingClearUID(t *testing.T) {
	t.Helper()
	t.Cleanup(func() {
		coldLockMu.Lock()
		coldLockUID = ""
		coldLockMu.Unlock()
	})
}

func pendingUIDField() string {
	coldLockMu.Lock()
	defer coldLockMu.Unlock()
	return coldLockUID
}

// pendingDirectState plants the cold-lock state a test names and restores every field it set.
func pendingDirectState(t *testing.T, running bool, uid string, bellAt int64, revoking bool) {
	t.Helper()
	coldLockMu.Lock()
	pr, pu, pb, prv := coldLockRunning, coldLockUID, coldLockBellAt, coldLockRevoking
	coldLockRunning, coldLockUID, coldLockBellAt, coldLockRevoking = running, uid, bellAt, revoking
	coldLockMu.Unlock()
	t.Cleanup(func() {
		coldLockMu.Lock()
		coldLockRunning, coldLockUID, coldLockBellAt, coldLockRevoking = pr, pu, pb, prv
		coldLockMu.Unlock()
	})
}

func pendingWaitIdle(t *testing.T) {
	t.Helper()
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
}

// (a) an explicit lock queued behind a seal: no marker yet, so GET-COLDLOCK says NONE, and PENDING names the user.
func TestColdLockPendingNamesAnExplicitLockQueuedForTheSlot(t *testing.T) {
	pendingClearUID(t)
	dest, _, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	clwParked(t, p)
	if got := getColdLockReply(t, dest); got != "NONE" {
		t.Fatalf("GET-COLDLOCK during the wait = %q, want NONE (the premise of the row)", got)
	}
	if got := pendingReply(t, dest); got != "PENDING 10" {
		t.Fatalf("GET-COLDLOCK-PENDING during an explicit lock's wait = %q, want PENDING 10", got)
	}
	hold.give()
	pendingWaitIdle(t)
}

// (b) an idle lock is still abortable by an unlock: it keeps the #73 path.
func TestColdLockPendingIdleLockIsNotNamed(t *testing.T) {
	pendingClearUID(t)
	dest, _, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	clwParked(t, p)
	if !coldLockInFlight() {
		t.Fatal("no teardown is running -- NONE below would be vacuous")
	}
	if got := pendingReply(t, dest); got != "NONE" {
		t.Fatalf("GET-COLDLOCK-PENDING for an abortable idle lock = %q, want NONE", got)
	}
	hold.give()
	pendingWaitIdle(t)
}

// (c) an explicit lock folded into a queued idle one can no longer be revoked: named.
func TestColdLockPendingExplicitFoldIntoIdleIsNamed(t *testing.T) {
	pendingClearUID(t)
	dest, _, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	clwParked(t, p)
	clwLock(t, dest, 0)
	if got := pendingReply(t, dest); got != "PENDING 10" {
		t.Fatalf("GET-COLDLOCK-PENDING after an explicit lock folded into an idle one = %q, want PENDING 10", got)
	}
	hold.give()
	pendingWaitIdle(t)
}

// (d) once the teardown is over -- committed, or survived -- nothing is named and the uid field is cleared.
func TestColdLockPendingNoneAfterTheTeardown(t *testing.T) {
	t.Run("committed", func(t *testing.T) {
		pendingClearUID(t)
		dest, _, hold := clwSetup(t)
		hold.take()
		p := coldLockParks.Load()
		clwLock(t, dest, 0)
		clwParked(t, p)
		if got := pendingReply(t, dest); got != "PENDING 10" {
			t.Fatalf("during the wait = %q, want PENDING 10", got)
		}
		hold.give()
		pendingWaitIdle(t)
		if !clwExists(dest, ".coldlock") {
			t.Fatal("the lock never committed -- this is not the committed case")
		}
		if got := pendingReply(t, dest); got != "NONE" {
			t.Fatalf("after a committed teardown = %q, want NONE", got)
		}
		if u := pendingUIDField(); u != "" {
			t.Fatalf("coldLockUID = %q after the teardown, want it cleared", u)
		}
	})
	t.Run("survived", func(t *testing.T) {
		pendingClearUID(t)
		dest, _, hold := clwSetup(t)
		hold.take()
		p := coldLockParks.Load()
		clwLock(t, dest, 1000)
		clwParked(t, p)
		clwLock(t, dest, 0)
		if got := pendingReply(t, dest); got != "PENDING 10" {
			t.Fatalf("during the wait = %q, want PENDING 10", got)
		}
		seq := setLogoffInFlight("10")
		t.Cleanup(func() { clearLogoffInFlight("10", seq) })
		hold.give() // Check B sees the logoff and revokes: the session survives
		pendingWaitIdle(t)
		clearLogoffInFlight("10", seq)
		if clwExists(dest, ".coldlock") {
			t.Fatal("the lock committed -- this is not the survived case")
		}
		if got := pendingReply(t, dest); got != "NONE" {
			t.Fatalf("after a revoked teardown = %q, want NONE", got)
		}
		if u := pendingUIDField(); u != "" {
			t.Fatalf("coldLockUID = %q after the teardown, want it cleared", u)
		}
	})
}

// (e) a teardown that has decided to revoke leaves a LIVE session: not named.
func TestColdLockPendingRevokingIsNotNamed(t *testing.T) {
	dest := t.TempDir()
	pendingDirectState(t, true, "10", 0, false)
	if got := pendingReply(t, dest); got != "PENDING 10" {
		t.Fatalf("control (not revoking) = %q, want PENDING 10", got)
	}
	pendingDirectState(t, true, "10", 0, true)
	if got := pendingReply(t, dest); got != "NONE" {
		t.Fatalf("while revoking = %q, want NONE", got)
	}
}

// (f) a logoff in flight for the uid makes Check B revoke: not named. Direct state, because through a real teardown
// the waiter would also set coldLockRevoking and that alone would answer NONE.
func TestColdLockPendingLogoffInFlightIsNotNamed(t *testing.T) {
	dest := t.TempDir()
	pendingDirectState(t, true, "10", 0, false)
	other := setLogoffInFlight("11")
	t.Cleanup(func() { clearLogoffInFlight("11", other) })
	if got := pendingReply(t, dest); got != "PENDING 10" {
		t.Fatalf("control (a logoff for another uid) = %q, want PENDING 10", got)
	}
	clearLogoffInFlight("11", other)
	seq := setLogoffInFlight("10")
	t.Cleanup(func() { clearLogoffInFlight("10", seq) })
	if got := pendingReply(t, dest); got != "NONE" {
		t.Fatalf("with a logoff in flight for the uid = %q, want NONE", got)
	}
}

// (g) the verb answers while sessionMu is held (a prefix or a materialise holds it for minutes).
func TestColdLockPendingAnswersWhileSessionMuIsHeld(t *testing.T) {
	pendingDirectState(t, true, "10", 0, false)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if got := replyWhileHeld(t, 5*time.Second, "GET-COLDLOCK-PENDING\n", "GET-COLDLOCK-PENDING"); got != "PENDING 10" {
		t.Fatalf("GET-COLDLOCK-PENDING with sessionMu held = %q, want PENDING 10", got)
	}
}
