package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// headHashes is every head blob a profile's six scopes resolve to. ⚠ A HEAD BLOB IS ALSO A `blob/<hash>`
// ENTRY WITH A NON-ZERO SIZE, so "counts as data" cannot simply mean "is a sized blob" -- a blind
// footprint leases exactly these and nothing else, and counting them as data made the first version of
// this test claim the blind path saw data it cannot see.
func headHashes(base, name, pass string) map[string]bool {
	out := map[string]bool{}
	for _, suf := range append([]string{""}, "#de", "#sys", "#media", "#apps", "#keys") {
		if h := getRef(base, headKey(base, name+suf, pass)); h != "" {
			out["blob/"+h] = true
		}
	}
	return out
}

// mustFootprint is profileFootprint for the tests that predate NWP-20260915-15's measured flag and
// only care about the map. It FAILS when the footprint was not measured, so a test that quietly
// started reading a heads-only list says so instead of shrinking its expectations.
func mustFootprint(t *testing.T, base, name, pass string, se []byte) map[string]int64 {
	t.Helper()
	refs, measured := profileFootprint(base, name, pass, se)
	if !measured {
		t.Fatalf("profileFootprint(%s) could not measure -- a scope resolved to a vault that no keyslot opened", logProfile(name))
	}
	return refs
}

// chunkRefs counts the entries in a footprint that are actual DATA -- manifest blobs and chunks -- as
// opposed to the head pointers and head blobs a blind footprint can still enumerate.
func chunkRefs(refs map[string]int64, heads map[string]bool) int {
	n := 0
	for k, sz := range refs {
		if strings.HasPrefix(k, "blob/") && sz > 0 && !heads[k] {
			n++
		}
	}
	return n
}

// hardenedWithData stands up a hardened profile that has actually sealed something, and returns its secret.
func hardenedWithData(t *testing.T, base, name, pass string) []byte {
	t.Helper()
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("payload"), 900), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	se := []byte("this-handsets-strongbox-secret")
	if err := enrollSE(base, name, pass, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	return se
}

// TestHardenedFootprintWithoutTheSecretSeesOnlyHeads is the measurement the whole slice turns on, and it is
// why fixing resolveDK alone would have been WORSE than fixing nothing (NWP-20260915-12).
//
// scopeFootprint opens the vault independently of resolveDK and, on nil, returns having added only the head
// pointer and the head blob. So a payRent that could pass its own gate but not open the vault HERE would
// lease the heads, re-stamp their deadlines as a successful renewal, and let every chunk age out underneath
// them -- a silent, confident, wrong renewal in place of a clean failure. The gateway GC then deletes those
// chunks one by one under a live head, and the next restore fails hard on the first missing one.
func TestHardenedFootprintWithoutTheSecretSeesOnlyHeads(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "rentblind", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)

	heads := headHashes(base, name, pass)
	blind, blindMeasured := profileFootprint(base, name, pass, nil)
	seeing, seeingMeasured := profileFootprint(base, name, pass, se)

	// NWP-20260915-15: the footprint SAYS when it could not see. Before that flag every caller had to
	// guess from a suspiciously small number, and none of them did -- the Storage screen reported ~0 GB
	// for a multi-GB profile and claimed to have measured it.
	if blindMeasured {
		t.Error("a footprint taken without the secret reported itself MEASURED -- every display built on " +
			"it will render a confidently wrong small number")
	}
	if !seeingMeasured {
		t.Error("a footprint taken WITH the secret reported itself unmeasured")
	}

	if got := chunkRefs(blind, heads); got != 0 {
		t.Errorf("a footprint taken without the secret leased %d data blob(s); want 0 -- if this is ever "+
			"non-zero the test below stops proving anything", got)
	}
	if got := chunkRefs(seeing, heads); got == 0 {
		t.Fatal("a footprint taken WITH the secret leased no data at all -- the rent payer would renew the " +
			"heads and let every chunk age out, which is the defect this slice exists to fix")
	}
	if len(seeing) <= len(blind) {
		t.Errorf("footprint with the secret has %d refs, without it %d -- the secret must make it STRICTLY "+
			"bigger, or the rent payer is still blind", len(seeing), len(blind))
	}
	// ...and the blind one is not empty either, which is exactly what makes it dangerous: payRent's own
	// `len(refs) == 0` guard does NOT catch it.
	if len(blind) == 0 {
		t.Error("the blind footprint is empty, so payRent's len(refs)==0 guard would have caught it -- the " +
			"real shape is a NON-empty footprint of heads only, and this test must reproduce that")
	}
}

