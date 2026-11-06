package main

// NWP-20261103-01 (Q147): the intermediate key of a chained passphrase change is kept in !bill-mid and the
// retry asks it too. The fake gateway below models what the real ledger does that matters here: grants live at
// a key, /rebind moves one, a move stamps it, and a stamped grant inside the cooldown (or a key holding nothing)
// answers 200 {"moved":0}.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type chainGateway struct {
	srv      *httptest.Server
	mu       sync.Mutex
	grants   map[string]int  // key -> grants held there
	stamped  map[string]bool // key -> the grant here moved inside the cooldown
	dropNext bool            // move, then close the connection without a reply
	olds     []string
}

func newChainGateway(t *testing.T) *chainGateway {
	t.Helper()
	g := &chainGateway{grants: map[string]int{}, stamped: map[string]bool{}}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /rebind", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Old, New string }
		json.NewDecoder(r.Body).Decode(&req)
		g.mu.Lock()
		g.olds = append(g.olds, req.Old)
		moved := 0
		if n := g.grants[req.Old]; n > 0 && !g.stamped[req.Old] {
			moved = n
			delete(g.grants, req.Old)
			g.grants[req.New] += n
			g.stamped[req.New] = true
		}
		drop := g.dropNext && moved > 0
		if drop {
			g.dropNext = false
		}
		g.mu.Unlock()
		if drop {
			if c, _, err := w.(http.Hijacker).Hijack(); err == nil {
				c.Close()
			}
			return
		}
		json.NewEncoder(w).Encode(map[string]int{"moved": moved})
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

func (g *chainGateway) liftCooldown() {
	g.mu.Lock()
	g.stamped = map[string]bool{}
	g.mu.Unlock()
}

func (g *chainGateway) at(k string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.grants[k]
}

func (g *chainGateway) asked() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.olds...)
}

// chainIndexOfHead reads the published head's scope index, so no assertion inspects an unsealed value.
func chainIndexOfHead(t *testing.T, base, name, pass string, dk []byte) map[string]scopeRec {
	t.Helper()
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV || v == nil {
		t.Fatal("no vault at the published head")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the scope index does not open")
	}
	return idx
}

