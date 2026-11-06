package main

import (
	"bytes"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261017-02: a sign-out that landed publishes the wallet BY VALUE and then drops wallet.json while the file
// still holds those bytes at the captured generation. Every probe below runs on walletFailSetup's cap-mode store:
// the profile stores 10 tokens, a session signs in (restore proof), appends 2, and signs out.

const logoutUID = "11"

// logoutStep runs the helper the way handleLogout's goroutine does and returns what it logged.
func (f *walletFailFixture) logoutStep(t *testing.T, gen string) (dropped bool, err error, log string) {
	t.Helper()
	log = captureStderr(t, func() {
		dropped, err = sealLogoutWalletAndDrop(f.dest, walletFailName, walletFailPass, nil, gen, logoutUID)
	})
	return
}

// session is a signed-in session with 12 tokens in its file.
func (f *walletFailFixture) session(t *testing.T) {
	t.Helper()
	f.signIn(t)
	f.appendTwo(t)
}

func logoutHooks(t *testing.T, captured, published func()) {
	t.Helper()
	logoutWalletCaptured, logoutWalletPublished = captured, published
	t.Cleanup(func() { logoutWalletCaptured, logoutWalletPublished = nil, nil })
}

func logoutRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func assertGone(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s is still in the state dir (stat err %v)", p, err)
		}
	}
}

// (a) A landed sign-out publishes its 12 tokens and the file leaves the state dir; the old generation's proof stays.
func TestLogoutWallet_PublishesThenDrops(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen := f.gen()
	proof := walletRestoreLandedPath(f.wpath, gen)
	os.WriteFile(f.wpath+".tmp", []byte("stray"), 0o600)
	os.WriteFile(walletPrevPath(f.wpath), []byte("prev"), 0o600)
	dropped, err, log := f.logoutStep(t, gen)
	if err != nil || !dropped {
		t.Fatalf("dropped=%v err=%v; stderr:\n%s", dropped, err, log)
	}
	f.assertStored(t, 12, "after the sign-out")
	assertGone(t, f.wpath, f.wpath+".tmp", walletPrevPath(f.wpath))
	if f.gen() == gen {
		t.Error("the generation did not move on with the drop")
	}
	if _, serr := os.Stat(proof); serr != nil {
		t.Errorf("the departed generation's restore proof was removed: %v", serr)
	}
	if want := "[logind] logout wallet user " + logoutUID + ": published and dropped"; !strings.Contains(log, want) {
		t.Errorf("no %q line; stderr:\n%s", want, log)
	}
	for _, leak := range []string{walletFailName, walletFailPass} {
		if strings.Contains(log, leak) {
			t.Errorf("the log leaks %q:\n%s", leak, log)
		}
	}
}

// (b) A publish that fails keeps the file, byte for byte, at the same generation.
func TestLogoutWallet_APublishErrorKeepsTheFile(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen, before := f.gen(), logoutRead(t, f.wpath)
	var back func()
	logoutHooks(t, func() { back = walletFailBreak(t) }, nil)
	dropped, err, log := f.logoutStep(t, gen)
	if back != nil {
		back()
	}
	if err == nil || dropped {
		t.Fatalf("dropped=%v err=%v -- a failed publish must keep the file and say so", dropped, err)
	}
	if !bytes.Equal(logoutRead(t, f.wpath), before) {
		t.Error("the wallet file changed after a failed publish")
	}
	if f.gen() != gen {
		t.Error("the generation moved on a failed publish")
	}
	if !strings.Contains(log, "logout wallet user "+logoutUID+": NOT published, kept (") {
		t.Errorf("no NOT published line; stderr:\n%s", log)
	}
	f.assertStored(t, 10, "after the failed publish")
}

// (c) A generation with no restore proof keeps the file and publishes nothing.
func TestLogoutWallet_NoRestoreProofKeepsTheFile(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	gen, before := f.gen(), logoutRead(t, f.wpath)
	dropped, err, _ := f.logoutStep(t, gen)
	if err != errWalletNotRestored || dropped {
		t.Fatalf("dropped=%v err=%v, want errWalletNotRestored and no drop", dropped, err)
	}
	if !bytes.Equal(logoutRead(t, f.wpath), before) {
		t.Error("the wallet file changed")
	}
	f.assertStored(t, 10, "a sign-out whose restore never landed")
}

// (d) A sign-in of ANOTHER profile between the capture and the publish: the departed profile's head gets ITS tokens,
// and the arriving profile's file is neither published nor dropped.
func TestLogoutWallet_ASignInInTheGapDoesNotPublishTheArrivingWallet(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen := f.gen()
	var other []byte
	logoutHooks(t, func() {
		removeWallet(f.wpath)
		f.appendTwo(t)
		f.appendTwo(t) // another profile's 4 tokens
		provenWallet(t, f.wpath)
		other = logoutRead(t, f.wpath)
	}, nil)
	dropped, err, log := f.logoutStep(t, gen)
	if err != nil || dropped {
		t.Fatalf("dropped=%v err=%v; stderr:\n%s", dropped, err, log)
	}
	f.assertStored(t, 12, "the departed profile after another profile signed in")
	if !bytes.Equal(logoutRead(t, f.wpath), other) {
		t.Error("the arriving profile's wallet file was touched")
	}
}

