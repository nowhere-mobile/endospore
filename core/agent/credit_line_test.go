package main

// NWP-20260907-06: `credit=` and `plangb=` ride the SAME GET-BILLING line and answer the same question --
// how big is this plan. They must not answer it from different places.
//
// NWP-20260907-03 moved `plangb=` to the account's size and left `credit=` on w.PlanGB, this handset's own
// memory of a purchase. Device-proven split on lynx 2026-09-07: one line read `credit=60 ... plangb=50`,
// where 60 is 10 GB x 6 periods off the stale local figure. Nothing on screen was wrong -- the fielded
// chooser ignores `credit=` on purpose -- which is precisely why it would have sat there unnoticed.

import (
	"strings"
	"testing"
)

// THE INVARIANT, stated as the line the device actually emits: the two fields must agree, because a reader
// dividing one by the other is doing something entirely reasonable.
func TestCreditAndPlangbAgreeOnOneBillingLine(t *testing.T) {
	// NWP-20260930-02: pinned to the day these figures were measured on lynx (2026-09-07, epoch day 20703), as
	// TestCreditIsSizedByTheAccountPlan below already is. billingLine reads the real clock, and on the real one the
	// "6 remaining periods" to PaidThrough became 5 on 2026-09-30 and failed every CI run from then on.
	old := nowEpoch
	nowEpoch = func() int64 { return 20703 }
	t.Cleanup(func() { nowEpoch = old })
	dir := t.TempDir()
	wp := dir + "/wallet.json"
	// lynx exactly as it was found: a stale local 10, the account's 50 learned from the gateway.
	if err := saveWallet(wp, &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20876, AccountPlanGB: 50}); err != nil {
		t.Fatal(err)
	}
	line := billingLine(wp)
	if !strings.Contains(line, "plangb=50") {
		t.Fatalf("line %q lost plangb=50", line)
	}
	if strings.Contains(line, "credit=60") {
		t.Fatalf("credit is still priced at the stale local 10 GB: %q -- this is the exact split measured "+
			"on lynx, one line disagreeing with itself", line)
	}
	if !strings.Contains(line, "credit=300") {
		t.Fatalf("line %q: want credit=300 (50 GB x 6 remaining periods), so credit/periods == plangb", line)
	}
}

func TestCreditIsSizedByTheAccountPlan(t *testing.T) {
	w := &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20876, AccountPlanGB: 50}
	if got := displayCredit(w, 20703); got != 300 {
		t.Fatalf("displayCredit=%d, want 300 (50 x 6) -- it is still pricing from this handset's PlanGB", got)
	}
}

// A gateway too old to send the field, or a profile that has never leased: nothing is learned, and the
// local figure is all there is. It must still work exactly as before.
func TestCreditFallsBackToTheLocalPlanWhenNothingWasLearned(t *testing.T) {
	w := &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20876}
	if got := displayCredit(w, 20703); got != 60 {
		t.Fatalf("displayCredit=%d, want 60 (10 x 6) -- the pre-existing behaviour must survive", got)
	}
}

// A case the OLD expression could not express: a handset that only ever LEARNED the plan. recordPlan runs
// only where the claim was redeemed, so PlanGB is 0 here -- and `w.PlanGB <= 0` sent it to the raw balance,
// reporting ZERO credit for a live paid term.
func TestALearnedOnlyHandsetReportsItsTermRatherThanZero(t *testing.T) {
	w := &Wallet{AccountPlanGB: 50, PaidThrough: 20876}
	if got := displayCredit(w, 20703); got == 0 {
		t.Fatal("displayCredit=0 for a handset that never redeemed the claim but holds a live 50 GB term")
	} else if got != 300 {
		t.Fatalf("displayCredit=%d, want 300", got)
	}
}

// With no live term the shim steps aside and reports real spendable credit -- an unactivated plan genuinely
// IS credit, and this must not start reporting a term the profile does not have.
func TestNoLiveTermStillReportsTheRealBalance(t *testing.T) {
	w := &Wallet{PlanGB: 10, PlanPeriods: 3, AccountPlanGB: 50, PaidThrough: 20000, Tokens: make([]Token, 7)}
	if got := displayCredit(w, 20703); got != 7 {
		t.Fatalf("displayCredit=%d, want 7 (the raw balance) -- PaidThrough is in the past", got)
	}
}

// A funded, unactivated purchase prices from the LOCAL plan, because that is what the customer just bought
// and what the headline shows. credit and plangb stay consistent through that window too.
func TestAPendingPurchasePricesFromWhatWasJustBought(t *testing.T) {
	w := &Wallet{PlanGB: 50, PlanPeriods: 3, AccountPlanGB: 10, PaidThrough: 20876, Tokens: make([]Token, 150)}
	if !w.planPending() {
		t.Fatal("setup is wrong: the purchase must be funded and unactivated")
	}
	if got, want := displayCredit(w, 20703), 50*6; got != want {
		t.Fatalf("displayCredit=%d, want %d -- during the activation window the screen shows what was just "+
			"bought, and credit must agree with it", got, want)
	}
}
