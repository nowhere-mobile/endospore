package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20260906-10. The ACCOUNT head is an IDENTITY ANCHOR (Chester's call, 2026-09-06): its keyslots stay
// current, its manifest stays frozen.
//
// Before this, a keyslot change with #91 on wrote only THIS unit's head, and headRef falls through to the
// account head for any device with no unit head of its own -- so a FIDO2 key revoked BECAUSE IT WAS LOST
// still opened the account through that fallback. Same revocation-failure shape as NWP-20260906-05, one ref
// further out.
//
// The manifest half is the decision, not an implementation detail: republishing this device's WHOLE vault
// would carry its app data to the account head, and a not-yet-sealed device would silently adopt it --
// crossing the 2026-07-03 rule that app data is per-unit ALWAYS and cross-unit access is an explicit
// point-in-time restore.

func fakeKey(t *testing.T, tag string) (cred, salt, hmacHex string) {
	t.Helper()
	raw := make([]byte, fido2HMACLen)
	rand.Read(raw)
	s := make([]byte, 32)
	rand.Read(s)
	return base64.StdEncoding.EncodeToString([]byte(tag)), base64.StdEncoding.EncodeToString(s), hex.EncodeToString(raw)
}

// accountVault reads the vault the ACCOUNT head points at -- the copy a device with no unit head opens.
func accountVault(t *testing.T, base, name, pass string) *vault {
	t.Helper()
	h := getRef(base, profileRefV2(name, pass))
	if h == "" {
		h = getRef(base, profileRefLegacy(name, pass))
	}
	if h == "" {
		return nil
	}
	v, isV := parseVault(getHeadBlob(base, h))
	if !isV {
		return nil
	}
	return v
}

func slotKinds(v *vault) map[string]int {
	out := map[string]int{}
	if v != nil {
		for _, s := range v.Slots {
			out[s.Kind]++
		}
	}
	return out
}

// TestRevokedFido2KeyDoesNotSurviveAtTheAccountHead is the security assertion: revoke a key, and it must be
// gone from the copy a not-yet-sealed device would open.
func TestRevokedFido2KeyDoesNotSurviveAtTheAccountHead(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")

	const name, pass = "anchorfido", "correct horse battery staple"
	createVault(base, name, pass)

	c1, s1, h1 := fakeKey(t, "key-keep")
	if err := enrollFido2(base, name, pass, c1, s1, h1, false, "", nil); err != nil {
		t.Fatalf("enroll key1: %v", err)
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", h1)
	c2, s2, h2 := fakeKey(t, "key-lost")
	if err := enrollFido2(base, name, pass, c2, s2, h2, false, "", nil); err != nil {
		t.Fatalf("enroll key2: %v", err)
	}
	if n := slotKinds(accountVault(t, base, name, pass))["fido2"]; n != 2 {
		t.Fatalf("account head carries %d fido2 slot(s) after enrolling two, want 2", n)
	}

	// Revoke the SECOND key, as a user would after losing it.
	if _, err := removeFido2Key(base, name, pass, c2, nil); err != nil {
		t.Fatalf("removeFido2Key: %v", err)
	}

	av := accountVault(t, base, name, pass)
	if av == nil {
		t.Fatal("no account head after revocation")
	}
	for _, s := range av.Slots {
		if s.Kind == "fido2" && s.CredID == c2 {
			t.Fatal("the REVOKED key's slot survives at the account head -- a device with no unit head of " +
				"its own falls through to it, so a key revoked because it was LOST still opens the account")
		}
	}
	if n := slotKinds(av)["fido2"]; n != 1 {
		t.Fatalf("account head carries %d fido2 slot(s) after revoking one of two, want 1", n)
	}
}

// TestAccountHeadKeepsItsOwnManifest is the decision. Identity travels; data does not.
func TestAccountHeadKeepsItsOwnManifest(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")

	const name, pass = "anchormanifest", "correct horse battery staple"
	createVault(base, name, pass)
	before := accountVault(t, base, name, pass)
	if before == nil {
		t.Fatal("no account head after create")
	}
	frozen := before.Manifest

	// Give THIS unit data of its own, so its vault's manifest diverges from the account head's.
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "mine.txt"), []byte("this unit's data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	// A keyslot change must carry the SLOTS and leave the manifest alone.
	c1, s1, h1 := fakeKey(t, "key-1")
	if err := enrollFido2(base, name, pass, c1, s1, h1, false, "", nil); err != nil {
		t.Fatalf("enroll: %v", err)
	}

	after := accountVault(t, base, name, pass)
	if after == nil {
		t.Fatal("no account head after the keyslot change")
	}
	if n := slotKinds(after)["fido2"]; n != 1 {
		t.Fatalf("the new keyslot did NOT reach the account head (fido2 slots=%d)", n)
	}
	if after.Manifest != frozen {
		t.Fatalf("the account head's MANIFEST advanced (%s -> %s). It must stay frozen: a not-yet-sealed "+
			"device falls through to this head, and advancing it makes that device silently adopt THIS "+
			"unit's app data, which the per-unit decision forbids", short(frozen), short(after.Manifest))
	}
}

// TestRotationPublishesAnAccountHeadAtTheNewCredential. With #91 on, putHead writes only the unit head, so
// nothing published an account head under the new passphrase -- a second device resolved NOTHING after a
// rotation, which the login path renders as a blank. The same shape NWP-20260906-02 fixed for creation.
func TestRotationPublishesAnAccountHeadAtTheNewCredential(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	const name, oldpass, newpass = "anchorrot", "the old passphrase here", "a brand new passphrase here"
	createVault(base, name, oldpass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, oldpass, src) // adopt to this unit's head

	if _, err := rotateVault(base, name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if av := accountVault(t, base, name, newpass); av == nil {
		t.Fatal("no ACCOUNT head at the new credential after a rotation -- a second device resolves nothing " +
			"and gets a blank login, indistinguishable from a wrong passphrase")
	}
	// And the old credential must still be revoked (NWP-20260906-05 must not regress).
	if _, _, ok := resolveKey(base, name, oldpass); ok {
		t.Fatal("the old passphrase still opens the profile after rotation")
	}
}

// TestRotationCarriesTheAccountDirectory. accountDirRef is keyed on (name, pass), so a rotation moved it and
// nothing migrated it: LIST-UNITS then showed one device where there were several, and it disarmed the
// multi-lineage rotation guard on any SECOND rotation.
func TestRotationCarriesTheAccountDirectory(t *testing.T) {
	base := newHTTPStore(t)
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")

	const name, oldpass, newpass = "anchordir", "the old passphrase here", "a brand new passphrase here"
	createVault(base, name, oldpass)
	dk := resolveDK(base, name, oldpass, nil)
	if dk == nil {
		t.Fatal("no DK")
	}
	writeAccountDir(base, name, oldpass, dk, &accountDir{Units: []unitEntry{
		{ID: deviceUnitID(), Label: "this phone", Edition: "endospore", Added: time.Now().Unix()},
	}})

	if _, err := rotateVault(base, name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	d, ok := loadAccountDir(base, name, newpass, dk)
	if !ok || d == nil || len(d.liveUnits()) != 1 {
		t.Fatal("the account directory did not survive the rotation -- LIST-UNITS would show one device " +
			"where there were several, and the multi-lineage rotation guard would be disarmed on the next one")
	}
	if getRef(base, accountDirRef(name, oldpass)) != "" {
		t.Fatal("the old directory ref still resolves after the rotation; it must be tombstoned")
	}
}

// TestRotationToTheSamePassphraseKeepsTheUnitHead (NWP-20261011-31). The retire pass tombstoned every old ref
// other than newV2 -- including unitHeadRef(name, oldpass, unit), which on a change to the SAME passphrase is
// the unit head putHead had just written. In the cap buffer the later write wins, so the tombstone replaced
// the head and the next login on this unit was a blank. The account directory had the same shape:
// accountDirRef(name, oldpass) is the directory writeAccountDir had just published. Run on both backends,
// because the buffered path is the one the bug lives in.
func TestRotationToTheSamePassphraseKeepsTheUnitHead(t *testing.T) {
	for _, mode := range []string{"direct", "cap"} {
		t.Run(mode, func(t *testing.T) {
			var base string
			if mode == "cap" {
				capRotateFixture(t)
				base = "s3"
			} else {
				base = newHTTPStore(t)
			}
			orig := unitIDPath
			t.Cleanup(func() { unitIDPath = orig })
			t.Setenv("NOWHERE_MULTIDEVICE", "1")
			unitIDPath = filepath.Join(t.TempDir(), "unit-id")
			pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture: one test binary shares the fence sample

			const name, pass = "samerot", "the one passphrase kept"
			if createVault(base, name, pass) == "" {
				t.Fatal("createVault returned no recovery code")
			}
			src := t.TempDir()
			if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("data"), 0o600); err != nil {
				t.Fatal(err)
			}
			pushProfile(base, name, pass, src) // adopt to this unit's head
			uref := unitHeadRef(name, pass, deviceUnitID())
			if getRef(base, uref) == "" {
				t.Fatal("precondition: the seal wrote no unit head")
			}
			dk := resolveDK(base, name, pass, nil)
			if dk == nil {
				t.Fatal("no DK")
			}
			capWrite(name, pass, dk, func() { // a no-op bracket off cap mode
				writeAccountDir(base, name, pass, dk, &accountDir{Units: []unitEntry{
					{ID: deviceUnitID(), Label: "this phone", Edition: "endospore", Added: time.Now().Unix()},
				}})
			})

			if _, err := rotateVault(base, name, pass, pass, nil, true); err != nil {
				t.Fatalf("rotateVault to the same passphrase: %v", err)
			}
			capReadCache = map[string]capEntry{} // read the store, not this process's memory of it

			for _, ref := range []string{uref, profileRefV2(name, pass)} {
				h := getRef(base, ref)
				if h == "" {
					t.Fatalf("head %s is gone after a change to the SAME passphrase -- the retire pass "+
						"tombstoned a ref this rotation had just published, and the next login is a blank", short(ref))
				}
				v, isV := parseVault(getHeadBlob(base, h))
				if !isV || unwrapDK(v, "pass", deriveKey(name, pass)) == nil {
					t.Fatalf("head %s no longer names a vault the passphrase opens", short(ref))
				}
			}
			if ref := headKey(base, name, pass); ref != uref {
				t.Fatalf("the login read resolved %s, want this unit's head", short(ref))
			}
			if _, _, ok := resolveKey(base, name, pass); !ok {
				t.Fatal("the passphrase no longer opens the profile after a change to itself")
			}
			if d, ok := loadAccountDir(base, name, pass, dk); !ok || d == nil || len(d.liveUnits()) != 1 {
				t.Fatal("the account directory was tombstoned by a change to the SAME passphrase")
			}
		})
	}
}
