package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// NWP-20260906-18. Chester, 2026-09-06: "if they've deliberately uninstall an app - they would expect it to be
// gone." Most of that already worked -- the uninstall reaches the drop list, the seal omits the app, its
// chunks lose their lease and store GC reaps them. The gap was a handset that was ALREADY SIGNED IN: it still
// has the app installed, stages it at its next seal, and puts it straight back into the account head.
//
// These tests drive the real pushProfile three times, which is exactly that sequence.

func dropListAt(t *testing.T, pkgs ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "drop.list")
	body := ""
	for _, k := range pkgs {
		body += k + "\n"
	}
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestTombstoneStopsAnotherHandsetReAddingAnApp is the decision, end to end.
func TestTombstoneStopsAnotherHandsetReAddingAnApp(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "tombdecide", "correct horse battery staple"
	createVault(base, name, pass)

	// 1. Both handsets' shared starting point.
	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone"))

	// 2. Device A: the user uninstalls one, so it reaches the seal through the drop list.
	// The seal models an UNINSTALL, so roamd names the package in both lists (NWP-20261023-07).
	gone := dropListAt(t, "com.example.gone")
	t.Setenv("NOWHERE_DROP_LIST", gone)
	t.Setenv("NOWHERE_GONE_LIST", gone)
	second := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep"))
	at, ok := second.Gone["com.example.gone"]
	if !ok {
		t.Fatal("the uninstall left no account tombstone, so no other handset can ever learn of it")
	}
	if at <= 0 {
		t.Fatalf("the tombstone carries no removal time (%d)", at)
	}

	// 3. Device B: signed in throughout, still has the app installed, and its OWN drop list is empty.
	os.Unsetenv("NOWHERE_DROP_LIST")
	os.Unsetenv("NOWHERE_GONE_LIST")
	third := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone"))

	if _, back := third.Ess["com.example.gone/base.apk"]; back {
		t.Fatal("a handset that was already signed in RE-ADDED the uninstalled app to the account head -- the " +
			"user's deletion is undone by a device that never heard about it")
	}
	if _, back := third.Apps["com.example.gone"]; back {
		t.Fatal("the uninstalled package's manifest.tsv line came back, so the next login installs it again")
	}
	if got := third.Gone["com.example.gone"]; got != at {
		t.Fatalf("the tombstone's removal time changed on a later seal (%d -> %d) -- it must record WHEN the "+
			"app was deleted, not when a device last sealed", at, got)
	}
	if _, still := third.Ess["com.example.keep/base.apk"]; !still {
		t.Fatal("the tombstone suppressed an unrelated package")
	}
}

// TestTombstoneIsClearedByAKeepAction. A permanent record with no way back is how a tombstone design goes
// wrong. This one is undone by the machinery that already shipped: loadDropList refuses to drop a package that
// is currently kept, so reinstalling the app and keeping it clears the tombstone with no expiry rule at all.
func TestTombstoneIsClearedByAKeepAction(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "tombclear", "correct horse battery staple"
	createVault(base, name, pass)

	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone"))
	// The seal models an UNINSTALL, so roamd names the package in both lists (NWP-20261023-07).
	gone := dropListAt(t, "com.example.gone")
	t.Setenv("NOWHERE_DROP_LIST", gone)
	t.Setenv("NOWHERE_GONE_LIST", gone)
	if _, ok := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep")).Gone["com.example.gone"]; !ok {
		t.Fatal("fixture: no tombstone to clear")
	}

	// The user reinstalls it and keeps it: the keep-set is the live truth and is what rescues it.
	os.Unsetenv("NOWHERE_DROP_LIST")
	os.Unsetenv("NOWHERE_GONE_LIST")
	kp := filepath.Join(t.TempDir(), "keep.list")
	if err := os.WriteFile(kp, []byte("com.example.gone\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_KEEP_LIST", kp)
	third := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone"))

	if _, ok := third.Ess["com.example.gone/base.apk"]; !ok {
		t.Fatal("a re-installed, re-KEPT app was still suppressed -- the tombstone has no way back, which is " +
			"how a user ends up unable to reinstall an app they deleted")
	}
	if _, ok := third.Gone["com.example.gone"]; ok {
		t.Fatal("the tombstone survived a deliberate re-add, so it would suppress the app again on any other " +
			"handset that does not happen to keep it")
	}
}

