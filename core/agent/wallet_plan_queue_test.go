package main

// NWP-20261031-07: the wallet activates each purchase at its own size and term (decided 2026-10-20,
// docs/product-decisions.md "a bigger plan starts at once ..."). recordPlan used to keep the MAX of every size and term it
// had seen, so a 10 GB top-up redeemed under a live 50 GB plan was priced at 50 GB x periods and could never be funded.
// Every test below has its own profile name and its own t.TempDir wallet.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

// pinQueueClock pins the local epoch and makes the jitter draw fail, which returns the full bound (2 epochs): a
// deterministic "ActivateAfter = now + 2".
func pinQueueClock(t *testing.T, epoch int64) {
	t.Helper()
	oldNow, oldRand := nowEpoch, jitterRand
	nowEpoch = func() int64 { return epoch }
	jitterRand = strings.NewReader("")
	t.Cleanup(func() { nowEpoch, jitterRand = oldNow, oldRand })
}

func queueWallet(t *testing.T) string {
	t.Helper()
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	return wp
}

// redeem is drainClaim's order: recordPlan first, the claim's tokens appended after.
func redeem(t *testing.T, wp string, gb int, periods int64) {
	t.Helper()
	if err := recordPlan(wp, periods, gb, false); err != nil {
		t.Fatal(err)
	}
	if err := appendTokens(wp, make([]BlindToken, gb*int(periods))); err != nil {
		t.Fatal(err)
	}
}

func mustLoad(t *testing.T, wp string) *Wallet {
	t.Helper()
	w, err := loadWallet(wp)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

// (a) the backlog row's own case.
func TestWalletPlanQueue_ATopUpUnderALivePlanIsPricedAtItsOwnSize(t *testing.T) {
	pinQueueClock(t, 100)
	wp := queueWallet(t)
	// live 50 GB x 3: activated, so its tokens are spent and the wallet holds none.
	if err := saveWallet(wp, &Wallet{PlanGB: 50, PlanPeriods: 3, PaidThrough: 200}); err != nil {
		t.Fatal(err)
	}
	redeem(t, wp, 10, 3)
	w := mustLoad(t, wp)
	if w.PlanGB != 10 || w.PlanPeriods != 3 || len(w.PlanQueue) != 0 {
		t.Fatalf("plan = %d x %d queue %v, want 10 x 3 and no queue", w.PlanGB, w.PlanPeriods, w.PlanQueue)
	}
	gb, periods, plain, blind := w.planPurchase(1000, false)
	if gb != 10 || periods != 3 || len(plain)+len(blind) != 30 {
		t.Fatalf("planPurchase = %d GB x %d with %d signatures, want 10 x 3 with 30 -- the top-up is stranded",
			gb, periods, len(plain)+len(blind))
	}
}

// queueGateway answers /quote with a movable epoch and /lease with Spent = what was presented, recording buy_gb.
type queueGateway struct {
	srv   *httptest.Server
	epoch int64
	buys  []int
}

func newQueueGateway(t *testing.T) *queueGateway {
	t.Helper()
	g := &queueGateway{}
	mux := http.NewServeMux()
	mux.HandleFunc("/quote", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"gb_per_token": 1, "current_epoch": g.epoch, "free_gb": 1})
	})
	mux.HandleFunc("/lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		g.buys = append(g.buys, req.BuyGB)
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: g.epoch + 90, DeadlineEpoch: g.epoch + 120,
			Spent: len(req.Tokens) + len(req.BlindTokens), WriteCaps: map[string]string{}})
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

