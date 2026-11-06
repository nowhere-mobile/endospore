package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261128-01 (backlog: "P1: On-demand apps that are not on the phone at a sign-out are dropped from the
// `#apps` code list, ..."). A head sealed before 0.5.51 has no app index, because pushProfile writes Apps only
// under the carry. Since NWP-20261119-02 roamd stages NOTHING for a carried On-demand/Auto package (no dir, no
// _meta, no line) and leaves the carry to that index. Over an index-less head the carry had nothing to carry from:
// the _meta and the line left the head, the #204 deferred carry kept the APKs, and the presence guard counted the
// package present. roamd now hands the agent the dormant shape in NOWHERE_APPS_DORMANT.

const (
	dormantInst = "com.example.dinst"
	dormantPass = "correct horse battery staple"
)

var dormantOD = []string{"com.example.dod1", "com.example.dod2", "com.example.dod3"}

// dormantReset clears the process-wide caches, as the carry tests' neighbours do, so a test reads its own store.
func dormantReset(t *testing.T) {
	t.Helper()
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCache = nil
	sealRefused = false
	sealRefusedWhy = ""
}

// dormantWrite writes one file, creating its directory.
func dormantWrite(t *testing.T, p, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// dormantLine is the line roamd writes for a dormant On-demand package: pkg, vc, sideloaded, mode, no APK.
func dormantLine(pkg, vc string) string { return pkg + "\t" + vc + "\t0\tondemand" }

// dormantShape writes <dir>/<pkg>/_meta/meta for each package and appends its line naming no APK to
// <dir>/manifest.tsv. With apk set it also writes <pkg>/base.apk (the deferred bytes of seal A).
func dormantShape(t *testing.T, dir, vc string, apk bool, pkgs ...string) {
	t.Helper()
	var man strings.Builder
	if b, err := os.ReadFile(filepath.Join(dir, "manifest.tsv")); err == nil {
		man.Write(b)
	}
	for _, p := range pkgs {
		dormantWrite(t, filepath.Join(dir, p, "_meta", "meta"), "vc\t"+vc+"\ncert\t"+strings.Repeat("c"+p, 40)+"\n")
		if apk {
			dormantWrite(t, filepath.Join(dir, p, "base.apk"), strings.Repeat("apk-"+p+" ", 300))
		}
		man.WriteString(dormantLine(p, vc) + "\n")
	}
	dormantWrite(t, filepath.Join(dir, "manifest.tsv"), man.String())
}

// dormantStage is an #apps stage holding the installed app (its line names base.apk) and, in the dormant shape
// with their APKs, the On-demand packages given.
func dormantStage(t *testing.T, od ...string) string {
	t.Helper()
	dir := t.TempDir()
	dormantWrite(t, filepath.Join(dir, dormantInst, "base.apk"), strings.Repeat("apk-inst ", 300))
	dormantWrite(t, filepath.Join(dir, "manifest.tsv"), dormantInst+"\t7\t0\tinstalled\tbase.apk\n")
	if len(od) > 0 {
		dormantShape(t, dir, "1", true, od...)
	}
	return dir
}

// dormantDeferList points NOWHERE_DEFER_LIST at a list naming each package's base.apk, as roamd's push does.
func dormantDeferList(t *testing.T, pkgs ...string) {
	t.Helper()
	var b strings.Builder
	for _, p := range pkgs {
		b.WriteString(p + "/base.apk\n")
	}
	p := filepath.Join(t.TempDir(), "defer")
	dormantWrite(t, p, b.String())
	t.Setenv("NOWHERE_DEFER_LIST", p)
}

// dormantSeal runs one #apps push with roamd's push-line env and returns its stdout and whether it was refused.
func dormantSeal(t *testing.T, base, name, src string, carry bool, dormant string, deferred ...string) (string, bool) {
	t.Helper()
	ce := "0"
	if carry {
		ce = "1"
	}
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", ce)
	t.Setenv("NOWHERE_CARRY_DEFERRED", "1")
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_APPS_DORMANT", dormant)
	dormantDeferList(t, deferred...)
	sealRefused = false
	sealRefusedWhy = ""
	out := captureStdout(t, func() { pushProfile(base, name+"#apps", dormantPass, src) })
	return out, sealRefused
}

// dormantIndexless seals head A with the carry OFF: the installed app and the On-demand packages in the dormant
// shape, their APKs deferred. The head has no Apps index, measured _meta bytes and the deferred APKs.
func dormantIndexless(t *testing.T, base, name string, od ...string) chunkManifest {
	t.Helper()
	dormantReset(t)
	createVault(base, name, dormantPass)
	if out, refused := dormantSeal(t, base, name, dormantStage(t, od...), false, "", od...); refused {
		t.Fatalf("fixture: seal A was refused:\n%s", out)
	}
	m := headManifestOf(t, base, name+"#apps", dormantPass)
	if len(m.Apps) != 0 {
		t.Fatalf("fixture: a carry-off head has an app index: %v", m.Apps)
	}
	for _, p := range od {
		if _, ok := m.Deferred[p+"/base.apk"]; !ok {
			t.Fatalf("fixture: seal A did not defer %s/base.apk", p)
		}
		if m.Pkg[p] <= 0 {
			t.Fatalf("fixture: seal A measured no bytes for %s (Pkg %v)", p, m.Pkg)
		}
	}
	return m
}

// dormantSide is the side directory roamd writes: each package's dir, _meta and a line naming no APK.
func dormantSide(t *testing.T, vc string, pkgs ...string) string {
	t.Helper()
	dir := t.TempDir()
	dormantShape(t, dir, vc, false, pkgs...)
	return dir
}

func dormantHeadJSON(t *testing.T, m chunkManifest) string {
	t.Helper()
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// dormantD1 is D1's two seals; D2 continues from it.
func dormantD1(t *testing.T, base, name string) chunkManifest {
	t.Helper()
	dormantIndexless(t, base, name, dormantOD...)
	out, refused := dormantSeal(t, base, name, dormantStage(t), true, dormantSide(t, "1", dormantOD...))
	if refused {
		t.Fatalf("seal B over an index-less head was refused (%s):\n%s", sealRefusedWhy, out)
	}
	if !strings.Contains(out, "adopted 3 dormant package(s) the stored app index does not name") {
		t.Fatalf("seal B did not report adopting the three dormant packages:\n%s", out)
	}
	m := headManifestOf(t, base, name+"#apps", dormantPass)
	for _, p := range append([]string{dormantInst}, dormantOD...) {
		if m.Apps[p] == "" {
			t.Fatalf("the new head's app index does not name %s -- the next sign-in raises no placeholder for it: %v", p, m.Apps)
		}
	}
	for _, p := range dormantOD {
		if m.Apps[p] != dormantLine(p, "1") {
			t.Fatalf("%s's line is %q, want the dormant line naming no APK", p, m.Apps[p])
		}
		if _, ok := m.Ess[p+"/_meta/meta"]; !ok {
			t.Fatalf("the new head's essential tree does not hold %s/_meta/meta", p)
		}
		if _, ok := m.Deferred[p+"/base.apk"]; !ok {
			t.Fatalf("the new head lost %s's deferred APK", p)
		}
	}
	return m
}

// TestDormantD1AdoptsOverAnIndexlessHead: the first carry-on seal over an index-less head keeps every untapped
// On-demand app's line, _meta and APK.
func TestDormantD1AdoptsOverAnIndexlessHead(t *testing.T) {
	dormantD1(t, newHTTPStore(t), "dormantd1")
}

// TestDormantD2IndexCarriesOnceItExists: once a head has the index, the index carries the packages and the
// dormant copy is not adopted.
func TestDormantD2IndexCarriesOnceItExists(t *testing.T) {
	base := newHTTPStore(t)
	const name = "dormantd2"
	first := dormantD1(t, base, name)
	side := dormantSide(t, "1", dormantOD...)
	out, refused := dormantSeal(t, base, name, dormantStage(t), true, side)
	if refused {
		t.Fatalf("the third seal was refused (%s):\n%s", sealRefusedWhy, out)
	}
	if !strings.Contains(out, "carrying 3 package(s) this handset did not stage") {
		t.Fatalf("the index did not carry the three packages:\n%s", out)
	}
	if strings.Contains(out, "adopted") {
		t.Fatalf("a dormant copy was adopted over an index that names it:\n%s", out)
	}
	second := headManifestOf(t, base, name+"#apps", dormantPass)
	if dormantHeadJSON(t, chunkManifest{Apps: second.Apps}) != dormantHeadJSON(t, chunkManifest{Apps: first.Apps}) {
		t.Fatalf("the app index changed:\n got %v\nwant %v", second.Apps, first.Apps)
	}
	for _, p := range dormantOD {
		if _, err := os.Stat(filepath.Join(side, p)); err != nil {
			t.Fatalf("the dormant copy of %s was moved: %v", p, err)
		}
	}
}

// TestDormantD3DropListIsNotAdopted: a package the drop list deletes is not adopted and does not refuse the seal.
func TestDormantD3DropListIsNotAdopted(t *testing.T) {
	base := newHTTPStore(t)
	const name = "dormantd3"
	od := []string{"com.example.dod1", "com.example.dod3"}
	dormantIndexless(t, base, name, od...)
	dl := filepath.Join(t.TempDir(), "drop.list")
	dormantWrite(t, dl, "com.example.dod3\n")
	t.Setenv("NOWHERE_DROP_LIST", dl)
	side := dormantSide(t, "1", od...)
	out, refused := dormantSeal(t, base, name, dormantStage(t), true, side)
	if refused {
		t.Fatalf("a dropped dormant package refused the seal (%s):\n%s", sealRefusedWhy, out)
	}
	if !strings.Contains(out, "adopted 1 dormant package(s)") {
		t.Fatalf("want exactly the kept package adopted:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(side, "com.example.dod3")); err != nil {
		t.Fatalf("the dropped package's dormant copy was moved into the stage: %v", err)
	}
	if _, err := os.Stat(filepath.Join(side, "com.example.dod1")); err == nil {
		t.Fatal("the kept package's dormant copy was not adopted")
	}
	m := headManifestOf(t, base, name+"#apps", dormantPass)
	if m.Apps[dormantInst] == "" || m.Apps["com.example.dod1"] == "" {
		t.Fatalf("the new index lost a kept package: %v", m.Apps)
	}
	if _, ok := m.Apps["com.example.dod3"]; ok {
		t.Fatalf("the new index names the dropped package: %v", m.Apps)
	}
}

// TestDormantD4IndexlessHeadWithoutDormantIsRefused: the defect without the dormant copy. The deferred carry
// keeps the APKs, so the package counts present, but its line is gone: the seal must refuse, not land.
func TestDormantD4IndexlessHeadWithoutDormantIsRefused(t *testing.T) {
	base := newHTTPStore(t)
	const name = "dormantd4"
	before := dormantIndexless(t, base, name, dormantOD...)
	out, refused := dormantSeal(t, base, name, dormantStage(t), true, "")
	if !refused || sealRefusedWhy != "apps-vanished" {
		t.Fatalf("a seal that keeps three packages' deferred bytes but drops their lines was not refused "+
			"apps-vanished (refused %v, why %q) -- every later seal keeps them lost:\n%s", refused, sealRefusedWhy, out)
	}
	if !strings.Contains(out, "3 package(s) keep their deferred bytes in this seal but lost their app-index line") {
		t.Fatalf("the refusal does not say the line was lost:\n%s", out)
	}
	for _, p := range dormantOD {
		if strings.Contains(out, p) {
			t.Fatalf("the refusal names a package (%s); roam.log outlives every wipe:\n%s", p, out)
		}
	}
	after := headManifestOf(t, base, name+"#apps", dormantPass)
	if dormantHeadJSON(t, after) != dormantHeadJSON(t, before) {
		t.Fatal("the refused seal changed the stored head")
	}
	sealRefused, sealRefusedWhy = false, ""
}

// TestDormantD5StoredLineWins: a stored index that names the package carries its own line; a dormant copy with
// another version is not adopted over it (NWP-20261119-02: a _meta never rides beside bytes it does not describe).
func TestDormantD5StoredLineWins(t *testing.T) {
	base := newHTTPStore(t)
	const name = "dormantd5"
	dormantReset(t)
	createVault(base, name, dormantPass)
	const pkg = "com.example.dod1"
	if out, refused := dormantSeal(t, base, name, dormantStage(t, pkg), true, "", pkg); refused {
		t.Fatalf("fixture: the indexed seal was refused:\n%s", out)
	}
	stored := headManifestOf(t, base, name+"#apps", dormantPass).Apps[pkg]
	if stored != dormantLine(pkg, "1") {
		t.Fatalf("fixture: the stored line is %q", stored)
	}
	out, refused := dormantSeal(t, base, name, dormantStage(t), true, dormantSide(t, "2", pkg))
	if refused {
		t.Fatalf("the seal was refused (%s):\n%s", sealRefusedWhy, out)
	}
	if got := headManifestOf(t, base, name+"#apps", dormantPass).Apps[pkg]; got != stored {
		t.Fatalf("the new index line is %q, want the stored line %q byte for byte", got, stored)
	}
}
