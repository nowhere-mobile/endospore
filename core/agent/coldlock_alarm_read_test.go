package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261129-26. Backlog row "The gate can read its alarm stash before a cold lock's at-lock relay lands, so an alarm
// set while the phone was offline is never scheduled at the gate". Since NWP-20261121-01 the relay runs behind the
// switch, and the gate reads and clears the stash once per onResume. With the screen on the read answered 0 and the
// relay then landed with no reader. GET-GATE-ALARM now waits, bounded, from the commit until the relay ends.

const clarGuard = 20 * time.Second

// clarHook replaces atLockRelayWaitStarted. The restore and the marker's end are cleanups, so a test that registers
// them BEFORE clwSetup has them run after clwSetup's cleanup, which waits for the teardown goroutine.
func clarHook(t *testing.T, hook func()) {
	t.Helper()
	prev := atLockRelayWaitStarted
	atLockRelayWaitStarted = hook
	t.Cleanup(func() {
		atLockRelayWaitStarted = prev
		endAtLockRelay()
	})
}

// clarRunning sets coldLockRunning by hand, for the tests that put a marker in flight with no teardown.
func clarRunning(running bool) {
	coldLockMu.Lock()
	coldLockRunning = running
	coldLockMu.Unlock()
}

// clarManual prepares a marker by hand: the teardown reported as running, and the bound restored afterwards.
func clarManual(t *testing.T) {
	t.Helper()
	prevWait := gateAlarmReadWait
	coldLockMu.Lock()
	prevRunning := coldLockRunning
	coldLockRunning = true
	coldLockMu.Unlock()
	t.Cleanup(func() {
		gateAlarmReadWait = prevWait
		clarRunning(prevRunning)
		endAtLockRelay()
	})
}

// clarAnswer sends one request and returns its reply, or fails after the hang guard.
func clarAnswer(t *testing.T, dest, req string) string {
	t.Helper()
	select {
	case got := <-driveLoginAsync(t, dest, req):
		return got
	case <-time.After(clarGuard):
		t.Fatalf("%q did not answer in %s", strings.TrimSpace(req), clarGuard)
		return ""
	}
}

