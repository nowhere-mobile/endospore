package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20260923-03: the cold-lock teardown's ORDER, tested for the first time.
//
// Field-proven on frankel (tickets NW-c55d612879b8 / NW-27681dee8a8c, build 2026092203), user report verbatim:
// "Cold lock while using the phone". An idle lock crossed its point of no return (PNR) two seconds after the
// alarm, then waited 4.6 minutes for the RW worker slot behind a periodic seal before it switched the owner out.
// The owner came back in between, unlocked into a session that was already doomed, had the abort REJECTED, and
// was ejected. Nothing tested this order at all before, which is how its central invariant -- Check B's "the long
// wait has just happened above it" -- went false for three weeks without a single test noticing.
//
// These tests drive the REAL teardown through its coldLockWorker seam and stand in for the seal by holding the
// RW slot themselves. T1, T3 and T4 were run against the OLD order (PNR above the wait) and each FAILED, which is
// the proof that they reproduce the field bug rather than merely passing on the new code.

// clwCall is what the teardown looked like at the instant it dispatched one worker op.
type clwCall struct {
	op          string
	pass        string
	seSecret    string
	rwHeld      bool
	slotLen     int
	coldlock    bool
	roamsession bool
	mediadReq   bool
	switchUID   string
	lockUID     string
}

type clwRecorder struct {
	mu    sync.Mutex
	dest  string
	calls []clwCall
	count map[string]int
	// ret overrides the reply for the nth call (1-based) of an op; "" means the default "OK".
	ret func(op string, nth int) string
	// stops counts coldLockStopMediad calls. mediad.req alone cannot say whether mediad was stopped any more:
	// the post-revoke kick rewrites it, so "never stopped" and "stopped, then re-kicked" look the same.
	stops int
	// NWP-20261004-01: the pre-stop steps, each recorded as the teardown looked when it ran. Their own seams, not
	// coldLockWorker, so the op sequences the tests below pin keep meaning what they say.
	relays, sweeps []clwCall
}

// preStop records a coldLockRelayAlarm or coldLockSweepMedia call. The worker op is named for the snapshot only.
func (r *clwRecorder) preStop(into *[]clwCall, op string) func(dest, name, pass, uid string) {
	return func(dest, name, pass, uid string) {
		pendingReapMu.Lock()
		sw, lk := pendingSwitchUID, pendingLockUID
		pendingReapMu.Unlock()
		c := clwCall{op: op, pass: pass, rwHeld: len(laneRW.slot) > 0, slotLen: len(laneRW.slot),
			coldlock: clwExists(dest, ".coldlock"), roamsession: clwExists(dest, ".roamsession"),
			mediadReq: clwExists(dest, "mediad.req"), switchUID: sw, lockUID: lk}
		r.mu.Lock()
		*into = append(*into, c)
		r.mu.Unlock()
	}
}

func (r *clwRecorder) preStops() (relays, sweeps []clwCall) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]clwCall(nil), r.relays...), append([]clwCall(nil), r.sweeps...)
}

// stop stands in for stopMediad: it counts the stop, then runs the real one, whose deletion of mediad.req the
// ordering checks still read.
func (r *clwRecorder) stop(dest string) {
	r.mu.Lock()
	r.stops++
	r.mu.Unlock()
	stopMediad(dest)
}

func (r *clwRecorder) stopCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.stops
}

func (r *clwRecorder) worker(dest, op, name, pass, uid, seSecret string, rwHeld bool) string {
	pendingReapMu.Lock()
	sw, lk := pendingSwitchUID, pendingLockUID
	pendingReapMu.Unlock()
	c := clwCall{op: op, pass: pass, seSecret: seSecret, rwHeld: rwHeld, slotLen: len(laneRW.slot),
		coldlock: clwExists(dest, ".coldlock"), roamsession: clwExists(dest, ".roamsession"),
		mediadReq: clwExists(dest, "mediad.req"), switchUID: sw, lockUID: lk}
	r.mu.Lock()
	r.count[op]++
	n := r.count[op]
	r.calls = append(r.calls, c)
	ret := r.ret
	r.mu.Unlock()
	if ret != nil {
		if v := ret(op, n); v != "" {
			return v
		}
	}
	return "OK"
}

func (r *clwRecorder) snapshot() []clwCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]clwCall(nil), r.calls...)
}

func (r *clwRecorder) ops() []string {
	var out []string
	for _, c := range r.snapshot() {
		out = append(out, c.op)
	}
	return out
}

// clwHold stands in for the seal that holds the RW slot.
type clwHold struct{ held bool }

func (h *clwHold) take() { laneRW.slot <- struct{}{}; h.held = true }
func (h *clwHold) give() {
	if h.held {
		h.held = false
		<-laneRW.slot
	}
}

func clwExists(dest, f string) bool {
	_, err := os.Stat(filepath.Join(dest, f))
	return err == nil
}

func clwWaitFor(timeout time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return cond()
}

func clwFlags() (string, string) {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return pendingSwitchUID, pendingLockUID
}

func clwStarts() int {
	coldLockMu.Lock()
	defer coldLockMu.Unlock()
	return coldLockStarts
}

// clwParked waits until the teardown's waiter has passed its revoked() check more than `after` times, each pass
// just before it enters its select. A stamp published after the count moves cannot be seen by that pass, which is
// what makes T4 reach Check B. It does NOT prove the waiter is already in the slot's send queue: T2, which needs
// FIFO order, keeps a margin on top of it.
func clwParked(t *testing.T, after int64) {
	t.Helper()
	if !clwWaitFor(2*time.Second, func() bool { return coldLockParks.Load() > after }) {
		t.Fatal("the teardown never parked on the RW slot")
	}
}

