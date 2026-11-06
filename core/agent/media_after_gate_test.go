package main

// NWP-20261123-07: bgSplit (Q106 slice S1, docs/media-after-gate.md §2 and §3).
//
// The sealed fixture goes through the real seal path, as TestEssSpan_IsASelfContainedTarFragment does, and reads
// the pre-gate chunk list back as the one stream cdcRestore would untar. The hand-built manifests pin what the
// seal cannot produce on demand: no index, bad spans, equal hashes at different indices, and overlapping regions.

import (
	"archive/tar"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// bgSplitEntry is one entry of a tar stream, as the login untar would see it.
type bgSplitEntry struct {
	name string
	flag byte
	body string
}

// bgSplitTarOf fetches, unseals and decompresses every chunk in order, concatenates them, and reads the result
// as one tar to its end: the stream cdcRestore feeds untarFrom. A cut inside an entry shows as a read error.
func bgSplitTarOf(t *testing.T, base string, key []byte, version int, chunks []string) []bgSplitEntry {
	t.Helper()
	var buf bytes.Buffer
	for i, h := range chunks {
		b, err := unpackChunk(unseal(key, getChunk(base, h)), version)
		if err != nil {
			t.Fatalf("decompress chunk %d: %v", i, err)
		}
		buf.Write(b)
	}
	var out []bgSplitEntry
	tr := tar.NewReader(&buf)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return out
		}
		if err != nil {
			t.Fatalf("the chunk list is not one valid tar after %d entries: %v", len(out), err)
		}
		data, err := io.ReadAll(tr)
		if err != nil {
			t.Fatalf("read entry %q: %v", hdr.Name, err)
		}
		if int64(len(data)) != hdr.Size {
			t.Fatalf("entry %q is short: %d of %d bytes", hdr.Name, len(data), hdr.Size)
		}
		name := strings.TrimSuffix(filepath.ToSlash(hdr.Name), "/")
		out = append(out, bgSplitEntry{name: name, flag: hdr.Typeflag, body: string(data)})
	}
}