// TestTombstoneIsOffWithoutTheFlag: the fleet's manifests must not change shape.
func TestTombstoneIsOffWithoutTheFlag(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "tomboff", "correct horse battery staple"
	createVault(base, name, pass)

	sealRefused = false
	pushProfile(base, name+"#apps", pass, stageApps(t, "com.example.keep", "com.example.gone"))
	t.Setenv("NOWHERE_DROP_LIST", dropListAt(t, "com.example.gone"))
	sealRefused = false
	pushProfile(base, name+"#apps", pass, stageApps(t, "com.example.keep"))
	if m := headManifestOf(t, base, name+"#apps", pass); len(m.Gone) != 0 {
		t.Fatalf("a flag-off seal published %d tombstone(s)", len(m.Gone))
	}
}

// TestTombstonesToPublish is the truth table, pure and without a store.
func TestTombstonesToPublish(t *testing.T) {
	named := map[string]bool{"a": true, "b": true, "c": true}

	// A fresh removal of a package the head named gets today's stamp.
	got := tombstonesToPublish(nil, map[string]bool{"a": true}, named, nil, 1000)
	if got["a"] != 1000 {
		t.Fatalf("a new tombstone = %v, want a@1000", got)
	}
	// A package the head never named is not tombstoned: another device's local drop cannot plant a record.
	if got := tombstonesToPublish(nil, map[string]bool{"zz": true}, named, nil, 1000); len(got) != 0 {
		t.Fatalf("tombstoned a package the account never had: %v", got)
	}
	// An existing tombstone keeps its ORIGINAL time, even while the drop list still names it.
	got = tombstonesToPublish(map[string]int64{"a": 500}, map[string]bool{"a": true}, named, nil, 1000)
	if got["a"] != 500 {
		t.Fatalf("an existing tombstone was refreshed to %d -- it must record when the app was DELETED, not "+
			"when a device last sealed", got["a"])
	}
	// Present in this seal -> the tombstone is spent (only reachable via the keep-set rescue).
	if got := tombstonesToPublish(map[string]int64{"a": 500}, nil, named, map[string]bool{"a": true}, 1000); len(got) != 0 {
		t.Fatalf("a deliberately re-added package kept its tombstone: %v", got)
	}
	// A drop AND present in the same seal: present wins, since the keep-set is the live truth.
	if got := tombstonesToPublish(nil, map[string]bool{"a": true}, named, map[string]bool{"a": true}, 1000); len(got) != 0 {
		t.Fatalf("tombstoned a package this seal actually carries: %v", got)
	}
	// Unrelated tombstones survive untouched.
	got = tombstonesToPublish(map[string]int64{"b": 7}, nil, named, map[string]bool{"a": true}, 1000)
	if len(got) != 1 || got["b"] != 7 {
		t.Fatalf("an unrelated tombstone was disturbed: %v", got)
	}
	// Nothing to say -> nil, so the field stays omitted rather than serialising an empty object.
	if got := tombstonesToPublish(nil, nil, named, nil, 1000); got != nil {
		t.Fatalf("want nil for an empty set, got %v", got)
	}
}

// TestHeadNamedPackages: a tombstone may only be minted for a package the stored head actually accounts for,
// and the head can say so in four places.
func TestHeadNamedPackages(t *testing.T) {
	got := headNamedPackages(chunkManifest{
		Pkg:      map[string]int64{"from.pkg": 1},
		Apps:     map[string]string{"from.apps": "line"},
		Ess:      map[string]essRegion{"from.ess/base.apk": {}, "manifest.tsv": {}},
		Deferred: map[string]deferredFile{"from.deferred/base.apk": {}},
	})
	for _, want := range []string{"from.pkg", "from.apps", "from.ess", "from.deferred"} {
		if !got[want] {
			t.Fatalf("headNamedPackages lost %q: %v", want, got)
		}
	}
	if got["manifest.tsv"] {
		t.Fatal("the whole-scope index was treated as a package -- it belongs to none, and tombstoning it " +
			"would suppress the file every restore is gated on")
	}
	if len(got) != 4 {
		t.Fatalf("headNamedPackages = %v, want exactly the four", got)
	}
}

