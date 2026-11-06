package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261101-01 (Q183): a cold lock that crosses its point of no return removes roamd's keystore-push stash
// (ks-logoff-creds: the session's name and passphrase in the clear) itself, whatever the btpark worker step answers.
// Since NWP-20261022-02 that step answers busy while an abandoned op still runs, and the lock completes anyway.

// kscPlant writes a stash in the shape roamd's `out` writes it.
func kscPlant(t *testing.T, dest string) string {
	t.Helper()
	p := filepath.Join(dest, ksLogoffCredsFile)
	if err := os.WriteFile(p, []byte("kscreds-alice\nkscreds-pw\n10\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// kscCommit runs one explicit cold lock to its end with btpark answering btpark.
func kscCommit(t *testing.T, dest string, rec *clwRecorder, btpark string) {
	t.Helper()
	rec.ret = func(op string, _ int) string {
		if op == "btpark" {
			return btpark
		}
		return ""
	}
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("control failed: the lock did not commit, so nothing below proves anything about the point of no return")
	}
	if rec.count["btpark"] != 1 {
		t.Fatalf("btpark ran %d times, want 1", rec.count["btpark"])
	}
}

func TestColdLockKsCredsGoneWhenBtparkAnswersBusy(t *testing.T) {
	dest, rec, _ := clwSetup(t)
	p := kscPlant(t, dest)
	kscCommit(t, dest, rec, "BUSY")
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("ks-logoff-creds survived a committed cold lock whose btpark answered BUSY (stat err %v): the passphrase stays in cleartext for the whole lock", err)
	}
}

func TestColdLockKsCredsGoneWhenBtparkAnswersOK(t *testing.T) {
	dest, rec, _ := clwSetup(t)
	p := kscPlant(t, dest)
	kscCommit(t, dest, rec, "OK")
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("ks-logoff-creds survived a committed cold lock whose btpark answered OK (stat err %v)", err)
	}
}

func TestColdLockKsCredsKeptByARevokedLock(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	p := kscPlant(t, dest)
	hold.take()
	par := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, par)
	lastPresentAt.Store(2000) // an unlock published without a ring: caught at Check B after the acquire
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if clwExists(dest, ".coldlock") {
		t.Fatal("control failed: the lock committed, so this test proves nothing about the revoke path")
	}
	if _, err := os.Stat(p); err != nil {
		t.Errorf("a REVOKED lock removed the stash (%v): a revoked lock must change nothing, the session keeps it", err)
	}
}

func TestColdLockKsCredsRemovalErrorDoesNotStopTheLock(t *testing.T) {
	dest, rec, _ := clwSetup(t)
	p := filepath.Join(dest, ksLogoffCredsFile)
	// A non-empty directory cannot be os.Remove'd.
	if err := os.MkdirAll(filepath.Join(p, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	logf, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	prev := os.Stderr
	os.Stderr = logf
	restore := func() { os.Stderr = prev }
	t.Cleanup(restore)
	kscCommit(t, dest, rec, "OK")
	restore()
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags = %q/%q, want 10/10: a failed stash removal stopped the lock from queueing its switch", sw, lk)
	}
	b, _ := os.ReadFile(logf.Name())
	if !strings.Contains(string(b), "the keystore-push stash could not be removed") {
		t.Errorf("the removal failure was not logged; stderr:\n%s", b)
	}
}
