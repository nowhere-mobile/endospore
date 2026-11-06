package main

import (
	"archive/tar"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// NWP-20261027-06: a grouped small file that changes while the seal reads it is read whole, checked by a post-read
// fstat and read once more if it changed; the entry is the bytes last read under a header that matches them. Before
// this writeEntriesTar wrote the walk-time header around a copy that was cut (growth) or zero-padded (shrink).

type groupedEnt struct {
	name string
	hdr  tar.Header
	data []byte
}

func writeGroupedFile(t *testing.T, dir, rel string, b []byte) (string, os.FileInfo) {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	return p, info
}

func sealGrouped(t *testing.T, ents []walkEnt) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := writeEntriesTar(&buf, ents); err != nil {
		t.Fatalf("writeEntriesTar: %v", err)
	}
	return buf.Bytes()
}

func readGroupedTar(t *testing.T, b []byte) []groupedEnt {
	t.Helper()
	var out []groupedEnt
	tr := tar.NewReader(bytes.NewReader(b))
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return out
		}
		if err != nil {
			t.Fatalf("tar: %v", err)
		}
		d, err := io.ReadAll(tr)
		if err != nil {
			t.Fatalf("tar body: %v", err)
		}
		out = append(out, groupedEnt{h.Name, *h, d})
	}
}

func hookGrouped(t *testing.T, path string, fn func(call int)) *int {
	t.Helper()
	old := sealAfterGroupedRead
	t.Cleanup(func() { sealAfterGroupedRead = old })
	calls := new(int)
	sealAfterGroupedRead = func(p string) {
		if p != path {
			return
		}
		*calls++
		fn(*calls)
	}
	return calls
}

func wantGroupedEntry(t *testing.T, e groupedEnt, want []byte) {
	t.Helper()
	if e.hdr.Size != int64(len(want)) || !bytes.Equal(e.data, want) {
		t.Fatalf("entry %q: header size %d, %d bytes %q; want %d bytes %q", e.name, e.hdr.Size, len(e.data), e.data, len(want), want)
	}
}

// (a) a file that grows before it is read is sealed at its final size, not cut at the walk-time one.
func TestTornGroupedGrowthIsSealedWhole(t *testing.T) {
	p, info := writeGroupedFile(t, t.TempDir(), "prefs.xml", bytes.Repeat([]byte("x"), 100))
	hookFor(t, p, 1, func(int) { appendTo(t, p, []byte("-grown")) })
	ents := readGroupedTar(t, sealGrouped(t, []walkEnt{{p, "prefs.xml", info}}))
	final, _ := os.ReadFile(p)
	if len(ents) != 1 {
		t.Fatalf("%d entries, want 1", len(ents))
	}
	wantGroupedEntry(t, ents[0], final)
}

// (b) a file that shrinks before it is read is sealed as the short content, with no NUL tail.
func TestTornGroupedShrinkIsNotZeroPadded(t *testing.T) {
	p, info := writeGroupedFile(t, t.TempDir(), "wal.db", bytes.Repeat([]byte("y"), 300))
	hookFor(t, p, 1, func(int) {
		if err := os.WriteFile(p, []byte("short"), 0o600); err != nil {
			t.Errorf("rewrite: %v", err)
		}
	})
	ents := readGroupedTar(t, sealGrouped(t, []walkEnt{{p, "wal.db", info}}))
	if len(ents) != 1 {
		t.Fatalf("%d entries, want 1", len(ents))
	}
	wantGroupedEntry(t, ents[0], []byte("short"))
}

// (c) a change between the read and its fstat is read once more.
func TestTornGroupedAChangeDuringTheReadIsReadOnceMore(t *testing.T) {
	p, info := writeGroupedFile(t, t.TempDir(), "a.txt", bytes.Repeat([]byte("z"), 64))
	calls := hookGrouped(t, p, func(call int) {
		if call == 1 {
			appendTo(t, p, []byte("+tail"))
		}
	})
	ents := readGroupedTar(t, sealGrouped(t, []walkEnt{{p, "a.txt", info}}))
	final, _ := os.ReadFile(p)
	wantGroupedEntry(t, ents[0], final)
	if *calls != 2 {
		t.Fatalf("read %d time(s), want 2", *calls)
	}
}

