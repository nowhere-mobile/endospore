package main

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261013-20, review pass 4: the reviewer's probes (FREV-A..E) as regression tests, and the sign-out and the
// periodic seal driven end to end against a store that recovers and one that stays down -- what a source pin alone
// convicted before.

// countStoreRequests puts a counting proxy in front of the fixture's store: n() is how many requests reached it.
func (f *walletFailFixture) countStoreRequests(t *testing.T) (n func() int64, restore func()) {
	t.Helper()
	target, _ := url.Parse(f.srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	var c atomic.Int64
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.Add(1)
		proxy.ServeHTTP(w, r)
	}))
	prev := os.Getenv("GATEWAY_URL")
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
	return c.Load, func() { px.Close(); t.Setenv("GATEWAY_URL", prev); capReadCache = map[string]capEntry{} }
}

// (FREV-E) syncLoop read session A (whose restore failed) and then, before its retry ran, A signed out and B signed
// in: B's generation has no proof yet. The retry is handed A's generation -- the one syncLoop captured before it read
// A's credentials -- and must refuse: before pass 4 it read the generation itself (B's), merged A's stored wallet
// into B's file and proved B's generation.
func TestAStaleSessionRetryNeverMergesIntoTheNextSession(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	genA := f.gen()
	removeWallet(f.wpath) // B signs in: a new generation, B's restore not yet landed
	genB := f.gen()
	if err := saveWallet(f.wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	n, back := f.countStoreRequests(t)
	err := retrySessionWallet(f.dest, walletFailName, walletFailPass, nil, genA, walletSignInWait)
	reads := n()
	back()
	if !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("a retry for A's generation over B's wallet = %v, want errWalletNotRestored", err)
	}
	if w, _ := loadWallet(f.wpath); w.balance() != 0 {
		t.Fatalf("B's wallet holds %d token(s) after A's stale retry: A's stored wallet was merged into it", w.balance())
	}
	if walletRestoreLanded(f.wpath, genB) || walletRestoreLanded(f.wpath, genA) {
		t.Fatal("A's stale retry wrote a proof")
	}
	if reads != 0 {
		t.Fatalf("A's stale retry made %d store request(s): it must refuse before resolving the key", reads)
	}
}

// The same refusal one level down: retryWalletRestore handed a generation the wallet has left reads nothing from
// the store and merges nothing (the check BEFORE the read; the one under the lock is TestRetryWalletRestore-
// RefusesAGenerationThatMovedWhileItWaited).
func TestARetryForAGenerationTheWalletLeftReadsNothing(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	genA := f.gen()
	removeWallet(f.wpath)
	if err := saveWallet(f.wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	n, back := f.countStoreRequests(t)
	err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, genA)
	reads := n()
	back()
	if !errors.Is(err, errWalletNotRestored) || reads != 0 {
		t.Fatalf("a retry for a generation the wallet left = %v after %d store request(s), want errWalletNotRestored "+
			"after none", err, reads)
	}
	if walletRestoreLanded(f.wpath, f.gen()) {
		t.Fatal("a retry for a generation the wallet left proved the current one")
	}
}

