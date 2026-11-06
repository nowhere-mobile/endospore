package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261113-20 (backlog "A `vpnup` worker op ran for a user after that user's reap"): retryVpnup is the vpnup
// op's only sender, and it kept retrying for ~90 s after a delete had reaped its session (`REAP uid=25`, then
// `worker op=vpnup uid=25`). It now re-reads the marker before every try and stops when the marker is absent or
// names another uid; a damaged marker is still a live session and carries on.

const vsgStopLine = "is no longer this session's -- stopping"

const vsgName = "Vsg Hidden Name" // this file's own profile name, in the marker AND passed to retryVpnup

// vsgSeams replaces the worker with one answering replies in turn (the last one repeats) and calling onCall with the
// 1-based call number first, and makes the sleep a no-op. It returns the call counter.
func vsgSeams(t *testing.T, replies []string, onCall func(n int)) *int {
	t.Helper()
	oldW, oldS, oldN := vpnupWorker, vpnupSleep, vpnupTries
	t.Cleanup(func() { vpnupWorker, vpnupSleep, vpnupTries = oldW, oldS, oldN })
	calls := 0
	vpnupWorker = func(dest, name, pass, uid string) string {
		calls++
		if onCall != nil {
			onCall(calls)
		}
		if calls <= len(replies) {
			return replies[calls-1]
		}
		return replies[len(replies)-1]
	}
	vpnupSleep = func(time.Duration) {}
	vpnupTries = 5
	return &calls
}

func vsgMarker(t *testing.T, dest, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte(body), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}
}

// (a) the marker names uid 25 for two tries, then is removed: no third try.
func TestVpnupSessionGoneStopsWhenTheMarkerIsRemoved(t *testing.T) {
	dest := t.TempDir()
	vsgMarker(t, dest, vsgName+"\npass\n25\n")
	calls := vsgSeams(t, []string{"NOTREADY"}, func(n int) {
		if n == 2 {
			os.Remove(filepath.Join(dest, roamSessionFile)) // the reap
		}
	})
	out := captureStderr(t, func() { retryVpnup(dest, vsgName, "pass", "25") })
	if *calls != 2 {
		t.Fatalf("worker called %d times, want 2 (it ran for a session that was gone); log %q", *calls, out)
	}
	if n := strings.Count(out, vsgStopLine); n != 1 || !strings.Contains(out, "user 25 ") {
		t.Fatalf("want the stopping line once with the uid, got %d in %q", n, out)
	}
	if strings.Contains(out, "gave up") {
		t.Fatalf("a stopped retry logged a give-up: %q", out)
	}
}

// (b) the marker names another uid from the start: the worker is never called.
func TestVpnupSessionGoneNeverRunsForAnotherUid(t *testing.T) {
	dest := t.TempDir()
	vsgMarker(t, dest, vsgName+"\npass\n26\n")
	calls := vsgSeams(t, []string{"NOTREADY"}, nil)
	out := captureStderr(t, func() { retryVpnup(dest, vsgName, "pass", "25") })
	if *calls != 0 {
		t.Fatalf("worker called %d times for uid 25 while the marker names uid 26, want 0", *calls)
	}
	if n := strings.Count(out, vsgStopLine); n != 1 {
		t.Fatalf("want the stopping line once, got %d in %q", n, out)
	}
}

// (c) the marker keeps naming uid 25: today's behaviour, OK APPLIED on the third try, quiet.
func TestVpnupSessionGoneKeepsTryingForItsOwnSession(t *testing.T) {
	dest := t.TempDir()
	vsgMarker(t, dest, vsgName+"\npass\n25\n")
	calls := vsgSeams(t, []string{"NOTREADY", "NOTREADY", "OK APPLIED"}, nil)
	out := captureStderr(t, func() { retryVpnup(dest, vsgName, "pass", "25") })
	if *calls != 3 {
		t.Fatalf("worker called %d times, want 3", *calls)
	}
	if out != "" {
		t.Fatalf("want no log line, got %q", out)
	}
}

// (d) a damaged marker -- the uid line lost -- is still a live session: the VPN is applied.
func TestVpnupSessionGoneDamagedMarkerIsStillLive(t *testing.T) {
	dest := t.TempDir()
	vsgMarker(t, dest, vsgName+"\npass\n")
	if _, _, u, st := readRoamSessionState(dest); st != roamSessionDamaged || u != "" {
		t.Fatalf("fixture is not a damaged marker with an empty uid: state %v uid %q", st, u)
	}
	calls := vsgSeams(t, []string{"OK APPLIED"}, nil)
	out := captureStderr(t, func() { retryVpnup(dest, vsgName, "pass", "25") })
	if *calls != 1 {
		t.Fatalf("worker called %d times on a damaged marker, want 1 (a live session's VPN was given up)", *calls)
	}
	if strings.Contains(out, vsgStopLine) {
		t.Fatalf("a damaged marker stopped the retry: %q", out)
	}
}

// (e) no line retryVpnup writes holds the profile name: the stop, the give-up and the damaged shapes.
func TestVpnupSessionGoneLogsNoProfileName(t *testing.T) {
	var all strings.Builder
	run := func(body string, replies []string, onCall func(dest string) func(int)) {
		dest := t.TempDir()
		vsgMarker(t, dest, body)
		var hook func(int)
		if onCall != nil {
			hook = onCall(dest)
		}
		vsgSeams(t, replies, hook)
		all.WriteString(captureStderr(t, func() { retryVpnup(dest, vsgName, "pass", "25") }))
	}
	run(vsgName+"\npass\n25\n", []string{"NOTREADY"}, func(dest string) func(int) {
		return func(n int) {
			if n == 2 {
				os.Remove(filepath.Join(dest, roamSessionFile))
			}
		}
	})
	run(vsgName+"\npass\n26\n", []string{"NOTREADY"}, nil)
	run(vsgName+"\npass\n25\n", []string{"NOTREADY"}, nil)
	run(vsgName+"\npass\n", []string{"OK NOHELPER"}, nil)
	out := all.String()
	if !strings.Contains(out, vsgStopLine) || !strings.Contains(out, "gave up") {
		t.Fatalf("the shapes did not all log: %q", out)
	}
	for _, w := range append([]string{vsgName}, strings.Fields(vsgName)...) {
		if strings.Contains(out, w) {
			t.Fatalf("log carries the profile name (%q): %q", w, out)
		}
	}
}
