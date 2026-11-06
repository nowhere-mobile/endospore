package main

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20260905-02. The gateway client used to bake ONE 30s deadline into its constructor, covering
// everything from a per-chunk /cap on the restore path to a whole-footprint /lease -- and the two call
// sites that already knew better mutated hc.Timeout AFTER construction, which is easy to miss when reading
// and easy to forget when adding a site. The constructor now requires a budget, so the compiler asks.
//
// These tests hold the two things the compiler cannot: that the budgets are the reviewed numbers rather
// than invented ones, and that they stay inside the worker's stall budget.

// budgetSite matches a construction and captures the budget it names.
var budgetSite = regexp.MustCompile(`newGatewayClient\([^;]*?,\s*(gw[A-Za-z]+)\)`)

func agentSources(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	ents, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if !strings.HasSuffix(e.Name(), ".go") {
			continue
		}
		b, err := os.ReadFile(e.Name())
		if err != nil {
			t.Fatal(err)
		}
		out[e.Name()] = string(b)
	}
	return out
}

// EVERY construction must name one of the three budgets. The compiler already forces a duration argument;
// what it cannot force is that the argument is a NAMED, justified constant rather than a literal dropped in
// to make the build pass. A bare `30*time.Second` at a new call site is exactly how the single baked-in
// deadline came back last time, and it would carry no reasoning with it.
func TestEveryGatewayCallSiteNamesABudget(t *testing.T) {
	allowed := map[string]bool{"gwDefault": true, "gwUI": true, "gwProbe": true}
	sites := 0
	for name, src := range agentSources(t) {
		// This file NAMES the constructor in its own scanning code and in its own failure messages, so it
		// matches itself -- the same self-reference trap as a `pgrep -f` watcher finding its own command
		// line. Skipping it by name is exact; a cleverer in-string test would be one more thing to be wrong.
		if name == "gateway_budget_test.go" {
			continue
		}
		for _, line := range strings.Split(src, "\n") {
			if !strings.Contains(line, "newGatewayClient(") || strings.Contains(line, "func newGatewayClient(") {
				continue
			}
			sites++
			m := budgetSite.FindStringSubmatch(line)
			if m == nil {
				t.Errorf("%s: gateway client built without a NAMED budget:\n  %s\n"+
					"use gwDefault, gwUI or gwProbe -- a literal duration carries no reasoning and is how "+
					"one deadline came to cover every verb", name, strings.TrimSpace(line))
				continue
			}
			if !allowed[m[1]] {
				t.Errorf("%s: unknown budget %q:\n  %s", name, m[1], strings.TrimSpace(line))
			}
		}
	}
	if sites < 20 {
		t.Fatalf("only %d call sites seen -- this test is not looking at the package it thinks it is", sites)
	}
}

// The values are the reviewed ones. gwDefault is what the tree already had; gwUI and gwProbe are the two
// numbers that existed at their call sites with written reasoning. If someone changes one, that is a
// decision and it should have to edit this test and say why.
func TestGatewayBudgetsAreTheReviewedValues(t *testing.T) {
	for _, c := range []struct {
		name string
		got  time.Duration
		want time.Duration
	}{
		{"gwDefault", gwDefault, 30 * time.Second},
		{"gwUI", gwUI, 10 * time.Second},
		{"gwProbe", gwProbe, 4 * time.Second},
	} {
		if c.got != c.want {
			t.Errorf("%s = %v, want %v -- changing a budget is a decision, not a tweak; if it is deliberate, "+
				"edit this test and record why in the constant's comment", c.name, c.got, c.want)
		}
	}
	if gwUI >= gwDefault || gwProbe >= gwUI {
		t.Errorf("the budgets must stay ordered probe < ui < default (got %v, %v, %v): a probe that "+
			"fails open should never wait longer than a call a person is watching", gwProbe, gwUI, gwDefault)
	}
}

