package main

import (
	"archive/zip"
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func resetIndexCaches() { // field-wise (copying the struct would trip vet's copylocks)
	indexCache.mu.Lock()
	indexCache.key, indexCache.entries, indexCache.gen = "", nil, 0
	indexCache.mu.Unlock()
	packCache.mu.Lock()
	if packCache.rc != nil {
		packCache.rc.Close()
	}
	packCache.key, packCache.rc, packCache.files = "", nil, nil
	packCache.mu.Unlock()
}

// withIndexKey sets a fresh test index key + temp paths, restoring the globals + caches after.
func withIndexKey(t *testing.T) (ed25519.PrivateKey, string, func()) {
	t.Helper()
	pub, pk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	dir := t.TempDir()
	sk, ss, sd, sp := indexPubKey, indexSystemPath, indexDataPath, iconPackPath
	sc, scd := catalogPubKey, catalogSystemPath
	sq, sh := indexKeySeqPath, indexKeyHeldPath
	indexPubKey = base64.StdEncoding.EncodeToString(pub)
	indexSystemPath = filepath.Join(dir, "index.json")
	indexDataPath = filepath.Join(dir, "index-data.json")
	iconPackPath = filepath.Join(dir, "icons.pack")
	catalogSystemPath = filepath.Join(dir, "catalog.json") // empty by default -> no curated entries
	indexKeySeqPath = filepath.Join(dir, "index-key-seq")
	indexKeyHeldPath = filepath.Join(dir, "index-key")
	resetIndexCaches()
	return pk, dir, func() {
		indexPubKey, indexSystemPath, indexDataPath, iconPackPath = sk, ss, sd, sp
		catalogPubKey, catalogSystemPath = sc, scd
		indexKeySeqPath, indexKeyHeldPath = sq, sh
		resetIndexCaches()
	}
}

func writeSignedIndex(t *testing.T, path string, priv ed25519.PrivateKey, c catalog) {
	t.Helper()
	b, _ := json.Marshal(c)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", ed25519.Sign(priv, b), 0o644); err != nil {
		t.Fatal(err)
	}
}

func idxEntry(pkg, label string, vc int64) catalogEntry {
	return catalogEntry{Pkg: pkg, Label: label, VersionCode: vc, Source: "fdroid",
		SigningCert: strings.Repeat("a", 64), IconRef: "https://f-droid.org/repo/" + pkg + "/icon.png",
		APKs: []catalogAPK{{Name: "base.apk", URL: "https://f-droid.org/repo/" + pkg + "_" + fmt.Sprint(vc) + ".apk", Sha256: strings.Repeat("b", 64), Size: 100}}}
}

func TestVerifyIndexSig(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	msg := []byte(`{"schema":1}`)
	sig := ed25519.Sign(priv, msg)
	if !verifyIndexSig(msg, sig) {
		t.Fatal("valid index sig rejected")
	}
	if verifyIndexSig([]byte(`{"schema":1,"x":1}`), sig) {
		t.Fatal("index sig verified over TAMPERED bytes")
	}
	// index key must NOT be the catalog key (domain separation): a catalog-key sig must not verify as an index sig
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	catalogPubKey = base64.StdEncoding.EncodeToString(other)
	if verifyIndexSig(msg, ed25519.Sign(func() ed25519.PrivateKey { _, k, _ := ed25519.GenerateKey(rand.Reader); return k }(), msg)) {
		t.Fatal("index sig verified under a different key")
	}
}

func TestLoadIndexBytes_bakedAndRollback(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	// baked /system, signed, generated=100
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 100, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	if got := indexGeneratedOf(loadIndexBytes()); got != 100 {
		t.Fatalf("baked index not served (gen=%d)", got)
	}
	// unsigned /system must be refused when a key is baked
	os.Remove(indexSystemPath + ".sig")
	if loadIndexBytes() != nil {
		t.Fatal("unsigned /system index served despite a baked key")
	}
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 100, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	// NEWER /data override wins
	writeSignedIndex(t, indexDataPath, priv, catalog{Schema: 1, Generated: 200, Entries: []catalogEntry{idxEntry("a.b", "A", 2)}})
	if got := indexGeneratedOf(loadIndexBytes()); got != 200 {
		t.Fatalf("newer /data override not served (gen=%d)", got)
	}
	// OLDER /data override must be IGNORED (rollback guard)
	writeSignedIndex(t, indexDataPath, priv, catalog{Schema: 1, Generated: 50, Entries: []catalogEntry{idxEntry("a.b", "A", 0)}})
	if got := indexGeneratedOf(loadIndexBytes()); got != 100 {
		t.Fatalf("rollback: older /data override served (gen=%d, want baked 100)", got)
	}
	// tampered /data sig -> ignored, baked served
	os.WriteFile(indexDataPath, []byte(`{"schema":1,"generated":999}`), 0o644) // sig no longer matches
	if got := indexGeneratedOf(loadIndexBytes()); got != 100 {
		t.Fatalf("tampered /data override served (gen=%d)", got)
	}
}

