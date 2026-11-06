package main

// h47 #1 option A, part 2 (NWP-20261117-04; docs/product-decisions.md, 2026-10-28): the login daemon's side of the
// stop request. LOGOUT raises $NOWHERE_STATE/.sealstop only when the announce it replaces is a periodic seal (or,
// since h49 #13, NWP-20261119-03, a manual one: seal_stop_manual_test.go);
// runWorkerHeld drops it under the slot immediately before an out op's request is written, after every guard, so an
// out op that is skipped or answered busy leaves it; a SKIP-STOPPED periodic records no verdict. The push side
// (part 1) has its own tests in seal_stop_test.go. The seams are package vars: none of these tests may run in parallel.

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// ssdStopSeen wraps workerStart (installed by abFakeInit) and records, per call, whether the stop request was present
// in dest when the start was made. Entry i matches f.snapshot()[i]: every call appends exactly one start.
func ssdStopSeen(t *testing.T, dest string) func() []bool {
	t.Helper()
	var mu sync.Mutex
	var seen []bool
	prev := workerStart
	workerStart = func(svc string) {
		mu.Lock()
		defer mu.Unlock()
		_, err := os.Stat(filepath.Join(dest, sealStopFile))
		seen = append(seen, err == nil)
		prev(svc)
	}
	t.Cleanup(func() { workerStart = prev })
	return func() []bool {
		mu.Lock()
		defer mu.Unlock()
		return append([]bool(nil), seen...)
	}
}

// ssdRaise creates the stop request in dest, as a sign-out would.
func ssdRaise(t *testing.T, dest string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, sealStopFile), nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func ssdPresent(dest string) bool {
	_, err := os.Stat(filepath.Join(dest, sealStopFile))
	return err == nil
}

// ssdShortReap shortens reapOrReboot's two waits (8 s and 12 s) to 1 s each, so a sign-out ends soon after
// ssdWaitReap acknowledges its reap phases (it does so within one 10 ms poll of the queue).
func ssdShortReap(t *testing.T) {
	t.Helper()
	sw, rw := reapSwitchWait, reapRemoveWait
	reapSwitchWait, reapRemoveWait = time.Second, time.Second
	t.Cleanup(func() { reapSwitchWait, reapRemoveWait = sw, rw })
}

// ssdWaitReap waits for the sign-out of uid to queue its reap, then acknowledges both reap phases as the user-0
// watcher would, and waits for the logoff goroutine to end. Every bound is a hang guard.
func ssdWaitReap(t *testing.T, uid string) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for {
		pendingReapMu.Lock()
		reap := pendingReapUID
		pendingReapMu.Unlock()
		if reap == uid {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the sign-out of user %s never queued its reap within 15s (hang guard)", uid)
		}
		time.Sleep(10 * time.Millisecond)
	}
	ackReapAction("SWITCH", uid)
	ackReapAction("REAP", uid)
	logoffDone(t, uid, 15*time.Second)
}

// LOGOUT raises the request over a periodic or (h49 #13, NWP-20261119-03) a manual announce: no seal is not asked.
func TestSealStopDaemon_LogoutRaisesOverAPeriodicOrAManual(t *testing.T) {
	for i, c := range []struct {
		kind string
		want bool
	}{{"periodic", true}, {"manual", true}, {"", false}} {
		name := c.kind
		if name == "" {
			name = "none"
		}
		t.Run(name, func(t *testing.T) {
			uid := fmt.Sprint(281 + i)
			dest := cutoffSession(t, uid)
			ssdShortReap(t)
			pendingReapMu.Lock()
			sealRunKind = c.kind
			pendingReapMu.Unlock()
			gate := make(chan struct{})
			// The cutoff is held, so the logoff's own out op cannot drop the request before the check below.
			cutoffWorkerGated(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": "OK"}, nil,
				map[string]chan struct{}{"cutoff#1": gate}, "")
			if got := ropReply(t, func(conn net.Conn) { handleLogout(conn, dest) }); got != "OK" {
				t.Fatalf("LOGOUT replied %q", got)
			}
			if got := ssdPresent(dest); got != c.want {
				t.Errorf("announce %q: stop request present = %v after LOGOUT, want %v", c.kind, got, c.want)
			}
			close(gate)
			ssdWaitReap(t, uid)
		})
	}
}

