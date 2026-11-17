package main

// NWP-20261202-40 (decided 2026-11-05, harvest 59 #10): the gate's lost-credit notice fires only for a token the
// session's own sign-in did not restore, read from the tmpfs record of the restored token keys (wallet.json.restored,
// wallet_restored.go). test-restored-credit.sh --mutate convicts M1-M12 against these.

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// rscBlind is n distinct blind tokens whose messages start with prefix (never hcBlind's).
func rscBlind(prefix string, n int) []BlindToken {
	b := make([]BlindToken, n)
	for i := range b {
		b[i] = BlindToken{Msg: prefix + "-m" + strconv.Itoa(i), Sig: prefix + "-s" + strconv.Itoa(i)}
	}
	return b
}

// rscLand lands w as the stored wallet of a sign-in at dest: a new generation, then writeRestoredWallet's no-file
// (fresh) branch. It returns the wallet path.
func rscLand(t *testing.T, dest string, w *Wallet) string {
	t.Helper()
	wp := walletPathFor(dest)
	if err := bumpWalletGeneration(wp); err != nil {
		t.Fatal(err)
	}
	pt, err := json.Marshal(w)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeRestoredWallet(wp, walletGeneration(wp), pt, nil); err != nil {
		t.Fatalf("writeRestoredWallet: %v", err)
	}
	return wp
}

// rscDrop saves the wallet at wp without the blind tokens whose messages are in msgs.
func rscDrop(t *testing.T, wp string, msgs ...string) {
	t.Helper()
	w, err := loadWallet(wp)
	if err != nil {
		t.Fatal(err)
	}
	drop := map[string]bool{}
	for _, m := range msgs {
		drop[m] = true
	}
	var keep []BlindToken
	for _, b := range w.BlindTokens {
		if !drop[b.Msg] {
			keep = append(keep, b)
		}
	}
	if len(keep) != len(w.BlindTokens)-len(msgs) {
		t.Fatalf("the wallet held %d of the %d tokens to drop", len(w.BlindTokens)-len(keep), len(msgs))
	}
	w.BlindTokens = keep
	if err := saveWallet(wp, w); err != nil {
		t.Fatal(err)
	}
}

// R1: a session that restored tokens and added none, whose no-keep sign-out failed to save, is not told credit was
// lost: the stored copy still holds every token.
func TestRestoredCredit_RestoredOnlyIsNotToldLost(t *testing.T) {
	uids := hcNoKeepSetup(t)
	dest := t.TempDir()
	rscLand(t, dest, &Wallet{BlindTokens: hcBlind(3)})
	hcSignOut(dest, "41")
	if len(*uids) != 1 || (*uids)[0] != "41" {
		t.Fatalf("the reap saw %q, want [41]: the sign-out did not run its whole path", *uids)
	}
	if _, err := os.Stat(creditLostPath(dest)); !os.IsNotExist(err) {
		t.Errorf("a session holding only restored tokens recorded the lost-credit notice (stat err %v)", err)
	}
	if got := creditLostReply(dest); got != "NONE" {
		t.Errorf("GET-CREDIT-LOST = %q after a restored-only sign-out, want NONE", got)
	}
}

// R2: a token the session added (a claim) is lost with the publish, so the gate is told.
func TestRestoredCredit_AnAddedTokenIsToldLost(t *testing.T) {
	uids := hcNoKeepSetup(t)
	dest := t.TempDir()
	wp := rscLand(t, dest, &Wallet{BlindTokens: hcBlind(3)})
	if walletHoldsUnrestoredCredit(wp) {
		t.Fatal("right after the landing the wallet holds unrestored credit: the restored tokens were not recorded")
	}
	w, err := loadWallet(wp)
	if err != nil {
		t.Fatal(err)
	}
	w.BlindTokens = append(w.BlindTokens, rscBlind("rc-add", 1)...)
	if err := saveWallet(wp, w); err != nil {
		t.Fatal(err)
	}
	hcSignOut(dest, "42")
	if len(*uids) != 1 || (*uids)[0] != "42" {
		t.Fatalf("the reap saw %q, want [42]: the sign-out did not run its whole path", *uids)
	}
	if _, err := os.Stat(creditLostPath(dest)); err != nil {
		t.Errorf("an added token's sign-out recorded no lost-credit notice (stat err %v)", err)
	}
	if got := creditLostReply(dest); !strings.HasPrefix(got, "NOTICE ") {
		t.Errorf("GET-CREDIT-LOST = %q after an added token's sign-out, want NOTICE <time>", got)
	}
}

