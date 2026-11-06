package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
)

// NWP-20261029-09: the strict release set, the blob cache eviction and the /release client. test-snapshot-release.sh
// re-runs this file against copies of snapshot_release.go with each guard broken in turn.

func snapRelDK(b byte) []byte {
	dk := make([]byte, 32)
	for i := range dk {
		dk[i] = b
	}
	return dk
}

func snapRelHex(tag string) string {
	h := sha256.Sum256([]byte(tag))
	return hex.EncodeToString(h[:])
}

// snapRelManifest stores a sealed CDC manifest naming the essential and deferred chunks and returns its hash.
func snapRelManifest(t *testing.T, base string, dk []byte, essential, deferred []string) string {
	t.Helper()
	m := chunkManifest{Version: 1, Chunks: essential}
	if len(deferred) > 0 {
		m.Deferred = map[string]deferredFile{"media/a.bin": {Chunks: deferred}}
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return postBlob(base, seal(dk, append(append([]byte{}, cdcMagic...), b...)))
}

func snapRelKeys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func snapRelBlobs(hs ...string) []string {
	var out []string
	for _, h := range hs {
		out = append(out, "blob/"+h)
	}
	sort.Strings(out)
	return out
}

func TestSnapshotReleaseSetIsTheRemovedVersionsUnsharedBlobs(t *testing.T) {
	base := newHTTPStore(t)
	dk := snapRelDK(1)
	c := func(s string) string { return snapRelHex("snaprel-a-" + s) }
	live := snapRelManifest(t, base, dk, []string{c("live"), c("shared-live")}, []string{c("dlive"), c("dshared-live")})
	keptE := snapRelManifest(t, base, dk, []string{c("kept"), c("shared-kept")}, []string{c("dkept"), c("dshared-kept")})
	gone := snapRelManifest(t, base, dk,
		[]string{c("own"), c("shared-live"), c("shared-kept")},
		[]string{c("down"), c("dshared-live"), c("dshared-kept")})
	kept := &vault{Manifest: live, History: []headSnap{{Version: 3, Manifest: keptE}}}
	got, err := snapshotReleaseSet(base, dk, headSnap{Version: 2, Manifest: gone}, kept)
	if err != nil {
		t.Fatal(err)
	}
	want := snapRelBlobs(gone, c("own"), c("down"))
	if g := snapRelKeys(got); !reflect.DeepEqual(g, want) {
		t.Errorf("release set\n got %v\nwant %v", g, want)
	}
}

func TestSnapshotReleaseSetOfTheLiveManifestIsEmpty(t *testing.T) {
	base := newHTTPStore(t)
	dk := snapRelDK(2)
	m := snapRelManifest(t, base, dk, []string{snapRelHex("snaprel-b-1")}, []string{snapRelHex("snaprel-b-2")})
	other := snapRelManifest(t, base, dk, []string{snapRelHex("snaprel-b-3")}, nil)
	for name, kept := range map[string]*vault{
		"live":         {Manifest: m},
		"kept entry":   {Manifest: other, History: []headSnap{{Version: 5, Manifest: m}}},
		"live + entry": {Manifest: m, History: []headSnap{{Version: 5, Manifest: m}}},
	} {
		got, err := snapshotReleaseSet(base, dk, headSnap{Version: 4, Manifest: m}, kept)
		if err != nil || len(got) != 0 {
			t.Errorf("%s: got %v, %v; want empty and no error", name, snapRelKeys(got), err)
		}
	}
}

// A retained duplicate of the removed manifest frees nothing, so no blob is read: an unreachable store (the manifest
// and an unrelated kept manifest both missing) must not turn that into an error.
func TestSnapshotReleaseSetOfAnUnreadableDuplicateIsEmpty(t *testing.T) {
	base := newHTTPStore(t)
	dk := snapRelDK(12)
	m := snapRelHex("snaprel-dup-missing")
	other := snapRelHex("snaprel-dup-other-missing")
	for name, kept := range map[string]*vault{
		"live":  {Manifest: m},
		"entry": {Manifest: other, History: []headSnap{{Version: 5, Manifest: other}, {Version: 6, Manifest: m}}},
	} {
		got, err := snapshotReleaseSet(base, dk, headSnap{Version: 4, Manifest: m}, kept)
		if err != nil || len(got) != 0 {
			t.Errorf("%s: got %v, %v; want empty and no error", name, snapRelKeys(got), err)
		}
	}
}

func TestSnapshotReleaseSetReleasesNothingWhenAManifestIsUnknown(t *testing.T) {
	base := newHTTPStore(t)
	dk := snapRelDK(3)
	good := snapRelManifest(t, base, dk, []string{snapRelHex("snaprel-c-1")}, nil)
	removed := snapRelManifest(t, base, dk, []string{snapRelHex("snaprel-c-2")}, nil)
	missing := snapRelHex("snaprel-c-missing")
	wrongKey := snapRelManifest(t, base, snapRelDK(9), []string{snapRelHex("snaprel-c-3")}, nil)
	badJSON := postBlob(base, seal(dk, append(append([]byte{}, cdcMagic...), []byte("{")...)))
	for name, c := range map[string]struct {
		rm   string
		kept *vault
	}{
		"kept history missing":  {removed, &vault{Manifest: good, History: []headSnap{{Version: 1, Manifest: missing}}}},
		"kept history wrongkey": {removed, &vault{Manifest: good, History: []headSnap{{Version: 1, Manifest: wrongKey}}}},
		"kept live missing":     {removed, &vault{Manifest: missing}},
		"kept live bad json":    {removed, &vault{Manifest: badJSON}},
		"kept history empty":    {removed, &vault{Manifest: good, History: []headSnap{{Version: 1}}}},
		"removed missing":       {missing, &vault{Manifest: good}},
		"removed wrongkey":      {wrongKey, &vault{Manifest: good}},
		"removed empty":         {"", &vault{Manifest: good}},
	} {
		got, err := snapshotReleaseSet(base, dk, headSnap{Version: 7, Manifest: c.rm}, c.kept)
		if err == nil || got != nil {
			t.Errorf("%s: got %v, %v; want (nil, error)", name, snapRelKeys(got), err)
		}
	}
}

func TestManifestBlobsStrictLeavesTheSetAloneOnFailure(t *testing.T) {
	base := newHTTPStore(t)
	dk := snapRelDK(4)
	into := map[string]bool{"blob/x": true}
	if err := manifestBlobsStrict(base, dk, snapRelHex("snaprel-d-missing"), into); err == nil {
		t.Fatal("a missing manifest blob was not an error")
	}
	if len(into) != 1 {
		t.Errorf("a failed read changed the set: %v", snapRelKeys(into))
	}
}

func snapRelCacheFile(t *testing.T, lines ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "blobcache.test")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestBlobCacheEvictRemovesExactlyTheNamedLines(t *testing.T) {
	a, b, c, d, e := snapRelHex("ev-a"), snapRelHex("ev-b"), snapRelHex("ev-c"), snapRelHex("ev-d"), snapRelHex("ev-e")
	p := snapRelCacheFile(t, a, b, c, d, e)
	blobCacheMu.Lock()
	saved := blobCache
	blobCache = map[string]bool{a: true, b: true, c: true, d: true, e: true}
	blobCacheMu.Unlock()
	defer func() { blobCacheMu.Lock(); blobCache = saved; blobCacheMu.Unlock() }()
	n, err := blobCacheEvict(p, map[string]bool{"blob/" + b: true, "blob/" + d: true})
	if err != nil || n != 2 {
		t.Fatalf("evict = %d, %v; want 2, nil", n, err)
	}
	raw, _ := os.ReadFile(p)
	if got, want := string(raw), strings.Join([]string{a, c, e}, "\n")+"\n"; got != want {
		t.Errorf("file\n got %q\nwant %q", got, want)
	}
	if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("file mode = %v, %v; want 0600", fi.Mode(), err)
	}
	ents, _ := os.ReadDir(filepath.Dir(p))
	if len(ents) != 1 {
		t.Errorf("the directory holds %d entries, want only the cache file", len(ents))
	}
	blobCacheMu.Lock()
	defer blobCacheMu.Unlock()
	if blobCache[b] || blobCache[d] || !blobCache[a] || !blobCache[c] || !blobCache[e] {
		t.Errorf("in-memory set after evict: %v", blobCache)
	}
}

