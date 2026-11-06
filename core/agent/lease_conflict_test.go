package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sync"
	"testing"
)

// NWP-20260906-03. A gateway 409 ("token already spent") used to reach the generic fail() in capFlush's
// entitled arm -- a panic, raised BEFORE settlePayment and saveWallet on the following lines. planPurchase
// had already TAKEN the tokens in memory, so nothing persisted, the disk wallet still held them, and the
// 120s sync loop re-presented the same dead nonces forever. A 409 is deterministic, so that is a PERMANENT
// wedge: the seal never completes and logoff re-arms the session rather than signing out. On an amnesiac
// device the refused seal is the only copy of that session.
//
// The fix withdraws the purchase and re-leases with buy_gb=0, which the gateway answers without looking at
// tokens at all. The tokens are KEPT, not dropped: redemption is atomic and the 409 body names no nonce, so
// presenting five where one is dead rejects all five and dropping them would forfeit four the customer paid
// for.

// conflictGateway 409s any lease that DECLARES a purchase and serves any lease that does not, recording what
// it was asked for. It models the real gateway's shape: token collection sits under `if req.BuyGB > 0`.
type conflictGateway struct {
	srv       *httptest.Server
	mu        sync.Mutex
	buyCalls  int   // leases that declared a purchase (these 409)
	freeBuys  int   // leases that declared none (these succeed)
	lastBuyGB int   // buy_gb on the most recent lease
	through   int64 // ThroughEpoch handed back by the token-less arm
	// buyReply, when set, answers a purchase-declaring lease 200 with this body instead of 409 --
	// the gateway grace-leasing a declaration it will not or cannot honour. Nil (the zero value) keeps
	// every existing test on the 409 behaviour they were written for. WriteCaps are filled in by the
	// handler, since only it knows the refs. NWP-20260915-26.
	buyReply *leaseInfo
	// retryPlanGB is the plan size named on the TOKEN-LESS arm -- what a real gateway sends a profile
	// that still holds a live grant. Zero (the default) is the lapsed/unknown profile every other test
	// here models. NWP-20260915-26.
	retryPlanGB int
	// conflictBody, when non-nil, is the body of the purchase-declaring 409 (NWP-20261020-03); nil keeps the
	// bodiless 409 every older test was written for.
	conflictBody []byte
	// objs is every object PUT through /obj, by key (NWP-20261031-07: a test reads back the published wallet).
	objs map[string][]byte
}

func newConflictGateway(t *testing.T, failNonConflict int) *conflictGateway {
	t.Helper()
	g := &conflictGateway{through: 99}
	objs := map[string][]byte{}
	g.objs = objs
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		g.mu.Lock()
		defer g.mu.Unlock()
		if r.Method == http.MethodPut {
			b, _ := io.ReadAll(r.Body)
			objs[k] = b
			w.WriteHeader(http.StatusOK)
			return
		}
		b, ok := objs[k]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Write(b)
	})
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(r.URL.Query().Get("ref"))})
	})
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42})
	})
	var n int
	mux.HandleFunc("POST /tokens", func(w http.ResponseWriter, r *http.Request) {
		var req tokensReq
		json.NewDecoder(r.Body).Decode(&req)
		var out tokensResp
		for i := 0; i < req.Count; i++ {
			n++
			out.Tokens = append(out.Tokens, Token{Denom: "1GBmo", Nonce: "t" + string(rune('a'+n)), Exp: 1 << 62, Sig: "sig"})
		}
		json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		g.mu.Lock()
		defer g.mu.Unlock()
		if req.Free {
			w.WriteHeader(http.StatusPaymentRequired) // free tier full -> route to the entitled path
			return
		}
		g.lastBuyGB = req.BuyGB
		if req.BuyGB > 0 {
			g.buyCalls++
			// failNonConflict lets one test prove the arm is 409-ONLY.
			if failNonConflict != 0 {
				w.WriteHeader(failNonConflict)
				return
			}
			if g.buyReply != nil {
				out := *g.buyReply
				out.WriteCaps = map[string]string{}
				for ref := range req.Refs {
					out.WriteCaps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
				}
				json.NewEncoder(w).Encode(out)
				return
			}
			if g.conflictBody != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusConflict)
				w.Write(g.conflictBody)
				return
			}
			w.WriteHeader(http.StatusConflict) // "token already spent"
			return
		}
		g.freeBuys++
		caps := map[string]string{}
		for ref := range req.Refs {
			caps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: g.through, Spent: 0, WriteCaps: caps, PlanGB: g.retryPlanGB})
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

