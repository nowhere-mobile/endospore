package main

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260917-21 (fixes NWP-20260917-15): a HARDENED profile whose marker has gone stale must still be able
// to change its passphrase.
//
// The se_secret read was gated on `live`, i.e. on the marker's line 2 matching the credential being rotated
// FROM. It has nothing to do with that: it is a property of the handset that was admitted, and it lives on
// line 4. Gating it that way left seSecret nil on exactly the stale-marker path NWP-20260917-14 exists to
// repair -- rotateVault returned ErrRotateNoSESecret, say() rendered it BLANK because live is false, and the
// user was told a CORRECT passphrase did not match, for the rest of that session.
//
// ⚠⚠ AND THAT WAS NOT A CORNER CASE. SE hardening was AUTOMATIC on Endospore then (the gate's ENROLL-SE ran at profile
// creation; lynx 2026091701 hardened odtest52 and the two profiles before it; opt-in since NWP-20261006-09, and a
// tied profile still reaches this path), so NWP-20260917-14's repair --
// and the log line NWP-20260916-03 needs to identify whatever stales the marker -- were dead code on the
// whole fleet. This is the test that says so.
func TestAHardenedProfileWithAStaleMarkerCanStillRotate(t *testing.T) {
	dest := capRotateFixture(t)
	calls := stubRekey(t, "OK")
	const name, oldp, newp = "hardstale", "horse battery staple correct", "a completely different passphrase"
	const stale = "whatever a late writer put back"
	se := []byte("handset-A-secret")
	seHex := hex.EncodeToString(se)

	createVault("s3", name, oldp)
	if err := enrollSE("s3", name, oldp, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	// A COMPLETE marker naming this profile, carrying this handset's se_secret, whose only fault is line 2.
	liveMarker(t, dest, name, stale, "14", seHex)

	if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
		t.Fatalf("rotation replied %q, want OK 0.\nBLANK here is the whole defect: the passphrase is CORRECT "+
			"and opens the vault, but the se_secret was not read because line 2 disagreed, so rotateVault "+
			"refused with ErrRotateNoSESecret and say() blanked it. The user is told their passphrase is "+
			"wrong, and nothing repairs the marker, so it keeps saying that for the rest of the session", got)
	}
	// ⚠ NOT resolveKey: a HARDENED vault does not open on the passphrase alone -- it needs the se_secret
	// too, so resolveKey answers !ok here whether or not the rotation published. The head under the new
	// credential is the credential-derived fact that actually distinguishes the two.
	if getRef("s3", headKey("s3", name, newp)) == "" {
		t.Error("no head under the new passphrase -- the rotation did not actually publish")
	}

	sn, sp, su := readRoamSession(dest)
	if sn != name || su != "14" {
		t.Fatalf("marker reads (%q,_,%q), want (%q,_,14)", sn, su, name)
	}
	if sp != newp {
		t.Errorf("the marker carries %q, want the rotated passphrase -- the repair did not run, so this "+
			"session still seals at a credential the store has now retired", sp)
	}
	// The repair rewrites the whole marker. Blanking line 4 on a HARDENED profile is a silent strand: the
	// worker exports nothing and every later seal opens no slot -- on precisely the profiles this rescues.
	if got := readRoamSessionSE(dest); got != seHex {
		t.Errorf("se_secret is %q after the repair, want it preserved (%q)", got, seHex)
	}
	// Unchanged from NWP-20260917-14: the marker cannot vouch for what the warm keyguard is armed with, so
	// the --old passed to lock_settings would be a guess, and a wrong guess locks the user out of their screen.
	if len(*calls) != 0 {
		t.Errorf("the keyguard re-key ran %d times on the repair path, want 0", len(*calls))
	}
}

