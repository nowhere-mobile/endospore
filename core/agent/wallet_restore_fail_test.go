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
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261013-20: no publish may ever replace the stored wallet with a copy missing tokens the store holds. A wallet
// publish for generation G is refused unless G carries a RESTORE PROOF, written only when G's restore landed or a
// strict read proved there is no stored wallet. Before this the roam-in's bare recover() turned a panicking read into
// "no wallet": the session ran with no wallet file, and a claim drained into it published a wallet holding only the
// new tokens over the stored one -- bearer credit gone. Every probe below ends in the same assertion: the stored
// wallet still holds its 10 tokens, never the session's 2.

const walletFailName, walletFailPass = "walletfail", "a wallet read that fails"

type walletFailFixture struct {
	srv    *httptest.Server
	objs   map[string][]byte
	objsMu *sync.Mutex
	dest   string
	wpath  string
	dk     []byte
	stored int
}

// walletFailSetup stores a 10-token wallet durably at the profile's head in a cap-mode mock store, gives the profile
// a (legacy, bare) data head so resolveDK opens it, then removes the local file the way a new sign-in does. Reads of
// the store work until walletFailBreak. The fixture's own first publish runs as a session whose restore landed: it is
// given its generation's proof, as a real sign-in's roamInWallet would.
func walletFailSetup(t *testing.T) *walletFailFixture {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil // another test may have written the same content; postBlob would then skip it
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	dest := t.TempDir()
	wpath := walletPathFor(dest)
	t.Setenv("NOWHERE_STATE", dest)
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	markWalletRestoreLanded(wpath, walletGeneration(wpath))
	dk := deriveKey(walletFailName, walletFailPass)
	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, dk, wpath); err != nil {
		t.Fatalf("fixture: sealWalletDurable: %v", err)
	}
	foldingSeal(t, walletFailName, walletFailPass, dk) // the data head; it folds the same 10 tokens
	if got := resolveDK("s3", walletFailName, walletFailPass, nil); string(got) != string(dk) {
		t.Fatal("fixture: the profile's key does not resolve from its head")
	}
	removeWallet(wpath)
	f := &walletFailFixture{srv: srv, objs: objs, objsMu: mu, dest: dest, wpath: wpath, dk: dk, stored: 10}
	if got := f.storedBalance(t); got != f.stored {
		t.Fatalf("fixture: stored wallet holds %d, want %d", got, f.stored)
	}
	return f
}

// walletFailBreak points the store at a server that is gone: every read fails after the retries.
func walletFailBreak(t *testing.T) (restore func()) {
	t.Helper()
	dead := httptest.NewServer(http.NotFoundHandler())
	url := dead.URL
	dead.Close()
	prev := os.Getenv("GATEWAY_URL")
	t.Setenv("GATEWAY_URL", url)
	capReadCache = map[string]capEntry{}
	return func() { t.Setenv("GATEWAY_URL", prev); capReadCache = map[string]capEntry{} }
}

// walletFailWalletReads keeps the store up but answers every read of the profile's #wallet head with status, so the
// key resolves and only the wallet read is hit -- what a claim against a live gateway meets (500), or a store that
// hides existence behind a 403 (P3).
func (f *walletFailFixture) walletFailWalletReads(t *testing.T, status int) (restore func()) {
	t.Helper()
	return f.walletReadsOf(t, walletFailName, walletFailPass, status)
}

// walletReadsOf is walletFailWalletReads for any profile's #wallet head.
func (f *walletFailFixture) walletReadsOf(t *testing.T, name, pass string, status int) (restore func()) {
	t.Helper()
	whk := walletHeadKey("s3", name, pass)
	target, _ := url.Parse(f.srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" && strings.Contains(r.URL.Query().Get("k"), whk) {
			w.WriteHeader(status)
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	prev := os.Getenv("GATEWAY_URL")
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
	return func() { px.Close(); t.Setenv("GATEWAY_URL", prev); capReadCache = map[string]capEntry{} }
}

func (f *walletFailFixture) walletFailBreakWalletOnly(t *testing.T) (restore func()) {
	return f.walletFailWalletReads(t, http.StatusInternalServerError)
}

func (f *walletFailFixture) storedBalance(t *testing.T) int {
	t.Helper()
	return foldedBalance(t, walletFailName, walletFailPass, f.dk)
}

func (f *walletFailFixture) gen() string { return walletGeneration(f.wpath) }

// failedRoamIn runs the roam-in's wallet block itself against a dead store and returns what it logged.
func (f *walletFailFixture) failedRoamIn(t *testing.T) string {
	t.Helper()
	back := walletFailBreak(t)
	defer back()
	return captureStderr(t, func() { roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath) })
}

// signIn is the next sign-in of the same profile with a working store: a new generation and a restore that lands.
func (f *walletFailFixture) signIn(t *testing.T) {
	t.Helper()
	removeWallet(f.wpath)
	roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath)
	if walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("fixture: a sign-in against a working store left its generation without a restore proof")
	}
}

// appendTwo is the session's claim: two blind tokens appended to its local wallet.
func (f *walletFailFixture) appendTwo(t *testing.T) {
	t.Helper()
	if err := appendTokens(f.wpath, newBlindTokens()); err != nil {
		t.Fatal(err)
	}
}

// assertStored is the invariant every probe ends on.
func (f *walletFailFixture) assertStored(t *testing.T, want int, what string) {
	t.Helper()
	if got := f.storedBalance(t); got != want {
		t.Fatalf("%s: the stored wallet holds %d tokens, want %d", what, got, want)
	}
}

// provenWallet gives walletPath's current generation its restore proof: the test models a signed-in session whose
// restore landed, which roamInWallet would have proven. Without it every wallet publish is refused.
func provenWallet(t *testing.T, walletPath string) {
	t.Helper()
	markWalletRestoreLanded(walletPath, walletGeneration(walletPath))
}

func newBlindTokens() []BlindToken {
	return []BlindToken{{Msg: "m1", Sig: "s1"}, {Msg: "m2", Sig: "s2"}}
}

// (1) THE BLOCK FAILS CLOSED: with the store dead from the first read -- resolveDK's head read included, which runs
// before any wallet read -- no proof is written, and one FAILED line names neither the profile nor a key.
func TestRoamInWalletBlockFailsClosedOnADeadStore(t *testing.T) {
	f := walletFailSetup(t)
	out := f.failedRoamIn(t)
	if !walletNotRestored(f.wpath, f.gen()) {
		t.Fatalf("the roam-in's wallet block against a dead store left a restore proof; stderr:\n%s", out)
	}
	if _, err := os.Stat(walletRestoreLandedPath(f.wpath, f.gen())); !os.IsNotExist(err) {
		t.Fatalf("a proof file exists after a failed read (stat err %v)", err)
	}
	i := strings.Index(out, "[logind] roam-in: wallet read FAILED")
	if i < 0 || !strings.Contains(out, "will not publish a wallet") {
		t.Fatalf("no FAILED line on a failed wallet read; stderr:\n%s", out)
	}
	for _, leak := range []string{walletFailName, walletFailPass, "X-Amz-", "ref/"} {
		if strings.Contains(out[i:], leak) {
			t.Fatalf("the FAILED line leaks %q:\n%s", leak, out)
		}
	}
	if _, err := os.Stat(f.wpath); !os.IsNotExist(err) {
		t.Fatalf("a failed read left a wallet file (stat err %v)", err)
	}
}

