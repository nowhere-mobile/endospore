package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The best-effort rent payment no longer ends in a recover that prints nothing (NWP-20261027-16).

// mrlLine returns the one stderr line that holds want, or fails.
func mrlLine(t *testing.T, stderr, want string) string {
	t.Helper()
	for _, l := range strings.Split(stderr, "\n") {
		if strings.Contains(l, want) {
			return l
		}
	}
	t.Fatalf("no stderr line holds %q; stderr:\n%s", want, stderr)
	return ""
}

func TestMaybePayRentLogsAFailedStoreRead(t *testing.T) {
	t.Cleanup(rgReset)
	const name = "mrl-payrent-fail"
	oldBase, oldCache := s3RetryBase, capReadCache
	s3RetryBase = time.Millisecond
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() { s3RetryBase, capReadCache = oldBase, oldCache })
	// A gateway that quotes and then fails every store request: the head read in resolveDKVault is what panics.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/quote" {
			json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42})
			return
		}
		http.Error(w, "store down", http.StatusServiceUnavailable)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	dest := rgSession(t, name)
	got := rgStderr(t, func() { maybePayRent(dest, name, "pw", walletGeneration(walletPathFor(dest))) })
	l := mrlLine(t, got, `[logind] pay-rent "`+name+`" -> skipped: store read FAILED after retries (`)
	if ref := profileRefV2(name, "pw"); strings.Contains(l, ref) {
		t.Errorf("the FAILED line carries the profile ref: %s", l)
	}
}

func TestBestEffortPanic_StoreFailureIsLoggedScrubbed(t *testing.T) {
	const name = "mrl-scrub-name"
	hexRef := strings.Repeat("ab12", 16)
	e := storeReadErr{fmt.Errorf(`Get "http://store.invalid/bucket/ref/%s?X-Amz-Signature=sigsecret&X-Amz-Credential=credsecret": EOF`, hexRef)}
	got := rgStderr(t, func() { bestEffortPanic("pay-rent", name, e) })
	if n := strings.Count(got, "\n"); n != 1 {
		t.Errorf("want exactly one line, got %d:\n%s", n, got)
	}
	want := `[logind] pay-rent "` + name + `" -> skipped: store read FAILED after retries (`
	if !strings.Contains(got, want) {
		t.Errorf("missing %q in:\n%s", want, got)
	}
	for _, leak := range []string{hexRef, "X-Amz-", "sigsecret", "credsecret", "?"} {
		if strings.Contains(got, leak) {
			t.Errorf("the line leaks %q:\n%s", leak, got)
		}
	}
}

func TestBestEffortPanic_OtherValuesAreWithheld(t *testing.T) {
	const name = "mrl-withheld-name"
	hexKey := strings.Repeat("cd34", 16)
	for _, r := range []any{"corrupt head blob blob/" + hexKey, errors.New("plain failure blob/" + hexKey)} {
		got := rgStderr(t, func() { bestEffortPanic("pay-rent", name, r) })
		want := `[logind] pay-rent "` + name + `" -> skipped: unexpected failure (details withheld)`
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
		if strings.Contains(got, hexKey) || strings.Contains(got, "blob/") || strings.Contains(got, "FAILED") {
			t.Errorf("the generic line leaks the value:\n%s", got)
		}
	}
}

func TestBestEffortPanic_NilPrintsNothing(t *testing.T) {
	if got := rgStderr(t, func() { bestEffortPanic("pay-rent", "mrl-nil-name", nil) }); got != "" {
		t.Errorf("a nil recover printed %q", got)
	}
}
