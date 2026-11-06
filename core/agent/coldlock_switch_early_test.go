package main

import (
	"strings"
	"testing"
	"time"
)

// NWP-20261121-01. Backlog row "An idle cold lock that has committed still lets the owner unlock into the session, and
// the switch to the gate lands about 16 s later". The teardown published the switch and the stop together, after the
// alarm relay and the media sweep, so a committed lock left the session in front for as long as those steps took. The
// switch is now published as soon as the steps that need the session in front are done (btpark and the three
// release* calls); the relay and the sweep need the user only RUNNING, so they run behind the switch, and the LOCK
// (the stop) is published after them.

// clwStepFlags is the (switch, lock) pair a step saw when it ran.
func clwStepFlags(c clwCall) string { return c.switchUID + "/" + c.lockUID }

// (a) Through the clw seams: btpark sees neither flag, the relay and the sweep see the switch and not the lock, and
// the lock ends with both flags published and the RW slot empty.
func TestColdLockSwitchEarlyThroughTheSeams(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	var parks []clwCall
	for _, c := range rec.snapshot() {
		if c.op == "btpark" {
			parks = append(parks, c)
		}
	}
	relays, sweeps := rec.preStops()
	if len(parks) != 1 || len(relays) != 1 || len(sweeps) != 1 {
		t.Fatalf("control failed: btpark=%d relay=%d sweep=%d, want exactly one each -- the order checks below "+
			"would prove nothing", len(parks), len(relays), len(sweeps))
	}
	if got := clwStepFlags(parks[0]); got != "/" {
		t.Errorf("btpark ran with switch/lock = %q, want neither published: the switch to user 0 cycles the "+
			"Bluetooth stack, so the bonds are captured with the session still in front", got)
	}
	for _, c := range []clwCall{relays[0], sweeps[0]} {
		if c.switchUID != "10" {
			t.Errorf("%s ran with the switch unpublished (%q): the gate stays behind the session for the whole "+
				"step, and an owner who unlocks then is in the session until the switch lands", c.op, c.switchUID)
		}
		if c.lockUID != "" {
			t.Errorf("%s ran after the LOCK was published (%q): the stop follows the LOCK, so the user may "+
				"already be stopped when it runs", c.op, c.lockUID)
		}
	}
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags after the lock = (%q, %q), want (10, 10)", sw, lk)
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot was left full (%d) after the teardown", n)
	}
}

// (b) A revoked lock publishes no switch: one revoked at Check B (after it took the slot), one revoked while queued.
func TestColdLockSwitchEarlyRevokedPublishesNoSwitch(t *testing.T) {
	t.Run("check-b", func(t *testing.T) {
		dest, rec, hold := clwSetup(t)
		hold.take()
		p := coldLockParks.Load()
		clwLock(t, dest, 1000)
		if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
			t.Fatal("the credential step never ran")
		}
		clwParked(t, p)
		lastPresentAt.Store(2000) // unlock published without a ring -> caught at Check B, after acquiring
		hold.give()
		if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
			t.Fatal("the teardown never finished")
		}
		if clwExists(dest, ".coldlock") {
			t.Fatal("control failed: the lock committed, so this case proves nothing about the revoke path")
		}
		if sw, lk := clwFlags(); sw != "" || lk != "" {
			t.Errorf("a lock revoked at Check B published switch/lock = (%q, %q): the gate would front over a "+
				"session that carries on", sw, lk)
		}
	})
	t.Run("queued", func(t *testing.T) {
		dest, rec, hold := clwSetup(t)
		hold.take()
		p := coldLockParks.Load()
		clwLock(t, dest, 1000)
		if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
			t.Fatal("the credential step never ran")
		}
		clwParked(t, p)
		if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
			t.Fatal("control failed: the unlock was rejected, so this case proves nothing about the revoke path")
		}
		if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
			t.Fatal("the teardown never left the queue")
		}
		if clwExists(dest, ".coldlock") {
			t.Fatal("control failed: the lock committed")
		}
		if sw, lk := clwFlags(); sw != "" || lk != "" {
			t.Errorf("a lock revoked while queued published switch/lock = (%q, %q)", sw, lk)
		}
	})
}