// Provable absence is not a failure: an unknown profile has no wallet head (a definite not-found on every rung), so
// its generation is proven and no FAILED line is written.
func TestRoamInWalletNoHeadIsProvenAbsence(t *testing.T) {
	f := walletFailSetup(t)
	out := captureStderr(t, func() { roamInWallet("s3", "nobody-here", walletFailPass, nil, f.wpath) })
	if walletNotRestored(f.wpath, f.gen()) || strings.Contains(out, "FAILED") {
		t.Fatalf("an absent wallet did not prove the generation (proof %v); stderr:\n%s", walletRestoreLanded(f.wpath, f.gen()), out)
	}
}

// A landed restore writes the proof, on disk where the seal worker sees it, and restores the stored wallet.
func TestRoamInWalletLandsAndProves(t *testing.T) {
	f := walletFailSetup(t)
	out := captureStderr(t, func() { roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath) })
	if walletNotRestored(f.wpath, f.gen()) || strings.Contains(out, "FAILED") {
		t.Fatalf("a normal restore left no proof; stderr:\n%s", out)
	}
	if b, err := os.ReadFile(walletRestoreLandedPath(f.wpath, f.gen())); err != nil || string(b) != walletLandedProofHead+f.gen() {
		t.Fatalf("the proof is not on disk as this generation's (%q, %v): the seal worker could not see it", b, err)
	}
	if w, err := loadWallet(f.wpath); err != nil || w.balance() != f.stored {
		t.Fatalf("restored wallet = (%v, %v), want %d tokens", w, err, f.stored)
	}
}

// (6) A panic in the step after a landed restore (the plan carry) is not a failed read: no FAILED line, and the
// proof stands, so the session publishes its (complete) wallet.
func TestRoamInWalletAPanicAfterALandedRestoreIsNotAFailedRead(t *testing.T) {
	f := walletFailSetup(t)
	old := roamInPlanCarry
	roamInPlanCarry = func(string, string, string, []byte, string, func() bool) { panic("the plan carry broke") }
	defer func() { roamInPlanCarry = old }()
	out := captureStderr(t, func() { roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath) })
	if strings.Contains(out, "wallet read FAILED") || strings.Contains(out, "will not publish") {
		t.Fatalf("a panic after a landed restore was reported as a failed read; stderr:\n%s", out)
	}
	if !strings.Contains(out, "the wallet restore landed; a later step") {
		t.Fatalf("the later step's failure was not logged; stderr:\n%s", out)
	}
	if walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("a panic after a landed restore withdrew the proof")
	}
}

// (pass 4) A proof the disk refuses is FORFEITED: an error, no proof held anywhere -- in this process or another --
// and a loud line. Pass 3 held it in memory, where a daemon restart lost it (the reviewer's FREV-C).
func TestWalletRestoreProofWriteFailureIsForfeited(t *testing.T) {
	wp := filepath.Join(t.TempDir(), "no-such-dir", "wallet.json")
	var err error
	out := captureStderr(t, func() { err = markWalletRestoreLanded(wp, "g1") })
	if !errors.Is(err, errWalletProofNotWritten) {
		t.Fatalf("a proof write that failed answered %v, want errWalletProofNotWritten", err)
	}
	if walletRestoreLanded(wp, "g1") {
		t.Fatal("a proof the disk refused still counts as a proof")
	}
	if !strings.Contains(out, "could NOT be written") || !strings.Contains(out, "FORFEITED") {
		t.Fatalf("a failed proof write was not logged as forfeited; stderr:\n%s", out)
	}
}

// (MA) Anything short of a readable proof naming the generation is no proof: a directory at the proof's path (a read
// error that is not "not there"), an empty file, another generation's proof, the unreadable generation.
func TestARestoreProofThatCannotBeReadIsNoProof(t *testing.T) {
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := os.Mkdir(walletRestoreLandedPath(wp, "g1"), 0o700); err != nil {
		t.Fatal(err)
	}
	if walletRestoreLanded(wp, "g1") {
		t.Fatal("a proof path that cannot be read (a directory) counts as a proof")
	}
	if err := os.WriteFile(walletRestoreLandedPath(wp, "g2"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if walletRestoreLanded(wp, "g2") {
		t.Fatal("an empty proof file counts as a proof")
	}
	if err := os.WriteFile(walletRestoreLandedPath(wp, "g3"), []byte(walletLandedProofHead+"g4"), 0o600); err != nil {
		t.Fatal(err)
	}
	if walletRestoreLanded(wp, "g3") {
		t.Fatal("another generation's proof counts for this one")
	}
	markWalletRestoreLanded(wp, walletGenUnreadable)
	if walletRestoreLanded(wp, walletGenUnreadable) {
		t.Fatal("the unreadable generation was given a proof")
	}
	markWalletRestoreLanded(wp, "g5")
	if !walletRestoreLanded(wp, "g5") {
		t.Fatal("a written proof does not read back")
	}
}

// (2) Without a proof for this generation, tokens appended to the empty local wallet reach the store through NO
// publisher. Each subtest observes its own publisher, not only the end balance (which another guard could hold).
func TestWalletNotRestoredBlocksEveryPublisher(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	wref, _ := headWriteRef(walletFailName+"#wallet", walletFailPass)
	walletKey := "ref/" + wref

	t.Run("fold", func(t *testing.T) {
		var mu sync.Mutex
		leased := false
		capStoreLeaseSeen = func(req leaseReq) {
			mu.Lock()
			defer mu.Unlock()
			if _, ok := req.Refs[walletKey]; ok {
				leased = true
			}
		}
		defer func() { capStoreLeaseSeen = nil }()
		out := captureStderr(t, func() { foldingSeal(t, walletFailName, walletFailPass, f.dk) })
		if !strings.Contains(out, "the fold publishes no wallet") {
			t.Fatalf("the fold did not report refusing; stderr:\n%s", out)
		}
		mu.Lock()
		defer mu.Unlock()
		if leased {
			t.Fatal("the fold folded the wallet: its head was in the lease (putWalletHead alone held it back)")
		}
		f.assertStored(t, f.stored, "the fold")
	})
	t.Run("sealWalletDurable", func(t *testing.T) {
		var err error
		out := captureStderr(t, func() { _, err = sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath) })
		if err != errWalletNotRestored || !strings.Contains(out, "sealWalletDurable: refused") {
			t.Fatalf("sealWalletDurable = %v; stderr:\n%s", err, out)
		}
		f.assertStored(t, f.stored, "sealWalletDurable")
	})
	t.Run("sealWalletValueDurable", func(t *testing.T) {
		data, _ := os.ReadFile(f.wpath)
		w, _ := loadWallet(f.wpath)
		proven := walletRestoreLanded(f.wpath, f.gen()) // what a caller reads with its copy (pass 5): false here
		var err error
		out := captureStderr(t, func() {
			_, err = sealWalletValueDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath, w, data, f.gen(), proven)
		})
		if !errors.Is(err, errWalletNotRestored) || !strings.Contains(out, "sealWalletValueDurable: refused") {
			t.Fatalf("sealWalletValueDurable = %v; stderr:\n%s", err, out)
		}
		f.assertStored(t, f.stored, "a by-value publish")
	})
	// putWalletHead asks the generation's proof again when it writes the head: the case of a copy whose proof stood
	// when it was taken and was forfeited since (removeWallet could not move the generation on).
	t.Run("putWalletHead", func(t *testing.T) {
		data, _ := os.ReadFile(f.wpath)
		w, _ := loadWallet(f.wpath)
		out := captureStderr(t, func() {
			sealWalletValueDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath, w, data, f.gen(), true)
		})
		if !strings.Contains(out, "the #wallet head is not written") {
			t.Fatalf("putWalletHead did not report refusing; stderr:\n%s", out)
		}
		f.assertStored(t, f.stored, "a by-value publish")
	})
	directStore := func(t *testing.T) (base, wp string) {
		base = newHTTPStore(t)
		t.Setenv("GATEWAY_URL", "")
		t.Setenv("S3_ACCESS_KEY", "k")
		wp = filepath.Join(t.TempDir(), "wallet.json")
		if err := appendTokens(wp, newBlindTokens()); err != nil {
			t.Fatal(err)
		}
		return base, wp
	}
	t.Run("sealWallet", func(t *testing.T) {
		base, wp := directStore(t)
		var err error
		out := captureStderr(t, func() { _, err = sealWallet(base, walletFailName, walletFailPass, f.dk, wp) })
		if err != errWalletNotRestored || !strings.Contains(out, "sealWallet: refused") {
			t.Fatalf("sealWallet = %v; stderr:\n%s", err, out)
		}
		if h := getRef(base, walletHeadKey(base, walletFailName, walletFailPass)); h != "" {
			t.Fatalf("sealWallet published a head (%s)", h)
		}
	})
	// (MF) judged by the generation the wallet was SAVED as, never the file's current one: the current generation
	// has a proof here, the departed one the publish carries does not (its copy's own proof stood: this is the
	// generation's check, not the copy's).
	t.Run("sealWalletValueDurable direct-store", func(t *testing.T) {
		base, wp := directStore(t)
		markWalletRestoreLanded(wp, walletGeneration(wp))
		w, _ := loadWallet(wp)
		var err error
		out := captureStderr(t, func() {
			_, err = sealWalletValueDurable(base, walletFailName, walletFailPass, f.dk, wp, w, nil, "a departed generation", true)
		})
		if err != errWalletNotRestored || !strings.Contains(out, "sealWalletValueDurable: refused") {
			t.Fatalf("sealWalletValueDurable = %v; stderr:\n%s", err, out)
		}
		if h := getRef(base, walletHeadKey(base, walletFailName, walletFailPass)); h != "" {
			t.Fatalf("sealWalletValueDurable published a head (%s)", h)
		}
	})
}

