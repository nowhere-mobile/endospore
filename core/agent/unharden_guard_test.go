package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

// newTestKey mints the values a FIDO2 ceremony would return: a credential id, a salt, and the hmac-secret
// output the authenticator derives from that salt.
func newTestKey(tag string) (credID, saltB64, hmacHex string, raw []byte) {
	raw = make([]byte, fido2HMACLen)
	rand.Read(raw)
	salt := make([]byte, 32)
	rand.Read(salt)
	return base64.StdEncoding.EncodeToString([]byte(tag)),
		base64.StdEncoding.EncodeToString(salt), hex.EncodeToString(raw), raw
}

// hardenedWithAKey builds the shape that could not exist before this slice: a vault that is BOTH hardened to
// a secure element AND enrolled with a security key. Returns the secret and the key's credential id.
func hardenedWithAKey(t *testing.T, base, name, pass string) (se []byte, credID string) {
	t.Helper()
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	se = []byte("this-handsets-strongbox-secret")
	if err := enrollSE(base, name, pass, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	c, s, h, raw := newTestKey("hardened-key")
	t.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(raw)) // the enrolled key's assertion, as a session holds it
	if err := enrollFido2(base, name, pass, c, s, h, true, "usb", se); err != nil {
		t.Fatalf("enrollFido2 on a hardened vault: %v -- before NWP-20260915-13 this was the whole defect: the "+
			"`pass` slot is gone by design, so the ladder fell through to an env the daemon never carries", err)
	}
	return se, c
}

// headSlotKinds is slotKinds (account_anchor_test.go) over the PUBLISHED head, which is what these
// tests need: the question is what the store now holds, not what an in-memory vault says.
func headSlotKinds(t *testing.T, base, name, pass string) map[string]int {
	t.Helper()
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("head is not a vault")
	}
	return slotKinds(v)
}

// TestRemovingTheLastKeyDoesNotUnHardenAVault is NWP-20260915-13.
//
// removeFido2Key re-adds a `pass` slot when the last key goes, so the user is not stranded -- and its stated
// premise is that "the vault would have neither a pass nor a fido2 slot". That is simply FALSE on a hardened
// vault: the handset's own secure element still opens it, and so do the 12 words. Re-adding a passphrase
// slot there handed back exactly the offline brute-force surface that dropping it bought, and nothing wrote
// v.Hardened -- so the vault went on REPORTING hardened while no longer being it.
func TestRemovingTheLastKeyDoesNotUnHardenAVault(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "unharden", "horse battery staple correct"
	se, _ := hardenedWithAKey(t, base, name, pass)

	before := headSlotKinds(t, base, name, pass)
	if before["se"] != 1 || before["fido2"] != 1 || before["pass"] != 0 {
		t.Fatalf("precondition: want one se slot, one fido2 slot and no pass slot; got %v", before)
	}

	// ⚠ NO CACHED KEY ASSERTION, and that is deliberate: with NOWHERE_FIDO2_HMAC still set the removal
	// opens the vault through fido2DK and never needs the secure-element secret at all -- a mutation
	// proved exactly that, by surviving. The env is empty whenever the daemon has restarted since
	// login, and on a hardened vault the `se` slot is then the ONLY thing left that opens it.
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	still, err := removeFido2Key(base, name, pass, "", se)
	if err != nil {
		t.Fatalf("removeFido2Key: %v -- with no cached assertion the secure-element slot is the only "+
			"opener a hardened vault has left", err)
	}
	if still {
		t.Error("removeFido2Key reported the vault is still key-protected after removing its only key")
	}

	after := headSlotKinds(t, base, name, pass)
	if after["pass"] != 0 {
		t.Errorf("a `pass` slot was re-added to a HARDENED vault (%v) -- the profile is offline "+
			"brute-forceable by passphrase again, which is the exact property kekSE exists to provide", after)
	}
	if after["se"] != 1 {
		t.Errorf("the secure-element slot did not survive the removal (%v)", after)
	}
	// The two assertions that make the flag honest rather than merely unchanged.
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Error("the passphrase ALONE opens the vault after removing the last key -- it is no longer hardened")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !v.Hardened {
		t.Error("Hardened went false -- the flag and the slots must agree, in both directions")
	}
	if n := seSlotsOpenableBy(t, base, name, pass, se); n != 1 {
		t.Errorf("this handset opens %d se slot(s) after the removal, want 1 -- removing a key must not "+
			"strand the user either", n)
	}
}

