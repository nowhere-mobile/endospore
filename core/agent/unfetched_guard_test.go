package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261124-06: the unfetched-package seal guard (unfetched_guard.go and its block in pushProfile). Once a
// sign-in skips an On-demand or Auto app's data (2026-10-26 #2), the next vault or #de seal walks a tree without
// that app's hold. These tests pin that such a seal is refused while the package is listed as unfetched.

const (
	unfHeld = "com.example.held"
	unfKeep = "com.example.keep"
	unfPass = "correct horse battery staple"
)

// unfHold is a rel in the on-demand hold shape: roamd parks a held app's data under the chooser's dir.
var unfHold = chooserPkg + "/" + odHoldDirName + "/" + unfHeld + "/shared_prefs/h.xml"

func TestUnfetchedDropped_Verdict(t *testing.T) {
	held := map[string]bool{unfHeld: true}
	cases := []struct {
		name           string
		oldPkg, newPkg map[string]int64
		oldDef, newDef []string
		unfetched      map[string]bool
		drop           map[string]bool
		want           int
	}{
		{"stored and present", map[string]int64{unfHeld: 10}, map[string]int64{unfHeld: 10}, nil, nil, held, nil, 0},
		{"stored and absent", map[string]int64{unfHeld: 10}, map[string]int64{"com.example.other": 5}, nil, nil, held, nil, 1},
		{"absent from both", map[string]int64{}, map[string]int64{}, nil, nil, held, nil, 0},
		{"hold deferred in the head, gone now", nil, map[string]int64{"com.example.other": 5}, []string{unfHold}, nil, held, nil, 1},
		{"hold deferred in the head and now", nil, map[string]int64{"com.example.other": 5}, []string{unfHold}, []string{unfHold}, held, nil, 0},
		{"stored, absent, dropped", map[string]int64{unfHeld: 10}, map[string]int64{"com.example.other": 5}, nil, nil, held, held, 0},
		{"an unlisted package lost", map[string]int64{"com.example.x": 10}, map[string]int64{}, nil, nil, held, nil, 0},
		{"two lost", map[string]int64{unfHeld: 1, "com.example.b": 1}, map[string]int64{}, nil, nil,
			map[string]bool{unfHeld: true, "com.example.b": true}, nil, 2},
	}
	for _, c := range cases {
		if got := unfetchedDropped(c.oldPkg, c.oldDef, c.newPkg, c.newDef, c.unfetched, c.drop); got != c.want {
			t.Errorf("%s: unfetchedDropped = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestUnfetchedList_Load(t *testing.T) {
	t.Setenv("NOWHERE_UNFETCHED_LIST", "") // registers the restore; the unset below is undone with it
	os.Unsetenv("NOWHERE_UNFETCHED_LIST")
	if m, ok := loadUnfetchedList(); m != nil || !ok {
		t.Errorf("unset: got (%v, %v), want (nil, true)", m, ok)
	}
	t.Setenv("NOWHERE_UNFETCHED_LIST", "")
	if m, ok := loadUnfetchedList(); m != nil || !ok {
		t.Errorf("empty: got (%v, %v), want (nil, true)", m, ok)
	}
	t.Setenv("NOWHERE_UNFETCHED_LIST", filepath.Join(t.TempDir(), "missing"))
	if m, ok := loadUnfetchedList(); m != nil || ok {
		t.Errorf("unreadable: got (%v, %v), want (nil, false) -- an unreadable list is not \"no list\"", m, ok)
	}
	p := filepath.Join(t.TempDir(), "unfetched.list")
	if err := os.WriteFile(p, []byte("# note\n\ncom.example.a\n  com.example.b  \n../etc\nbad name\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_UNFETCHED_LIST", p)
	m, ok := loadUnfetchedList()
	if !ok || len(m) != 2 || !m["com.example.a"] || !m["com.example.b"] {
		t.Errorf("readable: got (%v, %v), want ({com.example.a, com.example.b}, true)", m, ok)
	}
}

// unfTree writes a CE-shaped tree: one fetched app, plus, when withHold, a held app's data in the hold shape.
func unfTree(t *testing.T, withHold bool) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{unfKeep + "/shared_prefs/k.xml": strings.Repeat("keep ", 600)}
	if withHold {
		files[unfHold] = strings.Repeat("held ", 600)
	}
	for rel, body := range files {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func unfList(t *testing.T, pkgs ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "unfetched.list")
	if err := os.WriteFile(p, []byte(strings.Join(pkgs, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// unfSeal runs one pushProfile and reports whether it was refused, why, and what it printed.
func unfSeal(t *testing.T, base, profile, src string) (bool, string, string) {
	t.Helper()
	sealRefused, sealRefusedWhy = false, ""
	out := captureStdout(t, func() { pushProfile(base, profile, unfPass, src) })
	return sealRefused, sealRefusedWhy, out
}

// unfFirstSeal seals the stored head with the hold and checks that the head's Pkg index carries it.
func unfFirstSeal(t *testing.T, scope string) string {
	t.Helper()
	resetSealCaches()
	base := newHTTPStore(t)
	createVault(base, strings.SplitN(scope, "#", 2)[0], unfPass)
	if refused, why, _ := unfSeal(t, base, scope, unfTree(t, true)); refused {
		t.Fatalf("fixture: the first %s seal was refused (%s)", scope, why)
	}
	if m := headManifestOf(t, base, scope, unfPass); m.Pkg[unfHeld] <= 0 {
		t.Fatalf("fixture: the stored %s head has no Pkg entry for the hold (Pkg %v)", scope, m.Pkg)
	}
	return base
}

func unfHeadBytes(t *testing.T, base, scope string) []byte {
	t.Helper()
	_, mb, ok := resolveKey(base, scope, unfPass)
	if !ok {
		t.Fatalf("no %s head", scope)
	}
	return mb
}

// unfNoNames requires the refusal line to name no package (NWP-20261119-02: counts, never names).
func unfNoNames(t *testing.T, out string) {
	t.Helper()
	var line string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "SEAL REFUSED") {
			line = l
		}
	}
	if line == "" {
		t.Fatalf("no SEAL REFUSED line in the output:\n%s", out)
	}
	for _, p := range []string{unfHeld, unfKeep} {
		if strings.Contains(line, p) {
			t.Errorf("the refusal line names package %s: %q", p, line)
		}
	}
}

func unfRefusesADroppedHold(t *testing.T, scope string) {
	base := unfFirstSeal(t, scope)
	ucPlantHead(t, base, scope, func(m *chunkManifest) { m.PkgSpan = nil }) // a head sealed before NWP-20261127-01: the carry cannot take it
	before := unfHeadBytes(t, base, scope)
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, unfHeld))
	refused, why, out := unfSeal(t, base, scope, unfTree(t, false))
	if !refused || why != "unfetched-dropped" {
		t.Fatalf("%s seal without an unfetched package's hold: refused=%v why=%q, want refused \"unfetched-dropped\" -- "+
			"the app's data would be gone from the account", scope, refused, why)
	}
	unfNoNames(t, out)
	if after := unfHeadBytes(t, base, scope); !bytes.Equal(before, after) {
		t.Error("the stored head changed under a refused seal")
	}
}

func TestUnfetchedGuard_VaultRefusesADroppedHold(t *testing.T) { unfRefusesADroppedHold(t, "unfvault") }

func TestUnfetchedGuard_DeRefusesADroppedHold(t *testing.T) { unfRefusesADroppedHold(t, "unfde#de") }

func TestUnfetchedGuard_NoListSealsAsToday(t *testing.T) {
	base := unfFirstSeal(t, "unfnolist")
	if refused, why, _ := unfSeal(t, base, "unfnolist", unfTree(t, false)); refused {
		t.Fatalf("with no unfetched list the seal was refused (%s) -- no list must mean today's behaviour", why)
	}
	if m := headManifestOf(t, base, "unfnolist", unfPass); m.Pkg[unfHeld] > 0 {
		t.Errorf("the new head still carries the hold (Pkg %v)", m.Pkg)
	}
}

func TestUnfetchedGuard_DroppedPackageSeals(t *testing.T) {
	base := unfFirstSeal(t, "unfdrop")
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, unfHeld))
	dl := filepath.Join(t.TempDir(), "drop.list")
	if err := os.WriteFile(dl, []byte(unfHeld+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", dl)
	if refused, why, _ := unfSeal(t, base, "unfdrop", unfTree(t, false)); refused {
		t.Fatalf("a seal that drops a package the user switched Off was refused (%s) -- a deliberate Off is a deletion", why)
	}
}

func TestUnfetchedGuard_UnreadableListRefuses(t *testing.T) {
	base := unfFirstSeal(t, "unfunread")
	before := unfHeadBytes(t, base, "unfunread")
	t.Setenv("NOWHERE_UNFETCHED_LIST", filepath.Join(t.TempDir(), "missing"))
	refused, why, out := unfSeal(t, base, "unfunread", unfTree(t, false))
	if !refused || why != "unfetched-unknown" {
		t.Fatalf("seal with an unreadable unfetched list: refused=%v why=%q, want refused \"unfetched-unknown\"", refused, why)
	}
	unfNoNames(t, out)
	if after := unfHeadBytes(t, base, "unfunread"); !bytes.Equal(before, after) {
		t.Error("the stored head changed under a refused seal")
	}
}

// A #media seal never reads the list: an unreadable one would otherwise refuse it as unfetched-unknown.
func TestUnfetchedGuard_MediaNeverReadsTheList(t *testing.T) {
	base := unfFirstSeal(t, "unfmedia#media")
	t.Setenv("NOWHERE_UNFETCHED_LIST", filepath.Join(t.TempDir(), "missing"))
	if refused, why, _ := unfSeal(t, base, "unfmedia#media", unfTree(t, false)); refused {
		t.Fatalf("a #media seal was refused (%s) -- the unfetched list is for the bare vault and #de only", why)
	}
}

func TestUnfetchedGuard_ForceSkips(t *testing.T) {
	base := unfFirstSeal(t, "unfforce")
	t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, unfHeld))
	t.Setenv("NOWHERE_SEAL_FORCE", "1")
	if refused, why, _ := unfSeal(t, base, "unfforce", unfTree(t, false)); refused {
		t.Fatalf("NOWHERE_SEAL_FORCE=1 did not skip the unfetched guard (%s)", why)
	}
}
