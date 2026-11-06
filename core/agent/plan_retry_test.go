package main

// NWP-20260917-07: the plan carry becomes RETRYABLE.
//
// ⚠ WHY A RETRY NEEDED A RECORDED KEY AT ALL, which is the thing that is not obvious from the code. A carry
// has exactly ONE chance at the credential change itself, and afterwards the old key is UNNAMEABLE:
// repointScopes has advanced !bill to the new credential, and on the recovery path the old passphrase is
// gone by premise. So "just call it again later" is not available -- retrying required KEEPING the key, and
// that is what !bill-prev is.

import (
	"path/filepath"
	"testing"
)

// TestACredentialChangeRecordsThePreviousBillingKey.
func TestACredentialChangeRecordsThePreviousBillingKey(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, p1, p2 = "rbprev", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	dk, _, ok := resolveKey(base, name, p2)
	if !ok {
		t.Fatal("the rotated vault does not resolve")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index after the rotation")
	}
	if got := billPrevOf(idx); got != profileRefV2(name, p1) {
		t.Errorf("!bill-prev = %s, want the PRE-rotation key %s -- without it a failed carry is permanent, "+
			"because nothing else in the tree can name the plan afterwards",
			short(got), short(profileRefV2(name, p1)))
	}
	if got := billKeyOf(idx); got != profileRefV2(name, p2) {
		t.Errorf("!bill = %s, want the post-rotation key", short(got))
	}
}

// TestAnIndexWithNoBillingRecordGetsNoPreviousOne. Recording an empty previous key would make every later
// login attempt a carry it can never name -- a gateway call per login, forever, for nothing.
func TestAnIndexWithNoBillingRecordGetsNoPreviousOne(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, p1, p2 = "rbnoprev", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)

	// Strip !bill to stand in for a profile that has not sealed under a build carrying NWP-20260917-04.
	dk, _, _ := resolveKey(base, name, p1)
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p1))))
	idx, _ := openScopeIndex(dk, v.Scopes)
	delete(idx, scopeBillKey)
	v.Scopes = sealScopeIndex(dk, idx)
	signVault(v, dk)
	putHead(base, name, p1, postBlob(base, serializeVault(v)))

	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	dk2, _, _ := resolveKey(base, name, p2)
	v2, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
	idx2, ok := openScopeIndex(dk2, v2.Scopes)
	if !ok {
		t.Fatal("no index after the rotation")
	}
	if got := billPrevOf(idx2); got != "" {
		t.Errorf("!bill-prev = %s on a profile that had no !bill to move off -- that is a carry no login "+
			"can ever name, retried forever", short(got))
	}
	// ...and the ENTRY itself must be absent, not merely empty. A bare "p2:" reads as "" through billPrevOf
	// and is therefore harmless, but it is litter in a structure whose whole job is to be authoritative
	// about where things live, and the next reader cannot tell it from a real record without decoding it.
	if rec, present := idx2[scopeBillPrevKey]; present {
		t.Errorf("an empty !bill-prev entry was written anyway (%+v) -- record nothing rather than nothing-"+
			"shaped", rec)
	}
}

