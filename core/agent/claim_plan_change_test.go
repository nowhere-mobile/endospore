package main

// NWP-20261031-10: the customer's answer at an upgrade -- convert or keep -- is asked on the phone at redemption,
// travels with the purchase in the wallet (a purchase activates later than it is redeemed, inside the jitter window)
// and reaches the gateway as plan_change on THAT purchase's activation lease, and only there. Since NWP-20261125-12
// (h51 #5) both answers are sent: "keep" or "convert", each only when it was chosen; a purchase redeemed without the
// question (plain CLAIM, or a wallet written before this build) sends nothing.
// Every test has its own profile name, its own session directory and its own wallet.

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"nowhereagent/blindrsa"
)

type cpcClaim struct {
	count, gb int
	periods   int64
}

// cpcGateway signs per-code claims (each its own size and term, reported on /issue), counts /issue calls, and
// records every /lease body as the raw JSON the wire carries.
type cpcGateway struct {
	srv    *httptest.Server
	mu     sync.Mutex
	epoch  int64
	issues int
	leases []map[string]any
}

func newCPCGateway(t *testing.T, claims map[string]cpcClaim) *cpcGateway {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	g := &cpcGateway{epoch: 100}
	mux := http.NewServeMux()
	mux.HandleFunc("/issue/pubkey", func(w http.ResponseWriter, _ *http.Request) {
		der, _ := x509.MarshalPKIXPublicKey(&priv.PublicKey)
		p := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
		json.NewEncoder(w).Encode(map[string]string{"pubkey_pem": p, "denom": "1GBmo"})
	})
	mux.HandleFunc("/issue", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Claim   string   `json:"claim"`
			Blinded []string `json:"blinded"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		g.mu.Lock()
		g.issues++
		c, ok := claims[req.Claim]
		if !ok || len(req.Blinded) == 0 || len(req.Blinded) > c.count {
			g.mu.Unlock()
			w.WriteHeader(http.StatusPaymentRequired)
			return
		}
		c.count -= len(req.Blinded)
		claims[req.Claim] = c
		g.mu.Unlock()
		sigs := make([]string, len(req.Blinded))
		for i, b := range req.Blinded {
			raw, _ := base64.StdEncoding.DecodeString(b)
			s, err := blindrsa.BlindSign(priv, raw)
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			sigs[i] = base64.StdEncoding.EncodeToString(s)
		}
		json.NewEncoder(w).Encode(issueResp{BlindSigs: sigs, Periods: c.periods, GB: c.gb})
	})
	mux.HandleFunc("/quote", func(w http.ResponseWriter, _ *http.Request) {
		g.mu.Lock()
		defer g.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"gb_per_token": 1, "current_epoch": g.epoch, "free_gb": 1})
	})
	mux.HandleFunc("/lease", func(w http.ResponseWriter, r *http.Request) {
		var raw map[string]any
		var req leaseReq
		body := json.NewDecoder(r.Body)
		body.Decode(&raw)
		b, _ := json.Marshal(raw)
		json.Unmarshal(b, &req)
		g.mu.Lock()
		g.leases = append(g.leases, raw)
		ep := g.epoch
		g.mu.Unlock()
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: ep + 90, DeadlineEpoch: ep + 120,
			Spent: len(req.Tokens) + len(req.BlindTokens), WriteCaps: map[string]string{}})
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

// cpcEnv points the daemon at gw with a live, local-only session (a plain OK, no store seal) and an empty wallet.
func cpcEnv(t *testing.T, gw *cpcGateway, profile string) (dest, wpath string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	dest = t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	t.Setenv("NOWHERE_ENROLL_STATE", filepath.Join(t.TempDir(), "enroll"))
	wpath = walletPathFor(dest)
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := markRoamSession(dest, profile, "a passphrase for "+profile, "12", ""); err != nil {
		t.Fatal(err)
	}
	markLocalSession(dest)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	pinQueueClock(t, 100)
	return dest, wpath
}

// cpcActivate runs one lease at epoch 102, past the 2-epoch jitter, so the waiting purchase activates.
func cpcActivate(t *testing.T, gw *cpcGateway, wpath, profile string) {
	t.Helper()
	gw.mu.Lock()
	gw.epoch = 102
	gw.mu.Unlock()
	nowEpoch = func() int64 { return 102 }
	if _, _, err := leaseRefs(newGatewayClient(gw.srv.URL, gwDefault), wpath, profile, map[string]int64{"blob/x": 1}, nil); err != nil {
		t.Fatalf("activation lease: %v", err)
	}
}

// buys is every /lease that declared buy_gb, oldest first.
func (g *cpcGateway) buys() []map[string]any {
	g.mu.Lock()
	defer g.mu.Unlock()
	var out []map[string]any
	for _, l := range g.leases {
		if n, _ := l["buy_gb"].(float64); n > 0 {
			out = append(out, l)
		}
	}
	return out
}

func wantPlanChange(t *testing.T, l map[string]any, want string) {
	t.Helper()
	got, present := l["plan_change"]
	if want == "" {
		if present {
			t.Fatalf("lease carries plan_change %v, want the field absent", got)
		}
		return
	}
	if got != want {
		t.Fatalf("lease plan_change = %v, want %q", got, want)
	}
}

// (a) CLAIM2 keep: the purchase is stored with Keep and its activation lease says so.
func TestClaimPlanChange_KeepIsStoredAndSentOnTheActivationLease(t *testing.T) {
	gw := newCPCGateway(t, map[string]cpcClaim{"CPC-KEEP": {count: 30, gb: 10, periods: 3}})
	dest, wpath := cpcEnv(t, gw, "cpckeepprof")
	if got := evictConn(t, dest, "CLAIM2\nCPC-KEEP\nkeep\n"); got != "OK 30" {
		t.Fatalf("CLAIM2 keep replied %q, want OK 30", got)
	}
	w := mustLoad(t, wpath)
	if !w.PlanKeep || w.PlanConvert || w.PlanGB != 10 || w.PlanPeriods != 3 {
		t.Fatalf("stored plan = %d x %d keep=%v convert=%v, want 10 x 3 with keep only", w.PlanGB, w.PlanPeriods, w.PlanKeep, w.PlanConvert)
	}
	cpcActivate(t, gw, wpath, "cpckeepprof")
	b := gw.buys()
	if len(b) != 1 {
		t.Fatalf("%d purchase leases, want 1", len(b))
	}
	wantPlanChange(t, b[0], "keep")
}

// (b) CLAIM2 convert: the purchase is stored with Convert and its activation lease sends plan_change "convert" (h51 #5).
func TestClaimPlanChange_ConvertIsStoredAndSentOnTheActivationLease(t *testing.T) {
	gw := newCPCGateway(t, map[string]cpcClaim{"CPC-CONV": {count: 30, gb: 10, periods: 3}})
	dest, wpath := cpcEnv(t, gw, "cpcconvprof")
	if got := evictConn(t, dest, "CLAIM2\nCPC-CONV\nconvert\n"); got != "OK 30" {
		t.Fatalf("CLAIM2 convert replied %q, want OK 30", got)
	}
	w := mustLoad(t, wpath)
	if !w.PlanConvert || w.PlanKeep || w.PlanGB != 10 || w.PlanPeriods != 3 {
		t.Fatalf("stored plan = %d x %d keep=%v convert=%v, want 10 x 3 with convert only", w.PlanGB, w.PlanPeriods, w.PlanKeep, w.PlanConvert)
	}
	cpcActivate(t, gw, wpath, "cpcconvprof")
	b := gw.buys()
	if len(b) != 1 {
		t.Fatalf("%d purchase leases, want 1", len(b))
	}
	wantPlanChange(t, b[0], "convert")
}

// (b2) plain CLAIM: the question was not asked, so nothing is stored and the field is absent.
func TestClaimPlanChange_PlainClaimSendsNoField(t *testing.T) {
	gw := newCPCGateway(t, map[string]cpcClaim{"CPC-PLAIN": {count: 30, gb: 10, periods: 3}})
	dest, wpath := cpcEnv(t, gw, "cpcplainprof")
	if got := evictConn(t, dest, "CLAIM\nCPC-PLAIN\n"); got != "OK 30" {
		t.Fatalf("CLAIM replied %q, want OK 30", got)
	}
	if w := mustLoad(t, wpath); w.PlanKeep || w.PlanConvert {
		t.Fatalf("CLAIM stored keep=%v convert=%v, want no answer", w.PlanKeep, w.PlanConvert)
	}
	cpcActivate(t, gw, wpath, "cpcplainprof")
	b := gw.buys()
	if len(b) != 1 {
		t.Fatalf("%d purchase leases, want 1", len(b))
	}
	wantPlanChange(t, b[0], "")
}

// (c) a queued purchase keeps its own answer and the waiting one keeps its own; "" is a plain CLAIM.
func TestClaimPlanChange_QueuedAndWaitingPurchasesKeepTheirOwnChoice(t *testing.T) {
	req := func(code, mode string) string {
		if mode == "" {
			return "CLAIM\n" + code + "\n"
		}
		return "CLAIM2\n" + code + "\n" + mode + "\n"
	}
	for _, c := range []struct{ label, profile, first, second string }{
		{"waiting keep, queued convert", "cpcqkeepconv", "keep", "convert"},
		{"waiting convert, queued keep", "cpcqconvkeep", "convert", "keep"},
		{"waiting unanswered, queued convert", "cpcqnoneconv", "", "convert"},
	} {
		t.Run(c.label, func(t *testing.T) {
			gw := newCPCGateway(t, map[string]cpcClaim{
				"CPC-FIRST":  {count: 50, gb: 50, periods: 1},
				"CPC-SECOND": {count: 30, gb: 10, periods: 3},
			})
			dest, wpath := cpcEnv(t, gw, c.profile)
			if got := evictConn(t, dest, req("CPC-FIRST", c.first)); got != "OK 50" {
				t.Fatalf("first claim replied %q", got)
			}
			if got := evictConn(t, dest, req("CPC-SECOND", c.second)); got != "OK 30" {
				t.Fatalf("second claim replied %q", got)
			}
			w := mustLoad(t, wpath)
			if w.PlanKeep != (c.first == "keep") || w.PlanConvert != (c.first == "convert") || len(w.PlanQueue) != 1 ||
				w.PlanQueue[0].Keep != (c.second == "keep") || w.PlanQueue[0].Convert != (c.second == "convert") {
				t.Fatalf("waiting keep=%v convert=%v queue=%+v, want waiting %q and queued %q", w.PlanKeep, w.PlanConvert, w.PlanQueue, c.first, c.second)
			}
			cpcActivate(t, gw, wpath, c.profile)
			w = mustLoad(t, wpath)
			if w.PlanGB != 10 || w.PlanKeep != (c.second == "keep") || w.PlanConvert != (c.second == "convert") || len(w.PlanQueue) != 0 {
				t.Fatalf("after promotion plan = %d keep=%v convert=%v queue=%+v, want 10 with %q", w.PlanGB, w.PlanKeep, w.PlanConvert, w.PlanQueue, c.second)
			}
			// the second purchase's own lease, past its fresh jitter
			nowEpoch = func() int64 { return 110 }
			gw.mu.Lock()
			gw.epoch = 110
			gw.mu.Unlock()
			if _, _, err := leaseRefs(newGatewayClient(gw.srv.URL, gwDefault), wpath, c.profile, map[string]int64{"blob/x": 1}, nil); err != nil {
				t.Fatal(err)
			}
			b := gw.buys()
			if len(b) != 2 {
				t.Fatalf("%d purchase leases, want 2", len(b))
			}
			wantPlanChange(t, b[0], c.first)
			wantPlanChange(t, b[1], c.second)
		})
	}
}

// (d) any other mode is ERR-ARGS and nothing is drained.
func TestClaimPlanChange_ABadModeIsRefusedBeforeAnythingIsDrained(t *testing.T) {
	for _, mode := range []string{"maybe", "", "KEEP", "keep "} {
		gw := newCPCGateway(t, map[string]cpcClaim{"CPC-BAD": {count: 30, gb: 10, periods: 3}})
		dest, wpath := cpcEnv(t, gw, "cpcbadprof")
		if got := evictConn(t, dest, "CLAIM2\nCPC-BAD\n"+mode+"\n"); got != "ERR-ARGS" {
			t.Fatalf("CLAIM2 mode %q replied %q, want ERR-ARGS", mode, got)
		}
		gw.mu.Lock()
		n := gw.issues
		gw.mu.Unlock()
		if n != 0 {
			t.Fatalf("CLAIM2 mode %q made %d /issue call(s), want none", mode, n)
		}
		if w := mustLoad(t, wpath); w.balance() != 0 || w.PlanGB != 0 {
			t.Fatalf("CLAIM2 mode %q drained: balance %d plan %d", mode, w.balance(), w.PlanGB)
		}
	}
}

// (e) a lease that buys nothing never carries the field, even with Keep set on the waiting purchase.
func TestClaimPlanChange_ALeaseWithoutBuyGBNeverCarriesTheField(t *testing.T) {
	gw := newCPCGateway(t, nil)
	g := newGatewayClient(gw.srv.URL, gwDefault)
	if _, _, err := g.leaseEntitled("cpcnobuy", nil, nil, map[string]int64{"blob/x": 1}, 1, 0, planChangeKeep, nil); err != nil {
		t.Fatal(err)
	}
	if _, _, err := g.leaseEntitledExpire("cpcnobuy", nil, nil, map[string]int64{"blob/x": 1}, 1, 0, planChangeKeep, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	if _, _, err := g.leaseEntitled("cpcnobuy", nil, nil, map[string]int64{"blob/x": 1}, 1, 0, planChangeConvert, nil); err != nil {
		t.Fatal(err)
	}
	// an ordinary seal of a wallet whose waiting purchase is Keep and not yet due also buys nothing.
	wp := queueWallet(t)
	pinQueueClock(t, 100)
	if err := saveWallet(wp, &Wallet{PlanGB: 10, PlanPeriods: 3, PlanKeep: true, PaidThrough: 500}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := leaseRefs(g, wp, "cpcnobuy2", map[string]int64{"blob/x": 1}, nil); err != nil {
		t.Fatal(err)
	}
	gw.mu.Lock()
	defer gw.mu.Unlock()
	if len(gw.leases) != 4 {
		t.Fatalf("%d leases, want 4", len(gw.leases))
	}
	for _, l := range gw.leases {
		wantPlanChange(t, l, "")
	}
}

// The choice is part of the purchase: two distinct codes of one size and term with different answers are two purchases.
func TestClaimPlanChange_SameSizeAndTermWithDifferentChoicesAreTwoPurchases(t *testing.T) {
	for _, c := range []struct {
		label                 string
		firstKeep, secondKeep bool
	}{
		{"keep then convert", true, false},
		{"convert then keep", false, true},
	} {
		t.Run(c.label, func(t *testing.T) {
			pinQueueClock(t, 100)
			wp := queueWallet(t)
			if err := recordPlan(wp, 3, 10, c.firstKeep); err != nil {
				t.Fatal(err)
			}
			if err := appendTokens(wp, make([]BlindToken, 30)); err != nil {
				t.Fatal(err)
			}
			if err := recordPlan(wp, 3, 10, c.secondKeep); err != nil {
				t.Fatal(err)
			}
			w := mustLoad(t, wp)
			if w.PlanKeep != c.firstKeep || len(w.PlanQueue) != 1 || w.PlanQueue[0].Keep != c.secondKeep {
				t.Fatalf("waiting keep=%v queue=%v, want waiting keep=%v and queued keep=%v", w.PlanKeep, w.PlanQueue, c.firstKeep, c.secondKeep)
			}
			// the interrupted-code retry (same answer again) still records nothing
			if err := recordPlan(wp, 3, 10, c.secondKeep); err != nil {
				t.Fatal(err)
			}
			if w = mustLoad(t, wp); len(w.PlanQueue) != 1 {
				t.Fatalf("a retry with the same answer queued again: %v", w.PlanQueue)
			}
		})
	}
}

// A late wallet restore carries each waiting purchase's choice.
func TestClaimPlanChange_ALateRestoreRetainsEachChoice(t *testing.T) {
	stored := &Wallet{PlanGB: 50, PlanPeriods: 3, PlanKeep: false, Tokens: make([]Token, 150), PlanQueue: []PlanSpec{{GB: 20, Periods: 1, Keep: true}}}
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanKeep: true, BlindTokens: make([]BlindToken, 30)}
	m := mergeLateRestore(stored, local)
	if m.PlanKeep {
		t.Fatalf("waiting purchase keep=true, want the stored purchase's convert")
	}
	if len(m.PlanQueue) != 2 || !m.PlanQueue[0].Keep || !m.PlanQueue[1].Keep {
		t.Fatalf("queue %v, want both queued purchases keep", m.PlanQueue)
	}
	m = mergeLateRestore(&Wallet{}, &Wallet{PlanGB: 10, PlanPeriods: 3, PlanKeep: true, BlindTokens: make([]BlindToken, 30)})
	if !m.PlanKeep || m.PlanGB != 10 {
		t.Fatalf("the session's funded keep purchase merged as keep=%v plan=%d", m.PlanKeep, m.PlanGB)
	}
}

// A late wallet restore carries a convert answer on the waiting purchase and on a queued one (h51 #5).
func TestClaimPlanChange_ALateRestoreRetainsAConvert(t *testing.T) {
	stored := &Wallet{PlanGB: 50, PlanPeriods: 3, PlanConvert: true, Tokens: make([]Token, 150), PlanQueue: []PlanSpec{{GB: 20, Periods: 1, Keep: true}}}
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanConvert: true, BlindTokens: make([]BlindToken, 30)}
	m := mergeLateRestore(stored, local)
	if !m.PlanConvert || m.PlanKeep {
		t.Fatalf("waiting purchase keep=%v convert=%v, want the stored purchase's convert", m.PlanKeep, m.PlanConvert)
	}
	if len(m.PlanQueue) != 2 || !m.PlanQueue[0].Keep || m.PlanQueue[0].Convert || !m.PlanQueue[1].Convert || m.PlanQueue[1].Keep {
		t.Fatalf("queue %+v, want keep then convert", m.PlanQueue)
	}
	m = mergeLateRestore(&Wallet{}, &Wallet{PlanGB: 10, PlanPeriods: 3, PlanConvert: true, BlindTokens: make([]BlindToken, 30)})
	if !m.PlanConvert || m.PlanGB != 10 {
		t.Fatalf("the session's funded convert purchase merged as convert=%v plan=%d", m.PlanConvert, m.PlanGB)
	}
}

// A convert after an identical purchase redeemed without the question is another purchase, and the other way round.
func TestClaimPlanChange_ConvertAfterAnIdenticalUnansweredPurchaseQueuesOnItsOwn(t *testing.T) {
	for _, c := range []struct{ label, first, second string }{
		{"none then convert", "", "convert"},
		{"convert then none", "convert", ""},
	} {
		t.Run(c.label, func(t *testing.T) {
			pinQueueClock(t, 100)
			wp := queueWallet(t)
			if err := recordPlanMode(wp, 3, 10, c.first); err != nil {
				t.Fatal(err)
			}
			if err := appendTokens(wp, make([]BlindToken, 30)); err != nil {
				t.Fatal(err)
			}
			if err := recordPlanMode(wp, 3, 10, c.second); err != nil {
				t.Fatal(err)
			}
			w := mustLoad(t, wp)
			if w.PlanConvert != (c.first == "convert") || len(w.PlanQueue) != 1 || w.PlanQueue[0].Convert != (c.second == "convert") {
				t.Fatalf("waiting convert=%v queue=%+v, want waiting %q and queued %q", w.PlanConvert, w.PlanQueue, c.first, c.second)
			}
			// the interrupted-code retry (same answer again) still records nothing
			if err := recordPlanMode(wp, 3, 10, c.second); err != nil {
				t.Fatal(err)
			}
			if w = mustLoad(t, wp); len(w.PlanQueue) != 1 {
				t.Fatalf("a retry with the same answer queued again: %+v", w.PlanQueue)
			}
		})
	}
}

// A wallet written before this build has no plan_convert: it is no answer, and the lease sends nothing.
func TestClaimPlanChange_AWalletWithoutPlanConvertSendsNothing(t *testing.T) {
	gw := newCPCGateway(t, map[string]cpcClaim{"CPC-OLD": {count: 30, gb: 10, periods: 3}})
	dest, wpath := cpcEnv(t, gw, "cpcoldjsonprof")
	if got := evictConn(t, dest, "CLAIM2\nCPC-OLD\nconvert\n"); got != "OK 30" {
		t.Fatalf("CLAIM2 convert replied %q, want OK 30", got)
	}
	b, err := os.ReadFile(wpath)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	if raw["plan_convert"] != true {
		t.Fatalf("wallet JSON plan_convert = %v, want true", raw["plan_convert"])
	}
	delete(raw, "plan_convert")
	if b, err = json.Marshal(raw); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(wpath, b, 0o600); err != nil {
		t.Fatal(err)
	}
	cpcActivate(t, gw, wpath, "cpcoldjsonprof")
	buys := gw.buys()
	if len(buys) != 1 {
		t.Fatalf("%d purchase leases, want 1", len(buys))
	}
	wantPlanChange(t, buys[0], "")
	var w Wallet
	if err := json.Unmarshal([]byte(`{"plan_gb":10,"plan_periods":3,"plan_queue":[{"gb":20,"periods":1}]}`), &w); err != nil {
		t.Fatal(err)
	}
	if w.planChange() != "" || w.PlanQueue[0].Convert {
		t.Fatalf("an old wallet reads as plan_change %q, queued convert=%v; want no answer", w.planChange(), w.PlanQueue[0].Convert)
	}
}