// rentGateway is a mock gateway that records the ref set each lease presented.
type rentGateway struct {
	srv      *httptest.Server
	leased   []map[string]int64
	freeCode int  // status for POST /lease when Free
	conflict bool // answer the first entitled lease with 409, the way a spent nonce does
	seen     int
}

func newRentGateway(t *testing.T) *rentGateway {
	t.Helper()
	g := &rentGateway{freeCode: 200}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{
			Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 86400, EpochsPerLease: 30,
			PriceCents: 200, CurrentEpoch: 42, IssuerPubKey: "testpub", FreeGB: 1,
		})
	})
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 30, EntitledBytes: 0, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		g.seen++
		g.leased = append(g.leased, req.Refs)
		if g.conflict && g.seen == 1 {
			w.WriteHeader(http.StatusConflict)
			json.NewEncoder(w).Encode(leaseInfo{Reason: "nonce already spent"})
			return
		}
		if req.Free && g.freeCode != 200 {
			w.WriteHeader(g.freeCode)
			json.NewEncoder(w).Encode(leaseInfo{Reason: "over quota"})
			return
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, DeadlineEpoch: 129})
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

func (g *rentGateway) lastLeasedChunks(heads map[string]bool) int {
	if len(g.leased) == 0 {
		return -1
	}
	return chunkRefs(g.leased[len(g.leased)-1], heads)
}

// TestPayRentPresentsTheChunksOfAHardenedProfile: end to end through payRent, because the footprint test
// above cannot show that the value actually reaches it. maybePayRent is the only full-footprint re-lease in
// the system -- capFlush leases only what a flush writes, and postBlob skips a chunk it has already seen --
// so a chunk not presented here is never presented again and dies on its deadline.
func TestPayRentPresentsTheChunksOfAHardenedProfile(t *testing.T) {
	g := newRentGateway(t)
	base := newHTTPStore(t)
	const name, pass = "rentpays", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	freeRenewedThrough = map[string]int64{}

	if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, se); err != nil {
		t.Fatalf("payRent with the secret: %v", err)
	}
	if got := g.lastLeasedChunks(headHashes(base, name, pass)); got <= 0 {
		t.Fatalf("the lease presented %d data blob(s); a hardened profile's chunks must be re-presented or "+
			"the gateway GC deletes them individually, under a head that is still live", got)
	}
}

// TestPayRentRefusesAHardenedProfileItCannotOpen: the fielded behaviour, kept. Leasing the heads alone would
// be reported as a successful renewal, so a rent payer with no secret must fail LOUDLY rather than quietly
// re-stamping the wrong thing.
func TestPayRentRefusesAHardenedProfileItCannotOpen(t *testing.T) {
	g := newRentGateway(t)
	base := newHTTPStore(t)
	const name, pass = "rentblindfail", "horse battery staple correct"
	hardenedWithData(t, base, name, pass)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	saveWallet(wpath, &Wallet{})
	freeRenewedThrough = map[string]int64{}

	_, paid, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil)
	if err == nil {
		t.Fatal("payRent reported no error for a vault it could not open -- it must not renew a footprint it " +
			"cannot see")
	}
	if paid {
		t.Error("payRent reported that rent was paid")
	}
	if len(g.leased) != 0 {
		t.Errorf("it presented %d lease(s) anyway -- leasing the heads alone re-stamps their deadlines as a "+
			"successful renewal while every chunk ages out, which is worse than the clean failure", len(g.leased))
	}
}

