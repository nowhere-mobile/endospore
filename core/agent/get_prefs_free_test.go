package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestGetPrefsAnswersWhileSessionMuHeld (NWP-20261118-11): GET-PREFS answers prefs.out while sessionMu is held --
// the frankel 0.5.49 state, where GRANT-PERMS held it for the 122.55 s grant op and the gate's read timed out, so
// the session ran on the defaults. The 5 s is a hang guard, not a bound on how fast the reply comes.
func TestGetPrefsAnswersWhileSessionMuHeld(t *testing.T) {
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, "prefs.out"), []byte("idle=0\ntz=\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	sessionMu.Lock()
	held := true
	defer func() {
		if held {
			sessionMu.Unlock()
		}
	}()
	c := driveLoginAsync(t, dest, "GET-PREFS\n")
	select {
	case got := <-c:
		if got != "idle=0\ntz=" {
			t.Fatalf("GET-PREFS with sessionMu held answered %q, want the prefs.out lines idle=0 and tz=", got)
		}
	case <-time.After(5 * time.Second):
		sessionMu.Unlock()
		held = false
		<-c
		t.Fatal("GET-PREFS waited on sessionMu: no reply in 5 s while the test held it (NWP-20261118-11)")
	}
}