// An out op that runs drops the request before roamd is started on its request: a stale one never stops it.
func TestSealStopDaemon_OutDropsTheRequestBeforeItsRequest(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK"}})
	seen := ssdStopSeen(t, f.dest)
	ssdRaise(t, f.dest)
	if out := abRun(t, f, "out"); out != "OK" {
		t.Fatalf("out answered %q, want OK", out)
	}
	starts, at := f.snapshot(), seen()
	if len(starts) != 1 || starts[0].ignored || starts[0].reqOp != "out" {
		t.Fatalf("starts = %+v, want one honoured start of out", starts)
	}
	if at[0] {
		t.Error("the stop request was still present when the out op's roamd started -- a stale request stops the sign-out's own seal")
	}
	if ssdPresent(f.dest) {
		t.Error("the stop request is present after the out op ran")
	}
}

// A periodic skipped as superseded, and an out op skipped for a queued reap, run nothing and leave the request.
func TestSealStopDaemon_ASkippedOutLeavesTheRequest(t *testing.T) {
	for _, c := range []struct {
		name, intent, want string
		setup              func()
	}{
		{"superseded", "periodic", "SKIP-SUPERSEDED", func() { sealRunKind = "logoff" }},
		{"reaping", "", "SKIP-REAPING", func() { pendingReapUID = "10" }},
	} {
		t.Run(c.name, func(t *testing.T) {
			resetAbandoned(t, nil)
			pendingReapMu.Lock()
			prevKind, prevReap := sealRunKind, pendingReapUID
			c.setup()
			pendingReapMu.Unlock()
			prevDefer := sealDeferCount.Load()
			t.Cleanup(func() {
				pendingReapMu.Lock()
				sealRunKind, pendingReapUID = prevKind, prevReap
				pendingReapMu.Unlock()
				sealDeferCount.Store(prevDefer)
			})
			f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK"}})
			ssdStopSeen(t, f.dest)
			ssdRaise(t, f.dest)
			if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "", "", c.intent, nil); out != c.want {
				t.Fatalf("out answered %q, want %q", out, c.want)
			}
			if starts := f.snapshot(); len(starts) != 0 {
				t.Errorf("a skipped out op started roamd: %+v", starts)
			}
			if !ssdPresent(f.dest) {
				t.Error("a skipped out op removed the stop request")
			}
		})
	}
}

// An out op answered busy behind an abandoned one leaves the request, so the abandoned push still running stops at its
// next boundary; the next out op that runs drops it.
func TestSealStopDaemon_BusyBehindAnAbandonedOutLeavesTheRequest(t *testing.T) {
	resetAbandoned(t, nil)
	rel := make(chan struct{})
	f := abFakeInit(t, []abPlan{{laneRW, "OK", rel}, {laneRW, "OK", nil}})
	seen := ssdStopSeen(t, f.dest)
	abAbandon(t, f, "out")
	ssdRaise(t, f.dest) // after the abandoned op's own drop
	if out := abRun(t, f, "out"); out != workerBusy {
		t.Fatalf("out behind an abandoned one answered %q, want %q", out, workerBusy)
	}
	if !ssdPresent(f.dest) {
		t.Fatal("an out op answered busy removed the stop request -- the abandoned push runs on while the sign-out is refused")
	}
	close(rel)
	f.waitStopped(t, laneRW.svc)
	if out := abRun(t, f, "out"); out != "OK" {
		t.Fatalf("out after the abandoned one stopped answered %q, want OK", out)
	}
	starts, at := f.snapshot(), seen()
	last := len(starts) - 1
	if last < 1 || starts[last].ignored || starts[last].reqOp != "out" {
		t.Fatalf("starts = %+v, want a last honoured start of out", starts)
	}
	if at[last] {
		t.Error("the stop request was present when the next out op's roamd started")
	}
}

// A periodic stopped by a sign-out ran no whole seal: it leaves the verdict, its parts and the reason as they were.
func TestSealStopDaemon_StoppedPeriodicRecordsNoVerdict(t *testing.T) {
	t.Run("nocredit", func(t *testing.T) {
		skipVerdictSetup(t)
		stashCreditReason("free quota exceeded")
		recordSeal("ERR-NOCREDIT PARTIAL:apps=refused")
		recordSeal("SKIP-STOPPED")
		if got := sealStatusGet(); got != "nocredit" {
			t.Errorf("status = %q, want nocredit", got)
		}
		if got := sealPartsGet(); got != "apps=refused" {
			t.Errorf("parts = %q, want apps=refused", got)
		}
		if got := sealReasonGet(); got != "free quota exceeded" {
			t.Errorf("reason = %q, want the stashed text", got)
		}
	})
	t.Run("ok", func(t *testing.T) {
		skipVerdictSetup(t)
		recordSeal("OK")
		recordSeal("SKIP-STOPPED")
		if got := sealStatusGet(); got != "ok" {
			t.Errorf("status = %q, want ok", got)
		}
	})
}

