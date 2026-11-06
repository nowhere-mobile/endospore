package main

// NWP-20260909-02: the /lease deadline is sized by REF COUNT, because a flat 30s could not carry a
// freshly imported profile and turned it into a permanent wedge (lynx, 2026-09-09).
//
// The shape worth remembering: the gateway COMPLETED every one of those leases. Nothing was overloaded and
// nothing was down -- the client simply stopped listening 126ms too early, threw away work the server had
// finished, and paid a 1.99 GB re-upload to do it again 120 seconds later, forever.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The measured cost of the wedge, straight from the beta gateway's own `lease ... refs=N dur=Nms` lines
// on 2026-09-09. 15 large leases; these are the extremes.
const (
	wedgeRefs      = 12317
	wedgeWorstCase = 34840 * time.Millisecond // the slowest completed lease
	wedgeBestCase  = 30126 * time.Millisecond // the FASTEST one -- still over gwDefault, by 126ms
)

// A SMALL LEASE MUST BE UNCHANGED. Most leases carry a handful of refs, and this slice must not turn a
// dead gateway into a longer hang for them.
func TestLeaseBudget_ASmallLeaseKeepsTheOldDeadline(t *testing.T) {
	if got := leaseBudget(0); got != gwDefault {
		t.Errorf("leaseBudget(0) = %v, want the unchanged %v", got, gwDefault)
	}
	if got := leaseBudget(3); got > gwDefault+time.Second {
		t.Errorf("leaseBudget(3) = %v -- a 3-ref lease should be indistinguishable from the old %v",
			got, gwDefault)
	}
}

// THE REGRESSION TEST FOR THE INCIDENT. If this ever fails, an imported profile is unsealable again.
func TestLeaseBudget_CoversTheProfileThatWedged(t *testing.T) {
	got := leaseBudget(wedgeRefs)
	if got <= gwDefault {
		t.Fatalf("leaseBudget(%d) = %v, no better than the flat %v that caused the wedge", wedgeRefs, got, gwDefault)
	}
	if got <= wedgeWorstCase {
		t.Errorf("leaseBudget(%d) = %v, but the gateway was MEASURED taking %v for that ref count -- this "+
			"deadline would abandon a lease the server completes", wedgeRefs, got, wedgeWorstCase)
	}
	// The failure that actually shipped: 30.000s against a 30.126s server. Margin, not a coin flip.
	if got < 2*wedgeBestCase {
		t.Errorf("leaseBudget(%d) = %v gives under 2x the FASTEST measured completion (%v). The incident was "+
			"a 126ms miss; a deadline this tight re-runs it on a slightly slower day", wedgeRefs, got, wedgeBestCase)
	}
}

// THE CAP MUST STILL BIND, or an unreachable gateway hangs the seal for as long as the profile is big.
func TestLeaseBudget_IsCapped(t *testing.T) {
	if got := leaseBudget(100000000); got != gwLeaseMax {
		t.Errorf("leaseBudget(huge) = %v, want the %v cap -- without it a large profile makes a DEAD "+
			"gateway hang proportionally longer", got, gwLeaseMax)
	}
}

// leaseClient must not build a second client when it has nothing to add: the shared one carries the
// connection pool, and churning clients per lease would quietly drop it.
func TestLeaseClient_ReusesTheSharedClientWhenItsBudgetAlreadyCovers(t *testing.T) {
	g := &gatewayClient{base: "http://example.invalid", hc: &http.Client{Timeout: gwLeaseMax}}
	if got := g.leaseClient(wedgeRefs); got != g.hc {
		t.Error("leaseClient built a NEW client for a budget the shared one already covers")
	}
	// ...and the no-deadline client (Timeout 0) is already unbounded, so it needs nothing either.
	g0 := &gatewayClient{base: "http://example.invalid", hc: &http.Client{}}
	if got := g0.leaseClient(wedgeRefs); got != g0.hc {
		t.Error("leaseClient overrode a client that has NO timeout -- that shortens it, the wrong direction")
	}
}

// ...and it must not leak the long deadline back onto the shared client, which would slow every later
// /cap call made through it. This is the pattern NWP-20260905-02 moved the file off.
func TestLeaseClient_LeavesTheSharedClientAlone(t *testing.T) {
	g := &gatewayClient{base: "http://example.invalid", hc: &http.Client{Timeout: gwDefault}}
	_ = g.leaseClient(wedgeRefs)
	if g.hc.Timeout != gwDefault {
		t.Errorf("the shared client's deadline moved to %v -- a lease must not re-time the /cap calls that "+
			"follow it", g.hc.Timeout)
	}
}

// THE END TO END SHAPE OF THE BUG: a gateway that answers CORRECTLY but takes longer than the base
// deadline. Before this slice the client hung up on it; now the lease lands.
func TestLease_SurvivesAGatewaySlowerThanTheBaseDeadline(t *testing.T) {
	var served int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		served++
		time.Sleep(250 * time.Millisecond) // stands in for the measured 30-35s
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 20876})
	}))
	defer srv.Close()

	// A base deadline the server is guaranteed to blow through, so the escalation is what is under test
	// rather than the wall clock.
	g := &gatewayClient{base: srv.URL, hc: &http.Client{Timeout: 50 * time.Millisecond}}

	info, code, err := g.leaseFree("p", map[string]int64{"ref/a": 1}, nil)
	if err != nil {
		t.Fatalf("the lease was abandoned on a gateway that answered correctly: %v. That is the wedge: the "+
			"server finishes, the client does not wait, and the whole seal is re-done next cycle.", err)
	}
	if code != http.StatusOK || info.ThroughEpoch != 20876 {
		t.Errorf("lease came back code=%d through=%d, want 200/20876", code, info.ThroughEpoch)
	}
	if served != 1 {
		t.Errorf("the server saw %d requests, want 1", served)
	}
}

// The control for the test above: with NO refs there is nothing to size the deadline from, so a slow
// gateway must still time out. Without this, the test above would also pass if leaseClient simply made
// every call unbounded -- which would be a different bug wearing the same green tick.
func TestLease_AnUnboundedDeadlineIsNotTheFix(t *testing.T) {
	if leaseBudget(0) == gwLeaseMax {
		t.Fatal("leaseBudget(0) reaches the cap, so this control proves nothing")
	}
	g := &gatewayClient{base: "http://example.invalid", hc: &http.Client{Timeout: gwDefault}}
	if got := g.leaseClient(0).Timeout; got != gwDefault {
		t.Errorf("a ref-less lease got a %v deadline, want the unchanged %v -- the deadline must come from "+
			"the ref count, not from removing the bound", got, gwDefault)
	}
}
