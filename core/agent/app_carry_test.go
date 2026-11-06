package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260906-17 (#91 slice 5c, the CARRY half). Device A installs and keeps an app; device B, signed into
// the same account and never given it, reaches its next seal, stages 19 of 20 and commits a head without it.
// The bytes lose their lease and store GC reaps them: gone from the ACCOUNT.
//
// The carry re-emits the missing package BY HASH out of the manifest this seal already read -- nothing
// fetched, nothing decrypted from another lineage, nothing re-uploaded.

// carrySeal runs one #apps push with the carry on.
func carrySeal(t *testing.T, base, name, pass, src string) chunkManifest {
	t.Helper()
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	sealRefused = false
	pushProfile(base, name+"#apps", pass, src)
	if sealRefused {
		t.Fatal("the #apps seal was refused")
	}
	return headManifestOf(t, base, name+"#apps", pass)
}

// TestCarryKeepsAPackageThisHandsetNeverStaged is the defect, end to end.
func TestCarryKeepsAPackageThisHandsetNeverStaged(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "carrykeep", "correct horse battery staple"
	createVault(base, name, pass)

	// Device A: both apps.
	first := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.aegis"))
	if _, ok := first.Ess["com.example.aegis/base.apk"]; !ok {
		t.Fatal("fixture: device A did not index the app under test")
	}
	// Device B: only the one it has.
	second := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep"))

	r, ok := second.Ess["com.example.aegis/base.apk"]
	if !ok {
		t.Fatal("device B's seal DROPPED the app it never received -- its chunks lose their lease and store GC " +
			"reaps them, so the app is gone from the account, not just from this handset")
	}
	if r.E > len(second.Chunks) || r.E <= r.S {
		t.Fatalf("the carried span [%d,%d) is not backed by the new head's %d chunks", r.S, r.E, len(second.Chunks))
	}
	// The carried hashes must be the SAME content-addressed blobs, not a re-upload.
	want := first.Chunks[first.Ess["com.example.aegis/base.apk"].S:first.Ess["com.example.aegis/base.apk"].E]
	got := second.Chunks[r.S:r.E]
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("the carry re-emitted different hashes:\n got %v\nwant %v", got, want)
	}
}

// TestCarriedPackageIsInstallable is the assertion that matters, and the one the filed design would have
// failed: the chooser installs STRICTLY from manifest.tsv, so carrying an app's bytes without its LINE puts
// them on disk where nothing will ever install them.
func TestCarriedPackageIsInstallable(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "carryinstall", "correct horse battery staple"
	createVault(base, name, pass)

	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.aegis"))
	second := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep"))

	line, ok := second.Apps["com.example.aegis"]
	if !ok {
		t.Fatal("the carried package has no manifest.tsv line in the new head -- its APK bytes are carried and " +
			"the chooser, which installs strictly from that index, will never install them")
	}
	if !strings.HasPrefix(line, "com.example.aegis\t") {
		t.Fatalf("the carried line is not this package's: %q", line)
	}
	// ⚠ AND THE SEALED TAR MUST AGREE WITH THE INDEX. This unpacks every essential chunk IN ORDER and untars
	// the result -- what a restore does -- because an index entry proves nothing on its own. It is also the
	// only thing that catches the carried regions landing PAST the tar footer, where they would be leased,
	// billed, indexed and never restored, with every log line reporting success.
	dest := t.TempDir()
	key, _, _ := resolveKey(base, name+"#apps", pass)
	var stream []byte
	for i, h := range second.Chunks {
		pt, ue := unpackChunk(unseal(key, getChunk(base, h)), second.Version)
		if ue != nil {
			t.Fatalf("chunk %d did not unpack: %v", i, ue)
		}
		stream = append(stream, pt...)
	}
	if rejected := untarFrom(dest, bytes.NewReader(stream)); rejected != 0 {
		t.Fatalf("the restored stream rejected %d entr(ies)", rejected)
	}
	body, err := os.ReadFile(filepath.Join(dest, "manifest.tsv"))
	if err != nil {
		t.Fatalf("the restored scope has no manifest.tsv, which roamd gates the whole restore on: %v", err)
	}
	if !bytes.Contains(body, []byte("com.example.aegis\t")) {
		t.Fatalf("the RESTORED manifest.tsv does not list the carried package -- the tar and the index disagree:\n%s", body)
	}
	if _, err := os.Stat(filepath.Join(dest, "com.example.aegis", "base.apk")); err != nil {
		t.Fatalf("the carried package's APK did not restore: %v", err)
	}
}