// clwSetup plants a live session for user 10 and a pending mediad request (stopMediad deletes it, which is what
// makes the stop observable), swaps in the recorder for both seams, and registers a cleanup that waits for every
// teardown GOROUTINE to exit -- not just for coldLockRunning to clear, because the post-revoke mediad kick runs
// after it does -- and leaves the shared RW slot empty for whatever test runs next.
func clwSetup(t *testing.T) (string, *clwRecorder, *clwHold) {
	t.Helper()
	if n := len(laneRW.slot); n != 0 {
		t.Fatalf("the shared RW slot is already held (%d) -- a previous test leaked it; nothing below would mean anything", n)
	}
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "mediad.req"), []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := &clwRecorder{dest: dest, count: map[string]int{}}
	prev := coldLockWorker
	coldLockWorker = rec.worker
	prevStop := coldLockStopMediad
	coldLockStopMediad = rec.stop
	prevRelay, prevSweep := coldLockRelayAlarm, coldLockSweepMedia
	coldLockRelayAlarm = rec.preStop(&rec.relays, "alarmrelay")
	coldLockSweepMedia = rec.preStop(&rec.sweeps, "coldsweep")
	hold := &clwHold{}
	t.Cleanup(func() {
		hold.give()
		// Let any teardown still running finish: revoke and ring an abortable one; an explicit one needs only the
		// slot, which give() just freed. Then wait for the GOROUTINE, kick included.
		lastPresentAt.Store(1 << 62)
		ringColdLockBell(1 << 62)
		done := make(chan struct{})
		go func() { coldLockTeardowns.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("a cold-lock teardown goroutine (or its mediad kick) outlived the test")
		}
		for len(laneRW.slot) > 0 {
			<-laneRW.slot
		}
		coldLockWorker = prev
		coldLockStopMediad = prevStop
		coldLockRelayAlarm, coldLockSweepMedia = prevRelay, prevSweep
		lastPresentAt.Store(0)
		pendingReapMu.Lock()
		pendingSwitchUID, pendingLockUID, pendingRearmUID = "", "", ""
		pendingReapMu.Unlock()
		coldLockMu.Lock()
		coldLockRunning = false
		coldLockBell, coldLockBellAt = nil, 0
		coldLockRevoking, coldLockRerun, coldLockRerunAt = false, false, 0
		coldLockMu.Unlock()
		os.Unsetenv("NOWHERE_FIDO2_HMAC")
	})
	return dest, rec, hold
}

// clwLock sends the cold lock exactly as the daemon's dispatcher would, and returns its reply.
func clwLock(t *testing.T, dest string, decidedAt int64) string {
	t.Helper()
	server, client := net.Pipe()
	done := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(client).ReadString('\n')
		done <- line
	}()
	handleColdLock(server, dest, decidedAt)
	server.Close()
	reply := strings.TrimRight(<-done, "\r\n")
	client.Close()
	if !strings.Contains(reply, "LOCKING") {
		t.Fatalf("handleColdLock replied %q -- no teardown started, so nothing below tests anything", reply)
	}
	return reply
}

// T1. While someone else holds the RW slot, the teardown may run its credential step and NOTHING else: no marker,
// no .roamsession removal, no mediad stop, no switch. Then, once it holds the slot, btpark runs INSIDE the hold,
// after the commit, and the flags are published and the slot released.
func TestColdLockTouchesNothingIrreversibleUntilItHoldsRW(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p) // parked: anything a wrongly ordered teardown does before its wait has now been done

	if got := rec.ops(); len(got) != 1 || got[0] != "armcred" {
		t.Fatalf("while the seal holds the RW slot only the credential step may run; got %v", got)
	}
	if clwExists(dest, ".coldlock") {
		t.Error(".coldlock was written while the teardown was still QUEUED -- the point of no return was crossed " +
			"BEFORE the wait. That is the field bug: an owner who comes back now is rejected and ejected")
	}
	if !clwExists(dest, ".roamsession") {
		t.Error(".roamsession was removed while still queued -- an unlock now would be REJECTED (auid != live)")
	}
	if !clwExists(dest, "mediad.req") {
		t.Error("mediad was stopped while still queued -- a returning owner would have on-demand media dead for " +
			"the whole wait, which can be a whole seal (48 minutes measured)")
	}
	if sw, _ := clwFlags(); sw != "" {
		t.Errorf("the switch was published while still queued (%q)", sw)
	}

	hold.give() // the seal finishes
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown did not finish within 2s of the slot freeing -- the signature of an RW op re-entering " +
			"the acquire for the slot it already holds, which deadlocks the lane device-wide")
	}
	calls := rec.snapshot()
	if len(calls) != 2 || calls[1].op != "btpark" {
		t.Fatalf("ops = %v, want [armcred btpark]", rec.ops())
	}
	bp := calls[1]
	if !bp.rwHeld {
		t.Error("btpark was dispatched with rwHeld=false -- i.e. through triggerRoamWorker, outside the hold")
	}
	if bp.slotLen != 1 {
		t.Errorf("btpark ran with len(RW slot)=%d; the teardown must be holding it (1)", bp.slotLen)
	}
	if !bp.coldlock || bp.roamsession {
		t.Errorf("btpark ran before the commit (coldlock=%v roamsession=%v)", bp.coldlock, bp.roamsession)
	}
	if bp.mediadReq {
		t.Error("btpark ran before stopMediad")
	}
	if bp.switchUID != "" {
		t.Error("the switch was published BEFORE btpark -- the owner is switched out while their bonds are still live")
	}
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags = %q/%q, want 10/10 -- the lock never became visible", sw, lk)
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot was left full (%d) after the teardown -- every later seal, login and restore would wedge", n)
	}
	if n := rec.stopCount(); n != 1 {
		t.Errorf("mediad was stopped %d times by a committed lock, want exactly 1", n)
	}
}

