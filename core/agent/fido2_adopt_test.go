package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261111-03: fido2-adopt, the stranded phone's "Use your security key" (Q016). The key is never
// touched: fido2KeyAssertFn is stubbed, and the hmac it returns stands in for the authenticator's output.

// adoptStub replaces the assertion for one test.
func adoptStub(t *testing.T, fn func(credID, salt []byte, uv bool) ([]byte, error)) {
	t.Helper()
	orig := fido2KeyAssertFn
	t.Cleanup(func() { fido2KeyAssertFn = orig })
	fido2KeyAssertFn = fn
}

// adoptSetup gives a test its own store, state and stateDir, with no fido2 hmac in the env: an adopt must
// never be helped by one.
func adoptSetup(t *testing.T) (base, stateDir string) {
	t.Helper()
	base = newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	return base, t.TempDir()
}

func adoptRandom(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// adoptHeadSlots returns the fido2 slots of the profile's current stored head.
func adoptHeadSlots(t *testing.T, base, name, pass string) []fido2SlotInfo {
	t.Helper()
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("control failed: the head is not a vault")
	}
	return listFido2Slots(v)
}

// adoptEnrolKeyOnly makes a fido2-only vault (enrollFido2 drops the pass slot) and returns the key's hmac.
func adoptEnrolKeyOnly(t *testing.T, base, name, pass string) []byte {
	t.Helper()
	createVault(base, name, pass)
	h := adoptRandom(t, fido2HMACLen)
	cred := base64.StdEncoding.EncodeToString([]byte("adopt-cred-" + name))
	salt := base64.StdEncoding.EncodeToString(adoptRandom(t, 32))
	if err := enrollFido2(base, name, pass, cred, salt, hex.EncodeToString(h), false, "", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Fatal("control failed: the passphrase alone still opens the fido2-only head")
	}
	return h
}

// adoptAddKeyKeepingPass appends a fido2 slot to a pass vault WITHOUT dropping its pass slot, and returns
// the key's hmac: the head on which the pass rung would answer for any hmac.
func adoptAddKeyKeepingPass(t *testing.T, base, name, pass string) []byte {
	t.Helper()
	createVault(base, name, pass)
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("control failed: the fresh vault does not open")
	}
	v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	h := adoptRandom(t, fido2HMACLen)
	v.Slots = append(v.Slots, keyslot{
		Kind:    "fido2",
		CredID:  base64.StdEncoding.EncodeToString([]byte("adopt-cred-" + name)),
		Salt:    base64.StdEncoding.EncodeToString(adoptRandom(t, 32)),
		Wrapped: wrap(kekFido2(deriveKey(name, pass), h), dk),
	})
	signVault(v, dk)
	putHead(base, name, pass, postBlob(base, serializeVault(v)))
	nv, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if unwrapDK(nv, "pass", deriveKey(name, pass)) == nil || len(listFido2Slots(nv)) != 1 {
		t.Fatal("control failed: the head does not hold both a pass slot and one fido2 slot")
	}
	return h
}

func adoptNoPre(t *testing.T, stateDir string) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(stateDir, ".fido2slots.pre")); err == nil {
		t.Error("a refused adopt staged .fido2slots.pre")
	}
}

// A1: the key's hmac opens a fido2 slot of the head -> it is returned, the slot spec is staged as .pre, and
// neither the live spec nor .fido2hmac is written (roamd does that).
func TestFido2AdoptReturnsTheHmacThatOpensTheHeadAndStagesThePreSpec(t *testing.T) {
	base, st := adoptSetup(t)
	const name, pass = "adopta1", "correct horse battery staple"
	h := adoptEnrolKeyOnly(t, base, name, pass)
	adoptStub(t, func(credID, salt []byte, uv bool) ([]byte, error) { return h, nil })

	got, err := adoptFido2Key(base, name, pass, st)
	if err != nil {
		t.Fatalf("adoptFido2Key with the enrolled key: %v", err)
	}
	if !bytes.Equal(got, h) {
		t.Fatalf("adoptFido2Key returned %x, want the enrolled hmac", got)
	}
	pre, err := os.ReadFile(filepath.Join(st, ".fido2slots.pre"))
	if err != nil {
		t.Fatalf(".fido2slots.pre not staged: %v", err)
	}
	if want := encodeSlotSpec(adoptHeadSlots(t, base, name, pass)); string(pre) != want {
		t.Errorf(".fido2slots.pre = %q, want %q", pre, want)
	}
	for _, f := range []string{".fido2hmac", ".fido2slots"} {
		if _, err := os.Stat(filepath.Join(st, f)); err == nil {
			t.Errorf("adopt wrote %s; only roamd writes it", f)
		}
	}
}

