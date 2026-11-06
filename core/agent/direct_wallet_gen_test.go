package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261128-22: on a self-hosted store sealWallet judged the wallet's generation at entry, waited for the
// bracket, and then read the file with no lock and no generation check. A sign-in in that wait replaced the file
// with the arriving profile's wallet, so its bearer tokens were published at the departed profile's #wallet head.

// dwgTokens is a pair of blind tokens unique to tag, so a check for one profile's tokens at another's head means
// something (newBlindTokens is the same pair for every profile).
func dwgTokens(tag string) []BlindToken {
	return []BlindToken{{Msg: tag + "-m1", Sig: tag + "-s1"}, {Msg: tag + "-m2", Sig: tag + "-s2"}}
}

// dwgHas reports whether w holds a blind token whose Msg is msg.
func dwgHas(w *Wallet, msg string) bool {
	if w == nil {
		return false
	}
	for _, t := range w.BlindTokens {
		if t.Msg == msg {
			return true
		}
	}
	return false
}

// dwgSealWhileHeld runs sealWallet while another bracket is open. signIn (when not nil) runs once sealWallet is
// waiting on that bracket, before the bracket is released.
func dwgSealWhileHeld(t *testing.T, base, name, pass, wp string, signIn func()) (string, error) {
	t.Helper()
	release, _, _ := directBracketHold(t, name+"-a", pass+" a")
	waits := bracketWaits()
	var h string
	var err error
	done := make(chan struct{})
	go func() {
		defer close(done)
		h, err = sealWallet(base, name, pass, deriveKey(name, pass), wp)
	}()
	if directBracketOrdered(t, "sealWallet", waits, done) && signIn != nil {
		signIn()
	}
	release()
	directBracketJoin(t, "sealWallet", done)
	return h, err
}

func TestDirectWalletGen_ASignInWhileItWaitsIsNotPublished(t *testing.T) {
	directBracketEnv(t)
	base := newHTTPStore(t)
	const name1, pass1 = "dwg1", "pass of dwg1"
	wp := directBracketWallet(t)
	var p2Bytes []byte
	h, err := dwgSealWhileHeld(t, base, name1, pass1, wp, func() {
		// profile P2 signs in, as the real sign-in does it: the departed wallet goes, P2's restore lands and proves.
		removeWallet(wp)
		if err := appendTokens(wp, dwgTokens("p2")); err != nil {
			t.Fatal(err)
		}
		if err := markWalletRestoreLanded(wp, walletGeneration(wp)); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(wp)
		if err != nil {
			t.Fatal(err)
		}
		p2Bytes = b
	})
	if !errors.Is(err, errWalletChangedHands) {
		t.Errorf("sealWallet after a sign-in in its bracket wait = %q, %v; want errWalletChangedHands (NWP-20261128-22)", h, err)
	}
	if h != "" {
		t.Errorf("sealWallet returned a head %q for a wallet that changed hands", h)
	}
	if getRef(base, profileRefV2(name1+"#wallet", pass1)) != "" {
		t.Error("P1's #wallet head was published after P2 signed in during the wait (NWP-20261128-22)")
	}
	stored := readStoredWallet(base, name1, pass1, deriveKey(name1, pass1))
	for _, tok := range dwgTokens("p2") {
		if dwgHas(stored, tok.Msg) {
			t.Errorf("P1's stored wallet holds P2's token %q (NWP-20261128-22)", tok.Msg)
		}
	}
	now, rerr := os.ReadFile(wp)
	if rerr != nil || !bytes.Equal(now, p2Bytes) {
		t.Errorf("P2's wallet file changed: %q (%v), want %q", now, rerr, p2Bytes)
	}
}

func TestDirectWalletGen_AnUnchangedWalletStillPublishes(t *testing.T) {
	directBracketEnv(t)
	base := newHTTPStore(t)
	const name2, pass2 = "dwg2", "pass of dwg2"
	wp := directBracketWallet(t)
	h, err := dwgSealWhileHeld(t, base, name2, pass2, wp, nil)
	if err != nil || h == "" {
		t.Fatalf("sealWallet with no sign-in in its wait = %q, %v; want a head and no error", h, err)
	}
	if getRef(base, profileRefV2(name2+"#wallet", pass2)) == "" {
		t.Error("the #wallet head was not published")
	}
	stored := readStoredWallet(base, name2, pass2, deriveKey(name2, pass2))
	if stored == nil || len(stored.BlindTokens) != 2 || !dwgHas(stored, "m1") || !dwgHas(stored, "m2") {
		t.Errorf("the stored wallet = %+v, want exactly the tokens m1 and m2", stored)
	}
}

func TestDirectWalletGen_MergesTheStoredCopyBySeen(t *testing.T) {
	directBracketEnv(t)
	base := newHTTPStore(t)
	const name3, pass3 = "dwg3", "pass of dwg3"
	dk3 := deriveKey(name3, pass3)
	wp1 := directBracketWallet(t) // the session: m1, m2
	if _, err := sealWallet(base, name3, pass3, dk3, wp1); err != nil {
		t.Fatalf("the session's first publish: %v", err)
	}
	// Another handset of the same profile holds the session's tokens plus Y, and publishes them.
	y := dwgTokens("y")[0]
	wp2 := filepath.Join(t.TempDir(), "wallet.json")
	if err := appendTokens(wp2, append(newBlindTokens(), y)); err != nil {
		t.Fatal(err)
	}
	if err := markWalletRestoreLanded(wp2, walletGeneration(wp2)); err != nil {
		t.Fatal(err)
	}
	if _, err := sealWallet(base, name3, pass3, dk3, wp2); err != nil {
		t.Fatalf("the other handset's publish: %v", err)
	}
	if st := readStoredWallet(base, name3, pass3, dk3); !dwgHas(st, "m1") || !dwgHas(st, y.Msg) {
		t.Fatalf("precondition: the stored wallet = %+v, want m1 and %s", st, y.Msg)
	}
	// The session spends X = m1: gone from its file, still in its seen-set.
	w, err := loadWallet(wp1)
	if err != nil {
		t.Fatal(err)
	}
	var kept []BlindToken
	var x BlindToken
	for _, tok := range w.BlindTokens {
		if tok.Msg == "m1" {
			x = tok
			continue
		}
		kept = append(kept, tok)
	}
	w.BlindTokens = kept
	if err := saveWallet(wp1, w); err != nil {
		t.Fatal(err)
	}
	xKey := walletTokenKeys(&Wallet{BlindTokens: []BlindToken{x}})[0]
	if !walletSeen(wp1, walletGeneration(wp1))[xKey] {
		t.Fatalf("precondition: the spent token m1 is not in the session's seen-set")
	}
	if _, err := sealWallet(base, name3, pass3, dk3, wp1); err != nil {
		t.Fatalf("the session's publish after the spend: %v", err)
	}
	st := readStoredWallet(base, name3, pass3, dk3)
	if !dwgHas(st, y.Msg) {
		t.Errorf("the other handset's token %s was dropped: the stored copy was not merged by the seen-set (NWP-20261128-22): %+v", y.Msg, st)
	}
	if dwgHas(st, "m1") {
		t.Errorf("the spent token m1 came back from the stored copy: %+v", st)
	}
	if !dwgHas(st, "m2") {
		t.Errorf("the session's unspent token m2 is missing: %+v", st)
	}
}
