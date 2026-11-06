package main

import (
	"encoding/hex"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// hardenedTwoHandsets stands up a hardened profile with handsets A and B enrolled, and returns the 12 words.
func hardenedTwoHandsets(t *testing.T, base, name, pass string, seA, seB []byte) string {
	t.Helper()
	mnemonic := createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if err := enrollSE(base, name, pass, seA); err != nil {
		t.Fatalf("A enrollSE: %v", err)
	}
	if len(seB) > 0 {
		if err := enrollSEViaRecovery(base, name, mnemonic, pass, seB); err != nil {
			t.Fatalf("B enrollSEViaRecovery: %v", err)
		}
	}
	return mnemonic
}

// TestRotationKeepsTheActingHandsetSignedIn is NWP-20260915-10, and it is the inverse of a measured lockout.
//
// Hardening drops the `pass` slot, and `kekSE` is Argon2id(passphrase, salt=H(name‖se_secret)) -- so every
// `se` slot dies the instant the passphrase moves. rotateVault carried them forward unchanged, and its
// rewrap loop touched only slots of kind `pass`, which a hardened vault does not have. Probed on a
// two-handset vault before the fix: after the rotation the handset that PERFORMED it opened ZERO slots and
// the 12-word code was the only opener left -- on the phone in the user's hand.
func TestRotationKeepsTheActingHandsetSignedIn(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldp, newp = "rotkeep", "horse battery staple correct", "a completely different passphrase"
	seA := []byte("handset-A-strongbox-secret")
	hardenedTwoHandsets(t, base, name, oldp, seA, nil)

	retired, err := rotateVault(base, name, oldp, newp, seA, true)
	if err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if retired != 0 {
		t.Errorf("retired %d keyslots on a single-handset profile, want 0", retired)
	}
	if n := seSlotsOpenableBy(t, base, name, newp, seA); n != 1 {
		t.Fatalf("after the rotation the acting handset opens %d se slots under the NEW passphrase, want 1 -- "+
			"this is the lockout: the phone that changed the passphrase can no longer open its own profile", n)
	}
	// ...and hardening must survive it. A rotation that quietly re-admitted the passphrase would "fix" the
	// lockout by giving away the property hardening exists to provide.
	if _, _, ok := resolveKey(base, name, newp); ok {
		t.Error("the new passphrase ALONE opens the vault -- the rotation un-hardened the profile")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, newp))))
	if !v.Hardened {
		t.Error("Hardened went false across the rotation")
	}
}

// TestRotationRetiresTheOtherHandsetsAndSaysHowMany: the other phones cannot follow -- kekSE is
// passphrase-bound and only the handset holding a secret can re-wrap its own slot. Their slots are therefore
// dead the moment the passphrase moves, and keeping them would grow the vault (and its lease) with bytes no
// key on earth can open. The COUNT is the point: it is what lets the screen say "your other phone" rather
// than hedging about phones the user may not have.
func TestRotationRetiresTheOtherHandsetsAndSaysHowMany(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldp, newp = "rotretire", "horse battery staple correct", "a completely different passphrase"
	seA, seB := []byte("handset-A-secret"), []byte("handset-B-secret")
	mnemonic := hardenedTwoHandsets(t, base, name, oldp, seA, seB)

	retired, err := rotateVault(base, name, oldp, newp, seA, true)
	if err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if retired != 1 {
		t.Errorf("reported %d retired keyslots, want 1 -- the screen cannot name the consequence without it", retired)
	}
	if n := seSlotsOpenableBy(t, base, name, newp, seA); n != 1 {
		t.Errorf("the acting handset opens %d slots, want 1", n)
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, newp))))
	if got := seSlotCount(v); got != 1 {
		t.Errorf("the vault carries %d se slots after the rotation, want 1 -- a slot nothing can open is "+
			"unbounded growth, paid for on every lease", got)
	}
	// The retirement must be recoverable, or it is just a slower lockout: B rejoins with ADD-DEVICE, using
	// the NEW passphrase and the 12 words.
	if err := enrollSEViaRecovery(base, name, mnemonic, newp, seB); err != nil {
		t.Fatalf("handset B could not rejoin after the rotation: %v", err)
	}
	if n := seSlotsOpenableBy(t, base, name, newp, seB); n != 1 {
		t.Errorf("after rejoining, handset B opens %d slots, want 1", n)
	}
	if n := seSlotsOpenableBy(t, base, name, newp, seA); n != 1 {
		t.Errorf("handset B rejoining cost handset A its slot (%d)", n)
	}
}

