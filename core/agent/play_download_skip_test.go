package main

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261102-01 (Q076): Play's download cache is never sealed; an old head's deferred records there are
// fetched at sign-in and leave the head only once the heal handled them, never dropped unfetched.

const (
	pdlDir   = playDownloadRel
	pdlOther = "com.android.vending/files/other/keep.bin"
)

func TestIsPlayDownloadPath(t *testing.T) {
	for _, c := range []struct {
		rel  string
		want bool
	}{
		{pdlDir, true},
		{pdlDir + "/1/blob", true},
		{"/" + pdlDir + "/1", true},
		{"/" + pdlDir, true},
		{pdlDir + "x", false},
		{pdlDir + "x/a", false},
		{"com.android.vending/files", false},
		{"com.android.vending/files/other", false},
		{"com.android.vending/cache/phonesky-download-service", false},
		{"other.app/files/phonesky-download-service", false},
	} {
		if got := isPlayDownloadPath(c.rel); got != c.want {
			t.Errorf("isPlayDownloadPath(%q) = %v, want %v", c.rel, got, c.want)
		}
	}
}

// pdlTree writes a synthetic scope root: two Play download files, a sibling Play file, an unrelated app file.
func pdlTree(t *testing.T) (src string, playBytes int64) {
	t.Helper()
	src = t.TempDir()
	for rel, n := range map[string]int{
		pdlDir + "/1/blob.apk": 9000,
		pdlDir + "/2/split":    300,
		pdlOther:               5000,
		"app.other/files/x":    6000,
	} {
		iwrite(t, src, rel, bytes.Repeat([]byte("P"), n))
	}
	return src, 9300
}

func TestPlayDownloadSkippedByWalkChunks(t *testing.T) {
	src, play := pdlTree(t)
	next := 0
	emit := func([]byte) int { i := next; next++; return i }
	ranges, seen, deferred, _, _, dropped, _, _ := walkChunks(src, newFileScanCache(make([]byte, 32)), 4096, true, false,
		nil, nil, nil, nil, 0, emit, func(string) int { return 0 }, func(int64) {}, nil)
	for _, r := range ranges {
		if strings.Contains(r.rel, "phonesky-download-service") {
			t.Errorf("range for %q: the download cache was sealed", r.rel)
		}
	}
	for rel := range seen {
		if strings.Contains(rel, "phonesky-download-service") {
			t.Errorf("seen holds %q", rel)
		}
	}
	for _, d := range deferred {
		if strings.Contains(d.rel, "phonesky-download-service") {
			t.Errorf("deferred holds %q", d.rel)
		}
	}
	if !seen[pdlOther] {
		t.Errorf("the sibling %q was not sealed", pdlOther)
	}
	if dropped < play {
		t.Errorf("dropped = %d, want >= %d: the shrink guard must price the skipped directory", dropped, play)
	}
}

func TestPlayDownloadSkippedByTarDirTo(t *testing.T) {
	src, play := pdlTree(t)
	var buf bytes.Buffer
	dropped, err := tarDirTo(src, &buf)
	if err != nil {
		t.Fatal(err)
	}
	if dropped < play {
		t.Errorf("tarDirTo dropped = %d, want >= %d: the shrink guard must price the skipped directory", dropped, play)
	}
	tr := tar.NewReader(&buf)
	sibling := false
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(h.Name, "phonesky-download-service") {
			t.Errorf("tar holds %q", h.Name)
		}
		if strings.HasSuffix(h.Name, pdlOther) {
			sibling = true
		}
	}
	if !sibling {
		t.Errorf("the sibling %q is not in the tar", pdlOther)
	}
}

// pdlOldHead seals src (a big file at a neutral rel) under a deferring build, then renames that deferred
// record to the phonesky rel, as the head an older handset wrote. Returns the rel.
func pdlOldHead(t *testing.T, base, name, pass string, dk []byte, src string) string {
	t.Helper()
	const stage = "com.android.vending/files/stage/3/blob"
	rel := pdlDir + "/3/blob"
	preGateSeal(t)
	iwrite(t, src, stage, bytes.Repeat([]byte("PLAY-DL-"), 2000))
	iwrite(t, src, "app.a/note.txt", []byte("v1"))
	pushProfile(base, name, pass, src)
	m := headManifest(t, base, dk, name, pass)
	rec, ok := m.Deferred[stage]
	if !ok {
		t.Fatalf("fixture: %q not deferred (%d deferred)", stage, len(m.Deferred))
	}
	delete(m.Deferred, stage)
	m.Deferred[rel] = rec
	body, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	mh := postBlob(base, seal(dk, append(append([]byte{}, cdcMagic...), body...)))
	v, ok := openVaultHead(base, name, pass)
	if !ok {
		t.Fatal("fixture: no vault head")
	}
	v.Manifest = mh
	signVault(v, dk)
	putHead(base, name, pass, postBlob(base, serializeVault(v)))
	if _, ok := headManifest(t, base, dk, name, pass).Deferred[rel]; !ok {
		t.Fatal("fixture: renamed record missing from the head")
	}
	os.Remove(filepath.Join(src, stage))
	iwrite(t, src, rel, bytes.Repeat([]byte("PLAY-DL-"), 2000)) // on disk, as if Play or a partial heal wrote it
	sealScopeDefers = scopeDefersMedia                          // this build from here on
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	return rel
}

func TestPlayDownloadDeferredCarriedUntilHealed(t *testing.T) {
	state := healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "pdlcarry", "pdl carry horse battery staple"
	createVault(base, name, pass)
	dk := resolveDK(base, name, pass, nil)
	src := t.TempDir()
	rel := pdlOldHead(t, base, name, pass, dk, src)
	data := bytes.Repeat([]byte("PLAY-DL-"), 2000)

	// (a) the heal has not handled it: the walk skips the directory, so the record is carried, not dropped.
	clearHealList(state, name, pass)
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(src, "app.a/note.txt"), []byte("v2 -- a real second seal"), 0o644)
	pushProfile(base, name, pass, src)
	m := headManifest(t, base, dk, name, pass)
	if _, ok := m.Deferred[rel]; !ok {
		t.Fatal("an unfetched Play download record was DROPPED")
	}
	if manifestCarries(t, base, dk, m, rel, data) {
		t.Error("the present Play download file was sealed essential")
	}

	// (b) the sign-in heal fetched it: it leaves the head at this seal.
	m0 := headManifest(t, base, dk, name, pass)
	r := healDeferred(base, dk, m0, t.TempDir())
	handled := false
	for _, h := range r.handledRels {
		handled = handled || h == rel
	}
	if !handled {
		t.Fatalf("the heal did not handle %q: %v", rel, r.handledRels)
	}
	if err := writeHealList(state, name, pass, r.handledRels); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(src, "app.a/note.txt"), []byte("v3 -- a third seal"), 0o644)
	pushProfile(base, name, pass, src)
	m = headManifest(t, base, dk, name, pass)
	if _, ok := m.Deferred[rel]; ok {
		t.Error("a fetched Play download record stayed in the head")
	}
	if manifestCarries(t, base, dk, m, rel, data) {
		t.Error("the Play download file was sealed essential")
	}
}
