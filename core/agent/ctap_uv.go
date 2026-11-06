package main

import (
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
)

// NWP-20261025-07: the CTAP2 user-verification token. A key that requires user verification (alwaysUv, or
// makeCredUvNotRqd=false) answers makeCredential/getAssertion with a pinUvAuthParam only, and the param is
// keyed by a pinUvAuthToken the key hands out through authenticatorClientPIN. The decision of 2026-10-18
// (docs/product-decisions.md; docs/fido2-key-only-login.md §6, §9, §10): at the gate the key verifies the user by
// its own fingerprint when it has one, and by its PIN, typed on the phone, only when it has none. A key with
// built-in UV is never asked for its PIN. The PIN is runtime-only: never stored, never logged, never in an error.
// No production caller yet: the enrol and sign-in paths take this up in a later slice.

// uvMethod is how the key will verify the user for one token.
type uvMethod int

const (
	uvBuiltIn uvMethod = iota + 1 // the key's own fingerprint (getPinUvAuthTokenUsingUvWithPermissions)
	uvPIN                         // the key's PIN, typed on the phone
)

// CTAP2.1 §6.5.5.7 permissions a token is minted for; one token serves one command.
const (
	permMC uint64 = 0x01 // makeCredential
	permGA uint64 = 0x02 // getAssertion
)

// authenticatorClientPIN sub-commands this file sends (getKeyAgreement, 0x02, stays in ctap_cmd.go).
const (
	cpGetPinToken      = 0x05 // CTAP2.0 getPinToken: the PIN, no permissions
	cpGetTokenUsingUV  = 0x06 // getPinUvAuthTokenUsingUvWithPermissions
	cpGetTokenUsingPIN = 0x09 // getPinUvAuthTokenUsingPinWithPermissions
)

var (
	errBuiltInUVUnsupported = errors.New("the key verifies by fingerprint but offers no pinUvAuthToken, which this client needs to drive the fingerprint reader")
	errNoUserVerification   = errors.New("the key needs user verification but has no fingerprint enrolled and no PIN set")
	errKeyPINNeeded         = errors.New("the key has no fingerprint and needs its PIN, which this path cannot take")
	errKeyPINUnavailable    = errors.New("the key PIN could not be read")
	errUVBlocked            = errors.New("clientPIN: CTAP2 status 0x3c UV_BLOCKED: the fingerprint reader is locked after failed reads and must be unlocked elsewhere")
)

// chooseUV picks the verification for a key from its getInfo. The case order is the decision: built-in UV wins
// whenever the key has it, so a key with a fingerprint AND a PIN is never given the PIN path.
// Option semantics: `uv` absent means no sensor and false a sensor with no fingerprint enrolled; `clientPin`
// true means a PIN is set. A key with a usable fingerprint but no pinUvAuthToken option (a CTAP2.0-style
// key) is a bounded limit: its fingerprint can be driven only through getPinUvAuthTokenUsingUv, so it gets an
// error, never the PIN.
func chooseUV(i *ctapInfo) (uvMethod, error) {
	uv, _ := i.option("uv")
	tok, _ := i.option("pinUvAuthToken")
	pin, _ := i.option("clientPin")
	switch {
	case uv && tok:
		return uvBuiltIn, nil
	case uv:
		return 0, errBuiltInUVUnsupported
	case pin:
		return uvPIN, nil
	}
	return 0, errNoUserVerification
}

// pinUvToken is a pinUvAuthToken the key minted. It is runtime secret material: never logged, no String().
type pinUvToken struct{ token []byte }

// param is the pinUvAuthParam for a command (protocol 1): LEFT(HMAC-SHA-256(token, clientDataHash), 16).
func (t *pinUvToken) param(clientDataHash []byte) []byte {
	mac := hmac.New(sha256.New, t.token)
	mac.Write(clientDataHash)
	return mac.Sum(nil)[:16]
}

// getPinUvAuthToken obtains a token for perms on rpID: the key's fingerprint first, its PIN (asked from pin,
// exactly once) only for a key without one. A locked fingerprint reader (UV_BLOCKED) does not fall back to the PIN.
func getPinUvAuthToken(h ctapTransport, i *ctapInfo, pin func() (string, error), perms uint64, rpID string) (*pinUvToken, error) {
	m, err := chooseUV(i)
	if err != nil {
		return nil, err
	}
	if m == uvBuiltIn {
		tok, err := tokenUsingUV(h, perms, rpID)
		if errors.Is(err, errUVBlocked) { // the decision: a key with built-in UV is never asked for its PIN
			return nil, err
		}
		return tok, err
	}
	return tokenUsingPIN(h, i, pin, perms, rpID)
}

