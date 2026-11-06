package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// NWP-20260820-33. These tests pin the two properties that let the head-blob prefetch exist at all, plus the
// seal-path guard. Background: five designs for cutting login head resolution were adversarially reviewed and
// refuted; the fatal defect in the closest one was staging the HEAD DECISION, which bypassed the #139
// deleted-profile gate and reused stale heads. This design stages only content-addressed BYTES, so the
// properties to pin are (1) a warm cache removes the blob fetches and NOTHING else -- every ref probe stays
// live -- and (2) a head that moves after the prefetch is picked up correctly, because a different hash simply
// misses the cache. If (2) ever fails, this file has become the design that was refuted.

// countingStore is newHTTPStore's shape plus per-path hit counters, so a test can assert not just WHAT
// resolved but HOW MANY network reads it took -- the entire point of the prefetch.
func countingStore(t *testing.T) (base string, refReads, blobReads *int64) {
	t.Helper()
	var mu sync.Mutex
	var rr, br int64
	blobs := map[string][]byte{}
	refs := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			h := sha256.Sum256(body)
			key := hex.EncodeToString(h[:])
			blobs[key] = body
			io.WriteString(w, key)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			br++
			if b, ok := blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			body, _ := io.ReadAll(r.Body)
			refs[strings.TrimPrefix(r.URL.Path, "/ref/")] = string(body)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/ref/"):
			rr++
			if v, ok := refs[strings.TrimPrefix(r.URL.Path, "/ref/")]; ok {
				io.WriteString(w, v)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL, &rr, &br
}

// seedLegacyProfile writes a minimal legacy-shaped profile (head blob IS the sealed manifest) and returns
// the head hash.
func seedLegacyProfile(t *testing.T, base, name, pass string) string {
	t.Helper()
	mj, _ := json.Marshal(Manifest{})
	head := postBlob(base, seal(deriveKey(name, pass), mj))
	putRef(base, profileRefV2(name, pass), head)
	return head
}

func TestPrefetchRemovesBlobReadsAndOnlyBlobReads(t *testing.T) {
	base, refReads, blobReads := countingStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	const name, pass = "warmco", "correct horse battery staple"
	seedLegacyProfile(t, base, name, pass)

	// COLD baseline: what one resolve costs with no cache present.
	key1, m1, ok1 := resolveKey(base, name, pass)
	if !ok1 {
		t.Fatal("cold resolve failed")
	}
	coldRefs, coldBlobs := *refReads, *blobReads
	if coldBlobs == 0 {
		t.Fatal("test store not counting blob reads -- the assertions below would be vacuous")
	}
	// The cold resolve WROTE BACK to the cache (headBlobGet populates on miss -- deliberate, so the first
	// restore process to fetch a blob warms it for the five that follow even without a prefetch). Clear it
	// so the prefetch below is measured from genuinely cold, or its network delta is zero by construction.
	os.RemoveAll(headBlobCacheDir())

	// Prefetch, then resolve again. The blob read must come from the cache; the ref probes must stay LIVE
	// (same count as the cold resolve). If refs drop, the prefetch has started caching the head DECISION,
	// which is the refuted design.
	prefetchHeadBlobs(base, name, pass)
	prefRefs, prefBlobs := *refReads-coldRefs, *blobReads-coldBlobs
	if prefBlobs == 0 {
		t.Fatal("prefetch fetched no blobs -- it is inert")
	}
	key2, m2, ok2 := resolveKey(base, name, pass)
	if !ok2 {
		t.Fatal("warm resolve failed")
	}
	warmRefs := *refReads - coldRefs - prefRefs
	warmBlobs := *blobReads - coldBlobs - prefBlobs
	if warmBlobs != 0 {
		t.Fatalf("warm resolve did %d blob reads, want 0 -- the cache is not being consulted", warmBlobs)
	}
	if warmRefs != coldRefs {
		t.Fatalf("warm resolve did %d ref reads vs cold %d -- ref probes must stay LIVE and identical", warmRefs, coldRefs)
	}
	if string(key1) != string(key2) || string(m1) != string(m2) {
		t.Fatal("warm resolve returned different key/manifest than cold -- the cache served wrong bytes")
	}
}

func TestPrefetchedCacheCannotServeAMovedHead(t *testing.T) {
	base, _, blobReads := countingStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	const name, pass = "moveco", "correct horse battery staple"
	seedLegacyProfile(t, base, name, pass)
	prefetchHeadBlobs(base, name, pass)

	// The head MOVES after the prefetch: a new manifest is sealed and the ref repointed -- the exact
	// concurrent-seal scenario whose staleness killed the head-staging design.
	mj, _ := json.Marshal(Manifest{Items: []Item{{Name: "moved", Ref: "r", Size: 1}}})
	newHead := postBlob(base, seal(deriveKey(name, pass), mj))
	putRef(base, profileRefV2(name, pass), newHead)

	before := *blobReads
	_, m, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("resolve after head move failed")
	}
	if *blobReads-before == 0 {
		t.Fatal("no blob read after the head moved -- the cache served STALE bytes for a moved head")
	}
	var got Manifest
	if err := json.Unmarshal(unseal(deriveKey(name, pass), m), &got); err != nil || len(got.Items) != 1 || got.Items[0].Name != "moved" {
		t.Fatalf("resolve returned the OLD manifest after the head moved: %v %v", got, err)
	}
}

func TestPrefetchStagesNothingForBlankOrWrongPass(t *testing.T) {
	base, refReads, blobReads := countingStore(t)
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	const name, pass = "blindco", "correct horse battery staple"
	seedLegacyProfile(t, base, name, pass)

	// Wrong passphrase: refs derive to nothing that exists -> probes only, zero blob reads, nothing staged.
	b0 := *blobReads
	prefetchHeadBlobs(base, name, "the wrong passphrase entirely")
	if *blobReads-b0 != 0 {
		t.Fatalf("wrong-pass prefetch read %d blobs, want 0", *blobReads-b0)
	}
	// Unknown profile: same.
	r0, b1 := *refReads, *blobReads
	prefetchHeadBlobs(base, "nosuchprofile", pass)
	if *blobReads-b1 != 0 {
		t.Fatalf("unknown-profile prefetch read %d blobs, want 0", *blobReads-b1)
	}
	if *refReads == r0 {
		t.Fatal("unknown-profile prefetch probed nothing -- it must still probe (the miss is what keeps it blind)")
	}
}

func TestPushSetNeverSealsTheHeadBlobCache(t *testing.T) {
	base, _, _ := countingStore(t)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	root := t.TempDir()
	for _, d := range []string{"realdata", "headblobs"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, d, "f"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	const name, pass = "sealco", "correct horse battery staple"
	if n := pushSet(base, name, pass, root); n != 1 {
		t.Fatalf("pushSet sealed %d items, want 1 (realdata only, never headblobs)", n)
	}
}
