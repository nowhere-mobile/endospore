package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// NWP-20261201-18 (h60 #14, decided 2026-11-06): each recorded purchase carries a random id, sealed in the wallet and
// never sent to the gateway, so a publish queues the other phone's waiting purchases instead of carrying their tokens
// without a plan.

// stubPurchaseIDs replaces the minter with one that returns ids in order and counts its calls.
func stubPurchaseIDs(t *testing.T, ids ...string) *int {
	t.Helper()
	old := newPurchaseID
	calls := 0
	newPurchaseID = func() string {
		calls++
		if calls > len(ids) {
			t.Fatalf("minted %d purchase ids, want at most %d", calls, len(ids))
		}
		return ids[calls-1]
	}
	t.Cleanup(func() { newPurchaseID = old })
	return &calls
}

// The backlog row's case: each phone holds a different waiting purchase, and neither is stranded.
func TestWalletPurchaseID_TwoPhonesWaitingPurchasesAreBothKept(t *testing.T) {
	pinQueueClock(t, 100)
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "a", BlindTokens: pubWaitingTokens("two-local", 30)}
	stored := &Wallet{PlanGB: 20, PlanPeriods: 3, PlanID: "b", BlindTokens: pubWaitingTokens("two-stored", 60)}
	out := walletForPublish(stored, local, map[string]bool{})
	if out.PlanGB != 10 || out.PlanPeriods != 3 || out.PlanID != "a" {
		t.Fatalf("head %d x %d id %q, want this phone's 10 x 3 id a", out.PlanGB, out.PlanPeriods, out.PlanID)
	}
	if len(out.PlanQueue) != 1 || out.PlanQueue[0] != (PlanSpec{ID: "b", GB: 20, Periods: 3}) {
		t.Fatalf("queue %+v, want [20 x 3 id b]", out.PlanQueue)
	}
	if out.balance() != 90 {
		t.Fatalf("balance %d, want 90", out.balance())
	}
	if len(local.PlanQueue) != 0 {
		t.Fatalf("the publish wrote into this phone's wallet: %+v", local.PlanQueue)
	}

	gb, periods, plain, blind := out.planPurchase(1000, false)
	if gb != 10 || periods != 3 || len(plain)+len(blind) != 30 {
		t.Fatalf("planPurchase bought %d x %d with %d signatures, want 10 x 3 with 30", gb, periods, len(plain)+len(blind))
	}
	after := out.afterActivation()
	after.settlePayment(plain, blind, 30)
	if after.PlanGB != 20 || after.PlanPeriods != 3 || after.PlanID != "b" || !after.planPending() {
		t.Fatalf("after this phone's purchase: %d x %d id %q pending=%v, want a waiting 20 x 3 id b",
			after.PlanGB, after.PlanPeriods, after.PlanID, after.planPending())
	}

	// A local queue with spare capacity is copied, never appended to in place.
	spare := make([]PlanSpec, 1, 4)
	spare[0] = PlanSpec{ID: "q", GB: 5, Periods: 1}
	local.PlanQueue = spare
	out = walletForPublish(stored, local, map[string]bool{})
	if len(out.PlanQueue) != 2 || out.PlanQueue[0].ID != "q" || out.PlanQueue[1].ID != "b" {
		t.Fatalf("queue %+v, want [q b]", out.PlanQueue)
	}
	if got := spare[:2][1]; got != (PlanSpec{}) {
		t.Fatalf("the publish wrote %+v into this phone's queue array", got)
	}
}

// An idle phone publishes the other phone's head and queue, in order, and its id.
func TestWalletPurchaseID_AnIdlePhoneQueuesBothOfTheOthers(t *testing.T) {
	local := &Wallet{PlanGB: 50, PlanPeriods: 12, PlanID: "old", PaidThrough: 400}
	stored := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "a", PlanKeep: true,
		PlanQueue:   []PlanSpec{{ID: "b", GB: 20, Periods: 3, Convert: true}},
		BlindTokens: pubWaitingTokens("idle-stored", 90)}
	out := walletForPublish(stored, local, map[string]bool{})
	if out.PlanGB != 10 || out.PlanPeriods != 3 || !out.PlanKeep || out.PlanConvert || out.PlanID != "a" {
		t.Fatalf("head %d x %d keep=%v convert=%v id %q, want 10 x 3 keep id a",
			out.PlanGB, out.PlanPeriods, out.PlanKeep, out.PlanConvert, out.PlanID)
	}
	if len(out.PlanQueue) != 1 || out.PlanQueue[0] != (PlanSpec{ID: "b", GB: 20, Periods: 3, Convert: true}) {
		t.Fatalf("queue %+v, want [20 x 3 convert id b]", out.PlanQueue)
	}
	if local.PlanID != "old" || local.PlanGB != 50 {
		t.Fatalf("the publish wrote into this phone's wallet: %+v", local)
	}
}

