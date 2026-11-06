package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261013-21: a passphrase change must carry the profile's SIM bindings and sealed inbox to the new ref.
// profileRefV2(name, pass) keys both, a rotation or a recovery changes it, and the telephony keypair is kept -- so
// without the carry TEL-OWNER answers NO (outbound blocked), arrivals are sealed under a ref the next sign-in never
// reads, and a later delete leaves the old ref in bindings.conf.

const rbName = "rotbind"

func rbBind(t *testing.T, ref, pub string) {
	t.Helper()
	if err := setBindingOwner(1, "8901000000000001", "line", "open", ref, pub); err != nil {
		t.Fatal(err)
	}
}

func rbTelOwner(t *testing.T, pass string) string {
	t.Helper()
	return driveLogin(t, t.TempDir(), "TEL-OWNER\n"+rbName+"\n"+pass+"\n")
}

func rbSeal(t *testing.T, ref string) {
	t.Helper()
	if err := bufferSealed(ref, "", "c2VhbGVk"); err != nil {
		t.Fatal(err)
	}
}

func rbInboxCount(ref string) int {
	ents, _ := os.ReadDir(telInboxDir(ref))
	return len(ents)
}

func rbAllRefs() map[string]bool {
	m := map[string]bool{}
	for _, b := range readBindings() {
		for _, o := range b.Owners {
			m[o.ProfileRef] = true
		}
	}
	return m
}

func TestRotationCarriesBindingsAndInbox(t *testing.T) {
	useTempBindings(t)
	useTempInbox(t)
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const oldp, newp = "horse battery staple correct", "a completely different passphrase"
	createVault("s3", rbName, oldp)
	v, _ := openVaultHead("s3", rbName, oldp)
	if v == nil || v.TelPub == "" {
		t.Fatal("precondition: the vault has no telephony key")
	}
	oldRef, newRef := profileRefV2(rbName, oldp), profileRefV2(rbName, newp)
	rbBind(t, oldRef, v.TelPub)
	rbSeal(t, oldRef)
	if err := bufferPending(oldRef, "", "10", "sms 1", "cGVuZGluZw=="); err != nil {
		t.Fatal(err)
	}
	if got := rbTelOwner(t, oldp); got != "YES" {
		t.Fatalf("precondition: TEL-OWNER %q", got)
	}

	liveMarker(t, dest, rbName, oldp, "10", "")
	if got := rotateVerb(t, dest, rbName, oldp, newp); got != "OK 0" {
		t.Fatalf("rotation replied %q", got)
	}
	if got := rbTelOwner(t, newp); got != "YES" {
		t.Errorf("TEL-OWNER for the new passphrase is %q: the SIM was taken away by the rotation", got)
	}
	refs := rbAllRefs()
	if !refs[newRef] || refs[oldRef] {
		t.Errorf("owners after rotation: %v, want only the new ref", refs)
	}
	if rbInboxCount(newRef) != 2 || rbInboxCount(oldRef) != 0 {
		t.Errorf("sealed inbox: new %d old %d, want 2 (sealed + pending) and 0", rbInboxCount(newRef), rbInboxCount(oldRef))
	}
	if got := len(listPending(newRef)); got != 1 {
		t.Errorf("pending copies at new ref: %d, want 1", got)
	}
	// A delete afterwards leaves neither ref.
	if _, err := removeBindingOwnerEverywhere(newRef); err != nil {
		t.Fatal(err)
	}
	if refs := rbAllRefs(); len(refs) != 0 {
		t.Errorf("owners after a delete: %v, want none", refs)
	}
}

func TestRotationKeepsTheCoOwner(t *testing.T) {
	useTempBindings(t)
	rbBind(t, "aaaa1111", "pubA")
	rbBind(t, "bbbb2222", "pubB")
	n, err := renameBindingOwnerEverywhere("aaaa1111", "cccc3333")
	if err != nil || n != 1 {
		t.Fatalf("rename: %d %v", n, err)
	}
	b, _ := bindingForSubID(1, "8901000000000001")
	o := ownerRefs(b)
	if len(o) != 2 || o["cccc3333"] != "pubA" || o["bbbb2222"] != "pubB" {
		t.Errorf("owners %v, want cccc3333:pubA and bbbb2222:pubB", o)
	}
}

