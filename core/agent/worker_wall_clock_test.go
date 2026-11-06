package main

import (
	"os"
	"regexp"
	"testing"
)

// TestWorkerTimersAreWallClock is the regression test for NWP-20260913-18.
//
// triggerRoamWorkerKind reports how long an op waited for, and held, the worker slot. Both stamps were bare
// time.Now(), so time.Since measured CLOCK_MONOTONIC -- which on Linux does NOT advance across suspend. On a
// phone whose screen has just gone off (which is precisely when a cold lock runs) suspend is most of the
// elapsed time, so every one of those durations understated reality by however long the phone slept.
//
// Measured on frankel 2026-09-13: one `out` op reported "HELD the slot 53164ms" while roamd's own wall
// stamps for the SAME op read 19:18:54 -> 19:22:35, i.e. 221s. Neither instrument was lying; they were
// different clocks printed on adjacent lines of one log. That is why the tester's complaint -- "cold lock
// took way too long" -- had never once appeared in any log as a long number, and why it read to us as fast.
//
// ⚠ WHY THIS IS A SOURCE TEST AND NOT A BEHAVIOURAL ONE. tLock and tHold are function locals, so there is
// nothing a test can observe at runtime, and there is no way to fast-forward a real suspend in a unit test
// anyway (the sibling ota_wall_clock_test.go says the same of its own case). What CAN be pinned is the
// invariant that makes the fix work: these two stamps must be wall-clock instants. If either Round(0) is
// "tidied" away -- which is exactly what the NWP-20260824-03 note above otaCacheTTL (main.go) warns against, having already been through this once
// -- this fails.
func TestWorkerTimersAreWallClock(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	for _, stamp := range []string{"tLock", "tHold"} {
		// The assignment must carry Round(0). Matching the assignment (not just "the name appears somewhere")
		// is what makes the mutation check meaningful.
		ok := regexp.MustCompile(`(?m)^\s*` + stamp + ` := time\.Now\(\)\.Round\(0\)`)
		bare := regexp.MustCompile(`(?m)^\s*` + stamp + ` := time\.Now\(\)\s*$`)
		if !ok.Match(src) {
			t.Errorf("%s is not assigned time.Now().Round(0) in main.go -- its duration would measure "+
				"CLOCK_MONOTONIC and silently exclude suspend (NWP-20260913-18; see the NWP-20260824-03 note above otaCacheTTL in main.go)", stamp)
		}
		if bare.Match(src) {
			t.Errorf("%s is assigned a BARE time.Now() in main.go -- that carries a monotonic reading "+
				"(NWP-20260913-18)", stamp)
		}
	}
}
