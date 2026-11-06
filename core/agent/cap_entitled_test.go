package main

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sync"
	"testing"
)

// mockEntitledGateway models the #133 capacity gateway: the free tier is FULL (every free lease 402s),
// and profile-tagged paid leases pool purchased GB per profile -- a lease owes ceil(excess/GiB) over the
// entitlement, spending extends it, and later leases inside the window ride free. Counters expose how
// many free vs entitled calls the device made.
func mockEntitledGateway(t *testing.T) (srv *httptest.Server, objs map[string][]byte, mu *sync.Mutex, freeCalls, entCalls *int) {
	t.Helper()
	objs = map[string][]byte{}
	mu = &sync.Mutex{}
	freeCalls, entCalls = new(int), new(int)
	ents := map[string]int{}              // profile -> GB entitled (window liveness elided in the mock)
	live := map[string]map[string]int64{} // profile -> ref -> size
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		if r.Method == http.MethodPut {
			b, _ := io.ReadAll(r.Body)
			mu.Lock()
			objs[k] = b
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
			return
		}
		mu.Lock()
		b, ok := objs[k]
		mu.Unlock()
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
	var counter int
	mux.HandleFunc("POST /tokens", func(w http.ResponseWriter, r *http.Request) {
		var req tokensReq
		json.NewDecoder(r.Body).Decode(&req)
		out := tokensResp{}
		for i := 0; i < req.Count; i++ {
			counter++
			out.Tokens = append(out.Tokens, Token{Denom: "1GBmo", Nonce: "en" + string(rune('a'+counter)), Exp: 1 << 62, Sig: "sig"})
		}
		json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		defer mu.Unlock()
		if req.Free {
			*freeCalls++
			w.WriteHeader(http.StatusPaymentRequired) // the free tier is full in this mock
			return
		}
		if req.Profile == "" {
			w.WriteHeader(http.StatusBadRequest) // this mock only models the entitled path
			return
		}
		*entCalls++
		if live[req.Profile] == nil {
			live[req.Profile] = map[string]int64{}
		}
		var total int64
		for ref, sz := range req.Refs {
			live[req.Profile][ref] = sz
		}
		for _, sz := range live[req.Profile] {
			total += sz
		}
		covered := int64(ents[req.Profile]) * giB // free tier is full -> covered = entitlement only
		owed := 0
		if excess := total - covered; excess > 0 {
			owed = int(math.Ceil(float64(excess) / float64(giB)))
		}
		if len(req.Tokens)+len(req.BlindTokens) < owed {
			w.WriteHeader(http.StatusPaymentRequired)
			return
		}
		ents[req.Profile] += owed
		caps := map[string]string{}
		for ref := range req.Refs {
			caps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 46, Spent: owed, WriteCaps: caps})
	})
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, objs, mu, freeCalls, entCalls
}

// The #133 drain, fixed: a funded wallet + a small footprint seals repeatedly on the FREE tier and never
// spends a token (the old paid-first flow burned one full token per 2-minute seal).
func TestCapFlushChurnSpendsNothing(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(5)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	name, pass := "churnu", "seal churn must be free"
	dk := deriveKey(name, pass)
	for i := 0; i < 3; i++ { // three periodic seals, each writing fresh chunks
		bn := capBegin()
		capSetSession(name, pass, dk)
		h := postBlob("s3", append(bytes.Repeat([]byte("d"), 900), byte('0'+i)))
		putRef("s3", profileRefV2(name, pass), h)
		capFlush(bn)
	}
	if after, _ := loadWallet(wpath); after.balance() != 5 {
		t.Fatalf("3 seals under the free quota spent %d token(s), want 0", 5-after.balance())
	}
}

// Over the free quota, the entitled path buys capacity ONCE for the window: the first seal spends the
// excess, later seals ride the entitlement free -- and the device skips the doomed free attempt after
// the first same-epoch 402 (FreeFullEpoch).
func TestCapFlushOverQuotaBuysCapacityOnce(t *testing.T) {
	srv, _, _, freeCalls, entCalls := mockEntitledGateway(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(5)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	name, pass := "capu", "capacity beyond the free tier"
	dk := deriveKey(name, pass)
	for i := 0; i < 3; i++ {
		bn := capBegin()
		capSetSession(name, pass, dk)
		h := postBlob("s3", append(bytes.Repeat([]byte("x"), 700), byte('0'+i)))
		putRef("s3", profileRefV2(name, pass), h)
		capFlush(bn)
	}
	after, _ := loadWallet(wpath)
	if got := 5 - after.balance(); got != 1 {
		t.Fatalf("3 over-quota seals spent %d token(s), want exactly 1 (capacity bought once)", got)
	}
	if after.FreeFullEpoch != 42 {
		t.Fatalf("FreeFullEpoch=%d, want 42 (the 402 epoch remembered)", after.FreeFullEpoch)
	}
	if *freeCalls != 1 {
		t.Fatalf("free tier probed %d times, want 1 (skipped after the same-epoch 402)", *freeCalls)
	}
	if *entCalls != 3 {
		t.Fatalf("entitled leases: %d, want 3", *entCalls)
	}
}
