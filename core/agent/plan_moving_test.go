package main

// NWP-20261103-05 (Q147): a credential change that leaves the plan carry unsettled stamps its !bill-prev record
// with a time, writes a marker beside the wallet, and GET-BILLING says moving=<that time> while the gateway's
// rebind cooldown (nowhere-cloud NWC-20260917-01) can still be refusing it. The gateway is chainGateway
// (plan_carry_chain_test.go): a stamped key answers 200 {"moved":0}, which is the refusal.

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
)

// pinPlanMovingClock fixes the record's clock for one test and restores it after.
func pinPlanMovingClock(t *testing.T, at int64) {
	t.Helper()
	old := planMovingNow
	planMovingNow = func() int64 { return at }
	t.Cleanup(func() { planMovingNow = old })
}

func planMovingHasField(line string) bool { return strings.Contains(line, " moving=") }

// pmRefusedRotation rotates A->B with the grant at key(A) refused by the cooldown, returning what the tests read.
func pmRefusedRotation(t *testing.T, name string, walletOurs bool, at int64) (base, wpath string, gw *chainGateway, pA, pB string) {
	t.Helper()
	base, wpath = chainFixture(t)
	gw = newChainGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	pA, pB = "horse battery staple correct", "the second passphrase"
	createVault(base, name, pA)
	kA := profileRefV2(name, pA)
	gw.grants[kA] = 1
	gw.stamped[kA] = true // inside the cooldown: the gateway answers moved 0
	pinPlanMovingClock(t, at)
	if _, err := rotateVault(base, name, pA, pB, nil, walletOurs); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	return
}

func TestPlanMovingRefusedRotationStampsTheRecordAndBillingSaysMoving(t *testing.T) {
	const name, at = "pmovrefused", int64(1_800_000_000)
	base, wpath, _, _, pB := pmRefusedRotation(t, name, true, at)
	dk, _, _ := resolveKey(base, name, pB)
	idx := chainIndexOfHead(t, base, name, pB, dk)
	if got := billPrevAtOf(idx); got != at {
		t.Fatalf("!bill-prev At = %d, want %d", got, at)
	}
	pinPlanMovingClock(t, at+3600)
	if line := billingLine(wpath); !strings.Contains(line, " moving="+strconv.FormatInt(at, 10)) {
		t.Errorf("GET-BILLING %q does not carry moving=%d", line, at)
	}
}

func TestPlanMovingWalletNotOursWritesNoMarker(t *testing.T) {
	const name, at = "pmovnotours", int64(1_800_000_000)
	_, wpath, _, _, _ := pmRefusedRotation(t, name, false, at)
	if _, err := os.Stat(planMovingPath(wpath)); err == nil {
		t.Error("a marker was written beside a wallet that is not this profile's")
	}
	if line := billingLine(wpath); planMovingHasField(line) {
		t.Errorf("GET-BILLING %q says moving for a wallet that is not ours", line)
	}
}

func TestPlanMovingSettledRotationLeavesNeither(t *testing.T) {
	const name = "pmovsettled"
	base, wpath := chainFixture(t)
	gw := newChainGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	const pA, pB = "horse battery staple correct", "the second passphrase"
	createVault(base, name, pA)
	gw.grants[profileRefV2(name, pA)] = 1
	pinPlanMovingClock(t, 1_800_000_000)
	chainRotate(t, base, name, pA, pB)
	dk, _, _ := resolveKey(base, name, pB)
	if billPrevOf(chainIndexOfHead(t, base, name, pB, dk)) != "" {
		t.Error("a settled carry left !bill-prev")
	}
	if _, err := os.Stat(planMovingPath(wpath)); err == nil {
		t.Error("a settled carry left the marker")
	}
	if planMovingHasField(billingLine(wpath)) {
		t.Error("GET-BILLING says moving after a settled carry")
	}
}