func TestSearchIndex(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 100, Entries: []catalogEntry{
		idxEntry("org.mozilla.firefox", "Firefox", 5),
		idxEntry("com.other.firefoxish", "FireBird", 1),
		idxEntry("net.unrelated.app", "Widget", 1),
	}})
	// exact/prefix beats substring: "firefox" -> Firefox (label==q) first
	rep := searchIndex("firefox")
	if len(rep.Entries) < 1 || rep.Entries[0].Pkg != "org.mozilla.firefox" {
		t.Fatalf("ranking: got %+v", rep.Entries)
	}
	// index results route icons to the LOCAL pack: iconRef rewritten to the pkg
	if rep.Entries[0].IconRef != "org.mozilla.firefox" {
		t.Fatalf("index iconRef not routed to pack: %q", rep.Entries[0].IconRef)
	}
	// apks stripped
	if rep.Entries[0].APKs != nil {
		t.Fatal("search result leaked apks")
	}
	// no match -> empty
	if r := searchIndex("zzzznope"); len(r.Entries) != 0 {
		t.Fatalf("expected no matches, got %d", len(r.Entries))
	}
	// cap enforced
	many := make([]catalogEntry, 120)
	for i := range many {
		many[i] = idxEntry(fmt.Sprintf("app.match%03d", i), fmt.Sprintf("Matchy%03d", i), 1)
	}
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 101, Entries: many})
	resetIndexCaches()
	r := searchIndex("match")
	if len(r.Entries) != searchMaxResults || !r.Truncated {
		t.Fatalf("cap: got %d entries truncated=%v", len(r.Entries), r.Truncated)
	}
}

func TestSearchIndex_iconlessGetsBadgeMarker(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	// ~10% of F-Droid apps ship no icon (iconRef==""). Such an index result MUST still be marked iconRef==pkg
	// so the chooser renders the "Not curated by Nowhere" trust badge -- else an unvetted app looks curated
	// (regression, DIA-20260801-42). It also routes the (missing) icon to the local pack -> placeholder.
	noicon := idxEntry("com.farmerbb.notepad", "Notepad", 1)
	noicon.IconRef = ""
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 100, Entries: []catalogEntry{noicon}})
	rep := searchIndex("notepad")
	if len(rep.Entries) != 1 {
		t.Fatalf("want 1 result, got %d", len(rep.Entries))
	}
	if rep.Entries[0].IconRef != "com.farmerbb.notepad" {
		t.Fatalf("icon-less index entry must be marked iconRef==pkg (badge marker); got %q", rep.Entries[0].IconRef)
	}
}

func TestFindAppEntry_curatedThenIndex(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	// curated catalog (unsigned path served on trust when catalogPubKey=="" -- set it empty for this test)
	catalogPubKey = ""
	cur := catalog{Schema: 1, Entries: []catalogEntry{idxEntry("cur.app", "Curated", 9)}}
	cb, _ := json.Marshal(cur)
	os.WriteFile(catalogSystemPath, cb, 0o644)
	// index has a long-tail app + a NEWER version of a pkg not in catalog
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 100, Entries: []catalogEntry{idxEntry("tail.app", "Tail", 7)}})
	if e := findAppEntry("cur.app", 0); e == nil || e.Label != "Curated" {
		t.Fatal("curated app not found first")
	}
	if e := findAppEntry("tail.app", 0); e == nil || e.VersionCode != 7 {
		t.Fatal("index fallback failed for a long-tail app")
	}
	// vc advisory: an exact-vc miss falls back to latest indexed
	if e := findAppEntry("tail.app", 999); e == nil || e.VersionCode != 7 {
		t.Fatal("vc-miss did not fall back to latest indexed")
	}
	if e := findAppEntry("nope.app", 0); e != nil {
		t.Fatal("unknown app resolved")
	}
}