// T2. The flags are published BEFORE the slot is released, so the next op in the queue sees the lock -- a seal
// queued behind the teardown must read pendingSwitchUID and skip, never seal a user about to be stopped.
func TestColdLockPublishesTheSwitchBeforeReleasingRW(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	// ...plus a margin: the counter moves just BEFORE the waiter's select enqueues it on the slot, and this test is
	// the one that needs the teardown to be ahead of W in that queue.
	time.Sleep(100 * time.Millisecond)

	type seen struct {
		sw       string
		coldlock bool
	}
	got := make(chan seen, 1)
	go func() {
		laneRW.slot <- struct{}{} // W queues SECOND, behind the teardown
		sw, _ := clwFlags()
		s := seen{sw, clwExists(dest, ".coldlock")}
		<-laneRW.slot
		got <- s
	}()
	time.Sleep(50 * time.Millisecond)
	hold.give() // FIFO: the teardown acquires, commits, publishes, releases -- then W

	select {
	case s := <-got:
		if s.sw != "10" || !s.coldlock {
			t.Errorf("the next op in the queue saw switch=%q coldlock=%v; want 10/true -- the slot was released "+
				"before the lock was published, so a queued seal would run on a user that is about to be stopped",
				s.sw, s.coldlock)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the next op never acquired the slot")
	}

	// ⚠ THE CHECK ABOVE CANNOT CATCH ONE REORDERING, and that was measured, not assumed. If release() ran BEFORE
	// the flags, the slot hands off to W and the teardown's flag write RACES W's read -- and the teardown, already
	// on the CPU, usually wins, so the mutation that moves release() above the flags passed this test. So the
	// order is pinned in the SOURCE as well, on live code lines (comments stripped), the way the Check A adjacency
	// is pinned in logoff_veto_test.go.
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	i := strings.Index(src, "func coldLockTeardown(")
	if i < 0 {
		t.Fatal("control failed: coldLockTeardown not found in main.go, so the order check below proves nothing")
	}
	body := src[i:]
	if j := strings.Index(body, "\n}\n"); j > 0 {
		body = body[:j]
	}
	lines := codeLines(body)
	// ⚠ "the LAST release() is after the flags" is a false green: a mutation that INSERTS an early release() and
	// leaves the original at the end still satisfies it. What matters is the FIRST release() after btpark.
	btparkAt, flagAt, firstRelease := -1, -1, -1
	for n, l := range lines {
		if btparkAt < 0 && strings.Contains(l, `coldLockWorker(dest, "btpark"`) {
			btparkAt = n
		}
		if btparkAt >= 0 && flagAt < 0 && (l == "pendingLockUID = uid" || strings.HasPrefix(l, "pendingLockUID = uid ")) {
			flagAt = n
		}
		if btparkAt >= 0 && firstRelease < 0 && l == "release()" {
			firstRelease = n
		}
	}
	if btparkAt < 0 || flagAt < 0 || firstRelease < 0 {
		t.Fatalf("control failed: btpark (%d), the flag write (%d) or a release() after btpark (%d) not found in "+
			"coldLockTeardown, so the order check below proves nothing", btparkAt, flagAt, firstRelease)
	}
	if firstRelease < flagAt {
		t.Error("coldLockTeardown releases the RW slot after btpark BEFORE publishing the flags -- a seal queued " +
			"behind the teardown can take the slot and seal a user that is about to be stopped")
	}
}

// T3. THE INCIDENT. The owner unlocks while the teardown is queued behind a seal. The abort must be ARMED (today's
// order REJECTED it), and the teardown must leave the queue at once without having touched anything.
func TestColdLockAbortDuringTheWaitLeavesTheQueueUntouched(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000) // an idle lock, decided at 1000
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p) // genuinely mid-wait

	armed, luid := armColdLockAbort(dest, "10", 2000) // the owner unlocks, mid-wait
	if !armed {
		t.Fatalf("the unlock was REJECTED (live=%q). That is the field bug verbatim: the commit had already "+
			"removed .roamsession, so a genuine unlock of THIS session read as a stale one", luid)
	}
	if !clwWaitFor(time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown did not leave the queue within 1s of the unlock -- the bell never woke it, and it will " +
			"sit there until the seal ends and then commit anyway")
	}
	if got := rec.ops(); len(got) != 1 || got[0] != "armcred" {
		t.Errorf("ops = %v; only the credential step may have run", got)
	}
	if clwExists(dest, ".coldlock") {
		t.Error(".coldlock was written -- the owner will be offered a resume they did not ask for")
	}
	if !clwExists(dest, ".roamsession") {
		t.Error(".roamsession was removed -- the live session is no longer recorded and its periodic seals stop")
	}
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s) -- the returning owner's on-demand media is dead", n)
	}
	if sw, _ := clwFlags(); sw != "" {
		t.Errorf("the switch was published (%q) -- the owner would be ejected", sw)
	}
	if n := len(laneRW.slot); n != 1 {
		t.Errorf("len(RW slot) = %d, want 1: the seal still holds it, and a teardown that left the queue must never "+
			"have taken it", n)
	}

	// The backstop re-arms: the NEXT idle fire starts a fresh teardown.
	before := clwStarts()
	clwLock(t, dest, 3000)
	if after := clwStarts(); after != before+1 {
		t.Errorf("a later idle lock started %d teardowns, want 1 -- the revoked lock left the machinery wedged",
			after-before)
	}
	armColdLockAbort(dest, "10", 4000) // revoke that one too, so it leaves before cleanup
}

