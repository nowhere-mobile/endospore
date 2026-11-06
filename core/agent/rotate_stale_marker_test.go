package main

import (
	"encoding/hex"
	"testing"
)

// NWP-20260917-14: a rotation that COMMITS while the session marker disagrees with it must repair the
// marker, not leave it.
//
// This is the permanent carrier found while tracing NWP-20260916-03. rotateVault publishes and RETIRES
// whatever the rotation opened, and handleRotate replies a plain "OK n" either way -- but the only marker
// write sat under `live`, which is false the moment line 2 of the marker is not the credential being
// rotated from. So a rotation in that state was INDISTINGUISHABLE FROM A CLEAN ONE to the user while
// leaving the live session sealing at a credential the store had just retired. Every seal re-reads the
// marker (roam.req line 3 -> pw() -> a fresh push), so nothing later in that session could heal it: the
// observed shape was seals that silently stopped landing for the rest of the session.
func TestRotateRepairsAMarkerThatCarriesAnotherCredential(t *testing.T) {
	dest := capRotateFixture(t)
	calls := stubRekey(t, "OK")
	const name, oldp, newp = "verbstale", "horse battery staple correct", "a completely different passphrase"
	const stale = "whatever a late writer put back"
	// A marker se line WITHOUT an SE enrolment on the profile. The two are independent -- line 4 is whatever
	// the marker holds and readRoamSessionSE just reads it -- and keeping them apart is deliberate: a
	// hardened profile cannot reach this branch at all today, because the se_secret is read only under
	// `live`, so a stale marker makes a hardened rotation refuse instead of committing (NWP-20260917-15).
	// That is a separate defect with a separate fix; what is pinned here is that the repair preserves line 4.
	seHex := hex.EncodeToString([]byte("handset-secret"))

	createVault("s3", name, oldp)
	// The marker names THIS profile, and its uid is intact -- it is a live session by every test the daemon
	// applies. Only line 2 is wrong, which is the entire fault: it is what every seal sends as the credential.
	liveMarker(t, dest, name, stale, "12", seHex)

	if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
		t.Fatalf("rotation replied %q, want OK 0 -- the rotation itself must be unaffected", got)
	}

	sn, sp, su := readRoamSession(dest)
	if sn != name || su != "12" {
		t.Fatalf("marker reads (%q,_,%q), want (%q,_,12)", sn, su, name)
	}
	if sp == stale {
		t.Error("the marker still carries the stale credential after a COMMITTED rotation -- this session " +
			"will seal at a passphrase the store has retired, for the rest of its life, with no error " +
			"anywhere and a plain OK on the wire (NWP-20260916-03)")
	}
	if sp != newp {
		t.Errorf("the marker carries %q, want the rotated passphrase -- the commit is what settles which "+
			"credential is real, so the marker has exactly one correct value here", sp)
	}
	// The repair is a full rewrite of the marker, so it can blank line 4 exactly the way the recovery path
	// once did. A hardened profile with an empty se_secret exports nothing and every later seal opens no
	// slot -- a silent strand on precisely the profiles this is meant to rescue.
	if got := readRoamSessionSE(dest); got != seHex {
		t.Errorf("se_secret is %q after the repair, want it preserved (%q)", got, seHex)
	}
	// The keyguard is deliberately NOT widened: rekeyKeyguard passes oldpass as the --old, and a stale
	// marker cannot vouch for what the warm keyguard is actually armed with. Guessing there locks a user
	// out of their own screen, which is worse than the bug being fixed.
	if len(*calls) != 0 {
		t.Errorf("the keyguard re-key ran %d times on the repair path, want 0 -- the marker does not vouch "+
			"for the old credential, so the --old passed to lock_settings would be a guess", len(*calls))
	}
}

// TestRotateLeavesAnotherProfilesMarkerAlone: the repair keys on the marker naming THE PROFILE BEING
// ROTATED. A rotation driven for a different profile while someone is signed in must not touch the signed-in
// session's marker -- that would hand one profile's credential to another profile's seals, which is a data
// loss, not a repair. The guard is `sn == name`, and this is the test that holds it there.
func TestRotateLeavesAnotherProfilesMarkerAlone(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "verbother", "horse battery staple correct", "a completely different passphrase"
	const liveName, livePass = "someone-else", "the signed-in session passphrase"

	createVault("s3", name, oldp)
	liveMarker(t, dest, liveName, livePass, "13", "")

	if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
		t.Fatalf("rotation replied %q, want OK 0", got)
	}
	sn, sp, su := readRoamSession(dest)
	if sn != liveName || sp != livePass || su != "13" {
		t.Errorf("the signed-in session's marker reads (%q,%q,%q), want (%q,%q,13) -- a rotation for a "+
			"DIFFERENT profile overwrote it, so that session's seals now carry another profile's credential",
			sn, sp, su, liveName, livePass)
	}
}

// TestRotateWithNoMarkerWritesNone: with no session at all there is nothing to repair, and writing a marker
// would CREATE a session that does not exist -- the daemon treats a marker as proof somebody is signed in
// (the periodic seal, the logoff capture and the legacy-login guard all key on it). The CLI rotate verb and
// a rotation from the gate before login both land here.
func TestRotateWithNoMarkerWritesNone(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const name, oldp, newp = "verbnomark", "horse battery staple correct", "a completely different passphrase"

	createVault("s3", name, oldp)

	if got := rotateVerb(t, dest, name, oldp, newp); got != "OK 0" {
		t.Fatalf("rotation replied %q, want OK 0", got)
	}
	if roamSessionExists(dest) {
		t.Error("the rotation created a session marker where there was none -- the daemon reads a marker as " +
			"proof somebody is signed in, so this fabricates a session for the periodic seal to act on")
	}
}
