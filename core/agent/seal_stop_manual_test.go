package main

// h49 #13 (NWP-20261119-03; docs/product-decisions.md, 2026-10-31): a sign-out tapped during "Back up now" stops that
// save at its next safe point, saves once, and pins the sign-out's save. LOGOUT raises the stop over a "manual"
// announce and runs its out op as "logoff-pinned"; a stopped Back up now records nothing; the manual's end leaves a
// sign-out's announce alone; sealKind() pins "logoff-pinned". The seams are package vars: no test here runs in
// parallel.

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// smReqKinds wraps workerStart (after abFakeInit and ssdStopSeen) and records, per start, the request's op (line 1)
// and kind (line 6). It reads the request BEFORE the stand-in removes it.
func smReqKinds(t *testing.T, dest string) func() [][2]string {
	t.Helper()
	var mu sync.Mutex
	var got [][2]string
	prev := workerStart
	workerStart = func(svc string) {
		var rec [2]string
		if b, err := os.ReadFile(filepath.Join(dest, laneRW.req)); err == nil {
			lines := strings.Split(string(b), "\n")
			rec[0] = lines[0]
			if len(lines) > 5 {
				rec[1] = lines[5]
			}
		}
		mu.Lock()
		got = append(got, rec)
		mu.Unlock()
		prev(svc)
	}
	t.Cleanup(func() { workerStart = prev })
	return func() [][2]string {
		mu.Lock()
		defer mu.Unlock()
		return append([][2]string(nil), got...)
	}
}

// T1: the announce LOGOUT replaces decides both the stop and the out op's kind.
func TestManualStop_LogoutKindAndRaise(t *testing.T) {
	for i, c := range []struct {
		kind, line6 string
		stop        bool
	}{{"manual", "logoff-pinned", true}, {"periodic", "logoff", true}, {"", "logoff", false}} {
		label := c.kind
		if label == "" {
			label = "none"
		}
		t.Run(label, func(t *testing.T) {
			uid := []string{"301", "302", "303"}[i]
			cutoffSession(t, uid) // its resets only; the session is seated in the fake init's dir below
			ssdShortReap(t)
			resetAbandoned(t, nil)
			f := abFakeInit(t, []abPlan{{laneRW, "OK 0", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}})
			seen := ssdStopSeen(t, f.dest)
			kinds := smReqKinds(t, f.dest)
			name := "sealstopm" + uid
			if err := markRoamSession(f.dest, name, name+" pass", uid, ""); err != nil {
				t.Fatal(err)
			}
			pendingReapMu.Lock()
			sealRunKind = c.kind
			sealInFlight = c.kind == "manual"
			pendingReapMu.Unlock()
			if got := ropReply(t, func(conn net.Conn) { handleLogout(conn, f.dest) }); got != "OK" {
				t.Fatalf("LOGOUT replied %q", got)
			}
			ssdWaitReap(t, uid)
			starts, at, ks := f.snapshot(), seen(), kinds()
			var cutoffAt, outKind string
			for j, s := range starts {
				if s.ignored {
					continue
				}
				switch s.reqOp {
				case "cutoff":
					cutoffAt = map[bool]string{true: "present", false: "absent"}[at[j]]
				case "out":
					outKind = ks[j][1]
				}
			}
			if want := map[bool]string{true: "present", false: "absent"}[c.stop]; cutoffAt != want {
				t.Errorf("announce %q: the stop request was %q at the cutoff, want %q", c.kind, cutoffAt, want)
			}
			if outKind != c.line6 {
				t.Errorf("announce %q: the sign-out's out request carried kind %q on line 6, want %q", c.kind, outKind, c.line6)
			}
			if ssdPresent(f.dest) {
				t.Error("the stop request outlived the sign-out's seal")
			}
		})
	}
}