// TestRotationRefusesWithoutTheSecureElementSecret pins the refusal that replaces the fielded symptom.
//
// ⚠ THE FIELDED SYMPTOM WAS NOT A FALSE SUCCESS -- it was a false ACCUSATION. The login daemon never has
// NOWHERE_SE_SECRET (the sole exporter in the tree is nowhere_roamd.sh, inside the su:s0 worker), so a
// hardened ROTATE fell through openVaultDK to "pass slot won't unwrap", the daemon answered BLANK, and the
// chooser printed "couldn't change -- check your current passphrase" about a passphrase that was correct.
// The check now fires BEFORE the open, so the reason is honest and the store is never touched.
func TestRotationRefusesWithoutTheSecureElementSecret(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldp, newp = "rotnosec", "horse battery staple correct", "a completely different passphrase"
	seA := []byte("handset-A-secret")
	hardenedTwoHandsets(t, base, name, oldp, seA, nil)
	before := getRef(base, headKey(base, name, oldp))

	_, err := rotateVault(base, name, oldp, newp, nil, true)
	if !errors.Is(err, ErrRotateNoSESecret) {
		t.Fatalf("rotate without a secret returned %v, want ErrRotateNoSESecret -- any other error is rendered "+
			"as a credential accusation against a correct passphrase", err)
	}
	if after := getRef(base, headKey(base, name, oldp)); after != before {
		t.Error("the refusal still moved the head -- a refusal must write nothing")
	}
	if getRef(base, headKey(base, name, newp)) != "" {
		t.Error("a head was published under the new passphrase despite the refusal")
	}
	if n := seSlotsOpenableBy(t, base, name, oldp, seA); n != 1 {
		t.Error("the acting handset's slot was disturbed by a refused rotation")
	}
}

// TestRotationRefusesRatherThanStrandTheActingHandset drives the guard that "shouldn't happen": DK opens by
// some other route while every `se` slot belongs to someone else. rotateVault would then publish a vault
// this device cannot open -- the exact lockout, arrived at from the other side. The fido2 arm has carried
// this guard since DIA-20260704-35 ("refuse rather than strand"); the `se` arm did not exist.
//
// The vault is hand-built because production cannot currently produce the shape -- hardenVaultTo drops every
// `pass` slot when it adds an `se` one. That is exactly why the guard is worth having: it is the net under a
// state no current path reaches, and a net nothing can fall into is untested, not unnecessary.
func TestRotationRefusesRatherThanStrandTheActingHandset(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldp, newp = "rotstrand", "horse battery staple correct", "a completely different passphrase"
	seOther := []byte("some-other-handsets-secret")
	createVault(base, name, oldp)

	// Add a FOREIGN se slot alongside the pass slot, then republish.
	head := getRef(base, headKey(base, name, oldp))
	v, _ := parseVault(getHeadBlob(base, head))
	dk := unwrapDK(v, "pass", deriveKey(name, oldp))
	if dk == nil {
		t.Fatal("pass slot won't unwrap")
	}
	v.Slots = append(v.Slots, keyslot{Kind: "se", Wrapped: wrap(kekSE(name, oldp, seOther), dk)})
	v.Version++
	signVault(v, dk)
	putHeadSingle(base, name, oldp, postBlob(base, serializeVault(v)))
	before := getRef(base, headKey(base, name, oldp))

	// This handset holds a DIFFERENT secret, so DK still opens (via the pass slot) but no se slot follows.
	_, err := rotateVault(base, name, oldp, newp, []byte("this-handsets-secret"), true)
	if !errors.Is(err, ErrRotateSEStrand) {
		t.Fatalf("rotate returned %v, want ErrRotateSEStrand", err)
	}
	if after := getRef(base, headKey(base, name, oldp)); after != before {
		t.Error("the refusal still moved the head")
	}
}

