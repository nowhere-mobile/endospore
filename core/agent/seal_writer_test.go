package main

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261201-12 (h62 #4): the push line that names what a seal found changed, by writer class and data kind. These
// tests run walkChunks with group_cache_test.go's fake store and refresh the caches as pushProfile does.

func TestSealWriterClass(t *testing.T) {
	const hold = "com.nowhere.chooser/.nowhere-odhold/"
	for _, c := range []struct{ rel, want string }{
		{"com.google.android.gms/files/a", "play"},
		{"com.google.android.gsf/databases/x", "play"},
		{"com.android.vending/files/a", "play"}, // named by the play set, ahead of the com.android. prefix
		{"Android/data/com.google.android.gms/files/a", "play"},
		{"com.nowhere.chooser/files/a", "nowhere"},
		{"com.nowhere.other/files/a", "nowhere"},
		{"android/databases/x", "platform"},
		{"com.android.providers.contacts/shared_prefs/p", "platform"},
		{"app.grapheneos.setupwizard/files/a", "platform"},
		{"org.lineageos.updater/files/a", "platform"},
		{hold + "com.example.held/files/h", "held"},
		{hold + "com.google.android.gms/files/h", "held"}, // a held Play package is still held
		{"Android/data/" + hold + "com.example.held/files/h", "held"},
		{"Android/obb/" + hold + "com.example.held/main.obb", "held"},
		{"com.example.app/databases/x", "app"},
		{"com.google.android.apps.maps/files/a", "app"},
		{"com.androidx.lookalike/files/a", "app"}, // not the com.android. prefix
		{"app.grapheneos/files/a", "app"},         // not the app.grapheneos. prefix
		{"Android/data/com.example.app/files/a", "app"},
		{"Android/obb/com.example.app/main.obb", "app"},
		{"Android/media/com.example.app/Media/a", "app"},
		{"Android/data/" + hold + "com.example.held", "app"}, // nothing under the package, so not held
		{hold + "com.example.held", "nowhere"},               // the same, and the chooser's own dir
		{"com.example.app", "app"},
		{"DCIM/Camera/a", "other"},
		{"androidx/files/a", "other"},
		{"Android", "other"},
		{"Android/data", "other"},
		{"", "other"},
	} {
		if got := sealWriterClass(c.rel); got != c.want {
			t.Errorf("sealWriterClass(%q) = %q, want %q", c.rel, got, c.want)
		}
	}
}

func TestSealWriterKind(t *testing.T) {
	const hold = "com.nowhere.chooser/.nowhere-odhold/"
	for _, c := range []struct{ rel, want string }{
		{"com.example.app/cache/a", "cache"},
		{"com.example.app/code_cache/a", "cache"},
		{"com.example.app/databases/x", "db"},
		{"com.example.app/shared_prefs/p", "prefs"},
		{"com.example.app/files/a", "files"},
		{"com.example.app/no_backup/a", "nobackup"},
		{"com.example.app/app_webview/a", "appdir"},
		{"com.example.app/lib/a", "other"},
		{"com.example.app", "other"},
		{"com.nowhere.chooser/files/a", "files"}, // attrPkgForRel returns "" for the chooser
		{"android/databases/x", "db"},
		{hold + "com.example.held/databases/x", "db"},
		{"Android/data/" + hold + "com.example.held/no_backup/a", "nobackup"},
		{"Android/obb/" + hold + "com.example.held/cache/a", "cache"},
		{"Android/data/" + hold + "com.example.held", "other"},
		{hold + "com.example.held", "other"},
		{"Android/data/com.example.app/cache/a", "cache"},
		{"Android/obb/com.example.app/files/a", "files"},
		{"Android/media/com.example.app/app_x/a", "appdir"},
		{"Android/media/com.example.app/files/a", "files"},
		{"Android/other/com.example.app/files/a", "other"},
		{"Download/files/a", "other"}, // a media folder has no package, so files/ is the user's folder
		{"DCIM/cache/a", "other"},
		{"Android", "other"},
		{"", "other"},
	} {
		if got := sealWriterKind(c.rel); got != c.want {
			t.Errorf("sealWriterKind(%q) = %q, want %q", c.rel, got, c.want)
		}
	}
}

// swSetOld sets every entry under src to the same old time.
func swSetOld(t *testing.T, src string, mt time.Time) {
	t.Helper()
	filepath.Walk(src, func(p string, _ os.FileInfo, err error) error {
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
		return nil
	})
}

// swChanged rewrites one file with the same length and gives it this mtime.
func swChanged(t *testing.T, p string, mt time.Time) {
	t.Helper()
	old, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(strings.ToUpper(string(old))), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
}

// The fixture's vault: one regular file for each of four classes.
var swFixture = []string{
	"com.google.android.gms/files/a",
	"com.example.app/databases/x",
	"com.android.providers.contacts/shared_prefs/p",
	"com.nowhere.chooser/.nowhere-odhold/com.example.held/files/h",
}

// swChangeOneWriter seals the fixture once, changes only its Play file, walks again with a baseline between the old
// mtimes and now, and returns the second walk's tally.
func swChangeOneWriter(t *testing.T) sealWriterTally {
	t.Helper()
	gcReset(t)
	dk := gcDK(t.Name())
	src := t.TempDir()
	for _, rel := range swFixture {
		iwrite(t, src, rel, []byte(strings.Repeat("old content of "+rel+"; ", 8)))
	}
	swSetOld(t, src, time.Now().Add(-48*time.Hour))
	store := map[string][]byte{}
	gcFirstWalk(t, src, dk, store)
	sc := newFileScanCache(dk)
	since := time.Now().Add(-time.Hour)
	sc.setSealWriterSince(since)
	swChanged(t, filepath.Join(src, swFixture[0]), since.Add(time.Minute))
	gcWalk(t, src, sc, store, false)
	return sc.sealWriterStats()
}

func TestSealWriterTallyNamesTheChangedWriter(t *testing.T) {
	got := sealWriterLine(swChangeOneWriter(t), false)
	const want = "groups play=1 platform=0 nowhere=0 held=0 app=0 other=0; " +
		"files play=1 platform=0 nowhere=0 held=0 app=0 other=0; " +
		"kinds cache=0 db=0 prefs=0 files=1 nobackup=0 appdir=0 other=0"
	if got != want {
		t.Fatalf("the line after one Play file changed:\n got  %s\n want %s", got, want)
	}
}

func TestSealWriterNoBaseline(t *testing.T) {
	gcReset(t)
	src := t.TempDir()
	iwrite(t, src, "com.example.app/files/a", []byte("first seal"))
	sc := newFileScanCache(gcDK(t.Name()))
	gcWalk(t, src, sc, map[string][]byte{}, false)
	stats := sc.sealWriterStats()
	if !stats.since.IsZero() {
		t.Fatalf("since = %v with no groupcache file, want zero", stats.since)
	}
	got := sealWriterLine(stats, false)
	const want = "groups play=0 platform=0 nowhere=0 held=0 app=1 other=0; files not counted (no baseline)"
	if got != want {
		t.Fatalf("the line with no baseline:\n got  %s\n want %s", got, want)
	}
	t.Setenv("NOWHERE_BLOBCACHE", "")
	if s := newFileScanCache(gcDK(t.Name())).sealWriterStats().since; !s.IsZero() {
		t.Fatalf("since = %v with NOWHERE_BLOBCACHE unset, want zero", s)
	}
}

func TestSealWriterForceFull(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := t.TempDir()
	iwrite(t, src, "com.example.app/files/a", []byte("forced"))
	swSetOld(t, src, time.Now().Add(-48*time.Hour))
	store := map[string][]byte{}
	gcFirstWalk(t, src, dk, store)
	sc := newFileScanCache(dk)
	sc.setSealWriterSince(time.Now().Add(-72 * time.Hour))
	gcWalk(t, src, sc, store, true)
	stats := sc.sealWriterStats()
	if n := stats.groups["app"]; n != 0 {
		t.Fatalf("a forced walk counted %d group miss(es), want 0: every group misses on that walk", n)
	}
	got := sealWriterLine(stats, true)
	const want = "groups not counted (full re-hash); files play=0 platform=0 nowhere=0 held=0 app=1 other=0; " +
		"kinds cache=0 db=0 prefs=0 files=1 nobackup=0 appdir=0 other=0"
	if got != want {
		t.Fatalf("the line on a forced walk:\n got  %s\n want %s", got, want)
	}
	if got, want := sealWriterLine(sealWriterTally{}, true), "groups not counted (full re-hash); files not counted (no baseline)"; got != want {
		t.Fatalf("the line on a forced walk with no baseline:\n got  %s\n want %s", got, want)
	}
}

func TestSealWriterLineNamesNoPackage(t *testing.T) {
	line := sealWriterLine(swChangeOneWriter(t), false)
	const classes = ` play=\d+ platform=\d+ nowhere=\d+ held=\d+ app=\d+ other=\d+`
	strict := regexp.MustCompile(`^groups` + classes + `; files` + classes +
		`; kinds cache=\d+ db=\d+ prefs=\d+ files=\d+ nobackup=\d+ appdir=\d+ other=\d+$`)
	if !strict.MatchString(line) {
		t.Fatalf("the line holds more than the fixed words and digits: %s", line)
	}
	names := map[string]bool{"com.example.held": true}
	for _, rel := range swFixture {
		parts := strings.Split(rel, "/")
		names[parts[0]] = true
		names[parts[len(parts)-1]] = true
	}
	for _, tok := range regexp.MustCompile(`[ ;=]+`).Split(line, -1) {
		if names[tok] {
			t.Errorf("the line names %q: %s", tok, line)
		}
	}
}

// The baseline is the time groupcache.<tag> carries when the cache loads, and a second walk on one cache starts its
// counters again but keeps that baseline.
func TestSealWriterBaselineIsTheGroupCacheTime(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := t.TempDir()
	iwrite(t, src, "com.example.app/files/a", []byte("baseline"))
	iwrite(t, src, "com.example.app/files/b", []byte("baseline too"))
	swSetOld(t, src, time.Now().Add(-48*time.Hour))
	store := map[string][]byte{}
	gcFirstWalk(t, src, dk, store)
	at := time.Now().Add(-72 * time.Hour).Truncate(time.Second)
	if err := os.Chtimes(groupCachePath(contentCacheTagFor(dk)), at, at); err != nil {
		t.Fatal(err)
	}
	sc := newFileScanCache(dk)
	if got := sc.sealWriterStats().since; !got.Equal(at) {
		t.Fatalf("since = %v, want the groupcache file's time %v", got, at)
	}
	gcWalk(t, src, sc, store, false)
	first := sc.sealWriterStats()
	if first.files["app"] != 2 || first.kinds["files"] != 2 {
		t.Fatalf("walk 1 counted files %v kinds %v, want 2 and 2", first.files, first.kinds)
	}
	gcWalk(t, src, sc, store, false)
	second := sc.sealWriterStats()
	if !second.since.Equal(at) {
		t.Fatalf("since after a second walk = %v, want %v", second.since, at)
	}
	if !reflect.DeepEqual(second.files, first.files) || !reflect.DeepEqual(second.kinds, first.kinds) {
		t.Fatalf("a second walk did not start its counters again: files %v kinds %v, walk 1 files %v kinds %v",
			second.files, second.kinds, first.files, first.kinds)
	}
}

func TestSealWriterLargeFileCounted(t *testing.T) {
	gcReset(t)
	dk := gcDK(t.Name())
	src := t.TempDir()
	rel := "com.example.app/files/big"
	iwrite(t, src, rel, []byte(strings.Repeat("large file; ", gcThreshold/8)))
	old := time.Now().Add(-48 * time.Hour)
	swSetOld(t, src, old)
	store := map[string][]byte{}
	gcFirstWalk(t, src, dk, store)

	since := old.Add(time.Hour)
	sc := newFileScanCache(dk)
	sc.setSealWriterSince(since)
	gcWalk(t, src, sc, store, false)
	stats := sc.sealWriterStats()
	if stats.files["app"] != 0 || stats.kinds["files"] != 0 {
		t.Fatalf("an unchanged large file was counted: files %v kinds %v", stats.files, stats.kinds)
	}

	swChanged(t, filepath.Join(src, rel), since.Add(time.Minute))
	sc = newFileScanCache(dk)
	sc.setSealWriterSince(since)
	gcWalk(t, src, sc, store, false)
	stats = sc.sealWriterStats()
	if stats.files["app"] != 1 || stats.kinds["files"] != 1 {
		t.Fatalf("a changed large file: files %v kinds %v, want app=1 and files=1", stats.files, stats.kinds)
	}
}