// smBackupUnderSignOut drives a real "Back up now" through handleBackup and its goroutine against the fake init: the
// manual's out op holds the RW slot until the test lets it answer reply. While it runs, the relay is first seen writing
// the manual's own bar; then a sign-out takes the announce, as handleLogout does under pendingReapMu (its own seal
// queues behind the slot, so the test stands in for it), and the manual's worker writes one more progress frame. The
// worker then answers, and the helper joins the "manual-backup" goroutine (trackGoSafe), so every read after it sees
// what the goroutine's bookkeeping and its defer left. Only symbols that predate h49 #13 are used, so the tests build
// against the code before it and fail there by assertion.
func smBackupUnderSignOut(t *testing.T, uid, reply string) {
	t.Helper()
	tr := trackGoSafe(t)
	cutoffSession(t, uid) // its resets only; the session is seated in the fake init's dir below
	skipVerdictSetup(t)
	t.Setenv("GATEWAY_URL", "") // maybePayRent: billing not configured
	pendingReapMu.Lock()
	prevSettle := loginSettleUntil
	loginSettleUntil = time.Time{}
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		loginSettleUntil = prevSettle
		sealProg = ""
		pendingReapMu.Unlock()
	})
	resetAbandoned(t, nil)
	rel := make(chan struct{})
	f := abFakeInit(t, []abPlan{{laneRW, reply, rel}})
	name := "sealstopb" + uid
	if err := markRoamSession(f.dest, name, name+" pass", uid, ""); err != nil {
		t.Fatal(err)
	}
	if got := ropReply(t, func(conn net.Conn) { handleBackup(conn, f.dest) }); got != "OK" {
		t.Fatalf("BACKUP replied %q", got)
	}
	prog := filepath.Join(f.dest, laneRW.prog)
	smWait(t, "the manual's out op to start", func() bool {
		for _, s := range f.snapshot() {
			if !s.ignored && s.reqOp == "out" {
				return true
			}
		}
		return false
	})
	if err := os.WriteFile(prog, []byte("seal 5 100 data\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	smWait(t, "the manual's relay to write its own bar (control)", func() bool {
		pendingReapMu.Lock()
		defer pendingReapMu.Unlock()
		return sealProg == "seal 5 100 data"
	})
	pendingReapMu.Lock()
	sealInFlight, sealRunKind, sealRunAt = true, "logoff", time.Now()
	sealProg, sealPartial = "the sign-out's bar", "apps=refused"
	pendingReapMu.Unlock()
	// Written before the release: the poll reads the progress file before the result on every tick, so the relay
	// has seen this frame by the time the worker's answer is read.
	if err := os.WriteFile(prog, []byte("seal 9 100 data\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	close(rel)
	tr.wait(t, 15*time.Second)
}

// smWait polls cond every millisecond; a 10 s bound is a hang guard.
func smWait(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("waited 10s for %s (hang guard)", what)
		}
		time.Sleep(time.Millisecond)
	}
}

// T2: a Back up now a sign-out stopped (its worker answers SKIP-STOPPED) records no verdict, no landed seq and no
// summary: the sign-out owns the status and records its own save.
func TestManualStop_StoppedBackupRecordsNothing(t *testing.T) {
	prevLanded, prevSave := sealLandedSeq.Load(), lastSaveSeq.Load()
	prevBytes, prevAreas := lastSaveBytes.Load(), lastSaveAreas.Load()
	prevStart := lastLandedSealStartedAt.Load()
	t.Cleanup(func() {
		sealLandedSeq.Store(prevLanded)
		lastSaveSeq.Store(prevSave)
		lastSaveBytes.Store(prevBytes)
		lastSaveAreas.Store(prevAreas)
		lastLandedSealStartedAt.Store(prevStart)
	})
	smBackupUnderSignOut(t, "321", "SKIP-STOPPED")
	pendingReapMu.Lock()
	partial, failed := sealPartial, sealFail
	pendingReapMu.Unlock()
	if partial != "apps=refused" || failed {
		t.Errorf("after a stopped Back up now: sealPartial=%q sealFail=%v, want the sign-out's apps=refused and false",
			partial, failed)
	}
	if sealLandedSeq.Load() != prevLanded || lastSaveSeq.Load() != prevSave {
		t.Errorf("seqs moved: landed %d->%d, save %d->%d", prevLanded, sealLandedSeq.Load(), prevSave, lastSaveSeq.Load())
	}
	if lastSaveBytes.Load() != prevBytes || lastSaveAreas.Load() != prevAreas {
		t.Error("a stopped Back up now published a save summary")
	}
	if lastLandedSealStartedAt.Load() != prevStart {
		t.Error("a stopped Back up now moved the last landed seal's start")
	}
}

// T3: the manual goroutine ending after a sign-out took its announce leaves sealInFlight true and sealRunKind "logoff"
// (clearing them ended the sign-out's stall watchdog and POLL-REAP's SEALING while its seal still ran), and its
// relay stops writing the bar once the announce is the sign-out's.
func TestManualStop_EndLeavesASignOutsAnnounce(t *testing.T) {
	smBackupUnderSignOut(t, "322", "SKIP-STOPPED")
	pendingReapMu.Lock()
	in, kind, prog := sealInFlight, sealRunKind, sealProg
	pendingReapMu.Unlock()
	if !in || kind != "logoff" {
		t.Errorf("the manual's end under a sign-out: sealInFlight=%v sealRunKind=%q, want true and logoff", in, kind)
	}
	if prog != "the sign-out's bar" {
		t.Errorf("the manual's relay wrote the bar %q under a sign-out", prog)
	}
}

