package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261122-04 (h50 #9): an export-bundle probe on the managed store that gets a 403 on a FRESH cap is a read that
// could not tell, never absence -- so a Delete must not skip the bundle and answer done.

// capExistsFront points the cap-mode store at a reverse proxy over srvURL that counts every GET of the object key and
// answers 403 to the n-th one (1-based) when refuse(n) is true; everything else passes through. It is
// fpRefusedCapProxy with a counter and a policy.
func capExistsFront(t *testing.T, srvURL, key string, refuse func(n int32) bool) *atomic.Int32 {
	t.Helper()
	target, err := url.Parse(srvURL)
	if err != nil {
		t.Fatal(err)
	}
	var n atomic.Int32
	proxy := httputil.NewSingleHostReverseProxy(target)
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" && r.URL.Query().Get("k") == key {
			if refuse(n.Add(1)) {
				w.WriteHeader(http.StatusForbidden)
				return
			}
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
	return &n
}

// capExistsSession is exportSession with the export day pinned and a short store backoff.
func capExistsSession(t *testing.T, name, pass string, export bool) (dest string, b exportRef, srvURL string) {
	t.Helper()
	dest, _, _ = exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	if export {
		if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
			t.Fatalf("EXPORT replied %q", got)
		}
	}
	return dest, exportBundleRef(deriveKey(name, pass), exportTestDay), os.Getenv("GATEWAY_URL")
}

func TestCapRefExistsFresh403IsAnError(t *testing.T) {
	_, b, srv := capExistsSession(t, "capexistsfresh", "a fresh cap still gets a 403", true)
	n := capExistsFront(t, srv, b.key, func(int32) bool { return true })
	exists, err := capRefExists(b.key)
	if err == nil || exists {
		t.Fatalf("capRefExists on a fresh-cap 403 = (%v, %v), want (false, an error): it read the refusal as absence", exists, err)
	}
	if got := n.Load(); got != 2 {
		t.Errorf("the store saw %d GET(s) of the bundle, want 2: the stale-cap retry and the fresh one", got)
	}
	if !errors.Is(err, errStorePermanent) {
		t.Errorf("the fresh-cap 403 error does not wrap errStorePermanent, so retryStore spends its attempts: %v", err)
	}
	if strings.Contains(err.Error(), b.name()) {
		t.Fatal("the fresh-cap 403 error carries the bundle's key")
	}
}

func TestCapRefExistsStale403ThenPresent(t *testing.T) {
	_, b, srv := capExistsSession(t, "capexistsstale", "only the first cap is stale", true)
	n := capExistsFront(t, srv, b.key, func(i int32) bool { return i == 1 })
	exists, err := capRefExists(b.key)
	if err != nil || !exists {
		t.Fatalf("capRefExists after one stale-cap 403 = (%v, %v), want (true, nil)", exists, err)
	}
	if got := n.Load(); got != 2 {
		t.Fatalf("the store saw %d GET(s) of the bundle, want 2", got)
	}
}

func TestDeleteWhoseExportProbeGetsAFresh403IsUnverified(t *testing.T) {
	const name, pass = "capexistsdelete", "the bundle probe meets a 403"
	_, b, srv := capExistsSession(t, name, pass, true)
	capExistsFront(t, srv, b.key, func(int32) bool { return true })
	if got := deleteProfile("s3", name, pass); got != "unverified" {
		t.Fatalf("deleteProfile = %q while the bundle probe got a fresh-cap 403, want unverified", got)
	}
	if _, _, ok := resolveKey("s3", name, pass); !ok {
		t.Fatal("the profile's head no longer resolves after a Delete that answered unverified: nothing was to be deleted")
	}
	v, err := readSessionVault("s3", name, pass)
	if err != nil || v.RecoveryRef == "" || getRef("s3", v.RecoveryRef) == "" {
		t.Fatal("the recovery ref no longer resolves after a Delete that answered unverified: nothing was to be deleted")
	}
	t.Cleanup(func() { liftSealFence(scopedDeleteRefs(name, pass)) })
	if sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("the unverified Delete armed the publish fence: the session that is still signed in can no longer seal")
	}
}

func TestDeleteOfANeverExportedProfileStillCompletes(t *testing.T) {
	const name, pass = "capexistsnever", "this profile never exported"
	_, b, srv := capExistsSession(t, name, pass, false)
	n := capExistsFront(t, srv, b.key, func(int32) bool { return false })
	if got := deleteProfile("s3", name, pass); got != "deleted" {
		t.Fatalf("deleteProfile of a never-exported profile = %q, want deleted", got)
	}
	if n.Load() == 0 {
		t.Fatal("precondition: the Delete never probed today's bundle, so this test shows nothing")
	}
	if _, _, ok := resolveKey("s3", name, pass); ok {
		t.Fatal("the profile still resolves after a Delete that answered deleted")
	}
}
