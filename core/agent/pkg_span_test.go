package main

import (
	"bytes"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// NWP-20261127-01: the per-package span index (pkg_span.go, chunkManifest.PkgSpan). A vault or #de head names, per
// package, the chunk ranges that hold only that package's data, and a span restored alone yields exactly that
// package's files. test-pkg-span.sh --mutate convicts a broken copy of each guard.

const (
	psInst = "com.example.inst"
	psH1   = "com.example.h1"
	psH2   = "com.example.h2"
)

func psHold(pkg string) string { return chooserPkg + "/" + odHoldDirName + "/" + pkg }

// psFiles is the S1 tree: an installed package with small files and one file-aligned large file, two held packages
// in the hold shape (the shape hold_ondemand parks On-demand and Auto data in), and a chooser-own file.
func psFiles() map[string][]byte {
	big := make([]byte, sealFileThreshold()+sealFileThreshold()/2)
	rand.New(rand.NewSource(1127)).Read(big)
	return map[string][]byte{
		psInst + "/shared_prefs/a.xml":            []byte(strings.Repeat("inst-a ", 700)),
		psInst + "/files/b":                       []byte(strings.Repeat("inst-b ", 300)),
		psInst + "/files/big.bin":                 big,
		psHold(psH1) + "/shared_prefs/h1.xml":     []byte(strings.Repeat("held-one ", 500)),
		psHold(psH1) + "/databases/h1.db":         []byte(strings.Repeat("held-one-db ", 400)),
		psHold(psH2) + "/shared_prefs/h2.xml":     []byte(strings.Repeat("held-two ", 450)),
		psHold(psH2) + "/files/h2.bin":            []byte(strings.Repeat("held-two-bin ", 350)),
		chooserPkg + "/shared_prefs/own.xml":      []byte(strings.Repeat("chooser-own ", 200)),
		chooserPkg + "/files/" + "own-state.json": []byte(`{"own":true}`),
	}
}

func psWrite(t *testing.T, files map[string][]byte) string {
	t.Helper()
	dir := t.TempDir()
	for rel, body := range files {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, body, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// psSeal seals files as scope into a fresh store and returns the store, the head and the seal's output.
func psSeal(t *testing.T, scope string, files map[string][]byte) (string, chunkManifest, string) {
	t.Helper()
	resetSealCaches()
	base := newHTTPStore(t)
	createVault(base, strings.SplitN(scope, "#", 2)[0], unfPass)
	sealRefused, sealRefusedWhy = false, ""
	out := captureStdout(t, func() { pushProfile(base, scope, unfPass, psWrite(t, files)) })
	if sealRefused {
		t.Fatalf("fixture: the %s seal was refused (%s)\n%s", scope, sealRefusedWhy, out)
	}
	return base, headManifestOf(t, base, scope, unfPass), out
}

// psRegularFiles is every regular file under dir, rel -> content.
func psRegularFiles(t *testing.T, dir string) map[string][]byte {
	t.Helper()
	got := map[string][]byte{}
	err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			rel, _ := filepath.Rel(dir, p)
			b, rerr := os.ReadFile(p)
			if rerr != nil {
				return rerr
			}
			got[filepath.ToSlash(rel)] = b
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return got
}

// psRestoreAlone restores pkg's span by itself into a fresh dir and requires exactly want, byte for byte.
func psRestoreAlone(t *testing.T, base, scope string, m chunkManifest, pkg string, want map[string][]byte) {
	t.Helper()
	c, s, ok := pkgSpanChunks(m, pkg)
	if !ok {
		t.Fatalf("%s: pkgSpanChunks refused %s (span %v)", scope, pkg, m.PkgSpan[pkg])
	}
	key, _, rok := resolveKey(base, scope, unfPass)
	if !rok {
		t.Fatalf("no %s head", scope)
	}
	dest := t.TempDir()
	if skipped := cdcRestore(base, key, chunkManifest{Version: m.Version, Chunks: c, Sizes: s}, dest); skipped != 0 {
		t.Errorf("%s: restoring %s's span alone skipped %d entries", scope, pkg, skipped)
	}
	got := psRegularFiles(t, dest)
	for rel := range got {
		if _, ok := want[rel]; !ok {
			t.Errorf("%s: %s's span restored %s, a file of another package", scope, pkg, rel)
		}
	}
	for rel, body := range want {
		if g, ok := got[rel]; !ok {
			t.Errorf("%s: %s's span did not restore %s", scope, pkg, rel)
		} else if !bytes.Equal(g, body) {
			t.Errorf("%s: %s's span restored %s with other bytes (%d, want %d)", scope, pkg, rel, len(g), len(body))
		}
	}
}

// psOwn is the files of files that attrPkgForRel bills to pkg.
func psOwn(files map[string][]byte, pkg string) map[string][]byte {
	own := map[string][]byte{}
	for rel, b := range files {
		if attrPkgForRel(rel) == pkg {
			own[rel] = b
		}
	}
	return own
}

func psSpanLine(t *testing.T, out string) string {
	t.Helper()
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "pkg span index:") {
			return l
		}
	}
	return ""
}

func psEachPackageRestoresAlone(t *testing.T, scope string) {
	files := psFiles()
	base, m, out := psSeal(t, scope, files)
	var keys []string
	for p := range m.PkgSpan {
		keys = append(keys, p)
	}
	want := map[string]bool{psInst: true, psH1: true, psH2: true}
	if len(keys) != len(want) || !want[keys[0]] || !want[keys[1]] || !want[keys[2]] {
		t.Fatalf("%s head PkgSpan names %v, want exactly %s, %s and %s", scope, keys, psInst, psH1, psH2)
	}
	for p := range want {
		psRestoreAlone(t, base, scope, m, p, psOwn(files, p))
	}
	line := psSpanLine(t, out)
	if !strings.Contains(line, "3 package(s), 0 left out (NWP-20261127-01)") {
		t.Errorf("span count line %q, want 3 package(s), 0 left out", line)
	}
	for p := range want {
		if strings.Contains(line, p) {
			t.Errorf("the span count line names package %s: %q", p, line)
		}
	}
}

// S1: the core proof on the bare vault.
func TestPkgSpan_VaultEachPackageRestoresAlone(t *testing.T) {
	psEachPackageRestoresAlone(t, "psvault1")
}

// S2: the same on #de.
func TestPkgSpan_DeEachPackageRestoresAlone(t *testing.T) { psEachPackageRestoresAlone(t, "psde1#de") }

// S3: no other scope and no full-tar seal writes the index.
func TestPkgSpan_MediaAndFullSealWriteNone(t *testing.T) {
	t.Run("media", func(t *testing.T) {
		// The S1 tree, not an Android/... tree: its units name packages, so without the scope gate the #media
		// walk (the same incremental walk, which fills acct) would give the held packages spans.
		base, m, _ := psSeal(t, "psmedia1#media", psFiles())
		if m.Pkg[psH1] <= 0 || m.Pkg[psH2] <= 0 {
			t.Fatalf("fixture: the #media walk attributed no bytes to the held packages (Pkg %v)", m.Pkg)
		}
		if m.PkgSpan != nil {
			t.Errorf("a #media head carries a span index: %v", m.PkgSpan)
		}
		if raw := unfHeadBytes(t, base, "psmedia1#media"); bytes.Contains(raw, []byte(`"pspan"`)) {
			t.Error(`the raw #media head holds a "pspan" key`)
		}
	})
	t.Run("fullseal", func(t *testing.T) {
		t.Setenv("NOWHERE_SEAL_FULL", "1")
		base, m, _ := psSeal(t, "psfull1", psFiles())
		if m.PkgSpan != nil {
			t.Errorf("a full-tar vault head carries a span index: %v", m.PkgSpan)
		}
		if raw := unfHeadBytes(t, base, "psfull1"); bytes.Contains(raw, []byte(`"pspan"`)) {
			t.Error(`the raw full-tar head holds a "pspan" key`)
		}
	})
}

// S4: a loose root-level file inside a package's group makes the group mixed, and that package is left out.
func TestPkgSpan_MixedGroupLeavesItsPackageOut(t *testing.T) {
	// filepath.Walk is lexical and descends before it moves on: com.example.a (all of it), then the loose root FILE
	// com.example.a0 (unit "", it joins a's open group), then com.example.b.
	files := map[string][]byte{
		"com.example.a/shared_prefs/a.xml": []byte(strings.Repeat("aaa ", 400)),
		"com.example.a0":                   []byte(strings.Repeat("loose ", 100)),
		"com.example.b/shared_prefs/b.xml": []byte(strings.Repeat("bbb ", 400)),
	}
	base, m, out := psSeal(t, "psmixed1", files)
	if _, ok := m.PkgSpan["com.example.a"]; ok {
		t.Errorf("com.example.a has a span %v although a loose root file shares its group", m.PkgSpan["com.example.a"])
	}
	if _, ok := m.PkgSpan["com.example.b"]; !ok {
		t.Fatalf("com.example.b lost its span (PkgSpan %v)", m.PkgSpan)
	}
	psRestoreAlone(t, base, "psmixed1", m, "com.example.b", psOwn(files, "com.example.b"))
	if line := psSpanLine(t, out); !strings.Contains(line, "1 package(s), 1 left out") {
		t.Errorf("span count line %q, want 1 package(s), 1 left out", line)
	}

	// The other order: a loose root file that sorts first opens the group, and the package dir joins it.
	files = map[string][]byte{
		"0loose":                           []byte(strings.Repeat("loose ", 100)),
		"com.example.c/shared_prefs/c.xml": []byte(strings.Repeat("ccc ", 400)),
		"com.example.d/shared_prefs/d.xml": []byte(strings.Repeat("ddd ", 400)),
	}
	base, m, _ = psSeal(t, "psmixed2", files)
	if _, ok := m.PkgSpan["com.example.c"]; ok {
		t.Errorf("com.example.c has a span %v although a loose root file opened its group", m.PkgSpan["com.example.c"])
	}
	if _, ok := m.PkgSpan["com.example.d"]; !ok {
		t.Fatalf("com.example.d lost its span (PkgSpan %v)", m.PkgSpan)
	}
	psRestoreAlone(t, base, "psmixed2", m, "com.example.d", psOwn(files, "com.example.d"))
}

// S4, the builder alone: every reason a package is left out, and the packages that stay.
func TestPkgSpan_BuildLeavesOutSharedAndBadIndices(t *testing.T) {
	held := psHold("com.example.held")
	a := &pkgAcct{
		single: map[int]string{
			0: "com.example.p1", 1: "com.example.p1", // p1: singles plus its own group -> one range
			5:  "com.example.p2", // p2: also inside p3's group -> both out
			7:  "com.example.p5", // p5: inside a mixed group -> out
			8:  "com.example.p6", // p6: deferred (essIdx -1) -> out
			10: "com.example.p7", // p7: essential index beyond nChunks -> out
		},
		groups: []groupSpan{
			{start: 2, end: 4, unit: "com.example.p1", weights: map[string]int64{"com.example.p1": 9}},
			{start: 5, end: 6, unit: "com.example.p3", weights: map[string]int64{"com.example.p3": 9}},
			{start: 6, end: 8, unit: "com.example.p4", mixed: true, weights: map[string]int64{"com.example.p4": 9}},
			{start: 9, end: 10, unit: "com.example.p6"},
			{start: 11, end: 12, unit: chooserPkg, weights: map[string]int64{chooserPkg: 9}},
			{start: 12, end: 14, unit: held, weights: map[string]int64{"com.example.held": 9}},
			{start: 14, end: 15, unit: "com.example.p8", weights: map[string]int64{"com.example.p9": 9}},
			{start: 16, end: 17, unit: "", weights: nil},
			{start: 17, end: 19, unit: "com.example.p1", weights: map[string]int64{"com.example.p1": 1}},
		},
	}
	//            0  1  2  3  4  5  6  7   8  9  10 11 12 13 14 15 16 17 18
	essIdx := []int{0, 1, 2, 3, 4, 5, 6, 7, -1, 8, 99, 9, 10, 11, 12, 13, 14, 15, 16}
	got := buildPkgSpans(a, essIdx, 17)
	want := map[string][][2]int{
		"com.example.p1":   {{0, 4}, {15, 17}},
		"com.example.held": {{10, 12}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("buildPkgSpans = %v, want %v", got, want)
	}
	if n := len(pkgSpanNamed(a)) - len(got); n != 8 {
		t.Errorf("left out %d, want 8 (p2 to p9): named %v", n, pkgSpanNamed(a))
	}
	if buildPkgSpans(nil, essIdx, 17) != nil || buildPkgSpans(&pkgAcct{single: map[int]string{}}, nil, 0) != nil {
		t.Error("an empty accumulator must build nil")
	}
}

// S5: the reader refuses every malformed or shared span.
func TestPkgSpan_ReaderRefusesMalformed(t *testing.T) {
	const pkg = "com.example.a"
	base := func() chunkManifest {
		return chunkManifest{
			Version: 2,
			Chunks:  []string{"c0", "c1", "c2", "c3", "c4", "c5"},
			Sizes:   []int64{10, 11, 12, 13, 14, 15},
			PkgSpan: map[string][][2]int{pkg: {{0, 2}, {4, 5}}, "com.example.b": {{2, 4}}},
		}
	}
	cases := []struct {
		name string
		edit func(m *chunkManifest)
	}{
		{"no index", func(m *chunkManifest) { m.PkgSpan = nil }},
		{"pkg absent", func(m *chunkManifest) { delete(m.PkgSpan, pkg) }},
		{"empty ranges", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{} }},
		{"s below zero", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{{-1, 2}} }},
		{"e not above s", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{{1, 1}} }},
		{"e beyond Chunks", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{{4, 7}} }},
		{"unsorted", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{{4, 5}, {0, 2}} }},
		{"touching", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{{0, 1}, {1, 2}} }},
		{"overlapping", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{{0, 2}, {1, 2}} }},
		{"overlaps another package", func(m *chunkManifest) { m.PkgSpan[pkg] = [][2]int{{0, 3}} }},
		{"Sizes not parallel", func(m *chunkManifest) { m.Sizes = m.Sizes[:3] }},
		{"a Deferred rel under pkg", func(m *chunkManifest) {
			m.Deferred = map[string]deferredFile{pkg + "/files/x": {Chunks: []string{"d0"}}}
		}},
	}
	for _, c := range cases {
		t.Run(strings.ReplaceAll(c.name, " ", "_"), func(t *testing.T) {
			m := base()
			c.edit(&m)
			if ch, sz, ok := pkgSpanChunks(m, pkg); ok || ch != nil || sz != nil {
				t.Errorf("pkgSpanChunks = (%v, %v, %v), want a refusal", ch, sz, ok)
			}
		})
	}
	t.Run("well_formed", func(t *testing.T) {
		m := base()
		m.Deferred = map[string]deferredFile{"com.example.b/files/x": {Chunks: []string{"d0"}}}
		ch, sz, ok := pkgSpanChunks(m, pkg)
		if !ok || !reflect.DeepEqual(ch, []string{"c0", "c1", "c4"}) || !reflect.DeepEqual(sz, []int64{10, 11, 14}) {
			t.Errorf("pkgSpanChunks = (%v, %v, %v), want ([c0 c1 c4], [10 11 14], true)", ch, sz, ok)
		}
		m.Sizes = nil
		if ch, sz, ok := pkgSpanChunks(m, pkg); !ok || len(ch) != 3 || sz != nil {
			t.Errorf("no Sizes: pkgSpanChunks = (%v, %v, %v), want three hashes, nil sizes, true", ch, sz, ok)
		}
	})
}