// TestTombstonesDoNotLeakIntoADataSeal. One agent process serves every scope of a logoff in a row (the login
// daemon runs handleExport inline), and the tombstone set is in-process state. If an #apps seal armed it and a
// following DATA seal inherited it, that package's CE/DE data would be dropped as well -- a deletion of the
// user's data that nobody asked for, from a record that was only ever about app CODE.
//
// This is why setSealTombstones is called on EVERY push, with nil when the flag is off, rather than only when
// there is something to arm.
func TestTombstonesDoNotLeakIntoADataSeal(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "tombleak", "correct horse battery staple"
	createVault(base, name, pass)

	// An #apps seal that mints a tombstone, exactly as a logoff's appcode_seal would.
	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone"))
	// The seal models an UNINSTALL, so roamd names the package in both lists (NWP-20261023-07).
	gone := dropListAt(t, "com.example.gone")
	t.Setenv("NOWHERE_DROP_LIST", gone)
	t.Setenv("NOWHERE_GONE_LIST", gone)
	if _, ok := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep")).Gone["com.example.gone"]; !ok {
		t.Fatal("fixture: no tombstone was armed")
	}

	// ⚠ ONE MORE #apps SEAL FIRST, and without it this test proves nothing. The set is armed from the
	// STORED head, so the seal that MINTS a tombstone still runs with an empty set -- only the seal AFTER
	// it arms a non-empty one. The leak this guards against is therefore only reachable from here.
	os.Unsetenv("NOWHERE_DROP_LIST")
	os.Unsetenv("NOWHERE_GONE_LIST")
	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep"))
	if len(sealTombstones()) == 0 {
		t.Fatal("fixture: the in-process tombstone set is still empty, so a leak could not show up here")
	}

	// Now the DATA scope, in the same process. roamd sets NOWHERE_CARRY_ESSENTIAL only for appcode_seal, so
	// the flag is off here -- and this push must not inherit anything from the one above.
	os.Unsetenv("NOWHERE_CARRY_ESSENTIAL")
	data := t.TempDir()
	for _, pkg := range []string{"com.example.keep", "com.example.gone"} {
		if err := os.MkdirAll(filepath.Join(data, pkg, "files"), 0o700); err != nil {
			t.Fatal(err)
		}
		body := make([]byte, 3000)
		for i := range body {
			body[i] = byte('a' + len(pkg)%20)
		}
		if err := os.WriteFile(filepath.Join(data, pkg, "files", "db"), body, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	sealRefused = false
	pushProfile(base, name, pass, data)
	if sealRefused {
		t.Fatal("the data seal was refused")
	}
	m := headManifestOf(t, base, name, pass)
	if m.Pkg["com.example.gone"] == 0 {
		t.Fatalf("the DATA of an app tombstoned in the #apps scope was dropped from the data seal (Pkg=%v) -- "+
			"the tombstone records deleted app CODE and must never reach a data scope", m.Pkg)
	}
}

// writeList writes body to a fresh list file and returns its path.
func writeList(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "gone.list")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// goneFixture seals two apps, then a second seal on which com.example.gone is dropped by the drop list. Callers set
// NOWHERE_GONE_LIST before the second seal through the setGone callback. NWP-20261023-07.
func goneFixture(t *testing.T, name string, setGone func()) chunkManifest {
	t.Helper()
	base := newHTTPStore(t)
	const pass = "correct horse battery staple"
	createVault(base, name, pass)
	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.gone"))
	t.Setenv("NOWHERE_DROP_LIST", dropListAt(t, "com.example.gone"))
	os.Unsetenv("NOWHERE_GONE_LIST")
	setGone()
	m := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep"))
	if _, back := m.Ess["com.example.gone/base.apk"]; back {
		t.Fatal("fixture: the drop list did not remove the app's code from the head")
	}
	return m
}

// TestTombstoneIsNotMintedForAnOff is DECIDED 2026-09-26: an app switched Off leaves the store at the next roam
// but never mints the account tombstone. The drop list holds Offs and uninstalls alike; roamd names only the
// uninstalled subset in NOWHERE_GONE_LIST, so an Off is on the drop list and NOT on the gone list.
func TestTombstoneIsNotMintedForAnOff(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "tombnotoff", "correct horse battery staple"
	createVault(base, name, pass)
	keep := stageApps(t, "com.example.keep")

	carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.off"))

	t.Setenv("NOWHERE_DROP_LIST", dropListAt(t, "com.example.off"))
	os.Unsetenv("NOWHERE_GONE_LIST")
	second := carrySeal(t, base, name, pass, keep)
	if _, ok := second.Ess["com.example.off/base.apk"]; ok {
		t.Fatal("an Off no longer drops the app's code from the head")
	}
	if _, ok := second.Apps["com.example.off"]; ok {
		t.Fatal("an Off no longer drops the app's manifest.tsv line from the head")
	}
	if at, ok := second.Gone["com.example.off"]; ok {
		t.Fatalf("an Off minted an account tombstone (%d): it would delete the app from every other handset", at)
	}

	// Another handset, still having the app, with no drop list: nothing suppresses it.
	os.Unsetenv("NOWHERE_DROP_LIST")
	third := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.off"))
	if _, ok := third.Ess["com.example.off/base.apk"]; !ok {
		t.Fatal("another handset could not put the Off app back")
	}
	if _, ok := third.Apps["com.example.off"]; !ok {
		t.Fatal("another handset's manifest.tsv line for the Off app is missing")
	}
	if len(third.Gone) != 0 {
		t.Fatalf("an Off left tombstones behind: %v", third.Gone)
	}
}

// A NOWHERE_GONE_LIST naming a file that is not there mints nothing (roamd passes an empty path on a grep error).
func TestTombstoneGoneListMissingFileMintsNothing(t *testing.T) {
	m := goneFixture(t, "tombgonemissing", func() {
		t.Setenv("NOWHERE_GONE_LIST", filepath.Join(t.TempDir(), "absent.list"))
	})
	if len(m.Gone) != 0 {
		t.Fatalf("an unreadable gone list minted %v", m.Gone)
	}
}

// A line holding a path separator is ignored; the valid line beside it still mints.
func TestTombstoneGoneListIgnoresAPathLine(t *testing.T) {
	m := goneFixture(t, "tombgonepath", func() {
		t.Setenv("NOWHERE_GONE_LIST", writeList(t, "com.example/evil\ncom.example.gone\n"))
	})
	if len(m.Gone) != 1 || m.Gone["com.example.gone"] <= 0 {
		t.Fatalf("want exactly one tombstone, for com.example.gone; got %v", m.Gone)
	}
}

// With the flag off nothing reads either list: no Gone field, however both are set.
func TestTombstoneIsOffWithoutTheFlagEvenWithAGoneList(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "tomboffgone", "correct horse battery staple"
	createVault(base, name, pass)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "")
	os.Unsetenv("NOWHERE_CARRY_ESSENTIAL")

	sealRefused = false
	pushProfile(base, name+"#apps", pass, stageApps(t, "com.example.keep", "com.example.gone"))
	both := dropListAt(t, "com.example.gone")
	t.Setenv("NOWHERE_DROP_LIST", both)
	t.Setenv("NOWHERE_GONE_LIST", both)
	sealRefused = false
	pushProfile(base, name+"#apps", pass, stageApps(t, "com.example.keep"))
	if m := headManifestOf(t, base, name+"#apps", pass); len(m.Gone) != 0 {
		t.Fatalf("a flag-off seal published %d tombstone(s) with both lists set", len(m.Gone))
	}
}

