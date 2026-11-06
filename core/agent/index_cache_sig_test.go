package main

import (
	"crypto/ed25519"
	"encoding/json"
	"os"
	"testing"
	"time"
)

// stampIndexCacheFile gives path its own mtime, so a test never relies on a write's coarse clock tick to change
// the stat indexCacheKey reads.
func stampIndexCacheFile(t *testing.T, path string, k int64) {
	t.Helper()
	ts := time.Unix(1_700_000_000+k, 0)
	if err := os.Chtimes(path, ts, ts); err != nil {
		t.Fatalf("chtimes %s: %v", path, err)
	}
}

func indexCacheServes(t *testing.T, step, pkg string, gen int64) {
	t.Helper()
	idx := getIndex()
	if len(idx) != 1 || idx[0].Pkg != pkg {
		got := []string{}
		for _, e := range idx {
			got = append(got, e.Pkg)
		}
		t.Fatalf("%s: getIndex serves %v, want [%s]", step, got, pkg)
	}
	if g := cachedGenerated(); g != gen {
		t.Fatalf("%s: cachedGenerated = %d, want %d", step, g, gen)
	}
}

// A getIndex between refreshIndex's two renames caches the baked fallback; the .sig rename that follows must bust
// that cache even when index.json keeps its stat (no Last-Modified stamp after the second rename).
func TestIndexCacheSeesTheSignatureLand(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 100, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	stampIndexCacheFile(t, indexSystemPath, 1)
	stampIndexCacheFile(t, indexSystemPath+".sig", 2)
	writeSignedIndex(t, indexDataPath, priv, catalog{Schema: 1, Generated: 200, Entries: []catalogEntry{idxEntry("c.d", "C", 1)}})
	stampIndexCacheFile(t, indexDataPath, 3)
	stampIndexCacheFile(t, indexDataPath+".sig", 4)
	indexCacheServes(t, "signed /data pair", "c.d", 200)

	// first rename: the gen-300 index lands beside the gen-200 signature
	b, err := json.Marshal(catalog{Schema: 1, Generated: 300, Entries: []catalogEntry{idxEntry("e.f", "E", 1)}})
	if err != nil {
		t.Fatal(err)
	}
	sig300 := ed25519.Sign(priv, b)
	if err := os.WriteFile(indexDataPath, b, 0o644); err != nil {
		t.Fatal(err)
	}
	stampIndexCacheFile(t, indexDataPath, 5)
	indexCacheServes(t, "between the two renames", "a.b", 100)

	before, err := os.Stat(indexDataPath)
	if err != nil {
		t.Fatal(err)
	}
	// second rename: only the signature changes
	if err := os.WriteFile(indexDataPath+".sig", sig300, 0o644); err != nil {
		t.Fatal(err)
	}
	stampIndexCacheFile(t, indexDataPath+".sig", 6)
	after, err := os.Stat(indexDataPath)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().Equal(before.ModTime()) || after.Size() != before.Size() {
		t.Fatalf("index.json stat changed across the .sig write: %v/%d -> %v/%d",
			before.ModTime(), before.Size(), after.ModTime(), after.Size())
	}
	indexCacheServes(t, "after the signature landed", "e.f", 300)
}

// indexCacheKey must change when any one of the four files loadIndexBytes reads is created, removed, resized or
// re-stamped, and must tell a missing file from a present one in each index/.sig pair.
func TestIndexCacheKeyNamesEachFile(t *testing.T) {
	_, _, restore := withIndexKey(t)
	defer restore()
	files := []string{indexSystemPath, indexSystemPath + ".sig", indexDataPath, indexDataPath + ".sig"}
	if k := indexCacheKey(); k != "" {
		t.Fatalf("key with none of the four files = %q, want \"\"", k)
	}
	k := int64(0)
	write := func(path, body string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		k++
		stampIndexCacheFile(t, path, k)
	}
	for _, f := range files {
		write(f, "xxxx")
	}
	for _, f := range files {
		prev := indexCacheKey()
		write(f, "xxxxxxxx") // another size
		if got := indexCacheKey(); got == prev {
			t.Fatalf("key unchanged after %s was resized", f)
		}
		prev = indexCacheKey()
		k++
		stampIndexCacheFile(t, f, k) // another mtime, same size
		if got := indexCacheKey(); got == prev {
			t.Fatalf("key unchanged after %s got another mtime", f)
		}
		prev = indexCacheKey()
		if err := os.Remove(f); err != nil {
			t.Fatal(err)
		}
		if got := indexCacheKey(); got == prev {
			t.Fatalf("key unchanged after %s was removed", f)
		}
		prev = indexCacheKey()
		write(f, "xxxx")
		if got := indexCacheKey(); got == prev {
			t.Fatalf("key unchanged after %s was created", f)
		}
	}

	// In each pair, "index present, .sig absent" and "index absent, .sig present" with the same mtime and size
	// must not render the same key.
	for _, pair := range [][2]string{{files[0], files[1]}, {files[2], files[3]}} {
		for _, f := range files {
			os.Remove(f)
		}
		write(pair[0], "yyyy")
		stampIndexCacheFile(t, pair[0], 99)
		onlyIndex := indexCacheKey()
		os.Remove(pair[0])
		write(pair[1], "yyyy")
		stampIndexCacheFile(t, pair[1], 99)
		if onlySig := indexCacheKey(); onlySig == onlyIndex {
			t.Fatalf("%s alone and %s alone render the same key %q", pair[0], pair[1], onlySig)
		}
	}
	for _, f := range files {
		os.Remove(f)
	}
	if k := indexCacheKey(); k != "" {
		t.Fatalf("key after removing all four files = %q, want \"\"", k)
	}
}
