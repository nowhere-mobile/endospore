package main

// NWP-20261011-04: THE LOGOFF CUTOFF, from the daemon's side. A sign-out stops the session's apps (roamd `cutoff`)
// before anything is read for its seal, and every exit that keeps the session wakes them (`cutoffwake`). These tests
// drive the real handleLogout against a stand-in for roamd that answers each op as told and records the order the
// daemon handed them over in. The roamd side has its own suite (core/vendor-common/bin/test-logoff-cutoff.sh).

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// cutoffOwnerSeen holds, per state dir, the roam.req line 7 (the alarm owner) of the last cutoff the worker was handed.
var cutoffOwnerSeen sync.Map

// holdAtCutoff holds, per state dir, whether the alarm hold was already set when the cutoff reached the worker.
var holdAtCutoff sync.Map

// wakeSaw holds, per state dir, what the session looked like when its cutoffwake reached the worker (F9).
var wakeSaw sync.Map

// cutoffWorker stands in for roamd on the RW lane: each op is answered with answers[op] ("ERR-UNEXPECTED" for one the
// test did not expect) after hold[op], and recorded in the order it was handed over. hold[op+"#1"], when set, holds the
// op's FIRST hand-over instead (a later one gets hold[op]): the retry tests stall logoff A's step, not the retry's.
func cutoffWorker(t *testing.T, dest string, answers map[string]string, hold map[string]time.Duration) (ops func() []string) {
	t.Helper()
	return cutoffWorkerGated(t, dest, answers, hold, nil, "")
}

// cutoffWorkerGated is cutoffWorker with two additions that let a test order events by channels instead of sleeps.
// gate["<op>#<n>"] makes that op's n-th hand-over (1-based, per op) wait until the channel is closed, instead of
// sleeping, before its answer is written; the wait is in the per-answer goroutine, never in the poll loop, and a
// cleanup closes any gate still open. When beatUntil names an op, the stand-in keeps <dest>/roam.progress fresh about
// every 50 ms from its start until it is handed that op for the first time, then stops for good: roamd writes progress
// while it works and goes silent when stuck, and the logoff watchdog reads a newer mtime as liveness, so A's stall can
// begin only inside that op. Each beat is an EMPTY write that re-creates the file: runWorkerHeld removes roam.progress
// at the start of every op and when it takes a result (a Chtimes would fail on the missing file), and it relays only a
// non-empty line, so a beat never reaches the logoff bar.
func cutoffWorkerGated(t *testing.T, dest string, answers map[string]string, hold map[string]time.Duration, gate map[string]chan struct{}, beatUntil string) (ops func() []string) {
	t.Helper()
	var answerGoroutines sync.WaitGroup // every answer goroutine this stand-in started
	openGates := func() {
		for _, g := range gate {
			select {
			case <-g:
			default:
				close(g)
			}
		}
	}
	t.Cleanup(openGates)
	var mu sync.Mutex
	var seen []string
	calls := map[string]int{}
	done := make(chan struct{})
	finished := make(chan struct{})
	var lastBeat time.Time
	beating := beatUntil != ""
	go func() {
		defer close(finished)
		for {
			// runWorkerHeld writes roam.req with a plain os.WriteFile (roamd only reads it after ctl.start), so a poll can
			// catch it mid-write: take it only once all seven lines are there, or a torn read becomes a phantom op.
			if b, err := os.ReadFile(filepath.Join(dest, laneRW.req)); err == nil && strings.Count(string(b), "\n") >= 7 {
				os.Remove(filepath.Join(dest, laneRW.req))
				lines := strings.Split(string(b), "\n")
				op := lines[0]
				if len(lines) > 2 && op != "out" && op != "sweepmedia" && lines[2] != "" {
					t.Errorf("op %s carried a passphrase -- the cutoff and its wake need none", op)
				}
				if op == "cutoffwake" {
					_, err := os.Stat(filepath.Join(dest, ".roamsession"))
					pendingReapMu.Lock()
					failed := sealFail
					pendingReapMu.Unlock()
					wakeSaw.Store(dest, fmt.Sprintf("armed=%v failed=%v", err == nil, failed))
				}
				if op == "cutoff" && len(lines) > 6 {
					cutoffOwnerSeen.Store(dest, lines[6])     // roam.req line 7: the alarm owner the daemon passed
					holdAtCutoff.Store(dest, cutoffHolding()) // F5: the hold must already be set when the stop begins
				}
				mu.Lock()
				seen = append(seen, op)
				mu.Unlock()
				ans, ok := answers[op]
				if !ok {
					ans = "ERR-UNEXPECTED"
				}
				// "a||b||c": the op's n-th hand-over is answered with the n-th part, every later one with the last.
				if parts := strings.Split(ans, "||"); len(parts) > 1 {
					ans = parts[min(calls[op], len(parts)-1)]
				}
				d := hold[op]
				if d1, ok := hold[op+"#1"]; ok && calls[op] == 0 {
					d = d1
				}
				g := gate[fmt.Sprintf("%s#%d", op, calls[op]+1)]
				calls[op]++
				answerGoroutines.Add(1)
				go func(d time.Duration, a string, g chan struct{}) {
					defer answerGoroutines.Done()
					if g != nil {
						<-g
					} else {
						time.Sleep(d)
					}
					os.WriteFile(filepath.Join(dest, laneRW.res), []byte(a+"\n"), 0o600)
				}(d, ans, g)
			}
			// The request was read and dispatched above, so a beat never lands after the stalled op was handed over.
			if beating {
				if calls[beatUntil] > 0 {
					beating = false
				} else if time.Since(lastBeat) >= 50*time.Millisecond {
					lastBeat = time.Now()
					os.WriteFile(filepath.Join(dest, "roam.progress"), nil, 0o600)
				}
			}
			select {
			case <-done:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	// After <-finished no answer goroutine can be added; open any gate still shut, then join them (NWP-20261024-13).
	t.Cleanup(func() { close(done); <-finished; openGates(); answerGoroutines.Wait() })
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), seen...)
	}
}

// cutoffSession seats a STORED session (not a throwaway) for uid and resets the logoff's global state around the test.
func cutoffSession(t *testing.T, uid string) string {
	t.Helper()
	ropReapReset(t)
	// The 2 s onStop window is a plain sleep before the cutoff; nothing here observes it, so it is shortened (round 7).
	fw := logoffFlushWait
	logoffFlushWait = 100 * time.Millisecond
	t.Cleanup(func() { logoffFlushWait = fw })
	reset := func() {
		pendingReapMu.Lock()
		sealInFlight, sealUnstuck, sealFail, sealFailWhy, sealPartial, sealRunKind = false, false, false, "", "", ""
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "correct horse", uid, ""); err != nil {
		t.Fatal(err)
	}
	return dest
}

