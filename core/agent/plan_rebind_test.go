package main

// NWP-20260917-04: a paid plan follows a credential change.
//
// Entitlement grants are keyed on profileRefV2(name, passphrase), so before this slice a rotation or a
// 12-word recovery made the purchase unreachable forever -- which punished exactly the behaviour we most
// want: rotating after a suspected compromise, recovering after a real one. The gateway half is
// NWC-20260917-01; this is the client that calls it.
//
// ⚠ THE ROTATION TEST ALONE WOULD PASS ON A DESIGN THAT FAILS THE WHOLE POINT. A rotation holds the old
// passphrase and can simply derive the old billing key. A RECOVERY cannot -- the passphrase is what was
// lost -- and that is the case the !bill index entry exists for, so it is tested against a real
// recoverVault rather than a unit-level stand-in.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// rebindGateway records every /rebind it is asked for.
type rebindGateway struct {
	srv  *httptest.Server
	mu   sync.Mutex
	olds []string
	news []string
	// reply is what /rebind answers; zero value = {"moved":0}.
	moved int
}

func newRebindGateway(t *testing.T) *rebindGateway {
	t.Helper()
	g := &rebindGateway{moved: 1}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /rebind", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Old, New string }
		json.NewDecoder(r.Body).Decode(&req)
		g.mu.Lock()
		g.olds = append(g.olds, req.Old)
		g.news = append(g.news, req.New)
		g.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]int{"moved": g.moved})
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

func (g *rebindGateway) calls() ([]string, []string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.olds...), append([]string(nil), g.news...)
}

// TestARotationCarriesThePlanToTheNewKey is the easy half: both keys are derivable on the spot.
func TestARotationCarriesThePlanToTheNewKey(t *testing.T) {
	base := newHTTPStore(t)
	gw := newRebindGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	t.Setenv("NOWHERE_STATE", t.TempDir())

	const name, p1, p2 = "rbrot", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}

	olds, news := gw.calls()
	if len(olds) != 1 {
		t.Fatalf("/rebind was called %d time(s), want 1 -- the plan does not follow the rotation", len(olds))
	}
	if olds[0] != profileRefV2(name, p1) {
		t.Errorf("old = %s, want profileRefV2(name, oldpass) -- naming the wrong key moves nothing, and the "+
			"gateway cannot tell us so", short(olds[0]))
	}
	if news[0] != profileRefV2(name, p2) {
		t.Errorf("new = %s, want profileRefV2(name, newpass)", short(news[0]))
	}
}

// TestARecoveryCarriesThePlanToTheNewKey IS THE ONE THAT MATTERS. recoverVault has no old passphrase by
// premise, so the old billing key can only come from the !bill entry the scope index recorded under the old
// credential. If that record is missing, wrong, or read AFTER repointScopes has advanced it, this fails --
// and the failure is exactly "the customer who used their twelve words silently lost their plan".
func TestARecoveryCarriesThePlanToTheNewKey(t *testing.T) {
	base := newHTTPStore(t)
	gw := newRebindGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	t.Setenv("NOWHERE_STATE", t.TempDir())

	const name, p1, p2 = "rbrec", "horse battery staple correct", "a brand new passphrase"
	mnemonic := createVault(base, name, p1)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	// The key the gateway holds the grant under, captured BEFORE the recovery moves the credential.
	wantOld := profileRefV2(name, p1)

	if err := recoverVault(base, name, mnemonic, p2); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}

	olds, news := gw.calls()
	if len(olds) != 1 {
		t.Fatalf("/rebind was called %d time(s), want 1. A RECOVERY is the case this slice exists for -- you "+
			"recover precisely when somebody may hold your old passphrase, so losing the plan here punishes "+
			"the one action we most want people to take.", len(olds))
	}
	if olds[0] != wantOld {
		t.Errorf("old = %s, want %s (profileRefV2 under the PRE-recovery passphrase).\n"+
			"\tA recovery cannot derive this -- the passphrase is what was lost -- so it must come from the\n"+
			"\t!bill entry in the DK-sealed scope index, READ BEFORE repointScopes advances it.",
			short(olds[0]), short(wantOld))
	}
	if news[0] != profileRefV2(name, p2) {
		t.Errorf("new = %s, want profileRefV2(name, newpass)", short(news[0]))
	}
}

