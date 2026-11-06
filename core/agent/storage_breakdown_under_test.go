package main

import (
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// NWP-20261016-49: the breakdown summed each media fetch cache dir whole into CacheBytes, `.under` included.
// `.under/<leaf>` is mediad's bind of an overlaid dir, so its files are the user's REAL files (pinned and
// prefetched media, app write-backs, the real contents of an overlaid DCIM), and the bind is the only place the
// walk sees them. The "Streamed maps and photos" row then offered them as cache that "re-downloads when you open
// it again", beside a Clear that never frees them. And a range fetch's sparse `.part` counted at the whole file's
// size, so the row came back at gigabytes the phone does not hold after a Clear that keeps every `.part`. These
// tests stand the device's tree up under a temp root and run collectStorageBreakdownAt itself.

func TestUnderRelInvertsUnderLeaf(t *testing.T) {
	long := strings.Repeat("_/", 100)
	for _, r := range []string{"", "_", "/", "__", "//", "_/", "/_", "_u", "_s", "_h", "u", "s", "a/b/c", "a_b/c",
		"Pictures/Screenshots", "Pictures_Screenshots", "Android/data/app.organicmaps/files", "Movies.2024",
		strings.Repeat("_", 127) + "a"} {
		got, ok := underRel(underLeaf(r))
		if !ok || got != r {
			t.Errorf("underRel(underLeaf(%q)) = %q, %v; want %q, true", r, got, ok, r)
		}
	}
	// The hashed form (a rel too long to escape) cannot be read back, and must say so rather than invent a rel.
	if l := underLeaf(long); !strings.HasPrefix(l, "_h") {
		t.Fatalf("fixture: underLeaf of a long rel is not hashed: %q", l)
	}
	for _, leaf := range []string{underLeaf(long), "_x", "abc_", "_"} {
		if got, ok := underRel(leaf); ok {
			t.Errorf("underRel(%q) = %q, true; a leaf underLeaf never writes must not decode", leaf, got)
		}
	}
}

func TestUnderOwnerFollowsTheRealPathsRule(t *testing.T) {
	for _, c := range []struct {
		external  bool
		rel, want string
	}{
		{true, "DCIM/Camera/IMG.jpg", ""},
		{true, "Movies.2024/m.mp4", ""}, // a dotted folder on the media root is not a package
		{true, "Android/data/com.example.maps/files/w.map", "com.example.maps"},
		{true, "Android/obb/com.game/main.obb", "com.game"},
		{true, "Android/media/com.example.rec/a.wav", "com.example.rec"},
		{true, "Android/data/com.nowhere.chooser/.nowhere-odhold/com.held/files/a", "com.held"},
		// The chooser's own external data outside its hold: the real-path walk skips Android/data and Android/obb
		// for the chooser (skipChooser) and counts Android/media whole, so this does too.
		{true, "Android/data/com.nowhere.chooser/files/x/f", ""},
		{true, "Android/obb/com.nowhere.chooser/x.obb", ""},
		{true, "Android/media/com.nowhere.chooser/a", "com.nowhere.chooser"},
		{false, "com.example.ce/files/maps/x", "com.example.ce"},
		{false, "com.nowhere.chooser/.nowhere-odhold/com.held/files/a", "com.held"},
		{false, "com.nowhere.chooser/files/x", ""},
		{false, ".hidden/x", ""},
	} {
		if got := underOwner(c.external, c.rel); got != c.want {
			t.Errorf("underOwner(%v, %q) = %q, want %q", c.external, c.rel, got, c.want)
		}
	}
}

func TestStorageBreakdownUnderIsRealFilesNotCache(t *testing.T) {
	root := t.TempDir()
	user := filepath.Join(root, "data", "user", "10")
	media := filepath.Join(root, "data", "media", "10")
	ext := filepath.Join(user, chooserPkg, "files", ".nowhere-media-ext")
	ce := filepath.Join(user, chooserPkg, "files", ".nowhere-media")
	hexA, hexB, hexC := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	var planted int64
	plant := func(p string, n int) {
		mkfile(t, p, n)
		planted += int64(n)
	}

	// DE exists, empty: an absent volume root counts as blind (newWalkState), and this tree must read clean.
	if err := os.MkdirAll(filepath.Join(root, "data", "user_de", "10"), 0o755); err != nil {
		t.Fatal(err)
	}
	plant(filepath.Join(user, "com.example.app", "files", "f"), 100) // CE app data
	plant(filepath.Join(media, "Music", "song.mp3"), 200)            // the user's own, not overlaid

	// The #media scope's cache: what Clear frees, what it keeps, and the binds. (A sparse `.part` has its own
	// test below: its figure depends on the blocks the filesystem allocates.)
	plant(filepath.Join(ext, hexA), 1000)       // a complete entry
	plant(filepath.Join(ext, hexB+".have"), 30) // a range fetch's chunk map
	plant(filepath.Join(ext, ".deleted"), 7)    // the #media tombstones
	under := filepath.Join(ext, ".under")
	plant(filepath.Join(under, underLeaf("DCIM"), "Camera", "IMG.jpg"), 5000)
	plant(filepath.Join(under, underLeaf("Pictures/Screenshots"), "s.png"), 300)
	plant(filepath.Join(under, underLeaf("Movies.2024"), "m.mp4"), 60)
	plant(filepath.Join(under, underLeaf("Android/data/com.example.maps/files"), "maps", "w.map"), 7000)
	// One bind can hold several apps' files: each goes to its own owner, not the leaf's.
	plant(filepath.Join(under, underLeaf("Android/obb"), "com.game", "main.obb"), 900)
	plant(filepath.Join(under, underLeaf("Android/obb"), "com.other", "p.obb"), 50)
	// The chooser's own Android/data outside its hold is the user's, never a chooser row.
	plant(filepath.Join(under, underLeaf("Android/data/com.nowhere.chooser/files"), "x"), 11)
	// A rel too long to escape is hashed and cannot be read back: still real bytes, so still counted -- and its
	// owner is unknown, so a path INSIDE the bind that looks like an owner must not name one.
	long := strings.Repeat("Deep/", 60)
	plant(filepath.Join(under, underLeaf(long), "big"), 40)
	plant(filepath.Join(under, underLeaf(long), "Android", "data", "com.trap", "f"), 17)

	// The CE vault's cache.
	plant(filepath.Join(ce, hexC), 400)
	plant(filepath.Join(ce, ".under", underLeaf("com.example.ce/files/maps"), "x"), 800)
	ceLong := "com.example.ce/files/" + long
	if l := underLeaf(ceLong); !strings.HasPrefix(l, "_h") {
		t.Fatalf("fixture: underLeaf of a long CE rel is not hashed: %q", l)
	}
	plant(filepath.Join(ce, ".under", underLeaf(ceLong), "cache.v2", "y"), 13) // a dotted dir reads as a CE package

	b := collectStorageBreakdownAt(root, "10", nil)
	rows := map[string]int64{}
	var appSum int64
	for _, a := range b.Apps {
		rows[a.Pkg] = a.Bytes
		appSum += a.Bytes
	}

	if want := int64(1000 + 30 + 7 + 400); b.CacheBytes != want {
		t.Errorf("CacheBytes = %d, want %d: only the fetch caches outside .under (entries, sidecars, .deleted)", b.CacheBytes, want)
	}
	if want := int64(200 + 5000 + 300 + 60 + 11 + 40 + 17 + 13); b.MediaBytes != want {
		t.Errorf("MediaBytes = %d, want %d: the user's own files, the overlaid ones read through .under included", b.MediaBytes, want)
	}
	for pkg, want := range map[string]int64{
		"com.example.maps": 7000, "com.game": 900, "com.other": 50, "com.example.ce": 800, "com.example.app": 100,
	} {
		if rows[pkg] != want {
			t.Errorf("app row %s = %d, want %d", pkg, rows[pkg], want)
		}
	}
	for _, notPkg := range []string{"Movies.2024", "DCIM", chooserPkg, "com.trap", "cache.v2"} {
		if _, ok := rows[notPkg]; ok {
			t.Errorf("a row named %q: .under bytes were attributed to something that is not an app", notPkg)
		}
	}
	// Every planted file counted exactly once: moving .under out of the cache neither drops nor doubles a byte.
	if b.TotalBytes != planted {
		t.Errorf("TotalBytes = %d, want %d (every planted byte, once)", b.TotalBytes, planted)
	}
	if appSum+b.MediaBytes+b.CacheBytes != b.TotalBytes {
		t.Errorf("rows %d + media %d + cache %d != total %d", appSum, b.MediaBytes, b.CacheBytes, b.TotalBytes)
	}
	if b.Blind != 0 {
		t.Errorf("Blind = %d on a fully readable tree", b.Blind)
	}
}

// writePart lays out a range fetch's `.part` the way initPart and ensureRange do: truncated to the whole file's size,
// then n bytes written at off. The bytes are random so that no filesystem can store them as a hole.
func writePart(t *testing.T, p string, size, off int64, n int) {
	t.Helper()
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := f.Truncate(size); err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteAt(buf, off); err != nil {
		t.Fatal(err)
	}
	if err := f.Sync(); err != nil {
		t.Fatal(err)
	}
}

// partOnDisk is what the filesystem says p takes: its allocated blocks, capped at its apparent size.
func partOnDisk(t *testing.T, p string) (disk, allocated int64) {
	t.Helper()
	fi, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	sys, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatalf("no stat_t for %s", p)
	}
	allocated = int64(sys.Blocks) * 512
	return min(fi.Size(), allocated), allocated
}

