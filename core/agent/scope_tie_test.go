package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261007-11: the groundwork for a tie that protects a profile's scopes (docs/tie-scope-keys.md §8). Direct-mode
// store; the wiring slice drives the same functions from SE-TIE in cap mode.

var tieSE1 = bytes.Repeat([]byte{0x51}, 32)
var tieSE2 = bytes.Repeat([]byte{0x52}, 32)

// scopeHeadVault reads the scope's current head vault (headRef answers the value only on cap backends).
func scopeHeadVault(t *testing.T, base, scoped, pass string) *vault {
	t.Helper()
	ref, head, have := headRef(base, scoped, pass)
	if !have {
		head = getRef(base, ref)
	}
	v, isV := parseVault(getHeadBlob(base, head))
	if !isV {
		t.Fatalf("%s: the head is not a vault", scoped)
	}
	return v
}

// readScopeFile restores a scope and returns its f.txt, or ok=false when no slot opens it for (pass, se).
func readScopeFile(t *testing.T, base, scoped, pass string, se []byte) (string, bool) {
	t.Helper()
	t.Setenv("NOWHERE_SE_SECRET", "") // the daemon's environment: se only as an argument
	key, mb, ok := resolveKeySession(base, scoped, pass, se)
	if !ok {
		return "", false
	}
	pt := unseal(key, mb)
	d := t.TempDir()
	if bytes.HasPrefix(pt, cdcMagic) {
		var m chunkManifest
		if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
			t.Fatalf("%s: manifest will not parse: %v", scoped, err)
		}
		cdcRestore(base, key, m, d)
	} else {
		untarFrom(d, bytes.NewReader(pt))
	}
	b, err := os.ReadFile(filepath.Join(d, "f.txt"))
	if err != nil {
		return "", true // opened, but holds no f.txt (an empty placeholder)
	}
	return string(b), true
}

// sessionKeys returns the vault, its DK (through the pass slot) and its scope index.
func sessionKeys(t *testing.T, base, name, pass string) (*vault, []byte, map[string]scopeRec) {
	t.Helper()
	v, err := readSessionVault(base, name, pass)
	if err != nil {
		t.Fatal(err)
	}
	dk := unwrapDK(v, "pass", deriveKey(name, pass))
	if dk == nil {
		dk = unwrapDK(v, "se", kekSE(name, pass, tieSE1)) // after the tie: the first phone's chip
	}
	if dk == nil {
		t.Fatal("neither the pass slot nor the first phone's chip opens the vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the vault carries no scope index")
	}
	return v, dk, idx
}

