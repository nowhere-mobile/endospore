package main

// NWP-20260917-16: the three defects in NWP-20260917-07's carry record, found by the pre-flash review of
// the build that was about to ship them.
//
// ⚠ WHY THE ORIGINAL TESTS MISSED ALL OF THIS, which is the part worth keeping. Every test in
// plan_retry_test.go builds its store with newHTTPStore(t), so isS3(base) is false and postBlob's CAP arm
// never executes. Cap mode -- GATEWAY_URL set, no store creds -- is not an edge case here: it is the whole
// fielded fleet. A feature whose stop-condition only runs on managed devices was covered exclusively by a
// harness in which managed devices do not exist.

import (
	"path/filepath"
	"testing"
)

// TestClearingTheCarryRecordWorksInCapMode is defect A, and it is the one that made the feature inert.
//
// retryPlanCarry ended with a bare putHead(postBlob(...)). In cap mode postBlob BUFFERS, and outside a
// capBegin/capFlush bracket it calls fail(), which panics -- swallowed by retryPlanCarry's own recover and
// again by handleRoamIn's. So the record was never cleared, on every managed device, and nothing said so.
// migrateVault had the identical defect and its fix (capWrite) is eleven lines from the call site.
//
// Rule 2 is the arm under test because it is the COMMON one: repointScopes records !bill-prev on any
// credential change whose index already had !bill, whether or not a plan was ever bought.
func TestClearingTheCarryRecordWorksInCapMode(t *testing.T) {
	dest := capRotateFixture(t)
	const name, p1, p2 = "capclear", "horse battery staple correct", "a brand new passphrase"
	createVault("s3", name, p1)
	if _, err := rotateVault("s3", name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	dk, _, ok := resolveKey("s3", name, p2)
	if !ok {
		t.Fatal("the rotated vault does not resolve")
	}
	if got := billPrevOfHead(t, "s3", name, p2, dk); got == "" {
		t.Fatal("fixture bug: no !bill-prev was recorded, so this proves nothing about clearing it")
	}

	// No wallet file at all -> loadWallet errors -> rule 2 -> "no plan in the wallet -- dropping the record".
	retryPlanCarry("s3", name, p2, dk, filepath.Join(dest, "no-such-wallet.json"))

	if got := billPrevOfHead(t, "s3", name, p2, dk); got != "" {
		t.Errorf("!bill-prev is still %s after rule 2 decided to drop it. In cap mode the clearing write "+
			"panics outside a capBegin/capFlush bracket and both recovers swallow it, so the record survives "+
			"on every managed device while the log claims it was dropped -- and every later login repeats "+
			"the whole thing", short(got))
	}
}

// TestASettledCarryClearsItsOwnRecord is defect B.
//
// repointScopes writes !bill-prev BEFORE the carry is attempted -- it must, because the index is sealed
// into the very head the rotation publishes. So a carry that SUCCEEDS still leaves the record behind, and
// the login retry cannot finish the job: it asks the gateway, which answers {"moved":0} because the grant
// is already at the new key, and 0 is deliberately ambiguous between that, a cooldown and an unknown
// profile so a leaked key cannot learn a plan exists. Unsettled forever -> a /rebind on every login.
func TestASettledCarryClearsItsOwnRecord(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	gw := newRebindGateway(t) // moved = 1: the carry settles
	t.Setenv("GATEWAY_URL", gw.srv.URL)

	const name, p1, p2 = "settled", "horse battery staple correct", "a brand new passphrase"
	createVault(base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if olds, _ := gw.calls(); len(olds) != 1 {
		t.Fatalf("/rebind was called %d time(s), want 1 -- the carry did not run", len(olds))
	}
	dk, _, ok := resolveKey(base, name, p2)
	if !ok {
		t.Fatal("the rotated vault does not resolve")
	}
	if got := billPrevOfHead(t, base, name, p2, dk); got != "" {
		t.Errorf("!bill-prev is %s after a carry the gateway CONFIRMED. The record means \"a carry is still "+
			"owed\", so leaving it after a successful one makes every later login re-send the same /rebind "+
			"forever -- the unbounded retry this feature has three rules to prevent", short(got))
	}
}

// TestAnUnsettledRecordSurvivesASecondCredentialChange is defect C, and it is the one that loses money.
//
// The record was set from billKeyOf(idx) -- idx[!bill], the key of the change that just happened -- not
// from billPrevOf(idx), where a key whose carry has NOT settled lives. `next` is a fresh map, so a second
// credential change REPLACED an outstanding record with a key that never held the plan, and the grant was
// left at an address nothing in the tree could still name. The comment above that line claimed the
// opposite, in those words, before the code did it.
func TestAnUnsettledRecordSurvivesASecondCredentialChange(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "") // no gateway -> the carry can never settle -> the record stays owed

	const name, pA, pB, pC = "strand", "horse battery staple correct", "the second passphrase", "the third one"
	createVault(base, name, pA)
	if _, err := rotateVault(base, name, pA, pB, nil, true); err != nil {
		t.Fatalf("rotateVault A->B: %v", err)
	}
	if _, err := rotateVault(base, name, pB, pC, nil, true); err != nil {
		t.Fatalf("rotateVault B->C: %v", err)
	}
	dk, _, ok := resolveKey(base, name, pC)
	if !ok {
		t.Fatal("the twice-rotated vault does not resolve")
	}
	got := billPrevOfHead(t, base, name, pC, dk)
	if got == profileRefV2(name, pB) {
		t.Errorf("!bill-prev names key(B), which NEVER held the plan. The plan is still at key(A) and " +
			"nothing in the tree can name key(A) any more -- a paid plan stranded at an address the device " +
			"cannot produce, silently. This is the exact loss the record exists to prevent")
	}
	if got != profileRefV2(name, pA) {
		t.Errorf("!bill-prev = %s, want key(A) = %s -- the only key that can still hold a live grant",
			short(got), short(profileRefV2(name, pA)))
	}
}

// billPrevOfHead reads the outstanding carry record straight from the published head, so a test cannot pass
// by inspecting a value that was never sealed.
func billPrevOfHead(t *testing.T, base, name, pass string, dk []byte) string {
	t.Helper()
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV || v == nil {
		t.Fatal("no vault at the published head")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the scope index does not open")
	}
	return billPrevOf(idx)
}
