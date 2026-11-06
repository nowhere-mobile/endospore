package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
)

// NWP-20261120-01 (docs/backlog.md §B, "An odrestore the daemon gave up on keeps the roamd worker, ..."): at an
// odrestore's stall give-up runWorkerHeld sends ctl.stop for the lane and waits, at most workerStopSamples samples,
// for init to report it stopped, so the next op on the lane runs instead of answering busy. These cases reuse
// worker_abandoned_test.go's fake init (abFakeInit), which ignores a ctl.start while the service reads "running",
// and add a fake ctl.stop. The seams are package vars: none of these tests may run in parallel.

type wsStop struct {
	mu        sync.Mutex
	stops     []string // svc of every workerStop call
	sent      map[string]bool
	post      int  // workerState samples of a stopped svc taken after the stop
	overshoot bool // a sample was taken past workerStopSamples
}

// wsInstallStop wraps f's workerState and installs a workerStop. honourAfter: 0 = init stops the instance at once;
// N > 0 = it reads running for N samples after the stop, then stopped; -1 = init ignores the stop, but the fake
// reports stopped after workerStopSamples+5 samples, so a wait with no bound still ends (and records the overshoot).
func wsInstallStop(t *testing.T, f *abInit, honourAfter int) *wsStop {
	t.Helper()
	s := &wsStop{sent: map[string]bool{}}
	prevStop, prevState, prevSamples := workerStop, workerState, workerStopSamples
	t.Cleanup(func() { workerStop, workerState, workerStopSamples = prevStop, prevState, prevSamples })
	workerStopSamples = 20
	inner := workerState
	workerState = func(svc string) string {
		s.mu.Lock()
		release := false
		if s.sent[svc] {
			s.post++
			if s.post > workerStopSamples {
				s.overshoot = true
			}
			release = (honourAfter > 0 && s.post > honourAfter) || s.post > workerStopSamples+5
		}
		s.mu.Unlock()
		if release {
			f.setRunning(svc, false)
		}
		return inner(svc)
	}
	workerStop = func(svc string) {
		s.mu.Lock()
		s.stops = append(s.stops, svc)
		s.sent[svc] = true
		s.mu.Unlock()
		if honourAfter == 0 {
			f.setRunning(svc, false)
		}
	}
	return s
}

func (s *wsStop) snap() (stops []string, post int, overshoot bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.stops...), s.post, s.overshoot
}

// wsPlan: a first instance that never answers (its goroutine leaves at cleanup and writes no $RES), then one that
// answers OK-NEXT.
func wsPlan() []abPlan {
	return []abPlan{{lane: laneRW, text: "OK-OLD", release: make(chan struct{})}, {lane: laneRW, text: "OK-NEXT"}}
}

// wsGiveUp runs an odrestore that never answers and checks the give-up itself: ERR-TIMEOUT, exactly one stop, for
// nowhere_roamd. It returns the log.
func wsGiveUp(t *testing.T, f *abInit, s *wsStop) string {
	t.Helper()
	if laneFor("odrestore").svc != laneRW.svc || laneRW.svc != "nowhere_roamd" || workerStallTicks("odrestore") != roamStallTicks {
		t.Fatalf("control: odrestore does not run on nowhere_roamd with the ordinary stall budget")
	}
	var out string
	logs := captureStderr(t, func() { out = abRun(t, f, "odrestore") })
	if out != "ERR-TIMEOUT" {
		t.Fatalf("the odrestore returned %q, want ERR-TIMEOUT", out)
	}
	if stops, _, _ := s.snap(); len(stops) != 1 || stops[0] != "nowhere_roamd" {
		t.Fatalf("stops = %q, want exactly one, for nowhere_roamd", stops)
	}
	return logs
}

// wsNextRuns checks that the next op on the lane runs and answers for itself.
func wsNextRuns(t *testing.T, f *abInit) {
	t.Helper()
	if out := abRun(t, f, "materializeapp"); out != "OK-NEXT" {
		t.Fatalf("the next op returned %q, want its own answer OK-NEXT (not %q, not the old OK-OLD)", out, workerBusy)
	}
	starts := f.snapshot()
	if len(starts) != 2 || starts[1].ignored || starts[1].reqOp != "materializeapp" {
		t.Fatalf("starts = %+v, want a second, honoured start that consumed the next request", starts)
	}
	if got := laneAbandonedOp(laneRW); got != "" {
		t.Errorf("the abandoned record survives the next op: %q", got)
	}
}

