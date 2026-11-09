package main

import (
	"fmt"
	"net/http"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// NWP-20261129-10: an idle phone that publishes the other phone's credit publishes the purchase that credit pays for,
// whole: its size, term, answer and queue (decided 2026-10-20: a smaller purchase "is never stranded", and Q107: a
// publish carries the other phone's new credit). Handset B holds an activated 50 x 12 plan; handset A redeemed a
// 10 x 3 top-up with the "keep" answer. The max of the two prices 600 tokens beside A's 30.

func pubWaitingTokens(tag string, n int) []BlindToken {
	out := make([]BlindToken, n)
	for i := range out {
		out[i] = BlindToken{Msg: fmt.Sprintf("%s-msg-%d", tag, i), Sig: fmt.Sprintf("%s-sig-%d", tag, i)}
	}
	return out
}

// pubWaitingOtherPhone is handset A's copy: a waiting 10 x 3 keep purchase and its 30 tokens.
func pubWaitingOtherPhone() *Wallet {
	return &Wallet{PlanGB: 10, PlanPeriods: 3, PlanKeep: true, ActivateAfter: 105, BlindTokens: pubWaitingTokens("other", 30)}
}

// pubWaitingIdlePhone is handset B's copy: the activated 50 x 12 plan, no token.
func pubWaitingIdlePhone() *Wallet {
	return &Wallet{PlanGB: 50, PlanPeriods: 12, PaidThrough: 400}
}

// P1: the failure scenario. The published plan is the one the carried tokens fund, and it buys.
func TestWalletPublishWaiting_TheOtherPhonesTopUpIsPublishedWhole(t *testing.T) {
	out := walletForPublish(pubWaitingOtherPhone(), pubWaitingIdlePhone(), map[string]bool{})
	if out.PlanGB != 10 || out.PlanPeriods != 3 || !out.PlanKeep {
		t.Fatalf("published %d x %d keep=%v, want the other phone's 10 x 3 keep", out.PlanGB, out.PlanPeriods, out.PlanKeep)
	}
	if out.balance() != 30 || !out.planPending() {
		t.Fatalf("published balance %d pending=%v, want 30 tokens and a waiting purchase", out.balance(), out.planPending())
	}
	if out.ActivateAfter != 105 || out.PaidThrough != 400 {
		t.Fatalf("ActivateAfter %d PaidThrough %d, want each one's max: 105 and 400", out.ActivateAfter, out.PaidThrough)
	}
	if got := out.planChange(); got != planChangeKeep {
		t.Fatalf("planChange = %q, want %q", got, planChangeKeep)
	}
	gb, periods, plain, blind := out.planPurchase(106, false)
	if gb != 10 || periods != 3 || len(plain)+len(blind) != 30 {
		t.Fatalf("planPurchase bought %d x %d with %d signatures, want 10 x 3 with 30", gb, periods, len(plain)+len(blind))
	}
}

// P2: a stored queue and a convert answer are published with the purchase, as a copy, and the queue still promotes.
func TestWalletPublishWaiting_AQueueAndAConvertAnswerRideAlong(t *testing.T) {
	stored := &Wallet{PlanGB: 50, PlanPeriods: 3, PlanConvert: true, PlanQueue: make([]PlanSpec, 1, 4), BlindTokens: pubWaitingTokens("queue", 180)}
	stored.PlanQueue[0] = PlanSpec{GB: 10, Periods: 3, Keep: true}
	out := walletForPublish(stored, &Wallet{PlanGB: 20, PlanPeriods: 12}, map[string]bool{})
	if out.PlanGB != 50 || out.PlanPeriods != 3 || !out.PlanConvert || out.PlanKeep {
		t.Fatalf("published %d x %d convert=%v keep=%v, want 50 x 3 convert", out.PlanGB, out.PlanPeriods, out.PlanConvert, out.PlanKeep)
	}
	if got := out.planChange(); got != planChangeConvert {
		t.Fatalf("planChange = %q, want %q", got, planChangeConvert)
	}
	if len(out.PlanQueue) != 1 || out.PlanQueue[0] != (PlanSpec{GB: 10, Periods: 3, Keep: true}) {
		t.Fatalf("published queue %v, want [10 x 3 keep]", out.PlanQueue)
	}

	// A copy: stored's queue has spare capacity, so an alias would take this append and this write.
	queue := out.PlanQueue
	out.PlanQueue = append(out.PlanQueue, PlanSpec{GB: 99, Periods: 9})
	if got := stored.PlanQueue[:2][1]; got != (PlanSpec{}) {
		t.Fatalf("an append to the published queue wrote %v into stored's array", got)
	}
	out.PlanQueue[0].GB = 77
	if stored.PlanQueue[0].GB != 10 {
		t.Fatalf("a write to the published queue reached stored's: %v", stored.PlanQueue[0])
	}
	queue[0].GB = 10
	out.PlanQueue = queue

	out.BlindTokens = out.BlindTokens[150:] // the first purchase lands
	out.planActivated()
	if out.PlanGB != 10 || out.PlanPeriods != 3 || !out.PlanKeep || out.PlanConvert || !out.planPending() {
		t.Fatalf("after the first purchase: %d x %d keep=%v convert=%v pending=%v, want a waiting 10 x 3 keep",
			out.PlanGB, out.PlanPeriods, out.PlanKeep, out.PlanConvert, out.planPending())
	}
}

// P3: this session held every stored token, and this phone's own 30 tokens would pass the funding check. Nothing was
// carried, so the stored purchase is not adopted.
func TestWalletPublishWaiting_TokensThisPhoneHeld(t *testing.T) {
	stored := pubWaitingOtherPhone()
	seen := map[string]bool{}
	for _, k := range walletSeenKeys(stored) {
		seen[k] = true
	}
	local := pubWaitingIdlePhone()
	local.BlindTokens = pubWaitingTokens("mine", 30)
	if local.planPending() {
		t.Fatal("fixture: this phone must have nothing waiting (30 tokens under a 600-token plan)")
	}
	out := walletForPublish(stored, local, seen)
	if out.PlanGB != 50 || out.PlanPeriods != 12 || out.PlanKeep || len(out.PlanQueue) != 0 {
		t.Fatalf("published %d x %d keep=%v queue %v, want today's max 50 x 12", out.PlanGB, out.PlanPeriods, out.PlanKeep, out.PlanQueue)
	}
	if len(out.BlindTokens) != 30 || out.BlindTokens[0].Msg != "mine-msg-0" {
		t.Fatalf("published %d tokens, want this phone's 30 only", len(out.BlindTokens))
	}
}

// P4: a nil seen means no union, so no carried token and today's max.
func TestWalletPublishWaiting_ANilSeenKeepsTodaysMax(t *testing.T) {
	out := walletForPublish(pubWaitingOtherPhone(), pubWaitingIdlePhone(), nil)
	if out.PlanGB != 50 || out.PlanPeriods != 12 || out.PlanKeep || out.balance() != 0 {
		t.Fatalf("published %d x %d keep=%v with %d tokens, want 50 x 12 and none", out.PlanGB, out.PlanPeriods, out.PlanKeep, out.balance())
	}
}

// P5: this phone's own waiting purchase stays verbatim over a different stored one (NWP-20261031-07); the other
// phone's tokens ride without their plan.
func TestWalletPublishWaiting_ThisPhonesWaitingPurchaseStaysVerbatim(t *testing.T) {
	stored := &Wallet{PlanGB: 20, PlanPeriods: 1, BlindTokens: pubWaitingTokens("other", 20)}
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, BlindTokens: pubWaitingTokens("mine", 30)}
	out := walletForPublish(stored, local, map[string]bool{})
	if out.PlanGB != 10 || out.PlanPeriods != 3 || out.balance() != 50 {
		t.Fatalf("published %d x %d with %d tokens, want this phone's 10 x 3 with 50", out.PlanGB, out.PlanPeriods, out.balance())
	}
}

