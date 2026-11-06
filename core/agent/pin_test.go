package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"os"
	"testing"
)

// #81 item 3 sub-slice 1: the PIN roams SEALED under the vault DK -- set it, read it back, and confirm it
// reveals nothing without DK and survives a passphrase rotation (DK is stable across a rotate).
func TestStoredPINRoundTrip(t *testing.T) {
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	const name, pass = "pinuser", "correct horse battery staple"
	createVault(base, name, pass)

	// No PIN yet.
	if got := storedPIN(base, name, pass, nil); got != "" {
		t.Fatalf("fresh vault should have no PIN, got %q", got)
	}
	// Set one -> reads back, and the wrong passphrase can't read it.
	if err := setStoredPIN(base, name, pass, "246810", nil); err != nil {
		t.Fatalf("setStoredPIN: %v", err)
	}
	if got := storedPIN(base, name, pass, nil); got != "246810" {
		t.Fatalf("storedPIN = %q, want 246810", got)
	}
	if got := storedPIN(base, name, "the wrong passphrase", nil); got != "" {
		t.Fatalf("a wrong passphrase must not reveal the PIN, got %q", got)
	}
	// The stored PIN is CIPHERTEXT in the head -- the literal digits never appear in the store blob.
	head := getRef(base, headKey(base, name, pass))
	if blob := getBlob(base, head); bytes.Contains(blob, []byte("246810")) {
		t.Fatal("the PIN appears in plaintext in the store head -- it must be sealed under DK")
	}

	// Survives a passphrase rotation (DK unchanged -> the sealed PIN still decrypts under the new pass).
	const newpass = "river maple stone cloud lantern"
	if _, err := rotateVault(base, name, pass, newpass, nil, true); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if got := storedPIN(base, name, newpass, nil); got != "246810" {
		t.Fatalf("PIN lost across a passphrase rotation: got %q", got)
	}

	// Clear it.
	if err := setStoredPIN(base, name, newpass, "", nil); err != nil {
		t.Fatalf("clear PIN: %v", err)
	}
	if got := storedPIN(base, name, newpass, nil); got != "" {
		t.Fatalf("PIN not cleared, got %q", got)
	}
}

// The session stash mirrors the fido2 hmac stash: write, read, clear (empty pin removes the file).
func TestSessionPINStash(t *testing.T) {
	dir := t.TempDir()
	if got := sessionPIN(dir); got != "" {
		t.Fatalf("empty dir should have no stash, got %q", got)
	}
	stashSessionPIN(dir, "4321")
	if got := sessionPIN(dir); got != "4321" {
		t.Fatalf("stash round-trip = %q, want 4321", got)
	}
	stashSessionPIN(dir, "") // clear
	if got := sessionPIN(dir); got != "" {
		t.Fatalf("stash not cleared, got %q", got)
	}
}

// coldWrapKey seals the roaming passphrase for cold-lock recovery: a PIN(+key) resume must recover the exact
// passphrase, and a WRONG PIN or WRONG key must not (the seal is keyed by both factors). Mirrors the
// handleColdLock -> handleResume round-trip (#81 item 4).
func TestColdWrapKeyRoundTrip(t *testing.T) {
	const name, pass = "wrapuser", "correct horse battery staple"
	hmac := make([]byte, fido2HMACLen)
	rand.Read(hmac)

	// 32 bytes (AES-256) and deterministic.
	k := coldWrapKey(name, "246810", hmac)
	if len(k) != 32 {
		t.Fatalf("coldWrapKey len = %d, want 32", len(k))
	}
	if !bytes.Equal(coldWrapKey(name, "246810", hmac), k) {
		t.Fatal("coldWrapKey not deterministic")
	}

	// Seal the passphrase under the PIN+key, recover it with the same factors.
	blob := seal(k, []byte(pass))
	if got := string(unseal(k, blob)); got != pass {
		t.Fatalf("recovered passphrase = %q, want %q", got, pass)
	}

	// A wrong PIN derives a different key -> the seal won't open (unseal fail()s on a bad GCM tag).
	tryUnseal := func(key, ct []byte) (ok bool) {
		defer func() {
			if recover() != nil {
				ok = false
			}
		}()
		return string(unseal(key, ct)) == pass
	}
	if tryUnseal(coldWrapKey(name, "000000", hmac), blob) {
		t.Fatal("a wrong PIN recovered the passphrase")
	}
	other := make([]byte, fido2HMACLen)
	rand.Read(other)
	if tryUnseal(coldWrapKey(name, "246810", other), blob) {
		t.Fatal("a wrong key hmac recovered the passphrase")
	}
	// The right factors still open it (sanity: the negative cases above aren't a broken helper).
	if !tryUnseal(coldWrapKey(name, "246810", hmac), blob) {
		t.Fatal("the correct PIN+key failed to recover the passphrase")
	}
}

