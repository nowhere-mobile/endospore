package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// #81 P3: enrolling a fido2 2FA slot makes login require passphrase + the key's hmac-secret output; the
// passphrase alone no longer opens the vault, but the recovery mnemonic still does. Uses a disco store and a
// fixed hmac byte string standing in for a real authenticator (the agent never runs CTAP2).
func TestFido2VaultSlot(t *testing.T) {
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")

	const name, pass = "keyuser", "correct horse battery staple"
	mnemonic := createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}

	// Baseline: passphrase alone opens the fresh (key-less) vault.
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Fatal("pre-enroll: passphrase should open the vault")
	}

	// Enroll a 2FA key. hmac stands in for the authenticator's hmac-secret assertion output.
	hmac := make([]byte, fido2HMACLen)
	rand.Read(hmac)
	credID := base64.StdEncoding.EncodeToString([]byte("cred-id-bytes"))
	salt := make([]byte, 32)
	rand.Read(salt)
	saltB64 := base64.StdEncoding.EncodeToString(salt)
	if err := enrollFido2(base, name, pass, credID, saltB64, hex.EncodeToString(hmac), true, "", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}

	// Passphrase ALONE must now fail (2FA: the pass-only slot was dropped).
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Fatal("post-enroll: passphrase alone must NOT open a 2FA vault")
	}

	// Passphrase + the RIGHT key opens it.
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(hmac))
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Fatal("post-enroll: passphrase + correct key must open the vault")
	}

	// A WRONG key (different hmac) fails -> blank, indistinguishable.
	wrong := make([]byte, fido2HMACLen)
	rand.Read(wrong)
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(wrong))
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Fatal("post-enroll: a wrong key must NOT open the vault")
	}

	// The slot metadata is listable (what the gate needs to run the assertion).
	head := getRef(base, headKey(base, name, pass))
	v, _ := parseVault(getBlob(base, head))
	slots := listFido2Slots(v)
	if len(slots) != 1 || slots[0].CredID != credID || slots[0].Salt != saltB64 || !slots[0].UV {
		t.Fatalf("listFido2Slots = %+v; want one slot with the enrolled credId/salt/uv", slots)
	}

	// Recovery still works (the escape hatch is intact) -- reset to a new pass via the mnemonic.
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if err := recoverVault(base, name, mnemonic, "river maple stone cloud"); err != nil {
		t.Fatalf("recoverVault after key enroll: %v", err)
	}
}

// #81 regression (DIA-20260704-31): the SEAL side must open a 2FA vault too, not just login. The on-device
// bug (fidotest4222): resolveDK / pushProfile / profileFootprint tried only pass->se and never fido2DK, so a
// key-enrolled profile's periodic sync AND logoff seal both failed ("no slot opens" / ERR-PUSH) even with the
// hmac cached in env -- the session could log in but never SAVE ("couldn't save your data"). openVaultDK now
// centralizes the pass->se->fido2 ladder so every DK-open path opens identically.
func TestFido2SealPathsOpen2FAVault(t *testing.T) {
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	const name, pass = "sealkey", "correct horse battery staple"
	createVault(base, name, pass)

	// Seed data so there's a manifest + chunks to lease and seal.
	src := t.TempDir()
	data := bytes.Repeat([]byte("2fa seal payload 0123456789 abcdefghij\n"), 100000) // ~3.9MB -> several chunks
	if err := os.WriteFile(filepath.Join(src, "f.txt"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src) // baseline seal via the pass slot

	// Enroll a 2FA key -> the pass-only slot is DROPPED; the seal now requires the hmac.
	hmac := make([]byte, fido2HMACLen)
	rand.Read(hmac)
	salt := make([]byte, 32)
	rand.Read(salt)
	credID := base64.StdEncoding.EncodeToString([]byte("seal-cred"))
	if err := enrollFido2(base, name, pass, credID, base64.StdEncoding.EncodeToString(salt), hex.EncodeToString(hmac), true, "", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}

	// With NO key, the seal side must REFUSE (data-safety: fail loudly, never seal a partial/pass-only open):
	// resolveDK returns nil (pay-rent aborts) and pushProfile fails ("no slot opens").
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if dk := resolveDK(base, name, pass, nil); dk != nil {
		t.Fatal("resolveDK opened a 2FA vault with NO key -- the pass-only slot should be gone")
	}
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("pushProfile sealed a 2FA vault with NO key -- it must fail (no slot opens)")
			}
		}()
		pushProfile(base, name, pass, src)
	}()

	// WITH the key's hmac, every seal-side path opens it -- this is the fix.
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(hmac))
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if dk := resolveDK(base, name, pass, nil); dk == nil {
		t.Fatal("resolveDK could not open a 2FA vault WITH the key -> pay-rent fails -> ERR-PUSH")
	}
	if refs := mustFootprint(t, base, name, pass, nil); len(refs) < 3 {
		t.Fatalf("profileFootprint under-leased a 2FA vault: %d refs, want head+manifest+chunk(s) (GC would reap it)", len(refs))
	}
	// A fresh seal (what periodic sync / logoff run) must now SUCCEED and stay openable.
	if err := os.WriteFile(filepath.Join(src, "g.txt"), []byte("added while 2FA-enrolled"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src) // must NOT fail now (was ERR-PUSH before the fix)
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Fatal("post-seal: the 2FA vault no longer opens for login")
	}
}

