package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261024-01: a deferred file that tears during the seal's read must leave NOTHING in the essential tar
// stream. The torn branch of walkChunks' deferred arm dropped the record but its emitted chunks stayed in the emit
// order, and pushProfile counted every index outside a deferred range as essential -- so the file's raw bytes sat
// between tar entries: a restore met a bad header, or (behind a zero prefix) read the zeros as the end of the
// archive and silently lost every later entry. walkChunks now reports those indices as `discard`.

// tornAppFixture stages the #apps tree: an installed app, an on-demand app whose base.apk is the torn file, its
// _meta and manifest.tsv (which sorts AFTER the torn file in walk order). zeroPrefix zeroes the torn file's head.
type tornAppFixture struct {
	src      string
	tornPath string
	keepApk  []byte
	meta     []byte
	manifest []byte
	tornSize int
}

func stageTornApp(t *testing.T, zeroPrefix bool) *tornAppFixture {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	// The blob and content caches are process-global and keyed by the profile's DK: two tests that share a profile
	// name and passphrase would otherwise believe the other's blobs exist in this test's fresh store.
	blobCache = nil
	contentCache = nil
	f := &tornAppFixture{src: t.TempDir()}
	write := func(rel string, b []byte) {
		p := filepath.Join(f.src, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	f.keepApk = prBytes(3 << 20)
	torn := prBytes(9 << 20) // cdcMax is 4 MiB: at least three chunks
	if zeroPrefix {
		copy(torn, make([]byte, 2048))
	}
	f.meta = []byte("vc\t42\ncert\tZm9v\nact\tcom.od/.Main\tOnDemand\n")
	f.manifest = []byte("com.keep\t7\t1\tinstalled\tbase.apk\ncom.od\t42\t1\tondemand\tbase.apk\n")
	write("com.keep/base.apk", f.keepApk)
	write("com.od/base.apk", torn)
	write("com.od/_meta/meta", f.meta)
	write("manifest.tsv", f.manifest)
	f.tornPath = filepath.Join(f.src, "com.od", "base.apk")
	f.tornSize = len(torn)
	deferPath := filepath.Join(t.TempDir(), "defer")
	if err := os.WriteFile(deferPath, []byte("com.od/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", deferPath)
	return f
}

// growOnce makes the seam append 64 KiB to path the first time it runs, as an app writing the file would.
func growOnce(t *testing.T, path string) {
	t.Helper()
	old := sealAfterDeferredRead
	t.Cleanup(func() { sealAfterDeferredRead = old })
	grew := false
	sealAfterDeferredRead = func(p string) {
		if grew || p != path {
			return
		}
		grew = true
		fh, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			t.Errorf("grow torn file: %v", err)
			return
		}
		defer fh.Close()
		if _, err := fh.Write(prBytes(64 << 10)); err != nil {
			t.Errorf("grow torn file: %v", err)
		}
	}
}

func tornHeadManifest(t *testing.T, base string, scope, pass string) ([]byte, chunkManifest) {
	t.Helper()
	key, mb, ok := resolveKey(base, scope, pass)
	if !ok {
		t.Fatalf("no head for %s after push", scope)
	}
	var m chunkManifest
	if err := json.Unmarshal(unseal(key, mb)[len(cdcMagic):], &m); err != nil {
		t.Fatalf("decode manifest: %v", err)
	}
	return key, m
}

// restoreEssential restores the head's essential stream; a panic (untarFrom's check on a bad header) is a failure.
func restoreEssential(t *testing.T, base string, key []byte, m chunkManifest) string {
	t.Helper()
	dst := t.TempDir()
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("restore of the essential stream panicked: %v", r)
			}
		}()
		cdcRestore(base, key, m, dst)
	}()
	return dst
}

func wantFile(t *testing.T, root, rel string, want []byte) {
	t.Helper()
	got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("%s did not restore byte for byte (err=%v)", rel, err)
	}
}

func tornPushAndCheck(t *testing.T, zeroPrefix bool) {
	base := newHTTPStore(t)
	name, pass := "torndef", "torn deferred horse battery staple"
	createVault(base, name, pass)
	f := stageTornApp(t, zeroPrefix)
	growOnce(t, f.tornPath)

	pushProfile(base, name+"#apps", pass, f.src)

	key, m := tornHeadManifest(t, base, name+"#apps", pass)
	if _, ok := m.Deferred["com.od/base.apk"]; ok {
		t.Fatalf("a torn file must not get a Deferred entry; got %v", deferredRels(m.Deferred))
	}
	var sum int64
	for _, s := range m.Sizes {
		sum += s
	}
	if sum >= int64(f.tornSize) {
		t.Fatalf("essential Sizes sum %d must be below the torn file's size %d: its chunks leaked into the essential list", sum, f.tornSize)
	}
	dst := restoreEssential(t, base, key, m)
	wantFile(t, dst, "com.keep/base.apk", f.keepApk)
	wantFile(t, dst, "com.od/_meta/meta", f.meta)
	wantFile(t, dst, "manifest.tsv", f.manifest)
	if _, err := os.Stat(filepath.Join(dst, "com.od", "base.apk")); !os.IsNotExist(err) {
		t.Fatalf("the torn file must not restore at login; stat err=%v", err)
	}
}

