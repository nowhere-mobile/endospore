package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// NWP-20261006-14: a session's plaintext mailbox does not outlive the session. Every row in it keeps a sealed pending
// copy (NWP-20261006-05), so once the session's Android user is gone the file is only plaintext at rest.

func mailboxNames(t *testing.T, dir string) []string {
	t.Helper()
	ents, _ := os.ReadDir(dir)
	var n []string
	for _, e := range ents {
		n = append(n, e.Name())
	}
	sort.Strings(n)
	return n
}

func plant(t *testing.T, dir string, names ...string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, n := range names {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("sms 1 0 0 - -\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSweepGoneMailboxesTakesOnlyEndedSessions(t *testing.T) {
	dir := useTempIngest(t)
	users := useTempUsersDir(t)
	if err := os.MkdirAll(filepath.Join(users, "11"), 0o700); err != nil { // user 11 is still live; 12 is gone
		t.Fatal(err)
	}
	tag := simTag(iccidX)
	plant(t, dir, "telingest.11", "telingest.11."+tag, "telingest.12", "telingest.12."+tag, "telingest.12."+tag+".tmp",
		"telingest.12.notatag", "seal-notice.12") // the last two are not mailboxes: never touched
	underTelMu(func() {
		if n := sweepGoneMailboxes(); n != 1 {
			t.Errorf("swept %d uids, want 1 (user 12)", n)
		}
	})
	got := strings.Join(mailboxNames(t, dir), " ")
	want := "seal-notice.12 telingest.11 telingest.11." + tag + " telingest.12.notatag"
	if got != want {
		t.Fatalf("after the sweep: %s\nwant: %s", got, want)
	}
}

// Off Android (no users dir to read) nothing is known to be gone, so nothing is deleted.
func TestSweepGoneMailboxesNeedsTheUsersDir(t *testing.T) {
	dir := useTempIngest(t)
	old := androidUsersDir
	androidUsersDir = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { androidUsersDir = old })
	plant(t, dir, "telingest.12")
	underTelMu(func() { sweepGoneMailboxes() })
	if len(mailboxNames(t, dir)) != 1 {
		t.Fatal("a mailbox was deleted with no users dir to decide from")
	}
}

// A sign-in's bring-up sweeps: whatever end a session took (a failed sign-in's user is removed without a
// CLEAN-STORAGE), its mailbox is gone by the next sign-in.
func TestBringUpSweepsEndedSessions(t *testing.T) {
	dir := useTempIngest(t)
	users := useTempUsersDir(t)
	os.MkdirAll(filepath.Join(users, "13"), 0o700)
	plant(t, dir, "telingest.12", "telingest.13")
	if err := beginTelStaging("13", false); err != nil {
		t.Fatal(err)
	}
	endTelStaging("13")
	if got := strings.Join(mailboxNames(t, dir), " "); got != "telingest.13" {
		t.Fatalf("after a bring-up: %q, want only the live session's mailbox", got)
	}
}

// CLEAN-STORAGE (the reap) removes the reaped uid's mailboxes and sweeps the rest, under telMu, before the worker.
func TestCleanStorageTakesTheMailbox(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `if name == "CLEAN-STORAGE" {`)
	if i < 0 {
		t.Fatal("CLEAN-STORAGE handler not found")
	}
	h := src[i:]
	h = h[:strings.Index(h, "\n\t}\n")]
	sweep := strings.Index(h, "removeMailboxes(uid)\n\t\t\t\tsweepGoneMailboxes()")
	worker := strings.Index(h, `triggerRoamWorker(dest, "cleanstorage"`)
	if sweep < 0 || worker < 0 || sweep > worker || !strings.Contains(h, "underTelMu(func() {") {
		t.Errorf("CLEAN-STORAGE must remove the reaped uid's mailboxes and sweep, under telMu, before the worker (%d, %d)", sweep, worker)
	}
}