// (d) a file that keeps changing is read at most twice and the tar stays consistent.
func TestTornGroupedItIsReadAtMostTwice(t *testing.T) {
	p, info := writeGroupedFile(t, t.TempDir(), "busy.log", bytes.Repeat([]byte("q"), 64))
	calls := hookGrouped(t, p, func(call int) {
		if call > 2 {
			t.Fatalf("read a third time")
		}
		appendTo(t, p, []byte("+more"))
	})
	ents := readGroupedTar(t, sealGrouped(t, []walkEnt{{p, "busy.log", info}}))
	if len(ents) != 1 || ents[0].hdr.Size != int64(len(ents[0].data)) {
		t.Fatalf("inconsistent entry: %+v", ents)
	}
	if *calls != 2 {
		t.Fatalf("read %d time(s), want 2", *calls)
	}
}

// (e) an unchanged group is byte-identical to writeTarEntry's output: no tarEntryFormat bump is needed.
func TestTornGroupedAnUnchangedGroupIsByteIdentical(t *testing.T) {
	dir := t.TempDir()
	var ents []walkEnt
	add := func(rel string, info os.FileInfo, err error) {
		if err != nil {
			t.Fatal(err)
		}
		ents = append(ents, walkEnt{filepath.Join(dir, rel), rel, info})
	}
	if err := os.Mkdir(filepath.Join(dir, "d"), 0o700); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Lstat(filepath.Join(dir, "d"))
	add("d", fi, err)
	if err := os.Symlink("d", filepath.Join(dir, "lnk")); err != nil {
		t.Fatal(err)
	}
	fi, err = os.Lstat(filepath.Join(dir, "lnk"))
	add("lnk", fi, err)
	for rel, b := range map[string][]byte{"empty": nil, "s1": []byte("one"), "s2": bytes.Repeat([]byte("two"), 300), "s3": prBytes(5000)} {
		_, fi := writeGroupedFile(t, dir, rel, b)
		add(rel, fi, nil)
	}
	got := sealGrouped(t, ents)
	var want bytes.Buffer
	tw := tar.NewWriter(&want)
	for _, e := range ents {
		if err := writeTarEntry(tw, e.path, e.info, e.rel); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Flush(); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want.Bytes()) {
		t.Fatalf("grouped output differs from writeTarEntry's (%d vs %d bytes)", len(got), want.Len())
	}
}

// (f) a tear in one file leaves its neighbours' entries untouched and the stream extractable.
func TestTornGroupedNeighboursAreUntouched(t *testing.T) {
	dir := t.TempDir()
	var ents []walkEnt
	for _, rel := range []string{"a1", "b2", "c3"} {
		p, info := writeGroupedFile(t, dir, rel, []byte("content of "+rel))
		ents = append(ents, walkEnt{p, rel, info})
	}
	base := readGroupedTar(t, sealGrouped(t, ents))
	hookFor(t, ents[1].path, 1, func(int) { appendTo(t, ents[1].path, []byte(" grown")) })
	stream := sealGrouped(t, ents)
	got := readGroupedTar(t, stream)
	if len(got) != 3 {
		t.Fatalf("%d entries, want 3", len(got))
	}
	for _, i := range []int{0, 2} {
		if !bytes.Equal(got[i].data, base[i].data) || !reflect.DeepEqual(got[i].hdr, base[i].hdr) {
			t.Fatalf("neighbour %q changed", got[i].name)
		}
	}
	wantGroupedEntry(t, got[1], []byte("content of b2 grown"))
	dst := t.TempDir()
	if n := untarFrom(dst, bytes.NewReader(stream)); n != 0 {
		t.Fatalf("untarFrom skipped %d entries", n)
	}
	for rel, want := range map[string]string{"a1": "content of a1", "b2": "content of b2 grown", "c3": "content of c3"} {
		wantFile(t, dst, rel, []byte(want))
	}
}