// The floor: 4-16 digits only.
func TestPinFloor(t *testing.T) {
	ok := []string{"1234", "0000", "246810", "1234567890123456"}
	bad := []string{"", "123", "12345678901234567", "12a4", "abcd", "12 4", "-123"}
	for _, p := range ok {
		if !pinFloor(p) {
			t.Errorf("pinFloor(%q) = false, want true", p)
		}
	}
	for _, p := range bad {
		if pinFloor(p) {
			t.Errorf("pinFloor(%q) = true, want false", p)
		}
	}
	// setStoredPIN rejects a below-floor PIN without touching the vault.
	base := newHTTPStore(t)
	const name, pass = "floorpin", "correct horse battery staple"
	createVault(base, name, pass)
	if err := setStoredPIN(base, name, pass, "12", nil); err == nil {
		t.Fatal("setStoredPIN accepted a 2-digit PIN")
	}
	if got := storedPIN(base, name, pass, nil); got != "" {
		t.Fatalf("a rejected PIN must not be stored, got %q", got)
	}
}

// A 2FA (key-enrolled) profile can set + read its PIN using the session's cached key hmac, and the derived
// COLD credential mixes both the PIN and the key (either factor alone gives a different credential).
func TestStoredPIN2FAAndColdCred(t *testing.T) {
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	const name, pass = "pin2fa", "correct horse battery staple"
	createVault(base, name, pass)

	hmac := make([]byte, fido2HMACLen)
	rand.Read(hmac)
	salt := make([]byte, 32)
	rand.Read(salt)
	if err := enrollFido2(base, name, pass, base64.StdEncoding.EncodeToString([]byte("cred")),
		base64.StdEncoding.EncodeToString(salt), hex.EncodeToString(hmac), false, "usb", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(hmac)) // the login-cached key
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")

	if err := setStoredPIN(base, name, pass, "135790", nil); err != nil {
		t.Fatalf("setStoredPIN on a 2FA vault: %v", err)
	}
	if got := storedPIN(base, name, pass, nil); got != "135790" {
		t.Fatalf("2FA storedPIN = %q, want 135790", got)
	}
	// Without the key, the 2FA vault can't be opened, so the PIN can't be read either.
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	if got := storedPIN(base, name, pass, nil); got != "" {
		t.Fatalf("2FA PIN readable without the key: %q", got)
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(hmac))

	// coldCredPIN: 16 hex chars, deterministic, and BOTH the PIN and the key change it (neither alone suffices).
	c := coldCredPIN(name, "135790", hmac)
	if len(c) != 16 {
		t.Fatalf("coldCredPIN len = %d, want 16", len(c))
	}
	if _, err := hex.DecodeString(c); err != nil {
		t.Fatalf("coldCredPIN not hex: %v", err)
	}
	if coldCredPIN(name, "135790", hmac) != c {
		t.Fatal("coldCredPIN not deterministic")
	}
	if coldCredPIN(name, "000000", hmac) == c {
		t.Fatal("coldCredPIN ignored the PIN")
	}
	other := make([]byte, fido2HMACLen)
	rand.Read(other)
	if coldCredPIN(name, "135790", other) == c {
		t.Fatal("coldCredPIN ignored the key hmac")
	}
}
