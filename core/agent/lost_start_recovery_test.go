package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261021-14 (docs/backlog.md, the row "The #83 lost-start race fires ROUTINELY"): runWorkerHeld's lost-start
// recovery -- the idle%4 block that re-fires ctl.start when the service reads "stopped" while our request is still
// pending -- ran under no test: on a host every runWorkerHeld test got a failing getprop. These cases run it against a
// fake init through the workerTick / workerStart / workerState seams.
//
// The claim they execute: "stopped" is not the transient state. The transient one is a dying instance init still
// reports as "running" (init ignores a ctl.start then). A oneshot service then reads "stopped" from its exit until the
// next start (an INFERENCE from AOSP init's oneshot handling, not read here), so a 2 s sample cannot miss it, and an op
// only expires when the instance that ignored the start does not exit within the stall budget.
//
// The fake init is deterministic: a start it HONOURS removes the lane's req synchronously (roamd's first act) and from
// then on the service reads "running" until the stand-in roamd has written res, so no scripted "stopped" can race a
// further start. The seams are package vars, so none of these tests may run in parallel.

type lsrKind int

const (
	lsrIgnore lsrKind = iota // init ignored the start: the dying instance never reads the request
	lsrAnswer                // a fresh instance consumes the request and answers after a delay
	lsrCrash                 // a fresh instance consumes the request and exits without ever answering
)

type lsrPlan struct {
	kind  lsrKind
	text  string
	after time.Duration
}

type lsrStart struct {
	svc         string
	afterSample int    // workerState calls made before this start
	reqOp       string // first line of the request an honoured start consumed ("" if it was ignored)
}

type lsrInit struct {
	mu       sync.Mutex
	lane     workerLane
	dest     string
	states   []string
	plan     []lsrPlan
	samples  int
	starts   []lsrStart
	override string
	done     chan struct{}
}

func (f *lsrInit) snapshot() (int, []lsrStart) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.samples, append([]lsrStart(nil), f.starts...)
}

// lsrFakeInit installs the three seams for one test and restores them (and the lost-start counter) on cleanup. A start
// past the end of plan is ignored, and still recorded, so a start that should not have happened is visible.
func lsrFakeInit(t *testing.T, lane workerLane, states []string, plan []lsrPlan) *lsrInit {
	t.Helper()
	resetLostStarts(t)
	resetAbandoned(t, nil)
	f := &lsrInit{lane: lane, dest: t.TempDir(), states: states, plan: plan, done: make(chan struct{})}
	prevTick, prevStart, prevState := workerTick, workerStart, workerState
	t.Cleanup(func() {
		close(f.done)
		workerTick, workerStart, workerState = prevTick, prevStart, prevState
	})
	workerTick = time.Millisecond
	workerState = func(svc string) string {
		f.mu.Lock()
		defer f.mu.Unlock()
		i := f.samples
		f.samples++
		if f.override != "" {
			return f.override
		}
		if i >= len(f.states) {
			i = len(f.states) - 1
		}
		return f.states[i]
	}
	workerStart = func(svc string) {
		f.mu.Lock()
		defer f.mu.Unlock()
		idx := len(f.starts)
		rec := lsrStart{svc: svc, afterSample: f.samples}
		defer func() { f.starts = append(f.starts, rec) }()
		if idx >= len(f.plan) || f.plan[idx].kind == lsrIgnore {
			return
		}
		req := filepath.Join(f.dest, f.lane.req)
		if b, err := os.ReadFile(req); err == nil {
			rec.reqOp = strings.SplitN(string(b), "\n", 2)[0]
		}
		os.Remove(req) // roamd's first act, synchronous so nothing can start again for this request
		p := f.plan[idx]
		if p.kind == lsrCrash {
			f.override = "stopped"
			return
		}
		f.override = "running"
		res := filepath.Join(f.dest, f.lane.res)
		go func() {
			select {
			case <-time.After(p.after):
			case <-f.done:
				return
			}
			writeAtomic(res+".tmp", res, []byte(p.text+"\n"))
			f.mu.Lock()
			f.override = "stopped"
			f.mu.Unlock()
		}()
	}
	return f
}

// lsrRun runs op on lane through runWorkerHeld, after control-checking that the op really routes to that lane with the
// ordinary stall budget; a regression fails the test instead of hanging it.
func lsrRun(t *testing.T, f *lsrInit, op string) string {
	t.Helper()
	if laneFor(op).svc != f.lane.svc {
		t.Fatalf("control: op %q does not route to %s", op, f.lane.svc)
	}
	if workerStallTicks(op) != roamStallTicks {
		t.Fatalf("control: op %q does not use roamStallTicks", op)
	}
	ch := make(chan string, 1)
	go func() { ch <- runWorkerHeld(f.lane, f.dest, op, "p", "", "10", "", "", "", "", nil) }()
	select {
	case out := <-ch:
		return out
	case <-time.After(10 * time.Second):
		t.Fatal("runWorkerHeld did not return within 10s")
		return ""
	}
}