// TestRemovingTheLastKeyOnAPlainVaultStillRestoresThePassphrase is the canary for every profile that is NOT
// hardened -- Diaspore, and un-hardened Endospore. The guard is gated on an `se` slot existing, so this path
// must behave exactly as it always did: without the re-add, the last key's removal would strand the user on
// their 12-word code.
func TestRemovingTheLastKeyOnAPlainVaultStillRestoresThePassphrase(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "unhardenplain", "horse battery staple correct"
	createVault(base, name, pass)
	c, s, h, raw := newTestKey("plain-key")
	t.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(raw))
	if err := enrollFido2(base, name, pass, c, s, h, true, "usb", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}
	if k := headSlotKinds(t, base, name, pass); k["pass"] != 0 {
		t.Fatalf("precondition: a first enrol must drop the pass slot; got %v", k)
	}

	if _, err := removeFido2Key(base, name, pass, "", nil); err != nil {
		t.Fatalf("removeFido2Key: %v", err)
	}
	if k := headSlotKinds(t, base, name, pass); k["pass"] != 1 {
		t.Fatalf("the passphrase slot was NOT restored on a non-hardened vault (%v) -- the user's only "+
			"remaining way in would be the 12-word recovery code", k)
	}
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Error("the passphrase does not open the vault after removing the last key")
	}
}

// TestAHardenedVaultCanEnrolASecurityKey: the feature that was entirely dead on Endospore. All three entry
// points failed the same way -- USB enrol handed the worker an empty secret, and NFC enrol and remove are
// daemon-resident, where the environment never carries one -- so the 2FA tier did not work on the edition it
// was built for.
func TestAHardenedVaultCanEnrolASecurityKey(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "hardenkey", "horse battery staple correct"
	se, _ := hardenedWithAKey(t, base, name, pass) // fatals if the enrol itself fails

	k := headSlotKinds(t, base, name, pass)
	if k["fido2"] != 1 {
		t.Errorf("no key slot after enrolling on a hardened vault (%v)", k)
	}
	if k["pass"] != 0 {
		t.Errorf("enrolling a key on a hardened vault re-introduced a pass slot (%v)", k)
	}
	if k["se"] != 1 {
		t.Errorf("enrolling a key cost the vault its secure-element slot (%v)", k)
	}
	// A second key must also go on, which is the path that needs the secret rather than a cached hmac.
	c2, s2, h2, _ := newTestKey("second-key")
	if err := enrollFido2(base, name, pass, c2, s2, h2, true, "nfc", se); err != nil {
		t.Fatalf("a second key on a hardened vault: %v", err)
	}
	if k := headSlotKinds(t, base, name, pass); k["fido2"] != 2 {
		t.Errorf("want two key slots after a second enrol, got %v", k)
	}
	if n := seSlotsOpenableBy(t, base, name, pass, se); n != 1 {
		t.Errorf("enrolling keys cost this handset its own slot (%d)", n)
	}
}

// TestTheUsbEnrolHandsTheWorkerTheSessionSecret pins the one hop no behavioural test above can reach: the USB
// path does not call enrollFido2 in this process at all, it hands the op to the su:s0 worker, and roamd
// exports line 5 as NOWHERE_SE_SECRET only when it is NON-EMPTY. That line passed "", so the worker's agent
// ran blind and a hardened vault could never enrol by USB -- which is the primary path.
func TestTheUsbEnrolHandsTheWorkerTheSessionSecret(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `triggerRoamWorker(dest, "fido2-enroll"`)
	if i < 0 {
		t.Fatal("no fido2-enroll worker trigger found -- this test is looking at the wrong call")
	}
	line := src[i : i+strings.Index(src[i:], "\n")]
	if strings.Contains(line, `ud, "",`) {
		t.Error("the USB enrol still hands the worker an EMPTY se_secret. roamd exports line 5 only when it " +
			"is non-empty, so the worker's agent opens no `se` slot and a hardened profile cannot enrol a key " +
			"by USB at all (NWP-20260915-13).")
	}
	if !strings.Contains(line, "readRoamSessionSE(dest)") {
		t.Errorf("the USB enrol does not read the live session's secret: %s", line)
	}

	// ...and the two DAEMON-resident entry points, which the behavioural tests above reach only by
	// calling the functions directly. All three hops had to be fixed for the tier to work at all, so
	// all three are pinned: a mutation that cut any one of them would otherwise pass unnoticed.
	for _, tc := range []struct{ what, call string }{
		{"the NFC enrol", `enrollFido2("s3", nm, ps,`},
		{"the remove verb", `removeFido2KeyTapped("s3", nm, ps, cid`},
	} {
		j := strings.Index(src, tc.call)
		if j < 0 {
			t.Errorf("%s: call site not found -- this test is looking at the wrong place", tc.what)
			continue
		}
		// The call spans two lines at the NFC site, so take a window rather than one line.
		window := src[j:min(len(src), j+260)]
		if !strings.Contains(window, "seFromSession(dest)") {
			t.Errorf("%s does not hand the vault opener the live session's secure-element secret, so a "+
				"hardened profile cannot use it at all:%s%s", tc.what, "\n", window)
		}
	}
}
