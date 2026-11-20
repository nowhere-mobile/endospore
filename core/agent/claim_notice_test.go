package main

// NWP-20261208-03 (decided 2026-11-03, h55 #1): when the deferred drain clears a code on its second empty answer with
// nothing landed (unknown or spent) and the profile is then on the free plan, the same save records a hash of the code
// in Wallet.UnusableClaims; both wallet merges carry it once and never bring back an acknowledged one; GET-CLAIM-NOTICE
// and CLAIM-NOTICE-SHOWN serve it to Profile. The drains run against pcGateway (pending_claim_test.go). Every test has
// its own profile name, wallet dir and code.

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// cnDrainTwice runs drainPendingClaims twice on wp and fails on an error or on tokens landing.
func cnDrainTwice(t *testing.T, gw *pcGateway, wp string) {
	t.Helper()
	for run := 1; run <= 2; run++ {
		if n, err := drainPendingClaims(gw.client(), wp); err != nil || n != 0 {
			t.Fatalf("run %d: drainPendingClaims = (%d, %v), want (0, nil)", run, n, err)
		}
	}
}

// cnWithoutPending is the raw wallet file with its pending_claims member taken out.
func cnWithoutPending(t *testing.T, wp string) string {
	t.Helper()
	raw, err := os.ReadFile(wp)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	delete(m, "pending_claims")
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func cnList(got []string) string { return "[" + strings.Join(got, ",") + "]" }

// N1: a free wallet (paid through a date in the future, as a free lease leaves it) with one well-formed unknown code.
// Run 1 keeps the code and leaves no notice; run 2 clears it and leaves exactly its hash. The code is never written
// outside pending_claims, and no log line holds the code or a hash.
func TestClaimNotice_UnknownLeavesTheNotice(t *testing.T) {
	const code = "cnN1AAAAAAAAAAAAAAAAAAAA"
	wp := walletRaceEnv(t)
	if err := saveWallet(wp, &Wallet{PendingClaims: []string{code}, PaidThrough: nowEpoch() + 30}); err != nil {
		t.Fatal(err)
	}
	gw := newPCGateway(t, nil) // 402 for every code
	logs := captureStderr(t, func() {
		if n, err := drainPendingClaims(gw.client(), wp); err != nil || n != 0 {
			t.Errorf("run 1: drainPendingClaims = (%d, %v), want (0, nil)", n, err)
		}
		w := pcLoad(t, wp)
		if !pcHolds(w, code) || len(w.UnusableClaims) != 0 {
			t.Errorf("run 1: code kept %v, %d notice(s); want the code kept and no notice", pcHolds(w, code), len(w.UnusableClaims))
		}
		if strings.Contains(cnWithoutPending(t, wp), code) {
			t.Error("run 1: the wallet file holds the code outside pending_claims")
		}
		if n, err := drainPendingClaims(gw.client(), wp); err != nil || n != 0 {
			t.Errorf("run 2: drainPendingClaims = (%d, %v), want (0, nil)", n, err)
		}
	})
	w := pcLoad(t, wp)
	if len(w.PendingClaims) != 0 || cnList(w.UnusableClaims) != cnList([]string{unusableClaimKey(code)}) {
		t.Fatalf("run 2: %d pending code(s), notices %d; want none pending and exactly the code's notice",
			len(w.PendingClaims), len(w.UnusableClaims))
	}
	if raw, _ := os.ReadFile(wp); strings.Contains(string(raw), code) {
		t.Fatal("run 2: the wallet file still holds the code")
	}
	if strings.Contains(logs, code) || strings.Contains(logs, unusableClaimKey(code)[2:]) {
		t.Fatal("a log line holds the code or its hash")
	}
	if !strings.Contains(logs, ", 1 left a notice") {
		t.Fatal("run 2's counts line does not count the notice")
	}
}

// N2: a code that landed tokens and then got the proving 402 WAS used: it is cleared and leaves no notice, even when
// the wallet is free at the clear (a lease spent the tokens before it).
func TestClaimNotice_LandedThenEmptyNoNotice(t *testing.T) {
	const code = "cnN2AAAAAAAAAAAAAAAAAAAA"
	wp := walletRaceEnv(t)
	if err := saveWallet(wp, &Wallet{PendingClaims: []string{code}}); err != nil {
		t.Fatal(err)
	}
	gw := newPCGateway(t, map[string]int{code: 3})
	pendingClaimBeforeClear = func() {
		w, err := loadWallet(wp)
		if err != nil {
			t.Error(err)
			return
		}
		w.Tokens, w.BlindTokens = nil, nil // spent by a lease: the wallet is free at the clear
		if err := saveWallet(wp, w); err != nil {
			t.Error(err)
		}
	}
	t.Cleanup(func() { pendingClaimBeforeClear = nil })
	if n, err := drainPendingClaims(gw.client(), wp); err != nil || n != 3 {
		t.Fatalf("drainPendingClaims = (%d, %v), want (3, nil)", n, err)
	}
	w := pcLoad(t, wp)
	if !claimNoticeFree(w) {
		t.Fatal("precondition: the wallet is not free at the clear")
	}
	if len(w.PendingClaims) != 0 || len(w.UnusableClaims) != 0 {
		t.Fatalf("%d pending code(s), %d notice(s); want the code cleared and no notice", len(w.PendingClaims), len(w.UnusableClaims))
	}
}

// N3: a wallet that is not on the free plan gets no notice when its unknown code clears: one plain token held, a plan
// activated and spent (PlanGB stays set), or the gateway's recorded plan (AccountPlanGB).
func TestClaimNotice_NotFreeNoNotice(t *testing.T) {
	if !claimNoticeFree(&Wallet{PaidThrough: nowEpoch() + 30}) {
		t.Fatal("claimNoticeFree({PaidThrough in the future}) = false: a free lease advances PaidThrough")
	}
	cases := []struct {
		name, code string
		w          Wallet
	}{
		{"a token held", "cnN3TOKAAAAAAAAAAAAAAAAA", Wallet{Tokens: []Token{{Nonce: "cn-n3-nonce"}}}},
		{"a plan activated and spent", "cnN3PLNAAAAAAAAAAAAAAAAA", Wallet{PlanGB: 10, PlanPeriods: 1, PaidThrough: nowEpoch() + 30}},
		{"an account plan", "cnN3ACPAAAAAAAAAAAAAAAAA", Wallet{AccountPlanGB: 10}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := c.w
			if w.planPending() {
				t.Fatal("precondition: the plan is still waiting")
			}
			if claimNoticeFree(&w) {
				t.Fatal("claimNoticeFree = true for a wallet that is not on the free plan")
			}
			wp := walletRaceEnv(t)
			w.PendingClaims = []string{c.code}
			if err := saveWallet(wp, &w); err != nil {
				t.Fatal(err)
			}
			cnDrainTwice(t, newPCGateway(t, nil), wp)
			got := pcLoad(t, wp)
			if len(got.PendingClaims) != 0 || len(got.UnusableClaims) != 0 {
				t.Fatalf("%d pending code(s), %d notice(s); want the code cleared and no notice", len(got.PendingClaims), len(got.UnusableClaims))
			}
		})
	}
}

