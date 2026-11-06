package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// NWP-20261029-04: the release generation (release_gen.go). Every test uses its OWN profile name, and a private
// NOWHERE_BLOBCACHE it resets afterwards.

// relGenEnv points the blob cache at a private dir and returns its file path.
func relGenEnv(t *testing.T) string {
	t.Helper()
	old := blobCache
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	blobCache = nil
	t.Cleanup(func() { blobCacheMu.Lock(); blobCache = old; blobCacheMu.Unlock() })
	return blobCachePath()
}

// (a)
func TestRelGenRecordSeenRoundTrip(t *testing.T) {
	p := relGenEnv(t)
	if g, ok := relGenSeen(p, "k1"); ok || g != 0 {
		t.Fatalf("no file: got (%d, %v), want (0, false)", g, ok)
	}
	if err := relGenRecord(p, "k1", 3); err != nil {
		t.Fatal(err)
	}
	if err := relGenRecord(p, "k2", 5); err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]uint64{"k1": 3, "k2": 5} {
		if g, ok := relGenSeen(p, k); !ok || g != want {
			t.Errorf("%s: got (%d, %v), want (%d, true)", k, g, ok, want)
		}
	}
	if err := relGenRecord(p, "k1", 7); err != nil {
		t.Fatal(err)
	}
	if g, _ := relGenSeen(p, "k1"); g != 7 {
		t.Errorf("k1 after the rewrite = %d, want 7", g)
	}
	if g, _ := relGenSeen(p, "k2"); g != 5 {
		t.Errorf("a rewrite of k1 changed k2 to %d", g)
	}
	f, err := os.OpenFile(relGenPath(p), os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("zz\n" + relGenTag("k2") + " notanumber\n")
	f.Close()
	if g, ok := relGenSeen(p, "k2"); !ok || g != 5 {
		t.Errorf("malformed lines changed k2 to (%d, %v)", g, ok)
	}
	if st, err := os.Stat(relGenPath(p)); err != nil || st.Mode().Perm() != 0o600 {
		t.Errorf("relgen file mode: %v %v, want 0600", st, err)
	}
	if b, _ := os.ReadFile(relGenPath(p)); strings.Contains(string(b), "k1") {
		t.Error("the file names a head key in the clear")
	}
	ents, _ := os.ReadDir(filepath.Dir(p))
	for _, e := range ents {
		if strings.Contains(e.Name(), ".tmp") {
			t.Errorf("temp file left behind: %s", e.Name())
		}
	}
	// no cache configured: a no-op that creates nothing
	empty := t.TempDir()
	t.Setenv("NOWHERE_BLOBCACHE", "")
	if err := relGenRecord("", "k1", 1); err != nil {
		t.Errorf("relGenRecord with no path: %v", err)
	}
	if g, ok := relGenSeen("", "k1"); ok || g != 0 {
		t.Errorf("relGenSeen with no path: (%d, %v)", g, ok)
	}
	if ents, _ := os.ReadDir(empty); len(ents) != 0 {
		t.Errorf("a no-path record created %d entries", len(ents))
	}
}

// (b)
func TestBlobCacheDropForgetsKnownChunks(t *testing.T) {
	p := relGenEnv(t)
	blobCacheAdd("relgendropK")
	if !blobCacheKnown("relgendropK") {
		t.Fatal("fixture: the added key is not known")
	}
	blobCacheDrop(p)
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("the cache file survived the drop: %v", err)
	}
	if blobCacheKnown("relgendropK") {
		t.Error("the in-memory set still knows a dropped chunk")
	}
}

// (c)
func TestRelGenDistrustTruthTable(t *testing.T) {
	p := relGenEnv(t)
	const hk = "relgentruth-head"
	rows := []struct {
		name         string
		rec          int // -1: no record
		gen          uint64
		dropped      bool
		wantRecorded int // -1: no relgen file
	}{
		{"never deleted, no record", -1, 0, false, -1},
		{"first generation, no record", -1, 1, true, 1},
		{"generation equals the record", 1, 1, false, 1},
		{"generation moved up", 1, 2, true, 2},
		{"generation went down", 3, 1, true, 1},
	}
	for _, r := range rows {
		os.Remove(relGenPath(p))
		if r.rec >= 0 {
			if err := relGenRecord(p, hk, uint64(r.rec)); err != nil {
				t.Fatal(err)
			}
		}
		blobCacheAdd("relgentruthK")
		if got := distrustBlobCacheIfReleased(p, hk, r.gen); got != r.dropped {
			t.Errorf("%s: dropped = %v, want %v", r.name, got, r.dropped)
		}
		if known := blobCacheKnown("relgentruthK"); known == r.dropped {
			t.Errorf("%s: cache known = %v with dropped = %v", r.name, known, r.dropped)
		}
		g, ok := relGenSeen(p, hk)
		if r.wantRecorded < 0 {
			if ok {
				t.Errorf("%s: a record was written (%d)", r.name, g)
			}
		} else if !ok || g != uint64(r.wantRecorded) {
			t.Errorf("%s: record = (%d, %v), want %d", r.name, g, ok, r.wantRecorded)
		}
	}
}