func TestBgSplit_SealedFixture_PreGateUntarsToTheRest(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())

	a, _ := twoWriters(t, "bgsplitseal", "correct horse battery staple")
	// Every body is a few bytes, far under mediaUserMinBytes (1 MiB), so classifyDeferred keeps each in Ess.
	// Each has its own length, so a region mix-up is visible.
	bgWant := map[string]string{
		"DCIM/a.jpg":                      "a photo",
		"Pictures/x/b.png":                "a picture in a sub-folder",
		"Download/c.pdf":                  "a downloaded document, longer",
		"Android/media/com.example/d.mp4": "an app's media folder clip",
		"Music/e.mp3":                     "a song, of yet another length",
		"Movies/f.mkv":                    "a film",
	}
	preWant := map[string]string{
		"Documents/g.txt":                "not in Q106's list",
		"Alarms/h.ogg":                   "an alarm sound must be present first",
		"Android/data/com.example/i.bin": "app-private data",
		"Android/data/com.nowhere.chooser/.nowhere-odhold/com.example/j": "the on-demand hold",
		"DCIM/.nomedia":          "",
		"Pictures/k.db":          "a database in a user folder",
		"Download/x/databases/l": "a databases dir in a user folder",
		"Movies/m.so":            "a native library in a user folder!",
	}
	for rel, body := range bgWant {
		a.put(rel, body)
	}
	for rel, body := range preWant {
		a.put(rel, body)
	}
	if err := os.MkdirAll(filepath.Join(a.work, "Pictures", "empty"), 0o700); err != nil {
		t.Fatal(err)
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}

	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if !m.EssIdx {
		t.Fatal("the head carries no EssIdx -- this fixture proves nothing")
	}
	for _, set := range []map[string]string{bgWant, preWant} {
		for rel := range set {
			if _, ok := m.Ess[rel]; !ok {
				t.Fatalf("%s is not in the Ess index; index=%v", rel, keysOfEss(m.Ess))
			}
		}
	}

	bg, pre := bgSplit(m)
	wantBg := make([]string, 0, len(bgWant))
	for rel := range bgWant {
		wantBg = append(wantBg, rel)
	}
	slices.Sort(wantBg)
	if !reflect.DeepEqual(bg, wantBg) {
		t.Fatalf("bg = %v, want %v", bg, wantBg)
	}

	key := resolveDK(a.base, a.name+"#media", a.pass, nil)
	full := bgSplitTarOf(t, a.base, key, m.Version, m.Chunks)
	got := bgSplitTarOf(t, a.base, key, m.Version, pre)

	var want []bgSplitEntry
	for _, e := range full {
		if _, isBg := bgWant[e.name]; !isBg {
			want = append(want, e)
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("the pre-gate chunks untar to\n  %v\nwant every non-background entry of the head, in order:\n  %v", got, want)
	}

	// The comparison above is against the head's own stream; pin the fixture too, so a seal that dropped an
	// entry from both sides cannot pass.
	byName := map[string]bgSplitEntry{}
	dirs := 0
	for _, e := range got {
		byName[e.name] = e
		if e.flag == tar.TypeDir {
			dirs++
		}
	}
	if dirs == 0 {
		t.Error("no directory entry in the pre-gate stream: every directory must restore before the gate")
	}
	if e, ok := byName["Pictures/empty"]; !ok || e.flag != tar.TypeDir {
		t.Errorf("the empty directory Pictures/empty is not in the pre-gate stream (got %+v)", e)
	}
	for rel, body := range preWant {
		e, ok := byName[rel]
		if !ok {
			t.Errorf("pre-gate file %s is missing from the pre-gate stream", rel)
		} else if e.body != body {
			t.Errorf("%s: pre-gate body = %q, want %q", rel, e.body, body)
		}
	}
	for rel := range bgWant {
		if _, ok := byName[rel]; ok {
			t.Errorf("background file %s is still in the pre-gate stream", rel)
		}
	}

	// Each background rel still lands on its own from its region, which is what the later lander relies on.
	for _, rel := range bg {
		frag, err := fetchEssSpan(a.base, key, m, m.Ess[rel])
		if err != nil {
			t.Errorf("fetch the region of %s: %v", rel, err)
			continue
		}
		hdr, data, err := oneTarEntry(frag)
		if err != nil {
			t.Errorf("the region of %s: %v", rel, err)
			continue
		}
		if filepath.ToSlash(hdr.Name) != rel || string(data) != bgWant[rel] {
			t.Errorf("the region of %s holds %q = %q, want %q", rel, hdr.Name, data, bgWant[rel])
		}
	}
}

// bgSplitCheck runs bgSplit on a hand-built manifest and compares both results.
func bgSplitCheck(t *testing.T, m chunkManifest, wantBg, wantPre []string) {
	t.Helper()
	bg, pre := bgSplit(m)
	if len(bg) != 0 || len(wantBg) != 0 {
		if !reflect.DeepEqual(bg, wantBg) {
			t.Errorf("bg = %v, want %v", bg, wantBg)
		}
	}
	if !reflect.DeepEqual(pre, wantPre) {
		t.Errorf("preGate = %v, want %v", pre, wantPre)
	}
}

func TestBgSplit_NoIndexFlag_KeepsEverythingPreGate(t *testing.T) {
	// A non-empty Ess with a valid bg-shaped region: a head written before EssIdx restores fully inline.
	m := chunkManifest{
		Chunks: []string{"h0", "h1", "h2"},
		Ess:    map[string]essRegion{"DCIM/a.jpg": {S: 1, E: 2}},
	}
	bgSplitCheck(t, m, nil, []string{"h0", "h1", "h2"})
}

func TestBgSplit_EmptyIndex_KeepsEverythingPreGate(t *testing.T) {
	m := chunkManifest{EssIdx: true, Chunks: []string{"h0", "h1", "h2"}, Ess: map[string]essRegion{}}
	bgSplitCheck(t, m, nil, []string{"h0", "h1", "h2"})
}

