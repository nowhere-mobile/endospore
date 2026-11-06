package main

import (
	"bytes"
	"testing"
)

// TestWalkStatsSeparatesSmallFilesFromAnEmptyWalk pins the distinction that DIA-20260816-17 exists to make.
//
// The seal log used to print len(seen) as "walk saw %d path(s)". `seen` is populated at exactly one place in
// walkChunks -- inside `if info.Mode().IsRegular() && (info.Size() >= threshold || fd)` -- so it holds only
// files at or above the threshold. A scope full of small files therefore printed "walk saw 0 path(s)", which
// reads as "the walk found nothing".
//
// That misreading was expensive. It sent the #719 investigation and three follow-ups chasing an empty walk
// that never happened, including a "the restore returned nothing" theory and a "CE was evicted at seal time"
// theory, each costing a build-and-flash round to disprove. The measured case on lynx 2026081604: /data/media
// held Pictures and Movies of ~11 KB each, the walk read all of them, the manifest came out to 2 chunks /
// 1935 B -- and the line said 0.
//
// So: a scope of small files must report entries>0 and large==0, and an empty scope must report entries==0.
// If these two ever collapse to the same numbers again, the log has stopped being able to answer the only
// question anyone asks it.
func TestWalkStatsSeparatesSmallFilesFromAnEmptyWalk(t *testing.T) {
	const threshold = 1 << 20

	sink := func([]byte) int { return 0 }
	cached := func(string) int { return 0 }

	// --- a scope holding ONLY small files: the state that was misread as "found nothing" ---
	small := t.TempDir()
	iwrite(t, small, "Pictures/IMG_0001.jpg", bytes.Repeat([]byte("J"), 11*1024))
	iwrite(t, small, "Pictures/IMG_0002.jpg", bytes.Repeat([]byte("J"), 11*1024))
	iwrite(t, small, "Movies/clip.mp4", bytes.Repeat([]byte("M"), 11*1024))

	_, seen, _, _, _, _, st, _ := walkChunks(small, newFileScanCache(make([]byte, 32)), threshold, true, ondemandMedia(),
		nil, nil, nil, nil, 0, sink, cached, func(int64) {}, nil)

	// The old signal. Reproduced here deliberately: `seen` being empty is CORRECT and must stay that way --
	// it is the deferred-carry membership test, not a walk counter. The bug was the label, not this value.
	if len(seen) != 0 {
		t.Errorf("seen should hold only files >= threshold, got %d entries", len(seen))
	}
	// The new signal, which must NOT be zero.
	if st.entries == 0 {
		t.Fatal("a scope with three files reported an empty walk -- the log can still not tell a small-file scope from a broken restore")
	}
	if st.files != 3 {
		t.Errorf("files = %d, want 3", st.files)
	}
	if st.large != 0 {
		t.Errorf("large = %d, want 0 (nothing here reaches 1 MiB)", st.large)
	}
	if want := int64(3 * 11 * 1024); st.bytes != want {
		t.Errorf("bytes = %d, want %d", st.bytes, want)
	}
	// entries counts dirs too, so it must exceed the file count.
	if st.entries <= st.files {
		t.Errorf("entries (%d) should exceed files (%d): Pictures/ and Movies/ are entries as well", st.entries, st.files)
	}

	// --- a genuinely empty scope: the state the refusal message may legitimately shout about ---
	empty := t.TempDir()
	_, _, _, _, _, _, est, _ := walkChunks(empty, newFileScanCache(make([]byte, 32)), threshold, true, ondemandMedia(),
		nil, nil, nil, nil, 0, sink, cached, func(int64) {}, nil)

	if est.entries != 0 {
		t.Errorf("an empty dir must walk zero entries, got %d", est.entries)
	}
	if est.files != 0 || est.bytes != 0 {
		t.Errorf("an empty dir must walk zero files/bytes, got %d/%d", est.files, est.bytes)
	}

	// The whole point, stated as one assertion: these two scopes must not look alike.
	if st.entries == est.entries {
		t.Fatal("a small-file scope and an empty scope report identical entry counts -- the regression is back")
	}
}

// TestWalkStatsCountsLargeFilesAsSeenDoes keeps the new counter honest against the old one: st.large is meant
// to be a LABEL for len(seen), not a second, subtly different notion of largeness that could drift from it.
func TestWalkStatsCountsLargeFilesAsSeenDoes(t *testing.T) {
	const threshold = 4096

	dir := t.TempDir()
	iwrite(t, dir, "big1.bin", bytes.Repeat([]byte("B"), 8192))  // >= threshold
	iwrite(t, dir, "big2.bin", bytes.Repeat([]byte("B"), 4096))  // exactly threshold -> large
	iwrite(t, dir, "small.txt", bytes.Repeat([]byte("s"), 4095)) // one byte under -> not large

	_, seen, _, _, _, _, st, _ := walkChunks(dir, newFileScanCache(make([]byte, 32)), threshold, true, ondemandMedia(),
		nil, nil, nil, nil, 0, func([]byte) int { return 0 }, func(string) int { return 0 }, func(int64) {}, nil)

	if st.large != len(seen) {
		t.Errorf("large (%d) must agree with len(seen) (%d) -- they describe the same set", st.large, len(seen))
	}
	if st.large != 2 {
		t.Errorf("large = %d, want 2 (>= is inclusive, so the exactly-threshold file counts)", st.large)
	}
	if st.files != 3 {
		t.Errorf("files = %d, want 3 -- the small file is still walked and still tarred", st.files)
	}
}
