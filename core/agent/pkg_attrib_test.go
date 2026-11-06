package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The path shapes attribution must and must NOT recognise. The negative cases are the point: pinnedApp's
// fallback treats ANY first path component as a package, which in the #media scope invents apps out of the
// user's own folders (DIA-20260805-11).
func TestAttrPkgForRel(t *testing.T) {
	cases := []struct{ rel, want string }{
		{"com.example.app/databases/x.db", "com.example.app"},                        // CE / DE scope root
		{"com.example.app/files/blob.bin", "com.example.app"},                        // #apps stage shape
		{"Android/data/com.example.app/cache/x", "com.example.app"},                  // external app-private
		{"Android/obb/com.example.app/main.obb", "com.example.app"},                  // external obb
		{"Android/media/com.example.app/pics/a.jpg", "com.example.app"},              // billed, so attributed (not dropped)
		{chooserPkg + "/" + odHoldDirName + "/com.example.app/f", "com.example.app"}, // the login hold
		{"DCIM/Camera/VID_0001.mp4", ""},                                             // user folder, NOT an app
		{"Download/big.iso", ""},
		{"Pictures/Screenshots/a.png", ""},
		{"Android/media", ""},         // too shallow to name a package
		{"loose-file.txt", ""},        // no directory at all
		{chooserPkg + "/files/x", ""}, // the chooser's own data is not an app's plan cost
	}
	for _, c := range cases {
		if got := attrPkgForRel(c.rel); got != c.want {
			t.Errorf("attrPkgForRel(%q) = %q, want %q", c.rel, got, c.want)
		}
	}
}

// The emit-index -> essential-index translation, and the pro-rata split. Without the translation every
// large file is misattributed as soon as anything in the scope defers.
func TestAttributePkgBytesTranslatesAndSplits(t *testing.T) {
	// emit indices 0..3; index 1 DEFERRED -> sizes[] holds only the other three.
	essIdx := []int{0, -1, 1, 2}
	sizes := []int64{100, 200, 700}

	a := newPkgAcct()
	a.own(0, "com.a") // -> sizes[0] = 100
	a.own(1, "com.a") // deferred: priced from Deferred[rel].Sz, must contribute 0 here
	a.own(2, "com.b") // -> sizes[1] = 200
	a.groups = append(a.groups, groupSpan{start: 3, end: 4, weights: map[string]int64{
		"com.a": 3, "com.b": 1, // span sizes[2] = 700 -> 525 / 175
	}})

	got := attributePkgBytes(a, essIdx, sizes)
	if got["com.a"] != 100+525 {
		t.Errorf("com.a = %d, want %d (100 own + 525 pro rata)", got["com.a"], 100+525)
	}
	if got["com.b"] != 200+175 {
		t.Errorf("com.b = %d, want %d (200 own + 175 pro rata)", got["com.b"], 200+175)
	}
	// The parts of a group must never exceed its span -- the remainder is shown as unattributed, and an app
	// row that over-claims would promise savings the plan cannot deliver.
	var total int64
	for _, v := range got {
		total += v
	}
	if want := sizes[0] + sizes[1] + sizes[2]; total > want {
		t.Errorf("attributed %d bytes, more than the %d sealed", total, want)
	}
}

// A group whose bytes are shared with unattributable content must not inflate the packages present: the
// weights only cover what an app owns, so the leftover stays unattributed.
func TestAttributePkgBytesLeavesRemainder(t *testing.T) {
	a := newPkgAcct()
	a.groups = append(a.groups, groupSpan{start: 0, end: 1, weights: map[string]int64{"com.a": 1}})
	got := attributePkgBytes(a, []int{0}, []int64{1000})
	if got["com.a"] != 1000 {
		t.Errorf("single-owner group: com.a = %d, want 1000", got["com.a"])
	}
	// nothing attributed at all -> nil, so the manifest omits the field and a reader can tell "not measured"
	// from "measured as zero".
	if attributePkgBytes(newPkgAcct(), []int{0}, []int64{1000}) != nil {
		t.Error("empty accumulator should produce a nil index, not an empty map")
	}
	if attributePkgBytes(nil, nil, nil) != nil {
		t.Error("nil accumulator should produce a nil index")
	}
}

// End to end through the real walk: a big file is attributed exactly, small files share a group pro rata,
// and the user's own folders are attributed to nobody.
func TestWalkChunksAttributesPackages(t *testing.T) {
	src := t.TempDir()
	write := func(rel string, n int) {
		p := filepath.Join(src, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, make([]byte, n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	const threshold = 4096
	write("com.big.app/files/blob.bin", 40*1024) // >= threshold -> file-aligned, exact
	write("com.small.a/prefs.xml", 600)          // < threshold -> grouped
	write("com.small.b/prefs.xml", 200)          // < threshold -> grouped
	write("DCIM/Camera/vid.mp4", 8*1024)         // large, but nobody's app data

	var sizes []int64
	emitSeal := func(c []byte) int { sizes = append(sizes, int64(len(c))); return len(sizes) - 1 }
	emitCached := func(string) int { return 0 }

	acct := newPkgAcct()
	sc := newFileScanCache([]byte("0123456789abcdef0123456789abcdef"))
	walkChunks(src, sc, threshold, true, ondemandMedia(), nil, nil, nil, nil, 0, emitSeal, emitCached, func(int64) {}, acct)

	essIdx := make([]int, len(sizes))
	for i := range essIdx {
		essIdx[i] = i // nothing deferred in this walk
	}
	got := attributePkgBytes(acct, essIdx, sizes)

	if got["com.big.app"] <= 0 {
		t.Fatalf("the file-aligned big file was not attributed: %v", got)
	}
	if got["com.small.a"] <= 0 || got["com.small.b"] <= 0 {
		t.Fatalf("grouped small files were not attributed: %v", got)
	}
	// 600 vs 200 bytes of plaintext -> a must come out ahead of b.
	if got["com.small.a"] <= got["com.small.b"] {
		t.Errorf("pro rata ignored the weights: a=%d b=%d", got["com.small.a"], got["com.small.b"])
	}
	if _, ok := got["DCIM"]; ok {
		t.Errorf("a user folder was attributed as an app: %v", got)
	}
	// Attribution can never exceed what was actually sealed.
	var total, sealed int64
	for _, v := range got {
		total += v
	}
	for _, s := range sizes {
		sealed += s
	}
	if total > sealed {
		t.Errorf("attributed %d > sealed %d", total, sealed)
	}
}
