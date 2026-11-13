package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261202-10: the periodic save's change test (periodic_change.go). D1..D7 pin the pure decision; L1..L6 drive
// real syncLoop cycles against a stand-in worker and a stub probe; S1 pins where the gate sits in syncLoop.

// pchgAll is a change-mode reply with every count set to v and deletedUnknown as given.
func pchgAll(v int, unknown string) string {
	return fmt.Sprintf(`{"mode":"change","changedFiles":%d,"deferredChangedFiles":%d,"deletedFiles":%d,"changedDirs":%d,`+
		`"stateChanged":%d,"appsChanged":%d,"blind":%d%s}`, v, v, v, v, v, v, v, unknown)
}

var pchgNoChange = pchgAll(0, "")

func pchgDue(t *testing.T, label string, lastAgo time.Duration, dirty bool, reply string, err error, wantDue bool, wantWhy string) {
	t.Helper()
	now := time.Unix(1_800_000_000, 0)
	last := int64(0)
	if lastAgo >= 0 {
		last = now.Add(-lastAgo).Unix()
	}
	due, why := periodicSaveDue(now, last, dirty, reply, err)
	if due != wantDue || why != wantWhy {
		t.Errorf("%s: periodicSaveDue = (%v, %q), want (%v, %q)", label, due, why, wantDue, wantWhy)
	}
}

func TestPeriodicChangeD1NoBase(t *testing.T) {
	pchgDue(t, "no landed save, a nochange reply", -1, false, pchgNoChange, nil, true, "nobase")
	pchgDue(t, "no landed save, a probe error", -1, false, "", errors.New("x"), true, "nobase")
}

func TestPeriodicChangeD2Floor(t *testing.T) {
	pchgDue(t, "exactly 60 min", 60*time.Minute, false, pchgNoChange, nil, true, "floor")
	pchgDue(t, "61 min", 61*time.Minute, false, pchgNoChange, nil, true, "floor")
	pchgDue(t, "59 min 59 s", 60*time.Minute-time.Second, false, pchgNoChange, nil, false, "nochange")
}

func TestPeriodicChangeD3Dirty(t *testing.T) {
	pchgDue(t, "a mark, 5 min, a nochange reply", 5*time.Minute, true, pchgNoChange, nil, true, "dirty")
}

func TestPeriodicChangeD4ProbeErr(t *testing.T) {
	pchgDue(t, "an error with a nochange reply", 5*time.Minute, false, pchgNoChange, errors.New("idx"), true, "probe-err")
	for _, r := range []string{
		"", "ERR-WORKER", "BUSY", "null", "[]", "{", pchgNoChange + pchgNoChange, pchgNoChange + " x",
		strings.Replace(pchgNoChange, `"changedFiles":0`, `"changedFiles":"0"`, 1),
		strings.Replace(pchgNoChange, `"changedFiles":0`, `"changedFiles":0.5`, 1),
		strings.Replace(pchgNoChange, `"changedFiles":0,`, ``, 1),
		strings.Replace(pchgNoChange, `"blind":0`, `"blind":-1`, 1),
		strings.Replace(pchgNoChange, `}`, `,"deletedUnknown":"vault"}`, 1),
	} {
		pchgDue(t, fmt.Sprintf("reply %q", r), 5*time.Minute, false, r, nil, true, "probe-err")
	}
}

func TestPeriodicChangeD5OldAgent(t *testing.T) {
	pchgDue(t, "today's walk (no mode)", 5*time.Minute, false,
		`{"changedFiles":0,"deferredChangedFiles":0,"deletedFiles":0,"blind":0,"since":1}`, nil, true, "old-agent")
	pchgDue(t, "another mode", 5*time.Minute, false, strings.Replace(pchgNoChange, `"change"`, `"full"`, 1), nil, true, "old-agent")
}

