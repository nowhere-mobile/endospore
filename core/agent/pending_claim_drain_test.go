package main

// NWP-20261202-01 (h53 #6 slice 2, the drain half; h55 #1's webhook-lag edge): a sign-in whose wallet holds pending
// claim codes arms one deferred drain; it fires at a random moment 10-40 minutes later, only while that session and its
// wallet generation stand, and publishes the tokens and the clear in one wallet save. The wait is a hook here (no
// wall-clock waits): the fire runs only when a test releases it. Every test has its own profile name and code.

import (
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// pdEnv is one stored session (cpStored) whose wallet holds codes and is published, with a counting front before the
// gateway: every request the drain sends, /issue and the store's, is counted from the moment the env is ready.
type pdEnv struct {
	dest, wp, name, pass string
	gw                   *pcGateway
	reqs, issues         atomic.Int64
}

func pdSession(t *testing.T, name string, funded map[string]int, codes ...string) *pdEnv {
	t.Helper()
	e := &pdEnv{name: name, pass: "the passphrase of " + name}
	e.gw = newPCGateway(t, funded)
	e.dest, e.wp = cpStored(t, e.gw, name, true)
	blobCache, contentCache = nil, nil
	oldSleep := claimSealSleep
	claimSealSleep = func(time.Duration) {}
	t.Cleanup(func() { claimSealSleep = oldSleep; pendingClaimBeforeClear = nil })
	if err := saveWallet(e.wp, &Wallet{PendingClaims: codes}); err != nil {
		t.Fatal(err)
	}
	dk := resolveDK("s3", e.name, e.pass, nil)
	if dk == nil {
		t.Fatal("the profile does not resolve")
	}
	if _, err := sealWalletDurable("s3", e.name, e.pass, dk, e.wp); err != nil {
		t.Fatalf("publish: %v", err)
	}
	inner, err := url.Parse(os.Getenv("GATEWAY_URL"))
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(inner)
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.reqs.Add(1)
		if r.URL.Path == "/issue" {
			e.issues.Add(1)
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	t.Setenv("GATEWAY_URL", front.URL)
	return e
}

// pdHook replaces the drain's wait and its done seam. The wait signals entered and blocks until the test releases it.
// Its cleanup supersedes any armed fire (so one the test did not release exits unsent), releases it, waits for every
// started goroutine to end and restores the seams: no goroutine outlives its test.
type pdHook struct {
	entered, release, done chan struct{}
	started, released      int
	finished               int
}

func pdHooks(t *testing.T) *pdHook {
	t.Helper()
	h := &pdHook{entered: make(chan struct{}, 8), release: make(chan struct{}, 8), done: make(chan struct{}, 8)}
	oldSleep, oldDone := pendingDrainSleep, pendingDrainDone
	pendingDrainSleep = func(d time.Duration) {
		if d < pendingDrainMin || d > pendingDrainMax {
			t.Errorf("the drain's delay %v is outside [%v, %v]", d, pendingDrainMin, pendingDrainMax)
		}
		h.entered <- struct{}{}
		<-h.release
	}
	pendingDrainDone = func() { h.done <- struct{}{} }
	t.Cleanup(func() {
		pendingDrainSeq.Add(1)
		for ; h.released < h.started; h.released++ {
			h.release <- struct{}{}
		}
		for ; h.finished < h.started; h.finished++ {
			select {
			case <-h.done:
			case <-time.After(60 * time.Second):
				t.Error("an armed drain did not end")
				h.finished = h.started
			}
		}
		pendingDrainSleep, pendingDrainDone = oldSleep, oldDone
	})
	return h
}

// arm arms the drain for e and reports whether a goroutine was started.
func (h *pdHook) arm(e *pdEnv) bool {
	before := pendingDrainSeq.Load()
	armPendingClaimDrain(e.dest, e.name, e.pass)
	if pendingDrainSeq.Load() != before {
		h.started++
		return true
	}
	return false
}

// waitEntered waits until the armed goroutine is in its wait. A goroutine that ends first never waited.
func (h *pdHook) waitEntered(t *testing.T) {
	t.Helper()
	select {
	case <-h.entered:
	case <-h.done:
		h.finished++
		t.Fatal("drained without waiting")
	case <-time.After(60 * time.Second):
		t.Fatal("the armed drain never reached its wait")
	}
}

// fire releases the waiting goroutine and waits for it to end.
func (h *pdHook) fire(t *testing.T) {
	t.Helper()
	h.release <- struct{}{}
	h.released++
	select {
	case <-h.done:
		h.finished++
	case <-time.After(60 * time.Second):
		t.Fatal("the released drain did not end")
	}
}

func pdHasCode(w *Wallet, code string) bool {
	return w != nil && pcHolds(w, code)
}

// The row's pin: the first profile-tagged request is separated from the arm by the random wait. Nothing is sent
// before the moment; at it, /issue is reached and one publish carries the tokens and the clear.
func TestPendingDrain_NoRequestBeforeTheMoment(t *testing.T) {
	const code = "pdM1AAAAAAAAAAAAAAAAAAAA"
	e := pdSession(t, "pd-moment", map[string]int{code: 10}, code)
	h := pdHooks(t)
	if !h.arm(e) {
		t.Fatal("a wallet with a pending code armed nothing")
	}
	h.waitEntered(t)
	if n := e.reqs.Load(); n != 0 {
		t.Fatalf("%d request(s) sent before the drain's moment, want 0", n)
	}
	h.fire(t)
	if got := e.gw.issuedFor(code); got != 10 {
		t.Fatalf("the gateway issued %d tokens for the code, want 10", got)
	}
	if w := pcLoad(t, e.wp); len(w.BlindTokens) != 10 || pdHasCode(w, code) {
		t.Fatalf("the wallet: %d tokens, code held %v; want 10 and no code", len(w.BlindTokens), pdHasCode(w, code))
	}
	blobCache, contentCache = nil, nil
	sw := storedWallet(t, e.name, e.pass)
	if sw == nil || len(sw.BlindTokens) != 10 || pdHasCode(sw, code) {
		n := -1
		if sw != nil {
			n = len(sw.BlindTokens)
		}
		t.Fatalf("the stored #wallet head: %d tokens, code held %v; want 10 and no code (one publish)", n, pdHasCode(sw, code))
	}
}

func TestPendingDrain_DelayIsRandomAndBounded(t *testing.T) {
	distinct := map[time.Duration]bool{}
	for i := 0; i < 200; i++ {
		d := pendingDrainDelay()
		if d < pendingDrainMin || d > pendingDrainMax {
			t.Fatalf("draw %d = %v, outside [%v, %v]", i, d, pendingDrainMin, pendingDrainMax)
		}
		distinct[d] = true
	}
	if len(distinct) < 2 {
		t.Fatalf("200 draws gave %d distinct delay(s), want at least 2", len(distinct))
	}
}

// pdSkipCase arms a drain, changes the state while it waits, fires it and expects no request and the code kept.
func pdSkipCase(t *testing.T, name, code string, change func(e *pdEnv)) {
	t.Helper()
	e := pdSession(t, name, map[string]int{code: 10}, code)
	h := pdHooks(t)
	if !h.arm(e) {
		t.Fatal("a wallet with a pending code armed nothing")
	}
	h.waitEntered(t)
	change(e)
	h.fire(t)
	if n := e.reqs.Load(); n != 0 {
		t.Fatalf("the drain sent %d request(s), want 0", n)
	}
	if got := e.gw.issuedFor(code); got != 0 {
		t.Fatalf("the gateway issued %d tokens, want 0", got)
	}
	if w := pcLoad(t, e.wp); !pdHasCode(w, code) {
		t.Fatal("the code left the wallet: it must stay for the next session")
	}
}

func TestPendingDrain_SessionEndedFirstSendsNothing(t *testing.T) {
	pdSkipCase(t, "pd-ended", "pdS1AAAAAAAAAAAAAAAAAAAA", func(e *pdEnv) {
		if err := os.Remove(filepath.Join(e.dest, ".roamsession")); err != nil {
			t.Fatal(err)
		}
	})
}

func TestPendingDrain_ANewSignInFirstSendsNothing(t *testing.T) {
	pdSkipCase(t, "pd-newsignin", "pdS2AAAAAAAAAAAAAAAAAAAA", func(e *pdEnv) {
		if err := bumpWalletGeneration(e.wp); err != nil {
			t.Fatal(err)
		}
		provenWallet(t, e.wp) // only the generation check stops it
	})
}

func TestPendingDrain_LocalSessionSendsNothing(t *testing.T) {
	pdSkipCase(t, "pd-local", "pdS3AAAAAAAAAAAAAAAAAAAA", func(e *pdEnv) { markLocalSession(e.dest) })
}

func TestPendingDrain_ColdLockedSendsNothing(t *testing.T) {
	pdSkipCase(t, "pd-coldlock", "pdS4AAAAAAAAAAAAAAAAAAAA", func(e *pdEnv) {
		if err := os.WriteFile(filepath.Join(e.dest, ".coldlock"), []byte(e.name+"\n12\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if coldLockedUID(e.dest) == "" {
			t.Fatal("precondition: the cold-lock marker does not read back")
		}
	})
}

func TestPendingDrain_RestartPendingSendsNothing(t *testing.T) {
	t.Cleanup(resetRestartState)
	pdSkipCase(t, "pd-restart", "pdS5AAAAAAAAAAAAAAAAAAAA", func(e *pdEnv) { setRestartState("PENDING", e.name, "12") })
}

func TestPendingDrain_ASessionOpHeldSendsNothing(t *testing.T) {
	held := false
	t.Cleanup(func() {
		if held {
			sessionMu.Unlock()
		}
	})
	pdSkipCase(t, "pd-held", "pdS6AAAAAAAAAAAAAAAAAAAA", func(e *pdEnv) { sessionMu.Lock(); held = true })
	sessionMu.Unlock()
	held = false
}

// Moderator reason 1 (revision 2): a sign-out of A and a sign-in of B that try to land between A's /issue and A's
// publish wait for the fire. pendingClaimBeforeClear runs inside the drain, after A's tokens landed and before the clear
// and the seal; a swap that gets sessionMu there would move A's tokens into B's wallet and publish B's under A's head.
func TestPendingDrain_ASessionSwapMidDrainWaitsForThePublish(t *testing.T) {
	const code = "pdW1AAAAAAAAAAAAAAAAAAAA"
	const nameB = "pd-swap-b"
	passB := "the passphrase of " + nameB
	e := pdSession(t, "pd-swap-a", map[string]int{code: 10}, code)
	h := pdHooks(t)
	bTokens := []BlindToken{{Msg: "pd-swap-b-token-1", Sig: "s1"}, {Msg: "pd-swap-b-token-2", Sig: "s2"}}
	swapToB := func() {
		if err := markRoamSession(e.dest, nameB, passB, "13", ""); err != nil {
			t.Error(err)
		}
		if err := saveWallet(e.wp, &Wallet{BlindTokens: append([]BlindToken(nil), bTokens...)}); err != nil {
			t.Error(err)
		}
		if err := bumpWalletGeneration(e.wp); err != nil {
			t.Error(err)
		}
		provenWallet(t, e.wp)
	}
	swapped := false
	pendingClaimBeforeClear = func() {
		if sessionMu.TryLock() {
			swapToB()
			sessionMu.Unlock()
			swapped = true
		}
	}
	if !h.arm(e) {
		t.Fatal("a wallet with a pending code armed nothing")
	}
	h.waitEntered(t)
	h.fire(t)
	pendingClaimBeforeClear = nil
	if !swapped {
		sessionMu.Lock() // the sign-in that waited for the fire
		swapToB()
		sessionMu.Unlock()
	}
	if swapped {
		t.Error("a session swap ran while the drain held minted tokens")
	}
	isB := map[string]bool{}
	for _, b := range bTokens {
		isB[b.Msg] = true
	}
	blobCache, contentCache = nil, nil
	sa := storedWallet(t, e.name, e.pass)
	if sa == nil {
		t.Fatal("A has no stored wallet")
	}
	aMsgs := map[string]bool{}
	for _, b := range sa.BlindTokens {
		if isB[b.Msg] {
			t.Fatal("B's wallet was published under A's head")
		}
		aMsgs[b.Msg] = true
	}
	if len(sa.BlindTokens) != 10 || pdHasCode(sa, code) {
		t.Fatalf("A's stored wallet: %d tokens, code held %v; want A's 10 and no code", len(sa.BlindTokens), pdHasCode(sa, code))
	}
	for _, b := range pcLoad(t, e.wp).BlindTokens {
		if aMsgs[b.Msg] {
			t.Fatal("A's tokens landed in B's wallet")
		}
	}
}

func TestPendingDrain_NothingPendingArmsNothing(t *testing.T) {
	e := pdSession(t, "pd-nothing", nil)
	h := pdHooks(t)
	if h.arm(e) {
		t.Fatal("a wallet with no pending code armed a drain")
	}
	select {
	case <-h.entered:
		t.Fatal("the drain's wait was entered with nothing pending")
	default:
	}
	if n := e.reqs.Load(); n != 0 {
		t.Fatalf("arming sent %d request(s), want 0", n)
	}
}

// h55 #1's edge: an unknown code (the payment webhook may lag) is kept at the first empty answer, with its hash in
// pending_claim_misses, and cleared with the hash at the next session's. No miss holds the code itself.
func TestPendingDrain_UnknownIsRetriedOnceAtTheNextSession(t *testing.T) {
	const code = "pdU1AAAAAAAAAAAAAAAAAAAA"
	e := pdSession(t, "pd-unknown", nil, code)
	h := pdHooks(t)
	noRawCode := func(where string, w *Wallet) {
		t.Helper()
		if w == nil {
			return
		}
		for _, k := range w.PendingClaimMisses {
			if strings.Contains(k, code) {
				t.Fatalf("%s: a miss holds the code itself", where)
			}
		}
	}
	// Run 1: this session.
	if !h.arm(e) {
		t.Fatal("run 1 armed nothing")
	}
	h.waitEntered(t)
	h.fire(t)
	if n := e.issues.Load(); n != 1 {
		t.Fatalf("run 1 sent %d /issue request(s), want 1", n)
	}
	w := pcLoad(t, e.wp)
	noRawCode("run 1, local", w)
	if !pdHasCode(w, code) || len(w.PendingClaimMisses) != 1 || w.PendingClaimMisses[0] != pendingClaimSeenKey(code) {
		t.Fatalf("run 1: code kept %v, %d miss(es); want the code kept and exactly its hash", pdHasCode(w, code), len(w.PendingClaimMisses))
	}
	blobCache, contentCache = nil, nil
	sw := storedWallet(t, e.name, e.pass)
	noRawCode("run 1, stored", sw)
	if !pdHasCode(sw, code) || sw == nil || len(sw.PendingClaimMisses) != 1 {
		t.Fatal("run 1: the stored wallet does not carry the kept code and its one miss")
	}
	// Run 2: the next session's drain.
	if !h.arm(e) {
		t.Fatal("run 2 armed nothing")
	}
	h.waitEntered(t)
	h.fire(t)
	if n := e.issues.Load(); n != 2 {
		t.Fatalf("after run 2, %d /issue request(s) in all, want 2", n)
	}
	w = pcLoad(t, e.wp)
	noRawCode("run 2, local", w)
	if pdHasCode(w, code) || len(w.PendingClaimMisses) != 0 {
		t.Fatalf("run 2: code held %v, %d miss(es); want neither", pdHasCode(w, code), len(w.PendingClaimMisses))
	}
	blobCache, contentCache = nil, nil
	sw = storedWallet(t, e.name, e.pass)
	noRawCode("run 2, stored", sw)
	if sw == nil || pdHasCode(sw, code) || len(sw.PendingClaimMisses) != 0 {
		t.Fatal("run 2: the stored wallet still carries the code or its miss")
	}
}

// walletForPublish and mergeLateRestore keep a miss whose code is pending (on either side), drop one whose code is
// gone, and deduplicate.
func TestPendingDrain_MergeCarriesTheMiss(t *testing.T) {
	const a, b, gone = "pdG1AAAAAAAAAAAAAAAAAAAA", "pdG1BBBBBBBBBBBBBBBBBBBB", "pdG1GGGGGGGGGGGGGGGGGGGG"
	ka, kb, kg := pendingClaimSeenKey(a), pendingClaimSeenKey(b), pendingClaimSeenKey(gone)
	stored := &Wallet{PendingClaims: []string{a}, PendingClaimMisses: []string{ka, kg}}
	local := &Wallet{PendingClaims: []string{b}, PendingClaimMisses: []string{kb, kg, ka}}
	check := func(what string, got []string, want ...string) {
		t.Helper()
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("%s: %d miss(es) %v, want %d", what, len(got), got, len(want))
		}
	}
	check("walletForPublish", walletForPublish(stored, local, map[string]bool{}).PendingClaimMisses, kb, ka)
	check("walletForPublish, a seen", walletForPublish(stored, local, map[string]bool{ka: true}).PendingClaimMisses, kb)
	check("mergeLateRestore", mergeLateRestore(stored, local).PendingClaimMisses, ka, kb)
	check("mergeLateRestore, stored only", mergeLateRestore(stored, nil).PendingClaimMisses, ka)
	check("mergeLateRestore, local only", mergeLateRestore(nil, local).PendingClaimMisses, kb)
}
