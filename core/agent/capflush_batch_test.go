package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
)

// NWP-20261112-08 (Q090, docs/product-decisions.md, 2026-10-20): capFlush's entitled lease goes in batches of
// leaseBatchRefs. The purchase rides batch 0 only and is judged on the whole flush; batch 0 is settled and the wallet
// saved before the tokenless later batches; a later batch that fails fails the flush. test-capflush-batch.sh
// --mutate breaks each of those in turn.

// batchGateway answers the free lease 402 and every entitled lease 200 with a write cap for each ref it names (but
// those it lists as present), charging buy_gb*periods when tokens are presented, unless reply scripts the entitled
// request at that index. It records every entitled request and every PUT.
type batchGateway struct {
	srv     *httptest.Server
	mu      sync.Mutex
	leases  []leaseReq // the entitled /lease requests, in order
	puts    []string   // every key PUT through /obj
	freeGB  int64
	present func(key string) bool
	// reply, when non-nil and returning a non-zero code, is the answer to entitled request i.
	reply func(i int, req leaseReq) (int, string)
	// NWP-20261112-13: frees records every free /lease request, in order. free, when nil, answers each one 402;
	// else its non-zero, non-200 code is the answer to free request i, and anything else is a 200 with a write cap
	// for every ref, planGB as plan_gb, and the request's expire keys as expire_applied.
	frees  []leaseReq
	free   func(i int, req leaseReq) (int, string)
	planGB int
}

func newBatchGateway(t *testing.T) *batchGateway {
	t.Helper()
	g := &batchGateway{}
	objs := map[string][]byte{}
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		g.mu.Lock()
		defer g.mu.Unlock()
		if r.Method == http.MethodPut {
			b, _ := io.ReadAll(r.Body)
			objs[k] = b
			g.puts = append(g.puts, k)
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
		free := g.freeGB
		g.mu.Unlock()
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42, FreeGB: free})
	})
	var n int
	mux.HandleFunc("POST /tokens", func(w http.ResponseWriter, r *http.Request) {
		var req tokensReq
		json.NewDecoder(r.Body).Decode(&req)
		var out tokensResp
		g.mu.Lock()
		for i := 0; i < req.Count; i++ {
			n++
			out.Tokens = append(out.Tokens, Token{Denom: "1GBmo", Nonce: fmt.Sprintf("cfb%d", n), Exp: 1 << 62, Sig: "sig"})
		}
		g.mu.Unlock()
		json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		for k := range req.Expire { // the real gateway's refuseExpire
			if _, in := req.Refs[k]; !in {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				io.WriteString(w, `{"error":"expire ref not in refs"}`)
				return
			}
		}
		if req.Free {
			g.mu.Lock()
			i := len(g.frees)
			g.frees = append(g.frees, req)
			free, planGB := g.free, g.planGB
			g.mu.Unlock()
			if free == nil {
				w.WriteHeader(http.StatusPaymentRequired)
				return
			}
			if code, body := free(i, req); code != 0 && code != http.StatusOK {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(code)
				io.WriteString(w, body)
				return
			}
			out := leaseInfo{ThroughEpoch: 99, WriteCaps: map[string]string{}, PlanGB: planGB}
			for ref := range req.Refs {
				out.WriteCaps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
			}
			for k := range req.Expire {
				out.ExpireApplied = append(out.ExpireApplied, k)
			}
			sort.Strings(out.ExpireApplied)
			json.NewEncoder(w).Encode(out)
			return
		}
		g.mu.Lock()
		i := len(g.leases)
		g.leases = append(g.leases, req)
		reply, present := g.reply, g.present
		g.mu.Unlock()
		if reply != nil {
			if code, body := reply(i, req); code != 0 && code != http.StatusOK {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(code)
				io.WriteString(w, body)
				return
			}
		}
		out := leaseInfo{ThroughEpoch: 99, WriteCaps: map[string]string{}}
		for ref := range req.Refs {
			if present != nil && present(ref) {
				out.Present = append(out.Present, ref)
				continue
			}
			out.WriteCaps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
		}
		if len(req.Tokens)+len(req.BlindTokens) > 0 {
			out.Spent = req.BuyGB * int(req.Periods)
		}
		json.NewEncoder(w).Encode(out)
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

// batchFixture points the agent at g with a wallet of nTok faucet tokens and a pending plan of nTok GB for one
// period, and shrinks leaseBatchRefs to batch (0 keeps the default). It returns the wallet path.
func batchFixture(t *testing.T, g *batchGateway, nTok, batch int, activateAfter int64) string {
	t.Helper()
	t.Setenv("GATEWAY_URL", g.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}
	blobCache = nil
	contentCache = nil
	capLeaseRefused, capLeaseLanded = 0, nil
	if batch > 0 {
		was := leaseBatchRefs
		leaseBatchRefs = batch
		t.Cleanup(func() { leaseBatchRefs = was })
	}
	t.Cleanup(func() { capBracketLeakCheck(t) })
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(g.srv.URL, gwDefault).buyFaucet(nTok)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: nTok, PlanPeriods: 1, ActivateAfter: activateAfter}); err != nil {
		t.Fatal(err)
	}
	if err := markWalletRestoreLanded(wpath, walletGeneration(wpath)); err != nil { // so the flush folds the wallet
		t.Fatal(err)
	}
	return wpath
}

