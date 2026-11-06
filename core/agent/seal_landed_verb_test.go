package main

import (
	"fmt"
	"testing"
	"time"
)

// NWP-20261117-27: GET-SEAL-LANDED answers "OK <unix seconds>", the announce stamp of the last seal that landed OK
// this session (lastLandedSealStartedAt). The chooser's back-online watcher clears its "Back up now" prompt only once
// that stamp is at or after the reconnect (BackNowCycle), never on GET-SYNC-STATUS's OK, which is the last verdict.

// sealLandedGlobals saves the seal signals resetSealSignals clears and restores them when the test ends. It also
// shortens handleLogin's connection deadline: a daemon without the verb falls through to the legacy login, which
// waits for more lines until that deadline, so the test fails within seconds there instead of timing out.
func sealLandedGlobals(t *testing.T) {
	t.Helper()
	oldDeadline := loginConnDeadline
	loginConnDeadline = 2 * time.Second
	oldStart, oldOK, oldLanded := lastSealStartedAt.Load(), lastSealOKAt.Load(), lastLandedSealStartedAt.Load()
	oldBytes, oldAreas, oldDefer := lastSaveBytes.Load(), lastSaveAreas.Load(), sealDeferCount.Load()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() {
		loginConnDeadline = oldDeadline
		lastSealStartedAt.Store(oldStart)
		lastSealOKAt.Store(oldOK)
		lastLandedSealStartedAt.Store(oldLanded)
		lastSaveBytes.Store(oldBytes)
		lastSaveAreas.Store(oldAreas)
		sealDeferCount.Store(oldDefer)
	})
}

func TestGetSealLanded(t *testing.T) {
	sealLandedGlobals(t)
	ask := func() string { return driveLogin(t, t.TempDir(), "GET-SEAL-LANDED\n") }

	resetSealSignals()
	if got := ask(); got != "OK 0" {
		t.Fatalf("GET-SEAL-LANDED after resetSealSignals replied %q, want OK 0", got)
	}
	s := time.Now().Unix() - 30
	noteSealLanded(s, "OK")
	if got, want := ask(), fmt.Sprintf("OK %d", s); got != want {
		t.Fatalf("GET-SEAL-LANDED after an OK seal replied %q, want %q", got, want)
	}
	noteSealLanded(s+10, "ERR-PUSH")
	if got, want := ask(), fmt.Sprintf("OK %d", s); got != want {
		t.Fatalf("GET-SEAL-LANDED after a failed seal replied %q, want the last landed stamp %q", got, want)
	}
	noteSealLanded(s+20, "OK PARTIAL:apps=refused")
	if got, want := ask(), fmt.Sprintf("OK %d", s+20); got != want {
		t.Fatalf("GET-SEAL-LANDED after an OK PARTIAL seal replied %q, want %q", got, want)
	}
}

// TestGetSealLandedRunsUnderSessionMu: the watcher's 5 s poll must not wait behind a materialise or a sign-in.
func TestGetSealLandedRunsUnderSessionMu(t *testing.T) {
	if !concurrentSafeCmd("GET-SEAL-LANDED") {
		t.Errorf("GET-SEAL-LANDED is not on the lock-free allowlist (concurrentSafeCmd)")
	}
	sealLandedGlobals(t)
	resetSealSignals()
	s := time.Now().Unix() - 30
	noteSealLanded(s, "OK")
	func() {
		sessionMu.Lock()
		defer sessionMu.Unlock()
		if got := replyWhileHeld(t, 5*time.Second, "GET-SEAL-LANDED\n", "GET-SEAL-LANDED"); got != fmt.Sprintf("OK %d", s) {
			t.Fatalf("GET-SEAL-LANDED while sessionMu is held replied %q, want OK %d", got, s)
		}
	}()
}