// (b) a waiting 50 GB purchase, then a 10 GB one: queued, bought in order, the second behind a fresh jitter.
func TestWalletPlanQueue_ASecondPurchaseWaitsItsTurnBehindAFreshJitter(t *testing.T) {
	pinQueueClock(t, 100)
	wp := queueWallet(t)
	redeem(t, wp, 50, 3)
	redeem(t, wp, 10, 3)
	w := mustLoad(t, wp)
	if w.PlanGB != 50 || len(w.PlanQueue) != 1 || w.PlanQueue[0] != (PlanSpec{GB: 10, Periods: 3}) {
		t.Fatalf("plan = %d, queue = %v, want 50 with [10x3] queued", w.PlanGB, w.PlanQueue)
	}
	gw := newQueueGateway(t)
	g := newGatewayClient(gw.srv.URL, gwDefault)
	refs := map[string]int64{"blob/x": 1}

	gw.epoch, nowEpoch = 102, func() int64 { return 102 }
	if _, _, err := leaseRefs(g, wp, "queueprofb", refs, nil); err != nil {
		t.Fatalf("first lease: %v", err)
	}
	if len(gw.buys) != 1 || gw.buys[0] != 50 {
		t.Fatalf("first lease bought %v, want [50]", gw.buys)
	}
	w = mustLoad(t, wp)
	if w.PlanGB != 10 || w.PlanPeriods != 3 || len(w.PlanQueue) != 0 {
		t.Fatalf("after the 50 GB landed plan = %d x %d queue %v, want 10 x 3 and no queue", w.PlanGB, w.PlanPeriods, w.PlanQueue)
	}
	if w.ActivateAfter <= 102 {
		t.Fatalf("ActivateAfter = %d after promotion, want it in the future (> 102): the jitter restarts", w.ActivateAfter)
	}
	if _, _, err := leaseRefs(g, wp, "queueprofb", refs, nil); err != nil {
		t.Fatalf("held lease: %v", err)
	}
	if gw.buys[len(gw.buys)-1] != 0 {
		t.Fatalf("a lease inside the new jitter window bought %v, want nothing", gw.buys)
	}
	gw.epoch, nowEpoch = w.ActivateAfter, func() int64 { return w.ActivateAfter }
	if _, _, err := leaseRefs(g, wp, "queueprofb", refs, nil); err != nil {
		t.Fatalf("second lease: %v", err)
	}
	if got := gw.buys[len(gw.buys)-1]; got != 10 {
		t.Fatalf("the first lease past the jitter bought %d GB, want 10 (buys %v)", got, gw.buys)
	}
}

// (c) a shorter term after a longer one is not stretched.
func TestWalletPlanQueue_AShorterTermIsNotStretched(t *testing.T) {
	pinQueueClock(t, 100)
	wp := queueWallet(t)
	redeem(t, wp, 10, 12)
	redeem(t, wp, 10, 3)
	w := mustLoad(t, wp)
	if len(w.PlanQueue) != 1 || w.PlanQueue[0].Periods != 3 {
		t.Fatalf("queue = %v, want the 3-period purchase kept at 3", w.PlanQueue)
	}
	w.planActivated()
	if w.PlanPeriods != 3 {
		t.Fatalf("promoted term = %d, want 3 (not stretched to 12)", w.PlanPeriods)
	}
}

// (d) a publish keeps this phone's waiting purchase over a larger stored plan.
func TestWalletPlanQueue_WalletForPublishKeepsAWaitingPurchaseVerbatim(t *testing.T) {
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, Tokens: make([]Token, 30)}
	stored := &Wallet{PlanGB: 50, PlanPeriods: 12}
	out := walletForPublish(stored, local, nil)
	if out.PlanGB != 10 || out.PlanPeriods != 3 {
		t.Fatalf("published plan %d x %d over a waiting 10 x 3, want it unchanged", out.PlanGB, out.PlanPeriods)
	}
	queued := &Wallet{PlanGB: 50, PlanPeriods: 3, PlanQueue: []PlanSpec{{GB: 10, Periods: 3}}}
	out = walletForPublish(&Wallet{PlanGB: 100, PlanPeriods: 12}, queued, nil)
	if out.PlanGB != 50 || out.PlanPeriods != 3 || len(out.PlanQueue) != 1 {
		t.Fatalf("published %d x %d queue %v over a queued local, want 50 x 3 [10x3]", out.PlanGB, out.PlanPeriods, out.PlanQueue)
	}
	// nothing waiting: the account's larger plan still wins (a stale handset must not lower it).
	idle := walletForPublish(&Wallet{PlanGB: 50, PlanPeriods: 3}, &Wallet{PlanGB: 10, PlanPeriods: 3}, nil)
	if idle.PlanGB != 50 {
		t.Fatalf("idle publish plan = %d, want the account's 50", idle.PlanGB)
	}
}