func TestRenameMergesIntoAnExistingOwner(t *testing.T) {
	useTempBindings(t)
	rbBind(t, "aaaa1111", "pubA")
	rbBind(t, "cccc3333", "pubA")
	if _, err := renameBindingOwnerEverywhere("aaaa1111", "cccc3333"); err != nil {
		t.Fatal(err)
	}
	b, _ := bindingForSubID(1, "8901000000000001")
	if len(b.Owners) != 1 || b.Owners[0].ProfileRef != "cccc3333" {
		t.Errorf("owners %v, want one cccc3333 (a duplicate seals every arrival twice)", b.Owners)
	}
}

func TestRotationKeepsAnInFlightArrivalBound(t *testing.T) {
	telFixture(t)
	clk := useArrivalState(t)
	bindFor(t, iccidX, "oldRef")
	*clk += 1000
	stamp := *clk // the platform received it before the credential change
	*clk += 1000
	if _, err := renameBindingOwnerEverywhere("oldRef", "newRef"); err != nil {
		t.Fatal(err)
	}
	*clk += 1000
	got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(77), "sms", 2, iccidX, "+1", stamp, "in flight"))
	if !strings.HasPrefix(got, "OK ") {
		t.Fatalf("arrival stamped before the rotation replied %q, want OK", got)
	}
	if len(listSealed("oldRef")) != 0 || len(listSealed("newRef")) != 1 {
		t.Fatalf("in-flight arrival sealed old=%d new=%d, want 0 and 1", len(listSealed("oldRef")), len(listSealed("newRef")))
	}
}

func TestRenameWritesNothingWhenNothingMatched(t *testing.T) {
	useTempBindings(t)
	if n, err := renameBindingOwnerEverywhere("aaaa1111", "cccc3333"); err != nil || n != 0 {
		t.Fatalf("rename with no file: %d %v", n, err)
	}
	if _, err := os.Stat(bindingsPath); !os.IsNotExist(err) {
		t.Errorf("a no-op rename minted a bindings.conf (%v)", err)
	}
	carryTelephonyRef("aaaa1111", "cccc3333")
	if _, err := os.Stat(bindingsPath); !os.IsNotExist(err) {
		t.Errorf("a no-op carry minted a bindings.conf (%v)", err)
	}
}

func TestFailedRotationChangesNothing(t *testing.T) {
	useTempBindings(t)
	useTempInbox(t)
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const oldp, newp = "horse battery staple correct", "a completely different passphrase"
	createVault("s3", rbName, oldp)
	v, _ := openVaultHead("s3", rbName, oldp)
	oldRef := profileRefV2(rbName, oldp)
	rbBind(t, oldRef, v.TelPub)
	rbSeal(t, oldRef)
	liveMarker(t, dest, rbName, "not the session passphrase", "10", "")
	if got := rotateVerb(t, dest, rbName, "not the session passphrase", newp); strings.HasPrefix(got, "OK") {
		t.Fatalf("rotation replied %q, want a refusal", got)
	}
	if refs := rbAllRefs(); len(refs) != 1 || !refs[oldRef] {
		t.Errorf("owners after a failed rotation: %v", refs)
	}
	if rbInboxCount(oldRef) != 1 {
		t.Errorf("a failed rotation moved the inbox")
	}
}

func TestRecoveryCarriesByTelPub(t *testing.T) {
	useTempBindings(t)
	useTempInbox(t)
	base := newHTTPStore(t)
	const oldp, newp = "footprint horse battery staple", "a brand new passphrase"
	mnemonic := createVault(base, rbName, oldp)
	v, _ := openVaultHead(base, rbName, oldp)
	if v == nil || v.TelPub == "" {
		t.Fatal("precondition: the vault has no telephony key")
	}
	oldRef, newRef := profileRefV2(rbName, oldp), profileRefV2(rbName, newp)
	rbBind(t, oldRef, v.TelPub)
	rbSeal(t, oldRef)
	if err := recoverVault(base, rbName, mnemonic, newp); err != nil {
		t.Fatal(err)
	}
	if refs := rbAllRefs(); len(refs) != 1 || !refs[newRef] {
		t.Errorf("owners after recovery: %v, want only the new ref", refs)
	}
	if rbInboxCount(newRef) != 1 || rbInboxCount(oldRef) != 0 {
		t.Errorf("sealed inbox: new %d old %d, want 1 and 0", rbInboxCount(newRef), rbInboxCount(oldRef))
	}
}

