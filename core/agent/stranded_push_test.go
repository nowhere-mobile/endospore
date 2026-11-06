package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// NWP-20261111-01 (Q016, 2026-10-20): a push no slot opens, on a session whose restore receipt names a readable
// vault, is a REFUSAL named for its cause (locks-changed[-key] / unlock-lost[-key]) and classed FINAL -- not the
// ERR-PUSH failure that told the user to check the connection.

func resetStrandedSeal(t *testing.T) {
	t.Helper()
	sealRefused, sealRefusedWhy = false, ""
	t.Cleanup(func() { sealRefused, sealRefusedWhy = false, "" })
}

func TestStrandedPush_C1_StrandedReasonTable(t *testing.T) {
	sl := func(kind, wrapped string) keyslot { return keyslot{Kind: kind, Wrapped: wrapped} }
	key := keyslot{Kind: "fido2", Wrapped: "wk", CredID: "cred", Salt: "salt", UV: true}
	vlt := func(s ...keyslot) *vault { return &vault{Slots: s} }
	for _, c := range []struct {
		name          string
		stored, known *vault
		want          string
	}{
		{"a key enrolled: the pass slot gone, a key slot added", vlt(key, sl("recovery", "r")), vlt(sl("pass", "p"), sl("recovery", "r")), "locks-changed-key"},
		{"hardened: the pass slot gone, an se slot added", vlt(sl("se", "s"), sl("recovery", "r")), vlt(sl("pass", "p"), sl("recovery", "r")), "locks-changed"},
		{"the same se-only locks", vlt(sl("se", "s"), sl("recovery", "r")), vlt(sl("se", "s"), sl("recovery", "r")), "unlock-lost"},
		{"the same locks with a key slot", vlt(key, sl("recovery", "r")), vlt(key, sl("recovery", "r")), "unlock-lost-key"},
		{"the same kinds, one wrapped key differs (a rotation)", vlt(sl("se", "s2"), sl("recovery", "r")), vlt(sl("se", "s"), sl("recovery", "r")), "locks-changed"},
		{"the same locks in another order", vlt(sl("recovery", "r"), sl("se", "s")), vlt(sl("se", "s"), sl("recovery", "r")), "unlock-lost"},
		{"a relabelled key is the same lock", vlt(keyslot{Kind: "fido2", Wrapped: "wk", CredID: "cred", Salt: "salt", UV: true, Label: "blue"}), vlt(key), "unlock-lost-key"},
		{"nothing known: cannot tell", vlt(key), nil, ""},
	} {
		if got := strandedReason(c.stored, c.known); got != c.want {
			t.Errorf("%s: strandedReason = %q, want %q", c.name, got, c.want)
		}
	}
}

// strandedSetup makes a profile with a sealed baseline and a receipt naming its head, and returns (src, rcptRef, H0).
func strandedSetup(t *testing.T, base, name, pass string) (string, string, string) {
	t.Helper()
	createVault(base, name, pass)
	src := t.TempDir()
	data := bytes.Repeat([]byte("stranded seal payload 0123456789\n"), 20000)
	if err := os.WriteFile(filepath.Join(src, "f.txt"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatalf("baseline push refused (%s)", sealRefusedWhy)
	}
	h0 := getRef(base, headKey(base, name, pass))
	rcptRef := profileRefV2(name, pass)
	writeRestoreReceipt(rcptRef, h0)
	return src, rcptRef, h0
}

// pushNoPanic runs pushProfile and fails the test on a panic (the old fail()).
func pushNoPanic(t *testing.T, base, name, pass, src string) {
	t.Helper()
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("pushProfile failed instead of refusing: %v", r)
			}
		}()
		pushProfile(base, name, pass, src)
	}()
}

func strandedEnrollKey(t *testing.T, base, name, pass string) {
	t.Helper()
	hm := make([]byte, fido2HMACLen)
	rand.Read(hm)
	salt := make([]byte, 32)
	rand.Read(salt)
	credID := base64.StdEncoding.EncodeToString([]byte("stranded-cred-" + name))
	if err := enrollFido2(base, name, pass, credID, base64.StdEncoding.EncodeToString(salt), hex.EncodeToString(hm), true, "", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}
}