// (e) a late restore orders the queue stored-first.
func TestWalletPlanQueue_ALateRestoreOrdersTheQueueStoredFirst(t *testing.T) {
	stored := &Wallet{PlanGB: 50, PlanPeriods: 3, Tokens: make([]Token, 150), PlanQueue: []PlanSpec{{GB: 20, Periods: 1}}}
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, BlindTokens: make([]BlindToken, 30)}
	m := mergeLateRestore(stored, local)
	if m.PlanGB != 50 || m.PlanPeriods != 3 {
		t.Fatalf("merged plan %d x %d, want the stored 50 x 3 next", m.PlanGB, m.PlanPeriods)
	}
	want := []PlanSpec{{GB: 20, Periods: 1}, {GB: 10, Periods: 3}}
	if len(m.PlanQueue) != 2 || m.PlanQueue[0] != want[0] || m.PlanQueue[1] != want[1] {
		t.Fatalf("merged queue %v, want %v (stored's first, then the session's)", m.PlanQueue, want)
	}
}

// (f) a queued claim drained in two calls is queued once, and a later purchase behind it keeps its own price.
func TestWalletPlanQueue_ADrainedTwiceIsQueuedOnce(t *testing.T) {
	pinQueueClock(t, 100)
	wp := queueWallet(t)
	redeem(t, wp, 50, 3)
	// the 10 GB claim drains in two calls: recordPlan runs on each, the tokens arrive in halves.
	if err := recordPlan(wp, 3, 10, false); err != nil {
		t.Fatal(err)
	}
	if err := appendTokens(wp, make([]BlindToken, 15)); err != nil {
		t.Fatal(err)
	}
	if err := recordPlan(wp, 3, 10, false); err != nil {
		t.Fatal(err)
	}
	if err := appendTokens(wp, make([]BlindToken, 15)); err != nil {
		t.Fatal(err)
	}
	if q := mustLoad(t, wp).PlanQueue; len(q) != 1 {
		t.Fatalf("queue = %v after a two-call drain, want ONE entry", q)
	}
	redeem(t, wp, 50, 3)
	w := mustLoad(t, wp)
	if len(w.PlanQueue) != 2 || w.PlanQueue[1] != (PlanSpec{GB: 50, Periods: 3}) {
		t.Fatalf("queue = %v, want [10x3 50x3]", w.PlanQueue)
	}
	w.BlindTokens = w.BlindTokens[150:] // the first 50 GB landed: its 150 are spent
	w.planActivated()
	w.planActivated()
	if w.PlanGB != 50 || w.PlanPeriods != 3 || len(w.PlanQueue) != 0 {
		t.Fatalf("after two promotions plan = %d x %d queue %v, want 50 x 3", w.PlanGB, w.PlanPeriods, w.PlanQueue)
	}
	if w.PlanGB*int(w.PlanPeriods) != 150 {
		t.Fatalf("the later purchase is priced at %d, want 150", w.PlanGB*int(w.PlanPeriods))
	}
}