// T4. An unlock that lands BETWEEN the waiter's last check and its acquire -- published without a ring -- must
// still be caught by Check B, and the slot must be released on the way out.
func TestColdLockCheckBRevokesAnAbortThatRacedTheAcquire(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	lastPresentAt.Store(2000) // published AFTER the waiter's check, and NOT rung: it can only be seen at Check B
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if got := rec.ops(); len(got) != 1 || got[0] != "armcred" {
		t.Errorf("ops = %v; Check B must have revoked before btpark", got)
	}
	if clwExists(dest, ".coldlock") || !clwExists(dest, ".roamsession") || !clwExists(dest, "mediad.req") {
		t.Errorf("a revoke at Check B touched state: coldlock=%v roamsession=%v mediad.req=%v",
			clwExists(dest, ".coldlock"), clwExists(dest, ".roamsession"), clwExists(dest, "mediad.req"))
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the revoke path left the RW slot held (%d) -- every later worker op on the device would wedge", n)
	}
	// ⚠ The mediad.req check above no longer proves this on its own: the post-revoke kick rewrites the file, so
	// "stopped, then re-kicked" would pass it. Count the stops themselves (second review).
	if n := rec.stopCount(); n != 0 {
		t.Errorf("a revoke at Check B stopped mediad %d time(s) -- a returning owner's on-demand media dies", n)
	}
}

// T5. An EXPLICIT lock (Profile > Lock, a hand-switch: decidedAt == 0) is not abandonable. An unlock during its
// wait does not revoke it, and it commits once the slot frees.
func TestColdLockExplicitLockIsNotAbandonable(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	armColdLockAbort(dest, "10", 2000)
	time.Sleep(200 * time.Millisecond)
	if !coldLockInFlight() {
		t.Fatal("an explicit lock was abandoned by an unlock -- the owner asked for it, and it is not an idle backstop")
	}
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the explicit lock never finished")
	}
	if got := rec.ops(); len(got) != 2 || got[1] != "btpark" || !clwExists(dest, ".coldlock") {
		t.Errorf("ops = %v coldlock=%v; the explicit lock must commit", got, clwExists(dest, ".coldlock"))
	}
	if n := rec.stopCount(); n != 1 {
		t.Errorf("mediad was stopped %d times by a committed lock, want exactly 1", n)
	}
}

// T5b (review fix). An EXPLICIT lock that FOLDS into a queued idle lock makes it explicit. Without that, the owner
// taps Lock while an idle lock waits behind a seal, gets LOCKING, and a later unlock abandons what they asked for --
// leaving ProfileActivity pinned on "Locking..." with the screen kept on and the session CE-unlocked indefinitely.
func TestColdLockExplicitFoldMakesAQueuedIdleLockUnrevocable(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000) // an idle, abortable lock queues behind the seal
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	before := clwStarts()
	clwLock(t, dest, 0) // the owner taps Lock: it folds into the running teardown
	if clwStarts() != before {
		t.Fatal("the explicit lock started a SECOND teardown instead of folding into the running one")
	}
	armColdLockAbort(dest, "10", 2000) // then an unlock lands
	time.Sleep(200 * time.Millisecond)
	if !coldLockInFlight() {
		t.Fatal("the folded lock was ABANDONED by an unlock -- the owner asked to lock, and nothing will now stop the user")
	}
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the folded lock never finished")
	}
	if got := rec.ops(); len(got) != 2 || got[1] != "btpark" || !clwExists(dest, ".coldlock") {
		t.Errorf("ops = %v coldlock=%v; the folded lock must commit", got, clwExists(dest, ".coldlock"))
	}
	if n := rec.stopCount(); n != 1 {
		t.Errorf("mediad was stopped %d times by a committed lock, want exactly 1", n)
	}
}

// T4b (review fix). A lock revoked AFTER it took the slot took it from a seal whose post-seal mediad self-heal
// stood down for this teardown (G2). So the teardown re-kicks mediad itself -- after coldLockRunning clears, or the
// same stand-down would swallow it.
func TestColdLockRevokedAfterAcquireRekicksMediad(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	os.Remove(filepath.Join(dest, "mediad.req")) // mediad died during the seal: nothing requested
	lastPresentAt.Store(2000)                    // unlock published without a ring -> caught at Check B, AFTER acquiring
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if !clwWaitFor(time.Second, func() bool { return clwExists(dest, "mediad.req") }) {
		t.Error("no mediad kick after a revoke that took the slot from a seal -- on-demand media stays dead until the " +
			"next periodic seal, because that seal's own self-heal stood down for this teardown")
	}
}

// T4c (second review). The mediad re-kick does not depend on having held the slot. kickMediad stands down for the
// teardown's WHOLE life (G2), so a seal that finished while this teardown was still in its credential step, or
// queued behind ANOTHER RW op, lost its self-heal kick too. A lock revoked while queued must kick as well -- and
// without ever having taken the slot.
func TestColdLockRevokedWhileQueuedRekicksMediad(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	os.Remove(filepath.Join(dest, "mediad.req")) // mediad died; the seal's self-heal kick stood down for this lock
	if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
		t.Fatal("the unlock was rejected")
	}
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never left the queue")
	}
	if !clwWaitFor(time.Second, func() bool { return clwExists(dest, "mediad.req") }) {
		t.Error("no mediad kick after a revoke that never took the slot -- on-demand media stays dead for the " +
			"returning owner until the next periodic seal finishes")
	}
	if n := len(laneRW.slot); n != 1 {
		t.Errorf("len(RW slot) = %d, want 1: the kick must come without the teardown ever acquiring the slot", n)
	}
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s) on a revoke path", n)
	}
}