// The refusal changes no spending: the session's wallet file is loaded and saved as ever.
func TestWalletNotRestoredLeavesTheLocalWalletUsable(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	w, err := loadWallet(f.wpath)
	if err != nil || w.balance() != 2 {
		t.Fatalf("the local wallet = (%v, %v), want the 2 appended tokens", w, err)
	}
}

// (2) BOUND TO THE GENERATION, direction one: session A's read failed, A claimed 2 tokens, and A's late by-value
// publish (payRent from syncLoop after the sign-out, carrying A's generation) arrives after B has signed in and
// restored normally. It must not land: it would replace the stored 10 with A's 2.
func TestAFailedSessionsLatePublishIsRefusedAfterTheNextSignIn(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	genA := f.gen()
	f.appendTwo(t)
	data, _ := os.ReadFile(f.wpath)
	w, _ := loadWallet(f.wpath)
	proven := walletRestoreLanded(f.wpath, genA) // read with the copy, as payRent does
	f.signIn(t)                                  // B: a new generation, and its restore lands
	out := captureStderr(t, func() {
		sealWalletValueDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath, w, data, genA, proven)
	})
	if got := f.storedBalance(t); got != f.stored {
		t.Fatalf("the departed failed session's late publish landed: stored wallet holds %d, want %d; stderr:\n%s",
			got, f.stored, out)
	}
}

// Direction two: A restored normally and claimed 2 (12 local); B's read then fails. A's late publish is A's legitimate
// last word and must land, whatever B's generation says.
func TestALaterSessionsFailedReadDoesNotBlockTheDepartedOnesLastWord(t *testing.T) {
	f := walletFailSetup(t)
	f.signIn(t) // A
	genA := f.gen()
	f.appendTwo(t)
	data, _ := os.ReadFile(f.wpath)
	w, _ := loadWallet(f.wpath)
	proven := walletRestoreLanded(f.wpath, genA) // read with the copy, as payRent does
	removeWallet(f.wpath)                        // B signs in...
	f.failedRoamIn(t)                            // ...and its read fails
	if !walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("fixture: B's generation has a proof")
	}
	if _, err := sealWalletValueDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath, w, data, genA, proven); err != nil {
		t.Fatalf("A's last word: %v", err)
	}
	f.assertStored(t, f.stored+2, "A's last word")
}

// ---- the five holes a fix review reproduced (each ended stored 10 -> the session's 2) ----

// (P1) removeWallet's bump -> lock gap: a departed flush that wins the lock after the bump loads under the NEW
// generation, which has no proof yet. Its fold is refused.
func TestProbeP1AFoldUnderAFreshlyBumpedGenerationIsRefused(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	if err := bumpWalletGeneration(f.wpath); err != nil { // a sign-in's first bump; its roam-in has not run yet
		t.Fatal(err)
	}
	out := captureStderr(t, func() { foldingSeal(t, walletFailName, walletFailPass, f.dk) })
	if !strings.Contains(out, "the fold publishes no wallet") {
		t.Fatalf("the fold under a bumped generation did not refuse; stderr:\n%s", out)
	}
	f.assertStored(t, f.stored, "P1")
}

// (P2) a damaged blob: a 200 whose bytes do not hash to the head is a FAILED read, never "no wallet" -- and never a
// wallet either. The substitute here is the hardest case: bytes that DO open with the profile's key (an empty wallet,
// as a store serving the wrong object would hand back), so only the hash can tell them from the head's.
func TestProbeP2ADamagedWalletBlobIsAFailedRead(t *testing.T) {
	f := walletFailSetup(t)
	head := getRef("s3", walletHeadKey("s3", walletFailName, walletFailPass))
	f.objsMu.Lock()
	good, ok := f.objs["blob/"+head]
	f.objs["blob/"+head] = seal(f.dk, []byte(`{"tokens":[]}`))
	f.objsMu.Unlock()
	if !ok {
		t.Fatal("fixture: the wallet blob is not in the mock store under blob/<head>")
	}
	defer func() { // the stored bytes come back before the end check, so a publish shows as a changed head
		f.objsMu.Lock()
		f.objs["blob/"+head] = good
		f.objsMu.Unlock()
	}()
	out := captureStderr(t, func() { roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath) })
	if !walletNotRestored(f.wpath, f.gen()) || !strings.Contains(out, "wallet read FAILED") {
		t.Fatalf("a damaged wallet blob was taken for a restore or an absence; stderr:\n%s", out)
	}
	f.appendTwo(t)
	foldingSeal(t, walletFailName, walletFailPass, f.dk)
	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath); !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("sealWalletDurable after a damaged read = %v, want errWalletNotRestored", err)
	}
	f.objsMu.Lock()
	f.objs["blob/"+head] = good
	f.objsMu.Unlock()
	f.assertStored(t, f.stored, "P2")
}