// (FREV-D) proveNoStoredWallet never answers nil without a proof: an unreadable generation is an error, and so is a
// proof the disk refuses.
func TestProveNoStoredWalletNeverAnswersNilWithoutAProof(t *testing.T) {
	f := walletFailSetup(t)
	if err := os.Remove(f.wpath + ".gen"); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if err := os.Mkdir(f.wpath+".gen", 0o700); err != nil {
		t.Fatal(err)
	}
	g := walletGeneration(f.wpath)
	if g != walletGenUnreadable {
		t.Fatalf("fixture: generation %q, want the unreadable one", g)
	}
	n, back := f.countStoreRequests(t)
	err := proveNoStoredWallet("s3", "brand-new-nobody", walletFailPass, f.wpath, g)
	reads := n()
	back()
	if err == nil {
		t.Fatal("proveNoStoredWallet answered nil for an unreadable generation, which no proof can be written for")
	}
	if reads != 0 {
		t.Fatalf("proveNoStoredWallet read the store %d time(s) for a generation no answer could prove", reads)
	}
	if err := markWalletRestoreLanded(f.wpath, g); err == nil || walletRestoreLanded(f.wpath, g) {
		t.Fatalf("markWalletRestoreLanded for an unreadable generation = %v: it must refuse, and prove nothing", err)
	}
	wp := filepath.Join(t.TempDir(), "made.json")
	if err := os.Mkdir(walletRestoreLandedPath(wp, "g1"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := proveNoStoredWallet("s3", "brand-new-nobody", walletFailPass, wp, "g1"); !errors.Is(err, errWalletProofNotWritten) {
		t.Fatalf("proveNoStoredWallet with the proof write refused = %v, want errWalletProofNotWritten", err)
	}
}

// (M9) a promote whose new profile's wallet head cannot be read -- a 403, a 500 -- refuses with ERR-VAULT and makes
// no vault: convicted by behaviour, not only by the call-site pin.
func TestPromoteRefusesWhenTheNewProfilesWalletHeadCannotBeRead(t *testing.T) {
	for _, status := range []int{http.StatusForbidden, http.StatusInternalServerError} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			f := walletFailSetup(t)
			const name, pass = "promo-new", "a throwaway being saved for real"
			back := f.walletReadsOf(t, name, pass, status)
			var got string
			out := captureStderr(t, func() {
				got = ropReply(t, func(c net.Conn) { promoteToStore(c, f.dest, name, pass, "77") })
			})
			back()
			if got != "ERR-VAULT" {
				t.Fatalf("a promote over an unreadable wallet head replied %q, want ERR-VAULT; stderr:\n%s", got, out)
			}
			if !strings.Contains(out, "could not be proven empty") || strings.Contains(out, "promote vault") {
				t.Fatalf("the promote went past its failed absence proof; stderr:\n%s", out)
			}
			if h := getRef("s3", headKey("s3", name, pass)); h != "" {
				t.Fatalf("the refused promote made a vault (head %s)", short(h))
			}
		})
	}
}

// (FREV-A) multi-device on, the wallet stored at the account (v2) head from before: the strict ladder restores it and
// proves the generation, and a profile with no wallet at all still proves its absence.
func TestMultiDeviceStrictLadderRestoresAndProvesAbsence(t *testing.T) {
	f := walletFailSetup(t)
	orig := unitIDPath
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	t.Cleanup(func() { unitIDPath = orig })
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	f.signIn(t) // fatal without a proof
	if w, err := loadWallet(f.wpath); err != nil || w.balance() != f.stored {
		t.Fatalf("the multi-device restore = (%v, %v), want %d tokens", w, err, f.stored)
	}
	removeWallet(f.wpath)
	roamInWallet("s3", "brand-new-nobody", walletFailPass, nil, f.wpath)
	if walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("multi-device: a profile with no wallet earned no proof")
	}
}