func TestServePackIcon(t *testing.T) {
	_, _, restore := withIndexKey(t)
	defer restore()
	// write a tiny zip pack keyed by pkg
	f, _ := os.Create(iconPackPath)
	zw := zip.NewWriter(f)
	w, _ := zw.Create("com.foo.bar")
	w.Write([]byte("\x89PNGdummyicon"))
	zw.Close()
	f.Close()
	if b := servePackIcon("com.foo.bar"); string(b) != "\x89PNGdummyicon" {
		t.Fatalf("pack icon not served: %q", b)
	}
	if servePackIcon("not.in.pack") != nil {
		t.Fatal("missing pkg returned bytes")
	}
	if servePackIcon("../../etc/passwd") != nil {
		t.Fatal("path-traversal pkg not rejected")
	}
}

func TestRefreshIndex_generatedGuard(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	now := time.Now().Unix()
	baked := now - 3600 // baked index is 1h old (realistic; the staleness bound is relative to now)
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: baked, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	serve := func(gen int64, sign bool) *httptest.Server {
		body, _ := json.Marshal(catalog{Schema: 1, Generated: gen, Entries: []catalogEntry{idxEntry("a.b", "A", 2)}})
		sig := ed25519.Sign(priv, body)
		if !sign {
			sig = ed25519.Sign(priv, []byte("wrong"))
		}
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if strings.HasSuffix(r.URL.Path, ".sig") {
				w.Write(sig)
			} else {
				w.Write(body)
			}
		}))
	}
	do := func(gen int64, sign bool) error {
		s := serve(gen, sign)
		defer s.Close()
		t.Setenv("INDEX_URL", s.URL+"/index.json")
		err := refreshIndex()
		resetIndexCaches()
		return err
	}
	// newer + signed -> installs
	if err := do(now, true); err != nil {
		t.Fatalf("newer signed refresh failed: %v", err)
	}
	if indexGeneratedOf(loadIndexBytes()) != now {
		t.Fatal("newer refresh not installed")
	}
	// older-but-fresh -> benign no-op, /data stays at `now`
	if err := do(now-7200, true); err != nil {
		t.Fatalf("older refresh should be a benign no-op: %v", err)
	}
	if indexGeneratedOf(loadIndexBytes()) != now {
		t.Fatal("older refresh rolled the index back")
	}
	// TOO STALE (older than the window) -> refused even though validly signed + technically "newer than baked"
	if err := do(now-(maxIndexStaleness+86400), true); err == nil {
		t.Fatal("stale (replayed) index accepted")
	}
	// bad signature -> refused
	if err := do(now+10, false); err == nil {
		t.Fatal("bad-signature refresh accepted")
	}
}

func TestSearchSanitize(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	withSearchCatalogData(t)
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 1, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	// A 5000-byte query with control bytes at the FRONT, through the handler itself: at the end the 100-byte cut
	// would drop them even with the strip gone.
	header, body := searchAppsReply(t, "a\x00b\x07"+strings.Repeat("x", 4996))
	rep := decodeSearch(t, header, body)
	for i := 0; i < len(rep.Query); i++ {
		if c := rep.Query[i]; c < 0x20 || c == 0x7f {
			t.Fatalf("control byte %#x not stripped from the reply's query %q", c, rep.Query)
		}
	}
	if len(rep.Query) > searchMaxQuery {
		t.Fatalf("the reply's query is %d bytes, want at most %d", len(rep.Query), searchMaxQuery)
	}
	if want := "ab" + strings.Repeat("x", searchMaxQuery-2); rep.Query != want {
		t.Fatalf("the reply's query = %q, want %q", rep.Query, want)
	}
}

func TestIndexRefreshURL(t *testing.T) {
	t.Setenv("INDEX_URL", "")
	t.Setenv("GATEWAY_URL", "")
	if got := indexRefreshURL(); got != "" {
		t.Fatalf("no source configured: want empty, got %q", got)
	}
	// GATEWAY_URL fallback must target the gateway's /fdroid/ route, not a bare /index.json (which 404s).
	t.Setenv("GATEWAY_URL", "https://api-beta.nowhere.mobile")
	if got := indexRefreshURL(); got != "https://api-beta.nowhere.mobile/fdroid/index.json" {
		t.Fatalf("GATEWAY_URL fallback: want .../fdroid/index.json, got %q", got)
	}
	// An explicit INDEX_URL is used verbatim and wins over the fallback.
	t.Setenv("INDEX_URL", "https://static.example/custom/index.json")
	if got := indexRefreshURL(); got != "https://static.example/custom/index.json" {
		t.Fatalf("explicit INDEX_URL should win verbatim, got %q", got)
	}
}

