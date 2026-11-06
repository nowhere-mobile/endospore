package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The pure install-gate decision: how many BYTES over the plan `used+add` would put the profile.
//
// A SIZE check, not a token check. The old version asked whether the wallet held enough tokens for the
// excess, which is meaningless once a plan is a service period: the wallet is EMPTY by design after
// activation. Note the "wallet has tokens" cases below -- they used to FIT and now correctly do not,
// because credit no longer buys headroom. That was the live wrong-direction bug: a wallet holding an
// unactivated plan masked a genuine over-plan and let the install through.
func TestHeadroomShortBytes(t *testing.T) {
	cases := []struct {
		name               string
		used, add, covered int64
		want               int64
	}{
		{"within covered", 2 * giB, 100 << 20, 5 * giB, 0},
		{"exactly at covered", 5 * giB, 0, 5 * giB, 0},
		{"1GiB over", 5 * giB, 1 * giB, 5 * giB, 1 * giB},
		{"1.5GiB over is reported exactly, not rounded to whole tokens", 5 * giB, 3 * giB / 2, 5 * giB, 3 * giB / 2},
		{"holding tokens no longer buys headroom", 0, 3 * giB, 1 * giB, 2 * giB},
		{"free tier covers a small app", 100 << 20, 200 << 20, 10 * giB, 0},
		{"one byte over still does not fit", 5 * giB, 1, 5 * giB, 1},
	}
	for _, c := range cases {
		if got := headroomShortBytes(c.used, c.add, c.covered); got != c.want {
			t.Errorf("%s: short=%d want %d", c.name, got, c.want)
		}
	}
}

// Coverage is max(free, entitled) and NEVER their sum. Adding them allowed a whole extra free tier, so on
// a 10 GB plan the gate admitted 11 GiB and reported no shortfall while the gateway already called the
// profile full at 10 -- the gate silently stopped enforcing in exactly that band.
func TestCoveragePrefersGatewayAndNeverAdds(t *testing.T) {
	cases := []struct {
		name string
		ent  entitlementInfo
		want int64
	}{
		{"gateway's own figure wins", entitlementInfo{FreeBytes: 1 * giB, EntitledBytes: 10 * giB, CoveredBytes: 10 * giB}, 10 * giB},
		{"old gateway: max, not sum", entitlementInfo{FreeBytes: 1 * giB, EntitledBytes: 10 * giB}, 10 * giB},
		{"no plan falls back to the free tier", entitlementInfo{FreeBytes: 1 * giB}, 1 * giB},
		{"a plan smaller than the free tier still gets the free tier", entitlementInfo{FreeBytes: 1 * giB, EntitledBytes: 512 << 20}, 1 * giB},
	}
	for _, c := range cases {
		if got := c.ent.coverage(); got != c.want {
			t.Errorf("%s: coverage=%d want %d", c.name, got, c.want)
		}
	}
}

// The device entitlement client parses the gateway reply, and a non-200 (notably an OLD gateway that 404s the
// endpoint) is surfaced as an error so installHeadroom / entitlementLine FAIL-OPEN instead of mis-reading an
// empty body as "zero coverage" (which would wrongly block every install).
func TestEntitlementClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/entitlement" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		var req struct {
			Profile string `json:"profile"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		if req.Profile == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		json.NewEncoder(w).Encode(entitlementInfo{
			FreeBytes: 1 * giB, EntitledBytes: 2 * giB,
			UsedBytes: 3 * giB / 2, CurrentEpoch: 42, EpochSeconds: 604800, GBPerToken: 1,
		})
	}))
	defer srv.Close()

	ent, code, err := newGatewayClient(srv.URL, gwDefault).entitlement("profX")
	if err != nil || code != http.StatusOK {
		t.Fatalf("entitlement: code=%d err=%v", code, err)
	}
	if ent.FreeBytes != 1*giB || ent.EntitledBytes != 2*giB || ent.UsedBytes != 3*giB/2 {
		t.Fatalf("parsed wrong: %+v", ent)
	}

	// An old gateway (no such endpoint) -> 404 -> error, so callers fail-open.
	old := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }))
	defer old.Close()
	if _, code, err := newGatewayClient(old.URL, gwDefault).entitlement("profX"); err == nil || code != http.StatusNotFound {
		t.Fatalf("old gateway should be a 404 error (fail-open): code=%d err=%v", code, err)
	}
}
