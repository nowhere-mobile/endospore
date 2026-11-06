package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261005-10: GET-SESSION-PIN and ARM-PIN run outside sessionMu, so the stash is published by rename. It must
// round-trip, replace an older PIN, leave no temp file behind, and an empty PIN must remove it.
func TestStashSessionPINPublishesByRename(t *testing.T) {
	dest := t.TempDir()
	stashSessionPIN(dest, "1234")
	if got := sessionPIN(dest); got != "1234" {
		t.Fatalf("stash read back %q, want 1234", got)
	}
	stashSessionPIN(dest, "98765")
	if got := sessionPIN(dest); got != "98765" {
		t.Fatalf("restash read back %q, want 98765", got)
	}
	if _, err := os.Stat(filepath.Join(dest, ".sessionpin.tmp")); !os.IsNotExist(err) {
		t.Fatalf("the temp file was left behind (err %v)", err)
	}
	if fi, err := os.Stat(filepath.Join(dest, ".sessionpin")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("stash must be 0600: %v %v", fi, err)
	}
	stashSessionPIN(dest, "")
	if got := sessionPIN(dest); got != "" {
		t.Fatalf("an empty PIN must clear the stash, read %q", got)
	}
}