// #81 mid-session enroll (DIA-20260704-32): the enroll ceremony stashes the just-asserted hmac at the login
// hook's location and the daemon adopts it, so the ENROLLING session (which logged in pass-only -> nothing
// was stashed at login) keeps sealing without a re-login. On-device failure this reproduces: enroll `c`
// mid-session -> every seal ERR-PUSH -> "couldn't save your data".
func TestFido2MidSessionEnrollStash(t *testing.T) {
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")
	const name, pass = "midenroll", "correct horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("pre-enroll data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src) // pass-only login-era seal

	// Enroll mid-session (the vault op the ceremony ends in), then do what the CLI + daemon now do:
	// stash the asserted hmac and adopt it. The env starts EMPTY -- exactly the enrolling session's state.
	hmac := make([]byte, fido2HMACLen)
	rand.Read(hmac)
	salt := make([]byte, 32)
	rand.Read(salt)
	if err := enrollFido2(base, name, pass, base64.StdEncoding.EncodeToString([]byte("mid-cred")),
		base64.StdEncoding.EncodeToString(salt), hex.EncodeToString(hmac), false, "usb", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}
	state := t.TempDir()
	if err := stashFido2Hmac(state, hmac); err != nil {
		t.Fatalf("stashFido2Hmac: %v", err)
	}
	loadFido2HmacEnv(state) // the daemon's post-ENROLL-FIDO2 adopt

	// The session's next seal (periodic sync / logoff) must now succeed.
	if err := os.WriteFile(filepath.Join(src, "g.txt"), []byte("post-enroll data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src) // would fail("push: no slot opens") without the stash+adopt
	if dk := resolveDK(base, name, pass, nil); dk == nil {
		t.Fatal("resolveDK (pay-rent) can't open the vault after the enroll stash+adopt")
	}

	// And a later NON-fido2 session must not inherit it: an empty stash dir unsets the env.
	loadFido2HmacEnv(t.TempDir())
	if os.Getenv("NOWHERE_FIDO2_HMAC") != "" {
		t.Fatal("loadFido2HmacEnv left a stale hmac in env with no stash present")
	}
}

// #81 resume gap (DIA-20260704-34): the COLD session credential for a 2FA profile must bind the key hmac --
// a cold session resumable with the passphrase alone would be the weakest door on the strongest profiles.
func TestSessionCred(t *testing.T) {
	const name, pass = "coldkey", "correct horse battery staple"

	// Non-2FA (no hmac in env): the credential IS the passphrase -- warm/cold behavior unchanged.
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if got := sessionCred(name, pass); got != pass {
		t.Fatalf("non-2FA sessionCred = %q; want the passphrase unchanged", got)
	}

	// 2FA: derived, 16 hex chars (Android's keyguard max length), deterministic, and NOT the passphrase.
	hmac := make([]byte, fido2HMACLen)
	rand.Read(hmac)
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(hmac))
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")
	c1 := sessionCred(name, pass)
	if c1 == pass || len(c1) != 16 {
		t.Fatalf("2FA sessionCred = %q; want a 16-char derived credential != pass", c1)
	}
	if _, err := hex.DecodeString(c1); err != nil {
		t.Fatalf("2FA sessionCred %q is not hex: %v", c1, err)
	}
	if c2 := sessionCred(name, pass); c2 != c1 {
		t.Fatalf("sessionCred not deterministic: %q then %q (resume could never verify)", c1, c2)
	}
	// A different key (hmac) or passphrase must derive a DIFFERENT credential -- either factor alone is
	// insufficient to recompute it.
	if c := sessionCred(name, "some other passphrase entirely"); c == c1 {
		t.Fatal("sessionCred ignored the passphrase")
	}
	other := make([]byte, fido2HMACLen)
	rand.Read(other)
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(other))
	if c := sessionCred(name, pass); c == c1 {
		t.Fatal("sessionCred ignored the key hmac")
	}
}

