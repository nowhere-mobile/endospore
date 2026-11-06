package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// NWP-20260903-12: the CREATE-CODE adjacency P0 -- the activation jitter must not be bypassed on the
// create path.
//
// THE CHAIN THAT SHIPPED. handleCreateCode drains the claim at POST /issue (identified: the code came from
// a Stripe purchase) and calls handleCreate on the next statement. The create's first seal reaches
// capFlush's plan branch with planPending() true, which SKIPS the free probe (DIA-20260809-16) -- so `code`
// holds 402 by INITIALISATION, not measurement -- and the branch then called planPurchase(_, true), where
// that literal `true` is the "data is at risk" override that bypasses the jitter hold. Net: the first lease
// carried profileRefV2 AND freshly-minted blind signatures within seconds of an identified purchase, same
// connection, same address. Blinding hides the token, not the adjacency.
//
// TWO GUARDS, one per failure direction:
//   * behavioural, on planPurchase: the jitter window holds a funded plan when data is not at risk, and
//     yields when it is -- the semantics both callers now rely on;
//   * source, on capFlush: the call site passes a COMPUTED overFree. The literal was one character of
//     diff from correct and survived two reviews; a source pin is what makes the third re-introduction
//     fail a test instead of a privacy audit.

func jitterWallet(gb int, periods int64, activateAfter int64) *Wallet {
	w := &Wallet{PlanGB: gb, PlanPeriods: periods, ActivateAfter: activateAfter}
	// Fund it exactly: activation needs balance() >= gb*periods.
	for i := 0; i < gb*int(periods); i++ {
		w.Tokens = append(w.Tokens, Token{Nonce: strings.Repeat("n", 8) + string(rune('a'+i%26)) + string(rune('0'+i%10))})
	}
	return w
}

func TestJitterHoldsWhenDataIsNotAtRisk(t *testing.T) {
	now := int64(1000)
	w := jitterWallet(2, 3, now+10) // funded plan, window still open
	gb, periods, plain, blind := w.planPurchase(now, false)
	if gb != 0 || periods != 0 || len(plain) != 0 || len(blind) != 0 {
		t.Fatalf("planPurchase activated INSIDE the jitter window with data not at risk: gb=%d periods=%d "+
			"tokens=%d/%d -- the create path is presenting purchase-adjacent signatures again (NWP-20260903-12)",
			gb, periods, len(plain), len(blind))
	}
	if len(w.Tokens) != 6 {
		t.Fatalf("the held plan spent tokens anyway: %d left of 6", len(w.Tokens))
	}
}

func TestJitterYieldsWhenDataIsAtRisk(t *testing.T) {
	now := int64(1000)
	w := jitterWallet(2, 3, now+10)
	gb, periods, plain, blind := w.planPurchase(now, true)
	if gb != 2 || periods != 3 || len(plain)+len(blind) == 0 {
		t.Fatalf("planPurchase HELD the plan while data was at risk: gb=%d periods=%d tokens=%d -- "+
			"DIA-20260809-16's customer is locked out again", gb, periods, len(plain)+len(blind))
	}
}

func TestJitterExpiryActivates(t *testing.T) {
	now := int64(1000)
	w := jitterWallet(2, 3, now-1) // window passed
	gb, periods, plain, blind := w.planPurchase(now, false)
	if gb != 2 || periods != 3 || len(plain)+len(blind) == 0 {
		t.Fatalf("planPurchase never activated after the jitter window passed: gb=%d periods=%d tokens=%d",
			gb, periods, len(plain)+len(blind))
	}
}

// TestCapFlushComputesOverFree pins the CALL SITE: capFlush's 402 arm must derive overFree from the quote's
// free allowance, never pass a literal. Source-level for the same reason as syncloop_lock_test.go -- the
// defect is one token in one expression, unreachable behaviourally without a live gateway, and the exact
// shape that shipped twice.
func TestCapFlushComputesOverFree(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "capFlush"))
	joined := strings.Join(body, "\n")
	if regexp.MustCompile(`planPurchase\([^)]*,\s*true\s*\)`).MatchString(joined) {
		t.Fatal("capFlush passes a LITERAL true to planPurchase -- the jitter bypass is back (NWP-20260903-12)")
	}
	m := regexp.MustCompile(`planPurchase\(q\.CurrentEpoch,\s*(\w+)\)`).FindStringSubmatch(joined)
	if m == nil {
		t.Fatal("capFlush no longer calls planPurchase(q.CurrentEpoch, <var>) -- this test is stale, not the code")
	}
	if !strings.Contains(joined, m[1]+" := incomingB > q.FreeGB<<30") &&
		!strings.Contains(joined, m[1]+" := incomingB > (q.FreeGB << 30)") {
		t.Fatalf("capFlush's %q is not derived from the free allowance -- overFree must mean what it says", m[1])
	}
}
