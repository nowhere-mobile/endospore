package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260822-05. markIncomplete fires when a deferred dir has to be recreated at serve time, and that has
// TWO causes with opposite severities:
//
//   - a benign #92 scar   -- only the dir ENTRY was lost; the bytes are intact in the store; nothing is wrong
//   - a short #media come-down -- the app's essential runtime files really are missing and it dies at launch
//
// mediad cannot tell them apart locally (that would need a store round-trip #84 removed from the login path),
// so it has always surfaced BOTH -- which is why an unknown fraction of #80 "Some data didn't finish loading"
// reports have no network cause at all, and why #80 could not be MEASURED against any network change.
//
// The restore already knows: it reaches its clean end only with everything written, and a short restore dies
// via fail() before that. These tests pin the one bit being carried across, and — more importantly — pin the
// FAIL-DIRECTION, because the whole design rests on it.
func TestMediaRestoreWasClean(t *testing.T) {
	dir := t.TempDir()

	// Absent: the restore never finished (or never ran). Must read as NOT clean -- i.e. today's behaviour,
	// where every recreated dir is surfaced. This is the case that keeps the change strictly additive.
	if mediaRestoreWasClean(dir) {
		t.Error("an ABSENT receipt must read as not-clean; otherwise a died-mid-restore session would be " +
			"silently downgraded to a benign scar -- the one direction this must never fail in")
	}

	// Present and clean.
	if err := os.WriteFile(filepath.Join(dir, mediaRestoreOKFile), []byte("ok\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !mediaRestoreWasClean(dir) {
		t.Error("a written receipt must read as clean")
	}

	// Garbage must NOT read as clean. A truncated or half-written file is not evidence of completion.
	for _, junk := range []string{"", "\n", "no", "okish-but-not", "err short"} {
		if err := os.WriteFile(filepath.Join(dir, mediaRestoreOKFile), []byte(junk), 0o600); err != nil {
			t.Fatal(err)
		}
		if mediaRestoreWasClean(dir) {
			t.Errorf("receipt %q must not read as clean", junk)
		}
	}

	// No state dir configured (unit tests, a mediad without NOWHERE_STATE) must also be not-clean, never a
	// silent "assume fine".
	if mediaRestoreWasClean("") {
		t.Error("an empty state dir must read as not-clean")
	}
}

// The severity split itself: with a clean receipt a recreated dir must NOT raise the user-facing INCOMPLETE,
// and without one it must. This is the behaviour #80 is measured by, so it is pinned directly rather than
// inferred from the reader above.
func TestMarkIncompleteHonoursTheReceipt(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)

	// No receipt -> a real short restore is assumed -> INCOMPLETE is raised (pre-change behaviour).
	s := &mediaServer{}
	s.markIncomplete("com.example.app")
	if !s.incomplete["com.example.app"] {
		t.Fatal("without a clean receipt, a recreated dir must still raise INCOMPLETE")
	}

	// Clean receipt -> benign scar -> NOT raised.
	if err := os.WriteFile(filepath.Join(dir, mediaRestoreOKFile), []byte("ok\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s2 := &mediaServer{}
	s2.markIncomplete("com.example.app")
	if s2.incomplete["com.example.app"] {
		t.Fatal("with a clean restore receipt, a recreated dir is a #92 scar and must NOT raise INCOMPLETE")
	}
	if !s2.scarLogged["com.example.app"] {
		t.Error("the scar path must still be logged once -- silent is not the same as benign")
	}
}