// (P2b) a blob that hashes correctly but does not open with the profile's key fails CLOSED too.
func TestProbeP2AWalletBlobThatDoesNotOpenFailsClosed(t *testing.T) {
	f := walletFailSetup(t)
	other := filepath.Join(t.TempDir(), "other.json")
	if err := saveWallet(other, &Wallet{BlindTokens: []BlindToken{{Msg: "x", Sig: "y"}}}); err != nil {
		t.Fatal(err)
	}
	markWalletRestoreLanded(other, walletGeneration(other))
	wrongDK := deriveKey("someone else", "another passphrase")
	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, wrongDK, other); err != nil {
		t.Fatalf("fixture: sealing a blob under another key: %v", err)
	}
	out := captureStderr(t, func() { roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath) })
	if !walletNotRestored(f.wpath, f.gen()) || !strings.Contains(out, "does not open") {
		t.Fatalf("a wallet blob that does not open was taken for an absence; stderr:\n%s", out)
	}
}

// (P3) a 403 on the wallet head -- even on a fresh cap, which capGet reads as a hide-existence absence -- is a failed
// read for the wallet.
func TestProbeP3AForbiddenWalletHeadIsAFailedRead(t *testing.T) {
	f := walletFailSetup(t)
	back := f.walletFailWalletReads(t, http.StatusForbidden)
	out := captureStderr(t, func() { roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath) })
	if !walletNotRestored(f.wpath, f.gen()) {
		back()
		t.Fatalf("a 403 on the wallet head proved the generation; stderr:\n%s", out)
	}
	f.appendTwo(t)
	foldingSeal(t, walletFailName, walletFailPass, f.dk)
	back()
	f.assertStored(t, f.stored, "P3")
}

// (P4) an unreadable .gen (a directory in its place) is no generation anything may publish for -- not "".
func TestProbeP4AnUnreadableGenerationPublishesNothing(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	if err := os.Remove(f.wpath + ".gen"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(f.wpath+".gen", 0o700); err != nil {
		t.Fatal(err)
	}
	markWalletRestoreLanded(f.wpath, "") // even with the empty generation proven, an unreadable one is not it
	if g, err := walletGenerationErr(f.wpath); err == nil || g != walletGenUnreadable {
		t.Fatalf("walletGenerationErr on a directory = (%q, %v)", g, err)
	}
	foldingSeal(t, walletFailName, walletFailPass, f.dk)
	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath); !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("sealWalletDurable with an unreadable generation = %v", err)
	}
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen()); !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("a retry earned a proof for an unreadable generation (%v)", err)
	}
	f.assertStored(t, f.stored, "P4")
}

// (P5) the retry merges ONLY under the wallet lock. A holder that loaded the local-only file before the retry, and
// saves it after, must not leave a proven generation behind a file without the stored tokens.
func TestProbeP5ARetryThatCannotLockMergesNothing(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	held, _ := loadWallet(f.wpath) // the holder's copy: payRent's lease, a worker flush
	unlock, st := lockWalletWithin(f.wpath, time.Second)
	if st != walletLocked {
		t.Fatal("fixture: could not take the wallet lock")
	}
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	defer func() { walletSignInWait = old }()
	err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen())
	if err := saveWallet(f.wpath, held); err != nil { // the holder saves its copy at the same generation
		t.Fatal(err)
	}
	unlock()
	if !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("a retry that could not lock the wallet = %v, want errWalletNotRestored", err)
	}
	if walletRestoreLanded(f.wpath, f.gen()) {
		t.Fatal("a retry that could not lock the wallet proved the generation")
	}
	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath); !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("sealWalletDurable after the held save = %v", err)
	}
	f.assertStored(t, f.stored, "P5")
}

// ---- the reviewer's surviving mutants ----

// (MB) a retry whose generation moved while it waited for the lock merges into nobody's file and proves nothing: the
// check UNDER the lock (the one before the read passed).
func TestRetryWalletRestoreRefusesAGenerationThatMovedWhileItWaited(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	genA := f.gen()
	unlock, _ := lockWalletWithin(f.wpath, time.Second)
	var once sync.Once
	newOwner := &Wallet{BlindTokens: []BlindToken{{Msg: "theirs", Sig: "s"}}}
	walletLockTrace = func(ev string) {
		if ev == "wait" {
			once.Do(func() { // a sign-in hands the wallet over while the retry waits
				bumpWalletGeneration(f.wpath)
				saveWallet(f.wpath, newOwner)
				unlock()
			})
		}
	}
	defer func() { walletLockTrace = nil; unlock() }()
	err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, genA)
	if !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("retry across a generation change = %v, want errWalletNotRestored", err)
	}
	if w, _ := loadWallet(f.wpath); w.balance() != 1 {
		t.Fatalf("the new owner's wallet holds %d tokens after the retry, want its own 1 (the stored wallet was merged into it)", w.balance())
	}
	if walletRestoreLanded(f.wpath, f.gen()) || walletRestoreLanded(f.wpath, genA) {
		t.Fatal("a retry across a generation change wrote a proof")
	}
}

// (MC) the fold is judged by walletGen, the generation the flush LOADED under: the current generation having a proof
// changes nothing for a flush that loaded under one without.
func TestTheFoldIsJudgedByTheGenerationItLoaded(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	var once sync.Once
	capFlushWalletLoaded = func() {
		once.Do(func() {
			bumpWalletGeneration(f.wpath)
			markWalletRestoreLanded(f.wpath, f.gen()) // the NEXT generation is proven; the loaded one is not
		})
	}
	defer func() { capFlushWalletLoaded = nil }()
	// Observed at the fold itself, not only at the end balance: putWalletHead (judged by the same loaded generation)
	// would hold the head back on its own, so the balance alone cannot tell which guard refused.
	wref, _ := headWriteRef(walletFailName+"#wallet", walletFailPass)
	var mu sync.Mutex
	leased := false
	capStoreLeaseSeen = func(req leaseReq) {
		mu.Lock()
		defer mu.Unlock()
		if _, ok := req.Refs["ref/"+wref]; ok {
			leased = true
		}
	}
	defer func() { capStoreLeaseSeen = nil }()
	out := captureStderr(t, func() { foldingSeal(t, walletFailName, walletFailPass, f.dk) })
	mu.Lock()
	folded := leased
	mu.Unlock()
	if folded || !strings.Contains(out, "the fold publishes no wallet") {
		t.Fatalf("the fold was judged by the current (proven) generation, not the one it loaded (folded %v); stderr:\n%s", folded, out)
	}
	f.assertStored(t, f.stored, "a fold judged by the current generation")
}

