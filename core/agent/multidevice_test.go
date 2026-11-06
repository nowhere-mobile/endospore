package main

import (
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #91 slice 1: the per-unit head refs, the account-dir ref, and the shared-media ref are deterministic
// (a fresh device re-derives them from name+pass alone), distinct from each other and from the profile refs,
// and per-unit heads differ by unit id (so two devices never collide -> no split-brain).
func TestMultiDeviceRefs(t *testing.T) {
	const name, pass = "acct", "correct horse battery staple"

	// Deterministic: same inputs -> same ref.
	if unitHeadRef(name, pass, "unitA") != unitHeadRef(name, pass, "unitA") {
		t.Fatal("unitHeadRef not deterministic")
	}
	// Distinct per unit.
	if unitHeadRef(name, pass, "unitA") == unitHeadRef(name, pass, "unitB") {
		t.Fatal("two units resolved to the same head ref (split-brain)")
	}
	// The account refs + the legacy profile refs are all distinct domains. (sharedMediaRef was a third
	// account ref until NWP-20260907-23 retired it with slice 5b; #media lives at profileRefV2("<name>#media").)
	refs := map[string]string{
		"unitA":  unitHeadRef(name, pass, "unitA"),
		"dir":    accountDirRef(name, pass),
		"media":  profileRefV2(name+"#media", pass),
		"v2":     profileRefV2(name, pass),
		"legacy": profileRefLegacy(name, pass),
	}
	seen := map[string]string{}
	for k, v := range refs {
		if prev, dup := seen[v]; dup {
			t.Fatalf("ref collision: %s and %s derive the same ref", k, prev)
		}
		seen[v] = k
	}
	// A different passphrase yields entirely different refs (no cross-identity leakage).
	if unitHeadRef(name, "river maple stone cloud", "unitA") == refs["unitA"] {
		t.Fatal("unitHeadRef did not change with the passphrase")
	}
}

// The account directory adds/replaces units, keeps a stable tab order, distinguishes live vs retired, and
// round-trips sealed under the DK.
func TestAccountDirectory(t *testing.T) {
	d := newAccountDir(unitEntry{ID: "fp3", Label: "Chester's FP3", Edition: "diaspore", Added: 100})
	d.addUnit(unitEntry{ID: "pixel", Label: "Pixel 10", Edition: "endospore", Added: 200})
	if len(d.Units) != 2 || d.Version != 2 {
		t.Fatalf("dir = %d units v%d; want 2 units v2", len(d.Units), d.Version)
	}
	// Re-clone the same unit id -> update in place, not a duplicate tab.
	d.addUnit(unitEntry{ID: "pixel", Label: "Pixel 10 (relabeled)", Edition: "endospore", Added: 200})
	if len(d.Units) != 2 {
		t.Fatalf("re-adding an existing unit id duplicated the tab: %d units", len(d.Units))
	}
	if d.Units[1].Label != "Pixel 10 (relabeled)" {
		t.Fatalf("re-add did not update the label: %q", d.Units[1].Label)
	}
	// Stable tab order by Added time.
	if d.Units[0].ID != "fp3" || d.Units[1].ID != "pixel" {
		t.Fatalf("tab order = %s,%s; want fp3,pixel", d.Units[0].ID, d.Units[1].ID)
	}
	// Retire a unit -> still stored, not offered live.
	d.Units[0].Retired = true
	if got := d.liveUnits(); len(got) != 1 || got[0].ID != "pixel" {
		t.Fatalf("liveUnits after retiring fp3 = %v; want just pixel", got)
	}

	// Sealed round-trip under a DK; a foreign DK does not open it.
	dk := make([]byte, 32)
	rand.Read(dk)
	blob := sealAccountDir(dk, d)
	got, ok := openAccountDir(dk, blob)
	if !ok || got.Version != d.Version || len(got.Units) != 2 {
		t.Fatalf("sealed round-trip = %+v ok=%v; want v%d/2 units", got, ok, d.Version)
	}
	foreign := make([]byte, 32)
	rand.Read(foreign)
	if _, ok := openAccountDir(foreign, blob); ok {
		t.Fatal("a foreign DK opened the account directory")
	}
}

// slice 2: this device's stable unit id is minted once and then reused (a stable lineage), not regenerated.
func TestUnitIDMintPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "unit-id")
	id1, err := readOrMintUnitID(path)
	if err != nil || id1 == "" {
		t.Fatalf("mint: id=%q err=%v", id1, err)
	}
	id2, err := readOrMintUnitID(path)
	if err != nil || id2 != id1 {
		t.Fatalf("reuse: id2=%q want %q err=%v", id2, id1, err)
	}
	// A blank/whitespace file re-mints (never gets stuck on an empty id).
	if err := os.WriteFile(path, []byte("  \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if id3, _ := readOrMintUnitID(path); id3 == "" || id3 == id1 {
		t.Fatalf("blank file should re-mint a NEW id: id3=%q id1=%q", id3, id1)
	}
}