// The sparse `.part` OrganicMaps' startup header read leaves for every map counts by the disk it holds, not by the
// whole map its holes stand for: Clear keeps every `.part`, so counted at apparent size the row came back after a
// Clear at nearly the gigabytes it showed before it, and none of them were on the phone.
func TestStorageBreakdownPartCountsTheDiskItHolds(t *testing.T) {
	root := t.TempDir()
	ext := filepath.Join(root, "data", "user", "10", chooserPkg, "files", ".nowhere-media-ext")
	for _, d := range []string{filepath.Join(root, "data", "user_de", "10"), filepath.Join(root, "data", "media", "10"), ext} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	hexA, hexB, hexC := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	mkfile(t, filepath.Join(ext, hexA), 1000)       // a complete entry: its apparent size, as freemedia's toast counts it
	mkfile(t, filepath.Join(ext, hexB+".have"), 64) // the sparse part's chunk map, one byte per chunk
	const mapSize, written = 64 << 20, 64 << 10
	sparse := filepath.Join(ext, hexB+".part")
	writePart(t, sparse, mapSize, 8<<20, written) // one chunk of a 64 MiB map
	// A part whose every byte is written is not sparse: it counts at its size, not rounded up to whole blocks.
	full := filepath.Join(ext, hexC+".part")
	writePart(t, full, 5000, 0, 5000)

	sparseDisk, _ := partOnDisk(t, sparse)
	fullDisk, fullAlloc := partOnDisk(t, full)
	// The figures below depend on the filesystem under t.TempDir, so check it does what the device's does.
	if sparseDisk < written || sparseDisk >= 1<<20 {
		t.Fatalf("fixture: the temp filesystem holds %d bytes of a %d-byte .part with %d written; this test needs one that "+
			"keeps a file sparse and reports its blocks at write time (ext4, f2fs, tmpfs): point TMPDIR at one",
			sparseDisk, mapSize, written)
	}
	if fullDisk != 5000 || fullAlloc <= 5000 {
		t.Fatalf("fixture: a fully written 5000-byte .part holds %d bytes in %d allocated; this test needs a filesystem "+
			"that allocates whole blocks (ext4, f2fs, tmpfs)", fullDisk, fullAlloc)
	}

	b := collectStorageBreakdownAt(root, "10", nil)
	if again, _ := partOnDisk(t, sparse); again != sparseDisk {
		t.Fatalf("fixture: the sparse .part's allocation moved from %d to %d during the walk", sparseDisk, again)
	}

	if want := 1000 + 64 + sparseDisk + fullDisk; b.CacheBytes != want {
		t.Errorf("CacheBytes = %d, want %d: the entry and the sidecar at their size, the sparse .part at the %d bytes "+
			"it holds (not its %d apparent), the full .part at its 5000 (not its %d allocated)",
			b.CacheBytes, want, sparseDisk, int64(mapSize), fullAlloc)
	}
	if b.TotalBytes != b.CacheBytes {
		t.Errorf("TotalBytes = %d, want %d: only the cache was planted", b.TotalBytes, b.CacheBytes)
	}
	if b.Blind != 0 {
		t.Errorf("Blind = %d on a fully readable tree", b.Blind)
	}
}