// tieWithScopes runs the three-step order of docs/tie-scope-keys.md §8; publishHeads=false stops after step 2, the
// state a crash between the vault and the scope heads leaves.
func tieWithScopes(t *testing.T, base, name, pass string, se []byte, publishHeads bool) []*scopeRekey {
	t.Helper()
	v, dk, idx := sessionKeys(t, base, name, pass)
	var rks []*scopeRekey
	for _, suf := range tieSmallScopes {
		rk, err := prepareScopeRekey(base, name, pass, suf, se, randBytes(32))
		if err != nil {
			t.Fatalf("prepare %s: %v", suf, err)
		}
		rks = append(rks, rk)
	}
	v.Scopes = sealScopeIndex(dk, rekeyedIndex(idx, dk, rks))
	tieSlots(v, name, pass, se, dk)
	if err := publishSessionVault(base, name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	if publishHeads {
		// Inside a bracket, as sessionTie runs it: its stale-check readings belong to one (NWP-20261009-07).
		capWrite(name, pass, dk, func() { publishScopeRekeys(base, name, pass, rks) })
	}
	return rks
}

func newTiedFixture(t *testing.T, name, pass string) (base, mnemonic string) {
	t.Helper()
	base = newHTTPStore(t)
	mnemonic = sealScopeFixture(t, base, name, pass)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture: one test binary shares the fence sample
	if got, ok := readScopeFile(t, base, name+"#de", pass, nil); !ok || got != "payload#de" {
		t.Fatalf("precondition: #de reads %q (%v) before the tie", got, ok)
	}
	return base, mnemonic
}

func TestTieRekeysTheSmallScopesAndKeepsTheirContent(t *testing.T) {
	const name, pass = "tiescopes", "horse battery staple correct"
	base, _ := newTiedFixture(t, name, pass)
	tieWithScopes(t, base, name, pass, tieSE1, true)

	if _, ok := readScopeFile(t, base, name+"#de", pass, nil); ok {
		t.Fatal("after the tie the passphrase ALONE still opens #de: the scope is not protected")
	}
	got, ok := readScopeFile(t, base, name+"#de", pass, tieSE1)
	if !ok || got != "payload#de" {
		t.Fatalf("the tied phone reads #de as %q (%v), want its content unchanged", got, ok)
	}
	if k, _, _ := resolveKeySession(base, name+"#de", pass, tieSE1); bytes.Equal(k, deriveKey(name+"#de", pass)) {
		t.Fatal("#de is still under deriveKey(name#de, pass): a passphrase guess derives it")
	}
	for _, suf := range []string{"#keys", "#sys"} { // never sealed: a placeholder, protected from the start
		if _, ok := readScopeFile(t, base, name+suf, pass, tieSE1); !ok {
			t.Errorf("%s has no head the tied phone opens: its first seal would create a passphrase-keyed one", suf)
		}
		if _, ok := readScopeFile(t, base, name+suf, pass, nil); ok {
			t.Errorf("%s opens with the passphrase alone", suf)
		}
	}
	_, _, idx := sessionKeys(t, base, name, pass)
	for _, suf := range tieSmallScopes {
		if !idx[suf].Minted || idx[suf].Prev == "" && suf == "#de" {
			t.Errorf("%s: the index does not record a minted key (and #de its previous one): %+v", suf, idx[suf])
		}
	}
}

// A scope head that is a vault carries its retained snapshots; the tie re-seals them too (Chester, 2026-10-07).
func TestTieReencryptsTheScopeHistory(t *testing.T) {
	const name, p1, p2 = "tiehist", "horse battery staple correct", "a brand new passphrase"
	base, _ := newTiedFixture(t, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil { // the scope head becomes a vault
		t.Fatal(err)
	}
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "f.txt"), []byte("second version"), 0o600)
	pushProfile(base, name+"#de", p2, d) // the first version becomes a retained snapshot
	pushFenceSeq, pushFenceSampled = 0, false
	oldKey, _, _ := resolveKeySession(base, name+"#de", p2, nil)

	tieWithScopes(t, base, name, p2, tieSE1, true)

	newKey, _, ok := resolveKeySession(base, name+"#de", p2, tieSE1)
	if !ok {
		t.Fatal("the tied phone does not open #de")
	}
	v := scopeHeadVault(t, base, name+"#de", p2)
	if len(v.History) == 0 {
		t.Fatal("precondition: #de carries no retained snapshot to re-seal")
	}
	for i, sn := range v.History {
		m, ml := classifyManifestLoad(base, newKey, sn.Manifest)
		if ml != mlOK {
			t.Fatalf("snapshot %d does not open under the new key (%v): restoring a version from before the tie fails", i, ml)
		}
		if _, ml := classifyManifestLoad(base, oldKey, sn.Manifest); ml == mlOK {
			t.Fatalf("snapshot %d still opens under the passphrase-derived key: a passphrase guess reads it", i)
		}
		dd := t.TempDir()
		cdcRestore(base, newKey, m, dd)
		if b, _ := os.ReadFile(filepath.Join(dd, "f.txt")); string(b) != "payload#de" {
			t.Fatalf("snapshot %d restores %q, want the first version", i, b)
		}
	}
}

func TestUntieScopesReopensThemByPassphraseWithoutReupload(t *testing.T) {
	const name, pass = "untiescopes", "horse battery staple correct"
	base, _ := newTiedFixture(t, name, pass)
	tieWithScopes(t, base, name, pass, tieSE1, true)
	tiedV := scopeHeadVault(t, base, name+"#de", pass)

	_, dk, _ := sessionKeys(t, base, name, pass)
	var uerr error
	capWrite(name, pass, dk, func() { uerr = untieScopeHeads(base, name, pass, tieSE1, tieSmallScopes) }) // as sessionUntie runs it
	if uerr != nil {
		t.Fatal(uerr)
	}
	got, ok := readScopeFile(t, base, name+"#de", pass, nil)
	if !ok || got != "payload#de" {
		t.Fatalf("after untie the passphrase reads #de as %q (%v)", got, ok)
	}
	v := scopeHeadVault(t, base, name+"#de", pass)
	if v.Manifest != tiedV.Manifest {
		t.Fatal("untie re-sealed the scope: its manifest changed, so the content was uploaded again")
	}
	for _, s := range v.Slots {
		if s.Kind == "se" {
			t.Fatal("untie left an se slot on #de")
		}
	}
}

func TestPassphraseChangeKeepsATiedScopeTied(t *testing.T) {
	const name, p1, p2 = "rottied", "horse battery staple correct", "a brand new passphrase"
	base, _ := newTiedFixture(t, name, p1)
	tieWithScopes(t, base, name, p1, tieSE1, true)

	if _, err := rotateVault(base, name, p1, p2, tieSE1, true); err != nil {
		t.Fatal(err)
	}
	if _, ok := readScopeFile(t, base, name+"#de", p2, nil); ok {
		t.Fatal("after a passphrase change #de opens with the new passphrase alone: the change untied it")
	}
	got, ok := readScopeFile(t, base, name+"#de", p2, tieSE1)
	if !ok || got != "payload#de" {
		t.Fatalf("after a passphrase change the tied phone reads #de as %q (%v)", got, ok)
	}
}