func clarStash(t *testing.T, dest, when string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, "gate-alarm"), []byte(when+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// R1, through the real teardown: a GET-GATE-ALARM sent while the relay is in flight answers the relayed time.
func TestColdLockAlarmReadWaitsForTheRelay(t *testing.T) {
	waiting := make(chan struct{})
	var once sync.Once
	clarHook(t, func() { once.Do(func() { close(waiting) }) })
	dest, _, _ := clwSetup(t)
	asGate(t)

	when := strconv.FormatInt(time.Now().Add(time.Hour).UnixMilli(), 10)
	reply := make(chan string, 1)
	answered := make(chan struct{})
	var early atomic.Bool
	var setReply atomic.Value
	// The stub runs on the teardown goroutine: no t.Fatal in it.
	coldLockRelayAlarm = func(dest, name, pass, uid string) {
		go func() {
			reply <- driveLogin(t, dest, "GET-GATE-ALARM\n")
			close(answered)
		}()
		select {
		case <-answered:
			early.Store(true)
		case <-waiting:
			setReply.Store(driveLogin(t, dest, "SET-GATE-ALARM\n"+when+"\t10\tcom.example.clock\n"))
		}
	}
	clwLock(t, dest, 0)
	if !clwWaitFor(clarGuard, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	var got string
	select {
	case got = <-reply:
	case <-time.After(clarGuard):
		t.Fatalf("GET-GATE-ALARM did not answer in %s", clarGuard)
	}
	if got != when {
		t.Errorf("GET-GATE-ALARM answered %q (before the relay: %v), want the relayed %q: the gate reads the stash "+
			"once, so an alarm relayed after this answer never rings", got, early.Load(), when)
	}
	if !early.Load() {
		if r, _ := setReply.Load().(string); r != "OK" {
			t.Errorf("SET-GATE-ALARM answered %q, want OK", r)
		}
	}
}

// R2: a GET outside a relay answers at once, and no other verb waits during one.
func TestColdLockAlarmReadOnlyGetInARelayWaits(t *testing.T) {
	var hooked atomic.Int64
	clarHook(t, func() {
		hooked.Add(1)
		endAtLockRelay() // a mutant that makes another verb wait fails at once, and does not wait out the bound
	})
	clarManual(t)
	asGate(t)

	dest := t.TempDir()
	clarStash(t, dest, "12345")
	endAtLockRelay()
	if got := clarAnswer(t, dest, "GET-GATE-ALARM\n"); got != "12345" {
		t.Errorf("GET-GATE-ALARM with no marker answered %q, want the stash 12345", got)
	}
	if n := hooked.Load(); n != 0 {
		t.Errorf("GET-GATE-ALARM with no marker waited (%d)", n)
	}

	beginAtLockRelay()
	if !atLockRelayInFlight() {
		t.Fatal("control failed: the marker is not in flight, so the STATUS check proves nothing")
	}
	if got := clarAnswer(t, t.TempDir(), "STATUS\n"); got != "NONE" {
		t.Errorf("STATUS during a relay answered %q, want NONE", got)
	}
	if n := hooked.Load(); n != 0 {
		t.Errorf("STATUS waited for the relay (%d): only GET-GATE-ALARM reads the stash", n)
	}
}

// R3: the wait is bounded, and a marker whose teardown has ended holds nobody.
func TestColdLockAlarmReadWaitIsBounded(t *testing.T) {
	var hooked atomic.Int64
	clarHook(t, func() { hooked.Add(1) })
	clarManual(t)
	asGate(t)
	dest := t.TempDir()

	clarStash(t, dest, "12345")
	gateAlarmReadWait = 200 * time.Millisecond
	t0 := time.Now()
	beginAtLockRelay() // no end: only the bound can free the read
	if got := clarAnswer(t, dest, "GET-GATE-ALARM\n"); got != "12345" {
		t.Errorf("GET-GATE-ALARM at the bound answered %q, want the stash as it stood, 12345", got)
	}
	if n := hooked.Load(); n != 1 {
		t.Errorf("the hook ran %d times, want once: the read did not wait, so the bound is not tested", n)
	}
	if d := time.Since(t0); d < 150*time.Millisecond {
		t.Errorf("GET-GATE-ALARM answered after %s, before the 200ms bound", d)
	}

	// A fresh marker with a long bound, so only the teardown condition can free this read.
	hooked.Store(0)
	clarStash(t, dest, "67890")
	gateAlarmReadWait = time.Minute
	beginAtLockRelay()
	if !atLockRelayInFlight() {
		t.Fatal("control failed: the marker is not in flight with the teardown running")
	}
	clarRunning(false)
	if atLockRelayInFlight() {
		t.Error("the marker outlived its teardown")
	}
	if got := clarAnswer(t, dest, "GET-GATE-ALARM\n"); got != "67890" {
		t.Errorf("GET-GATE-ALARM after the teardown ended answered %q, want the stash 67890", got)
	}
	if n := hooked.Load(); n != 0 {
		t.Errorf("GET-GATE-ALARM waited on a marker whose teardown has ended (%d)", n)
	}
}

// R4: through a whole teardown the marker is in flight at the relay and has ended by the sweep. The teardown condition
// cannot hide a missing end there, because the teardown is still running.
func TestColdLockAlarmReadRelayEndsBeforeTheSweep(t *testing.T) {
	clarHook(t, func() {})
	dest, _, _ := clwSetup(t)
	var relays, sweeps atomic.Int64
	var atRelay, atSweep atomic.Bool
	coldLockRelayAlarm = func(dest, name, pass, uid string) {
		relays.Add(1)
		atRelay.Store(atLockRelayInFlight())
	}
	coldLockSweepMedia = func(dest, name, pass, uid string) {
		sweeps.Add(1)
		atSweep.Store(atLockRelayInFlight())
	}
	clwLock(t, dest, 0)
	if !clwWaitFor(clarGuard, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if relays.Load() != 1 || sweeps.Load() != 1 {
		t.Fatalf("control failed: relay=%d sweep=%d, want one each", relays.Load(), sweeps.Load())
	}
	if !atRelay.Load() {
		t.Error("the marker was not in flight at the relay: a GET sent then answers before the relay lands")
	}
	if atSweep.Load() {
		t.Error("the marker was still in flight at the sweep: a GET waits on after the relay has ended")
	}
}

// R5, the two lines in the source: the commit's begin before anything can answer COMMITTED or switch, and the end
// right after the relay.
func TestColdLockAlarmReadSourceOrder(t *testing.T) {
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	i := strings.Index(src, "func coldLockTeardown(")
	if i < 0 {
		t.Fatal("control failed: coldLockTeardown not found in main.go")
	}
	body := src[i:]
	if j := strings.Index(body, "\n}\n"); j > 0 {
		body = body[:j]
	}
	lines := codeLines(body)
	begin, end, commit, sw := -1, -1, -1, -1
	begins, ends := 0, 0
	for n, l := range lines {
		switch {
		case l == "beginAtLockRelay()":
			begin = n
			begins++
		case l == "endAtLockRelay()":
			end = n
			ends++
		case strings.Contains(l, "coldLockCommitMarker("):
			commit = n
		case sw < 0 && strings.HasPrefix(l, "pendingSwitchUID = uid"):
			sw = n
		}
	}
	if begins != 1 || ends != 1 {
		t.Fatalf("coldLockTeardown holds beginAtLockRelay() %d times and endAtLockRelay() %d times, want once each", begins, ends)
	}
	if commit < 0 || sw < 0 {
		t.Fatalf("control failed: the commit (%d) or the switch publish (%d) not found", commit, sw)
	}
	if !(commit < begin) {
		t.Error("beginAtLockRelay() comes before the commit: a revoked lock would set a marker it never ends")
	}
	if begin+1 >= len(lines) || !strings.HasPrefix(lines[begin+1], `os.Remove(filepath.Join(dest, ".roamsession"))`) {
		t.Error("beginAtLockRelay() is not the line right before the .roamsession removal: COLD-LOCK-ABORT can answer " +
			"COMMITTED, and the gate can switch itself, with no marker set")
	}
	if !(begin < sw) {
		t.Error("beginAtLockRelay() comes after the switch publish: the gate can read the stash with no marker set")
	}
	if end < 1 || !strings.HasPrefix(lines[end-1], "coldLockRelayAlarm(") {
		t.Error("endAtLockRelay() is not the line right after coldLockRelayAlarm(")
	}
}
