package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
)

// CTAP2 PIN/UV auth protocol 1 crypto for the FIDO2 hmac-secret flow (#81 P4c). This is the platform half
// of the ECDH + AES + HMAC dance a security key requires; stdlib-only (crypto/ecdh has P-256), and modelled
// against a simulated authenticator in the tests so the whole thing is proven WITHOUT hardware.
//
// Protocol 1 (universally supported, incl. the Yubico Security Key series):
//   - key agreement: platform + authenticator each hold an ephemeral P-256 key; the shared secret is
//     sharedSecret = SHA-256(ECDH(priv, otherPub).x).
//   - encrypt(k, m) = AES-256-CBC(key=k, IV=0, m)   -- no padding; m must be block-aligned.
//   - decrypt(k, c) = AES-256-CBC decrypt(key=k, IV=0, c).
//   - authenticate(k, m) = LEFT(HMAC-SHA-256(k, m), 16).
// hmac-secret rides this: the salt is encrypt(sharedSecret, salt); the authenticator returns HMAC(credKey,
// salt) encrypt(sharedSecret, ...)'d, which the platform decrypts.

// coseP256 is the (x,y) of a P-256 point as an authenticator/platform key-agreement COSE key.
// COSE_Key: {1:2(EC2), 3:-25(ECDH-ES+HKDF-256), -1:1(P-256), -2:x, -3:y}.
func coseKeyAgreement(pub *ecdh.PublicKey) *cborMap {
	raw := pub.Bytes() // 0x04 || x(32) || y(32)
	x := raw[1:33]
	y := raw[33:65]
	return newCBORMap().
		put(uint64(1), uint64(2)).
		put(uint64(3), int64(-25)).
		put(int64(-1), uint64(1)).
		put(int64(-2), x).
		put(int64(-3), y)
}

// parseCOSEKeyAgreement reads the authenticator's key-agreement COSE key (from clientPIN getKeyAgreement)
// into an ecdh public key. Only the curve point (-2 x, -3 y) is needed.
func parseCOSEKeyAgreement(m *cborMap) (*ecdh.PublicKey, error) {
	x, okx := cborBytes(m.get(int64(-2)))
	y, oky := cborBytes(m.get(int64(-3)))
	if !okx || !oky || len(x) != 32 || len(y) != 32 {
		return nil, errors.New("cose: bad P-256 key-agreement point")
	}
	raw := make([]byte, 65)
	raw[0] = 0x04
	copy(raw[1:33], x)
	copy(raw[33:65], y)
	return ecdh.P256().NewPublicKey(raw)
}

// pinProto1 holds the derived shared secret for one session with the authenticator.
type pinProto1 struct{ shared []byte }

// newPinProto1 derives the protocol-1 shared secret from the platform ephemeral private key and the
// authenticator's key-agreement public key.
func newPinProto1(platformPriv *ecdh.PrivateKey, authPub *ecdh.PublicKey) (*pinProto1, error) {
	z, err := platformPriv.ECDH(authPub) // the x-coordinate of the shared point (32 bytes)
	if err != nil {
		return nil, err
	}
	h := sha256.Sum256(z)
	return &pinProto1{shared: h[:]}, nil
}

func (p *pinProto1) encrypt(plaintext []byte) ([]byte, error) {
	if len(plaintext)%aes.BlockSize != 0 {
		return nil, errors.New("ctap encrypt: plaintext not block-aligned")
	}
	block, err := aes.NewCipher(p.shared)
	if err != nil {
		return nil, err
	}
	iv := make([]byte, aes.BlockSize) // protocol 1: zero IV
	out := make([]byte, len(plaintext))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, plaintext)
	return out, nil
}

func (p *pinProto1) decrypt(ct []byte) ([]byte, error) {
	if len(ct)%aes.BlockSize != 0 || len(ct) == 0 {
		return nil, errors.New("ctap decrypt: ciphertext not block-aligned")
	}
	block, err := aes.NewCipher(p.shared)
	if err != nil {
		return nil, err
	}
	iv := make([]byte, aes.BlockSize)
	out := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, ct)
	return out, nil
}

// authenticate = LEFT(HMAC-SHA-256(sharedSecret, msg), 16) -- the pinUvAuthParam / salt auth tag.
func (p *pinProto1) authenticate(msg []byte) []byte {
	mac := hmac.New(sha256.New, p.shared)
	mac.Write(msg)
	return mac.Sum(nil)[:16]
}

// hmacSecretSaltEnc prepares the hmac-secret extension inputs for a getAssertion: the encrypted salt and its
// auth tag. salt is the 32-byte per-slot salt (from the vault slot). Returns (saltEnc, saltAuth).
func (p *pinProto1) hmacSecretSaltEnc(salt []byte) (saltEnc, saltAuth []byte, err error) {
	if len(salt) != 32 {
		return nil, nil, errors.New("hmac-secret: salt must be 32 bytes")
	}
	saltEnc, err = p.encrypt(salt)
	if err != nil {
		return nil, nil, err
	}
	return saltEnc, p.authenticate(saltEnc), nil
}

// hmacSecretOutput decrypts the authenticator's hmac-secret result (the encrypted HMAC(credKey, salt)) back
// to the 32-byte secret that feeds the vault slot's KEK.
func (p *pinProto1) hmacSecretOutput(encOutput []byte) ([]byte, error) {
	out, err := p.decrypt(encOutput)
	if err != nil {
		return nil, err
	}
	if len(out) != 32 {
		return nil, errors.New("hmac-secret: output not 32 bytes")
	}
	return out, nil
}

// pinHashEnc encrypts LEFT(SHA-256(PIN),16) under the shared secret -- the clientPIN getPINToken input.
func (p *pinProto1) pinHashEnc(pin string) ([]byte, error) {
	h := sha256.Sum256([]byte(pin))
	return p.encrypt(h[:16])
}