func TestBgSplit_BadSpan_StaysPreGate(t *testing.T) {
	// Each bad span sits apart from the valid region, so only the bad-span check decides it.
	m := chunkManifest{
		EssIdx: true,
		Chunks: []string{"h0", "h1", "h2", "h3", "h4", "h5"},
		Ess: map[string]essRegion{
			"DCIM/n.jpg":  {S: -1, E: 1}, // negative S
			"DCIM/ok.jpg": {S: 1, E: 2},
			"DCIM/s.jpg":  {S: 3, E: 2}, // S >= E
			"DCIM/z.jpg":  {S: 3, E: 3}, // S == E
			"DCIM/e.jpg":  {S: 4, E: 7}, // E past the end
		},
	}
	bgSplitCheck(t, m, []string{"DCIM/ok.jpg"}, []string{"h0", "h2", "h3", "h4", "h5"})
}

func TestBgSplit_BadSpanOverlap_StaysPreGate(t *testing.T) {
	// RF-001: a bad span stays pre-gate, and a bg region inside its ends must not take a chunk it may hold.
	chunks := []string{"h0", "h1", "h2"}
	for _, bad := range []essRegion{{S: 1, E: 4}, {S: -1, E: 2}, {S: 2, E: 1}} {
		m := chunkManifest{EssIdx: true, Chunks: chunks, Ess: map[string]essRegion{
			"DCIM/a.jpg":      {S: 1, E: 2},
			"Documents/b.txt": bad,
		}}
		t.Logf("bad span %+v", bad)
		bgSplitCheck(t, m, nil, chunks)
	}
}

func TestBgSplit_IndexNotHash(t *testing.T) {
	// Two regions over equal chunk hashes at different indices: only the background copy's INDEX goes.
	m := chunkManifest{
		EssIdx: true,
		Chunks: []string{"h0", "hX", "h2", "hX"},
		Ess: map[string]essRegion{
			"DCIM/a.jpg":      {S: 1, E: 2},
			"Documents/b.txt": {S: 3, E: 4},
		},
	}
	bgSplitCheck(t, m, []string{"DCIM/a.jpg"}, []string{"h0", "h2", "hX"})
}

func TestBgSplit_Overlap_StaysPreGate(t *testing.T) {
	chunks := []string{"h0", "h1", "h2", "h3"}
	t.Run("two background regions", func(t *testing.T) {
		m := chunkManifest{EssIdx: true, Chunks: chunks, Ess: map[string]essRegion{
			"DCIM/a.jpg":     {S: 1, E: 3},
			"Pictures/b.png": {S: 2, E: 4},
		}}
		bgSplitCheck(t, m, nil, chunks)
	})
	t.Run("background over pre-gate", func(t *testing.T) {
		m := chunkManifest{EssIdx: true, Chunks: chunks, Ess: map[string]essRegion{
			"DCIM/a.jpg":      {S: 1, E: 3},
			"Documents/c.txt": {S: 2, E: 3},
		}}
		bgSplitCheck(t, m, nil, chunks)
	})
}

func TestBgSplit_Rules(t *testing.T) {
	m := chunkManifest{
		EssIdx: true,
		Chunks: []string{"h0", "h1", "h2", "h3", "h4", "h5", "h6"},
		Ess: map[string]essRegion{
			"DCIM/.nomedia":    {S: 0, E: 1},
			"Pictures/k.db":    {S: 1, E: 2},
			"Documents/g.txt":  {S: 2, E: 3},
			"Android/data/p/x": {S: 3, E: 4},
			"DCIMX/a.jpg":      {S: 4, E: 5},
			"Music/e.mp3":      {S: 5, E: 6},
		},
	}
	bgSplitCheck(t, m, []string{"Music/e.mp3"}, []string{"h0", "h1", "h2", "h3", "h4", "h6"})
}

func TestBgSplit_DoesNotTouchItsInput(t *testing.T) {
	m := chunkManifest{
		EssIdx: true,
		Chunks: []string{"h0", "h1", "h2"},
		Ess:    map[string]essRegion{"DCIM/a.jpg": {S: 0, E: 1}},
	}
	before := slices.Clone(m.Chunks)
	_, pre := bgSplit(m)
	if !reflect.DeepEqual(m.Chunks, before) {
		t.Fatalf("bgSplit changed m.Chunks: %v, was %v", m.Chunks, before)
	}
	if len(pre) > 0 && len(m.Chunks) > 0 && &pre[0] == &m.Chunks[0] {
		t.Fatal("preGate aliases m.Chunks")
	}
}