// capSealWith drives one cap-mode seal against g, returning the wallet as it stands afterwards.
func capSealWith(t *testing.T, g *conflictGateway, name, pass string) (*Wallet, string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", g.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)

	toks, err := newGatewayClient(g.srv.URL, gwDefault).buyFaucet(5)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}); err != nil {
		t.Fatal(err)
	}
	dk := deriveKey(name, pass)
	bn := capBegin()
	capSetSession(name, pass, dk)
	h := postBlob("s3", bytes.Repeat([]byte("d"), 4096))
	putRef("s3", profileRefV2(name, pass), h)
	capFlush(bn)

	after, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	return after, wpath
}

// TestCapFlush409WithdrawsThePurchaseAndLandsTheWrite is the wedge. The seal must COMPLETE, and the tokens
// must survive it.
func TestCapFlush409WithdrawsThePurchaseAndLandsTheWrite(t *testing.T) {
	g := newConflictGateway(t, 0)
	after, _ := capSealWith(t, g, "conflictu", "the gateway says already spent")

	g.mu.Lock()
	buys, retries, lastGB := g.buyCalls, g.freeBuys, g.lastBuyGB
	g.mu.Unlock()

	if buys == 0 {
		t.Fatal("the mock never saw a purchase-declaring lease -- the fixture did not reach the entitled arm")
	}
	if retries == 0 {
		t.Fatal("no token-less lease followed the 409: the seal did not land, which is the wedge this fixes")
	}
	if lastGB != 0 {
		t.Fatalf("the retry still declared buy_gb=%d; it must withdraw the purchase, or the gateway collects "+
			"tokens again and 409s identically forever", lastGB)
	}
	if after.balance() != 5 {
		t.Fatalf("wallet holds %d token(s) after a 409, want 5 -- redemption is atomic and the 409 names no "+
			"nonce, so tokens presented alongside a dead one are still good and must not be forfeited",
			after.balance())
	}
}

// TestCapFlush409DoesNotStampPaidThrough. recordCoverage assigns PaidThrough from ANY 200, and the
// token-less retry is answered by the free window or by grace. Stamping it would paint a live plan on the
// Storage screen for a purchase that just failed.
func TestCapFlush409DoesNotStampPaidThrough(t *testing.T) {
	g := newConflictGateway(t, 0)
	after, _ := capSealWith(t, g, "coverageu", "the gateway says already spent")

	if after.PaidThrough == g.through {
		t.Fatalf("PaidThrough was stamped %d from a lease that bought NOTHING -- with PlanGB still set the "+
			"chooser paints a plan the gateway holds no grant for, telling a customer whose purchase failed "+
			"that it succeeded", after.PaidThrough)
	}
}

// TestCapFlushNon409FailureStillFails pins that the arm is 409-ONLY. A 503 from the edge is retryable and
// must keep failing the seal; converting it into a token-less lease would silently buy nothing on a
// transient error.
func TestCapFlushNon409FailureStillFails(t *testing.T) {
	g := newConflictGateway(t, http.StatusServiceUnavailable)
	defer func() {
		if recover() == nil {
			t.Fatal("a 503 entitled lease did NOT fail the seal -- the 409 arm must not swallow retryable errors")
		}
	}()
	capSealWith(t, g, "transientu", "the gateway is briefly unavailable")
}