// logoffDone waits for the logoff goroutine of uid to return (its defer releases the veto), failing after limit.
func logoffDone(t *testing.T, uid string, limit time.Duration) {
	t.Helper()
	deadline := time.Now().Add(limit)
	for logoffInFlight(uid) {
		if time.Now().After(deadline) {
			t.Fatalf("the logoff of user %s did not finish within %s", uid, limit)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func sameOps(got, want []string) bool { return strings.Join(got, ",") == strings.Join(want, ",") }

// landedLogoff drives a sign-out of uid whose cutoff answers cut and whose sweep and seal land, and returns the ops
// roamd was handed once the reap is queued. It then stands in for the user-0 watcher and acknowledges both reap
// phases, so the logoff's reapOrReboot (8 s and 20 s on) finds nothing stuck and ends without a reboot attempt.
func landedLogoff(t *testing.T, uid, cut string) []string {
	t.Helper()
	_, ops := landedLogoffIn(t, uid, cut, nil)
	return ops
}

// landedLogoffIn is landedLogoff with a setup step run on the state dir before LOGOUT; it also returns the dir.
func landedLogoffIn(t *testing.T, uid, cut string, setup func(dest string)) (string, []string) {
	t.Helper()
	dest := cutoffSession(t, uid)
	if setup != nil {
		setup(dest)
	}
	ops := cutoffWorker(t, dest, map[string]string{"cutoff": cut, "sweepmedia": "OK", "out": "OK"}, nil)
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
	return dest, got
}

// The order of a sign-out that lands: the cutoff FIRST, then the sweep, then the seal -- and no wake, because the
// session ends. Driven, so a cutoff moved after the sweep or the seal fails here, not only in a source pin.
func TestLogoffCutoff_RunsFirstAndIsNotUndoneWhenTheSealLands(t *testing.T) {
	dest, got := landedLogoffIn(t, "71", "OK 3", nil)
	if want := []string{"cutoff", "sweepmedia", "out"}; !sameOps(got, want) {
		t.Fatalf("a landed sign-out handed roamd %v, want %v", got, want)
	}
	if h, _ := holdAtCutoff.Load(dest); h != true {
		t.Error("the alarm hold was not set when the cutoff began -- a clock app stopped by it could clear the gate's copy")
	}
}

// The cutoff gates nothing: a cutoff that could not even list the packages still seals, as every logoff did before it.
func TestLogoffCutoff_AFailedCutoffStillSeals(t *testing.T) {
	if got, want := landedLogoff(t, "72", "ERR-LIST"), []string{"cutoff", "sweepmedia", "out"}; !sameOps(got, want) {
		t.Fatalf("after a failed cutoff the sign-out handed roamd %v, want %v -- the cutoff must never be a gate", got, want)
	}
}

// Every exit that keeps the session signed in wakes the apps the cutoff stopped, AFTER the verdict that keeps it.
func TestLogoffCutoff_EveryKeptSessionIsWoken(t *testing.T) {
	for _, c := range []struct {
		name    string
		uid     string
		answers map[string]string
		want    []string
	}{
		{"the media sweep did not verify", "73",
			map[string]string{"cutoff": "OK 3", "sweepmedia": "ERR-MEDIA-SWEEP 1", "cutoffwake": "WAKE OK 3"},
			[]string{"cutoff", "sweepmedia", "sweepmedia", "cutoffwake"}}, // NWP-20261117-03: 1 then 1 does not fall
		{"the seal failed", "74",
			map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "ERR-PUSH", "cutoffwake": "WAKE OK 3"},
			[]string{"cutoff", "sweepmedia", "out", "cutoffwake"}},
		{"the seal was refused", "75",
			map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "ERR-REFUSED PARTIAL:de=refused", "cutoffwake": "WAKE OK 3"},
			[]string{"cutoff", "sweepmedia", "out", "cutoffwake"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			dest := cutoffSession(t, c.uid)
			ops := cutoffWorker(t, dest, c.answers, nil)
			ropReply(t, func(conn net.Conn) { handleLogout(conn, dest) })
			logoffDone(t, c.uid, 20*time.Second)
			if got := ops(); !sameOps(got, c.want) {
				t.Fatalf("handed roamd %v, want %v -- a session that stays signed in must have its apps woken", got, c.want)
			}
			if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err != nil {
				t.Errorf("the kept session was not re-armed: %v", err)
			}
			// F9: the wake runs FIRST -- before the arm says FAILED and re-arms the session, so no retry can have
			// started and no periodic seal can be queued in front of it.
			if got, _ := wakeSaw.Load(dest); got != "armed=false failed=false" {
				t.Errorf("the wake ran with the session %v, want armed=false failed=false -- it must come before the "+
					"FAILED verdict and the re-arm", got)
			}
		})
	}
}

// The stall watchdog un-sticks the screen while the seal still holds the slot; the verdict that lands after it keeps
// the session, so it is that exit which wakes the apps.
func TestLogoffCutoff_TheLateVerdictAfterAnUnstickWakes(t *testing.T) {
	const uid = "76"
	dest := cutoffSession(t, uid)
	lim, hc, tick := logoffStallLimit, logoffStallHardCap, logoffStallTick
	logoffStallLimit, logoffStallHardCap, logoffStallTick = 300*time.Millisecond, time.Hour, 50*time.Millisecond
	t.Cleanup(func() { logoffStallLimit, logoffStallHardCap, logoffStallTick = lim, hc, tick })
	ops := cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "OK", "cutoffwake": "WAKE OK 3"},
		map[string]time.Duration{"out": 2 * time.Second})
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	logoffDone(t, uid, 20*time.Second)
	pendingReapMu.Lock()
	unstuck, reap := sealUnstuck, pendingReapUID
	pendingReapMu.Unlock()
	if !unstuck {
		t.Fatal("the stall watchdog never un-stuck the logoff -- this test reaches nothing")
	}
	if reap != "" {
		t.Errorf("a verdict after the unstick queued a reap (%q)", reap)
	}
	if got, want := ops(), []string{"cutoff", "sweepmedia", "out", "cutoffwake"}; !sameOps(got, want) {
		t.Fatalf("handed roamd %v, want %v -- the session the user was told they keep must have its apps woken", got, want)
	}
}

