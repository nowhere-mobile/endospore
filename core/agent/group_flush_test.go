package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260903-22: the grouped essential tar must not be split for a file that contributes no tar bytes.
//
// flushGroup used to run at the TOP of the large-file branch, three lines before the tier decision -- so a
// DEFERRED file forced a group boundary even though both its arms return without writing a single tar byte
// (carry-by-hash reads nothing; the fresh arm chunks RAW file bytes into their own region). flushGroup
// starts a fresh cdcSplit, so each of those boundaries was a PERMANENT structural split in a ~1.95 GB
// grouped tar: the segment before ended in a truncated chunk, the one after restarted misaligned until the
// CDC re-synchronised. Measured on lynx: 65 chunks / 68.53 MiB uploaded by a logoff that should have
// carried almost everything by hash -- billed bytes, on the logoff critical path.
//
// These count EMITTED CHUNKS, which is exact here: every fixture file is far below cdcMin (256 KiB), so a
// group tar is always exactly one chunk. walkChunks also emits the tar FOOTER (two zero blocks) as one
// final chunk, so the arithmetic throughout is: <groups> + <large files> + 1.

// walkEmits runs a walk and returns (essential chunks emitted, deferred chunks emitted, large-file ranges).
func walkEmits(t *testing.T, dir string, threshold int64) (essential, deferredChunks int, ranges []scanRange) {
	t.Helper()
	emits := 0
	emit := func([]byte) int { i := emits; emits++; return i }
	sc := newFileScanCache(make([]byte, 32))
	rs, _, def, _, _, _, _, _ := walkChunks(dir, sc, threshold, true, ondemandMedia(), nil, nil, nil, nil, 0,
		emit, func(string) int { return 0 }, func(int64) {}, nil)
	for _, d := range def {
		deferredChunks += d.end - d.start
	}
	return emits - deferredChunks, deferredChunks, rs
}

// mediaFixture: a small file, a DEFERRED media file, another small file -- in walk order.
func mediaFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	iwrite(t, dir, "a.txt", []byte("small one"))
	iwrite(t, dir, "app.maps/files/big.bin", bytes.Repeat([]byte("M"), 8192))
	iwrite(t, dir, "z.txt", []byte("small two"))
	return dir
}

func TestDeferredFileDoesNotSplitTheGroupedTar(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_BLOBCACHE", "")
	blobCacheMu.Lock()
	blobCache = map[string]bool{}
	blobCacheMu.Unlock()

	ess, defc, rs := walkEmits(t, mediaFixture(t), 4096)
	if defc == 0 {
		t.Fatal("fixture is wrong: the media file did not defer, so nothing here tests the split")
	}
	if len(rs) != 0 {
		t.Fatalf("fixture is wrong: the media file took the ESSENTIAL large-file path (%d range(s))", len(rs))
	}
	// 1 group (a.txt + z.txt together) + 1 footer. A spurious split makes it 3.
	if ess != 2 {
		t.Fatalf("the two small files must share ONE group tar; a deferred file emits no tar bytes and must not split it: want 2 essential chunks (1 group + footer), got %d", ess)
	}
}

// The #204 force-defer list is the OTHER route into the same deferred return (any size, no media
// heuristic). It must not split the group either -- and it is the arm an on-demand app APK takes.
func TestForceDeferredFileDoesNotSplitTheGroupedTar(t *testing.T) {
	dir := t.TempDir()
	iwrite(t, dir, "a.txt", []byte("small one"))
	iwrite(t, dir, "m.apk", bytes.Repeat([]byte("K"), 8192))
	iwrite(t, dir, "z.txt", []byte("small two"))
	dl := filepath.Join(t.TempDir(), "defer.list")
	if err := os.WriteFile(dl, []byte("m.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", dl)

	ess, defc, _ := walkEmits(t, dir, 1<<20) // threshold ABOVE the file: only the defer list can select it
	if defc == 0 {
		t.Fatal("fixture is wrong: the force-defer list did not take effect")
	}
	// 1 group + 1 footer, as above.
	if ess != 2 {
		t.Fatalf("a force-deferred file emits no tar bytes and must not split the group: want 2 essential chunks (1 group + footer), got %d", ess)
	}
}

// THE OTHER HALF, and the reason this is a MOVE and not a DELETION: an ESSENTIAL large file is written
// file-aligned, so its region must still start on a chunk boundary. Drop the flush entirely and the small
// file before it would be carried into a group emitted AFTER the large file -- reordering the tar stream.
func TestEssentialLargeFileStillForcesABoundary(t *testing.T) {
	dir := t.TempDir()
	iwrite(t, dir, "a.txt", []byte("small one"))
	iwrite(t, dir, "big.bin", bytes.Repeat([]byte("E"), 8192))
	iwrite(t, dir, "z.txt", []byte("small two"))

	ess, defc, rs := walkEmits(t, dir, 4096)
	if defc != 0 {
		t.Fatalf("fixture is wrong: nothing should defer here (%d deferred chunk(s))", defc)
	}
	if len(rs) != 1 {
		t.Fatalf("expected exactly one essential large-file range, got %d", len(rs))
	}
	// group[a.txt] + big.bin + group[z.txt] + footer == 4, and the large region must NOT start at 0.
	if ess != 4 {
		t.Fatalf("an essential large file must still split the group: want 4 essential chunks (2 groups + the file + footer), got %d", ess)
	}
	if rs[0].start == 0 {
		t.Fatal("the large file was emitted BEFORE the group holding the file that precedes it -- the tar stream is reordered")
	}
}
