package main

import (
	"testing"
	"time"
)

// NWP-20260903-53. Chester, frankel 2026090320, after deleting a profile and re-creating the same name:
// "stuck at creating your space... for a while. Then your data shows when it was saved before deletion".
//
// The store side was clean -- nothing survived the purge. lastSealOKAt is a DAEMON-PROCESS global (its own
// comment: "0 = never this daemon lifetime") whose only writer is recordSeal, with no reset anywhere. The
// login daemon runs from boot across every login, so the next identity inherited the departed one's save
// time. That is a cross-identity leak, and this pins the reset that closes it.
func TestSessionStartClearsThePreviousSealSignals(t *testing.T) {
	dest := t.TempDir()

	// A previous session sealed successfully.
	lastSealStartedAt.Store(time.Now().Add(-time.Hour).Unix())
	lastSealOKAt.Store(time.Now().Add(-time.Hour).Unix())
	if lastSealOKAt.Load() == 0 {
		t.Fatal("setup failed: the departed session must look like it sealed")
	}

	// A DIFFERENT identity takes over the daemon -- a login, or a create after a delete.
	markSession(dest, "someone-else", "correct horse battery staple")

	if got := lastSealOKAt.Load(); got != 0 {
		t.Errorf("lastSealOKAt = %d after a new session began; the new identity can see the previous one's save time", got)
	}
	if got := lastSealStartedAt.Load(); got != 0 {
		t.Errorf("lastSealStartedAt = %d after a new session began", got)
	}

	// No separate check that the SCREEN stops showing it, and that is deliberate rather than an omission:
	// handleSealDelta assigns `r.LastOK = lastSealOKAt.Load()` (seal_delta.go) with no transformation,
	// so this atomic IS the rendered value. Driving handleSealDelta here would need a roam-session marker
	// and would test the plumbing, not the fix.
}
