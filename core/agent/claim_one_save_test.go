package main

// NWP-20261128-24: a claim batch's plan and its tokens land in ONE save, or nothing of the batch lands. drainClaimMode
// saved the plan first and the tokens second, so a failed second save left a plan with no tokens, which the next paid
// lease bought with the credit the wallet already held (the failure NWP-20261122-16 closed for a refused signature).
// The fault is TestWalletSeen_AFailedMarkerWriteRefusesTheSave's: a save that adds a seen key fails, and a save that
// adds none lands. test-claim-bad-signature.sh M4 (the two writes back) is convicted by O1 and O2, and M5
// (applyPlanMode after the append) by O3(c). Every test has its own claim code and its own wallet in a t.TempDir().

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
)

// cosFault makes every later save that adds a seen key fail: the seen-set's temp file and its poison marker are both
// directories. A save that adds no key still lands. Call it after the setup save, so wp+".seen" exists.
func cosFault(t *testing.T, wp string) {
	t.Helper()
	tmp, bad := wp+".seen.tmp", seenBadPath(wp)
	if err := os.Mkdir(tmp, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(bad, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		os.Remove(tmp)
		os.Remove(bad)
	})
}

// cosNoID records every purchase of the test without an id. Since NWP-20261201-18 a recorded purchase's id is a seen
// key (p:<id>), so with an id the plan-only first write of mutant M4 also adds a key, fails under cosFault, and M4
// passes. An id-less purchase adds no key, as before h60 #14, so M4's plan write lands and the test convicts it.
func cosNoID(t *testing.T) {
	t.Helper()
	old := newPurchaseID
	newPurchaseID = func() string { return "" }
	t.Cleanup(func() { newPurchaseID = old })
}

// cosFunded saves a wallet holding an earlier funded purchase: a 5 GB x 1 plan and 5 plain tokens to pay for it.
func cosFunded(t *testing.T, wp string) {
	t.Helper()
	if err := bumpWalletGeneration(wp); err != nil {
		t.Fatal(err)
	}
	w := &Wallet{PlanGB: 5, PlanPeriods: 1}
	for i := 0; i < 5; i++ {
		w.Tokens = append(w.Tokens, Token{Denom: "1GBmo", Nonce: "cos-funded-" + strconv.Itoa(i), Exp: 1900000000, Sig: "cos"})
	}
	if err := saveWallet(wp, w); err != nil {
		t.Fatal(err)
	}
}

// O1: a batch whose token save fails records no plan. Two saves left plan 10 x 3 with zero tokens.
func TestClaimOneSave_APlanNeverLandsWithoutItsTokens(t *testing.T) {
	cosNoID(t)
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := bumpWalletGeneration(wp); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wp, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	cosFault(t, wp)
	n, err := drainClaim(cbsGateway(t, cbsGood, 30), wp, "COS-O1", false)
	if n != 0 || err == nil {
		t.Fatalf("drainClaim = (%d, %v), want (0, an error)", n, err)
	}
	w := cbsLoad(t, wp)
	if w.PlanGB != 0 || w.PlanPeriods != 0 || len(w.PlanQueue) != 0 || len(w.BlindTokens) != 0 || w.balance() != 0 {
		t.Fatalf("a failed batch left plan %d x %d, queue %v and %d blind tokens, want no plan and no token",
			w.PlanGB, w.PlanPeriods, w.PlanQueue, len(w.BlindTokens))
	}
}

// O2: the same fault under an earlier funded purchase leaves the wallet file byte for byte as it was. Two saves
// queued 10 x 3 behind the 5 x 1 with no token to pay for it.
func TestClaimOneSave_AFailedBatchLeavesAFundedWalletAsItWas(t *testing.T) {
	cosNoID(t)
	wp := filepath.Join(t.TempDir(), "wallet.json")
	cosFunded(t, wp)
	before, err := os.ReadFile(wp)
	if err != nil {
		t.Fatal(err)
	}
	cosFault(t, wp)
	n, err := drainClaim(cbsGateway(t, cbsGood, 30), wp, "COS-O2", false)
	if n != 0 || err == nil {
		t.Fatalf("drainClaim = (%d, %v), want (0, an error)", n, err)
	}
	after, err := os.ReadFile(wp)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, before) {
		w := cbsLoad(t, wp)
		t.Fatalf("a failed batch changed the wallet: plan %d x %d, queue %v, %d blind tokens",
			w.PlanGB, w.PlanPeriods, w.PlanQueue, len(w.BlindTokens))
	}
}

// O3: with no fault the one save records what the two did, and applies the plan before it appends the tokens.
func TestClaimOneSave_NoFault(t *testing.T) {
	t.Run("a full drain records the plan and every token", func(t *testing.T) {
		wp := filepath.Join(t.TempDir(), "wallet.json")
		n, err := drainClaim(cbsGateway(t, cbsGood, 30), wp, "COS-O3A", false)
		if n != 30 || err != nil {
			t.Fatalf("drainClaim = (%d, %v), want (30, nil)", n, err)
		}
		w := cbsLoad(t, wp)
		if len(w.BlindTokens) != 30 || w.PlanGB != 10 || w.PlanPeriods != 3 || len(w.PlanQueue) != 0 {
			t.Fatalf("wallet holds %d blind tokens, plan %d x %d and queue %v, want 30, 10 x 3 and no queue",
				len(w.BlindTokens), w.PlanGB, w.PlanPeriods, w.PlanQueue)
		}
	})
	t.Run("a code drained behind a waiting funded purchase is queued", func(t *testing.T) {
		wp := filepath.Join(t.TempDir(), "wallet.json")
		cosFunded(t, wp)
		n, err := drainClaim(cbsGateway(t, cbsGood, 30), wp, "COS-O3B", false)
		if n != 30 || err != nil {
			t.Fatalf("drainClaim = (%d, %v), want (30, nil)", n, err)
		}
		w := cbsLoad(t, wp)
		for i := range w.PlanQueue {
			w.PlanQueue[i].ID = "" // a minted random id (h60 #14); this test pins the size and term
		}
		want := []PlanSpec{{GB: 10, Periods: 3}}
		if w.PlanGB != 5 || w.PlanPeriods != 1 || !reflect.DeepEqual(w.PlanQueue, want) {
			t.Fatalf("wallet holds plan %d x %d and queue %v, want 5 x 1 and %v", w.PlanGB, w.PlanPeriods, w.PlanQueue, want)
		}
	})
	// THE ORDER CASE. The 1 x 1 plan has activated: its tokens are spent and none is left. With the append first,
	// the first batch's one token makes the old 1 x 1 funded, and the new plan queues behind it (mutant M5).
	t.Run("an activated plan is replaced", func(t *testing.T) {
		wp := filepath.Join(t.TempDir(), "wallet.json")
		if err := saveWallet(wp, &Wallet{PlanGB: 1, PlanPeriods: 1, PaidThrough: 1000}); err != nil {
			t.Fatal(err)
		}
		n, err := drainClaim(cbsGateway(t, cbsGood, 30), wp, "COS-O3C", false)
		if n != 30 || err != nil {
			t.Fatalf("drainClaim = (%d, %v), want (30, nil)", n, err)
		}
		w := cbsLoad(t, wp)
		if w.PlanGB != 10 || w.PlanPeriods != 3 || len(w.PlanQueue) != 0 {
			t.Fatalf("wallet holds plan %d x %d and queue %v, want 10 x 3 and no queue", w.PlanGB, w.PlanPeriods, w.PlanQueue)
		}
	})
}