// A purchase that activated here is in seen and not in this phone's waiting list. It stays out, although the stored
// copy shows it waiting and the other phone added a token that funds it.
func TestWalletPurchaseID_APurchaseActivatedHereIsNotResurrected(t *testing.T) {
	local := func() *Wallet { return &Wallet{PlanGB: 50, PlanPeriods: 12, PlanID: "c", PaidThrough: 400} }
	stored := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "a", BlindTokens: pubWaitingTokens("activated", 30)}
	out := walletForPublish(stored, local(), map[string]bool{"p:a": true, "p:c": true})
	if out.PlanID != "c" || out.PlanGB != 50 || out.PlanPeriods != 12 || len(out.PlanQueue) != 0 {
		t.Fatalf("published %d x %d id %q queue %+v, want this phone's 50 x 12 id c and no queue",
			out.PlanGB, out.PlanPeriods, out.PlanID, out.PlanQueue)
	}
	// A queued purchase with no id does not bring the older rule back for that head.
	behind := *stored
	behind.PlanQueue = []PlanSpec{{GB: 5, Periods: 1}}
	out = walletForPublish(&behind, local(), map[string]bool{"p:a": true, "p:c": true})
	if out.PlanID != "c" || out.PlanGB != 50 || out.PlanPeriods != 12 || len(out.PlanQueue) != 0 {
		t.Fatalf("published %d x %d id %q queue %+v, want this phone's 50 x 12 id c and no queue",
			out.PlanGB, out.PlanPeriods, out.PlanID, out.PlanQueue)
	}
	// Control: the same copy with the id unseen is the other phone's purchase, and it is taken.
	out = walletForPublish(stored, local(), map[string]bool{"p:c": true})
	if out.PlanID != "a" || out.PlanGB != 10 {
		t.Fatalf("published %d id %q, want the unseen purchase 10 id a", out.PlanGB, out.PlanID)
	}
}

// This phone's own waiting purchase, already in the stored copy, is one purchase. seen holds no p: key, so only the
// check of this phone's own ids stops it.
func TestWalletPurchaseID_ThisPhonesOwnPurchaseIsNotDuplicated(t *testing.T) {
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "a", BlindTokens: pubWaitingTokens("own-local", 30)}
	stored := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "a", BlindTokens: pubWaitingTokens("own-stored", 30)}
	out := walletForPublish(stored, local, map[string]bool{})
	if out.PlanID != "a" || len(out.PlanQueue) != 0 {
		t.Fatalf("head id %q queue %+v, want id a and no queue", out.PlanID, out.PlanQueue)
	}
	// Control: another id in the same shape is queued.
	other := *stored
	other.PlanID = "b"
	out = walletForPublish(&other, local, map[string]bool{})
	if len(out.PlanQueue) != 1 || out.PlanQueue[0].ID != "b" {
		t.Fatalf("queue %+v, want [id b]", out.PlanQueue)
	}
}