// TestRotationMigratesTheRestoreReceipts: without this a SUCCESSFUL rotation silently stops the session
// sealing, including the logoff capture -- so the user changes their passphrase and loses everything the
// session did afterwards.
//
// pushProfile keys the receipt by profileRefV2(profile, pass) and refuses to overwrite a non-empty head
// without one; a rotation moves that ref, and reanchorReceipt deliberately never MINTS one. Pre-existing and
// not specific to hardening: it has applied to every successful rotation, Diaspore included.
func TestRotationMigratesTheRestoreReceipts(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	const name, oldp, newp = "rotrcpt", "horse battery staple correct", "a completely different passphrase"
	createVault(base, name, oldp)

	// The shape a live session is in: a receipt for the bare profile and for a scope it restored.
	writeRestoreReceipt(profileRefV2(name, oldp), "old-bare-head")
	writeRestoreReceipt(profileRefV2(name+"#media", oldp), "old-media-head")

	if _, err := rotateVault(base, name, oldp, newp, nil, true); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	for _, scoped := range []string{name, name + "#media"} {
		if !haveRestoreReceipt(profileRefV2(scoped, newp)) {
			t.Errorf("no receipt for %q under the new passphrase -- its next seal is REFUSED, and the seal that "+
				"matters most is the logoff capture", scoped)
		}
		if haveRestoreReceipt(profileRefV2(scoped, oldp)) {
			t.Errorf("the receipt for %q still names the tombstoned old credential", scoped)
		}
	}
	// ⚠ MOVING IS NOT MINTING. A scope this session never restored must NOT acquire a certificate it never
	// earned -- that guard is what stopped a 46%-complete restore from destroying 2.8 GB.
	if haveRestoreReceipt(profileRefV2(name+"#apps", newp)) {
		t.Error("a receipt was MINTED for a scope that never had one -- the incomplete-restore guard is disarmed")
	}
}

// TestRotationOnAPassOnlyVaultIsUnchanged is the canary for Diaspore and for every un-hardened Endospore
// profile: every new refusal is gated on an `se` slot existing, so a pass-only rotation must take exactly
// the path it always took, with no secret supplied and nothing retired.
func TestRotationOnAPassOnlyVaultIsUnchanged(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldp, newp = "rotplain", "horse battery staple correct", "a completely different passphrase"
	createVault(base, name, oldp)

	retired, err := rotateVault(base, name, oldp, newp, nil, true)
	if err != nil {
		t.Fatalf("a pass-only rotation must not need a secure-element secret: %v", err)
	}
	if retired != 0 {
		t.Errorf("retired %d keyslots on a pass-only vault, want 0", retired)
	}
	if _, _, ok := resolveKey(base, name, newp); !ok {
		t.Error("the new passphrase does not open a pass-only vault after rotation")
	}
	if _, _, ok := resolveKey(base, name, oldp); ok {
		t.Error("the OLD passphrase still opens it -- the rotation revoked nothing")
	}
}