func TestRecoveryOpensTiedScopesUntied(t *testing.T) {
	const name, pass, p3 = "rectied", "horse battery staple correct", "the recovered passphrase"
	base, mnemonic := newTiedFixture(t, name, pass)
	tieWithScopes(t, base, name, pass, tieSE1, true)

	if err := recoverVault(base, name, mnemonic, p3); err != nil {
		t.Fatal(err)
	}
	got, ok := readScopeFile(t, base, name+"#de", p3, nil)
	if !ok || got != "payload#de" {
		t.Fatalf("after recovery #de reads %q (%v): the 12 words must still reach a tied scope's data", got, ok)
	}
}

// A crash after the vault carries the re-keyed index (step 2) but before the scope heads switch (step 3).
func TestACrashBeforeTheHeadsSwitchStaysOpenable(t *testing.T) {
	const name, pass, p3 = "tiecrash", "horse battery staple correct", "the recovered passphrase"
	base, mnemonic := newTiedFixture(t, name, pass)
	tieWithScopes(t, base, name, pass, tieSE1, false)

	got, ok := readScopeFile(t, base, name+"#de", pass, tieSE1)
	if !ok || got != "payload#de" {
		t.Fatalf("the tied phone reads #de as %q (%v) in the gap", got, ok)
	}
	if err := recoverVault(base, name, mnemonic, p3); err != nil {
		t.Fatalf("recovery in the gap: %v (the index's Prev must open the old head)", err)
	}
	if got, ok := readScopeFile(t, base, name+"#de", p3, nil); !ok || got != "payload#de" {
		t.Fatalf("after recovery in the gap #de reads %q (%v)", got, ok)
	}
}

func TestScopeKeyForUsesOnlyAKeyThatOpensTheHead(t *testing.T) {
	const name, pass = "keyfor", "horse battery staple correct"
	base, _ := newTiedFixture(t, name, pass)
	_, dk, idx := sessionKeys(t, base, name, pass)
	kek := kekScopes(dk)
	rec := idx["#de"]
	if _, ok := scopeKeyFor(base, rec, kek); !ok {
		t.Fatal("control: the recorded key does not open #de")
	}
	rec.Wrapped, rec.Prev = wrap(kek, randBytes(32)), ""
	if _, ok := scopeKeyFor(base, rec, kek); ok {
		t.Fatal("a recorded key that opens nothing was accepted")
	}
	rec.Prev = idx["#de"].Wrapped
	if _, ok := scopeKeyFor(base, rec, kek); !ok {
		t.Fatal("the previous key was not tried after a wrong current one")
	}
}

func TestAddedPhoneOpensTheTiedScopes(t *testing.T) {
	const name, pass = "addtied", "horse battery staple correct"
	base, mnemonic := newTiedFixture(t, name, pass)
	tieWithScopes(t, base, name, pass, tieSE1, true)

	if err := enrollSEViaRecovery(base, name, mnemonic, pass, tieSE2); err != nil {
		t.Fatal(err)
	}
	if got, ok := readScopeFile(t, base, name+"#de", pass, tieSE2); !ok || got != "payload#de" {
		t.Fatalf("the added phone reads #de as %q (%v): it opens the vault but not the profile's data", got, ok)
	}
	if _, ok := readScopeFile(t, base, name+"#de", pass, tieSE1); !ok {
		t.Fatal("adding a phone removed the first phone's access to #de")
	}
}

func TestTieIsIdempotentOnAScopeAlreadyTiedHere(t *testing.T) {
	const name, pass = "tieagain", "horse battery staple correct"
	base, _ := newTiedFixture(t, name, pass)
	tieWithScopes(t, base, name, pass, tieSE1, true)
	for _, suf := range tieSmallScopes {
		rk, err := prepareScopeRekey(base, name, pass, suf, tieSE1, randBytes(32))
		if err != nil {
			t.Fatal(err)
		}
		if rk.NewHead != "" {
			t.Errorf("%s: a second tie re-sealed a scope already tied on this phone", suf)
		}
	}
}

// With no index -- an older build strips it, the case rescueScopeIndex exists for -- a rotation has no recorded
// key to fall back on, so the tied scope must open through the session's se, given as an argument.
func TestPassphraseChangeKeepsATiedScopeTiedWithoutAnIndex(t *testing.T) {
	const name, p1, p2 = "rottiednoidx", "horse battery staple correct", "a brand new passphrase"
	base, _ := newTiedFixture(t, name, p1)
	tieWithScopes(t, base, name, p1, tieSE1, true)
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(tieSE1)) // only so the helper can open the tied vault
	stripScopeIndex(t, base, name, p1)
	t.Setenv("NOWHERE_SE_SECRET", "")

	if _, err := rotateVault(base, name, p1, p2, tieSE1, true); err != nil {
		t.Fatalf("a passphrase change on a tied profile with no index: %v", err)
	}
	if got, ok := readScopeFile(t, base, name+"#de", p2, tieSE1); !ok || got != "payload#de" {
		t.Fatalf("after the change the tied phone reads #de as %q (%v)", got, ok)
	}
	if _, ok := readScopeFile(t, base, name+"#de", p2, nil); ok {
		t.Fatal("after the change #de opens with the new passphrase alone")
	}
}