func TestStrandedPush_P1_AKeyEnrolledElsewhereIsLocksChangedKey(t *testing.T) {
	resetStrandedSeal(t)
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	const name, pass = "strandedp1", "correct horse battery staple"
	src, rcptRef, h0 := strandedSetup(t, base, name, pass)

	strandedEnrollKey(t, base, name, pass) // 2FA: the pass slot is dropped
	if restoreReceiptHead(rcptRef) == h0 {
		t.Fatal("enrollFido2's putHead did not re-anchor this process's receipt -- the setup below assumes it does")
	}
	// The other phone's receipt never sees that head: put it back where this session last knew it.
	writeRestoreReceipt(rcptRef, h0)
	if _, ok := parseVault(headBlobGet(base, h0)); !ok {
		t.Fatal("the head this session knew is no longer readable as a vault")
	}
	h1 := getRef(base, headKey(base, name, pass))

	pushNoPanic(t, base, name, pass, src)
	if !sealRefused || sealRefusedWhy != "locks-changed-key" {
		t.Fatalf("sealRefused=%v why=%q, want a refusal named locks-changed-key", sealRefused, sealRefusedWhy)
	}
	if got := getRef(base, headKey(base, name, pass)); got != h1 {
		t.Fatalf("the stored head moved (%s -> %s): a refused push must store nothing", h1, got)
	}
}

func TestStrandedPush_P2_UnchangedLocksAreUnlockLost(t *testing.T) {
	resetStrandedSeal(t)
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	const name, pass = "strandedp2", "correct horse battery staple"
	src, rcptRef, _ := strandedSetup(t, base, name, pass)

	se := make([]byte, 32)
	rand.Read(se)
	if err := enrollSE(base, name, pass, se); err != nil { // hardened: se-only, the pass slot dropped
		t.Fatalf("enrollSE: %v", err)
	}
	h1 := getRef(base, headKey(base, name, pass))
	writeRestoreReceipt(rcptRef, h1) // this session knew the stored head; it lost the se secret

	pushNoPanic(t, base, name, pass, src)
	if !sealRefused || sealRefusedWhy != "unlock-lost" {
		t.Fatalf("sealRefused=%v why=%q, want a refusal named unlock-lost", sealRefused, sealRefusedWhy)
	}
	if got := getRef(base, headKey(base, name, pass)); got != h1 {
		t.Fatalf("the stored head moved (%s -> %s): a refused push must store nothing", h1, got)
	}
}

func TestStrandedPush_P3_NoReceiptKeepsTheOldFailure(t *testing.T) {
	resetStrandedSeal(t)
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	const name, pass = "strandedp3", "correct horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("no receipt payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	strandedEnrollKey(t, base, name, pass)

	var got any
	func() {
		defer func() { got = recover() }()
		pushProfile(base, name, pass, src)
	}()
	if got == nil || !strings.Contains(fmt.Sprint(got), "no slot opens") {
		t.Fatalf("with no receipt the push must still fail with \"no slot opens\", got %v", got)
	}
	if sealRefused {
		t.Fatalf("with no receipt the push refused as %q -- it cannot tell, so it must not name a cause", sealRefusedWhy)
	}
}

func TestStrandedPush_P4_EachReasonTravelsAndLicensesTheExit(t *testing.T) {
	for _, r := range []string{"locks-changed", "locks-changed-key", "unlock-lost", "unlock-lost-key"} {
		if got := sealRefusalReasons(true, r, false, false); !reflect.DeepEqual(got, []string{r}) {
			t.Errorf("sealRefusalReasons(%q) = %v", r, got)
		}
		if !refusalToken(r) {
			t.Errorf("%q is not a refusal token: the stash would drop it", r)
		}
		if !refusalReasonFinal(r) {
			t.Errorf("%q is classed RETRY: END-UNSAVED would never be licensed for it", r)
		}
		if !logoffRefusalFinal("vault=refused", map[string][]string{"vault": {r}}) {
			t.Errorf("a vault refused as %q does not license the exit", r)
		}
	}
	if !logoffRefusalFinal("vault=refused", map[string][]string{"vault": {"locks-changed"}}) {
		t.Error(`logoffRefusalFinal("vault=refused", {vault: [locks-changed]}) = false`)
	}
}
