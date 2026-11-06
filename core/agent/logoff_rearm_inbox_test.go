package main

// NWP-20261019-04: handleLogout removes .roamsession before its seal, so an arrival on a bound SIM during the seal
// is sealed to the RAM-only inbox. Each of the three arms that re-arm the session (seal failed, seal stalled, media
// sweep did not verify) now stages that inbox for the surviving session, after the re-arm. These tests drive the
// real handleLogout through cutoffWorker / cutoffWorkerGated with logoffStageInbox stubbed; test-logoff-rearm-inbox.sh re-runs them
// against broken copies of main.go.

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const rearmSecretHex = "a1b2c3d4e5f60718"

const rearmHang = 2 * time.Minute // a hang, never a slow lane: farm CI runs at GOMAXPROCS 1-8 under a CPU quota (NWP-20261123-16)

type stageCall struct {
	base, name, pass, uid string
	se                    []byte
	markerPresent         bool
}

// recordStaging stubs logoffStageInbox, noting for each call whether the marker of dest names the session.
func recordStaging(t *testing.T, dest string) func() []stageCall {
	t.Helper()
	var mu sync.Mutex
	var calls []stageCall
	old := logoffStageInbox
	logoffStageInbox = func(base, name, pass, uid string, se []byte) {
		n, _, _ := readRoamSession(dest)
		mu.Lock()
		calls = append(calls, stageCall{base, name, pass, uid, se, n != ""})
		mu.Unlock()
	}
	t.Cleanup(func() { logoffStageInbox = old })
	return func() []stageCall {
		mu.Lock()
		defer mu.Unlock()
		return append([]stageCall(nil), calls...)
	}
}

// rearmSession seats the stored session with a hardened secret, so the captured secret is observable.
func rearmSession(t *testing.T, uid string) string {
	t.Helper()
	dest := cutoffSession(t, uid)
	if err := markRoamSession(dest, "alice", "correct horse", uid, rearmSecretHex); err != nil {
		t.Fatal(err)
	}
	return dest
}

func shortStall(t *testing.T, limit time.Duration) {
	t.Helper()
	lim, hc, tick := logoffStallLimit, logoffStallHardCap, logoffStallTick
	logoffStallLimit, logoffStallHardCap, logoffStallTick = limit, time.Hour, 50*time.Millisecond
	t.Cleanup(func() { logoffStallLimit, logoffStallHardCap, logoffStallTick = lim, hc, tick })
}

// rearmNoSync stubs logoffSync for the test: a real sync(2) waits on the whole host's I/O.
func rearmNoSync(t *testing.T) {
	t.Helper()
	sy := logoffSync
	logoffSync = func() {}
	t.Cleanup(func() { logoffSync = sy })
}

// unstuckInsideOut, called once the test has seen staging call 1, fails unless an `out` was already handed over. It
// needs no wait: cutoffWorkerGated records an op (seen = append(seen, op)) when it hands it over, and its beat, which
// keeps roam.progress fresh so the stall cannot fire, stops only after that (calls[beatUntil] > 0). So the stall arm's
// staging call comes after `out` is in ops(), unless A was un-stuck while the beat still ran (NWP-20261123-16).
func unstuckInsideOut(t *testing.T, ops func() []string) {
	t.Helper()
	got := ops()
	for _, o := range got {
		if o == "out" {
			return
		}
	}
	t.Fatalf("A was un-stuck before its out was handed over; roamd was handed %v", got)
}

func wantOneStaging(t *testing.T, what string, got []stageCall, uid string) {
	t.Helper()
	if len(got) != 1 {
		t.Fatalf("%s: %d staging calls, want exactly 1: %+v", what, len(got), got)
	}
	c := got[0]
	if c.base != "s3" || c.name != "alice" || c.uid != uid {
		t.Errorf("%s: staged for (%q, %q, uid %q), want (s3, alice, %s)", what, c.base, c.name, c.uid, uid)
	}
	if !c.markerPresent {
		t.Errorf("%s: staged before the re-arm wrote the marker back", what)
	}
	if !bytes.Equal(c.se, seFromHex(rearmSecretHex)) {
		t.Errorf("%s: staged with secret %x, want the captured %s", what, c.se, rearmSecretHex)
	}
}

