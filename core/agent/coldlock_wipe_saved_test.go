package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261106-12 (Q138): EVICT-RECHECK-SAVED answers on the last save alone (coldlock_evict.go).

func TestSavedWipeDecision(t *testing.T) {
	if got := savedWipeDecision(true, "", "15"); got != "WIPE 15" {
		t.Errorf("saved: %q, want WIPE 15", got)
	}
	if got := savedWipeDecision(false, "never-saved", "15"); got != "KEEP UNSAVED never-saved" {
		t.Errorf("unsaved: %q, want KEEP UNSAVED never-saved", got)
	}
}

// savedSetup plants a cold-locked user 15 with a clean last save, and stubs the probe and the worker to count.
func savedSetup(t *testing.T) (dest string, calls *int) {
	t.Helper()
	asGate(t)
	dest = t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("alice\n15\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	n := 0
	prevCheck, prevStart := coldLockEvictCheck, workerStart
	coldLockEvictCheck = func(d, uid string) string { n++; return "OK EVICTED" }
	workerStart = func(svc string) { n++ }
	sealMu.Lock()
	prevStatus, prevParts := sealStatus, sealParts
	sealStatus, sealParts = "ok", ""
	sealMu.Unlock()
	prevOK := lastSealOKAt.Load()
	lastSealOKAt.Store(100)
	t.Cleanup(func() {
		coldLockEvictCheck, workerStart = prevCheck, prevStart
		sealMu.Lock()
		sealStatus, sealParts = prevStatus, prevParts
		sealMu.Unlock()
		lastSealOKAt.Store(prevOK)
	})
	return dest, &n
}

func askSaved(t *testing.T, dest, uid, want string, calls *int) {
	t.Helper()
	if got := evictConn(t, dest, "EVICT-RECHECK-SAVED\n"+uid+"\n"); got != want {
		t.Errorf("uid %q: reply %q, want %q", uid, got, want)
	}
	if *calls != 0 {
		t.Errorf("the probe or the worker ran %d times; this verb asks neither", *calls)
	}
}

func TestEvictRecheckSaved_NoMarkerIsGone(t *testing.T) {
	dest, calls := savedSetup(t)
	os.Remove(filepath.Join(dest, ".coldlock"))
	askSaved(t, dest, "15", "OK GONE", calls)
}

func TestEvictRecheckSaved_AnotherUidsMarkerIsGone(t *testing.T) {
	dest, calls := savedSetup(t)
	askSaved(t, dest, "16", "OK GONE", calls)
}

func TestEvictRecheckSaved_LiveSessionKeeps(t *testing.T) {
	dest, calls := savedSetup(t)
	if err := markRoamSession(dest, "bob", "pw2", "16", ""); err != nil {
		t.Fatal(err)
	}
	askSaved(t, dest, "15", "KEEP LIVE-SESSION 16", calls)
}

func TestEvictRecheckSaved_CleanSaveWipes(t *testing.T) {
	dest, calls := savedSetup(t)
	askSaved(t, dest, "15", "WIPE 15", calls)
	// The decision claims nothing: the wipe's own CLAIM-COLDLOCK does.
	if _, err := os.Stat(filepath.Join(dest, ".coldlock")); err != nil {
		t.Errorf("the marker is gone after the verb: %v", err)
	}
}

func TestEvictRecheckSaved_UnsavedKeeps(t *testing.T) {
	t.Run("never-saved", func(t *testing.T) {
		dest, calls := savedSetup(t)
		lastSealOKAt.Store(0)
		askSaved(t, dest, "15", "KEEP UNSAVED never-saved", calls)
	})
	t.Run("local-only", func(t *testing.T) {
		dest, calls := savedSetup(t)
		markLocalSession(dest)
		askSaved(t, dest, "15", "KEEP UNSAVED local-only", calls)
	})
	t.Run("partial", func(t *testing.T) {
		dest, calls := savedSetup(t)
		sealMu.Lock()
		sealParts = "apps=refused"
		sealMu.Unlock()
		askSaved(t, dest, "15", "KEEP UNSAVED last-save-partial", calls)
	})
}

func TestEvictRecheckSaved_RefusesABadUid(t *testing.T) {
	dest, calls := savedSetup(t)
	for _, u := range []string{"0", "9", "x", ""} {
		askSaved(t, dest, u, "ERR-UID", calls)
	}
}