// T5c (second review). An IDLE fire folding into a queued IDLE lock leaves it exactly as revocable as it was. The
// NWP-20260922-07 re-arm path sends a second COLD-LOCK-IDLE while the first teardown is still queued -- a window that
// is now minutes long -- and if that fold made the lock explicit, an owner who comes back would be ejected: the field
// bug, back through the side door.
func TestColdLockIdleFoldLeavesAnIdleLockRevocable(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	before := clwStarts()
	clwLock(t, dest, 5000) // a second idle fire folds in
	if clwStarts() != before {
		t.Fatal("the second idle fire started a SECOND teardown instead of folding into the running one")
	}
	if armed, _ := armColdLockAbort(dest, "10", 6000); !armed {
		t.Fatal("the unlock was rejected")
	}
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("an idle lock that another idle fire folded into could no longer be revoked -- the owner who comes " +
			"back is ejected")
	}
	if got := rec.ops(); len(got) != 1 || got[0] != "armcred" {
		t.Errorf("ops = %v; only the credential step may have run", got)
	}
	if clwExists(dest, ".coldlock") || !clwExists(dest, ".roamsession") {
		t.Errorf("the revoked lock touched state: coldlock=%v roamsession=%v",
			clwExists(dest, ".coldlock"), clwExists(dest, ".roamsession"))
	}
	if n := len(laneRW.slot); n != 1 {
		t.Errorf("len(RW slot) = %d, want 1", n)
	}
}

// T5d (second review). An IDLE fire folding into a queued EXPLICIT lock must not make it revocable: the owner asked
// for that lock, and an unlock afterwards is them handing the phone over, not coming back to it.
func TestColdLockIdleFoldLeavesAnExplicitLockUnrevocable(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	clwLock(t, dest, 5000) // an idle fire folds into the explicit lock
	armColdLockAbort(dest, "10", 6000)
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the explicit lock never finished")
	}
	if got := rec.ops(); len(got) != 2 || got[1] != "btpark" || !clwExists(dest, ".coldlock") {
		t.Errorf("ops = %v coldlock=%v; an idle fold must not have made the explicit lock revocable",
			got, clwExists(dest, ".coldlock"))
	}
}

// clwRevokeHeldOpen drives a 2FA session into a revoke whose UNWIND is held open, so a lock request can land after
// the revoke is decided. The 2FA unwind is used only because it is the one revoke path slow enough to land in: in the
// field a 2FA owner cannot unlock after the forward rekey (main.go G1; docs/backlog.md, the 2FA cold-lock row), so
// the reachable case is an unlock in the seconds before that rekey lands, then a request while the unwind runs. The
// rerun machinery under test does not depend on how the revoke was decided. The unwind replies unwindRet ("" = OK).
//
// The returned release is idempotent and registered as a cleanup, so a test that fails early can never leave a
// teardown blocked in the hook -- that would hang every later clw test behind coldLockTeardowns (third review).
func clwRevokeHeldOpen(t *testing.T, dest string, rec *clwRecorder, hold *clwHold, unwindRet string) (release func(), parks int64) {
	t.Helper()
	clwFido2(t, dest)
	unwinding := make(chan struct{})
	resume := make(chan struct{})
	var once sync.Once
	release = func() { once.Do(func() { close(resume) }) }
	t.Cleanup(release)
	rec.ret = func(op string, nth int) string {
		if op == "rekey" && nth == 2 { // the revoke's unwind: hold it open
			close(unwinding)
			<-resume
			return unwindRet
		}
		return ""
	}
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the forward rekey never ran")
	}
	clwParked(t, p)
	parks = coldLockParks.Load()
	if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
		t.Fatal("the unlock was rejected")
	}
	select {
	case <-unwinding:
	case <-time.After(2 * time.Second):
		t.Fatal("the revoke's unwind never started")
	}
	return release, parks
}

// T10 (second review). A lock request that lands AFTER the teardown has decided to revoke has nothing to fold into.
// It used to be answered LOCKING and dropped: an explicit Lock tap silently lost, ProfileActivity pinned on
// "Locking...", the session left CE-unlocked. The owner taps Lock while the revoke is still unwinding; that lock must
// run once the revoke has finished -- in the same goroutine, so there is never a second teardown alongside the first.
func TestColdLockRequestDuringARevokeRunsAfterIt(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	release, p := clwRevokeHeldOpen(t, dest, rec, hold, "")
	before := clwStarts()
	clwLock(t, dest, 0) // the owner taps Lock while the revoke is still unwinding
	release()
	if clwStarts() != before {
		t.Fatal("a second teardown goroutine started alongside the revoking one")
	}
	// The revoke finishes; then the queued explicit lock runs its own forward rekey and queues behind the seal.
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 3 }) {
		t.Fatalf("ops = %v: the lock tapped during the revoke never ran -- it was answered LOCKING and dropped",
			rec.ops())
	}
	clwParked(t, p)
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the queued lock never finished")
	}
	got := rec.ops()
	if len(got) != 4 || got[0] != "rekey" || got[1] != "rekey" || got[2] != "rekey" || got[3] != "btpark" {
		t.Fatalf("ops = %v, want [rekey rekey rekey btpark]: forward, unwind, the rerun's forward, then its commit", got)
	}
	if !clwExists(dest, ".coldlock") {
		t.Error("the queued lock did not commit")
	}
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags = %q/%q, want 10/10", sw, lk)
	}
	if n := rec.stopCount(); n != 1 {
		t.Errorf("mediad was stopped %d times, want exactly 1 (by the committed rerun)", n)
	}
}