// A wake whose sign-out has been superseded by a newer one of the same session does nothing: run after the retry's
// cutoff, it would un-stop the apps that retry just stopped, mid-seal. A current claim, or none in flight, runs.
func TestLogoffCutoff_ASupersededWakeDoesNothing(t *testing.T) {
	const uid = "77"
	dest := t.TempDir()
	ops := cutoffWorker(t, dest, map[string]string{"cutoffwake": "WAKE OK 1"}, nil)
	old := setLogoffInFlight(uid)
	cur := setLogoffInFlight(uid) // the retry
	if got := wakeAfterCutoff(dest, "alice", uid, old, "test"); got != "SKIP-SUPERSEDED" {
		t.Errorf("a superseded wake answered %q, want SKIP-SUPERSEDED", got)
	}
	if got := ops(); len(got) != 0 {
		t.Fatalf("a superseded wake handed roamd %v", got)
	}
	if got := wakeAfterCutoff(dest, "alice", uid, cur, "test"); got != "WAKE OK 1" {
		t.Errorf("the current logoff's wake answered %q, want WAKE OK 1", got)
	}
	clearLogoffInFlight(uid, cur)
	if got := wakeAfterCutoff(dest, "alice", uid, old, "test"); got != "WAKE OK 1" {
		t.Errorf("a wake with no sign-out in flight answered %q, want WAKE OK 1 -- only a NEWER sign-out supersedes", got)
	}
	if got := ops(); !sameOps(got, []string{"cutoffwake", "cutoffwake"}) {
		t.Errorf("handed roamd %v", got)
	}
}

// Pinned in the source, where driving is not enough: the cutoff precedes the media teardown and the sync, it follows
// the 2 s onStop window, and the paths that are not a sign-out never run it.
func TestLogoffCutoff_PlacementInTheSource(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	lo := strings.Join(stripComments(funcBody(t, src, "handleLogout")), "\n")
	if !strings.Contains(string(mustRead(t, "logoff_cutoff.go")), "logoffFlushWait    = 2 * time.Second") {
		t.Error("the onStop window is no longer 2 s")
	}
	// Round 8: the whole statement, not its spelling -- `flushWait := logoffFlushWait * 0`, or a later `flushWait = 0`,
	// would keep the substring and drop the window. TestLogoffCutoff_TheOnStopWindowPrecedesTheCutoff drives it too.
	var take, assigned int
	takeRe := regexp.MustCompile(`^\s*flushWait := logoffFlushWait\s*(//.*)?$`)
	assignRe := regexp.MustCompile(`\bflushWait\s*([-+*/%&|^]|<<|>>|&\^)?=|\bflushWait\s*:=|\bflushWait\s*(\+\+|--)`)
	for _, l := range stripComments(funcBody(t, src, "handleLogout")) {
		if takeRe.MatchString(l) {
			take++
		}
		assigned += len(assignRe.FindAllString(l, -1))
	}
	if take != 1 || assigned != 1 || strings.Count(lo, "time.Sleep(flushWait)") != 1 {
		t.Errorf("handleLogout must take the onStop window as exactly `flushWait := logoffFlushWait`, assign flushWait "+
			"nowhere else and sleep on it once: the statement %d time(s), %d assignment(s), %d sleep(s)",
			take, assigned, strings.Count(lo, "time.Sleep(flushWait)"))
	}
	// NWP-20261017-12: the sync before the seal is logoffSync (a watchdog test stubs it), syscall.Sync in production,
	// taken whole like the window above and called once.
	if !strings.Contains(string(mustRead(t, "logoff_cutoff.go")), "\tlogoffSync         = syscall.Sync\n") {
		t.Error("the flush before the logoff seal is no longer syscall.Sync")
	}
	syncTake := regexp.MustCompile(`(?m)^\s*flushSync := logoffSync\s*(//.*)?$`).FindAllString(lo, -1)
	if len(syncTake) != 1 || len(regexp.MustCompile(`\bflushSync\s*:?=`).FindAllString(lo, -1)) != 1 ||
		strings.Count(lo, "flushSync()") != 1 {
		t.Errorf("handleLogout must take the sync as exactly `flushSync := logoffSync`, assign it nowhere else and call it once")
	}
	sleep, cut, med, sweep, sync := strings.Index(lo, "time.Sleep(flushWait)"), strings.Index(lo, "logoffCutoff(dest, name, uid)"),
		strings.Index(lo, "stopMediad(dest)"), strings.Index(lo, `triggerRoamWorker(dest, "sweepmedia"`), strings.Index(lo, "flushSync()")
	if sleep < 0 || cut < 0 || med < 0 || sweep < 0 || sync < 0 || !(sleep < cut && cut < med && med < sweep && sweep < sync) {
		t.Errorf("handleLogout: 2 s window %d, cutoff %d, stopMediad %d, sweep %d, sync %d -- the cutoff must follow the "+
			"onStop window and precede the media teardown and everything the seal reads", sleep, cut, med, sweep, sync)
	}
	if n := strings.Count(lo, "logoffCutoff("); n != 1 {
		t.Errorf("handleLogout runs the cutoff %d times, want 1", n)
	}
	if n := strings.Count(lo, "wakeAfterCutoff(dest, name, uid, logoffClaim,"); n != 3 {
		t.Errorf("handleLogout wakes at %d exits, want 3 (sweep failed, seal failed, late verdict after the unstick)", n)
	}
	// The throwaway branch returns before the cutoff: nothing is sealed there, the reap destroys the user.
	if tw := strings.Index(lo, "LOCAL/throwaway -> reap WITHOUT seal"); tw < 0 || tw > cut {
		t.Error("the throwaway branch no longer returns before the cutoff")
	}
	for _, f := range []struct{ file, fn string }{{"main.go", "coldLockTeardown"}, {"end_unsaved.go", "handleEndUnsaved"},
		{"end_unsaved.go", "handleRestartUnsaved"}} {
		if strings.Contains(fileFuncBody(t, f.file, f.fn), "logoffCutoff(") {
			t.Errorf("%s runs the cutoff -- a cold lock is not a sign-out, and END-/RESTART-UNSAVED discard the session", f.fn)
		}
	}
}

