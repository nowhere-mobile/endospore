package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261022-02 (docs/backlog.md §H, "An abandoned worker op's late reply is no longer read by the next op on its
// lane"): after an op returned ERR-TIMEOUT its roamd instance is still running, init ignores a ctl.start while it
// does, and the reply channel has no request id -- so the next op's poll used to return the OLD instance's reply as
// its own. These cases drive runWorkerHeld through the workerTick / workerStart / workerState seams against a fake
// init that, like init, IGNORES a ctl.start while the service reads "running" (lsrFakeInit honours every planned
// start, so it cannot show the bug). The seams are package vars: none of these tests may run in parallel.

// resetAbandoned installs m (nil = no lane recorded) as the abandoned record and restores the previous one on cleanup.
func resetAbandoned(t *testing.T, m map[string]string) {
	t.Helper()
	abandonedMu.Lock()
	prev := abandonedOp
	abandonedOp = map[string]string{}
	for k, v := range m {
		abandonedOp[k] = v
	}
	abandonedMu.Unlock()
	t.Cleanup(func() {
		abandonedMu.Lock()
		abandonedOp = prev
		abandonedMu.Unlock()
	})
}

type abPlan struct {
	lane    workerLane
	text    string
	release chan struct{} // the stand-in answers when this closes; nil = after 5 ms
}

type abStart struct {
	svc           string
	reqOp         string // first line of the request an honoured start consumed
	ignored       bool
	samplesBefore int // workerState calls for svc before this start
}

type abInit struct {
	mu      sync.Mutex
	dest    string
	running map[string]bool
	samples map[string]int
	plan    []abPlan
	next    int
	starts  []abStart
	done    chan struct{}
}

func abFakeInit(t *testing.T, plan []abPlan) *abInit {
	t.Helper()
	f := &abInit{dest: t.TempDir(), running: map[string]bool{}, samples: map[string]int{}, plan: plan, done: make(chan struct{})}
	prevTick, prevStart, prevState := workerTick, workerStart, workerState
	t.Cleanup(func() {
		close(f.done)
		workerTick, workerStart, workerState = prevTick, prevStart, prevState
	})
	workerTick = time.Millisecond
	workerState = func(svc string) string {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.samples[svc]++
		if f.running[svc] {
			return "running"
		}
		return "stopped"
	}
	workerStart = func(svc string) {
		f.mu.Lock()
		defer f.mu.Unlock()
		rec := abStart{svc: svc, samplesBefore: f.samples[svc]}
		defer func() { f.starts = append(f.starts, rec) }()
		if f.running[svc] || f.next >= len(f.plan) {
			rec.ignored = true
			return
		}
		p := f.plan[f.next]
		f.next++
		req := filepath.Join(f.dest, p.lane.req)
		if b, err := os.ReadFile(req); err == nil {
			rec.reqOp = strings.SplitN(string(b), "\n", 2)[0]
		}
		os.Remove(req) // roamd's first act
		f.running[svc] = true
		res := filepath.Join(f.dest, p.lane.res)
		go func() {
			if p.release != nil {
				select {
				case <-p.release:
				case <-f.done:
					return
				}
			} else {
				select {
				case <-time.After(5 * time.Millisecond):
				case <-f.done:
					return
				}
			}
			writeAtomic(res+".tmp", res, []byte(p.text+"\n"))
			f.mu.Lock()
			f.running[svc] = false
			f.mu.Unlock()
		}()
	}
	return f
}

func (f *abInit) snapshot() []abStart {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]abStart(nil), f.starts...)
}

func (f *abInit) setRunning(svc string, v bool) {
	f.mu.Lock()
	f.running[svc] = v
	f.mu.Unlock()
}

func (f *abInit) sampleCount(svc string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.samples[svc]
}

