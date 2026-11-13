package main

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
)

// NWP-20261130-03: the sign-in skip of parked packages' spans and the per-package fetch (unfetched_fetch.go), and the
// seal's exclusion of a listed package's empty skeleton. test-unfetched-fetch.sh --mutate convicts a broken copy of each.

const (
	ufOD   = "com.example.od"   // On-demand, stored in the hold shape
	ufAuto = "com.example.auto" // Auto, stored in the canonical shape
	ufBoth = "com.example.both" // On-demand, stored in BOTH shapes (the hold and a canonical beside it)
	ufInst = "com.example.inst" // installed: never skipped
	ufShip = "com.example.ship" // On-demand but the image ships it: never skipped
)

func ufKeep() []byte {
	return []byte(ufOD + "\tondemand\n" + ufAuto + "\tauto\n" + ufBoth + "\tondemand\n" + ufInst + "\n" + ufShip + "\tondemand\n")
}

func ufFiles() map[string][]byte {
	return map[string][]byte{
		chooserPkg + "/files/nowhere-appkeep":  ufKeep(),
		chooserPkg + "/shared_prefs/own.xml":   []byte(strings.Repeat("chooser-own ", 200)),
		psHold(ufOD) + "/shared_prefs/od.xml":  []byte(strings.Repeat("od-prefs ", 500)),
		psHold(ufOD) + "/files/big.bin":        ucRand(1130, 1<<20),
		ufAuto + "/databases/auto.db":          []byte(strings.Repeat("auto-db ", 600)),
		psHold(ufBoth) + "/shared_prefs/b.xml": []byte(strings.Repeat("both-held-old ", 300)),
		psHold(ufBoth) + "/files/only-held":    []byte(strings.Repeat("only-in-hold ", 300)),
		ufBoth + "/shared_prefs/b.xml":         []byte(strings.Repeat("both-canon-new ", 300)),
		ufInst + "/shared_prefs/inst.xml":      []byte(strings.Repeat("installed ", 500)),
		ufShip + "/shared_prefs/ship.xml":      []byte(strings.Repeat("shipped ", 500)),
	}
}

// ufExpectHold is what hold_ondemand parks for pkg from a full restore: the canonical laid over the hold.
func ufExpectHold(files map[string][]byte, pkg string) map[string][]byte {
	out := map[string][]byte{}
	for rel, b := range files {
		if r, ok := strings.CutPrefix(rel, psHold(pkg)+"/"); ok {
			if _, dup := out[r]; !dup {
				out[r] = b
			}
		}
	}
	for rel, b := range files {
		if r, ok := strings.CutPrefix(rel, pkg+"/"); ok {
			out[r] = b
		}
	}
	return out
}

type ufEnv struct {
	base, scope, dir, dest string
}

// ufSkipRestore seals files into a fresh store as scope, then restores its head with the skip on, as roamd's sign-in
// does: the odfetch dir with both lists empty, the keep file the restore itself writes, a shipped list.
func ufSkipRestore(t *testing.T, scope string, files map[string][]byte) (ufEnv, int, string) {
	t.Helper()
	base, m, _ := psSeal(t, scope, files)
	return ufRestoreHead(t, base, scope, m)
}