const wsStoppedLine = "worker lane nowhere_roamd: stopped the odrestore op this daemon gave up on (2026-11-01)"

func TestWorkerStopAbandonedOdrestoreFreesTheLane(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, wsPlan())
	s := wsInstallStop(t, f, 0)
	logs := wsGiveUp(t, f, s)
	if !strings.Contains(logs, wsStoppedLine) {
		t.Errorf("stop line missing from log:\n%s", logs)
	}
	if got := laneAbandonedOp(laneRW); got != "odrestore" {
		t.Errorf("the record after the stop reads %q, want \"odrestore\" (the next op discards what the instance left)", got)
	}
	wsNextRuns(t, f)
}

func TestWorkerStopWaitsForALateStop(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, wsPlan())
	s := wsInstallStop(t, f, 3)
	logs := wsGiveUp(t, f, s)
	if !strings.Contains(logs, wsStoppedLine) {
		t.Errorf("stop line missing from log:\n%s", logs)
	}
	if _, post, _ := s.snap(); post < 4 {
		t.Errorf("%d samples after the stop, want the wait to sample past the 3 that read running", post)
	}
	wsNextRuns(t, f)
}

func TestWorkerStopBoundedWhenInitIgnoresIt(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, wsPlan())
	s := wsInstallStop(t, f, -1)
	logs := wsGiveUp(t, f, s)
	// Read before the next op: its own busy check takes one more sample.
	_, post, overshoot := s.snap()
	if post > workerStopSamples || overshoot {
		t.Errorf("%d samples after the stop (overshoot %v), want at most workerStopSamples = %d", post, overshoot, workerStopSamples)
	}
	want := fmt.Sprintf("worker lane nowhere_roamd: the odrestore op did not stop within %d samples -- the lane answers busy until it ends", workerStopSamples)
	if !strings.Contains(logs, want) {
		t.Errorf("did-not-stop line missing from log:\n%s", logs)
	}
	if out := abRun(t, f, "materializeapp"); out != workerBusy {
		t.Errorf("the next op returned %q while the instance still runs, want %q", out, workerBusy)
	}
}

// A seal (`out`) or a sign-in (`in`) is never stopped by this slice (h50 #2 is open): the lane answers busy as before.
func TestWorkerStopNotSentForOtherOps(t *testing.T) {
	for _, op := range []string{"out", "in"} {
		t.Run(op, func(t *testing.T) {
			resetAbandoned(t, nil)
			f := abFakeInit(t, wsPlan())
			s := wsInstallStop(t, f, 0)
			if laneFor(op).svc != laneRW.svc {
				t.Fatalf("control: op %q does not run on laneRW", op)
			}
			if out := abRun(t, f, op); out != "ERR-TIMEOUT" {
				t.Fatalf("control: op %q returned %q, want ERR-TIMEOUT", op, out)
			}
			if stops, _, _ := s.snap(); len(stops) != 0 {
				t.Errorf("op %q given up on sent %d stop(s): %q, want none", op, len(stops), stops)
			}
			if out := abRun(t, f, "materializeapp"); out != workerBusy {
				t.Errorf("the op after a given-up %q returned %q, want %q", op, out, workerBusy)
			}
		})
	}
}

func TestWorkerStopPropertyLabelled(t *testing.T) {
	b, err := os.ReadFile("../vendor-common/sepolicy/property_contexts")
	if err != nil {
		t.Fatal(err)
	}
	const label = "u:object_r:ctl_nowhere_roamd_prop:s0"
	found := map[string]bool{}
	for _, line := range strings.Split(string(b), "\n") {
		if f := strings.Fields(line); len(f) == 2 && f[1] == label {
			found[f[0]] = true
		}
	}
	for _, key := range []string{"ctl.start$nowhere_roamd", "ctl.stop$nowhere_roamd"} {
		if !found[key] {
			t.Errorf("property_contexts has no %q line with %s", key, label)
		}
	}
}
