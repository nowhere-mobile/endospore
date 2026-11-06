package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
	"testing"
)

// Q090 (NWP-20261109-08): payRent renews in batches of leaseBatchRefs, the purchase on the first and judged on the
// whole footprint, later batches tokenless; a short renewal records the spend but not the renewal stamp.

type renewBatchFixture struct {
	base, name, p1, p2, wpath string
	gw                        *gatewayClient
	mu                        sync.Mutex
	leases                    []leaseReq
	failAt                    map[int]bool // /lease request indexes answered 500
}

// renewBatchSetup builds a rotated profile (so its vault holds a !bill-retag record and `prior` is non-empty) with at
// least 8 MiB of seeded random data: chunks are 256 KiB..4 MiB, so the footprint is well over 7 refs.
func renewBatchSetup(t *testing.T, name string, tokens int) *renewBatchFixture {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	f := &renewBatchFixture{name: name, p1: "old horse battery staple", p2: "new maple stone cloud lantern", failAt: map[int]bool{}}
	f.base = newHTTPStore(t)
	if createVault(f.base, name, f.p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if _, err := rotateVault(f.base, name, f.p1, f.p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if got := retagOfAt(t, f.base, name, f.p2); len(got) != 1 {
		t.Fatalf("fixture: !bill-retag = %v, want the old key", shortAll(got))
	}
	src := t.TempDir()
	rng := rand.New(rand.NewSource(961))
	for i := 0; i < 4; i++ {
		buf := make([]byte, 2<<20+1234)
		rng.Read(buf)
		if err := os.WriteFile(filepath.Join(src, fmt.Sprintf("f%d.bin", i)), buf, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	pushProfile(f.base, name, f.p2, src)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 86400, EpochsPerLease: 30,
			PriceCents: 200, CurrentEpoch: 42, FreeGB: 1})
	})
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		f.mu.Lock()
		i := len(f.leases)
		f.leases = append(f.leases, req)
		fail := f.failAt[i]
		f.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprint(w, `{"error":"x"}`)
			return
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, DeadlineEpoch: 129, Spent: len(req.Tokens) + len(req.BlindTokens)})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	f.gw = newGatewayClient(srv.URL, gwDefault)

	f.wpath = filepath.Join(t.TempDir(), "wallet.json")
	w := &Wallet{}
	for i := 0; i < tokens; i++ {
		w.Tokens = append(w.Tokens, Token{Denom: "1GBmo", Nonce: fmt.Sprintf("%s-%d", name, i), Exp: 1 << 62, Sig: "s"})
	}
	if err := saveWallet(f.wpath, w); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, f.wpath)
	freeRenewedThrough = map[string]int64{}
	old := leaseBatchRefs
	t.Cleanup(func() { leaseBatchRefs = old })
	return f
}

// renewBatchFootprint is exactly what payRent leases: the measured footprint plus the wallet's two refs.
func renewBatchFootprint(t *testing.T, f *renewBatchFixture) map[string]int64 {
	t.Helper()
	refs, measured := profileFootprint(f.base, f.name, f.p2, nil)
	if !measured {
		t.Fatal("fixture footprint not measured")
	}
	whk := walletHeadKey(f.base, f.name, f.p2)
	if cur := getRef(f.base, whk); cur != "" {
		refs["blob/"+cur] = blobSize(f.base, cur)
	}
	refs["ref/"+whk] = 0
	if len(refs) < 7 {
		t.Fatalf("fixture gives %d refs, need >= 7", len(refs))
	}
	return refs
}

func (f *renewBatchFixture) sent() []leaseReq {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]leaseReq(nil), f.leases...)
}

func renewBatchKeys(m map[string]int64) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// renewBatchUnion checks the requests' refs are pairwise disjoint and returns their union.
func renewBatchUnion(t *testing.T, reqs []leaseReq) map[string]int64 {
	t.Helper()
	u := map[string]int64{}
	for i, r := range reqs {
		for k, v := range r.Refs {
			if _, dup := u[k]; dup {
				t.Fatalf("request %d re-sends %s", i, k)
			}
			u[k] = v
		}
	}
	return u
}

func TestRenewBatch_SplitsSortedAndComplete(t *testing.T) {
	refs := map[string]int64{}
	for i := 0; i < 7; i++ {
		refs[fmt.Sprintf("blob/%02d", i)] = int64(i + 1)
	}
	bs := leaseBatches(refs, 3)
	if len(bs) != 3 || len(bs[0]) != 3 || len(bs[1]) != 3 || len(bs[2]) != 1 {
		t.Fatalf("batch sizes wrong: %d batches", len(bs))
	}
	var all []string
	union := map[string]int64{}
	for _, b := range bs {
		ks := renewBatchKeys(b)
		for _, k := range ks {
			if _, dup := union[k]; dup {
				t.Fatalf("%s is in two batches", k)
			}
			union[k] = b[k]
		}
		all = append(all, ks...)
	}
	if !sort.StringsAreSorted(all) {
		t.Fatalf("batches are not consecutive in sorted order: %v", all)
	}
	if !reflect.DeepEqual(union, refs) {
		t.Fatalf("union %v != input %v", union, refs)
	}
	for _, n := range []int{7, 100, 0, -1} {
		if got := leaseBatches(refs, n); len(got) != 1 || len(got[0]) != 7 {
			t.Fatalf("n=%d: %d batches, want one holding all 7", n, len(got))
		}
	}
}

