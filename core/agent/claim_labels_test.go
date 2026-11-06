package main

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

// NWP-20261125-06: the holder's name in the claim file (h54 #1, `docs/product-decisions.md`, 2026-11-02).
// Each holding unit's label rides beside Claims in the sealed bare-vault manifest; the seal compares the holder's
// label with this phone's own deviceLabel() and writes the name as the claim file's third column, or nothing.

const unitC = "cccc3333"

func TestClaimLabels_LabelsToPublish_OwnSetWhileHolding(t *testing.T) {
	claims := map[string]appClaim{"com.mine": {Unit: unitA, At: t0}}
	got := labelsToPublish(nil, claims, unitA, "Pixel 9")
	if want := map[string]string{unitA: "Pixel 9"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("labelsToPublish = %v, want %v", got, want)
	}
}

func TestClaimLabels_LabelsToPublish_OwnDroppedWhenHoldingNothing(t *testing.T) {
	old := map[string]string{unitA: "Pixel 9", unitB: "Pixel 8"}
	claims := map[string]appClaim{"com.theirs": {Unit: unitB, At: t0}}
	got := labelsToPublish(old, claims, unitA, "Pixel 9")
	if _, ok := got[unitA]; ok {
		t.Fatalf("this unit holds nothing, but its label was kept: %v", got)
	}
	if got[unitB] != "Pixel 8" {
		t.Fatalf("the other unit's label was lost: %v", got)
	}
}

func TestClaimLabels_LabelsToPublish_OtherKeptVerbatimWhileItHolds(t *testing.T) {
	old := map[string]string{unitB: " Pixel 8 "}
	claims := map[string]appClaim{"com.theirs": {Unit: unitB, At: t0}}
	got := labelsToPublish(old, claims, unitA, "Pixel 9")
	if want := map[string]string{unitB: " Pixel 8 "}; !reflect.DeepEqual(got, want) {
		t.Fatalf("another unit's entry must be carried unchanged: got %q, want %q", got, want)
	}
}

func TestClaimLabels_LabelsToPublish_OtherDroppedOnceItsClaimsLapse(t *testing.T) {
	oldClaims := map[string]appClaim{"com.theirs": {Unit: unitB, At: t0 - claimTTL - 1}}
	claims, _ := claimsToPublish(oldClaims, unitA, []string{"com.mine"}, t0)
	got := labelsToPublish(map[string]string{unitB: "Pixel 8"}, claims, unitA, "Pixel 9")
	if _, ok := got[unitB]; ok {
		t.Fatalf("a label must leave with its unit's lapsed claims: %v", got)
	}
	if got[unitA] != "Pixel 9" {
		t.Fatalf("this unit's label is missing: %v", got)
	}
}

func TestClaimLabels_LabelsToPublish_NilWhenEmpty(t *testing.T) {
	if got := labelsToPublish(map[string]string{unitB: "Pixel 8"}, nil, unitA, "Pixel 9"); got != nil {
		t.Fatalf("no claims must publish no labels, got %v", got)
	}
	mj, _ := json.Marshal(chunkManifest{})
	if strings.Contains(string(mj), "labels") {
		t.Fatalf("an empty manifest carries a labels key: %s", mj)
	}
}

func TestClaimLabels_LabelsToPublish_InvalidOwnLabelNotPublished(t *testing.T) {
	claims := map[string]appClaim{"com.mine": {Unit: unitA, At: t0}}
	for _, l := range []string{"", "a\tb", "x\ny"} {
		if got := labelsToPublish(nil, claims, unitA, l); got != nil {
			t.Errorf("label %q was published: %v", l, got)
		}
	}
}

func TestClaimLabels_HolderNames_DifferentLabelsNameEachOther(t *testing.T) {
	if got := holderNames(map[string]string{unitA: "Pixel 8", unitB: "Pixel 9"}, "Pixel 9"); !reflect.DeepEqual(got,
		map[string]string{unitA: "Pixel 8"}) {
		t.Errorf("the Pixel 9 does not name the Pixel 8: %v", got)
	}
	if got := holderNames(map[string]string{unitA: "Pixel 8", unitB: "Pixel 9"}, "Pixel 8"); !reflect.DeepEqual(got,
		map[string]string{unitB: "Pixel 9"}) {
		t.Errorf("the Pixel 8 does not name the Pixel 9: %v", got)
	}
}

func TestClaimLabels_HolderNames_EqualOrAbsentGiveNone(t *testing.T) {
	if got := holderNames(map[string]string{unitB: " Pixel 8 "}, "Pixel 8"); got != nil {
		t.Errorf("two equal labels must give \"your other device\", got %v", got)
	}
	if got := holderNames(nil, "Pixel 8"); got != nil {
		t.Errorf("an absent label must give \"your other device\", got %v", got)
	}
	if got := holderNames(map[string]string{unitC: "Pixel 7"}, "Pixel 8"); got[unitB] != "" {
		t.Errorf("a unit without a label was named: %v", got)
	}
}

func TestClaimLabels_HolderNames_InvalidCarriedGivesNone(t *testing.T) {
	if got := holderNames(map[string]string{unitA: "a\tb", unitB: "x\ny", unitC: ""}, "Pixel 8"); got != nil {
		t.Errorf("an invalid carried label reached the names: %q", got)
	}
}

