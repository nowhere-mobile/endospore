package main

// NWP-20261029-16: the purge's wiring in deleteForSession, pinned by behaviour on every verdict.
//
// These tests REPLACE TestDeletePathCallsThePurge, a strings.Contains over the function text. That pin passed with
// the purge on the wrong arm ("unverified", where nothing was deleted and the user must retry), on only one of the
// two arms, called with the session's login credentials instead of the typed ones, or with purgeLocalProfileState
// no longer clearing the inbox. Here the real deleteForSession runs end to end on a test store and the outcome is
// read back from bindings.conf and the telephony inbox.

import (
	"net/http"
	"os"
	"testing"
)

const (
	purgeIccid1 = "8901000000000011"
	purgeIccid2 = "8901000000000012"
	purgeOther  = "cccc3333"
)

// purgeFixture binds name/pass on SIM 1 alone and on SIM 2 shared with an unrelated ref, and seals one item to
// the profile's inbox and one to the unrelated ref's.
func purgeFixture(t *testing.T, name, pass string) (ref string) {
	t.Helper()
	useTempBindings(t)
	useTempInbox(t)
	ref = profileRefV2(name, pass)
	bindAndSealPurgeFixture(t, ref)
	if err := setBindingOwner(2, purgeIccid2, "line two", "open", purgeOther, "pubOther"); err != nil {
		t.Fatal(err)
	}
	v, _ := vaultWithTelKey(t)
	if err := sealItemToInbox(purgeOther, v.TelPub, "", telItem{Kind: "sms", From: "+2", When: 2, Body: "other"}); err != nil {
		t.Fatal(err)
	}
	return ref
}

// bindAndSealPurgeFixture (re)binds ref on SIM 1 and SIM 2 and seals it one item.
func bindAndSealPurgeFixture(t *testing.T, ref string) {
	t.Helper()
	if err := setBindingOwner(1, purgeIccid1, "line one", "open", ref, "pubMine"); err != nil {
		t.Fatal(err)
	}
	if err := setBindingOwner(2, purgeIccid2, "line two", "open", ref, "pubMine"); err != nil {
		t.Fatal(err)
	}
	v, _ := vaultWithTelKey(t)
	if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: 1, Body: "mine"}); err != nil {
		t.Fatal(err)
	}
}

// wantPurged asserts the profile is off both SIMs, its inbox is empty and the unrelated ref is untouched.
func wantPurged(t *testing.T, ref string) {
	t.Helper()
	if _, ok := bindingForSubID(1, purgeIccid1); ok {
		t.Error("SIM 1 had only the deleted profile and still resolves an owner")
	}
	b2, ok := bindingForSubID(2, purgeIccid2)
	if !ok {
		t.Fatal("the SHARED SIM 2 did not survive the delete")
	}
	owners := ownerRefs(b2)
	if _, still := owners[ref]; still {
		t.Error("the deleted profile is still bound to the shared SIM")
	}
	if len(owners) != 1 || owners[purgeOther] != "pubOther" {
		t.Errorf("shared SIM owners = %v, want only the unrelated ref", owners)
	}
	if n := len(listSealed(ref)); n != 0 {
		t.Errorf("the deleted profile's inbox still holds %d item(s)", n)
	}
	if n := len(listSealed(purgeOther)); n != 1 {
		t.Errorf("the unrelated ref's inbox holds %d item(s), want 1", n)
	}
}

// wantUntouched asserts bindings.conf is byte-identical to before and the profile's inbox item is still there.
func wantUntouched(t *testing.T, ref string, before []byte) {
	t.Helper()
	after, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Errorf("bindings.conf changed:\nbefore %q\nafter  %q", before, after)
	}
	if n := len(listSealed(ref)); n != 1 {
		t.Errorf("the profile's inbox holds %d item(s), want 1", n)
	}
}

func TestDeletePurgeWiring_Deleted(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "purgewiredel", "correct horse battery"
	createVault(base, name, pass)
	ref := purgeFixture(t, name, pass)
	if got := deleteForSession(base, name, pass, name, pass, nil); got != "deleted" {
		t.Fatalf("deleteForSession = %q, want \"deleted\"", got)
	}
	wantPurged(t, ref)
}

func TestDeletePurgeWiring_Gone(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "purgewiregone", "correct horse battery"
	createVault(base, name, pass)
	ref := purgeFixture(t, name, pass)
	if got := deleteForSession(base, name, pass, name, pass, nil); got != "deleted" {
		t.Fatalf("first deleteForSession = %q, want \"deleted\"", got)
	}
	// A device whose earlier delete predated the purge: bound and holding mail again for a deleted profile.
	bindAndSealPurgeFixture(t, ref)
	if got := deleteForSession(base, name, pass, name, pass, nil); got != "gone" {
		t.Fatalf("second deleteForSession = %q, want \"gone\"", got)
	}
	wantPurged(t, ref)
}

func TestDeletePurgeWiring_Wrongpass(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "purgewirewrong", "correct horse battery"
	createVault(base, name, pass)
	ref := purgeFixture(t, name, pass)
	before, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := deleteForSession(base, name, "wrong-pass", name, pass, nil); got != "wrongpass" {
		t.Fatalf("deleteForSession = %q, want \"wrongpass\"", got)
	}
	wantUntouched(t, ref, before)
}

func TestDeletePurgeWiring_Noop(t *testing.T) {
	base := newHTTPStore(t)
	useTempBindings(t)
	useTempInbox(t)
	// No bindings.conf at all: a noop delete must not create one.
	if got := deleteForSession(base, "purgewireghost", "x", "", "", nil); got != "noop" {
		t.Fatalf("deleteForSession = %q, want \"noop\"", got)
	}
	if _, err := os.Stat(bindingsPath); !os.IsNotExist(err) {
		t.Fatal("a noop delete created a bindings.conf")
	}
	// Another profile bound: the file is left byte for byte.
	if err := setBindingOwner(1, purgeIccid1, "line one", "open", purgeOther, "pubOther"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := deleteForSession(base, "purgewireghost", "x", "", "", nil); got != "noop" {
		t.Fatalf("deleteForSession = %q, want \"noop\"", got)
	}
	after, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Errorf("a noop delete rewrote bindings.conf:\nbefore %q\nafter  %q", before, after)
	}
}

func TestDeletePurgeWiring_Unverified(t *testing.T) {
	fastRetries(t)
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := t.TempDir() + "/wallet.json"
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	const name, pass = "purgewireunver", "horse battery staple correct"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	capStorePostCap = func(req capBoundReq, objURL string) (int, capBoundResp) {
		return http.StatusForbidden, capBoundResp{} // held by another profile: every tombstone is refused
	}
	ref := purgeFixture(t, name, pass)
	before, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	var got string
	captureStderr(t, func() { got = deleteForSession("s3", name, pass, name, pass, nil) })
	if got != "unverified" {
		t.Fatalf("deleteForSession = %q, want \"unverified\"", got)
	}
	wantUntouched(t, ref, before)
}

func TestDeletePurgeWiring_DeletedDamagedMarker(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "purgewiredmg", "correct horse battery"
	createVault(base, name, pass)
	ref := purgeFixture(t, name, pass)
	// The marker lost its login creds: only the TYPED credentials can name the profile to purge.
	if got := deleteForSession(base, name, pass, "", "", nil); got != "deleted" {
		t.Fatalf("deleteForSession = %q, want \"deleted\"", got)
	}
	wantPurged(t, ref)
}