func (f *abInit) waitStopped(t *testing.T, svc string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		f.mu.Lock()
		r := f.running[svc]
		f.mu.Unlock()
		if !r {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("stand-in for %s did not stop within 5s", svc)
}

// abRunAsync runs op on its own lane through runWorkerHeld and returns the channel its answer arrives on.
func abRunAsync(t *testing.T, f *abInit, op string) <-chan string {
	t.Helper()
	lane := laneFor(op)
	ch := make(chan string, 1)
	go func() { ch <- runWorkerHeld(lane, f.dest, op, "p", "", "10", "", "", "", "", nil) }()
	return ch
}

func abWait(t *testing.T, ch <-chan string) string {
	t.Helper()
	select {
	case out := <-ch:
		return out
	case <-time.After(10 * time.Second):
		t.Fatal("runWorkerHeld did not return within 10s")
		return ""
	}
}

func abRun(t *testing.T, f *abInit, op string) string {
	t.Helper()
	return abWait(t, abRunAsync(t, f, op))
}

// abAbandon makes op time out on laneRW with its stand-in still running; release lets the stand-in answer later.
func abAbandon(t *testing.T, f *abInit, op string) {
	t.Helper()
	if laneFor(op).svc != laneRW.svc || workerStallTicks(op) != roamStallTicks {
		t.Fatalf("control: op %q does not run on laneRW with the ordinary stall budget", op)
	}
	if out := abRun(t, f, op); out != "ERR-TIMEOUT" {
		t.Fatalf("control: the first op returned %q, want ERR-TIMEOUT", out)
	}
	if got := laneAbandonedOp(laneRW); got != op {
		t.Fatalf("the timed-out op was recorded as %q, want %q", got, op)
	}
}

// abNoAnswerWithin returns the answer if one arrives within d, else "" and false.
func abNoAnswerWithin(ch <-chan string, d time.Duration) (string, bool) {
	select {
	case out := <-ch:
		return out, true
	case <-time.After(d):
		return "", false
	}
}

func TestAbandonedOpOnTheLaneAnswersBusyWhileItRuns(t *testing.T) {
	resetAbandoned(t, nil)
	release := make(chan struct{})
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK 11", release: release}, {lane: laneRW, text: "OK-B"}})
	abAbandon(t, f, "materializeapp")
	startsAfterA := len(f.snapshot())

	var logs string
	busyOps := []string{"in", "odrestore"}
	for _, op := range busyOps {
		var out string
		logs = captureStderr(t, func() {
			ch := abRunAsync(t, f, op)
			var ok bool
			if out, ok = abNoAnswerWithin(ch, 200*time.Millisecond); !ok {
				close(release) // let the old instance answer: the bug returns its reply as this op's
				release = make(chan struct{})
				out = abWait(t, ch)
			}
		})
		if out != workerBusy {
			t.Fatalf("op %q issued while the abandoned instance runs returned %q, want exactly %q", op, out, workerBusy)
		}
		if n := len(f.snapshot()); n != startsAfterA {
			t.Fatalf("op %q started the service (%d starts, want %d)", op, n, startsAfterA)
		}
		if b, err := os.ReadFile(filepath.Join(f.dest, laneRW.req)); err == nil && strings.SplitN(string(b), "\n", 2)[0] == op {
			t.Fatalf("op %q's request was written to roam.req while the abandoned instance runs", op)
		}
		if !strings.Contains(logs, "materializeapp op this daemon gave up on is still running -- "+op+" answered busy") {
			t.Errorf("busy line for %q missing from log:\n%s", op, logs)
		}
	}
}

func TestAbandonedLateReplyIsDiscardedOnceItStops(t *testing.T) {
	resetAbandoned(t, nil)
	release := make(chan struct{})
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK 11", release: release}, {lane: laneRW, text: "OK-C"}})
	abAbandon(t, f, "materializeapp")
	close(release)
	f.waitStopped(t, laneRW.svc)

	var out string
	logs := captureStderr(t, func() { out = abRun(t, f, "materializeapp") })
	if out != "OK-C" {
		t.Fatalf("got %q, want the new op's own answer (never the abandoned instance's \"OK 11\")", out)
	}
	starts := f.snapshot()
	if len(starts) != 2 || starts[1].ignored || starts[1].reqOp != "materializeapp" {
		t.Fatalf("starts = %+v, want a second, honoured start that consumed the new request", starts)
	}
	if !strings.Contains(logs, "discarded the late reply of the abandoned materializeapp op (OK)") {
		t.Errorf("discard line missing from log:\n%s", logs)
	}
	if strings.Contains(logs, "11") {
		t.Errorf("the log carries more than the reply's first word:\n%s", logs)
	}
	if got := laneAbandonedOp(laneRW); got != "" {
		t.Errorf("the record survives the discard: %q", got)
	}
}

func TestAbandonedJSONReplyIsLoggedAsData(t *testing.T) {
	resetAbandoned(t, map[string]string{laneRW.svc: "materializeapp"})
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK-D"}})
	if err := os.WriteFile(filepath.Join(f.dest, laneRW.res), []byte(`{"total":4096,"uid":11}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var out string
	logs := captureStderr(t, func() { out = abRun(t, f, "materializeapp") })
	if out != "OK-D" {
		t.Fatalf("got %q, want the op's own answer", out)
	}
	if !strings.Contains(logs, "(<data>)") {
		t.Errorf("a JSON-looking reply was not logged as <data>:\n%s", logs)
	}
	if strings.Contains(logs, "total") || strings.Contains(logs, "4096") {
		t.Errorf("reply content reached the log:\n%s", logs)
	}
}

func TestAbandonedReplyToken(t *testing.T) {
	for in, want := range map[string]string{
		"OK 11":       "OK",
		"ERR-TIMEOUT": "ERR-TIMEOUT",
		"BLANK NET":   "BLANK",
		`{"total":1}`: "<data>",
		"ok":          "<data>",
		"":            "<data>",
		"  \n":        "<data>",
	} {
		if got := abandonedReplyToken(in); got != want {
			t.Errorf("abandonedReplyToken(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAbandonedRecordIsPerLane(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK 11", release: make(chan struct{})}, {lane: laneRO, text: "OK-RO"}})
	abAbandon(t, f, "materializeapp")
	if got := laneAbandonedOp(laneRO); got != "" {
		t.Errorf("laneRO recorded as %q by an laneRW abandonment", got)
	}
	if got := laneAbandonedOp(laneCred); got != "" {
		t.Errorf("laneCred recorded as %q by an laneRW abandonment", got)
	}
	if out := abRun(t, f, "storagebreakdown"); out != "OK-RO" {
		t.Fatalf("the RO op returned %q, want its own answer", out)
	}
	starts := f.snapshot()
	if last := starts[len(starts)-1]; last.svc != laneRO.svc || last.ignored || last.samplesBefore != 0 {
		t.Errorf("RO start = %+v, want an honoured start with no state sample before it", last)
	}
}

func TestAbandonedNeverAbandonedLaneTakesNoSample(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK-E"}})
	if out := abRun(t, f, "materializeapp"); out != "OK-E" {
		t.Fatalf("got %q, want the op's answer", out)
	}
	starts := f.snapshot()
	if len(starts) != 1 || starts[0].samplesBefore != 0 {
		t.Fatalf("starts = %+v, want one start with no workerState sample before it", starts)
	}
}

func TestAbandonedDaemonStartMarksEveryLane(t *testing.T) {
	resetAbandoned(t, abandonedAtDaemonStart())
	for _, l := range []workerLane{laneRW, laneRO, laneCred} {
		if got := laneAbandonedOp(l); got != "(daemon start)" {
			t.Errorf("lane %s reads %q at daemon start, want \"(daemon start)\"", l.svc, got)
		}
	}
	f := abFakeInit(t, []abPlan{{lane: laneRO, text: "OK-RO"}})
	f.setRunning(laneRW.svc, true)
	var out string
	logs := captureStderr(t, func() { out = abRun(t, f, "materializeapp") })
	if out != workerBusy {
		t.Fatalf("first op on a running lane after daemon start returned %q, want %q", out, workerBusy)
	}
	if len(f.snapshot()) != 0 {
		t.Errorf("a busy answer started something: %+v", f.snapshot())
	}
	if !strings.Contains(logs, "(daemon start) op this daemon gave up on is still running") {
		t.Errorf("busy line does not name the daemon start:\n%s", logs)
	}
	if out := abRun(t, f, "storagebreakdown"); out != "OK-RO" {
		t.Errorf("first op on a stopped lane returned %q, want it to run", out)
	}
}

// The package var's initialiser is what marks a fresh daemon; a source pin, as signin_stall_test.go does.
func TestAbandonedInitialValueIsTheDaemonStartMarking(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "var abandonedOp = abandonedAtDaemonStart()") {
		t.Error("main.go no longer initialises abandonedOp with abandonedAtDaemonStart()")
	}
}
