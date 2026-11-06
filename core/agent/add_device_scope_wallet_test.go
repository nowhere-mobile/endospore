package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261114-03: ADD-DEVICE is a gate verb with no session. Its scope-slot bracket (addScopeSlotsAfterEnrol) must run
// no-login, as hardenVaultTo's does: a departed profile's kept wallet.json is not this profile's to fold or to spend.

// adswTiedProfile builds, in cap mode, a profile tied to tieSE1 whose #de scope the tie re-keyed (a Minted index
// entry), and returns its recovery code. The setup writes are paid from a wallet of the profile's own.
func adswTiedProfile(t *testing.T, srvURL, name, pass string) string {
	t.Helper()
	own := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", own)
	toks, err := newGatewayClient(srvURL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(own, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	mnemonic := sealScopeFixture(t, "s3", name, pass)
	if err := sessionTie("s3", name, pass, tieSE1); err != nil {
		t.Fatalf("sessionTie: %v", err)
	}
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	dk := unwrapDK(v, "se", kekSE(name, pass, tieSE1))
	if dk == nil {
		t.Fatal("precondition: the first phone's chip does not open the tied vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	minted := false
	for _, rec := range idx {
		minted = minted || rec.Minted
	}
	if !ok || !minted {
		t.Fatal("precondition: the tie re-keyed no scope, so addScopeSlotsAfterEnrol never opens its bracket")
	}
	return mnemonic
}

// adswPlantStranger leaves a departed profile's wallet in the boot-lifetime state: plan-pending, so the lease ladder
// takes the entitled path that presents tokens, and with its restore proof standing, so the fold does not skip it.
func adswPlantStranger(t *testing.T, srvURL string) string {
	t.Helper()
	stranger := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", stranger)
	toks, err := newGatewayClient(srvURL, gwDefault).buyFaucet(8)
	if err != nil {
		t.Fatal(err)
	}
	w := &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}
	if !w.planPending() {
		t.Fatal("precondition: the stranger wallet is not plan-pending, so the free probe would cover the flush")
	}
	if err := saveWallet(stranger, w); err != nil {
		t.Fatal(err)
	}
	if err := markWalletRestoreLanded(stranger, walletGeneration(stranger)); err != nil {
		t.Fatalf("precondition: the stranger's restore proof was not written: %v", err)
	}
	return stranger
}

func TestAddDeviceScopeSlots_NeverFoldsAStrangersWallet(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()

	const name, pass = "adswscope", "horse battery staple correct"
	mnemonic := adswTiedProfile(t, srv.URL, name, pass)
	walletHead := getRef("s3", walletHeadKey("s3", name, pass))

	stranger := adswPlantStranger(t, srv.URL)
	before, err := os.ReadFile(stranger)
	if err != nil {
		t.Fatal(err)
	}

	capStoreTokensPresented = 0
	if err := enrollSEViaRecovery("s3", name, mnemonic, pass, tieSE2); err != nil {
		t.Fatalf("enrollSEViaRecovery: %v", err)
	}

	if capStoreTokensPresented != 0 {
		t.Errorf("ADD-DEVICE PRESENTED %d TOKEN(S) FROM A STRANGER'S WALLET. The gateway's spent set is keyed on the "+
			"nonce alone, so the owner is refused permanently.", capStoreTokensPresented)
	}
	if got := getRef("s3", walletHeadKey("s3", name, pass)); got != walletHead {
		t.Errorf("ADD-DEVICE FOLDED A STRANGER'S WALLET INTO THIS PROFILE'S #wallet HEAD (%s, want %s). The same "+
			"bearer tokens now live in two accounts.", short(got), short(walletHead))
	}
	if after, err := os.ReadFile(stranger); err != nil || !bytes.Equal(before, after) {
		t.Errorf("ADD-DEVICE REWROTE A WALLET THAT IS NOT ITS OWN (read error %v).", err)
	}
	if _, ok := readScopeFile(t, "s3", name+"#de", pass, tieSE2); !ok {
		t.Error("the added phone does not open #de: the scope-slot bracket did not run, so this test proves nothing")
	}
}