func TestWalletPurchaseID_IdsAreMintedPerRecordedPurchase(t *testing.T) {
	pinQueueClock(t, 100)
	first, second := newPurchaseID(), newPurchaseID()
	if len(first) != 32 || first == second {
		t.Fatalf("the minter gave %q and %q, want two different 16-byte hex ids", first, second)
	}

	calls := stubPurchaseIDs(t, "one", "two")
	w := &Wallet{}
	applyPlanMode(w, 3, 10, "") // the replace arm
	if w.PlanID != "one" {
		t.Fatalf("replace arm: PlanID %q, want one", w.PlanID)
	}
	w.BlindTokens = pubWaitingTokens("mint", 30)
	applyPlanMode(w, 3, 20, "") // the queue arm
	if len(w.PlanQueue) != 1 || w.PlanQueue[0].ID != "two" {
		t.Fatalf("queue arm: queue %+v, want [id two]", w.PlanQueue)
	}
	applyPlanMode(w, 3, 20, "") // the equal plan records nothing
	if *calls != 2 || len(w.PlanQueue) != 1 {
		t.Fatalf("an equal plan: %d ids minted, queue %+v, want 2 and one entry", *calls, w.PlanQueue)
	}
	if w.PlanID != "one" {
		t.Fatalf("the queue arm moved the head id to %q", w.PlanID)
	}
	w.planActivated()
	if w.PlanID != "two" || w.PlanGB != 20 {
		t.Fatalf("after activation: %d id %q, want 20 id two", w.PlanGB, w.PlanID)
	}
	w.planActivated() // nothing queued: the activated purchase keeps its id
	if w.PlanID != "two" {
		t.Fatalf("an empty promotion changed the id to %q", w.PlanID)
	}
}

// The real minter over a random source that fails: the purchase is recorded without an id, the process lives (rand.Read
// would abort it), and one fixed line is logged that holds neither an id nor the reader's error.
func TestWalletPurchaseID_AFailedRandomSourceRecordsThePurchaseWithoutAnID(t *testing.T) {
	pinQueueClock(t, 100)
	old := purchaseIDRand
	purchaseIDRand = failingReader{}
	t.Cleanup(func() { purchaseIDRand = old })
	bare := &Wallet{}
	logged := captureStderr(t, func() { applyPlanMode(bare, 3, 10, "") })
	if bare.PlanGB != 10 || bare.PlanPeriods != 3 || bare.PlanID != "" {
		t.Fatalf("a failed mint: %d x %d id %q, want 10 x 3 and no id", bare.PlanGB, bare.PlanPeriods, bare.PlanID)
	}
	const want = "[agent] wallet: the purchase id could not be generated -- the purchase is recorded without one (h60 #14)\n"
	if logged != want {
		t.Fatalf("a failed mint logged %q, want exactly %q", logged, want)
	}
	bare.BlindTokens = pubWaitingTokens("mint-fail", 30)
	logged = captureStderr(t, func() { applyPlanMode(bare, 3, 20, "") }) // the queue arm
	if len(bare.PlanQueue) != 1 || bare.PlanQueue[0] != (PlanSpec{GB: 20, Periods: 3}) || logged != want {
		t.Fatalf("a failed mint in the queue arm: queue %+v, log %q", bare.PlanQueue, logged)
	}
}

func TestWalletPurchaseID_TheSeenSetHoldsPlanIDs(t *testing.T) {
	w := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "head", PlanQueue: []PlanSpec{{ID: "queued", GB: 20, Periods: 3}, {GB: 5, Periods: 1}}}
	keys := map[string]bool{}
	for _, k := range walletSeenKeys(w) {
		keys[k] = true
	}
	if !keys["p:head"] || !keys["p:queued"] {
		t.Fatalf("walletSeenKeys = %v, want p:head and p:queued", keys)
	}
	if keys["p:"] {
		t.Fatalf("a purchase without an id made a key: %v", keys)
	}
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, w); err != nil {
		t.Fatal(err)
	}
	seen := walletSeen(wp, walletGeneration(wp))
	if !seen["p:head"] || !seen["p:queued"] {
		t.Fatalf("the seen-set after a save = %v, want p:head and p:queued", seen)
	}
}

func TestWalletPurchaseID_ALateRestoreDedupsByID(t *testing.T) {
	stored := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "a", BlindTokens: pubWaitingTokens("late-stored", 30)}
	local := &Wallet{PlanGB: 10, PlanPeriods: 3, PlanID: "a", BlindTokens: pubWaitingTokens("late-local", 90),
		PlanQueue: []PlanSpec{{ID: "b", GB: 20, Periods: 3}}}
	out := mergeLateRestore(stored, local)
	if out.PlanID != "a" || len(out.PlanQueue) != 1 || out.PlanQueue[0].ID != "b" {
		t.Fatalf("head id %q queue %+v, want id a and [id b]", out.PlanID, out.PlanQueue)
	}
	// The head's id is the first waiting purchase's, not the stored copy's stale one.
	idle := &Wallet{PlanGB: 50, PlanPeriods: 12, PlanID: "stale", PaidThrough: 400}
	waiting := &Wallet{PlanGB: 20, PlanPeriods: 3, PlanID: "b", BlindTokens: pubWaitingTokens("late-b", 60)}
	out = mergeLateRestore(idle, waiting)
	if out.PlanGB != 20 || out.PlanID != "b" {
		t.Fatalf("head %d id %q, want 20 id b", out.PlanGB, out.PlanID)
	}
}

