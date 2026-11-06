package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// TestALeaseMayLengthenTheTermButNeverShortenIt: the field this guards is the one the Storage screen turns
// into "274 days left", and it is the last remaining record that a customer ever bought a plan.
//
// The gateway answers a profile it holds no grant for with a rolling ONE-EPOCH grace lease -- through =
// now + 1, HTTP 200, not flagged as lapsed. That is a correct answer to "may I write" and a catastrophic
// one to record as "this is the term you bought". Entitlement grants are keyed on profileRefV2(name, pass),
// so they do not follow a passphrase change: within a day of rotating or recovering, a customer holding
// nine months of an annual plan was told they had one day left -- and the wallet had overwritten the only
// evidence that they ever bought it.
//
// ⚠ MONOTONIC IS NOT A NEW RULE. walletForPublish already merges this very field by max and says why: "a
// term never shortens, a deadline never nears ... Taking the max is therefore not a guess about which write
// came last; it is the true value in both." Only the RECORD side ever disagreed with the PUBLISH side.
//
// The same principle is already pinned one field over, by TestRecordPlanNeverDowngradesTheTerm in
// plan_term_test.go: a shorter top-up must not downgrade a live PlanPeriods. This is that rule applied
// to the field the screen actually renders.
func TestALeaseMayLengthenTheTermButNeverShortenIt(t *testing.T) {
	for _, tc := range []struct {
		label  string
		start  int64
		lease  int64
		want   int64
		reason string
	}{
		{"a grace lease must not cut a live term", 500, 1, 500,
			"a one-epoch grace lease is the gateway saying 'you may write', not 'this is your term'"},
		{"a real renewal still extends it", 500, 900, 900,
			"a lease that genuinely buys more term must still be recorded, or renewal never lands"},
		{"an expired term is left expired", 0, 0, 0,
			"nothing to record and nothing to protect"},
		{"the first lease of a profile records normally", 0, 700, 700,
			"a wallet with no term yet must be able to acquire one"},
	} {
		t.Run(tc.label, func(t *testing.T) {
			w := &Wallet{PaidThrough: tc.start}
			recordCoverage(w, leaseInfo{ThroughEpoch: tc.lease}, false, 0)
			if w.PaidThrough != tc.want {
				t.Errorf("PaidThrough %d -> %d after a lease through %d, want %d: %s",
					tc.start, w.PaidThrough, tc.lease, tc.want, tc.reason)
			}
		})
	}
}

// TestAShortenedTermWouldDestroyTheEvidenceTheScreenNeeds states the consequence the rule exists for, in the
// shape the Storage screen actually reads: a carried term that is still in the future is what distinguishes
// "we cannot corroborate your plan" from "your plan expired". Those two sentences send the customer to
// different places -- the second tells them to buy a plan they already own.
func TestAShortenedTermWouldDestroyTheEvidenceTheScreenNeeds(t *testing.T) {
	const now, bought = 1000, 1274 // an annual plan with most of its term left
	w := &Wallet{PaidThrough: bought, PlanGB: 50}

	// Thirty days of grace leases, one per sync, each answering "through = now + 1".
	for i := 0; i < 30; i++ {
		recordCoverage(w, leaseInfo{ThroughEpoch: now + 1}, false, 0)
	}

	if w.PaidThrough <= now {
		t.Fatalf("after 30 grace leases the wallet reports PaidThrough=%d, which is in the past at epoch %d. "+
			"The screen then reads 'Plan expired' and routes the customer to buy a SECOND plan -- while the "+
			"grant they already paid for is alive on the server under their old profile key.", w.PaidThrough, now)
	}
	if w.PaidThrough != bought {
		t.Errorf("the purchased term drifted from %d to %d. It is the only record that the purchase happened; "+
			"nothing re-derives it.", bought, w.PaidThrough)
	}
}

// ============================================================================================
// NWP-20260915-26: a term comes from a GRANT, never from permission to write.
//
// The rule these tests pin is one line -- !withdrew && leaseBoughtCoverage(info) -- and it took three
// attempts, so each wrong answer is pinned here too. The shapes below are the gateway's REAL reply
// shapes, transcribed from nowhere-cloud's four leaseResp writers. A fixture that invents a shape would
// prove nothing about a rule whose entire job is telling those four apart.

// termGateway answers /lease with a reply the test dictates and counts what it was asked.
type termGateway struct {
	srv      *httptest.Server
	reply    leaseInfo
	entitled int64 // entitled_bytes for POST /entitlement
	freeGB   int64
	leases   int
	buyGB    []int
}

func newTermGateway(t *testing.T, now int64, reply leaseInfo) *termGateway {
	t.Helper()
	g := &termGateway{reply: reply, freeGB: 1}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{
			Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 86400, EpochsPerLease: 30,
			PriceCents: 200, CurrentEpoch: now, IssuerPubKey: "testpub", FreeGB: g.freeGB,
		})
	})
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 30, EntitledBytes: g.entitled, CurrentEpoch: now})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		g.leases++
		g.buyGB = append(g.buyGB, req.BuyGB)
		json.NewEncoder(w).Encode(g.reply)
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

