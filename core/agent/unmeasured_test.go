package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTheBreakdownServesTheLocalWalkRatherThanAWrongTotal.
//
// ⚠ NOT StoreMeasured, WHICH IS A DIFFERENT QUESTION -- I nearly conflated them. Its documented
// meaning is that a sealed head carries a Pkg INDEX (attribution), and withStoreBytes' own early
// return already kept it honest on a hardened vault. What was wrong is StoreTotal: the footprint
// could only see head refs, so the number the user is PAYING came out as a few kilobytes. The fix
// takes the exit the function already has, so the screen shows no store numbers rather than wrong
// ones -- a shape the UI already renders.
func TestTheBreakdownServesTheLocalWalkRatherThanAWrongTotal(t *testing.T) {
	b, err := os.ReadFile("storage_breakdown.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "withStoreBytes")), "\n")
	if !strings.Contains(body, "fp, fpMeasured := footprintOf") {
		t.Error("withStoreBytes does not ask whether the footprint was measured")
	}
	i := strings.Index(body, "fpMeasured")
	j := strings.Index(body, "b.StoreTotal +=")
	if i < 0 || j < 0 || i > j {
		t.Error("the measured check must come BEFORE StoreTotal is summed -- otherwise the screen still " +
			"renders a total built from head refs alone")
	}
	// The NEGATION, for the same reason as above: `if fpMeasured && false` keeps every substring this
	// test looked for and disables the branch entirely.
	if !strings.Contains(body, "if !fpMeasured {") {
		t.Error("the guard is not a negation -- the branch must be taken when the footprint was NOT " +
			"measured")
	}
	if !strings.Contains(body[i:j], "return workerJSON, nil") {
		t.Error("an unmeasured footprint must serve the pure local walk, the same exit this function " +
			"already takes when it cannot attribute")
	}
}

// TestScopeManifestOpensAHardenedScope: scopeFootprint's twin, blind in the same way and for the same
// reason. It is what turns a sealed chunk set into per-package rows, so without it the Storage screen can
// show a total but cannot say where the total went.
func TestScopeManifestOpensAHardenedScope(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "scopeman", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)

	if _, ok := scopeManifest(base, name, pass, nil); ok {
		t.Error("scopeManifest opened a hardened vault with no secret -- then this test proves nothing")
	}
	if _, ok := scopeManifest(base, name, pass, se); !ok {
		t.Error("scopeManifest could not open a hardened vault WITH its secret")
	}
}

// TestPayRentRefusesAnUnmeasuredFootprint pins the belt-and-braces arm, which is not redundant with the
// resolveDK gate above it: that gate opens the BARE vault, while scopeFootprint opens each scope again on
// its own. A renewal that leased the heads alone would re-stamp their deadlines as a success while every
// chunk aged out -- the NWP-20260915-12 shape, arrived at through a scope rather than through the profile.
func TestPayRentRefusesAnUnmeasuredFootprint(t *testing.T) {
	g := newRentGateway(t)
	base := newHTTPStore(t)
	const name, pass = "unmeasrent", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	saveWallet(wpath, &Wallet{})
	freeRenewedThrough = map[string]int64{}

	// Sanity: WITH the secret it renews, so the refusal below is about measurement and nothing else.
	if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, se); err != nil {
		t.Fatalf("payRent with the secret: %v", err)
	}
	leasedWithSecret := len(g.leased)

	freeRenewedThrough = map[string]int64{}
	_, paid, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil)
	if err == nil {
		t.Fatal("payRent renewed a footprint it could not measure")
	}
	if paid {
		t.Error("payRent reported rent paid on an unmeasured footprint")
	}
	if len(g.leased) != leasedWithSecret {
		t.Errorf("it presented %d extra lease(s) -- leasing the heads alone re-stamps their deadlines as a "+
			"successful renewal while every chunk ages out", len(g.leased)-leasedWithSecret)
	}
}