// ufRestoreHead is ufSkipRestore's restore of an already sealed head m.
func ufRestoreHead(t *testing.T, base, scope string, m chunkManifest) (ufEnv, int, string) {
	t.Helper()
	if len(m.PkgSpan) == 0 {
		t.Fatalf("fixture: the %s head has no span index", scope)
	}
	dir := t.TempDir()
	for _, f := range []string{odUnfetchedCE, odUnfetchedDE} {
		if err := os.WriteFile(filepath.Join(dir, f), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "shipped"), []byte(ufShip+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	sc, _ := odScopeOf(scope)
	list, _ := odScopeFiles(dir, sc)
	t.Setenv("NOWHERE_PARK_KEEP", filepath.Join(dest, chooserPkg, "files", "nowhere-appkeep"))
	t.Setenv("NOWHERE_PARK_SHIPPED", filepath.Join(dir, "shipped"))
	t.Setenv("NOWHERE_UNFETCHED_LIST", list)
	key, _, ok := resolveKey(base, scope, unfPass)
	if !ok {
		t.Fatalf("no %s head", scope)
	}
	var skipped int
	out := captureStdout(t, func() { skipped = restoreSkippingParked(base, key, scope, m, dest) })
	return ufEnv{base, scope, dir, dest}, skipped, out
}

func ufReadList(t *testing.T, path string) map[string]bool {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return parseUnfetched(b)
}

func ufHas(got map[string][]byte, prefix string) bool {
	for rel := range got {
		if strings.HasPrefix(rel, prefix) {
			return true
		}
	}
	return false
}

func TestUnfetchedRestore_SkipsParkedSpans(t *testing.T) {
	files := ufFiles()
	e, skipped, out := ufSkipRestore(t, "ufskip", files)
	if skipped != 0 {
		t.Errorf("the skip restore skipped %d tar entries, want 0", skipped)
	}
	got := psRegularFiles(t, e.dest)
	for _, p := range []string{ufOD, ufAuto, ufBoth} {
		if ufHas(got, p+"/") || ufHas(got, psHold(p)+"/") {
			t.Errorf("parked package %s was restored at sign-in", p)
		}
	}
	for _, rel := range []string{chooserPkg + "/files/nowhere-appkeep", chooserPkg + "/shared_prefs/own.xml",
		ufInst + "/shared_prefs/inst.xml", ufShip + "/shared_prefs/ship.xml"} {
		if !bytes.Equal(got[rel], files[rel]) {
			t.Errorf("%s was not restored byte for byte", rel)
		}
	}
	ce := ufReadList(t, filepath.Join(e.dir, odUnfetchedCE))
	if len(ce) != 3 || !ce[ufOD] || !ce[ufAuto] || !ce[ufBoth] {
		t.Errorf("unfetched.ce = %v, want exactly the three parked packages", ce)
	}
	if de := ufReadList(t, filepath.Join(e.dir, odUnfetchedDE)); len(de) != 0 {
		t.Errorf("the vault restore wrote unfetched.de: %v", de)
	}
	plan, err := readOdPlan(filepath.Join(e.dir, odPlanCE))
	if err != nil || len(plan.Pkgs) != 3 || len(plan.Pkgs[ufOD].Chunks) == 0 {
		t.Errorf("plan.ce = %+v (err %v), want the three packages' chunks", plan, err)
	}
	if !strings.Contains(out, "unfetched: 3 package(s) skipped") {
		t.Errorf("no sign-in skip line with 3 packages:\n%s", out)
	}
	for _, p := range []string{ufOD, ufAuto, ufBoth} {
		if strings.Contains(out, p) {
			t.Errorf("the restore output names package %s", p)
		}
	}
}

// Each OFF condition restores the whole head, and the restore never creates a missing list.
func TestUnfetchedRestore_OffRestoresAll(t *testing.T) {
	cases := []struct {
		name string
		set  func(t *testing.T, dir string)
	}{
		{"nokeep", func(t *testing.T, dir string) { t.Setenv("NOWHERE_PARK_KEEP", "") }},
		{"listmissing", func(t *testing.T, dir string) {
			os.Remove(filepath.Join(dir, odUnfetchedCE))
		}},
		{"otherscope", func(t *testing.T, dir string) {
			t.Setenv("NOWHERE_UNFETCHED_LIST", filepath.Join(dir, odUnfetchedDE))
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			files := ufFiles()
			scope := "ufoff" + c.name
			base, m, _ := psSeal(t, scope, files)
			dir := t.TempDir()
			for _, f := range []string{odUnfetchedCE, odUnfetchedDE, "shipped"} {
				os.WriteFile(filepath.Join(dir, f), nil, 0o600)
			}
			dest := t.TempDir()
			t.Setenv("NOWHERE_PARK_KEEP", filepath.Join(dest, chooserPkg, "files", "nowhere-appkeep"))
			t.Setenv("NOWHERE_PARK_SHIPPED", filepath.Join(dir, "shipped"))
			t.Setenv("NOWHERE_UNFETCHED_LIST", filepath.Join(dir, odUnfetchedCE))
			c.set(t, dir)
			key, _, _ := resolveKey(base, scope, unfPass)
			captureStdout(t, func() { restoreSkippingParked(base, key, scope, m, dest) })
			got := psRegularFiles(t, dest)
			for rel, b := range files {
				if !bytes.Equal(got[rel], b) {
					t.Errorf("%s: %s was not restored", c.name, rel)
				}
			}
			if c.name == "listmissing" {
				if _, err := os.Stat(filepath.Join(dir, odUnfetchedCE)); err == nil {
					t.Errorf("the restore created the missing list")
				}
			}
		})
	}
}

// A package fetched after the skip is byte-equal, in content and mode, to what hold_ondemand parks from a full restore.
func TestFetchOdData_RoundTripByteEqual(t *testing.T) {
	for _, scope := range []string{"ufrt", "ufrt#de"} {
		t.Run(strings.ReplaceAll(scope, "#", "_"), func(t *testing.T) {
			files := ufFiles()
			e, _, _ := ufSkipRestore(t, scope, files)
			name := strings.SplitN(scope, "#", 2)[0]
			ceRoot, deRoot := e.dest, t.TempDir()
			if strings.HasSuffix(scope, "#de") {
				ceRoot, deRoot = t.TempDir(), e.dest
			}
			for _, p := range []string{ufOD, ufAuto, ufBoth} {
				var ceB, deB int64
				var fetched bool
				var err error
				captureStdout(t, func() { ceB, deB, fetched, err = fetchOdData(e.base, name, unfPass, p, ceRoot, deRoot, e.dir) })
				if err != nil || !fetched || ceB+deB <= 0 {
					t.Fatalf("%s: fetch = (%d, %d, %v, %v)", p, ceB, deB, fetched, err)
				}
				hold := filepath.Join(e.dest, chooserPkg, odHoldDirName, p)
				got := psRegularFiles(t, hold)
				want := ufExpectHold(files, p)
				if len(got) != len(want) {
					t.Errorf("%s: the hold holds %d files, want %d", p, len(got), len(want))
				}
				for rel, b := range want {
					if !bytes.Equal(got[rel], b) {
						t.Errorf("%s: %s in the hold is not the full restore's copy", p, rel)
					}
					if fi, err := os.Stat(filepath.Join(hold, rel)); err != nil || fi.Mode().Perm() != 0o600 {
						t.Errorf("%s: %s mode is not the sealed one (%v)", p, rel, err)
					}
				}
				if _, err := os.Stat(filepath.Join(e.dest, p)); err == nil {
					t.Errorf("%s: the fetch wrote the canonical dir, not only the hold", p)
				}
			}
			if _, err := os.Stat(filepath.Join(e.dest, chooserPkg, odFetchStageName)); err == nil {
				if ents, _ := os.ReadDir(filepath.Join(e.dest, chooserPkg, odFetchStageName)); len(ents) != 0 {
					t.Errorf("the fetch left a stage behind")
				}
			}
		})
	}
}

func TestFetchOdData_ListAndPlanBookkeeping(t *testing.T) {
	files := ufFiles()
	e, _, _ := ufSkipRestore(t, "ufbook", files)
	ceList, cePlan := odScopeFiles(e.dir, "ce")
	// Placed: off the list and out of the plan; the other listed packages stay.
	captureStdout(t, func() {
		if _, _, _, err := fetchOdData(e.base, "ufbook", unfPass, ufOD, e.dest, t.TempDir(), e.dir); err != nil {
			t.Fatalf("fetch: %v", err)
		}
	})
	if l := ufReadList(t, ceList); l[ufOD] || !l[ufAuto] || !l[ufBoth] {
		t.Errorf("after the fetch unfetched.ce = %v, want it without %s only", l, ufOD)
	}
	if p, _ := readOdPlan(cePlan); p.Pkgs[ufOD].Chunks != nil || p.Pkgs[ufAuto].Chunks == nil {
		t.Errorf("after the fetch the plan still holds %s or lost %s", ufOD, ufAuto)
	}
	// A package on neither list is a no-op.
	captureStdout(t, func() {
		if _, _, fetched, err := fetchOdData(e.base, "ufbook", unfPass, ufInst, e.dest, t.TempDir(), e.dir); fetched || err != nil {
			t.Errorf("an unlisted package: fetched=%v err=%v", fetched, err)
		}
	})
	// A listed package with no plan entry is a failure, and stays listed with no stage.
	p, _ := readOdPlan(cePlan)
	delete(p.Pkgs, ufAuto)
	writeOdPlan(cePlan, p)
	captureStdout(t, func() {
		if _, _, _, err := fetchOdData(e.base, "ufbook", unfPass, ufAuto, e.dest, t.TempDir(), e.dir); err == nil {
			t.Errorf("a listed package with no plan entry was fetched")
		}
	})
	if !ufReadList(t, ceList)[ufAuto] {
		t.Errorf("a failed fetch took %s off the list", ufAuto)
	}
	// A hold already in place is NOT a placement (RF-003): without the done marker and a plan entry it is a failure,
	// and the package stays listed.
	os.MkdirAll(filepath.Join(e.dest, chooserPkg, odHoldDirName, ufAuto), 0o700)
	captureStdout(t, func() {
		if _, _, _, err := fetchOdData(e.base, "ufbook", unfPass, ufAuto, e.dest, t.TempDir(), e.dir); err == nil {
			t.Errorf("an existing hold with no plan entry counted as fetched")
		}
	})
	if !ufReadList(t, ceList)[ufAuto] {
		t.Errorf("an existing hold took %s off the list", ufAuto)
	}
}

// A list that is missing or cannot be read is unknown state: the fetch fails and reports nothing as "not unfetched",
// whichever scope is lost and whatever the other list says. Neither of these reaches the store.
func TestFetchOdData_UncertainListIsRefused(t *testing.T) {
	lost := func(t *testing.T, p string) {
		if err := os.Remove(p); err != nil {
			t.Fatal(err)
		}
	}
	unreadable := func(t *testing.T, p string) {
		lost(t, p)
		if err := os.Mkdir(p, 0o700); err != nil { // ReadFile fails on a directory for root too
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		name   string
		file   string
		damage func(*testing.T, string)
	}{
		{"ce-missing", odUnfetchedCE, lost}, {"de-missing", odUnfetchedDE, lost},
		{"ce-unreadable", odUnfetchedCE, unreadable}, {"de-unreadable", odUnfetchedDE, unreadable},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			for _, f := range []string{odUnfetchedCE, odUnfetchedDE} {
				if err := os.WriteFile(filepath.Join(dir, f), nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			c.damage(t, filepath.Join(dir, c.file))
			_, _, fetched, err := fetchOdData("http://store.invalid", "ufuncertain", unfPass, ufOD, t.TempDir(), t.TempDir(), dir)
			if err == nil {
				t.Fatalf("the fetch answered \"not unfetched\" (fetched=%v) with %s", fetched, c.name)
			}
			if fetched {
				t.Errorf("the fetch reported fetched with %s", c.name)
			}
		})
	}
}

// The CE list names the package and the DE list is lost: nothing is placed, and the CE line and plan entry stay.
func TestFetchOdData_LostDEListStopsTheCEPlacement(t *testing.T) {
	files := ufFiles()
	e, _, _ := ufSkipRestore(t, "ufdelost", files)
	ceList, cePlan := odScopeFiles(e.dir, "ce")
	if err := os.Remove(filepath.Join(e.dir, odUnfetchedDE)); err != nil {
		t.Fatal(err)
	}
	de := t.TempDir()
	var err error
	captureStdout(t, func() { _, _, _, err = fetchOdData(e.base, "ufdelost", unfPass, ufOD, e.dest, de, e.dir) })
	if err == nil {
		t.Fatal("the fetch placed CE data with the DE list lost")
	}
	if _, serr := os.Lstat(filepath.Join(e.dest, chooserPkg, odHoldDirName, ufOD)); serr == nil {
		t.Errorf("the CE hold exists after the refusal")
	}
	if !ufReadList(t, ceList)[ufOD] {
		t.Errorf("the refusal took %s off the CE list", ufOD)
	}
	if plan, perr := readOdPlan(cePlan); perr != nil || plan.Pkgs[ufOD].Bytes == 0 {
		t.Errorf("the refusal changed the CE plan: err=%v entry=%+v", perr, plan.Pkgs[ufOD])
	}
}

// The CE data came back in an earlier call and the DE list is lost after it: the DE half is unknown, so the call fails.
func TestFetchOdData_LostDEListAfterCERecovery(t *testing.T) {
	files := ufFiles()
	e, _, _ := ufSkipRestore(t, "ufdeafter", files)
	de := t.TempDir()
	captureStdout(t, func() {
		if _, _, fetched, err := fetchOdData(e.base, "ufdeafter", unfPass, ufOD, e.dest, de, e.dir); err != nil || !fetched {
			t.Fatalf("first fetch: fetched=%v err=%v", fetched, err)
		}
	})
	if err := os.Remove(filepath.Join(e.dir, odUnfetchedDE)); err != nil {
		t.Fatal(err)
	}
	var fetched bool
	var err error
	captureStdout(t, func() { _, _, fetched, err = fetchOdData(e.base, "ufdeafter", unfPass, ufOD, e.dest, de, e.dir) })
	if err == nil || fetched {
		t.Fatalf("after the CE recovery a lost DE list answered fetched=%v err=%v, want a failure", fetched, err)
	}
}

// RF-003: a hold that exists before the fetch -- hold_ondemand's move of an empty skeleton, or a partial one a killed
// overlay left -- is fetched into, the stored copy laid over it; only the done marker of a completed placement lets a
// later call finish the bookkeeping alone.
func TestFetchOdData_ExistingHoldIsNotAReceipt(t *testing.T) {
	for _, shape := range []string{"empty", "partial", "placed", "placedplangone"} {
		t.Run(shape, func(t *testing.T) {
			files := ufFiles()
			prof := "ufhold" + shape
			e, _, _ := ufSkipRestore(t, prof, files)
			ceList, cePlan := odScopeFiles(e.dir, "ce")
			hold := filepath.Join(e.dest, chooserPkg, odHoldDirName, ufOD)
			want := ufExpectHold(files, ufOD)
			switch shape {
			case "empty":
				os.MkdirAll(filepath.Join(hold, "cache"), 0o700)
			case "partial":
				os.MkdirAll(filepath.Join(hold, "shared_prefs"), 0o700)
				os.WriteFile(filepath.Join(hold, "shared_prefs", "od.xml"), []byte("half"), 0o600)
			case "placed", "placedplangone":
				// A completed placement whose bookkeeping a crash cut: the data and the marker are in place.
				plan, _ := readOdPlan(cePlan)
				for rel, b := range want {
					os.MkdirAll(filepath.Dir(filepath.Join(hold, rel)), 0o700)
					os.WriteFile(filepath.Join(hold, rel), b, 0o600)
				}
				os.WriteFile(odDonePath(e.dir, "ce", ufOD), odDoneToken(ufOD, plan.Pkgs[ufOD].Chunks), 0o600)
				if shape == "placedplangone" {
					delete(plan.Pkgs, ufOD)
					writeOdPlan(cePlan, plan)
				}
			}
			var err error
			captureStdout(t, func() { _, _, _, err = fetchOdData(e.base, prof, unfPass, ufOD, e.dest, t.TempDir(), e.dir) })
			if err != nil {
				t.Fatalf("fetch over a %s hold: %v", shape, err)
			}
			got := psRegularFiles(t, hold)
			for rel, b := range want {
				if !bytes.Equal(got[rel], b) {
					t.Errorf("%s: %s in the hold is not the stored copy", shape, rel)
				}
			}
			if _, err := os.Lstat(odDonePath(e.dir, "ce", ufOD)); err == nil {
				t.Errorf("%s: the done marker is left", shape)
			}
			for rel := range got {
				if strings.Contains(rel, "odfetch-done") || strings.HasPrefix(filepath.Base(rel), "done.") {
					t.Errorf("%s: the hold holds a marker %s", shape, rel)
				}
			}
			if ufReadList(t, ceList)[ufOD] {
				t.Errorf("%s: the package is still listed", shape)
			}
			if p, _ := readOdPlan(cePlan); p.Pkgs[ufOD].Chunks != nil {
				t.Errorf("%s: the plan still holds the package", shape)
			}
		})
	}
}

// RF-010: a failed fetch's log line holds the package, the scope, the error code and the time, and no path: a filesystem
// error repeats its paths unquoted, and roam.log's scrub leaves those, so an app's file names would outlive the session.
func TestFetchOdData_FailureLineHasNoPath(t *testing.T) {
	const secret = "private-document-title.sqlite"
	for _, c := range []struct {
		name, scope string
		arrange     func(e ufEnv, hold string)
	}{
		{name: "rename", scope: "ce: ", arrange: func(e ufEnv, hold string) {
			os.MkdirAll(hold, 0o700)
			real := odRename
			odRename = func(from, to string) error { return real(from, filepath.Join(to, "gone", "x")) }
			t.Cleanup(func() { odRename = real })
		}},
		{name: "holdfile", scope: "ce: ", arrange: func(e ufEnv, hold string) {
			os.RemoveAll(filepath.Dir(hold))
			os.WriteFile(filepath.Dir(hold), nil, 0o600)
		}},
		{name: "plandir", scope: "ce: plan unreadable: ", arrange: func(e ufEnv, hold string) {
			_, plan := odScopeFiles(e.dir, "ce")
			os.Remove(plan)
			os.Mkdir(plan, 0o700)
		}},
		{name: "listdir", scope: "de list unreadable: ", arrange: func(e ufEnv, hold string) {
			list, _ := odScopeFiles(e.dir, "de")
			os.Remove(list)
			os.Mkdir(list, 0o700)
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			files := ufFiles()
			files[psHold(ufOD)+"/databases/"+secret] = []byte(strings.Repeat("private ", 200))
			prof := "ufprivacy" + c.name
			e, _, _ := ufSkipRestore(t, prof, files)
			c.arrange(e, filepath.Join(e.dest, chooserPkg, odHoldDirName, ufOD))
			var err error
			captureStdout(t, func() { _, _, _, err = fetchOdData(e.base, prof, unfPass, ufOD, e.dest, t.TempDir(), e.dir) })
			if err == nil {
				t.Fatal("the fetch succeeded, want a failure")
			}
			line := odFetchFailedLine(ufOD, err, 7)
			if !strings.Contains(line, `"`+ufOD+`"`) || !strings.Contains(line, "("+c.scope) || !strings.Contains(line, "after 7ms") {
				t.Errorf("the line lost the package, the scope or the time: %q", line)
			}
			if strings.HasSuffix(strings.SplitN(line, " after ", 2)[0], c.scope+")") {
				t.Errorf("the line has no error code: %q", line)
			}
			scrubbed, kept := scrubIssueLine(line, nil)
			for _, l := range []string{line, scrubbed} {
				if strings.Contains(l, secret) || strings.Contains(l, "/") {
					t.Errorf("the line holds a path (kept=%v): %q", kept, l)
				}
			}
		})
	}
}

// RF-006: with receipts ON (NOWHERE_STATE), the skip restore's completion earns the #72 receipt through finishRestore,
// as the restore verb does, and that receipt admits a seal while the list still names the skipped packages; the seal
// carries each skipped package's stored span byte for byte. Without the receipt the same seal is refused.
func TestUnfetchedReceipt_AdmitsSealAfterSkip(t *testing.T) {
	files := ufFiles()
	const prof = "ufrcpt"
	base, m, _ := psSeal(t, prof, files)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	e, skipped, _ := ufRestoreHead(t, base, prof, m)
	_, _, head, ok := resolveKeyHead(base, prof, unfPass)
	if !ok {
		t.Fatal("no head")
	}
	captureStdout(t, func() { finishRestore(prof, unfPass, head, skipped) })
	ref := profileRefV2(prof, unfPass)
	if !haveRestoreReceipt(ref) {
		t.Fatalf("the skip restore (skipped=%d) earned no restore receipt", skipped)
	}
	ceList := filepath.Join(e.dir, odUnfetchedCE)
	before := headManifestOf(t, base, prof, unfPass)
	for _, p := range []string{ufOD, ufAuto, ufBoth} {
		os.MkdirAll(filepath.Join(e.dest, p, "cache"), 0o700) // installd's skeleton of an archived placeholder
	}
	t.Setenv("NOWHERE_UNFETCHED_LIST", ceList)
	refused, why, out := unfSeal(t, base, prof, e.dest)
	if refused {
		t.Fatalf("the seal with the receipt and three packages unfetched was refused (%s)\n%s", why, out)
	}
	if l := ufReadList(t, ceList); len(l) != 3 {
		t.Fatalf("the list changed under the seal: %v", l)
	}
	after := headManifestOf(t, base, prof, unfPass)
	for _, p := range []string{ufOD, ufAuto, ufBoth} {
		bc, _, _ := pkgSpanChunks(before, p)
		ac, _, ok := pkgSpanChunks(after, p)
		if !ok || strings.Join(ac, ",") != strings.Join(bc, ",") {
			t.Errorf("%s: the new head does not carry the stored span byte for byte", p)
		}
		if after.Pkg[p] != before.Pkg[p] {
			t.Errorf("%s: Pkg = %d, want the stored %d", p, after.Pkg[p], before.Pkg[p])
		}
	}
	ucRestoreIs(t, base, prof, files)
	// The receipt is what admitted it: the same session without one is refused.
	os.Remove(receiptFile(ref))
	os.WriteFile(filepath.Join(e.dest, ufInst, "shared_prefs", "inst.xml"), []byte("changed"), 0o600)
	if refused, why, _ := unfSeal(t, base, prof, e.dest); !refused || why != "no-receipt" {
		t.Errorf("a seal with no receipt: refused=%v why=%q, want refused no-receipt", refused, why)
	}
}

// RF-004: a list write that fails after the placement leaves what the next call needs to finish, and the next call
// finishes from it without a download: the plan entry and the done marker stay until the list line is off.
func TestFetchOdData_RetryAfterListWriteFailure(t *testing.T) {
	files := ufFiles()
	const prof = "ufretry"
	e, _, _ := ufSkipRestore(t, prof, files)
	ceList, cePlan := odScopeFiles(e.dir, "ce")
	block := ceList + ".tmp" // publishReceiptFile's temp: a non-empty directory there makes the list write fail
	if err := os.MkdirAll(filepath.Join(block, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	var err error
	captureStdout(t, func() { _, _, _, err = fetchOdData(e.base, prof, unfPass, ufOD, e.dest, t.TempDir(), e.dir) })
	if err == nil {
		t.Fatal("the fetch succeeded although its list could not be written")
	}
	if !ufReadList(t, ceList)[ufOD] {
		t.Fatal("the failed list write took the package off the list")
	}
	if p, _ := readOdPlan(cePlan); p.Pkgs[ufOD].Chunks == nil {
		t.Errorf("the failed list write lost the plan entry")
	}
	if _, serr := os.Lstat(odDonePath(e.dir, "ce", ufOD)); serr != nil {
		t.Errorf("the failed list write lost the done marker: %v", serr)
	}
	os.RemoveAll(block)
	// The retry finishes the bookkeeping alone: a store that cannot be reached is never asked.
	captureStdout(t, func() {
		_, _, _, err = fetchOdData("http://127.0.0.1:1", prof, unfPass, ufOD, e.dest, t.TempDir(), e.dir)
	})
	if err != nil {
		t.Fatalf("the retry after the list storage recovered: %v", err)
	}
	if ufReadList(t, ceList)[ufOD] {
		t.Errorf("the retry left the package listed")
	}
	if _, serr := os.Lstat(odDonePath(e.dir, "ce", ufOD)); serr == nil {
		t.Errorf("the retry left the done marker")
	}
	hold := filepath.Join(e.dest, chooserPkg, odHoldDirName, ufOD)
	got := psRegularFiles(t, hold)
	want := ufExpectHold(files, ufOD)
	if len(got) != len(want) {
		t.Errorf("the hold holds %d files, want %d", len(got), len(want))
	}
	for rel, b := range want {
		if !bytes.Equal(got[rel], b) {
			t.Errorf("%s in the hold is not the stored copy", rel)
		}
	}
	// A marker a crash left after the list line came off is removed by the next call, and is never in the hold.
	os.WriteFile(odDonePath(e.dir, "ce", ufOD), []byte(ufOD+"\n"), 0o600)
	captureStdout(t, func() { fetchOdData(e.base, prof, unfPass, ufOD, e.dest, t.TempDir(), e.dir) })
	if _, serr := os.Lstat(odDonePath(e.dir, "ce", ufOD)); serr == nil {
		t.Errorf("a leftover marker of an unlisted package was kept")
	}
}

// RF-005: a sign-out raised while a package's data downloads stops it between chunks: the reads after the marker are
// bounded by the download window, nothing is placed, and the package stays listed with its plan entry.
func TestFetchOdData_SignOutStopsTheDownload(t *testing.T) {
	files := ufFiles()
	files[psHold(ufOD)+"/files/big.bin"] = ucRand(1132, 12<<20)
	const prof = "ufcancel"
	e, _, _ := ufSkipRestore(t, prof, files)
	ceList, cePlan := odScopeFiles(e.dir, "ce")
	plan, _ := readOdPlan(cePlan)
	n := len(plan.Pkgs[ufOD].Chunks)
	if n < 8 {
		t.Fatalf("fixture: the span has %d chunks, want at least 8", n)
	}
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", "1")
	var gets atomic.Int64
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/blob/") {
			gets.Add(1)
		}
		resp, err := http.Get(e.base + r.URL.Path)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}))
	defer proxy.Close()
	marker := filepath.Join(t.TempDir(), "od-cancel")
	t.Setenv("NOWHERE_OD_CANCEL", marker)
	var asks, atMarker int
	prev := odFetchCancelled
	t.Cleanup(func() { odFetchCancelled = prev })
	odFetchCancelled = func() bool {
		asks++
		if asks == 3 { // 1: before the scope, 2: before chunk 0 is written, 3: before chunk 1
			os.WriteFile(marker, nil, 0o600)
			atMarker = int(gets.Load())
		}
		return odCancelRequested()
	}
	var err error
	captureStdout(t, func() { _, _, _, err = fetchOdData(proxy.URL, prof, unfPass, ufOD, e.dest, t.TempDir(), e.dir) })
	if !errors.Is(err, errOdFetchCancelled) {
		t.Fatalf("the fetch with the sign-out raised mid-download: err=%v, want cancelled", err)
	}
	if asks != 3 {
		t.Errorf("the download asked %d times, want 3: it went on after the marker", asks)
	}
	if after := int(gets.Load()) - atMarker; after > 2 {
		t.Errorf("%d chunk reads after the marker, want at most the 1-wide window (2)", after)
	}
	if !ufReadList(t, ceList)[ufOD] {
		t.Errorf("the cancelled fetch took the package off the list")
	}
	if p, _ := readOdPlan(cePlan); p.Pkgs[ufOD].Chunks == nil {
		t.Errorf("the cancelled fetch lost the plan entry")
	}
	if _, serr := os.Lstat(filepath.Join(e.dest, chooserPkg, odHoldDirName, ufOD)); serr == nil {
		t.Errorf("the cancelled fetch placed a hold")
	}
	if _, serr := os.Lstat(filepath.Join(e.dest, chooserPkg, odFetchStageName, ufOD)); serr == nil {
		t.Errorf("the cancelled fetch left its stage")
	}
}

// A listed package's directory is not walked, whatever it holds: an empty skeleton (a bare <pkg>/ dir, or an empty hold
// dir), or fresh files an app wrote before its fetch (RF-002), a small package beside a large profile included. Without
// the exclusion the seal names the package as present -- empty, or with the fresh copy -- in place of its stored span.
func TestUnfetchedWalk_ExcludesListed(t *testing.T) {
	for _, shape := range []string{"bare", "hold", "freshbare", "freshhold"} {
		t.Run(shape, func(t *testing.T) {
			scope := "ufwalk" + shape
			big := map[string][]byte{ucA + "/files/large.bin": ucRand(1131, 8<<20)}
			all := ucUnion(ucAFiles(), big, ucBFiles(1024))
			base := ucFirstSeal(t, scope, all)
			src := psWrite(t, ucUnion(ucAFiles(), big))
			skel := filepath.Join(src, ucB)
			if strings.HasSuffix(shape, "hold") {
				skel = filepath.Join(src, psHold(ucB))
			}
			if err := os.MkdirAll(skel, 0o700); err != nil {
				t.Fatal(err)
			}
			if strings.HasPrefix(shape, "fresh") {
				if err := os.WriteFile(filepath.Join(skel, "fresh.xml"), []byte("first run"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("NOWHERE_UNFETCHED_LIST", unfList(t, ucB))
			refused, why, out := unfSeal(t, base, scope, src)
			if refused {
				t.Fatalf("the seal with an empty skeleton of a listed package was refused (%s)\n%s", why, out)
			}
			ucLine(t, out, "1 package(s) carried by span, 0 left to the guard")
			ucRestoreIs(t, base, scope, all)
		})
	}
}

// A fetch stage a killed fetch left is in no head.
func TestSealSkipsOdFetchStage(t *testing.T) {
	files := ucUnion(ucAFiles(), map[string][]byte{chooserPkg + "/" + odFetchStageName + "/" + ucB + "/" + ucB + "/x": []byte("stage")})
	base, m, _ := psSeal(t, "ufstage", files)
	key, _, _ := resolveKey(base, "ufstage", unfPass)
	if ufHas(psRegularFiles(t, restoreEssential(t, base, key, m)), chooserPkg+"/"+odFetchStageName) {
		t.Errorf("the seal carried the fetch stage")
	}
}

// roamd's od_unf_path names the same two list files as the agent.
func TestOdListNamesMatchRoamd(t *testing.T) {
	b, err := os.ReadFile("../vendor-common/bin/nowhere_roamd.sh")
	if err != nil {
		t.Fatal(err)
	}
	fn := regexp.MustCompile(`(?s)\nod_unf_path\(\) \{\n(.*?)\n\}`).FindSubmatch(b)
	if fn == nil {
		t.Fatal("no od_unf_path in nowhere_roamd.sh")
	}
	body := string(fn[1])
	if !strings.Contains(body, `"$STATE/odfetch.$1/unfetched.$2"`) || !strings.Contains(body, "ce|de)") {
		t.Errorf("od_unf_path does not print $STATE/odfetch.<uid>/unfetched.<ce|de>:\n%s", body)
	}
	if odUnfetchedCE != "unfetched.ce" || odUnfetchedDE != "unfetched.de" {
		t.Errorf("the agent's list names drifted from roamd's: %s %s", odUnfetchedCE, odUnfetchedDE)
	}
}
