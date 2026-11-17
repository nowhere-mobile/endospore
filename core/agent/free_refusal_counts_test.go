package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// NWP-20261203-19: a free renewal refused 402 logs the gateway's live bytes and free allowance beside the MiB and refs
// that renewal named, so a report from a refused free profile shows the gap without the profile key. Counts only, and
// login.log only (Q008): nothing here reaches a screen.

// frcGateway answers /quote as renewBatchSetup's gateway does, /entitlement with entStatus (on 200: a 1 GiB free
// allowance, 1200 MiB live, nothing entitled), and every /lease with leaseStatus and leaseBody. *leases counts the
// /lease requests.
func frcGateway(t *testing.T, entStatus, leaseStatus int, leaseBody string, leases *int) *gatewayClient {
	t.Helper()
	var mu sync.Mutex
	mux := http.NewServeMux()
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 86400, EpochsPerLease: 30,
			PriceCents: 200, CurrentEpoch: 42, FreeGB: 1})
	})
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		if entStatus != http.StatusOK {
			w.WriteHeader(entStatus)
			return
		}
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 30, UsedBytes: 1200 << 20, EntitledBytes: 0, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		*leases++
		mu.Unlock()
		w.WriteHeader(leaseStatus)
		fmt.Fprint(w, leaseBody)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return newGatewayClient(srv.URL, gwDefault)
}

// frcNames is the clause's "this renewal names" part for the whole footprint, computed here, not by the helper.
func frcNames(want map[string]int64) string {
	var s int64
	for _, n := range want {
		if n > 0 {
			s += n
		}
	}
	return fmt.Sprintf("this renewal names %d MiB in %d refs (NWP-20261203-19)", s>>20, len(want))
}

// frcNoProfileMaterial fails when the error carries a ref, a key or the profile's metering key.
func frcNoProfileMaterial(t *testing.T, msg string, f *renewBatchFixture) {
	t.Helper()
	for _, bad := range []string{"blob/", "ref/", profileRefV2(f.name, f.p2)} {
		if strings.Contains(msg, bad) {
			t.Fatalf("the refusal line carries %q: %s", bad, msg)
		}
	}
}

func TestFreeRefusalCounts_Helper(t *testing.T) {
	refs := map[string]int64{"a": 3 << 20, "b": 2<<20 + 5, "z": 0, "neg": -(7 << 20)}
	ent := entitlementInfo{UsedBytes: 1200 << 20, FreeBytes: 1 << 30}
	if got, want := freeRefusalCounts(ent, true, refs),
		"gateway counts 1200 MiB live of a 1024 MiB free allowance; this renewal names 5 MiB in 4 refs (NWP-20261203-19)"; got != want {
		t.Fatalf("answered:\n got %q\nwant %q", got, want)
	}
	got := freeRefusalCounts(ent, false, refs)
	if want := "gateway count unread; this renewal names 5 MiB in 4 refs (NWP-20261203-19)"; got != want {
		t.Fatalf("unread:\n got %q\nwant %q", got, want)
	}
	if strings.Contains(got, "0 MiB live") || strings.Contains(got, "1200") {
		t.Fatalf("unread arm states a count it did not read: %q", got)
	}
}

func TestFreeRefusalCounts_PayRent402(t *testing.T) {
	f := renewBatchSetup(t, "frc2", 0)
	want := renewBatchFootprint(t, f)
	leases := 0
	f.gw = frcGateway(t, http.StatusOK, http.StatusPaymentRequired, `{"error":"free quota exceeded"}`, &leases)
	leaseBatchRefs = 3
	if len(want) <= leaseBatchRefs {
		t.Fatalf("fixture gives %d refs, need more than one batch of %d", len(want), leaseBatchRefs)
	}
	_, _, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil)
	if err == nil {
		t.Fatal("payRent: a 402 free renewal returned no error")
	}
	msg := err.Error()
	for _, sub := range []string{
		`free tier unavailable for "frc2" (HTTP 402, gateway said: free quota exceeded; `,
		"gateway counts 1200 MiB live of a 1024 MiB free allowance; ",
		frcNames(want) + ") -- add credit",
	} {
		if !strings.Contains(msg, sub) {
			t.Fatalf("the refusal line lacks %q:\n%s", sub, msg)
		}
	}
	frcNoProfileMaterial(t, msg, f)
	if leases != 1 {
		t.Fatalf("%d /lease requests, want 1: the first-batch refusal returns", leases)
	}
}

func TestFreeRefusalCounts_EntitlementDown(t *testing.T) {
	f := renewBatchSetup(t, "frc3", 0)
	want := renewBatchFootprint(t, f)
	leases := 0
	f.gw = frcGateway(t, http.StatusServiceUnavailable, http.StatusPaymentRequired, `{"error":"free quota exceeded"}`, &leases)
	leaseBatchRefs = 3
	_, _, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil)
	if err == nil {
		t.Fatal("payRent: a 402 free renewal returned no error")
	}
	msg := err.Error()
	if sub := "gateway said: free quota exceeded; gateway count unread; " + frcNames(want) + ") -- add credit"; !strings.Contains(msg, sub) {
		t.Fatalf("the refusal line lacks %q:\n%s", sub, msg)
	}
	if strings.Contains(msg, "MiB live") {
		t.Fatalf("an unanswered /entitlement printed a live count: %s", msg)
	}
	frcNoProfileMaterial(t, msg, f)
}

func TestFreeRefusalCounts_OtherStatusUnchanged(t *testing.T) {
	f := renewBatchSetup(t, "frc4", 0)
	leases := 0
	f.gw = frcGateway(t, http.StatusOK, http.StatusForbidden, `{"error":"free tier disabled"}`, &leases)
	_, _, err := payRent(f.gw, f.base, f.name, f.p2, f.wpath, nil)
	if err == nil {
		t.Fatal("payRent: a 403 free renewal returned no error")
	}
	if got, want := err.Error(), `pay-rent: free tier unavailable for "frc4" (HTTP 403, gateway said: free tier disabled) -- add credit`; got != want {
		t.Fatalf("a 403 changed its line:\n got %q\nwant %q", got, want)
	}
}
