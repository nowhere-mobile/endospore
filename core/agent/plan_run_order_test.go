package main

// NWP-20261120-10 (h48 #9): the gateway sends the account's plans in run order (nowhere-cloud NWC-20261118-01) and
// Storage shows them, "50 GB to Jan 21, then 10 GB to Jul 20". The agent learns the list into the display-only
// Wallet.AccountPlans and GET-BILLING ships the live steps as plans=. Device-seen on lynx 2026-10-24: after a 50 GB
// code redeemed with keep over a live 10 GB plan, Storage showed no line for the 10 GB term after the 50 GB one.

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var planRunOrderTwo = []leasePlanStep{{GB: 50, ThroughEpoch: 21109}, {GB: 10, ThroughEpoch: 21199}}

func planRunOrderClock(t *testing.T, epoch int64) {
	t.Helper()
	old := nowEpoch
	nowEpoch = func() int64 { return epoch }
	t.Cleanup(func() { nowEpoch = old })
}

func planRunOrderLine(t *testing.T, w *Wallet) string {
	t.Helper()
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, w); err != nil {
		t.Fatal(err)
	}
	return billingLine(wp)
}

func TestPlanRunOrderLearned(t *testing.T) {
	var info leaseInfo
	reply := `{"through_epoch":1,"spent":0,"write_caps":{},"plan_gb":50,` +
		`"plans":[{"gb":50,"through_epoch":21109},{"gb":10,"through_epoch":21199}]}`
	if err := json.Unmarshal([]byte(reply), &info); err != nil {
		t.Fatal(err)
	}
	var w Wallet
	learnPlanSize(&w, info)
	if w.AccountPlanGB != 50 {
		t.Fatalf("AccountPlanGB = %d, want 50", w.AccountPlanGB)
	}
	if !reflect.DeepEqual(w.AccountPlans, planRunOrderTwo) {
		t.Fatalf("AccountPlans = %+v, want %+v in run order", w.AccountPlans, planRunOrderTwo)
	}
	// The wallet must not alias the reply: a later change to the reply's slice is not a change to the wallet.
	info.Plans[0].GB = 1
	if w.AccountPlans[0].GB != 50 {
		t.Fatalf("AccountPlans aliases the lease reply: %+v", w.AccountPlans)
	}
}

func TestPlanRunOrderAbsentKeeps(t *testing.T) {
	var info leaseInfo
	if err := json.Unmarshal([]byte(`{"through_epoch":1,"spent":0,"write_caps":{},"plan_gb":50}`), &info); err != nil {
		t.Fatal(err)
	}
	w := Wallet{AccountPlans: append([]leasePlanStep(nil), planRunOrderTwo...)}
	learnPlanSize(&w, info)
	if !reflect.DeepEqual(w.AccountPlans, planRunOrderTwo) {
		t.Fatalf("a reply without plans changed the stored list to %+v; absent is no news", w.AccountPlans)
	}
}

func TestPlanRunOrderInvalidKeeps(t *testing.T) {
	for _, bad := range [][]leasePlanStep{
		{{GB: 50, ThroughEpoch: 21109}, {GB: 0, ThroughEpoch: 21199}},
		{{GB: 50, ThroughEpoch: 0}, {GB: 10, ThroughEpoch: 21199}},
		{},
	} {
		w := Wallet{AccountPlans: append([]leasePlanStep(nil), planRunOrderTwo...)}
		learnPlanSize(&w, leaseInfo{PlanGB: 50, Plans: bad})
		if !reflect.DeepEqual(w.AccountPlans, planRunOrderTwo) {
			t.Fatalf("an invalid list %+v replaced the stored one: %+v", bad, w.AccountPlans)
		}
	}
}

func TestPlanRunOrderOneStepReplaces(t *testing.T) {
	w := Wallet{AccountPlans: append([]leasePlanStep(nil), planRunOrderTwo...)}
	one := []leasePlanStep{{GB: 10, ThroughEpoch: 21199}}
	learnPlanSize(&w, leaseInfo{PlanGB: 10, Plans: one})
	if !reflect.DeepEqual(w.AccountPlans, one) {
		t.Fatalf("a valid one-step list did not replace the stored two-step list: %+v", w.AccountPlans)
	}
}

