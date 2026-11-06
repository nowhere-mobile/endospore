package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sealedManifestBlob(t *testing.T, base string, key []byte, chunks []string) string {
	t.Helper()
	body, err := json.Marshal(chunkManifest{Version: 1, Chunks: chunks})
	if err != nil {
		t.Fatal(err)
	}
	return postBlob(base, seal(key, append(append([]byte{}, cdcMagic...), body...)))
}

// The four cases loadCDCManifest cannot tell apart. This is the whole point: the seal guards go inert at
// zero chunks, so "empty" and "unreadable" having the same answer is what silently disarms them.
func TestClassifyManifestLoad(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct#media", "correct horse battery staple"
	dk := deriveKey(name, pass)

	if _, st := classifyManifestLoad(base, dk, ""); st != mlAbsent {
		t.Fatalf("empty hash: got %v, want mlAbsent", st)
	}
	full := sealedManifestBlob(t, base, dk, []string{"aa", "bb"})
	if m, st := classifyManifestLoad(base, dk, full); st != mlOK || len(m.Chunks) != 2 {
		t.Fatalf("good manifest: got %v with %d chunks, want mlOK with 2", st, len(m.Chunks))
	}
	// An EMPTY manifest is legal and must NOT read as a failure -- otherwise every genuinely empty scope
	// would refuse to seal.
	empty := sealedManifestBlob(t, base, dk, nil)
	if m, st := classifyManifestLoad(base, dk, empty); st != mlOK || len(m.Chunks) != 0 {
		t.Fatalf("empty manifest: got %v with %d chunks, want mlOK with 0", st, len(m.Chunks))
	}
	// Decrypts, but carries no CDC magic: a legacy pre-CDC head. Real data, simply not a manifest.
	legacy := postBlob(base, seal(dk, []byte("legacy tar head, not CDC")))
	if _, st := classifyManifestLoad(base, dk, legacy); st != mlNotCDC {
		t.Fatalf("legacy head: got %v, want mlNotCDC", st)
	}
	// Present and hash-correct, but sealed under a different key.
	foreign := sealedManifestBlob(t, base, deriveKey(name, "river maple stone cloud"), []string{"zz"})
	if _, st := classifyManifestLoad(base, dk, foreign); st != mlUnreadable {
		t.Fatalf("foreign key: got %v, want mlUnreadable", st)
	}
	// Decrypts and carries the magic, but the body will not parse: corrupt, not legacy.
	corrupt := postBlob(base, seal(dk, append(append([]byte{}, cdcMagic...), []byte("{not json")...)))
	if _, st := classifyManifestLoad(base, dk, corrupt); st != mlUnreadable {
		t.Fatalf("corrupt body: got %v, want mlUnreadable", st)
	}
	// Absent blob.
	if _, st := classifyManifestLoad(base, dk, strings.Repeat("ab", 32)); st != mlUnreadable {
		t.Fatalf("absent blob: got %v, want mlUnreadable", st)
	}
}

// End to end: a scope head that is intact but does not decrypt must REFUSE the seal rather than overwrite
// it with the guards silently inert. Before this, oldN==0 made both the receipt keystone and the
// shrink-count net no-ops, and the bad head won.
func TestSealRefusedWhenOldHeadUnreadable(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct#media", "correct horse battery staple"
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "note.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}

	// A head that is present and hash-correct, but sealed under a different passphrase.
	foreign := sealedManifestBlob(t, base, deriveKey(name, "river maple stone cloud"), []string{"aa", "bb", "cc", "dd"})
	putHead(base, name, pass, foreign)

	sealRefused = false
	pushProfile(base, name, pass, src)
	if !sealRefused {
		t.Fatal("seal was NOT refused -- an unreadable head let the guards go inert and overwrote it")
	}
	if cur := readHead(base, name, pass); cur != foreign {
		t.Fatalf("head moved to %q despite the refusal", short(cur))
	}

	// NOWHERE_SEAL_FORCE must still be able to overwrite it blind -- the escape hatch every other seal
	// guard honours. Without this the guard could strand a profile whose old key is genuinely gone.
	t.Setenv("NOWHERE_SEAL_FORCE", "1")
	sealRefused = false
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatal("NOWHERE_SEAL_FORCE=1 did not override the refusal")
	}
	if cur := readHead(base, name, pass); cur == foreign {
		t.Fatal("forced seal did not move the head")
	}
}

// TestScopeManifestReportsAnUnreadableManifest is #117's READ side (NWP-20261011-26). scopeManifest used to
// read a vault's manifest through loadCDCManifest, which answers an empty manifest for a missing blob, a
// decrypt failure and corrupt JSON alike -- so it returned ok=true with no chunks, and the Storage screen, the
// seal-delta cache and the per-app rows reported a scope they could not read as an EMPTY one. Every caller
// already reads !ok as "not measured"; this pins that an unreadable manifest reaches them as exactly that.
//
// The store is fronted by a proxy that breaks ONE blob -- the vault's manifest -- so the head, the vault and
// its keyslots all still open and the only thing wrong is the read under test.
func TestScopeManifestReportsAnUnreadableManifest(t *testing.T) {
	store := newHTTPStore(t)
	const name, pass = "scopeunread", "horse battery staple correct"
	se := hardenedWithData(t, store, name, pass)

	v, isV := parseVault(getHeadBlob(store, getRef(store, headKey(store, name, pass))))
	if !isV || v.Manifest == "" {
		t.Fatal("the harness did not produce a vault head with a manifest -- then this test proves nothing")
	}

	var broken string // "" passes every request through; otherwise how the manifest blob is broken
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" && r.URL.Path == "/blob/"+v.Manifest {
			switch broken {
			case "missing":
				w.WriteHeader(http.StatusNotFound)
				return
			case "garbage":
				io.WriteString(w, "not a sealed manifest")
				return
			}
		}
		req, err := http.NewRequest(r.Method, store+r.URL.RequestURI(), r.Body)
		if err != nil {
			t.Error(err)
			return
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Error(err)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}))
	t.Cleanup(proxy.Close)

	// Positive control, through the same proxy: intact, the scope opens and carries chunks.
	if m, ok := scopeManifest(proxy.URL, name, pass, se); !ok || len(m.Chunks) == 0 {
		t.Fatalf("intact profile: ok=%v with %d chunks, want ok=true with chunks", ok, len(m.Chunks))
	}
	for _, mode := range []string{"missing", "garbage"} {
		broken = mode
		if m, ok := scopeManifest(proxy.URL, name, pass, se); ok {
			t.Errorf("%s manifest blob: ok=true with %d chunks -- an unreadable scope reported as measured",
				mode, len(m.Chunks))
		}
	}
}