// N4: both phones restored the same unknown code and both clear it: every merge holds exactly one notice.
func TestClaimNotice_TwoPhonesOneNotice(t *testing.T) {
	const code = "cnN4AAAAAAAAAAAAAAAAAAAA"
	key := unusableClaimKey(code)
	p := pcSetup(t, "cn-n4-twophones", code)
	wa := p.restore(t)
	wb := p.restore(t)
	gw := newPCGateway(t, nil)
	cnDrainTwice(t, gw, wa)
	cnDrainTwice(t, gw, wb)
	a, b := pcLoad(t, wa), pcLoad(t, wb)
	if cnList(a.UnusableClaims) != cnList([]string{key}) || cnList(b.UnusableClaims) != cnList([]string{key}) {
		t.Fatalf("precondition: phone A holds %d notice(s), phone B %d; want one each", len(a.UnusableClaims), len(b.UnusableClaims))
	}
	seenB := walletSeen(wb, walletGeneration(wb))
	if seenB == nil {
		t.Fatal("precondition: phone B has no seen-set")
	}
	if got := walletForPublish(a, b, seenB).UnusableClaims; cnList(got) != cnList([]string{key}) {
		t.Errorf("walletForPublish(A stored, B local, B's seen): %d notice(s), want 1", len(got))
	}
	t.Run("dedup without seen", func(t *testing.T) {
		// seen is non-nil and EMPTY, so only the dedup keeps the stored copy of the same notice out.
		got := walletForPublish(&Wallet{UnusableClaims: []string{key}}, &Wallet{UnusableClaims: []string{key}}, map[string]bool{}).UnusableClaims
		if cnList(got) != cnList([]string{key}) {
			t.Errorf("walletForPublish of one notice on both sides, empty seen: %d notice(s), want 1", len(got))
		}
	})
	if got := mergeLateRestore(a, b).UnusableClaims; cnList(got) != cnList([]string{key}) {
		t.Errorf("mergeLateRestore(A, B): %d notice(s), want 1", len(got))
	}
	k1, k2 := unusableClaimKey("cnN4K1AAAAAAAAAAAAAAAAAA"), unusableClaimKey("cnN4K2AAAAAAAAAAAAAAAAAA")
	if got := mergeLateRestore(&Wallet{UnusableClaims: []string{k1}}, &Wallet{UnusableClaims: []string{k2}}).UnusableClaims; cnList(got) != cnList([]string{k1, k2}) {
		t.Errorf("mergeLateRestore of two notices: %v, want the stored one first, then the local one", got)
	}
}