// (c) The order in the SOURCE, on live code lines (comments stripped, as T2 does): a behavioural run cannot tell a
// switch published just before the relay from one published with the lock if the seams see the same flags.
func TestColdLockSwitchEarlySourceOrder(t *testing.T) {
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
	is := func(l, want string) bool { return l == want || strings.HasPrefix(l, want+" ") }
	find := func(from int, match func(string) bool) int {
		if from < 0 {
			return -1
		}
		for n := from; n < len(lines); n++ {
			if match(lines[n]) {
				return n
			}
		}
		return -1
	}
	btpark := find(0, func(l string) bool { return strings.Contains(l, `coldLockWorker(dest, "btpark"`) })
	sw := find(0, func(l string) bool { return is(l, "pendingSwitchUID = uid") })
	relay := find(sw, func(l string) bool { return strings.HasPrefix(l, "coldLockRelayAlarm(") })
	sweep := find(relay, func(l string) bool { return strings.HasPrefix(l, "coldLockSweepMedia(") })
	lock := find(sweep, func(l string) bool { return is(l, "pendingLockUID = uid") })
	rel := find(lock, func(l string) bool { return l == "release()" })
	for _, a := range []struct {
		name string
		at   int
	}{{"the btpark call", btpark}, {"the first `pendingSwitchUID = uid`", sw},
		{"`coldLockRelayAlarm(` after the switch", relay}, {"`coldLockSweepMedia(` after the relay", sweep},
		{"`pendingLockUID = uid` after the sweep", lock}, {"the first release() after the lock", rel}} {
		if a.at < 0 {
			t.Fatalf("control failed: %s not found in coldLockTeardown, so the order check proves nothing", a.name)
		}
	}
	if !(btpark < sw) {
		t.Error("the switch is published before btpark -- the owner is switched out while their bonds are still live")
	}
	n := 0
	for _, l := range lines {
		if is(l, "pendingSwitchUID = uid") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("coldLockTeardown writes `pendingSwitchUID = uid` %d times, want once (alone, before the relay)", n)
	}
	locks := 0
	for _, l := range lines {
		if is(l, "pendingLockUID = uid") {
			locks++
		}
	}
	if locks != 1 {
		t.Errorf("coldLockTeardown writes `pendingLockUID = uid` %d times, want once (alone, after the sweep)", locks)
	}
}

// (d) While this uid's teardown still runs -- the gate can be in front by then -- a RESUME answers busy and no worker
// op runs: a resume then would re-arm a session the LOCK is about to stop.
func TestResumeRefusedWhileTeardownRunsForThatUser(t *testing.T) {
	l := crLock(t, crKinds[0])
	f := &crFake{mode: "openAny"}
	crStartFake(t, l.dest, f)
	coldLockMu.Lock()
	prevRunning, prevUID := coldLockRunning, coldLockUID
	coldLockMu.Unlock()
	t.Cleanup(func() {
		coldLockMu.Lock()
		coldLockRunning, coldLockUID = prevRunning, prevUID
		coldLockMu.Unlock()
	})
	setTeardown := func(uid string) {
		coldLockMu.Lock()
		coldLockRunning, coldLockUID = true, uid
		coldLockMu.Unlock()
	}

	setTeardown("10")
	if got := crResume(t, l.dest, l.unlock); got != workerBusy {
		t.Errorf("a resume while user 10's cold-lock teardown runs answered %q, want %q", got, workerBusy)
	}
	if ops := f.snapshot(); len(ops) != 0 {
		t.Errorf("a resume refused as busy still ran %d worker op(s), first %q", len(ops), ops[0].op)
	}
	crAssertUntouched(t, l)

	// CONTROL: a teardown for another uid does not refuse this resume. The empty entry ends at the `entry == ""`
	// refusal, before any worker call, so this never waits on a lane.
	setTeardown("11")
	if got := crResume(t, l.dest, ""); got != "WRONGPASS" {
		t.Errorf("control failed: with another uid's teardown running, an empty entry answered %q, want WRONGPASS "+
			"-- the guard refuses every resume, not only this user's", got)
	}
}