// relGenLeases collects the blob keys of every lease the store sees, per call of take.
type relGenLeases struct {
	mu   sync.Mutex
	refs map[string]bool
}

func (l *relGenLeases) take() map[string]bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	r := l.refs
	l.refs = map[string]bool{}
	return r
}

func relGenWatchLeases(t *testing.T) *relGenLeases {
	l := &relGenLeases{refs: map[string]bool{}}
	capStoreLeaseSeen = func(req leaseReq) {
		l.mu.Lock()
		for k := range req.Refs {
			if strings.HasPrefix(k, "blob/") {
				l.refs[k] = true
			}
		}
		l.mu.Unlock()
	}
	t.Cleanup(func() { capStoreLeaseSeen = nil })
	return l
}

func relGenOverlap(a, b map[string]bool) int {
	n := 0
	for k := range a {
		if b[k] {
			n++
		}
	}
	return n
}

// (d)
func TestReleaseGenDropsTheCacheBeforeASeal(t *testing.T) {
	capFixture(t)
	p := relGenEnv(t)
	const name, pass = "relgenseal", "release generation seal horse staple"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	l := relGenWatchLeases(t)
	seal := func(what string) map[string]bool {
		t.Helper()
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload "+name), 0o600); err != nil {
			t.Fatal(err)
		}
		l.take()
		if didPanic(func() { pushProfile("s3", name, pass, d) }) {
			t.Fatalf("%s: the seal failed", what)
		}
		return l.take()
	}
	first := seal("first")
	if len(first) == 0 {
		t.Fatal("fixture: the first seal leased no blobs")
	}
	if n := relGenOverlap(first, seal("second")); n != 0 {
		t.Errorf("an unchanged second seal re-leased %d of the first seal's blobs: the cache is not warm", n)
	}
	if _, ok := relGenSeen(p, relGenHeadKey("s3", name, pass)); ok {
		t.Error("a profile that never deleted a snapshot has a release record")
	}
	// Another phone's snapshot delete: the same vault with the generation bumped, republished.
	_, dk := snapDelHead(t, "s3", name, pass)
	capWrite(name, pass, dk, func() {
		cur, err := capReadVaultForEdit("s3", "relgen test", name, pass, dk, true)
		if err != nil {
			t.Fatal(err)
		}
		cur.ReleaseGen = 1
		signVault(cur, dk)
		vh := postBlob("s3", serializeVault(cur))
		putHead("s3", name, pass, vh)
		if cur.RecoveryRef != "" {
			putRef("s3", cur.RecoveryRef, vh)
		}
	})
	l.take()
	out := captureStdout(t, func() {
		if n := relGenOverlap(first, seal("third")); n == 0 {
			t.Error("a seal after another phone's release re-leased none of the cached chunks: the cache was trusted")
		}
	})
	if !strings.Contains(out, "the cache is dropped for this seal (release generation 1)") {
		t.Errorf("no drop line in the seal's output:\n%s", out)
	}
	if g, ok := relGenSeen(p, relGenHeadKey("s3", name, pass)); !ok || g != 1 {
		t.Errorf("record after the drop = (%d, %v), want (1, true)", g, ok)
	}
	if after, _ := openVaultHead("s3", name, pass); after == nil || after.ReleaseGen != 1 {
		t.Error("a seal did not preserve the head's release generation")
	}
	if n := relGenOverlap(first, seal("fourth")); n != 0 {
		t.Errorf("the seal after the drop re-leased %d cached blobs: the cache is not warm again", n)
	}
}

// TestRelGenRestoreHelperProcess is not a test: it is the agent re-executed from the test binary, running the real
// `restore` verb through main().
func TestRelGenRestoreHelperProcess(t *testing.T) {
	a := os.Getenv("NOWHERE_RELGEN_RESTORE_HELPER")
	if a == "" {
		return
	}
	os.Args = append([]string{"nowhere_agent", "restore"}, strings.Split(a, "\n")...)
	main()
	os.Exit(0)
}

// relGenRestore runs the restore verb for profile in a child process sharing this process's blob cache dir.
func relGenRestore(t *testing.T, base, profile, pass string) string {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestRelGenRestoreHelperProcess$", "-test.count=1")
	env := []string{"NOWHERE_RELGEN_RESTORE_HELPER=" + strings.Join([]string{base, profile, pass, t.TempDir()}, "\n")}
	for _, kv := range os.Environ() {
		switch kv[:strings.IndexByte(kv+"=", '=')] {
		case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS":
			continue
		}
		env = append(env, kv)
	}
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("restore of %q: %v\n%s", profile, err, out)
	}
	return string(out)
}