func TestPeriodicChangeD6Changed(t *testing.T) {
	for _, f := range []string{"changedFiles", "deferredChangedFiles", "deletedFiles", "changedDirs", "stateChanged", "appsChanged", "blind"} {
		r := strings.Replace(pchgNoChange, `"`+f+`":0`, `"`+f+`":1`, 1)
		if r == pchgNoChange {
			t.Fatalf("fixture: %s is not in the reply", f)
		}
		pchgDue(t, f+"=1", 5*time.Minute, false, r, nil, true, "changed")
	}
	pchgDue(t, "deletedUnknown non-empty", 5*time.Minute, false, pchgAll(0, `,"deletedUnknown":["vault"]`), nil, true, "changed")
}

func TestPeriodicChangeD7NoChange(t *testing.T) {
	pchgDue(t, "every count 0, deletedUnknown absent", 5*time.Minute, false, pchgNoChange, nil, false, "nochange")
	pchgDue(t, "every count 0, deletedUnknown empty", 5*time.Minute, false, pchgAll(0, `,"deletedUnknown":[]`), nil, false, "nochange")
	pchgDue(t, "with blanks round it", 5*time.Minute, false, "\n "+pchgNoChange+"\n", nil, false, "nochange")
}

// ---- one or two real syncLoop cycles ----

const pchgPass, pchgGen = "pc-gate-pass", "pc-gen-1"

type pchgFix struct {
	dest   string
	probes atomic.Int32
	ops    func() []string
}