// (FREV-B) a store that answers 403 for a MISSING wallet head (hide-existence) gives a brand-new profile no proof, so
// it publishes no wallet: fail-closed by the rule, and the reason the device step checks that the store answers 404.
func TestAStoreThatAnswers403ForAMissingWalletGivesANewProfileNoProof(t *testing.T) {
	f := walletFailSetup(t)
	target, _ := url.Parse(f.srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ModifyResponse = func(r *http.Response) error {
		if r.StatusCode == http.StatusNotFound {
			r.StatusCode = http.StatusForbidden
		}
		return nil
	}
	px := httptest.NewServer(proxy)
	defer px.Close()
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
	removeWallet(f.wpath)
	out := captureStderr(t, func() { roamInWallet("s3", "brand-new-nobody", walletFailPass, nil, f.wpath) })
	if walletRestoreLanded(f.wpath, f.gen()) {
		t.Fatal("a 403 for a missing wallet head proved a new profile's generation: a 403 is never absence")
	}
	if !strings.Contains(out, "wallet read FAILED") {
		t.Fatalf("no FAILED line for a 403; stderr:\n%s", out)
	}
}

// GET-CREDIT-LOST and CLEAR-CREDIT-LOST answer user 0 only (handleGetRelogin's rule): a roamed session's caller reads
// NONE whatever is recorded and its CLEAR is DENIED and clears nothing; the gate reads and clears the notice.
func TestCreditLostVerbsServeOnlyUserZero(t *testing.T) {
	dest := t.TempDir()
	noteCreditLost(dest)
	notice := creditLostReply(dest)
	if !strings.HasPrefix(notice, "NOTICE ") {
		t.Fatalf("fixture: the notice reads %q", notice)
	}
	stamp := strings.TrimPrefix(notice, "NOTICE ")
	for _, c := range []struct {
		what string
		uid  int
	}{
		{"the chooser in a roamed user", 1010123},
		{"an app in another roamed user", 1110200},
		{"a peer with no uid", -1},
	} {
		asCaller(t, c.uid, 10123)
		if got := driveLogin(t, dest, "GET-CREDIT-LOST\n"); got != "NONE" {
			t.Errorf("%s: GET-CREDIT-LOST = %q, want NONE", c.what, got)
		}
		if got := driveLogin(t, dest, "CLEAR-CREDIT-LOST\n"+stamp+"\n"); got != "DENIED" {
			t.Errorf("%s: CLEAR-CREDIT-LOST = %q, want DENIED", c.what, got)
		}
		if creditLostReply(dest) != notice {
			t.Fatalf("%s: a refused CLEAR-CREDIT-LOST cleared the notice", c.what)
		}
	}
	asGate(t)
	if got := driveLogin(t, dest, "GET-CREDIT-LOST\n"); got != notice {
		t.Fatalf("the gate's GET-CREDIT-LOST = %q, want %q", got, notice)
	}
	if got := driveLogin(t, dest, "CLEAR-CREDIT-LOST\n"+stamp+"\n"); got != "OK" {
		t.Fatalf("the gate's CLEAR-CREDIT-LOST = %q, want OK", got)
	}
	if got := driveLogin(t, dest, "GET-CREDIT-LOST\n"); got != "NONE" {
		t.Fatalf("after the gate's clear GET-CREDIT-LOST = %q, want NONE", got)
	}
}

// The gate's wipe of a cold-locked session (CLAIM-COLDLOCK: the 12-hour wipe and the failed-eviction one) publishes
// nothing, so a stored session that never earned its proof and holds credit records the notice; one that did earn
// it, one holding nothing and a throwaway record none.
func TestTheGatesWipeRecordsTheNoticeForANeverRestoredSessionHoldingCredit(t *testing.T) {
	gatePeer(t, 10123)
	coldLocked := func(t *testing.T, f *walletFailFixture) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(f.dest, ".coldlock"), []byte(walletFailName+"\n15\n\n\n\n\n\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	claim := func(t *testing.T, f *walletFailFixture) string {
		t.Helper()
		if got := evictConn(t, f.dest, "CLAIM-COLDLOCK\n15\n"); got != "OK" {
			t.Fatalf("CLAIM-COLDLOCK = %q, want OK", got)
		}
		return creditLostReply(f.dest)
	}
	t.Run("never restored, holding credit: the notice", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		coldLocked(t, f)
		if got := claim(t, f); !strings.HasPrefix(got, "NOTICE ") {
			t.Fatalf("the wipe of a never-restored session holding credit recorded %q, want a notice", got)
		}
	})
	t.Run("restored: no notice", func(t *testing.T) {
		f := walletFailSetup(t)
		f.signIn(t)
		f.appendTwo(t)
		coldLocked(t, f)
		if got := claim(t, f); got != "NONE" {
			t.Fatalf("the wipe of a restored session recorded %q", got)
		}
	})
	t.Run("never restored, nothing held: no notice", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		coldLocked(t, f)
		if got := claim(t, f); got != "NONE" {
			t.Fatalf("the wipe of a session holding no credit recorded %q", got)
		}
	})
	t.Run("a throwaway: no notice", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		markLocalSession(f.dest)
		coldLocked(t, f)
		if got := claim(t, f); got != "NONE" {
			t.Fatalf("the wipe of a throwaway recorded %q", got)
		}
	})
}