// T3 control: a Back up now that ends under its own announce releases it (the compare-and-clear still clears).
func TestManualStop_EndReleasesItsOwnAnnounce(t *testing.T) {
	tr := trackGoSafe(t)
	cutoffSession(t, "323")
	skipVerdictSetup(t)
	t.Setenv("GATEWAY_URL", "")
	pendingReapMu.Lock()
	prevSettle := loginSettleUntil
	loginSettleUntil = time.Time{}
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		loginSettleUntil = prevSettle
		sealProg = ""
		pendingReapMu.Unlock()
	})
	resetAbandoned(t, nil)
	f := abFakeInit(t, []abPlan{{laneRW, "SKIP-STOPPED", nil}})
	if err := markRoamSession(f.dest, "sealstopb323", "sealstopb323 pass", "323", ""); err != nil {
		t.Fatal(err)
	}
	if got := ropReply(t, func(conn net.Conn) { handleBackup(conn, f.dest) }); got != "OK" {
		t.Fatalf("BACKUP replied %q", got)
	}
	tr.wait(t, 15*time.Second)
	pendingReapMu.Lock()
	in, kind := sealInFlight, sealRunKind
	pendingReapMu.Unlock()
	if in || kind != "" {
		t.Errorf("the manual's own end: sealInFlight=%v sealRunKind=%q, want false and empty", in, kind)
	}
}

// T4: a pinned sign-out's snapshot is pinned; a plain logoff's is not.
func TestSealKind_LogoffPinned(t *testing.T) {
	for v, want := range map[string]string{"manual": "manual", "logoff-pinned": "manual", "logoff": "", "": "", "periodic": ""} {
		t.Setenv("NOWHERE_SEAL_KIND", v)
		if got := sealKind(); got != want {
			t.Errorf("NOWHERE_SEAL_KIND=%q: sealKind() = %q, want %q", v, got, want)
		}
	}
}

// smAtSlot sets the announce to kind for the test (restored in Cleanup) and returns a fake init with one RW answer, so
// a test can call runWorkerHeld directly, as TestSealStopDaemon_ASkippedOutLeavesTheRequest does.
func smAtSlot(t *testing.T, kind string) *abInit {
	t.Helper()
	resetAbandoned(t, nil)
	pendingReapMu.Lock()
	prevKind, prevReap, prevSwitch := sealRunKind, pendingReapUID, pendingSwitchUID
	sealRunKind, pendingReapUID, pendingSwitchUID = kind, "", ""
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealRunKind, pendingReapUID, pendingSwitchUID = prevKind, prevReap, prevSwitch
		pendingReapMu.Unlock()
	})
	return abFakeInit(t, []abPlan{{lane: laneRW, text: "OK"}})
}

// smOneOut fails unless starts is exactly one honoured start of out.
func smOneOut(t *testing.T, starts []abStart) {
	t.Helper()
	if len(starts) != 1 || starts[0].ignored || starts[0].reqOp != "out" {
		t.Errorf("starts = %+v, want one honoured start of out", starts)
	}
}

// T5 (NWP-20261126-11): a Back up now still queued for the slot when a sign-out takes its announce answers
// SKIP-STOPPED under the slot, writes no request and leaves the sign-out's stop request for the sign-out's own seal.
func TestManualStop_QueuedManualSkipsAtTheSlot(t *testing.T) {
	f := smAtSlot(t, "logoff")
	ssdRaise(t, f.dest)
	if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "manual", "", "manual", nil); out != "SKIP-STOPPED" {
		t.Errorf("a queued Back up now under a sign-out's announce answered %q, want SKIP-STOPPED (h49 #13)", out)
	}
	if starts := f.snapshot(); len(starts) != 0 {
		t.Errorf("the skipped Back up now started roamd: %+v", starts)
	}
	if _, err := os.Stat(filepath.Join(f.dest, laneRW.req)); !os.IsNotExist(err) {
		t.Errorf("the skipped Back up now left a request file (stat err %v)", err)
	}
	if !ssdPresent(f.dest) {
		t.Error("the skipped Back up now dropped the sign-out's stop request")
	}
}

// T5 control: the sign-out's own out op (intent "") runs under its own "logoff" announce and drops the request.
func TestManualStop_SignOutsOwnOutRunsUnderItsAnnounce(t *testing.T) {
	f := smAtSlot(t, "logoff")
	ssdRaise(t, f.dest)
	if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "logoff-pinned", "", "", nil); out != "OK" {
		t.Fatalf("the sign-out's own out op answered %q, want OK", out)
	}
	smOneOut(t, f.snapshot())
	if ssdPresent(f.dest) {
		t.Error("the stop request outlived the sign-out's own out op")
	}
}

// T5 control: a queued Back up now under its own "manual" announce runs as tapped.
func TestManualStop_QueuedManualRunsWithItsOwnAnnounce(t *testing.T) {
	f := smAtSlot(t, "manual")
	if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "manual", "", "manual", nil); out != "OK" {
		t.Fatalf("a Back up now under its own announce answered %q, want OK", out)
	}
	smOneOut(t, f.snapshot())
}

