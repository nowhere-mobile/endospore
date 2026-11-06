package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"testing"
)

// #81 P4c: model BOTH sides of the CTAP2 PIN-protocol-1 hmac-secret exchange -- a stand-in "authenticator"
// with its own ephemeral key + per-credential HMAC key -- and prove the platform half (ctap_crypto.go)
// interoperates end to end, WITHOUT a security key.

// simAuthenticator is a minimal in-memory model of what a real key does for hmac-secret.
type simAuthenticator struct {
	priv    *ecdh.PrivateKey // the key's ephemeral key-agreement key (getKeyAgreement returns its pub)
	credKey []byte           // the per-credential secret HMAC key, never leaves the "device"
}

func newSimAuthenticator(t *testing.T) *simAuthenticator {
	t.Helper()
	priv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ck := make([]byte, 32)
	rand.Read(ck)
	return &simAuthenticator{priv: priv, credKey: ck}
}

// shared derives the authenticator-side shared secret from the platform's key-agreement pub (mirrors
// newPinProto1 on the other side).
func (a *simAuthenticator) shared(t *testing.T, platformPub *ecdh.PublicKey) []byte {
	z, err := a.priv.ECDH(platformPub)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(z)
	return h[:]
}

// assert models authenticatorGetAssertion's hmac-secret path: verify the salt auth tag, decrypt the salt,
// compute HMAC(credKey, salt), and return it encrypted under the shared secret.
func (a *simAuthenticator) assert(t *testing.T, sharedSecret, saltEnc, saltAuth []byte) []byte {
	mac := hmac.New(sha256.New, sharedSecret)
	mac.Write(saltEnc)
	if !hmac.Equal(mac.Sum(nil)[:16], saltAuth) {
		t.Fatal("authenticator: saltAuth did not verify")
	}
	// decrypt the salt (AES-256-CBC, zero IV)
	salt := aesCBCDec(t, sharedSecret, saltEnc)
	// the real secret: HMAC(credKey, salt)
	out := hmac.New(sha256.New, a.credKey)
	out.Write(salt)
	secret := out.Sum(nil)
	// return it encrypted under the shared secret
	return aesCBCEnc(t, sharedSecret, secret)
}

func TestHmacSecretRoundTrip(t *testing.T) {
	auth := newSimAuthenticator(t)

	// Platform: ephemeral key + derive the shared secret from the authenticator's key-agreement pub.
	platPriv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pp, err := newPinProto1(platPriv, auth.priv.PublicKey())
	if err != nil {
		t.Fatal(err)
	}

	// Both sides must derive the SAME shared secret.
	if !bytes.Equal(pp.shared, auth.shared(t, platPriv.PublicKey())) {
		t.Fatal("platform and authenticator derived different shared secrets")
	}

	// A fixed per-slot salt (what the vault slot stores).
	salt := make([]byte, 32)
	rand.Read(salt)

	// Platform prepares the assertion inputs; authenticator answers; platform decrypts.
	saltEnc, saltAuth, err := pp.hmacSecretSaltEnc(salt)
	if err != nil {
		t.Fatal(err)
	}
	encOut := auth.assert(t, pp.shared, saltEnc, saltAuth)
	got, err := pp.hmacSecretOutput(encOut)
	if err != nil {
		t.Fatal(err)
	}

	// It must equal HMAC(credKey, salt) -- the value that would derive the vault slot's KEK.
	want := hmac.New(sha256.New, auth.credKey)
	want.Write(salt)
	if !bytes.Equal(got, want.Sum(nil)) {
		t.Fatal("recovered hmac-secret output != HMAC(credKey, salt)")
	}

	// DETERMINISM: the same key + same salt yields the same secret on a fresh session (a NEW ephemeral key
	// agreement) -- the property that makes it usable as a stable KEK across logins.
	platPriv2, _ := ecdh.P256().GenerateKey(rand.Reader)
	pp2, _ := newPinProto1(platPriv2, auth.priv.PublicKey())
	se2, sa2, _ := pp2.hmacSecretSaltEnc(salt)
	got2, _ := pp2.hmacSecretOutput(auth.assert(t, pp2.shared, se2, sa2))
	if !bytes.Equal(got, got2) {
		t.Fatal("hmac-secret output not deterministic across sessions")
	}

	// A WRONG salt yields a different secret (so a different vault slot / a tampered salt won't unwrap DK).
	badSalt := make([]byte, 32)
	rand.Read(badSalt)
	seB, saB, _ := pp.hmacSecretSaltEnc(badSalt)
	gotB, _ := pp.hmacSecretOutput(auth.assert(t, pp.shared, seB, saB))
	if bytes.Equal(got, gotB) {
		t.Fatal("a different salt produced the same secret")
	}
}

// The COSE key-agreement encoding round-trips through our CBOR codec (what getKeyAgreement returns and what
// makeCredential/getAssertion send).
func TestCOSEKeyAgreementRoundTrip(t *testing.T) {
	priv, _ := ecdh.P256().GenerateKey(rand.Reader)
	cose := coseKeyAgreement(priv.PublicKey())
	enc, err := cborEncode(cose)
	if err != nil {
		t.Fatal(err)
	}
	dv, err := cborDecode(enc)
	if err != nil {
		t.Fatal(err)
	}
	dm, _ := asCBORMap(dv)
	pub, err := parseCOSEKeyAgreement(dm)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(pub.Bytes(), priv.PublicKey().Bytes()) {
		t.Fatal("COSE key-agreement point did not round-trip")
	}
}

// The PIN hash encryption is one AES block and reverses under the same shared secret.
func TestPinHashEnc(t *testing.T) {
	priv, _ := ecdh.P256().GenerateKey(rand.Reader)
	other, _ := ecdh.P256().GenerateKey(rand.Reader)
	pp, _ := newPinProto1(priv, other.PublicKey())
	enc, err := pp.pinHashEnc("1234")
	if err != nil {
		t.Fatal(err)
	}
	if len(enc) != 16 {
		t.Fatalf("pinHashEnc len = %d, want 16", len(enc))
	}
	back, _ := pp.decrypt(enc)
	want := sha256.Sum256([]byte("1234"))
	if !bytes.Equal(back, want[:16]) {
		t.Fatal("pinHashEnc did not decrypt to LEFT(SHA-256(PIN),16)")
	}
}

// ---- test-local AES-256-CBC (zero IV) helpers, so the sim authenticator is independent of ctap_crypto.go ----

func aesCBCEnc(t *testing.T, key, pt []byte) []byte {
	t.Helper()
	pp := &pinProto1{shared: key}
	out, err := pp.encrypt(pt)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func aesCBCDec(t *testing.T, key, ct []byte) []byte {
	t.Helper()
	pp := &pinProto1{shared: key}
	out, err := pp.decrypt(ct)
	if err != nil {
		t.Fatal(err)
	}
	return out
}
