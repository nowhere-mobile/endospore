package main

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261129-03: the unfetched-package carry (unfetched_carry.go and its three lines in pushProfile). Each test seals
// a head, seals again without a listed package, and restores the new head into an empty dir. test-unfetched-carry.sh
// --mutate convicts a broken copy of each guard.

const (
	ucA = "com.example.a"
	ucB = "com.example.b"
	ucC = "com.example.c"
)

func ucRand(seed int64, n int) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

// ucBFiles is com.b's hold: small files and one large file.
func ucBFiles(bigSize int) map[string][]byte {
	return map[string][]byte{
		psHold(ucB) + "/shared_prefs/b.xml": []byte(strings.Repeat("held-b ", 500)),
		psHold(ucB) + "/databases/b.db":     []byte(strings.Repeat("held-b-db ", 400)),
		psHold(ucB) + "/files/big.bin":      ucRand(1129, bigSize),
	}
}

func ucAFiles() map[string][]byte {
	return map[string][]byte{ucA + "/shared_prefs/a.xml": []byte(strings.Repeat("keep-a ", 600))}
}

func ucUnion(ms ...map[string][]byte) map[string][]byte {
	out := map[string][]byte{}
	for _, m := range ms {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}

// ucFirstSeal seals files as scope into a fresh store.
func ucFirstSeal(t *testing.T, scope string, files map[string][]byte) string {
	t.Helper()
	base, _, _ := psSeal(t, scope, files)
	return base
}

// ucLands seals files and requires the seal to land.
func ucLands(t *testing.T, base, scope string, files map[string][]byte) string {
	t.Helper()
	refused, why, out := unfSeal(t, base, scope, psWrite(t, files))
	if refused {
		t.Fatalf("the %s seal was refused (%s)\n%s", scope, why, out)
	}
	return out
}

// ucRestoreIs restores the head into an empty dir and requires exactly want, comparing every file byte for byte.
func ucRestoreIs(t *testing.T, base, scope string, want map[string][]byte) {
	t.Helper()
	key, _, ok := resolveKey(base, scope, unfPass)
	if !ok {
		t.Fatalf("no %s head", scope)
	}
	got := psRegularFiles(t, restoreEssential(t, base, key, headManifestOf(t, base, scope, unfPass)))
	for rel, body := range want {
		b, ok := got[rel]
		if !ok {
			t.Errorf("%s: the restore lacks %s", scope, rel)
		} else if !bytes.Equal(b, body) {
			t.Errorf("%s: %s is not byte-identical after the restore", scope, rel)
		}
	}
	for rel := range got {
		if _, ok := want[rel]; !ok {
			t.Errorf("%s: the restore holds %s, which is not wanted", scope, rel)
		}
	}
}

// ucPlantHead rewrites the stored head as mut says: a head this agent did not write, or one an older agent wrote.
func ucPlantHead(t *testing.T, base, scope string, mut func(*chunkManifest)) {
	t.Helper()
	m := headManifestOf(t, base, scope, unfPass)
	mut(&m)
	body, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	key, _, ok := resolveKey(base, scope, unfPass)
	if !ok {
		t.Fatalf("no %s head", scope)
	}
	mh := postBlob(base, seal(key, append(append([]byte{}, cdcMagic...), body...)))
	if v, ok := openVaultHead(base, scope, unfPass); ok {
		v.Manifest = mh
		signVault(v, key)
		putHead(base, scope, unfPass, postBlob(base, serializeVault(v)))
		return
	}
	putRef(base, profileRefV2(scope, unfPass), mh)
}

// ucLine requires the carry's log line to say exactly these counts and to name no package.
func ucLine(t *testing.T, out, want string) {
	t.Helper()
	var line string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "unfetched carry:") {
			line = l
		}
	}
	if !strings.Contains(line, want) {
		t.Errorf("the carry line is %q, want it to hold %q", line, want)
	}
	for _, p := range []string{ucA, ucB, ucC} {
		if strings.Contains(line, p) {
			t.Errorf("the carry line names package %s: %q", p, line)
		}
	}
}

