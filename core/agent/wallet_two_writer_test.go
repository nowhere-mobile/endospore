package main

import (
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261031-01 (decided 2026-10-20, Q107): two handsets signed in to ONE profile merge their wallets. Handset A and
// handset B are two state dirs (two wallet files, two seen-sets) against one fake store; each publishes through the
// production sealWalletDurable.

func twoWriterNonces(w *Wallet) map[string]bool {
	out := map[string]bool{}
	for _, t := range w.Tokens {
		out[t.Nonce] = true
	}
	for _, t := range w.BlindTokens {
		out[blindSeenKey(t)] = true
	}
	return out
}

func twoWriterBlind(n string) BlindToken { return deadBlind(n + "AAAAAAAAAAAAAA") }

func TestWalletTwoWriter_ClaimsOfBothHandsetsSurviveAndASpentTokenStaysSpent(t *testing.T) {
	const name, pass = "twowriterwallet", "two handsets, one profile, one wallet"
	wa := walletRaceEnv(t)
	wb := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wb)
	standUpProfile(t, name, pass)
	dk := resolveDK("s3", name, pass, nil)
	publish := func(wpath string) {
		t.Helper()
		t.Setenv("NOWHERE_WALLET", wpath)
		if _, err := sealWalletDurable("s3", name, pass, dk, wpath); err != nil {
			t.Fatalf("publish from %s: %v", filepath.Base(filepath.Dir(wpath)), err)
		}
	}
	has := func(label string, want, absent []string) {
		t.Helper()
		sw := storedWallet(t, name, pass)
		if sw == nil {
			t.Fatalf("%s: no stored wallet", label)
		}
		got := twoWriterNonces(sw)
		for _, k := range want {
			if !got[k] {
				t.Errorf("%s: the stored wallet lost %s (holds %v)", label, k, got)
			}
		}
		for _, k := range absent {
			if got[k] {
				t.Errorf("%s: the stored wallet holds %s, which must be absent", label, k)
			}
		}
	}
	key := func(b BlindToken) string { return blindSeenKey(b) }

	// Both handsets restore T1..T5 (blind, so the paid lease presents T1 first) and the plain token P1.
	tk := func(n string) BlindToken { return twoWriterBlind(n) }
	t15 := []BlindToken{tk("T1"), tk("T2"), tk("T3"), tk("T4"), tk("T5")}
	p1 := Token{Nonce: "P1"}
	for _, wpath := range []string{wa, wb} {
		if err := saveWallet(wpath, &Wallet{Tokens: []Token{p1}, BlindTokens: append([]BlindToken(nil), t15...)}); err != nil {
			t.Fatal(err)
		}
	}
	publish(wa)
	has("setup", []string{"P1", key(t15[0]), key(t15[4])}, nil)

	// A spends T1 and claims N1..N3. B claims M1..M2 and the plain Q1, and publishes.
	n1, n2, n3 := tk("N1"), tk("N2"), tk("N3")
	m1, m2, q1 := tk("M1"), tk("M2"), Token{Nonce: "Q1"}
	if err := saveWallet(wa, &Wallet{Tokens: []Token{p1}, BlindTokens: append(append([]BlindToken(nil), t15[1:]...), n1, n2, n3)}); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wb, &Wallet{Tokens: []Token{p1, q1}, BlindTokens: append(append([]BlindToken(nil), t15...), m1, m2)}); err != nil {
		t.Fatal(err)
	}
	publish(wb)
	has("B's publish", []string{"P1", "Q1", key(t15[0]), key(m1), key(m2)}, nil)

	// A publishes: T2..T5 + N1..N3 + M1..M2 + Q1; T1 stays out (A held and spent it), M and Q stay in (A never held them).
	publish(wa)
	has("A's publish", []string{"P1", "Q1", key(t15[1]), key(t15[4]), key(n1), key(n2), key(n3), key(m1), key(m2)}, []string{key(t15[0])})

	// B publishes: B still holds T1, so it is back -- until B's next paid lease meets the gateway's 409.
	publish(wb)
	has("B's publish", []string{"Q1", key(t15[0]), key(t15[1]), key(n1), key(n3), key(m1)}, nil)

	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if !r.Free && r.BuyGB > 0 {
			return http.StatusConflict, string(deadBody("T1AAAAAAAAAAAAAA"))
		}
		if !r.Free {
			return http.StatusOK, "" // the token-less renewal that follows a withdrawn purchase
		}
		return 0, ""
	}
	t.Cleanup(func() { capStoreLeaseStatus = nil })
	bw, err := loadWallet(wb)
	if err != nil {
		t.Fatal(err)
	}
	bw.PlanGB, bw.PlanPeriods = 1, 1 // a purchase waiting: the next lease declares it and presents tokens
	if err := saveWallet(wb, bw); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_WALLET", wb)
	n := capBegin() // sessionFlush, under the profile's own key so the fold publishes where the others read
	capSetSession(name, pass, dk)
	postBlob("s3", []byte("B's next write, under a paid lease"))
	capFlush(n)
	capEndBracket(n)
	if aw, _ := loadWallet(wb); twoWriterNonces(aw)[key(t15[0])] {
		t.Fatal("control: the 409 did not retire T1 from B's wallet -- this test is not on the path it is about")
	}
	capStoreLeaseStatus = nil
	if aw, err := loadWallet(wb); err != nil {
		t.Fatal(err)
	} else {
		aw.PlanGB, aw.PlanPeriods, aw.FreeFullEpoch = 0, 0, 0 // the purchase is settled and the free tier open again: a plain seal
		if err := saveWallet(wb, aw); err != nil {
			t.Fatal(err)
		}
	}
	publish(wb)
	has("after the 409", []string{"Q1", key(t15[1]), key(n1), key(m1)}, []string{key(t15[0])})
}

