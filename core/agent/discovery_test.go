package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"golang.org/x/crypto/argon2"
)

// A fresh device with only DISCO_ENDPOINT + DISCO_BUCKET (no creds) bootstraps its store config from a
// public-read discovery bucket over an anonymous HTTP GET -- proving the keyless lookup path end to end
// (URL build + GET + unseal). Discovery only holds sealed blobs at unguessable refs, so public-read is safe.
func TestDiscoAnonLookup(t *testing.T) {
	name, pass := "alice", "correct horse battery"
	cfg := "S3_ENDPOINT=https://s3.filebase.io\nS3_REGION=auto\nS3_BUCKET=data\nS3_ACCESS_KEY=AK\nS3_SECRET_KEY=SK\n"
	sealed := wrap(bootstrapKey(name, pass), []byte(cfg)) // exactly what publishDiscovery would PUT
	bucket := "disco-bucket"
	wantPath := "/" + bucket + "/ref/" + bootstrapRef(name, pass)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == wantPath {
			io.WriteString(w, sealed)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	t.Setenv("DISCO_ENDPOINT", srv.URL)
	t.Setenv("DISCO_BUCKET", bucket)
	t.Setenv("DISCO_ACCESS_KEY", "") // no creds -> anonymous path
	t.Setenv("DISCO_SECRET_KEY", "")

	if !discoCanLookup() {
		t.Fatal("endpoint+bucket should be enough to look up")
	}
	if discoConfigured() {
		t.Fatal("with no keys the device must NOT be publish-configured")
	}

	got, ok := discoverConfig("disco", name, pass)
	if !ok {
		t.Fatal("anonymous discovery lookup should succeed against a public-read bucket")
	}
	if got != cfg {
		t.Fatalf("discovered config mismatch:\n got %q\nwant %q", got, cfg)
	}

	// Blind: a wrong passphrase derives a different bootstrapRef -> a GET miss, indistinguishable.
	if _, ok := discoverConfig("disco", name, "wrong-pass"); ok {
		t.Fatal("a wrong passphrase must miss (blind login)")
	}
}

// TestGatewayRoamsViaDiscovery (DIA-20260627-B / B.4): the billing GATEWAY_URL rides the sealed store-config
// so a user's gateway re-materializes on another device from name+pass alone; an empty gateway is omitted.
func TestGatewayRoamsViaDiscovery(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "gw", "roam my gateway too"

	publishDiscovery(base, name, pass,
		"https://s3.test", "auto", "bkt", "AK", "SK", "https://gw.nowhere.mobile")
	cfg, ok := discoverConfig(base, name, pass)
	if !ok {
		t.Fatal("discover after publish should succeed")
	}
	if !strings.Contains(cfg, "GATEWAY_URL=https://gw.nowhere.mobile") {
		t.Fatalf("gateway URL did not roam with the store config:\n%s", cfg)
	}

	// an empty gateway is omitted: older readers see only the S3_* lines.
	publishDiscovery(base, name, pass, "https://s3.test", "auto", "bkt", "AK", "SK", "")
	cfg2, _ := discoverConfig(base, name, pass)
	if strings.Contains(cfg2, "GATEWAY_URL") {
		t.Fatalf("an empty gateway should be omitted from the roamed config:\n%s", cfg2)
	}
}

// ---- NWP-20261117-08 (#32): bootstrapRef is KDF-derived, with no lookup of the old sha256 form. ----

// discoRefShaForm is the OLD discovery key: a bare sha256 of name and passphrase. Nothing may request it.
func discoRefShaForm(name, pass string) string {
	h := sha256.Sum256([]byte("nowhere-bootstrap-ref:" + name + "\x00" + pass))
	return hex.EncodeToString(h[:])
}

// discoRefHMACForm is the decided discovery key, computed here from first principles (never through deriveKey or
// bootstrapRef): HMAC-SHA256 keyed by the Argon2id root key, under the discovery's own label.
func discoRefHMACForm(name, pass string) string {
	salt := sha256.Sum256([]byte("nowhere-salt:" + name))
	k := argon2.IDKey([]byte(pass), salt[:], 1, 64*1024, 4, 32)
	mac := hmac.New(sha256.New, k)
	mac.Write([]byte("nowhere-bootstrap-ref-v2"))
	return hex.EncodeToString(mac.Sum(nil))
}

// discoRefSpy is a ref store at <prefix>/ref/<key> that logs every request as "METHOD PATH". notFound makes every
// GET miss. It returns the server, a seed func and a snapshot of the log.
func discoRefSpy(t *testing.T, prefix string, notFound bool) (*httptest.Server, func(key, val string), func() []string) {
	t.Helper()
	var mu sync.Mutex
	refs := map[string]string{}
	var reqs []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		reqs = append(reqs, r.Method+" "+r.URL.Path)
		key, isRef := strings.CutPrefix(r.URL.Path, prefix+"/ref/")
		switch {
		case isRef && r.Method == "PUT":
			body, _ := io.ReadAll(r.Body)
			refs[key] = string(body)
		case isRef && r.Method == "GET" && !notFound:
			if v, ok := refs[key]; ok {
				io.WriteString(w, v)
				return
			}
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	seed := func(key, val string) { mu.Lock(); refs[key] = val; mu.Unlock() }
	log := func() []string { mu.Lock(); defer mu.Unlock(); return append([]string(nil), reqs...) }
	return srv, seed, log
}

// discoRefNamesKey reports whether any logged request path contains key.
func discoRefNamesKey(reqs []string, key string) bool {
	for _, r := range reqs {
		if strings.Contains(r, key) {
			return true
		}
	}
	return false
}

// The published discovery object lands at the HMAC form, and only there: no request names the sha256 form.
func TestDiscoRefPublishedKeyIsKDFDerived(t *testing.T) {
	name, pass := "discoref-a", "a passphrase for the published key"
	srv, _, reqs := discoRefSpy(t, "", false)
	publishDiscovery(srv.URL, name, pass, "https://s3.test", "auto", "bkt", "AK", "SK", "")
	want := "PUT /ref/" + discoRefHMACForm(name, pass)
	var puts []string
	for _, r := range reqs() {
		if strings.HasPrefix(r, "PUT ") {
			puts = append(puts, r)
		}
	}
	if len(puts) != 1 || puts[0] != want {
		t.Errorf("publish PUTs = %q, want exactly [%q]", puts, want)
	}
	if discoRefNamesKey(reqs(), discoRefShaForm(name, pass)) {
		t.Errorf("a request named the old sha256 discovery key: %q", reqs())
	}
}

// The lookup requests the HMAC form and nothing else: a record still at the old sha256 key does not resolve (#32: no
// transitional lookup), a republished one does, and a wrong passphrase still misses (blind).
func TestDiscoRefLookupRequestsOnlyTheKDFKey(t *testing.T) {
	name, pass := "discoref-b", "a passphrase for the lookup"
	cfg := "S3_ENDPOINT=https://s3.test\nS3_REGION=auto\nS3_BUCKET=bkt\nS3_ACCESS_KEY=AK\nS3_SECRET_KEY=SK\n"
	srv, seed, reqs := discoRefSpy(t, "", false)
	sha := discoRefShaForm(name, pass)
	seed(sha, wrap(bootstrapKey(name, pass), []byte(cfg)))

	if _, ok := discoverConfig(srv.URL, name, pass); ok {
		t.Errorf("a record only at the old sha256 key resolved: the lookup reads the old form")
	}
	if want := "GET /ref/" + discoRefHMACForm(name, pass); !discoRefNamesKey(reqs(), want) {
		t.Errorf("the lookup did not request %q: %q", want, reqs())
	}
	if discoRefNamesKey(reqs(), sha) {
		t.Errorf("the lookup requested the old sha256 key: %q", reqs())
	}

	publishDiscovery(srv.URL, name, pass, "https://s3.test", "auto", "bkt", "AK", "SK", "")
	if got, ok := discoverConfig(srv.URL, name, pass); !ok || got != cfg {
		t.Errorf("lookup after a republish = %q, %v; want the config", got, ok)
	}
	if _, ok := discoverConfig(srv.URL, name, "wrong-pass"); ok {
		t.Errorf("a wrong passphrase must miss (blind login)")
	}
	if discoRefNamesKey(reqs(), sha) {
		t.Errorf("a request named the old sha256 key: %q", reqs())
	}
}

// The discovery key is the HMAC form under its OWN label, so it never equals the profile's head key.
func TestDiscoRefDistinctFromProfileRef(t *testing.T) {
	name, pass := "discoref-c", "a passphrase for the label"
	got := bootstrapRef(name, pass)
	if want := discoRefHMACForm(name, pass); got != want {
		t.Errorf("bootstrapRef = %s, want the HMAC form %s", got, want)
	}
	if got == profileRefV2(name, pass) {
		t.Errorf("bootstrapRef equals profileRefV2: the discovery key is the profile head key")
	}
	if got == discoRefShaForm(name, pass) {
		t.Errorf("bootstrapRef is still the sha256 form")
	}
}

// A publish then a lookup in one process cost one Argon2 run of deriveKey: the ref shares the memoized key.
func TestDiscoRefOneArgon2PerProcess(t *testing.T) {
	name, pass := "discoref-d", "a passphrase for the memo"
	srv, _, _ := discoRefSpy(t, "", false)
	deriveKeyMu.Lock()
	delete(deriveKeyCache, name+"\x00"+pass)
	before := deriveKeyMisses
	deriveKeyMu.Unlock()

	publishDiscovery(srv.URL, name, pass, "https://s3.test", "auto", "bkt", "AK", "SK", "")
	if _, ok := discoverConfig(srv.URL, name, pass); !ok {
		t.Errorf("lookup after publish missed")
	}

	deriveKeyMu.Lock()
	delta := deriveKeyMisses - before
	deriveKeyMu.Unlock()
	if delta != 1 {
		t.Errorf("publish + lookup ran deriveKey's Argon2 %d time(s), want exactly 1", delta)
	}
}

// A NOSTORE device's lookup that misses leaves no derived key at the gate (dn-1106 #1): bootstrapRef now derives K,
// so tryDiscover forgets the KDF cache on a false return after the lookup.
func TestDiscoRefNoStoreMissForgetsTheKey(t *testing.T) {
	name, pass := "discoref-e", "a passphrase for the miss"
	for _, k := range []string{"S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY", "GATEWAY_URL"} {
		t.Setenv(k, "")
	}
	if storeConfigured() {
		t.Fatal("setup: the store must be unconfigured")
	}
	srv, _, reqs := discoRefSpy(t, "/disco-bucket", true)
	discoBoundFixture(t, srv, false)
	deriveKeyMu.Lock()
	delete(deriveKeyCache, name+"\x00"+pass)
	deriveKeyMu.Unlock()

	var found bool
	captureStderr(t, func() { found = tryDiscover(name, pass) })
	if found {
		t.Errorf("tryDiscover found a config on a store that answers 404")
	}
	if want := "GET /disco-bucket/ref/" + discoRefHMACForm(name, pass); !discoRefNamesKey(reqs(), want) {
		t.Errorf("the NOSTORE lookup did not request %q: %q", want, reqs())
	}
	deriveKeyMu.Lock()
	_, held := deriveKeyCache[name+"\x00"+pass]
	deriveKeyMu.Unlock()
	if held {
		t.Errorf("a NOSTORE miss left the typed name, passphrase and root key in the KDF cache")
	}
}