func relGenCacheLines(p string) map[string]bool {
	m := map[string]bool{}
	b, _ := os.ReadFile(p)
	for _, l := range strings.Fields(string(b)) {
		m[l] = true
	}
	return m
}

// relGenSetGen republishes the profile's head with the given release generation.
func relGenSetGen(t *testing.T, base, name, pass string, gen uint64) {
	t.Helper()
	v, dk := snapDelHead(t, base, name, pass)
	v.ReleaseGen = gen
	signVault(v, dk)
	vh := postBlob(base, serializeVault(v))
	putHead(base, name, pass, vh)
	if v.RecoveryRef != "" {
		putRef(base, v.RecoveryRef, vh)
	}
}

// (e)
func TestReleaseGenRestoreDropsBeforeSeeding(t *testing.T) {
	base := newHTTPStore(t)
	p := relGenEnv(t)
	const name, pass = "relgenrestore", "release generation restore horse staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("restore payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	hk := relGenHeadKey(base, name, pass)

	// A cache from earlier in the boot, recorded under generation 1; the head is now generation 2.
	os.Remove(p)
	blobCache = nil
	blobCacheAdd("relgenrestoreK")
	if err := relGenRecord(p, hk, 1); err != nil {
		t.Fatal(err)
	}
	relGenSetGen(t, base, name, pass, 2)
	relGenRestore(t, base, name, pass)
	lines := relGenCacheLines(p)
	if lines["relgenrestoreK"] {
		t.Error("the restore kept a chunk key cached under an older release generation")
	}
	if len(lines) == 0 {
		t.Error("the restore seeded nothing into the dropped cache")
	}
	if g, ok := relGenSeen(p, hk); !ok || g != 2 {
		t.Errorf("record after the restore = (%d, %v), want (2, true)", g, ok)
	}
	blobCache = nil
	out := captureStdout(t, func() { pushProfile(base, name, pass, src) })
	if strings.Contains(out, "the cache is dropped for this seal") {
		t.Errorf("the first seal after the restore dropped the cache again:\n%s", out)
	}

	// A head whose generation equals the record keeps the cache.
	blobCache = nil
	blobCacheAdd("relgenrestoreK")
	relGenRestore(t, base, name, pass)
	if !relGenCacheLines(p)["relgenrestoreK"] {
		t.Error("a restore of a head at the recorded generation dropped the cache")
	}
}

// (f)
func TestCarryForwardCarriesReleaseGen(t *testing.T) {
	nv := &vault{}
	carryForward(&vault{ReleaseGen: 4}, nv)
	if nv.ReleaseGen != 4 {
		t.Errorf("carryForward gave ReleaseGen %d, want 4", nv.ReleaseGen)
	}
}

// (g)
func TestReleaseGenIgnoresScopes(t *testing.T) {
	capFixture(t)
	p := relGenEnv(t)
	const name, pass = "relgenscope", "release generation scope horse staple"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	de := sealBareAndDe(t, name, pass)
	if de == "" {
		t.Fatal("fixture: no scope head")
	}
	scope := name + "#de"
	if err := relGenRecord(p, relGenHeadKey("s3", scope, pass), 5); err != nil {
		t.Fatal(err)
	}
	blobCacheAdd("relgenscopeK")
	before, _ := os.ReadFile(relGenPath(p))
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "g.txt"), []byte("scope payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	if didPanic(func() { pushProfile("s3", scope, pass, d) }) {
		t.Fatal("the scope seal failed")
	}
	if after, _ := os.ReadFile(relGenPath(p)); string(after) != string(before) {
		t.Errorf("a scope seal rewrote the relgen file:\n%s\n--\n%s", before, after)
	}
	if !blobCacheKnown("relgenscopeK") {
		t.Error("a scope seal dropped the blob cache")
	}
}

// (g) the restore half: a scope restore must not read or write the relgen file, nor drop the shared cache.
func TestReleaseGenScopeRestoreIgnoresRelGen(t *testing.T) {
	base := newHTTPStore(t)
	p := relGenEnv(t)
	const name, pass = "relgenscoperestore", "release generation scope restore horse staple"
	createVault(base, name, pass)
	scope := name + "#de"
	for _, n := range []string{name, scope} {
		src := t.TempDir()
		if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("payload "+n), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, n, pass, src)
	}
	if err := relGenRecord(p, relGenHeadKey(base, scope, pass), 5); err != nil {
		t.Fatal(err)
	}
	blobCache = nil
	blobCacheAdd("relgenscoperestoreK")
	before, _ := os.ReadFile(relGenPath(p))
	relGenRestore(t, base, scope, pass)
	if after, _ := os.ReadFile(relGenPath(p)); string(after) != string(before) {
		t.Errorf("a scope restore rewrote the relgen file:\n%s\n--\n%s", before, after)
	}
	if !relGenCacheLines(p)["relgenscoperestoreK"] {
		t.Error("a scope restore dropped the blob cache")
	}
}