// slice 2: the account directory records THIS device on the first login of an account, idempotently, sealed
// under the identity DK, and reads back with both lineages after a second device enrolls.
func TestEnsureUnitInDirectory(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct", "correct horse battery staple"
	dk := make([]byte, 32)
	rand.Read(dk)

	// First login of this account on unit A -> creates the directory and writes.
	d, wrote := ensureUnitInDirectory(base, name, pass, dk, "unitA", "Chester's FP3", "diaspore")
	if !wrote || len(d.Units) != 1 || d.Units[0].ID != "unitA" {
		t.Fatalf("first enroll: wrote=%v units=%d", wrote, len(d.Units))
	}
	// A later login on the SAME unit -> idempotent, no second write.
	if _, wrote := ensureUnitInDirectory(base, name, pass, dk, "unitA", "Chester's FP3", "diaspore"); wrote {
		t.Fatal("re-login on the same unit re-wrote the directory")
	}
	// A second device (unit B) on the same account -> adds a lineage.
	d, wrote = ensureUnitInDirectory(base, name, pass, dk, "unitB", "Pixel 10", "endospore")
	if !wrote || len(d.Units) != 2 {
		t.Fatalf("second unit: wrote=%v units=%d", wrote, len(d.Units))
	}
	// Persisted + opens under the identity DK.
	got, ok := loadAccountDir(base, name, pass, dk)
	if !ok || len(got.Units) != 2 {
		t.Fatalf("reload: ok=%v units=%d", ok, len(got.Units))
	}
	// A foreign DK cannot read it (sealed under the identity DK).
	foreign := make([]byte, 32)
	rand.Read(foreign)
	if _, ok := loadAccountDir(base, name, pass, foreign); ok {
		t.Fatal("a foreign DK opened the account directory")
	}
}

