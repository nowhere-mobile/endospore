package main

import (
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

// NWP-20261006-10: a profile tied to another phone's chip must look, on this phone, like nothing at all -- a throwaway
// sign-in with no scope restored. These pin the two predicates and the four places that consult them.

func TestVaultHeadLockedFollowsWhatTheCallerHolds(t *testing.T) {
	_, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	head := getRef("s3", headKey("s3", name, pass))
	open := func(se []byte) func(*vault) []byte {
		return func(v *vault) []byte { return openVaultDKSE(v, name, pass, se) }
	}
	if l, u := vaultHeadLocked("s3", head, open(nil)); l || u {
		t.Fatalf("an untied profile: locked=%v unreadable=%v to a caller holding only the passphrase", l, u)
	}
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	head = getRef("s3", headKey("s3", name, pass))
	for _, c := range []struct {
		se   []byte
		want bool
		who  string
	}{
		{nil, true, "the passphrase alone (another phone with no chip)"},
		{[]byte("phone-b-se-secret"), true, "another phone's chip"},
		{seA, false, "the phone it is tied to"},
	} {
		if got, u := vaultHeadLocked("s3", head, open(c.se)); got != c.want || u {
			t.Errorf("tied profile, caller holding %s: locked=%v unreadable=%v, want %v and readable", c.who, got, u, c.want)
		}
	}
	if l, u := vaultHeadLocked("s3", "", open(nil)); l || u {
		t.Error("no head is a throwaway already, not a locked head")
	}
}

func TestScopeRestoreRefusedForAProfileThatDoesNotOpenHere(t *testing.T) {
	_, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	t.Setenv("NOWHERE_SE_SECRET", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	if l, u := scopeOwnerLocked("s3", name+"#media", pass); l || u {
		t.Fatal("an untied profile's scope was refused")
	}
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	for _, suf := range []string{"#de", "#sys", "#media", "#apps", "#keys"} {
		if l, u := scopeOwnerLocked("s3", name+suf, pass); !l || u {
			t.Errorf("%s of a profile tied elsewhere would restore by passphrase alone", suf)
		}
	}
	if l, u := scopeOwnerLocked("s3", name, pass); l || u {
		t.Error("the bare profile is not a scope (its own restore already finds nothing)")
	}
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	if l, u := scopeOwnerLocked("s3", name+"#media", pass); l || u {
		t.Fatal("on the phone it is tied to, its scopes were refused")
	}
}

// The four call sites, by source order: each must consult the predicate before it does the thing it guards.
func TestLockedHeadIsConsultedWhereItMatters(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	main, media := read("main.go"), read("mediafs.go")
	before := func(src, what, first, then string) {
		t.Helper()
		i, j := strings.Index(src, first), strings.Index(src, then)
		if i < 0 || j < 0 || i > j {
			t.Errorf("%s: %q must come before %q (at %d, %d)", what, first, then, i, j)
		}
	}
	restore := main[strings.Index(main, "\tcase \"restore\":"):]
	before(restore, "restore", "locked, unreadable := scopeOwnerLockedWith(base, profile, pass, memo)", "resolveKeyHeadForLoginWith(base, profile, pass, memo)")
	before(restore, "restore (an unreadable head exits before the locked arm)", "os.Exit(exitStoreUnreachable)", "if locked {")
	app := main[strings.Index(main, "\tcase \"restore-app\":"):]
	before(app, "restore-app", "locked, unreadable := scopeOwnerLocked(base, scope, pass)", "restoreAppCode(base, scope, pass, pkg, dest)")
	before(media, "mediad", "locked, unreadable := scopeOwnerLocked(base, name+\"#media\", pass)", "serveMediaScope(base, name, pass, userDir, cacheDir, stateDir)")
	roam := main[strings.Index(main, "if strings.HasPrefix(out, \"OK\") {\n\t\t// THROWAWAY detection"):]
	before(roam, "roam-in", "if vaultLocked(headVault, func(v *vault) []byte { return openVaultDKSE(v, name, pass, seKey) }) {",
		"\t\tif head == \"\" {\n\t\t\tmarkLocalSession(dest)")
	before(roam, "roam-in (the chip and key it checks are loaded first)", "loadFido2HmacEnv(dest)", "if vaultLocked(")
	// NWP-20261124-07: the strict head read and its BLANK NET arm come before anything records the sign-in.
	for _, first := range []string{"roamInHead(\"s3\", name, pass, srcUnit)", "roamInHeadUnreadable(conn, dest, name)"} {
		before(roam, "roam-in (the head read is strict and first)", first, "beginTelStaging(uid, true)")
		before(roam, "roam-in (the head read is strict and first)", first, "markRoamSession(dest,")
		before(roam, "roam-in (the head read is strict and first)", first, "removeWallet(walletPathFor(dest))")
	}
}
