package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261119-18: the Q106 user-media classifier and the essential share the #media restore logs.

func TestMediaUserShareClassifier(t *testing.T) {
	cases := []struct {
		rel  string
		want bool
	}{
		{"DCIM/a.jpg", true},
		{"DCIM/Camera/2026/b.jpg", true},
		{"Pictures/x.png", true},
		{"Movies/m.mp4", true},
		{"Music/s.flac", true},
		{"Download/f.pdf", true},
		{"Download/sub/f", true},
		{"Android/media/com.whatsapp/WhatsApp/Media/a.jpg", true},
		{"Android/media/x/il2cpp/y", true}, // Q106's list wins over a path segment
		{"DCIMX/a", false},
		{"dcim/a", false},
		{"Downloads/a", false},
		{"Download2/a", false},
		{"Android/mediafoo/x", false},
		{"Android/media", false}, // a directory entry, never a file in Ess
		{"Android/data/x", false},
		{"Android/obb/x", false},
		{"Android/data/com.game/files/il2cpp/Metadata/global-metadata.dat", false},
		{"Documents/a", false},
		{"Alarms/a", false},
		{"a/DCIM/b", false},
		{"", false},
	}
	for _, c := range cases {
		if got := isUserMediaRel(c.rel); got != c.want {
			t.Errorf("isUserMediaRel(%q) = %v, want %v", c.rel, got, c.want)
		}
	}
}

func TestMediaUserShareCountsEssentialBySize(t *testing.T) {
	m := chunkManifest{
		Chunks: []string{"c0", "c1", "c2", "c3", "c4", "c5", "c6"},
		Ess: map[string]essRegion{
			"DCIM/Camera/a.jpg":                 {S: 0, E: 1, Size: 1000},
			"Download/f.pdf":                    {S: 1, E: 2, Size: 200},
			"Android/media/com.app/Media/v.mp4": {S: 2, E: 3, Size: 30},
			"DCIMX/b":                           {S: 3, E: 4, Size: 4},
			"Android/data/com.game/files/x":     {S: 4, E: 5, Size: 50000},
			"Android/obb/com.game/main.obb":     {S: 5, E: 6, Size: 600000},
			"Documents/n.txt":                   {S: 6, E: 7, Size: 7},
		},
		Deferred: map[string]deferredFile{
			"DCIM/Camera/big.mp4": {Size: 9_000_000_000},
		},
	}
	uf, ub, of, ob, idx := mediaUserShare(m)
	if !idx {
		t.Fatalf("indexed = false for a manifest with an Ess index")
	}
	if uf != 3 || ub != 1230 {
		t.Errorf("user media = %d file(s) %d B, want 3 file(s) 1230 B (deferred entries are not counted)", uf, ub)
	}
	if of != 4 || ob != 650011 {
		t.Errorf("other = %d file(s) %d B, want 4 file(s) 650011 B", of, ob)
	}
}

func TestMediaUserShareNoIndex(t *testing.T) {
	const want = "restore: #media essential: no per-file index in this head (Q106 share not measured)"
	for name, m := range map[string]chunkManifest{
		"empty":         {},
		"chunks+defers": {Chunks: []string{"c0"}, Deferred: map[string]deferredFile{"DCIM/a.jpg": {Size: 5}}},
	} {
		uf, ub, of, ob, idx := mediaUserShare(m)
		if idx || uf != 0 || ub != 0 || of != 0 || ob != 0 {
			t.Errorf("%s: mediaUserShare = %d %d %d %d %v, want 0 0 0 0 false", name, uf, ub, of, ob, idx)
		}
		if got := mediaUserShareLine(m); got != want {
			t.Errorf("%s: line = %q, want %q", name, got, want)
		}
	}
}

func TestMediaUserShareLineCarriesNoRelOrName(t *testing.T) {
	m := chunkManifest{
		Chunks: []string{"c0", "c1", "c2"},
		Ess: map[string]essRegion{
			"DCIM/odsecretrel.jpg":       {S: 0, E: 1, Size: 10},
			"Download/odsecretrel2.pdf":  {S: 1, E: 2, Size: 20},
			"Android/data/odsecretpkg/x": {S: 2, E: 3, Size: 5},
		},
	}
	got := mediaUserShareLine(m)
	const want = "restore: #media essential: 2 user-media file(s) 30 B (DCIM, Pictures, Movies, Music, Download, Android/media), 1 other file(s) 5 B (Q106)"
	if got != want {
		t.Errorf("line = %q, want %q", got, want)
	}
	for _, leak := range []string{"odsecret", ".jpg", ".pdf", "Android/data"} {
		if strings.Contains(got, leak) {
			t.Errorf("line %q leaks %q", got, leak)
		}
	}
}

func TestMediaUserShareRestoreCallsItOnceUnderTheMediaScope(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if n := strings.Count(src, "mediaUserShareLine("); n != 1 {
		t.Fatalf("main.go calls mediaUserShareLine %d time(s), want exactly 1", n)
	}
	start := strings.Index(src, "if bytes.HasPrefix(pt, cdcMagic) {\n\t\t\tvar m chunkManifest")
	if start < 0 {
		t.Fatal("the restore's CDC branch was not found in main.go")
	}
	end := strings.Index(src[start:], "skipped = untarFrom(dest, bytes.NewReader(pt))")
	if end < 0 {
		t.Fatal("the restore's legacy branch was not found after its CDC branch")
	}
	branch := src[start : start+end]
	const call = "if isSharedMediaScope(profile) {\n\t\t\t\tfmt.Println(mediaUserShareLine(m))\n\t\t\t}"
	if n := strings.Count(branch, call); n != 1 {
		t.Fatalf("the CDC restore branch holds the #media-scoped share call %d time(s), want exactly 1", n)
	}
	restoreLine := strings.LastIndex(branch, `fmt.Printf("restore: profile %s (%d chunks) -> %s`)
	if restoreLine < 0 {
		t.Fatal("the restore line was not found in the CDC branch")
	}
	if strings.Index(branch, call) < restoreLine {
		t.Error("the share line is logged before the restore line, want after it")
	}
}
