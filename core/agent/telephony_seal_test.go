package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"reflect"
	"strings"
	"testing"
)

func mustKeypair(t *testing.T) (pub string, priv []byte) {
	t.Helper()
	pub, priv, err := newTelephonyKeypair()
	if err != nil {
		t.Fatalf("newTelephonyKeypair: %v", err)
	}
	if pb, _ := base64.StdEncoding.DecodeString(pub); len(pb) != x25519KeyLen {
		t.Fatalf("pub key len = %d, want %d", len(pb), x25519KeyLen)
	}
	if len(priv) != x25519KeyLen {
		t.Fatalf("priv key len = %d, want %d", len(priv), x25519KeyLen)
	}
	return pub, priv
}

func TestSealRoundTrip(t *testing.T) {
	pub, priv := mustKeypair(t)
	for _, pt := range [][]byte{
		[]byte("hello"),
		{},                              // empty
		bytes.Repeat([]byte("A"), 4096), // large
		[]byte("unicode: café ☎ 📱"),
	} {
		blob, err := sealToProfile(pub, pt)
		if err != nil {
			t.Fatalf("seal: %v", err)
		}
		got, err := openSealed(priv, blob)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		if !bytes.Equal(got, pt) {
			t.Fatalf("round-trip mismatch: got %q want %q", got, pt)
		}
	}
}

func TestSealItemRoundTrip(t *testing.T) {
	pub, priv := mustKeypair(t)
	for _, it := range []telItem{
		{Kind: "sms", SubID: 1, From: "+15551234567", When: 1_700_000_000_000, Body: "on my way"},
		{Kind: "call", SubID: 2, From: "+15559876543", When: 1_700_000_100_000, CallType: 1, DurSec: 42},
		{Kind: "call", SubID: 1, From: "+15550000000", When: 1_700_000_200_000, CallType: 3}, // missed
		// #150 MMS: subject + a smil + text + binary image part must all survive the seal round-trip.
		{Kind: "mms", SubID: 2, From: "+15551112222", When: 1_700_000_300_000, Subject: "pics 📷",
			Parts: []mmsPart{
				{ContentType: "application/smil", Name: "smil.xml", Data: []byte(`<smil><body/></smil>`)},
				{ContentType: "text/plain", Name: "text.txt", Data: []byte("check this out")},
				{ContentType: "image/jpeg", Name: "photo.jpg", Data: bytes.Repeat([]byte{0xFF, 0xD8, 0xFF, 0x00}, 500)},
			}},
	} {
		blob, err := sealTelItem(pub, it)
		if err != nil {
			t.Fatalf("sealTelItem: %v", err)
		}
		got, err := openTelItem(priv, blob)
		if err != nil {
			t.Fatalf("openTelItem: %v", err)
		}
		if !reflect.DeepEqual(got, it) {
			t.Fatalf("item round-trip mismatch:\n got %+v\nwant %+v", got, it)
		}
	}
}

func TestSealItemTooLarge(t *testing.T) {
	pub, _ := mustKeypair(t)
	// A pathological MMS: one part over the cap. sealTelItem must refuse it (the SEAL-MMS handler then
	// degrades to a content-free notice) rather than buffering a huge blob in the tmpfs inbox.
	big := telItem{Kind: "mms", From: "+15551234567", When: 1,
		Parts: []mmsPart{{ContentType: "image/jpeg", Data: make([]byte, maxTelItemBytes+1)}}}
	if _, err := sealTelItem(pub, big); err != errTelItemTooLarge {
		t.Fatalf("over-cap seal must return errTelItemTooLarge, got %v", err)
	}
	// A just-under-cap item must still seal fine (headroom check, accounting for JSON+base64 overhead).
	ok := telItem{Kind: "mms", From: "+15551234567", When: 1,
		Parts: []mmsPart{{ContentType: "image/jpeg", Data: make([]byte, 2<<20)}}}
	if _, err := sealTelItem(pub, ok); err != nil {
		t.Fatalf("under-cap MMS must seal, got %v", err)
	}
}

func TestOpenWrongKeyFails(t *testing.T) {
	pub, _ := mustKeypair(t)
	_, otherPriv := mustKeypair(t)
	blob, err := sealToProfile(pub, []byte("secret"))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if _, err := openSealed(otherPriv, blob); err == nil {
		t.Fatal("open with the wrong private key must fail")
	}
}

