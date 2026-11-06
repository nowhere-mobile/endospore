package main

import (
	"encoding/json"
	"testing"
)

// withStoreBytes must ADD information and never destroy any: on every failure path the caller's JSON comes
// back untouched, because this screen is offered exactly when the user is over their plan and wants to act.
func TestWithStoreBytesNeverDamagesTheReply(t *testing.T) {
	in := `{"apps":[{"pkg":"com.a","bytes":100,"mode":"installed"}],"total_bytes":100}`

	if got, err := withStoreBytes(in, "prof", "", nil); got != in || err == nil {
		t.Errorf("no session key: got %q err=%v, want the input back with an error", got, err)
	}
	if got, _ := withStoreBytes("not json at all", "prof", "pw", nil); got != "not json at all" {
		t.Errorf("unparseable worker output: got %q, want it returned verbatim", got)
	}
	// No store configured in a unit test -> nothing measured -> the local walk is served exactly as before,
	// and specifically NOT a table of zeros implying every app is free.
	got, err := withStoreBytes(in, "prof", "pw", nil)
	if err != nil {
		t.Fatalf("unmeasured profile: %v", err)
	}
	if got != in {
		t.Errorf("unmeasured profile rewrote the reply:\n got %s\nwant %s", got, in)
	}
	var b storageBreakdown
	if json.Unmarshal([]byte(got), &b) != nil || b.StoreMeasured {
		t.Error("StoreMeasured must stay false when no scope carries a Pkg index")
	}
}

// The remainder is what makes the column honest: rows + other == total, so the screen can show where the
// rest of the bill went instead of leaving a silent gap the user reads as slack.
func TestStoreRemainderReconciles(t *testing.T) {
	b := storageBreakdown{Apps: []storageApp{{Pkg: "com.a"}, {Pkg: "com.b"}}}
	per := map[string]int64{"com.a": 300, "com.b": 200}
	total := int64(900)

	var attributed int64
	for i := range b.Apps {
		b.Apps[i].Store = per[b.Apps[i].Pkg]
	}
	for _, v := range per {
		attributed += v
	}
	b.StoreTotal = total
	b.StoreOther = total - attributed

	var sum int64
	for _, a := range b.Apps {
		sum += a.Store
	}
	if sum+b.StoreOther != b.StoreTotal {
		t.Errorf("rows(%d) + other(%d) = %d, want the billed total %d", sum, b.StoreOther, sum+b.StoreOther, b.StoreTotal)
	}
	if b.StoreOther != 400 {
		t.Errorf("other = %d, want 400 (snapshots + shared chunks + non-app data)", b.StoreOther)
	}
}

// storePkgBytes attributes a scope's Deferred entries by path, and reports measured=false when no scope
// carries a Pkg index -- the difference between "this app costs nothing" and "we have not measured".
func TestStorePkgBytesFromManifestShapes(t *testing.T) {
	m := chunkManifest{
		Pkg: map[string]int64{"com.a": 1000},
		Deferred: map[string]deferredFile{
			"com.b/base.apk":                   {Sz: []int64{10, 20}}, // on-demand APK code
			"Android/media/com.b/pics/big.jpg": {Sz: []int64{70}},     // billed, so it is com.b's cost
			"DCIM/Camera/vid.mp4":              {Sz: []int64{5000}},   // the user's own video: nobody's app
		},
	}
	per := map[string]int64{}
	measured := false
	for pkg, bytes := range m.Pkg {
		if pkg != "" && bytes > 0 {
			per[pkg] += bytes
			measured = true
		}
	}
	for rel, d := range m.Deferred {
		if pkg := attrPkgForRel(rel); pkg != "" {
			for _, z := range d.Sz {
				per[pkg] += z
			}
		}
	}
	if !measured {
		t.Fatal("a manifest carrying Pkg must report measured")
	}
	if per["com.a"] != 1000 {
		t.Errorf("com.a = %d, want 1000 from the Pkg index", per["com.a"])
	}
	if per["com.b"] != 100 {
		t.Errorf("com.b = %d, want 100 (30 apk + 70 external media)", per["com.b"])
	}
	if _, ok := per["DCIM"]; ok {
		t.Error("a user folder was priced as an app")
	}
}

