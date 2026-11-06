package main

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

// NWP-20261128-13: the by-value publisher (sealWalletValueDurable: the sign-out, payRent's spend, a create's staged
// claim) merges the stored copy by the Q107 rule (NWP-20261031-01): this phone's tokens plus the stored copy's minus
// every token this session has held. Handset A signs in on walletFailSetup's store and spends a restored token X;
// handset B, signed in to the same profile, publishes the stored wallet plus a token Y that A never held. A's
// by-value publish must keep Y and leave X out. Every assertion reads the STORE, never a log line.

func signOutMergeY() BlindToken { return BlindToken{Msg: "handset-b-y", Sig: "sig-y"} }

// signOutMergeStore builds that store state and returns X's nonce and the 12 keys the store must hold after A
// publishes: A's 11 (9 restored plain tokens, the 2 appended blind ones) and Y.
func signOutMergeStore(t *testing.T, f *walletFailFixture) (x string, want []string) {
	t.Helper()
	f.session(t) // 10 restored plain tokens, 2 appended blind ones
	w, err := loadWallet(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	if len(w.Tokens) == 0 {
		t.Fatal("fixture: the session restored no plain token")
	}
	x = w.Tokens[0].Nonce // A spends X: the seen-set keeps it
	w.Tokens = w.Tokens[1:]
	if err := saveWallet(f.wpath, w); err != nil {
		t.Fatal(err)
	}
	for k := range twoWriterNonces(w) {
		want = append(want, k)
	}
	if len(want) != 11 {
		t.Fatalf("fixture: A's wallet holds %d tokens after the spend, want 11", len(want))
	}

	// Handset B: its own state dir, its restore proven, and NOWHERE_WALLET pointed at it for its publish, because
	// capFlush folds capWalletPath().
	wb := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wb)
	sw := storedWallet(t, walletFailName, walletFailPass)
	if sw == nil {
		t.Fatal("fixture: no stored wallet before handset B publishes")
	}
	bw := *sw
	bw.BlindTokens = append(append([]BlindToken(nil), sw.BlindTokens...), signOutMergeY())
	if err := saveWallet(wb, &bw); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_WALLET", wb)
	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, wb); err != nil {
		t.Fatalf("handset B's publish: %v", err)
	}
	t.Setenv("NOWHERE_WALLET", f.wpath)

	y := blindSeenKey(signOutMergeY())
	got := signOutMergeStored(t)
	if !got[x] || !got[y] {
		t.Fatalf("control: before A publishes the stored wallet must hold X (%v) and Y (%v)", got[x], got[y])
	}
	return x, append(want, y)
}

func signOutMergeStored(t *testing.T) map[string]bool {
	t.Helper()
	sw := storedWallet(t, walletFailName, walletFailPass)
	if sw == nil {
		t.Fatal("no stored wallet")
	}
	return twoWriterNonces(sw)
}

// signOutMergeAssert: the store holds exactly the 12 keys of want, and not x.
func signOutMergeAssert(t *testing.T, x string, want []string) {
	t.Helper()
	got := signOutMergeStored(t)
	for _, k := range want {
		if !got[k] {
			t.Errorf("the stored wallet lost %s", k)
		}
	}
	if got[x] {
		t.Errorf("the stored wallet holds %s, the token this session spent", x)
	}
	if len(got) != len(want) {
		t.Errorf("the stored wallet holds %d tokens, want %d", len(got), len(want))
	}
}

// The sign-out (sealLogoutWalletAndDrop) publishes by value: B's Y stays, A's spent X stays out.
func TestSignOutWalletMerge_KeepsTheOtherHandsetsTokensAndLeavesASpentOneOut(t *testing.T) {
	f := walletFailSetup(t)
	x, want := signOutMergeStore(t, f)
	dropped, err, log := f.logoutStep(t, f.gen())
	if err != nil || !dropped {
		t.Fatalf("dropped=%v err=%v; stderr:\n%s", dropped, err, log)
	}
	signOutMergeAssert(t, x, want)
}

// payRent's spend publishes by value through the same call, with the copy taken under the wallet lock as
// payRentGenRule takes it and the lock released before the publish (its bracket's capFlush takes it).
func TestSignOutWalletMerge_PayRentsByValuePublishMergesToo(t *testing.T) {
	f := walletFailSetup(t)
	x, want := signOutMergeStore(t, f)
	unlock := lockWallet(f.wpath)
	w, err := loadWallet(f.wpath)
	if err != nil {
		unlock()
		t.Fatal(err)
	}
	gen := walletGeneration(f.wpath)
	basis, _ := json.Marshal(w)
	proven := walletRestoreLanded(f.wpath, gen)
	unlock()
	if !proven {
		t.Fatal("control: the session's generation has no restore proof")
	}
	if _, err := sealWalletValueDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath, w, basis, gen, true); err != nil {
		t.Fatalf("sealWalletValueDurable: %v", err)
	}
	signOutMergeAssert(t, x, want)
}