// TestLeaseRefs409RetriesWithoutBuying covers payRent's twin. It does not wedge the seal (maybePayRent
// recovers), but returning early leaves the WHOLE-FOOTPRINT RENEWAL permanently stopped, and that renewal is
// the only thing keeping cold refs off their deadlines.
func TestLeaseRefs409RetriesWithoutBuying(t *testing.T) {
	g := newConflictGateway(t, 0)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	toks, err := newGatewayClient(g.srv.URL, gwDefault).buyFaucet(5)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}); err != nil {
		t.Fatal(err)
	}
	gc := newGatewayClient(g.srv.URL, gwDefault)
	if _, _, err := leaseRefs(gc, wpath, "profX", map[string]int64{"blob/a": 8 * giB}, nil); err != nil {
		t.Fatalf("leaseRefs returned %v on a 409; it must withdraw the purchase and renew without buying, or "+
			"the whole-footprint renewal stops for good and cold refs drift onto their deadlines", err)
	}
	after, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if after.balance() != 5 {
		t.Fatalf("wallet holds %d token(s) after a 409, want 5 -- none were charged, so none may be lost",
			after.balance())
	}
}

// TestCapFlushDoesNotStampATermFromAGraceLease is capFlush's half of NWP-20260915-26, and it exists because
// TWO mutants survived without it: reverting this gate to the shipped `!boughtNothing`, and gating it on
// `buyGB > 0` instead. Both survived a full suite, which means nothing at all covered capFlush's recording
// gate -- and capFlush is the path where the bug actually bites, since a lapsed profile over the free
// allowance reaches the entitled arm on every seal.
//
// The shape here is the one that makes `buyGB > 0` insufficient rather than merely inelegant: the device
// DECLARES a purchase and the gateway answers 200 with a grace term, having bought nothing. That is not a
// contrived reply. handleEntitledLease grace-leases a declaration whose signatures do not verify, and a
// live-bytes read error grace-leases before buy_gb is validated at all -- and collectTokens silently skips
// a token that fails Verify, so credit that expired unnoticed (NWP-20260915-25) produces exactly this.
func TestCapFlushDoesNotStampATermFromAGraceLease(t *testing.T) {
	g := newConflictGateway(t, 0)
	// graceLease's real body: through = now + 1, nothing spent, and no plan named.
	g.buyReply = &leaseInfo{ThroughEpoch: 43}
	after, _ := capSealWith(t, g, "graceu", "the gateway holds no grant for this key")

	g.mu.Lock()
	buys, lastGB := g.buyCalls, g.lastBuyGB
	g.mu.Unlock()
	if buys == 0 || lastGB == 0 {
		t.Fatalf("the fixture never declared a purchase (buys=%d last_buy_gb=%d) -- this test would then "+
			"pass for the wrong reason, and the declaration is the whole point of it", buys, lastGB)
	}
	if after.PaidThrough == 43 {
		t.Fatalf("PaidThrough was stamped 43 from a lease that bought NOTHING. We asked to buy; the gateway " +
			"said 'you may write' and sold us no term. Recording it is how a lapsed plan came to read as a " +
			"live one with a day left -- and then, once the Storage screen learned to notice the gateway " +
			"disagreeing, as 'our servers don't show this plan against this profile'.")
	}
}

// TestCapFlushStampsATermTheGatewayCharged is the other direction, so the gate above cannot be satisfied by
// simply never recording anything. A seal that genuinely buys its term must still say so, or the Storage
// screen reports "Plan expired" to somebody who has just paid.
func TestCapFlushStampsATermTheGatewayCharged(t *testing.T) {
	g := newConflictGateway(t, 0)
	// handleEntitledLease's purchase arm: nonces verified, a grant appended in the same transaction, and
	// the post-lease plan size named on the way out.
	g.buyReply = &leaseInfo{ThroughEpoch: 77, Spent: 1, PlanGB: 1}
	after, _ := capSealWith(t, g, "boughtu", "the gateway charged for the term")

	if after.PaidThrough != 77 {
		t.Fatalf("PaidThrough = %d, want 77 -- the gateway charged for this term and named the grant it "+
			"created, and a customer who has just paid must not be told their plan expired", after.PaidThrough)
	}
}

