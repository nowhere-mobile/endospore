package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20261119-20 (h49 #7, docs/backlog.md section B, the row "The 17.0s "user creation" window"): runWorkerHeld read
// the result file only once per 500 ms workerTick, so a job roamd answered in 100 ms still cost half a second, and
// seed-ssaid at every sign-in paid it. Inside the first workerFastWindow of slept time the poll now sleeps each tick
// in workerFastTick pieces and reads the result after each piece; the progress read, the beat, idle, the stall check
// and the lost-start check stay once per full tick. These cases drive the poll through the workerSleep seam with a
// virtual clock: the fake sleep advances it and writes the stand-in answer once it reaches the answer time, so no case
// sleeps for real and none needs a wall-time bound. The seams are package vars: none of these tests may run in
// parallel.

type wfpFake struct {
	lane     workerLane
	dest     string
	answerAt time.Duration
	text     string
	now      time.Duration
	started  bool
	answered bool
	sleeps   []time.Duration
	samples  int // workerState calls
	starts   int // workerStart calls
	progs    int // onProg calls
}

// wfpSetup installs the seams with the given tick, fast tick and window, and restores them on cleanup. The fake init
// does NOT consume the request (so the lost-start check reads it as pending) and always reads "running" (so a sample
// never re-fires a start): every workerState call is one lost-start check.
func wfpSetup(t *testing.T, tick, fast, window, answerAt time.Duration, text string) *wfpFake {
	t.Helper()
	resetLostStarts(t)
	resetAbandoned(t, nil)
	f := &wfpFake{lane: laneRW, dest: t.TempDir(), answerAt: answerAt, text: text}
	prevTick, prevFast, prevWindow := workerTick, workerFastTick, workerFastWindow
	prevSleep, prevStart, prevState := workerSleep, workerStart, workerState
	t.Cleanup(func() {
		workerTick, workerFastTick, workerFastWindow = prevTick, prevFast, prevWindow
		workerSleep, workerStart, workerState = prevSleep, prevStart, prevState
	})
	workerTick, workerFastTick, workerFastWindow = tick, fast, window
	res := filepath.Join(f.dest, f.lane.res)
	workerSleep = func(d time.Duration) {
		f.sleeps = append(f.sleeps, d)
		f.now += d
		if f.started && !f.answered && f.now >= f.answerAt {
			if err := writeAtomic(res+".tmp", res, []byte(f.text+"\n")); err != nil {
				t.Errorf("fake worker: write res: %v", err)
			}
			f.answered = true
		}
	}
	workerStart = func(svc string) {
		f.starts++
		f.started = true
		// one progress line, so the first tick relays it and the heartbeat has a line to repeat
		if err := os.WriteFile(filepath.Join(f.dest, f.lane.prog), []byte("1/2\n"), 0o600); err != nil {
			t.Errorf("fake worker: write prog: %v", err)
		}
	}
	workerState = func(svc string) string {
		f.samples++
		return "running"
	}
	return f
}

// wfpRun runs a materializeapp op through runWorkerHeld, after control-checking its lane and stall budget.
func wfpRun(t *testing.T, f *wfpFake) string {
	t.Helper()
	const op = "materializeapp"
	if laneFor(op).svc != f.lane.svc {
		t.Fatalf("control: op %q does not route to %s", op, f.lane.svc)
	}
	if workerStallTicks(op) != roamStallTicks {
		t.Fatalf("control: op %q does not use roamStallTicks", op)
	}
	ch := make(chan string, 1)
	go func() {
		ch <- runWorkerHeld(f.lane, f.dest, op, "wfp-profile", "", "10", "", "", "", "", func(string) { f.progs++ })
	}()
	select {
	case out := <-ch:
		return out
	case <-time.After(10 * time.Second):
		t.Fatal("runWorkerHeld did not return within 10s")
		return ""
	}
}

func wfpSum(ds []time.Duration) time.Duration {
	var s time.Duration
	for _, d := range ds {
		s += d
	}
	return s
}

// F1: an answer 30 ms into a 2 s tick is read after six 5 ms sleeps, not after the whole tick.
func TestWorkerFastPoll_AnswerInTheWindowReturnsBeforeOneTick(t *testing.T) {
	f := wfpSetup(t, 2*time.Second, 5*time.Millisecond, time.Second, 30*time.Millisecond, "OK-F1")
	if out := wfpRun(t, f); out != "OK-F1" {
		t.Fatalf("got %q, want the stand-in's answer", out)
	}
	if s := wfpSum(f.sleeps); s >= workerTick {
		t.Fatalf("the poll slept %v (%d sleeps) before it read an answer written at 30ms: want less than one tick (%v)",
			s, len(f.sleeps), workerTick)
	}
	if len(f.sleeps) != 6 {
		t.Errorf("sleeps = %d, want 6 (the answer lands after the 6th 5ms sleep)", len(f.sleeps))
	}
	for i, d := range f.sleeps {
		if d != 5*time.Millisecond {
			t.Errorf("sleep %d = %v, want 5ms inside the window", i, d)
		}
	}
	if _, err := os.Stat(filepath.Join(f.dest, f.lane.res)); !os.IsNotExist(err) {
		t.Errorf("the result file was not removed after the fast read (%v)", err)
	}
	if _, err := os.Stat(filepath.Join(f.dest, f.lane.prog)); !os.IsNotExist(err) {
		t.Errorf("the progress file was not removed after the fast read (%v)", err)
	}
	if n := roamLostStarts.Load(); n != 0 {
		t.Errorf("roamLostStarts = %d, want 0", n)
	}
}

// F2: an answer at or after the window is still returned, and the per-tick counts are the pre-change loop's for the
// same span: idle (seen through the lost-start samples and the stall budget), the heartbeat and the lost-start count.
// With a 1 ms fast tick there are 500 fast sleeps per tick, so idle counted per fast sleep passes roamStallTicks (300)
// inside the first tick and the op answers ERR-TIMEOUT.
func TestWorkerFastPoll_AnswerAfterTheWindowKeepsTheTickCounts(t *testing.T) {
	const tick = 500 * time.Millisecond
	for _, answerAt := range []time.Duration{1500 * time.Millisecond, 10500 * time.Millisecond} {
		t.Run(answerAt.String(), func(t *testing.T) {
			f := wfpSetup(t, tick, time.Millisecond, time.Second, answerAt, "OK-F2")
			if out := wfpRun(t, f); out != "OK-F2" {
				t.Fatalf("got %q, want the stand-in's answer", out)
			}
			n := int(answerAt / tick) // the tick at whose end the answer is read
			// The pre-change loop: idle is n-1 at the read (no timeout), a lost-start check at idle 4, 8, ...,
			// the first relay plus one heartbeat per 20 beats.
			if want := (n - 1) / 4; f.samples != want {
				t.Errorf("lost-start checks (workerState calls) = %d, want %d for %d ticks", f.samples, want, n)
			}
			if want := 1 + n/20; f.progs != want {
				t.Errorf("onProg calls = %d, want %d (one relay and %d heartbeats)", f.progs, want, n/20)
			}
			if f.starts != 1 {
				t.Errorf("workerStart calls = %d, want 1", f.starts)
			}
			if c := roamLostStarts.Load(); c != 0 {
				t.Errorf("roamLostStarts = %d, want 0 (noteLostStart called)", c)
			}
			fast, full := 0, 0
			for _, d := range f.sleeps {
				switch d {
				case time.Millisecond:
					fast++
				case tick:
					full++
				default:
					t.Fatalf("a sleep of %v: want 1ms or %v only", d, tick)
				}
			}
			if fast != 1000 || full != n-2 {
				t.Errorf("sleeps: %d fast + %d full, want 1000 fast (ticks 1 and 2) + %d full", fast, full, n-2)
			}
		})
	}
}

// F3: once the poll has slept workerFastWindow, it sleeps whole ticks only.
func TestWorkerFastPoll_AfterTheWindowSleepsFullTicksOnly(t *testing.T) {
	const tick, fastTick = 100 * time.Millisecond, 5 * time.Millisecond
	f := wfpSetup(t, tick, fastTick, time.Second, 3*time.Second, "OK-F3")
	if out := wfpRun(t, f); out != "OK-F3" {
		t.Fatalf("got %q, want the stand-in's answer", out)
	}
	var slept time.Duration
	fast := 0
	for i, d := range f.sleeps {
		if slept >= time.Second && d != tick {
			t.Fatalf("sleep %d = %v after %v slept: want only full %v ticks after the 1s window", i, d, slept, tick)
		}
		if d == fastTick {
			fast++
		}
		slept += d
	}
	if want := int(time.Second / fastTick); fast != want {
		t.Errorf("fast sleeps = %d, want %d (the 1s window)", fast, want)
	}
}

// The production values, and the guard the older seam tests rely on: a workerTick no longer than workerFastTick (the
// 1 ms tick of lost_start_recovery_test.go and worker_abandoned_test.go) turns the fast poll off.
func TestWorkerFastPoll_DefaultsAndGuard(t *testing.T) {
	if workerFastTick != 25*time.Millisecond {
		t.Errorf("workerFastTick = %v, want 25ms", workerFastTick)
	}
	if workerFastWindow != time.Second {
		t.Errorf("workerFastWindow = %v, want 1s", workerFastWindow)
	}
	if workerTick != 500*time.Millisecond {
		t.Errorf("workerTick = %v, want 500ms", workerTick)
	}
	f := wfpSetup(t, time.Millisecond, 25*time.Millisecond, time.Second, 5*time.Millisecond, "OK-G")
	if out := wfpRun(t, f); out != "OK-G" {
		t.Fatalf("got %q, want the stand-in's answer", out)
	}
	if len(f.sleeps) != 5 {
		t.Errorf("sleeps = %d, want 5 full 1ms ticks", len(f.sleeps))
	}
	for i, d := range f.sleeps {
		if d != time.Millisecond {
			t.Errorf("sleep %d = %v, want the full 1ms tick: the fast poll must be off when it is not shorter", i, d)
		}
	}
}