// condIndexServer serves an index + .sig through http.ServeContent with a fixed modtime, as the gateway's
// handleFdroidFile does (NWP-20261102-11), and counts what it is asked.
type condIndexServer struct {
	mu        sync.Mutex
	body, sig []byte
	mod       time.Time
	idxReqs   int
	sigReqs   int
	ims       []string // If-Modified-Since of each index.json request ("" when absent)
	sigIMS    []string // the same for each .sig request
	srv       *httptest.Server
}

func newCondIndexServer(t *testing.T, priv ed25519.PrivateKey, gen int64, mod time.Time) *condIndexServer {
	t.Helper()
	c := &condIndexServer{}
	c.set(priv, gen, mod)
	c.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.mu.Lock()
		defer c.mu.Unlock()
		if strings.HasSuffix(r.URL.Path, ".sig") {
			c.sigReqs++
			c.sigIMS = append(c.sigIMS, r.Header.Get("If-Modified-Since"))
			http.ServeContent(w, r, "index.json.sig", c.mod, bytes.NewReader(c.sig))
			return
		}
		c.idxReqs++
		c.ims = append(c.ims, r.Header.Get("If-Modified-Since"))
		http.ServeContent(w, r, "index.json", c.mod, bytes.NewReader(c.body))
	}))
	t.Cleanup(c.srv.Close)
	t.Setenv("INDEX_URL", c.srv.URL+"/index.json")
	return c
}

func (c *condIndexServer) set(priv ed25519.PrivateKey, gen int64, mod time.Time) {
	body, _ := json.Marshal(catalog{Schema: 1, Generated: gen, Entries: []catalogEntry{idxEntry("a.b", "A", gen)}})
	c.mu.Lock()
	c.body, c.sig, c.mod = body, ed25519.Sign(priv, body), mod
	c.mu.Unlock()
}

func (c *condIndexServer) counts() (int, int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.idxReqs, c.sigReqs
}