// TestOnlyAGatewayBackedTermIsReportedAsBought is the rule itself, at the seam that decides it.
//
// leaseRefs returns the bool the two recording call sites gate on, so this table IS the gate. Each row is
// a reply shape the gateway really sends, and the comment on each says which handler sends it.
func TestOnlyAGatewayBackedTermIsReportedAsBought(t *testing.T) {
	const now = 1000
	for _, tc := range []struct {
		label  string
		reply  leaseInfo
		wallet *Wallet
		want   bool
		// wantBuy is what the DEVICE must have declared on the wire. Asserted because two rows are only
		// meaningful if planPurchase actually declared a purchase: without it, a row that silently
		// declined (an under-funded wallet, or the activation jitter holding the plan) would pass while
		// testing nothing at all -- and the row below is the one that rules out gating on buyGB.
		wantBuy int
		why     string
	}{
		{
			// graceLease: "No nonces and no added capacity: this writes the leases and nothing else."
			// PlanGB is omitted because "Grace is reached only when every grant has lapsed, so LiveGB is 0
			// by construction".
			"a grace lease buys nothing",
			leaseInfo{ThroughEpoch: now + 1, DeadlineEpoch: now + 120},
			&Wallet{PaidThrough: now - 100, PlanGB: 10, PlanPeriods: 12, Tokens: []Token{{}}},
			false,
			0, // one token against a 120-signature plan: planPurchase declines rather than part-funding it
			"through = now+1 with nothing spent and no grant named is the gateway saying 'you may write'",
		},
		{
			// handleEntitledLease, carried arm: nothing bought, but a live grant already covers it, so
			// through is the grant's own term and PlanGB is ent.LiveGB(now).
			"a carried renewal inside a live term still buys coverage",
			leaseInfo{ThroughEpoch: now + 300, DeadlineEpoch: now + 330, PlanGB: 10},
			&Wallet{PaidThrough: now - 100, PlanGB: 10, PlanPeriods: 12},
			true,
			0, // an empty wallet buys nothing -- this is the customer BETWEEN purchases
			"an entitled profile renewing inside a live term legitimately spends nothing -- withholding the " +
				"term from it is the display bug NWP-20260829-06, which is why Spent alone cannot be the rule",
		},
		{
			// handleEntitledLease, purchase arm: owed nonces verified and a grant appended in the same tx.
			"a purchase the gateway charged for buys a term",
			leaseInfo{ThroughEpoch: now + 360, DeadlineEpoch: now + 450, Spent: 120, PlanGB: 10},
			&Wallet{PlanGB: 10, PlanPeriods: 12, BlindTokens: make([]BlindToken, 120)},
			true,
			10,
			"the gateway charged for it; this is the one unambiguous purchase",
		},
		{
			// ⚠ THE ROW THAT KILLS THE OBVIOUS FIX. The device DECLARED buy_gb > 0 and the gateway answered
			// 200 with a grace term: handleEntitledLease grace-leases a declaration whose signatures do not
			// verify, and a live-bytes read error grace-leases BEFORE buy_gb is validated at all. Reachable
			// in the field -- collectTokens silently skips a token that fails Verify, so credit that expired
			// unnoticed (NWP-20260915-25) declares a purchase the gateway cannot back.
			"a DECLARED purchase the gateway grace-leased buys nothing",
			leaseInfo{ThroughEpoch: now + 1, DeadlineEpoch: now + 120},
			&Wallet{PlanGB: 10, PlanPeriods: 12, BlindTokens: make([]BlindToken, 120)},
			false,
			10, // ⚠ the whole point of the row: the device DID declare it, and it still bought nothing
			"buyGB > 0 is OUR declaration, not the gateway's answer; gating on it leaves -26 half-fixed",
		},
		{
			// A gateway predating plan_gb (NWC-20260907-01) never names a grant, and the LEGACY no-profile
			// path never does either ("a throwaway has no plan to be wrong about"). Spent is what still
			// carries a purchase there. Version skew must degrade to stale, never to wrong -- and never to
			// silently dropping a term somebody was charged for.
			"a purchase is recorded even when the gateway never names a plan",
			leaseInfo{ThroughEpoch: now + 360, DeadlineEpoch: now + 450, Spent: 120},
			&Wallet{PlanGB: 10, PlanPeriods: 12, BlindTokens: make([]BlindToken, 120)},
			true,
			10,
			"the gateway charged for this term; an older gateway not naming the plan cannot unmake that",
		},
	} {
		t.Run(tc.label, func(t *testing.T) {
			g := newTermGateway(t, now, tc.reply)
			g.freeGB = 0 // everything counts as over-free, so planPurchase is never held by its jitter window
			wp := filepath.Join(t.TempDir(), "wallet.json")
			if err := saveWallet(wp, tc.wallet); err != nil {
				t.Fatal(err)
			}
			_, bought, err := leaseRefs(newGatewayClient(g.srv.URL, gwDefault), wp, "prof", map[string]int64{"blob/x": 4096}, nil)
			if err != nil {
				t.Fatalf("leaseRefs: %v", err)
			}
			if bought != tc.want {
				t.Errorf("reported bought=%v, want %v (declared buy_gb=%v). %s", bought, tc.want, g.buyGB, tc.why)
			}
			// PROVE THE PROBE RAN. Without this a row whose wallet quietly declined to declare a purchase
			// would assert the right answer for the wrong reason, and the row that exists to rule out
			// buyGB-gating is exactly the row that would go quiet.
			if len(g.buyGB) == 0 || g.buyGB[0] != tc.wantBuy {
				t.Fatalf("the device declared buy_gb=%v, want %d -- this row is not testing what it says",
					g.buyGB, tc.wantBuy)
			}
		})
	}
}

