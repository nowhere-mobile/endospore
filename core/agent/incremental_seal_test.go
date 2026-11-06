package main

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// The correctness invariant of the incremental (#69) chunker: the plaintext chunks it emits, concatenated in
// manifest order, MUST equal tarDirTo(src) EXACTLY -- because restore just concatenates chunk plaintexts and
// untars them, so byte-identity here == a byte-identical restore. We assert it across a full seal, a no-change
// seal (large files reused from the scan cache), a small-file change, and a large-file change.

func iwrite(t *testing.T, dir, rel string, b []byte) {
	t.Helper()
	p := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func tarBytes(t *testing.T, dir string) []byte {
	t.Helper()
	var buf bytes.Buffer
	if _, err := tarDirTo(dir, &buf); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

type sealOut struct {
	order  []string
	cached map[string]bool
}

// sealCollect drives walkChunks with a fake store (hash->plaintext) so the test can reconstruct the byte
// stream, and refreshes the scan cache exactly as pushProfile does after a successful seal.
func sealCollect(t *testing.T, src string, sc *fileScanCache, store map[string][]byte, threshold int64, forceFull bool) sealOut {
	t.Helper()
	var order []string
	cached := map[string]bool{}
	emitSeal := func(c []byte) int {
		h := chunkHash(c)
		store[h] = append([]byte(nil), c...)
		order = append(order, h)
		blobCacheAdd(h) // a real seal confirms the blob present; the scan cache's get() gates reuse on this
		return len(order) - 1
	}
	emitCached := func(h string) int {
		order = append(order, h)
		cached[h] = true
		return len(order) - 1
	}
	ranges, _, _, _, _, _, _, _ := walkChunks(src, sc, threshold, forceFull, ondemandMedia(), nil, nil, nil, nil, 0, emitSeal, emitCached, func(int64) {}, nil)
	for _, r := range ranges {
		sc.put(r.rel, r.mtime, r.size, r.mode, order[r.start:r.end])
	}
	return sealOut{order, cached}
}

func concatChunks(store map[string][]byte, order []string) []byte {
	var buf bytes.Buffer
	for _, h := range order {
		buf.Write(store[h])
	}
	return buf.Bytes()
}

func makeTree(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	iwrite(t, dir, "a_small.txt", []byte("hello small a"))
	iwrite(t, dir, "big.bin", bytes.Repeat([]byte("BIGDATA_"), 4000))  // 32 KiB > threshold -> file-aligned
	iwrite(t, dir, "m_mid.bin", bytes.Repeat([]byte("MIDDLE__"), 300)) // 2.4 KiB > threshold
	iwrite(t, dir, "sub/z_small.txt", []byte("nested small file"))
	iwrite(t, dir, "sub/deep/tiny", []byte("x"))
	return dir
}

func TestIncrementalChunksMatchTar(t *testing.T) {
	blobCacheMu.Lock()
	blobCache = map[string]bool{}
	blobCacheMu.Unlock()
	t.Setenv("NOWHERE_BLOBCACHE", "") // in-memory only; no disk persistence in the test

	const threshold = 1024
	dir := makeTree(t)
	sc := &fileScanCache{m: map[string]scanEntry{}}
	store := map[string][]byte{}

	// 1) full seal (empty cache) -> byte-identical to tarDirTo.
	r1 := sealCollect(t, dir, sc, store, threshold, false)
	if got, want := concatChunks(store, r1.order), tarBytes(t, dir); !bytes.Equal(got, want) {
		t.Fatalf("full seal chunks != tarDirTo (%d vs %d bytes)", len(got), len(want))
	}
	if len(r1.cached) != 0 {
		t.Fatal("the first seal has nothing to reuse")
	}

	// 2) no-change seal -> still byte-identical, and the large files came from the cache (skipped).
	r2 := sealCollect(t, dir, sc, store, threshold, false)
	if got, want := concatChunks(store, r2.order), tarBytes(t, dir); !bytes.Equal(got, want) {
		t.Fatal("no-change seal chunks != tarDirTo")
	}
	if len(r2.cached) == 0 {
		t.Fatal("no-change seal should reuse the unchanged large files (big.bin, m_mid.bin) from the scan cache")
	}

	// 3) change a SMALL file (grouped, re-chunked) -> still byte-identical.
	time.Sleep(10 * time.Millisecond)
	iwrite(t, dir, "a_small.txt", []byte("hello small a -- CHANGED and longer now"))
	r3 := sealCollect(t, dir, sc, store, threshold, false)
	if got, want := concatChunks(store, r3.order), tarBytes(t, dir); !bytes.Equal(got, want) {
		t.Fatal("small-file-change seal chunks != tarDirTo")
	}

	// 4) change a LARGE file (content + size + mtime) -> still byte-identical, and it's re-chunked, not reused.
	time.Sleep(10 * time.Millisecond)
	iwrite(t, dir, "big.bin", bytes.Repeat([]byte("NEWDATA_"), 6000)) // different size -> definite cache miss
	r4 := sealCollect(t, dir, sc, store, threshold, false)
	if got, want := concatChunks(store, r4.order), tarBytes(t, dir); !bytes.Equal(got, want) {
		t.Fatal("large-file-change seal chunks != tarDirTo")
	}
}

// forceFull ignores the scan cache: every large file is re-chunked (the periodic full-rehash safety valve).
func TestIncrementalForceFullReChunks(t *testing.T) {
	blobCacheMu.Lock()
	blobCache = map[string]bool{}
	blobCacheMu.Unlock()
	t.Setenv("NOWHERE_BLOBCACHE", "")

	const threshold = 1024
	dir := makeTree(t)
	sc := &fileScanCache{m: map[string]scanEntry{}}
	store := map[string][]byte{}

	sealCollect(t, dir, sc, store, threshold, false) // populate the cache
	r := sealCollect(t, dir, sc, store, threshold, true)
	if len(r.cached) != 0 {
		t.Fatalf("forceFull must re-chunk everything, but %d chunks were reused from the cache", len(r.cached))
	}
	if got, want := concatChunks(store, r.order), tarBytes(t, dir); !bytes.Equal(got, want) {
		t.Fatal("forceFull seal chunks != tarDirTo")
	}
}

// A deleted large file is dropped from the scan cache (save keeps only the rels seen this seal), and the
// stream stays byte-identical.
func TestIncrementalHandlesDeletion(t *testing.T) {
	blobCacheMu.Lock()
	blobCache = map[string]bool{}
	blobCacheMu.Unlock()
	t.Setenv("NOWHERE_BLOBCACHE", "")

	const threshold = 1024
	dir := makeTree(t)
	sc := &fileScanCache{m: map[string]scanEntry{}}
	store := map[string][]byte{}

	sealCollect(t, dir, sc, store, threshold, false)
	if err := os.Remove(filepath.Join(dir, "big.bin")); err != nil {
		t.Fatal(err)
	}
	r := sealCollect(t, dir, sc, store, threshold, false)
	if got, want := concatChunks(store, r.order), tarBytes(t, dir); !bytes.Equal(got, want) {
		t.Fatal("post-deletion seal chunks != tarDirTo")
	}
}

// TestSealWalkBlindClassifies pins the distinction the #media day-long seal outage turned on: a walk error
// meaning "this path VANISHED under the live user" is benign and must be skipped, while ANY other error
// (EACCES on a directory we must descend, EIO) means the walk went blind and the resulting manifest is short.
// The original code returned nil for both, so an EACCES on the walk root produced an empty manifest that only
// the shrink guard caught -- and that guard is inert on a scope's first seal.
func TestSealWalkBlindClassifies(t *testing.T) {
	for _, tc := range []struct {
		name  string
		err   error
		blind bool
	}{
		{"nil", nil, false},
		{"vanished", &fs.PathError{Op: "lstat", Path: "/x", Err: syscall.ENOENT}, false},
		{"wrapped vanished", fmt.Errorf("walk: %w", fs.ErrNotExist), false},
		{"permission denied", &fs.PathError{Op: "open", Path: "/data/media", Err: syscall.EACCES}, true},
		{"io error", &fs.PathError{Op: "read", Path: "/x", Err: syscall.EIO}, true},
	} {
		if got := sealWalkBlind(tc.err); got != tc.blind {
			t.Errorf("%s: sealWalkBlind(%v) = %v, want %v", tc.name, tc.err, got, tc.blind)
		}
	}
}

// A FIFO must be classified from the DIRECTORY ENTRY, with no stat of the file itself. That is the whole
// point: SELinux denies { getattr } on Realm's TrealmStorage.note under an app's data dir, so anything that
// stats the file is already lost -- and a blind path there refuses EVERY logoff (Tesla, NWP-20260825-09).
// A regular file and a dir must NOT be classified special, or a genuinely unreadable file would be silently
// skipped instead of refusing, which is the failure mode the blind counter exists to prevent.
func TestSealSpecialFromDirentClassifiesWithoutStat(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "TrealmStorage.note")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Skipf("mkfifo unsupported here: %v", err)
	}
	reg := filepath.Join(dir, "plain.db")
	if err := os.WriteFile(reg, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(dir, "adir")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	cache := map[string]map[string]fs.FileMode{}
	for _, tc := range []struct {
		path        string
		wantSpecial bool
	}{
		{fifo, true},
		{reg, false},
		{sub, false},
	} {
		sp, known := sealSpecialFromDirent(tc.path, cache)
		if !known {
			t.Fatalf("%s: not knowable from the dirent -- the walk would refuse the seal", tc.path)
		}
		if sp != tc.wantSpecial {
			t.Fatalf("%s: special=%v want %v", tc.path, sp, tc.wantSpecial)
		}
	}
	// A path that does not exist is NOT knowable -- the caller must keep treating it as blind.
	if _, known := sealSpecialFromDirent(filepath.Join(dir, "nope"), cache); known {
		t.Fatal("a missing entry must not be reported as knowable")
	}
}

// A refusal has to NAME the app blocking sign-out, so the package must come out of the unreadable path.
// The non-app cases matter as much as the app ones: /data/media has no package, and naming the wrong thing
// in a dialog that offers to DROP that app's data would be worse than naming nothing (NWP-20260825-13).
func TestBlindPkgOf(t *testing.T) {
	for _, tc := range []struct{ path, want string }{
		{"/data/user/10/com.teslamotors.tesla/files/TrealmStorage.note", "com.teslamotors.tesla"},
		{"/data/user_de/10/com.teslamotors.tesla/x", "com.teslamotors.tesla"},
		{"/data/user/10/com.teslamotors.tesla", "com.teslamotors.tesla"},
		{"/data/media/10/Pictures/x.jpg", ""},
		{"/data/user/10", ""},
		{"/data/user/", ""},
		{"/somewhere/else", ""},
		{"", ""},
	} {
		if got := blindPkgOf(tc.path); got != tc.want {
			t.Errorf("blindPkgOf(%q) = %q, want %q", tc.path, got, tc.want)
		}
	}
}
