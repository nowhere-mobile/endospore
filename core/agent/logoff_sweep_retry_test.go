package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261117-03: every test in this package that drives a failed sweep through handleLogout now reaches at least
// one retry, and the production gap would sleep 5 s of real time there (50 s for a count that falls). No test may
// measure the gaps in wall time either: the tests below record what the hook was asked to sleep. So the hook is a
// no-op by default, and recordGaps installs a recording one for a single test.
func init() { logoffSweepRetrySleep = func(time.Duration) {} }

// recordGaps installs a gap hook that records each gap (and runs during, when non-nil) and restores the no-op after
// the test. The hook runs on the logoff goroutine, so the list is guarded.
func recordGaps(t *testing.T, during func()) func() []time.Duration {
	t.Helper()
	var mu sync.Mutex
	var gaps []time.Duration
	logoffSweepRetrySleep = func(d time.Duration) {
		mu.Lock()
		gaps = append(gaps, d)
		mu.Unlock()
		if during != nil {
			during()
		}
	}
	t.Cleanup(func() { logoffSweepRetrySleep = func(time.Duration) {} })
	return func() []time.Duration {
		mu.Lock()
		defer mu.Unlock()
		return append([]time.Duration(nil), gaps...)
	}
}

func sameGaps(got, want []time.Duration) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

// sweepAnswers joins scripted ERR-MEDIA-SWEEP counts (or whole replies) as cutoffWorkerGated's "a||b||c".
func sweepAnswers(replies ...string) string { return strings.Join(replies, "||") }

// failedSweepLogoff signs uid out with roamd's sweepmedia answering sweep, and returns the ops roamd was handed once
// the logoff goroutine has returned. The session must stay signed in (the last sweep does not verify).
func failedSweepLogoff(t *testing.T, uid, sweep string) (dest string, ops []string) {
	t.Helper()
	t.Cleanup(resetMediaStuck)
	resetMediaStuck()
	dest = cutoffSession(t, uid)
	got := cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": sweep, "cutoffwake": "WAKE OK 3",
		"out": "OK"}, nil)
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	logoffDone(t, uid, 20*time.Second)
	return dest, got()
}

// (a) A count that falls to OK signs out: three sweeps, gaps 5 s then 15 s, and the run of failures ends.
func TestLogoffSweepRetry_ACountThatFallsToOKSignsOut(t *testing.T) {
	const uid = "141"
	t.Cleanup(resetMediaStuck)
	resetMediaStuck()
	gaps := recordGaps(t, nil)
	dest := cutoffSession(t, uid)
	ops := cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "out": "OK", "cutoffwake": "WAKE OK 3",
		"sweepmedia": sweepAnswers("ERR-MEDIA-SWEEP 90", "ERR-MEDIA-SWEEP 40", "OK")}, nil)
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		pendingReapMu.Lock()
		reap := pendingReapUID
		pendingReapMu.Unlock()
		if reap == uid {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the sign-out never queued its reap; roamd was handed %v", ops())
		}
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(700 * time.Millisecond) // room for a wake that must NOT come to reach the worker
	got := ops()
	ackReapAction("SWITCH", uid)
	ackReapAction("REAP", uid)
	if want := []string{"cutoff", "sweepmedia", "sweepmedia", "sweepmedia", "out"}; !sameOps(got, want) {
		t.Fatalf("handed roamd %v, want %v -- a sweep whose count falls must be retried until it verifies", got, want)
	}
	if g, want := gaps(), []time.Duration{5 * time.Second, 15 * time.Second}; !sameGaps(g, want) {
		t.Errorf("gaps %v, want %v -- each gap must be longer than the last", g, want)
	}
	if n := mediaStuckCount("alice", uid); n != 0 {
		t.Errorf("a sweep that verified on a retry left a run of %d failures", n)
	}
}