// S6: recording zero-weight groups changes no Pkg value, and a held package's Pkg is now exactly its span's bytes.
func TestPkgSpan_AttributionUnchangedAndExact(t *testing.T) {
	a := &pkgAcct{
		single: map[int]string{0: "com.example.a"},
		groups: []groupSpan{{start: 1, end: 3, weights: map[string]int64{"com.example.a": 3, "com.example.b": 1}}},
	}
	essIdx := []int{0, 1, 2, 3, 4}
	sizes := []int64{100, 40, 60, 70, 80}
	before := attributePkgBytes(a, essIdx, sizes)
	a.groups = append(a.groups,
		groupSpan{start: 3, end: 4, unit: chooserPkg, weights: map[string]int64{}},
		groupSpan{start: 4, end: 5, unit: "", weights: nil})
	if after := attributePkgBytes(a, essIdx, sizes); !reflect.DeepEqual(before, after) {
		t.Errorf("zero-weight groups changed Pkg: %v -> %v", before, after)
	}

	_, m, _ := psSeal(t, "psattr1", psFiles())
	for _, p := range []string{psInst, psH1, psH2} {
		_, sz, ok := pkgSpanChunks(m, p)
		if !ok {
			t.Fatalf("pkgSpanChunks refused %s (span %v)", p, m.PkgSpan[p])
		}
		var sum int64
		for _, n := range sz {
			sum += n
		}
		if m.Pkg[p] != sum {
			t.Errorf("Pkg[%s] = %d, want %d, the sealed bytes of its own span", p, m.Pkg[p], sum)
		}
	}
}

