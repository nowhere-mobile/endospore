package main

import "testing"

// NWP-20261113-18: a sign-out whose seal stopped making progress -- runWorkerHeld's stall backstop (ERR-TIMEOUT) or
// the logoff stall watchdog (ERR-STALLED) -- answers SEAL-STATUS "FAILED TIMEOUT", so the chooser stops telling the
// user the store was out of reach. The match is on the exact verb: PARTIAL detail is stripped, ERR-TIMEOUTX is not
// a timeout, and every other verdict reads as it did before.
func TestSealStatusTimeout(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	pendingReapMu.Lock()
	f0, w0, r0, i0, k0, p0 := sealFail, sealFailWhy, sealFailReason, sealInFlight, sealRunKind, sealPartial
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		resetSealStatus()
		pendingReapMu.Lock()
		sealFail, sealFailWhy, sealFailReason, sealInFlight, sealRunKind, sealPartial = f0, w0, r0, i0, k0, p0
		pendingReapMu.Unlock()
	})

	for _, c := range []struct{ verdict, want string }{
		{"ERR-TIMEOUT", "FAILED TIMEOUT"},
		{"ERR-TIMEOUT PARTIAL:apps=refused", "FAILED TIMEOUT"},
		{"ERR-PUSH", "FAILED"},
		{"ERR-REFUSED", "FAILED REFUSED"},
		{"ERR-TIMEOUTX", "FAILED"},
	} {
		failLogoff(t, c.verdict, "")
		if got := sealStatusWire(t); got != c.want {
			t.Errorf("SEAL-STATUS after a logoff verdict %q = %q, want %q", c.verdict, got, c.want)
		}
	}

	// ERR-STALLED is set by the logoff stall watchdog in handleLogout, not by logoffSealFailed: set the fields as it does.
	resetSealStatus()
	pendingReapMu.Lock()
	sealInFlight, sealRunKind = false, ""
	sealFail, sealFailWhy, sealFailReason = true, "ERR-STALLED", ""
	pendingReapMu.Unlock()
	if got := sealStatusWire(t); got != "FAILED TIMEOUT" {
		t.Errorf("SEAL-STATUS after the logoff stall watchdog (ERR-STALLED) = %q, want %q", got, "FAILED TIMEOUT")
	}
}
