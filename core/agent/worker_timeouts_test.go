package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261204-16 (Q182, the backlog row "The #83 lost-start race fires ROUTINELY"): runWorkerHeld's ERR-TIMEOUT exits
// count each expiry, whether a lost-start re-fire came before it and whether the request was still unread; noteLostStart
// counts its re-fires by op; an issue report carries both at every scope. The runWorkerHeld cases reuse
// lost_start_recovery_test.go's fake init, whose 1 ms workerTick keeps a stall expiry inside lsrRun's 10 s bound.

const emptyWorkerTimeouts = "n=0 after_lost_start=0 unconsumed=0 ops=none"

// resetWorkerTimeouts zeroes the expiry counts and the lost starts by op for a test and restores them afterwards.
func resetWorkerTimeouts(t *testing.T) {
	t.Helper()
	workerTimeoutsMu.Lock()
	prev := workerTimeouts
	prev.byOp = copyOpCounts(workerTimeouts.byOp)
	prevLost := copyOpCounts(lostStartsByOp)
	workerTimeouts.n, workerTimeouts.afterLostStart, workerTimeouts.unconsumed = 0, 0, 0
	workerTimeouts.byOp = map[string]int64{}
	lostStartsByOp = map[string]int64{}
	workerTimeoutsMu.Unlock()
	t.Cleanup(func() {
		workerTimeoutsMu.Lock()
		defer workerTimeoutsMu.Unlock()
		workerTimeouts = prev
		lostStartsByOp = prevLost
	})
}

func copyOpCounts(m map[string]int64) map[string]int64 {
	c := make(map[string]int64, len(m))
	for k, v := range m {
		c[k] = v
	}
	return c
}

// (a) A lost start is re-fired and the fresh instance consumes the request but never answers: the expiry is counted
// after a lost start, with the request consumed.
func TestWorkerTimeouts_RefiredStartStillUnanswered(t *testing.T) {
	f := lsrFakeInit(t, laneRW, lsrStates("stopped"), []lsrPlan{{kind: lsrIgnore}, {kind: lsrCrash}})
	resetWorkerTimeouts(t)
	if out := lsrRun(t, f, "materializeapp"); out != "ERR-TIMEOUT" {
		t.Fatalf("got %q, want ERR-TIMEOUT", out)
	}
	_, starts := f.snapshot()
	if len(starts) != 2 || starts[1].reqOp != "materializeapp" {
		t.Fatalf("control: starts = %+v, want the ignored start and one re-fire that consumed the request", starts)
	}
	if got, want := workerTimeoutsValue(), "n=1 after_lost_start=1 unconsumed=0 ops=materializeapp:1"; got != want {
		t.Errorf("workerTimeoutsValue() = %q, want %q", got, want)
	}
	if got, want := lostStartsByOpValue(), "materializeapp=1"; got != want {
		t.Errorf("lostStartsByOpValue() = %q, want %q", got, want)
	}
	if n := roamLostStarts.Load(); n != 1 {
		t.Errorf("roamLostStarts = %d, want 1", n)
	}
}

// (b) The row's residual: the instance that ignored the start never exits, so nothing is re-fired and the request is
// never read.
func TestWorkerTimeouts_HungInstanceUnconsumed(t *testing.T) {
	f := lsrFakeInit(t, laneRW, lsrStates("running"), []lsrPlan{{kind: lsrIgnore}})
	resetWorkerTimeouts(t)
	if out := lsrRun(t, f, "materializeapp"); out != "ERR-TIMEOUT" {
		t.Fatalf("got %q, want ERR-TIMEOUT", out)
	}
	if _, err := os.Stat(filepath.Join(f.dest, f.lane.req)); err != nil {
		t.Fatalf("control: the request is gone (%v), the hung instance never consumed it", err)
	}
	if got, want := workerTimeoutsValue(), "n=1 after_lost_start=0 unconsumed=1 ops=materializeapp:1"; got != want {
		t.Errorf("workerTimeoutsValue() = %q, want %q", got, want)
	}
	if got := lostStartsByOpValue(); got != "none" {
		t.Errorf("lostStartsByOpValue() = %q, want none", got)
	}
}