// batchSeal stages nBlobs distinct blobs and the profile head in a bracket for name/pass (with prior, when set),
// lets stage adjust the staged state, and flushes it. It reports whether the flush panicked and with what.
func batchSeal(t *testing.T, name, pass string, nBlobs int, prior []string, stage func()) (rec any) {
	t.Helper()
	bn := capBegin()
	capSetSession(name, pass, deriveKey(name, pass))
	if prior != nil {
		capSetSessionPrior(prior)
	}
	var h string
	for i := 0; i < nBlobs; i++ {
		h = postBlob("s3", bytes.Repeat([]byte(fmt.Sprintf("%s blob %d ", name, i)), 256))
	}
	putRef("s3", profileRefV2(name, pass), h)
	if stage != nil {
		stage()
	}
	defer func() { rec = recover() }()
	capFlush(bn)
	return nil
}

func (g *batchGateway) snapshot() ([]leaseReq, []string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]leaseReq(nil), g.leases...), append([]string(nil), g.puts...)
}

func (g *batchGateway) freeSnapshot() []leaseReq {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]leaseReq(nil), g.frees...)
}

func batchRefKeys(m map[string]int64) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// unionOnce is the union of the requests' refs, failing on a ref that is in two of them.
func unionOnce(t *testing.T, reqs []leaseReq) map[string]int64 {
	t.Helper()
	all := map[string]int64{}
	for i, r := range reqs {
		for k, v := range r.Refs {
			if _, dup := all[k]; dup {
				t.Errorf("ref %s is in two entitled requests (the second is %d)", k, i)
			}
			all[k] = v
		}
	}
	return all
}

func presents(r leaseReq) bool { return len(r.Tokens)+len(r.BlindTokens) > 0 }