func TestPlanMovingSignInRetryThatSettlesRemovesTheMarker(t *testing.T) {
	const name, at = "pmovretry", int64(1_800_000_000)
	base, wpath, gw, _, pB := pmRefusedRotation(t, name, true, at)
	if _, err := os.Stat(planMovingPath(wpath)); err != nil {
		t.Fatalf("fixture bug: no marker after the refused rotation: %v", err)
	}
	dk, _, _ := resolveKey(base, name, pB)
	// still refused, from no marker (removeWallet ran at the sign-in): the retry notes the record's own time.
	removeWallet(wpath)
	if err := saveWallet(wpath, &Wallet{PaidThrough: 1 << 40, PlanGB: 10}); err != nil {
		t.Fatal(err)
	}
	pinPlanMovingClock(t, at+86400)
	retryPlanCarry(base, name, pB, dk, wpath)
	if b, err := os.ReadFile(planMovingPath(wpath)); err != nil || string(b) != strconv.FormatInt(at, 10) {
		t.Fatalf("a still-refused retry left marker %q (%v), want the record's time %d", b, err, at)
	}
	gw.liftCooldown()
	retryPlanCarry(base, name, pB, dk, wpath)
	if _, err := os.Stat(planMovingPath(wpath)); err == nil {
		t.Error("a retry that settled left the marker")
	}
	if billPrevOf(chainIndexOfHead(t, base, name, pB, dk)) != "" {
		t.Error("a retry that settled left !bill-prev")
	}
}

func TestPlanMovingWindowEnds(t *testing.T) {
	const at = int64(1_800_000_000)
	_, wpath := chainFixture(t)
	notePlanMoving(wpath, at)
	end := at + (rebindCooldownEpochs+1)*billingEpochSeconds
	pinPlanMovingClock(t, end-1)
	if !strings.Contains(billingLine(wpath), " moving="+strconv.FormatInt(at, 10)) {
		t.Error("no moving= one second before the window ends")
	}
	pinPlanMovingClock(t, end)
	if planMovingHasField(billingLine(wpath)) {
		t.Error("moving= after the cooldown plus one epoch has passed")
	}
}