// A2: a key whose hmac opens no slot (revoked, or re-wrapped elsewhere) -> refused, nothing staged.
func TestFido2AdoptRefusesAnHmacThatOpensNothing(t *testing.T) {
	base, st := adoptSetup(t)
	const name, pass = "adopta2", "correct horse battery staple"
	adoptEnrolKeyOnly(t, base, name, pass)
	wrong := adoptRandom(t, fido2HMACLen)
	adoptStub(t, func(credID, salt []byte, uv bool) ([]byte, error) { return wrong, nil })

	got, err := adoptFido2Key(base, name, pass, st)
	if err == nil {
		t.Fatalf("adoptFido2Key accepted an hmac that opens no slot (returned %x)", got)
	}
	if !strings.Contains(err.Error(), "the key did not unlock this profile") {
		t.Errorf("err = %q, want the key did not unlock this profile", err)
	}
	if got != nil {
		t.Error("a refused adopt returned an hmac")
	}
	adoptNoPre(t, st)
}

// A3: a pass vault with no key -> refused before the key is ever asserted.
func TestFido2AdoptWithNoKeySlotNeverTouchesTheKey(t *testing.T) {
	base, st := adoptSetup(t)
	const name, pass = "adopta3", "correct horse battery staple"
	createVault(base, name, pass)
	adoptStub(t, func(credID, salt []byte, uv bool) ([]byte, error) {
		t.Error("the key was asserted for a profile with no fido2 slot")
		return nil, nil
	})

	_, err := adoptFido2Key(base, name, pass, st)
	if err == nil || !strings.Contains(err.Error(), "no security key") {
		t.Fatalf("err = %v, want no security key", err)
	}
	adoptNoPre(t, st)
}

// A4: the passphrase still opens the head (a pass slot beside the fido2 one) and the key's hmac is wrong ->
// refused: the pass rung must never read as "the key adopted". The right hmac on the same head is the control.
func TestFido2AdoptDoesNotCountThePassRung(t *testing.T) {
	base, st := adoptSetup(t)
	const name, pass = "adopta4", "correct horse battery staple"
	h := adoptAddKeyKeepingPass(t, base, name, pass)
	wrong := adoptRandom(t, fido2HMACLen)
	adoptStub(t, func(credID, salt []byte, uv bool) ([]byte, error) { return wrong, nil })

	if got, err := adoptFido2Key(base, name, pass, st); err == nil {
		t.Fatalf("adoptFido2Key accepted a wrong hmac because the passphrase opens the head (returned %x)", got)
	}
	adoptNoPre(t, st)

	adoptStub(t, func(credID, salt []byte, uv bool) ([]byte, error) { return h, nil })
	got, err := adoptFido2Key(base, name, pass, st)
	if err != nil || !bytes.Equal(got, h) {
		t.Fatalf("control: the right hmac on the pass+fido2 head: got %x, err %v", got, err)
	}
}

// A5: a legacy bare head has no slots at all -> refused as not a vault, the key never asserted.
func TestFido2AdoptRefusesALegacyBareHead(t *testing.T) {
	base, st := adoptSetup(t)
	const name, pass = "adopta5", "correct horse battery staple"
	seedLegacyProfile(t, base, name, pass)
	adoptStub(t, func(credID, salt []byte, uv bool) ([]byte, error) {
		t.Error("the key was asserted for a legacy bare head")
		return nil, nil
	})

	_, err := adoptFido2Key(base, name, pass, st)
	if err == nil || !strings.Contains(err.Error(), "not a vault") {
		t.Fatalf("err = %v, want not a vault", err)
	}
	adoptNoPre(t, st)
}

// A6: the CLI arm calls adoptFido2Key and prints exactly one line, the hex hmac; every failure goes through
// fail(), so nothing else (the passphrase, the name) reaches stdout or stderr from the arm itself.
func TestFido2AdoptArmPrintsOnlyTheHmac(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(src)
	start := strings.Index(text, `case "fido2-adopt":`)
	if start < 0 {
		t.Fatal(`main.go has no case "fido2-adopt":`)
	}
	arm := text[start:]
	if end := strings.Index(arm[1:], "\n\tcase \""); end >= 0 {
		arm = arm[:end+1]
	} else {
		t.Fatal("the fido2-adopt arm has no following case")
	}
	if !strings.Contains(arm, "adoptFido2Key(os.Args[2], os.Args[3], os.Args[4], os.Args[5])") {
		t.Error("the fido2-adopt arm does not call adoptFido2Key with <store> <name> <pass> <statedir>")
	}
	if n := strings.Count(arm, "fmt.Print"); n != 1 || !strings.Contains(arm, "fmt.Println(hex.EncodeToString(h))") {
		t.Errorf("the fido2-adopt arm has %d fmt.Print calls, want exactly fmt.Println(hex.EncodeToString(h))", n)
	}
	if strings.Contains(arm, "os.Stderr") || strings.Contains(arm, "log.") {
		t.Error("the fido2-adopt arm writes to stderr or the log directly; failures go through fail()")
	}
}