func readFileT(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestIndexConditional_notModifiedSkipsSig(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	now := time.Now().Unix()
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: now - 3600, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	mod1 := time.Unix(now-1800, 0).UTC()
	s := newCondIndexServer(t, priv, now-600, mod1)

	if err := refreshIndex(); err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	resetIndexCaches()
	if s.ims[0] != "" {
		t.Fatalf("only the baked copy exists, yet the request carried If-Modified-Since %q", s.ims[0])
	}
	if i, g := s.counts(); i != 1 || g != 1 {
		t.Fatalf("first refresh made %d index and %d sig requests, want 1 and 1", i, g)
	}
	if !bytes.Equal(readFileT(t, indexDataPath), s.body) || !bytes.Equal(readFileT(t, indexDataPath+".sig"), s.sig) {
		t.Fatal("first refresh did not install the served index + sig")
	}
	fi, err := os.Stat(indexDataPath)
	if err != nil {
		t.Fatal(err)
	}
	if !fi.ModTime().Equal(mod1) {
		t.Fatalf("index.json mtime = %v, want the server's Last-Modified %v", fi.ModTime().UTC(), mod1)
	}
	idx1, sig1 := readFileT(t, indexDataPath), readFileT(t, indexDataPath+".sig")
	sfi, _ := os.Stat(indexDataPath + ".sig")

	if err := refreshIndex(); err != nil {
		t.Fatalf("second refresh (304) should be a no-op, got: %v", err)
	}
	resetIndexCaches()
	if want := mod1.Format(http.TimeFormat); s.ims[1] != want {
		t.Fatalf("second request If-Modified-Since = %q, want %q", s.ims[1], want)
	}
	if i, g := s.counts(); i != 2 || g != 1 {
		t.Fatalf("after the 304: %d index and %d sig requests, want 2 and 1 (no .sig on a 304)", i, g)
	}
	if !bytes.Equal(readFileT(t, indexDataPath), idx1) || !bytes.Equal(readFileT(t, indexDataPath+".sig"), sig1) {
		t.Fatal("a 304 changed the installed files")
	}
	fi2, _ := os.Stat(indexDataPath)
	sfi2, _ := os.Stat(indexDataPath + ".sig")
	if !fi2.ModTime().Equal(mod1) || !sfi2.ModTime().Equal(sfi.ModTime()) {
		t.Fatal("a 304 touched a file's mtime")
	}
	if g := indexGeneratedOf(loadIndexBytes()); g != now-600 {
		t.Fatalf("served generated = %d, want %d", g, now-600)
	}
}

func TestIndexConditional_newerServerReplaces(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	now := time.Now().Unix()
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: now - 3600, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	mod1 := time.Unix(now-1800, 0).UTC()
	s := newCondIndexServer(t, priv, now-600, mod1)
	if err := refreshIndex(); err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	resetIndexCaches()

	mod2 := mod1.Add(600 * time.Second)
	s.set(priv, now-300, mod2)
	if err := refreshIndex(); err != nil {
		t.Fatalf("refresh against a newer server: %v", err)
	}
	resetIndexCaches()
	if want := mod1.Format(http.TimeFormat); s.ims[1] != want {
		t.Fatalf("request If-Modified-Since = %q, want %q", s.ims[1], want)
	}
	if i, g := s.counts(); i != 2 || g != 2 {
		t.Fatalf("%d index and %d sig requests, want 2 and 2", i, g)
	}
	if !bytes.Equal(readFileT(t, indexDataPath), s.body) || !bytes.Equal(readFileT(t, indexDataPath+".sig"), s.sig) {
		t.Fatal("the newer index was not installed")
	}
	if fi, _ := os.Stat(indexDataPath); !fi.ModTime().Equal(mod2) {
		t.Fatalf("index.json mtime = %v, want %v", fi.ModTime().UTC(), mod2)
	}
	if g := indexGeneratedOf(loadIndexBytes()); g != now-300 {
		t.Fatalf("served generated = %d, want %d", g, now-300)
	}
}

func TestIndexConditional_noHeaderUnlessServed(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	now := time.Now().Unix()
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: now - 3600, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	s := newCondIndexServer(t, priv, now-600, time.Unix(now-1800, 0).UTC())

	// (b) a signed /data copy OLDER than the baked index is not what loadIndexBytes serves
	writeSignedIndex(t, indexDataPath, priv, catalog{Schema: 1, Generated: now - 7200, Entries: []catalogEntry{idxEntry("a.b", "A", 0)}})
	recent := time.Now().Add(-time.Minute)
	if err := os.Chtimes(indexDataPath, recent, recent); err != nil {
		t.Fatal(err)
	}
	if err := refreshIndex(); err != nil {
		t.Fatalf("refresh over an older /data copy: %v", err)
	}
	resetIndexCaches()
	if s.ims[0] != "" {
		t.Fatalf("a /data copy older than the baked index is not served, yet the request carried %q", s.ims[0])
	}

	// (c) a /data copy whose .sig is bad is not served either
	if err := os.WriteFile(indexDataPath+".sig", ed25519.Sign(priv, []byte("wrong")), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(indexDataPath, recent, recent); err != nil {
		t.Fatal(err)
	}
	if err := refreshIndex(); err != nil && !strings.Contains(err.Error(), "HTTP") {
		t.Fatalf("refresh over a badly signed /data copy: %v", err)
	}
	resetIndexCaches()
	if s.ims[1] != "" {
		t.Fatalf("a /data copy with a bad signature is not served, yet the request carried %q", s.ims[1])
	}
}

// A /data copy loadIndexBytes rejects must not supply If-Modified-Since even when its bytes equal the baked
// index (RF-001): its phone-clock mtime could 304 a newer server index.
func TestIndexConditional_rejectedDataMatchingBakedSuppliesNoTimestamp(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	now := time.Now().Unix()
	c := catalog{Schema: 1, Generated: now - 3600, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}}
	writeSignedIndex(t, indexSystemPath, priv, c)
	writeSignedIndex(t, indexDataPath, priv, c)
	if servedIndexDataMtime().IsZero() {
		t.Fatal("a signed /data copy at the baked generation is served and should supply a timestamp")
	}
	os.Remove(indexDataPath + ".sig")
	if !servedIndexDataMtime().IsZero() {
		t.Fatal("a /data copy with a missing signature matching the baked bytes contributed a timestamp")
	}
	if err := os.WriteFile(indexDataPath+".sig", ed25519.Sign(priv, []byte("wrong")), 0o644); err != nil {
		t.Fatal(err)
	}
	if !servedIndexDataMtime().IsZero() {
		t.Fatal("a /data copy with an invalid signature matching the baked bytes contributed a timestamp")
	}
}
