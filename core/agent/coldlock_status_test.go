package main

import (
	"strings"
	"testing"
	"time"
)

// NWP-20261005-09: COLD-LOCK-STATUS tells the lock screen what a pending lock is waiting for. On frankel 0.5.41 an
// explicit lock queued behind a periodic seal and the screen said only "Locking…" for over five minutes.

func TestColdLockStatusLineStates(t *testing.T) {
	t.Cleanup(func() {
		coldLockWaitSince.Store(0)
		setRWHolder("")
		coldLockMu.Lock()
		coldLockRunning = false
		coldLockMu.Unlock()
	})
	now := time.UnixMilli(1_000_000_000)
	if got := coldLockStatusLine(now); got != "NONE" {
		t.Fatalf("no lock in flight: got %q, want NONE", got)
	}
	coldLockMu.Lock()
	coldLockRunning = true
	coldLockMu.Unlock()
	if got := coldLockStatusLine(now); got != "LOCKING" {
		t.Fatalf("a running, unqueued teardown: got %q, want LOCKING", got)
	}
	coldLockWaitSince.Store(now.UnixMilli() - 125_000)
	setRWHolder("out")
	if got := coldLockStatusLine(now); got != "WAITING out 125" {
		t.Fatalf("queued behind a seal: got %q, want %q", got, "WAITING out 125")
	}
	setRWHolder("")
	if got := coldLockStatusLine(now); got != "WAITING - 125" {
		t.Fatalf("queued between holders: got %q, want %q", got, "WAITING - 125")
	}
	coldLockWaitSince.Store(now.UnixMilli() + 5_000) // a wall clock that stepped back must not print a negative wait
	if got := coldLockStatusLine(now); got != "WAITING - 0" {
		t.Fatalf("clock stepped back: got %q, want %q", got, "WAITING - 0")
	}
}

// The real teardown, queued behind a seal that holds the RW slot, must report WAITING with that seal as the holder,
// and stop reporting it once it takes the slot. Driven through the same seams as coldlock_wait_order_test.go.
func TestColdLockStatusReportsTheRealWait(t *testing.T) {
	dest, _, hold := clwSetup(t)
	t.Cleanup(func() { setRWHolder(""); coldLockWaitSince.Store(0) })
	hold.take()
	setRWHolder("out") // what triggerRoamWorkerKind publishes for the periodic seal it is running
	parks := coldLockParks.Load()
	clwLock(t, dest, 0) // an explicit lock: the one whose screen is pinned
	clwParked(t, parks)
	got := coldLockStatusLine(time.Now())
	if !strings.HasPrefix(got, "WAITING out ") {
		t.Fatalf("queued behind the seal: got %q, want WAITING out <secs>", got)
	}
	setRWHolder("") // the seal releases, exactly as triggerRoamWorkerKind's defer does
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished after the slot was freed")
	}
	if got := coldLockStatusLine(time.Now()); got != "NONE" {
		t.Fatalf("after the lock: got %q, want NONE", got)
	}
	if op, _ := rwHolderOp.Load().(string); op != "" {
		t.Fatalf("the teardown released the slot but left itself as holder %q", op)
	}
}