func ucNoLine(t *testing.T, out string) {
	t.Helper()
	if strings.Contains(out, "unfetched carry:") {
		t.Errorf("the carry ran:\n%s", out)
	}
}

// ucCarriesHold is U1 for scope: the second seal has no com.b on disk and carries it from the head.
func ucCarriesHold(t *testing.T, scope string, bigSize int) (string, map[string][]byte) {
	t.Helper()
	all := ucUnion(ucAFiles(), ucBFiles(bigSize))
	base := ucFirstSeal(t, scope, all)
	first := headManifestOf(t, base, scope, unfPass)
	if first.Pkg[ucB] <= 0 || len(first.PkgSpan[ucB]) == 0 {
		t.Fatalf("fixture: the first head has no index for com.b (Pkg %v, spans %v)", first.Pkg, first.PkgSpan)
	}
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	out := ucLands(t, base, scope, ucAFiles())
	ucLine(t, out, "1 package(s) carried by span, 0 left to the guard")
	second := headManifestOf(t, base, scope, unfPass)
	if second.Pkg[ucB] != first.Pkg[ucB] {
		t.Errorf("Pkg[com.b] = %d, want the first head's %d", second.Pkg[ucB], first.Pkg[ucB])
	}
	if len(second.PkgSpan[ucB]) != 1 {
		t.Errorf("pspan[com.b] = %v, want one range", second.PkgSpan[ucB])
	}
	if len(second.Sizes) != len(second.Chunks) {
		t.Errorf("Sizes has %d entries for %d chunks", len(second.Sizes), len(second.Chunks))
	}
	ucRestoreIs(t, base, scope, all)
	return base, all
}

func TestUnfetchedCarry_U1_VaultCarriesByteIdentical(t *testing.T) {
	ucCarriesHold(t, "ucu1", 1<<20)
}

// A package larger than four fifths of the head: the walk alone looks like a collapse to the shrink guard.
func TestUnfetchedCarry_U1_LargePackageBeatsTheShrinkGuard(t *testing.T) {
	const scope = "ucu1big"
	all := ucUnion(ucAFiles(), ucBFiles(16<<20))
	base := ucFirstSeal(t, scope, all)
	if n := len(headManifestOf(t, base, scope, unfPass).Chunks); n <= 10 {
		t.Fatalf("fixture: the first head has %d chunks; the 2 walked chunks must be under one fifth of it", n)
	}
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	ucLands(t, base, scope, ucAFiles())
	ucRestoreIs(t, base, scope, all)
}

func TestUnfetchedCarry_U2_ThirdSealCarriesAgain(t *testing.T) {
	const scope = "ucu2"
	all := ucUnion(ucAFiles(), ucBFiles(1<<20))
	base := ucFirstSeal(t, scope, all)
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	for i := 0; i < 2; i++ {
		out := ucLands(t, base, scope, ucAFiles())
		ucLine(t, out, "1 package(s) carried by span, 0 left to the guard")
		ucRestoreIs(t, base, scope, all)
	}
}

// com.b's hold is back on disk with one file changed: the walk's copy wins, and the old chunks do not come back.
// NWP-20261130-03 superseded "the walk's copy wins": while a package is listed, its stored span goes forward byte for
// byte, and a changed copy of it on the phone (what an app wrote on fresh data before its fetch) is left out.
func TestUnfetchedCarry_U3_StoredSpanWinsOverLocalCopy(t *testing.T) {
	const scope = "ucu3"
	stored := ucUnion(ucAFiles(), ucBFiles(1<<20))
	base := ucFirstSeal(t, scope, stored)
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	now := ucUnion(ucAFiles(), ucBFiles(1<<20))
	now[psHold(ucB)+"/shared_prefs/b.xml"] = []byte(strings.Repeat("changed-b ", 500))
	out := ucLands(t, base, scope, now)
	ucLine(t, out, "1 package(s) carried by span, 0 left to the guard")
	ucRestoreIs(t, base, scope, stored)
}