func TestBlobCacheEvictMissingFileAndEmptyPath(t *testing.T) {
	k := map[string]bool{"blob/" + snapRelHex("ev-z"): true}
	if n, err := blobCacheEvict(filepath.Join(t.TempDir(), "nope"), k); n != 0 || err != nil {
		t.Errorf("missing file = %d, %v; want 0, nil", n, err)
	}
	if n, err := blobCacheEvict("", k); n != 0 || err != nil {
		t.Errorf("empty path = %d, %v; want 0, nil", n, err)
	}
}

func TestWorkerBlobCachePath(t *testing.T) {
	t.Setenv("S3_ENDPOINT", "")
	t.Setenv("S3_BUCKET", "")
	t.Setenv("GATEWAY_URL", "https://gw.example.test")
	t.Setenv("NOWHERE_BLOBCACHE", "/run/bc")
	t.Setenv("NOWHERE_STATE", "/data/st")
	sum := sha256.Sum256([]byte("\x00\x00https://gw.example.test"))
	tag := hex.EncodeToString(sum[:])[:12]
	if got, want := blobCachePath(), "/run/bc/blobcache."+tag; got != want {
		t.Errorf("blobCachePath = %q, want %q (its value must not change)", got, want)
	}
	if got := workerBlobCachePath(); got != blobCachePath() {
		t.Errorf("with NOWHERE_BLOBCACHE set: %q, want %q", got, blobCachePath())
	}
	t.Setenv("NOWHERE_BLOBCACHE", "")
	if got, want := workerBlobCachePath(), "/data/st/blobcache."+tag; got != want {
		t.Errorf("with only NOWHERE_STATE: %q, want %q", got, want)
	}
	if blobCachePath() != "" {
		t.Error("blobCachePath must stay empty without NOWHERE_BLOBCACHE")
	}
	t.Setenv("NOWHERE_STATE", "")
	if got := workerBlobCachePath(); got != "" {
		t.Errorf("with neither: %q, want empty", got)
	}
}