// T10b (third review). An IDLE request queued during a revoke keeps its OWN stamp. Decided at 1500, before the unlock
// at 2000 that revoked the running lock, it is revoked by that same unlock at its own Check A -- before it runs a
// credential step. A rerun made explicit here would lock a phone its owner had just unlocked.
func TestColdLockIdleRequestDuringARevokeKeepsItsStamp(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	release, _ := clwRevokeHeldOpen(t, dest, rec, hold, "")
	clwLock(t, dest, 1500)
	release()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatalf("ops = %v: the queued idle rerun did not end -- it ran as an unrevocable lock", rec.ops())
	}
	if got := rec.ops(); len(got) != 2 {
		t.Fatalf("ops = %v, want [rekey rekey]: the rerun must be revoked at Check A, before its own credential step", got)
	}
	if clwExists(dest, ".coldlock") || !clwExists(dest, ".roamsession") {
		t.Errorf("the revoked rerun touched state: coldlock=%v roamsession=%v",
			clwExists(dest, ".coldlock"), clwExists(dest, ".roamsession"))
	}
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s)", n)
	}
	if n := len(laneRW.slot); n != 1 {
		t.Errorf("len(RW slot) = %d, want 1", n)
	}
}

// T10c (third review). An idle request decided AFTER the unlock survives it -- and, being idle, gets a BELL of its
// own: a later unlock takes it out of the queue exactly like the lock it replaced.
func TestColdLockIdleRerunIsItselfAbortable(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	release, p := clwRevokeHeldOpen(t, dest, rec, hold, "")
	clwLock(t, dest, 3000) // decided after the unlock at 2000
	release()
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 3 }) {
		t.Fatalf("ops = %v: the idle rerun decided after the unlock never ran", rec.ops())
	}
	clwParked(t, p)
	if armed, _ := armColdLockAbort(dest, "10", 4000); !armed {
		t.Fatal("the second unlock was rejected")
	}
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the idle rerun could not be revoked while queued -- it had no bell")
	}
	if got := rec.ops(); len(got) != 4 {
		t.Errorf("ops = %v, want [rekey rekey rekey rekey]: the rerun's forward rekey, then its own unwind", got)
	}
	if clwExists(dest, ".coldlock") {
		t.Error("the revoked rerun committed")
	}
	if n := len(laneRW.slot); n != 1 {
		t.Errorf("len(RW slot) = %d, want 1: a rerun revoked while queued must never have taken it", n)
	}
}

// T6c (third review). A request queued during a revoke that is then DECLINED -- the unwind failed, so the lock commits
// after all -- is satisfied by that commit. It must not run a SECOND teardown over a user that is being stopped: that
// would re-arm the credential on a stopped user and rewrite the marker it just wrote.
func TestColdLockRequestDuringADeclinedRevokeIsSatisfiedByTheCommit(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	release, p := clwRevokeHeldOpen(t, dest, rec, hold, "ERR-REKEY")
	before := clwStarts()
	clwLock(t, dest, 0)
	release()
	clwParked(t, p) // the declined revoke queues for the slot again
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the declined lock never finished")
	}
	got := rec.ops()
	if len(got) != 3 || got[2] != "btpark" {
		t.Fatalf("ops = %v, want [rekey rekey btpark]: the queued request ran a second teardown after the commit", got)
	}
	if n := rec.stopCount(); n != 1 {
		t.Errorf("mediad was stopped %d times, want exactly 1", n)
	}
	if clwStarts() != before {
		t.Error("a second teardown goroutine started")
	}
	if b, _ := os.ReadFile(filepath.Join(dest, ".coldlock")); len(strings.Split(string(b), "\n")) < 4 ||
		strings.Split(string(b), "\n")[3] != "fido2" {
		t.Errorf("the marker was rewritten by a second teardown: %q", b)
	}
}

// T5e (third review). A NEWER idle decision that folds into a running idle lock before any revoke is queued, not
// dropped. Before, it was answered LOCKING -- spending the chooser's alarm -- and then an unlock between the two
// stamps revoked the running lock and no lock came at all: a CE-unlocked session with no idle bound.
func TestColdLockNewerIdleFoldSurvivesAnOlderRevoke(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	before := clwStarts()
	clwLock(t, dest, 5000) // a newer idle decision folds in
	if clwStarts() != before {
		t.Fatal("the newer idle decision started a SECOND teardown")
	}
	p = coldLockParks.Load()
	if armed, _ := armColdLockAbort(dest, "10", 3000); !armed { // an unlock BETWEEN the two stamps
		t.Fatal("the unlock was rejected")
	}
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 2 }) {
		t.Fatalf("ops = %v: the newer idle decision was DROPPED when the older lock was revoked", rec.ops())
	}
	clwParked(t, p)
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the rerun never finished")
	}
	if got := rec.ops(); len(got) != 3 || got[2] != "btpark" || !clwExists(dest, ".coldlock") {
		t.Errorf("ops = %v coldlock=%v, want [armcred armcred btpark] and a committed lock", got, clwExists(dest, ".coldlock"))
	}
	if n := rec.stopCount(); n != 1 {
		t.Errorf("mediad was stopped %d times, want exactly 1", n)
	}
}