// TestInstallHeadroomFailsOpenRatherThanUndercounting: the headroom check decides whether an app store
// install is allowed to proceed. A heads-only footprint made `used` a few kilobytes, so the check passed for
// an install that does not fit and the user met the refusal later, at a seal, with no explanation. Failing
// OPEN is the existing behaviour for "cannot project" and is the right answer here too -- the lease decides.
func TestInstallHeadroomFailsOpenRatherThanUndercounting(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 20, EntitledBytes: 1 << 20, CurrentEpoch: 42})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	base := newHTTPStore(t)
	const name, pass = "headroom", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	saveWallet(wpath, &Wallet{})
	g := newGatewayClient(srv.URL, gwDefault)

	fits, _, used, _ := installHeadroom(g, base, name, pass, wpath, 8<<30, nil)
	if !fits {
		t.Error("an unmeasurable profile must fail OPEN and let the lease decide")
	}
	if used != 0 {
		t.Errorf("it reported %d bytes used from a footprint it could not see -- that is the confidently "+
			"wrong small number, and here it decides whether an install proceeds", used)
	}
	// With the secret it measures for real, and a tiny entitlement against an 8 GiB add must NOT fit.
	if fits, _, used, _ := installHeadroom(g, base, name, pass, wpath, 8<<30, se); fits || used == 0 {
		t.Errorf("with the secret: fits=%v used=%d -- want a real measurement and a refusal", fits, used)
	}
}

// TestEntitlementLineOmitsTheLineRatherThanUnderstatingIt: the app store's headroom header. The UI omits the
// line rather than rendering a number we cannot stand behind -- honest, where a small one reads as plenty of
// room.
//
// ⚠ THE REPLY IS "UNKNOWN", NOT "NONE", SINCE NWP-20260918-02. This assertion read `== "NONE\n"` before, and
// that shared token is precisely the defect: the chooser turned any non-OK reply into "On the free tier --
// at no cost", so a profile it merely could not MEASURE was reported as having no plan. "NONE" now means only
// what handleGetEntitlement emits for an unmanaged device; every could-not-determine arm says UNKNOWN.
func TestEntitlementLineOmitsTheLineRatherThanUnderstatingIt(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 30, EntitledBytes: 1 << 30, CurrentEpoch: 42})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	base := newHTTPStore(t)
	const name, pass = "entline", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	saveWallet(wpath, &Wallet{})
	g := newGatewayClient(srv.URL, gwDefault)

	if got := entitlementLine(g, base, name, pass, wpath, nil); got != "UNKNOWN\n" {
		t.Errorf("an unmeasurable profile produced %q, want UNKNOWN -- the header would otherwise understate "+
			"what is used and tell the user they have room they do not have", strings.TrimSpace(got))
	}
	if got := entitlementLine(g, base, name, pass, wpath, se); !strings.HasPrefix(got, "OK ") {
		t.Errorf("with the secret the line is still not a real answer: %q", strings.TrimSpace(got))
	}

	// ⚠ AND IT MUST NOT SAY "NONE" EITHER, which is the whole point of the slice. NONE is reserved for an
	// UNMANAGED device; a measurable profile behind a silent gateway is a different state and the chooser
	// renders it differently. Asserting only "!= OK" would pass against the old code and prove nothing.
	if got := entitlementLine(g, base, name, pass, wpath, nil); strings.HasPrefix(got, "NONE") {
		t.Error("an unmeasurable profile still answers NONE -- the chooser reads that as \"no plan\" and " +
			"tells a paying customer they are on the free tier at no cost")
	}
}

// TestAnUnreachableGatewayIsUnknownRatherThanNoPlan (NWP-20260918-02) covers the arm that actually bit a
// customer: the gateway is CONFIGURED and simply does not answer. Observed on lynx 2026091702, where the
// Storage screen read "On the free tier ... at no cost" for a profile whose POST /entitlement returns
// entitled_bytes 53687091200.
//
// The distinction is not cosmetic. "NONE" is a claim about the customer's account; "UNKNOWN" is a claim about
// our own reachability. Only one of them is ours to make when the network is down.
func TestAnUnreachableGatewayIsUnknownRatherThanNoPlan(t *testing.T) {
	// A server that accepts the connection and then fails the request -- a silent/erroring gateway, which is
	// the realistic shape. A closed port would also work but exercises the dial rather than the reply.
	mux := http.NewServeMux()
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "usage unavailable", http.StatusServiceUnavailable)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	base := newHTTPStore(t)
	const name, pass = "gwdown", "horse battery staple correct"
	createVault(base, name, pass)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	saveWallet(wpath, &Wallet{})

	got := entitlementLine(newGatewayClient(srv.URL, gwDefault), base, name, pass, wpath, nil)
	if got != "UNKNOWN\n" {
		t.Errorf("a gateway that did not answer produced %q, want UNKNOWN. NONE is a statement about the "+
			"CUSTOMER'S ACCOUNT and this is a statement about OUR REACHABILITY -- the chooser turns the "+
			"former into \"On the free tier, at no cost\", which is what told a 50 GiB customer they had "+
			"no plan", strings.TrimSpace(got))
	}
}