// P7: 14 tokens carried do not fund a 30-token purchase, so adopting it would publish another plan no balance funds.
func TestWalletPublishWaiting_ACarriedShortfallKeepsTodaysMax(t *testing.T) {
	stored := pubWaitingOtherPhone()
	seen := map[string]bool{}
	for _, tok := range stored.BlindTokens[:16] {
		seen[blindSeenKey(tok)] = true
	}
	out := walletForPublish(stored, pubWaitingIdlePhone(), seen)
	if out.PlanGB != 50 || out.PlanPeriods != 12 || out.PlanKeep || len(out.BlindTokens) != 14 {
		t.Fatalf("published %d x %d keep=%v with %d tokens, want today's max 50 x 12 with 14", out.PlanGB, out.PlanPeriods, out.PlanKeep, len(out.BlindTokens))
	}
}

// P6: the scenario through the store. Handset A publishes its waiting purchase; handset B, in its own state dir with
// the activated plan and no token, publishes after it. Every assertion reads the STORE.
func TestWalletPublishWaiting_ThroughADurablePublish(t *testing.T) {
	const name, pass = "pubwaitingdurable", "a top-up on one phone, a plan on the other"
	wa := walletRaceEnv(t)
	standUpProfile(t, name, pass)
	dk := resolveDK("s3", name, pass, nil)

	// FreeGB 5 keeps this profile under the free allowance, so A's activation wait holds the purchase. A held
	// purchase skips the free probe and sends a token-less entitled lease, which the real gateway's free arm grants.
	capStoreQuote = func(_ http.Header, q *quoteInfo) { q.FreeGB = 5 }
	var bought atomic.Int32
	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if r.BuyGB > 0 {
			bought.Add(1)
		}
		return http.StatusOK, ""
	}
	far := nowEpoch() + 100000

	a := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanKeep: true, ActivateAfter: far, BlindTokens: pubWaitingTokens("handset-a", 30)}
	if err := saveWallet(wa, a); err != nil {
		t.Fatal(err)
	}
	if _, err := sealWalletDurable("s3", name, pass, dk, wa); err != nil {
		t.Fatalf("handset A's publish: %v", err)
	}
	sw := storedWallet(t, name, pass)
	if sw == nil || sw.PlanGB != 10 || sw.balance() != 30 {
		t.Fatalf("control: after handset A's publish the store holds %+v", sw)
	}

	// Handset B: its own state dir, its restore proven, and NOWHERE_WALLET pointed at it for its publish, because
	// capFlush folds capWalletPath().
	wb := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wb)
	if err := saveWallet(wb, &Wallet{PlanGB: 50, PlanPeriods: 12, PaidThrough: far}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_WALLET", wb)
	if _, err := sealWalletDurable("s3", name, pass, dk, wb); err != nil {
		t.Fatalf("handset B's publish: %v", err)
	}

	sw = storedWallet(t, name, pass)
	if sw == nil {
		t.Fatal("no stored wallet after handset B's publish")
	}
	if sw.PlanGB != 10 || sw.PlanPeriods != 3 || !sw.PlanKeep {
		t.Errorf("the store holds %d x %d keep=%v, want handset A's 10 x 3 keep", sw.PlanGB, sw.PlanPeriods, sw.PlanKeep)
	}
	got := twoWriterNonces(sw)
	if len(got) != 30 {
		t.Errorf("the store holds %d tokens, want handset A's 30", len(got))
	}
	for _, tok := range a.BlindTokens {
		if !got[blindSeenKey(tok)] {
			t.Errorf("the store lost handset A's token %s", tok.Msg)
			break
		}
	}
	if n := bought.Load(); n != 0 {
		t.Errorf("%d leases bought a plan; both publishes must hold the purchase", n)
	}
}
