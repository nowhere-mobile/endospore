package main

import (
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Q067 (NWP-20261111-09): a sign-out for a session whose cold lock holds the sign-out bar is refused BUSY COLDLOCK
// until the lock lands or aborts. A key-bound lock raises the bar before its forward rekey (from then on the owner
// cannot type the keyguard credential); any lock raises it at Check B once it will commit. handleLogout reads the
// bar and claims the logoff veto in one coldLockMu hold, so "whichever claims the session first finishes, and the
// other waits". A PIN or passphrase session keeps today's veto while it waits. Backlog row: "A 2FA owner who returns
// during a queued cold lock cannot type the keyguard credential, and cannot abort".

// sobSetup is clwSetup plus the state this file touches: the bar, the commit hook, the veto and the restart state.
func sobSetup(t *testing.T) (string, *clwRecorder, *clwHold) {
	t.Helper()
	dest, rec, hold := clwSetup(t)
	rearmClear(t)
	reset := func() {
		coldLockMu.Lock()
		coldLockSignOutBar = ""
		coldLockMu.Unlock()
		coldLockBeforeCommit = func() {}
		setLogoffInFlight("")
		setRestartState("", "", "")
	}
	reset()
	t.Cleanup(reset)
	return dest, rec, hold
}

// sobLogoffStandIn makes a LOGOUT that proceeds end in the test, never on a real worker: the stand-in for roamd
// fails the media sweep, so the logoff keeps the session, wakes its apps and releases the veto. It also covers the
// old code, where the refusals below did not exist and the LOGOUT went on into the background seal.
func sobLogoffStandIn(t *testing.T, dest string) {
	t.Helper()
	fw := logoffFlushWait
	logoffFlushWait = 100 * time.Millisecond
	t.Cleanup(func() { logoffFlushWait = fw })
	resetSeal := func() {
		pendingReapMu.Lock()
		sealInFlight, sealUnstuck, sealFail, sealFailWhy, sealPartial, sealRunKind = false, false, false, "", "", ""
		pendingReapMu.Unlock()
	}
	resetSeal()
	t.Cleanup(resetSeal)
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": "ERR-MEDIA-SWEEP 1", "cutoffwake": "WAKE OK 3"}, nil)
	// Registered after the stand-in, so it runs before the stand-in stops answering.
	t.Cleanup(func() {
		deadline := time.Now().Add(20 * time.Second)
		for logoffInFlight("10") && time.Now().Before(deadline) {
			time.Sleep(50 * time.Millisecond)
		}
	})
}

// sobLogout sends LOGOUT as the dispatcher would and returns the reply. No *testing.T: the commit hook calls it
// from the teardown goroutine.
func sobLogout(dest string) string {
	cli, srv := net.Pipe()
	go func() { handleLogout(srv, dest); srv.Close() }()
	raw, _ := io.ReadAll(cli)
	cli.Close()
	return strings.TrimSpace(string(raw))
}

func sobBar() string {
	coldLockMu.Lock()
	defer coldLockMu.Unlock()
	return coldLockSignOutBar
}

func sobHasOp(rec *clwRecorder, op string) bool {
	for _, o := range rec.ops() {
		if o == op {
			return true
		}
	}
	return false
}

// B1. A key-bound lock waits for the RW slot after its forward rekey. The owner cannot type the keyguard, so the
// L4 auto-logoff is refused and changes nothing; the lock then lands.
func TestColdLockSignOutBarRefusesWhileAKeyBoundLockWaits(t *testing.T) {
	dest, rec, hold := sobSetup(t)
	sobLogoffStandIn(t, dest)
	clwFido2(t, dest)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return sobHasOp(rec, "rekey") }) {
		t.Fatal("the forward rekey never ran")
	}
	clwParked(t, p)
	if got := sobLogout(dest); got != "BUSY COLDLOCK" {
		t.Errorf("LOGOUT during a key-bound lock's wait replied %q, want BUSY COLDLOCK (Q067)", got)
	}
	if !clwExists(dest, ".roamsession") {
		t.Error("the refused LOGOUT removed .roamsession")
	}
	if logoffInFlight("10") {
		t.Error("the refused LOGOUT claimed the logoff veto, so Check B revokes the lock the owner cannot unlock")
	}
	hold.give()
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("the lock did not commit after the slot was released")
	}
	if got := sobLogout(dest); got != "OK" {
		t.Errorf("LOGOUT after the lock landed replied %q, want OK (no session)", got)
	}
	if b := sobBar(); b != "" {
		t.Errorf("the sign-out bar outlived the teardown: %q", b)
	}
}

