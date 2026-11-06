package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261013-03: a sign-in's restore (`in`) gets 15 minutes without a new progress line; every other op keeps
// roamStallTicks. A large real profile's silent post-#media stretch outgrew 150 s and the daemon reaped three
// sign-ins in a row while the worker was still working.
func TestSignInStallBudgetIsLongerThanEveryOtherOp(t *testing.T) {
	if got := workerStallTicks("in"); got != roamInStallTicks || got*500 < 15*60*1000 {
		t.Fatalf("workerStallTicks(\"in\") = %d ticks, want roamInStallTicks (%d) = at least 15 min", got, roamInStallTicks)
	}
	for _, op := range []string{"out", "odrestore", "materializeapp", "stageapp", "grant", "cleanstorage", ""} {
		if got := workerStallTicks(op); got != roamStallTicks {
			t.Fatalf("workerStallTicks(%q) = %d, want roamStallTicks (%d): only a sign-in gets the long budget", op, got, roamStallTicks)
		}
	}
}

// The budget is only real if runWorkerHeld USES it: pin that the watchdog reads the per-op value.
func TestRunWorkerHeldUsesThePerOpStallBudget(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "func runWorkerHeld(")
	if i < 0 {
		t.Fatal("runWorkerHeld not found")
	}
	body := src[i:]
	if j := strings.Index(body[1:], "\nfunc "); j > 0 {
		body = body[:j+1]
	}
	if !strings.Contains(body, "stallTicks := workerStallTicks(op)") {
		t.Fatal("runWorkerHeld no longer takes its stall budget from workerStallTicks(op)")
	}
	if !strings.Contains(body, "if idle >= stallTicks {") {
		t.Fatal("runWorkerHeld's stall check no longer reads stallTicks")
	}
}