// TestRollbackStopsAccusingACorrectPassphrase: rollbackHead answered "wrong passphrase" whenever no keyslot
// opened -- and on a hardened vault that fired for a CORRECT one. The caller has already resolved the head
// with (name, pass) by the time we get here, so the passphrase is known good; blaming it is the
// credential-accusation class NWP-20260915-10 fixed for rotate.
func TestRollbackStopsAccusingACorrectPassphrase(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "rollacc", "horse battery staple correct"
	hardenedWithData(t, base, name, pass)

	_, err := rollbackHead(base, name, pass, 0, nil)
	if err == nil {
		t.Fatal("rollbackHead succeeded with no way to open the vault")
	}
	if strings.Contains(strings.ToLower(err.Error()), "wrong passphrase") {
		t.Errorf("rollbackHead answered %q for a CORRECT passphrase -- the head resolved with it three lines "+
			"earlier", err)
	}
}

// TestTheDisplayVerbsAreWiredAndRefuseRatherThanUnderstate pins, by source, what display_verbs_exec_test.go
// cannot run: GET-ENTITLEMENT's session hand-off (it needs a gateway), the breakdown handler's (it needs the
// roam worker), and that GET-USAGE, GET-FOOTPRINT and the breakdown merge read the store through the
// footprintOf / storePkgBytesOf seams the executing tests replace. The refusal and success arms themselves
// are executed there, not searched for here.
func TestTheDisplayVerbsAreWiredAndRefuseRatherThanUnderstate(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	mainGo, fpList, breakdown, count := read("main.go"), read("footprint_list.go"), read("storage_breakdown.go"), read("storage_count.go")

	// MOVED TO display_verbs_exec_test.go, which RUNS them (NWP-20261015-35): the `seFromSession(dest)`,
	// `UNMEASURED`, `ERR-UNMEASURED` and `if !measured {` rows of GET-USAGE and GET-FOOTPRINT, and the
	// breakdown's `seFromSession(dest)` hand-off, are now asserted on the handlers' replies and on the secret
	// the footprint stub receives. What stays here is what a run cannot see: GET-ENTITLEMENT (it needs a
	// gateway), the breakdown count's own `seFromSession(dest)` (it needs the roam worker), and that every
	// call still goes through the seam rather than straight to the store.
	for _, tc := range []struct{ what, src, fn, want string }{
		{"GET-USAGE", mainGo, "handleGetUsage", "footprintOf(\"s3\", name, pass, seFromSession(dest))"},
		{"GET-ENTITLEMENT", mainGo, "handleGetEntitlement", "seFromSession(dest)"},
		{"GET-FOOTPRINT", fpList, "handleGetFootprint", "footprintOf(\"s3\", name, pass, seFromSession(dest))"},
		{"GET-STORAGE-BREAKDOWN", count, "storageCountRunDefault", "seFromSession(dest)"}, // NWP-20261118-06: the count's default hook holds the call
		{"the breakdown merge", breakdown, "withStoreBytes", "footprintOf(\"s3\", name, pass, se)"},
		{"the breakdown merge", breakdown, "withStoreBytes", "storePkgBytesOf(\"s3\", name, pass, se)"},
	} {
		body := strings.Join(stripComments(funcBody(t, tc.src, tc.fn)), "\n")
		if !strings.Contains(body, tc.want) {
			t.Errorf("%s (%s) does not contain %q.\n"+
				"  Every one of these renders a NUMBER a user acts on, and a footprint it cannot open returns\n"+
				"  head refs only -- a few KB across six scopes for a multi-GB profile. Either it sees the\n"+
				"  profile, or it says it could not.", tc.what, tc.fn, tc.want)
		}
	}

	// ⚠ LIST-UNITS and the GATE rollback are deliberately NOT in that list, and this pins the reason so the
	// omission reads as a decision rather than a gap: both run at the gate from a typed name+pass with no
	// .roamsession to read, so the only way to supply a secret is a new wire field -- and the chooser never
	// closes its write side, so a daemon blocking on a line an older build never sends would wedge while
	// holding sessionMu.
	for _, fn := range []string{"handleRollbackGate"} {
		body := strings.Join(stripComments(funcBody(t, mainGo, fn)), "\n")
		if strings.Contains(body, "seFromSession") {
			t.Errorf("%s now reads a session secret -- it runs at the GATE, where there is no session. If this "+
				"is deliberate, the wire change and its wedge risk need reviewing, not just this test.", fn)
		}
	}
}

