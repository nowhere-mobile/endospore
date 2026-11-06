package main

// DIA-20260809-02: the device must buy the TERM it paid for.
//
// nowhere-cloud #130/#131 shipped Periods and plan-grace on the gateway, but the agent never sent Periods,
// so every lease defaulted to one 30-day window and graceFor(1) always returned the SHORT grace. An annual
// buyer received a twelfth of the coverage they paid for and lost their data six weeks after going dark --
// the exact hole the one-time model exists to close. These tests fail if the field stops being sent.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// leaseSpy records the Periods each /lease carries and answers with a term proportional to it.
type leaseSpy struct {
	srv        *httptest.Server
	gotPeriods []int64
}

func newLeaseSpy(t *testing.T, epochsPerLease int64) *leaseSpy {
	t.Helper()
	s := &leaseSpy{}
	mux := http.NewServeMux()
	mux.HandleFunc("/quote", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"gb_per_token": 1, "current_epoch": 100, "free_gb": 0})
	})
	mux.HandleFunc("/lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		s.gotPeriods = append(s.gotPeriods, req.Periods)
		p := req.Periods
		if p == 0 {
			p = 1
		}
		through := 100 + p*epochsPerLease
		grace := int64(30)
		if p >= 12 {
			grace = 90
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: through, DeadlineEpoch: through + grace, WriteCaps: map[string]string{}})
	})
	s.srv = httptest.NewServer(mux)
	t.Cleanup(s.srv.Close)
	return s
}

func TestAnnualWalletAsksForTheWholeTerm(t *testing.T) {
	spy := newLeaseSpy(t, 30)
	wp := filepath.Join(t.TempDir(), "wallet.json")
	// 10 GB x 12 periods COSTS 120 signatures, and the device must present all of them to activate. The
	// fixture held 40, which was enough while price came from stored bytes and is not enough now: an
	// under-funded wallet declines to activate rather than buying a fraction of the term.
	if err := saveWallet(wp, &Wallet{PlanPeriods: 12, PlanGB: 10, BlindTokens: make([]BlindToken, 120)}); err != nil {
		t.Fatal(err)
	}
	g := newGatewayClient(spy.srv.URL, gwDefault)

	info, _, err := leaseRefs(g, wp, "profA", map[string]int64{"blob/x": 1}, nil)
	if err != nil {
		t.Fatalf("leaseRefs: %v", err)
	}
	if len(spy.gotPeriods) == 0 || spy.gotPeriods[0] != 12 {
		t.Fatalf("/lease carried periods=%v, want 12 first -- the device is not buying its term", spy.gotPeriods)
	}
	if got, want := info.ThroughEpoch, int64(100+12*30); got != want {
		t.Errorf("coverage runs to %d, want %d (360 days, not 30)", got, want)
	}
	if got, want := info.DeadlineEpoch-info.ThroughEpoch, int64(90); got != want {
		t.Errorf("grace = %d epochs, want %d -- an annual buyer earned the long band", got, want)
	}
}

// A wallet with no known plan -- a dev-faucet wallet, or a claim that carried no plan metadata -- must
// still be able to buy coverage, and must claim only the SHORTEST term. Credit that can never activate
// means a failed seal, and on this device a failed seal is lost data.
//
// This asserted `periods = 0` (absent) while the gateway inferred the purchase from stored bytes. It now
// declares a single period explicitly, which is the same coverage and the same thing an older gateway
// does with an absent field. The guarantee that matters is unchanged and still checked: never claim a
// term longer than one period on a plan nobody recorded.
func TestUnknownPlanBuysASinglePeriod(t *testing.T) {
	spy := newLeaseSpy(t, 30)
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, &Wallet{BlindTokens: make([]BlindToken, 40)}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := leaseRefs(newGatewayClient(spy.srv.URL, gwDefault), wp, "profB", map[string]int64{"blob/y": 1}, nil); err != nil {
		t.Fatalf("leaseRefs: %v", err)
	}
	if len(spy.gotPeriods) != 1 || spy.gotPeriods[0] > 1 {
		t.Errorf("periods sent = %v, want a single term (0 or 1) -- never a term nobody bought", spy.gotPeriods)
	}
}

// GET-BILLING carries the new fields only when they are KNOWN. An absent deadline must stay absent: the
// chooser has to print nothing rather than a date nobody computed.
func TestBillingLineOmitsUnknownPlanFields(t *testing.T) {
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, &Wallet{Tokens: []Token{{}}, PaidThrough: 2951}); err != nil {
		t.Fatal(err)
	}
	got := billingLine(wp)
	for _, absent := range []string{"deadline=", "periods=", "plangb="} {
		if strings.Contains(got, absent) {
			t.Errorf("unknown field %q was emitted anyway: %q", absent, got)
		}
	}

	if err := saveWallet(wp, &Wallet{Tokens: []Token{{}}, PaidThrough: 2951, DeadlineEpoch: 3041, PlanPeriods: 12, PlanGB: 10}); err != nil {
		t.Fatal(err)
	}
	got = billingLine(wp)
	for _, want := range []string{"deadline=3041", "periods=12", "plangb=10"} {
		if !strings.Contains(got, want) {
			t.Errorf("billing line missing %q: %q", want, got)
		}
	}
}

// NWP-20261031-07 (decided 2026-10-20, docs/product-decisions.md "a bigger plan starts at once ..."): THE MAX IS GONE.
// recordPlan used to refuse to downgrade a live term, and a 10 GB top-up under a live 50 GB plan was then priced at
// 50 GB and could never be spent. With nothing waiting, a later purchase REPLACES the plan -- term included.
func TestRecordPlanNeverDowngradesTheTerm(t *testing.T) {
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := os.WriteFile(wp, []byte(`{"tokens":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := recordPlan(wp, 12, 10, false); err != nil {
		t.Fatal(err)
	}
	if err := recordPlan(wp, 3, 10, false); err != nil {
		t.Fatal(err)
	}
	w, err := loadWallet(wp)
	if err != nil {
		t.Fatal(err)
	}
	if w.PlanPeriods != 3 || w.PlanGB != 10 || len(w.PlanQueue) != 0 {
		t.Errorf("plan = %d GB x %d queue %v after a later 3-period purchase with nothing waiting, want 10 x 3 and no queue",
			w.PlanGB, w.PlanPeriods, w.PlanQueue)
	}
}