// (MD) a stored wallet there is no key to open (the data head does not resolve) is not an absence: no proof.
func TestAStoredWalletWithNoKeyIsNotAnAbsence(t *testing.T) {
	f := walletFailSetup(t)
	const orphan = "orphan-wallet"
	other := filepath.Join(t.TempDir(), "orphan.json")
	if err := saveWallet(other, &Wallet{BlindTokens: newBlindTokens()}); err != nil {
		t.Fatal(err)
	}
	markWalletRestoreLanded(other, walletGeneration(other))
	if _, err := sealWalletDurable("s3", orphan, walletFailPass, deriveKey(orphan, walletFailPass), other); err != nil {
		t.Fatalf("fixture: a wallet head with no data head: %v", err)
	}
	if resolveDK("s3", orphan, walletFailPass, nil) != nil {
		t.Fatal("fixture: the orphan's key resolves")
	}
	out := captureStderr(t, func() { roamInWallet("s3", orphan, walletFailPass, nil, f.wpath) })
	if !walletNotRestored(f.wpath, f.gen()) {
		t.Fatalf("a stored wallet with no key to open it proved the generation; stderr:\n%s", out)
	}
}

// (ME / 6, pass 4; the reviewer's FREV-C) a landed restore whose proof the disk refuses is UNDONE, so the session
// holds none of the stored tokens: it cannot spend one, and nothing a daemon restart could lose stands between it and
// a merge. Pass 3 held the proof in memory; a restart lost it, and the next retry merged the stored wallet back over
// the session's spends -- the spent nonces came back. Here the retry that lands once the disk is back merges every
// stored token in exactly once.
func TestAForfeitedProofNeverResurrectsASpentToken(t *testing.T) {
	f := walletFailSetup(t)
	stored := readBackStored(t)
	p := walletRestoreLandedPath(f.wpath, f.gen())
	if err := os.Mkdir(p, 0o700); err != nil { // the proof's rename fails onto a directory
		t.Fatal(err)
	}
	out := captureStderr(t, func() { roamInWallet("s3", walletFailName, walletFailPass, nil, f.wpath) })
	if walletRestoreLanded(f.wpath, f.gen()) {
		t.Fatal("a restore whose proof the disk refused proved its generation")
	}
	if !strings.Contains(out, "FORFEITED") || strings.Contains(out, "wallet read FAILED") {
		t.Fatalf("a refused proof was not logged as forfeited (or was logged as a failed read); stderr:\n%s", out)
	}
	if _, err := os.Stat(f.wpath); !os.IsNotExist(err) {
		t.Fatalf("the restored wallet was left in place without its proof (stat err %v): the session could spend a "+
			"stored token and a later merge would bring it back", err)
	}
	f.appendTwo(t) // the session's own claim
	foldingSeal(t, walletFailName, walletFailPass, f.dk)
	f.assertStored(t, f.stored, "the fold of a session whose proof was forfeited")
	if err := os.Remove(p); err != nil { // the disk is back; a restart in between loses nothing
		t.Fatal(err)
	}
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen()); err != nil {
		t.Fatalf("the retry once the disk is back: %v", err)
	}
	w, _ := loadWallet(f.wpath)
	seen := map[string]int{}
	for _, tk := range w.Tokens {
		seen[tk.Nonce]++
	}
	for _, tk := range stored.Tokens {
		if seen[tk.Nonce] != 1 {
			t.Fatalf("stored token %s is in the merged wallet %d times, want once", tk.Nonce, seen[tk.Nonce])
		}
	}
	if w.balance() != f.stored+2 {
		t.Fatalf("the merged wallet holds %d, want the stored %d plus the session's 2", w.balance(), f.stored)
	}
}

// readBackStored is the fixture profile's stored wallet, read strictly.
func readBackStored(t *testing.T) *Wallet {
	t.Helper()
	w, _, err := readStoredWalletStrict("s3", walletFailName, walletFailPass, deriveKey(walletFailName, walletFailPass))
	if err != nil || w == nil {
		t.Fatalf("fixture: the stored wallet = (%v, %v)", w, err)
	}
	return w
}

// (pass 4) the retry's merge is undone the same way when its proof cannot be written: the file goes back to the
// session's own tokens, and nothing is proven.
func TestARetryWhoseProofTheDiskRefusesUndoesItsMerge(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	before, _ := os.ReadFile(f.wpath)
	p := walletRestoreLandedPath(f.wpath, f.gen())
	if err := os.Mkdir(p, 0o700); err != nil {
		t.Fatal(err)
	}
	err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen())
	if !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("a retry whose proof the disk refused = %v, want errWalletNotRestored", err)
	}
	if walletRestoreLanded(f.wpath, f.gen()) {
		t.Fatal("a retry whose proof the disk refused proved its generation")
	}
	if after, _ := os.ReadFile(f.wpath); string(after) != string(before) {
		t.Fatalf("the merge was not undone: the file holds %s, want the session's own %s", after, before)
	}
	os.Remove(p)
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen()); err != nil {
		t.Fatalf("the retry once the disk is back: %v", err)
	}
	if w, _ := loadWallet(f.wpath); w.balance() != f.stored+2 {
		t.Fatalf("the merged wallet holds %d, want %d", w.balance(), f.stored+2)
	}
}

// (MI) END's wallet step on a session whose restore LANDED: a failed key read is an ordinary failure (ERR-WALLET,
// the session is kept), never "not restored" (which would end the session without saving its wallet).
func TestPublishWalletBeforeDiscardKeyFailureOnALandedSessionIsNotNotRestored(t *testing.T) {
	f := walletFailSetup(t)
	f.signIn(t)
	f.appendTwo(t)
	back := walletFailBreak(t)
	err := publishWalletBeforeDiscard(f.dest, walletFailName, walletFailPass, nil, f.gen())
	back()
	if err == nil || errors.Is(err, errWalletNotRestored) || errors.Is(err, errWalletNoSlot) {
		t.Fatalf("publishWalletBeforeDiscard on a landed session with a dead store = %v, want a plain error "+
			"(errWalletNoSlot is a head that was read and no slot opens, NWP-20261114-06)", err)
	}
}

// removeWallet bumps again once it has (or has waited out) the lock, so a writer that loaded under the first bump's
// generation cannot pass its save check.
func TestRemoveWalletBumpsAgainAfterTheLock(t *testing.T) {
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	unlock, _ := lockWalletWithin(wp, time.Second)
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	var mid string
	walletLockTrace = func(ev string) {
		if ev == "wait" && mid == "" {
			mid = walletGeneration(wp) // what a writer winning the lock in the gap would load under
		}
	}
	defer func() { walletSignInWait = old; walletLockTrace = nil; unlock() }()
	removeWallet(wp)
	if mid == "" || walletGeneration(wp) == mid {
		t.Fatalf("the generation after removeWallet (%q) is the one a writer in the gap loaded under (%q)", walletGeneration(wp), mid)
	}
}