// #81 multi-key + un-enroll + 2FA rotate (DIA-20260704-35).
func TestFido2MultiKeyAndUnenroll(t *testing.T) {
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")
	const name, pass = "multikey", "correct horse battery staple"
	mnemonic := createVault(base, name, pass)

	newKey := func(tag string) (cred, salt, hmacHex string, raw []byte) {
		raw = make([]byte, fido2HMACLen)
		rand.Read(raw)
		s := make([]byte, 32)
		rand.Read(s)
		return base64.StdEncoding.EncodeToString([]byte(tag)), base64.StdEncoding.EncodeToString(s), hex.EncodeToString(raw), raw
	}

	// First key (pass slot present -> dropped).
	c1, s1, h1hex, h1 := newKey("key-1")
	if err := enrollFido2(base, name, pass, c1, s1, h1hex, false, "", nil); err != nil {
		t.Fatalf("enroll key1: %v", err)
	}
	// Add a SECOND key -- this requires opening the vault via key1's cached hmac (the pass slot is gone).
	os.Setenv("NOWHERE_FIDO2_HMAC", h1hex) // the roamd stash for the LOGGED-IN key1
	c2, s2, h2hex, h2 := newKey("key-2")
	if err := enrollFido2(base, name, pass, c2, s2, h2hex, false, "", nil); err != nil {
		t.Fatalf("enroll key2 (needs key1's cached hmac to open): %v", err)
	}
	// Now EITHER key + passphrase opens the vault.
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h1))
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Fatal("key1 no longer opens after enrolling key2")
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h2))
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Fatal("key2 doesn't open the vault")
	}
	head := getRef(base, headKey(base, name, pass))
	v, _ := parseVault(getBlob(base, head))
	if len(listFido2Slots(v)) != 2 {
		t.Fatalf("want 2 fido2 slots, got %d", len(listFido2Slots(v)))
	}

	// 2FA change-passphrase: rotate under key2's cached hmac. The present key's slot follows; the absent
	// key1's slot (KEK mixes the OLD pass) is dropped.
	const newpass = "river maple stone cloud lantern"
	if _, err := rotateVault(base, name, pass, newpass, nil, true); err != nil {
		t.Fatalf("rotate 2FA vault: %v", err)
	}
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Fatal("old passphrase still opens after rotate")
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h2)) // the rotated-through key
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("new passphrase + rotated key doesn't open")
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h1)) // dropped key must NOT open under the new pass
	if _, _, ok := resolveKey(base, name, newpass); ok {
		t.Fatal("the dropped key still opens after rotate (should be dead)")
	}

	// Enroll a SECOND key again (key2 survived the rotate) so we have two to test per-key removal.
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h2))
	c3, s3, h3hex, h3 := newKey("key-3")
	if err := enrollFido2(base, name, newpass, c3, s3, h3hex, false, "", nil); err != nil {
		t.Fatalf("enroll key3: %v", err)
	}
	// Remove ONE key (key2) by its credId -> the OTHER (key3) must still open; still 2FA (stillEnrolled).
	if still, err := removeFido2Key(base, name, newpass, c2, nil); err != nil || !still {
		t.Fatalf("removeFido2Key(key2): still=%v err=%v (want still=true)", still, err)
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h2))
	if _, _, ok := resolveKey(base, name, newpass); ok {
		t.Fatal("removed key2 still opens the vault")
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h3))
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("the surviving key3 no longer opens after removing key2")
	}
	head = getRef(base, headKey(base, name, newpass))
	v, _ = parseVault(getBlob(base, head))
	if len(listFido2Slots(v)) != 1 {
		t.Fatalf("want 1 fido2 slot after removing one of two, got %d", len(listFido2Slots(v)))
	}
	if listFido2Slots(v)[0].Added == 0 {
		t.Fatal("enrolled slot missing its Added timestamp (the remove-list would show no date)")
	}
	// Remove the LAST key (empty credID also works, but exercise the explicit-credId last-key path) ->
	// downgrade: stillEnrolled=false, passphrase alone opens, no fido2 slots remain.
	if still, err := removeFido2Key(base, name, newpass, c3, nil); err != nil || still {
		t.Fatalf("removeFido2Key(last): still=%v err=%v (want still=false)", still, err)
	}
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("passphrase alone doesn't open after removing the last key")
	}
	head = getRef(base, headKey(base, name, newpass))
	v, _ = parseVault(getBlob(base, head))
	if len(listFido2Slots(v)) != 0 {
		t.Fatalf("want 0 fido2 slots after removing the last key, got %d", len(listFido2Slots(v)))
	}
	// Recovery still works through the whole dance.
	if err := recoverVault(base, name, mnemonic, "brand new passphrase entirely"); err != nil {
		t.Fatalf("recover after multi-key/unenroll: %v", err)
	}
}

