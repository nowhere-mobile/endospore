package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const seedHeader = "# pkg\tunit -- written by the seal; empty means nothing is held elsewhere\n"

// seedEnv points the unit id at a temp file holding `own` and the seed at a path in a fresh dir.
func seedEnv(t *testing.T, own string) (dir, seed string) {
	t.Helper()
	dir = t.TempDir()
	orig := unitIDPath
	unitIDPath = filepath.Join(dir, "unit-id")
	t.Cleanup(func() { unitIDPath = orig })
	if err := os.WriteFile(unitIDPath, []byte(own), 0o600); err != nil {
		t.Fatal(err)
	}
	seed = filepath.Join(dir, "claims.seed")
	t.Setenv("NOWHERE_CLAIMS_SEED", seed)
	t.Setenv("NOWHERE_UNIT_SRC", "")
	return dir, seed
}

func TestClaimsSeed_OnlyOtherHandsetsLiveClaims(t *testing.T) {
	_, seed := seedEnv(t, unitA)
	now := time.Now().Unix()
	seedClaimsAtRestore(map[string]appClaim{
		"com.seed.a": {Unit: unitB, At: now},
		"com.seed.b": {Unit: unitA, At: now},
		"com.seed.c": {Unit: unitB, At: now - claimTTL - 60},
	})
	b, err := os.ReadFile(seed)
	if err != nil {
		t.Fatalf("no seed written: %v", err)
	}
	if want := seedHeader + "com.seed.a\t" + unitB + "\n"; string(b) != want {
		t.Errorf("seed = %q, want %q", b, want)
	}
	if fi, _ := os.Stat(seed); fi == nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("seed mode = %v, want 0600", fi)
	}
}

func TestClaimsSeed_ForeignUnitHeadNeverSeeds(t *testing.T) {
	_, seed := seedEnv(t, unitA)
	t.Setenv("NOWHERE_UNIT_SRC", unitB)
	seedClaimsAtRestore(map[string]appClaim{"com.seed.a": {Unit: unitB, At: time.Now().Unix()}})
	if _, err := os.Stat(seed); !os.IsNotExist(err) {
		t.Fatalf("a restore from another unit seeded enforcement (stat err=%v)", err)
	}
}

func TestClaimsSeed_NoSeedPathWritesNothing(t *testing.T) {
	dir, _ := seedEnv(t, unitA)
	t.Setenv("NOWHERE_CLAIMS_SEED", "")
	seedClaimsAtRestore(map[string]appClaim{"com.seed.a": {Unit: unitB, At: time.Now().Unix()}})
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 || ents[0].Name() != "unit-id" {
		t.Fatalf("files written with no seed path: %v", ents)
	}
}

func TestClaimsSeed_EmptyMapWritesTheHeaderOnly(t *testing.T) {
	for name, m := range map[string]map[string]appClaim{"nil": nil, "empty": {}} {
		_, seed := seedEnv(t, unitA)
		seedClaimsAtRestore(m)
		b, err := os.ReadFile(seed)
		if err != nil || string(b) != seedHeader {
			t.Errorf("%s map: seed = %q, %v; want the header only", name, b, err)
		}
	}
}

// The seal's file must not change by a byte with the split.
func TestClaimsSeed_SealFileIsByteIdenticalAfterTheSplit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "claims")
	t.Setenv("NOWHERE_CLAIMS_OUT", p)
	writeClaimsOut(map[string]appClaim{
		"com.zzz":  {Unit: unitB, At: t0},
		"com.aaa":  {Unit: unitB, At: t0},
		"com.mine": {Unit: unitA, At: t0},
		"com.old":  {Unit: unitB, At: t0 - claimTTL},
	}, unitA, t0)
	b, _ := os.ReadFile(p)
	want := "# pkg\tunit -- written by the seal; empty means nothing is held elsewhere\n" +
		"com.aaa\t" + unitB + "\ncom.zzz\t" + unitB + "\n"
	if string(b) != want {
		t.Errorf("seal file = %q, want %q", b, want)
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("tmp left behind (stat err=%v)", err)
	}
}

// restoreSeedGuarded checks, in main.go's source, that the restore command seeds from the CDC manifest, only
// for the bare vault, and before the chunks are restored.
func restoreSeedGuarded(src string) error {
	if strings.Count(src, "seedClaimsAtRestore(") != 1 {
		return errSeed("seedClaimsAtRestore must be called exactly once in main.go")
	}
	i := strings.Index(src, `case "restore":`)
	if i < 0 {
		return errSeed("no restore case")
	}
	rest := src[i:]
	const parse = "check(json.Unmarshal(pt[len(cdcMagic):], &m))"
	j := strings.Index(rest, parse)
	k := strings.Index(rest, "skipped = restoreSkippingParked(base, key, profile, mediaRestorePlan(profile, pass, restoredHead, m), dest)")
	if j < 0 || k < 0 || j > k {
		return errSeed("manifest parse / cdcRestore anchors not found in order")
	}
	var code []string
	for _, ln := range strings.Split(rest[j+len(parse):k], "\n") {
		if t := strings.TrimSpace(ln); t != "" && !strings.HasPrefix(t, "//") {
			code = append(code, t)
		}
	}
	if len(code) < 2 || !strings.HasPrefix(code[0], `if !strings.Contains(profile, "#") {`) ||
		code[1] != "seedClaimsAtRestore(m.Claims)" {
		return errSeed("the seed call is not guarded by the bare-vault condition right after the manifest parse")
	}
	return nil
}

type errSeed string

func (e errSeed) Error() string { return string(e) }

func TestClaimsSeed_RestoreSeedsTheBareVaultOnly(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if err := restoreSeedGuarded(src); err != nil {
		t.Fatal(err)
	}
	guard := "\t\t\tif !strings.Contains(profile, \"#\") { // NWP-20261029-06: the bare vault head carries Claims (app_claim.go)\n"
	if !strings.Contains(src, guard) {
		t.Fatal("self-check anchor missing")
	}
	noGuard := strings.Replace(src, guard+"\t\t\t\tseedClaimsAtRestore(m.Claims)\n\t\t\t}\n", "\t\t\tseedClaimsAtRestore(m.Claims)\n", 1)
	if restoreSeedGuarded(noGuard) == nil {
		t.Error("an unguarded call passes the scan")
	}
	moved := strings.Replace(src, guard+"\t\t\t\tseedClaimsAtRestore(m.Claims)\n\t\t\t}\n", "", 1)
	moved = strings.Replace(moved, "skipped = restoreSkippingParked(base, key, profile, mediaRestorePlan(profile, pass, restoredHead, m), dest)\n", "skipped = restoreSkippingParked(base, key, profile, mediaRestorePlan(profile, pass, restoredHead, m), dest)\n"+guard+"\t\t\t\tseedClaimsAtRestore(m.Claims)\n\t\t\t}\n", 1)
	if restoreSeedGuarded(moved) == nil {
		t.Error("a call after cdcRestore passes the scan")
	}
}
