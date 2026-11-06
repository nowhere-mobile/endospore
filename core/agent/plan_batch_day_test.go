package main

import (
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261102-12: Q134 defence 3 -- a plan starts only on a batch day shared by every phone (docs/billing-plan-model.md).
// The 0-2 epoch jitter is kept; ActivateAfter is then rounded UP to a multiple of planBatchEpochs. Epoch numbers are
// absolute unix-days, so every purchase in one span redeems on the same day.

// pinBatchClock pins the epoch and makes the jitter draw fail, which jitterEpochs reads as the full default delay (2).
func pinBatchClock(t *testing.T, epoch int64) {
	t.Helper()
	oldNow, oldRand := nowEpoch, jitterRand
	nowEpoch = func() int64 { return epoch }
	jitterRand = strings.NewReader("")
	t.Cleanup(func() { nowEpoch, jitterRand = oldNow, oldRand })
}

// batchEnv sets ACTIVATION_JITTER_EPOCHS, or removes it entirely when set is false.
func batchEnv(t *testing.T, v string, set bool) {
	t.Helper()
	t.Setenv("ACTIVATION_JITTER_EPOCHS", "")
	if set {
		t.Setenv("ACTIVATION_JITTER_EPOCHS", v)
	} else {
		os.Unsetenv("ACTIVATION_JITTER_EPOCHS")
	}
}

func TestPlanBatch_RoundsUpToASharedDay(t *testing.T) {
	for _, now := range []int64{300, 301, 302} {
		for j := int64(0); j <= 2; j++ {
			e := activationEpoch(now, j, true)
			if e%planBatchEpochs != 0 || e < now+j || e >= now+j+planBatchEpochs {
				t.Fatalf("activationEpoch(%d,%d,true)=%d: want a multiple of %d in [%d,%d)", now, j, e, planBatchEpochs, now+j, now+j+planBatchEpochs)
			}
		}
	}
	for _, c := range []struct{ now, j, want int64 }{{301, 0, 303}, {300, 0, 300}, {301, 2, 303}, {302, 2, 306}} {
		if got := activationEpoch(c.now, c.j, true); got != c.want {
			t.Fatalf("activationEpoch(%d,%d,true)=%d, want %d", c.now, c.j, got, c.want)
		}
	}
}

func TestPlanBatch_TwoPurchasesInOneSpanShareADay(t *testing.T) {
	a, b := activationEpoch(301, 1, true), activationEpoch(303, 0, true)
	if a != b || a != 303 {
		t.Fatalf("purchases two days apart landed on %d and %d, want both 303", a, b)
	}
}

func TestPlanBatch_WithoutBatchIsUnrounded(t *testing.T) {
	if got := activationEpoch(301, 1, false); got != 302 {
		t.Fatalf("activationEpoch(301,1,false)=%d, want 302", got)
	}
	if got := activationEpoch(301, 0, false); got != 301 {
		t.Fatalf("activationEpoch(301,0,false)=%d, want 301", got)
	}
}

func TestPlanBatch_HoldOverrideZeroIsNotRounded(t *testing.T) {
	pinBatchClock(t, 301)
	for _, v := range []string{"0", " 0 "} {
		batchEnv(t, v, true)
		if got := activationHold(); got != 301 {
			t.Fatalf("ACTIVATION_JITTER_EPOCHS=%q: activationHold()=%d, want 301 (a test ring sees a purchase land)", v, got)
		}
	}
}

func TestPlanBatch_HoldDefaultLandsOnABatchDay(t *testing.T) {
	pinBatchClock(t, 302) // a failed draw is the full default delay: raw 304
	for _, c := range []struct {
		env  string
		set  bool
		want int64
	}{{"", false, 306}, {"x", true, 306}, {"-1", true, 306}, {"1", true, 303}} {
		batchEnv(t, c.env, c.set)
		if got := activationHold(); got != c.want {
			t.Fatalf("env %q (set=%v): activationHold()=%d, want %d", c.env, c.set, got, c.want)
		}
	}
	t.Run("real randomness", func(t *testing.T) {
		pinBatchClock(t, 301)
		jitterRand = rand.Reader
		batchEnv(t, "", false)
		for i := 0; i < 20; i++ {
			if e := activationHold(); e%planBatchEpochs != 0 || e < 301 || e > 305 {
				t.Fatalf("draw %d: activationHold()=%d, want a multiple of 3 in [301,305]", i, e)
			}
		}
	})
}

func TestPlanBatch_RecordPlanStoresABatchDay(t *testing.T) {
	batchEnv(t, "", false)
	for _, now := range []int64{301, 302} {
		pinBatchClock(t, now)
		wp := filepath.Join(t.TempDir(), "wallet.json")
		if err := saveWallet(wp, &Wallet{}); err != nil {
			t.Fatal(err)
		}
		if err := recordPlan(wp, 3, 10, false); err != nil {
			t.Fatal(err)
		}
		w, err := loadWallet(wp)
		if err != nil {
			t.Fatal(err)
		}
		if w.ActivateAfter%planBatchEpochs != 0 || w.ActivateAfter < now+2 {
			t.Fatalf("now=%d: stored ActivateAfter=%d, want a multiple of 3 >= %d", now, w.ActivateAfter, now+2)
		}
		first := w.ActivateAfter
		nowEpoch = func() int64 { return now + 1 }
		if err := recordPlan(wp, 12, 20, false); err != nil {
			t.Fatal(err)
		}
		if w, err = loadWallet(wp); err != nil {
			t.Fatal(err)
		}
		if w.ActivateAfter != first {
			t.Fatalf("a top-up moved ActivateAfter %d -> %d", first, w.ActivateAfter)
		}
	}
}

func TestPlanBatch_PlanActivatedRestartsOnABatchDay(t *testing.T) {
	batchEnv(t, "", false)
	pinBatchClock(t, 302)
	w := &Wallet{PlanGB: 50, PlanPeriods: 3, PlanQueue: []PlanSpec{{GB: 10, Periods: 3}}}
	w.planActivated()
	if w.ActivateAfter != 306 {
		t.Fatalf("promoted plan ActivateAfter=%d, want 306 (the batch day after 304)", w.ActivateAfter)
	}
}

func TestPlanBatch_OverFreeStartsAtOnce(t *testing.T) {
	batchEnv(t, "", false)
	pinBatchClock(t, 302)
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	if err := recordPlan(wp, 3, 2, false); err != nil {
		t.Fatal(err)
	}
	rec, err := loadWallet(wp)
	if err != nil {
		t.Fatal(err)
	}
	if rec.ActivateAfter != 306 {
		t.Fatalf("recorded ActivateAfter=%d, want 306", rec.ActivateAfter)
	}
	fund := func() *Wallet { return jitterWallet(2, 3, rec.ActivateAfter) }
	if gb, _, _, _ := fund().planPurchase(302, false); gb != 0 {
		t.Fatalf("held plan bought %d GB before its batch day", gb)
	}
	if gb, periods, _, _ := fund().planPurchase(302, true); gb != 2 || periods != 3 {
		t.Fatalf("over-free profile did not start at once: gb=%d periods=%d", gb, periods)
	}
	if gb, _, _, _ := fund().planPurchase(306, false); gb != 2 {
		t.Fatalf("plan did not start on its batch day: gb=%d", gb)
	}
}