// TestAHardenedProfileWithADamagedMarkerStillRefuses is the guard, not a reproduction: this behaviour is
// DELIBERATE and predates the fix. A damaged marker yields no se_secret, so a hardened rotation refuses
// rather than publishing a credential the handset can no longer open the vault with.
//
// It is enforced by the READER -- readRoamSessionSE returns "" for anything that is not roamSessionComplete
// -- which is why widening the condition around it is safe. This test is what holds that apart: it fails the
// moment someone "simplifies" the refusal by reading line 4 directly.
func TestAHardenedProfileWithADamagedMarkerStillRefuses(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "harddmg", "horse battery staple correct", "a completely different passphrase"
	const stale = "whatever a late writer put back"
	se := []byte("handset-A-secret")

	createVault("s3", name, oldp)
	if err := enrollSE("s3", name, oldp, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	// DAMAGED but WITH a line 4. The uid line is present-and-EMPTY, which is what readRoamSessionFields
	// calls damaged, while line 4 still carries a real se_secret.
	//
	// ⚠ THE SHAPE IS THE TEST. A first draft used a two-line marker and a mutation run proved it VACUOUS:
	// stripping the completeness guard out of readRoamSessionSE did not fail it, because a two-line marker
	// has no line 4 to return either way -- it passed for the wrong reason. This marker is the one where
	// that guard is the only thing standing between a damaged marker and a usable secret.
	body := name + "\n" + stale + "\n" + "\n" + hex.EncodeToString(se) + "\n"
	if err := os.MkdirAll(dest, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".roamsession"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	if got := rotateVerb(t, dest, name, oldp, newp); got != "BLANK" {
		t.Errorf("replied %q, want BLANK -- a damaged marker carries no se_secret, and publishing a new "+
			"credential the handset cannot open the vault with is worse than refusing", got)
	}
	// Same reason as above: assert on the heads, not on resolveKey, because this profile is hardened.
	if getRef("s3", headKey("s3", name, oldp)) == "" {
		t.Error("the head under the OLD passphrase is gone -- the rotation published despite refusing")
	}
	if getRef("s3", headKey("s3", name, newp)) != "" {
		t.Error("a head was published under the new passphrase after the refusal")
	}
}

// TestTheStaleMarkerRepairLineNamesTheUser: the repair line exists to tie a stale marker to a SESSION, and
// the first version could not. It passed setOrEmpty(su), so the first time it ever fired -- planted on lynx
// 2026091701 on 2026-09-17, the first time the NWP-20260916-03 instrument had ever been able to fire at all
// -- it printed "(user set)". The one field a reader needs, withheld by the line built to supply it.
func TestTheStaleMarkerRepairLineNamesTheUser(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "namesuser", "horse battery staple correct", "a completely different passphrase"
	const stale = "whatever a late writer put back"
	se := []byte("handset-A-secret")

	createVault("s3", name, oldp)
	if err := enrollSE("s3", name, oldp, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	liveMarker(t, dest, name, stale, "17", hex.EncodeToString(se))

	out := captureStderr(t, func() {
		if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
			t.Errorf("rotation replied %q, want OK 0", got)
		}
	})

	if !strings.Contains(out, "(user 17)") {
		t.Errorf("the repair line does not name the user. Got:\n%s\nwant it to contain \"(user 17)\" -- "+
			"without the uid the line says only THAT a marker went stale, never WHOSE, which is the whole "+
			"thing NWP-20260916-03 could not establish", out)
	}
	if strings.Contains(out, "(user set)") {
		t.Error("the repair line printed presence instead of the uid -- setOrEmpty is for a DAMAGED marker, " +
			"where a shifted line could put the passphrase in the uid slot; this marker is complete")
	}
}

// TestTheRepairLineNeverPrintsADamagedMarkersUidSlot is the leak guard, and it is why the line checks the
// SHAPE of the uid rather than the marker state.
//
// A marker's uid "may be anything at all (a shifted line)" (roamsession_marker.go). A shift can put a SECRET
// in the uid slot, and printing it raw would write that secret into a log the issue reporter can ship. The
// trap is that the shifted marker still reads as COMPLETE, so the state is no defence -- see the fixture.
func TestTheRepairLineNeverPrintsADamagedMarkersUidSlot(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "shifted", "horse battery staple correct", "a completely different passphrase"
	const stale = "whatever a late writer put back"
	// NOT hardened: a hardened profile refuses a damaged marker outright (no se_secret) and the repair
	// branch is never reached, so the leak could not be observed there. This profile reaches it.
	createVault("s3", name, oldp)

	// THE FRANKEL SHAPE: the uid line is LOST, so the marker is (name, pass, se_secret) -- three non-empty
	// fields, which readRoamSessionFields reads as COMPLETE with the SE SECRET in the uid slot.
	//
	// ⚠ This is why the guard cannot be `sst == roamSessionComplete`. A first version of the fix used
	// exactly that, and this test caught it printing the secret verbatim. The marker STATE cannot tell a
	// real uid from a shifted secret; only the SHAPE of the value can.
	const shifted = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
	writeMarker(t, dest, name+"\n"+stale+"\n"+shifted+"\n")

	out := captureStderr(t, func() { rotateVerb(t, dest, name, oldp, newp) })

	if strings.Contains(out, shifted) {
		t.Errorf("the repair line printed a DAMAGED marker's uid slot verbatim:\n%s\nA shifted line puts the "+
			"passphrase there, so this writes the login secret into a log", out)
	}
	if strings.Contains(out, "rotate: the session marker") && !strings.Contains(out, "(user set)") {
		t.Errorf("the repair line fired on a shifted marker but did not render presence. Got:\n%s", out)
	}
}