// Chester, 2026-10-11: "Never stop the alarm app". The package that owns the session's next alarm clock -- as the
// session's last relay recorded it -- reaches roamd's cutoff on roam.req line 7, where it joins the keep-set. Only an
// owner recorded for THIS user, and only a plain package name.
func TestLogoffCutoff_TheAlarmOwnerIsPassedToTheCutoff(t *testing.T) {
	for _, c := range []struct {
		name, uid, src, want string
	}{
		{"this user's owner", "81", "81\tcom.example.clock", "com.example.clock"},
		{"another user's owner", "82", "15\tcom.example.clock", ""},
		{"not a package name", "83", "83\t-x", ""},
		{"no owner on record", "84", "", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			dest, ops := landedLogoffIn(t, c.uid, "OK 3", func(dest string) {
				if c.src != "" {
					os.WriteFile(filepath.Join(dest, "gate-alarm-src"), []byte(c.src), 0o600)
				}
			})
			if len(ops) == 0 || ops[0] != "cutoff" {
				t.Fatalf("no cutoff ran: %v", ops)
			}
			got, _ := cutoffOwnerSeen.Load(dest)
			if got != c.want {
				t.Errorf("the cutoff was handed alarm owner %q, want %q", got, c.want)
			}
		})
	}
}

// Belt and braces, keyed to THIS sign-out: while a cutoff is unsettled, a relayed CLEAR -- anyone's (round 4: with the
// apps stopped, the user's own relay reads the same empty next alarm) -- does not delete the gate's alarm, nor its owner
// record (X3). A relayed time still lands, and once the cutoff is settled a clear works again.
func TestLogoffCutoff_ARelayClearIsHeldWhileTheCutoffIsUnsettled(t *testing.T) {
	const uid = "85"
	dest := t.TempDir()
	p, ps := filepath.Join(dest, "gate-alarm"), filepath.Join(dest, "gate-alarm-src")
	plant := func() {
		os.WriteFile(p, []byte("1760000000000"), 0o600)
		os.WriteFile(ps, []byte(uid+"\tcom.example.clock"), 0o600)
	}
	plant()
	setCutoffHold(uid)
	t.Cleanup(func() { endCutoffHold(uid) })
	for _, clear := range []string{"0", "0\t\t\tu", ""} {
		if got := evictConn(t, dest, "SET-GATE-ALARM\n"+clear+"\n"); got != "OK" {
			t.Fatalf("SET-GATE-ALARM %q replied %q", clear, got)
		}
		if b, err := os.ReadFile(p); err != nil || string(b) != "1760000000000" {
			t.Fatalf("a clear %q during an unsettled cutoff deleted the gate's alarm (%q, %v) -- a clock app stopped by "+
				"the cutoff would leave the alarm unrung", clear, b, err)
		}
		if b, err := os.ReadFile(ps); err != nil || string(b) != uid+"\tcom.example.clock" {
			t.Errorf("a held clear touched gate-alarm-src (%q, %v) -- the owner the gate silences must survive it (X3)", b, err)
		}
	}
	evictConn(t, dest, "SET-GATE-ALARM\n1760000000999\t"+uid+"\tcom.example.clock\n")
	if b, _ := os.ReadFile(p); string(b) != "1760000000999" {
		t.Errorf("a relayed time during the hold did not land (%q)", b)
	}
	// Settled: a clear lands again.
	endCutoffHold(uid)
	plant()
	evictConn(t, dest, "SET-GATE-ALARM\n0\n")
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("a clear with no unsettled cutoff did not delete the gate's alarm (%v)", err)
	}
}

// The hold ends with the wake of a kept session, and on a sign-out that lands only at the REAP ack (sent once the
// chooser's dpm.removeUser call returns) -- not when the reap is queued: the post-seal relay, kicked from inside `out`,
// can land in between (F2). A REAP ack for ANOTHER uid leaves the hold alone.
func TestLogoffCutoff_TheHoldEndsWithTheWakeOrTheRemoval(t *testing.T) {
	const kept = "87"
	dest := cutoffSession(t, kept)
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": "ERR-MEDIA-SWEEP 1", "cutoffwake": "WAKE OK 3"}, nil)
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	logoffDone(t, kept, 20*time.Second)
	if cutoffHolding() {
		t.Error("the hold outlived the wake of a kept session")
	}

	const gone = "88"
	dest = cutoffSession(t, gone)
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "OK"}, nil)
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	deadline := time.Now().Add(15 * time.Second)
	for {
		pendingReapMu.Lock()
		reap := pendingReapUID
		pendingReapMu.Unlock()
		if reap == gone {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the sign-out never queued its reap")
		}
		time.Sleep(50 * time.Millisecond)
	}
	// The reap is queued and the user not yet removed: the late post-seal relay's clear is held. The pause stands for
	// the relay arriving a moment after the queue -- the order F2 is about -- so nothing done at the queue can pass.
	time.Sleep(300 * time.Millisecond)
	p := filepath.Join(dest, "gate-alarm")
	os.WriteFile(p, []byte("1760000000000"), 0o600)
	evictConn(t, dest, "SET-GATE-ALARM\n0\n")
	if _, err := os.Stat(p); err != nil {
		t.Errorf("a post-seal clear between the queued reap and the removal deleted the gate's alarm (%v) (F2)", err)
	}
	ackReapAction("SWITCH", gone)
	if !cutoffHolding() {
		t.Error("the hold ended at the SWITCH, before the user's removal was requested")
	}
	ackReapAction("REAP", "89") // another session's (a stale) REAP ack
	if !cutoffHolding() {
		t.Error("a REAP ack for another uid ended this sign-out's hold")
	}
	ackReapAction("REAP", gone)
	if cutoffHolding() {
		t.Error("the hold outlived the REAP ack")
	}
	evictConn(t, dest, "SET-GATE-ALARM\n0\n")
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("a clear after the removal did not land (%v)", err)
	}
}