// TestGoneDropList: the uninstall subset of the drop list, row by row. The drop list is {a, b}.
func TestGoneDropList(t *testing.T) {
	str := func(s string) *string { return &s }
	cases := []struct {
		name string
		path *string // NOWHERE_GONE_LIST as the literal path; nil = unset
		body *string // when path is nil: a file with this body is written and named
		want map[string]bool
	}{
		{name: "unset"},
		{name: "empty variable", path: str("")},
		{name: "empty file", body: str("")},
		{name: "missing file", path: str("/nonexistent-nowhere-dir/absent.list")},
		{name: "path line ignored", body: str("x/y\nb\n"), want: map[string]bool{"b": true}},
		{name: "gone package not on the drop list", body: str("z\n")},
		{name: "intersection, trimmed", body: str("b\nc\n  a  \n"), want: map[string]bool{"a": true, "b": true}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("NOWHERE_DROP_LIST", dropListAt(t, "a", "b"))
			os.Unsetenv("NOWHERE_GONE_LIST")
			switch {
			case c.path != nil:
				t.Setenv("NOWHERE_GONE_LIST", *c.path)
			case c.body != nil:
				t.Setenv("NOWHERE_GONE_LIST", writeList(t, *c.body))
			}
			got := goneDropList()
			if c.want == nil {
				if got != nil {
					t.Fatalf("want nil, got %v", got)
				}
				return
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("want %v, got %v", c.want, got)
			}
		})
	}
}