func TestPlanMovingGarbageMarker(t *testing.T) {
	_, wpath := chainFixture(t)
	pinPlanMovingClock(t, 1_800_000_000)
	want := billingLine(wpath)
	for _, junk := range []string{"x", "", "-5", "0", "12ab"} {
		if err := os.WriteFile(planMovingPath(wpath), []byte(junk), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := billingLine(wpath); planMovingHasField(got) || got != want {
			t.Errorf("marker %q: GET-BILLING %q, want %q", junk, got, want)
		}
	}
}

func TestPlanMovingNoPlanNoMoving(t *testing.T) {
	_, wpath := chainFixture(t)
	if err := saveWallet(wpath, &Wallet{PaidThrough: 0, PlanGB: 10, BlindTokens: []BlindToken{{}}}); err != nil {
		t.Fatal(err)
	}
	pinPlanMovingClock(t, 1_800_000_000)
	notePlanMoving(wpath, 1_800_000_000-10)
	if line := billingLine(wpath); planMovingHasField(line) {
		t.Errorf("GET-BILLING %q says moving for a wallet with no plan", line)
	}
}

func TestPlanMovingRemoveWalletRemovesTheMarker(t *testing.T) {
	_, wpath := chainFixture(t)
	notePlanMoving(wpath, 1_800_000_000)
	removeWallet(wpath)
	if _, err := os.Stat(planMovingPath(wpath)); err == nil {
		t.Error("removeWallet left the marker")
	}
}

func TestPlanMovingKeptPrevKeepsItsAt(t *testing.T) {
	const name = "pmovkept"
	base, _ := chainFixture(t)
	gw := newChainGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	const pA, pB, pC = "horse battery staple correct", "the second passphrase", "the third one"
	createVault(base, name, pA)
	kA := profileRefV2(name, pA)
	gw.grants[kA] = 1
	gw.stamped[kA] = true
	const t1, t2 = int64(1_800_000_000), int64(1_800_100_000)
	pinPlanMovingClock(t, t1)
	chainRotate(t, base, name, pA, pB)
	pinPlanMovingClock(t, t2)
	chainRotate(t, base, name, pB, pC)
	dk, _, _ := resolveKey(base, name, pC)
	if got := billPrevAtOf(chainIndexOfHead(t, base, name, pC, dk)); got != t1 {
		t.Errorf("a kept !bill-prev has At = %d, want its own %d", got, t1)
	}
}

func TestPlanMovingIndexWithoutFieldRoundTrips(t *testing.T) {
	b, err := json.Marshal(scopeRec{Ref: "r", Wrapped: "w"})
	if err != nil || strings.Contains(string(b), `"at"`) {
		t.Fatalf("a record without a time marshals %s (%v)", b, err)
	}
	var back scopeRec
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if b2, _ := json.Marshal(back); string(b2) != string(b) {
		t.Errorf("round trip changed %s into %s", b, b2)
	}
	if b3, _ := json.Marshal(scopeRec{Ref: "r", At: 5}); !strings.Contains(string(b3), `"at":5`) {
		t.Errorf("a timed record marshals %s", b3)
	}
}

// A change to the same passphrase records the current key as !bill-prev, a record that never settles and moves
// nothing: neither the rotation nor a later sign-in may say the plan is moving.
func TestPlanMovingSamePassphraseIsNotMoving(t *testing.T) {
	const name, at = "pmovsame", int64(1_800_000_000)
	base, wpath := chainFixture(t)
	gw := newChainGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	const pA = "horse battery staple correct"
	createVault(base, name, pA)
	kA := profileRefV2(name, pA)
	gw.grants[kA] = 1
	gw.stamped[kA] = true // the gateway refusing
	pinPlanMovingClock(t, at)
	chainRotate(t, base, name, pA, pA)
	dk, _, _ := resolveKey(base, name, pA)
	if billPrevOf(chainIndexOfHead(t, base, name, pA, dk)) != kA {
		t.Fatal("fixture bug: the A->A change recorded no !bill-prev naming key(A)")
	}
	pinPlanMovingClock(t, at+3600)
	if _, err := os.Stat(planMovingPath(wpath)); err == nil || planMovingHasField(billingLine(wpath)) {
		t.Error("a change to the same passphrase wrote the marker or GET-BILLING says moving=")
	}
	notePlanMoving(wpath, at) // a marker the sign-in retry must remove, not keep
	retryPlanCarry(base, name, pA, dk, wpath)
	if _, err := os.Stat(planMovingPath(wpath)); err == nil || planMovingHasField(billingLine(wpath)) {
		t.Error("the sign-in retry after a change to the same passphrase kept the marker or GET-BILLING says moving=")
	}
}

// A->B moves the plan but its reply is lost (the marker is noted); once the cooldown lifts, B->C settles the carry,
// and that settle at the rotation removes the earlier marker.
func TestPlanMovingSettledRotationClearsAnEarlierMarker(t *testing.T) {
	const name, at = "pmovsettlelater", int64(1_800_000_000)
	base, wpath := chainFixture(t)
	gw := newChainGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	const pA, pB, pC = "horse battery staple correct", "the second passphrase", "the third one"
	kB, kC := profileRefV2(name, pB), profileRefV2(name, pC)
	createVault(base, name, pA)
	gw.grants[profileRefV2(name, pA)] = 1
	gw.dropNext = true // A->B moves, then the reply is lost
	pinPlanMovingClock(t, at)
	chainRotate(t, base, name, pA, pB)
	if gw.at(kB) != 1 {
		t.Fatal("fixture bug: the A->B move did not happen at the gateway")
	}
	if _, err := os.Stat(planMovingPath(wpath)); err != nil {
		t.Fatalf("fixture bug: no marker after the A->B change whose reply was lost: %v", err)
	}
	gw.liftCooldown()
	pinPlanMovingClock(t, at+3600)
	chainRotate(t, base, name, pB, pC)
	if gw.at(kC) != 1 {
		t.Fatal("fixture bug: B->C did not move the plan")
	}
	if _, err := os.Stat(planMovingPath(wpath)); err == nil {
		t.Error("a rotation that settled the carry left the earlier marker")
	}
	if planMovingHasField(billingLine(wpath)) {
		t.Error("GET-BILLING says moving after a rotation that settled the carry")
	}
}

// A->B moves the plan but its reply is lost, then B->A inside the cooldown is refused. !bill-prev names key(A), the
// key the profile is back on, but !bill-mid names key(B), where the plan sits: still moving, at the rotation and at
// the sign-in after it.
func TestPlanMovingChangeBackWithAMidKeyStaysMoving(t *testing.T) {
	const name, at = "pmovback", int64(1_800_000_000)
	base, wpath := chainFixture(t)
	gw := newChainGateway(t)
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	const pA, pB = "horse battery staple correct", "the second passphrase"
	kA, kB := profileRefV2(name, pA), profileRefV2(name, pB)
	createVault(base, name, pA)
	gw.grants[kA] = 1
	gw.dropNext = true // A->B moves, then the reply is lost
	pinPlanMovingClock(t, at)
	chainRotate(t, base, name, pA, pB)
	pinPlanMovingClock(t, at+3600)
	chainRotate(t, base, name, pB, pA) // refused: the grant at key(B) moved inside the cooldown
	dk, _, _ := resolveKey(base, name, pA)
	idx := chainIndexOfHead(t, base, name, pA, dk)
	if mid := billMidOf(idx); gw.at(kB) != 1 || billPrevOf(idx) != kA || len(mid) != 1 || mid[0] != kB {
		t.Fatalf("fixture bug: %d grant(s) at key(B), prev=%s mid=%v, want 1, key(A), [key(B)]",
			gw.at(kB), short(billPrevOf(idx)), mid)
	}
	want := strconv.FormatInt(at, 10)
	if b, err := os.ReadFile(planMovingPath(wpath)); err != nil || string(b) != want {
		t.Errorf("the refused change back left marker %q (%v), want the record's time %s", b, err, want)
	}
	if line := billingLine(wpath); !strings.Contains(line, " moving="+want) {
		t.Errorf("GET-BILLING %q does not carry moving=%s after the refused change back", line, want)
	}
	// The sign-in under A: removeWallet ran, the retry is still refused, and it must note the record's time again.
	removeWallet(wpath)
	if err := saveWallet(wpath, &Wallet{PaidThrough: 1 << 40, PlanGB: 10}); err != nil {
		t.Fatal(err)
	}
	retryPlanCarry(base, name, pA, dk, wpath)
	if b, err := os.ReadFile(planMovingPath(wpath)); err != nil || string(b) != want {
		t.Errorf("the still-refused sign-in retry left marker %q (%v), want the record's time %s", b, err, want)
	}
}

// A->B is refused by the cooldown, then B->B. The record still names key(A), which holds the plan, so the change to
// the same passphrase keeps the marker the refused change wrote. A rotation that ruled out old == new instead of
// reading the record would wipe it.
func TestPlanMovingSamePassphraseAfterARefusedChangeStaysMoving(t *testing.T) {
	const name, at = "pmovsameafter", int64(1_800_000_000)
	base, wpath, _, pA, pB := pmRefusedRotation(t, name, true, at)
	pinPlanMovingClock(t, at+3600)
	chainRotate(t, base, name, pB, pB)
	dk, _, _ := resolveKey(base, name, pB)
	if got := billPrevOf(chainIndexOfHead(t, base, name, pB, dk)); got != profileRefV2(name, pA) {
		t.Fatalf("fixture bug: !bill-prev = %s after B->B, want key(A)", short(got))
	}
	want := strconv.FormatInt(at, 10)
	if b, err := os.ReadFile(planMovingPath(wpath)); err != nil || string(b) != want {
		t.Errorf("the change to the same passphrase left marker %q (%v), want the refused change's %s", b, err, want)
	}
	if line := billingLine(wpath); !strings.Contains(line, " moving="+want) {
		t.Errorf("GET-BILLING %q does not carry moving=%s after the change to the same passphrase", line, want)
	}
}
