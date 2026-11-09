package main

// NWP-20261128-31: walletHoldsCredit is the unspent balance. A plan whose tokens were spent at activation keeps PlanGB
// > 0 for good, and the gateway holds its grant under the profile's key, so it is not credit a lost publish loses: the
// gate's "credit ... is lost" notice (decided 2026-10-15 "Retry, then warn" and 2026-10-16 "warn and tell") and
// GET-PARKED-CREDIT's warning must not fire for it. test-held-credit.sh --mutate convicts K1-K3 against these.

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// hcBlind is n distinct blind tokens.
func hcBlind(n int) []BlindToken {
	b := make([]BlindToken, n)
	for i := range b {
		b[i] = BlindToken{Msg: "hc-m" + strconv.Itoa(i), Sig: "hc-s" + strconv.Itoa(i)}
	}
	return b
}

// hcActive is the wallet of an activated plan: 10 GB for three periods, paid through a future epoch, no tokens left
// (activation spent them).
func hcActive() *Wallet {
	return &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: nowEpoch() + 60}
}

// hcWallet saves w as the wallet of a fresh state dir and returns the dir.
func hcWallet(t *testing.T, w *Wallet) string {
	t.Helper()
	dest := t.TempDir()
	if err := saveWallet(walletPathFor(dest), w); err != nil {
		t.Fatal(err)
	}
	return dest
}

// H1: the predicate itself.
func TestHeldCredit_Table(t *testing.T) {
	withTokens := func(w *Wallet, n int) *Wallet { w.BlindTokens = hcBlind(n); return w }
	saved := func(w *Wallet) func(t *testing.T) string {
		return func(t *testing.T) string { return walletPathFor(hcWallet(t, w)) }
	}
	cases := []struct {
		name    string
		setup   func(t *testing.T) string // returns the wallet path
		pending *bool                     // when set, what planPending must say of the saved wallet
		want    bool
	}{
		{name: "no wallet file", setup: func(t *testing.T) string { return walletPathFor(t.TempDir()) }},
		{name: "an activated plan with no tokens", setup: saved(hcActive())},
		{name: "a directory at the path", want: true, setup: func(t *testing.T) string {
			wp := walletPathFor(t.TempDir())
			if err := os.Mkdir(wp, 0o700); err != nil {
				t.Fatal(err)
			}
			return wp
		}},
		{name: "unparsable JSON", want: true, setup: func(t *testing.T) string {
			wp := walletPathFor(t.TempDir())
			if err := os.WriteFile(wp, []byte("{not json"), 0o600); err != nil {
				t.Fatal(err)
			}
			return wp
		}},
		{name: "one plain token", want: true, setup: saved(&Wallet{Tokens: []Token{{Denom: "1", Nonce: "hc-n1", Exp: 1, Sig: "s"}}})},
		{name: "one blind token", want: true, setup: saved(withTokens(&Wallet{}, 1))},
		{name: "a plan bought and waiting with its 30 tokens", want: true, pending: ptrBool(true),
			setup: saved(withTokens(hcActive(), 30))},
		{name: "a plan with 7 tokens, short of its price", want: true, pending: ptrBool(false),
			setup: saved(withTokens(hcActive(), 7))},
		{name: "a queued purchase with its tokens", want: true, setup: saved(func() *Wallet {
			w := withTokens(hcActive(), 20)
			w.PlanQueue = []PlanSpec{{GB: 20, Periods: 1}}
			return w
		}())},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			wp := c.setup(t)
			if c.pending != nil {
				w, err := loadWallet(wp)
				if err != nil {
					t.Fatal(err)
				}
				if w.planPending() != *c.pending {
					t.Fatalf("planPending() = %v, want %v: the case does not mean what it says", w.planPending(), *c.pending)
				}
			}
			if got := walletHoldsCredit(wp); got != c.want {
				t.Errorf("walletHoldsCredit = %v, want %v", got, c.want)
			}
		})
	}
}