// A cache dir or a `.under` dir that cannot be listed is a SHORT walk, and must say so (Blind) rather than look like
// a complete small figure. Each of the two ReadDirs keeps its own count: chmod covers the realistic EACCES when not
// root (a cache dir that can be searched but not listed still lets the walk reach its `.under`), and a regular file
// where the dir belongs gives ENOTDIR for root too.
func TestStorageBreakdownUnlistableCacheOrUnderIsBlind(t *testing.T) {
	for _, c := range []struct {
		name                   string
		nonRoot                bool
		spoil                  func(t *testing.T, ext string)
		blind                  int
		cacheBytes, mediaBytes int64
	}{
		{"cache dir searchable, not listable", true, func(t *testing.T, ext string) { chmodFor(t, ext, 0o100) },
			1, 0, 200 + 5000},
		{".under not listable", true, func(t *testing.T, ext string) { chmodFor(t, filepath.Join(ext, ".under"), 0o000) },
			1, 1000, 200},
		// Both ReadDirs fail, the cache dir's and the one of its `.under` beneath it: one count each.
		{"cache dir is a file", false, func(t *testing.T, ext string) { replaceWithFile(t, ext) },
			2, 0, 200},
		{".under is a file", false, func(t *testing.T, ext string) { replaceWithFile(t, filepath.Join(ext, ".under")) },
			1, 1000, 200},
	} {
		t.Run(c.name, func(t *testing.T) {
			if c.nonRoot && os.Geteuid() == 0 {
				t.Skip("root ignores directory permissions")
			}
			root := t.TempDir()
			ext := filepath.Join(root, "data", "user", "10", chooserPkg, "files", ".nowhere-media-ext")
			if err := os.MkdirAll(filepath.Join(root, "data", "user_de", "10"), 0o755); err != nil {
				t.Fatal(err)
			}
			mkfile(t, filepath.Join(root, "data", "media", "10", "Music", "song.mp3"), 200)
			mkfile(t, filepath.Join(ext, strings.Repeat("a", 64)), 1000)
			mkfile(t, filepath.Join(ext, ".under", underLeaf("DCIM"), "a.jpg"), 5000)
			c.spoil(t, ext)

			b := collectStorageBreakdownAt(root, "10", nil)
			if b.Blind != c.blind {
				t.Errorf("Blind = %d, want %d: a listing that failed must count as an undercount", b.Blind, c.blind)
			}
			if b.CacheBytes != c.cacheBytes || b.MediaBytes != c.mediaBytes {
				t.Errorf("CacheBytes, MediaBytes = %d, %d; want %d, %d", b.CacheBytes, b.MediaBytes, c.cacheBytes, c.mediaBytes)
			}
		})
	}
}

// chmodFor sets p's mode for the rest of the test and restores it after, so t.TempDir can clean up.
func chmodFor(t *testing.T, p string, mode os.FileMode) {
	t.Helper()
	if err := os.Chmod(p, mode); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(p, 0o755) })
}

// replaceWithFile swaps the dir p for a regular file of the same name, so listing p fails with ENOTDIR.
func replaceWithFile(t *testing.T, p string) {
	t.Helper()
	if err := os.RemoveAll(p); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}