// clientPINSession runs a fresh key agreement against the key and returns the shared secret plus the platform key.
func clientPINSession(h ctapTransport) (*pinProto1, *ecdh.PrivateKey, error) {
	authPub, err := getKeyAgreement(h)
	if err != nil {
		return nil, nil, err
	}
	platformPriv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	pp, err := newPinProto1(platformPriv, authPub)
	if err != nil {
		return nil, nil, err
	}
	return pp, platformPriv, nil
}

func tokenUsingUV(h ctapTransport, perms uint64, rpID string) (*pinUvToken, error) {
	pp, platformPriv, err := clientPINSession(h)
	if err != nil {
		return nil, err
	}
	req := newCBORMap().
		put(uint64(1), uint64(1)).
		put(uint64(2), uint64(cpGetTokenUsingUV)).
		put(uint64(3), coseKeyAgreement(platformPriv.PublicKey())).
		put(uint64(9), perms).
		put(uint64(0x0a), rpID)
	return clientPINToken(h, pp, req)
}

func tokenUsingPIN(h ctapTransport, i *ctapInfo, pin func() (string, error), perms uint64, rpID string) (*pinUvToken, error) {
	if pin == nil {
		return nil, errKeyPINNeeded
	}
	pp, platformPriv, err := clientPINSession(h)
	if err != nil {
		return nil, err
	}
	var hashEnc []byte
	{
		p, err := pin()
		if err != nil { // the callback's own text is dropped: it could carry what the user typed
			return nil, errKeyPINUnavailable
		}
		if hashEnc, err = pp.pinHashEnc(p); err != nil {
			return nil, err
		}
	} // the PIN goes out of scope here: nothing below can carry it
	req := newCBORMap().
		put(uint64(1), uint64(1)).
		put(uint64(3), coseKeyAgreement(platformPriv.PublicKey())).
		put(uint64(6), hashEnc)
	if withPerms, _ := i.option("pinUvAuthToken"); withPerms {
		req.put(uint64(2), uint64(cpGetTokenUsingPIN)).put(uint64(9), perms).put(uint64(0x0a), rpID)
	} else {
		req.put(uint64(2), uint64(cpGetPinToken)) // CTAP2.0: no permissions, no rpId
	}
	return clientPINToken(h, pp, req)
}

// clientPINToken sends a token request and decrypts the token from response key 0x02.
func clientPINToken(h ctapTransport, pp *pinProto1, req *cborMap) (*pinUvToken, error) {
	pb, err := cborEncode(req)
	if err != nil {
		return nil, err
	}
	status, body, err := h.cbor(ctapClientPIN, pb)
	if err != nil {
		return nil, err
	}
	if status != 0x00 {
		return nil, tokenStatusErr(status)
	}
	m, err := decodeMap(body)
	if err != nil {
		return nil, err
	}
	enc, ok := cborBytes(m.get(uint64(2)))
	if !ok {
		return nil, errors.New("clientPIN: no pinUvAuthToken in response")
	}
	tok, err := pp.decrypt(enc)
	if err != nil {
		return nil, fmt.Errorf("clientPIN: %w", err)
	}
	if len(tok) != 16 && len(tok) != 32 {
		return nil, fmt.Errorf("clientPIN: pinUvAuthToken is %d bytes, want 16 or 32", len(tok))
	}
	return &pinUvToken{token: tok}, nil
}

// tokenStatusErr names the statuses a token request can answer. None of the texts carries the PIN or its hash.
func tokenStatusErr(st byte) error {
	switch st {
	case 0x31:
		return errors.New("clientPIN: CTAP2 status 0x31 PIN_INVALID: the key refused the PIN")
	case 0x32:
		return errors.New("clientPIN: CTAP2 status 0x32 PIN_BLOCKED: the key's PIN retries are used up and the key must be reset")
	case 0x34:
		return errors.New("clientPIN: CTAP2 status 0x34 PIN_AUTH_BLOCKED: the key's PIN is locked until the key is power-cycled")
	case 0x35:
		return errors.New("clientPIN: CTAP2 status 0x35 PIN_NOT_SET: the key has no PIN")
	case 0x36:
		return errors.New("clientPIN: CTAP2 status 0x36 PUAT_REQUIRED: the key wants a pinUvAuthToken first")
	case 0x3c:
		return errUVBlocked
	case 0x3f:
		return errors.New("clientPIN: CTAP2 status 0x3f UV_INVALID: the key did not recognise the fingerprint")
	case 0x40:
		return errors.New("clientPIN: CTAP2 status 0x40 UNAUTHORIZED_PERMISSION: the key refused the requested permissions")
	}
	return fmt.Errorf("clientPIN: CTAP2 status 0x%02x", st)
}