// TestFreeRenewalThrottleLatchesOnSuccessNotOnTheAttempt: the latch was assigned BEFORE the vault open,
// before the footprint and before the lease -- so any failure downstream burned the profile's ONE
// whole-footprint renewal for the entire epoch, and nothing in the call chain retries. That renewal is the
// only thing keeping cold chunks off their deadlines, so a latch spent on a failed attempt costs exactly what
// this slice is about.
func TestFreeRenewalThrottleLatchesOnSuccessNotOnTheAttempt(t *testing.T) {
	g := newRentGateway(t)
	g.freeCode = http.StatusPaymentRequired // the free lease is refused
	base := newHTTPStore(t)
	const name, pass = "rentthrottle", "horse battery staple correct"
	createVault(base, name, pass)
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("x"), 4096), 0o600)
	pushProfile(base, name, pass, src)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	saveWallet(wpath, &Wallet{})
	freeRenewedThrough = map[string]int64{}

	if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil); err == nil {
		t.Fatal("the free lease was refused but payRent reported success")
	}
	if len(freeRenewedThrough) != 0 {
		t.Fatalf("a FAILED attempt latched the throttle (%v) -- this profile now gets no whole-footprint "+
			"renewal for the rest of the epoch, and nothing retries it", freeRenewedThrough)
	}
	// The next cycle must actually try again.
	g.freeCode = 200
	if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil); err != nil {
		t.Fatalf("the retry after a failed attempt: %v", err)
	}
	if len(freeRenewedThrough) != 1 {
		t.Errorf("a SUCCESSFUL renewal did not latch the throttle (%v) -- the footprint would be recomputed "+
			"on every 120s keep-alive", freeRenewedThrough)
	}
}

// TestFreeRenewalThrottleIsPerProfile: the latch was one process-wide int, and the login daemon is ONE
// process for the whole boot serving every profile in turn -- so the first profile to renew in an epoch
// throttled every other profile signed in that day out of its own renewal.
func TestFreeRenewalThrottleIsPerProfile(t *testing.T) {
	g := newRentGateway(t)
	base := newHTTPStore(t)
	const pass = "horse battery staple correct"
	freeRenewedThrough = map[string]int64{}
	for _, name := range []string{"tenant-a", "tenant-b"} {
		createVault(base, name, pass)
		src := t.TempDir()
		os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("y"), 4096), 0o600)
		pushProfile(base, name, pass, src)
		wpath := filepath.Join(t.TempDir(), "wallet.json")
		provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
		saveWallet(wpath, &Wallet{})
		if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if len(g.leased) != 2 {
		t.Fatalf("%d lease(s) for two profiles -- the second was throttled out of its renewal by the first, "+
			"and the daemon serves every profile on the device from one process", len(g.leased))
	}
}

// TestPayRentRecordsNoPaidTermWhenTheLeaseBoughtNothing: a 409 withdraws the purchase and re-leases with
// buy_gb=0. recordCoverage assigns PaidThrough from ANY 200, and payRent passes full=true, which also
// authorises writing the DELETION date -- so without the guard a customer whose purchase just failed is told
// it succeeded, with a date attached. capFlush has carried this guard since NWP-20260906-03; payRent never
// got it, and this slice is what makes payRent reachable on the profiles that matter most.
func TestPayRentRecordsNoPaidTermWhenTheLeaseBoughtNothing(t *testing.T) {
	g := newRentGateway(t)
	g.conflict = true
	base := newHTTPStore(t)
	const name, pass = "rent409", "horse battery staple correct"
	createVault(base, name, pass)
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("z"), 4096), 0o600)
	pushProfile(base, name, pass, src)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	// A wallet with credit: noCredit is false, so payRent takes the PAID path where the 409 lives.
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{}, {}}, PlanGB: 10, PlanPeriods: 3}); err != nil {
		t.Fatal(err)
	}
	freeRenewedThrough = map[string]int64{}

	if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil); err != nil {
		t.Fatalf("payRent: %v", err)
	}
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if w.PaidThrough > 42 {
		t.Errorf("PaidThrough advanced to %d after a lease that bought NOTHING -- the Storage screen now "+
			"paints a live term the gateway holds no grant for", w.PaidThrough)
	}
	if w.DeadlineEpoch != 0 {
		t.Errorf("a DELETION date (%d) was recorded from a lease that bought nothing", w.DeadlineEpoch)
	}
}