// TestAFailedRenewalStillLearnsTheTermTheCustomerHolds retires the WITHDRAWAL LATCH and pins why.
//
// NWP-20260906-03 added `!withdrew` (and capFlush's `!boughtNothing`) when the recording gate was bare, and
// it was then doing the whole job of stopping a false term. leaseBoughtCoverage does that job properly now,
// and -03's own tests stay green on it: a failed purchase against a profile with NO live grant is answered
// by grace, which spends nothing and names no plan, so nothing is recorded.
//
// ⚠ WHAT THE LATCH STILL DID WAS SUPPRESS A TRUE TERM, PERMANENTLY. The re-lease declares buy_gb=0, so
// `owed` and therefore Spent are 0 by construction; the only limb it could veto was PlanGB, which is
// positive only when the gateway HOLDS a live grant -- and that reply carries through = LatestThrough(now),
// the customer's real purchased term. And the 409 does not clear: settlePayment returns every presented
// token to the wallet, nothing prunes a spent nonce, and capFlush says it plainly -- "DETERMINISTIC --
// re-presenting the same nonces reproduces it exactly". So planPending stays true, every later lease
// re-declares and re-409s, and the term would be withheld FOREVER: a customer holding 300 days reads
// "Plan expired" and is routed to buy a plan they already own. That is NWP-20260829-06 again, through the
// last door still open to it.
func TestAFailedRenewalStillLearnsTheTermTheCustomerHolds(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.retryPlanGB = 1 // a LIVE grant: the re-lease reports the term the customer already holds
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	toks, err := newGatewayClient(g.srv.URL, gwDefault).buyFaucet(5)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}); err != nil {
		t.Fatal(err)
	}
	_, bought, err := leaseRefs(newGatewayClient(g.srv.URL, gwDefault), wpath, "profRenew", map[string]int64{"blob/a": 8 * giB}, nil)
	if err != nil {
		t.Fatalf("leaseRefs: %v", err)
	}
	g.mu.Lock()
	buys, retries := g.buyCalls, g.freeBuys
	g.mu.Unlock()
	if buys == 0 || retries == 0 {
		t.Fatalf("the fixture did not reach the 409-then-withdraw path (buys=%d retries=%d) -- without both "+
			"legs this test asserts nothing about the latch", buys, retries)
	}
	if !bought {
		t.Fatal("the lease that followed a 409 reported that it bought no term, but the gateway answered it " +
			"from a LIVE grant and named the plan. The purchase failed; the TERM the customer already holds " +
			"did not. Withholding it here is permanent, because the 409 recurs on every seal.")
	}
}

// TestAFailedPurchaseWithNoGrantStillRecordsNothing is the other half, and it is what NWP-20260906-03
// actually asked for. The latch is gone, so this must hold on leaseBoughtCoverage alone: a 409 against a
// profile the gateway holds NO grant for is answered by grace, and a customer whose purchase just failed
// must not be told it succeeded.
func TestAFailedPurchaseWithNoGrantStillRecordsNothing(t *testing.T) {
	g := newConflictGateway(t, 0) // retryPlanGB stays 0: no live grant, so the retry is a grace lease
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	toks, err := newGatewayClient(g.srv.URL, gwDefault).buyFaucet(5)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}); err != nil {
		t.Fatal(err)
	}
	_, bought, err := leaseRefs(newGatewayClient(g.srv.URL, gwDefault), wpath, "profNoGrant", map[string]int64{"blob/a": 8 * giB}, nil)
	if err != nil {
		t.Fatalf("leaseRefs: %v", err)
	}
	if bought {
		t.Fatal("a 409'd purchase against a profile with no live grant reported a bought term -- the gateway " +
			"spent nothing and named no plan, so there is no term to report (NWP-20260906-03)")
	}
}
