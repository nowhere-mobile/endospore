package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"

	"golang.org/x/crypto/hkdf"
)

// #135 telephony sealed inbox. When an inbound call/SMS lands for a SIM whose owning profile is NOT
// live (at the gate, cold-locked, or a different user is foreground), the item is sealed to that
// profile's telephony PUBLIC key and buffered as ciphertext in tmpfs, then decrypted + ingested into
// the profile's own providers at the owner's next login (docs/telephony-owner-mode.md).
//
// The seal is an anonymous sealed-box (ephemeral-static X25519 ECDH, NaCl-box shaped) built
// stdlib-only, matching the agent's crypto posture: crypto/ecdh (X25519) + HKDF-SHA256 + AES-256-GCM
// (the same GCM primitive wrap()/unwrap() use, and the same HKDF-over-a-domain-string pattern as
// fido2's kekFido2). Anyone can seal to a profile (public key only, so it works at the keyless gate);
// only the profile's private key -- wrap()'d under the vault DK and openable after a full login --
// can open it. A fresh ephemeral key per seal makes successive items to the same profile unlinkable.

const telSealInfo = "nowhere-telephony-seal-v1"

const (
	x25519KeyLen = 32 // raw X25519 public/private key length
	telNonceLen  = 12 // AES-GCM standard nonce length
)

// newTelephonyKeypair generates a profile's telephony keypair. pubB64 (raw 32-byte X25519, base64) is
// PUBLIC -- it goes into the SIM binding so the gate can seal to this profile without it being logged
// in. privRaw (raw 32 bytes) is SECRET -- the caller wrap()s it under the vault DK (vault.TelPriv), so
// it is recoverable only after a full pass(+key) login, exactly like the session PIN.
func newTelephonyKeypair() (pubB64 string, privRaw []byte, err error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", nil, err
	}
	return base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes()), priv.Bytes(), nil
}

// telSealKey derives the AEAD key from the ECDH shared secret, binding it to BOTH public keys
// (ephemeral + recipient) via the HKDF salt so a sealed box cannot be re-targeted at another
// recipient or have its ephemeral header swapped. HKDF-SHA256, domain-separated by telSealInfo.
func telSealKey(shared, ephPub, recipientPub []byte) ([]byte, error) {
	salt := make([]byte, 0, len(ephPub)+len(recipientPub))
	salt = append(salt, ephPub...)
	salt = append(salt, recipientPub...)
	r := hkdf.New(sha256.New, shared, salt, []byte(telSealInfo))
	key := make([]byte, 32)
	if _, err := io.ReadFull(r, key); err != nil {
		return nil, err
	}
	return key, nil
}

// sealToProfile seals plaintext to a profile's telephony public key (base64 raw X25519). The output
// (base64) is ephemeralPub(32) || nonce(12) || AES-256-GCM(ciphertext||tag), with the ephemeral
// public key also bound as the AEAD additional data. Never persists the plaintext.
func sealToProfile(pubB64 string, plaintext []byte) (string, error) {
	pubRaw, err := base64.StdEncoding.DecodeString(pubB64)
	if err != nil {
		return "", err
	}
	pub, err := ecdh.X25519().NewPublicKey(pubRaw)
	if err != nil {
		return "", err
	}
	eph, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	ephPub := eph.PublicKey().Bytes()
	shared, err := eph.ECDH(pub)
	if err != nil {
		return "", err
	}
	key, err := telSealKey(shared, ephPub, pubRaw)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := randBytes(gcm.NonceSize())
	out := make([]byte, 0, len(ephPub)+len(nonce)+len(plaintext)+gcm.Overhead())
	out = append(out, ephPub...)
	out = append(out, nonce...)
	out = gcm.Seal(out, nonce, plaintext, ephPub)
	return base64.StdEncoding.EncodeToString(out), nil
}

// openSealed reverses sealToProfile using the profile's raw private key (32-byte X25519). Returns an
// error (never a panic) on a short, malformed, tampered, or wrong-recipient blob.
func openSealed(privRaw []byte, blobB64 string) ([]byte, error) {
	blob, err := base64.StdEncoding.DecodeString(blobB64)
	if err != nil {
		return nil, err
	}
	if len(blob) < x25519KeyLen+telNonceLen {
		return nil, errors.New("telephony: sealed blob too short")
	}
	ephPub := blob[:x25519KeyLen]
	nonce := blob[x25519KeyLen : x25519KeyLen+telNonceLen]
	ct := blob[x25519KeyLen+telNonceLen:]
	priv, err := ecdh.X25519().NewPrivateKey(privRaw)
	if err != nil {
		return nil, err
	}
	ephPubKey, err := ecdh.X25519().NewPublicKey(ephPub)
	if err != nil {
		return nil, err
	}
	shared, err := priv.ECDH(ephPubKey)
	if err != nil {
		return nil, err
	}
	key, err := telSealKey(shared, ephPub, priv.PublicKey().Bytes())
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if gcm.NonceSize() != telNonceLen {
		return nil, errors.New("telephony: unexpected GCM nonce size")
	}
	return gcm.Open(nil, nonce, ct, ephPub)
}

