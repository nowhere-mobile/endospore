package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261010-07: CLEAR-COLDLOCK is sent by the chooser AFTER a new session has signed in over a parked cold lock,
// so it must leave that session's markers alone. It used to remove .localsession, which turned a throwaway (a
// mistyped passphrase, a chip-locked profile) into a session whose seals run against the store.
func TestClearColdLockKeepsTheNewSessionLocal(t *testing.T) {
	gatePeer(t, 10123)
	for _, tc := range []struct {
		name    string
		offline bool
	}{{"online throwaway", false}, {"offline sign-in", true}} {
		t.Run(tc.name, func(t *testing.T) {
			dest := t.TempDir()
			// The superseded session's cold lock, still parked: the new ROAM-IN removes it itself, but the chooser
			// clears it again, and the verb must still do that part.
			if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("15\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			markLocalSession(dest) // what ROAM-IN's throwaway arm (and ROAM-IN-OFFLINE) wrote for the new session
			if tc.offline {
				markOfflineSession(dest)
			}
			if got := evictConn(t, dest, "CLEAR-COLDLOCK\n"); got != "OK" {
				t.Fatalf("CLEAR-COLDLOCK replied %q, want OK", got)
			}
			if clwExists(dest, ".coldlock") {
				t.Error("CLEAR-COLDLOCK left the cold-lock marker -- GET-COLDLOCK would still offer \"Welcome back\"")
			}
			if !isLocalSession(dest) {
				t.Error("CLEAR-COLDLOCK removed the live session's .localsession -- a throwaway's periodic and " +
					"logoff seals would now run against the store (a typo becomes a stored profile)")
			}
			if tc.offline && !isOfflineSession(dest) {
				t.Error("CLEAR-COLDLOCK removed the live session's .offlinesession")
			}
		})
	}
}
