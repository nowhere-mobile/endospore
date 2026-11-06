package main

import (
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261109-04 (Q183 option (c)): a cold lock that holds the RW slot while an RW op this daemon abandoned still
// runs waits for that instance, bounded and revocable, and says so in COLD-LOCK-STATUS. Before it, every RW step of
// the lock (btpark first) answered busy and the lock committed with the session's Bluetooth bonds and location live.
//
// Driven through clwSetup's seams. workerState is swapped for a script of answers about the RW lane's instance;
// abandonedOp through resetAbandoned, as worker_abandoned_test.go does.

// claState is the fake init's view of the RW lane's instance.
type claState struct {
	calls atomic.Int64
	done  atomic.Bool // set by cleanup: from then on the instance reads stopped, so no wait outlives the test
	mu    sync.Mutex
	// script answers the nth (1-based) sample of the RW lane.
	script func(n int64) string
	// waitForSeen records any non-empty coldLockWaitFor the fake saw while it was being asked.
	waitForSeen atomic.Bool
}

func (c *claState) setScript(f func(n int64) string) {
	c.mu.Lock()
	c.script = f
	c.mu.Unlock()
}

func claRunning(int64) string { return "running" }
func claStopped(int64) string { return "stopped" }

// claSetup plants the abandoned op (op == "" records none), a scripted workerState and short bound/poll, on top of
// clwSetup. Restores are registered BEFORE clwSetup so they run after its cleanup has waited out the teardown; the
// "now stopped" switch is registered after it, so it runs first and ends any wait still in progress.
func claSetup(t *testing.T, op string, script func(n int64) string, bound time.Duration) (string, *clwRecorder, *claState) {
	t.Helper()
	prevState, prevBound, prevPoll := workerState, coldLockAbandonedBound, coldLockAbandonedPoll
	t.Cleanup(func() {
		workerState, coldLockAbandonedBound, coldLockAbandonedPoll = prevState, prevBound, prevPoll
		coldLockWaitFor.Store("")
		coldLockWaitSince.Store(0)
		setRWHolder("")
	})
	if op == "" {
		resetAbandoned(t, nil)
	} else {
		resetAbandoned(t, map[string]string{laneRW.svc: op})
	}
	st := &claState{script: script}
	workerState = func(svc string) string {
		if svc != laneRW.svc {
			return "stopped"
		}
		n := st.calls.Add(1)
		if s, _ := coldLockWaitFor.Load().(string); s != "" {
			st.waitForSeen.Store(true)
		}
		if st.done.Load() {
			return "stopped"
		}
		st.mu.Lock()
		f := st.script
		st.mu.Unlock()
		return f(n)
	}
	coldLockAbandonedBound = bound
	coldLockAbandonedPoll = 50 * time.Millisecond
	dest, rec, _ := clwSetup(t)
	t.Cleanup(func() { st.done.Store(true) })
	return dest, rec, st
}

// claBtparkAt makes the recorder note, when btpark is dispatched, how many samples workerState had answered.
func claBtparkAt(rec *clwRecorder, st *claState) *atomic.Int64 {
	at := &atomic.Int64{}
	at.Store(-1)
	rec.ret = func(op string, nth int) string {
		if op == "btpark" {
			at.Store(st.calls.Load())
		}
		return ""
	}
	return at
}

func claCount(rec *clwRecorder, op string) int {
	n := 0
	for _, o := range rec.ops() {
		if o == op {
			n++
		}
	}
	return n
}

// A1. The abandoned seal stops after three polls: the lock waits for it, says so, and only then runs btpark.
func TestColdLockAbandonedWaitsForTheOldOpThenParks(t *testing.T) {
	dest, rec, st := claSetup(t, "out", func(n int64) string {
		if n <= 4 { // the first sample and three polls
			return "running"
		}
		return "stopped"
	}, 3*time.Second)
	at := claBtparkAt(rec, st)
	t0 := time.Now()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return st.calls.Load() >= 2 }) {
		t.Fatal("the teardown never re-sampled the abandoned instance -- it did not wait for it")
	}
	if got := coldLockStatusLine(time.Now()); !strings.HasPrefix(got, "WAITING out ") {
		t.Errorf("during the wait COLD-LOCK-STATUS = %q, want WAITING out <secs>", got)
	}
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the lock never finished")
	}
	if el := time.Since(t0); el > 1500*time.Millisecond {
		t.Errorf("the lock took %v, though the old op stopped after ~200ms: a stopped instance did not end the wait", el)
	}
	if n := at.Load(); n < 5 {
		t.Errorf("btpark was dispatched after %d sample(s); the first that read stopped was the 5th -- it ran while the old op still held the lane", n)
	}
	if n := claCount(rec, "btpark"); n != 1 {
		t.Errorf("btpark dispatched %d time(s), want 1", n)
	}
	if !clwExists(dest, ".coldlock") {
		t.Error(".coldlock was not written: the lock did not commit")
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("len(RW slot) = %d after the lock, want 0", n)
	}
	if got := coldLockStatusLine(time.Now()); got != "NONE" {
		t.Errorf("after the lock COLD-LOCK-STATUS = %q, want NONE", got)
	}
}