// (b) A count that does not fall stops after retry 1, keeps the session, and licenses RESTART-UNSAVED.
func TestLogoffSweepRetry_ACountThatDoesNotFallStopsAfterOneRetry(t *testing.T) {
	const uid = "142"
	gaps := recordGaps(t, nil)
	dest, ops := failedSweepLogoff(t, uid, "ERR-MEDIA-SWEEP 90")
	if want := []string{"cutoff", "sweepmedia", "sweepmedia", "cutoffwake"}; !sameOps(ops, want) {
		t.Fatalf("handed roamd %v, want %v -- a count that did not fall gets no second retry", ops, want)
	}
	if g, want := gaps(), []time.Duration{5 * time.Second}; !sameGaps(g, want) {
		t.Errorf("gaps %v, want %v", g, want)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err != nil {
		t.Errorf("the kept session was not re-armed: %v", err)
	}
	if n := mediaStuckCount("alice", uid); n != 2 {
		t.Errorf("mediaStuckCount = %d, want 2 -- every failed attempt counts, so a stop after a retry licenses "+
			"RESTART-UNSAVED", n)
	}
	if got := strings.Join(composeSealStatus(dest), "|"); !strings.Contains(got, "FAILED MEDIA") {
		t.Errorf("SEAL-STATUS = %q, want FAILED MEDIA", got)
	}
}

// (c) A count that keeps falling gets three retries and no fourth.
func TestLogoffSweepRetry_ThreeRetriesThenStop(t *testing.T) {
	const uid = "143"
	gaps := recordGaps(t, nil)
	dest, ops := failedSweepLogoff(t, uid, sweepAnswers("ERR-MEDIA-SWEEP 90", "ERR-MEDIA-SWEEP 60",
		"ERR-MEDIA-SWEEP 30", "ERR-MEDIA-SWEEP 10"))
	if want := []string{"cutoff", "sweepmedia", "sweepmedia", "sweepmedia", "sweepmedia", "cutoffwake"}; !sameOps(ops, want) {
		t.Fatalf("handed roamd %v, want %v -- at most three retries", ops, want)
	}
	if g, want := gaps(), []time.Duration{5 * time.Second, 15 * time.Second, 30 * time.Second}; !sameGaps(g, want) {
		t.Errorf("gaps %v, want %v", g, want)
	}
	if n := mediaStuckCount("alice", uid); n != 4 {
		t.Errorf("mediaStuckCount = %d, want 4 (one per failed sweep)", n)
	}
	if got := strings.Join(composeSealStatus(dest), "|"); !strings.Contains(got, "FAILED MEDIA") {
		t.Errorf("SEAL-STATUS = %q, want FAILED MEDIA", got)
	}
}

// (d) An unreadable count is never "fewer": one retry, then stop.
func TestLogoffSweepRetry_AnUnreadableCountStopsAfterOneRetry(t *testing.T) {
	const uid = "144"
	gaps := recordGaps(t, nil)
	_, ops := failedSweepLogoff(t, uid, "ERR-MEDIA-SWEEP UNREAD")
	if want := []string{"cutoff", "sweepmedia", "sweepmedia", "cutoffwake"}; !sameOps(ops, want) {
		t.Fatalf("handed roamd %v, want %v", ops, want)
	}
	if g, want := gaps(), []time.Duration{5 * time.Second}; !sameGaps(g, want) {
		t.Errorf("gaps %v, want %v", g, want)
	}
	if n := mediaStuckCount("alice", uid); n != 2 {
		t.Errorf("mediaStuckCount = %d, want 2", n)
	}
}

// scriptedSweep returns its replies in order, then the last one on every later call, and counts its calls.
func scriptedSweep(replies ...string) (run func() string, calls func() int) {
	n := 0
	return func() string {
			r := replies[min(n, len(replies)-1)]
			n++
			return r
		}, func() int {
			return n
		}
}

// claimFor claims a logoff of uid for a unit test of the loop, so logoffVerdictSuperseded says no.
func claimFor(t *testing.T, uid string) uint64 {
	t.Helper()
	t.Cleanup(resetMediaStuck)
	resetMediaStuck()
	claim := setLogoffInFlight(uid)
	t.Cleanup(func() { clearLogoffInFlight(uid, claim) })
	return claim
}

// (d2), (d3) A number, then an unreadable reply, is not a fall to 0: the case "unreadable is never fewer" exists for.
func TestLogoffSweepRetry_ANumberThenUnreadableStopsAfterOneRetry(t *testing.T) {
	for _, c := range []struct{ uid, second string }{{"145", "ERR-MEDIA-SWEEP UNREAD"}, {"146", workerBusy}} {
		t.Run(c.second, func(t *testing.T) {
			claim := claimFor(t, c.uid)
			gaps := recordGaps(t, nil)
			run, calls := scriptedSweep("ERR-MEDIA-SWEEP 90", c.second)
			if got := logoffSweepWithRetries(c.uid, claim, "bob", run); got != c.second {
				t.Errorf("returned %q, want %q", got, c.second)
			}
			if n := calls(); n != 2 {
				t.Errorf("ran %d sweeps, want 2 -- an unreadable count after 90 is not fewer", n)
			}
			if g, want := gaps(), []time.Duration{5 * time.Second}; !sameGaps(g, want) {
				t.Errorf("gaps %v, want %v", g, want)
			}
			if n := mediaStuckCount("bob", c.uid); n != 1 {
				t.Errorf("mediaStuckCount = %d, want 1 (the loop counts all but the last)", n)
			}
		})
	}
}

// (e) A newer sign-out that claims inside the gap owns the session: the loop stops and counts nothing.
func TestLogoffSweepRetry_ANewerSignOutStopsTheLoop(t *testing.T) {
	const uid = "147"
	claim := claimFor(t, uid)
	var newer uint64
	t.Cleanup(func() { clearLogoffInFlight(uid, newer) })
	gaps := recordGaps(t, func() {
		if newer == 0 {
			newer = setLogoffInFlight(uid)
		}
	})
	run, calls := scriptedSweep("ERR-MEDIA-SWEEP 90", "ERR-MEDIA-SWEEP 40")
	if got := logoffSweepWithRetries(uid, claim, "carol", run); got != "ERR-MEDIA-SWEEP 90" {
		t.Errorf("returned %q, want the first attempt's reply", got)
	}
	if n := calls(); n != 1 {
		t.Errorf("ran %d sweeps after a newer sign-out claimed, want 1", n)
	}
	if g, want := gaps(), []time.Duration{5 * time.Second}; !sameGaps(g, want) {
		t.Errorf("gaps %v, want %v", g, want)
	}
	if n := mediaStuckCount("carol", uid); n != 0 {
		t.Errorf("a superseded logoff counted %d failed sweeps", n)
	}
}

// (f) A screen the stall watchdog un-stuck inside the gap belongs to a session in use: no retry tears its media down.
func TestLogoffSweepRetry_AnUnstuckScreenStopsTheLoop(t *testing.T) {
	const uid = "148"
	claim := claimFor(t, uid)
	pendingReapMu.Lock()
	old := sealUnstuck
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealUnstuck = old
		pendingReapMu.Unlock()
	})
	recordGaps(t, func() {
		pendingReapMu.Lock()
		sealUnstuck = true
		pendingReapMu.Unlock()
	})
	run, calls := scriptedSweep("ERR-MEDIA-SWEEP 90", "OK")
	if got := logoffSweepWithRetries(uid, claim, "dave", run); got != "ERR-MEDIA-SWEEP 90" {
		t.Errorf("returned %q, want the first attempt's reply", got)
	}
	if n := calls(); n != 1 {
		t.Errorf("ran %d sweeps after the screen was un-stuck, want 1", n)
	}
	if n := mediaStuckCount("dave", uid); n != 0 {
		t.Errorf("mediaStuckCount = %d, want 0", n)
	}
}

