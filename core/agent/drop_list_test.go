package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The drop list decides what does NOT get sealed, so every one of these is a data-loss guard, not a nicety.

func TestLoadDropListIgnoresPathsAndBlanks(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "drop")
	// A producer that wrote PATHS instead of package names must not be honoured: matching "a/b" as a name
	// could otherwise skip an unrelated subtree.
	if err := os.WriteFile(p, []byte("com.example.a\n\n  com.example.b  \nevil/../../etc\nC:\\win\\path\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", p)
	m := loadDropList()
	if !m["com.example.a"] || !m["com.example.b"] {
		t.Errorf("plain package names must load, got %v", m)
	}
	if len(m) != 2 {
		t.Errorf("path-shaped entries must be ignored, got %v", m)
	}
}

// No env var, a missing file, or an empty one must all mean "drop nothing" -- i.e. byte-for-byte the
// behaviour before this feature existed. Anything else would silently change what every seal captures.
func TestLoadDropListInertByDefault(t *testing.T) {
	t.Setenv("NOWHERE_DROP_LIST", "")
	if m := loadDropList(); m != nil {
		t.Errorf("unset -> nil, got %v", m)
	}
	t.Setenv("NOWHERE_DROP_LIST", filepath.Join(t.TempDir(), "nope"))
	if m := loadDropList(); m != nil {
		t.Errorf("missing file -> nil, got %v", m)
	}
	empty := filepath.Join(t.TempDir(), "empty")
	if err := os.WriteFile(empty, []byte("\n\n  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", empty)
	if m := loadDropList(); m != nil {
		t.Errorf("blank file -> nil, got %v", m)
	}
}

// The keep-set wins over the drop list, always. The drop list is a logoff artifact that seals and roams, so
// a stale one must never be able to drop an app the user has since switched back On -- roamd clears it at
// roam-in, and this makes the dangerous direction unreachable if that reset ever fails.
func TestLoadDropListNeverDropsAKeptPackage(t *testing.T) {
	d := t.TempDir()
	drop := filepath.Join(d, "drop")
	keep := filepath.Join(d, "keep")
	if err := os.WriteFile(drop, []byte("com.example.stale\ncom.example.gone\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// com.example.stale is kept again (bare line = installed); the group row shape must parse too.
	if err := os.WriteFile(keep, []byte("com.example.stale\ncom.other\tondemand\tgroup:sandboxed-play\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", drop)
	t.Setenv("NOWHERE_KEEP_LIST", keep)

	m := loadDropList()
	if m["com.example.stale"] {
		t.Error("a package in the keep-set must never be dropped")
	}
	if !m["com.example.gone"] {
		t.Error("a genuinely switched-off package must still drop")
	}

	// If every entry is rescued, the result is nil -- i.e. the seal drops nothing at all.
	if err := os.WriteFile(drop, []byte("com.example.stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if m := loadDropList(); m != nil {
		t.Errorf("a fully-rescued list must be inert, got %v", m)
	}

	// A missing/unreadable keep-set must not silently disable the rescue AND must not crash; the drop list
	// still applies (roamd only exports the pair together).
	t.Setenv("NOWHERE_KEEP_LIST", filepath.Join(d, "nope"))
	if m := loadDropList(); !m["com.example.stale"] {
		t.Error("with no keep-set readable the drop list still applies")
	}
}

// Matching must be ANCHORED to the four shapes a package's data actually takes. The negative cases are the
// point: a same-named directory at any other depth is somebody's real data and must survive.
func TestDropPkgForRelMatchesOnlyRealAppDataDirs(t *testing.T) {
	drop := map[string]bool{"com.example.a": true}
	hold := chooserPkg + "/" + odHoldDirName + "/com.example.a"

	for _, rel := range []string{
		"com.example.a",              // CE / DE canonical dir
		"Android/data/com.example.a", // external app-private data
		"Android/obb/com.example.a",  // expansion files
		hold,                         // roamd's login-time hold
	} {
		if !dropPkgForRel(rel, drop) {
			t.Errorf("must drop %q", rel)
		}
	}

	for _, rel := range []string{
		"com.example.b",                    // a different app
		"Android/data/com.example.b",       //
		"Pictures/com.example.a",           // a user folder that merely shares the name
		"com.example.a/files/x",            // a FILE inside the dropped dir: the dir match SkipDirs it
		"Android/data/com.example.a/cache", // ditto, one level deeper
		"Android/other/com.example.a",      // not one of the external app-private prefixes
		// Android/media is app-CREATED but USER-FACING: MediaStore-indexed shared content (WhatsApp's Media
		// tree). Switching an app off means "stop carrying the app", not "delete my photos".
		"Android/media/com.example.a",
		"deep/nest/Android/data/com.example.a", // the Android prefix must be at the scope ROOT
		chooserPkg + "/files/com.example.a",    // chooser dir, but not the hold
		"",                                     // degenerate
		// A backslash is a legal FILENAME character on Android, and the seal only ever produces '/'-separated
		// rels. So this is a single directory whose name happens to contain backslashes -- somebody's real
		// data. Treating it as a path would be the bug, not the fix.
		"Android\\data\\com.example.a",
	} {
		if dropPkgForRel(rel, drop) {
			t.Errorf("must NOT drop %q -- that is real data", rel)
		}
	}

	// An empty drop set never matches anything, whatever the shape.
	if dropPkgForRel("com.example.a", nil) || dropPkgForRel("com.example.a", map[string]bool{}) {
		t.Error("an empty drop set must match nothing")
	}
}

// The FILE variant backs the deferred carry-forward. It must match things UNDER a dropped app's dir and
// nothing else -- if it were as loose as a prefix check it would drop unrelated deferred media.
func TestDropPkgForFileRelMatchesOnlyFilesUnderDroppedDirs(t *testing.T) {
	drop := map[string]bool{"com.example.a": true}
	for _, rel := range []string{
		"com.example.a/files/big.dat",
		"Android/data/com.example.a/files/x",
		"Android/obb/com.example.a/main.obb",
		chooserPkg + "/" + odHoldDirName + "/com.example.a/files/y",
	} {
		if !dropPkgForFileRel(rel, drop) {
			t.Errorf("must drop file %q", rel)
		}
	}
	for _, rel := range []string{
		"com.example.a",                       // the dir itself is the OTHER function's job
		"com.example.b/files/x",               // different app
		"Android/media/com.example.a/pic.jpg", // user-facing shared media -- never dropped
		"Pictures/com.example.a/pic.jpg",      // a user folder that shares the name
		chooserPkg + "/files/com.example.a/z", // chooser dir, not the hold
		"Android/data",                        // too shallow
	} {
		if dropPkgForFileRel(rel, drop) {
			t.Errorf("must NOT drop file %q -- that is real data", rel)
		}
	}
	if dropPkgForFileRel("com.example.a/f", nil) {
		t.Error("an empty drop set must match nothing")
	}
}

// /data/app entries are "<pkg>-<random>", and the random half routinely contains hyphens
// ("com.google.android.youtube-V5zXet2iOz-zOmB2dyi7uw=="). Splitting on the FIRST hyphen is what makes the
// attribution correct, and it is only safe because an Android package name is dot-separated Java identifiers
// and can never contain one. A last-hyphen split would have produced "com.google.android.youtube-V5zXet2iOz".
func TestAppDirPackageAttribution(t *testing.T) {
	for _, c := range []struct{ dir, want string }{
		{"com.google.android.youtube-V5zXet2iOz-zOmB2dyi7uw==", "com.google.android.youtube"},
		{"com.ringapp-QQYsmfSpo2DR1nqc6t-QiQ==", "com.ringapp"},
		{"com.example.a-abc==", "com.example.a"},
		{"com.example.nohyphen", "com.example.nohyphen"}, // defensive: no suffix at all
	} {
		got := c.dir
		if i := strings.IndexByte(got, '-'); i > 0 {
			got = got[:i]
		}
		if got != c.want {
			t.Errorf("%q -> %q, want %q", c.dir, got, c.want)
		}
	}
}

// End-to-end through the real walk: a dropped app's tree contributes no chunks and is reported, while a kept
// app's identical tree is sealed untouched.
func TestWalkChunksSkipsDroppedPackages(t *testing.T) {
	src := t.TempDir()
	iwrite(t, src, "com.example.keep/files/a.bin", make([]byte, 2048))
	iwrite(t, src, "com.example.drop/files/b.bin", make([]byte, 2048))
	iwrite(t, src, "Android/obb/com.example.drop/big.obb", make([]byte, 4096))

	list := filepath.Join(t.TempDir(), "drop")
	if err := os.WriteFile(list, []byte("com.example.drop\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", list)

	var tarred []byte
	sc := newFileScanCache(make([]byte, 32))
	_, seen, _, _, blind, dropped, _, _ := walkChunks(src, sc, 1<<20, true, ondemandMedia(), nil, nil, nil, nil, 0,
		func(c []byte) int { tarred = append(tarred, c...); return 0 },
		func(string) int { return 0 }, func(int64) {}, nil)

	if dropped <= 0 {
		t.Errorf("dropped = %d bytes, want > 0 (the CE dir and the obb dir)", dropped)
	}
	if blind != 0 {
		t.Errorf("a deliberate drop must not register as blind, got %d", blind)
	}
	for rel := range seen {
		if filepath.ToSlash(rel) == "com.example.drop/files/b.bin" {
			t.Error("a dropped app's file was walked")
		}
	}
	// The kept app's bytes must still be in the stream, the dropped app's must not.
	if !bytesContains(tarred, []byte("com.example.keep")) {
		t.Error("the kept app is missing from the seal")
	}
	if bytesContains(tarred, []byte("com.example.drop")) {
		t.Error("a switched-off app's data was sealed anyway")
	}
}

func bytesContains(hay, needle []byte) bool {
	if len(needle) == 0 || len(hay) < len(needle) {
		return len(needle) == 0
	}
	for i := 0; i+len(needle) <= len(hay); i++ {
		match := true
		for j := range needle {
			if hay[i+j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