// (e) The file gained a token after the publish, at the same generation: it holds more than was published.
func TestLogoutWallet_AChangedFileIsKept(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen := f.gen()
	logoutHooks(t, nil, func() { f.appendTwo(t) })
	dropped, err, log := f.logoutStep(t, gen)
	if err != nil || dropped {
		t.Fatalf("dropped=%v err=%v", dropped, err)
	}
	if _, serr := os.Stat(f.wpath); serr != nil {
		t.Errorf("the changed wallet was dropped: %v", serr)
	}
	if !strings.Contains(log, "published, kept (the wallet changed since it was published)") {
		t.Errorf("stderr:\n%s", log)
	}
}

// (f) The generation moved on and the identical bytes came back: another hand's file, kept.
func TestLogoutWallet_AMovedGenerationIsKept(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen, same := f.gen(), logoutRead(t, f.wpath)
	logoutHooks(t, nil, func() {
		if err := bumpWalletGeneration(f.wpath); err != nil {
			t.Error(err)
		}
		if err := os.WriteFile(f.wpath, same, 0o600); err != nil {
			t.Error(err)
		}
	})
	dropped, err, log := f.logoutStep(t, gen)
	if err != nil || dropped {
		t.Fatalf("dropped=%v err=%v", dropped, err)
	}
	if !bytes.Equal(logoutRead(t, f.wpath), same) {
		t.Error("the wallet file was removed or changed")
	}
	if !strings.Contains(log, "published, kept (the wallet changed hands)") {
		t.Errorf("stderr:\n%s", log)
	}
}

// A removal that fails leaves the bearer tokens in the tmpfs: never reported as dropped.
func TestLogoutWallet_AFailedRemovalIsNotDropped(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen := f.gen()
	walletRemoveFile = func(p string) error {
		if p == f.wpath {
			return os.ErrPermission
		}
		return os.Remove(p)
	}
	t.Cleanup(func() { walletRemoveFile = os.Remove })
	dropped, err, log := f.logoutStep(t, gen)
	if err != nil || dropped {
		t.Fatalf("dropped=%v err=%v; stderr:\n%s", dropped, err, log)
	}
	if _, serr := os.Stat(f.wpath); serr != nil {
		t.Errorf("the wallet is gone: %v", serr)
	}
	if !strings.Contains(log, "published, kept (could not remove wallet.json)") || strings.Contains(log, "published and dropped") {
		t.Errorf("stderr:\n%s", log)
	}
}

// (g) No wallet file: nothing to publish or drop.
func TestLogoutWallet_AbsentWalletIsANoOp(t *testing.T) {
	f := walletFailSetup(t)
	dropped, err, _ := f.logoutStep(t, f.gen())
	if dropped || err != nil {
		t.Fatalf("dropped=%v err=%v", dropped, err)
	}
	f.assertStored(t, 10, "no wallet file")
}

// logoutWiring drives LOGOUT through the cutoff harness with the step stubbed and returns what the stub saw.
type logoutCall struct {
	dest, name, uid, gen string
	reapQueued           string
}

func logoutWiring(t *testing.T, uid, out string) (calls []logoutCall, dest, wantGen string) {
	t.Helper()
	dest = cutoffSession(t, uid)
	if err := bumpWalletGeneration(walletPathFor(dest)); err != nil {
		t.Fatal(err)
	}
	wantGen = walletGeneration(walletPathFor(dest))
	var mu sync.Mutex
	old := logoutWalletStep
	logoutWalletStep = func(d, name, pass string, se []byte, gen, u string) (bool, error) {
		pendingReapMu.Lock()
		q := pendingReapUID
		pendingReapMu.Unlock()
		mu.Lock()
		calls = append(calls, logoutCall{d, name, u, gen, q})
		mu.Unlock()
		return false, nil
	}
	t.Cleanup(func() { logoutWalletStep = old })
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": out, "cutoffwake": "WAKE OK 0"}, nil)
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	if out == "OK" {
		deadline := time.Now().Add(15 * time.Second)
		for {
			mu.Lock()
			n := len(calls)
			mu.Unlock()
			if n > 0 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("the wallet step never ran after a landed sign-out")
			}
			time.Sleep(20 * time.Millisecond)
		}
		ackReapAction("SWITCH", uid)
		ackReapAction("REAP", uid)
	} else {
		logoffDone(t, uid, 20*time.Second)
	}
	time.Sleep(300 * time.Millisecond) // room for a call that must NOT come
	mu.Lock()
	defer mu.Unlock()
	return append([]logoutCall(nil), calls...), dest, wantGen
}

// (h) WIRING: a landed sign-out runs the step once, after the reap is queued, with the generation read at the top; a
// failed one never does (its session stays and its wallet is live).
func TestLogoutWallet_RunsOnceAfterALandedSignOut(t *testing.T) {
	calls, dest, gen := logoutWiring(t, "11", "OK")
	if len(calls) != 1 {
		t.Fatalf("the wallet step ran %d times, want 1", len(calls))
	}
	c := calls[0]
	if c.dest != dest || c.uid != "11" || c.name != "alice" || c.gen != gen {
		t.Errorf("the step got %+v, want dest %s uid 11 name alice gen %q", c, dest, gen)
	}
	if c.reapQueued != "11" {
		t.Errorf("the step ran with the reap queued for %q, want 11 -- it must come after the reap is queued", c.reapQueued)
	}
}

func TestLogoutWallet_NeverRunsWhenTheSealFailed(t *testing.T) {
	calls, _, _ := logoutWiring(t, "12", "ERR-PUSH 1")
	if len(calls) != 0 {
		t.Fatalf("the wallet step ran after a failed seal: %+v -- that session stays signed in", calls)
	}
}
