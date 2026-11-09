package main

import (
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"sync/atomic"
	"testing"
)

// docs/product-decisions.md, "seventeen answers to harvest 59 ...", #9 (NWP-20261129-22): the periodic and manual seals
// renew the whole footprint at most once per epoch while the wallet's tokens cannot buy the lease.

// renewOnceStore counts what reaches the store: every request, and the footprint walks. Only profileFootprint reads
// the head of the profile's #keys scope, and it reads it once per walk.
type renewOnceStore struct {
	all, walks atomic.Int64
}

// renewOnceSetup is renewBatchSetup with a counting proxy in front of the store and the wallet given shape. It also
// returns the footprint's size, read before the proxy goes in so that the read counts no walk.
func renewOnceSetup(t *testing.T, name string, tokens int, shape func(*Wallet)) (*renewBatchFixture, *renewOnceStore, int) {
	t.Helper()
	noWalletRenewedReset(t)
	f := renewBatchSetup(t, name, tokens)
	n := len(renewBatchFootprint(t, f))
	marker := "/ref/" + headKey(f.base, name+"#keys", f.p2)
	target, err := url.Parse(f.base)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	c := &renewOnceStore{}
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.all.Add(1)
		if r.Method == http.MethodGet && r.URL.Path == marker {
			c.walks.Add(1)
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	f.base = front.URL

	w, err := loadWallet(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	shape(w)
	if err := saveWallet(f.wpath, w); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, f.wpath)
	return f, c, n
}

func (f *renewBatchFixture) setEpoch(e int64) {
	f.mu.Lock()
	f.epoch = e
	f.mu.Unlock()
}

func renewOnceCall(t *testing.T, f *renewBatchFixture) {
	t.Helper()
	if _, _, err := payRentGen(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath)); err != nil {
		t.Fatalf("payRentGen: %v", err)
	}
}

func renewOnceCounts(t *testing.T, f *renewBatchFixture, c *renewOnceStore, when string, leases, walks int) {
	t.Helper()
	if got := len(f.sent()); got != leases {
		t.Errorf("%s: %d /lease requests, want %d", when, got, leases)
	}
	if got := c.walks.Load(); got != int64(walks) {
		t.Errorf("%s: %d footprint walks, want %d", when, got, walks)
	}
}

func renewOnceWallet(t *testing.T, f *renewBatchFixture) *Wallet {
	t.Helper()
	w, err := loadWallet(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

// E1: a lapsed wallet that holds 7 of the 30 tokens its plan costs renews once per epoch and spends nothing.
func TestRenewOnce_E1_LapsedShortWallet(t *testing.T) {
	f, c, _ := renewOnceSetup(t, "renewonce1", 7, func(w *Wallet) {
		w.PaidThrough, w.RenewedEpoch, w.PlanGB, w.PlanPeriods = 41, 20, 10, 3
	})
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "first call at 42", 1, 1)
	after := c.all.Load()
	renewOnceCall(t, f)
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "three calls at 42", 1, 1)
	if got := c.all.Load(); got != after {
		t.Errorf("a call that is not due sent %d store requests, want 0", got-after)
	}
	f.setEpoch(43)
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "one more call at 43", 2, 2)
	for i, r := range f.sent() {
		if len(r.Tokens) != 0 || len(r.BlindTokens) != 0 || r.BuyGB != 0 {
			t.Errorf("request %d carries tokens=%d buy_gb=%d, want none", i, len(r.Tokens)+len(r.BlindTokens), r.BuyGB)
		}
	}
	w := renewOnceWallet(t, f)
	if w.balance() != 7 || w.PaidThrough != 41 || w.RenewedEpoch != 43 {
		t.Errorf("balance=%d PaidThrough=%d RenewedEpoch=%d, want 7, 41 and 43", w.balance(), w.PaidThrough, w.RenewedEpoch)
	}
}

// E2: a funded purchase in its ActivateAfter hold renews once per epoch until the hold ends. Then the renewal buys, and
// a second call in that epoch is not due.
func TestRenewOnce_E2_FundedPurchaseInItsHold(t *testing.T) {
	f, c, _ := renewOnceSetup(t, "renewonce2", 30, func(w *Wallet) {
		w.PaidThrough, w.RenewedEpoch, w.PlanGB, w.PlanPeriods, w.ActivateAfter = 41, 20, 10, 3, 44
	})
	renewOnceCall(t, f)
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "two calls at 42", 1, 1)
	f.setEpoch(43)
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "one call at 43", 2, 2)
	f.setEpoch(44)
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "first call at 44", 3, 3)
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "second call at 44", 3, 3)
	reqs := f.sent()
	if len(reqs) != 3 {
		t.Fatalf("%d /lease requests, want 3", len(reqs))
	}
	for i, r := range reqs[:2] {
		if len(r.Tokens) != 0 || len(r.BlindTokens) != 0 || r.BuyGB != 0 {
			t.Errorf("request %d, inside the hold, carries tokens=%d buy_gb=%d, want none", i, len(r.Tokens)+len(r.BlindTokens), r.BuyGB)
		}
	}
	if got := len(reqs[2].Tokens) + len(reqs[2].BlindTokens); got != 30 || reqs[2].BuyGB != 10 {
		t.Errorf("the renewal at 44 carries tokens=%d buy_gb=%d, want 30 and 10", got, reqs[2].BuyGB)
	}
	w := renewOnceWallet(t, f)
	if w.balance() != 0 || w.PaidThrough != 99 || w.RenewedEpoch != 44 {
		t.Errorf("balance=%d PaidThrough=%d RenewedEpoch=%d, want 0, 99 and 44", w.balance(), w.PaidThrough, w.RenewedEpoch)
	}
}

// E3: the gate does not stop the staleness arm, which is what keeps cold refs alive inside a live term.
func TestRenewOnce_E3_StaleFootprintStillRenews(t *testing.T) {
	f, c, _ := renewOnceSetup(t, "renewonce3", 2, func(w *Wallet) {
		w.PaidThrough, w.RenewedEpoch = 92, 42-renewEveryEpochs
	})
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "first call at 42", 1, 1)
	if got := renewOnceWallet(t, f).RenewedEpoch; got != 42 {
		t.Errorf("RenewedEpoch = %d, want 42", got)
	}
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "second call at 42", 1, 1)
}

// E4: a renewal whose second batch fails stamps nothing (Q090), so it runs again in the same epoch, and the renewal
// that lands is the epoch's last.
func TestRenewOnce_E4_ShortRenewalRetriesInTheEpoch(t *testing.T) {
	f, c, n := renewOnceSetup(t, "renewonce4", 7, func(w *Wallet) {
		w.PaidThrough, w.RenewedEpoch, w.PlanGB, w.PlanPeriods = 41, 20, 10, 3
	})
	leaseBatchRefs = (n + 2) / 3
	f.failAt[1] = true
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "the short renewal", 3, 1)
	if got := renewOnceWallet(t, f).RenewedEpoch; got != 20 {
		t.Fatalf("RenewedEpoch = %d after a short renewal, want 20", got)
	}
	renewOnceCall(t, f)
	sent := len(f.sent())
	if sent <= 3 {
		t.Fatalf("%d /lease requests after the retry, want more than 3", sent)
	}
	if got := renewOnceWallet(t, f).RenewedEpoch; got != 42 {
		t.Fatalf("RenewedEpoch = %d after the retry landed, want 42", got)
	}
	renewOnceCall(t, f)
	renewOnceCounts(t, f, c, "a call after the retry landed", sent, 2)
}
