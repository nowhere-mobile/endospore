package main

import "testing"

// h60 #13 (docs/product-decisions.md, "twenty answers to harvest 60 ..."): the over-free bypass of the Q134 activation
// hold applies only when no live bought term covers the profile (PaidThrough <= now). An uncovered profile over the
// free allowance is one sweep away from losing bytes and starts at once. A covered one is not at risk, so its early
// renewal or top-up waits out its hold like any other purchase.

const overFreeNow = int64(1000)

func overFreeWantBuys(t *testing.T, w *Wallet, overFree bool) {
	t.Helper()
	gb, periods, plain, blind := w.planPurchase(overFreeNow, overFree)
	if gb != 2 || periods != 3 || len(plain)+len(blind) != 6 {
		t.Fatalf("planPurchase = %d x %d with %d signatures, want 2 x 3 with 6", gb, periods, len(plain)+len(blind))
	}
}

func overFreeWantHolds(t *testing.T, w *Wallet, overFree bool) {
	t.Helper()
	gb, periods, plain, blind := w.planPurchase(overFreeNow, overFree)
	if gb != 0 || periods != 0 || len(plain)+len(blind) != 0 {
		t.Fatalf("planPurchase = %d x %d with %d signatures, want nothing during the hold", gb, periods, len(plain)+len(blind))
	}
	if w.balance() != 6 {
		t.Fatalf("balance = %d after a held purchase, want 6 (nothing may be spent)", w.balance())
	}
}

func TestOverFreeLiveTerm_NoTermStartsAtOnce(t *testing.T) {
	w := jitterWallet(2, 3, overFreeNow+10)
	overFreeWantBuys(t, w, true)
}

// The boundary: a term that ends at this epoch is not live (PaidThrough <= now).
func TestOverFreeLiveTerm_TermEndingNowCountsAsNone(t *testing.T) {
	w := jitterWallet(2, 3, overFreeNow+10)
	w.PaidThrough = overFreeNow
	overFreeWantBuys(t, w, true)
}

func TestOverFreeLiveTerm_ALiveTermWaitsOutTheHold(t *testing.T) {
	w := jitterWallet(2, 3, overFreeNow+10)
	w.PaidThrough = overFreeNow + 30
	overFreeWantHolds(t, w, true)
}

// The hold delays an early renewal. It must not block one: the funded gate lets it past a live term.
func TestOverFreeLiveTerm_ALiveTermStartsOnceTheHoldEnds(t *testing.T) {
	w := jitterWallet(2, 3, overFreeNow)
	w.PaidThrough = overFreeNow + 30
	overFreeWantBuys(t, w, true)
}

func TestOverFreeLiveTerm_UnderFreeHoldsEitherWay(t *testing.T) {
	for _, paidThrough := range []int64{0, overFreeNow + 30} {
		w := jitterWallet(2, 3, overFreeNow+10)
		w.PaidThrough = paidThrough
		overFreeWantHolds(t, w, false)
	}
}