func TestRecoveryWithNoMatchingOwnerChangesNothing(t *testing.T) {
	useTempBindings(t)
	useTempInbox(t)
	base := newHTTPStore(t)
	const oldp, newp = "footprint horse battery staple", "a brand new passphrase"
	mnemonic := createVault(base, rbName, oldp)
	rbBind(t, "aaaa1111", "someone else's key")
	rbSeal(t, "aaaa1111")
	before, _ := os.ReadFile(bindingsPath)
	if err := recoverVault(base, rbName, mnemonic, newp); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(bindingsPath)
	if string(before) != string(after) {
		t.Errorf("bindings.conf changed with no matching owner:\n%s\n%s", before, after)
	}
	if rbInboxCount("aaaa1111") != 1 {
		t.Error("the inbox of an unrelated owner moved")
	}
}

func TestRecoveryWithSeveralMatchingOwnersChangesNothing(t *testing.T) {
	useTempBindings(t)
	useTempInbox(t)
	base := newHTTPStore(t)
	const oldp, newp = "footprint horse battery staple", "a brand new passphrase"
	mnemonic := createVault(base, rbName, oldp)
	v, _ := openVaultHead(base, rbName, oldp)
	rbBind(t, "aaaa1111", v.TelPub)
	if err := setBindingOwner(2, "8901000000000002", "line two", "open", "bbbb2222", v.TelPub); err != nil {
		t.Fatal(err)
	}
	rbSeal(t, "aaaa1111")
	before, _ := os.ReadFile(bindingsPath)
	if err := recoverVault(base, rbName, mnemonic, newp); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(bindingsPath)
	if string(before) != string(after) {
		t.Errorf("bindings.conf changed with several matching owners:\n%s\n%s", before, after)
	}
	if rbInboxCount("aaaa1111") != 1 {
		t.Error("an ambiguous owner's inbox moved")
	}
}

func TestMoveTelInboxMergesIntoAnExistingDir(t *testing.T) {
	useTempInbox(t)
	rbSeal(t, "aaaa1111")
	rbSeal(t, "cccc3333")
	if n, err := moveTelInbox("aaaa1111", "cccc3333"); err != nil || n != 1 {
		t.Fatalf("move: %d %v", n, err)
	}
	if rbInboxCount("cccc3333") != 2 {
		t.Errorf("merged inbox holds %d, want 2", rbInboxCount("cccc3333"))
	}
	if _, err := os.Stat(filepath.Join(telInboxBase, "aaaa1111")); !os.IsNotExist(err) {
		t.Error("the old inbox dir survived the move")
	}
}

func TestMoveTelInboxMergeDoesNotOverwriteANameCollision(t *testing.T) {
	useTempInbox(t)
	oldDir, newDir := telInboxDir("aaaa1111"), telInboxDir("cccc3333")
	if err := os.MkdirAll(oldDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(newDir, 0o700); err != nil {
		t.Fatal(err)
	}
	const name = "0123456789abcdef.10.0123456789abcdef.pend"
	if err := os.WriteFile(filepath.Join(oldDir, name), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(newDir, name), []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if n, err := moveTelInbox("aaaa1111", "cccc3333"); err != nil || n != 1 {
		t.Fatalf("move: %d %v", n, err)
	}
	paths := listPending("cccc3333")
	if len(paths) != 2 {
		t.Fatalf("pending copies after collision: %v, want both", paths)
	}
	got := map[string]bool{}
	for _, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		got[string(b)] = true
	}
	if !got["old"] || !got["new"] {
		t.Errorf("pending contents after collision: %v, want old and new", got)
	}
}

// A co-owner unbound after the platform stamped an arrival, then the remaining owner rotates: the resolver's history
// holds the pre-rotation ref, so without renameLinkHistoryOwner the arrival's surviving owner no longer matches
// anything current and it is classified REMOVED and discarded.
func TestRotationAfterACoOwnerUnbindKeepsAnInFlightArrivalBound(t *testing.T) {
	telFixture(t)
	clk := useArrivalState(t)
	bindFor(t, iccidX, "oldRef")
	v, _ := vaultWithTelKey(t)
	if err := setBindingOwner(2, iccidX, "L", "open", "coRef", v.TelPub); err != nil {
		t.Fatal(err)
	}
	*clk += 1000
	stamp := *clk
	*clk += 1000
	if _, err := removeBindingOwnerEverywhere("coRef"); err != nil {
		t.Fatal(err)
	}
	*clk += 1000
	if _, err := renameBindingOwnerEverywhere("oldRef", "newRef"); err != nil {
		t.Fatal(err)
	}
	*clk += 1000
	got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(78), "sms", 2, iccidX, "+1", stamp, "in flight"))
	if !strings.HasPrefix(got, "OK ") {
		t.Fatalf("arrival replied %q, want OK (the surviving owner only changed credential)", got)
	}
	if len(listSealed("newRef")) != 1 {
		t.Fatalf("sealed at the new ref: %d, want 1", len(listSealed("newRef")))
	}
}

