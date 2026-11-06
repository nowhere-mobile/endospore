package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260906-15 (#91 slice 5c, the detection half). roamd builds the #apps stage from the KEEP-SET, and
// `live_code_dir` returns empty for a kept app THIS handset never received -- which appcode_seal silently
// skips. So a second phone signed into the same account seals an #apps head missing an app the first phone
// installed, the bytes lose their lease, and store GC reaps them: gone from the ACCOUNT.
//
// Neither neighbouring guard can see it (roamd's all-or-nothing needs staged==0; the shrink net needs a 5x
// collapse), and the stale-publish guard cannot either -- it only fires when the head moves DURING a seal,
// and this loss is sequential.
//
// These tests drive the REAL pushProfile twice against a real store: seal a stage with two packages, then
// seal one with a single package, which is exactly the shape the second handset produces.

// stageApps writes an #apps stage: manifest.tsv at the root, then <pkg>/base.apk per package.
func stageApps(t *testing.T, pkgs ...string) string {
	t.Helper()
	dir := t.TempDir()
	var man strings.Builder
	for _, p := range pkgs {
		if err := os.MkdirAll(filepath.Join(dir, p), 0o700); err != nil {
			t.Fatal(err)
		}
		// >= sealFileThreshold would be file-aligned; small is fine here -- attributePkgBytes still attributes
		// a grouped span pro rata, which is what populates Pkg and therefore arms this guard.
		body := strings.Repeat("apk-"+p+" ", 200)
		if err := os.WriteFile(filepath.Join(dir, p, "base.apk"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		man.WriteString(p + "\t0\t0\tinstalled\tbase.apk\n")
	}
	if err := os.WriteFile(filepath.Join(dir, "manifest.tsv"), []byte(man.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// headManifestOf reads back the sealed manifest at a scope head, the same way app_code_test.go does.
func headManifestOf(t *testing.T, base, scope, pass string) chunkManifest {
	t.Helper()
	key, mb, ok := resolveKey(base, scope, pass)
	if !ok {
		t.Fatalf("no %s head", scope)
	}
	var m chunkManifest
	if err := json.Unmarshal(unseal(key, mb)[len(cdcMagic):], &m); err != nil {
		t.Fatalf("manifest parse: %v", err)
	}
	return m
}

// sealApps runs one #apps push and reports whether a guard refused it.
func sealApps(t *testing.T, base, name, pass, src string) bool {
	t.Helper()
	sealRefused = false
	pushProfile(base, name+"#apps", pass, src)
	return sealRefused
}

// TestAppsSealRefusesAPackageThatVanishedUnexplained is the defect: the second handset stages 1 of 2.
func TestAppsSealRefusesAPackageThatVanishedUnexplained(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "presguard", "correct horse battery staple"
	createVault(base, name, pass)

	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.aegis")); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep")); !refused {
		t.Fatal("a seal that drops a package the stored head carries was ACCEPTED -- the other handset's app " +
			"loses its lease and store GC reaps it, so it is gone from the account, not just from this phone")
	}
}

// TestAppsSealAllowsADeliberatelyDroppedPackage: the drop list is a declaration, and the #204 carry already
// treats it as one ("a deliberate exclusion is a deletion"). A guard that refused these would block the one
// action the Your-apps screen offers.
func TestAppsSealAllowsADeliberatelyDroppedPackage(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "presdrop", "correct horse battery staple"
	createVault(base, name, pass)

	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone")); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	dl := filepath.Join(t.TempDir(), "drop.list")
	if err := os.WriteFile(dl, []byte("com.example.gone\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", dl)
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep")); refused {
		t.Fatal("a seal that drops a package the user DELIBERATELY removed was refused -- the drop list is the " +
			"deliberate-deletion channel, and refusing it would make an uninstall unsealable")
	}
}

// TestPresenceGuardIsAppsScopeOnly. Everywhere else the walk sees the live tree, so absent means absent, and
// arming this fleet-wide would refuse legitimate seals of ordinary app data.
func TestPresenceGuardIsAppsScopeOnly(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "presscope", "correct horse battery staple"
	createVault(base, name, pass)

	sealRefused = false
	pushProfile(base, name, pass, stageApps(t, "com.example.a", "com.example.b"))
	if sealRefused {
		t.Fatal("fixture: the first bare-scope seal was refused")
	}
	sealRefused = false
	pushProfile(base, name, pass, stageApps(t, "com.example.a"))
	if sealRefused {
		t.Fatal("the presence guard fired on the BARE scope -- there the walk sees the live tree, so a missing " +
			"package is genuinely missing and this would refuse ordinary logoffs across the fleet")
	}
}

// TestPresenceGuardInertWithoutAPkgIndex: an empty Pkg index means NOT MEASURED, never "no packages" -- the
// rule shrinkIntentAllowed already states for itself. A pre-DIA-20260805-11 head must not be read as a total
// package loss and refuse every seal after an upgrade.
func TestPresenceGuardInertWithoutAPkgIndex(t *testing.T) {
	if got := pkgPresenceSet(nil, nil); len(got) != 0 {
		t.Fatalf("pkgPresenceSet(nil, nil) = %v, want empty", got)
	}
	// A package present ONLY as a deferred rel is present, not gone: an on-demand app's APK lives in Deferred.
	got := pkgPresenceSet(map[string]int64{"com.example.a": 10}, []string{"com.example.b/base.apk", "loose"})
	for _, want := range []string{"com.example.a", "com.example.b", "loose"} {
		if !got[want] {
			t.Fatalf("pkgPresenceSet lost %q: %v", want, got)
		}
	}
	if len(got) != 3 {
		t.Fatalf("pkgPresenceSet = %v, want exactly the three", got)
	}
}

// TestAppsSealAllowsAPackageThatMovedToTheDeferredTier. An app switched to on-demand has its APK staged into
// Deferred instead of the essential region, so it leaves Pkg while remaining fully present. Refusing that
// would make the Your-apps mode toggle unsealable.
func TestAppsSealAllowsAPackageThatMovedToTheDeferredTier(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "prestier", "correct horse battery staple"
	createVault(base, name, pass)

	src := stageApps(t, "com.example.keep", "com.example.od")
	if refused := sealApps(t, base, name, pass, src); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	// Re-seal the same stage with one package DEFERRED, exactly as appcode_seal does for an on-demand app.
	dfl := filepath.Join(t.TempDir(), "defer.list")
	if err := os.WriteFile(dfl, []byte("com.example.od/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", dfl)
	t.Setenv("NOWHERE_CARRY_DEFERRED", "1")
	if refused := sealApps(t, base, name, pass, src); refused {
		t.Fatal("a package that moved to the DEFERRED tier was treated as vanished -- it is fully present, and " +
			"refusing here would make switching an app to on-demand unsealable")
	}
}

// TestAppsSealInertAgainstAHeadWithNoPkgIndex is the UPGRADE path, and it is the one that would land on every
// fielded profile at once if it were wrong. `chunkManifest.Pkg` is omitempty, and its own comment says a head
// without it must read as "not measured", NEVER as "this app costs nothing" -- so a head carrying no index
// must not be read as a total package loss. A full-tar seal (NOWHERE_SEAL_FULL=1, the #69 kill-switch) has no
// per-file boundaries to attribute and so writes no index, which is exactly that shape.
func TestAppsSealInertAgainstAHeadWithNoPkgIndex(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "presnoindex", "correct horse battery staple"
	createVault(base, name, pass)

	t.Setenv("NOWHERE_SEAL_FULL", "1") // a head with no Pkg index, as a pre-DIA-20260805-11 profile has
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.other")); refused {
		t.Fatal("fixture: the full-tar #apps seal was refused")
	}
	os.Unsetenv("NOWHERE_SEAL_FULL")
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep")); refused {
		t.Fatal("the guard armed against a head with NO Pkg index -- an absent index means NOT MEASURED, not " +
			"'no packages', so this would refuse the first seal of every profile that has not sealed since " +
			"DIA-20260805-11, all at once")
	}
}

// TestAppsSealCatchesAVanishedDeferredOnlyPackage covers the REAL fielded shape with no Pkg index: #84's
// deferred index shipped BEFORE DIA-20260805-11's per-package byte attribution, so a head sealed between them
// carries Deferred and no Pkg. Those packages are per-path and therefore measured, so the guard must still
// see one vanish. This is what makes the "was it measured" arm unnecessary rather than merely redundant.
func TestAppsSealCatchesAVanishedDeferredOnlyPackage(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "presdefonly", "correct horse battery staple"
	createVault(base, name, pass)

	both := stageApps(t, "com.example.keep", "com.example.aegis")
	dfl := filepath.Join(t.TempDir(), "defer.list")
	if err := os.WriteFile(dfl, []byte("com.example.keep/base.apk\ncom.example.aegis/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", dfl)
	t.Setenv("NOWHERE_CARRY_DEFERRED", "1")
	if refused := sealApps(t, base, name, pass, both); refused {
		t.Fatal("fixture: the deferred-only #apps seal was refused")
	}
	if m := headManifestOf(t, base, name+"#apps", pass); len(m.Pkg) != 0 || len(m.Deferred) != 2 {
		t.Fatalf("fixture: wanted a head with NO Pkg and 2 deferred, got Pkg=%d deferred=%d", len(m.Pkg), len(m.Deferred))
	}

	// The second handset stages only the one app it has, and the carry must not paper over the difference.
	one := stageApps(t, "com.example.keep")
	dfl2 := filepath.Join(t.TempDir(), "defer2.list")
	if err := os.WriteFile(dfl2, []byte("com.example.keep/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", dfl2)
	t.Setenv("NOWHERE_CARRY_DEFERRED", "")
	if refused := sealApps(t, base, name, pass, one); !refused {
		t.Fatal("a package that vanished from a head carrying NO Pkg index was accepted -- deferred packages " +
			"are per-path and therefore measured, so this head shape must be guarded like any other")
	}
}

// TestAppsSealAllowsAUserDeclaredClear: a DELIBERATE shrink-intent marker speaks for the whole scope. Refusing
// a user who did exactly what the UI asked would leave them over their plan with only a daemon log to say why
// -- the failure the shrink net's own comment already warns about.
func TestAppsSealAllowsAUserDeclaredClear(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "presdeliberate", "correct horse battery staple"
	createVault(base, name, pass)

	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.cleared")); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	markShrinkIntent(profileRefV2(name+"#apps", pass))
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep")); refused {
		t.Fatal("a seal the user DELIBERATELY declared was refused -- storage-clearing is the one operation " +
			"whose purpose is a shrink, and refusing it strands the user over their plan")
	}
}

// TestAppsSealInferredIntentSpeaksOnlyForWhatItNamed is the sharp half (NWP-20260903-13): an INFERRED marker
// is not the user's word, so it excuses the packages the inference named and nothing else.
func TestAppsSealInferredIntentSpeaksOnlyForWhatItNamed(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "presinferred", "correct horse battery staple"
	createVault(base, name, pass)

	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.named", "com.example.unnamed")); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	markShrinkIntentInferred(profileRefV2(name+"#apps", pass), []string{"com.example.named"})
	// Dropping ONLY the named package is explained.
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.unnamed")); refused {
		t.Fatal("an inferred marker did not excuse the package it explicitly named")
	}
	markShrinkIntentInferred(profileRefV2(name+"#apps", pass), []string{"com.example.named"})
	// Dropping one it did NOT name is not.
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep")); !refused {
		t.Fatal("an INFERRED marker naming one package excused a DIFFERENT one -- an inference is not the " +
			"user's word, and treating it as blanket authority is how an orphaned stack lost its code")
	}
}
