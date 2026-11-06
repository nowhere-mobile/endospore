package main

// NWP-20260907-03: the plan size the Storage screen shows must be the ACCOUNT's, not this handset's.
//
// Chester bought 50 GB on frankel while lynx was signed into the same profile. frankel showed "50 GB plan",
// lynx showed "10 GB", and after lynx sealed last BOTH showed 10 GB -- the #wallet ref is shared and
// last-writer-wins under MULTIDEVICE=0, so an older copy of the whole wallet replaced the newer one.
//
// The learned value goes into a SEPARATE field on purpose. PlanGB prices a purchase waiting to activate
// (planPurchase demands PlanGB*PlanPeriods signatures), so healing it directly would strand money that has
// already been paid. TestLearningNeverDisturbsThePriceOfAPendingPurchase is the test that pins that, and it
// is the reason this slice has two fields instead of one.

import (
	"strings"
	"testing"
)

func TestAStaleHandsetLearnsTheAccountPlanSize(t *testing.T) {
	// lynx: signed in before the purchase, so its wallet remembers the old plan and holds no credit.
	w := &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20876}
	learnPlanSize(w, leaseInfo{PlanGB: 50})
	if got := planSizeForDisplay(w); got != 50 {
		t.Fatalf("Storage screen would show %d GB, want 50 -- this is the frankel/lynx split, unhealed", got)
	}
}

// THE TEST THIS SLICE EXISTS AROUND. An earlier draft healed PlanGB itself; it would have made a paid
// top-up permanently unspendable, silently, behind a screen that looked right.
func TestLearningNeverDisturbsThePriceOfAPendingPurchase(t *testing.T) {
	// A 10 GB / 3-month top-up bought while a 50 GB grant is still live: 30 signatures, priced at 10x3.
	w := &Wallet{PlanGB: 10, PlanPeriods: 3, Tokens: make([]Token, 30)}
	if !w.planPending() {
		t.Fatal("setup is wrong: the purchase must be funded and unactivated")
	}
	learnPlanSize(w, leaseInfo{PlanGB: 50}) // the account holds 50; this handset is buying 10

	if w.PlanGB != 10 {
		t.Fatalf("PlanGB moved to %d: planPurchase now wants %d signatures for a purchase funded with 30, "+
			"so choosePayment can never meet it and the money is stranded", w.PlanGB, w.PlanGB*int(w.PlanPeriods))
	}
	gb, periods, plain, blind := w.planPurchase(20700, false)
	if gb != 10 || periods != 3 {
		t.Fatalf("planPurchase declared buy_gb=%d periods=%d, want 10x3 -- the customer bought 10 GB", gb, periods)
	}
	if len(plain)+len(blind) != 30 {
		t.Fatalf("presented %d signatures, want 30", len(plain)+len(blind))
	}
}

// ...and while that purchase is pending, the screen shows what was just bought rather than the account's
// older size. Activation waits out up to two days of privacy jitter, and "you have 10 GB" is the wrong
// thing to tell someone who paid for 50 a minute ago.
func TestAPendingPurchaseIsWhatTheScreenShows(t *testing.T) {
	w := &Wallet{PlanGB: 50, PlanPeriods: 3, Tokens: make([]Token, 150), AccountPlanGB: 10}
	if got := planSizeForDisplay(w); got != 50 {
		t.Fatalf("showed %d GB while a 50 GB purchase is funded and waiting, want 50", got)
	}
	// Once it activates the signatures are gone, and the account's answer takes over on the next lease.
	w.Tokens = nil
	w.AccountPlanGB = 50
	if got := planSizeForDisplay(w); got != 50 {
		t.Fatalf("showed %d GB after activation, want 50", got)
	}
}

func TestAZeroPlanSizeIsNeverWritten(t *testing.T) {
	for _, tc := range []struct {
		name string
		info leaseInfo
	}{
		{"a lapsed profile in grace", leaseInfo{ThroughEpoch: 20704, PlanGB: 0}},
		{"a free-tier profile", leaseInfo{ThroughEpoch: 20794}},
		{"a gateway too old to send the field", leaseInfo{ThroughEpoch: 20794}},
	} {
		w := &Wallet{PlanGB: 50, AccountPlanGB: 50}
		learnPlanSize(w, tc.info)
		if w.AccountPlanGB != 50 {
			t.Errorf("%s: blanked the size to %d -- the screen can no longer say \"50 GB plan, expired\", "+
				"which is the sentence it most needs at that moment", tc.name, w.AccountPlanGB)
		}
	}
}

// LiveGB is already a max over the account's live grants, so when it drops the plan really has shrunk. A
// local max on top of it would pin a lapsed plan on the screen forever.
func TestTheLearnedSizeFollowsTheAccountDown(t *testing.T) {
	w := &Wallet{PlanGB: 50, AccountPlanGB: 50, PaidThrough: 20900}
	learnPlanSize(w, leaseInfo{PlanGB: 10})
	if w.AccountPlanGB != 10 {
		t.Fatalf("AccountPlanGB=%d after the 50 GB grant lapsed under a live 10 GB one, want 10", w.AccountPlanGB)
	}
	if got := planSizeForDisplay(w); got != 10 {
		t.Fatalf("screen shows %d GB, want 10", got)
	}
}

// The learning has to ride recordCoverage, which is the one place every full lease already passes through.
func TestRecordCoverageCarriesTheLearnedPlanSize(t *testing.T) {
	w := &Wallet{PlanGB: 10, PlanPeriods: 3}
	recordCoverage(w, leaseInfo{ThroughEpoch: 20876, PlanGB: 50}, true, 20703)
	if w.AccountPlanGB != 50 {
		t.Fatalf("recordCoverage left AccountPlanGB=%d; payRent's full lease is the path that must heal a "+
			"handset whose seals all take the paid arm", w.AccountPlanGB)
	}
	if w.PaidThrough != 20876 {
		t.Errorf("recordCoverage stopped recording the term (PaidThrough=%d)", w.PaidThrough)
	}
}

// The wire field is unchanged -- what moved is where the number behind it comes from. A chooser that
// already parses plangb= needs no change, which is why this ships without a versionCode bump.
func TestBillingLineShipsTheAccountSize(t *testing.T) {
	dir := t.TempDir()
	wp := dir + "/wallet.json"
	if err := saveWallet(wp, &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20876, AccountPlanGB: 50}); err != nil {
		t.Fatal(err)
	}
	line := billingLine(wp)
	if !strings.Contains(line, "plangb=50") {
		t.Fatalf("GET-BILLING said %q, want plangb=50 -- the screen still renders this handset's own memory", line)
	}
}
