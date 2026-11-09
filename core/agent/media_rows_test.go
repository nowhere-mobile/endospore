package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMediaRowsFilter(t *testing.T) {
	for rel, want := range map[string]bool{
		"DCIM/a.jpg":                  true,
		"Android/media/com.x/M/a.jpg": true,
		"Android/data/com.x/f/a.jpg":  false,
		"android/OBB/com.x/a.jpg":     false,
		"DCIM/.hidden/a.jpg":          false,
		"DCIM/.a.jpg":                 false,
		"../x.jpg":                    false,
		"/x.jpg":                      false,
		"DCIM//a.jpg":                 false,
		"DCIM/\xff.jpg":               false,
		"":                            false,
	} {
		if got := mediaRowRel(rel); got != want {
			t.Errorf("mediaRowRel(%q) = %v, want %v", rel, got, want)
		}
	}
}

// mediaRowsWrite writes the list for deferred under a fresh state dir and returns its bytes.
func mediaRowsWrite(t *testing.T, deferred map[string]deferredFile, dest string) string {
	t.Helper()
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	writeMediaRowsList(deferred, dest)
	b, err := os.ReadFile(filepath.Join(st, mediaRowsFile))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestMediaRowsNomedia(t *testing.T) {
	dest := t.TempDir()
	for _, d := range []string{"Pictures/Hidden/Sub", "Pictures/Secret", "Pictures/Open"} {
		if err := os.MkdirAll(filepath.Join(dest, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"Pictures/Hidden/.nomedia", "Pictures/Secret/.nomedia"} {
		if err := os.WriteFile(filepath.Join(dest, f), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got := mediaRowsWrite(t, map[string]deferredFile{
		"Pictures/Hidden/Sub/a.jpg": {Size: 1}, // an ancestor holds it
		"Pictures/Secret/b.jpg":     {Size: 1}, // its own directory holds it
		"Pictures/Open/c.jpg":       {Size: 1},
		"Pictures/Late/.nomedia":    {Size: 0}, // a deferred .nomedia hides its folder too
		"Pictures/Late/Sub/d.jpg":   {Size: 1},
	}, dest)
	if want := "1\x000\x00pictures/open\x00Pictures/Open/c.jpg\x00"; got != want {
		t.Fatalf("list = %q, want %q", got, want)
	}
}

func TestMediaRowsFormat(t *testing.T) {
	const secs = int64(1700000000)
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	writeMediaRowsList(map[string]deferredFile{
		"Movies/Ta\tb/n\nl.mp4": {Size: 7, MTime: secs},       // web import: seconds
		"DCIM/CAM/a.jpg":        {Size: 9, MTime: secs * 1e9}, // seal: nanoseconds
		"top.jpg":               {Size: 3},                    // no parent, no mtime
		"Android/data/p/a.jpg":  {Size: 1, MTime: secs},       // filtered
	}, t.TempDir())
	p := filepath.Join(st, mediaRowsFile)
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	want := "9\x001700000000\x00dcim/cam\x00DCIM/CAM/a.jpg\x00" +
		"7\x001700000000\x00movies/ta\tb\x00Movies/Ta\tb/n\nl.mp4\x00" +
		"3\x000\x00\x00top.jpg\x00"
	if string(b) != want {
		t.Fatalf("list = %q, want %q", b, want)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", fi.Mode().Perm())
	}
	if strings.Contains(string(b), "Android") {
		t.Fatal("an app-private entry reached the list")
	}
}

func TestMediaRowsEmptyListIsWritten(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	p := filepath.Join(st, mediaRowsFile)
	if err := os.WriteFile(p, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	writeMediaRowsList(nil, t.TempDir())
	if b, err := os.ReadFile(p); err != nil || len(b) != 0 {
		t.Fatalf("list after a restore with nothing deferred = %q, %v; want empty", b, err)
	}
}

func TestMediaRowsClear(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	p := filepath.Join(st, mediaRowsFile)
	if err := os.WriteFile(p, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_PHASE", "de")
	clearMediaRowsList()
	if _, err := os.Stat(p); err != nil {
		t.Fatal("another phase must leave the list alone")
	}
	t.Setenv("NOWHERE_PHASE", "media")
	clearMediaRowsList()
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatal("a #media restore must clear the stale list before it begins")
	}
}

func TestJavaLowerRoot(t *testing.T) {
	for in, want := range map[string]string{
		"Pictures/İstanbul": "pictures/i̇stanbul",
		"ΣΑΣ/ΣΑΣ":           "σας/σας",
		"Σ":                 "σ",
		"AΣ.B":              "aσ.b",
		"КАМЕРА":            "камера",
		"🎬Clips":            "🎬clips",
	} {
		if got := javaLowerRoot(in); got != want {
			t.Errorf("javaLowerRoot(%q) = %q, want %q", in, got, want)
		}
	}
}

// The restore case's call sites: the list is cleared before anything can return, and it is written only for #media.
func TestMediaRowsRestoreCallSites(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	clear := "\t\tclearHealList(os.Getenv(\"NOWHERE_STATE\"), profile, pass)\n\t\tclearMediaRowsList()\n"
	if strings.Count(src, clear) != 1 {
		t.Fatal("clearMediaRowsList must directly follow clearHealList in the restore case, once")
	}
	write := "\t\t\tif isSharedMediaScope(profile) {\n\t\t\t\twriteMediaRowsList(m.Deferred, dest) // NWP-20261130-02"
	if strings.Count(src, write) != 1 {
		t.Fatal("writeMediaRowsList must run once, under the #media scope")
	}
}
