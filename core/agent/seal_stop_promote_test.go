package main

// h59 #1 (NWP-20261129-23; docs/product-decisions.md, 2026-11-05): a sign-out tapped while a promote seal is running
// stops that seal at its next safe point, as h49 #13 does for Back up now, so a sign-out saves once. LOGOUT raises the
// stop over a "promote" announce and seals as plain "logoff"; a promote still queued for the RW slot answers
// SKIP-STOPPED there and leaves the request for the sign-out's own out op; a stopped promote records nothing. The seams
// are package vars: no test here runs in parallel.

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// psThrowaway seats a throwaway session for uid in dest, under a profile name of its own (the caches key on it).
func psThrowaway(t *testing.T, dest, uid string) {
	t.Helper()
	if err := markRoamSession(dest, "promotestop"+uid, ropPass, uid, ""); err != nil {
		t.Fatal(err)
	}
	markLocalSession(dest)
}

// psPromote runs "Save to your store" through PROMOTE2 (same passphrase, so no re-key) and waits for the background
// seal's "promote" announce. The seal is then queued for the RW slot or holding it, as the test's fake init decides.
func psPromote(t *testing.T, dest string) {
	t.Helper()
	if got := ropReply(t, func(c net.Conn) { handlePromote2(c, dest, ropPass) }); !strings.HasPrefix(got, "OK RECOVERY ") {
		t.Fatalf("PROMOTE2 replied %q, want OK RECOVERY <words>", got)
	}
	smWait(t, "the promote seal's announce", func() bool {
		pendingReapMu.Lock()
		defer pendingReapMu.Unlock()
		return sealRunKind == "promote"
	})
}

// psHoldSlot makes the test the RW op that holds the slot, and returns the function that frees it.
func psHoldSlot(t *testing.T) func() {
	t.Helper()
	var once sync.Once
	laneRW.slot <- struct{}{}
	free := func() { once.Do(func() { <-laneRW.slot }) }
	t.Cleanup(free)
	return free
}

// psGateSync holds a sign-out at its flush until the returned function runs, so the promote seal ends first.
func psGateSync(t *testing.T) func() {
	t.Helper()
	var once sync.Once
	gate := make(chan struct{})
	open := func() { once.Do(func() { close(gate) }) }
	prev := logoffSync
	logoffSync = func() { <-gate }
	t.Cleanup(func() { open(); logoffSync = prev })
	return open
}

// psOutKinds returns line 6 of every out request roamd really read.
func psOutKinds(f *abInit, kinds func() [][2]string) []string {
	ks := []string{}
	got := kinds()
	for i, s := range f.snapshot() {
		if !s.ignored && s.reqOp == "out" {
			ks = append(ks, got[i][1])
		}
	}
	return ks
}

// psStamps is every landed-seal counter a seal's verdict can move.
type psStamps struct{ landed, save, bytes, areas, start int64 }

func psReadStamps() psStamps {
	return psStamps{sealLandedSeq.Load(), lastSaveSeq.Load(), lastSaveBytes.Load(), lastSaveAreas.Load(), lastLandedSealStartedAt.Load()}
}

// psRestoreStamps puts the counters back after the test, for a run in which the code under test moved them.
func psRestoreStamps(t *testing.T) {
	t.Helper()
	prev := psReadStamps()
	t.Cleanup(func() {
		sealLandedSeq.Store(prev.landed)
		lastSaveSeq.Store(prev.save)
		lastSaveBytes.Store(prev.bytes)
		lastSaveAreas.Store(prev.areas)
		lastLandedSealStartedAt.Store(prev.start)
	})
}