// TestAFootprintWithNothingSealedIsMeasured: the flag must mean "I could not see", never "there was
// nothing to see". Reporting an ordinary un-sealed profile as unmeasured would make every display
// refuse for the most common state there is -- a profile between create and its first seal.
func TestAFootprintWithNothingSealedIsMeasured(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "emptyprof", "horse battery staple correct"
	createVault(base, name, pass)

	refs, measured := profileFootprint(base, name, pass, nil)
	if !measured {
		t.Fatal("a profile that has sealed nothing reported itself UNMEASURED -- the flag means \"I could " +
			"not see\", not \"there was nothing to see\", and every display would refuse on a fresh profile")
	}
	// Its bare vault head exists and is leased; what it has no manifest for is data.
	if len(refs) == 0 {
		t.Error("a created profile leased nothing at all -- its own head must stay alive")
	}
}

// TestAnOpenedScopeWithNothingSealedIsNotBlindness pins the arm that separates "I opened it and there is
// nothing under it" from "I could not open it". They were one condition before NWP-20260915-15 and both
// returned silently, which is how a heads-only footprint came to look like a small profile.
//
// The vault is hand-built because production cannot currently produce it -- createVault always posts a
// manifest blob, so v.Manifest is never empty for a created profile. That is exactly why the arm needs a
// test: it is the net under a shape no current path reaches, and a net nothing can fall into is untested
// rather than unnecessary.
func TestAnOpenedScopeWithNothingSealedIsNotBlindness(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "nomanifest", "horse battery staple correct"
	createVault(base, name, pass)

	// Republish the head with its manifest cleared: openable, and with nothing sealed under it.
	head := getRef(base, headKey(base, name, pass))
	v, _ := parseVault(getHeadBlob(base, head))
	dk := unwrapDK(v, "pass", deriveKey(name, pass))
	if dk == nil {
		t.Fatal("pass slot won't unwrap")
	}
	v.Manifest = ""
	v.Version++
	signVault(v, dk)
	putHeadSingle(base, name, pass, postBlob(base, serializeVault(v)))

	if _, measured := profileFootprint(base, name, pass, nil); !measured {
		t.Error("a scope that OPENED but has nothing sealed under it was reported as a measurement failure -- " +
			"every display would then refuse for a profile that is simply empty, which is the ordinary state " +
			"between create and the first seal")
	}
}