// (c) An answered op is no expiry, whether it was answered at once or after a lost-start re-fire.
func TestWorkerTimeouts_AnsweredOpsAreNotCounted(t *testing.T) {
	t.Run("healthy", func(t *testing.T) {
		f := lsrFakeInit(t, laneRW, lsrStates("running"),
			[]lsrPlan{{kind: lsrAnswer, text: "OK-B", after: 50 * time.Millisecond}})
		resetWorkerTimeouts(t)
		if out := lsrRun(t, f, "materializeapp"); out != "OK-B" {
			t.Fatalf("got %q, want OK-B", out)
		}
		if got := workerTimeoutsValue(); got != emptyWorkerTimeouts {
			t.Errorf("workerTimeoutsValue() = %q, want %q", got, emptyWorkerTimeouts)
		}
	})
	t.Run("recovered", func(t *testing.T) {
		f := lsrFakeInit(t, laneRW, lsrStates("running", "running", "running", "stopped"),
			[]lsrPlan{{kind: lsrIgnore}, {kind: lsrAnswer, text: "OK-A", after: 5 * time.Millisecond}})
		resetWorkerTimeouts(t)
		if out := lsrRun(t, f, "materializeapp"); out != "OK-A" {
			t.Fatalf("got %q, want OK-A", out)
		}
		if got := workerTimeoutsValue(); got != emptyWorkerTimeouts {
			t.Errorf("workerTimeoutsValue() = %q, want %q", got, emptyWorkerTimeouts)
		}
		if got, want := lostStartsByOpValue(), "materializeapp=1"; got != want {
			t.Errorf("lostStartsByOpValue() = %q, want %q", got, want)
		}
	})
}

// (d) The by-op lists: sorted, a token that is not a fixed op word becomes "other", at most 12 items and then +<k>.
func TestWorkerTimeouts_ByOpTokensAndCap(t *testing.T) {
	resetLostStarts(t)
	resetWorkerTimeouts(t)
	if got := lostStartsByOpValue(); got != "none" {
		t.Fatalf("control: lostStartsByOpValue() = %q on a reset count, want none", got)
	}
	noteLostStart("bootsweep")
	noteLostStart("materializeapp")
	noteLostStart("bootsweep")
	if got, want := lostStartsByOpValue(), "bootsweep=2 materializeapp=1"; got != want {
		t.Errorf("lostStartsByOpValue() = %q, want %q", got, want)
	}
	for _, bad := range []string{"a/b", "Bootsweep", strings.Repeat("a", 25)} {
		resetWorkerTimeouts(t)
		noteLostStart(bad)
		noteWorkerTimeout(bad, false, false)
		if got := lostStartsByOpValue(); got != "other=1" {
			t.Errorf("op %q: lostStartsByOpValue() = %q, want other=1", bad, got)
		}
		if got, want := workerTimeoutsValue(), "n=1 after_lost_start=0 unconsumed=0 ops=other:1"; got != want {
			t.Errorf("op %q: workerTimeoutsValue() = %q, want %q", bad, got, want)
		}
	}
	resetWorkerTimeouts(t)
	var lost, exp []string
	for i := 0; i < 13; i++ {
		op := fmt.Sprintf("op%02d", i)
		noteLostStart(op)
		noteWorkerTimeout(op, true, true)
		if i < 12 {
			lost = append(lost, op+"=1")
			exp = append(exp, op+":1")
		}
	}
	if got, want := lostStartsByOpValue(), strings.Join(lost, " ")+" +1"; got != want {
		t.Errorf("13 ops: lostStartsByOpValue() = %q, want %q", got, want)
	}
	if got, want := workerTimeoutsValue(), "n=13 after_lost_start=13 unconsumed=13 ops="+strings.Join(exp, ",")+",+1"; got != want {
		t.Errorf("13 ops: workerTimeoutsValue() = %q, want %q", got, want)
	}
}

// (e) Both keys reach the report at BOTH scopes, the gate's included.
func TestIssueReportCarriesWorkerTimeouts(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	resetLostStarts(t)
	resetWorkerTimeouts(t)
	noteLostStart("bootsweep")
	noteWorkerTimeout("materializeapp", true, false)
	wantT, wantL := workerTimeoutsValue(), lostStartsByOpValue()
	if wantT == emptyWorkerTimeouts || wantL == "none" {
		t.Fatalf("control: the seeded counts read empty (%q, %q)", wantT, wantL)
	}
	for _, c := range []struct {
		name  string
		scope bool
	}{{"", true}, {"x", false}} {
		rep := buildIssueReport(c.name, c.scope, "", nil, nil)
		if got, ok := rep.Status["roam_worker_timeouts"]; !ok || got != wantT {
			t.Errorf("deviceScope=%v: status roam_worker_timeouts = %q (present=%v), want %q", c.scope, got, ok, wantT)
		}
		if got, ok := rep.Status["roam_lost_starts_by_op"]; !ok || got != wantL {
			t.Errorf("deviceScope=%v: status roam_lost_starts_by_op = %q (present=%v), want %q", c.scope, got, ok, wantL)
		}
	}
}