// (g) A gap keeps the stall watchdog's liveness clock moving, so it never reads the gap as silence.
func TestLogoffSweepRetry_TheGapKeepsTheStallClockAlive(t *testing.T) {
	step := logoffSweepRetryStep
	pendingReapMu.Lock()
	oldAt := sealProgAt
	sealProgAt = time.Now().Add(-time.Hour)
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		logoffSweepRetryStep = step
		pendingReapMu.Lock()
		sealProgAt = oldAt
		pendingReapMu.Unlock()
	})
	logoffSweepRetryStep = 5 * time.Millisecond
	sleepRefreshingStallClock(12 * time.Millisecond)
	pendingReapMu.Lock()
	at := sealProgAt
	pendingReapMu.Unlock()
	if time.Since(at) > time.Second {
		t.Errorf("sealProgAt is %s old after a gap -- the stall watchdog would read the gap as silence", time.Since(at))
	}
}

// (h) Only "ERR-MEDIA-SWEEP <n>", n >= 0, is a count.
func TestLogoffSweepRetry_MountsLeft(t *testing.T) {
	if n, ok := sweepMountsLeft("ERR-MEDIA-SWEEP 90"); n != 90 || !ok {
		t.Errorf("ERR-MEDIA-SWEEP 90 -> %d, %v", n, ok)
	}
	for _, r := range []string{"ERR-MEDIA-SWEEP UNREAD", "ERR-TIMEOUT", "ERR-MEDIA-SWEEP ", "ERR-MEDIA-SWEEP -1",
		"ERR-MEDIA-SWEEP 9x", "OK", workerBusy} {
		if n, ok := sweepMountsLeft(r); ok || n != 0 {
			t.Errorf("%q -> %d, %v, want 0, false -- an unreadable count is never fewer", r, n, ok)
		}
	}
}