// slice 3: the GATED per-unit head model. An existing single-head profile is adopted to THIS device's unit
// head on the first seal (zero data movement, the pre-multi-device head left intact as a safety net); a second
// device does not see the first's unit head (no split-brain); #media stays account-shared; and with the flag
// OFF everything is byte-for-byte the legacy single-head behavior.
func TestPerUnitHeadMigration(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct", "correct horse battery staple"
	origUnitPath := unitIDPath
	defer func() { unitIDPath = origUnitPath }()
	os.Setenv("NOWHERE_MULTIDEVICE", "1")
	defer os.Unsetenv("NOWHERE_MULTIDEVICE")

	// A pre-multi-device profile: a single head at the v2 profile ref.
	legacy := postBlob(base, []byte("pre-multidevice head"))
	putRef(base, profileRefV2(name, pass), legacy)

	// This device (unit A).
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	urefA := unitHeadRef(name, pass, deviceUnitID())

	// Before this device has sealed, headKey falls through to the single head so it SEES the account's data.
	if got := headKey(base, name, pass); got != profileRefV2(name, pass) {
		t.Fatalf("pre-seal headKey = %s; want the single head (adoption read)", got)
	}
	// First seal on this device -> the UNIT head; the pre-multi-device head is untouched.
	sealed := postBlob(base, []byte("unit A seal"))
	putHead(base, name, pass, sealed)
	if getRef(base, urefA) != sealed {
		t.Fatal("putHead did not write this device's unit head")
	}
	if getRef(base, profileRefV2(name, pass)) != legacy {
		t.Fatal("putHead disturbed the pre-multi-device single head (must stay as the safety net)")
	}
	// Reads now resolve to the unit head.
	if got := headKey(base, name, pass); got != urefA {
		t.Fatalf("post-seal headKey = %s; want the unit head %s", got, urefA)
	}

	// A DIFFERENT device (unit B) does not see A's seal -> adopts the pre-multi-device head (no split-brain).
	unitIDPath = filepath.Join(t.TempDir(), "unit-id-B")
	if got := headKey(base, name, pass); got != profileRefV2(name, pass) {
		t.Fatalf("unit B headKey = %s; want the single head, not A's unit head", got)
	}

	// #media stays SHARED at the legacy ref regardless of the flag/unit -- NOT per-unit.
	media := postBlob(base, []byte("shared media head"))
	putHead(base, name+"#media", pass, media)
	if getRef(base, profileRefV2(name+"#media", pass)) != media {
		t.Fatal("#media must seal to the shared (v2) ref")
	}
	if refExists(base, unitHeadRef(name+"#media", pass, deviceUnitID())) {
		t.Fatal("#media must NOT be written to a per-unit head")
	}

	// The gate is real: flag OFF -> the legacy single-head behavior, unaffected by the unit heads written above.
	os.Unsetenv("NOWHERE_MULTIDEVICE")
	if got := headKey(base, name, pass); got != profileRefV2(name, pass) {
		t.Fatalf("flag OFF: headKey = %s; want the legacy single head", got)
	}
}

// slice 4: the initial lineage label is the capitalized edition + a short id (distinguishable per device).
func TestDefaultUnitLabel(t *testing.T) {
	if got := defaultUnitLabel("diaspore", "da4bf24dccf3ac4d"); got != "Diaspore · da4bf24d" {
		t.Fatalf("defaultUnitLabel = %q; want \"Diaspore · da4bf24d\"", got)
	}
	if got := defaultUnitLabel("endospore", "abc"); got != "Endospore · abc" {
		t.Fatalf("defaultUnitLabel short id = %q", got)
	}
	// NWP-20260910-22: an Endospore Pixel other than lynx used to enrol as "Diaspore · ...".
	if got := defaultUnitLabel(editionForOSRef("os-frankel"), "3f8a1c2d99"); got != "Endospore · 3f8a1c2d" {
		t.Fatalf("defaultUnitLabel(os-frankel) = %q; want \"Endospore · 3f8a1c2d\"", got)
	}
}

// NWP-20261011-30: every shipped codename maps to its edition, whatever whitespace or os- prefix the baked
// os-ref carries. The expected table is spelled out here rather than read from deviceEditions, so dropping a
// row there fails this test.
func TestEditionForOSRef(t *testing.T) {
	want := map[string]string{
		"fp3":      "diaspore",
		"lynx":     "endospore",
		"frankel":  "endospore",
		"tegu":     "endospore",
		"stallion": "endospore",
		"husky":    "endospore",
	}
	for dev, ed := range want {
		for _, in := range []string{dev, dev + "\n", "os-" + dev, "os-" + dev + "\n", " os-" + dev + " \n"} {
			if got := editionForOSRef(in); got != ed {
				t.Errorf("editionForOSRef(%q) = %q; want %q", in, got, ed)
			}
		}
	}
}

// NWP-20261011-30: nothing that is not in the table is guessed into an edition -- empty contents are
// "unknown", and an unlisted codename reports itself.
func TestEditionForOSRefNeverGuesses(t *testing.T) {
	for _, in := range []string{"", "\n", "  ", "os-", "os-\n"} {
		if got := editionForOSRef(in); got != "unknown" {
			t.Errorf("editionForOSRef(%q) = %q; want \"unknown\"", in, got)
		}
	}
	for in, want := range map[string]string{"os-zz9": "zz9", "zz9\n": "zz9"} {
		if got := editionForOSRef(in); got != want {
			t.Errorf("editionForOSRef(%q) = %q; want %q", in, got, want)
		}
	}
}