func rearmAnswers(over map[string]string) map[string]string {
	a := map[string]string{"cutoff": "OK 3", "sweepmedia": "OK", "out": "OK", "cutoffwake": "WAKE OK 3"}
	for k, v := range over {
		a[k] = v
	}
	return a
}

func TestLogoffRearmInbox_AFailedSealStagesTheInbox(t *testing.T) {
	const uid = "81"
	dest := rearmSession(t, uid)
	calls := recordStaging(t, dest)
	rearmNoSync(t)
	cutoffWorker(t, dest, rearmAnswers(map[string]string{"out": "ERR-PUSH 1"}), nil)
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	logoffDone(t, uid, rearmHang)
	wantOneStaging(t, "failed seal", calls(), uid)
}

func TestLogoffRearmInbox_AFailedMediaSweepStagesTheInbox(t *testing.T) {
	const uid = "82"
	dest := rearmSession(t, uid)
	t.Cleanup(resetMediaStuck)
	calls := recordStaging(t, dest)
	rearmNoSync(t)
	cutoffWorker(t, dest, rearmAnswers(map[string]string{"sweepmedia": "ERR-MEDIA-SWEEP 1"}), nil)
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	logoffDone(t, uid, rearmHang)
	wantOneStaging(t, "failed media sweep", calls(), uid)
}

// The beat keeps A's watchdog clock fresh through its cutoff and sweep and its `out` is gated, so the stall fires
// inside the seal (unstuckInsideOut) and un-sticks it with one staging call. The gate then lets the late OK land: the
// late-verdict arm, which stages nothing, as the marker has been up since the unstick.
func TestLogoffRearmInbox_AStalledSealStagesOnceAndALateVerdictDoesNot(t *testing.T) {
	tr := trackGoSafe(t)
	const uid = "83"
	var dest string
	stateDirMustStayGone(t, func() string { return filepath.Dir(dest) })
	dest = rearmSession(t, uid)
	calls := recordStaging(t, dest)
	rearmNoSync(t)
	shortStall(t, 2500*time.Millisecond)
	gate := map[string]chan struct{}{"out#1": make(chan struct{})}
	ops := cutoffWorkerGated(t, dest, rearmAnswers(nil), nil, gate, "out")
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	deadline := time.Now().Add(rearmHang)
	for len(calls()) == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("the watchdog's unstick never staged the inbox; roamd was handed %v", ops())
		}
		time.Sleep(20 * time.Millisecond)
	}
	unstuckInsideOut(t, ops)
	close(gate["out#1"]) // the late OK: the late verdict
	logoffDone(t, uid, rearmHang)
	wantOneStaging(t, "stalled seal", calls(), uid)
	tr.wait(t, rearmHang)
}

func TestLogoffRearmInbox_ALandedSealStagesNothing(t *testing.T) {
	const uid = "84"
	rearmNoSync(t)
	calls := make(chan func() []stageCall, 1)
	landedLogoffIn(t, uid, "OK 3", func(dest string) {
		if err := markRoamSession(dest, "alice", "correct horse", uid, rearmSecretHex); err != nil {
			t.Fatal(err)
		}
		calls <- recordStaging(t, dest)
	})
	if got := (<-calls)(); len(got) != 0 {
		t.Fatalf("a landed seal staged the inbox: %+v", got)
	}
}