// carryUnfetched never re-emits a package the walk recorded (that would put two copies in one tar), and the guard
// refuses the seal that then leaves the stored span behind.
func TestUnfetchedCarry_U3_WalkedIsNotCarriedAndIsRefused(t *testing.T) {
	oldM := chunkManifest{Chunks: []string{"a", "b", "f"}, PkgSpan: map[string][][2]int{ucB: {{1, 2}}}, Pkg: map[string]int64{ucB: 9}}
	_, spans, _, n := carryUnfetched(oldM, []string{"x", "f2"}, map[string]bool{ucB: true}, map[string]bool{ucB: true}, nil)
	if n != 0 || spans[ucB] != nil {
		t.Fatalf("a walked package was carried: n=%d spans=%v", n, spans)
	}
	if got := unfetchedNotCarried(oldM.Pkg, spans, map[string]bool{ucB: true}, nil); got != 1 {
		t.Errorf("unfetchedNotCarried = %d, want 1 for a listed package not carried by its span", got)
	}
}

func TestUnfetchedCarry_U4_UntrustedSpanRefused(t *testing.T) {
	cases := []struct {
		name string
		mut  func(*chunkManifest)
	}{
		{"deferred", func(m *chunkManifest) {
			if m.Deferred == nil {
				m.Deferred = map[string]deferredFile{}
			}
			// In the hold shape: the deferred carry drops such a rel, so only the reader's refusal is left to see it.
			m.Deferred[psHold(ucB)+"/files/d.bin"] = deferredFile{Size: 1}
		}},
		{"overlap", func(m *chunkManifest) { m.PkgSpan["com.example.z"] = m.PkgSpan[ucB] }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			scope := "ucu4" + c.name
			base := ucFirstSeal(t, scope, ucUnion(ucAFiles(), ucBFiles(1<<20)))
			ucPlantHead(t, base, scope, c.mut)
			before := unfHeadBytes(t, base, scope)
			t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
			refused, why, out := unfSeal(t, base, scope, psWrite(t, ucAFiles()))
			if !refused || why != "unfetched-dropped" {
				t.Fatalf("seal over an untrusted span: refused=%v why=%q, want refused \"unfetched-dropped\"\n%s", refused, why, out)
			}
			ucLine(t, out, "0 package(s) carried by span, 1 left to the guard")
			if after := unfHeadBytes(t, base, scope); !bytes.Equal(before, after) {
				t.Error("the stored head changed under a refused seal")
			}
		})
	}
}

func TestUnfetchedCarry_U5_DeCarriesByteIdentical(t *testing.T) {
	ucCarriesHold(t, "ucu5#de", 1<<20)
}

func TestUnfetchedCarry_U6_OtherScopesNeverCarry(t *testing.T) {
	t.Run("media", func(t *testing.T) {
		const scope = "ucu6m#media"
		base := ucFirstSeal(t, scope, ucUnion(ucAFiles(), ucBFiles(1<<20)))
		t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
		out := ucLands(t, base, scope, ucAFiles())
		ucNoLine(t, out)
		ucRestoreIs(t, base, scope, ucAFiles())
	})
	// #apps has its own presence guard, which refuses a seal without the package. So this seal keeps the tree, and the
	// carry must not run for it either.
	t.Run("apps", func(t *testing.T) {
		const scope = "ucu6a#apps"
		all := ucUnion(ucAFiles(), ucBFiles(1<<20))
		base := ucFirstSeal(t, scope, all)
		t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
		ucNoLine(t, ucLands(t, base, scope, all))
	})
	// NWP-20261130-03: pushProfile hands the carry the list it read once (sealUnfetchedList, nil for these scopes), so the
	// carry's own scope gate is pinned directly, with a list handed in.
	t.Run("gate", func(t *testing.T) {
		oldM := chunkManifest{Chunks: []string{"a", "f"}, PkgSpan: map[string][][2]int{ucB: {{0, 1}}}, Pkg: map[string]int64{ucB: 9}}
		for _, scope := range []string{"ucu6g#media", "ucu6g#apps"} {
			if _, spans, _, n := sealCarryUnfetched(scope, oldM, []string{"x", "f"}, nil, nil, map[string]bool{ucB: true}, true); n != 0 || spans != nil {
				t.Errorf("%s: the carry ran (n=%d)", scope, n)
			}
		}
	})
}