// TestPayRentRefusesWhenOnlyASCOPEIsUnopenable is the arm the earlier test could not reach.
//
// TestPayRentRefusesAnUnmeasuredFootprint passes even with the measured check disabled, because resolveDK
// gates on the BARE vault and fires first -- a mutation proved exactly that by surviving. The measured check
// exists for the case resolveDK cannot see: the bare vault opens, and a SCOPE head is a vault that does not.
// scopeFootprint would then add the scope's head refs and return, and payRent would lease the heads and
// re-stamp their deadlines as a successful renewal while that scope's chunks aged out.
//
// The shape is hand-built because no current path produces it -- a re-pointed scope head carries a `pass`
// slot, so it opens by passphrase. That is why the arm is a net, and why a net needs a test.
func TestPayRentRefusesWhenOnlyASCOPEIsUnopenable(t *testing.T) {
	g := newRentGateway(t)
	base := newHTTPStore(t)
	const name, pass = "scopeblind", "horse battery staple correct"
	createVault(base, name, pass)
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("m"), 4096), 0o600)
	pushProfile(base, name+"#media", pass, src)

	// Replace the #media head with a vault only a secure element could open -- and never supply that secret.
	scope := name + "#media"
	mh := getRef(base, headKey(base, scope, pass))
	if mh == "" {
		t.Fatal("no #media head to replace")
	}
	sv, isV := parseVault(getHeadBlob(base, mh))
	if !isV {
		// A bare scope head: wrap it in a vault whose only slot is `se`, which is the state being modelled.
		sk := deriveKey(scope, pass)
		sv = &vault{V: 1, Manifest: mh,
			Slots: []keyslot{{Kind: "se", Wrapped: wrap(kekSE(scope, pass, []byte("some-handset")), sk)}}}
		signVault(sv, sk)
	}
	putHeadSingle(base, scope, pass, postBlob(base, serializeVault(sv)))

	wpath := filepath.Join(t.TempDir(), "wallet.json")
	saveWallet(wpath, &Wallet{})
	freeRenewedThrough = map[string]int64{}

	// The BARE vault still opens by passphrase, so resolveDK succeeds and the refusal can only come from the
	// measured flag -- which is the whole point of this test.
	if dk := resolveDK(base, name, pass, nil); dk == nil {
		t.Fatal("precondition: the bare vault must still open, or resolveDK gates first and this proves nothing")
	}
	if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil); err == nil {
		t.Error("payRent renewed a profile whose #media scope it could not open -- it leased the heads and " +
			"re-stamped their deadlines as a success while that scope's chunks aged out")
	}
	if len(g.leased) != 0 {
		t.Errorf("it presented %d lease(s) for a footprint it could not measure", len(g.leased))
	}
}

// TestTheCLIVerbsRefuseAnUnmeasuredFootprint (NWP-20260918-01) closes the half of NWP-20260915-15 that was
// never wired: the two CLI verbs in main()'s switch discarded the flag with `refs, _ :=` while every daemon
// and billing caller honoured it.
//
// ⚠ THE CLI IS THE HALF THAT REACHES A HARDENED PROFILE UNARMED. Both verbs pass se=nil, so on Endospore --
// where the chooser hardens every new profile at create and enrollSE drops the pass slots -- the BARE vault
// opens by no keyslot at all. handleGetFootprint passes seFromSession(dest) and never had this exposure,
// which is precisely why the guard got written on that side only. TestTheDisplayVerbsAreWiredAndRefuseRather
// ThanUnderstate polices the four daemon verbs and did not police these, so the omission survived the test
// that exists to prevent it.
//
// Source-level for the same reason that test gives: the arms call os.Exit, and the defect is the absence of
// a branch rather than a behaviour reachable from a harness.
func TestTheCLIVerbsRefuseAnUnmeasuredFootprint(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)

	// Slice one `case "<verb>":` out of main()'s switch: from the case label to the next case label at the
	// same indent. Anchored on the literal tab depth so a `case` inside a nested switch cannot end it early.
	caseBody := func(verb string) string {
		start := strings.Index(src, "\n\tcase \""+verb+"\":")
		if start < 0 {
			t.Fatalf("no `case %q:` in main.go -- the verb was renamed and this test is now vacuous", verb)
		}
		rest := src[start+1:]
		if end := strings.Index(rest[1:], "\n\tcase \""); end >= 0 {
			return rest[:end+1]
		}
		return rest
	}

	for _, tc := range []struct{ verb, why string }{
		{"footprint", "its output IS a copy recipe -- a short list silently loses every object of the scope " +
			"it could not open, and sha256(bytes)==key verifies what IS there while saying nothing about " +
			"what is missing"},
		{"lease", "it calls leaseRefs directly rather than through payRent, so it bypasses that guard and " +
			"would lease the HEADS alone -- re-stamping their deadlines as a success while every chunk " +
			"under the unopenable scope ages out"},
	} {
		body := strings.Join(stripComments(strings.Split(caseBody(tc.verb), "\n")), "\n")
		// ⚠ THE CONDITION, NOT JUST THE NAME -- same lesson the daemon-verb table records above. Binding
		// the flag and never testing it would satisfy a `contains("measured")` check and change nothing.
		if !strings.Contains(body, "!measured") {
			t.Errorf("the %q verb does not test the measured flag. It must: %s", tc.verb, tc.why)
		}
		if strings.Contains(body, ", _ := profileFootprint(") {
			t.Errorf("the %q verb DISCARDS profileFootprint's measured flag (`, _ :=`). %s",
				tc.verb, tc.why)
		}
	}
}