// TestTheRentPayerIsWiredToTheSessionSecret pins the WIRING, which is the whole of NWP-20260915-12 and the
// one thing no behavioural test above can show.
//
// Every other test here hands payRent a secret directly, so all of them would still pass with the wiring
// cut -- and cutting it is precisely what the defect was. syncLoop read the secret at one line and dropped
// it before calling maybePayRent twenty-four lines later; handleBackup did the same.
//
// WHY A SOURCE TEST. maybePayRent hardcodes the "s3" store and takes its gateway from the process
// environment, so exercising it behaviourally means standing up cap mode -- and in cap mode GATEWAY_URL must
// be the cap store, which is then also the rent gateway, so the assertion loses the thing it wanted to
// observe. The defect is an ABSENCE of an argument, which is expressible directly. Same reasoning, and the
// same idiom, as TestOfflineLoginDisposesInheritedSessionState.
func TestTheRentPayerIsWiredToTheSessionSecret(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "maybePayRent")), "\n")
	if !strings.Contains(body, "seFromSession(dest)") {
		t.Error("maybePayRent never reads the live session's secure-element secret. It is sitting on " +
			".roamsession line 4, put there by the login this same daemon served, and the daemon's own " +
			"environment can never carry NOWHERE_SE_SECRET -- the only exporter is nowhere_roamd.sh, in the " +
			"su:s0 worker.")
	}
	// NWP-20261010-04: maybePayRent calls payRentGen, which also takes the wallet generation.
	if !strings.Contains(body, "payRentGen(") || !strings.Contains(body, "wpath, seSecret, wgen)") {
		t.Error("maybePayRent calls payRent without handing it the secret it just read")
	}

	// ...and payRent must give it to BOTH openers. resolveDK alone is not enough: scopeFootprint opens the
	// vault independently and, failing, returns only the head refs -- so a half-wired payRent leases the
	// heads, re-stamps their deadlines as a successful renewal, and lets every chunk age out underneath.
	bb, err := os.ReadFile("billing.go")
	if err != nil {
		t.Fatal(err)
	}
	pay := strings.Join(stripComments(funcBody(t, string(bb), "payRentGenRule")), "\n") // payRent, payRentGen and payRentGenSignOut wrap it (NWP-20261010-04, NWP-20261112-14)
	// resolveDKVault is resolveDK that also returns the vault (NWP-20261009-02: payRent reads its !bill-retag
	// record from it); resolveDK delegates to it, so this is the same opener under its fuller name.
	for _, want := range []string{"resolveDKVault(base, name, pass, se)", "profileFootprint(base, name, pass, se)"} {
		if !strings.Contains(pay, want) {
			t.Errorf("payRent does not call %s. Both openers must see the secret; fixing only the first is "+
				"WORSE than fixing neither, because it converts a clean failure into a confident wrong "+
				"renewal.", want)
		}
	}
}

// TestTheSessionSecretSurvivesTheRoundTripToAFootprint closes the gap the source test above cannot: it
// checks the DECODER, not the call. A mutation that made seFromHex return nothing left every other test in
// this file green while rendering the entire fix inert -- the wiring would be present and carrying nothing.
//
// This drives the real chain minus maybePayRent's hardcoded "s3" store: marker -> seFromSession -> footprint.
func TestTheSessionSecretSurvivesTheRoundTripToAFootprint(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "rentchain", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	if err := markRoamSession(dest, name, pass, "10", hex.EncodeToString(se)); err != nil {
		t.Fatal(err)
	}

	got := seFromSession(dest)
	if len(got) == 0 {
		t.Fatal("seFromSession returned nothing for a marker that carries a secret -- the wiring would be " +
			"present and carrying nothing, which every other test in this file would still call green")
	}
	if !bytes.Equal(got, se) {
		t.Fatalf("seFromSession decoded %x, want %x", got, se)
	}
	heads := headHashes(base, name, pass)
	if n := chunkRefs(mustFootprint(t, base, name, pass, got), heads); n == 0 {
		t.Error("the secret read back off the marker does not open the footprint -- the decode round-trips " +
			"but the value is not the one the vault was hardened with")
	}

	// The refusals, which must all read as "this caller has none" rather than as an error.
	for _, tc := range []struct{ label, hex string }{
		{"no marker line", ""},
		{"not hex at all", "not a secret"},
		{"odd-length hex", "abc"},
	} {
		// ⚠ len(), not != nil: hex.DecodeString("") returns an EMPTY NON-NIL slice, and every consumer
		// tests len(se) > 0 -- so "no secret" is the property, and nil-ness is not it.
		if got := seFromHex(tc.hex); len(got) != 0 {
			t.Errorf("seFromHex(%s) returned %x, want no secret -- a malformed value must mean 'none', so "+
				"a Diaspore profile and a damaged marker take exactly the path they took before", tc.label, got)
		}
	}
}