// A removal that cannot move the generation on forfeits the departed session's proof, so the arriving session does
// not inherit it.
func TestRemoveWalletThatCannotBumpForfeitsTheProof(t *testing.T) {
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := bumpWalletGeneration(wp); err != nil {
		t.Fatal(err)
	}
	g := walletGeneration(wp)
	markWalletRestoreLanded(wp, g)
	if err := os.Mkdir(wp+".gen.tmp", 0o700); err != nil { // both bumps' writes fail
		t.Fatal(err)
	}
	out := captureStderr(t, func() { removeWallet(wp) })
	if walletGeneration(wp) != g {
		t.Fatal("fixture: the generation moved")
	}
	if walletRestoreLanded(wp, g) {
		t.Fatalf("a removal that could not bump left the departed session's proof; stderr:\n%s", out)
	}
}

// ---- the lazy second read ----

// The store is back, so the stored wallet is merged under this session's new tokens, the proof is written, and the
// next durable publish carries all of them.
func TestRetryWalletRestoreLandsAndMerges(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen()); err != nil {
		t.Fatalf("retryWalletRestore against a working store: %v", err)
	}
	if walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("a landed retry wrote no proof")
	}
	if w, _ := loadWallet(f.wpath); w.balance() != f.stored+2 {
		t.Fatalf("the merged wallet holds %d, want the stored %d plus this session's 2", w.balance(), f.stored)
	}
	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath); err != nil {
		t.Fatalf("sealWalletDurable after the retry: %v", err)
	}
	f.assertStored(t, f.stored+2, "after the retry and publish")
	// and a second retry on the proven generation merges nothing again
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen()); err != nil {
		t.Fatal(err)
	}
	if w, _ := loadWallet(f.wpath); w.balance() != f.stored+2 {
		t.Fatalf("a second retry changed the wallet to %d tokens", w.balance())
	}
}

// A retry that waited for the lock while ANOTHER retry landed (and the session then spent a stored token) merges
// nothing again: the generation's proof, re-read under the lock, says the stored wallet is already in the file.
func TestRetryWalletRestoreDoesNotMergeAGenerationThatLandedWhileItWaited(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	unlock, _ := lockWalletWithin(f.wpath, time.Second)
	var once sync.Once
	walletLockTrace = func(ev string) {
		if ev == "wait" {
			once.Do(func() { // the other retry: merged, proven, and one stored token spent since
				stored, _, err := readStoredWalletStrict("s3", walletFailName, walletFailPass, f.dk)
				if err != nil {
					t.Errorf("fixture: the other retry's read: %v", err)
				}
				local, _ := loadWallet(f.wpath)
				m := mergeLateRestore(stored, local)
				m.Tokens = m.Tokens[1:]
				saveWallet(f.wpath, m)
				markWalletRestoreLanded(f.wpath, f.gen())
				unlock()
			})
		}
	}
	defer func() { walletLockTrace = nil; unlock() }()
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen()); err != nil {
		t.Fatalf("retry on a generation that landed meanwhile: %v", err)
	}
	if w, _ := loadWallet(f.wpath); w.balance() != f.stored+2-1 {
		t.Fatalf("the wallet holds %d, want %d: the stored wallet was merged a second time, over the spend",
			w.balance(), f.stored+2-1)
	}
}

func TestRetryWalletRestoreStillFailingKeepsTheRefusal(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	back := walletFailBreak(t)
	err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen())
	back()
	if !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("retryWalletRestore against a dead store = %v, want errWalletNotRestored", err)
	}
	if walletRestoreLanded(f.wpath, f.gen()) {
		t.Fatal("a failed retry wrote a proof")
	}
}

func TestMergeLateRestoreIsAUnionByNonce(t *testing.T) {
	stored := &Wallet{Tokens: []Token{{Nonce: "a"}, {Nonce: "b"}}, BlindTokens: []BlindToken{{Msg: "x"}}, PaidThrough: 9}
	local := &Wallet{Tokens: []Token{{Nonce: "b"}, {Nonce: "c"}}, BlindTokens: []BlindToken{{Msg: "x"}, {Msg: "y"}}, PlanGB: 10, PlanPeriods: 3}
	m := mergeLateRestore(stored, local)
	if len(m.Tokens) != 3 || len(m.BlindTokens) != 2 || m.PaidThrough != 9 || m.PlanGB != 10 || m.PlanPeriods != 3 {
		t.Fatalf("merge = %+v", m)
	}
	if len(stored.Tokens) != 2 || len(local.Tokens) != 2 {
		t.Fatal("the merge mutated its inputs")
	}
}

// (5) Add-credits: one retry of the read, then no sleeps against a refusal no attempt can change.
func TestClaimSealStopsAtOnceOnANotRestoredWallet(t *testing.T) {
	f := walletFailSetup(t)
	if err := markRoamSession(f.dest, walletFailName, walletFailPass, "10", ""); err != nil {
		t.Fatal(err)
	}
	f.failedRoamIn(t)
	f.appendTwo(t)
	sleeps := 0
	old := claimSealSleep
	claimSealSleep = func(time.Duration) { sleeps++ }
	defer func() { claimSealSleep = old }()
	back := f.walletFailBreakWalletOnly(t)
	var saved bool
	out := captureStderr(t, func() { saved = sealClaimedWallet(f.dest, walletFailName, walletFailPass, 2, f.gen()) })
	back()
	if saved {
		t.Fatal("a wallet whose restore never landed reported saved")
	}
	if sleeps != 0 {
		t.Fatalf("slept %d time(s) retrying a refusal no retry can change", sleeps)
	}
	if !strings.Contains(out, "never read its stored wallet") {
		t.Fatalf("no distinct not-restored line; stderr:\n%s", out)
	}
	f.assertStored(t, f.stored, "a refused claim seal")
}

// ...and with the store back, the same claim's seal retries the read, merges and lands.
func TestClaimSealRetriesTheReadAndLands(t *testing.T) {
	f := walletFailSetup(t)
	if err := markRoamSession(f.dest, walletFailName, walletFailPass, "10", ""); err != nil {
		t.Fatal(err)
	}
	f.failedRoamIn(t)
	f.appendTwo(t)
	if !sealClaimedWallet(f.dest, walletFailName, walletFailPass, 2, f.gen()) {
		t.Fatal("the claim's seal did not land with the store back")
	}
	f.assertStored(t, f.stored+2, "a claim seal after the retry")
}