// F7 (third review). Check A publishes its revoke decision on BOTH of its branches. No behavioural seam reaches the
// window between Check A's decision and coldLockNext, so this is pinned in source, the way logoff_veto_test.go pins
// Check A's veto -- on live code lines, so a copy in a comment cannot satisfy it.
func TestColdLockCheckAPublishesItsRevokeDecision(t *testing.T) {
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	if !hasCodeLinePrefix(src, "if coldLockRevoked(decidedAt, lastPresentAt.Load()) {") {
		t.Fatal("control failed: Check A's user-present test is not in main.go, so the pins below prove nothing")
	}
	if !hasCodeLineFollowedBy(src, "if coldLockRevoked(decidedAt, lastPresentAt.Load()) {", "coldLockRevoking = true") {
		t.Error("Check A's user-present revoke no longer publishes coldLockRevoking -- a request landing after it is " +
			"folded into a lock that is not happening, answered LOCKING, and lost")
	}
	if !hasCodeLineFollowedBy(src,
		`fmt.Fprintf(os.Stderr, "[logind] cold-lock ABORTED before teardown (logoff in flight for user %s)\n", uid)`,
		"coldLockRevoking = true") {
		t.Error("Check A's logoff revoke no longer publishes coldLockRevoking")
	}
}

// clwFido2 makes the session key-enrolled, so the cold credential is the derived coldCredPIN and the teardown
// takes the 2FA branch: a forward rekey before the wait, and an unwind if it is revoked.
func clwFido2(t *testing.T, dest string) {
	t.Helper()
	b := make([]byte, fido2HMACLen)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".fido2hmac"), []byte(hex.EncodeToString(b)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// T6a. A 2FA lock revoked while queued unwinds its rekey and never takes the slot.
func TestColdLockFido2RevokedWhileQueuedUnwindsTheRekey(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	clwFido2(t, dest)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the forward rekey never ran")
	}
	clwParked(t, p)
	if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
		t.Fatal("the unlock was rejected")
	}
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	calls := rec.snapshot()
	if len(calls) != 2 || calls[0].op != "rekey" || calls[1].op != "rekey" {
		t.Fatalf("ops = %v, want [rekey rekey]: forward, then the unwind", rec.ops())
	}
	if calls[1].pass != calls[0].seSecret || calls[1].seSecret != calls[0].pass {
		t.Error("the second rekey is not the INVERSE of the first -- the owner is left on the untypable coldCredPIN")
	}
	if n := len(laneRW.slot); n != 1 {
		t.Errorf("len(RW slot) = %d, want 1 -- a revoke while queued must never have taken it", n)
	}
	if n := rec.stopCount(); n != 0 {
		t.Errorf("mediad was stopped %d time(s) on a revoke path", n)
	}
}

// T6b. If the unwind FAILS the revoke is declined and the lock completes -- and since the teardown had already
// left the queue, it must QUEUE AGAIN and wait for the slot before touching anything.
//
// ⚠ The obvious assertion here is a false green. btpark is dispatched with rwHeld=true as a literal, so a teardown
// that skipped the re-acquire would still record rwHeld=true -- and len(slot)==1 would be the TEST's token, not
// the teardown's. The honest discriminator is timing: while the test still holds the slot, a declined revoke must
// be waiting, with nothing committed and btpark not yet called.
func TestColdLockFido2DeclinedRevokeRequeuesBeforeCommitting(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	clwFido2(t, dest)
	rec.ret = func(op string, nth int) string {
		if op == "rekey" && nth == 2 {
			return "ERR-REKEY" // the unwind fails
		}
		return ""
	}
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the forward rekey never ran")
	}
	clwParked(t, p)
	p = coldLockParks.Load()
	armColdLockAbort(dest, "10", 2000)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 2 }) {
		t.Fatal("the unwind was never attempted")
	}
	// The declined revoke must QUEUE AGAIN: wait until it has parked on the slot. A teardown that skipped the
	// re-acquire never parks, so this Fatals with it rather than racing it.
	clwParked(t, p)
	if got := rec.ops(); len(got) != 2 {
		t.Fatalf("ops = %v while the seal still holds the slot -- a declined revoke committed WITHOUT re-queueing, so "+
			"btpark ran outside the hold, racing the seal for roam.req", got)
	}
	if clwExists(dest, ".coldlock") {
		t.Fatal(".coldlock written while the seal still holds the slot -- committed without re-queueing")
	}
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the declined lock never finished")
	}
	calls := rec.snapshot()
	if len(calls) != 3 || calls[2].op != "btpark" {
		t.Fatalf("ops = %v, want [rekey rekey btpark]", rec.ops())
	}
	if calls[2].slotLen != 1 || !calls[2].coldlock {
		t.Errorf("btpark ran with len(slot)=%d coldlock=%v", calls[2].slotLen, calls[2].coldlock)
	}
	if n := rec.stopCount(); n != 1 {
		t.Errorf("mediad was stopped %d times by the declined-then-committed lock, want 1", n)
	}
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags = %q/%q, want 10/10", sw, lk)
	}
}

// T7. An RW op outside the hold fails CLOSED rather than racing the holder, and the held path refuses an op that
// does not belong to the lane it holds.
func TestColdLockDispatchFailsClosedOutsideTheHold(t *testing.T) {
	// The pure lane facts FIRST, and fatally. If rekey rode the RW lane, the runWorkerHeld call below would find no
	// lane mismatch and go on to poll a worker for 150s -- so the test must stop here, cleanly, rather than hang
	// (measured: it did hang, and a timeout reads nothing like the defect that caused it).
	if laneFor("btpark").svc != laneRW.svc {
		t.Fatal("btpark no longer rides the RW lane -- the hold would not cover it")
	}
	for _, op := range []string{"armcred", "rekey"} {
		if laneFor(op).slot == laneRW.slot {
			t.Fatalf("%s shares the RW slot -- the teardown's RW->Cred nesting would self-deadlock", op)
		}
	}
	dest := t.TempDir()
	if got := coldLockDispatch(dest, "btpark", "alice", "pw", "10", "", false); got != "ERR-LANE" {
		t.Errorf("btpark outside the hold returned %q, want ERR-LANE", got)
	}
	if clwExists(dest, laneRW.req) {
		t.Error("roam.req was written by an RW op outside the hold -- it would race the real holder's request")
	}
	if got := runWorkerHeld(laneRW, dest, "rekey", "alice", "pw", "10", "", "", "", "", nil); got != "ERR-LANE" {
		t.Errorf("runWorkerHeld(laneRW, rekey) returned %q, want ERR-LANE -- a credential op would share roam.req", got)
	}
	if clwExists(dest, laneRW.req) || clwExists(dest, laneCred.req) {
		t.Error("a request file was written for a lane mismatch")
	}
}