// P1: LOGOUT over a "promote" announce raises the request, logs it, and seals as "logoff": only a replaced Back up now
// pins.
func TestPromoteStop_LogoutRaisesAndSealsAsLogoff(t *testing.T) {
	const uid = "341"
	cutoffSession(t, uid) // its resets only; the session is seated in the fake init's dir below
	ssdShortReap(t)
	resetAbandoned(t, nil)
	f := abFakeInit(t, []abPlan{{laneRW, "OK 0", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}})
	seen := ssdStopSeen(t, f.dest)
	kinds := smReqKinds(t, f.dest)
	log := captureStderrLive(t)
	if err := markRoamSession(f.dest, "promotestop"+uid, ropPass, uid, ""); err != nil {
		t.Fatal(err)
	}
	pendingReapMu.Lock()
	sealRunKind = "promote"
	pendingReapMu.Unlock()
	if got := ropReply(t, func(conn net.Conn) { handleLogout(conn, f.dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	ssdWaitReap(t, uid)
	starts, at, ks := f.snapshot(), seen(), kinds()
	cutoffSeen, outKind := false, ""
	for j, s := range starts {
		if s.ignored {
			continue
		}
		switch s.reqOp {
		case "cutoff":
			cutoffSeen = at[j]
		case "out":
			outKind = ks[j][1]
		}
	}
	if !cutoffSeen {
		t.Error("the stop request was absent at the cutoff: a promote seal was not asked to stop (h59 #1)")
	}
	if text := log.String(); !strings.Contains(text, "asked the running promote seal to stop") || !strings.Contains(text, "(h59 #1)") {
		t.Errorf("the log does not name the raise over a promote seal; it holds:\n%s", text)
	}
	if outKind != "logoff" {
		t.Errorf("the sign-out's out request carried kind %q on line 6, want logoff (a replaced promote does not pin)", outKind)
	}
	if ssdPresent(f.dest) {
		t.Error("the stop request outlived the sign-out's seal")
	}
}

// P2: a promote still queued for the slot when a sign-out takes its announce answers SKIP-STOPPED, writes no request,
// clears none of the sign-out's bridges and leaves the stop request. The sign-out's own out op then drops it and runs.
func TestPromoteStop_QueuedPromoteSkipsAtTheSlot(t *testing.T) {
	skipVerdictSetup(t)
	f := smAtSlot(t, "logoff")
	ssdRaise(t, f.dest)
	stashCreditReason("the sign-out's reason")
	if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "", "", "promote", nil); out != "SKIP-STOPPED" {
		t.Fatalf("a queued promote under a sign-out's announce answered %q, want SKIP-STOPPED (h59 #1)", out)
	}
	if starts := f.snapshot(); len(starts) != 0 {
		t.Errorf("the skipped promote started roamd: %+v", starts)
	}
	if _, err := os.Stat(filepath.Join(f.dest, laneRW.req)); !os.IsNotExist(err) {
		t.Errorf("the skipped promote left a request file (stat err %v)", err)
	}
	if !ssdPresent(f.dest) {
		t.Fatal("the skipped promote dropped the sign-out's stop request")
	}
	if got := takeCreditReason(); got != "the sign-out's reason" {
		t.Errorf("the skipped promote cleared the credit-reason stash: %q", got)
	}
	if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "logoff", "", "", nil); out != "OK" {
		t.Fatalf("the sign-out's own out op answered %q, want OK", out)
	}
	smOneOut(t, f.snapshot())
	if ssdPresent(f.dest) {
		t.Error("the stop request outlived the sign-out's own out op")
	}
}

// P3 (a control; it passes on the code before h59 #1): a promote under its own announce writes its request and runs.
func TestPromoteStop_RunsUnderItsOwnAnnounce(t *testing.T) {
	f := smAtSlot(t, "promote")
	if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "", "", "promote", nil); out != "OK" {
		t.Fatalf("a promote under its own announce answered %q, want OK", out)
	}
	smOneOut(t, f.snapshot())
}

// P4: promoteToStore's goroutine passes its intent. The at-slot check cannot see a promote seal without it.
func TestPromoteStop_GoroutinePassesItsIntent(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `goSafe("promote-seal"`)
	if i < 0 {
		t.Fatal("promoteToStore's goroutine was not found")
	}
	body, _, ok := strings.Cut(src[i:], "\n\t})")
	if !ok {
		t.Fatal("the end of promoteToStore's goroutine was not found")
	}
	if !strings.Contains(body, `readRoamSessionSE(dest), "", "", "promote", nil)`) {
		t.Errorf("promoteToStore's goroutine does not pass intent \"promote\":\n%s", body)
	}
}

// P5: the real goroutine, queued behind a held slot when a sign-out takes its announce: it records no seal verdict,
// moves no landed-seal stamp, starts nothing and leaves the sign-out's announce.
func TestPromoteStop_StoppedPromoteRecordsNothing(t *testing.T) {
	tr := trackGoSafe(t)
	skipVerdictSetup(t)
	ropStore(t)
	ropReapReset(t)
	resetAbandoned(t, nil)
	psRestoreStamps(t)
	f := abFakeInit(t, []abPlan{{laneRW, "OK", nil}})
	psThrowaway(t, f.dest, "342")
	free := psHoldSlot(t)
	psPromote(t, f.dest)
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealRunKind, sealPartial = "", ""
		pendingReapMu.Unlock()
	})
	pendingReapMu.Lock()
	sealRunKind, sealPartial = "logoff", "apps=refused"
	pendingReapMu.Unlock()
	sealMu.Lock()
	prevStatus := sealStatus
	sealMu.Unlock()
	before := psReadStamps()
	free()
	tr.wait(t, 60*time.Second)
	pendingReapMu.Lock()
	kind, partial, failed := sealRunKind, sealPartial, sealFail
	pendingReapMu.Unlock()
	sealMu.Lock()
	status := sealStatus
	sealMu.Unlock()
	if partial != "apps=refused" || failed {
		t.Errorf("after a stopped promote: sealPartial=%q sealFail=%v, want the sign-out's apps=refused and false", partial, failed)
	}
	if status != prevStatus {
		t.Errorf("a stopped promote recorded the verdict %q over %q", status, prevStatus)
	}
	if after := psReadStamps(); after != before {
		t.Errorf("a stopped promote moved a landed-seal stamp: %+v -> %+v", before, after)
	}
	if starts := f.snapshot(); len(starts) != 0 {
		t.Errorf("a stopped promote started roamd: %+v", starts)
	}
	if kind != "logoff" {
		t.Errorf("the stopped promote's end left the announce %q, want the sign-out's logoff", kind)
	}
}