func lsrStates(s ...string) []string { return s }

func lsrLostStartCase(t *testing.T, lane workerLane, op string) {
	f := lsrFakeInit(t, lane,
		lsrStates("running", "running", "running", "stopped"),
		[]lsrPlan{{kind: lsrIgnore}, {kind: lsrAnswer, text: "OK-A", after: 5 * time.Millisecond}})
	if out := lsrRun(t, f, op); out != "OK-A" {
		t.Fatalf("a lost start was not recovered: got %q, want the stand-in's answer", out)
	}
	samples, starts := f.snapshot()
	if samples < 4 {
		t.Fatalf("control: only %d samples taken, the scripted \"stopped\" (4th) was never read", samples)
	}
	if len(starts) != 2 {
		t.Fatalf("starts = %d, want exactly 2 (the first, ignored, and one re-fire)", len(starts))
	}
	if starts[1].afterSample < 4 {
		t.Errorf("the re-fire came after %d samples: it fired before the service was read \"stopped\"", starts[1].afterSample)
	}
	if starts[0].svc != lane.svc || starts[1].svc != lane.svc {
		t.Errorf("starts named %q and %q, want the lane's own service %q", starts[0].svc, starts[1].svc, lane.svc)
	}
	if starts[1].reqOp != op {
		t.Errorf("the re-fired start consumed request %q, want %q", starts[1].reqOp, op)
	}
	if n := roamLostStarts.Load(); n != 1 {
		t.Errorf("roamLostStarts = %d, want 1", n)
	}
}

func TestLostStartRecovery_LostStartIsRefired(t *testing.T) {
	lsrLostStartCase(t, laneRW, "materializeapp")
}

func TestLostStartRecovery_ReadOnlyLaneRefiresItsOwnService(t *testing.T) {
	lsrLostStartCase(t, laneRO, "storagebreakdown")
}

func TestLostStartRecovery_HealthyStartIsNotRefired(t *testing.T) {
	f := lsrFakeInit(t, laneRW, lsrStates("running"),
		[]lsrPlan{{kind: lsrAnswer, text: "OK-B", after: 50 * time.Millisecond}})
	if out := lsrRun(t, f, "materializeapp"); out != "OK-B" {
		t.Fatalf("got %q, want the stand-in's answer", out)
	}
	_, starts := f.snapshot()
	if len(starts) != 1 || starts[0].reqOp != "materializeapp" {
		t.Fatalf("starts = %+v, want exactly one that consumed the request", starts)
	}
	if n := roamLostStarts.Load(); n != 0 {
		t.Errorf("roamLostStarts = %d, want 0 for a healthy start", n)
	}
}

func TestLostStartRecovery_ConsumedRequestIsNeverRerun(t *testing.T) {
	f := lsrFakeInit(t, laneRW, lsrStates("stopped"), []lsrPlan{{kind: lsrCrash}})
	if out := lsrRun(t, f, "materializeapp"); out != "ERR-TIMEOUT" {
		t.Fatalf("got %q, want ERR-TIMEOUT for an instance that consumed the request and never answered", out)
	}
	_, starts := f.snapshot()
	if len(starts) != 1 {
		t.Fatalf("starts = %d, want 1: a consumed request was started again -- a second seal", len(starts))
	}
	if n := roamLostStarts.Load(); n != 0 {
		t.Errorf("roamLostStarts = %d, want 0", n)
	}
}

func TestLostStartRecovery_HungInstanceExpires(t *testing.T) {
	f := lsrFakeInit(t, laneRW, lsrStates("running"), []lsrPlan{{kind: lsrIgnore}})
	if out := lsrRun(t, f, "materializeapp"); out != "ERR-TIMEOUT" {
		t.Fatalf("got %q, want ERR-TIMEOUT: the residual is an instance that does not exit within the stall budget", out)
	}
	_, starts := f.snapshot()
	if len(starts) != 1 {
		t.Fatalf("starts = %d, want 1: the service never read \"stopped\", so nothing may be re-fired", len(starts))
	}
	if _, err := os.Stat(filepath.Join(f.dest, f.lane.req)); err != nil {
		t.Errorf("the request is gone (%v): the hung instance never consumed it", err)
	}
	if n := roamLostStarts.Load(); n != 0 {
		t.Errorf("roamLostStarts = %d, want 0", n)
	}
}

func TestLostStartRecovery_SeamDefaults(t *testing.T) {
	if workerTick != 500*time.Millisecond {
		t.Errorf("workerTick = %v, want 500ms", workerTick)
	}
	if roamStallBudget != roamStallTicks*workerTick {
		t.Errorf("roamStallBudget = %v, want roamStallTicks x workerTick", roamStallBudget)
	}
}