// pchgSetup gives a live session at a fresh state dir whose last periodic save landed 5 minutes ago and whose wallet
// stamp is taken, so nobase, floor and the wallet mark do not decide. The wallet generation has its restore proof, so
// the seal path's wallet retry never reads a store.
func pchgSetup(t *testing.T, name, uid string) *pchgFix {
	t.Helper()
	sessionState(t)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	oldLanded, oldStarted, oldProbe := lastLandedSealStartedAt.Load(), periodicSealStartedAt.Load(), periodicChangeProbe
	resetPeriodicChange()
	t.Cleanup(func() {
		periodicChangeProbe = oldProbe
		lastLandedSealStartedAt.Store(oldLanded)
		periodicSealStartedAt.Store(oldStarted)
		resetPeriodicChange()
	})
	f := &pchgFix{dest: t.TempDir()}
	if err := markRoamSession(f.dest, name, pchgPass, uid, ""); err != nil {
		t.Fatal(err)
	}
	wp := walletPathFor(f.dest)
	if err := os.WriteFile(wp+".gen", []byte(pchgGen), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(walletRestoreLandedPath(wp, pchgGen), []byte(walletLandedProofHead+pchgGen), 0o600); err != nil {
		t.Fatal(err)
	}
	lastLandedSealStartedAt.Store(time.Now().Unix() - 300)
	periodicSealVerdict(f.dest, "OK") // the stamp: no wallet file
	periodicDirty.Store(false)
	return f
}

// probe makes the stub probe answer reply; bumpGen also moves the wallet generation, so the skip arm's wallet retry
// shows that it ran (it refuses, logging so) without reading any store.
func (f *pchgFix) probe(reply string, bumpGen bool) {
	periodicChangeProbe = func(dest, name, pass, uid string, since int64) (string, error) {
		f.probes.Add(1)
		if bumpGen {
			os.WriteFile(walletPathFor(dest)+".gen", []byte("pc-gen-2"), 0o600)
		}
		return reply, nil
	}
}

// cycles runs n cycles of the real syncLoop and returns its stderr.
func (f *pchgFix) cycles(t *testing.T, n int32) string {
	t.Helper()
	old := syncLoopSleep
	t.Cleanup(func() { syncLoopSleep = old })
	var sleeps atomic.Int32
	syncLoopSleep = func(time.Duration) {
		if sleeps.Add(1) > n {
			runtime.Goexit()
		}
	}
	return captureStderr(t, func() {
		done := make(chan struct{})
		go func() {
			defer close(done)
			syncLoop(f.dest)
		}()
		select {
		case <-done:
		case <-time.After(60 * time.Second):
			t.Fatal("the periodic cycles did not finish within 60 s")
		}
	})
}

func (f *pchgFix) outs() int {
	n := 0
	for _, op := range f.ops() {
		if op == "out" {
			n++
		}
	}
	return n
}

func TestPeriodicChangeL1NoChangeSkips(t *testing.T) {
	f := pchgSetup(t, "pc-gate-l1", "171")
	f.ops = cutoffWorker(t, f.dest, map[string]string{"out": "OK"}, nil)
	f.probe(pchgNoChange, true)
	t.Setenv("GATEWAY_URL", "http://127.0.0.1:1") // maybePayRent reaches its gate; the hold below spends nothing
	rentMu.Lock()
	oldHold := rentExitHold
	rentExitHold = true
	rentMu.Unlock()
	t.Cleanup(func() { rentMu.Lock(); rentExitHold = oldHold; rentMu.Unlock() })
	started := periodicSealStartedAt.Load()
	out := f.cycles(t, 1)
	if f.probes.Load() != 1 {
		t.Fatalf("the probe ran %d times, want 1; stderr:\n%s", f.probes.Load(), out)
	}
	if n := f.outs(); n != 0 {
		t.Errorf("a cycle with no change ran the out op %d time(s); stderr:\n%s", n, out)
	}
	if periodicSealStartedAt.Load() != started {
		t.Error("a skipped cycle announced a periodic seal")
	}
	if !strings.Contains(out, "[logind] periodic seal skipped: no change since the last landed save 5 min ago (floor 60 min) (NWP-20261202-10)") {
		t.Errorf("no skip line; stderr:\n%s", out)
	}
	if periodicNoChangeSkips.Load() != 1 {
		t.Errorf("periodicNoChangeSkips = %d, want 1", periodicNoChangeSkips.Load())
	}
	if !strings.Contains(out, "the session changed since its wallet generation was read -- no retry") {
		t.Errorf("the skip arm did not reach retrySessionWallet; stderr:\n%s", out)
	}
	if !strings.Contains(out, `pay-rent "pc-gate-l1": skipped -- an unsaved sign-out or restart is in progress`) {
		t.Errorf("the skip arm did not reach maybePayRent; stderr:\n%s", out)
	}
	if !strings.Contains(out, "mediad start requested for user 171") {
		t.Errorf("the skip arm did not reach kickMediad; stderr:\n%s", out)
	}
	if strings.Contains(out, "periodic change test:") {
		t.Errorf("a nochange verdict logged the change-test line; stderr:\n%s", out)
	}
}

func TestPeriodicChangeL2ChangedSeals(t *testing.T) {
	f := pchgSetup(t, "pc-gate-l2", "172")
	f.ops = cutoffWorker(t, f.dest, map[string]string{"out": "OK"}, nil)
	f.probe(strings.Replace(pchgNoChange, `"changedFiles":0`, `"changedFiles":3`, 1), false)
	out := f.cycles(t, 1)
	if f.probes.Load() != 1 || f.outs() != 1 {
		t.Fatalf("probes %d, out ops %d, want 1 and 1; stderr:\n%s", f.probes.Load(), f.outs(), out)
	}
	if !strings.Contains(out, "[logind] periodic change test: changed (files=3 dirs=0 deferred=0 deleted=0 unknown=0 state=0 apps=0 blind=0)") {
		t.Errorf("no change-test line; stderr:\n%s", out)
	}
	if strings.Contains(out, "periodic seal skipped") {
		t.Errorf("a changed cycle logged a skip; stderr:\n%s", out)
	}
}

func TestPeriodicChangeL3ShrinkMarks(t *testing.T) {
	f := pchgSetup(t, "pc-gate-l3", "173")
	f.ops = cutoffWorker(t, f.dest, map[string]string{"out": "OK"}, nil)
	f.probe(pchgNoChange, false)
	if got := esReply(t, func(c net.Conn) {
		handleExpectShrinkInferred(c, bufio.NewReader(strings.NewReader("org.example.pcgate\n")), f.dest)
	}); got != "OK" {
		t.Fatalf("EXPECT-SHRINK-INFERRED replied %q", got)
	}
	if !periodicDirty.Load() {
		t.Error("an EXPECT-SHRINK-INFERRED OK did not mark the session")
	}
	out := f.cycles(t, 1)
	if f.probes.Load() != 0 || f.outs() != 1 {
		t.Fatalf("after a shrink: probes %d, out ops %d, want 0 and 1; stderr:\n%s", f.probes.Load(), f.outs(), out)
	}
}

func TestPeriodicChangeL4WalletMarks(t *testing.T) {
	f := pchgSetup(t, "pc-gate-l4", "174")
	f.ops = cutoffWorker(t, f.dest, map[string]string{"out": "OK"}, nil)
	f.probe(pchgNoChange, false)
	if err := os.WriteFile(walletPathFor(f.dest), []byte(`{"tokens":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	out := f.cycles(t, 1)
	if f.probes.Load() != 0 || f.outs() != 1 {
		t.Fatalf("after a wallet write: probes %d, out ops %d, want 0 and 1; stderr:\n%s", f.probes.Load(), f.outs(), out)
	}
}

// L5: a mark set while the seal runs (after the announce) is kept for the next cycle.
func TestPeriodicChangeL5MarkDuringTheSealSurvives(t *testing.T) {
	f := pchgSetup(t, "pc-gate-l5", "175")
	g := make(chan struct{})
	f.ops = cutoffWorkerGated(t, f.dest, map[string]string{"out": "OK"}, nil, map[string]chan struct{}{"out#1": g}, "")
	f.probe(strings.Replace(pchgNoChange, `"stateChanged":0`, `"stateChanged":1`, 1), false)
	go func() {
		deadline := time.Now().Add(30 * time.Second)
		for !slices.Contains(f.ops(), "out") && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond)
		}
		periodicDirty.Store(true)
		close(g)
	}()
	out := f.cycles(t, 2)
	if f.outs() != 2 {
		t.Fatalf("out ops %d, want 2 (the mark set during the first seal must make the second cycle seal); stderr:\n%s", f.outs(), out)
	}
	if f.probes.Load() != 1 {
		t.Fatalf("the probe ran %d times, want 1 (the second cycle is decided by the mark); stderr:\n%s", f.probes.Load(), out)
	}
}

// L6: a periodic seal that does not land marks the session again, so a shrink mark is not lost to it.
func TestPeriodicChangeL6AFailedSealMarksAgain(t *testing.T) {
	f := pchgSetup(t, "pc-gate-l6", "176")
	f.ops = cutoffWorker(t, f.dest, map[string]string{"out": "ERR-STORE||OK"}, nil)
	f.probe(pchgNoChange, false)
	periodicDirty.Store(true)
	out := f.cycles(t, 2)
	if f.outs() != 2 || f.probes.Load() != 0 {
		t.Fatalf("out ops %d, probes %d, want 2 and 0; stderr:\n%s", f.outs(), f.probes.Load(), out)
	}
}

// S1: the gate precedes the announce, its skip arm keeps the wallet retry, the mediad kick and the rent, and the mark
// is cleared right after the announce.
func TestPeriodicChangeS1GatePlacement(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "syncLoop")), "\n")
	at := func(needle string) int {
		t.Helper()
		i := strings.Index(body, needle)
		if i < 0 {
			t.Fatalf("syncLoop has no %q -- this pin is stale", needle)
		}
		return i
	}
	gate, ann := at("periodicGate(dest, name, pass, uid)"), at("if !announcePeriodicSeal() {")
	outOp := at(`triggerRoamWorkerKind(dest, "out", name, pass, uid`)
	if gate > ann {
		t.Error("the change test runs after the announce: a skipped cycle would announce a seal that never runs")
	}
	skip := at("if !due {")
	if skip < gate || skip > ann {
		t.Error("the skip arm is not between the change test and the announce")
	}
	arm := body[skip:]
	end := strings.Index(arm, "continue")
	if end < 0 {
		t.Fatal("the skip arm has no continue")
	}
	arm = arm[:end]
	for _, call := range []string{
		"retrySessionWallet(dest, name, pass, seFromSession(dest), wgen, walletSignInWait)",
		"kickMediad(dest)",
		"maybePayRent(dest, name, pass, wgen)",
	} {
		if !strings.Contains(arm, call) {
			t.Errorf("the skip arm does not call %s before its continue", call)
		}
	}
	clr := at("periodicDirty.Store(false)")
	if clr < ann || clr > outOp {
		t.Error("the mark is not cleared between the announce and the out op")
	}
}