func TestRenewBatch_PaidSendsBatchesTokensOnlyFirst(t *testing.T) {
	f := renewBatchSetup(t, "rbatch1", 2)
	want := renewBatchFootprint(t, f)
	leaseBatchRefs = 3
	if _, paid, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil); err != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v", paid, err)
	}
	reqs := f.sent()
	if n := (len(want) + 2) / 3; len(reqs) != n {
		t.Fatalf("%d /lease requests for %d refs, want %d", len(reqs), len(want), n)
	}
	if len(reqs[0].Tokens)+len(reqs[0].BlindTokens) == 0 || reqs[0].BuyGB <= 0 {
		t.Fatalf("first request tokens=%d buy_gb=%d, want the purchase", len(reqs[0].Tokens), reqs[0].BuyGB)
	}
	oldKey := profileRefV2(f.name, f.p1)
	for i, r := range reqs {
		if i > 0 && (len(r.Tokens) != 0 || len(r.BlindTokens) != 0 || r.BuyGB != 0) {
			t.Fatalf("request %d carries tokens=%d buy_gb=%d, want none", i, len(r.Tokens), r.BuyGB)
		}
		if r.Periods != reqs[0].Periods {
			t.Fatalf("request %d periods %d != %d", i, r.Periods, reqs[0].Periods)
		}
		if !reflect.DeepEqual(r.Prior, reqs[0].Prior) || len(r.Prior) != 1 || r.Prior[0] != oldKey {
			t.Fatalf("request %d prior %v, want [old key] on every batch", i, shortAll(r.Prior))
		}
	}
	if got := renewBatchUnion(t, reqs); !reflect.DeepEqual(got, want) {
		t.Fatalf("the batches' union (%d refs) is not the footprint (%d refs)", len(got), len(want))
	}
	if got := retagOfAt(t, f.base, f.name, f.p2); len(got) != 0 {
		t.Fatalf("!bill-retag = %v after a whole renewal, want it cleared", shortAll(got))
	}
}

// The purchase is judged on the whole footprint: 7 x 200 MiB is over the 1 GiB allowance, a batch of 3 is not.
func TestRenewBatch_PurchaseJudgedOnWholeFootprint(t *testing.T) {
	refs := map[string]int64{}
	for i := 0; i < 7; i++ {
		refs[fmt.Sprintf("blob/aa%02d", i)] = 200 << 20
	}
	run := func(n int) []leaseReq {
		var mu sync.Mutex
		var got []leaseReq
		mux := http.NewServeMux()
		mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
			var req leaseReq
			json.NewDecoder(r.Body).Decode(&req)
			mu.Lock()
			got = append(got, req)
			mu.Unlock()
			json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, Spent: len(req.Tokens)})
		})
		srv := httptest.NewServer(mux)
		defer srv.Close()
		old := leaseBatchRefs
		leaseBatchRefs = n
		defer func() { leaseBatchRefs = old }()
		// inside the activation jitter: only "over the free allowance" lets the purchase through
		w := &Wallet{PlanGB: 1, PlanPeriods: 1, ActivateAfter: 50, Tokens: []Token{{Denom: "1GBmo", Nonce: "rbatch2-t", Exp: 1 << 62, Sig: "s"}}}
		if _, err := leaseRefsLocked(newGatewayClient(srv.URL, gwDefault), quoteInfo{FreeGB: 1, CurrentEpoch: 42, GBPerToken: 1}, w, "rbatch2", refs, nil); err != nil {
			t.Fatalf("leaseRefsLocked(n=%d): %v", n, err)
		}
		return got
	}
	one, three := run(0), run(3)
	if len(one) != 1 || len(three) != 3 {
		t.Fatalf("requests: %d unbatched, %d batched, want 1 and 3", len(one), len(three))
	}
	if one[0].BuyGB != 1 || len(one[0].Tokens) != 1 {
		t.Fatalf("unbatched run buy_gb=%d tokens=%d, want the purchase", one[0].BuyGB, len(one[0].Tokens))
	}
	if three[0].BuyGB != one[0].BuyGB || len(three[0].Tokens) != len(one[0].Tokens) {
		t.Fatalf("batched first request buy_gb=%d tokens=%d, want the one-batch run's %d and %d",
			three[0].BuyGB, len(three[0].Tokens), one[0].BuyGB, len(one[0].Tokens))
	}
}

