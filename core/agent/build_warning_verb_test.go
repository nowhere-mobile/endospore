package main

// NWP-20261120-03: GET-BUILD-WARNING answers WARN when the daemon's cached warning names the running build and has not
// expired, NONE otherwise. The gate asks it before sign-in, so it is lock-free (concurrentSafeCmd): a sign-in or a reap
// holding sessionMu must not delay it.

import (
	"path/filepath"
	"testing"
	"time"
)

// buildWarningVerbGlobals empties the cache, gives the test its own seq floor path and the running version, and
// restores all of it when the test ends. It also shortens handleLogin's connection deadline: a daemon without the verb
// falls through to the legacy login, which waits for more lines until that deadline, so the test fails within seconds
// there instead of timing out. NOWHERE_STATE is a temp dir, so that fallthrough wipes nothing real.
func buildWarningVerbGlobals(t *testing.T, version string) {
	t.Helper()
	oldDeadline, oldVersion, oldSeq := loginConnDeadline, buildWarningVersion, buildWarningSeqPath
	loginConnDeadline = 2 * time.Second
	buildWarningVersion = func() string { return version }
	buildWarningSeqPath = filepath.Join(t.TempDir(), "build-warning-seq")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	bwMu.Lock()
	oldCurrent := bwCurrent
	bwCurrent = nil
	bwMu.Unlock()
	t.Cleanup(func() {
		loginConnDeadline = oldDeadline
		buildWarningVersion = oldVersion
		buildWarningSeqPath = oldSeq
		bwMu.Lock()
		bwCurrent = oldCurrent
		bwMu.Unlock()
	})
}

// bwVerbWarning is a warning naming 0.5.50.
func bwVerbWarning(issued, expires int64) *buildWarning {
	return &buildWarning{Schema: 1, Seq: 1, Issued: issued, Expires: expires, Versions: []string{"0.5.50"}}
}

// bwVerbLive caches a warning for 0.5.50 that expires in an hour.
func bwVerbLive() {
	now := time.Now().Unix()
	refreshBuildWarning(now, func() (*buildWarning, error) { return bwVerbWarning(now-60, now+3600), nil })
}

func askBuildWarning(t *testing.T) string {
	t.Helper()
	return driveLogin(t, t.TempDir(), "GET-BUILD-WARNING\n")
}

func TestGetBuildWarningNoCache(t *testing.T) {
	buildWarningVerbGlobals(t, "0.5.50")
	if got := askBuildWarning(t); got != "NONE" {
		t.Fatalf("GET-BUILD-WARNING with no cached warning replied %q, want NONE", got)
	}
}

func TestGetBuildWarningWarnsTheNamedBuild(t *testing.T) {
	buildWarningVerbGlobals(t, "0.5.50")
	bwVerbLive()
	if got := askBuildWarning(t); got != "WARN" {
		t.Fatalf("GET-BUILD-WARNING with a live warning for the running 0.5.50 replied %q, want WARN", got)
	}
}

func TestGetBuildWarningOtherBuild(t *testing.T) {
	buildWarningVerbGlobals(t, "0.5.51")
	bwVerbLive()
	if got := askBuildWarning(t); got != "NONE" {
		t.Fatalf("GET-BUILD-WARNING on 0.5.51 with a warning for 0.5.50 replied %q, want NONE", got)
	}
}

func TestGetBuildWarningExpired(t *testing.T) {
	buildWarningVerbGlobals(t, "0.5.50")
	now := time.Now().Unix()
	// Cached an hour ago, when it was still live; it expired a minute ago.
	refreshBuildWarning(now-3600, func() (*buildWarning, error) { return bwVerbWarning(now-3700, now-60), nil })
	bwMu.Lock()
	cached := bwCurrent != nil
	bwMu.Unlock()
	if !cached {
		t.Fatal("control: the refresh did not cache the warning, so the test cannot prove the verb's expiry check")
	}
	if got := askBuildWarning(t); got != "NONE" {
		t.Fatalf("GET-BUILD-WARNING with an expired warning replied %q, want NONE", got)
	}
}

func TestGetBuildWarningEmptyVersion(t *testing.T) {
	buildWarningVerbGlobals(t, "")
	bwVerbLive()
	if got := askBuildWarning(t); got != "NONE" {
		t.Fatalf("GET-BUILD-WARNING with an empty running version replied %q, want NONE", got)
	}
}

// TestGetBuildWarningRunsUnderSessionMu: the gate asks before sign-in, while a sign-in or a reap may hold sessionMu.
func TestGetBuildWarningRunsUnderSessionMu(t *testing.T) {
	if !concurrentSafeCmd("GET-BUILD-WARNING") {
		t.Errorf("GET-BUILD-WARNING is not on the lock-free allowlist (concurrentSafeCmd)")
	}
	buildWarningVerbGlobals(t, "0.5.50")
	bwVerbLive()
	func() {
		sessionMu.Lock()
		defer sessionMu.Unlock()
		if got := replyWhileHeld(t, 30*time.Second, "GET-BUILD-WARNING\n", "GET-BUILD-WARNING"); got != "WARN" {
			t.Fatalf("GET-BUILD-WARNING while sessionMu is held replied %q, want WARN", got)
		}
	}()
}