// capFlush's promotion copy is inside a lease path that needs a live gateway, so the block is read from the source.
func TestWalletPurchaseID_TheCapFoldCopiesPlanID(t *testing.T) {
	raw, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	const open = "if promoted != nil && len(w.PlanQueue) > 0 {"
	i := strings.Index(src, open)
	if i < 0 {
		t.Fatalf("main.go no longer holds %q", open)
	}
	block := src[i:]
	end := strings.Index(block, "\n\t\t\t\t}\n")
	if end < 0 {
		t.Fatal("the promotion block has no closing brace")
	}
	if !strings.Contains(block[:end], "w.PlanID = promoted.PlanID") {
		t.Fatalf("the promotion block does not copy the purchase id:\n%s", block[:end])
	}
}

// The gateway contract is unchanged: no lease field carries the id, and the id is not in the body of a lease that buys.
func TestWalletPurchaseID_NoLeaseFieldCarriesAnID(t *testing.T) {
	typ := reflect.TypeOf(leaseReq{})
	for i := 0; i < typ.NumField(); i++ {
		tag, _, _ := strings.Cut(typ.Field(i).Tag.Get("json"), ",")
		if tag == "id" || tag == "plan_id" {
			t.Fatalf("leaseReq.%s is tagged %q: the purchase id must never reach the gateway", typ.Field(i).Name, tag)
		}
	}

	pinQueueClock(t, 100)
	wp := queueWallet(t)
	redeem(t, wp, 10, 3)
	redeem(t, wp, 20, 3)
	w := mustLoad(t, wp)
	if w.PlanID == "" || len(w.PlanQueue) != 1 || w.PlanQueue[0].ID == "" {
		t.Fatalf("recorded id %q queue %+v, want ids on both purchases", w.PlanID, w.PlanQueue)
	}
	var bodies []string
	mux := http.NewServeMux()
	mux.HandleFunc("/quote", func(rw http.ResponseWriter, r *http.Request) {
		json.NewEncoder(rw).Encode(map[string]any{"gb_per_token": 1, "current_epoch": 1000, "free_gb": 1})
	})
	mux.HandleFunc("/lease", func(rw http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(raw))
		var req leaseReq
		json.Unmarshal(raw, &req)
		json.NewEncoder(rw).Encode(leaseInfo{ThroughEpoch: 1090, DeadlineEpoch: 1120,
			Spent: len(req.Tokens) + len(req.BlindTokens), WriteCaps: map[string]string{}})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	if _, _, err := leaseRefs(newGatewayClient(srv.URL, gwDefault), wp, "purchase-id-lease-profile", map[string]int64{"blob/a": 1}, nil); err != nil {
		t.Fatalf("leaseRefs: %v", err)
	}
	joined := strings.Join(bodies, "\n")
	if !strings.Contains(joined, `"buy_gb":10`) {
		t.Fatalf("no lease bought the purchase, so the check proves nothing: %q", joined)
	}
	for _, id := range []string{w.PlanID, w.PlanQueue[0].ID} {
		if strings.Contains(joined, id) {
			t.Fatal("a lease body holds a purchase id")
		}
	}
	if got := mustLoad(t, wp); got.PlanID != w.PlanQueue[0].ID {
		t.Fatal("the landed purchase did not promote the queued id")
	}
}

// A stored purchase with no id still takes the NWP-20261129-10 rule, and the head does not keep this phone's id.
func TestWalletPurchaseID_AStoredPurchaseWithoutAnIDTakesTheOldArm(t *testing.T) {
	local := &Wallet{PlanGB: 50, PlanPeriods: 12, PlanID: "c", PaidThrough: 400}
	stored := &Wallet{PlanGB: 10, PlanPeriods: 3, BlindTokens: pubWaitingTokens("legacy", 30)}
	out := walletForPublish(stored, local, map[string]bool{})
	if out.PlanGB != 10 || out.PlanPeriods != 3 || out.PlanID != "" {
		t.Fatalf("published %d x %d id %q, want the stored 10 x 3 and no id", out.PlanGB, out.PlanPeriods, out.PlanID)
	}
}

// An id-less head with a queued id this session already held: the ids take nothing, so the older rule still publishes
// the head that the carried tokens fund. The refused id stays out, and a queued purchase with no id stays in.
func TestWalletPurchaseID_ASeenQueueIDLeavesTheOlderHead(t *testing.T) {
	local := func() *Wallet { return &Wallet{PlanGB: 50, PlanPeriods: 12, PlanID: "c", PaidThrough: 400} }
	seen := map[string]bool{"p:b": true, "p:c": true}
	tokens := pubWaitingTokens("mixed", 90)
	stored := &Wallet{PlanGB: 10, PlanPeriods: 3, BlindTokens: tokens, PlanQueue: []PlanSpec{{ID: "b", GB: 20, Periods: 3}}}
	out := walletForPublish(stored, local(), seen)
	if out.PlanGB != 10 || out.PlanPeriods != 3 || out.PlanID != "" || out.balance() != 90 || len(out.PlanQueue) != 0 {
		t.Fatalf("published %d x %d id %q balance %d queue %+v, want the stored 10 x 3, no id, 90 and no queue",
			out.PlanGB, out.PlanPeriods, out.PlanID, out.balance(), out.PlanQueue)
	}

	withOld := &Wallet{PlanGB: 10, PlanPeriods: 3, BlindTokens: tokens,
		PlanQueue: []PlanSpec{{ID: "b", GB: 20, Periods: 3}, {GB: 5, Periods: 1}}}
	out = walletForPublish(withOld, local(), seen)
	if out.PlanGB != 10 || len(out.PlanQueue) != 1 || out.PlanQueue[0] != (PlanSpec{GB: 5, Periods: 1}) {
		t.Fatalf("published %d queue %+v, want the stored 10 and [5 x 1]", out.PlanGB, out.PlanQueue)
	}

	// Nothing waits without an id here: the stored balance does not fund its head and the only queued id is refused,
	// so the max stands, although this phone's tokens and the carried ones together reach the head's price.
	active := &Wallet{PlanGB: 10, PlanPeriods: 3, BlindTokens: pubWaitingTokens("mixed-short", 20),
		PlanQueue: []PlanSpec{{ID: "b", GB: 20, Periods: 3}}}
	if active.planPending() {
		t.Fatal("the fixture's head must not be waiting")
	}
	funded := local()
	funded.BlindTokens = pubWaitingTokens("mixed-local", 15)
	out = walletForPublish(active, funded, seen)
	if out.PlanGB != 50 || out.PlanPeriods != 12 || out.PlanID != "c" || len(out.PlanQueue) != 0 {
		t.Fatalf("published %d x %d id %q queue %+v, want this phone's 50 x 12 id c and no queue",
			out.PlanGB, out.PlanPeriods, out.PlanID, out.PlanQueue)
	}
}

// When the ids take a purchase the older rule does not fire, although the id-less head is funded.
func TestWalletPurchaseID_AnUnseenQueueIDStopsTheOlderRule(t *testing.T) {
	local := &Wallet{PlanGB: 50, PlanPeriods: 12, PlanID: "c", PaidThrough: 400}
	stored := &Wallet{PlanGB: 10, PlanPeriods: 3, BlindTokens: pubWaitingTokens("took", 90),
		PlanQueue: []PlanSpec{{ID: "b", GB: 20, Periods: 3}}}
	out := walletForPublish(stored, local, map[string]bool{"p:c": true})
	if out.PlanGB != 20 || out.PlanPeriods != 3 || out.PlanID != "b" || len(out.PlanQueue) != 0 {
		t.Fatalf("published %d x %d id %q queue %+v, want the unseen 20 x 3 id b and no queue",
			out.PlanGB, out.PlanPeriods, out.PlanID, out.PlanQueue)
	}
}