// snapRelGateway answers POST /release; status(n) gives the n-th request's status (1-based).
func snapRelGateway(t *testing.T, status func(n int) int) (*gatewayClient, *[]map[string]string) {
	t.Helper()
	var mu sync.Mutex
	var bodies []map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Method != "POST" || r.URL.Path != "/release" {
			http.Error(w, "no", http.StatusNotFound)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		var in struct {
			Release map[string]string `json:"release"`
		}
		if json.Unmarshal(raw, &in) != nil || in.Release == nil {
			http.Error(w, "bad", http.StatusBadRequest)
			return
		}
		bodies = append(bodies, in.Release)
		if st := status(len(bodies)); st != http.StatusOK {
			http.Error(w, `{"error":"nope"}`, st)
			return
		}
		out := []string{}
		for k := range in.Release {
			out = append(out, k)
		}
		sort.Strings(out)
		json.NewEncoder(w).Encode(map[string]any{"released": out})
	}))
	t.Cleanup(srv.Close)
	return newGatewayClient(srv.URL, gwDefault), &bodies
}

func snapRelProofs(n int) map[string]string {
	p := map[string]string{}
	for i := 0; i < n; i++ {
		p[fmt.Sprintf("blob/%064x", i)] = fmt.Sprintf("%064x", i+1)
	}
	return p
}

func TestReleaseBlobsBatchesAt4096(t *testing.T) {
	g, bodies := snapRelGateway(t, func(int) int { return 200 })
	proofs := snapRelProofs(5000)
	rel, st, err := g.releaseBlobs(proofs)
	if err != nil || st != 200 {
		t.Fatalf("releaseBlobs = %d, %v", st, err)
	}
	if len(*bodies) != 2 || len((*bodies)[0]) != 4096 || len((*bodies)[1]) != 904 {
		var sz []int
		for _, b := range *bodies {
			sz = append(sz, len(b))
		}
		t.Fatalf("requests of sizes %v, want [4096 904]", sz)
	}
	for _, b := range *bodies {
		for k, v := range b {
			if proofs[k] != v {
				t.Fatalf("a body entry does not carry its key's preimage")
			}
		}
	}
	if len(rel) != 5000 {
		t.Errorf("released %d, want 5000", len(rel))
	}
}

func TestReleaseBlobsAnOldGatewayStopsWithoutAnError(t *testing.T) {
	for _, st := range []int{404, 405} {
		g, bodies := snapRelGateway(t, func(int) int { return st })
		rel, got, err := g.releaseBlobs(snapRelProofs(5000))
		if rel != nil || got != st || err != nil || len(*bodies) != 1 {
			t.Errorf("status %d: (%v, %d, %v) after %d requests; want (nil, %d, nil) after 1", st, len(rel), got, err, len(*bodies), st)
		}
	}
}

func TestReleaseBlobsKeepsWhatABatchReleasedWhenTheNextFails(t *testing.T) {
	g, _ := snapRelGateway(t, func(n int) int {
		if n == 2 {
			return 503
		}
		return 200
	})
	rel, st, err := g.releaseBlobs(snapRelProofs(5000))
	if err == nil || st != 503 || len(rel) != 4096 {
		t.Errorf("(%d released, %d, %v); want 4096 released, 503 and an error", len(rel), st, err)
	}
}

// TestSnapshotReleaseSourceNeverFormatsASecret: every fmt/log call in snapshot_release.go takes only string
// literals and the status, reason and count idents -- never a key, a proof, a preimage or a commitment.
func TestSnapshotReleaseSourceNeverFormatsASecret(t *testing.T) {
	fs := token.NewFileSet()
	f, err := parser.ParseFile(fs, "snapshot_release.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	ok := map[string]bool{"code": true, "reason": true, "n": true, "err": true, "nil": true}
	calls := 0
	ast.Inspect(f, func(n ast.Node) bool {
		ce, isCall := n.(*ast.CallExpr)
		if !isCall {
			return true
		}
		sel, isSel := ce.Fun.(*ast.SelectorExpr)
		if !isSel {
			return true
		}
		id, isID := sel.X.(*ast.Ident)
		if !isID || (id.Name != "fmt" && id.Name != "log") {
			return true
		}
		calls++
		for _, a := range ce.Args {
			switch x := a.(type) {
			case *ast.BasicLit:
			case *ast.Ident:
				if !ok[x.Name] {
					t.Errorf("%s: %s.%s formats %q", fs.Position(a.Pos()), id.Name, sel.Sel.Name, x.Name)
				}
			default:
				t.Errorf("%s: %s.%s takes a computed argument", fs.Position(a.Pos()), id.Name, sel.Sel.Name)
			}
		}
		return true
	})
	if calls == 0 {
		t.Error("found no fmt/log call: the pin is not looking at anything")
	}
}
