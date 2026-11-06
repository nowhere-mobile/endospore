package main

// NWP-20260907-12: a handset may not lower an account fact it does not know about.
//
// Confirmed in the field 2026-09-07: Chester bought 50 GB on frankel while lynx was signed in; lynx sealed
// afterwards and both handsets then read 10 GB. A handset that had bought nothing, and could not know a
// purchase had happened, erased a paid plan by writing its own whole wallet over the account's.

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// THE FIELD CASE, exactly as it happened.
func TestWalletPublish_AStaleHandsetCannotLowerThePlan(t *testing.T) {
	account := &Wallet{PlanGB: 50, PlanPeriods: 3, PaidThrough: 20876, DeadlineEpoch: 20906}
	lynx := &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20876, DeadlineEpoch: 20906}

	out := walletForPublish(account, lynx, nil)
	if out.PlanGB != 50 {
		t.Fatalf("a handset that bought nothing published plan_gb=%d over the account's 50 -- this is the "+
			"frankel/lynx failure, unfixed", out.PlanGB)
	}
}

// Every monotonic field, not just the one that was reported. A stale handset is stale in all of them at
// once, and fixing only the symptom would leave the term and the deletion date to be lowered next.
func TestWalletPublish_NoMonotonicFactCanGoBackwards(t *testing.T) {
	account := &Wallet{PlanGB: 50, PlanPeriods: 12, PaidThrough: 21000, DeadlineEpoch: 21030,
		RenewedEpoch: 20900, ActivateAfter: 20950}
	stale := &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20800, DeadlineEpoch: 20830,
		RenewedEpoch: 20700, ActivateAfter: 20750}

	out := walletForPublish(account, stale, nil)
	for _, c := range []struct {
		field string
		got   int64
		want  int64
	}{
		{"PlanGB", int64(out.PlanGB), 50},
		{"PlanPeriods", out.PlanPeriods, 12},
		{"PaidThrough", out.PaidThrough, 21000},
		{"DeadlineEpoch", out.DeadlineEpoch, 21030},
		{"RenewedEpoch", out.RenewedEpoch, 20900},
		{"ActivateAfter", out.ActivateAfter, 20950},
	} {
		if c.got != c.want {
			t.Errorf("%s was lowered to %d; the account holds %d", c.field, c.got, c.want)
		}
	}
}

// A handset that genuinely advanced something must still be able to publish it -- otherwise the fix would
// freeze the account at whatever was there first, which is a worse defect than the one it replaces.
func TestWalletPublish_RealProgressStillLands(t *testing.T) {
	account := &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20800}
	frankel := &Wallet{PlanGB: 50, PlanPeriods: 12, PaidThrough: 21000} // just redeemed

	out := walletForPublish(account, frankel, nil)
	if out.PlanGB != 50 || out.PlanPeriods != 12 || out.PaidThrough != 21000 {
		t.Fatalf("a real purchase did not survive the merge: plan_gb=%d periods=%d through=%d",
			out.PlanGB, out.PlanPeriods, out.PaidThrough)
	}
}

// AccountPlanGB is the GATEWAY's own answer and must stay free to fall -- a plan really can lapse, and
// pinning it at a high-water mark would leave the Storage screen advertising a plan the account no longer
// has. It is deliberately not in the merge.
func TestWalletPublish_TheGatewaysFigureIsNotPinnedHigh(t *testing.T) {
	account := &Wallet{AccountPlanGB: 50}
	afterLapse := &Wallet{AccountPlanGB: 10} // the gateway now reports a smaller live plan

	if out := walletForPublish(account, afterLapse, nil); out.AccountPlanGB != 10 {
		t.Fatalf("AccountPlanGB was pinned at %d; the gateway says 10, and it is the authority on what "+
			"the account actually holds", out.AccountPlanGB)
	}
}

// NWP-20261031-01 (decided 2026-10-20, Q107): the tokens merge by the seen-set rule. A token this session has held and
// spent is never resurrected from the stored copy -- a plain union would bring back nonces the gateway has marked spent.
func TestWalletPublish_ASpentTokenIsNeverResurrected(t *testing.T) {
	account := &Wallet{Tokens: make([]Token, 150)}
	seen := map[string]bool{}
	for i := range account.Tokens {
		account.Tokens[i].Nonce = fmt.Sprintf("n%d", i)
		seen["t:"+account.Tokens[i].Nonce] = true
	}
	spender := &Wallet{Tokens: nil} // this handset held and spent them; the account copy predates that

	if out := walletForPublish(account, spender, seen); len(out.Tokens) != 0 {
		t.Fatalf("the merge resurrected %d token(s) this session had already spent -- the gateway "+
			"will answer 409 for every one and they become permanently undeadable", len(out.Tokens))
	}
}