// THE INVARIANT THAT CONVICTS THE NEXT "JUST RAISE THE LEASE TIMEOUT".
//
// capFlush's gateway leg is a progress-SILENT stretch: it writes progress once before the quote and not
// again until the PUT loop begins, so a slow /quote followed by a slow /lease is 2 x gwDefault of silence
// with nothing feeding the worker's stall watchdog. The watchdog gives up after roamStallBudget with no
// CHANGE in roam.progress and reports ERR-TIMEOUT -- which on this device reads to the user as a failed
// seal on a healthy connection.
//
// So these are not independent numbers. Raising gwDefault far enough eats the whole budget and turns a slow
// link into a false timeout; that is the #45 / #87 failure shape. The 2x margin here is deliberate: the
// pair must fit with room, not merely fit.
//
// NWP-20261010-04: the wait for the wallet lock sits in the same silent stretch -- between the quote and the
// lease -- so it is counted here too. Waiting out another holder's leases there is what this test would have
// caught if the lock had used walletLockWait in capFlush. The model is the one this test already had (a quote
// and a lease at gwDefault); see capFlushWalletWait for what it leaves out.
//
// capFlush has a SECOND silent stretch: after the last blob's progress write, through the fold blob, the
// pointer PUTs and putWalletHead's try for the lock. Each PUT there is one store request (storeHTTP) like any
// blob's; what this slice adds to it is the try, so the try is counted beside one PUT and must leave the same
// 2x margin.
func TestSealGatewayLegFitsTheStallBudget(t *testing.T) {
	const callsInTheSilentWindow = 2 // quote, then lease
	silent := callsInTheSilentWindow*gwDefault + capFlushWalletWait
	if silent*2 > roamStallBudget {
		t.Errorf("the seal's gateway leg can be silent for %v (2 x gwDefault + capFlushWalletWait %v) against a "+
			"%v stall budget -- raising gwDefault or the wallet wait here buys a false ERR-TIMEOUT on a healthy "+
			"seal, not a more patient one. If a longer lease deadline is genuinely needed, the fix is to feed "+
			"progress across the gateway leg FIRST", silent, capFlushWalletWait, roamStallBudget)
	}
	if head := storeHTTP.Timeout + capFlushHeadWait; head*2 > roamStallBudget {
		t.Errorf("the wallet head's PUT can be silent for %v (storeHTTP %v + capFlushHeadWait %v) against a %v "+
			"stall budget -- putWalletHead must try the lock, not wait for it", head, storeHTTP.Timeout,
			capFlushHeadWait, roamStallBudget)
	}
	// NWP-20261117-10: the lease leg's longest silence is now one leaseBeat, not leaseBudget: a /lease in flight
	// re-writes its line every leaseBeat (lease_progress.go).
	if leaseBeat*2 > roamStallBudget {
		t.Errorf("a /lease in flight is silent for up to leaseBeat %v against a %v stall budget -- the beat "+
			"must come at least twice inside the budget", leaseBeat, roamStallBudget)
	}
}

// NWP-20261010-04: a sign-in's wallet removal and restore, and a create's removal, run while the chooser waits
// (ROAM-IN 120 s, CREATE 90 s, and a create past its read has made the profile and lost its recovery code).
// Together they stay under 20 s, leaving the rest of each budget to the login's own work.
func TestSignInWalletWaitsFitTheChoosersBudget(t *testing.T) {
	if both := 2 * walletSignInWait; both > 20*time.Second {
		t.Errorf("a sign-in can spend %v waiting for the wallet lock (removeWallet + the restore at "+
			"walletSignInWait %v) -- over the 20 s this budget allows inside the chooser's 90/120 s reads", both, walletSignInWait)
	}
}

// The one value change in this slice, pinned so it is not silently reverted: handlePingStore is the Store
// screen's connection banner and is byte-identical in shape to handleSetStoreManaged, which has been gwUI
// with reviewed reasoning since it was written. Both must stay gwUI.
func TestStoreScreenProbesUseTheUIBudget(t *testing.T) {
	src := agentSources(t)["main.go"]
	for _, fn := range []string{"handlePingStore", "handleSetStoreManaged"} {
		body := funcBody(t, src, fn)
		found := false
		for _, l := range body {
			if strings.Contains(l, "newGatewayClient(") {
				found = true
				if !strings.Contains(l, "gwUI") {
					t.Errorf("%s builds its client with %q -- both Store-screen probes are one /quote behind "+
						"a connection banner and belong on gwUI", fn, strings.TrimSpace(l))
				}
			}
		}
		if !found {
			t.Errorf("%s no longer builds a gateway client -- this pin is stale, not the code", fn)
		}
	}
}

