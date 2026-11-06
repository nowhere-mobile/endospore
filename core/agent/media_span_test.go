package main

// NWP-20260908-21: THE ASSUMPTION THE WHOLE MID-SESSION SYNC RESTS ON.
//
// chunkManifest.Ess maps a rel to a half-open span of Chunks. The carry re-emits that span BY HASH without
// ever holding the bytes, which is all it needs. Materializing is the opposite: fetch exactly those chunks,
// concatenate them, and read ONE file out. That only works if a span is a self-contained tar fragment --
// starts on a header boundary, ends after that entry's padding.
//
// It should hold, because the Ess index is only written under the essential-index flags and those force
// sealFileThreshold() to 0, i.e. per-file alignment. But "should" is how this area keeps going wrong, and if
// it does not hold the whole design changes: we would need the surrounding chunks too, and the span index
// would be decoration. So it is pinned here before anything is built on it.

import (
	"archive/tar"
	"bytes"
	"io"
	"path/filepath"
	"testing"
)

func TestEssSpan_IsASelfContainedTarFragment(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())

	a, _ := twoWriters(t, "essspan", "correct horse battery staple")
	want := map[string]string{
		"DCIM/Camera/one.jpg": "the first photo, small enough to ride the essential tar",
		"DCIM/Camera/two.jpg": "the second, deliberately a different length so a span mix-up is visible",
		"Pictures/three.png":  "a third, in another directory",
	}
	for rel, body := range want {
		a.put(rel, body)
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}

	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if len(m.Ess) == 0 {
		t.Fatal("the head carries no per-file index -- this fixture proves nothing")
	}
	key := resolveDK(a.base, a.name+"#media", a.pass, nil)

	for rel, body := range want {
		r, ok := m.Ess[rel]
		if !ok {
			t.Errorf("%s is not in the Ess index at all; index=%v", rel, keysOfEss(m.Ess))
			continue
		}
		frag, err := fetchEssSpan(a.base, key, m, r)
		if err != nil {
			t.Errorf("fetch the span for %s: %v", rel, err)
			continue
		}
		// Read it as a tar. One entry, the right name, the right bytes, and then the end.
		tr := tar.NewReader(bytes.NewReader(frag))
		hdr, err := tr.Next()
		if err != nil {
			t.Errorf("the span for %s does not begin with a tar header (%v). If this fails, an Ess span is NOT "+
				"self-contained and the materialize design has to fetch surrounding chunks too.", rel, err)
			continue
		}
		if filepath.ToSlash(hdr.Name) != rel {
			t.Errorf("the span for %s holds %q -- the index points at the wrong bytes", rel, hdr.Name)
			continue
		}
		got, _ := io.ReadAll(tr)
		if string(got) != body {
			t.Errorf("%s: span content = %q, want %q", rel, string(got), body)
		}
		if _, err := tr.Next(); err != io.EOF && err != io.ErrUnexpectedEOF {
			t.Errorf("%s: the span carries MORE than this one file (next entry err=%v). A span that spills into "+
				"its neighbour would materialize files the user did not ask for.", rel, err)
		}
	}
}