// B9. A 2FA lock whose owner-present revoke is DECLINED (the unwind rekey fails) queues for the RW slot again before it
// commits. A LOGOUT in that re-queue is refused BUSY COLDLOCK and claims no veto, so the lock that commits after all
// never commits over a logoff (row defect (1), the re-queue path). The bar has two writers there: the key-bound raise
// before the forward rekey and the declined branch's re-raise; test-coldlock-signout-bar.sh's M8 removes both.
func TestColdLockSignOutBarRefusesDuringADeclinedRevokeRequeue(t *testing.T) {
	dest, rec, hold := sobSetup(t)
	sobLogoffStandIn(t, dest)
	clwFido2(t, dest)
	rec.ret = func(op string, nth int) string {
		if op == "rekey" && nth == 2 {
			return "ERR-REKEY" // the unwind fails, so the revoke is declined
		}
		return ""
	}
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return sobHasOp(rec, "rekey") }) {
		t.Fatal("the forward rekey never ran")
	}
	clwParked(t, p)
	p = coldLockParks.Load()
	if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
		t.Fatal("the unlock was rejected")
	}
	if !clwWaitFor(2*time.Second, func() bool { return len(rec.ops()) >= 2 }) {
		t.Fatal("the unwind was never attempted")
	}
	clwParked(t, p) // the declined revoke queues for the slot again
	if got := sobLogout(dest); got != "BUSY COLDLOCK" {
		t.Errorf("LOGOUT during a declined revoke's re-queue replied %q, want BUSY COLDLOCK (Q067)", got)
	}
	if !clwExists(dest, ".roamsession") {
		t.Error("the refused LOGOUT removed .roamsession")
	}
	if logoffInFlight("10") {
		t.Error("the refused LOGOUT claimed the logoff veto, so the declined lock commits over the logoff")
	}
	if clwExists(dest, ".coldlock") {
		t.Error(".coldlock written while the seal still holds the slot")
	}
	hold.give()
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("the declined lock did not commit after the slot was released")
	}
	if b := sobBar(); b != "" {
		t.Errorf("the sign-out bar outlived the teardown: %q", b)
	}
	if got := sobLogout(dest); got != "OK" {
		t.Errorf("LOGOUT after the lock landed replied %q, want OK (no session)", got)
	}
}

// B2. A logoff that claimed after Check A and before the key-bound rekey wins: no rekey is sent, nothing commits,
// and the session is kept. The FIFO .sessionpin is the teardown's first read after Check A, so the claim lands there.
func TestColdLockSignOutBarLogoffFirstSendsNoRekey(t *testing.T) {
	dest, rec, _ := sobSetup(t)
	clwFido2(t, dest)
	fifo := filepath.Join(dest, ".sessionpin")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatalf("mkfifo: %v", err)
	}
	clwLock(t, dest, 0)
	var w *os.File
	deadline := time.Now().Add(2 * time.Second)
	for {
		f, err := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
		if err == nil {
			w = f
			break
		}
		if !errors.Is(err, syscall.ENXIO) || time.Now().After(deadline) {
			t.Fatalf("the teardown never read .sessionpin: %v", err)
		}
		time.Sleep(2 * time.Millisecond)
	}
	setLogoffInFlight("10")
	w.Close() // an empty PIN: the teardown goes on to the key-bound branch
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if sobHasOp(rec, "rekey") {
		t.Errorf("a rekey was dispatched with a logoff already claimed (ops %v) -- the keyguard moved under a sign-out", rec.ops())
	}
	if clwExists(dest, ".coldlock") {
		t.Error(".coldlock was written over a claimed logoff")
	}
	if !clwExists(dest, ".roamsession") {
		t.Error("the session was not kept")
	}
	if got := nextReapAction(); got != "REARM 10" {
		t.Errorf("nextReapAction = %q, want REARM 10", got)
	}
}

