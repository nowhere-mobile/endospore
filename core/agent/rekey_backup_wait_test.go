package main

import (
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// "Back up now" during a background re-key batch says what it waits for (NWP-20261206-13). The batch announces itself
// while it holds the worker slot (rekeyHoldsSlot); a tap during one is still accepted, and its OK gains a second line
// "WAIT rekey-batch" and a login.log line. A user op queued behind the batch still answers BUSY user-op-waiting.

// holdsSlotNow reads rekeyHoldsSlot under the lock that guards it.
func holdsSlotNow() bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return rekeyHoldsSlot
}

// keepRekeyWaitGlobals restores rekeyHoldsSlot and rekeyScopeStep when the test ends.
func keepRekeyWaitGlobals(t *testing.T) {
	t.Helper()
	oldHolds, oldStep := holdsSlotNow(), rekeyScopeStep
	t.Cleanup(func() {
		rekeyScopeStep = oldStep
		setRekeyHoldsSlot(oldHolds)
	})
}

// waitSealClear lets a manual seal goroutine finish before the test restores the globals it reads.
func waitSealClear() {
	for i := 0; i < 300; i++ {
		pendingReapMu.Lock()
		f := sealInFlight
		pendingReapMu.Unlock()
		if !f {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestRekeyBatchAnnouncesItselfWhileItHoldsTheSlot(t *testing.T) {
	keepRekeyWaitGlobals(t)
	clearBusyInputs(t)
	ropReapReset(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	uid := "34"
	dest := t.TempDir()
	if err := markRoamSession(dest, "rekeybk-wait-announce", ropPass, uid, hex.EncodeToString(seA)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, rekeyArmedFile), []byte(uid+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	rekeyStateMu.Lock()
	oldState, oldUID, oldErr := rekeyState, rekeyStateUID, rekeyLastErr
	rekeyStateMu.Unlock()
	t.Cleanup(func() {
		rekeyStateMu.Lock()
		rekeyState, rekeyStateUID, rekeyLastErr = oldState, oldUID, oldErr
		rekeyStateMu.Unlock()
	})

	calls, sawFlag, sawSlot := 0, false, false
	rekeyScopeStep = func(_, _, _ string, _ []byte, suf string) (rekeyStep, error) {
		calls++
		sawFlag = holdsSlotNow()
		sawSlot = len(laneRW.slot) == cap(laneRW.slot)
		return rekeyStep{Suf: suf, Batched: true}, nil
	}
	rekeyOnce(dest)
	if calls != 1 {
		t.Fatalf("precondition: the scope step ran %d times, want 1", calls)
	}
	if !sawSlot {
		t.Error("precondition: the batch ran without holding the worker slot")
	}
	if !sawFlag {
		t.Error("a re-key batch holding the worker slot did not announce itself (rekeyHoldsSlot false)")
	}
	if holdsSlotNow() {
		t.Error("rekeyHoldsSlot still true after the batch released the worker slot")
	}
	if n := len(laneRW.slot); n != 0 {
		t.Fatalf("the worker slot is still held after the batch (%d)", n)
	}

	pendingReapMu.Lock()
	sealInFlight = true
	pendingReapMu.Unlock()
	calls, sawFlag = 0, false
	rekeyOnce(dest)
	if calls != 0 {
		t.Errorf("rekeyOnce ran a batch while a seal was in flight")
	}
	if holdsSlotNow() {
		t.Error("rekeyHoldsSlot set by a tick that stood down")
	}
}

// backupWaitSession is a signed-in session under its own profile name and uid, with the reap queue and the busy
// inputs cleared, for a handleBackup test.
func backupWaitSession(t *testing.T, name, uid string) string {
	t.Helper()
	_, _, _ = ropStore(t)
	ropReapReset(t)
	clearBusyInputs(t)
	keepRekeyWaitGlobals(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, name, ropPass, uid, ""); err != nil {
		t.Fatal(err)
	}
	return dest
}

func TestBackupDuringARekeyBatchSaysWhatItWaitsFor(t *testing.T) {
	dest := backupWaitSession(t, "rekeybk-wait-during", "35")
	stop := ropWorker(t, dest)
	laneRW.slot <- struct{}{} // as rekeyOnce: the slot, then the flag
	setRekeyHoldsSlot(true)
	released := false
	release := func() {
		if !released {
			released = true
			setRekeyHoldsSlot(false)
			<-laneRW.slot
		}
	}
	t.Cleanup(func() { release(); waitSealClear(); stop() })

	var got string
	logged := captureStderr(t, func() {
		got = ropReply(t, func(c net.Conn) { handleBackup(c, dest) })
	})
	if got != "OK\nWAIT rekey-batch" {
		t.Errorf("reply %q, want exactly %q", got, "OK\nWAIT rekey-batch")
	}
	if !strings.Contains(logged, "manual backup waits for the re-key batch already running") {
		t.Errorf("login.log does not say the tap waits for the re-key batch; stderr was %q", logged)
	}
	if strings.Contains(logged, "refused BUSY") {
		t.Errorf("a tap during a re-key batch was refused; stderr was %q", logged)
	}
	release()
	waitSealClear()
}

func TestBackupWithNoRekeyBatchRepliesExactlyOK(t *testing.T) {
	dest := backupWaitSession(t, "rekeybk-wait-idle", "36")
	stop := ropWorker(t, dest)
	t.Cleanup(func() { waitSealClear(); stop() })
	setRekeyHoldsSlot(false)

	var got string
	logged := captureStderr(t, func() {
		got = ropReply(t, func(c net.Conn) { handleBackup(c, dest) })
	})
	if got != "OK" {
		t.Errorf("reply %q, want exactly OK", got)
	}
	if strings.Contains(logged, "waits for the re-key") {
		t.Errorf("an idle tap was logged as waiting for a re-key batch; stderr was %q", logged)
	}
	waitSealClear()
}

func TestAUserOpBehindTheBatchStillRefuses(t *testing.T) {
	dest := backupWaitSession(t, "rekeybk-wait-userop", "37")
	setRekeyHoldsSlot(true)
	userOpWaiting.Add(1)
	t.Cleanup(func() { userOpWaiting.Add(-1) })

	var got string
	logged := captureStderr(t, func() {
		got = ropReply(t, func(c net.Conn) { handleBackup(c, dest) })
	})
	if got != "BUSY user-op-waiting" {
		t.Errorf("reply %q, want exactly BUSY user-op-waiting", got)
	}
	if !strings.Contains(logged, "manual backup refused BUSY: user-op-waiting") {
		t.Errorf("the refusal left no cause in the log; stderr was %q", logged)
	}
	if strings.Contains(logged, "waits for the re-key") {
		t.Errorf("a refused tap was logged as waiting for the re-key batch; stderr was %q", logged)
	}
}

func TestBackupWaitLine(t *testing.T) {
	if got := backupWaitLine(true); got != "WAIT rekey-batch\n" {
		t.Errorf("backupWaitLine(true) = %q, want %q", got, "WAIT rekey-batch\n")
	}
	if got := backupWaitLine(false); got != "" {
		t.Errorf("backupWaitLine(false) = %q, want empty", got)
	}
}
