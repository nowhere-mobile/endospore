package main

import "testing"

// The no-reboot teardown hands the user-0 chooser its work in phases: SWITCH (to the gate, fast, before the
// S3 seal), then REAP (remove the user, after the seal). SWITCH wins if both are pending.
//
// DIA-20260814-05 (#141) changed the DELIVERY CONTRACT from at-most-once to AT-LEAST-ONCE, and this test was
// rewritten with it. It used to assert "handed out exactly once" -- which is precisely the property that
// stranded a user on hardware: the reply was the only copy, so a POLL-REAP whose reply never reached the
// watcher (client read timeout while the daemon held sessionMu) dropped the step forever, and the phone sat
// on "Profile deleted" while the daemon believed the teardown had been collected. A phase now stays queued
// until the watcher ACKS having performed it, so a lost reply is simply redelivered on the next 250ms poll.
func TestNextReapActionRedeliversUntilAcked(t *testing.T) {
	reset := func() {
		pendingReapMu.Lock()
		pendingSwitchUID, pendingReapUID, pendingLockUID, pendingRearmUID = "", "", "", ""
		pendingReapMu.Unlock()
	}
	reset()
	defer reset()

	if got := nextReapAction(); got != "NONE" {
		t.Fatalf("idle: got %q want NONE", got)
	}

	// logout queues the SWITCH first (the gate reclaims the foreground before the seal)
	pendingReapMu.Lock()
	pendingSwitchUID = "10"
	pendingReapMu.Unlock()

	// REDELIVERED while unacked -- this is the whole point: a dropped reply must not lose the step.
	for i := 0; i < 3; i++ {
		if got := nextReapAction(); got != "SWITCH 10" {
			t.Fatalf("poll %d before ack: got %q want SWITCH 10", i, got)
		}
	}
	// A stale ack (some earlier session's uid) must NOT retire the live phase.
	ackReapAction("SWITCH", "9")
	if got := nextReapAction(); got != "SWITCH 10" {
		t.Fatalf("after stale ack: got %q want SWITCH 10", got)
	}
	ackReapAction("SWITCH", "10")
	if got := nextReapAction(); got != "NONE" {
		t.Fatalf("after ack: got %q want NONE", got)
	}

	// after the seal completes, the REAP is queued -- same redeliver-until-acked contract
	pendingReapMu.Lock()
	pendingReapUID = "10"
	pendingReapMu.Unlock()
	if got := nextReapAction(); got != "REAP 10" {
		t.Fatalf("got %q want REAP 10", got)
	}
	if got := nextReapAction(); got != "REAP 10" {
		t.Fatalf("REAP must redeliver until acked: got %q", got)
	}
	ackReapAction("REAP", "10")
	if got := nextReapAction(); got != "NONE" {
		t.Fatalf("after REAP ack: got %q want NONE", got)
	}

	// If both are pending, SWITCH takes priority and REAP is not offered until SWITCH is acked -- which is
	// what stops a fast second poll from removing a user whose switch is still in flight.
	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID = "11", "11"
	pendingReapMu.Unlock()
	if got := nextReapAction(); got != "SWITCH 11" {
		t.Fatalf("priority: got %q want SWITCH 11", got)
	}
	if got := nextReapAction(); got != "SWITCH 11" {
		t.Fatalf("REAP must NOT jump ahead of an unacked SWITCH: got %q", got)
	}
	ackReapAction("SWITCH", "11")
	if got := nextReapAction(); got != "REAP 11" {
		t.Fatalf("then: got %q want REAP 11", got)
	}

	// LOCK (P3 cold-lock) follows the same rules once the earlier phases are retired.
	ackReapAction("REAP", "11")
	pendingReapMu.Lock()
	pendingLockUID = "12"
	pendingReapMu.Unlock()
	if got := nextReapAction(); got != "LOCK 12" {
		t.Fatalf("got %q want LOCK 12", got)
	}
	ackReapAction("LOCK", "12")
	if got := nextReapAction(); got != "NONE" {
		t.Fatalf("after LOCK ack: got %q want NONE", got)
	}
}
