package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The #apps presence guard under a DELIBERATE shrink-intent marker (backlog: "Switching any app Off lets that
// logoff's #apps seal drop another signed-in handset's apps without the presence guard's refusal"). Every
// storage-clearing action arms a deliberate marker, and the marker used to excuse the whole scope, so an Off of
// one app let the seal drop a kept app this handset never received. roamd hands the push the live keep-set as
// NOWHERE_KEEP_LIST; a deliberate marker now excuses only a package that file no longer names.

const (
	kgMine  = "com.example.mine"
	kgOther = "com.example.other"
)

// kgFile writes a list file inside the test's own temp dir and returns its path.
func kgFile(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// kgSeed seals the first #apps head (mine + other) and arms a marker for the second seal.
func kgSeed(t *testing.T, name string, inferred []string) (base, pass string) {
	t.Helper()
	base = newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_KEEP_LIST", "") // registers the restore; the variable itself is removed next
	os.Unsetenv("NOWHERE_KEEP_LIST")
	t.Setenv("NOWHERE_DROP_LIST", "")
	pass = "correct horse battery staple"
	createVault(base, name, pass)
	if sealApps(t, base, name, pass, stageApps(t, kgMine, kgOther)) {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	if inferred != nil {
		markShrinkIntentInferred(profileRefV2(name+"#apps", pass), inferred)
	} else {
		markShrinkIntent(profileRefV2(name+"#apps", pass))
	}
	return base, pass
}

func kgHeadHas(t *testing.T, base, name, pass, pkg string) bool {
	t.Helper()
	m := headManifestOf(t, base, name+"#apps", pass)
	return pkgPresenceSet(m.Pkg, nil)[pkg]
}

func TestAppsGuardKeepset_K1StillKeptPackageIsRefusedUnderADeliberateMarker(t *testing.T) {
	const name = "kgkeptrefused"
	base, pass := kgSeed(t, name, nil)
	t.Setenv("NOWHERE_KEEP_LIST", kgFile(t, "keep.list", kgMine+"\tinstalled\n"+kgOther+"\tinstalled\n"))
	if !sealApps(t, base, name, pass, stageApps(t, kgMine)) {
		t.Fatal("a deliberate marker excused a package the live keep-set still names -- this handset never " +
			"received it, so sealing drops its code from the account")
	}
	if !kgHeadHas(t, base, name, pass, kgOther) {
		t.Fatal("the refused seal moved the head: com.example.other is gone from it")
	}
}

func TestAppsGuardKeepset_K2AnOffStillSticks(t *testing.T) {
	const name = "kgoffsticks"
	base, pass := kgSeed(t, name, nil)
	t.Setenv("NOWHERE_KEEP_LIST", kgFile(t, "keep.list", kgMine+"\tinstalled\n"))
	if sealApps(t, base, name, pass, stageApps(t, kgMine)) {
		t.Fatal("a package the user switched Off (no longer in the keep-set) was refused")
	}
	if kgHeadHas(t, base, name, pass, kgOther) {
		t.Fatal("the Off did not leave the store: com.example.other is still in the head")
	}
}

func TestAppsGuardKeepset_K3EmptyKeepSetAllowsAnEmptyStage(t *testing.T) {
	const name = "kgemptykeep"
	base, pass := kgSeed(t, name, nil)
	t.Setenv("NOWHERE_KEEP_LIST", kgFile(t, "keep.list", ""))
	if sealApps(t, base, name, pass, stageApps(t)) {
		t.Fatal("an existing EMPTY keep-set with an empty stage was refused -- the user switched every app Off")
	}
}

func TestAppsGuardKeepset_K4UnreadableKeepSetExcusesNothing(t *testing.T) {
	const name = "kgunreadable"
	base, pass := kgSeed(t, name, nil)
	t.Setenv("NOWHERE_KEEP_LIST", filepath.Join(t.TempDir(), "missing.list"))
	if !sealApps(t, base, name, pass, stageApps(t, kgMine)) {
		t.Fatal("a deliberate marker excused a vanished package while the keep-set could not be read")
	}
}

func TestAppsGuardKeepset_K5UnsetKeepListKeepsTheWholeScopeExcuse(t *testing.T) {
	const name = "kgunset"
	base, pass := kgSeed(t, name, nil)
	if sealApps(t, base, name, pass, stageApps(t, kgMine)) {
		t.Fatal("with NOWHERE_KEEP_LIST unset a deliberate marker no longer speaks for the whole scope")
	}
}

func TestAppsGuardKeepset_K5bEmptyKeepListPathExcusesNothing(t *testing.T) {
	const name = "kgemptypath"
	base, pass := kgSeed(t, name, nil)
	t.Setenv("NOWHERE_KEEP_LIST", "")
	if !sealApps(t, base, name, pass, stageApps(t, kgMine)) {
		t.Fatal("NOWHERE_KEEP_LIST set to an empty path was treated as unset")
	}
}

func TestAppsGuardKeepset_K6DropListCannotLaunderAKeptPackage(t *testing.T) {
	const name = "kgdroplaunder"
	base, pass := kgSeed(t, name, nil)
	t.Setenv("NOWHERE_KEEP_LIST", kgFile(t, "keep.list", kgMine+"\tinstalled\n"+kgOther+"\tinstalled\n"))
	t.Setenv("NOWHERE_DROP_LIST", kgFile(t, "drop.list", kgOther+"\n"))
	out := captureStdout(t, func() {
		if !sealApps(t, base, name, pass, stageApps(t, kgMine)) {
			t.Error("a kept package named in the drop list was excused -- the drop list must never launder a kept app")
		}
	})
	if !strings.Contains(out, "SEAL REFUSED") || !strings.Contains(out, kgOther) {
		t.Fatalf("the refusal does not name the package: %q", out)
	}
}

func TestAppsGuardKeepset_K7DropChannelStillWorksForAnUnkeptPackage(t *testing.T) {
	const name = "kgdropunkept"
	base, pass := kgSeed(t, name, nil)
	t.Setenv("NOWHERE_KEEP_LIST", kgFile(t, "keep.list", kgMine+"\tinstalled\n"))
	t.Setenv("NOWHERE_DROP_LIST", kgFile(t, "drop.list", kgOther+"\n"))
	if sealApps(t, base, name, pass, stageApps(t, kgMine)) {
		t.Fatal("an un-kept package in the drop list was refused")
	}
}

func TestAppsGuardKeepset_KInferredMarkerStillExcusesWhatItNamed(t *testing.T) {
	const name = "kginferred"
	base, pass := kgSeed(t, name, []string{kgOther})
	t.Setenv("NOWHERE_KEEP_LIST", kgFile(t, "keep.list", kgMine+"\tinstalled\n"+kgOther+"\tinstalled\n"))
	if sealApps(t, base, name, pass, stageApps(t, kgMine)) {
		t.Fatal("an inferred marker no longer excuses the package it named while the keep-set names it")
	}
}