// A wake settles only ITS OWN logoff's hold. The hold is keyed by uid, so a retry of the same session sets the same key:
// a wake that is skipped as superseded must leave it set, and so must a wake that ran but was superseded WHILE it ran
// (the retry claimed and its cutoff set the hold during the cutoffwake, about 3 min at worst). Ending it there would let
// the retry's stop, seal and reap run with relayed clears applied.
func TestLogoffCutoff_AWakeNeverEndsANewerSignOutsHold(t *testing.T) {
	const uid = "92"
	t.Cleanup(func() { endCutoffHold(uid) })

	t.Run("skipped", func(t *testing.T) {
		dest := t.TempDir()
		ops := cutoffWorker(t, dest, map[string]string{"cutoffwake": "WAKE OK 1"}, nil)
		old := setLogoffInFlight(uid)
		cur := setLogoffInFlight(uid) // the retry
		defer clearLogoffInFlight(uid, cur)
		setCutoffHold(uid) // the retry's cutoff
		if got := wakeAfterCutoff(dest, "alice", uid, old, "test"); got != "SKIP-SUPERSEDED" {
			t.Fatalf("a superseded wake answered %q, want SKIP-SUPERSEDED", got)
		}
		if o := ops(); len(o) != 0 {
			t.Fatalf("a superseded wake handed roamd %v", o)
		}
		if !cutoffHolding() {
			t.Error("a wake SKIPPED as superseded ended the retry's hold")
		}
	})

	t.Run("superseded while it ran", func(t *testing.T) {
		endCutoffHold(uid)
		dest := t.TempDir()
		ops := cutoffWorker(t, dest, map[string]string{"cutoffwake": "WAKE OK 1"},
			map[string]time.Duration{"cutoffwake": 800 * time.Millisecond})
		old := setLogoffInFlight(uid)
		setCutoffHold(uid) // A's cutoff
		got := make(chan string, 1)
		go func() { got <- wakeAfterCutoff(dest, "alice", uid, old, "test") }()
		deadline := time.Now().Add(10 * time.Second)
		for len(ops()) == 0 { // A's wake is past its supersede check and running in roamd
			if time.Now().After(deadline) {
				t.Fatal("the wake never reached the worker")
			}
			time.Sleep(20 * time.Millisecond)
		}
		cur := setLogoffInFlight(uid) // retry B claims while A's wake runs...
		defer clearLogoffInFlight(uid, cur)
		setCutoffHold(uid) // ...and its cutoff sets the hold
		select {
		case r := <-got:
			if r != "WAKE OK 1" {
				t.Fatalf("A's wake answered %q, want WAKE OK 1 -- it was not superseded when it checked", r)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("A's wake never returned")
		}
		if !cutoffHolding() {
			t.Error("A's wake ended retry B's hold -- B's stop, seal and reap would run with relayed clears applied")
		}
		// Not superseded at its end: B's own wake does end it.
		if r := wakeAfterCutoff(dest, "alice", uid, cur, "test"); r != "WAKE OK 1" {
			t.Fatalf("B's wake answered %q", r)
		}
		if cutoffHolding() {
			t.Error("the current sign-out's wake did not end its hold")
		}
	})
}

// A reply that is not the wake's own -- a timed-out op's late roam.res -- is not taken for it: the wake asks once more.
func TestLogoffCutoff_TheWakeRejectsAReplyThatIsNotItsOwn(t *testing.T) {
	const uid = "90"
	dest := t.TempDir()
	ops := cutoffWorker(t, dest, map[string]string{"cutoffwake": "OK||WAKE OK 2"}, nil)
	claim := setLogoffInFlight(uid)
	defer clearLogoffInFlight(uid, claim)
	if got := wakeAfterCutoff(dest, "alice", uid, claim, "test"); got != "WAKE OK 2" {
		t.Errorf("the wake answered %q, want WAKE OK 2 -- a bare OK is a late sweep's, not the wake's", got)
	}
	if got := ops(); !sameOps(got, []string{"cutoffwake", "cutoffwake"}) {
		t.Errorf("handed roamd %v, want the wake asked twice", got)
	}
}

// NWP-20261125-21: a partial wake is asked once more under the same slot. roamd keeps the packages still stopped in
// the record, so the second answer is the one that stands.
func TestLogoffCutoff_APartialWakeIsAskedOnceMore(t *testing.T) {
	const uid = "78"
	dest := t.TempDir()
	ops := cutoffWorker(t, dest, map[string]string{"cutoffwake": "WAKE PARTIAL 5 2||WAKE OK 2"}, nil)
	claim := setLogoffInFlight(uid)
	defer clearLogoffInFlight(uid, claim)
	if got := wakeAfterCutoff(dest, "alice", uid, claim, "test"); got != "WAKE OK 2" {
		t.Errorf("the wake answered %q, want WAKE OK 2 -- a partial wake was not asked once more", got)
	}
	if got := ops(); !sameOps(got, []string{"cutoffwake", "cutoffwake"}) {
		t.Errorf("handed roamd %v, want the wake asked twice", got)
	}
}

// NWP-20261125-21: at most one extra cutoffwake per call, whatever the reason. A call that re-asked for a reply that
// was not its own does not ask a third time when the second answer is partial.
func TestLogoffCutoff_AWakeIsReAskedAtMostOnce(t *testing.T) {
	const uid = "80"
	dest := t.TempDir()
	ops := cutoffWorker(t, dest, map[string]string{"cutoffwake": "OK||WAKE PARTIAL 5 2"}, nil)
	claim := setLogoffInFlight(uid)
	defer clearLogoffInFlight(uid, claim)
	if got := wakeAfterCutoff(dest, "alice", uid, claim, "test"); got != "WAKE PARTIAL 5 2" {
		t.Errorf("the wake answered %q, want WAKE PARTIAL 5 2", got)
	}
	if got := ops(); !sameOps(got, []string{"cutoffwake", "cutoffwake"}) {
		t.Errorf("handed roamd %v, want exactly two wakes in all", got)
	}
}

// The supersede check runs UNDER the slot: a retry whose claim lands while this wake is still waiting for the slot
// supersedes it. Checked at the call instead, the wake would un-stop the apps the retry's cutoff had just stopped.
func TestLogoffCutoff_ARetryThatLandsWhileTheWakeWaitsSupersedesIt(t *testing.T) {
	const uid = "86"
	dest := t.TempDir()
	ops := cutoffWorker(t, dest, map[string]string{"cutoffwake": "WAKE OK 1"}, nil)
	old := setLogoffInFlight(uid)
	laneRW.slot <- struct{}{} // the stalled seal, still holding the slot
	got := make(chan string, 1)
	go func() { got <- wakeAfterCutoff(dest, "alice", uid, old, "test") }()
	time.Sleep(200 * time.Millisecond)
	cur := setLogoffInFlight(uid) // the retry, while the wake waits
	defer clearLogoffInFlight(uid, cur)
	<-laneRW.slot
	select {
	case r := <-got:
		if r != "SKIP-SUPERSEDED" {
			t.Errorf("a wake superseded while it waited answered %q, want SKIP-SUPERSEDED", r)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the wake never returned")
	}
	if o := ops(); len(o) != 0 {
		t.Errorf("a superseded wake handed roamd %v", o)
	}
}

// Round 6: a verdict that lands after a RETRY has claimed belongs to the retry's session, not to the logoff that
// produced it. Logoff A is un-stuck while one of its steps still holds the RW slot, the user taps Log off again and
// retry B claims; then A's step answers. sealUnstuck cannot guard this -- B's claim reset it -- so before the fix a
// late OK queued the switch+reap of the user B was sealing (the REAP ack then ended B's hold and B's `out` sealed a
// removed user), and a late failure put FAILED over B's "Saving…" screen and re-armed the session under it. Round 7
// adds B claiming during the wake of A's late verdict, after that arm's first check passed: A re-armed .roamsession
// under B, leaving a marker that named the user B's reap removed. Through all of B's run until B's own seal is handed
// over nothing of B's may move, and after B's reap is acknowledged no marker may name the removed user.
func TestLogoffCutoff_AVerdictAfterARetryClaimedIsNotActedOn(t *testing.T) {
	for _, c := range []struct {
		name, uid string
		answers   map[string]string
		stall     string // the op of A that is still running when A is un-stuck
		bAt       string // "" -> B claims right after the unstick; else once A has handed roamd this op
		aOuts     int    // `out`s A hands roamd: 0 when A must not seal after a superseded sweep
		stuck     bool   // R7-F4: one failed sweep on record before A; A's verified sweep must reset it
	}{
		{"late seal OK", "93", map[string]string{"out": "OK"}, "out", "", 1, false},
		{"late seal failure", "94", map[string]string{"out": "ERR-PUSH 1||OK"}, "out", "", 1, false},
		{"late sweep failure", "95", map[string]string{"sweepmedia": "ERR-MEDIA-SWEEP 1||OK"}, "sweepmedia", "", 0, false},
		{"late sweep OK", "96", map[string]string{}, "sweepmedia", "", 0, true},
		{"retry during the late verdict's wake", "97", map[string]string{"out": "OK"}, "out", "cutoffwake", 1, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			uid := c.uid
			dest := cutoffSession(t, uid)
			t.Cleanup(func() { endCutoffHold(uid) })
			t.Cleanup(resetMediaStuck)
			if c.stuck {
				noteMediaSweepFailed("alice", uid)
			}
			// A's stall is ordered by gates and a heartbeat, not by sleeps: the stand-in beats roam.progress until A's stalled
			// op is handed over, so the watchdog can only begin counting inside that op, and that op's answer (and the
			// wake's, and in the stuck case the retry's sweep) waits on a channel the test closes at the step it names. The
			// 2.5 s limit is kept; it now bounds how long A sits silent, not the order of anything. logoffSync is stubbed
			// because a real sync(2) waits on the whole host's I/O.
			lim, hc, tick, fw, sy := logoffStallLimit, logoffStallHardCap, logoffStallTick, logoffFlushWait, logoffSync
			logoffStallLimit, logoffStallHardCap, logoffStallTick = 2500*time.Millisecond, time.Hour, 50*time.Millisecond
			logoffFlushWait = 100 * time.Millisecond
			logoffSync = func() {}
			t.Cleanup(func() {
				logoffStallLimit, logoffStallHardCap, logoffStallTick, logoffFlushWait, logoffSync = lim, hc, tick, fw, sy
			})
			answers := map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "OK", "cutoffwake": "WAKE OK 3"}
			for k, v := range c.answers {
				answers[k] = v
			}
			gate := map[string]chan struct{}{c.stall + "#1": make(chan struct{}), "cutoffwake#1": make(chan struct{})}
			if c.stuck {
				gate["sweepmedia#2"] = make(chan struct{}) // the retry's sweep: the count is read after A's verdict, before the retry's
			}
			release := func(key string) {
				select {
				case <-gate[key]:
				default:
					close(gate[key])
				}
			}
			ops := cutoffWorkerGated(t, dest, answers, nil, gate, c.stall)
			count := func(op string) (n int) {
				for _, o := range ops() {
					if o == op {
						n++
					}
				}
				return n
			}
			waitFor := func(what string, cond func() bool) {
				t.Helper()
				deadline := time.Now().Add(15 * time.Second)
				for !cond() {
					if time.Now().After(deadline) {
						t.Fatalf("%s never happened; roamd was handed %v", what, ops())
					}
					time.Sleep(20 * time.Millisecond)
				}
			}
			ropReply(t, func(c net.Conn) { handleLogout(c, dest) }) // A
			waitFor("A's unstick", func() bool {
				pendingReapMu.Lock()
				defer pendingReapMu.Unlock()
				return sealUnstuck
			})
			if count(c.stall) != 1 {
				t.Fatalf("A was un-stuck outside its %s (handed %v) -- this case reaches nothing", c.stall, ops())
			}
			if c.bAt != "" {
				release(c.stall + "#1") // A's late verdict lands and runs its wake, which the stand-in holds
				waitFor("A's "+c.bAt, func() bool { return count(c.bAt) >= 1 })
			}
			logoffStallLimit = time.Hour // B: its own watchdog stays quiet, as in production
			// Retry B: the user, told they are still signed in, taps Log off again.
			if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
				t.Fatalf("the retry's LOGOUT replied %q", got)
			}
			if !logoffInFlight(uid) {
				t.Fatal("the retry did not claim")
			}
			if c.bAt == "" {
				release(c.stall + "#1") // A's stalled op answers only now, after B has claimed
			} else {
				release(c.bAt + "#1")
			}
			// Watch B's state until B's own seal is handed over (B's verdict cannot land before its `out` is answered).
			deadline := time.Now().Add(25 * time.Second)
			var bad []string
			note := func(s string) {
				if len(bad) == 0 || bad[len(bad)-1] != s {
					bad = append(bad, s)
				}
			}
			stuckRead := false
			for count("out") < c.aOuts+1 && time.Now().Before(deadline) {
				pendingReapMu.Lock()
				reap, sw, inFlight, fail, why := pendingReapUID, pendingSwitchUID, sealInFlight, sealFail, sealFailWhy
				pendingReapMu.Unlock()
				if reap == uid || sw == uid {
					note("a switch+reap was queued while the retry was in flight")
					ackReapAction("SWITCH", uid) // stand in for the watcher, so no reboot fallback runs
					ackReapAction("REAP", uid)
				}
				if !inFlight {
					note("sealInFlight dropped under the retry")
				}
				if fail {
					note("sealFail set under the retry (" + why + ")")
				}
				if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err == nil {
					note("the session was re-armed under the retry")
				}
				if c.stuck && !stuckRead && count("sweepmedia") == 2 { // B's sweep handed over, not yet answered
					stuckRead = true
					if n := mediaStuckCount("alice", uid); n != 0 {
						note(fmt.Sprintf("A's verified sweep left the failed-sweep count at %d", n))
					}
					release("sweepmedia#2")
				}
				time.Sleep(20 * time.Millisecond)
			}
			for _, b := range bad {
				t.Errorf("A's late %s verdict: %s", c.stall, b)
			}
			if c.stuck && !stuckRead {
				t.Error("the retry's sweep was never seen -- the failed-sweep count was not checked")
			}
			// B lands: its own switch+reap, acknowledged so its reap fallback finds nothing stuck.
			waitFor("the retry's own reap", func() bool {
				pendingReapMu.Lock()
				defer pendingReapMu.Unlock()
				return pendingReapUID == uid
			})
			ackReapAction("SWITCH", uid)
			ackReapAction("REAP", uid)
			if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err == nil {
				t.Errorf("after the retry's reap was acknowledged, .roamsession still names the removed user %s", uid)
			}
			if n := count("out"); n != c.aOuts+1 {
				t.Errorf("roamd was handed %d `out`(s), want %d (A's %d + the retry's): %v", n, c.aOuts+1, c.aOuts, ops())
			}
		})
	}
}

