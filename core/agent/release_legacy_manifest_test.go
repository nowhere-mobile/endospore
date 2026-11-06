package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// NWP-20261113-14: a manifest that decrypts under the DK and is not a CDC manifest -- the creation state createVault
// seals as an empty tar, which the first seal pushes into History -- is a whole-tar blob that names only itself. A
// profile delete releases its vault past it and a snapshot delete frees exactly its blob; a fetch or decrypt failure,
// a wrong key and CDC magic followed by JSON that does not parse still fail the set. test-release-legacy-manifest.sh
// re-runs this file against copies of snapshot_release.go with the rule broken in turn.

// relLegacy is a cap-mode profile sealed twice after createVault, so its History still holds the creation state,
// with a /release route that records each request's keys and releases them all.
type relLegacy struct {
	v        *vault
	dk       []byte
	creation string
	reqs     []map[string]string
	objs     map[string][]byte
	mu       *sync.Mutex
}

// put stores data as a blob straight in the mock store (a cap-mode postBlob needs a funded bracket) and returns its
// hash.
func (r *relLegacy) put(data []byte) string {
	h := sha256.Sum256(data)
	k := hex.EncodeToString(h[:])
	r.mu.Lock()
	r.objs["blob/"+k] = data
	r.mu.Unlock()
	return k
}