// (5, decided 2026-10-15 "Retry, then warn") a normal sign-out's wallet step: one locked retry; landed, the seal
// publishes as usual; not landed, the sign-out goes ahead and the gate is told only when the session holds credit.
func TestLogoffWalletRetry(t *testing.T) {
	t.Run("a proven session: nothing to do", func(t *testing.T) {
		f := walletFailSetup(t)
		f.signIn(t)
		f.appendTwo(t)
		if logoffWalletRetry(f.dest, walletFailName, walletFailPass, nil, f.gen()) {
			t.Fatal("a proven session's sign-out reported lost credit")
		}
	})
	t.Run("the retry lands: merged, proven, no notice", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		if logoffWalletRetry(f.dest, walletFailName, walletFailPass, nil, f.gen()) {
			t.Fatal("a sign-out whose retry landed reported lost credit")
		}
		if walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("the sign-out's landed retry wrote no proof")
		}
		if w, _ := loadWallet(f.wpath); w.balance() != f.stored+2 {
			t.Fatalf("the sign-out's merged wallet holds %d, want %d", w.balance(), f.stored+2)
		}
	})
	t.Run("the retry fails with credit held: the gate is told", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		back := f.walletFailBreakWalletOnly(t)
		lost := logoffWalletRetry(f.dest, walletFailName, walletFailPass, nil, f.gen())
		back()
		if !lost {
			t.Fatal("a sign-out that could not read the wallet, holding credit, did not report it lost")
		}
		if walletRestoreLanded(f.wpath, f.gen()) {
			t.Fatal("a failed sign-out retry wrote a proof")
		}
		foldingSeal(t, walletFailName, walletFailPass, f.dk) // the sign-out's own seal
		f.assertStored(t, f.stored, "the sign-out's seal")
	})
	t.Run("the retry fails with nothing held: no notice", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		back := f.walletFailBreakWalletOnly(t)
		lost := logoffWalletRetry(f.dest, walletFailName, walletFailPass, nil, f.gen())
		back()
		if lost {
			t.Fatal("a sign-out with no credit held reported credit lost")
		}
	})
}

// The gate's notice: recorded content-free, read until cleared, and cleared only for the notice the gate showed.
func TestCreditLostNoticeShowOnceAndClear(t *testing.T) {
	dest := t.TempDir()
	if got := creditLostReply(dest); got != "NONE" {
		t.Fatalf("no notice recorded: %q", got)
	}
	noteCreditLost(dest)
	got := creditLostReply(dest)
	if !strings.HasPrefix(got, "NOTICE ") {
		t.Fatalf("a recorded notice reads %q", got)
	}
	if b, _ := os.ReadFile(creditLostPath(dest)); strings.Trim(string(b), "0123456789") != "" {
		t.Fatalf("the notice file holds more than a time: %q", b)
	}
	if !strings.HasPrefix(filepath.Base(creditLostPath(dest)), "wallet.json.") {
		t.Fatal("the notice is not named wallet.json.*: wipeSessionState would remove it before the gate reads it")
	}
	if r := clearCreditLost(dest, "1"); r != "STALE" || creditLostReply(dest) != got {
		t.Fatalf("a clear for another notice = %q and left %q", r, creditLostReply(dest))
	}
	if r := clearCreditLost(dest, strings.TrimPrefix(got, "NOTICE ")+"\n"); r != "OK" {
		t.Fatalf("the clear for the shown notice = %q", r)
	}
	if got := creditLostReply(dest); got != "NONE" {
		t.Fatalf("after its clear the notice still reads %q", got)
	}
}

// proveNoStoredWallet: a profile being made proves its generation only on a strict, definite absence.
func TestProveNoStoredWallet(t *testing.T) {
	f := walletFailSetup(t)
	wp := filepath.Join(t.TempDir(), "made.json")
	if err := proveNoStoredWallet("s3", "a new profile", walletFailPass, wp, ""); err != nil || !walletRestoreLanded(wp, "") {
		t.Fatalf("a profile with no wallet head: err %v, proven %v", err, walletRestoreLanded(wp, ""))
	}
	wp2 := filepath.Join(t.TempDir(), "made.json")
	if err := proveNoStoredWallet("s3", walletFailName, walletFailPass, wp2, ""); !errors.Is(err, errStoredWalletExists) || walletRestoreLanded(wp2, "") {
		t.Fatalf("a profile with a stored wallet: err %v, proven %v", err, walletRestoreLanded(wp2, ""))
	}
	back := f.walletFailWalletReads(t, http.StatusForbidden)
	wp3 := filepath.Join(t.TempDir(), "made.json")
	err := proveNoStoredWallet("s3", walletFailName, walletFailPass, wp3, "")
	back()
	if err == nil || errors.Is(err, errStoredWalletExists) || walletRestoreLanded(wp3, "") {
		t.Fatalf("a 403 on the wallet head: err %v, proven %v", err, walletRestoreLanded(wp3, ""))
	}
}

// (4) END-UNSAVED's wallet step: lands after a retry, or refuses to publish with errWalletNotRestored.
func TestPublishWalletBeforeDiscardOnANotRestoredWallet(t *testing.T) {
	t.Run("the retry lands: the wallet is published as usual", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		if err := publishWalletBeforeDiscard(f.dest, walletFailName, walletFailPass, nil, f.gen()); err != nil {
			t.Fatalf("publishWalletBeforeDiscard with the store back: %v", err)
		}
		f.assertStored(t, f.stored+2, "END after a landed retry")
	})
	t.Run("the retry fails: nothing is published", func(t *testing.T) {
		f := walletFailSetup(t)
		f.failedRoamIn(t)
		f.appendTwo(t)
		// The store is dead again: the key read (resolveDK) or the wallet read fails, and either is "not restored".
		back := walletFailBreak(t)
		err := publishWalletBeforeDiscard(f.dest, walletFailName, walletFailPass, nil, f.gen())
		back()
		if !errors.Is(err, errWalletNotRestored) {
			t.Fatalf("publishWalletBeforeDiscard against a dead store = %v, want errWalletNotRestored", err)
		}
		f.assertStored(t, f.stored, "END with the store dead")
	})
}

// (4) The handlers: a wallet that was never read ends the session anyway, with the distinct reply, and publishes
// nothing (the wallet hook is the only publisher either calls). END records the gate's notice when credit is held.
func TestEndUnsaved_ANotRestoredWalletEndsWithTheCreditLostReply(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	f.walletEr = errWalletNotRestored
	if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	if got := f.end(); got != endUnsavedCreditLost {
		t.Fatalf("got %q, want %s", got, endUnsavedCreditLost)
	}
	pendingReapMu.Lock()
	rp := pendingReapUID
	pendingReapMu.Unlock()
	if rp != euUID || roamSessionExists(f.dest) {
		t.Fatalf("the session was not ended (reap %q)", rp)
	}
	if f.wallets != 1 {
		t.Errorf("the wallet step ran %d times, want 1", f.wallets)
	}
	if !strings.HasPrefix(creditLostReply(f.dest), "NOTICE ") {
		t.Error("END over a never-read wallet holding credit recorded no gate notice")
	}
}

func TestEndUnsaved_ANotRestoredWalletWithNoCreditRecordsNoNotice(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	f.walletEr = errWalletNotRestored
	if got := f.end(); got != endUnsavedCreditLost {
		t.Fatalf("got %q, want %s", got, endUnsavedCreditLost)
	}
	if got := creditLostReply(f.dest); got != "NONE" {
		t.Errorf("END with no credit held recorded a gate notice (%q)", got)
	}
}

func TestEndUnsaved_ASavedWalletRecordsNoNotice(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	if got := f.end(); got != "OK" {
		t.Fatalf("got %q, want OK", got)
	}
	if got := creditLostReply(f.dest); got != "NONE" {
		t.Errorf("a saved END recorded a gate notice (%q)", got)
	}
}