// Round 8: the onStop window, driven. The cutoff force-stops the session's apps, so it must not reach roamd before the
// window has passed: an app stopped inside it loses the pending SharedPreferences write its onStop queued
// (DIA-20260623-01). Measured with a 400 ms window from the LOGOUT to the cutoff's hand-over, which the stand-in roamd
// can only see late (it polls), never early.
func TestLogoffCutoff_TheOnStopWindowPrecedesTheCutoff(t *testing.T) {
	const uid = "98"
	dest := cutoffSession(t, uid) // restores logoffFlushWait on cleanup
	const window = 400 * time.Millisecond
	logoffFlushWait = window
	ops := cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "OK"}, nil)
	t0 := time.Now()
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	for len(ops()) == 0 {
		if time.Since(t0) > 10*time.Second {
			t.Fatal("the cutoff never reached roamd")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if el := time.Since(t0); el < window {
		t.Errorf("the cutoff reached roamd %s after LOGOUT, inside the %s onStop window", el.Round(time.Millisecond), window)
	}
	if o := ops(); o[0] != "cutoff" {
		t.Errorf("the first op was %q, want the cutoff", o[0])
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
		time.Sleep(20 * time.Millisecond)
	}
	ackReapAction("SWITCH", uid)
	ackReapAction("REAP", uid)
}

// NWP-20261017-12: each sign-out's stall watchdog exits on its OWN supersede. The stand-ins below drive the real
// handleLogout; the watchdog's exit line is read from a live capture of os.Stderr.

const watchdogSupersededLine = "[logind] logoff stall watchdog: superseded by a retry, exiting"

// liveStderr redirects os.Stderr into a buffer a test can poll while the daemon goroutines keep writing.
type liveStderr struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (l *liveStderr) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

func (l *liveStderr) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()
}

