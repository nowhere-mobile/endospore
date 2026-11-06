package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestCreateVaultMintsTheScopeIndex: the index must exist from the FIRST moment a profile does, not from its
// first seal. A profile created, used for one session and then recovered is the canonical "wrote down my 12
// words, then lost the phone" case, and roamd seals the bare vault BEFORE any scope -- so an index minted
// only on observation would be empty for exactly that user.
func TestCreateVaultMintsTheScopeIndex(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "mintcreate", "horse battery staple correct"
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("the fresh vault does not resolve")
	}
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("the fresh head is not a vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("A BRAND-NEW VAULT CARRIES NO SCOPE INDEX. A profile created, used once and then recovered " +
			"is precisely the lost-phone case, and it would recover to an empty profile.")
	}
	// NWP-20260917-04: +1 for the RESERVED scopeBillKey entry, which is not a scope -- it records the
	// profile's own billing key so a recovery can name the plan it is moving off.
	if len(idx) != len(scopeIndexSuffixes)+1 {
		t.Errorf("index has %d entries, want %d -- it must be DERIVED for every scope, not observed",
			len(idx), len(scopeIndexSuffixes)+1)
	}
	if billKeyOf(idx) != profileRefV2(name, pass) {
		t.Error("a brand-new vault does not record its billing key, so its first RECOVERY could not name " +
			"the plan to carry -- and recovery is the case plan continuity exists for")
	}
	for _, suf := range scopeIndexSuffixes {
		if idx[suf].Ref == "" {
			t.Errorf("%s: no location recorded -- the location is the one fact a recovery cannot derive "+
				"for itself", suf)
		}
		// ⚠ A KEY IS RECORDED FOR EVERY SUFFIX EXCEPT THE ONE WHOSE HEAD IS SEALED UNDER THE PROFILE DK.
		// Asserted in BOTH directions on purpose: a missing key for a real scope would leave a recovery
		// unable to open it, and a PRESENT key for #wallet is the false record NWP-20260915-17 removed.
		if scopeSealedUnderDK(suf) != (idx[suf].Wrapped == "") {
			t.Errorf("%s: wrapped=%q, but scopeSealedUnderDK says %v", suf, idx[suf].Wrapped, scopeSealedUnderDK(suf))
		}
	}
}

// TestBareSealRefreshesTheIndexAndScopeSealsDoNot pins both halves of the guard in pushProfile: a bare seal
// REFRESHES the index (this is what migrates a fielded profile, while the user still holds the passphrase),
// and a SCOPE seal must never write an index of its own.
func TestBareSealRefreshesTheIndexAndScopeSealsDoNot(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "mintseal", "horse battery staple correct"
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}

	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, d) // BARE seal

	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("vault does not resolve after the bare seal")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if _, ok := openScopeIndex(dk, v.Scopes); !ok {
		t.Fatal("A BARE SEAL DID NOT REFRESH THE SCOPE INDEX. That seal is the migration path for every " +
			"fielded profile -- it is the only moment the scope keys are derivable, because it is the only " +
			"moment the passphrase is in hand.")
	}

	// A SCOPE seal writes a bare head today, so there is no vault to carry an index. The assertion is that
	// nothing has started minting one: an index on a scope head would be a profile inside a profile, and
	// after the re-point work a scope head IS a vault, so this guard is what keeps that vault index-free.
	pushProfile(base, name+"#de", pass, d)
	sv, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name+"#de", pass))))
	if isV && sv.Scopes != "" {
		t.Error("a SCOPE head carries a scope index of its own -- guard the mint on !strings.Contains(profile, \"#\")")
	}
}

// TestRecoveryCarriesTheIndexEndToEnd is the wiring check between carryForward and the real recovery path:
// after a recovery the new vault must still carry an index that opens under the (unchanged) DK. Without it
// the re-point step that follows has nothing to work from.
func TestRecoveryCarriesTheIndexEndToEnd(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "mintrec", "horse battery staple correct"
	mnemonic := createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, d)

	const newpass = "a brand new passphrase"
	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}
	dk, _, ok := resolveKey(base, name, newpass)
	if !ok {
		t.Fatal("vault does not resolve after recovery")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, newpass))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("THE RECOVERED VAULT CARRIES NO SCOPE INDEX -- carryForward dropped it, and the re-point " +
			"step has nothing to find the scopes with.")
	}
	// The recovery RE-POINTS the scopes, so the index it leaves behind must name where they landed -- the
	// refs under the NEW passphrase -- and not where they used to be. (Before repointScopes existed this
	// test asserted the opposite, which was right for a recovery that only carried the index and wrong for
	// one that acts on it.)
	for _, suf := range scopeIndexSuffixes {
		want, _ := headWriteRef(name+suf, newpass)
		if idx[suf].Ref != want {
			t.Errorf("%s: the recovered index names %q, but the re-point published the head at %q",
				suf, idx[suf].Ref, want)
		}
	}
	// And the recorded key must still OPEN the scope, which is the half a wrong re-point gets wrong
	// silently: a head that resolves but whose manifest is gibberish looks fine until someone reads it.
	key, kok := unwrap(kekScopes(dk), idx["#de"].Wrapped)
	if !kok {
		t.Fatal("#de: the recorded key does not unwrap under kekScopes(dk) after the recovery")
	}
	if got, _, ok := resolveKey(base, name+"#de", newpass); ok && string(got) != string(key) {
		t.Error("#de: the key the index records is not the key resolveKey returns for the re-pointed head -- " +
			"a later recovery would re-point it under the wrong key")
	}
}
