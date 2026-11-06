package main

// DIA-20260809-04: the whole footprint must keep being re-leased even while the term still covers it.
//
// payRent is the ONLY lease over the whole footprint, and it used to gate solely on PaidThrough. That was
// safe while a lease bought one 30-day period: PaidThrough sat ~30 days out, so payRent ran monthly and
// every ref -- hot and cold -- was re-stamped well inside its own deadline. Once the device started buying
// its real term (up to 360 days), PaidThrough moved a year out and payRent went quiet for that whole year,
// while capFlush re-leased only the spilled delta.
//
// The refs that die first are the FREE-stamped ones: capFlush tries the free lease FIRST, and a free lease
// lives FreeTTL(90d) + grace(30d) = ~120 days from last access. Sweep has no reachability check and getBlob
// fails hard on a missing chunk, so the result is not a profile with gaps -- it is a profile that cannot
// log in.

import "testing"

func TestRenewalRunsWhileTheTermStillCovers(t *testing.T) {
	const now = int64(20000)
	// An annual buyer: covered for another year, and renewed only yesterday. Nothing to do.
	fresh := &Wallet{PaidThrough: now + 360, RenewedEpoch: now - 1}
	if renewalDue(fresh, now) {
		t.Error("renewed yesterday and covered for a year -- must not re-lease on every sync")
	}

	// Same buyer, renewEveryEpochs later. The term still covers them, so the OLD rule returns early here --
	// and that early return is the bug: nothing re-stamps a cold ref for the rest of the term.
	stale := &Wallet{PaidThrough: now + 360, RenewedEpoch: now - renewEveryEpochs}
	if !renewalDue(stale, now) {
		t.Errorf("a %d-epoch-old footprint was not renewed: cold refs age out at ~120 days while the term hides it",
			renewEveryEpochs)
	}

	// The cadence must beat the shortest life any ref can carry -- a free-stamped ref at FreeTTL 90d plus
	// 30d of grace. Without a wide margin a single missed pass loses data.
	const shortestRefLifeEpochs = 90 + 30
	if renewEveryEpochs*2 >= shortestRefLifeEpochs {
		t.Errorf("renewEveryEpochs=%d leaves too little margin against a %d-epoch ref life",
			renewEveryEpochs, shortestRefLifeEpochs)
	}
}

// Rent genuinely due must still renew, exactly as before -- the staleness arm is additive.
func TestRenewalStillRunsWhenRentIsDue(t *testing.T) {
	const now = int64(20000)
	w := &Wallet{PaidThrough: now, RenewedEpoch: now} // lapsed this epoch, renewed this epoch
	if !renewalDue(w, now) {
		t.Error("PaidThrough no longer covers this epoch -- rent is due and must be paid")
	}
}

// A wallet written before RenewedEpoch existed reads as never-renewed and must renew once, rather than
// inheriting a silent year of suppression from its PaidThrough.
func TestLegacyWalletRenewsOnce(t *testing.T) {
	const now = int64(20000)
	w := &Wallet{PaidThrough: now + 360} // RenewedEpoch absent -> 0
	if !renewalDue(w, now) {
		t.Error("a wallet predating RenewedEpoch must renew once, not wait out the term")
	}
}

// Only a FULL-footprint lease may record the deletion date. The gateway answers with the earliest deadline
// among the refs in THAT call, so a delta lease reports the floor of a few freshly-stamped refs and would
// show a date later than the one the collector will actually use.
func TestOnlyAFullLeaseRecordsTheDeadline(t *testing.T) {
	w := &Wallet{}
	recordCoverage(w, leaseInfo{ThroughEpoch: 460, DeadlineEpoch: 550}, true, 100)
	if w.DeadlineEpoch != 550 || w.RenewedEpoch != 100 {
		t.Fatalf("full lease not recorded: %+v", w)
	}

	// A delta lease reporting a LATER deadline must not overwrite the full-footprint floor.
	recordCoverage(w, leaseInfo{ThroughEpoch: 470, DeadlineEpoch: 9999}, false, 0)
	if w.DeadlineEpoch != 550 {
		t.Errorf("a delta lease raised the deadline to %d -- it only saw its own refs", w.DeadlineEpoch)
	}
	if w.RenewedEpoch != 100 {
		t.Errorf("a delta lease counted as a full renewal (RenewedEpoch=%d) -- cold refs would go unrefreshed", w.RenewedEpoch)
	}
	if w.PaidThrough != 470 {
		t.Errorf("the term should still track any lease: PaidThrough=%d", w.PaidThrough)
	}

	// A later full lease ASSIGNS, even downward: a new ref with a nearer deadline genuinely lowers the floor.
	recordCoverage(w, leaseInfo{ThroughEpoch: 480, DeadlineEpoch: 500}, true, 130)
	if w.DeadlineEpoch != 500 {
		t.Errorf("full lease did not assign the true floor: %d, want 500", w.DeadlineEpoch)
	}
}