// TestCarryRespectsADeliberateUninstall. Chester's 2026-09-06 decision: an uninstall means gone. With a carry,
// not-staged stops meaning deleted, so removal has to be positively expressed -- and the drop list is that
// channel, exactly as it already is for the #204 deferred carry ("a deliberate exclusion is a deletion").
func TestCarryRespectsADeliberateUninstall(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "carrydrop", "correct horse battery staple"
	createVault(base, name, pass)

	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone"))
	dl := filepath.Join(t.TempDir(), "drop.list")
	if err := os.WriteFile(dl, []byte("com.example.gone\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DROP_LIST", dl)
	second := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep"))

	if _, ok := second.Ess["com.example.gone/base.apk"]; ok {
		t.Fatal("the carry resurrected a package the user DELIBERATELY uninstalled -- an uninstall must delete " +
			"it from the account, not merely stop carrying it next round")
	}
	if _, ok := second.Apps["com.example.gone"]; ok {
		t.Fatal("the uninstalled package's manifest.tsv line survived the carry, so the next login would " +
			"still try to install it")
	}
}

// TestCarryIsOffWithoutTheFlag: the fleet must behave exactly as before.
func TestCarryIsOffWithoutTheFlag(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "carryoff", "correct horse battery staple"
	createVault(base, name, pass)

	sealRefused = false
	pushProfile(base, name+"#apps", pass, stageApps(t, "com.example.keep", "com.example.aegis"))
	sealRefused = false
	pushProfile(base, name+"#apps", pass, stageApps(t, "com.example.keep"))
	m := headManifestOf(t, base, name+"#apps", pass)
	if len(m.Ess) != 0 || len(m.Apps) != 0 {
		t.Fatalf("the flag-off seal published an index (ess=%d apps=%d) -- fielded manifests must not change shape",
			len(m.Ess), len(m.Apps))
	}
}

// TestReconcileAppManifestIsIdempotent. roamd rebuilds the stage every seal, so the union normally runs against a
// fresh file -- but a retry, or a test, can run it twice over one stage, and a duplicated line would install
// the same package twice.
func TestReconcileAppManifestIsIdempotent(t *testing.T) {
	src := stageApps(t, "com.example.keep")
	old := map[string]string{"com.example.aegis": "com.example.aegis\t0\t0\tinstalled\tbase.apk"}

	for i := 0; i < 2; i++ {
		carry := carryablePackages(src, old, nil)
		if len(carry) != 1 || carry[0] != "com.example.aegis" {
			t.Fatalf("round %d: carryable = %v, want the one absent package", i, carry)
		}
		if _, _, err := reconcileAppManifest(src, carry, old, nil); err != nil {
			t.Fatalf("round %d: %v", i, err)
		}
	}
	body, err := os.ReadFile(filepath.Join(src, appManifestRel))
	if err != nil {
		t.Fatal(err)
	}
	if n := bytes.Count(body, []byte("com.example.aegis\t")); n != 1 {
		t.Fatalf("the package appears %d times after two unions, want 1:\n%s", n, body)
	}
}

// TestCarryablePackagesIgnoresAStagedOne: presence is decided by the STAGE DIRECTORY, because this runs before
// the walk and `seen` does not exist yet.
func TestCarryablePackagesIgnoresAStagedOne(t *testing.T) {
	src := stageApps(t, "com.example.here")
	old := map[string]string{
		"com.example.here":    "com.example.here\t0\t0\tinstalled\tbase.apk",
		"com.example.missing": "com.example.missing\t0\t0\tinstalled\tbase.apk",
	}
	got := carryablePackages(src, old, nil)
	if len(got) != 1 || got[0] != "com.example.missing" {
		t.Fatalf("carryablePackages = %v, want only the absent one", got)
	}
	// A dropped package is not carryable however absent it is.
	if got := carryablePackages(src, old, map[string]bool{"com.example.missing": true}); len(got) != 0 {
		t.Fatalf("carryablePackages = %v with the package dropped, want none", got)
	}
}

// TestLoadCDCManifestFailsClosed pins loadCDCManifest's stated contract directly, rather than as a side
// assertion of the repoint tests: it "collapses a wrong key, a missing blob and an empty scope into the same
// empty struct".
//
// ⚠ THIS IS NOT HYPOTHETICAL, AND IT SURFACED WHILE ADDING ONE FIELD. With `Apps` added to chunkManifest, a
// WRONG-KEY read began returning a struct whose Chunks length was garbage (7214878089432953715 in one run),
// while instrumentation INSIDE the function showed it returning zero -- the deferred `m = chunkManifest{}`
// ran, printed 0, and the caller still saw nonsense. Go 1.25.12. I did not root-cause that to a specific
// toolchain mechanism and am not claiming to have; what is certain is that the correctness rested on a
// deferred write to a named result UNDOING a partial one, and it stopped holding when the struct grew.
//
// The consequence was not cosmetic. manifestLoad's own comment says the seal guards "key entirely off
// len(oldM.Chunks) and go INERT at zero" -- so a bogus huge length ARMS them with nonsense, and any caller
// that ranges over Chunks indexes into a slice that does not exist.
//
// loadCDCManifest now publishes only on FULL success, so nothing half-written can escape at any size.
func TestLoadCDCManifestFailsClosed(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "failclosed#apps", "correct horse battery staple"
	body, err := json.Marshal(chunkManifest{Version: 1, Chunks: []string{"aa", "bb"}})
	if err != nil {
		t.Fatal(err)
	}
	h := postBlob(base, seal(deriveKey(name, pass), append(append([]byte{}, cdcMagic...), body...)))

	if got := loadCDCManifest(base, deriveKey(name, pass), h); len(got.Chunks) != 2 {
		t.Fatalf("fixture: the RIGHT key read %d chunks, want 2", len(got.Chunks))
	}
	for _, tc := range []struct {
		what string
		dk   []byte
		hash string
	}{
		{"a wrong key", deriveKey(name, "wrong pass"), h},
		{"a wrong profile's key", deriveKey("someone-else#apps", pass), h},
		{"a missing blob", deriveKey(name, pass), "00000000000000000000000000000000"},
		{"an empty hash", deriveKey(name, pass), ""},
	} {
		got := loadCDCManifest(base, tc.dk, tc.hash)
		if len(got.Chunks) != 0 || len(got.Ess) != 0 || len(got.Apps) != 0 || len(got.Deferred) != 0 {
			t.Fatalf("%s returned a non-empty manifest (chunks=%d ess=%d apps=%d deferred=%d) -- the seal "+
				"guards key off len(Chunks) and a bogus length arms them with nonsense",
				tc.what, len(got.Chunks), len(got.Ess), len(got.Apps), len(got.Deferred))
		}
	}
}