// sessionState resets the seal/logoff globals a driven sign-out or periodic seal touches, around the test.
func sessionState(t *testing.T) {
	t.Helper()
	ropReapReset(t)
	fw := logoffFlushWait
	logoffFlushWait = 100 * time.Millisecond
	started := lastSealStartedAt.Load()
	reset := func() {
		pendingReapMu.Lock()
		sealInFlight, sealUnstuck, sealFail, sealFailWhy, sealPartial, sealRunKind = false, false, false, "", "", ""
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(func() { reset(); logoffFlushWait = fw; lastSealStartedAt.Store(started) })
}

// signOut drives a real LOGOUT of the fixture's session as uid against a stand-in roamd whose cutoff, sweep and seal
// land, and returns once the reap is queued (the notice, when there is one, is recorded before it).
func (f *walletFailFixture) signOut(t *testing.T, uid string) string {
	t.Helper()
	sessionState(t)
	// NWP-20261112-14: the fixture's gateway answers /quote and /lease, so the landed arm's full-footprint renewal
	// would spend from the wallet these cases count. It has its own tests (logout_renew_test.go).
	oldRenew := logoutRenewStep
	logoutRenewStep = func(string, string, string, []byte, string, string) {}
	t.Cleanup(func() { logoutRenewStep = oldRenew })
	if err := markRoamSession(f.dest, walletFailName, walletFailPass, uid, ""); err != nil {
		t.Fatal(err)
	}
	cutoffWorker(t, f.dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": "OK"}, nil)
	return captureStderr(t, func() {
		if got := ropReply(t, func(c net.Conn) { handleLogout(c, f.dest) }); got != "OK" {
			t.Fatalf("LOGOUT replied %q", got)
		}
		deadline := time.Now().Add(30 * time.Second)
		for {
			pendingReapMu.Lock()
			reap := pendingReapUID
			pendingReapMu.Unlock()
			if reap == uid {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("the sign-out never queued its reap")
			}
			time.Sleep(50 * time.Millisecond)
		}
		time.Sleep(700 * time.Millisecond)
		ackReapAction("SWITCH", uid)
		ackReapAction("REAP", uid)
	})
}

// (M10, M17) a normal sign-out of a session whose restore never landed, driven through handleLogout. The store is back:
// its retry lands, so the generation is proven, the stored wallet is merged in, the sign-out's seal publishes all of
// it, and no notice is recorded. The store stays down: nothing is proven or published, and the gate's notice is
// recorded before the switch.
func TestSignOutOfANeverRestoredSession(t *testing.T) {
	t.Run("the store is back: the retry lands and the wallet publishes", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		flushes := flushSeamCalls.Load()
		out := f.signOut(t, "83")
		if flushSeamCalls.Load() <= flushes {
			t.Fatal("the sign-out's flush did not reach the binary-wide stub (flush_seam_test.go)")
		}
		// NWP-20261017-02: the landed sign-out then publishes the wallet by value and drops the file, on a goroutine of
		// its own. That the retry landed is what lets it: a generation without the proof would keep the file.
		deadline := time.Now().Add(15 * time.Second)
		for {
			if _, err := os.Stat(f.wpath); os.IsNotExist(err) {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("the sign-out did not retry the wallet read and drop the wallet; stderr:\n%s", out)
			}
			time.Sleep(20 * time.Millisecond)
		}
		f.assertStored(t, f.stored+2, "the sign-out's by-value publish after a landed retry")
		f.assertStored(t, f.stored+2, "the sign-out's seal after a landed retry")
		if got := creditLostReply(f.dest); got != "NONE" {
			t.Fatalf("a sign-out whose retry landed recorded the notice (%q)", got)
		}
	})
	t.Run("the store stays down: nothing publishes and the gate is told", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		back := f.walletFailBreakWalletOnly(t)
		out := f.signOut(t, "84")
		foldingSeal(t, walletFailName, walletFailPass, f.dk)
		back()
		if walletRestoreLanded(f.wpath, f.gen()) {
			t.Fatal("a sign-out whose retry failed proved the generation")
		}
		f.assertStored(t, f.stored, "the sign-out's seal with the store down")
		if got := creditLostReply(f.dest); !strings.HasPrefix(got, "NOTICE ") {
			t.Fatalf("a sign-out that lost credit recorded no notice (%q); stderr:\n%s", got, out)
		}
	})
}