// A malformed hmac / salt / credId is rejected without touching the vault.
func TestEnrollFido2Validation(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "v", "correct horse battery staple"
	createVault(base, name, pass)
	good := hex.EncodeToString(make([]byte, 32))
	goodSalt := base64.StdEncoding.EncodeToString(make([]byte, 32))
	goodCred := base64.StdEncoding.EncodeToString([]byte("c"))

	for _, c := range []struct{ cred, salt, hmac string }{
		{goodCred, goodSalt, "abcd"},                                          // short hmac
		{goodCred, base64.StdEncoding.EncodeToString(make([]byte, 16)), good}, // 16-byte salt
		{"", goodSalt, good},                                                  // empty cred
		{"!!not base64!!", goodSalt, good},                                    // bad cred
	} {
		if err := enrollFido2(base, name, pass, c.cred, c.salt, c.hmac, false, "", nil); err == nil {
			t.Errorf("enrollFido2(%q,%q,%q) accepted a malformed input", c.cred, c.salt, c.hmac)
		}
	}
	// The vault is still a plain passphrase vault (nothing was mutated).
	if _, _, ok := resolveKey(base, name, pass); !ok {
		t.Fatal("passphrase should still open the vault after rejected enrollments")
	}
}

// TestColdSlotSpecRoundTrip covers the PIN+FIDO2 cold-resume path (NWP-20260823-09): the slot spec cached at
// login must survive the marker round trip, because it is the ONLY thing a PIN resume can assert from -- it
// never types the passphrase a head lookup needs, and that passphrase is itself sealed under the hmac the
// assert produces. A silent break here is not a failed login, it is a session that cannot be re-entered.
func TestColdSlotSpecRoundTrip(t *testing.T) {
	in := []fido2SlotInfo{
		{CredID: "Y3JlZC1vbmU=", Salt: "c2FsdC1vbmU=", UV: true},
		{CredID: "Y3JlZC10d28=", Salt: "c2FsdC10d28=", UV: false},
	}
	got := parseSlotSpec(encodeSlotSpec(in))
	if len(got) != len(in) {
		t.Fatalf("round trip lost slots: got %d, want %d", len(got), len(in))
	}
	for i := range in {
		if got[i].CredID != in[i].CredID || got[i].Salt != in[i].Salt || got[i].UV != in[i].UV {
			t.Fatalf("slot %d round-tripped as %+v, want %+v", i, got[i], in[i])
		}
	}
	// Junk must degrade to "no slots" rather than a bogus assert or a panic.
	for _, bad := range []string{"", ",", "onlyonefield", ":", "a:", ":b"} {
		if n := len(parseSlotSpec(bad)); n != 0 {
			t.Fatalf("parseSlotSpec(%q) = %d slots; want 0", bad, n)
		}
	}
}