// (h) RF-001: the cap fold is the only durable wallet and is taken before the lease, so it must carry the
// queue-consistent state a landed purchase leaves. Restoring the PUBLISHED wallet right after a queued activation
// has to price the next purchase at the promoted size.
func TestWalletPlanQueue_TheCapFoldPublishesThePromotedQueue(t *testing.T) {
	pinQueueClock(t, 100)
	wp := queueWallet(t)
	redeem(t, wp, 50, 3)
	redeem(t, wp, 10, 3)
	w := mustLoad(t, wp)
	buyGB, periods, plain, blind := w.planPurchase(100, true)
	if buyGB != 50 || periods != 3 || len(plain)+len(blind) != 150 {
		t.Fatalf("take = %d x %d with %d sigs, want 50 x 3 with 150", buyGB, periods, len(plain)+len(blind))
	}
	folded := w.afterActivation()
	if w.PlanGB != 50 || len(w.PlanQueue) != 1 {
		t.Fatalf("afterActivation mutated the live wallet: plan %d queue %v", w.PlanGB, w.PlanQueue)
	}
	wj, err := json.Marshal(walletForPublish(nil, folded, nil))
	if err != nil {
		t.Fatal(err)
	}
	var restored Wallet
	if err := json.Unmarshal(wj, &restored); err != nil {
		t.Fatal(err)
	}
	if restored.PlanGB != 10 || restored.PlanPeriods != 3 || len(restored.PlanQueue) != 0 || restored.ActivateAfter <= 100 {
		t.Fatalf("restored plan %d x %d queue %v after %d, want 10 x 3, no queue, a fresh jitter", restored.PlanGB, restored.PlanPeriods, restored.PlanQueue, restored.ActivateAfter)
	}
	restored.ActivateAfter = 0
	gb, per, p, b := restored.planPurchase(100, true)
	if gb != 10 || per != 3 || len(p)+len(b) != 30 {
		t.Fatalf("restored wallet buys %d x %d with %d sigs, want 10 x 3 with 30", gb, per, len(p)+len(b))
	}
}

// RF-002: the cap fold publishes the promoted queue BEFORE the lease answers. A 200 that charged nothing (a grace
// lease on a declared purchase) bought nothing, so what the store holds afterwards must be the UNPROMOTED wallet:
// the original plan, the queue, and every unspent signature.
func TestWalletPlanQueue_TheCapFoldRestoresTheOriginalOnAGraceLease(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.buyReply = &leaseInfo{ThroughEpoch: 43} // HTTP 200, Spent 0, nothing bought
	t.Setenv("GATEWAY_URL", g.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(g.srv.URL, gwDefault).buyFaucet(180)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 50, PlanPeriods: 3, PlanQueue: []PlanSpec{{GB: 10, Periods: 3}}}); err != nil {
		t.Fatal(err)
	}
	if err := markWalletRestoreLanded(wpath, walletGeneration(wpath)); err != nil { // else the fold publishes nothing
		t.Fatal(err)
	}
	name, pass := "queuegraceu", "the lease buys nothing"
	dk := deriveKey(name, pass)
	bn := capBegin()
	capSetSession(name, pass, dk)
	h := postBlob("s3", []byte(strings.Repeat("d", 4096)))
	putRef("s3", profileRefV2(name, pass), h)
	capFlush(bn)

	g.mu.Lock()
	buys := g.buyCalls
	var published []*Wallet
	for _, b := range g.objs {
		if pw := openWallet(dk, b); pw != nil {
			published = append(published, pw)
		}
	}
	g.mu.Unlock()
	if buys == 0 {
		t.Fatal("the fixture never declared a purchase -- this test would pass for the wrong reason")
	}
	if len(published) != 1 {
		t.Fatalf("%d published wallets, want exactly the one re-fold", len(published))
	}
	r := published[0]
	if r.PlanGB != 50 || r.PlanPeriods != 3 || len(r.PlanQueue) != 1 || r.PlanQueue[0] != (PlanSpec{GB: 10, Periods: 3}) || r.balance() != 180 {
		t.Fatalf("published plan %d x %d queue %v with %d sigs, want 50 x 3, [10x3], 180 -- nothing was bought, so nothing may be promoted or spent",
			r.PlanGB, r.PlanPeriods, r.PlanQueue, r.balance())
	}
	if l := mustLoad(t, wpath); l.PlanGB != 50 || len(l.PlanQueue) != 1 || l.balance() != 180 {
		t.Fatalf("local wallet plan %d queue %v with %d sigs, want 50, [10x3], 180", l.PlanGB, l.PlanQueue, l.balance())
	}
}

// openWallet is a stored object read as a sealed wallet, or nil for anything else (unseal panics on a foreign blob).
func openWallet(dk, b []byte) (w *Wallet) {
	defer func() {
		if recover() != nil {
			w = nil
		}
	}()
	var pw Wallet
	if json.Unmarshal(unseal(dk, b), &pw) != nil || pw.PlanGB == 0 {
		return nil
	}
	return &pw
}