// R3a: a late landing that merges into a claim's file records the stored tokens, not the claimed one.
func TestRestoredCredit_ALateMergeRecordsTheStoredTokens(t *testing.T) {
	wp := walletPathFor(t.TempDir())
	if err := bumpWalletGeneration(wp); err != nil {
		t.Fatal(err)
	}
	claimed := rscBlind("rc-claim", 1)
	if err := saveWallet(wp, &Wallet{BlindTokens: claimed}); err != nil {
		t.Fatal(err)
	}
	pt, err := json.Marshal(&Wallet{BlindTokens: hcBlind(3)})
	if err != nil {
		t.Fatal(err)
	}
	if err := writeRestoredWallet(wp, walletGeneration(wp), pt, nil); err != nil {
		t.Fatalf("writeRestoredWallet (merge): %v", err)
	}
	if w, _ := loadWallet(wp); w == nil || len(w.BlindTokens) != 4 {
		t.Fatalf("the merge did not land the 3 stored tokens beside the claimed one: %+v", w)
	}
	if !walletHoldsUnrestoredCredit(wp) {
		t.Error("the claimed token is held and the predicate says no unrestored credit")
	}
	rscDrop(t, wp, claimed[0].Msg)
	if walletHoldsUnrestoredCredit(wp) {
		t.Error("only the merged stored tokens are held and the predicate says unrestored credit")
	}
}

// R3b: the locked retry's merge records the stored tokens, not the two the session claimed.
func TestRestoredCredit_ALockedRetryRecordsTheStoredTokens(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	if err := retryWalletRestoreWithin("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen(), time.Second); err != nil {
		t.Fatalf("retryWalletRestoreWithin: %v", err)
	}
	if !walletHoldsUnrestoredCredit(f.wpath) {
		t.Error("the two claimed tokens are held and the predicate says no unrestored credit")
	}
	var msgs []string
	for _, b := range newBlindTokens() {
		msgs = append(msgs, b.Msg)
	}
	rscDrop(t, f.wpath, msgs...)
	if w, _ := loadWallet(f.wpath); w == nil || len(w.Tokens) != f.stored {
		t.Fatalf("the retry did not merge the %d stored tokens: %+v", f.stored, w)
	}
	if walletHoldsUnrestoredCredit(f.wpath) {
		t.Error("only the retried stored tokens are held and the predicate says unrestored credit")
	}
}