func TestUnfetchedCarry_U7_FullSealRefusesUnknown(t *testing.T) {
	const scope = "ucu7"
	base := ucFirstSeal(t, scope, ucUnion(ucAFiles(), ucBFiles(1<<10))) // small: a large head trips the shrink guard first
	before := unfHeadBytes(t, base, scope)
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	t.Setenv("NOWHERE_SEAL_FULL", "1")
	refused, why, out := unfSeal(t, base, scope, psWrite(t, ucAFiles()))
	if !refused || why != "unfetched-unknown" {
		t.Fatalf("full seal: refused=%v why=%q, want refused \"unfetched-unknown\"\n%s", refused, why, out)
	}
	ucNoLine(t, out)
	if after := unfHeadBytes(t, base, scope); !bytes.Equal(before, after) {
		t.Error("the stored head changed under a refused seal")
	}
}

// com.b is the only hold: no walked entry names the hold dir, so the restore must create its parents from the file entry.
func TestUnfetchedCarry_U8_OnlyHoldCreatesItsParents(t *testing.T) {
	const scope = "ucu8"
	all := ucUnion(ucAFiles(), ucBFiles(1<<20))
	base := ucFirstSeal(t, scope, all)
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	dir := psWrite(t, ucAFiles())
	if _, err := os.Stat(filepath.Join(dir, chooserPkg)); !os.IsNotExist(err) {
		t.Fatalf("fixture: the second tree names the chooser dir (err=%v)", err)
	}
	refused, why, out := unfSeal(t, base, scope, dir)
	if refused {
		t.Fatalf("refused (%s)\n%s", why, out)
	}
	ucRestoreIs(t, base, scope, all)
}

func TestUnfetchedCarry_U9_TwoRangesBecomeOne(t *testing.T) {
	const scope = "ucu9"
	keep := map[string][]byte{ucC + "/shared_prefs/c.xml": []byte(strings.Repeat("between-c ", 500))}
	canon := map[string][]byte{ucB + "/shared_prefs/canon.xml": []byte(strings.Repeat("canon-b ", 500))}
	all := ucUnion(keep, canon, ucBFiles(1<<20))
	base := ucFirstSeal(t, scope, all)
	if rs := headManifestOf(t, base, scope, unfPass).PkgSpan[ucB]; len(rs) != 2 {
		t.Fatalf("fixture: the first head's pspan[com.b] = %v, want two ranges", rs)
	}
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	for i := 0; i < 2; i++ {
		out := ucLands(t, base, scope, keep)
		ucLine(t, out, "1 package(s) carried by span, 0 left to the guard")
		if rs := headManifestOf(t, base, scope, unfPass).PkgSpan[ucB]; len(rs) != 1 {
			t.Errorf("seal %d: pspan[com.b] = %v, want one range", i+2, rs)
		}
		ucRestoreIs(t, base, scope, all)
	}
}

func TestUnfetchedCarry_U10_DroppedIsNotCarried(t *testing.T) {
	const scope = "ucu10"
	base := ucFirstSeal(t, scope, ucUnion(ucAFiles(), ucBFiles(1<<10)))
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	dl := filepath.Join(t.TempDir(), "drop.list")
	if err := os.WriteFile(dl, []byte(ucB+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", dl)
	ucLands(t, base, scope, ucAFiles())
	if m := headManifestOf(t, base, scope, unfPass); m.Pkg[ucB] != 0 || len(m.PkgSpan[ucB]) != 0 {
		t.Errorf("a dropped package stayed in the head: Pkg %v, spans %v", m.Pkg, m.PkgSpan)
	}
	ucRestoreIs(t, base, scope, ucAFiles())
}

// The whole account is the listed package: the walk builds no index, so the merges start from nil maps.
func TestUnfetchedCarry_U11_EmptyWalkCarries(t *testing.T) {
	const scope = "ucu11"
	all := ucBFiles(1 << 20)
	base := ucFirstSeal(t, scope, all)
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
	ucLands(t, base, scope, nil)
	ucRestoreIs(t, base, scope, all)
}