// TestTheBillingRecordSurvivesARotationSoTheNextRecoveryCanUseIt. repointScopes advances the record on
// every credential change; without that, a recovery AFTER a rotation would name a key two credentials old
// and move nothing.
func TestTheBillingRecordSurvivesARotationSoTheNextRecoveryCanUseIt(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, p1, p2 = "rbchain", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	dk, _, ok := resolveKey(base, name, p2)
	if !ok {
		t.Fatal("the rotated vault does not resolve")
	}
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
	if !isV {
		t.Fatal("the rotated head is not a vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the rotated vault carries no scope index")
	}
	if got := billKeyOf(idx); got != profileRefV2(name, p2) {
		t.Errorf("after a rotation the billing record reads %s, want the POST-rotation key %s -- a recovery "+
			"that followed would name a stale key and move nothing",
			short(got), short(profileRefV2(name, p2)))
	}
}

// TestABareSealBackfillsTheBillingRecord is THE path that reaches the existing fleet, and it is not the
// mint. deriveScopeIndex only runs for a profile with NO index at all; every profile already carrying one
// -- which is every profile that has sealed since NWP-20260915-02 -- would otherwise never record its
// billing key, and its next RECOVERY would still lose the plan.
//
// The fixture strips the entry to stand in for a profile sealed by a build that predates this slice.
func TestABareSealBackfillsTheBillingRecord(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "rbbackfill", "horse battery staple correct"
	createVault(base, name, pass)

	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("the fresh vault does not resolve")
	}
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("the fresh head is not a vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index to strip")
	}
	delete(idx, scopeBillKey) // a pre-NWP-20260917-04 index
	v.Scopes = sealScopeIndex(dk, idx)
	signVault(v, dk)
	putHead(base, name, pass, postBlob(base, serializeVault(v)))

	// Confirm the fixture really removed it, or the assertion below proves nothing.
	v2, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if idx2, ok := openScopeIndex(dk, v2.Scopes); !ok || billKeyOf(idx2) != "" {
		t.Fatal("fixture bug: the billing record was not stripped")
	}

	// An ordinary bare seal.
	d := t.TempDir()
	pushProfile(base, name, pass, d)

	v3, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("the sealed head is not a vault")
	}
	idx3, ok := openScopeIndex(dk, v3.Scopes)
	if !ok {
		t.Fatal("the sealed vault carries no scope index")
	}
	if got := billKeyOf(idx3); got != profileRefV2(name, pass) {
		t.Errorf("a bare seal did not backfill the billing record (got %q) -- every profile already carrying "+
			"a scope index would then keep losing its plan on recovery, which is the whole fielded fleet",
			got)
	}
}

// TestTheBillingRecordIsUnresolvableByAnOlderBuild is the whole backward-compatibility argument, and it is
// the reason for the p2: prefix.
//
// ⚠ BOTH INDEX WALKERS ITERATE BY MAP KEY, so a build carrying the scope index but not this slice WILL see
// the !bill entry and treat it as a scope. Unprefixed, the recorded value is the live bare vault head's
// REAL address: that build would resolve it, fail to open "name#!bill", and fail the whole rotation -- or
// answer BLANK to a correct twelve-word phrase. The prefix is what makes getRef miss instead.
func TestTheBillingRecordIsUnresolvableByAnOlderBuild(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "rbprefix", "horse battery staple correct"
	createVault(base, name, pass)
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("the fresh vault does not resolve")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index")
	}

	rec := idx[scopeBillKey]
	if rec.Ref == "" {
		t.Fatal("no billing record was written")
	}
	if getRef(base, rec.Ref) != "" {
		t.Errorf("the recorded ref %q RESOLVES. An older build walks this entry as a scope, and a resolvable "+
			"ref sends it down the re-point path -- which fails the whole rotation and answers BLANK to a "+
			"correct recovery phrase.", rec.Ref)
	}
	if rec.Wrapped != "" {
		t.Error("the billing record declares a wrapped key; it names no head and must carry none")
	}
	if rec.Observed {
		t.Error("the billing record is marked Observed -- nothing was ever sealed at that address")
	}
	// ...and the bare profile head, which is what it RECORDS, is of course live. This is what would have
	// been resolvable without the prefix.
	if getRef(base, profileRefV2(name, pass)) == "" {
		t.Fatal("fixture bug: the bare head does not resolve, so the prefix check above proves nothing")
	}
}