// periodicCycle runs ONE cycle of the real syncLoop for the fixture's session as uid: the stand-in roamd answers its
// seal SKIP-REAPING, which sends the loop straight back to its sleep, and the second sleep ends the loop.
func (f *walletFailFixture) periodicCycle(t *testing.T, uid string) string {
	t.Helper()
	sessionState(t)
	resetSealSignals() // NWP-20261202-10: no landed save, so the change test answers nobase and runs no probe
	if err := markRoamSession(f.dest, walletFailName, walletFailPass, uid, ""); err != nil {
		t.Fatal(err)
	}
	cutoffWorker(t, f.dest, map[string]string{"out": "SKIP-REAPING"}, nil)
	old := syncLoopSleep
	t.Cleanup(func() { syncLoopSleep = old })
	var sleeps atomic.Int32
	syncLoopSleep = func(time.Duration) {
		if sleeps.Add(1) > 1 {
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
			t.Fatal("one periodic cycle did not finish within 60 s")
		}
	})
}

// (M11) the periodic seal's retry, driven through the real syncLoop: with the store back it proves the generation and
// merges the stored wallet in, so the seal's fold publishes all of it; with the store still down nothing is proven
// and nothing publishes.
func TestPeriodicSealRetriesTheWalletRead(t *testing.T) {
	t.Run("the store is back", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		out := f.periodicCycle(t, "85")
		if strings.Contains(out, "periodic seal deferred") {
			t.Fatalf("fixture: the cycle was deferred, so it proves nothing; stderr:\n%s", out)
		}
		if walletNotRestored(f.wpath, f.gen()) {
			t.Fatalf("the periodic seal did not retry the wallet read (no proof); stderr:\n%s", out)
		}
		if w, _ := loadWallet(f.wpath); w.balance() != f.stored+2 {
			t.Fatalf("after the periodic retry the wallet holds %d, want %d", w.balance(), f.stored+2)
		}
		foldingSeal(t, walletFailName, walletFailPass, f.dk)
		f.assertStored(t, f.stored+2, "the periodic seal after a landed retry")
	})
	t.Run("the store stays down", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		back := f.walletFailBreakWalletOnly(t)
		out := f.periodicCycle(t, "86")
		foldingSeal(t, walletFailName, walletFailPass, f.dk)
		back()
		if strings.Contains(out, "periodic seal deferred") {
			t.Fatalf("fixture: the cycle was deferred, so it proves nothing; stderr:\n%s", out)
		}
		if !strings.Contains(out, "the retried restore read FAILED too") {
			t.Fatalf("the periodic seal did not retry the read; stderr:\n%s", out)
		}
		if walletRestoreLanded(f.wpath, f.gen()) {
			t.Fatal("a periodic retry against a store still down proved the generation")
		}
		f.assertStored(t, f.stored, "the periodic seal with the store down")
	})
}