func TestRestartUnsaved_ANotRestoredWalletRestartsWithTheCreditLostReply(t *testing.T) {
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	f.walletEr = errWalletNotRestored
	if got := ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }); got != endUnsavedCreditLost {
		t.Fatalf("RESTART-UNSAVED = %q, want %s", got, endUnsavedCreditLost)
	}
}

func TestOkAsConnRewritesOnlyTheBareOK(t *testing.T) {
	for _, tc := range []struct{ in, want string }{{"OK\n", "OK-CREDIT-LOST"}, {"BUSY\n", "BUSY"}, {"OK 3\n", "OK 3"}} {
		got := ropReply(t, func(c net.Conn) { okAsConn{c, endUnsavedCreditLost}.Write([]byte(tc.in)) })
		if got != tc.want {
			t.Errorf("%q -> %q, want %q", tc.in, got, tc.want)
		}
	}
}

// (3) A signed-in passphrase rotation of a session whose read failed CARRIES the stored wallet to the new passphrase:
// the fold is refused, so treating the file as ours would leave the stored head at the old passphrase.
func TestRotationOfANotRestoredSessionCarriesTheStoredWallet(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}
	blobCache = nil // another test may have written the same content; postBlob would then skip it
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	const name, pass, newpass = "walrot", "the passphrase before", "the passphrase after"
	_, oldHead, wpath := fundedProfile(t, srv.URL, name, pass, 10)
	removeWallet(wpath)
	back := walletFailBreak(t)
	roamInWallet("s3", name, pass, nil, wpath)
	back()
	if !walletNotRestored(wpath, walletGeneration(wpath)) {
		t.Fatal("fixture: the sign-in's read did not fail")
	}
	if err := appendTokens(wpath, newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	if rotateWalletOurs(true, wpath) {
		t.Fatal("rotateWalletOurs: a live session whose restore never landed counts its file as the profile's wallet")
	}
	if _, err := rotateVault("s3", name, pass, newpass, nil, rotateWalletOurs(true, wpath)); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if h := getRef("s3", walletHeadKey("s3", name, newpass)); h != oldHead {
		t.Fatalf("the stored wallet was not carried to the new passphrase (head %q, want %q)", short(h), short(oldHead))
	}
	if w := walletAt(t, name, newpass); w == nil || w.balance() != 10 {
		t.Fatalf("the wallet at the new passphrase = %+v, want the stored 10 tokens", w)
	}
	// and a session whose restore landed still owns its file
	removeWallet(wpath)
	roamInWallet("s3", name, newpass, nil, wpath)
	if !rotateWalletOurs(true, wpath) || rotateWalletOurs(false, wpath) {
		t.Fatal("rotateWalletOurs after a landed restore: want live")
	}
}

// ---- wiring the behaviour tests above cannot reach: pinned in the source ----

// handleRoamIn restores through roamInWallet, and no bare restoreWallet (whose failed read a recover() would swallow)
// is back on the roam-in path.
func TestHandleRoamInRestoresTheWalletThroughRoamInWallet(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(src), "handleRoamIn")), "\n")
	// NWP-20261116-03 (h46 #1): through the guarded variant, in the sign-in's late job.
	if !strings.Contains(body, `roamInWalletGuarded("s3", lateName, latePass, lateSE, lateWallet, lw.mayWrite)`) {
		t.Fatal("handleRoamIn no longer restores the wallet through roamInWallet")
	}
	if strings.Contains(body, "restoreWallet(") {
		t.Fatal("handleRoamIn calls the wallet restore directly again, outside roamInWallet's proof")
	}
}

// The sign-out retries the read BEFORE its seal, and records the gate's notice BEFORE it queues the switch; the
// periodic seal retries before its own; a create with a staged claim and a promote prove the new profile's wallet head
// empty before they publish.
func TestTheWalletRetryAndProofCallSites(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	order := func(fn string, first, then string) {
		t.Helper()
		body := strings.Join(stripComments(funcBody(t, s, fn)), "\n")
		i, j := strings.Index(body, first), strings.Index(body, then)
		if i < 0 || j < 0 || i > j {
			t.Errorf("%s: %q (at %d) must come before %q (at %d)", fn, first, i, then, j)
		}
	}
	order("handleLogout", "lgen := walletGeneration(walletPathFor(dest))", "name, pass, uid := readRoamSession(dest)")
	order("handleLogout", "logoffCreditLost := logoffWalletRetry(dest, name, pass, seFromHex(seSecret), lgen)",
		`triggerRoamWorkerKind(dest, "out", name, pass, uid, seSecret, outKind`)
	order("handleLogout", "if logoffCreditLost {\n\t\t\t\tnoteCreditLost(dest)", "pendingSwitchUID = uid // seal landed")
	order("syncLoop", "wgen := walletGeneration(walletPathFor(dest))", "name, pass, uid := readRoamSession(dest)")
	order("syncLoop", "retrySessionWallet(dest, name, pass, seFromSession(dest), wgen, walletSignInWait)",
		`triggerRoamWorkerKind(dest, "out", name, pass, uid, readRoamSessionSE(dest), "", "", "periodic"`)
	order("createAndReply", `proveNoStoredWallet("s3", name, pass, staged, walletGeneration(staged))`, "createVaultWalletProg(")
	order("promoteToStore", `proveNoStoredWallet("s3", name, pass, wp, walletGeneration(wp))`, `createVault("s3", name, pass)`)
	// pass 4: every other retry entry point captures its generation before it reads the session (and so before any
	// store read), and hands that generation to the retry.
	order("handleRoamOut", "rgen := walletGeneration(walletPathFor(dest))", "name, pass, uid := readRoamSession(dest)")
	order("handleRoamOut", "if logoffWalletRetry(dest, name, pass, seFromHex(readRoamSessionSE(dest)), rgen) {\n\t\t\tnoteCreditLost(dest)",
		"out := triggerRoamWorker(dest, \"out\", name, pass, uid, readRoamSessionSE(dest), nil)")
	order("handleClaimMode", "cgen := walletGeneration(walletPathFor(dest))", "name, pass, _ := readRoamSession(dest)")
	order("handleClaimMode", "name, pass, _ := readRoamSession(dest)", "saved = sealClaimedWallet(dest, name, pass, n, cgen)")
	order("sealClaimedWallet", `retryWalletRestore("s3", name, pass, dk, wp, gen)`, `sealWalletDurable("s3", name, pass, dk, wp)`)
	eu, err := os.ReadFile("end_unsaved.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"handleEndUnsaved", "handleRestartUnsaved"} {
		body := strings.Join(stripComments(funcBody(t, string(eu), fn)), "\n")
		i, j := strings.Index(body, "wgen := walletGeneration(walletPathFor(dest))"), strings.Index(body, "name, pass, uid := readRoamSession(dest)")
		k := strings.Index(body, "endUnsavedWallet(dest, name, pass, seFromHex(readRoamSessionSE(dest)), wgen)")
		if i < 0 || j < 0 || k < 0 || i > j || j > k {
			t.Errorf("%s: the wallet generation must be read before the session (at %d, %d) and handed to its wallet step (%d)", fn, i, j, k)
		}
	}
}