func TestRenewBatch_ShortRenewalRecordsSpendNotStamp(t *testing.T) {
	f := renewBatchSetup(t, "rbatch3", 2)
	n := len(renewBatchFootprint(t, f))
	leaseBatchRefs = (n + 2) / 3
	f.failAt[1] = true
	if _, paid, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil); err != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v, want a paid renewal despite the short batch", paid, err)
	}
	reqs := f.sent()
	if len(reqs) != 3 {
		t.Fatalf("%d /lease requests, want 3 (the third is still sent after the second fails)", len(reqs))
	}
	w, _ := loadWallet(f.wpath)
	if w.balance() != 2-len(reqs[0].Tokens) || len(reqs[0].Tokens) == 0 {
		t.Fatalf("balance %d after presenting %d of 2 tokens", w.balance(), len(reqs[0].Tokens))
	}
	if w.PaidThrough != 99 {
		t.Fatalf("PaidThrough %d, want 99 recorded", w.PaidThrough)
	}
	if w.RenewedEpoch != 0 || w.DeadlineEpoch != 0 {
		t.Fatalf("RenewedEpoch=%d DeadlineEpoch=%d, want neither stamped on a short renewal", w.RenewedEpoch, w.DeadlineEpoch)
	}
	if got := retagOfAt(t, f.base, f.name, f.p2); len(got) != 1 {
		t.Fatalf("!bill-retag = %v after a short renewal, want it kept", shortAll(got))
	}
}

func TestRenewBatch_FirstBatchFailsNothingRecorded(t *testing.T) {
	f := renewBatchSetup(t, "rbatch4", 2)
	leaseBatchRefs = 3
	f.failAt[0] = true
	before, _ := os.ReadFile(f.wpath)
	if _, paid, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil); err == nil || paid {
		t.Fatalf("payRent: paid=%v err=%v, want an error", paid, err)
	}
	if n := len(f.sent()); n != 1 {
		t.Fatalf("%d /lease requests, want 1 (no later batch after the first fails)", n)
	}
	after, _ := os.ReadFile(f.wpath)
	if string(before) != string(after) {
		t.Fatalf("the wallet changed on a failed first batch:\n%s\n%s", before, after)
	}
	if got := retagOfAt(t, f.base, f.name, f.p2); len(got) != 1 {
		t.Fatalf("!bill-retag = %v, want it kept", shortAll(got))
	}
}

func TestRenewBatch_FreeArmBatchesAndLatchesOnlyWhole(t *testing.T) {
	f := renewBatchSetup(t, "rbatch5", 0)
	want := renewBatchFootprint(t, f)
	leaseBatchRefs = 3
	if _, paid, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil); err != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v", paid, err)
	}
	reqs := f.sent()
	if len(reqs) != (len(want)+2)/3 || len(reqs) < 3 {
		t.Fatalf("%d /lease requests for %d refs", len(reqs), len(want))
	}
	for i, r := range reqs {
		if !r.Free || len(r.Tokens) != 0 {
			t.Fatalf("request %d free=%v tokens=%d", i, r.Free, len(r.Tokens))
		}
	}
	if got := renewBatchUnion(t, reqs); !reflect.DeepEqual(got, want) {
		t.Fatalf("free batches' union (%d refs) is not the footprint (%d refs)", len(got), len(want))
	}
	if got := freeRenewedThrough[profileRefV2(f.name, f.p2)]; got != 42 {
		t.Fatalf("freeRenewedThrough = %d after a whole renewal, want 42", got)
	}
	if got := retagOfAt(t, f.base, f.name, f.p2); len(got) != 0 {
		t.Fatalf("!bill-retag = %v after a whole free renewal, want it cleared", shortAll(got))
	}

	g := renewBatchSetup(t, "rbatch6", 0)
	renewBatchFootprint(t, g)
	leaseBatchRefs = 3
	g.failAt[1] = true
	if _, paid, err := payRent(g.gw, g.base, g.name, g.p2, g.wpath, nil); err != nil || !paid {
		t.Fatalf("short payRent: paid=%v err=%v", paid, err)
	}
	if n := len(g.sent()); n < 3 {
		t.Fatalf("%d requests, want the later batches still sent", n)
	}
	if v, ok := freeRenewedThrough[profileRefV2(g.name, g.p2)]; ok {
		t.Fatalf("freeRenewedThrough = %d after a short renewal, want no latch", v)
	}
	if got := retagOfAt(t, g.base, g.name, g.p2); len(got) != 1 {
		t.Fatalf("!bill-retag = %v after a short free renewal, want it kept", shortAll(got))
	}
}

func TestRenewBatch_SmallFootprintOneRequest(t *testing.T) {
	f := renewBatchSetup(t, "rbatch7", 2)
	want := renewBatchFootprint(t, f)
	if _, paid, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil); err != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v", paid, err)
	}
	reqs := f.sent()
	if len(reqs) != 1 || !reflect.DeepEqual(reqs[0].Refs, want) {
		t.Fatalf("%d requests, want one carrying all %d refs", len(reqs), len(want))
	}
}