// TestTheLoginRetryCarriesAPlanTheCredentialChangeCouldNot is the point of the slice: a carry that failed
// at the credential change succeeds at a later login, and then stops asking.
func TestTheLoginRetryCarriesAPlanTheCredentialChangeCouldNot(t *testing.T) {
	base := newHTTPStore(t)
	gw := newRebindGateway(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	wpath := filepath.Join(state, "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)

	const name, p1, p2 = "rbretry", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)

	// The credential change happens with NO gateway reachable, so the carry cannot run at all.
	t.Setenv("GATEWAY_URL", "")
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if olds, _ := gw.calls(); len(olds) != 0 {
		t.Fatalf("fixture bug: %d carry call(s) happened during the rotation", len(olds))
	}

	dk, _, _ := resolveKey(base, name, p2)
	// A plan in the wallet is what says the retry is worth making.
	if err := saveWallet(wpath, &Wallet{PaidThrough: 1 << 40, PlanGB: 10}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("GATEWAY_URL", gw.srv.URL)
	retryPlanCarry(base, name, p2, dk, wpath)

	olds, news := gw.calls()
	if len(olds) != 1 {
		t.Fatalf("the login retry made %d call(s), want 1 -- a carry that missed its one chance at the "+
			"credential change must be retryable, or losing it is permanent", len(olds))
	}
	if olds[0] != profileRefV2(name, p1) || news[0] != profileRefV2(name, p2) {
		t.Errorf("retry sent {%s -> %s}, want {%s -> %s}",
			short(olds[0]), short(news[0]), short(profileRefV2(name, p1)), short(profileRefV2(name, p2)))
	}

	// ...and having succeeded, it stops.
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no index after the retry")
	}
	if got := billPrevOf(idx); got != "" {
		t.Errorf("!bill-prev survived a CONFIRMED carry (%s) -- the retry would run on every login forever",
			short(got))
	}
	retryPlanCarry(base, name, p2, dk, wpath)
	if olds2, _ := gw.calls(); len(olds2) != 1 {
		t.Errorf("a second login made another call (%d total) -- the record was not cleared", len(olds2))
	}
}

// TestTheLoginRetryStopsWhenTheWalletHasNoPlan. The gateway answers 200 {"moved":0} to a cooldown, an
// unknown profile and a profile with no plan ALIKE -- deliberately, so a holder of a leaked key learns
// nothing from it. The reply therefore can never tell the device to stop, and the WALLET has to.
func TestTheLoginRetryStopsWhenTheWalletHasNoPlan(t *testing.T) {
	base := newHTTPStore(t)
	gw := newRebindGateway(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	wpath := filepath.Join(state, "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)

	const name, p1, p2 = "rbnoplan", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	t.Setenv("GATEWAY_URL", "")
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	dk, _, _ := resolveKey(base, name, p2)

	// No wallet at all: this profile never bought anything.
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	retryPlanCarry(base, name, p2, dk, wpath)

	if olds, _ := gw.calls(); len(olds) != 0 {
		t.Errorf("the retry called the gateway %d time(s) for a profile with no plan -- it must be stopped "+
			"by the WALLET, since a 0 reply is indistinguishable from a cooldown", len(olds))
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
	idx, _ := openScopeIndex(dk, v.Scopes)
	if got := billPrevOf(idx); got != "" {
		t.Errorf("!bill-prev survived (%s) on a profile with no plan -- it would be retried at every login "+
			"for the rest of the profile's life", short(got))
	}
}

// TestARefusedRetryKeepsTheRecord. A cooldown refusal is exactly the case worth trying again tomorrow, and
// it is indistinguishable on the wire from "nothing to move" -- so an unconfirmed carry must KEEP the record.
func TestARefusedRetryKeepsTheRecord(t *testing.T) {
	base := newHTTPStore(t)
	gw := newRebindGateway(t)
	gw.moved = 0 // the shape of a cooldown refusal
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	wpath := filepath.Join(state, "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)

	const name, p1, p2 = "rbrefused", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	t.Setenv("GATEWAY_URL", "")
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	dk, _, _ := resolveKey(base, name, p2)
	if err := saveWallet(wpath, &Wallet{PaidThrough: 1 << 40, PlanGB: 10}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("GATEWAY_URL", gw.srv.URL)
	retryPlanCarry(base, name, p2, dk, wpath)

	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
	idx, _ := openScopeIndex(dk, v.Scopes)
	if got := billPrevOf(idx); got != profileRefV2(name, p1) {
		t.Errorf("!bill-prev = %s after an UNCONFIRMED carry, want it KEPT -- a cooldown refusal is the "+
			"case the retry exists for, and dropping the record makes the plan unreachable forever",
			short(got))
	}
}