func TestPlanRunOrderBillingLine(t *testing.T) {
	planRunOrderClock(t, 20750)
	base := func() *Wallet { return &Wallet{PaidThrough: 21199, AccountPlanGB: 50} }

	// Two live steps: plans= comes right after plangb= and no other token changes. credit=750 is the unchanged
	// displayCredit: 50 GB x ceil((21199 - 20750) / 30) periods.
	w := base()
	w.AccountPlans = append([]leasePlanStep(nil), planRunOrderTwo...)
	want := "OK credit=750 through=21199 epochsec=86400 sub=0 plangb=50 plans=50:21109,10:21199\n"
	if got := planRunOrderLine(t, w); got != want {
		t.Fatalf("two live steps: line %q, want %q", got, want)
	}
	if prefix := fmt.Sprintf("OK credit=%d ", displayCredit(base(), 20750)); !strings.HasPrefix(want, prefix) {
		t.Fatalf("the pinned line does not start with displayCredit's %q", prefix)
	}

	// One step: nothing to put in order.
	w = base()
	w.AccountPlans = []leasePlanStep{{GB: 50, ThroughEpoch: 21199}}
	if got := planRunOrderLine(t, w); strings.Contains(got, "plans=") {
		t.Fatalf("one step: line %q carries plans=", got)
	}

	// An ended step is dropped; the two live ones stay in order.
	w = base()
	w.AccountPlans = []leasePlanStep{{GB: 20, ThroughEpoch: 20700}, {GB: 50, ThroughEpoch: 21109}, {GB: 10, ThroughEpoch: 21199}}
	if got := planRunOrderLine(t, w); !strings.Contains(got, " plans=50:21109,10:21199\n") {
		t.Fatalf("an ended step: line %q, want plans=50:21109,10:21199 exactly", got)
	}

	// An ended step that leaves one live step: nothing.
	w = base()
	w.AccountPlans = []leasePlanStep{{GB: 50, ThroughEpoch: 20700}, {GB: 10, ThroughEpoch: 21199}}
	if got := planRunOrderLine(t, w); strings.Contains(got, "plans=") {
		t.Fatalf("one live step left: line %q carries plans=", got)
	}

	// A waiting purchase is a fact the gateway does not have yet: no plans=.
	w = base()
	w.AccountPlans = append([]leasePlanStep(nil), planRunOrderTwo...)
	w.PlanGB, w.PlanPeriods = 10, 3
	for i := 0; i < 30; i++ {
		w.Tokens = append(w.Tokens, Token{Nonce: fmt.Sprintf("plan-run-order-%02d", i)})
	}
	got := planRunOrderLine(t, w)
	if !strings.Contains(got, " pending=1") {
		t.Fatalf("pending: line %q lost pending=1; the case does not test what it says", got)
	}
	if strings.Contains(got, "plans=") {
		t.Fatalf("pending: line %q carries plans=", got)
	}

	// No list: the line is the earlier shape, byte for byte.
	want = "OK credit=750 through=21199 epochsec=86400 sub=0 plangb=50\n"
	if got := planRunOrderLine(t, base()); got != want {
		t.Fatalf("no list: line %q, want %q", got, want)
	}
}

func TestPlanRunOrderRestoreKeepsLocal(t *testing.T) {
	stored := &Wallet{AccountPlans: []leasePlanStep{{GB: 10, ThroughEpoch: 21000}, {GB: 5, ThroughEpoch: 21100}}}
	local := &Wallet{AccountPlans: append([]leasePlanStep(nil), planRunOrderTwo...)}
	if out := mergeLateRestore(stored, local); !reflect.DeepEqual(out.AccountPlans, planRunOrderTwo) {
		t.Fatalf("the merge did not keep the session's list: %+v", out.AccountPlans)
	}
	if out := mergeLateRestore(stored, &Wallet{}); !reflect.DeepEqual(out.AccountPlans, stored.AccountPlans) {
		t.Fatalf("an empty session list dropped the stored one: %+v", out.AccountPlans)
	}
}
