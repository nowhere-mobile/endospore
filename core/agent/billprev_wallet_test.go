package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261114-07: dropBillPrev bracketed its vault edit with capWrite, so its flush counted wallet.json as this
// profile's. recoverVault runs it at the gate with no sign-in, and rotateVaultOnce runs it with walletOurs false, so
// the file can be a departed profile's: the flush could present its tokens and fold it into this profile's #wallet
// head. It now brackets walletNotOurs, as dropBillRetag does. test-recovery-ref-arm.sh M8 puts capWrite back; M9
// makes the same edit to dropBillRetag's bracket, the control that M8's anchor picks the right call.

// bpwPlantStranger writes a plan-pending wallet with a landed restore proof at a new path, points NOWHERE_WALLET at
// it and returns its bytes: the file a departed profile's sign-out keeps when the store is down.
func bpwPlantStranger(t *testing.T) (string, []byte) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", path)
	toks, err := newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).buyFaucet(8)
	if err != nil {
		t.Fatal(err)
	}
	w := &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}
	if !w.planPending() {
		t.Fatal("precondition: the stranger wallet is not plan-pending, so the free probe would cover the flush")
	}
	if err := saveWallet(path, w); err != nil {
		t.Fatal(err)
	}
	if err := markWalletRestoreLanded(path, walletGeneration(path)); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return path, b
}

func TestRecoveryRefArm_BillDropPrevNeverFoldsAStrangersWallet(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "bpwrecover", "a plan carry clear at the gate"
	dk := billDropPrevProfile(t, name, pass)
	path, before := bpwPlantStranger(t)

	walletHead := getRef("s3", walletHeadKey("s3", name, pass))
	capStoreTokensPresented = 0
	if !dropBillPrev("s3", name, pass, dk) {
		t.Fatal("the carry clear did not clear")
	}
	if capStoreTokensPresented != 0 {
		t.Errorf("THE PLAN-CARRY CLEAR PRESENTED %d TOKEN(S) FROM A WALLET THAT IS NOT ITS OWN: the profile that "+
			"paid for them re-presents them later and is refused forever", capStoreTokensPresented)
	}
	if got := getRef("s3", walletHeadKey("s3", name, pass)); got != walletHead {
		t.Errorf("the plan-carry clear moved this profile's #wallet head (%s -> %s): it sealed another profile's "+
			"wallet under this profile's key", short(walletHead), short(got))
	}
	if after, err := os.ReadFile(path); err != nil || !bytes.Equal(after, before) {
		t.Errorf("the plan-carry clear changed the stranger's wallet file (err %v)", err)
	}
	v, isV := openVaultHead("s3", name, pass)
	if !isV || v == nil {
		t.Fatal("the head is not a vault after the clear")
	}
	if idx, ok := openScopeIndex(dk, v.Scopes); !ok || billPrevOf(idx) != "" {
		t.Error("the record is still in the head's index, so the bracket did not flush")
	}
}
