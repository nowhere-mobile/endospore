package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// NWP-20260903-13: an INFERRED drop must not disarm the shrink guard like a user's choice.
//
// The filed field case, one logoff, two scopes: #sys REFUSED its destructive shrink while #apps sealed
// 3 pkgs -> 2 unchallenged -- because the play-stack-orphan reconcile (an INFERENCE) had set the chooser's
// clearedStorageThisSession flag, and the logoff re-declare then armed the same profile-wide marker a
// deliberate storage-clearing tap arms. The marker's content said "deliberate". Nobody had deliberated.
//
// The split: the inference now declares itself on its own verb, scoped to #apps, with the packages it
// dropped -- and the guard's verdict (shrinkIntentAllowed, pure) lets an inferred marker vouch ONLY for
// those packages, verified against the manifest's own Pkg index. Unverifiable refuses: the same rule the
// build-number guard settled -- unverifiable is not the same as correct.

func TestDeliberateIntentAllowsOutright(t *testing.T) {
	ok, unexplained := shrinkIntentAllowed("deliberate", nil, map[string]int64{"a": 1}, nil, nil)
	if !ok || unexplained != nil {
		t.Fatalf("a deliberate marker must keep its pre-provenance authority: ok=%v unexplained=%v", ok, unexplained)
	}
}

func TestInferredIntentVouchesOnlyForItsPackages(t *testing.T) {
	oldPkg := map[string]int64{"com.android.vending": 9, "com.google.android.gms": 9, "com.other.app": 9}
	newPkg := map[string]int64{"com.other.app": 9}
	declared := []string{"com.android.vending", "com.google.android.gms"}
	ok, unexplained := shrinkIntentAllowed("inferred", declared, oldPkg, newPkg, nil)
	if !ok || len(unexplained) != 0 {
		t.Fatalf("an inferred drop that exactly explains the vanished set must pass: ok=%v unexplained=%v", ok, unexplained)
	}
}

func TestInferredIntentRefusesAnUnexplainedVanishing(t *testing.T) {
	oldPkg := map[string]int64{"com.android.vending": 9, "com.keep.me": 9}
	newPkg := map[string]int64{}
	ok, unexplained := shrinkIntentAllowed("inferred", []string{"com.android.vending"}, oldPkg, newPkg, nil)
	if ok {
		t.Fatal("com.keep.me vanished and the inference never named it -- allowing this is the filed bug")
	}
	if len(unexplained) != 1 || unexplained[0] != "com.keep.me" {
		t.Fatalf("the refusal must NAME the unexplained package: got %v", unexplained)
	}
}

func TestInferredIntentCountsDeferredAsPresent(t *testing.T) {
	// A package whose bytes all moved to the deferred tier is still carried -- its rels' first segment
	// names it. Vanishing-from-Pkg alone must not read as dropped.
	oldPkg := map[string]int64{"com.android.vending": 9, "com.deferred.app": 9}
	newPkg := map[string]int64{}
	rels := []string{"com.deferred.app/files/big.bin"}
	ok, unexplained := shrinkIntentAllowed("inferred", []string{"com.android.vending"}, oldPkg, newPkg, rels)
	if !ok {
		t.Fatalf("com.deferred.app is present via its deferred rel; only vending vanished and it was declared: unexplained=%v", unexplained)
	}
}

func TestInferredIntentRefusesWithoutAnIndex(t *testing.T) {
	ok, _ := shrinkIntentAllowed("inferred", []string{"com.android.vending"}, nil, nil, nil)
	if ok {
		t.Fatal("no Pkg index on the old head means the claim is unverifiable -- unverifiable must refuse")
	}
}

func TestInferredIntentRefusesWhenNothingVanished(t *testing.T) {
	oldPkg := map[string]int64{"a": 1}
	newPkg := map[string]int64{"a": 1}
	if ok, _ := shrinkIntentAllowed("inferred", []string{"a"}, oldPkg, newPkg, nil); ok {
		t.Fatal("no package vanished, so the shrink came from somewhere the inference cannot speak for")
	}
}

func TestProvenanceRoundTripAndLegacy(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := strings.Repeat("ab", 32)
	markShrinkIntentInferred(ref, []string{"p.one", "p.two"})
	kind, pkgs := shrinkIntentProvenance(ref)
	if kind != "inferred" || len(pkgs) != 2 || pkgs[0] != "p.one" || pkgs[1] != "p.two" {
		t.Fatalf("round trip: kind=%q pkgs=%v", kind, pkgs)
	}
	if !haveShrinkIntent(ref) {
		t.Fatal("an inferred marker must still register as an armed intent (lifetime/clearing unchanged)")
	}
	// The pre-provenance marker reads as deliberate -- old sessions keep old behaviour.
	ref2 := strings.Repeat("cd", 32)
	markShrinkIntent(ref2)
	if kind, _ := shrinkIntentProvenance(ref2); kind != "deliberate" {
		t.Fatalf("a legacy 'deliberate' marker read as %q", kind)
	}
	clearShrinkIntent(ref)
	if haveShrinkIntent(ref) {
		t.Fatal("clearShrinkIntent must clear an inferred marker identically")
	}
}

// TestGuardConsultsProvenance pins the CALL SITE: pushProfile's intent case must route through the
// provenance verdict, not bare existence. Same source-pin rationale as the overFree literal this morning:
// the regression is a one-line "simplification" back to haveShrinkIntent(rcptRef).
func TestGuardConsultsProvenance(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "pushProfile")), "\n")
	if !regexp.MustCompile(`shrinkIntentAllowed\(`).MatchString(body) {
		t.Fatal("pushProfile's guard no longer consults shrinkIntentAllowed -- an inferred marker disarms " +
			"the net by mere existence again (NWP-20260903-13)")
	}
	if regexp.MustCompile(`case haveShrinkIntent\(rcptRef\):`).MatchString(body) {
		t.Fatal("the guard's intent case is back to bare haveShrinkIntent(rcptRef) -- provenance is ignored")
	}
}