// NWP-20261011-30: deviceEdition reads the os-ref file through editionForOSRef; a missing file is the FP3
// (which bakes none), any other read failure is "unknown", and $NOWHERE_EDITION still overrides.
func TestDeviceEditionFromOSRef(t *testing.T) {
	dir := t.TempDir()
	orig := osRefPath
	defer func() { osRefPath = orig }()
	t.Setenv("NOWHERE_EDITION", "")

	osRefPath = filepath.Join(dir, "missing")
	if got := deviceEdition(); got != "diaspore" {
		t.Errorf("missing os-ref: deviceEdition = %q; want \"diaspore\"", got)
	}
	osRefPath = dir // a directory: the read fails with something other than not-exist
	if got := deviceEdition(); got != "unknown" {
		t.Errorf("unreadable os-ref: deviceEdition = %q; want \"unknown\"", got)
	}
	osRefPath = filepath.Join(dir, "os-ref")
	for contents, want := range map[string]string{"os-frankel\n": "endospore", "os-fp3\n": "diaspore", "": "unknown", "os-zz9\n": "zz9"} {
		if err := os.WriteFile(osRefPath, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := deviceEdition(); got != want {
			t.Errorf("os-ref %q: deviceEdition = %q; want %q", contents, got, want)
		}
	}
	t.Setenv("NOWHERE_EDITION", "endospore")
	osRefPath = filepath.Join(dir, "missing")
	if got := deviceEdition(); got != "endospore" {
		t.Errorf("$NOWHERE_EDITION override: deviceEdition = %q; want \"endospore\"", got)
	}
}

// NWP-20261011-30: deviceEditions is exactly the device tree. Every editions/<e>/devices/<d> dir must have the
// row d -> e, the table must name no device the tree lacks, and each device's committed os-ref must read
// os-<d> -- or, for a device that commits none, <d> must be the one deviceEdition assumes when the file is
// missing. So a device added without a row here fails CI instead of enrolling under a guessed edition.
func TestEveryDeviceDirHasAnEdition(t *testing.T) {
	root := filepath.Join("..", "..", "editions")
	editions, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read %s: %v (this test needs the repo checkout)", root, err)
	}
	seen := map[string]string{}
	for _, e := range editions {
		if !e.IsDir() {
			continue
		}
		devs, err := os.ReadDir(filepath.Join(root, e.Name(), "devices"))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range devs {
			if !d.IsDir() {
				continue
			}
			dev := d.Name()
			seen[dev] = e.Name()
			if got, ok := deviceEditions[dev]; !ok {
				t.Errorf("editions/%s/devices/%s has no deviceEditions row", e.Name(), dev)
			} else if got != e.Name() {
				t.Errorf("deviceEditions[%q] = %q; the tree puts it under editions/%s", dev, got, e.Name())
			}
			b, err := os.ReadFile(filepath.Join(root, e.Name(), "devices", dev, "vendor", "etc", "os-ref"))
			switch {
			case os.IsNotExist(err):
				if "os-"+dev != osRefDefault {
					t.Errorf("editions/%s/devices/%s commits no vendor/etc/os-ref, and only %s may rely on the missing-file default", e.Name(), dev, osRefDefault)
				}
			case err != nil:
				t.Fatal(err)
			case strings.TrimSpace(string(b)) != "os-"+dev:
				t.Errorf("editions/%s/devices/%s/vendor/etc/os-ref = %q; want %q", e.Name(), dev, strings.TrimSpace(string(b)), "os-"+dev)
			}
		}
	}
	if len(seen) == 0 {
		t.Fatalf("no device dirs under %s", root)
	}
	for dev, ed := range deviceEditions {
		if _, ok := seen[dev]; !ok {
			t.Errorf("deviceEditions has %q -> %q, but there is no editions/%s/devices/%s", dev, ed, ed, dev)
		}
	}
}