func TestTamperFails(t *testing.T) {
	pub, priv := mustKeypair(t)
	blob, err := sealToProfile(pub, []byte("do not tamper"))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	raw, _ := base64.StdEncoding.DecodeString(blob)
	// Flip a byte in each region: ephemeral pub, nonce, and ciphertext/tag.
	for _, pos := range []int{0, x25519KeyLen, len(raw) - 1} {
		bad := append([]byte{}, raw...)
		bad[pos] ^= 0xff
		if _, err := openSealed(priv, base64.StdEncoding.EncodeToString(bad)); err == nil {
			t.Fatalf("tampering byte %d must fail authentication", pos)
		}
	}
}

func TestShortBlobErrorsNoPanic(t *testing.T) {
	_, priv := mustKeypair(t)
	for _, b := range []string{
		"",                // empty
		"!!!notbase64!!!", // bad base64
		base64.StdEncoding.EncodeToString([]byte("short")),                                   // < ephPub+nonce
		base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0}, x25519KeyLen+telNonceLen)), // header only, no ct
	} {
		if _, err := openSealed(priv, b); err == nil {
			t.Fatalf("malformed blob %q must error", b)
		}
	}
}

func TestSealIsNondeterministic(t *testing.T) {
	pub, priv := mustKeypair(t)
	pt := []byte("same plaintext")
	a, _ := sealToProfile(pub, pt)
	b, _ := sealToProfile(pub, pt)
	if a == b {
		t.Fatal("two seals of the same plaintext must differ (fresh ephemeral + nonce)")
	}
	// ...but both still open to the same plaintext.
	for _, blob := range []string{a, b} {
		got, err := openSealed(priv, blob)
		if err != nil || !bytes.Equal(got, pt) {
			t.Fatalf("both seals must open: err=%v got=%q", err, got)
		}
	}
}

func TestEphemeralHeaderCannotBeSwapped(t *testing.T) {
	pub, priv := mustKeypair(t)
	a, _ := sealToProfile(pub, []byte("message A"))
	b, _ := sealToProfile(pub, []byte("message B"))
	ra, _ := base64.StdEncoding.DecodeString(a)
	rb, _ := base64.StdEncoding.DecodeString(b)
	// Graft B's ephemeral-pub header onto A's nonce+ciphertext.
	spliced := append(append([]byte{}, rb[:x25519KeyLen]...), ra[x25519KeyLen:]...)
	if _, err := openSealed(priv, base64.StdEncoding.EncodeToString(spliced)); err == nil {
		t.Fatal("swapping the ephemeral header must break the seal (key + AAD binding)")
	}
}

func TestBadPublicKeyErrors(t *testing.T) {
	if _, err := sealToProfile("!!!notbase64!!!", []byte("x")); err == nil {
		t.Fatal("non-base64 public key must error")
	}
	if _, err := sealToProfile(base64.StdEncoding.EncodeToString([]byte("tooshort")), []byte("x")); err == nil {
		t.Fatal("wrong-length public key must error")
	}
}

func TestOpenBadPrivateKeyErrors(t *testing.T) {
	pub, _ := mustKeypair(t)
	blob, _ := sealToProfile(pub, []byte("x"))
	if _, err := openSealed([]byte("tooshort"), blob); err == nil {
		t.Fatal("wrong-length private key must error")
	}
}

func TestManyRandomRoundTrips(t *testing.T) {
	pub, priv := mustKeypair(t)
	for i := 0; i < 200; i++ {
		n := i % 300
		pt := make([]byte, n)
		if _, err := rand.Read(pt); err != nil {
			t.Fatalf("rand: %v", err)
		}
		blob, err := sealToProfile(pub, pt)
		if err != nil {
			t.Fatalf("seal(%d): %v", n, err)
		}
		got, err := openSealed(priv, blob)
		if err != nil {
			t.Fatalf("open(%d): %v", n, err)
		}
		if !bytes.Equal(got, pt) {
			t.Fatalf("mismatch at len %d", n)
		}
	}
}

// The blob must not contain the plaintext in the clear (sanity that we actually encrypt).
func TestBlobHidesPlaintext(t *testing.T) {
	pub, _ := mustKeypair(t)
	secret := "SUPER-SECRET-NEEDLE-9f3a"
	blob, err := sealToProfile(pub, []byte(secret))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	raw, _ := base64.StdEncoding.DecodeString(blob)
	if strings.Contains(string(raw), secret) || bytes.Contains(raw, []byte(secret)) {
		t.Fatal("sealed blob leaks the plaintext")
	}
}
