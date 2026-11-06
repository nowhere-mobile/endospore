package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// meterSpy is a minimal managed-store gateway that records the PROFILE each lease is metered under. It
// answers the free tier, which is all a small seal needs -- the point is WHICH identity is presented, not
// what it costs.
func meterSpy(t *testing.T) (*httptest.Server, func() []string, map[string][]byte, *sync.Mutex) {
	t.Helper()
	var mu sync.Mutex
	seen := []string{}
	objs := map[string][]byte{}
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		mu.Lock()
		defer mu.Unlock()
		switch r.Method {
		case "PUT":
			b := make([]byte, r.ContentLength)
			if r.ContentLength > 0 {
				if _, err := r.Body.Read(b); err != nil && err.Error() != "EOF" {
					t.Log(err)
				}
			}
			objs[k] = b
			w.WriteHeader(http.StatusOK)
		default:
			if b, ok := objs[k]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		}
	})
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		ref := r.URL.Query().Get("ref")
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)})
	})
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		seen = append(seen, req.Profile)
		mu.Unlock()
		caps := map[string]string{}
		for ref := range req.Refs {
			caps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, Spent: 0, WriteCaps: caps})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, func() []string { mu.Lock(); defer mu.Unlock(); return append([]string(nil), seen...) }, objs, &mu
}

// NWP-20260904-03. Chester, frankel 2026090320, on a 50 GB plan with 88 days left and 10.21 GB used:
// "Why cant I logoff?" -> ERR-NOCREDIT PARTIAL:media=nocredit.
//
// payRent buys the plan under profileRefV2(BARE). Every seal metered under profileRefV2(SCOPE) -- unrelated
// HMACs, and the gateway strips nothing -- so a paid profile presented each scope as a stranger, and the one
// scope over the free allowance was refused.
//
// This drives the REAL capFlush and asserts the identity the gateway is handed. An earlier version of this
// test asserted capSession.base instead, which is a restatement of the fix rather than a test of it: the
// mutation that put profileRefV2(sess.name) back did NOT convict it.
func TestScopeSealMetersUnderTheProfileRef(t *testing.T) {
	srv, seenProfiles, objs, mu := meterSpy(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_WALLET", filepath.Join(t.TempDir(), "wallet.json"))
	capReadCache = map[string]capEntry{}
	blobCache = nil

	const name, pass = "alice", "correct horse battery staple"
	bare := profileRefV2(name, pass)
	scoped := profileRefV2(name+"#media", pass)

	bn := capBegin()
	capSetSession(name+"#media", pass, deriveKey(name+"#media", pass))
	h := postBlob("s3", []byte("some media bytes"))
	putRef("s3", scoped, h)
	capFlush(bn)

	got := seenProfiles()
	if len(got) == 0 {
		t.Fatal("the seal never reached /lease -- nothing was metered, so this proves nothing")
	}
	for _, p := range got {
		if p == scoped {
			t.Errorf("a #media seal metered under the SCOPE ref %s; the plan is bought under %s", short(p), short(bare))
		}
		if p != bare {
			t.Errorf("metered under %s, want the profile ref %s", short(p), short(bare))
		}
	}

	// And the wallet fold must not have written a per-scope wallet head: sess.dk on a scope seal is the
	// SCOPE key, so such a head is sealed with a key the real wallet reader does not hold.
	mu.Lock()
	defer mu.Unlock()
	for k := range objs {
		if strings.Contains(k, profileRefV2(name+"#media#wallet", pass)) {
			t.Errorf("a scope seal wrote a per-scope wallet head at %s -- unreadable by the wallet reader", short(k))
		}
	}
}

// Strips a KNOWN suffix, not everything after the first "#": the name is user-chosen, and re-pointing "a#b"
// at "a" would meter one profile against another's entitlement -- the same bug, caused by its own fix.
func TestProfileBaseNameDoesNotMangleAUserChosenHash(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"alice", "alice"},
		{"alice#media", "alice"},
		{"alice#wallet", "alice"},
		{"a#b", "a#b"},
		{"team#1", "team#1"},
		{"m#media#media", "m#media"},
	} {
		if got := profileBaseName(c.in); got != c.want {
			t.Errorf("profileBaseName(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