// The seen-set belongs to a generation: another generation's file is ignored, and removeWallet takes it away.
func TestWalletSeen_AnotherGenerationIsIgnoredAndRemoveWalletRemovesIt(t *testing.T) {
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := bumpWalletGeneration(wpath); err != nil {
		t.Fatal(err)
	}
	gen := walletGeneration(wpath)
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "T1"}}, BlindTokens: []BlindToken{{Msg: "m", Sig: "SIGNATURE"}}}); err != nil {
		t.Fatal(err)
	}
	seen := walletSeen(wpath, gen)
	if !seen["t:T1"] || !seen[blindSeenKey(BlindToken{Msg: "m"})] || len(seen) != 2 {
		t.Fatalf("seen = %v, want the plain nonce and the blind message's hash", seen)
	}
	raw, _ := os.ReadFile(wpath + ".seen")
	if strings.Contains(string(raw), "SIGNATURE") {
		t.Fatal("the seen-set holds a signature")
	}
	if fi, err := os.Stat(wpath + ".seen"); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("seen-set mode: %v %v", fi, err)
	}
	if walletSeen(wpath, "another-generation") != nil {
		t.Fatal("a seen-set of another generation was read")
	}
	// A save under a new generation restarts the file.
	if err := bumpWalletGeneration(wpath); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "T9"}}}); err != nil {
		t.Fatal(err)
	}
	if s := walletSeen(wpath, walletGeneration(wpath)); len(s) != 1 || !s["t:T9"] {
		t.Fatalf("a new generation's seen-set = %v, want only t:T9", s)
	}
	removeWallet(wpath)
	if _, err := os.Stat(wpath + ".seen"); err == nil {
		t.Fatal("removeWallet left the seen-set behind")
	}
}