// TestAnExpiredTermIsNotNudgedForwardByAGraceLease is the regression itself, end to end through payRent
// and out into the wallet the Storage screen reads.
//
// Monotonic (NWP-20260915-19) stops a grace lease SHORTENING a live term. An EXPIRED term is in the past,
// so now+1 is greater than it and the guard waves it through -- one epoch per sync, forever. The screen
// then reads "1 day left" instead of "Plan expired"; and because -19 also taught it to notice the gateway
// disagreeing, it reads "Our servers don't show this plan against this profile" -- blaming us for the
// customer's own lapse and replacing their renewal button with an inert Report this.
//
// The profile here is lapsed with credit left over, which is what makes it take the paid path at all.
func TestAnExpiredTermIsNotNudgedForwardByAGraceLease(t *testing.T) {
	const now, expiredAt = 1000, 900
	g := newTermGateway(t, now, leaseInfo{ThroughEpoch: now + 1, DeadlineEpoch: now + 120})
	base := newHTTPStore(t)
	const name, pass = "lapsedplan", "horse battery staple correct"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), make([]byte, 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	if err := saveWallet(wpath, &Wallet{PaidThrough: expiredAt, PlanGB: 10, PlanPeriods: 12, Tokens: []Token{{}}}); err != nil {
		t.Fatal(err)
	}
	freeRenewedThrough = map[string]int64{}

	for i := 0; i < 30; i++ { // a month of syncs
		if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil); err != nil {
			t.Fatalf("payRent %d: %v", i, err)
		}
	}
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if w.PaidThrough != expiredAt {
		t.Errorf("an expired term drifted from %d to %d across %d grace leases. The screen reports a live "+
			"plan, and tells the customer their own lapse is our fault with no way to renew.",
			expiredAt, w.PaidThrough, g.leases)
	}
	if w.DeadlineEpoch != 0 {
		t.Errorf("a deletion date (%d) was recorded from a lease that bought no term (NWP-20260906-03)", w.DeadlineEpoch)
	}
	// ...but what the lease DID establish is recorded. Withholding this was its own bug: renewalDue reads
	// RenewedEpoch, and for a profile whose remembered term is LIVE that clause is the only one that can
	// fire, so never writing it re-leases the whole footprint on every 120s keep-alive.
	if w.RenewedEpoch != now {
		t.Errorf("RenewedEpoch = %d, want %d -- the footprint was re-stamped and that much is true", w.RenewedEpoch, now)
	}
}

// TestACarriedRenewalStillRecordsItsTerm is the guard on the other side, and the reason the rule is not
// simply "did we buy something".
//
// An entitled customer renewing INSIDE a live term buys nothing: planPurchase declines and the lease costs
// zero. Gating the term on the device's own purchase -- info.Spent, or buyGB > 0 -- withholds PaidThrough
// from every paying customer between purchases, which is the display bug NWP-20260829-06. My first attempt
// at -26 did exactly that and two existing tests caught it; this one states it directly so the next attempt
// does not have to.
func TestACarriedRenewalStillRecordsItsTerm(t *testing.T) {
	const now, carried = 1000, 1300
	g := newTermGateway(t, now, leaseInfo{ThroughEpoch: carried, DeadlineEpoch: carried + 30, PlanGB: 10})
	g.entitled = 10 << 30 // a LIVE grant: this is what sends payRent down the paid path with an empty wallet
	base := newHTTPStore(t)
	const name, pass = "paidupplan", "horse battery staple correct"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), make([]byte, 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	if err := saveWallet(wpath, &Wallet{PaidThrough: now - 100, PlanGB: 10, PlanPeriods: 12}); err != nil {
		t.Fatal(err)
	}
	freeRenewedThrough = map[string]int64{}

	if _, _, err := payRent(newGatewayClient(g.srv.URL, gwDefault), base, name, pass, wpath, nil); err != nil {
		t.Fatalf("payRent: %v", err)
	}
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if w.PaidThrough != carried {
		t.Errorf("PaidThrough = %d, want %d. The gateway named a live grant and gave its term; withholding "+
			"it tells a paying customer their plan expired and routes them to buy a second one.",
			w.PaidThrough, carried)
	}
	if w.DeadlineEpoch != carried+30 {
		t.Errorf("DeadlineEpoch = %d, want %d -- the term was bought, so its deadline is real too",
			w.DeadlineEpoch, carried+30)
	}
}