// N5: a notice this session acknowledged is not brought back from a stored copy that still holds it; a notice this
// session never held (the other phone left it) is kept.
func TestClaimNotice_AckedNotResurrected(t *testing.T) {
	k := unusableClaimKey("cnN5AAAAAAAAAAAAAAAAAAAA")
	stored := &Wallet{UnusableClaims: []string{k}}
	if got := walletForPublish(stored, &Wallet{}, map[string]bool{k: true}).UnusableClaims; len(got) != 0 {
		t.Errorf("an acknowledged notice: published %d, want 0", len(got))
	}
	if got := walletForPublish(stored, &Wallet{}, map[string]bool{}).UnusableClaims; cnList(got) != cnList([]string{k}) {
		t.Errorf("a notice never held here: published %d, want 1 (kept)", len(got))
	}
	// The real path: the session's wallet held the notice, and Profile acknowledged it (a save without it).
	wp := walletRaceEnv(t)
	if err := saveWallet(wp, &Wallet{UnusableClaims: []string{k}}); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wp, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	seen := walletSeen(wp, walletGeneration(wp))
	if !seen[k] {
		t.Fatal("the seen-set does not hold the notice the wallet held")
	}
	if got := walletForPublish(stored, pcLoad(t, wp), seen).UnusableClaims; len(got) != 0 {
		t.Errorf("after the acknowledgement: published %d notice(s), want 0", len(got))
	}
}

// N6: the two verbs over handleLogin. No stored session answers NONE; the count is the number of notices; SHOWN n
// drops the first n; a bad n is ERR-ARGS and changes nothing; a held wallet lock is BUSY. No reply or log line holds
// a hash.
func TestClaimNotice_Verbs(t *testing.T) {
	k1, k2 := unusableClaimKey("cnN6K1AAAAAAAAAAAAAAAAAA"), unusableClaimKey("cnN6K2AAAAAAAAAAAAAAAAAA")
	wp := walletRaceEnv(t)
	dest := t.TempDir()
	old := walletSignInWait
	walletSignInWait = 100 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
	check := func(what, req, want string) {
		t.Helper()
		if got := driveLogin(t, dest, req); got != want {
			t.Errorf("%s: %q, want %q", what, got, want)
		}
	}
	logs := captureStderr(t, func() {
		if err := saveWallet(wp, &Wallet{UnusableClaims: []string{k1, k2}}); err != nil {
			t.Fatal(err)
		}
		check("no session", "GET-CLAIM-NOTICE\n", "NONE")
		check("no session, shown", "CLAIM-NOTICE-SHOWN\n1\n", "NONE")
		if err := writeRoamSession(dest, "cn-n6-verbs", "the passphrase of cn-n6-verbs", "10", "", true); err != nil {
			t.Fatal(err)
		}
		check("two notices", "GET-CLAIM-NOTICE\n", "NOTICE 2")
		check("shown 1", "CLAIM-NOTICE-SHOWN\n1\n", "OK")
		check("one left", "GET-CLAIM-NOTICE\n", "NOTICE 1")
		if got := pcLoad(t, wp).UnusableClaims; cnList(got) != cnList([]string{k2}) {
			t.Errorf("after shown 1: %d notice(s) left, want the second one", len(got))
		}
		check("shown 0", "CLAIM-NOTICE-SHOWN\n0\n", "ERR-ARGS")
		check("shown x", "CLAIM-NOTICE-SHOWN\nx\n", "ERR-ARGS")
		if got := pcLoad(t, wp).UnusableClaims; len(got) != 1 {
			t.Errorf("after a bad n: %d notice(s), want 1 (unchanged)", len(got))
		}
		unlock, state := lockWalletWithin(wp, time.Second)
		if state != walletLocked {
			unlock()
			t.Fatalf("precondition: the test could not take the wallet lock (state %d)", state)
		}
		check("lock held", "CLAIM-NOTICE-SHOWN\n1\n", "BUSY")
		unlock()
		if got := pcLoad(t, wp).UnusableClaims; len(got) != 1 {
			t.Errorf("after BUSY: %d notice(s), want 1 (unchanged)", len(got))
		}
		check("shown 5 of 1", "CLAIM-NOTICE-SHOWN\n5\n", "OK")
		check("all shown", "GET-CLAIM-NOTICE\n", "NONE")
		if err := os.Remove(wp); err != nil {
			t.Fatal(err)
		}
		check("no wallet, shown", "CLAIM-NOTICE-SHOWN\n1\n", "NONE")
	})
	if regexp.MustCompile(`[0-9a-f]{64}`).MatchString(logs) {
		t.Fatal("a log line holds a 64-hex run (a notice's hash)")
	}
}