func chainFixture(t *testing.T) (base, wpath string) {
	t.Helper()
	base = newHTTPStore(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	wpath = filepath.Join(state, "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{PaidThrough: 1 << 40, PlanGB: 10}); err != nil {
		t.Fatal(err)
	}
	return base, wpath
}

func chainRotate(t *testing.T, base, name, from, to string) {
	t.Helper()
	if _, err := rotateVault(base, name, from, to, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
}

// (a) The honest chain: A->B moves the plan but the reply is lost, B->C is refused by the cooldown, and the
// retry at a sign-in under C must reach B.
func TestPlanCarryChainReachesTheIntermediateKey(t *testing.T) {
	base, wpath := chainFixture(t)
	gw := newChainGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	const name, pA, pB, pC = "chainhonest", "horse battery staple correct", "the second passphrase", "the third one"
	kA, kB, kC := profileRefV2(name, pA), profileRefV2(name, pB), profileRefV2(name, pC)
	createVault(base, name, pA)
	gw.grants[kA] = 1
	gw.dropNext = true
	chainRotate(t, base, name, pA, pB)
	if gw.at(kB) != 1 {
		t.Fatal("fixture bug: the A->B move did not happen at the gateway")
	}
	chainRotate(t, base, name, pB, pC)
	if gw.at(kC) != 0 {
		t.Fatal("fixture bug: B->C moved inside the cooldown")
	}
	dk, _, _ := resolveKey(base, name, pC)
	idx := chainIndexOfHead(t, base, name, pC, dk)
	if billPrevOf(idx) != kA || len(billMidOf(idx)) != 1 || billMidOf(idx)[0] != kB {
		t.Fatalf("records after the chain: prev=%s mid=%v, want prev=key(A) mid=[key(B)]", short(billPrevOf(idx)), billMidOf(idx))
	}
	gw.liftCooldown()
	retryPlanCarry(base, name, pC, dk, wpath)
	if gw.at(kC) != 1 {
		t.Errorf("the plan is not at key(C) after the retry (asked %v): it is stranded at key(B)", gw.asked())
	}
	idx = chainIndexOfHead(t, base, name, pC, dk)
	if billPrevOf(idx) != "" || len(billMidOf(idx)) != 0 {
		t.Errorf("records survived a settled carry: prev=%q mid=%v", billPrevOf(idx), billMidOf(idx))
	}
}

// (b) One change keeps no mid record.
func TestPlanCarryChainSingleChangeKeepsNoMidRecord(t *testing.T) {
	base, _ := chainFixture(t)
	t.Setenv("GATEWAY_URL", "")
	const name, pA, pB = "chainsingle", "horse battery staple correct", "the second passphrase"
	createVault(base, name, pA)
	chainRotate(t, base, name, pA, pB)
	dk, _, _ := resolveKey(base, name, pB)
	idx := chainIndexOfHead(t, base, name, pB, dk)
	if billPrevOf(idx) != profileRefV2(name, pA) {
		t.Fatalf("fixture bug: !bill-prev = %s, want key(A)", short(billPrevOf(idx)))
	}
	if _, has := idx[scopeBillMidKey]; has {
		t.Errorf("a single change wrote !bill-mid %v", billMidOf(idx))
	}
}

// (c) A->B->A never records the key the profile moved back to.
func TestPlanCarryChainBackToAWritesNoMidNamingA(t *testing.T) {
	base, _ := chainFixture(t)
	t.Setenv("GATEWAY_URL", "")
	const name, pA, pB = "chainback", "horse battery staple correct", "the second passphrase"
	createVault(base, name, pA)
	chainRotate(t, base, name, pA, pB)
	chainRotate(t, base, name, pB, pA)
	dk, _, _ := resolveKey(base, name, pA)
	idx := chainIndexOfHead(t, base, name, pA, dk)
	for _, k := range billMidOf(idx) {
		if k == profileRefV2(name, pA) {
			t.Errorf("!bill-mid names key(A), the key the profile moved back to: %v", billMidOf(idx))
		}
	}
}

// (d) A grant at A (it never moved) and another at B (a purchase made under B): one retry moves both.
func TestPlanCarryChainRetryMovesEveryKeyThatHoldsAGrant(t *testing.T) {
	base, wpath := chainFixture(t)
	gw := newChainGateway(t)
	t.Setenv("GATEWAY_URL", "")
	const name, pA, pB, pC = "chaintwo", "horse battery staple correct", "the second passphrase", "the third one"
	kA, kB, kC := profileRefV2(name, pA), profileRefV2(name, pB), profileRefV2(name, pC)
	createVault(base, name, pA)
	chainRotate(t, base, name, pA, pB)
	chainRotate(t, base, name, pB, pC)
	dk, _, _ := resolveKey(base, name, pC)
	gw.grants[kA], gw.grants[kB] = 1, 1
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	retryPlanCarry(base, name, pC, dk, wpath)
	if gw.at(kC) != 2 {
		t.Errorf("%d grant(s) at key(C), want 2 (asked %v): the retry stopped before every key was tried", gw.at(kC), gw.asked())
	}
}

// (e) An older build's walker cannot resolve !bill-mid, and no store walker treats it as a scope.
func TestPlanCarryChainMidRecordIsUnresolvableByAnOlderBuild(t *testing.T) {
	base, _ := chainFixture(t)
	t.Setenv("GATEWAY_URL", "")
	const name, pA, pB, pC = "chainunres", "horse battery staple correct", "the second passphrase", "the third one"
	createVault(base, name, pA)
	chainRotate(t, base, name, pA, pB)
	chainRotate(t, base, name, pB, pC)
	dk, _, _ := resolveKey(base, name, pC)
	rec := chainIndexOfHead(t, base, name, pC, dk)[scopeBillMidKey]
	if rec.Ref == "" || !strings.HasPrefix(rec.Ref, billRefPrefix) {
		t.Fatalf("fixture bug: no prefixed !bill-mid record (%q)", rec.Ref)
	}
	if getRef(base, rec.Ref) != "" {
		t.Errorf("the recorded ref %q RESOLVES", rec.Ref)
	}
	if rec.Wrapped != "" || rec.Observed {
		t.Error("the !bill-mid record declares a key or is Observed; it names no head")
	}
	if isScopeSuffix(scopeBillMidKey) {
		t.Error("isScopeSuffix(!bill-mid) is true: every walker that does store I/O would treat it as a scope")
	}
}