// The other phone's new credit -- a token this session never held -- is kept, plain and blind alike.
func TestWalletPublish_TheOtherPhonesNewCreditIsKept(t *testing.T) {
	account := &Wallet{
		Tokens:      []Token{{Nonce: "T1"}, {Nonce: "M1"}},
		BlindTokens: []BlindToken{{Msg: "d|b1|9"}, {Msg: "d|m2|9"}},
	}
	local := &Wallet{Tokens: []Token{{Nonce: "N1"}}, BlindTokens: []BlindToken{{Msg: "d|b1|9"}}}
	seen := map[string]bool{"t:T1": true, blindSeenKey(BlindToken{Msg: "d|b1|9"}): true}
	out := walletForPublish(account, local, seen)
	if len(out.Tokens) != 2 || out.Tokens[0].Nonce != "N1" || out.Tokens[1].Nonce != "M1" {
		t.Fatalf("plain tokens = %+v, want N1 (local) and M1 (the other phone's)", out.Tokens)
	}
	if len(out.BlindTokens) != 2 || out.BlindTokens[1].Msg != "d|m2|9" {
		t.Fatalf("blind tokens = %+v, want b1 (local, once) and m2 (the other phone's)", out.BlindTokens)
	}
	if len(local.Tokens) != 1 || len(local.BlindTokens) != 1 {
		t.Fatal("the publish mutated the caller's token slices")
	}
}

// A nil seen-set (absent, unreadable, another generation) merges no tokens: the local set publishes unchanged.
func TestWalletPublish_NoSeenSetPublishesTheLocalSet(t *testing.T) {
	account := &Wallet{Tokens: []Token{{Nonce: "M1"}}}
	if out := walletForPublish(account, &Wallet{}, nil); len(out.Tokens) != 0 {
		t.Fatalf("a nil seen-set merged %d stored token(s)", len(out.Tokens))
	}
}

// A store that cannot be read must degrade to the old behaviour rather than block a seal. The wallet
// publish is on the seal path, and on an amnesiac device a blocked seal is lost data.
func TestWalletPublish_AnUnreadableAccountCopyDoesNotBlockTheWrite(t *testing.T) {
	local := &Wallet{PlanGB: 10, PaidThrough: 20800}
	out := walletForPublish(nil, local, nil)
	if out == nil || out.PlanGB != 10 || out.PaidThrough != 20800 {
		t.Fatalf("a nil account copy did not fall through to the local wallet: %+v", out)
	}
}

// The caller's wallet must not be mutated by a publish: the same in-memory wallet is used afterwards by
// the seal path, and a publish quietly editing it would be a second, invisible writer.
func TestWalletPublish_DoesNotMutateTheCallersWallet(t *testing.T) {
	account := &Wallet{PlanGB: 50}
	local := &Wallet{PlanGB: 10}
	_ = walletForPublish(account, local, nil)
	if local.PlanGB != 10 {
		t.Fatalf("the caller's wallet was mutated to plan_gb=%d", local.PlanGB)
	}
}

// EVERY PUBLISHER MUST BE WIRED, not just the one that was reported. walletForPublish being correct and
// unwired is the likelier failure: there are three publish sites and only one of them -- the cap-mode
// fold -- is exercised by the fleet, so a missed one would sit silent. This walks the source instead of
// trusting a grep, because that is exactly how the fifth copy of the refusal string survived four passes.
func TestWalletPublish_EveryPublisherMerges(t *testing.T) {
	src := readSourceForTest(t, "billing.go") + readSourceForTest(t, "main.go")
	// The three sites that write the wallet head.
	for _, site := range []string{
		`putHead(base, name+"#wallet", pass, h) // #80`, // sealWallet, direct-store
		`putHead(base, name+"#wallet", pass, h)`,        // sealWalletDurable, cap mode
		`headWriteRef(foldName+"#wallet", sess.pass)`,   // capFlush's fold (foldName: NWP-20261010-04)
	} {
		if !strings.Contains(src, site) {
			t.Fatalf("publish site %q not found -- this test is checking source that has moved, so it is "+
				"no longer guarding anything", site)
		}
	}
	if n := strings.Count(src, "walletForPublish("); n < 4 {
		t.Errorf("walletForPublish appears %d times across billing.go + main.go; expected at least 4 "+
			"(its definition plus one call at each of the three publish sites). A publisher that skips "+
			"the merge can lower an account fact it does not know about, which is the whole defect.", n)
	}
}

func readSourceForTest(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(name)
	if err != nil {
		t.Skipf("cannot read %s (%v) -- this test needs the source tree", name, err)
	}
	return string(b)
}