// groupUnit gives a held package its own unit and leaves every other rel as before; spanPkgOfUnit reads it back.
func TestPkgSpan_GroupUnitAndSpanPkgOfUnit(t *testing.T) {
	dir, err := os.Stat(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := psWrite(t, map[string][]byte{"f": []byte("x")})
	file, err := os.Stat(filepath.Join(f, "f"))
	if err != nil {
		t.Fatal(err)
	}
	hold := chooserPkg + "/" + odHoldDirName
	cases := []struct {
		rel  string
		info os.FileInfo
		unit string
		pkg  string
	}{
		{hold, dir, chooserPkg, ""},
		{hold + "/com.example.h", dir, hold + "/com.example.h", "com.example.h"},
		{hold + "/com.example.h/shared_prefs/x.xml", file, hold + "/com.example.h", "com.example.h"},
		{chooserPkg + "/files/own", file, chooserPkg, ""},
		{chooserPkg, dir, chooserPkg, ""},
		{"com.example.a/files/x", file, "com.example.a", "com.example.a"},
		{"com.example.a", dir, "com.example.a", "com.example.a"},
		{"Android/data/com.example.a/x", file, "Android", ""},
		{"folder/x", file, "folder", ""},
		{"loose.txt", file, "", ""},
	}
	for _, c := range cases {
		u := groupUnit(c.rel, c.info)
		if u != c.unit {
			t.Errorf("groupUnit(%q) = %q, want %q", c.rel, u, c.unit)
		}
		if p := spanPkgOfUnit(u); p != c.pkg {
			t.Errorf("spanPkgOfUnit(%q) = %q, want %q", u, p, c.pkg)
		}
	}
	for _, u := range []string{hold + "/", hold + "/a/b", "a.b/c"} {
		if p := spanPkgOfUnit(u); p != "" {
			t.Errorf("spanPkgOfUnit(%q) = %q, want none", u, p)
		}
	}
}

// RF-001: a mixed group leaves its package out WHOLE. The package's own single chunks and clean groups must not give
// it a span with the mixed group's chunks missing: a carry by that span would drop the files in the mixed group.
func TestPkgSpan_MixedGroupLeavesWholePackageOut(t *testing.T) {
	// The builder alone: p1 has a single chunk, a clean group and a mixed group with its weights; p2 has a single
	// chunk and a mixed group of directories only (no weights, its unit names it); p3 is clean and stays.
	a := &pkgAcct{
		single: map[int]string{0: "com.example.p1", 3: "com.example.p2", 5: "com.example.p3"},
		groups: []groupSpan{
			{start: 1, end: 2, unit: "com.example.p1", weights: map[string]int64{"com.example.p1": 9}},
			{start: 2, end: 3, unit: "com.example.p1", mixed: true, weights: map[string]int64{"com.example.p1": 9, "com.example.p1x": 4}},
			{start: 4, end: 5, unit: "com.example.p2", mixed: true},
			{start: 6, end: 7, unit: "com.example.p3", weights: map[string]int64{"com.example.p3": 9}},
		},
	}
	got := buildPkgSpans(a, []int{0, 1, 2, 3, 4, 5, 6}, 7)
	if want := map[string][][2]int{"com.example.p3": {{5, 7}}}; !reflect.DeepEqual(got, want) {
		t.Errorf("buildPkgSpans = %v, want %v (p1 and p2 each have data in a mixed group)", got, want)
	}

	// The walk: com.example.a's large file is its own chunks and flushes a's open group; a's later small entries
	// then share a group with the loose root file com.example.a0. Once with a small file, once with directories only.
	threshold := int64(4096)
	big := make([]byte, 3*threshold)
	rand.New(rand.NewSource(1558)).Read(big)
	for _, tc := range []struct {
		name  string
		files map[string][]byte
		dirs  []string
	}{
		{"file", map[string][]byte{
			"com.example.a/files/big":          big,
			"com.example.a/shared_prefs/a.xml": []byte(strings.Repeat("a", 18)),
			"com.example.a0":                   []byte("loose root file"),
			"com.example.b/files/b":            []byte(strings.Repeat("b", 40)),
		}, nil},
		{"dirs-only", map[string][]byte{
			"com.example.a/files/big": big,
			"com.example.a0":          []byte("loose root file"),
			"com.example.b/files/b":   []byte(strings.Repeat("b", 40)),
		}, []string{"com.example.a/zz_empty/inner"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			src := psWrite(t, tc.files)
			for _, d := range tc.dirs {
				if err := os.MkdirAll(filepath.Join(src, filepath.FromSlash(d)), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			n := 0
			emit := func([]byte) int { n++; return n - 1 }
			emitCached := func(string) int { n++; return n - 1 }
			acct := newPkgAcct()
			walkChunks(src, newFileScanCache(make([]byte, 32)), threshold, true, false, nil, nil, nil, nil, 0,
				emit, emitCached, func(int64) {}, acct)
			essIdx := make([]int, n)
			for i := range essIdx {
				essIdx[i] = i
			}
			spans := buildPkgSpans(acct, essIdx, n)
			if s, ok := spans["com.example.a"]; ok {
				t.Errorf("com.example.a has the partial span %v although a mixed group holds some of its entries", s)
			}
			if _, ok := spans["com.example.b"]; !ok {
				t.Errorf("com.example.b lost its span (spans %v)", spans)
			}
		})
	}
}
