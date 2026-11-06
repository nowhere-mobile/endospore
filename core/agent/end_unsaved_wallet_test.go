package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261021-01: END-UNSAVED on a real wallet. euSetupAs puts the END-UNSAVED fixture on walletFailSetup's store, so
// the REAL handler runs with the real wallet save and the REAL sealLogoutWalletAndDrop behind the seam: the session
// signs in at a proven generation, claims two tokens (12 in the file), and is ended without saving.

type euWalletRun struct {
	f       *walletFailFixture
	reply   string
	log     string
	dropped bool
	derr    error
}

// endUnsavedOnAWallet runs END-UNSAVED over a signed-in funded session and waits for the drop step to finish. The
// step's goroutine writes dropped/derr and then closes done, so reading them after done is ordered.
func endUnsavedOnAWallet(t *testing.T, captured func(wpath string)) *euWalletRun {
	t.Helper()
	wf := walletFailSetup(t)
	wf.session(t)
	if captured != nil {
		logoutHooks(t, func() { captured(wf.wpath) }, nil)
	}
	os.WriteFile(wf.wpath+".tmp", []byte("stray"), 0o600)
	os.WriteFile(walletPrevPath(wf.wpath), []byte("prev"), 0o600)
	f := euSetupAs(t, wf.dest, walletFailName, walletFailPass)
	endUnsavedWallet = publishWalletBeforeDiscard // the real save
	r := &euWalletRun{f: wf}
	done := make(chan struct{})
	endUnsavedWalletDrop = func(d, n, p string, se []byte, g, u string) (bool, error) {
		defer close(done)
		r.dropped, r.derr = sealLogoutWalletAndDrop(d, n, p, se, g, u)
		return r.dropped, r.derr
	}
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	r.log = captureStderr(t, func() {
		r.reply = f.end()
		select {
		case <-done:
		case <-time.After(15 * time.Second):
			t.Error("the drop step never finished")
		}
	})
	return r
}

func TestEndUnsaved_TheSavedWalletIsPublishedAndDropped(t *testing.T) {
	r := endUnsavedOnAWallet(t, nil)
	if r.reply != "OK" {
		t.Fatalf("got %q, want OK; stderr:\n%s", r.reply, r.log)
	}
	if r.derr != nil || !r.dropped {
		t.Fatalf("dropped=%v err=%v; stderr:\n%s", r.dropped, r.derr, r.log)
	}
	assertGone(t, r.f.wpath, r.f.wpath+".tmp", walletPrevPath(r.f.wpath))
	r.f.assertStored(t, 12, "after the END-UNSAVED")
	if want := "[logind] logout wallet user " + euUID + ": published and dropped"; !strings.Contains(r.log, want) {
		t.Errorf("no %q line; stderr:\n%s", want, r.log)
	}
	for _, leak := range []string{walletFailName, walletFailPass} {
		for _, line := range strings.Split(r.log, "\n") {
			if (strings.Contains(line, "logout wallet") || strings.Contains(line, "NWP-20261021-01")) && strings.Contains(line, leak) {
				t.Errorf("a wallet log line leaks %q: %s", leak, line)
			}
		}
	}
}

// A sign-in replaced the wallet between the commit and the step: the arriving file is neither published nor dropped.
func TestEndUnsaved_ASignInInTheGapKeepsTheArrivingWallet(t *testing.T) {
	var arrived []byte
	var gapErr error
	r := endUnsavedOnAWallet(t, func(wpath string) { // runs in the drop goroutine, so it never calls t.*
		removeWallet(wpath)
		for i := 0; i < 2 && gapErr == nil; i++ {
			gapErr = appendTokens(wpath, newBlindTokens())
		}
		markWalletRestoreLanded(wpath, walletGeneration(wpath))
		arrived, _ = os.ReadFile(wpath)
	})
	if r.reply != "OK" {
		t.Fatalf("got %q, want OK; stderr:\n%s", r.reply, r.log)
	}
	if gapErr != nil {
		t.Fatal(gapErr)
	}
	if r.derr != nil || r.dropped {
		t.Fatalf("dropped=%v err=%v -- the arriving wallet must be kept; stderr:\n%s", r.dropped, r.derr, r.log)
	}
	if got := logoutRead(t, r.f.wpath); len(arrived) == 0 || !bytes.Equal(got, arrived) {
		t.Error("the arriving wallet file was published away or touched")
	}
	r.f.assertStored(t, 12, "the departed session's tokens after another sign-in arrived")
}
