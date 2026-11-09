package main

// NWP-20261129-05: a purchase recorded with nothing waiting gets a fresh hold once the stored one has passed (Q134,
// docs/product-decisions.md). capFlush never clears ActivateAfter when a purchase lands and walletForPublish keeps the
// later copy, so after a profile's first purchase it is never 0 again.
// Every test has its own t.TempDir wallet. batchEnv + pinBatchClock: the draw fails, so a fresh hold at 42 is 45.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sync"
	"testing"
)

func freshHoldToks(prefix string, n int) []BlindToken {
	out := make([]BlindToken, n)
	for i := range out {
		out[i] = BlindToken{Msg: fmt.Sprintf("%s-m%d", prefix, i), Sig: fmt.Sprintf("%s-s%d", prefix, i)}
	}
	return out
}

func freshHoldWallet(t *testing.T, w *Wallet) string {
	t.Helper()
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, w); err != nil {
		t.Fatal(err)
	}
	return wp
}

// F1.
func TestPlanFreshHold_ALaterPurchaseWaitsItsOwnHold(t *testing.T) {
	batchEnv(t, "", false)
	pinBatchClock(t, 42)
	wp := freshHoldWallet(t, &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 200, ActivateAfter: 33})
	if err := recordPlan(wp, 3, 10, false); err != nil {
		t.Fatal(err)
	}
	if err := appendTokens(wp, freshHoldToks("f1", 30)); err != nil {
		t.Fatal(err)
	}
	w := mustLoad(t, wp)
	if w.ActivateAfter != 45 {
		t.Fatalf("ActivateAfter=%d, want 45", w.ActivateAfter)
	}
	if gb, _, _, _ := w.planPurchase(42, false); gb != 0 {
		t.Fatalf("bought %d GB at 42, inside the fresh hold", gb)
	}
	if gb, per, _, _ := w.planPurchase(45, false); gb != 10 || per != 3 {
		t.Fatalf("at the hold's epoch: %d x %d, want 10 x 3", gb, per)
	}
}

// F2: planPurchase holds only while ActivateAfter > now, so a hold equal to now has ended.
func TestPlanFreshHold_AHoldEndingNowIsFinished(t *testing.T) {
	batchEnv(t, "", false)
	pinBatchClock(t, 42)
	wp := freshHoldWallet(t, &Wallet{ActivateAfter: 42})
	if err := recordPlan(wp, 3, 10, false); err != nil {
		t.Fatal(err)
	}
	if got := mustLoad(t, wp).ActivateAfter; got != 45 {
		t.Fatalf("ActivateAfter=%d, want 45", got)
	}
}

// F3: a re-draw at 44 would give 48.
func TestPlanFreshHold_ARunningHoldIsKept(t *testing.T) {
	batchEnv(t, "", false)
	pinBatchClock(t, 44)
	wp := freshHoldWallet(t, &Wallet{ActivateAfter: 45})
	if err := recordPlan(wp, 3, 10, false); err != nil {
		t.Fatal(err)
	}
	if got := mustLoad(t, wp).ActivateAfter; got != 45 {
		t.Fatalf("ActivateAfter=%d, want 45 kept", got)
	}
}

// F4: a queued purchase never moves the waiting purchase's hold, even one that has passed.
func TestPlanFreshHold_AWaitingPurchasesPassedHoldStays(t *testing.T) {
	batchEnv(t, "", false)
	pinBatchClock(t, 42)
	wp := freshHoldWallet(t, &Wallet{PlanGB: 10, PlanPeriods: 3, ActivateAfter: 40, BlindTokens: freshHoldToks("f4", 30)})
	if err := recordPlan(wp, 1, 20, false); err != nil {
		t.Fatal(err)
	}
	w := mustLoad(t, wp)
	if len(w.PlanQueue) != 1 || w.ActivateAfter != 40 {
		t.Fatalf("queue=%v ActivateAfter=%d, want one queued and 40", w.PlanQueue, w.ActivateAfter)
	}
}