// R4: a record the predicate cannot use counts as empty (today's answer); with a record and no wallet file there is no
// credit.
func TestRestoredCredit_ARecordItCannotUseCountsEveryToken(t *testing.T) {
	t.Run("other_generation", func(t *testing.T) {
		wp := rscLand(t, t.TempDir(), &Wallet{BlindTokens: hcBlind(3)})
		w, err := loadWallet(wp)
		if err != nil {
			t.Fatal(err)
		}
		rec := "another-gen\n" + strings.Join(walletTokenKeys(w), "\n") + "\n"
		if err := os.WriteFile(walletRestoredPath(wp), []byte(rec), 0o600); err != nil {
			t.Fatal(err)
		}
		if !walletHoldsUnrestoredCredit(wp) {
			t.Error("a record of another generation listing every token was believed")
		}
	})
	t.Run("directory", func(t *testing.T) {
		wp := walletPathFor(t.TempDir())
		if err := bumpWalletGeneration(wp); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(walletRestoredPath(wp), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := saveWallet(wp, &Wallet{BlindTokens: hcBlind(1)}); err != nil {
			t.Fatal(err)
		}
		if !walletHoldsUnrestoredCredit(wp) {
			t.Error("a directory at the record's path hid a held token")
		}
	})
	t.Run("unparsable_wallet", func(t *testing.T) {
		wp := rscLand(t, t.TempDir(), &Wallet{BlindTokens: hcBlind(3)})
		if err := os.WriteFile(wp, []byte("{"), 0o600); err != nil {
			t.Fatal(err)
		}
		if !walletHoldsUnrestoredCredit(wp) {
			t.Error("a wallet file that cannot be read counts as holding no credit")
		}
	})
	t.Run("no_wallet_file", func(t *testing.T) {
		wp := rscLand(t, t.TempDir(), &Wallet{BlindTokens: hcBlind(3)})
		if err := os.Remove(wp); err != nil {
			t.Fatal(err)
		}
		if walletHoldsUnrestoredCredit(wp) {
			t.Error("no wallet file counts as holding credit")
		}
	})
}

// R5: the record goes with the wallet.
func TestRestoredCredit_TheWalletRemovalsTakeTheRecord(t *testing.T) {
	gone := func(t *testing.T, wp, after string) {
		t.Helper()
		for _, p := range []string{walletRestoredPath(wp), walletRestoredPath(wp) + ".tmp"} {
			if _, err := os.Stat(p); !os.IsNotExist(err) {
				t.Errorf("%s left %s (stat err %v)", after, strings.TrimPrefix(p, wp), err)
			}
		}
	}
	dest := t.TempDir()
	wp := rscLand(t, dest, &Wallet{BlindTokens: hcBlind(2)})
	if _, err := os.Stat(walletRestoredPath(wp)); err != nil {
		t.Fatalf("the landing wrote no record: %v", err)
	}
	if err := os.WriteFile(walletRestoredPath(wp)+".tmp", []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	removeWallet(wp)
	gone(t, wp, "removeWallet")

	wp = rscLand(t, dest, &Wallet{BlindTokens: hcBlind(2)})
	if _, err := os.Stat(walletRestoredPath(wp)); err != nil {
		t.Fatalf("the second landing wrote no record: %v", err)
	}
	if err := os.WriteFile(walletRestoredPath(wp)+".tmp", []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	basis, err := os.ReadFile(wp)
	if err != nil {
		t.Fatal(err)
	}
	if ok, why := dropWalletIfUnchanged(wp, walletGeneration(wp), basis); !ok {
		t.Fatalf("dropWalletIfUnchanged = false (%s), want a drop", why)
	}
	gone(t, wp, "dropWalletIfUnchanged")
}

// R6: the record holds keys only: no signature, no blind message in clear, no claim code.
func TestRestoredCredit_TheRecordHoldsNothingSpendable(t *testing.T) {
	wp := rscLand(t, t.TempDir(), &Wallet{
		Tokens:        []Token{{Denom: "1", Nonce: "rc-n1", Exp: 1, Sig: "rc-plain-sig"}},
		BlindTokens:   hcBlind(2),
		PendingClaims: []string{"rc-claim-code-1"},
	})
	fi, err := os.Stat(walletRestoredPath(wp))
	if err != nil {
		t.Fatalf("the landing wrote no record: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("the record's mode is %v, want 0600", fi.Mode().Perm())
	}
	raw, err := os.ReadFile(walletRestoredPath(wp))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if lines[0] != walletGeneration(wp) {
		t.Errorf("the record's first line is %q, want the generation", lines[0])
	}
	have := map[string]bool{}
	for _, l := range lines[1:] {
		have[l] = true
		if strings.HasPrefix(l, "c:") {
			t.Errorf("the record holds a claim key %q", l)
		}
	}
	want := []string{"t:rc-n1"}
	for _, b := range hcBlind(2) {
		want = append(want, blindSeenKey(b))
	}
	for _, k := range want {
		if !have[k] {
			t.Errorf("the record lacks the token key %q", k)
		}
	}
	if len(lines)-1 != len(want) {
		t.Errorf("the record holds %d keys, want %d", len(lines)-1, len(want))
	}
	for _, leak := range []string{"rc-plain-sig", "hc-s0", "hc-s1", "hc-m0", "hc-m1", "rc-claim-code-1",
		pendingClaimSeenKey("rc-claim-code-1")} {
		if strings.Contains(string(raw), leak) {
			t.Errorf("the record holds %q", leak)
		}
	}
}
