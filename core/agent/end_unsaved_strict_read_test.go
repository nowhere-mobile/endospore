package main

import (
	"bytes"
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261201-27 (h60 #16, the rule of 2026-10-22 #4): END-UNSAVED and RESTART-UNSAVED read the stored wallet
// strictly, one retry in one bound, before their publish. Unreadable, they publish no #wallet, keep the file and answer
// OK-CREDIT-LOST, with the notice recorded before the switch. Run with --mutate by test-end-unsaved-strict-read.sh.

// strictReadSeam replaces the read's single try and its bound for one test.
func strictReadSeam(t *testing.T, wait time.Duration, try func(name, pass string, dk []byte) bool) {
	t.Helper()
	oldWait, oldTry := endStoredWalletReadWait, endStoredWalletReadTry
	endStoredWalletReadWait, endStoredWalletReadTry = wait, try
	t.Cleanup(func() { endStoredWalletReadWait, endStoredWalletReadTry = oldWait, oldTry })
}

// Two failed tries are unreadable, and a third is never made.
func TestEndUnsavedStrictRead_TwoFailedTriesAreUnreadable(t *testing.T) {
	var tries atomic.Int32
	strictReadSeam(t, 5*time.Second, func(string, string, []byte) bool { tries.Add(1); return false })
	if endStoredWalletRead("strictread-two", "pw", strictReadKey) {
		t.Fatal("a read that failed twice was reported readable")
	}
	if n := tries.Load(); n != 2 {
		t.Fatalf("the read made %d tries, want 2", n)
	}
}

// The retry that lands is readable.
func TestEndUnsavedStrictRead_ASecondTryThatLandsIsReadable(t *testing.T) {
	var tries atomic.Int32
	strictReadSeam(t, 5*time.Second, func(string, string, []byte) bool { return tries.Add(1) == 2 })
	if !endStoredWalletRead("strictread-second", "pw", strictReadKey) {
		t.Fatal("a read whose retry landed was reported unreadable")
	}
	if n := tries.Load(); n != 2 {
		t.Fatalf("the read made %d tries, want 2", n)
	}
}

// A read that does not answer inside the bound is unreadable, whatever it answers later.
func TestEndUnsavedStrictRead_TheBoundEndsAStuckRead(t *testing.T) {
	released, finished := make(chan struct{}), make(chan struct{})
	strictReadSeam(t, 50*time.Millisecond, func(string, string, []byte) bool {
		defer close(finished)
		select {
		case <-released:
		case <-time.After(2 * time.Second):
		}
		return true
	})
	readable := endStoredWalletRead("strictread-bound", "pw", strictReadKey)
	close(released)
	<-finished // the read is done with the seam before the cleanup puts it back
	if readable {
		t.Fatal("a read past its bound was reported readable")
	}
}

// The real publish over a stored wallet that cannot be read: nothing is published and the file stays.
func TestEndUnsavedStrictRead_PublishesNothingOverAnUnreadableCopy(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	before := logoutRead(t, f.wpath)
	back := f.walletFailBreakWalletOnly(t)
	err := publishWalletBeforeDiscard(f.dest, walletFailName, walletFailPass, nil, f.gen())
	back()
	if !errors.Is(err, errEndWalletUnreadable) {
		t.Fatalf("publish over an unreadable stored wallet = %v, want errEndWalletUnreadable", err)
	}
	f.assertStored(t, f.stored, "after a publish over an unreadable copy")
	if !bytes.Equal(logoutRead(t, f.wpath), before) {
		t.Fatal("the wallet file changed")
	}
}

// A real END-UNSAVED whose stored wallet cannot be read ends and warns, records the notice, and keeps the file.
func TestEndUnsavedStrictRead_EndUnsavedWarnsAndKeepsTheFile(t *testing.T) {
	wf := walletFailSetup(t)
	wf.session(t)
	f := euSetupAs(t, wf.dest, walletFailName, walletFailPass)
	endUnsavedWallet = publishWalletBeforeDiscard // the real save; euSetupAs's recording drop seam stays
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	before := logoutRead(t, wf.wpath)
	back := wf.walletFailBreakWalletOnly(t)
	var reply string
	log := captureStderr(t, func() { reply = f.end() })
	back()
	if reply != endUnsavedCreditLost {
		t.Fatalf("END-UNSAVED = %q, want %s; stderr:\n%s", reply, endUnsavedCreditLost, log)
	}
	if got := creditLostReply(wf.dest); !strings.HasPrefix(got, "NOTICE ") {
		t.Errorf("the gate's notice = %q, want NOTICE: it must be recorded before the switch", got)
	}
	if strings.Contains(log, "the saved wallet now leaves the state tmpfs") {
		t.Errorf("the unsaved wallet was handed to the drop step; stderr:\n%s", log)
	}
	f.noDrop(t, "an unreadable stored wallet")
	if d := f.dropCalls(); len(d) != 0 {
		t.Errorf("the drop seam ran %d time(s)", len(d))
	}
	wf.assertStored(t, wf.stored, "after END-UNSAVED over an unreadable copy")
	if !bytes.Equal(logoutRead(t, wf.wpath), before) {
		t.Error("the wallet file changed")
	}
}

// RESTART-UNSAVED takes the same arm: a warned restart, not ERR-WALLET, with its notice left for after the boot.
func TestEndUnsavedStrictRead_RestartUnsavedWarns(t *testing.T) {
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	f.walletEr = errEndWalletUnreadable
	if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	got := ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) })
	if got != endUnsavedCreditLost {
		t.Fatalf("RESTART-UNSAVED = %q, want %s", got, endUnsavedCreditLost)
	}
	if _, ok := noticeOnDisk(t); !ok {
		t.Fatal("a restart that loses credit left no notice for the gate after the boot")
	}
}