// (a) a torn on-demand APK leaves no raw bytes in the essential stream.
func TestTornDeferredLeavesEssentialStreamIntact(t *testing.T) { tornPushAndCheck(t, false) }

// (b) the same behind a zero prefix, which tar reads as the end of the archive: every later file must still restore.
func TestTornDeferredZeroPrefixDoesNotEndTheArchive(t *testing.T) { tornPushAndCheck(t, true) }

// A discarded chunk and an essential chunk with the same content share one blob hash: the head must still
// reference only blobs the store holds, and the restore must be complete.
func TestTornDeferredSharedHashWithEssentialChunk(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "torndef3", "torn deferred horse battery staple"
	createVault(base, name, pass)
	f := stageTornApp(t, false)
	// The torn file opens with exactly the installed app's bytes, so its leading chunks hash like the essential ones.
	torn := append(append([]byte{}, f.keepApk...), prBytes(6<<20)...)
	if err := os.WriteFile(f.tornPath, torn, 0o600); err != nil {
		t.Fatal(err)
	}
	f.tornSize = len(torn)
	growOnce(t, f.tornPath)
	pushProfile(base, name+"#apps", pass, f.src)

	key, m := tornHeadManifest(t, base, name+"#apps", pass)
	for _, h := range m.Chunks {
		if sz := blobSize(base, h); sz <= 0 {
			t.Fatalf("head references chunk %s the store does not hold", h)
		}
	}
	dst := restoreEssential(t, base, key, m)
	wantFile(t, dst, "com.keep/base.apk", f.keepApk)
	wantFile(t, dst, "com.od/_meta/meta", f.meta)
	wantFile(t, dst, "manifest.tsv", f.manifest)
}

// (c) the next seal, with the file stable, seals it as a deferred entry of exactly its bytes.
func TestTornDeferredSealsOnceStable(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "torndef2", "torn deferred horse battery staple"
	createVault(base, name, pass)
	f := stageTornApp(t, false)
	growOnce(t, f.tornPath)
	pushProfile(base, name+"#apps", pass, f.src)

	sealAfterDeferredRead = func(string) {}
	pushProfile(base, name+"#apps", pass, f.src)

	key, m := tornHeadManifest(t, base, name+"#apps", pass)
	d, ok := m.Deferred["com.od/base.apk"]
	if !ok {
		t.Fatalf("the stable file must be deferred on the second seal; got %v", deferredRels(m.Deferred))
	}
	st, err := os.Stat(f.tornPath)
	if err != nil {
		t.Fatal(err)
	}
	if d.Size != st.Size() {
		t.Fatalf("deferred Size = %d, want the file's %d", d.Size, st.Size())
	}
	dst := restoreEssential(t, base, key, m)
	wantFile(t, dst, "com.keep/base.apk", f.keepApk)
	wantFile(t, dst, "com.od/_meta/meta", f.meta)
	wantFile(t, dst, "manifest.tsv", f.manifest)
}

// (d) walkChunks level: the discard range is exactly the indices emitted while the torn file was read, and a stable
// deferred file produces none.
func TestTornDeferredDiscardRangeIsExactlyTheTornEmits(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	dir := t.TempDir()
	iwrite(t, dir, "app.organicmaps/files/torn.mwm", prBytes(300<<10))
	iwrite(t, dir, "app.organicmaps/files/stable.mwm", prBytes(200<<10))
	tornPath := filepath.Join(dir, "app.organicmaps", "files", "torn.mwm")

	n := 0
	emit := func([]byte) int { n++; return n - 1 }
	walk := func() (def, discard []scanRange) {
		n = 0
		_, _, def, _, _, _, _, discard = walkChunks(dir, newFileScanCache(make([]byte, 32)), 4096, true, ondemandMedia(), nil, nil, nil, nil, 0,
			emit, func(string) int { return 0 }, func(int64) {}, nil)
		return
	}

	def, discard := walk()
	if len(discard) != 0 || len(def) != 2 {
		t.Fatalf("stable tree: want 2 deferred and no discard; got %d deferred, discard %+v", len(def), discard)
	}

	atSeam := -1
	old := sealAfterDeferredRead
	t.Cleanup(func() { sealAfterDeferredRead = old })
	sealAfterDeferredRead = func(p string) {
		if p != tornPath || atSeam >= 0 {
			return
		}
		atSeam = n
		fh, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			t.Errorf("grow: %v", err)
			return
		}
		defer fh.Close()
		_, _ = fh.Write(prBytes(64 << 10))
	}
	def, discard = walk()
	// stable.mwm sorts first and is one chunk, so the torn file's emits are [1, atSeam).
	if atSeam <= 1 {
		t.Fatalf("the torn read ended at emit %d, want at least one chunk after the stable file's", atSeam)
	}
	if len(discard) != 1 || discard[0].rel != "app.organicmaps/files/torn.mwm" || discard[0].start != 1 || discard[0].end != atSeam {
		t.Fatalf("discard = %+v, want one range [1,%d) for app.organicmaps/files/torn.mwm", discard, atSeam)
	}
	if len(def) != 1 || def[0].rel != "app.organicmaps/files/stable.mwm" {
		t.Fatalf("deferred = %+v, want only app.organicmaps/files/stable.mwm", def)
	}
}
