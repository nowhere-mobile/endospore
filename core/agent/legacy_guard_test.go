package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261019-16: legacy LOGOFF and the legacy-login fallthrough wipe the shared roam state (wipeSessionState), so
// both refuse while a roamed session is live or a cold lock is parked. The parked rule is refuseCreateOverColdLock's,
// gone-user exception included.

// usersWith redirects androidUsersDir to a temp dir holding the given user dirs.
func usersWith(t *testing.T, uids ...string) {
	t.Helper()
	d := t.TempDir()
	for _, u := range uids {
		if err := os.Mkdir(filepath.Join(d, u), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	old := androidUsersDir
	androidUsersDir = d
	t.Cleanup(func() { androidUsersDir = old })
}

func plantFile(t *testing.T, dest, rel string) string {
	t.Helper()
	p := filepath.Join(dest, rel)
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLegacyLogoffRefusedWhileRoamedSessionLive(t *testing.T) {
	dest := t.TempDir()
	writeMarker(t, dest, "alice\npass\n12\n")
	wallet := plantFile(t, dest, "wallet.json")
	state := plantFile(t, dest, "somestate")
	if got := driveLogin(t, dest, "LOGOFF\n"); got != "BUSY" {
		t.Fatalf("LOGOFF reply %q, want BUSY", got)
	}
	mustExist(t, ".roamsession", filepath.Join(dest, ".roamsession"))
	mustExist(t, "wallet.json", wallet)
	mustExist(t, "the state file", state)
}

func TestLegacyLogoffRefusedWhileColdLockParked(t *testing.T) {
	usersWith(t, "12")
	dest := t.TempDir()
	check := parkColdLock(t, dest)
	if got := driveLogin(t, dest, "LOGOFF\n"); got != "BUSY" {
		t.Fatalf("LOGOFF reply %q, want BUSY", got)
	}
	check("a refused LOGOFF")
}

func TestLegacyLogoffProceedsWhenColdLockUserGone(t *testing.T) {
	usersWith(t, "7") // users dir exists, user 12 does not
	dest := t.TempDir()
	parkColdLock(t, dest)
	blob, mailbox := seedTelSubtree(t, dest)
	if got := driveLogin(t, dest, "LOGOFF\n"); got != "OK" {
		t.Fatalf("LOGOFF reply %q, want OK", got)
	}
	mustExist(t, "the sealed blob", blob)
	mustExist(t, "the mailbox", mailbox)
	if _, err := os.Stat(filepath.Join(dest, ".coldlock")); !os.IsNotExist(err) {
		t.Fatalf("LOGOFF left the gone user's .coldlock (err %v)", err)
	}
}

func TestLegacyLoginFallthroughRefusedWhileColdLockParked(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	usersWith(t, "12")
	dest := t.TempDir()
	check := parkColdLock(t, dest)
	if got := driveLogin(t, dest, "someone-else\nsome passphrase\n"); got != "BLANK" {
		t.Fatalf("legacy login reply %q, want BLANK", got)
	}
	check("a refused legacy login")
	if _, err := os.Stat(filepath.Join(dest, ".session")); err == nil {
		t.Fatal("the refused legacy login restored a session")
	}
}
