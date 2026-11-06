package main

import (
	"testing"
	"time"
)

// NWP-20260821-19. syncDeferReason is the extracted, pure form of syncLoop's "may I start a periodic seal
// now?" decision. It is tested rather than the loop because the loop sleeps for the whole sync interval
// before its first check, so nothing can drive it in a unit test -- which is exactly why the guard it is
// modelled on (odMaterializeUntil, #204) has had zero coverage since it landed.
//
// The property that matters is not any single case but the ORDER and the DEFAULT: every added guard must be
// deny-by-reason, and the absence of every reason must be the only path that proceeds.
func TestSyncDeferReason(t *testing.T) {
	now := time.Now()
	past := now.Add(-time.Second)
	future := now.Add(time.Minute)
	zero := time.Time{}

	for _, tc := range []struct {
		name        string
		sealBusy    bool
		od, log     time.Time
		want        string
		userWaiting int32
	}{
		{"idle proceeds", false, zero, zero, "", 0},
		{"expired windows proceed", false, past, past, "", 0},
		{"a seal in flight defers", true, zero, zero, "seal-in-flight", 0},
		{"a materialise window defers", false, future, zero, "materialise", 0},
		{"a login window defers", false, zero, future, "login", 0},

		// Precedence. sealInFlight is the pre-existing OUTERMOST guard and keeps priority; the login window
		// must never be able to mask a reason that already existed, because the CALLER increments the
		// login-deferred counter on the "login" reason alone and a mis-ordered switch would misattribute it.
		{"seal beats materialise", true, future, zero, "seal-in-flight", 0},
		{"seal beats login", true, zero, future, "seal-in-flight", 0},
		{"materialise beats login", false, future, future, "materialise", 0},

		// The boundary. now.Before(win) is exclusive, so a window whose deadline is exactly now has EXPIRED.
		// Pinned because the alternative (!After) would hold the window one whole cycle longer at the default
		// interval, and that difference is invisible in any log.
		{"a window ending exactly now has expired", false, zero, now, "", 0},

		// NWP-20260825-11: a user op already QUEUED for the worker defers the periodic seal. Chester's tap
		// waited 4m45s behind a background seal that had itself waited 2m; roam.req/res is a single slot, so
		// admission ORDER is the only lever. Ranked BELOW the three existing reasons on purpose: when a seal
		// is already in flight that is the more actionable line, and the caller counts "login" specifically.
		{"a queued user op defers", false, zero, zero, "user-op-waiting", 1},
		{"seal in flight beats a queued user op", true, zero, zero, "seal-in-flight", 3},
		{"login window beats a queued user op", false, zero, future, "login", 2},
	} {
		if got := syncDeferReason(now, tc.sealBusy, tc.od, tc.log, tc.userWaiting); got != tc.want {
			t.Errorf("%s: syncDeferReason(sealBusy=%v, od=%v, login=%v) = %q, want %q",
				tc.name, tc.sealBusy, tc.od, tc.log, got, tc.want)
		}
	}
}

// The login window MUST be bounded. syncLoop has no backstop of its own -- every guard is a bare `continue`,
// there is no skip counter and no "seal anyway after K misses" -- so a guard that could be held open forever
// would convert this latency fix into silent data loss on an unclean power-off, which is the exact failure
// the sync loop exists to bound.
//
// This asserts the two facts that make the bound real: the cap is finite, and it is the quantity actually
// armed. A future edit that swaps the cap for "no expiry" or re-arms in a loop fails here.
func TestLoginWindowIsBounded(t *testing.T) {
	if loginWindowCap <= 0 {
		t.Fatalf("loginWindowCap must be positive, got %v", loginWindowCap)
	}
	if loginWindowTail <= 0 || loginWindowTail >= loginWindowCap {
		t.Fatalf("loginWindowTail must be positive and shorter than the cap; tail=%v cap=%v",
			loginWindowTail, loginWindowCap)
	}
	// A window armed one cap ago must be expired -- i.e. the deadline is derived from the cap, not open-ended.
	armed := time.Now().Add(-loginWindowCap - time.Second)
	if r := syncDeferReason(time.Now(), false, time.Time{}, armed.Add(loginWindowCap), 0); r != "" {
		t.Errorf("a window armed longer ago than the cap still defers (%q) -- the cap is not bounding it", r)
	}
}

// A zero deadline must never defer. This is what makes the GRANT-PERMS clear safe to guard on IsZero: the
// verb is a plain socket command, so a replayed or out-of-login call must not be able to OPEN a suppression
// window from nothing, and the never-armed state must read as "proceed".
func TestZeroLoginWindowNeverDefers(t *testing.T) {
	if r := syncDeferReason(time.Now(), false, time.Time{}, time.Time{}, 0); r != "" {
		t.Errorf("a never-armed login window defers (%q); it must proceed", r)
	}
}

// NWP-20260825-11: a periodic seal must not be scheduled in front of a user op that is already QUEUED for
// the worker. Chester's tap waited 4m45s on workerMu behind a background seal that had itself waited 2m --
// roam.req/res is a single slot, so the only lever is admission ORDER.
func TestSyncDefersToAQueuedUserOp(t *testing.T) {
	if r := syncDeferReason(time.Now(), false, time.Time{}, time.Time{}, 1); r != "user-op-waiting" {
		t.Fatalf("a queued user op must defer the periodic seal, got %q", r)
	}
	if r := syncDeferReason(time.Now(), false, time.Time{}, time.Time{}, 0); r != "" {
		t.Fatalf("no waiter -> no deferral, got %q", r)
	}
	// Precedence: an in-flight seal still reports itself, not the waiter -- the caller distinguishes them and
	// "seal-in-flight" is the more actionable line when both are true.
	if r := syncDeferReason(time.Now(), true, time.Time{}, time.Time{}, 3); r != "seal-in-flight" {
		t.Fatalf("seal-in-flight must win, got %q", r)
	}
}