// A rotation whose retire pass began is COMMITTED (ERR-SESSION): the next sign-in resolves the NEW ref, so the carry
// must happen on that path as well.
func TestCommittedButErroredRotationStillCarries(t *testing.T) {
	rb := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = rb })
	useTempBindings(t)
	useTempInbox(t)
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const oldp, newp = "horse battery staple correct", "a completely different passphrase"
	createVault("s3", rbName, oldp)
	v, _ := openVaultHead("s3", rbName, oldp)
	oldRef, newRef := profileRefV2(rbName, oldp), profileRefV2(rbName, newp)
	rbBind(t, oldRef, v.TelPub)
	rbSeal(t, oldRef)
	liveMarker(t, dest, rbName, oldp, "10", "")
	victim := ""
	capStorePutHook = func(key string, body []byte) error {
		if victim == "" && strings.HasPrefix(key, "ref/") && len(body) == 0 {
			victim = key
		}
		if key == victim {
			return errTestStoreRefused
		}
		return nil
	}
	got := rotateVerb(t, dest, rbName, oldp, newp)
	capStorePutHook = nil
	if victim == "" || got != "ERR-SESSION" {
		t.Fatalf("precondition: victim %q reply %q, want a committed-but-errored rotation", victim, got)
	}
	if refs := rbAllRefs(); len(refs) != 1 || !refs[newRef] {
		t.Errorf("owners after a committed rotation: %v, want only the new ref", refs)
	}
	if rbInboxCount(newRef) != 1 || rbInboxCount(oldRef) != 0 {
		t.Errorf("sealed inbox: new %d old %d, want 1 and 0", rbInboxCount(newRef), rbInboxCount(oldRef))
	}
}

// The daemon verb itself: the helpers above are only half the claim, because a handleRotate that never calls the
// carry leaves every one of them green. This drives ROTATE the way the chooser does and reads the result back
// through TEL-OWNER.
func TestRotateVerbCarriesBindingsAndInbox(t *testing.T) {
	useTempBindings(t)
	useTempInbox(t)
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	const oldp, newp = "horse battery staple correct", "a completely different passphrase"
	if createVault("s3", rbName, oldp) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	v, _ := openVaultHead("s3", rbName, oldp)
	if v == nil || v.TelPub == "" {
		t.Fatal("precondition: the vault has no telephony key")
	}
	oldRef, newRef := profileRefV2(rbName, oldp), profileRefV2(rbName, newp)
	rbBind(t, oldRef, v.TelPub)
	rbSeal(t, oldRef)
	liveMarker(t, dest, rbName, oldp, "10", "")
	if got := rotateVerb(t, dest, rbName, oldp, newp); got != "OK 0" {
		t.Fatalf("ROTATE replied %q, want OK 0", got)
	}
	if refs := rbAllRefs(); len(refs) != 1 || !refs[newRef] {
		t.Errorf("owners after ROTATE: %v, want only the new ref", refs)
	}
	if rbInboxCount(newRef) != 1 || rbInboxCount(oldRef) != 0 {
		t.Errorf("sealed inbox: new %d old %d, want 1 and 0", rbInboxCount(newRef), rbInboxCount(oldRef))
	}
}