// TestRotationRefusesWhenThePublishIsFenced: rotateVault consulted only rotRepointErr, so a publish the
// store refused returned nil and the chooser said the passphrase had changed. The user then walks away
// believing a credential that does not exist -- and the old one, which does, is the one they have stopped
// using. Every other vault publisher already checks this.
//
// ⚠ IT ARMS THE REAL GUARDS. These cases used to set sealFenceHit/sealStaleHit directly before the
// call; NWP-20260915-14 made that meaningless, because capWrite now clears both as it opens the bracket
// (in the daemon they otherwise latch for the whole boot and make a LATER rotation report a failure that
// never happened). Arming the mechanism proves strictly more: that a real refusal reaches the arm.
func TestRotationRefusesWhenThePublishIsFenced(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldp, newp = "rotfence", "horse battery staple correct", "a completely different passphrase"
	createVault(base, name, oldp)

	t.Setenv("NOWHERE_STATE", t.TempDir())
	pushFenceSeq, pushFenceSampled = 0, false
	for _, tc := range []struct {
		label string
		arm   func(ref string)
		newp  string
	}{
		{"fence", func(ref string) { armSealFence([]string{ref}) }, newp},
		{"stale", func(ref string) { expectRef(ref, "a head value the store does not hold") }, newp + " two"},
	} {
		t.Run(tc.label, func(t *testing.T) {
			ref := profileRefV2(name, tc.newp) // where this rotation would publish the new head
			tc.arm(ref)
			t.Cleanup(func() {
				liftSealFence([]string{ref})
				clearSealExpectations()
				sealFenceHit = false
			})
			_, err := rotateVault(base, name, oldp, tc.newp, nil, true)
			if err == nil {
				t.Error("rotation reported SUCCESS over a refused publish")
			}
			// ...and it was refused by the guard this case armed, not by something upstream of it. Without
			// this a case that fails early reports an error and goes green over an arm it never reached --
			// which is exactly what a surviving mutant caught in the add-device twin of this test.
			if !sealFenceHit && !sealStaleHit {
				t.Errorf("nothing was actually refused, so this case proved nothing -- rotateVault failed "+
					"with %v, upstream of the guard this case armed", err)
			}
		})
	}
}

// --- the daemon verb ------------------------------------------------------------------------------------