func relLegacySetup(t *testing.T, name, pass string) *relLegacy {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	freeRenewedThrough = map[string]int64{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	t.Setenv("NOWHERE_BLOBCACHE", dir)
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	blobCache = nil
	t.Cleanup(func() { blobCache = nil })
	capStoreLeaseStatus = func(leaseReq) (int, string) { return 200, "" }
	r := &relLegacy{objs: objs, mu: mu}
	capStoreRelease = func(b []byte) (int, string) {
		var in struct {
			Release map[string]string `json:"release"`
		}
		if json.Unmarshal(b, &in) != nil || in.Release == nil {
			return 400, `{"error":"bad"}`
		}
		r.reqs = append(r.reqs, in.Release)
		out := []string{}
		for k := range in.Release {
			out = append(out, k)
		}
		body, _ := json.Marshal(map[string]any{"released": out})
		return 200, string(body)
	}
	snapDelSeals(t, "s3", name, pass, 2)
	r.v, r.dk = snapDelHead(t, "s3", name, pass)
	if len(r.v.History) < 2 {
		t.Fatalf("fixture: history %v, want the creation state and a sealed version", snapDelVersions(r.v.History))
	}
	// The evidence the History keeps the creation state: its oldest entry decrypts under the DK and is not CDC.
	r.creation = r.v.History[len(r.v.History)-1].Manifest
	if r.creation == "" {
		t.Fatal("fixture: the oldest History entry has no manifest")
	}
	if pt := unseal(r.dk, getBlob("s3", r.creation)); bytes.HasPrefix(pt, cdcMagic) {
		t.Fatal("fixture: the oldest History entry is a CDC manifest, not the creation state")
	}
	if _, ml := classifyManifestLoad("s3", r.dk, r.creation); ml != mlNotCDC {
		t.Fatalf("fixture: the creation state classifies as %v, want mlNotCDC", ml)
	}
	if _, ml := classifyManifestLoad("s3", r.dk, r.v.Manifest); ml != mlOK {
		t.Fatalf("fixture: the live manifest classifies as %v, want mlOK", ml)
	}
	for _, h := range r.v.History[:len(r.v.History)-1] {
		if _, ml := classifyManifestLoad("s3", r.dk, h.Manifest); ml != mlOK {
			t.Fatalf("fixture: kept v%d classifies as %v, want mlOK", h.Version, ml)
		}
	}
	return r
}

// relLegacyCDCBlobs is what a CDC manifest names, read independently of manifestBlobsStrict.
func relLegacyCDCBlobs(t *testing.T, dk []byte, hash string, into map[string]bool) {
	t.Helper()
	m, ml := classifyManifestLoad("s3", dk, hash)
	if ml != mlOK {
		t.Fatalf("fixture: %v is not a CDC manifest", ml)
	}
	into["blob/"+hash] = true
	for _, c := range m.Chunks {
		if c != "" {
			into["blob/"+c] = true
		}
	}
	for _, d := range m.Deferred {
		for _, c := range d.Chunks {
			if c != "" {
				into["blob/"+c] = true
			}
		}
	}
}

// (a) The delete set holds the creation state's blob and every blob of the live and kept CDC manifests, no more.
func TestReleaseLegacyManifestDeleteSetHoldsTheCreationState(t *testing.T) {
	r := relLegacySetup(t, "rellegacy-a", "rellegacy a passphrase")
	set, err := deleteReleaseSet("s3", r.dk, r.v)
	if err != nil {
		t.Fatalf("deleteReleaseSet: %v; want no error past the creation state", err)
	}
	want := map[string]bool{"blob/" + r.creation: true}
	relLegacyCDCBlobs(t, r.dk, r.v.Manifest, want)
	for _, h := range r.v.History[:len(r.v.History)-1] {
		relLegacyCDCBlobs(t, r.dk, h.Manifest, want)
	}
	if !set["blob/"+r.creation] {
		t.Errorf("the set lacks the creation state's blob")
	}
	if got, w := snapRelKeys(set), snapRelKeys(want); !reflect.DeepEqual(got, w) {
		t.Errorf("delete set\n got %v\nwant %v", got, w)
	}
}

// (b) The delete of that vault sends a release and logs the released line, not the skip.
func TestReleaseLegacyManifestDeleteReleasesTheVault(t *testing.T) {
	r := relLegacySetup(t, "rellegacy-b", "rellegacy b passphrase")
	out := snapRelStderr(t, func() { releaseDeletedProfile("s3", r.dk, r.v, nil) })
	if len(r.reqs) == 0 {
		t.Fatalf("no release was sent; output %q", out)
	}
	sent := map[string]bool{}
	for _, req := range r.reqs {
		for k := range req {
			sent[k] = true
		}
	}
	if !sent["blob/"+r.creation] {
		t.Errorf("the release does not name the creation state's blob")
	}
	if !strings.Contains(out, "object(s) of the profile's vault released") {
		t.Errorf("no released line in %q", out)
	}
	if strings.Contains(out, "nothing released early") {
		t.Errorf("the delete skipped the release: %q", out)
	}
}

// (c) A History entry that is CDC magic followed by bad JSON, a missing blob or one sealed under another DK still
// fails the whole set, and nothing is released.
func TestReleaseLegacyManifestStillFailsOnUnknown(t *testing.T) {
	r := relLegacySetup(t, "rellegacy-c", "rellegacy c passphrase")
	badJSON := r.put(seal(r.dk, append(append([]byte{}, cdcMagic...), '{')))
	m, err := json.Marshal(chunkManifest{Version: 1, Chunks: []string{snapRelHex("rellegacy-c-x")}})
	if err != nil {
		t.Fatal(err)
	}
	otherDK := r.put(seal(snapRelDK(77), append(append([]byte{}, cdcMagic...), m...)))
	missing := snapRelHex("rellegacy-c-missing")
	with := func(bad string) *vault {
		h := append(append([]headSnap{}, r.v.History...), headSnap{Version: 1, Manifest: bad})
		return &vault{Manifest: r.v.Manifest, History: h}
	}
	for name, bad := range map[string]string{"bad json": badJSON, "missing": missing, "other dk": otherDK} {
		set, err := deleteReleaseSet("s3", r.dk, with(bad))
		if err == nil || set != nil {
			t.Errorf("%s: got %v, %v; want (nil, error)", name, snapRelKeys(set), err)
		}
	}
	out := snapRelStderr(t, func() { releaseDeletedProfile("s3", r.dk, with(badJSON), nil) })
	if len(r.reqs) != 0 {
		t.Errorf("%d release request(s) sent past a manifest that does not parse", len(r.reqs))
	}
	if !strings.Contains(out, "nothing released early -- a version could not be read") {
		t.Errorf("no skip line in %q", out)
	}
	into := map[string]bool{"blob/x": true}
	if err := manifestBlobsStrict("s3", r.dk, badJSON, into); err == nil {
		t.Error("CDC magic followed by bad JSON was not an error")
	}
	if len(into) != 1 {
		t.Errorf("a manifest that does not parse changed the set: %v", snapRelKeys(into))
	}
}

// (d) Removing the creation state frees exactly its blob; a kept non-CDC live manifest protects exactly its own blob.
func TestReleaseLegacyManifestSnapshotSet(t *testing.T) {
	r := relLegacySetup(t, "rellegacy-d", "rellegacy d passphrase")
	removed := r.v.History[len(r.v.History)-1]
	kept := &vault{Manifest: r.v.Manifest, History: r.v.History[:len(r.v.History)-1]}
	set, err := snapshotReleaseSet("s3", r.dk, removed, kept)
	if err != nil {
		t.Fatalf("removing the creation state: %v", err)
	}
	if got, want := snapRelKeys(set), snapRelBlobs(r.creation); !reflect.DeepEqual(got, want) {
		t.Errorf("removing the creation state frees\n got %v\nwant %v", got, want)
	}

	base := newHTTPStore(t)
	dk := snapRelDK(61)
	notCDC := postBlob(base, seal(dk, []byte("not a manifest")))
	c1, c2 := snapRelHex("rellegacy-d-1"), snapRelHex("rellegacy-d-2")
	// The removed version also names the non-CDC blob, so "minus only that manifest's own blob" is observable.
	rm := snapRelManifest(t, base, dk, []string{c1, c2, notCDC}, nil)
	set, err = snapshotReleaseSet(base, dk, headSnap{Version: 7, Manifest: rm}, &vault{Manifest: notCDC})
	if err != nil {
		t.Fatalf("a kept live non-CDC manifest: %v", err)
	}
	if got, want := snapRelKeys(set), snapRelBlobs(rm, c1, c2); !reflect.DeepEqual(got, want) {
		t.Errorf("with a kept live non-CDC manifest the removed version frees\n got %v\nwant %v", got, want)
	}
}