// Logoff A stalls inside its gated `out` and is un-stuck (its arm stages); a retry B supersedes it; the gate then
// opens, so A's ERR-PUSH 1 lands after B claimed and A takes its superseded return. A's late failure and B's success
// stage nothing, so the whole run makes exactly one call, and B's `out` is the second one handed over.
func TestLogoffRearmInbox_ASupersededLogoffStagesNothing(t *testing.T) {
	tr := trackGoSafe(t)
	const uid = "85"
	var dest string
	stateDirMustStayGone(t, func() string { return filepath.Dir(dest) })
	dest = rearmSession(t, uid)
	t.Cleanup(func() { endCutoffHold(uid) })
	calls := recordStaging(t, dest)
	rearmNoSync(t)
	shortStall(t, 2500*time.Millisecond)
	gate := map[string]chan struct{}{"out#1": make(chan struct{})}
	ops := cutoffWorkerGated(t, dest, rearmAnswers(map[string]string{"out": "ERR-PUSH 1||OK"}), nil, gate, "out")
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) }) // A
	deadline := time.Now().Add(rearmHang)
	for len(calls()) == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("A's stall arm never staged; roamd was handed %v", ops())
		}
		time.Sleep(20 * time.Millisecond)
	}
	unstuckInsideOut(t, ops)
	logoffStallLimit = time.Hour // B's own watchdog stays quiet, as in production
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("the retry's LOGOUT replied %q", got)
	}
	close(gate["out#1"]) // A's verdict lands after B claimed
	deadline = time.Now().Add(rearmHang)
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
	if want := []string{"cutoff", "sweepmedia", "out", "cutoff", "sweepmedia", "out"}; !sameOps(ops(), want) {
		t.Fatalf("roamd was handed %v once the retry's reap was queued, want %v", ops(), want)
	}
	ackReapAction("SWITCH", uid)
	ackReapAction("REAP", uid)
	logoffDone(t, uid, rearmHang)
	tr.wait(t, rearmHang)
	wantOneStaging(t, "superseded logoff", calls(), uid)
}

// The real helper against an unreachable store: no panic, the sealed copy stays.
func TestLogoffRearmInbox_ADeadStoreIsPanicFree(t *testing.T) {
	_, ref, _ := rbInboxStore(t, "rrdead", "horse battery staple correct", false)
	stageTelInboxForLiveSession("http://127.0.0.1:1", "rrdead", "horse battery staple correct", rbInboxUID, nil)
	if len(listSealed(ref)) != 1 {
		t.Error("the sealed copy must stay when the store cannot be reached")
	}
}

// The re-arm writes the captured secret back into the marker, so a call reading seFromSession(dest) after it passes
// every behavioural case: the wiring is pinned in the source.
func TestLogoffRearmInbox_TheWiringIsPinned(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "handleLogout"))
	const call = `logoffStageInbox("s3", name, pass, uid, seFromHex(seSecret))`
	var calls []int
	for i, l := range body {
		if strings.Contains(l, "seFromSession(") {
			t.Errorf("handleLogout reads seFromSession(: %s", strings.TrimSpace(l))
		}
		if strings.Contains(l, "logoffStageInbox(") {
			calls = append(calls, i)
			if s := strings.TrimSpace(l); s != call {
				t.Errorf("staging statement is %q, want %q", s, call)
			}
		}
	}
	if len(calls) != 3 {
		t.Fatalf("handleLogout has %d logoffStageInbox( statements, want 3", len(calls))
	}
	for _, reason := range []string{"logout seal stalled", "logout media sweep did not verify", "logout seal failed"} {
		rearm := -1
		for i, l := range body {
			if strings.HasPrefix(strings.TrimSpace(l), "rearmRoamSession(") && strings.Contains(l, `"`+reason) {
				rearm = i
			}
		}
		if rearm < 0 {
			t.Fatalf("no re-arm for %q -- this test is stale, not the code", reason)
		}
		ret := -1
		for i := rearm + 1; i < len(body); i++ {
			if strings.TrimSpace(body[i]) == "return" {
				ret = i
				break
			}
		}
		n := 0
		for _, c := range calls {
			if c > rearm && c < ret {
				n++
			}
		}
		if n != 1 {
			t.Errorf("%d staging call(s) between the %q re-arm and its return, want 1", n, reason)
		}
	}
}
