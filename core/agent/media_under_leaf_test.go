package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261011-74: the .under leaf was strings.ReplaceAll(rel, "/", "_"), so `Pictures/Screenshots` and a
// top-level `Pictures_Screenshots` shared one leaf; the second bind stacked on the first, one overlay served
// the other's files, and the seal recorded them under the wrong rels. underLeaf must give distinct rels
// distinct, slash-free leaves.
func TestUnderLeafIsInjective(t *testing.T) {
	if underLeaf("Pictures/Screenshots") == underLeaf("Pictures_Screenshots") {
		t.Fatalf("Pictures/Screenshots and Pictures_Screenshots share the leaf %q", underLeaf("Pictures_Screenshots"))
	}
	pairs := [][2]string{
		{"Pictures/Screenshots", "Pictures_Screenshots"},
		{"a_/b", "a/_b"},
		{"a_s", "a/"},
		{"_u", "_"},
		{"_s", "/"},
		{"a__b", "a_/b"},
		{"a//b", "a_s_sb"},
		{"x_h", "x/h"},
	}
	for _, p := range pairs {
		if a, b := underLeaf(p[0]), underLeaf(p[1]); a == b {
			t.Errorf("underLeaf(%q) == underLeaf(%q) == %q", p[0], p[1], a)
		}
	}
	// Every pair across a wider set, including the hashed form for over-long rels.
	long := strings.Repeat("_/", 100)
	rels := []string{"", "_", "/", "__", "//", "_/", "/_", "_u", "_s", "_h", "u", "s", "a/b/c", "a_b/c", "a/b_c", "a_b_c",
		"Android/data/app.organicmaps/files", "Android_data/app.organicmaps/files", long, long + "x", long[1:]}
	seen := map[string]string{}
	for _, r := range rels {
		l := underLeaf(r)
		if strings.Contains(l, "/") {
			t.Errorf("underLeaf(%q) = %q contains a /", r, l)
		}
		if prev, dup := seen[l]; dup {
			t.Errorf("underLeaf(%q) and underLeaf(%q) collide on %q", prev, r, l)
		}
		seen[l] = r
	}
	// Bytes other than `_` and `/` pass through, so ordinary leaves stay readable in /proc/mounts.
	if got := underLeaf("Android/data/net.peakgames.toonblast/files/ContentDownload"); got != "Android_sdata_snet.peakgames.toonblast_sfiles_sContentDownload" {
		t.Errorf("underLeaf spelling changed: %q", got)
	}
}

// Escaping lengthens a leaf, and a leaf over NAME_MAX makes mediad's MkdirAll and bind fail, so the dir is
// never overlaid. A rel dense in `_` and `/` must still produce a leaf of at most 255 bytes.
func TestUnderLeafFitsNameMax(t *testing.T) {
	for _, r := range []string{
		strings.Repeat("_/", 64),             // 128 bytes -> 256 escaped: just over
		strings.Repeat("_", 127) + "a",       // 128 bytes -> 255 escaped: just fits, stays escaped
		strings.Repeat("a_b/", 200),          // far over
		strings.Repeat("Pictures/", 40),      // no underscores, still over once escaped
		"Android/data/com.example/files/Big", // ordinary
	} {
		l := underLeaf(r)
		if len(l) > 255 {
			t.Errorf("underLeaf(%d-byte rel) is %d bytes, over NAME_MAX", len(r), len(l))
		}
		if strings.Contains(l, "/") {
			t.Errorf("underLeaf(%d-byte rel) contains a /", len(r))
		}
	}
	if l := underLeaf(strings.Repeat("_", 127) + "a"); l != strings.Repeat("_u", 127)+"a" {
		t.Errorf("a 255-byte escaped leaf was hashed: %q", l)
	}
	if l := underLeaf(strings.Repeat("_/", 64)); !strings.HasPrefix(l, "_h") || len(l) != 66 {
		t.Errorf("a 256-byte escaped leaf was not hashed: %q", l)
	}
}

// The hand-written leaves in media_seal_test.go's fixtures must be what underLeaf computes for their rels,
// or that test pins a spelling mediad never produces.
func TestUnderLeafPinsTheSealFixtures(t *testing.T) {
	for rel, leaf := range map[string]string{
		"Android/data/net.peakgames.toonblast/files/ContentDownload": "Android_sdata_snet.peakgames.toonblast_sfiles_sContentDownload",
		"com.nowhere.chooser/files/.appcode/com.google.android.gms":  "com.nowhere.chooser_sfiles_s.appcode_scom.google.android.gms",
		"Android/data/com.example.orphan/files/Big":                  "Android_sdata_scom.example.orphan_sfiles_sBig",
	} {
		if got := underLeaf(rel); got != leaf {
			t.Errorf("underLeaf(%q) = %q, fixture says %q", rel, got, leaf)
		}
	}
}

// The bind (mediafs.go) and the seal's lookup (media_seal.go) must spell the leaf the same way; that they
// did not have to was half the bug. Both must call underLeaf and neither may carry the old mangling.
func TestUnderLeafIsTheOnlyLeafSpelling(t *testing.T) {
	for file, want := range map[string]string{
		"mediafs.go":    "hidden := filepath.Join(hideBase, underLeaf(dir))",
		"media_seal.go": "leaf := underLeaf(rel)",
	} {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		if !strings.Contains(src, want) {
			t.Errorf("%s no longer builds the .under leaf with underLeaf (want %q)", file, want)
		}
		for _, old := range []string{`ReplaceAll(dir, "/", "_")`, `ReplaceAll(rel, "/", "_")`} {
			if strings.Contains(src, old) {
				t.Errorf("%s still carries the non-injective mangling %s", file, old)
			}
		}
	}
}