// B1: an over-free flush of 8 refs goes in ceil(8/3) entitled requests; only the first presents tokens and declares
// buy_gb; every ref is in exactly one; the PUT phase has a write cap for every ref.
func TestCapFlushBatch_SplitsTheLeaseAndBuysOnlyOnTheFirst(t *testing.T) {
	g := newBatchGateway(t)
	batchFixture(t, g, 1, 3, 0)
	if rec := batchSeal(t, "cfbatchone", "split the lease in three", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	reqs, puts := g.snapshot()
	all := unionOnce(t, reqs)
	if len(all) != 8 {
		t.Fatalf("the flush leased %d refs, want 8 (5 blobs, the head, the wallet fold's blob and head)", len(all))
	}
	if len(reqs) != 3 {
		t.Fatalf("%d entitled /lease requests for 8 refs at leaseBatchRefs=3, want 3", len(reqs))
	}
	for i, r := range reqs {
		if i == 0 && (!presents(r) || r.BuyGB == 0) {
			t.Errorf("request 0 presented %d token(s) with buy_gb=%d, want the purchase", len(r.Tokens)+len(r.BlindTokens), r.BuyGB)
		}
		if i > 0 && (presents(r) || r.BuyGB != 0 || r.PlanChange != "") {
			t.Errorf("later request %d presented %d token(s), buy_gb=%d, plan_change=%q: only batch 0 may buy",
				i, len(r.Tokens)+len(r.BlindTokens), r.BuyGB, r.PlanChange)
		}
		if i > 0 && r.Periods != reqs[0].Periods {
			t.Errorf("later request %d carried periods=%d, want batch 0's %d", i, r.Periods, reqs[0].Periods)
		}
	}
	if want := batchRefKeys(all)[:3]; strings.Join(batchRefKeys(reqs[0].Refs), ",") != strings.Join(want, ",") {
		t.Errorf("request 0 leased %v, want the first 3 refs in sorted order %v", batchRefKeys(reqs[0].Refs), want)
	}
	putSet := map[string]bool{}
	for _, k := range puts {
		putSet[k] = true
	}
	for k := range all {
		if !putSet[k] {
			t.Errorf("ref %s was leased but never PUT", k)
		}
	}
	if len(putSet) != len(all) {
		t.Errorf("%d distinct keys PUT, want the %d leased", len(putSet), len(all))
	}
}

// B2: the purchase is judged on the whole flush. Batch 0 alone is under the 1 GB allowance, the whole flush is over
// it, and the plan sits inside its activation jitter: only an over-free judgment buys, and it must.
func TestCapFlushBatch_ThePurchaseIsJudgedOnTheWholeFlush(t *testing.T) {
	g := newBatchGateway(t)
	g.freeGB = 1
	g.present = func(k string) bool { return strings.HasPrefix(k, "blob/") } // nothing reads the faked sizes
	batchFixture(t, g, 1, 3, 1000)
	rec := batchSeal(t, "cfbatchwhole", "judge the whole flush", 4, nil, func() {
		capWriteMu.Lock()
		for i := range capCur.blobs {
			capCur.blobs[i].size = 300 << 20 // 4 x 300 MiB: over 1 GiB in all, under it in any 3
		}
		capWriteMu.Unlock()
	})
	if rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	reqs, _ := g.snapshot()
	if len(reqs) < 2 {
		t.Fatalf("%d entitled requests, want the flush split", len(reqs))
	}
	var b0 int64
	for _, sz := range reqs[0].Refs {
		b0 += sz
	}
	if b0 > 1<<30 {
		t.Fatalf("precondition: batch 0 carries %d bytes, want it under the 1 GiB allowance", b0)
	}
	if !presents(reqs[0]) || reqs[0].BuyGB == 0 {
		t.Fatalf("batch 0 bought nothing (buy_gb=%d) although the whole flush is over the free allowance: the "+
			"purchase was judged on batch 0's bytes", reqs[0].BuyGB)
	}
}

// B3: a 409 on batch 0 retries batch 0 tokenless (after the re-fold, re-split), then sends the rest; the nonce the
// 409 names is retired and the other kept, as without batching.
func TestCapFlushBatch_A409OnBatchZeroRetriesItThenSendsTheRest(t *testing.T) {
	g := newBatchGateway(t)
	g.reply = func(i int, req leaseReq) (int, string) {
		if i == 0 {
			return http.StatusConflict, string(deadBody(req.Tokens[0].Nonce))
		}
		return 0, ""
	}
	wpath := batchFixture(t, g, 2, 3, 0)
	before, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if rec := batchSeal(t, "cfbatchconflict", "retry batch zero only", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	reqs, _ := g.snapshot()
	if len(reqs) != 4 {
		t.Fatalf("%d entitled requests, want the 409'd purchase, batch 0 again, and two later batches", len(reqs))
	}
	if !presents(reqs[0]) {
		t.Fatal("precondition: request 0 was not the purchase")
	}
	rest := reqs[1:]
	all := unionOnce(t, rest)
	if len(all) != 8 {
		t.Fatalf("the requests after the 409 leased %d refs, want 8", len(all))
	}
	for i, r := range rest {
		if presents(r) || r.BuyGB != 0 {
			t.Errorf("request %d after the 409 presented tokens or buy_gb=%d", i+1, r.BuyGB)
		}
	}
	if got, want := strings.Join(batchRefKeys(rest[0].Refs), ","), strings.Join(batchRefKeys(all)[:3], ","); got != want {
		t.Errorf("the 409 retry leased %v, want batch 0 of the re-folded flush %v", batchRefKeys(rest[0].Refs), batchRefKeys(all)[:3])
	}
	after, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if len(after.Tokens) != 1 || after.Tokens[0].Nonce != before.Tokens[1].Nonce {
		t.Fatalf("wallet holds %v after a 409 naming %s, want exactly %s kept", after.Tokens, before.Tokens[0].Nonce, before.Tokens[1].Nonce)
	}
}

// B4: a 500 on batch 2 fails the flush before any PUT, and the wallet already saved batch 0's purchase: the spent
// tokens are gone and the plan is no longer pending, so the next flush presents nothing.
func TestCapFlushBatch_ALaterFailureFailsTheFlushAfterThePurchaseIsSaved(t *testing.T) {
	g := newBatchGateway(t)
	g.reply = func(i int, _ leaseReq) (int, string) {
		if i == 2 {
			return http.StatusInternalServerError, `{"error":"edge hiccup"}`
		}
		return 0, ""
	}
	wpath := batchFixture(t, g, 1, 3, 0)
	rec := batchSeal(t, "cfbatchfail", "the third batch fails", 5, nil, nil)
	if rec == nil {
		t.Fatal("a 500 on a later batch did not fail the flush: that batch's refs have no write cap")
	}
	if capLeaseRefused != http.StatusInternalServerError {
		t.Errorf("capLeaseRefused = %d, want 500", capLeaseRefused)
	}
	reqs, puts := g.snapshot()
	if len(reqs) != 3 {
		t.Errorf("%d entitled requests, want 3 (the flush stops at the failed batch)", len(reqs))
	}
	if len(puts) != 0 {
		t.Errorf("%d PUT(s) after a failed lease, want none", len(puts))
	}
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if w.balance() != 0 || w.planPending() {
		t.Fatalf("the saved wallet holds %d token(s), plan pending=%v: batch 0's charged purchase was not recorded "+
			"before the later batch failed", w.balance(), w.planPending())
	}
	if gb, _, p, b := w.planPurchase(42, true); gb != 0 || len(p)+len(b) != 0 {
		t.Fatalf("the next planPurchase presents %d token(s) for %d GB: it would buy the plan a second time", len(p)+len(b), gb)
	}
}

// B5: a 402 on a later batch is a credit refusal carrying the gateway's reason, as a 402 on batch 0 is.
func TestCapFlushBatch_ALater402IsACreditRefusal(t *testing.T) {
	g := newBatchGateway(t)
	const reason = "storage quota exhausted for this plan"
	g.reply = func(i int, _ leaseReq) (int, string) {
		if i == 2 {
			return http.StatusPaymentRequired, `{"error":"` + reason + `"}`
		}
		return 0, ""
	}
	batchFixture(t, g, 1, 3, 0)
	rec := batchSeal(t, "cfbatchcredit", "the third batch is refused credit", 5, nil, nil)
	err, _ := rec.(error)
	if err == nil {
		t.Fatalf("the flush did not fail with an error (recovered %v)", rec)
	}
	if got := creditReason(err); got != reason {
		t.Fatalf("a later 402 failed the flush with %v (credit reason %q), want creditRefused(%q)", err, got, reason)
	}
	if capLeaseRefused != http.StatusPaymentRequired {
		t.Errorf("capLeaseRefused = %d, want 402", capLeaseRefused)
	}
}

// B6: with the default leaseBatchRefs a small flush sends exactly one entitled request, carrying every ref.
func TestCapFlushBatch_ASmallFlushIsOneRequest(t *testing.T) {
	g := newBatchGateway(t)
	batchFixture(t, g, 1, 0, 0)
	if rec := batchSeal(t, "cfbatchsmall", "one request as before", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	reqs, _ := g.snapshot()
	if len(reqs) != 1 {
		t.Fatalf("%d entitled requests for a small flush, want 1", len(reqs))
	}
	if len(reqs[0].Refs) != 8 || !presents(reqs[0]) {
		t.Fatalf("the one request leased %d refs (want 8) and presented tokens=%v", len(reqs[0].Refs), presents(reqs[0]))
	}
}

// B7: a later batch failing on a flush with a prior records what DID land -- batch 0 and the later batches that
// answered 200 have already re-tagged their rows on a strict gateway -- so compensateCredentialLease can hand them
// back. Exactly those refs: not the failed batch's.
func TestCapFlushBatch_APartialLandingIsRecordedForTheHandBack(t *testing.T) {
	g := newBatchGateway(t)
	g.reply = func(i int, _ leaseReq) (int, string) {
		if i == 2 {
			return http.StatusInternalServerError, `{"error":"edge hiccup"}`
		}
		return 0, ""
	}
	batchFixture(t, g, 1, 3, 0)
	const name, pass = "cfbatchprior", "a credential change in flight"
	x := strings.Repeat("c7", 32)
	if rec := batchSeal(t, name, pass, 5, []string{x}, nil); rec == nil {
		t.Fatal("precondition: the flush did not fail")
	}
	reqs, _ := g.snapshot()
	if len(reqs) != 3 {
		t.Fatalf("precondition: %d entitled requests, want 3", len(reqs))
	}
	rec := capLeaseLanded
	if rec == nil {
		t.Fatal("no lease recorded after batches 0 and 1 landed with a prior: a failing credential change could not hand their rows back")
	}
	want := unionOnce(t, reqs[:2])
	if rec.profile != profileRefV2(name, pass) || len(rec.prior) != 1 || rec.prior[0] != x || rec.periods != reqs[0].Periods {
		t.Errorf("recorded profile=%s prior=%v periods=%d, want the flush's own, [x], %d", short(rec.profile), shortAll(rec.prior), rec.periods, reqs[0].Periods)
	}
	if len(rec.refs) != len(want) {
		t.Errorf("recorded %d refs, want the %d batches 0 and 1 leased", len(rec.refs), len(want))
	}
	for k, v := range want {
		if got, ok := rec.refs[k]; !ok || got != v {
			t.Errorf("landed ref %s recorded as (%d, %v), want %d", k, got, ok, v)
		}
	}
	for k := range reqs[2].Refs {
		if _, ok := rec.refs[k]; ok {
			t.Errorf("ref %s of the failed batch was recorded as landed", k)
		}
	}
}

// NWP-20261112-13 (Q090): capFlush's FREE lease goes in batches of leaseBatchRefs too, each batch with its own expire
// and release subsets. A 402 on any batch sends the whole flush down the entitled arm; any other refusal fails it; a
// free batch that landed before a refusal is recorded for the hand-back.

// freeFixture is batchFixture with no plan pending (tokens kept), so the flush tries the free lease first.
func freeFixture(t *testing.T, g *batchGateway, batch int) string {
	t.Helper()
	wpath := batchFixture(t, g, 1, batch, 0)
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	w.PlanGB, w.PlanPeriods = 0, 0
	if err := saveWallet(wpath, w); err != nil {
		t.Fatal(err)
	}
	if err := markWalletRestoreLanded(wpath, walletGeneration(wpath)); err != nil {
		t.Fatal(err)
	}
	return wpath
}

// markRefs stages n extra refs in the open bracket and marks each one expire-now.
func markRefs(t *testing.T, tag string, n int) []string {
	t.Helper()
	var marked []string
	for i := 0; i < n; i++ {
		k := fmt.Sprintf("%s%060x", tag, i)
		putRef("s3", k, "v")
		if !capMarkExpire(k, bytes.Repeat([]byte{byte(i + 1)}, 32), expireNow) {
			t.Fatalf("capMarkExpire(%s) refused", k)
		}
		marked = append(marked, "ref/"+k)
	}
	sort.Strings(marked)
	return marked
}

func putKeys(puts []string) map[string]bool {
	set := map[string]bool{}
	for _, k := range puts {
		set[k] = true
	}
	return set
}

// F1: an in-allowance flush of 8 refs goes in ceil(8/3) free requests and no entitled one; each carries its own
// release commits; every ref gets a write cap and is PUT; the wallet is saved with batch 0's plan size.
func TestCapFlushBatch_FreeLeaseGoesInBatches(t *testing.T) {
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) { return http.StatusOK, "" }
	g.planGB = 7
	wpath := freeFixture(t, g, 3)
	const name, pass = "cfbfreeone", "the free lease in three"
	if rec := batchSeal(t, name, pass, 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	frees := g.freeSnapshot()
	reqs, puts := g.snapshot()
	if len(reqs) != 0 {
		t.Errorf("%d entitled requests for an in-allowance flush, want 0", len(reqs))
	}
	if len(frees) != 3 {
		t.Fatalf("%d free /lease requests for 8 refs at leaseBatchRefs=3, want 3", len(frees))
	}
	all := unionOnce(t, frees)
	if len(all) != 8 {
		t.Fatalf("the free requests leased %d refs, want 8", len(all))
	}
	for i, r := range frees {
		if !r.Free || r.Profile != profileRefV2(name, pass) {
			t.Errorf("free request %d: free=%v profile=%s, want the flush's free lease", i, r.Free, short(r.Profile))
		}
		var blobs []string
		for k := range r.Refs {
			if strings.HasPrefix(k, "blob/") {
				blobs = append(blobs, k)
			}
		}
		sort.Strings(blobs)
		var commits []string
		for k := range r.ReleaseCommit {
			commits = append(commits, k)
		}
		sort.Strings(commits)
		if strings.Join(commits, ",") != strings.Join(blobs, ",") {
			t.Errorf("free request %d committed release proofs for %v, want its own blobs %v", i, commits, blobs)
		}
	}
	putSet := putKeys(puts)
	for k := range all {
		if !putSet[k] {
			t.Errorf("ref %s was leased but never PUT", k)
		}
	}
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if w.balance() != 1 || w.FreeFullEpoch != 0 || w.AccountPlanGB != 7 {
		t.Fatalf("the saved wallet holds %d token(s), FreeFullEpoch=%d, AccountPlanGB=%d; want 1, 0, 7 (no tokens "+
			"moved, no latch, batch 0's plan size learned)", w.balance(), w.FreeFullEpoch, w.AccountPlanGB)
	}
}

// F2: a 402 on the second free batch sends the WHOLE flush down the entitled arm, in batches, buying once.
func TestCapFlushBatch_AFree402OnALaterBatchGoesEntitledOverTheWholeFlush(t *testing.T) {
	g := newBatchGateway(t)
	g.free = func(i int, _ leaseReq) (int, string) {
		if i == 1 {
			return http.StatusPaymentRequired, `{"error":"over the free allowance"}`
		}
		return http.StatusOK, ""
	}
	wpath := freeFixture(t, g, 3)
	const name, pass = "cfbfree402", "the second free batch is over"
	if rec := batchSeal(t, name, pass, 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	frees := g.freeSnapshot()
	reqs, puts := g.snapshot()
	if len(frees) != 2 {
		t.Errorf("%d free requests, want 2 (the free attempt stops at the 402)", len(frees))
	}
	if len(reqs) != 3 {
		t.Fatalf("%d entitled requests, want 3 (the whole flush of 8 refs at leaseBatchRefs=3)", len(reqs))
	}
	all := unionOnce(t, reqs)
	if len(all) != 8 {
		t.Fatalf("the entitled path leased %d refs, want all 8: the refs the free batches leased need it too", len(all))
	}
	if _, ok := all["ref/"+profileRefV2(name, pass)]; !ok {
		t.Error("the entitled path did not lease the profile head")
	}
	for i, r := range reqs {
		if presents(r) != (i == 0) {
			t.Errorf("entitled request %d presented tokens=%v, want only request 0 to buy", i, presents(r))
		}
	}
	putSet := putKeys(puts)
	for k := range all {
		if !putSet[k] {
			t.Errorf("ref %s was leased but never PUT", k)
		}
	}
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if w.FreeFullEpoch != 42 {
		t.Errorf("FreeFullEpoch = %d after a free 402, want 42", w.FreeFullEpoch)
	}
}

// F3: a 500 on a free batch fails the flush, sends nothing entitled and PUTs nothing.
func TestCapFlushBatch_AFree500OnABatchFailsTheFlush(t *testing.T) {
	g := newBatchGateway(t)
	g.free = func(i int, _ leaseReq) (int, string) {
		if i == 1 {
			return http.StatusInternalServerError, `{"error":"edge hiccup"}`
		}
		return http.StatusOK, ""
	}
	freeFixture(t, g, 3)
	if rec := batchSeal(t, "cfbfree500", "the second free batch fails", 5, nil, nil); rec == nil {
		t.Fatal("a 500 on a free batch did not fail the flush: that batch's refs have no write cap")
	}
	if capLeaseRefused != http.StatusInternalServerError {
		t.Errorf("capLeaseRefused = %d, want 500", capLeaseRefused)
	}
	reqs, puts := g.snapshot()
	if len(reqs) != 0 {
		t.Errorf("%d entitled requests after a free 500, want 0", len(reqs))
	}
	if len(puts) != 0 {
		t.Errorf("%d PUT(s) after a failed lease, want none", len(puts))
	}
}

// F4: each free batch marks only its own refs' expire entries, and the merged expire_applied names every mark.
func TestCapFlushBatch_TheFreeBatchesMarkEveryExpireRef(t *testing.T) {
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) { return http.StatusOK, "" }
	freeFixture(t, g, 3)
	var marked []string
	if rec := batchSeal(t, "cfbfreeexpire", "four marks across batches", 5, nil, func() {
		marked = markRefs(t, "f4", 4)
	}); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	frees := g.freeSnapshot()
	if len(frees) != 4 {
		t.Fatalf("%d free requests for 12 refs at leaseBatchRefs=3, want 4", len(frees))
	}
	var sent []string
	for i, r := range frees {
		for k := range r.Expire {
			if _, in := r.Refs[k]; !in {
				t.Errorf("free request %d marks %s, which it does not lease", i, k)
			}
			sent = append(sent, k)
		}
	}
	sort.Strings(sent)
	if strings.Join(sent, ",") != strings.Join(marked, ",") {
		t.Errorf("the free requests marked %v, want every mark once %v", sent, marked)
	}
	applied := append([]string(nil), capExpireApplied...)
	sort.Strings(applied)
	if strings.Join(applied, ",") != strings.Join(marked, ",") {
		t.Fatalf("capExpireApplied = %v, want the marks of every batch %v", applied, marked)
	}
}

// F5: with the default leaseBatchRefs a small free flush is the one request it was: every ref, the whole expire set,
// a release commit for every blob.
func TestCapFlushBatch_ASmallFreeFlushIsTheRequestItWas(t *testing.T) {
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) { return http.StatusOK, "" }
	freeFixture(t, g, 0)
	var marked []string
	if rec := batchSeal(t, "cfbfreesmall", "one free request as before", 5, nil, func() {
		marked = markRefs(t, "f5", 2)
	}); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	frees := g.freeSnapshot()
	if len(frees) != 1 {
		t.Fatalf("%d free requests for a small flush, want 1", len(frees))
	}
	r := frees[0]
	if len(r.Refs) != 10 {
		t.Errorf("the one free request leased %d refs, want all 10", len(r.Refs))
	}
	var sent []string
	for k := range r.Expire {
		sent = append(sent, k)
	}
	sort.Strings(sent)
	if strings.Join(sent, ",") != strings.Join(marked, ",") {
		t.Errorf("the one free request marked %v, want %v", sent, marked)
	}
	for k := range r.Refs {
		if _, ok := r.ReleaseCommit[k]; strings.HasPrefix(k, "blob/") && !ok {
			t.Errorf("blob %s has no release commit", k)
		}
	}
}

// F6: a free batch that fails after batch 0 landed with a prior records batch 0's refs, and only those, so a
// credential change failing from here can hand them back.
func TestCapFlushBatch_APartialFreeLandingIsRecordedForTheHandBack(t *testing.T) {
	g := newBatchGateway(t)
	g.free = func(i int, _ leaseReq) (int, string) {
		if i == 1 {
			return http.StatusInternalServerError, `{"error":"edge hiccup"}`
		}
		return http.StatusOK, ""
	}
	freeFixture(t, g, 3)
	const name, pass = "cfbfreeprior", "a free credential change in flight"
	x := strings.Repeat("f6", 32)
	if rec := batchSeal(t, name, pass, 5, []string{x}, nil); rec == nil {
		t.Fatal("a 500 on free batch 1 did not fail the flush")
	}
	frees := g.freeSnapshot()
	reqs, puts := g.snapshot()
	if len(frees) != 2 || len(reqs) != 0 {
		t.Fatalf("%d free and %d entitled requests, want 2 and 0", len(frees), len(reqs))
	}
	if capLeaseRefused != http.StatusInternalServerError {
		t.Errorf("capLeaseRefused = %d, want 500", capLeaseRefused)
	}
	if len(puts) != 0 {
		t.Errorf("%d PUT(s) after a failed lease, want none", len(puts))
	}
	rec := capLeaseLanded
	if rec == nil {
		t.Fatal("no lease recorded after free batch 0 landed with a prior: a failing credential change could not hand its rows back")
	}
	if rec.profile != profileRefV2(name, pass) || len(rec.prior) != 1 || rec.prior[0] != x || rec.periods != 0 {
		t.Errorf("recorded profile=%s prior=%v periods=%d, want the flush's own, [x], 0", short(rec.profile), shortAll(rec.prior), rec.periods)
	}
	if len(rec.refs) != len(frees[0].Refs) {
		t.Errorf("recorded %d refs, want the %d free batch 0 leased", len(rec.refs), len(frees[0].Refs))
	}
	for k, v := range frees[0].Refs {
		if got, ok := rec.refs[k]; !ok || got != v {
			t.Errorf("landed ref %s recorded as (%d, %v), want %d", k, got, ok, v)
		}
	}
	for k := range frees[1].Refs {
		if _, ok := rec.refs[k]; ok {
			t.Errorf("ref %s of the failed free batch was recorded as landed", k)
		}
	}
}

// F7: free batches 0 and 1 land, batch 2 answers 402, and the entitled arm's batch 1 fails: the record is the union
// of the free batches that landed and the entitled batch 0.
func TestCapFlushBatch_AFree402ThenAFailedEntitledBatchRecordsBothLandings(t *testing.T) {
	g := newBatchGateway(t)
	g.free = func(i int, _ leaseReq) (int, string) {
		if i == 2 {
			return http.StatusPaymentRequired, `{"error":"over the free allowance"}`
		}
		return http.StatusOK, ""
	}
	g.reply = func(i int, _ leaseReq) (int, string) {
		if i == 1 {
			return http.StatusInternalServerError, `{"error":"edge hiccup"}`
		}
		return 0, ""
	}
	freeFixture(t, g, 3)
	const name, pass = "cfbfreeunion", "both landings are handed back"
	x := strings.Repeat("f7", 32)
	if rec := batchSeal(t, name, pass, 5, []string{x}, nil); rec == nil {
		t.Fatal("a 500 on entitled batch 1 did not fail the flush")
	}
	frees := g.freeSnapshot()
	reqs, _ := g.snapshot()
	if len(frees) != 3 || len(reqs) != 2 {
		t.Fatalf("%d free and %d entitled requests, want 3 and 2", len(frees), len(reqs))
	}
	rec := capLeaseLanded
	if rec == nil {
		t.Fatal("no lease recorded after free and entitled batches landed with a prior")
	}
	if rec.profile != profileRefV2(name, pass) || len(rec.prior) != 1 || rec.prior[0] != x || rec.periods != reqs[0].Periods {
		t.Errorf("recorded profile=%s prior=%v periods=%d, want the flush's own, [x], %d", short(rec.profile), shortAll(rec.prior), rec.periods, reqs[0].Periods)
	}
	want := map[string]int64{}
	for _, m := range []map[string]int64{frees[0].Refs, frees[1].Refs, reqs[0].Refs} {
		for k, v := range m {
			want[k] = v
		}
	}
	if len(rec.refs) != len(want) {
		t.Errorf("recorded %d refs, want the %d of free batches 0, 1 and entitled batch 0", len(rec.refs), len(want))
	}
	for k, v := range want {
		if got, ok := rec.refs[k]; !ok || got != v {
			t.Errorf("landed ref %s recorded as (%d, %v), want %d", k, got, ok, v)
		}
	}
}