// A2. The old op never stops: the lock waits out the bound, then locks as before the wait.
func TestColdLockAbandonedLocksAtTheBound(t *testing.T) {
	dest, rec, _ := claSetup(t, "out", claRunning, 300*time.Millisecond)
	t0 := time.Now()
	clwLock(t, dest, 0)
	if !clwWaitFor(3*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the lock never finished: the bound did not end the wait")
	}
	if el := time.Since(t0); el < 300*time.Millisecond {
		t.Errorf("the lock finished after %v, before the 300ms bound: it did not wait for the abandoned op", el)
	}
	if n := claCount(rec, "btpark"); n != 1 {
		t.Errorf("btpark dispatched %d time(s), want 1", n)
	}
	if !clwExists(dest, ".coldlock") {
		t.Error(".coldlock was not written: a lock at the bound must commit")
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("len(RW slot) = %d after the lock, want 0", n)
	}
}

// A3. An unlock during the wait revokes an idle lock at once, touching nothing.
func TestColdLockAbandonedWaitIsRevokedByAnUnlock(t *testing.T) {
	dest, rec, st := claSetup(t, "out", claRunning, 3*time.Second)
	clwLock(t, dest, 1000) // an idle lock, decided at 1000
	if !clwWaitFor(2*time.Second, func() bool { return st.calls.Load() >= 2 }) {
		t.Fatal("the teardown never re-sampled the abandoned instance -- it did not wait for it")
	}
	lastPresentAt.Store(2000)
	ringColdLockBell(2000)
	if !clwWaitFor(time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the lock did not leave within 1s of the unlock -- the wait ignored the revoke")
	}
	if clwExists(dest, ".coldlock") {
		t.Error(".coldlock was written by a revoked lock")
	}
	if !clwExists(dest, ".roamsession") {
		t.Error(".roamsession was removed by a revoked lock -- the live session is no longer recorded")
	}
	if n := claCount(rec, "btpark"); n != 0 {
		t.Errorf("btpark dispatched %d time(s) by a revoked lock", n)
	}
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad stopped %d time(s) by a revoked lock", n)
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("len(RW slot) = %d after the revoke, want 0", n)
	}
}

// A4. No abandoned op: the lock never asks init about the lane.
func TestColdLockAbandonedNoneTakesNoSample(t *testing.T) {
	dest, rec, st := claSetup(t, "", claRunning, 3*time.Second)
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the lock never finished")
	}
	if n := st.calls.Load(); n != 0 {
		t.Errorf("workerState sampled %d time(s) with no abandoned op recorded, want 0", n)
	}
	if n := claCount(rec, "btpark"); n != 1 || !clwExists(dest, ".coldlock") {
		t.Errorf("btpark=%d coldlock=%v; the lock must commit", n, clwExists(dest, ".coldlock"))
	}
}

// A5. The daemon-start marking has no plain token: the status line keeps its three fields with "-".
func TestColdLockAbandonedDaemonStartShowsADash(t *testing.T) {
	dest, _, st := claSetup(t, "(daemon start)", claRunning, 3*time.Second)
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return st.calls.Load() >= 2 }) {
		t.Fatal("the teardown never re-sampled the abandoned instance -- it did not wait for it")
	}
	got := coldLockStatusLine(time.Now())
	if f := strings.Fields(got); len(f) != 3 || f[0] != "WAITING" || f[1] != "-" {
		t.Errorf("during the wait COLD-LOCK-STATUS = %q, want WAITING - <secs>", got)
	}
	st.setScript(claStopped)
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the lock never finished after the old op stopped")
	}
}

// A6. The abandoned op has already stopped: one sample, no wait, no WAITING line.
func TestColdLockAbandonedStoppedDoesNotWait(t *testing.T) {
	dest, rec, st := claSetup(t, "out", claStopped, 3*time.Second)
	var status atomic.Value
	status.Store("")
	rec.ret = func(op string, nth int) string {
		if op == "btpark" {
			status.Store(coldLockStatusLine(time.Now()))
		}
		return ""
	}
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the lock never finished")
	}
	if n := st.calls.Load(); n != 1 {
		t.Errorf("workerState sampled %d time(s), want 1", n)
	}
	if st.waitForSeen.Load() {
		t.Error("coldLockWaitFor was published although the abandoned op had stopped")
	}
	if s := status.Load().(string); strings.HasPrefix(s, "WAITING") {
		t.Errorf("at btpark COLD-LOCK-STATUS = %q, want no WAITING", s)
	}
	if n := claCount(rec, "btpark"); n != 1 || !clwExists(dest, ".coldlock") {
		t.Errorf("btpark=%d coldlock=%v; the lock must commit", n, clwExists(dest, ".coldlock"))
	}
}