// End to end: a periodic seal holds the RW slot, its stand-in roamd works until the stop request appears and then
// answers SKIP-STOPPED; a LOGOUT meanwhile raises the request. The periodic records no verdict, the sign-out's out
// request is written once and only after the request is gone, and the sign-out's seal is the one that lands.
func TestSealStopDaemon_LogoutStopsARunningPeriodicAndSealsOnce(t *testing.T) {
	const uid = "291"
	cutoffSession(t, uid) // its resets only; the session is seated in the fake init's dir below
	ssdShortReap(t)
	skipVerdictSetup(t)
	resetAbandoned(t, nil)
	rel := make(chan struct{})
	f := abFakeInit(t, []abPlan{{laneRW, "SKIP-STOPPED", rel}, {laneRW, "OK 0", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}})
	seen := ssdStopSeen(t, f.dest)
	const name, pass = "sealstopd291", "sealstopd291 pass"
	if err := markRoamSession(f.dest, name, pass, uid, ""); err != nil {
		t.Fatal(err)
	}
	recordSeal("OK") // the last real verdict (after markRoamSession, which resets it); a stopped periodic must leave it

	// The feeder keeps the periodic alive: runWorkerHeld resets its stall count only on a new non-empty progress line,
	// and abFakeInit's 1 ms tick makes the budget about 0.3 s. It stops for good when it sees the request, then lets
	// the stand-in answer. Its only bound is the 10 s hang guard; on that it does NOT release the stand-in.
	prog := filepath.Join(f.dest, laneRW.prog)
	stop := filepath.Join(f.dest, sealStopFile)
	quit := make(chan struct{})
	fed := make(chan struct{})
	go func() {
		defer close(fed)
		guard := time.After(10 * time.Second)
		for n := 1; ; n++ {
			if _, err := os.Stat(stop); err == nil {
				close(rel)
				return
			}
			os.WriteFile(prog, []byte(fmt.Sprintf("seal %d\n", n)), 0o600)
			select {
			case <-guard:
				t.Errorf("LOGOUT raised no stop request within 10s (hang guard)")
				return
			case <-quit:
				return
			case <-f.done:
				return
			case <-time.After(2 * time.Millisecond):
			}
		}
	}()
	t.Cleanup(func() { close(quit); <-fed })

	periodic := make(chan string, 1)
	go func() {
		if !announcePeriodicSeal() {
			periodic <- "NOT-ANNOUNCED"
			return
		}
		out := triggerRoamWorkerKind(f.dest, "out", name, pass, uid, "", "", "", "periodic", nil)
		if out != "SKIP-REAPING" {
			clearSealRunIf("periodic")
			recordSeal(out)
		}
		periodic <- out
	}()
	deadline := time.Now().Add(10 * time.Second)
	for len(f.snapshot()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the periodic's out op never started within 10s (hang guard)")
		}
		time.Sleep(time.Millisecond)
	}

	if got := ropReply(t, func(conn net.Conn) { handleLogout(conn, f.dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	select {
	case out := <-periodic:
		if out != "SKIP-STOPPED" {
			t.Errorf("periodic answered %q, want SKIP-STOPPED", out)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("the periodic did not return within 15s (hang guard)")
	}
	ssdWaitReap(t, uid)

	starts, at := f.snapshot(), seen()
	var ops []string
	var outAt []bool
	for i, s := range starts {
		if s.ignored {
			continue
		}
		ops = append(ops, s.reqOp)
		outAt = append(outAt, at[i])
	}
	if want := []string{"out", "cutoff", "sweepmedia", "out"}; !sameOps(ops, want) {
		t.Fatalf("roamd was handed %v, want %v -- the sign-out's out written once, after the periodic", ops, want)
	}
	if !outAt[1] {
		t.Error("the stop request was absent at the sign-out's cutoff -- LOGOUT did not raise it, or something dropped it early")
	}
	if outAt[3] {
		t.Error("the stop request was still present when the sign-out's own out op started")
	}
	if ssdPresent(f.dest) {
		t.Error("the stop request outlived the sign-out's seal")
	}
	// A sign-out whose seal lands records no recordSeal verdict (the session ends): its verdict is the queued reap above
	// and a cleared FAILED flag. The verdict before it must survive the stopped periodic untouched.
	if got := sealStatusGet(); got != "ok" {
		t.Errorf("recorded verdict = %q after the stopped periodic, want the earlier ok left as it was", got)
	}
	pendingReapMu.Lock()
	failed, kind := sealFail, sealRunKind
	pendingReapMu.Unlock()
	if failed || kind != "" {
		t.Errorf("after the sign-out landed: sealFail = %v, sealRunKind = %q; want false and empty", failed, kind)
	}
}