func TestClaimLabels_WriteClaimsTo_WithAndWithoutName(t *testing.T) {
	m := map[string]appClaim{
		"com.a":    {Unit: unitB, At: t0},
		"com.b":    {Unit: unitC, At: t0},
		"com.mine": {Unit: unitA, At: t0},
	}
	dir := t.TempDir()
	named := dir + "/named"
	if n, err := writeClaimsToNamed(named, m, unitA, t0, false, map[string]string{unitB: "Pixel 8"}); err != nil || n != 2 {
		t.Fatalf("writeClaimsToNamed = %d, %v", n, err)
	}
	b, _ := os.ReadFile(named)
	if want := seedHeader + "com.a\t" + unitB + "\tPixel 8\n" + "com.b\t" + unitC + "\n"; string(b) != want {
		t.Fatalf("named file:\n%q\nwant\n%q", b, want)
	}
	plain := dir + "/plain"
	if _, err := writeClaimsTo(plain, m, unitA, t0, false); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(plain)
	if want := seedHeader + "com.a\t" + unitB + "\n" + "com.b\t" + unitC + "\n"; string(b) != want {
		t.Fatalf("unnamed file:\n%q\nwant\n%q", b, want)
	}
}

// The moderator ruling of 2026-11-03: only the seal writes the name; the sign-in seed stays two columns.
func TestClaimLabels_SeedStaysTwoColumns(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "seedClaimsAtRestore(m.Claims)\n") {
		t.Errorf("the restore's seed call changed; the sign-in seed stays two columns")
	}
	ac, err := os.ReadFile("app_claim.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(ac), "func seedClaimsAtRestore(m map[string]appClaim) {") {
		t.Errorf("seedClaimsAtRestore's signature changed")
	}
}

// The seal level, in the two-unit shape of TestClaims_AScopedSealPublishesNothingAndDoesNotClobberTheEnforcementFile.
func TestClaimLabels_SealNamesTheHolder(t *testing.T) {
	for _, tc := range []struct {
		profile, labelTwo string
		named             bool
	}{
		{"labelpair", "Pixel 9", true},
		{"labelsame", "Pixel 8", false},
	} {
		t.Run(tc.profile, func(t *testing.T) { sealNamesTheHolder(t, tc.profile, tc.labelTwo, tc.named) })
	}
}

func sealNamesTheHolder(t *testing.T, name, labelTwo string, named bool) {
	fenceTestEnv(t)
	t.Setenv("NOWHERE_SEAL_FORCE", "1")

	origUnit, origLabel, origModel := unitIDPath, deviceLabelPath, deviceModelFn
	defer func() { unitIDPath, deviceLabelPath, deviceModelFn = origUnit, origLabel, origModel }()
	deviceModelFn = func() string { return "" }

	pass := "labels battery staple"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	dir := t.TempDir()
	held := dir + "/held"
	out := dir + "/claims"
	t.Setenv("NOWHERE_HELD_LIST", held)
	t.Setenv("NOWHERE_CLAIMS_OUT", out)
	deviceLabelPath = dir + "/device-label"
	write := func(p, body string) {
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	// UNIT ONE ("Pixel 8") holds com.theirs.
	unitIDPath = dir + "/unit-one"
	write(deviceLabelPath, "Pixel 8\n")
	write(held, "com.theirs\n")
	sealDone()
	pushProfile(base, name, pass, seedDir(t, 2))
	b, err := os.ReadFile(dir + "/unit-one")
	if err != nil {
		t.Fatalf("unit one has no unit id: %v", err)
	}
	unitOne := strings.TrimSpace(string(b))

	// UNIT TWO holds com.mine.
	unitIDPath = dir + "/unit-two"
	write(deviceLabelPath, labelTwo+"\n")
	write(held, "com.mine\n")
	sealDone()
	pushProfile(base, name, pass, seedDir(t, 3))
	b, err = os.ReadFile(dir + "/unit-two")
	if err != nil {
		t.Fatalf("unit two has no unit id: %v", err)
	}
	unitTwo := strings.TrimSpace(string(b))

	first, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("the bare seal wrote no claim file: %v", err)
	}
	want := seedHeader + "com.theirs\t" + unitOne + "\n"
	if named {
		want = seedHeader + "com.theirs\t" + unitOne + "\tPixel 8\n"
	}
	if string(first) != want {
		t.Fatalf("claim file:\n%q\nwant\n%q", first, want)
	}
	bm := headManifestOf(t, base, name, pass)
	wantLabels := map[string]string{unitOne: "Pixel 8", unitTwo: labelTwo}
	if !reflect.DeepEqual(bm.Labels, wantLabels) {
		t.Fatalf("the bare head's Labels = %v, want %v", bm.Labels, wantLabels)
	}

	// A scoped seal neither writes nor drops the labels, and leaves the claim file alone.
	sealDone()
	pushProfile(base, name+"#de", pass, seedDir(t, 2))
	if dm := headManifestOf(t, base, name+"#de", pass); len(dm.Labels) != 0 {
		t.Errorf("a #de seal published labels: %v", dm.Labels)
	}
	if am := headManifestOf(t, base, name, pass); !reflect.DeepEqual(am.Labels, wantLabels) {
		t.Errorf("the bare head's Labels changed after a #de seal: %v", am.Labels)
	}
	after, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("the claim file vanished after a scoped seal: %v", err)
	}
	if string(after) != string(first) {
		t.Errorf("a #de seal rewrote the claim file:\nbefore %q\nafter  %q", first, after)
	}
}
