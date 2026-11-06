package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestRecoveryReachesEveryScope asks the question TestFootprintCopyRoundTripsRecovery structurally cannot.
//
// That test calls pushProfile ONCE, with the bare name, so the only head it ever creates is the vault's. It
// then recovers and checks the vault resolves -- which it does. But a real profile is SIX heads: the bare
// vault plus `#de`, `#sys`, `#media`, `#apps` and `#keys`, and essentially all of the bytes live in the five
// it never creates. So the passing test is not evidence that a recovery returns a user's DATA; it is
// evidence that it returns their vault.
//
// The mechanism, read at source: a scope head's LOCATION is headKey(base, name#scope, pass) -> profileRefV2
// = HMAC(deriveKey(name#scope, pass)) (profileRefV2, deriveKey and headKey in main.go), and its KEY is deriveKey(name#scope, pass)
// directly -- a scope head is a BARE head, not a vault, so it carries no keyslots and therefore no recovery
// slot (buildVault has exactly three callers, createVaultWalletProg, migrateVault and recoverVault, and all three pass the BARE name).
// recoverVault rewrites only the bare head; it contains no scope loop, and neither does rotateVault. So both
// the location and the key of every scope move when the passphrase moves, and nothing migrates them.
//
// If that reading is right, this test fails at the #de assertion and the failure IS the finding: a user who
// recovers with their 12 words on a new handset gets their vault back and their app data, media, accounts,
// APKs and Keystore blobs stay at a passphrase they no longer know.
func TestRecoveryReachesEveryScope(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "scoperec", "footprint horse battery staple"
	mnemonic := createVault(base, name, pass)

	// Seal the bare vault AND a scope, the way a real session does -- pushProfile runs once per scope with
	// the SCOPED name.
	bare := t.TempDir()
	if err := os.WriteFile(filepath.Join(bare, "vault.txt"), []byte("the vault payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, bare)

	de := t.TempDir()
	if err := os.WriteFile(filepath.Join(de, "de.txt"), []byte("the #de payload -- app data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#de", pass, de)

	// Preconditions: under the ORIGINAL passphrase both the vault and the scope resolve. If either fails the
	// test is mis-built and proves nothing.
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Fatal("precondition: vault does not resolve under the original passphrase")
	}
	if _, _, ok := resolveKey(base, name+"#de", pass); !ok {
		t.Fatal("precondition: #de does not resolve under the original passphrase -- the scope was never sealed")
	}
	deHeadOld := headKey(base, name+"#de", pass)

	// The canonical lost-phone path: recover with the 12 words to a NEW passphrase.
	const newpass = "a brand new passphrase"
	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}

	// The vault comes back. This is what the existing test asserts, and it passes.
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("vault does not resolve after recovery -- unrelated breakage")
	}

	// THE QUESTION. Does the user's data come back with it?
	if _, _, ok := resolveKey(base, name+"#de", newpass); !ok {
		t.Errorf("#de IS UNREACHABLE AFTER RECOVERY. The vault resolves under the new passphrase; the scope "+
			"holding the app data does not. The scope head is still at headKey(name#de, OLD pass) = %q, and "+
			"the recovering user no longer knows that passphrase -- that is why they recovered. On the "+
			"profile measured in docs/profile-snapshot.md the vault is ~22 MB of ~600 MB; media, app data, "+
			"accounts, APKs and Keystore blobs are stranded.", deHeadOld)
	}
}

// TestRecoveryFootprintIsSuperset is the DISCRIMINATING assertion for NWP-20260915-02: it fails against
// today's code AND against the obvious-but-wrong version of the fix, which is what makes it worth writing
// first.
//
// Why the footprint rather than just "does #de resolve": profileFootprint is the lease set that keeps a
// profile's objects alive against the gateway GC, and it is also the copy recipe an export walks
// (footprint_list.go). So "every object the profile occupied before the recovery is still named after it"
// is simultaneously the data-reachability property, the do-not-get-reaped property, and the
// can-still-be-exported property. One assertion, three guarantees.
//
// Why it also convicts the WRONG fix: a design that re-points the scope heads but wraps their keys in a slot
// kind only recoverVault understands would let the resolveKey calls above pass while scopeFootprint -- which
// runs in a SEPARATE agent process with no profile DK in hand -- still fails to open the manifest and
// silently leases only the head pointer ("can't open the manifest -> lease just the head (defensive)").
// That failure is invisible at the resolve layer and fatal at the billing layer, so the superset check is
// the one that catches it.
func TestRecoveryFootprintIsSuperset(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "fpsuper", "footprint horse battery staple"
	mnemonic := createVault(base, name, pass)

	for _, sc := range []struct{ suffix, payload string }{
		{"", "the vault payload"},
		{"#de", "the #de payload -- app data"},
		{"#media", "the #media payload -- photos"},
	} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte(sc.payload), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, name+sc.suffix, pass, d)
	}

	before, _ := profileFootprint(base, name, pass, nil)
	if len(before) == 0 {
		t.Fatal("precondition: empty footprint before the recovery")
	}

	// ⚠ A STRICT SUPERSET IS THE WRONG PROPERTY, and saying why is the point of this block.
	//
	// A credential change legitimately SUPERSEDES two classes of object: the head REFS it re-points away
	// from, and the head BLOBS those refs named. Both are pure pointers -- the data they pointed at is
	// content-addressed and is re-named by the new heads -- so their leaving the footprint is correct, and
	// is in fact the mechanism by which the old pointers eventually age out.
	//
	// What must NEVER leave is a DATA object. So the assertion is: everything except the superseded
	// pointers survives. Recording them here, before the recovery, is the only moment they are nameable.
	superseded := map[string]bool{}
	for _, suf := range []string{"", "#de", "#media"} {
		ref := headKey(base, name+suf, pass)
		superseded["ref/"+ref] = true
		if h := getRef(base, ref); h != "" {
			superseded["blob/"+h] = true
		}
	}

	const newpass = "a brand new passphrase"
	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}
	after, _ := profileFootprint(base, name, newpass, nil)

	var lost []string
	for k := range before {
		if _, ok := after[k]; ok || superseded[k] {
			continue
		}
		lost = append(lost, k)
	}
	sort.Strings(lost)
	if len(lost) > 0 {
		t.Errorf("THE RECOVERY DROPPED %d DATA OBJECTS FROM THE PROFILE FOOTPRINT (before: %d, after: %d). "+
			"These are not superseded pointers -- they are objects the profile still occupies and still pays "+
			"for, which the walk no longer names, so each is un-leased against the gateway GC, absent from "+
			"any export driven by this walk, and unreachable by its owner. lost: %s",
			len(lost), len(before), len(after), strings.Join(lost, " "))
	}
	// ...and the re-point must have ADDED the new heads, or nothing was actually re-pointed and the check
	// above passed only because the old objects happened to survive.
	if len(after) <= len(before) {
		t.Errorf("the footprint did not grow across the recovery (%d -> %d): the re-pointed scope heads "+
			"should be new objects the walk now names", len(before), len(after))
	}
}
