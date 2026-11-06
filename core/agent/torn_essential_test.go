package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261024-03: a file-aligned ESSENTIAL file that changes while the seal copies it is detected (a short copy,
// or a post-copy fstat that disagrees with the walk stat), its chunks go to `discard`, and it is read ONCE more from
// a fresh stat. Before this the entry was the walk-time header around a mix of old and new bytes -- zero-padded if
// the file shrank, cut if it grew -- and it was recorded and counted as walked.

type tornEssFixture struct {
	src     string
	bigPath string
	before  []byte
	after   []byte
	bigSize int
}

func stageTornEssential(t *testing.T) *tornEssFixture {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_DEFER_LIST", "")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	// The blob and content caches are process-global and keyed by the profile's DK (see stageTornApp).
	blobCache = nil
	contentCache = nil
	f := &tornEssFixture{src: t.TempDir()}
	f.before = []byte("a small file before the large one")
	f.after = []byte("a small file after the large one")
	for rel, b := range map[string][]byte{"a-before.txt": f.before, "z-after.txt": f.after, "m-big.bin": prBytes(2 << 20)} {
		if err := os.WriteFile(filepath.Join(f.src, rel), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	f.bigPath = filepath.Join(f.src, "m-big.bin")
	f.bigSize = 2 << 20
	return f
}

// hookFor installs sealAfterEssentialCopy so that fn runs on the first n calls for path, with the 1-based call
// number; calls for other paths (grouped files reach the seam too) are ignored. It returns the per-path call count.
func hookFor(t *testing.T, path string, n int, fn func(call int)) *int {
	t.Helper()
	old := sealAfterEssentialCopy
	t.Cleanup(func() { sealAfterEssentialCopy = old })
	calls := new(int)
	sealAfterEssentialCopy = func(p string) {
		if p != path {
			return
		}
		*calls++
		if *calls <= n {
			fn(*calls)
		}
	}
	return calls
}

func appendTo(t *testing.T, path string, b []byte) {
	t.Helper()
	fh, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Errorf("append: %v", err)
		return
	}
	defer fh.Close()
	if _, err := fh.Write(b); err != nil {
		t.Errorf("append: %v", err)
	}
}

func tornEssPush(t *testing.T, name string, f *tornEssFixture) (base, pass string) {
	t.Helper()
	base = newHTTPStore(t)
	pass = "torn essential horse battery staple"
	createVault(base, name, pass)
	pushProfile(base, name, pass, f.src)
	return base, pass
}

func checkTornEssRestore(t *testing.T, base, name, pass string, f *tornEssFixture) {
	t.Helper()
	_, dst := restoreManifest(t, base, name, pass)
	want, err := os.ReadFile(f.bigPath)
	if err != nil {
		t.Fatal(err)
	}
	wantFile(t, dst, "m-big.bin", want)
	wantFile(t, dst, "a-before.txt", f.before)
	wantFile(t, dst, "z-after.txt", f.after)
}

// (a) the file shrinks to 1 MiB and its head is rewritten while it is copied: the restore is the content AFTER the
// change, not the new head followed by zero padding up to the walk-time 2 MiB.
func TestTornEssentialShrinkIsReread(t *testing.T) {
	f := stageTornEssential(t)
	calls := hookFor(t, f.bigPath, 1, func(int) {
		if err := os.Truncate(f.bigPath, 1<<20); err != nil {
			t.Errorf("truncate: %v", err)
			return
		}
		fh, err := os.OpenFile(f.bigPath, os.O_WRONLY, 0o644)
		if err != nil {
			t.Errorf("open: %v", err)
			return
		}
		defer fh.Close()
		// shifted by 17 so the new head differs from the old one (prBytes is deterministic)
		if _, err := fh.WriteAt(prBytes(1<<20 + 17)[17:], 0); err != nil {
			t.Errorf("rewrite: %v", err)
		}
	})
	base, pass := tornEssPush(t, "tornessa", f)
	if *calls != 2 {
		t.Fatalf("the file was copied %d time(s), want 2 (the torn read and one re-read)", *calls)
	}
	checkTornEssRestore(t, base, "tornessa", pass, f)
	if st, err := os.Stat(f.bigPath); err != nil || st.Size() != 1<<20 {
		t.Fatalf("fixture: file is %v (err %v), want 1 MiB", st, err)
	}
}

// (b) the file grows while it is copied: the walk-size header cut the copy, the restore is the grown file.
func TestTornEssentialGrowthIsReread(t *testing.T) {
	f := stageTornEssential(t)
	hookFor(t, f.bigPath, 1, func(int) { appendTo(t, f.bigPath, prBytes(256<<10)) })
	base, pass := tornEssPush(t, "tornessb", f)
	checkTornEssRestore(t, base, "tornessb", pass, f)
	if st, err := os.Stat(f.bigPath); err != nil || st.Size() != int64(f.bigSize)+256<<10 {
		t.Fatalf("fixture: file is %v (err %v), want it grown by 256 KiB", st, err)
	}
}

// (c) a file that keeps changing is copied exactly twice -- never a third read -- and the seal completes with the
// re-read's size: the second copy is cut at the size the fresh Lstat saw.
func TestTornEssentialIsReadAtMostTwice(t *testing.T) {
	f := stageTornEssential(t)
	var seen int64
	calls := hookFor(t, f.bigPath, 5, func(call int) {
		appendTo(t, f.bigPath, prBytes(64<<10))
		if call == 1 {
			st, err := os.Stat(f.bigPath)
			if err != nil {
				t.Errorf("stat: %v", err)
				return
			}
			seen = st.Size() // what the re-read's fresh Lstat will see
		}
	})
	base, pass := tornEssPush(t, "tornessc", f)
	if *calls != 2 {
		t.Fatalf("the file was copied %d time(s), want exactly 2", *calls)
	}
	_, dst := restoreManifest(t, base, "tornessc", pass)
	got, err := os.ReadFile(filepath.Join(dst, "m-big.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(got)) != seen {
		t.Fatalf("restored %d bytes, want the %d the re-read's fresh stat saw", len(got), seen)
	}
	wantFile(t, dst, "a-before.txt", f.before)
	wantFile(t, dst, "z-after.txt", f.after)
}

func tornEssWalk(t *testing.T, dir string) (ranges, discard []scanRange, emitted int) {
	t.Helper()
	n := 0
	emit := func([]byte) int { n++; return n - 1 }
	ranges, _, _, _, _, _, _, discard = walkChunks(dir, newFileScanCache(make([]byte, 32)), 4096, true, false, nil, nil, nil, nil, 0,
		emit, func(string) int { return 0 }, func(int64) {}, nil)
	return ranges, discard, n
}

// (d) walkChunks level: a stable file produces no discard; a torn one reports the first read's emits as discard, the
// re-read's as its range, and the range carries the fresh mtime and size.
func TestTornEssentialDiscardAndFreshRange(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_DEFER_LIST", "")
	dir := t.TempDir()
	iwrite(t, dir, "a-small.txt", []byte("small"))
	iwrite(t, dir, "m-big.bin", prBytes(300<<10))
	iwrite(t, dir, "z-small.txt", []byte("small too"))
	bigPath := filepath.Join(dir, "m-big.bin")

	ranges, discard, _ := tornEssWalk(t, dir)
	if len(discard) != 0 {
		t.Fatalf("stable tree: discard = %+v, want none", discard)
	}
	if len(ranges) == 0 {
		t.Fatal("stable tree: no ranges recorded")
	}

	hookFor(t, bigPath, 1, func(int) { appendTo(t, bigPath, prBytes(64<<10)) })
	ranges, discard, _ = tornEssWalk(t, dir)
	if len(discard) != 1 || discard[0].rel != "m-big.bin" || discard[0].end <= discard[0].start {
		t.Fatalf("discard = %+v, want one non-empty range for m-big.bin", discard)
	}
	var got *scanRange
	for i := range ranges {
		if ranges[i].rel == "m-big.bin" {
			got = &ranges[i]
		}
	}
	if got == nil {
		t.Fatalf("ranges = %+v, want one for m-big.bin", ranges)
	}
	if got.start != discard[0].end {
		t.Fatalf("re-read range starts at %d, want %d: it must follow the discarded emits immediately", got.start, discard[0].end)
	}
	st, err := os.Lstat(bigPath)
	if err != nil {
		t.Fatal(err)
	}
	if got.size != st.Size() || got.mtime != st.ModTime().UnixNano() {
		t.Fatalf("range carries size %d mtime %d, want the fresh %d / %d", got.size, got.mtime, st.Size(), st.ModTime().UnixNano())
	}
}

// (e) a grouped small file that changes during its copy still seals without error. writeEntriesTar cannot discard
// an entry (its chunks are shared with its neighbours), so since NWP-20261027-06 it heals a tear itself --
// torn_grouped_test.go pins the bytes; this only pins that the seal does not fail.
func TestTornEssentialGroupedFileStillSeals(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "small.txt")
	if err := os.WriteFile(p, bytes.Repeat([]byte("x"), 100), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	hookFor(t, p, 1, func(int) { appendTo(t, p, []byte("more")) })
	var buf bytes.Buffer
	if err := writeEntriesTar(&buf, []walkEnt{{p, "small.txt", info}}); err != nil {
		t.Fatalf("writeEntriesTar on a changed grouped file: %v", err)
	}
	if buf.Len() == 0 {
		t.Fatal("no tar bytes written")
	}
}