func captureStderrLive(t *testing.T) *liveStderr {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	l := &liveStderr{}
	old := os.Stderr
	os.Stderr = w
	done := make(chan struct{})
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := r.Read(buf)
			if n > 0 {
				l.Write(buf[:n])
			}
			if err != nil {
				close(done)
				return
			}
		}
	}()
	t.Cleanup(func() {
		os.Stderr = old
		w.Close()
		<-done
		r.Close()
	})
	return l
}

// A's seal fails and its watchdog has not noticed yet when the retry claims: A's watchdog must exit on the supersede,
// once, and must not unstick the retry on A's clock.
//
// A's watchdog runs on a hand-stepped tick (logoffStallTicker, NWP-20261110-08). On a real ticker this test lived on
// sleep margins -- A's seal failing between two ticks, the retry claiming before the next -- and it failed CI step 2
// on main whenever the runner was busy. Here A takes no tick until the retry has claimed: a tick with nothing in flight
// exits the watchdog silently, which is not the case under test. A's hard cap is 1 ms, so any tick A takes without
// a supersede goes to the unstick, and no wall-clock margin is left to lose; the stall limit and the tick are an hour,
// so a watchdog that ignores the hook never ticks inside the test. After the claim, ONE tick must produce exactly one
// supersede line, and a second tick offered afterwards must find no reader (the watchdog RETURNED). logoffSync is
// stubbed because a real sync(2) waits on the whole host's I/O -- 3.5 s on the shared CI VM. The retry's 6 s `out`
// keeps it in flight while A is stepped. The wait for the logoff to end is 60 s: reapOrReboot sleeps 20 s from the
// reap queue even when both phases are acknowledged, so the old 20 s bound was a second race of the same kind.
// The uid is used by no other test: a watchdog prints the supersede line for any newer claim of ITS uid, and the
// landed-logoff test's watchdog (uid 71, a real 15 s ticker) outlives that test, so on a busy run it ticked inside
// A's sign-out of the same uid and wrote the line this test reads (farm run 509bcc58, NWP-20261115-09).
func TestLogoffWatchdog_ARetryClaimingInTheLastTickIsNotGuardedOnTheFirstClock(t *testing.T) {
	const uid = "79"
	dest := cutoffSession(t, uid)
	t.Cleanup(func() { endCutoffHold(uid) })
	lim, hc, tick, sy, tk := logoffStallLimit, logoffStallHardCap, logoffStallTick, logoffSync, logoffStallTicker
	t.Cleanup(func() {
		logoffStallLimit, logoffStallHardCap, logoffStallTick, logoffSync, logoffStallTicker = lim, hc, tick, sy, tk
	})
	logoffStallLimit, logoffStallHardCap, logoffStallTick = time.Hour, time.Millisecond, time.Hour
	logoffSync = func() {}
	aTicks := make(chan time.Time)
	logoffStallTicker = func(time.Duration) (<-chan time.Time, func()) { return aTicks, func() {} }
	errs := captureStderrLive(t)
	ops := cutoffWorker(t, dest,
		map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "ERR-PUSH 1||OK", "cutoffwake": "WAKE OK 3"},
		map[string]time.Duration{"out#1": 0, "out": 6 * time.Second})
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) }) // A
	deadline := time.Now().Add(15 * time.Second)
	for {
		pendingReapMu.Lock()
		failed, inFlight := sealFail, sealInFlight
		pendingReapMu.Unlock()
		if failed && !inFlight {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("A's seal never failed; roamd was handed %v", ops())
		}
		time.Sleep(10 * time.Millisecond)
	}
	if strings.Contains(errs.String(), watchdogSupersededLine) {
		t.Fatal("A's watchdog reported a supersede before any retry claimed")
	}
	// The retry gets a real ticker back; with the tick still an hour, its own watchdog stays quiet, as in production.
	logoffStallTicker = tk
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("the retry's LOGOUT replied %q", got)
	}
	select {
	case aTicks <- time.Now():
	case <-time.After(5 * time.Second):
		t.Fatalf("A's watchdog no longer reads its ticker; stderr:\n%s", errs.String())
	}
	deadline = time.Now().Add(5 * time.Second)
	for !strings.Contains(errs.String(), watchdogSupersededLine) {
		if time.Now().After(deadline) {
			t.Fatalf("A's watchdog took the tick after the retry's claim but reported no supersede; stderr:\n%s", errs.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
	select {
	case aTicks <- time.Now():
		t.Error("A's watchdog took a second tick after its supersede line (it must RETURN)")
	case <-time.After(500 * time.Millisecond):
	}
	log := errs.String()
	if n := strings.Count(log, watchdogSupersededLine); n != 1 {
		t.Errorf("the supersede line appeared %d times, want 1 (the watchdog must RETURN)", n)
	}
	if strings.Contains(log, "FAIL-SAFE unstick") {
		t.Errorf("A's watchdog un-stuck the retry on A's clock:\n%s", log)
	}
	pendingReapMu.Lock()
	unstuck, inFlight, why := sealUnstuck, sealInFlight, sealFailWhy
	pendingReapMu.Unlock()
	if unstuck || why == "ERR-STALLED" || !inFlight {
		t.Errorf("the retry was disturbed: sealUnstuck=%v sealInFlight=%v sealFailWhy=%q", unstuck, inFlight, why)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err == nil {
		t.Error("the session was re-armed under the retry")
	}
	// B lands: its own switch+reap, acknowledged so its reap fallback finds nothing stuck.
	deadline = time.Now().Add(20 * time.Second)
	for {
		pendingReapMu.Lock()
		reap := pendingReapUID
		pendingReapMu.Unlock()
		if reap == uid {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the retry never queued its reap; roamd was handed %v", ops())
		}
		time.Sleep(20 * time.Millisecond)
	}
	ackReapAction("SWITCH", uid)
	ackReapAction("REAP", uid)
	logoffDone(t, uid, 60*time.Second) // reapOrReboot sleeps 8 s + 12 s from the queue: 20 s is its floor
}

// Control: a single logoff that stalls is un-stuck exactly as before, and never claims a supersede.
func TestLogoffWatchdog_ASingleStalledLogoffIsStillUnstuck(t *testing.T) {
	const uid = "72"
	dest := cutoffSession(t, uid)
	lim, hc, tick := logoffStallLimit, logoffStallHardCap, logoffStallTick
	logoffStallLimit, logoffStallHardCap, logoffStallTick = 300*time.Millisecond, time.Hour, 50*time.Millisecond
	t.Cleanup(func() { logoffStallLimit, logoffStallHardCap, logoffStallTick = lim, hc, tick })
	errs := captureStderrLive(t)
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "OK", "cutoffwake": "WAKE OK 3"},
		map[string]time.Duration{"out": 2 * time.Second})
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	logoffDone(t, uid, 20*time.Second)
	pendingReapMu.Lock()
	unstuck, fail, why := sealUnstuck, sealFail, sealFailWhy
	pendingReapMu.Unlock()
	if !unstuck || !fail || why != "ERR-STALLED" {
		t.Errorf("the stalled logoff was not un-stuck: sealUnstuck=%v sealFail=%v sealFailWhy=%q", unstuck, fail, why)
	}
	log := errs.String()
	if !strings.Contains(log, "FAIL-SAFE unstick") {
		t.Errorf("no FAIL-SAFE unstick line:\n%s", log)
	}
	if strings.Contains(log, watchdogSupersededLine) {
		t.Errorf("a lone logoff's watchdog claimed a supersede:\n%s", log)
	}
}

// Source placement: the watchdog asks logoffSuperseded twice, each time inside a pendingReapMu Lock/Unlock pair, and
// the second ask comes before the unstick block mutates the seal state.
func TestLogoffWatchdog_TheSupersedeChecksSitUnderTheLock(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	from := strings.Index(s, `goSafe("logoff-stall-watchdog"`)
	to := strings.Index(s, `goSafe("logoff", func()`)
	if from < 0 || to < from {
		t.Fatal("the watchdog goroutine was not found in main.go")
	}
	w := s[from:to]
	const call = "logoffSuperseded("
	if n := strings.Count(w, call); n != 2 {
		t.Fatalf("the watchdog holds %d %s calls, want 2", n, call)
	}
	held := func(at int) bool {
		return strings.LastIndex(w[:at], "pendingReapMu.Lock()") > strings.LastIndex(w[:at], "pendingReapMu.Unlock()")
	}
	first := strings.Index(w, call)
	second := first + len(call) + strings.Index(w[first+len(call):], call)
	for i, at := range []int{first, second} {
		if !held(at) {
			t.Errorf("logoffSuperseded call %d is not inside a pendingReapMu Lock/Unlock pair", i+1)
		}
	}
	mutates := strings.Index(w, "sealUnstuck = true")
	if mutates < 0 || second > mutates {
		t.Error("the second supersede check does not come before the unstick block mutates sealUnstuck")
	}
	for _, field := range []string{"sealInFlight = false", "sealFail = true"} {
		if at := strings.Index(w, field); at < 0 || second > at {
			t.Errorf("the second supersede check does not come before %q", field)
		}
	}
	if !strings.Contains(w[second:mutates], "return") {
		t.Error("the unstick block's supersede check does not return")
	}
}
