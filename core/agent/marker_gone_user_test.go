package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261006-15: a session marker that names a user who no longer exists (an abandoned sign-in or resume) is cleared
// by the periodic seal loop and by every reap, so nothing seals or reports on behalf of a session that is gone.

func TestClearMarkerOfGoneUser(t *testing.T) {
	users := useTempUsersDir(t)
	os.MkdirAll(filepath.Join(users, "11"), 0o700)
	for _, c := range []struct {
		uid, want string
		kept      bool
	}{
		{"12", "12", false}, // gone: cleared
		{"11", "", true},    // live: kept
	} {
		dest := t.TempDir()
		if err := markRoamSession(dest, "alice", "pw", c.uid, ""); err != nil {
			t.Fatal(err)
		}
		got := clearMarkerOfGoneUser(dest)
		_, err := os.Stat(filepath.Join(dest, roamSessionFile))
		if got != c.want || (err == nil) != c.kept {
			t.Errorf("marker for user %s: cleared %q, still there %v; want cleared %q, kept %v", c.uid, got, err == nil, c.want, c.kept)
		}
	}
	if got := clearMarkerOfGoneUser(t.TempDir()); got != "" {
		t.Errorf("no marker at all reported clearing %q", got)
	}
}

// Off Android (no users dir) nothing is known to be gone: the marker stays.
func TestClearMarkerKeepsItWithoutTheUsersDir(t *testing.T) {
	old := androidUsersDir
	androidUsersDir = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { androidUsersDir = old })
	dest := t.TempDir()
	markRoamSession(dest, "alice", "pw", "12", "")
	if clearMarkerOfGoneUser(dest) != "" {
		t.Fatal("a marker was cleared with no users dir to decide from")
	}
}

// The wiring: the seal loop clears (under a TryLock of sessionMu) BEFORE it reads the marker to seal; the reap clears
// too; and OTA-NOTES never waits on sessionMu.
func TestGoneUserMarkerIsClearedWhereItMatters(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	loop := src[strings.Index(src, "func syncLoop(dest string) {"):]
	tl, cl, rd := strings.Index(loop, "if sessionMu.TryLock() {"), strings.Index(loop, "clearMarkerOfGoneUser(dest)"),
		strings.Index(loop, "name, pass, uid := readRoamSession(dest)")
	if tl < 0 || cl < 0 || rd < 0 || !(tl < cl && cl < rd) {
		t.Errorf("syncLoop must TryLock sessionMu and clear a gone user's marker before it reads the marker (%d, %d, %d)", tl, cl, rd)
	}
	cs := src[strings.Index(src, `if name == "CLEAN-STORAGE" {`):]
	cs = cs[:strings.Index(cs, `triggerRoamWorker(dest, "cleanstorage"`)]
	if !strings.Contains(cs, "clearMarkerOfGoneUser(dest)") {
		t.Error("CLEAN-STORAGE no longer clears a marker that names a gone user")
	}
	if !concurrentSafeCmd("OTA-NOTES") {
		t.Error("OTA-NOTES waits on sessionMu: the What's new popup would block behind any login or seal")
	}
}
