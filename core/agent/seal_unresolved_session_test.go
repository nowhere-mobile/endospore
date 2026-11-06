package main

import (
	"encoding/hex"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261019-05 -- a session that never resolved a profile creates no head for it. The seal gates all go
// through localOnlySession; this is the seal itself (pushProfile's two head-absent arms), so a throwaway whose
// .localsession was lost cannot mint a profile from the typed credential, and a session of a profile tied to
// another phone's chip cannot write this phone's data into scopes that profile has no head for.

const noResolvedLine = "NOT creating a profile from it"

func unresolvedSrc(t *testing.T) string {
	t.Helper()
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	return src
}

func hardDeleteRef(t *testing.T, base, ref string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodDelete, base+"/ref/"+ref, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if refExists(base, ref) {
		t.Fatal("setup: the hard-deleted ref still exists")
	}
}

// (a) A throwaway: never created, no receipt. Neither the bare head nor a scope head appears.
func TestThrowawaySealCreatesNoProfile(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	name, pass := "ghost", "typo horse battery staple"
	sealRefused = false
	out := captureStdout(t, func() {
		pushProfile(base, name, pass, unresolvedSrc(t))
		pushProfile(base, name+"#de", pass, unresolvedSrc(t))
	})
	if refExists(base, headKey(base, name, pass)) {
		t.Fatal("a throwaway's seal created a bare profile head")
	}
	if refExists(base, headKey(base, name+"#de", pass)) {
		t.Fatal("a throwaway's seal created a #de head")
	}
	if strings.Count(out, noResolvedLine) != 2 || strings.Contains(out, "re-sealing to recover") {
		t.Fatalf("want the 'not creating' line for both seals and no recovery line, got:\n%s", out)
	}
	if sealRefused {
		t.Fatal("the skip must not set sealRefused: a throwaway's sign-out must match a fresh profile's (blind login)")
	}
}

// (b) A lost head WITH the bare receipt is recovered.
func TestLostHeadWithBareReceiptRecovers(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	name, pass := "recov", "lost horse battery staple"
	createVault(base, name, pass)
	ref := headKey(base, name, pass)
	writeRestoreReceipt(profileRefV2(name, pass), getRef(base, ref))
	hardDeleteRef(t, base, ref)
	pushProfile(base, name, pass, unresolvedSrc(t))
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("a lost head with the session's bare receipt was not recovered (#19)")
	}
}

// (c) A live profile holding the bare receipt lazily creates its first #de head.
func TestLiveProfileWithBareReceiptCreatesScope(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	name, pass := "lively", "live horse battery staple"
	createVault(base, name, pass)
	writeRestoreReceipt(profileRefV2(name, pass), getRef(base, headKey(base, name, pass)))
	pushProfile(base, name+"#de", pass, unresolvedSrc(t))
	if getRef(base, headKey(base, name+"#de", pass)) == "" {
		t.Fatal("a live profile's first #de seal created nothing")
	}
}

// (c2) The receipt alone suffices: the bare head is gone, the scope is still created.
func TestScopeCreatedOnReceiptAloneWithBareHeadGone(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	name, pass := "bareless", "gone horse battery staple"
	createVault(base, name, pass)
	ref := headKey(base, name, pass)
	writeRestoreReceipt(profileRefV2(name, pass), getRef(base, ref))
	hardDeleteRef(t, base, ref)
	pushProfile(base, name+"#de", pass, unresolvedSrc(t))
	if getRef(base, headKey(base, name+"#de", pass)) == "" {
		t.Fatal("the bare receipt alone did not permit the scope head")
	}
}

// tiedNoReceipt builds a profile tied to seA's chip on store "s3" and drops every receipt the fixture's seals
// minted, so the session under test holds none.
func tiedNoReceipt(t *testing.T) (name, pass string) {
	t.Helper()
	_, name, pass, _ = tieFixture(t, hex.EncodeToString(seA))
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(restoreReceiptDir()); err != nil {
		t.Fatal(err)
	}
	return name, pass
}