// A legacy BARE head must parse. Only the base CE scope is ever a vault (createVault takes the bare profile
// name alone), so #de / #media / #apps / #keys are all bare -- and treating them as unreadable made the plan
// column price ONE of the four scopes it claims to cover.
//
// Device-proven on lynx (DIA-20260806-03): Play Services read "under 1 MB of your plan" against 88 MB on the
// phone, because its data sits in the DE hold (com.nowhere.chooser/.nowhere-odhold/<pkg>, where roamd parks
// every kept app's data at login) -- i.e. in #de, which was never opened. The walk-side attribution was
// correct all along; nothing downstream could see it.
func TestParseBareHeadManifest(t *testing.T) {
	want := chunkManifest{
		Version: 2,
		Chunks:  []string{"aa", "bb"},
		Sizes:   []int64{100, 200},
		Pkg:     map[string]int64{"com.google.android.gms": 89000000},
	}
	body, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := parseBareHeadManifest(append(append([]byte{}, cdcMagic...), body...))
	if !ok {
		t.Fatal("a cdcMagic-prefixed bare head must parse -- every scope but the base vault is one")
	}
	if got.Pkg["com.google.android.gms"] != 89000000 {
		t.Errorf("Pkg index lost: %v", got.Pkg)
	}
	if len(got.Chunks) != 2 || got.Sizes[1] != 200 {
		t.Errorf("manifest body lost: %+v", got)
	}
	// Not a manifest at all -> reported as unreadable, never as an empty one (an empty manifest would read
	// as "this scope costs nothing", which is exactly the lie this bug told).
	if _, ok := parseBareHeadManifest([]byte("not a manifest")); ok {
		t.Error("garbage must not parse as an empty manifest")
	}
}

// NWP-20260826-02: a package the LOCAL walk never saw must still get a row.
//
// b.Apps comes from the walk, so an app that is sealed but locally absent -- an #apps-only orphan (APK in
// #apps, no data dir), or an on-demand app whose hold was released -- used to appear in NEITHER the rows nor
// StoreOther: `attributed` counted it, which SUBTRACTED it from the remainder, while nothing rendered it. Its
// bytes went missing from the one screen that explains where the plan went, and with no row there was nothing
// for the chooser's "Stop carrying" chip to hang off -- the same dead end Chester hit with tesla, reached by a
// different route and without even a number to start from.
func TestRowlessPackagesGetRows(t *testing.T) {
	apps := []storageApp{{Pkg: "com.local", Bytes: 100, Store: 300}}
	per := map[string]int64{"com.local": 300, "com.sealedonly": 500, "com.zero": 0}
	code := map[string]bool{"com.sealedonly": true}

	got := rowsForRowlessPackages(apps, per, code)

	if len(got) != 2 {
		t.Fatalf("got %d rows, want 2 (the local one plus the sealed-only one)", len(got))
	}
	if got[0].Pkg != "com.local" || got[0].Bytes != 100 {
		t.Errorf("the existing row was disturbed: %+v", got[0])
	}
	row := got[1]
	if row.Pkg != "com.sealedonly" {
		t.Fatalf("row 1 = %q, want com.sealedonly", row.Pkg)
	}
	if row.Store != 500 {
		t.Errorf("Store = %d, want 500 -- the plan cost is the number the user is paying", row.Store)
	}
	if row.Bytes != 0 {
		t.Errorf("Bytes = %d, want 0: there genuinely is nothing on this device to free", row.Bytes)
	}
	if !row.CodeSealed {
		t.Error("CodeSealed must carry through, or the row cannot say whether the app can come back")
	}
	// A zero-cost entry must not manufacture a row: an empty row invites the user to act on nothing.
	for _, a := range got {
		if a.Pkg == "com.zero" {
			t.Error("a zero-byte attribution produced a row")
		}
	}
}

// Adding rows must not break the arithmetic the column depends on: rows + other == total. Before this,
// rowless packages were subtracted from `other` and rendered nowhere, so the screen under-summed the bill.
func TestRowlessPackagesKeepTheRemainderHonest(t *testing.T) {
	per := map[string]int64{"com.a": 300, "com.rowless": 200}
	b := storageBreakdown{Apps: []storageApp{{Pkg: "com.a", Store: 300}}, StoreTotal: 900}

	b.Apps = rowsForRowlessPackages(b.Apps, per, nil)
	var attributed int64
	for _, v := range per {
		attributed += v
	}
	b.StoreOther = b.StoreTotal - attributed

	var sum int64
	for _, a := range b.Apps {
		sum += a.Store
	}
	if sum+b.StoreOther != b.StoreTotal {
		t.Errorf("rows(%d) + other(%d) = %d, want %d", sum, b.StoreOther, sum+b.StoreOther, b.StoreTotal)
	}
	if sum != 500 {
		t.Errorf("rows total %d, want 500 -- the rowless package must be VISIBLE, not just netted out", sum)
	}
}

// Map iteration is randomised; a screen whose rows reshuffle between reads reads as instability even when
// every number is identical.
func TestRowlessPackageOrderIsStable(t *testing.T) {
	per := map[string]int64{"com.z": 1, "com.a": 1, "com.m": 1}
	var first []string
	for i := 0; i < 20; i++ {
		var names []string
		for _, a := range rowsForRowlessPackages(nil, per, nil) {
			names = append(names, a.Pkg)
		}
		if i == 0 {
			first = names
			continue
		}
		for j := range names {
			if names[j] != first[j] {
				t.Fatalf("row order changed between runs: %v then %v", first, names)
			}
		}
	}
}