// psSignOutSetup is P6's shared setup: a throwaway of its own for uid, against a fake init that answers plan, with a
// sign-out that holds at its flush until the test opens it.
func psSignOutSetup(t *testing.T, uid string, plan []abPlan) (tr *goSafeTracker, f *abInit, kinds func() [][2]string, open func()) {
	t.Helper()
	tr = trackGoSafe(t)
	skipVerdictSetup(t)
	ropStore(t)
	cutoffSession(t, uid) // its resets only; the session is seated in the fake init's dir below
	ssdShortReap(t)
	resetAbandoned(t, nil)
	psRestoreStamps(t)
	f = abFakeInit(t, plan)
	kinds = smReqKinds(t, f.dest)
	psThrowaway(t, f.dest, uid)
	return tr, f, kinds, psGateSync(t)
}

// psLogout runs LOGOUT with billing not configured (maybePayRent), as the manual tests do.
func psLogout(t *testing.T, dest string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	if got := ropReply(t, func(conn net.Conn) { handleLogout(conn, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
}

// P6, the failure scenario end to end: "Save to your store" and then Log off write one sign-out seal, not two whole
// seals. The test holds the slot or the promote's worker, and holds the sign-out at its flush, so the order is forced
// by the test, never by the scheduler.
func TestPromoteStop_SignOutSavesOnce(t *testing.T) {
	// cutoff, sweepmedia and out for the sign-out; one spare so the pre-fix code's extra out also gets an answer.
	t.Run("queued", func(t *testing.T) {
		const uid = "343"
		tr, f, kinds, open := psSignOutSetup(t, uid, []abPlan{{laneRW, "OK 0", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}})
		free := psHoldSlot(t)
		psPromote(t, f.dest)
		psLogout(t, f.dest)
		free()
		smWait(t, "the queued promote seal to end", func() bool { return tr.count("promote-seal") == 0 })
		if ks := psOutKinds(f, kinds); len(ks) != 0 {
			t.Errorf("the queued promote wrote out request(s) %q under a sign-out -- it must skip (h59 #1)", ks)
		}
		if !ssdPresent(f.dest) {
			t.Error("the queued promote dropped the sign-out's stop request, or the sign-out raised none")
		}
		open()
		ssdWaitReap(t, uid)
		if ks := psOutKinds(f, kinds); len(ks) != 1 || ks[0] != "logoff" {
			t.Errorf("out requests written = %q, want exactly one, logoff", ks)
		}
		if ssdPresent(f.dest) {
			t.Error("the stop request outlived the sign-out's seal")
		}
	})
	t.Run("running", func(t *testing.T) {
		const uid = "344"
		rel := make(chan struct{})
		tr, f, kinds, open := psSignOutSetup(t, uid, []abPlan{{laneRW, "SKIP-STOPPED", rel}, {laneRW, "OK 0", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}})
		psPromote(t, f.dest)
		smWait(t, "the promote seal's out op to start", func() bool { return len(psOutKinds(f, kinds)) == 1 })
		psLogout(t, f.dest)
		if !ssdPresent(f.dest) {
			t.Error("LOGOUT did not ask the running promote seal to stop (h59 #1)")
		}
		// The sign-out holds at its flush until the stopped promote has ended: what the promote left is its own doing.
		pendingReapMu.Lock()
		sealPartial = "apps=refused"
		pendingReapMu.Unlock()
		before := psReadStamps()
		close(rel)
		smWait(t, "the stopped promote seal to end", func() bool { return tr.count("promote-seal") == 0 })
		pendingReapMu.Lock()
		partial, runKind := sealPartial, sealRunKind
		pendingReapMu.Unlock()
		if partial != "apps=refused" {
			t.Errorf("the stopped promote overwrote the sign-out's sealPartial with %q", partial)
		}
		if after := psReadStamps(); after != before {
			t.Errorf("the stopped promote moved a landed-seal stamp: %+v -> %+v", before, after)
		}
		if runKind != "logoff" {
			t.Errorf("the stopped promote's end left the announce %q, want the sign-out's logoff", runKind)
		}
		open()
		ssdWaitReap(t, uid)
		if ks := psOutKinds(f, kinds); len(ks) != 2 || ks[0] != "" || ks[1] != "logoff" {
			t.Errorf("out requests written = %q, want the promote's stopped one (kind empty), then logoff", ks)
		}
		if ssdPresent(f.dest) {
			t.Error("the stop request outlived the sign-out's seal")
		}
	})
}