func ptrBool(b bool) *bool { return &b }

// hcNoKeepSetup replaces the no-keep sign-out's reap with a recorder (its default, reapOrReboot, blocks up to 20 s and
// can call rebootNow) and points the restart notice at a temp path; cleanup restores both and the reap queue.
func hcNoKeepSetup(t *testing.T) *[]string {
	t.Helper()
	var uids []string
	reap, restart := logoutNoKeepReap, restartCreditLostPath
	logoutNoKeepReap = func(u string) { uids = append(uids, u) }
	restartCreditLostPath = filepath.Join(t.TempDir(), "restart-credit-lost")
	t.Cleanup(func() {
		logoutNoKeepReap, restartCreditLostPath = reap, restart
		pendingReapMu.Lock()
		pendingSwitchUID, pendingReapUID, sealInFlight, sealRunKind = "", "", false, ""
		pendingReapMu.Unlock()
	})
	return &uids
}

// hcSignOut drives logoutEndNoKeep from the state its real caller leaves: a logoff seal in flight.
func hcSignOut(dest, uid string) {
	pendingReapMu.Lock()
	sealInFlight, sealRunKind = true, "logoff"
	pendingReapMu.Unlock()
	logoutEndNoKeep(dest, uid, "held-credit test arm")
}

// H2: a cold-lock no-keep sign-out whose save failed tells the gate nothing for an activated plan, and tells it for a
// token.
func TestHeldCredit_AnActivePlanIsNotToldLost(t *testing.T) {
	uids := hcNoKeepSetup(t)

	dest := hcWallet(t, hcActive())
	hcSignOut(dest, "17")
	if len(*uids) != 1 || (*uids)[0] != "17" {
		t.Fatalf("the reap saw %q, want [17]: the sign-out did not run its whole path", *uids)
	}
	if _, err := os.Stat(creditLostPath(dest)); !os.IsNotExist(err) {
		t.Errorf("an activated plan with no tokens recorded the lost-credit notice (stat err %v)", err)
	}
	if got := creditLostReply(dest); got != "NONE" {
		t.Errorf("GET-CREDIT-LOST = %q after an activated plan's sign-out, want NONE", got)
	}

	w := hcActive()
	w.BlindTokens = hcBlind(1)
	dest = hcWallet(t, w)
	hcSignOut(dest, "18")
	if _, err := os.Stat(creditLostPath(dest)); err != nil {
		t.Errorf("a plan holder with one token recorded no lost-credit notice: %v", err)
	}
	if got := creditLostReply(dest); len(got) < 7 || got[:7] != "NOTICE " {
		t.Errorf("GET-CREDIT-LOST = %q after a sign-out that lost a token, want NOTICE <time>", got)
	}
}

// H3: GET-PARKED-CREDIT warns of no loss for a parked cold-locked activated plan, and warns for a token.
func TestHeldCredit_ParkedActivePlanIsNotLost(t *testing.T) {
	dest := hcWallet(t, hcActive()) // no restore proof: the parked session never read its stored wallet
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("parkedone\n15\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	wp := walletPathFor(dest)
	if !walletNotRestored(wp, walletGeneration(wp)) {
		t.Fatal("the fixture's wallet earned a restore proof: the case does not mean what it says")
	}
	if got := parkedCreditReply(dest); got != "NONE" {
		t.Errorf("GET-PARKED-CREDIT = %q for a parked activated plan with no tokens, want NONE", got)
	}
	if err := appendTokens(wp, hcBlind(1)); err != nil {
		t.Fatal(err)
	}
	if !walletNotRestored(wp, walletGeneration(wp)) {
		t.Fatal("appendTokens earned a restore proof: the case does not mean what it says")
	}
	if got := parkedCreditReply(dest); got != "LOST" {
		t.Errorf("GET-PARKED-CREDIT = %q for a parked plan holding one token, want LOST", got)
	}
}