// slice 4: enrollUnitAtLogin records this device in the account directory on login, idempotently, and is a
// no-op when the per-unit head model is disabled.
func TestEnrollUnitAtLogin(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct", "correct horse battery staple"
	origUnitPath := unitIDPath
	defer func() { unitIDPath = origUnitPath }()
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	createVault(base, name, pass) // a real vault so resolveDK opens the DK

	// Flag OFF -> enrollUnitAtLogin is a no-op (no directory written).
	os.Unsetenv("NOWHERE_MULTIDEVICE")
	enrollUnitAtLogin(base, name, pass, nil)
	dk := resolveDK(base, name, pass, nil)
	if _, ok := loadAccountDir(base, name, pass, dk); ok {
		t.Fatal("flag off: enrollUnitAtLogin created a directory")
	}

	// Flag ON -> the first login records THIS unit.
	os.Setenv("NOWHERE_MULTIDEVICE", "1")
	defer os.Unsetenv("NOWHERE_MULTIDEVICE")
	enrollUnitAtLogin(base, name, pass, nil)
	d, ok := loadAccountDir(base, name, pass, dk)
	if !ok || len(d.Units) != 1 || d.Units[0].ID != deviceUnitID() {
		t.Fatalf("after login: dir ok=%v units=%d", ok, len(d.Units))
	}
	// Idempotent: a later login writes nothing new.
	enrollUnitAtLogin(base, name, pass, nil)
	if d2, _ := loadAccountDir(base, name, pass, dk); len(d2.Units) != 1 || d2.Version != d.Version {
		t.Fatalf("re-login mutated the directory: units=%d v%d (was v%d)", len(d2.Units), d2.Version, d.Version)
	}
}

// slice 4b: NOWHERE_UNIT_SRC overrides the READ head to another lineage's unit ("restore from that device"),
// while WRITES still land on this device's own head -- so a restore is a point-in-time copy, never a live link.
func TestUnitSrcOverride(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct", "correct horse battery staple"
	origUnitPath := unitIDPath
	defer func() { unitIDPath = origUnitPath }()
	os.Setenv("NOWHERE_MULTIDEVICE", "1")
	defer os.Unsetenv("NOWHERE_MULTIDEVICE")
	defer os.Unsetenv("NOWHERE_UNIT_SRC")

	// Unit A seals a head.
	unitIDPath = filepath.Join(t.TempDir(), "unit-A")
	unitA := deviceUnitID()
	headA := postBlob(base, []byte("device A head"))
	putHead(base, name, pass, headA)

	// Unit B (this device) seals a DIFFERENT head.
	unitIDPath = filepath.Join(t.TempDir(), "unit-B")
	unitB := deviceUnitID()
	headB := postBlob(base, []byte("device B head"))
	putHead(base, name, pass, headB)

	// No override: this device (B) resolves its OWN head.
	if got := getRef(base, headKey(base, name, pass)); got != headB {
		t.Fatalf("no override: headKey -> %s; want B's head", got)
	}
	// Override to unit A: the READ resolves A's head (the point-in-time restore-from-A).
	os.Setenv("NOWHERE_UNIT_SRC", unitA)
	if got := getRef(base, headKey(base, name, pass)); got != headA {
		t.Fatalf("override -> A: headKey read %s; want A's head", got)
	}
	// A seal DURING a restore-from-A must still write THIS device's (B's) head -- never the source's.
	writeC := postBlob(base, []byte("seal during restore-from-A"))
	putHead(base, name, pass, writeC)
	if got := getRef(base, unitHeadRef(name, pass, unitB)); got != writeC {
		t.Fatal("putHead honored the override -- writes must always target THIS device's head")
	}
	if got := getRef(base, unitHeadRef(name, pass, unitA)); got != headA {
		t.Fatal("putHead during a restore-from-A clobbered the SOURCE unit's head")
	}
}