// freshHoldGateway is shaped on newConflictGateway (lease_conflict_test.go): its /quote carries free_gb 1 and a
// purchase-declaring /lease answers 200 with Spent = the tokens presented. epoch moves between seals.
type freshHoldGateway struct {
	srv   *httptest.Server
	mu    sync.Mutex
	epoch int64
	buys  []int
}

func newFreshHoldGateway(t *testing.T) *freshHoldGateway {
	t.Helper()
	g := &freshHoldGateway{epoch: 42}
	objs := map[string][]byte{}
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		g.mu.Lock()
		defer g.mu.Unlock()
		if r.Method == http.MethodPut {
			b, _ := io.ReadAll(r.Body)
			objs[k] = b
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
		g.mu.Lock()
		defer g.mu.Unlock()
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 86400, EpochsPerLease: 4, CurrentEpoch: g.epoch, FreeGB: 1})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		g.mu.Lock()
		defer g.mu.Unlock()
		if req.Free {
			w.WriteHeader(http.StatusPaymentRequired)
			return
		}
		caps := map[string]string{}
		for ref := range req.Refs {
			caps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
		}
		out := leaseInfo{ThroughEpoch: g.epoch + 90, WriteCaps: caps}
		if req.BuyGB > 0 {
			g.buys = append(g.buys, req.BuyGB)
			out.Spent, out.PlanGB = len(req.Tokens)+len(req.BlindTokens), req.BuyGB
		}
		json.NewEncoder(w).Encode(out)
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

// seal drives one cap-mode seal at epoch and returns every purchase declared so far.
func (g *freshHoldGateway) seal(name, pass string, epoch int64, data byte) []int {
	g.mu.Lock()
	g.epoch = epoch
	g.mu.Unlock()
	capReadCache = map[string]capEntry{}
	blobCache = nil
	bn := capBegin()
	capSetSession(name, pass, deriveKey(name, pass))
	h := postBlob("s3", bytes.Repeat([]byte{data}, 4096))
	putRef("s3", profileRefV2(name, pass), h)
	capFlush(bn)
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]int(nil), g.buys...)
}

// F5: the failure scenario through capFlush.
func TestPlanFreshHold_ThroughCapFlush(t *testing.T) {
	batchEnv(t, "", false)
	pinBatchClock(t, 42)
	g := newFreshHoldGateway(t)
	t.Setenv("GATEWAY_URL", g.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	wp := freshHoldWallet(t, &Wallet{PlanGB: 10, PlanPeriods: 3, ActivateAfter: 33, BlindTokens: freshHoldToks("first", 30)})
	t.Setenv("NOWHERE_WALLET", wp)
	const name, pass = "freshholdu", "the later purchase waits its own hold"

	if buys := g.seal(name, pass, 42, 'a'); len(buys) != 1 || buys[0] != 10 {
		t.Fatalf("the first seal declared %v, want one purchase of 10", buys)
	}
	w := mustLoad(t, wp)
	if w.ActivateAfter > 42 || w.balance() != 0 {
		t.Fatalf("after the first purchase ActivateAfter=%d balance=%d, want a past hold and 0", w.ActivateAfter, w.balance())
	}
	if err := recordPlan(wp, 3, 10, false); err != nil {
		t.Fatal(err)
	}
	if err := appendTokens(wp, freshHoldToks("second", 30)); err != nil {
		t.Fatal(err)
	}
	if buys := g.seal(name, pass, 42, 'b'); len(buys) != 1 {
		t.Fatalf("the claim's own seal declared the second purchase: %v", buys)
	}
	if buys := g.seal(name, pass, 45, 'c'); len(buys) != 2 || buys[1] != 10 {
		t.Fatalf("a seal at the hold's epoch declared %v, want a second purchase of 10", buys)
	}
}
