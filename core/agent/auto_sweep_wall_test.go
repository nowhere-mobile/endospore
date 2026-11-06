package main

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261127-05: the Auto sweep's "ended after" figure is wall time from the first start of a hold, so a suspended
// stretch counts (the 2026-11-04 entry in docs/product-decisions.md; frankel 0.5.52, NW-84c1d80f5001, logged 4389 s
// for a sweep of 4 h 20 min). The lease, the hold cap and GET-SWEEP keep the monotonic clock.

// wallSweep saves and restores the sweep globals and the wall seam, and pins the seam to *at.
func wallSweep(t *testing.T) *time.Time {
	t.Helper()
	sweepState(t)
	at := new(time.Time)
	*at = time.Date(2026, 11, 4, 23, 0, 0, 0, time.UTC)
	pendingReapMu.Lock()
	pw := autoSweepBeganWall
	autoSweepBeganWall = time.Time{}
	pendingReapMu.Unlock()
	pn := autoSweepWallNow
	autoSweepWallNow = func() time.Time { return *at }
	t.Cleanup(func() {
		autoSweepWallNow = pn
		pendingReapMu.Lock()
		autoSweepBeganWall = pw
		pendingReapMu.Unlock()
	})
	return at
}

// wallEnded is the "ended after" line among lines, or fails the test.
func wallEnded(t *testing.T, lines []string) string {
	t.Helper()
	for _, l := range lines {
		if strings.Contains(l, "auto sweep ended after ") {
			return l
		}
	}
	t.Fatalf("no \"ended after\" line in %q", lines)
	return ""
}

func wallWant(secs string) string {
	return "[logind] auto sweep ended after " + secs + "s: periodic seals resume"
}

func TestAutoSweepEndedAfterCountsTimeAsleep(t *testing.T) {
	at := wallSweep(t)
	d := t.TempDir()
	sweepLog(t, d, "1")
	*at = at.Add(4*time.Hour + 20*time.Minute)
	if got, want := wallEnded(t, sweepLog(t, d, "0")), wallWant("15600"); got != want {
		t.Errorf("a sweep of 4 h 20 min on the wall clock logged %q, want %q (NW-84c1d80f5001: the monotonic "+
			"clock dropped the stretch the phone slept)", got, want)
	}
}

func TestAutoSweepEndedAfterCountsFromTheFirstStart(t *testing.T) {
	at := wallSweep(t)
	t0 := *at
	d := t.TempDir()
	sweepLog(t, d, "1")
	*at = t0.Add(time.Hour)
	sweepLog(t, d, "1") // joins the live hold
	*at = t0.Add(2 * time.Hour)
	lines := sweepLog(t, d, "0")
	if len(lines) != 1 || lines[0] != "[logind] auto sweep ended, 1 still running: seals stay held" {
		t.Fatalf("the first of two ends logged %q, want only the still-running line", lines)
	}
	*at = t0.Add(3 * time.Hour)
	if got, want := wallEnded(t, sweepLog(t, d, "0")), wallWant("10800"); got != want {
		t.Errorf("two overlapping sweeps logged %q, want %q (from the FIRST start; a joiner must not move it)", got, want)
	}
}

func TestAutoSweepEndedAfterALapsedLeaseStartsAgain(t *testing.T) {
	at := wallSweep(t)
	t0 := *at
	d := t.TempDir()
	sweepLog(t, d, "1")
	pendingReapMu.Lock()
	autoSweepUntil = time.Now().Add(-time.Second) // the chooser died: the lease lapses
	pendingReapMu.Unlock()
	*at = t0.Add(5 * time.Hour)
	sweepLog(t, d, "1") // a fresh hold
	*at = t0.Add(5*time.Hour + 10*time.Minute)
	if got, want := wallEnded(t, sweepLog(t, d, "0")), wallWant("600"); got != want {
		t.Errorf("a sweep after a lapsed lease logged %q, want %q (the old wall start must not be reused)", got, want)
	}
}

func TestAutoSweepEndedAfterAClockSetBackIsZero(t *testing.T) {
	at := wallSweep(t)
	d := t.TempDir()
	sweepLog(t, d, "1")
	*at = at.Add(-2 * time.Hour)
	if got, want := wallEnded(t, sweepLog(t, d, "0")), wallWant("0"); got != want {
		t.Errorf("a wall clock set back 2 h during the sweep logged %q, want %q (clamped)", got, want)
	}
}

func TestAutoSweepWallSeamLeavesTheLeaseAlone(t *testing.T) {
	at := wallSweep(t)
	t0 := *at
	d := t.TempDir()
	sweepLog(t, d, "1")
	*at = t0.Add(4*time.Hour + 20*time.Minute)
	got := evictConn(t, d, "GET-SWEEP\n")
	n, err := strconv.Atoi(strings.TrimPrefix(got, "LIVE "))
	if !strings.HasPrefix(got, "LIVE ") || err != nil {
		t.Fatalf("GET-SWEEP replied %q, want LIVE <n>", got)
	}
	if n >= 60 {
		t.Errorf("GET-SWEEP replied %q, want LIVE <60: it reads the monotonic start, not the wall seam", got)
	}
	if r := periodicNow(t); r != "auto-sweep" {
		t.Errorf("the periodic decision read %q, want auto-sweep: the hold cap reads the monotonic clock", r)
	}
	now := time.Now()
	until, began := now.Add(time.Minute), now.Add(-time.Minute)
	*at = t0
	a := sweepDeferReason(now, until, began, 0, autoSweepMaxSealGap)
	*at = t0.Add(4*time.Hour + 20*time.Minute)
	if b := sweepDeferReason(now, until, began, 0, autoSweepMaxSealGap); a != b || a != "auto-sweep" {
		t.Errorf("sweepDeferReason read %q then %q as the seam moved, want auto-sweep both times", a, b)
	}
	if got, want := wallEnded(t, sweepLog(t, d, "0")), wallWant("15600"); got != want {
		t.Errorf("the end logged %q, want %q (the seam was live)", got, want)
	}
}

func TestAutoSweepLateEndAfterASessionResetLogsZero(t *testing.T) {
	at := wallSweep(t)
	d := t.TempDir()
	sweepLog(t, d, "1")
	resetOdWindow() // a new sign-in
	*at = at.Add(time.Hour)
	if got, want := wallEnded(t, sweepLog(t, d, "0")), wallWant("0"); got != want {
		t.Errorf("a late end after a session reset logged %q, want %q (not the age of a stale wall start)", got, want)
	}
}
