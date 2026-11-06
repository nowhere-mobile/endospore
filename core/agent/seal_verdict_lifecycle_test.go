package main

import "testing"

// NWP-20261005-26: the seal verdict's lifecycle across a failed logoff and the next session.
//
// (a) A failed logoff keeps the session signed in and re-arms its marker. The re-arm used to go through the
// new-session reset, which wiped the FAILED verdict logoffSealFailed had just recorded, so GET-SYNC-STATUS read OK
// for a session that had just failed to seal and SEAL-STATUS lost its cause.
// (b) A session that never seals at logoff (a throwaway, an offline sign-in) read an EARLIER session's FAILED,
// because only a sealing logoff cleared it.
func resetVerdictGlobals(t *testing.T) {
	t.Helper()
	pendingReapMu.Lock()
	sealFail, sealFailWhy, sealPartial, sealInFlight, sealRunKind = false, "", "", false, ""
	pendingReapMu.Unlock()
	sealMu.Lock()
	sealStatus, sealParts, sealReason = "", "", ""
	sealMu.Unlock()
}

func TestFailedLogoffVerdictSurvivesTheRearm(t *testing.T) {
	resetVerdictGlobals(t)
	t.Cleanup(func() { resetVerdictGlobals(t) })
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	logoffSealFailed("ERR-TIMEOUT")
	rearmRoamSession(dest, "alice", "pw", "10", "", "logout seal failed, re-arm")
	if got := sealStatusGet(); got != "fail" {
		t.Errorf("GET-SYNC-STATUS verdict after a failed logoff and its re-arm = %q, want fail", got)
	}
	pendingReapMu.Lock()
	f, why := sealFail, sealFailWhy
	pendingReapMu.Unlock()
	if !f || why != "ERR-TIMEOUT" {
		t.Errorf("SEAL-STATUS after the re-arm: failed=%v why=%q, want true/ERR-TIMEOUT", f, why)
	}
	if n, _, u := readRoamSession(dest); n != "alice" || u != "10" {
		t.Fatalf("the re-arm did not rewrite the marker: %q %q", n, u)
	}
}

func TestNewSessionClearsAnEarlierLogoffFailure(t *testing.T) {
	resetVerdictGlobals(t)
	t.Cleanup(func() { resetVerdictGlobals(t) })
	logoffSealFailed("ERR-REFUSED")
	// A different session starts -- a throwaway's roam-in writes its marker exactly this way.
	if err := markRoamSession(t.TempDir(), "someone-else", "pw2", "11", ""); err != nil {
		t.Fatal(err)
	}
	pendingReapMu.Lock()
	f, why, part := sealFail, sealFailWhy, sealPartial
	pendingReapMu.Unlock()
	if f || why != "" || part != "" {
		t.Errorf("an earlier session's logoff failure reached the new session: failed=%v why=%q partial=%q", f, why, part)
	}
	if got := sealStatusGet(); got != "" {
		t.Errorf("new session verdict = %q, want empty (current as of restore)", got)
	}
}
