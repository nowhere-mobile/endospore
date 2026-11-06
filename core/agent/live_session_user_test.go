package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261006-02: an arrival goes live only to a session whose Android user still exists. A marker naming a removed
// user (a sign-in or resume the chooser abandoned while the daemon finished it) used to take every later arrival for
// that profile into the dead uid's mailbox, with its gate notice suppressed.
func useTempUsersDir(t *testing.T) string {
	t.Helper()
	old := androidUsersDir
	androidUsersDir = t.TempDir()
	t.Cleanup(func() { androidUsersDir = old })
	if err := os.MkdirAll(filepath.Join(androidUsersDir, "0"), 0o700); err != nil {
		t.Fatal(err)
	}
	return androidUsersDir
}

func TestLiveSessionRequiresAnExistingUser(t *testing.T) {
	users := useTempUsersDir(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if n, _, u := liveSession(dest); n != "" || u != "" {
		t.Fatalf("a marker naming a removed user 10 is a live session (%q %q) -- arrivals would go to a dead mailbox", n, u)
	}
	if err := os.MkdirAll(filepath.Join(users, "10"), 0o700); err != nil {
		t.Fatal(err)
	}
	if n, _, u := liveSession(dest); n != "alice" || u != "10" {
		t.Fatalf("user 10 exists, but liveSession = %q %q", n, u)
	}
}

// Fail open: with no users dir to look in, nothing is known to be gone, so the session stays live as before.
func TestLiveSessionWithoutAUsersDirIsUnchanged(t *testing.T) {
	old := androidUsersDir
	androidUsersDir = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { androidUsersDir = old })
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if n, _, u := liveSession(dest); n != "alice" || u != "10" {
		t.Fatalf("no users dir: liveSession = %q %q, want the marker's session", n, u)
	}
}

// End to end through the arrival hand-off: a bound owner whose session marker names a removed user is SEALED to the
// inbox (delivered at the next login, with the gate notice), not appended to the dead uid's mailbox.
func TestArrivalForADeadSessionSealsInsteadOfGoingLive(t *testing.T) {
	useTempUsersDir(t)
	useTempInbox(t)
	useTempIngest(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	v, _ := vaultWithTelKey(t)
	b := simBinding{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open",
		Owners: []bindingOwner{{profileRefV2("alice", "pw"), v.TelPub}}}
	sealed, appended, kick := deliverToOwners(dest, b, testSMS)
	if appended != "" || kick {
		t.Fatalf("the arrival went live to removed user %q (kick=%v)", appended, kick)
	}
	if sealed != 1 {
		t.Fatalf("sealed to %d owner(s), want 1 -- with no live session it must be kept in the inbox", sealed)
	}
	if fs := mailboxFiles("10"); len(fs) != 0 {
		t.Fatalf("a mailbox was written for the removed user: %v", fs)
	}
}