// liveMarker writes the .roamsession shape a signed-in session has, so handleRotate can recognise its own
// caller. seHex "" is the un-hardened case; uid "" is the documented DAMAGED shape (the frankel marker,
// whose uid line was lost).
func liveMarker(t *testing.T, dest, name, pass, uid, seHex string) {
	t.Helper()
	if err := os.MkdirAll(dest, 0o700); err != nil {
		t.Fatal(err)
	}
	body := name + "\n" + pass + "\n" + uid + "\n" + seHex + "\n"
	if err := os.WriteFile(filepath.Join(dest, ".roamsession"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// rotateVerb drives the daemon handler over a pipe and returns the reply line, so what is pinned is the
// bytes the chooser reads rather than a Go error the wire never carries.
func rotateVerb(t *testing.T, dest, name, oldpass, newpass string) string {
	t.Helper()
	c1, c2 := net.Pipe()
	go func() {
		handleRotate(c2, dest, name, oldpass, newpass)
		c2.Close()
	}()
	raw, err := io.ReadAll(c1)
	if err != nil {
		t.Fatalf("reading the ROTATE reply: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

// capRotateFixture stands up cap mode (the entire fielded fleet) with a funded wallet, and returns the state
// dir the session marker lives in.
func capRotateFixture(t *testing.T) string {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	return dest
}

// stubRekey replaces the keyguard re-key for one test and records what it was asked to do. The real call
// polls the su:s0 worker for up to 150s before giving up, so a guard reachable only through it would be a
// guard that is never tested -- the same reason dumpsysConnectivity is a variable.
func stubRekey(t *testing.T, out string) *[][4]string {
	t.Helper()
	saved := rekeyKeyguard
	calls := &[][4]string{}
	rekeyKeyguard = func(dest, name, oldpass, uid, newpass string) string {
		*calls = append(*calls, [4]string{name, oldpass, uid, newpass})
		return out
	}
	t.Cleanup(func() { rekeyKeyguard = saved })
	return calls
}

// TestRotateVerbNamesWhichFailure pins the wire contract (NWP-20260915-10).
//
// ⚠ EVERY NAMED REFUSAL IS GATED ON THE LIVE SESSION, and that is what keeps blind login intact: they reach
// only a caller who already IS the signed-in session, and anybody else gets the same BLANK the socket gave
// before. Someone holding the session open learns nothing from being told which of their own fields was
// wrong -- while a user who typed a correct passphrase stops being told it was wrong, which was the whole
// fielded symptom.
func TestRotateVerbNamesWhichFailure(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "verbrot", "horse battery staple correct", "a completely different passphrase"
	seA := []byte("handset-A-secret")
	if createVault("s3", name, oldp) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	if err := enrollSE("s3", name, oldp, seA); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}

	// A live session whose marker carries NO se_secret: hardened profile, secret unavailable.
	liveMarker(t, dest, name, oldp, "10", "")
	if got := rotateVerb(t, dest, name, oldp, newp); got != "ERR-SECRET" {
		t.Errorf("hardened rotation with no session secret replied %q, want ERR-SECRET -- anything else renders as "+
			"a credential accusation against a correct passphrase", got)
	}

	// A caller that is NOT the live session gets the blind answer, whatever went wrong.
	if got := rotateVerb(t, dest, name, "not the session passphrase", newp); got != "BLANK" {
		t.Errorf("a stranger's failed rotation replied %q, want BLANK", got)
	}

	// The same session, now with its secret: the rotation goes through and reports what it retired.
	liveMarker(t, dest, name, oldp, "10", hex.EncodeToString(seA))
	if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
		t.Fatalf("rotation replied %q, want OK 0", got)
	}
	if n := seSlotsOpenableBy(t, "s3", name, newp, seA); n != 1 {
		t.Errorf("after the verb, the acting handset opens %d slots under the new passphrase, want 1", n)
	}
}

// TestRotateVerbKeepsTheSessionSecretOnTheMarker: the handler used to write
// markRoamSession(dest, name, newpass, uid, "") -- an EMPTY se_secret, under the comment "recovery path: no
// SE secret yet". markRoamSession is a full rewrite, so that ERASES line 4; readRoamSessionSE then returns
// "" for the rest of the session, the worker exports nothing, and every later seal opens no slot -- the
// periodic sync, the logoff capture, the save-point and the rollback all strand silently. Harmless only
// while a hardened rotation never reached the success branch, which is exactly what this slice changes.
func TestRotateVerbKeepsTheSessionSecretOnTheMarker(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "verbmark", "horse battery staple correct", "a completely different passphrase"
	seA := []byte("handset-A-secret")
	createVault("s3", name, oldp)
	if err := enrollSE("s3", name, oldp, seA); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	seHex := hex.EncodeToString(seA)
	liveMarker(t, dest, name, oldp, "10", seHex)

	if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
		t.Fatalf("rotation replied %q", got)
	}
	sn, sp, su := readRoamSession(dest)
	if sn != name || sp != newp || su != "10" {
		t.Errorf("marker reads (%q,%q,%q), want (%q,%q,10)", sn, sp, su, name, newp)
	}
	if got := readRoamSessionSE(dest); got != seHex {
		t.Errorf("the session's se_secret is %q after the rotation, want it preserved -- an empty line 4 means "+
			"the next seal, and above all the logoff capture, opens no slot and strands silently", got)
	}
}

// TestRotateVerbRefusesWhenTheKeyguardCannotFollow: the roamed user's lockscreen is armed with the
// passphrase typed at the gate -- one-shot, captured as a final String, never re-read. So a rotation that
// publishes without re-keying leaves the user unable to unlock the phone they were just told had a new
// passphrase. handlePromote2 states the rule this now follows: re-key FIRST, and do not proceed if it fails.
func TestRotateVerbRefusesWhenTheKeyguardCannotFollow(t *testing.T) {
	dest := capRotateFixture(t)
	calls := stubRekey(t, "ERR-TIMEOUT")
	const name, oldp, newp = "verbkey", "horse battery staple correct", "a completely different passphrase"
	createVault("s3", name, oldp)
	liveMarker(t, dest, name, oldp, "11", "")

	if got := rotateVerb(t, dest, name, oldp, newp); got != "ERR-REKEY" {
		t.Fatalf("replied %q, want ERR-REKEY", got)
	}
	if len(*calls) != 1 {
		t.Errorf("the keyguard re-key was attempted %d times, want 1", len(*calls))
	}
	if _, _, ok := resolveKey("s3", name, oldp); !ok {
		t.Error("the old passphrase no longer opens the profile -- the rotation published despite refusing")
	}
	if getRef("s3", headKey("s3", name, newp)) != "" {
		t.Error("a head was published under the new passphrase after an ERR-REKEY refusal")
	}
}

// TestRotateVerbRollsTheKeyguardBackWhenTheRotationFails: the re-key happens FIRST, so a rotation that then
// refuses would leave the lockscreen wanting a passphrase that opens nothing -- the mirror image of the bug
// this slice fixes. handlePromote2 performs the same rollback for the same reason.
func TestRotateVerbRollsTheKeyguardBackWhenTheRotationFails(t *testing.T) {
	dest := capRotateFixture(t)
	calls := stubRekey(t, "OK")
	const name, oldp, newp = "verbroll", "horse battery staple correct", "a completely different passphrase"
	seA := []byte("handset-A-secret")
	createVault("s3", name, oldp)
	if err := enrollSE("s3", name, oldp, seA); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	liveMarker(t, dest, name, oldp, "12", "") // hardened, and the marker carries no secret -> ERR-SECRET

	if got := rotateVerb(t, dest, name, oldp, newp); got != "ERR-SECRET" {
		t.Fatalf("replied %q, want ERR-SECRET", got)
	}
	if len(*calls) != 2 {
		t.Fatalf("the keyguard was re-keyed %d time(s); want 2 -- forward, then rolled back", len(*calls))
	}
	fwd, back := (*calls)[0], (*calls)[1]
	if fwd[1] != oldp || fwd[3] != newp {
		t.Errorf("forward re-key was %q -> %q, want %q -> %q", fwd[1], fwd[3], oldp, newp)
	}
	if back[1] != newp || back[3] != oldp {
		t.Errorf("rollback re-key was %q -> %q, want %q -> %q -- the lockscreen is otherwise left on a "+
			"passphrase that opens nothing", back[1], back[3], newp, oldp)
	}
}

// TestRotateVerbSkipsTheRekeyWhenTheSessionHasAPIN: with a session PIN the warm keyguard IS the PIN, which a
// passphrase change does not touch. Re-keying anyway would swap the user's PIN for a passphrase behind their
// back.
func TestRotateVerbSkipsTheRekeyWhenTheSessionHasAPIN(t *testing.T) {
	dest := capRotateFixture(t)
	calls := stubRekey(t, "OK")
	const name, oldp, newp = "verbpin", "horse battery staple correct", "a completely different passphrase"
	createVault("s3", name, oldp)
	liveMarker(t, dest, name, oldp, "13", "")
	if err := os.WriteFile(filepath.Join(dest, ".sessionpin"), []byte("246810"), 0o600); err != nil {
		t.Fatal(err)
	}

	if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
		t.Fatalf("replied %q, want OK 0", got)
	}
	if len(*calls) != 0 {
		t.Errorf("the keyguard was re-keyed %d time(s) on a PIN session; want 0", len(*calls))
	}
}

// TestRotateVerbRefusesADamagedMarkerRatherThanStrandTheKeyguard: a damaged marker (the frankel shape, uid
// line lost) is still a LIVE session -- the user is on screen. There is no uid to re-key, so publishing
// would leave the lockscreen behind; and because the session is still recognised as live, the refusal is
// NAMED rather than rendered as "that passphrase doesn't match" at the very user this slice exists for.
func TestRotateVerbRefusesADamagedMarkerRatherThanStrandTheKeyguard(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "verbdmg", "horse battery staple correct", "a completely different passphrase"
	createVault("s3", name, oldp)
	liveMarker(t, dest, name, oldp, "", "") // the uid line is lost

	if got := rotateVerb(t, dest, name, oldp, newp); got != "ERR-REKEY" {
		t.Errorf("a damaged marker replied %q, want ERR-REKEY -- BLANK here accuses a correct passphrase", got)
	}
	if _, _, ok := resolveKey("s3", name, oldp); !ok {
		t.Error("the old passphrase no longer opens the profile after a refusal")
	}
}