// B3. A PIN session keeps today's veto: a LOGOUT during the wait claims, and Check B revokes the lock.
func TestColdLockSignOutBarPinSessionKeepsTheVeto(t *testing.T) {
	dest, rec, hold := sobSetup(t)
	sobLogoffStandIn(t, dest)
	if err := os.WriteFile(filepath.Join(dest, ".sessionpin"), []byte("1234\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	clwParked(t, p)
	if got := sobLogout(dest); got != "OK" {
		t.Fatalf("LOGOUT during a PIN lock's wait replied %q, want OK (today's veto)", got)
	}
	if !logoffInFlight("10") {
		t.Fatal("the LOGOUT did not claim the logoff veto")
	}
	hold.give()
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if clwExists(dest, ".coldlock") {
		t.Error("the lock committed over a logoff that claimed first")
	}
	if sobHasOp(rec, "btpark") {
		t.Error("btpark ran for a revoked lock")
	}
	logoffDone(t, "10", 20*time.Second)
}

// B4. A PIN session past Check B: the lock will commit, so a LOGOUT arriving before the commit is refused and
// never claims a veto the lock has already passed.
func TestColdLockSignOutBarPinSessionRefusedPastCheckB(t *testing.T) {
	dest, _, _ := sobSetup(t)
	sobLogoffStandIn(t, dest)
	if err := os.WriteFile(filepath.Join(dest, ".sessionpin"), []byte("1234\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	type seen struct {
		reply           string
		claimed, sealed bool
	}
	got := make(chan seen, 1)
	coldLockBeforeCommit = func() {
		r := sobLogout(dest)
		pendingReapMu.Lock()
		s := sealInFlight
		pendingReapMu.Unlock()
		got <- seen{r, logoffInFlight("10"), s}
	}
	clwLock(t, dest, 0)
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	var s seen
	select {
	case s = <-got:
	default:
		t.Fatal("the commit hook never ran")
	}
	if s.reply != "BUSY COLDLOCK" {
		t.Errorf("LOGOUT past Check B replied %q, want BUSY COLDLOCK (Q067)", s.reply)
	}
	if s.claimed || s.sealed {
		t.Errorf("the LOGOUT past Check B claimed the veto (%v) or started a seal (%v)", s.claimed, s.sealed)
	}
	if !clwExists(dest, ".coldlock") {
		t.Error("the lock did not commit")
	}
}

// B5. After an abort (the user came back) the bar is clear and a sign-out proceeds.
func TestColdLockSignOutBarClearAfterAbort(t *testing.T) {
	dest, rec, hold := sobSetup(t)
	sobLogoffStandIn(t, dest)
	clwFido2(t, dest)
	hold.take()
	p := coldLockParks.Load()
	clwLock(t, dest, 1000)
	if !clwWaitFor(2*time.Second, func() bool { return sobHasOp(rec, "rekey") }) {
		t.Fatal("the forward rekey never ran")
	}
	clwParked(t, p)
	if armed, _ := armColdLockAbort(dest, "10", 2000); !armed {
		t.Fatal("the unlock was rejected")
	}
	if !clwWaitFor(5*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	hold.give()
	if clwExists(dest, ".coldlock") {
		t.Fatal("the aborted lock committed")
	}
	if b := sobBar(); b != "" {
		t.Errorf("the sign-out bar outlived an aborted lock: %q", b)
	}
	if got := sobLogout(dest); got != "OK" {
		t.Fatalf("LOGOUT after an aborted lock replied %q, want OK", got)
	}
	if !logoffInFlight("10") {
		t.Error("the LOGOUT after an aborted lock did not claim the veto")
	}
	logoffDone(t, "10", 20*time.Second)
}

// B6. A pending restart still answers a bare BUSY first, bar or no bar: the chooser reboots on it, as confirmed.
func TestColdLockSignOutBarRestartPendingStillAnswersBusy(t *testing.T) {
	dest, _, _ := sobSetup(t)
	setRestartState("PENDING", "alice", "10")
	coldLockMu.Lock()
	coldLockSignOutBar = "10"
	coldLockMu.Unlock()
	if got := sobLogout(dest); got != "BUSY" {
		t.Errorf("LOGOUT with a restart pending replied %q, want BUSY", got)
	}
}

// B7a. A key-bound lock whose forward rekey is refused hands off to a sign-out; that sign-out must not meet the bar.
func TestColdLockSignOutBarArmFailClearsBeforeSignOut(t *testing.T) {
	dest, rec, _ := sobSetup(t)
	saw := make(chan string, 1)
	prev := coldLockSignOut
	coldLockSignOut = func(string) { saw <- sobBar() }
	t.Cleanup(func() { coldLockSignOut = prev })
	clwFido2(t, dest)
	rec.ret = func(op string, nth int) string {
		if op == "rekey" && nth == 1 {
			return "ERR-REKEY"
		}
		return ""
	}
	clwLock(t, dest, 0)
	select {
	case b := <-saw:
		if b != "" {
			t.Errorf("the arm-fail sign-out met the sign-out bar %q -- its handleLogout answers BUSY COLDLOCK", b)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the arm failure never handed off to a sign-out")
	}
	rearmIdle(t)
}

// B7b. The source half of B7a, which alone races the defer: the arm-fail hold clears the bar before the hand-off.
func TestColdLockSignOutBarArmFailClearSource(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "coldLockTeardown"))
	at := -1
	for i, l := range body {
		if strings.HasPrefix(strings.TrimSpace(l), `goSafe("coldlock-armfail-signout"`) {
			at = i
			break
		}
	}
	if at < 0 {
		t.Fatal(`no goSafe("coldlock-armfail-signout" in coldLockTeardown -- this test is stale`)
	}
	lock := -1
	for i := at; i >= 0; i-- {
		if strings.TrimSpace(body[i]) == "coldLockMu.Lock()" {
			lock = i
			break
		}
	}
	if lock < 0 {
		t.Fatal("no coldLockMu hold before the arm-fail hand-off")
	}
	for i := lock + 1; i < at; i++ {
		s := strings.TrimSpace(body[i])
		if s == "coldLockMu.Unlock()" {
			break
		}
		if s == `coldLockSignOutBar = ""` {
			return
		}
	}
	t.Error(`the arm-fail branch's coldLockMu hold does not clear coldLockSignOutBar before goSafe("coldlock-armfail-signout" ` +
		"-- the handed-off sign-out can meet the bar and be refused")
}

// B8. handleLogout claims the veto in the hold that reads the bar, and nowhere else.
func TestColdLockSignOutBarClaimSharesTheHold(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, l := range stripComments(funcBody(t, string(b), "handleLogout")) {
		if s := strings.TrimSpace(l); s != "" {
			lines = append(lines, s)
		}
	}
	bar, claim, claims := -1, -1, 0
	for i, s := range lines {
		if s == "if coldLockSignOutBar == uid {" && bar < 0 {
			bar = i
		}
		if strings.Contains(s, "setLogoffInFlight(") {
			claims++
			if strings.HasPrefix(s, "logoffClaim := setLogoffInFlight(uid)") {
				claim = i
			}
		}
	}
	switch {
	case bar < 0:
		t.Fatal("handleLogout does not read the sign-out bar")
	case bar == 0 || lines[bar-1] != "coldLockMu.Lock()":
		t.Error("the bar check is not the first step of a coldLockMu hold")
	case claims != 1:
		t.Errorf("handleLogout claims the veto %d times, want once", claims)
	case claim < bar:
		t.Error("the veto claim is not after the bar check")
	case claim+1 >= len(lines) || lines[claim+1] != "coldLockMu.Unlock()":
		t.Error("the veto claim is not in the bar's coldLockMu hold -- a lock can raise the bar between the check and the claim")
	}
	for i := bar + 1; bar >= 0 && i < claim; i++ {
		if lines[i] == "coldLockMu.Lock()" {
			t.Error("handleLogout takes coldLockMu again between the bar check and the claim")
		}
	}
}
