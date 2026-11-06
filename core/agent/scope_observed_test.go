package main

// NWP-20260915-18: a delete tombstone is only evidence of a LOSS if somebody actually saw a scope there.
//
// deleteProfile tombstones all seven suffixes -- an empty object that EXISTS, deliberately, because delRef
// must never hard-delete (a just-DELETED key on Filebase can still serve stale pinned content, which is the
// original "deleted but still logs in" bug, proven on FP3). createVault re-publishes only the bare head, the
// recovery ref and the wallet, so a re-created profile sits on six tombstones forever and nothing clears
// them. Meanwhile createVault MINTS the whole scope index -- at a moment when, by construction, not one
// scope exists -- so every entry pointed at one of those tombstones.
//
// repointScopes read that as "a scope was deleted out from under this profile" and refused. Permanently, on
// ROTATION and on RECOVERY, and RECOVER answers only OK or BLANK -- so a user holding a CORRECT twelve-word
// phrase, who had already lost a handset, was told the phrase was wrong.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// recreatedProfile deletes a profile and creates it again at the SAME name and passphrase, which is the
// state this whole file is about. Returns the new recovery mnemonic.
func recreatedProfile(t *testing.T, base, name, pass string) string {
	t.Helper()
	createVault(base, name, pass)
	// Seal a SCOPE in the first life, not just the bare vault. deleteProfile tombstones only refs that
	// already exist ("no litter for never-used scopes"), so a profile that never had #de leaves no tombstone
	// there and this fixture would skip its way to a green run while testing nothing. That also sharpens the
	// trigger for NWP-20260915-18: the tombstones a re-created profile trips over are exactly the scopes it
	// really had -- which, for any profile that was ever signed into, includes #de.
	for _, suf := range []string{"", "#de"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("first life"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, name+suf, pass, d)
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("deleteProfile = %q, want \"deleted\" -- the fixture never reached the state under test", got)
	}
	m := createVault(base, name, pass)
	if m == "" {
		t.Fatal("re-create returned no recovery code")
	}
	return m
}

// TestADeletedAndRecreatedProfileCanStillChangeItsPassphrase is the headline. A user who deletes a profile
// and makes a new one at the same name -- their own action, and one the product invites -- could never
// change that passphrase again.
func TestADeletedAndRecreatedProfileCanStillChangeItsPassphrase(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "recreatedrot", "horse battery staple correct", "a brand new passphrase"
	recreatedProfile(t, base, name, pass)

	// The tombstones must really be there, or this test proves nothing about them.
	ref, _ := headWriteRef(name+"#de", pass)
	if !refExists(base, ref) || getRef(base, ref) != "" {
		t.Fatal("FIXTURE BROKE: the #de scope is not present after it was tombstoned -- this backend keeps an empty ref present (newHTTPStore stores \"\"; delRef writes an empty object), so the fixture no longer reaches the state under test")
	}

	if _, err := rotateVault(base, name, pass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault refused a re-created profile: %v"+
			"\n\nThe six scope refs are tombstones this profile's OWN re-create left behind, at addresses "+
			"nothing has ever sealed a scope to. Refusing here means a profile that was once deleted can "+
			"never change its passphrase again.", err)
	}
}

// TestADeletedAndRecreatedProfileCanStillBeRecovered is the same defect on the path where it costs most.
// recoverVault runs the same repointScopes, and the RECOVER verb answers only OK or BLANK -- the blind-login
// wrong-credentials reply. So the refusal reached the user as "that recovery phrase doesn't match", told to
// someone holding a correct one who has already lost a phone and has no other way in.
func TestADeletedAndRecreatedProfileCanStillBeRecovered(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "recreatedrec", "horse battery staple correct", "a brand new passphrase"
	mnemonic := recreatedProfile(t, base, name, pass)

	ref, _ := headWriteRef(name+"#de", pass)
	if !refExists(base, ref) || getRef(base, ref) != "" {
		t.Fatal("FIXTURE BROKE: the #de scope is not present after it was tombstoned -- this backend keeps an empty ref present (newHTTPStore stores \"\"; delRef writes an empty object), so the fixture no longer reaches the state under test")
	}

	if err := recoverVault(base, name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault refused a CORRECT recovery phrase: %v"+
			"\n\nThe daemon turns any error here into BLANK, which is the same reply a wrong phrase gets. "+
			"There is no other route into the profile once the passphrase is gone.", err)
	}
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("recovery reported success but the profile does not open under the new passphrase")
	}
}

// TestATombstoneIsNotEvidenceUntilSomebodySawTheScope is the rule itself, stated at the seam, and it is the
// boundary the fix deliberately draws. Both rows are the same store state -- an empty-but-present ref -- and
// the ONLY thing that separates them is whether the index says anyone ever saw a head there.
//
// ⚠ THE NARROWING IS REAL AND IS PINNED HERE ON PURPOSE. A scope lost before any observation was recorded
// now passes silently. It is indistinguishable at the ref level from a re-created profile, so one of the two
// had to give -- and refusing was the wrong choice, because it turned a rare true positive into a systematic
// false one that bricked recovery for every profile that had ever been deleted and re-created.
func TestATombstoneIsNotEvidenceUntilSomebodySawTheScope(t *testing.T) {
	for _, tc := range []struct {
		label    string
		observed bool
		wantErr  bool
		why      string
	}{
		{"derived: nobody ever saw a scope at this address", false, false,
			"this is what a re-created profile carries on all six suffixes -- its own purge left them"},
		{"observed: a head was seen here and is now gone", true, true,
			"the scope really existed, so publishing a profile without it would lose it silently"},
	} {
		t.Run(tc.label, func(t *testing.T) {
			base := newHTTPStore(t)
			const name, pass, newpass = "tombevid", "horse battery staple correct", "a brand new passphrase"
			createVault(base, name, pass)
			dk, _, ok := resolveKey(base, name, pass)
			if !ok {
				t.Fatal("vault does not resolve")
			}
			ref, _ := headWriteRef(name+"#de", pass)
			putRef(base, ref, "") // the tombstone, identical in both rows
			if !refExists(base, ref) {
				t.Fatal("FIXTURE BROKE: the #de scope is not present after it was tombstoned -- this backend keeps an empty ref present (newHTTPStore stores \"\"; delRef writes an empty object), so the fixture no longer reaches the state under test")
			}
			idx := map[string]scopeRec{"#de": {Ref: ref, Wrapped: wrap(kekScopes(dk), deriveKey(name+"#de", pass)), Observed: tc.observed}}

			_, _, err := repointScopes(base, name, idx, newpass, dk, "", nil)
			if tc.wantErr && !errors.Is(err, ErrScopeTombstoned) {
				t.Fatalf("got %v, want ErrScopeTombstoned -- %s", err, tc.why)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("got %v, want success -- %s", err, tc.why)
			}
		})
	}
}