// T5 control: a queued Back up now whose sign-out already ended (announce "") runs as tapped and drops the stale
// request, as any out op that runs does.
func TestManualStop_QueuedManualAfterTheSignOutEnded(t *testing.T) {
	f := smAtSlot(t, "")
	ssdRaise(t, f.dest)
	if out := runWorkerHeld(laneRW, f.dest, "out", "p", "", "10", "", "manual", "", "manual", nil); out != "OK" {
		t.Fatalf("a Back up now after the sign-out ended answered %q, want OK", out)
	}
	smOneOut(t, f.snapshot())
	if ssdPresent(f.dest) {
		t.Error("the stale stop request outlived the Back up now that ran")
	}
}

// T5: only a "manual" intent under a "logoff" announce is stopped at the slot.
func TestManualStoppedAtSlot(t *testing.T) {
	pendingReapMu.Lock()
	prev := sealRunKind
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealRunKind = prev
		pendingReapMu.Unlock()
	})
	for _, c := range []struct {
		intent, kind string
		want         bool
	}{
		{"manual", "logoff", true},
		{"manual", "manual", false},
		{"manual", "", false},
		{"periodic", "logoff", false},
		{"", "logoff", false},
		{"logoff", "logoff", false},
	} {
		pendingReapMu.Lock()
		sealRunKind = c.kind
		pendingReapMu.Unlock()
		if got := manualStoppedAtSlot(c.intent); got != c.want {
			t.Errorf("manualStoppedAtSlot(%q) under announce %q = %v, want %v", c.intent, c.kind, got, c.want)
		}
	}
}

// T6, end to end: a Back up now queued behind an RW op that holds the slot, then a sign-out. When the slot frees, the
// Back up now answers SKIP-STOPPED and the sign-out writes the only out request, as "logoff-pinned". The test holds
// the slot itself, and holds the sign-out at its flush (logoffSync) until the Back up now's goroutine has ended, so the
// order is forced by the test, never by the scheduler.
func TestManualStop_QueuedBackupThenSignOutSealsOnce(t *testing.T) {
	const uid = "331"
	tr := trackGoSafe(t)
	cutoffSession(t, uid) // its resets only; the session is seated in the fake init's dir below
	ssdShortReap(t)
	skipVerdictSetup(t)
	t.Setenv("GATEWAY_URL", "") // maybePayRent: billing not configured
	pendingReapMu.Lock()
	prevSettle := loginSettleUntil
	loginSettleUntil = time.Time{}
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		loginSettleUntil = prevSettle
		sealProg = ""
		pendingReapMu.Unlock()
	})
	resetAbandoned(t, nil)
	// cutoff, sweepmedia and out for the sign-out; one spare so the pre-fix code's extra out also gets an answer.
	f := abFakeInit(t, []abPlan{{laneRW, "OK 0", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}, {laneRW, "OK", nil}})
	kinds := smReqKinds(t, f.dest)
	name := "sealstopq" + uid
	if err := markRoamSession(f.dest, name, name+" pass", uid, ""); err != nil {
		t.Fatal(err)
	}
	var freeOnce, syncOnce sync.Once
	laneRW.slot <- struct{}{} // another RW op holds the slot
	free := func() { freeOnce.Do(func() { <-laneRW.slot }) }
	t.Cleanup(free)
	syncGate := make(chan struct{})
	open := func() { syncOnce.Do(func() { close(syncGate) }) }
	prevSync := logoffSync
	logoffSync = func() { <-syncGate }
	t.Cleanup(func() { open(); logoffSync = prevSync })
	if got := ropReply(t, func(conn net.Conn) { handleBackup(conn, f.dest) }); got != "OK" {
		t.Fatalf("BACKUP replied %q", got)
	}
	if got := ropReply(t, func(conn net.Conn) { handleLogout(conn, f.dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	free()
	smWait(t, "the queued Back up now to end", func() bool { return tr.count("manual-backup") == 0 })
	outs := func() []string {
		var ks []string
		got := kinds()
		for i, s := range f.snapshot() {
			if !s.ignored && s.reqOp == "out" {
				ks = append(ks, got[i][1])
			}
		}
		return ks
	}
	if ks := outs(); len(ks) != 0 {
		t.Errorf("the queued Back up now wrote out request(s) %q under a sign-out -- it must skip (h49 #13)", ks)
	}
	if !ssdPresent(f.dest) {
		t.Error("the queued Back up now dropped the sign-out's stop request")
	}
	open()
	ssdWaitReap(t, uid)
	if ks := outs(); len(ks) != 1 || ks[0] != "logoff-pinned" {
		t.Errorf("out requests written = %q, want exactly one, logoff-pinned", ks)
	}
	if ssdPresent(f.dest) {
		t.Error("the stop request outlived the sign-out's seal")
	}
}