// NWP-20261011-24. capGetMax retries a chunk read (gateway /cap leg + presigned GET) inside ONE closure, and a
// restore writes progress in chunk order, so a chunk stuck there is a stretch with no progress at all. Its
// worst case has to fit inside the worker's stall budget, or the retries meant for a hung fetch can never run:
// the watchdog's ERR-TIMEOUT arrives first. One attempt is readCap's gateway requests at gwDefault each plus
// storeHTTP.Timeout; retryStoreWithin starts the last attempt at most capGetRetryWindow after the first, and
// the largest backoff is added on top to stay pessimistic.
func TestCapGetFitsTheStallBudget(t *testing.T) {
	// readCap's gateway requests: the /caps POST, then the GET /cap fallback for a gateway that predates /caps.
	// Counted from the source so a third request cannot slip in without this sum noticing.
	body := strings.Join(stripComments(funcBody(t, agentSources(t)["billing.go"], "(g *gatewayClient) readCap")), "\n")
	gwCalls := time.Duration(strings.Count(body, "g.postJSON(") + strings.Count(body, "g.getJSON("))
	if gwCalls != 2 {
		t.Errorf("readCap makes %d gateway requests, this test was written for 2 -- recheck the sum below", gwCalls)
	}
	attempt := gwCalls*gwDefault + storeHTTP.Timeout
	maxBackoff := s3RetryBase << (storeRetryAttempts - 2)
	if worst := capGetRetryWindow + attempt + maxBackoff; worst >= roamStallBudget {
		t.Errorf("one capGet can take %v (capGetRetryWindow %v + one attempt %v [%d x gwDefault %v + storeHTTP %v] "+
			"+ backoff %v) against a %v stall budget -- the watchdog would give up before the retries do. Shrink "+
			"capGetRetryWindow first; if an attempt alone no longer fits, the fix is to feed progress across "+
			"the retry, not to raise roamStallTicks", worst, capGetRetryWindow, attempt, gwCalls, gwDefault,
			storeHTTP.Timeout, maxBackoff, roamStallBudget)
	}
	// The window must still let a FAST failure (a reset, #70; a stale-cap 403, #139) use every attempt: the
	// backoffs between the five attempts sum to s3RetryBase x (1+2+4+8).
	if all := s3RetryBase * (1<<(storeRetryAttempts-1) - 1); all >= capGetRetryWindow {
		t.Errorf("capGetRetryWindow %v leaves no room for the %v of backoff five fast failures need -- a "+
			"connection reset would no longer get its retries", capGetRetryWindow, all)
	}
	// And capGetMax must actually use the bounded retry: a revert to plain retryStore passes every sum above.
	got := strings.Join(stripComments(funcBody(t, agentSources(t)["main.go"], "capGetMaxOpt")), "\n")
	if !strings.Contains(got, `retryStoreWithin("cap GET "+key, capGetRetryWindow,`) {
		t.Errorf("capGetMax no longer retries through retryStoreWithin(..., capGetRetryWindow, ...) -- its " +
			"worst case is then 5 attempts with no time bound, far over roamStallBudget")
	}
}

// retryStoreWithin starts no attempt past its window, and returns the last error when it stops.
func TestRetryStoreWithinStopsAtTheWindow(t *testing.T) {
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	defer func() { s3RetryBase = old }()

	// Each attempt takes 200 ms; the window is 300 ms. Attempt 2 starts at ~201 ms (inside it), and after it
	// ~401 ms have passed, so attempt 3 must not start. 99 ms of scheduling slack before attempt 2 is missed.
	calls := 0
	err := retryStoreWithin("cap GET chunk/x", 300*time.Millisecond, func() error {
		calls++
		time.Sleep(200 * time.Millisecond)
		return fmt.Errorf("attempt %d hung", calls)
	})
	if calls != 2 {
		t.Errorf("ran %d attempts, want 2: the window should allow the 2nd and refuse the 3rd", calls)
	}
	if err == nil || err.Error() != "attempt 2 hung" {
		t.Errorf("returned %v, want the LAST attempt's error -- stopping early must still fail loudly", err)
	}
}

// A fast failure inside the window gets all five attempts, as retryStore always gave it.
func TestRetryStoreWithinKeepsFastRetries(t *testing.T) {
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	defer func() { s3RetryBase = old }()

	calls := 0
	err := retryStoreWithin("cap GET chunk/x", 10*time.Second, func() error {
		calls++
		return errors.New("connection reset by peer")
	})
	if calls != storeRetryAttempts || err == nil {
		t.Errorf("ran %d attempts (err %v), want %d failing attempts", calls, err, storeRetryAttempts)
	}

	calls = 0
	err = retryStoreWithin("cap GET chunk/x", 10*time.Second, func() error {
		if calls++; calls < 3 {
			return errors.New("connection reset by peer")
		}
		return nil
	})
	if calls != 3 || err != nil {
		t.Errorf("ran %d attempts (err %v), want success on the 3rd", calls, err)
	}
}

// An errStorePermanent refusal is still final at once, window or not.
func TestRetryStoreWithinPermanentIsFinal(t *testing.T) {
	calls := 0
	err := retryStoreWithin("cap GET chunk/x", 10*time.Second, func() error {
		calls++
		return fmt.Errorf("refused: %w", errStorePermanent)
	})
	if calls != 1 || !errors.Is(err, errStorePermanent) {
		t.Errorf("ran %d attempts (err %v), want 1 and errStorePermanent", calls, err)
	}
}