// TestAnIndexFromAnOlderBuildReadsAsDerived pins the POLARITY, which is the whole migration. Every scope
// index in the field was minted by deriveScopeIndex and none of them carry this key, so absent must mean
// DERIVED. Reading absent as "observed" would leave every fielded profile on the broken behaviour -- the fix
// would compile, pass its own tests, and reach nobody.
func TestAnIndexFromAnOlderBuildReadsAsDerived(t *testing.T) {
	var rec scopeRec
	if err := json.Unmarshal([]byte(`{"ref":"abc","wrapped":"def"}`), &rec); err != nil {
		t.Fatal(err)
	}
	if rec.Observed {
		t.Fatal("an index entry with no \"observed\" key read as OBSERVED. Every index already on the store " +
			"looks exactly like this, so the tombstone refusal would still fire for every re-created " +
			"profile in the field and the fix would reach nobody.")
	}
	// ...and the field must not appear at all when false, so an index that predates it round-trips byte-identically.
	b, err := json.Marshal(scopeRec{Ref: "abc", Wrapped: "def"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "observed") {
		t.Errorf("a derived entry rendered the observed key anyway: %s", b)
	}
}

// TestASealUpgradesADerivedEntryOnceTheScopeIsThere covers the other half: without it, a profile created on
// this build would carry "never seen" for scopes it has been sealing for months, and the tombstone refusal
// would never fire for it again -- trading -18 for the bug -18's guard was written to catch.
func TestASealUpgradesADerivedEntryOnceTheScopeIsThere(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "obsupgrade", "horse battery staple correct"
	createVault(base, name, pass)
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("vault does not resolve")
	}

	readIndex := func() map[string]scopeRec {
		t.Helper()
		v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
		idx, ok := openScopeIndex(dk, v.Scopes)
		if !ok {
			t.Fatal("no scope index on the head")
		}
		return idx
	}
	if readIndex()["#de"].Observed {
		t.Fatal("createVault recorded #de as OBSERVED, but no scope exists at create time by construction -- " +
			"that is the prediction-as-fact this slice removes")
	}

	for _, suf := range []string{"#de", ""} { // seal the scope, then the bare vault that records it
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, name+suf, pass, d)
	}
	if !readIndex()["#de"].Observed {
		t.Error("#de is sealed and its head resolves, but the index still calls it derived. The tombstone " +
			"refusal can never fire for this profile again, which is the guard NWP-20260906-03 wrote " +
			"silently deleted.")
	}
	// A scope that was never sealed stays derived: nobody has seen one.
	if readIndex()["#media"].Observed {
		t.Error("#media was never sealed but reads as observed -- an observation nobody made")
	}
}

// TestASecondCredentialChangeStillKnowsWhatTheFirstOneSaw closes the gap a mutation run found: repointScopes
// records Observed on every scope it re-points, and without that line a SECOND credential change reads its
// own freshly written index as "never seen" and would wave a real loss through.
//
// It matters because a credential change writes the index itself and does not wait for a seal: rotate, then
// rotate again (or recover, then rotate) is an ordinary sequence, and between the two there may be no bare
// seal at all to re-observe anything.
func TestASecondCredentialChangeStillKnowsWhatTheFirstOneSaw(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, p2, p3 = "twicerot", "horse battery staple correct", "the second passphrase", "the third passphrase"
	sealScopeFixture(t, base, name, pass)

	if _, err := rotateVault(base, name, pass, p2, nil, true); err != nil {
		t.Fatalf("first rotation: %v", err)
	}
	dk, _, ok := resolveKey(base, name, p2)
	if !ok {
		t.Fatal("profile does not resolve after the first rotation")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index after the first rotation")
	}
	if !idx["#de"].Observed {
		t.Fatal("the rotation re-pointed #de -- it read the head, wrote a new one and read it back -- but " +
			"recorded the result as DERIVED. The next credential change would then treat a tombstone there " +
			"as ordinary history and publish a profile with the scope silently missing.")
	}

	// Now lose it, with NO bare seal in between, and the second rotation must refuse.
	putRef(base, idx["#de"].Ref, "")
	if !refExists(base, idx["#de"].Ref) {
		t.Fatal("FIXTURE BROKE: the #de scope is not present after it was tombstoned -- this backend keeps an empty ref present (newHTTPStore stores \"\"; delRef writes an empty object), so the fixture no longer reaches the state under test")
	}
	if _, err := rotateVault(base, name, p2, p3, nil, true); !errors.Is(err, ErrScopeTombstoned) {
		t.Fatalf("second rotation returned %v, want ErrScopeTombstoned", err)
	}
}