// T8. kickMediad stands down while a cold lock is in flight (G2). With the control: the same kick, with no lock in
// flight, DOES write the request -- otherwise "no request" would only prove the probe cannot see a kick.
func TestKickMediadStandsDownWhileAColdLockIsInFlight(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		coldLockMu.Lock()
		coldLockRunning = false
		coldLockMu.Unlock()
	})
	coldLockMu.Lock()
	coldLockRunning = true
	coldLockMu.Unlock()
	kickMediad(dest)
	if clwExists(dest, "mediad.req") {
		t.Error("kickMediad wrote mediad.req while a cold lock was in flight -- the post-seal self-heal can start " +
			"mediad after the teardown's stopMediad, and mediad then pins the CE key through stopUser")
	}
	coldLockMu.Lock()
	coldLockRunning = false
	coldLockMu.Unlock()
	kickMediad(dest)
	if !clwExists(dest, "mediad.req") {
		t.Fatal("control failed: the kick wrote nothing even with no cold lock in flight, so the check above proves nothing")
	}
}

// T9. The seal clobber guard refuses a uid that .coldlock names (G3), before any request is written.
func TestClobberGuardRefusesAColdLockedUid(t *testing.T) {
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("alice\n10\n\nnokey\nnopin\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if u := coldLockedUID(dest); u != "10" {
		t.Fatalf("control failed: coldLockedUID read %q from a marker naming 10, so the guard below cannot fire", u)
	}
	done := make(chan string, 1)
	go func() { done <- runWorkerHeld(laneRW, dest, "out", "alice", "pw", "10", "", "", "", "", nil) }()
	select {
	case got := <-done:
		if got != "SKIP-REAPING" {
			t.Errorf("a seal for a cold-locked uid returned %q, want SKIP-REAPING", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a seal for a cold-locked uid got past the guard and is now polling a worker")
	}
	if clwExists(dest, laneRW.req) {
		t.Error("roam.req was written for a cold-locked uid -- the seal would run on a user being stopped")
	}
}

// NWP-20261004-01. The two pre-stop steps -- the alarm relay and the media sweep -- run exactly once per committed
// lock, and only where they can do their job: AFTER the point of no return (a revoked lock must not have handed the
// gate an alarm for a session that carries on, nor torn its media down), INSIDE the RW hold (both are worker ops),
// and BEFORE the LOCK is published (the stop follows the LOCK, and both need the user still running). Since
// NWP-20261121-01 the switch is already published when they run: they need the user running, not in front.
func TestColdLockPreStopStepsRunInsideTheHoldBeforeTheSwitch(t *testing.T) {
	dest, rec, hold := clwSetup(t)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 1 }) {
		t.Fatal("the credential step never ran")
	}
	clwParked(t, p)
	if relays, sweeps := rec.preStops(); len(relays) != 0 || len(sweeps) != 0 {
		t.Fatalf("relay=%d sweep=%d while the teardown was still QUEUED -- both must wait for the point of no "+
			"return, or an owner who comes back now has lost on-demand media and handed the gate a stale alarm",
			len(relays), len(sweeps))
	}
	hold.give()
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	relays, sweeps := rec.preStops()
	if len(relays) != 1 || len(sweeps) != 1 {
		t.Fatalf("relay ran %d time(s), sweep %d time(s); want exactly one each per committed lock", len(relays), len(sweeps))
	}
	for _, c := range []clwCall{relays[0], sweeps[0]} {
		if !c.coldlock || c.roamsession {
			t.Errorf("%s ran before the commit (coldlock=%v roamsession=%v)", c.op, c.coldlock, c.roamsession)
		}
		if c.slotLen != 1 {
			t.Errorf("%s ran with len(RW slot)=%d -- it is a worker op and must run inside the teardown's hold", c.op, c.slotLen)
		}
		if c.switchUID != "10" {
			t.Errorf("%s ran before the switch was published (%q) -- the gate stays behind the session for the "+
				"whole step (NWP-20261121-01)", c.op, c.switchUID)
		}
		if c.lockUID != "" {
			t.Errorf("%s ran after the LOCK was published (%q) -- the stop follows the LOCK, not the switch, so "+
				"the user may already be stopped when it runs", c.op, c.lockUID)
		}
		if c.pass != "pw" {
			t.Errorf("%s was not given the session's credential (got %q)", c.op, c.pass)
		}
	}
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags after the lock = (%q, %q), want (10, 10)", sw, lk)
	}
}

// NWP-20261004-01. A lock revoked at Check B -- after it took the slot, before the commit -- runs neither step: the
// session carries on, so its media must stay up and the gate must not be handed an alarm it would ring over a
// live session.
func TestColdLockRevokedRunsNoPreStopStep(t *testing.T) {
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
		t.Fatal("control failed: the lock committed, so this test proves nothing about the revoke path")
	}
	if relays, sweeps := rec.preStops(); len(relays) != 0 || len(sweeps) != 0 {
		t.Errorf("relay=%d sweep=%d on a REVOKED lock", len(relays), len(sweeps))
	}
}