// TestANoOpCredentialChangeDoesNotSpendThePlansOneMove. Nothing in the agent or the chooser rejects
// newpass == oldpass, and the gateway allows one move per plan per cooldown -- so a "change" that moved
// nothing would strand the plan for the whole window.
func TestANoOpCredentialChangeDoesNotSpendThePlansOneMove(t *testing.T) {
	gw := newRebindGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)

	_ = rebindPlanReporting("samekey", "samekey")
	_ = rebindPlanReporting("", "newkey")
	_ = rebindPlanReporting("oldkey", "")

	if olds, _ := gw.calls(); len(olds) != 0 {
		t.Errorf("%d pointless /rebind call(s) were made; each one burns the plan's single move inside the "+
			"cooldown", len(olds))
	}
}

// TestARefusalIsNotASuccessfulMove pins the branch that is easy to leave out. postJSONReasonOn returns
// err == nil on EVERY non-2xx, so a rebind that checked only err would read a 404 from a gateway predating
// the endpoint -- or a 503 from one whose ledger is wedged -- as "the plan moved". The device would then
// log a success, never ask again, and the customer's plan would sit at the old key forever.
func TestARefusalIsNotASuccessfulMove(t *testing.T) {
	for _, code := range []int{http.StatusNotFound, http.StatusServiceUnavailable, http.StatusBadRequest} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "nope", code)
		}))
		moved, got, err := newGatewayClient(srv.URL, gwProbe).rebind("oldkey", "newkey")
		srv.Close()
		if err == nil {
			t.Errorf("HTTP %d was reported as a SUCCESSFUL move (moved=%d) -- a refusal must be an error, or "+
				"the plan is silently abandoned at the old key", code, moved)
		}
		if got != code {
			t.Errorf("status = %d, want %d", got, code)
		}
		if moved != 0 {
			t.Errorf("a refusal reported %d grant(s) moved", moved)
		}
	}
}

// TestPlanCarryIsSkippedWithNoGateway. A self-hosted device never reaches a gateway; the carry must be a
// silent no-op rather than an error on a credential change.
func TestPlanCarryIsSkippedWithNoGateway(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	_ = rebindPlanReporting("oldkey", "newkey") // must not panic, must not block
}

// TestPlanCarryNeverFailsACredentialChange. rebindPlanReporting swallows every failure on purpose, and its
// bool says only whether a RETRY is worth making -- it is never an error the caller can propagate:
// handleRotate reads any error from rotateVault as a rotation outcome and rolls the KEYGUARD back, aiming
// the lockscreen at a passphrase that no longer opens the vault; recoverVault's wrapper collapses an error
// to BLANK. A plan that failed to follow is a support ticket -- either of those is a lockout.
//
// NWP-20260917-16: this used to call maybeRebindPlan, a second entry point that discarded the verdict. That
// discard is what let a SUCCESSFUL carry leave its !bill-prev record behind, so there is one body now.
func TestPlanCarryNeverFailsACredentialChange(t *testing.T) {
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "ledger unavailable", http.StatusServiceUnavailable)
	}))
	t.Cleanup(dead.Close)
	t.Setenv("GATEWAY_URL", dead.URL)
	_ = rebindPlanReporting("oldkey", "newkey") // a 503 must be absorbed

	t.Setenv("GATEWAY_URL", "http://127.0.0.1:1") // nothing listening
	_ = rebindPlanReporting("oldkey", "newkey")

	// ...and the credential change itself still succeeds end to end against a gateway that refuses.
	base := newHTTPStore(t)
	t.Setenv("GATEWAY_URL", dead.URL)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, p1, p2 = "rbdead", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("a refused /rebind failed the ROTATION itself: %v.\n"+
			"\tThat is a lockout: handleRotate rolls the keyguard back below capRetireBegun, pointing the "+
			"lockscreen at a passphrase that no longer opens the vault.", err)
	}
	if _, _, ok := resolveKey(base, name, p2); !ok {
		t.Fatal("the rotation did not take")
	}
}