// TestColdLockSlotsMarker proves line 7 survives the marker written by handleColdLock's format, and that a
// pre-NWP-20260823-09 six-line marker reads as "no slots" (-> the legacy passphrase path) rather than
// mis-parsing passWrap as a slot spec.
func TestColdLockSlotsMarker(t *testing.T) {
	dir := t.TempDir()
	spec := "Y3JlZC1vbmU=:c2FsdC1vbmU=:1"
	seven := "alice\n12\nse\nfido2\npin\ncGFzc3dyYXA=\n" + spec + "\n"
	if err := os.WriteFile(filepath.Join(dir, ".coldlock"), []byte(seven), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := coldLockSlots(dir); got != spec {
		t.Fatalf("coldLockSlots = %q, want %q", got, spec)
	}
	six := "alice\n12\nse\nfido2\npin\ncGFzc3dyYXA=\n"
	if err := os.WriteFile(filepath.Join(dir, ".coldlock"), []byte(six), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := coldLockSlots(dir); got != "" {
		t.Fatalf("legacy 6-line marker gave slots %q; want empty", got)
	}
	if got := coldLockSlots(t.TempDir()); got != "" {
		t.Fatalf("absent marker gave slots %q; want empty", got)
	}
}

// TestStashFido2SlotsRoundTrip covers the login-side half: what the assert caches is what cold-lock reads.
func TestStashFido2SlotsRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if got := readFido2SlotsStash(dir); got != "" {
		t.Fatalf("empty dir gave %q; want empty", got)
	}
	slots := []fido2SlotInfo{{CredID: "Y3JlZA==", Salt: "c2FsdA==", UV: true}}
	stashFido2Slots(dir, slots)
	if got, want := readFido2SlotsStash(dir), encodeSlotSpec(slots); got != want {
		t.Fatalf("stash round trip = %q, want %q", got, want)
	}
	fi, err := os.Stat(filepath.Join(dir, ".fido2slots"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("stash mode %o; want 600", perm)
	}
}

// TestFido2SlotsPreIsSeparateFromLive is the regression test for the bug that made NWP-20260823-10 INERT: the
// login assert wrote the LIVE stash, and the per-login reset in roamd's commit arm -- which runs AFTER the
// assert -- deleted it again, so every keyed login produced an empty marker line 7 and no PIN resume could
// ever work. The two writers must target DIFFERENT files, so that the commit arm can clear the live one and
// promote the pending one without the order mattering.
func TestFido2SlotsPreIsSeparateFromLive(t *testing.T) {
	dir := t.TempDir()
	slots := []fido2SlotInfo{{CredID: "Y3JlZA==", Salt: "c2FsdA==", UV: true}}

	stashFido2SlotsPre(dir, slots)
	if _, err := os.Stat(filepath.Join(dir, ".fido2slots.pre")); err != nil {
		t.Fatalf("stashFido2SlotsPre wrote no .pre file: %v", err)
	}
	if got := readFido2SlotsStash(dir); got != "" {
		t.Fatalf("the .pre write leaked into the LIVE stash (%q) -- roamd's commit-arm reset would erase it", got)
	}

	// Promotion (what roamd's commit arm does with mv) must make it readable as the live stash.
	if err := os.Rename(filepath.Join(dir, ".fido2slots.pre"), filepath.Join(dir, ".fido2slots")); err != nil {
		t.Fatal(err)
	}
	if got, want := readFido2SlotsStash(dir), encodeSlotSpec(slots); got != want {
		t.Fatalf("after promotion the live stash is %q, want %q", got, want)
	}

	fi, err := os.Stat(filepath.Join(dir, ".fido2slots"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("promoted stash mode %o; want 600", perm)
	}
}

// TestColdLockPinFlagGatesTheFallback pins the marker fields the resume path branches on: the legacy
// head-resolved fallback must be reachable ONLY for a non-PIN session, because for a PIN one it cannot
// succeed and would send refs derived from a 4-6 digit secret to the gateway.
func TestColdLockPinFlagGatesTheFallback(t *testing.T) {
	for _, tc := range []struct {
		name      string
		marker    string
		wantKeyed bool
		wantPin   bool
	}{
		{"pin+key", "alice\n12\nse\nfido2\npin\nd3JhcA==\nY3JlZA==:c2FsdA==:1\n", true, true},
		{"key, no pin", "alice\n12\nse\nfido2\nnopin\n\nY3JlZA==:c2FsdA==:1\n", true, false},
		{"keyless", "alice\n12\nse\nnokey\npin\nd3JhcA==\n", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, ".coldlock"), []byte(tc.marker), 0o600); err != nil {
				t.Fatal(err)
			}
			_, _, _, keyed, pin, _ := readColdLock(dir)
			if keyed != tc.wantKeyed || pin != tc.wantPin {
				t.Fatalf("readColdLock keyed=%v pin=%v; want keyed=%v pin=%v", keyed, pin, tc.wantKeyed, tc.wantPin)
			}
		})
	}
}