// A failed seen-set update must not leave a short set eligible for the union: a token this session held and spent
// would be resurrected as the other phone's credit (RF-001).
func TestWalletSeen_AFailedWriteLeavesNoShortSet(t *testing.T) {
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := bumpWalletGeneration(wpath); err != nil {
		t.Fatal(err)
	}
	gen := walletGeneration(wpath)
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "old"}}}); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(wpath+".seen.tmp", 0o700); err != nil { // the next update cannot write its temp file
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "old"}, {Nonce: "new"}}}); err != nil {
		t.Fatal(err)
	}
	os.Remove(wpath + ".seen.tmp")
	if err := saveWallet(wpath, &Wallet{}); err != nil { // "new" is spent
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "later"}}}); err != nil {
		t.Fatal(err)
	}
	seen := walletSeen(wpath, gen)
	if seen != nil {
		t.Fatalf("a short seen-set stayed readable after a failed write: %v", seen)
	}
	got := walletForPublish(&Wallet{Tokens: []Token{{Nonce: "new"}}}, &Wallet{}, seen)
	if len(got.Tokens) != 0 {
		t.Fatalf("resurrected a spent token after a seen-set write failure: %v", got.Tokens)
	}
}

// TestWalletSeenHelperProcess is the body of the child agent processes of the cross-process test below; it does
// nothing unless that test started it.
func TestWalletSeenHelperProcess(t *testing.T) {
	wpath := os.Getenv("WALLET_SEEN_HELPER_PATH")
	if wpath == "" {
		t.Skip("helper process only")
	}
	switch os.Getenv("WALLET_SEEN_HELPER_OP") {
	case "spend":
		if err := saveWallet(wpath, &Wallet{}); err != nil {
			t.Fatal(err)
		}
	case "publish":
		stored := &Wallet{Tokens: []Token{{Nonce: "new"}}}
		got := walletForPublish(stored, &Wallet{}, walletSeen(wpath, walletGeneration(wpath)))
		if len(got.Tokens) != 0 {
			t.Fatalf("resurrected a spent token across processes: %v", got.Tokens)
		}
	}
}

// A failed seen-set write is remembered by EVERY agent process sharing the session's wallet (RF-001): another
// process must not recreate a valid but incomplete set for the same generation.
func TestWalletSeen_AFailedWriteIsRememberedAcrossProcesses(t *testing.T) {
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := bumpWalletGeneration(wpath); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "old"}}}); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(wpath+".seen.tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "old"}, {Nonce: "new"}}}); err != nil {
		t.Fatal(err)
	}
	os.Remove(wpath + ".seen.tmp")
	for _, op := range []string{"spend", "publish"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestWalletSeenHelperProcess$")
		cmd.Env = append(os.Environ(), "WALLET_SEEN_HELPER_PATH="+wpath, "WALLET_SEEN_HELPER_OP="+op)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s in another process: %v\n%s", op, err, out)
		}
	}
	removeWallet(wpath)
	if _, err := os.Stat(seenBadPath(wpath)); err == nil {
		t.Fatal("removeWallet left the poison marker behind")
	}
}

// When the seen-set update AND its poison marker both fail, the save is refused (RF-001): the wallet on disk and the
// set beside it stay as they were, so no process can later resurrect a token the refused wallet would have held.
func TestWalletSeen_AFailedMarkerWriteRefusesTheSave(t *testing.T) {
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := bumpWalletGeneration(wpath); err != nil {
		t.Fatal(err)
	}
	gen := walletGeneration(wpath)
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "old"}}}); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(wpath+".seen.tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(seenBadPath(wpath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Nonce: "old"}, {Nonce: "new"}}}); err == nil {
		t.Fatal("a save whose seen-set and poison marker both failed landed")
	}
	if w, err := loadWallet(wpath); err != nil || len(w.Tokens) != 1 || w.Tokens[0].Nonce != "old" {
		t.Fatalf("the refused save touched the wallet: %v %v", w, err)
	}
	os.Remove(wpath + ".seen.tmp")
	os.Remove(seenBadPath(wpath))
	seen := walletSeen(wpath, gen)
	if seen == nil || !seen["t:old"] {
		t.Fatalf("the refused save destroyed the recorded set: %v", seen)
	}
	if seenPoisoned[seenPoisonKey(wpath, gen)] {
		t.Fatal("a marker that was never written poisoned the generation in memory")
	}
}