// mmsPart is one part of a sealed MMS (#150): a text or media element of the multipart body. Data is
// the raw part bytes (Go's json marshals a []byte as base64, so the whole telItem stays one JSON blob);
// for a text part Data is the UTF-8 text, for a media part it is the binary (image/audio/...). Kept
// content-minimal -- content-type + best-effort name + bytes -- exactly what the roamed MMS provider
// needs to rebuild the pdu/part rows at ingest (P4), no more.
type mmsPart struct {
	ContentType string `json:"ct"`             // e.g. "text/plain", "image/jpeg", "application/smil"
	Name        string `json:"name,omitempty"` // part name / filename, best-effort
	Data        []byte `json:"data"`           // raw part bytes (base64 in JSON)
}

// telItem is one buffered inbound telephony event addressed to a profile -- the content-minimal set
// of fields the profile's SMS / CallLog / MMS providers need to reconstruct the row at ingest. It is
// JSON then sealed. Body is present only for kind=="sms"; call metadata only for kind=="call"; Subject
// + Parts only for kind=="mms".
type telItem struct {
	Kind     string `json:"kind"`                // "sms" | "call" | "mms"
	SubID    int    `json:"sub_id"`              // subscription/SIM the event arrived on
	From     string `json:"from"`                // sender / caller number as delivered
	When     int64  `json:"when"`                // unix milliseconds (arrival / call start)
	Body     string `json:"body,omitempty"`      // SMS text (empty for calls / mms)
	CallType int    `json:"call_type,omitempty"` // CallLog.Calls.TYPE (incoming/missed/...) for calls
	DurSec   int    `json:"dur_sec,omitempty"`   // call duration seconds (0 for missed / SMS)

	// #150 MMS-only:
	Subject string    `json:"subject,omitempty"` // MMS subject line (may be empty)
	Parts   []mmsPart `json:"parts,omitempty"`   // MMS body parts (text + media)
	// Note is a machine tag for a DEGRADED delivery, rendered as a short hint by the roamed ingest
	// (TelIngest.deliverMms) so a content-free MMS isn't a blank bubble. Currently only "too-large" (an
	// over-cap MMS whose media handleSealMms dropped). Empty for a normal item.
	Note string `json:"note,omitempty"`
}

// maxTelItemBytes caps a marshaled telItem before sealing. The seal buffers the whole (base64) blob in
// tmpfs (RAM), so an absurdly large MMS could pressure memory -- bound it. Carriers cap MMS around
// 300 KB-1 MB; 4 MiB of raw parts (JSON+base64 ~= 5.5 MiB) is generous headroom while still refusing a
// pathological one. The caller (the SEAL-MMS handler) turns an over-cap item into a content-free notice
// rather than sealing it, so a giant MMS degrades gracefully instead of OOMing the RAM buffer.
const maxTelItemBytes = 4 << 20 // 4 MiB

// sealTelItem marshals a telItem and seals it to the profile's telephony public key. Refuses an
// over-cap item (see maxTelItemBytes) so a pathological MMS can't blow up the tmpfs inbox.
func sealTelItem(pubB64 string, it telItem) (string, error) {
	b, err := json.Marshal(it)
	if err != nil {
		return "", err
	}
	if len(b) > maxTelItemBytes {
		return "", errTelItemTooLarge
	}
	return sealToProfile(pubB64, b)
}

// errTelItemTooLarge signals a marshaled telItem over maxTelItemBytes; the SEAL-MMS caller catches it
// and seals a content-free placeholder instead.
var errTelItemTooLarge = errors.New("telephony: sealed item exceeds size cap")

// errTelBoundFull signals a bound arrival whose buffer would cross the bound hard budget (telephony_owner.go). Its
// caller (deliverToOwners) counts the owner as not sealed, exactly like any other seal failure, so a line whose every
// owner is offline and full posts the loss notice. maxTelItemBytes caps one MMS; telBoundBudgetHard caps the aggregate.
var errTelBoundFull = errors.New("telephony: bound inbox at budget")

// telItemOversize reports whether a marshaled telItem would exceed the seal cap. The SEAL-MMS handler
// uses it to strip an over-cap MMS's media parts ONCE (content-free degrade: keep from/subject/when so
// the owner still learns an MMS arrived) before sealing to owners, rather than each per-owner seal
// failing with errTelItemTooLarge.
func telItemOversize(it telItem) bool {
	b, err := json.Marshal(it)
	return err != nil || len(b) > maxTelItemBytes
}

// openTelItem opens a sealed blob with the profile's private key and unmarshals the telItem.
func openTelItem(privRaw []byte, blobB64 string) (telItem, error) {
	var it telItem
	b, err := openSealed(privRaw, blobB64)
	if err != nil {
		return it, err
	}
	if err := json.Unmarshal(b, &it); err != nil {
		return it, err
	}
	return it, nil
}
