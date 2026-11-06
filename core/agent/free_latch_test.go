package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// NWP-20260829-06, the free-lease LATCH. payRent chose its endpoint with
//
//	freeUser := w.balance() == 0 && w.PaidThrough <= q.CurrentEpoch
//
// and the free branch returns WITHOUT recordCoverage ("no PaidThrough advance, so the next epoch renews
// again"). Buying a plan empties the wallet by design, so once the remembered term lapses BOTH halves are
// permanently true, and the only code that would learn the real term is on the other side of the branch.
// The discriminator was read from state that the branch it selects refuses to refresh.
//
// These tests pin the two halves that must both hold: the wallet-only signal cannot distinguish a paying
// customer from a free user, and routing a zero-balance wallet down the paid path cannot spend anything.

// The exact wallet measured on lynx: a live 10 GB / 3-period plan whose tokens were spent activating it.
func latchedWallet() *Wallet {
	return &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20694, DeadlineEpoch: 20812, RenewedEpoch: 20693}
}

// THE LATCH ITSELF: the old predicate cannot tell a paid-up customer from a free user, because after
// activation they are the same wallet. This is the assertion that says a local-only answer is impossible --
// which is why the fix asks the gateway rather than reading another field.
func TestWalletAloneCannotDistinguishPaidFromFree(t *testing.T) {
	const now = int64(20694)
	paid := latchedWallet()             // bought a plan; tokens spent creating the grant
	free := &Wallet{PaidThrough: 20694} // never bought anything

	oldPredicate := func(w *Wallet) bool { return w.balance() == 0 && w.PaidThrough <= now }
	if oldPredicate(paid) != oldPredicate(free) {
		t.Fatal("premise broken: if the wallet COULD tell these apart, the fix would not need the gateway")
	}
	if !oldPredicate(paid) {
		t.Fatal("the paid-up wallet must look free to the old predicate -- that is the bug being fixed")
	}
}

// SPEND SAFETY, the deciding property. Routing a zero-balance wallet down the PAID path must not buy
// anything: only planPurchase spends, and it must decline from an empty wallet. If this ever fails, the fix
// is unsafe however well it works, because it would charge a genuinely free profile.
func TestRoutingToThePaidPathCannotSpend(t *testing.T) {
	const now = int64(20694)
	for _, tc := range []struct {
		why string
		w   *Wallet
	}{
		{"a plan bought and already activated (the latched case)", latchedWallet()},
		{"a plan recorded but the wallet emptied some other way", &Wallet{PlanGB: 10, PlanPeriods: 3}},
		{"no plan at all -- a genuinely free profile", &Wallet{}},
		{"over the free allowance, which bypasses the jitter hold", latchedWallet()},
	} {
		overFree := tc.why == "over the free allowance, which bypasses the jitter hold"
		gb, periods, plain, blind := tc.w.planPurchase(now, overFree)
		if gb != 0 || periods != 0 || len(plain) != 0 || len(blind) != 0 {
			t.Errorf("%s: planPurchase spent from an empty wallet (gb=%d periods=%d plain=%d blind=%d)",
				tc.why, gb, periods, len(plain), len(blind))
		}
		if tc.w.balance() != 0 {
			t.Errorf("%s: balance changed", tc.why)
		}
	}
}

// A FUNDED plan must still activate. The fix must not make the paid path unreachable for the case it is
// actually for -- a wallet holding enough tokens to buy its recorded plan.
func TestAFundedPlanStillActivates(t *testing.T) {
	w := &Wallet{PlanGB: 10, PlanPeriods: 3}
	for i := 0; i < 30; i++ { // 10 GB x 3 periods = 30 tokens
		w.Tokens = append(w.Tokens, Token{})
	}
	gb, periods, _, _ := w.planPurchase(20694, true)
	if gb != 10 || periods != 3 {
		t.Fatalf("a funded plan must activate: got gb=%d periods=%d, want 10/3", gb, periods)
	}
}

// THE REAL TEST: drive payRent itself and observe WHICH lease the gateway is asked for. Both paths POST to
// /lease; the free one sets Free:true in the body, so the server can tell them apart.
//
// This is the test that has to fail against the old predicate. An earlier version of this file asserted the
// routing rule by re-implementing it in the test, which passed against the broken code -- the mutation check
// caught it, and that is the third time today a re-implemented assertion proved worthless.
func TestPayRentAsksTheGatewayWhenTheWalletLooksFree(t *testing.T) {
	for _, tc := range []struct {
		why           string
		entitledBytes int64
		status        int
		wantFreeLease bool
	}{
		{"a LIVE grant -> must take the PAID path, the only one that records coverage", 10 << 30, 200, false},
		{"no live capacity -> must stay on the free tier", 0, 200, true},
		{"gateway too old to answer -> FAIL OPEN to today's free routing", 0, 404, true},
	} {
		t.Run(tc.why, func(t *testing.T) {
			var sawFree, leased bool
			mux := http.NewServeMux()
			mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
				json.NewEncoder(w).Encode(quoteInfo{
					Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4,
					PriceCents: 200, CurrentEpoch: 42, IssuerPubKey: "testpub",
				})
			})
			mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
				if tc.status != 200 {
					w.WriteHeader(tc.status)
					return
				}
				json.NewEncoder(w).Encode(entitlementInfo{
					FreeBytes: 1 << 30, EntitledBytes: tc.entitledBytes, CurrentEpoch: 42,
				})
			})
			mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
				var req leaseReq
				json.NewDecoder(r.Body).Decode(&req)
				leased, sawFree = true, req.Free
				json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99})
			})
			srv := httptest.NewServer(mux)
			defer srv.Close()

			base := newHTTPStore(t)
			name, pass := "latch"+strconv.Itoa(int(tc.entitledBytes))+strconv.Itoa(tc.status), "latched wallet passphrase"
			createVault(base, name, pass)
			src := t.TempDir()
			if err := os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("data"), 500), 0o600); err != nil {
				t.Fatal(err)
			}
			pushProfile(base, name, pass, src)

			wpath := filepath.Join(t.TempDir(), "wallet.json")
			provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
			// The measured shape: a plan was bought, its tokens are spent, and the remembered term has run
			// out. Indistinguishable from a free wallet by any local field.
			if err := saveWallet(wpath, &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 42}); err != nil {
				t.Fatal(err)
			}
			freeRenewedThrough = map[string]int64{} // reset the per-process throttle

			if _, _, err := payRent(newGatewayClient(srv.URL, gwDefault), base, name, pass, wpath, nil); err != nil {
				t.Fatalf("payRent: %v", err)
			}
			if !leased {
				t.Fatal("payRent took no lease at all")
			}
			if sawFree != tc.wantFreeLease {
				t.Fatalf("asked for a FREE lease = %v, want %v -- the wallet cannot tell these apart, so the "+
					"gateway must decide", sawFree, tc.wantFreeLease)
			}
			w, _ := loadWallet(wpath)
			if w.balance() != 0 {
				t.Fatalf("routing must never spend: balance = %d", w.balance())
			}
		})
	}
}