// (d) Tied elsewhere: the bare head is present but does not open here, so no scope head is written.
func TestTiedElsewhereWritesNoScopeHead(t *testing.T) {
	name, pass := tiedNoReceipt(t)
	t.Setenv("NOWHERE_SE_SECRET", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	sealRefused = false
	out := captureStdout(t, func() { pushProfile("s3", name+"#apps", pass, unresolvedSrc(t)) })
	if refExists("s3", headKey("s3", name+"#apps", pass)) {
		t.Fatal("a session of a profile tied to another phone wrote an #apps head")
	}
	if !strings.Contains(out, noResolvedLine) {
		t.Fatalf("want the 'not creating' line, got:\n%s", out)
	}
	if sealRefused {
		t.Fatal("the skip must not set sealRefused")
	}
}

// (d2) The same profile on the phone it is tied to (the chip opens it): the scope is created, as today.
func TestTiedProfileThatOpensHereCreatesScopeWithoutReceipt(t *testing.T) {
	name, pass := tiedNoReceipt(t)
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	pushProfile("s3", name+"#apps", pass, unresolvedSrc(t))
	if getRef("s3", headKey("s3", name+"#apps", pass)) == "" {
		t.Fatal("a profile whose bare head opens here lost its lazy scope creation")
	}
}

// (e) With NOWHERE_STATE unset receipts are not in use and the helper is a no-op gate.
func TestNoStateDirKeepsTodaysBehaviour(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "")
	if !sessionHoldsBareReceipt("anyone#de", "any pass") {
		t.Fatal("with receipts off the helper must not gate the seal")
	}
}

// rotatedSession builds the shape of a session whose passphrase was changed in-session: the vault created
// under p1, the session's bare receipt planted under p1 the way a sign-in restore leaves it, the rotation
// run (which MOVES the receipt), and the bare head under p2 then lost from the store.
func rotatedSession(t *testing.T) (base, name, p2 string) {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base = newHTTPStore(t)
	const p1 = "before horse battery staple"
	name, p2 = "rotgate", "after horse battery staple"
	createVault(base, name, p1)
	writeRestoreReceipt(profileRefV2(name, p1), getRef(base, headKey(base, name, p1)))
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	hardDeleteRef(t, base, headKey(base, name, p2))
	return base, name, p2
}

// (f) A passphrase change composes with the gate: the receipt the rotation moved is the one the seal checks,
// so a lost bare head is recovered under the NEW passphrase rather than refused as if from a throwaway.
func TestRotatedSessionRecoversLostHead(t *testing.T) {
	base, name, p2 := rotatedSession(t)
	out := captureStdout(t, func() { pushProfile(base, name, p2, unresolvedSrc(t)) })
	if getRef(base, headKey(base, name, p2)) == "" {
		t.Fatalf("a rotated session's lost head was not recovered under the new passphrase (#19):\n%s", out)
	}
	if strings.Contains(out, noResolvedLine) {
		t.Fatalf("the rotated session was refused as a throwaway:\n%s", out)
	}
}

// (f2) The control: the same session with the new-passphrase receipt removed is a throwaway to the gate.
func TestRotatedSessionWithoutReceiptCreatesNoHead(t *testing.T) {
	base, name, p2 := rotatedSession(t)
	if f := receiptFile(profileRefV2(name, p2)); f == "" {
		t.Fatal("setup: no receipt path")
	} else if err := os.Remove(f); err != nil {
		t.Fatalf("setup: the rotation left no receipt under the new passphrase: %v", err)
	}
	out := captureStdout(t, func() { pushProfile(base, name, p2, unresolvedSrc(t)) })
	if refExists(base, headKey(base, name, p2)) {
		t.Fatal("a session holding no receipt created a head")
	}
	if !strings.Contains(out, noResolvedLine) {
		t.Fatalf("want the 'not creating' line, got:\n%s", out)
	}
}
