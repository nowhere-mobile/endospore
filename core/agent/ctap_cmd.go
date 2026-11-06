package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"strings"
)

// CTAP2 commands for the FIDO2 hmac-secret flow (#81 P4d): getKeyAgreement, makeCredential (enroll),
// getAssertion (login). These ride the proven layers -- the CBOR codec (P4a), the PIN/hmac-secret crypto
// (P4c), and a CTAP2 transport -- so this file is just the command/response shaping. 2FA mode
// (tier 2a): touch-only (no key PIN required) enroll + assert; the passphrase is the second factor.

// ctapTransport is one open CTAP2 session over any binding. cbor sends a CTAP2 command (a command byte +
// CBOR params) and returns the CTAP2 status byte + CBOR response body. Two implementations: ctapHID (USB-HID,
// #81 item 1-4, opens /dev/hidraw in the root worker) and ctapNFC (ISO-DEP APDUs, #81 item 5, transceived by
// the chooser's NfcAdapter reader mode). The command shaping below is transport-agnostic -- it only calls cbor.
type ctapTransport interface {
	cbor(ctapCmd byte, params []byte) (status byte, body []byte, err error)
	Close()
}

const (
	ctapMakeCredential = 0x01
	ctapGetAssertion   = 0x02
	ctapCmdGetInfo     = 0x04
	ctapClientPIN      = 0x06

	// The relying-party id baked into our credentials. A key stores it; getAssertion must present the same.
	// A fixed value -- there is no web origin here, the key is a local key-material source.
	nowhereRPID = "nowhere.mobile"
)

// getKeyAgreement runs authenticatorClientPIN(subCommand=getKeyAgreement) and returns the authenticator's
// ephemeral P-256 key-agreement public key (protocol 1). Needed to derive the shared secret for hmac-secret.
func getKeyAgreement(h ctapTransport) (*ecdh.PublicKey, error) {
	params := newCBORMap().
		put(uint64(1), uint64(1)). // pinUvAuthProtocol = 1
		put(uint64(2), uint64(2))  // subCommand = getKeyAgreement
	pb, err := cborEncode(params)
	if err != nil {
		return nil, err
	}
	status, body, err := h.cbor(ctapClientPIN, pb)
	if err != nil {
		return nil, err
	}
	if status != 0x00 {
		return nil, fmt.Errorf("getKeyAgreement: CTAP2 status 0x%02x", status)
	}
	m, err := decodeMap(body)
	if err != nil {
		return nil, err
	}
	ka, ok := asCBORMap(m.get(uint64(1))) // keyAgreement COSE key
	if !ok {
		return nil, errors.New("getKeyAgreement: no key in response")
	}
	pub, perr := parseCOSEKeyAgreement(ka)
	return pub, perr
}

// makeCredential enrolls a NON-RESIDENT credential (2FA: the credId is stored in our vault slot, not on the
// key) with the hmac-secret extension enabled. Returns the credential id. Requires one user-presence touch.
func makeCredential(h ctapTransport, rpID string) (credID []byte, err error) {
	return makeCredentialTok(h, rpID, nil)
}

// makeCredentialTok is makeCredential for a key that requires user verification: with tok the request also
// carries pinUvAuthParam (0x08) and pinUvAuthProtocol (0x09), from a token minted with permMC (ctap_uv.go).
func makeCredentialTok(h ctapTransport, rpID string, tok *pinUvToken) (credID []byte, err error) {
	clientDataHash := make([]byte, 32)
	rand.Read(clientDataHash)
	userID := []byte("nowhere") // non-resident: stored but unused by us

	params := newCBORMap().
		put(uint64(1), clientDataHash).
		put(uint64(2), newCBORMap().put("id", rpID).put("name", "nowhere")).
		put(uint64(3), newCBORMap().put("id", userID).put("name", "nowhere").put("displayName", "nowhere")).
		put(uint64(4), []any{newCBORMap().put("alg", int64(-7)).put("type", "public-key")}). // ES256
		put(uint64(6), newCBORMap().put("hmac-secret", true))                                // enable hmac-secret
	// options omitted: rk defaults false (non-resident). 0x27 (operation denied) with no touch has TWO causes:
	// (1) an explicit default option -- CTAP2.1 keys reject one, hence none is sent; (2) a key that requires user
	// verification (alwaysUv, or makeCredUvNotRqd=false), which this client cannot supply until it has
	// getPINToken (docs/fido2-key-only-login.md §6). enrollMakeCredential asks getInfo first, so cause (2) is
	// refused by name before this is sent; makeCredUvNotRqd=true means touch-only is allowed.
	if tok != nil { // the key's user verification: LEFT(HMAC(token, clientDataHash), 16), protocol 1
		params.put(uint64(8), tok.param(clientDataHash)).put(uint64(9), uint64(1))
	}
	pb, err := cborEncode(params)
	if err != nil {
		return nil, err
	}
	status, body, err := h.cbor(ctapMakeCredential, pb)
	if err != nil {
		return nil, err
	}
	if status != 0x00 {
		if status == 0x27 {
			return nil, errors.New("makeCredential: CTAP2 status 0x27 (operation denied: an explicit default option was sent, or the key requires user verification -- a PIN or fingerprint -- which this client cannot supply yet)")
		}
		return nil, fmt.Errorf("makeCredential: CTAP2 status 0x%02x", status)
	}
	m, err := decodeMap(body)
	if err != nil {
		return nil, err
	}
	authData, ok := cborBytes(m.get(uint64(2))) // 2 = authData
	if !ok {
		return nil, errors.New("makeCredential: no authData")
	}
	cid, _, err := parseAuthData(authData)
	if err != nil {
		return nil, err
	}
	if len(cid) == 0 {
		return nil, errors.New("makeCredential: no credential id in authData")
	}
	return cid, nil
}

// getAssertionHMAC runs authenticatorGetAssertion with the hmac-secret extension for a stored credential +
// salt, and returns the 32-byte HMAC(credKey, salt) that feeds the vault slot's KEK. Requires one user
// presence: a touch over USB, THE TAP ITSELF over NFC. up is always true -- the spec releases the hmac-secret
// output only WITH user presence (up:false = CTAP2_ERR_USER_ACTION_REQUIRED 0x3b, proven on the Yubico C NFC)
// -- and an NFC key grants exactly ONE presence per physical tap, which is why the NFC enroll is TWO taps
// (makeCredential consumes tap 1's presence; this assertion needs tap 2's).
//
// #81 item 5: over NFC the authenticator can invalidate its key-agreement state between commands (proven:
// makeCredential in the same field session stales it -> the salt-auth checks against a secret the platform
// never used -> CTAP2_ERR_PIN_AUTH_INVALID 0x34). Retry with a FRESH getKeyAgreement each time. Over USB 0x34
// never occurs, so this returns on the first attempt.
func getAssertionHMAC(h ctapTransport, rpID string, credID, salt []byte) ([]byte, error) {
	return getAssertionHMACTok(h, rpID, credID, salt, nil)
}

// getAssertionHMACTok is getAssertionHMAC for a key that requires user verification: with tok every attempt also
// carries pinUvAuthParam (0x06, over that attempt's own clientDataHash) and pinUvAuthProtocol (0x07), from a
// token minted with permGA. Such an assertion yields the key's WithUV hmac-secret output, a different one from
// the no-token output. A token is valid for one command and a token assertion is USB-only so far, so a 0x34
// is returned at once instead of retried.
func getAssertionHMACTok(h ctapTransport, rpID string, credID, salt []byte, tok *pinUvToken) ([]byte, error) {
	const maxAttempts = 4
	var lastStatus byte
	for attempt := 0; attempt < maxAttempts; attempt++ {
		authPub, err := getKeyAgreement(h)
		if err != nil {
			return nil, err
		}
		platformPriv, err := ecdh.P256().GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		pp, err := newPinProto1(platformPriv, authPub)
		if err != nil {
			return nil, err
		}
		saltEnc, saltAuth, err := pp.hmacSecretSaltEnc(salt)
		if err != nil {
			return nil, err
		}
		// hmac-secret getAssertion extension (protocol 1): {1: platform keyAgreement, 2: saltEnc, 3: saltAuth}.
		hmacExt := newCBORMap().
			put(uint64(1), coseKeyAgreement(platformPriv.PublicKey())).
			put(uint64(2), saltEnc).
			put(uint64(3), saltAuth)
		clientDataHash := make([]byte, 32)
		rand.Read(clientDataHash)

		params := newCBORMap().
			put(uint64(1), rpID).
			put(uint64(2), clientDataHash).
			put(uint64(3), []any{newCBORMap().put("id", credID).put("type", "public-key")}). // allowList
			put(uint64(4), newCBORMap().put("hmac-secret", hmacExt)).
			put(uint64(5), newCBORMap().put("up", true)) // hmac-secret requires UP (see doc comment)
		if tok != nil {
			params.put(uint64(6), tok.param(clientDataHash)).put(uint64(7), uint64(1))
		}
		pb, err := cborEncode(params)
		if err != nil {
			return nil, err
		}
		status, body, err := h.cbor(ctapGetAssertion, pb)
		if err != nil {
			return nil, err
		}
		lastStatus = status
		if status == 0x34 && tok != nil {
			return nil, errors.New("getAssertion: CTAP2 status 0x34 with a pinUvAuthToken, not retried")
		}
		if status == 0x34 { // PIN_AUTH_INVALID: stale key agreement over NFC -> fresh getKeyAgreement + retry
			continue
		}
		if status != 0x00 {
			return nil, fmt.Errorf("getAssertion: CTAP2 status 0x%02x", status)
		}
		m, err := decodeMap(body)
		if err != nil {
			return nil, err
		}
		authData, ok := cborBytes(m.get(uint64(2))) // 2 = authData
		if !ok {
			return nil, errors.New("getAssertion: no authData")
		}
		_, ext, err := parseAuthData(authData)
		if err != nil {
			return nil, err
		}
		if ext == nil {
			return nil, errors.New("getAssertion: no extensions in authData (hmac-secret unsupported/off?)")
		}
		encOut, ok := cborBytes(ext.get("hmac-secret"))
		if !ok {
			return nil, errors.New("getAssertion: no hmac-secret output")
		}
		return pp.hmacSecretOutput(encOut)
	}
	return nil, fmt.Errorf("getAssertion: CTAP2 status 0x%02x after %d attempts", lastStatus, maxAttempts)
}

// parseAuthData extracts the credential id (present only when the AT flag is set, i.e. from makeCredential)
// and the extensions map (present when the ED flag is set, i.e. hmac-secret output) from a WebAuthn/CTAP2
// authenticator-data byte string. Layout: rpIdHash(32) | flags(1) | signCount(4) | [attestedCredentialData]
// | [extensions]. AT = flags bit 6 (0x40), ED = flags bit 7 (0x80).
func parseAuthData(a []byte) (credID []byte, ext *cborMap, err error) {
	if len(a) < 37 {
		return nil, nil, errors.New("authData too short")
	}
	flags := a[32]
	off := 37
	if flags&0x40 != 0 { // AT: attested credential data present
		if len(a) < off+18 {
			return nil, nil, errors.New("authData: truncated attested-cred header")
		}
		off += 16 // skip aaguid
		l := int(binary.BigEndian.Uint16(a[off : off+2]))
		off += 2
		if len(a) < off+l {
			return nil, nil, errors.New("authData: truncated credential id")
		}
		credID = append([]byte(nil), a[off:off+l]...)
		off += l
		// skip the credential public key (a COSE CBOR map) by decoding + measuring how much it consumed
		_, rest, derr := cborDec(a[off:])
		if derr != nil {
			return nil, nil, fmt.Errorf("authData: bad credential public key: %w", derr)
		}
		off = len(a) - len(rest)
	}
	if flags&0x80 != 0 { // ED: extensions present
		v, _, derr := cborDec(a[off:])
		if derr != nil {
			return nil, nil, fmt.Errorf("authData: bad extensions: %w", derr)
		}
		m, ok := asCBORMap(v)
		if !ok {
			return nil, nil, errors.New("authData: extensions not a map")
		}
		ext = m
	}
	return credID, ext, nil
}

// decodeMap decodes a CBOR body and asserts it is a map (every CTAP2 success response body is a map).
func decodeMap(body []byte) (*cborMap, error) {
	v, err := cborDecode(body)
	if err != nil {
		return nil, err
	}
	m, ok := asCBORMap(v)
	if !ok {
		return nil, errors.New("CTAP2 response is not a map")
	}
	return m, nil
}

// ---- authenticatorGetInfo: ask the key what it can do before the first touch (docs/fido2-key-only-login.md §7) ----

// ctapOption is one entry of getInfo's options map (key 0x04), kept in the key's own order.
type ctapOption struct {
	Name  string
	Value any
}

// ctapInfo is the decoded authenticatorGetInfo answer. Has records which top-level keys the answer carried with
// the right type, so an absent key is told apart from an empty one; RemainingDiscoverable is -1 without key 0x14.
type ctapInfo struct {
	Versions, Extensions  []string
	Options               []ctapOption
	PinProtocols          []uint64
	RemainingDiscoverable int64
	Has                   map[uint64]bool
}

// option looks an option up by name; v is true only for a bool true.
func (i *ctapInfo) option(name string) (v, present bool) {
	for _, o := range i.Options {
		if o.Name == name {
			b, _ := o.Value.(bool)
			return b, true
		}
	}
	return false, false
}

func (i *ctapInfo) hasExtension(name string) bool {
	for _, e := range i.Extensions {
		if e == name {
			return true
		}
	}
	return false
}

func (i *ctapInfo) hasProtocol(p uint64) bool {
	for _, q := range i.PinProtocols {
		if q == p {
			return true
		}
	}
	return false
}

func cborStrings(a []any) []string {
	var out []string
	for _, e := range a {
		if s, ok := cborStr(e); ok {
			out = append(out, s)
		}
	}
	return out
}

// ctapGetInfo sends authenticatorGetInfo (no params). A key or element of the wrong type is skipped, never a panic.
func ctapGetInfo(h ctapTransport) (*ctapInfo, error) {
	status, body, err := h.cbor(ctapCmdGetInfo, nil)
	if err != nil {
		return nil, err
	}
	if status != 0x00 {
		return nil, fmt.Errorf("getInfo: CTAP2 status 0x%02x", status)
	}
	m, err := decodeMap(body)
	if err != nil {
		return nil, err
	}
	info := &ctapInfo{RemainingDiscoverable: -1, Has: map[uint64]bool{}}
	if a, ok := cborArr(m.get(uint64(1))); ok {
		info.Has[1] = true
		info.Versions = cborStrings(a)
	}
	if a, ok := cborArr(m.get(uint64(2))); ok {
		info.Has[2] = true
		info.Extensions = cborStrings(a)
	}
	if o, ok := asCBORMap(m.get(uint64(4))); ok {
		info.Has[4] = true
		for _, e := range o.kv {
			if k, ok := e.K.(string); ok {
				info.Options = append(info.Options, ctapOption{k, e.V})
			}
		}
	}
	if a, ok := cborArr(m.get(uint64(6))); ok {
		info.Has[6] = true
		for _, e := range a {
			if p, ok := cborUint(e); ok {
				info.PinProtocols = append(info.PinProtocols, p)
			}
		}
	}
	switch n := m.get(uint64(0x14)).(type) {
	case uint64:
		if n <= math.MaxInt64 {
			info.Has[0x14] = true
			info.RemainingDiscoverable = int64(n)
		}
	}
	return info, nil
}

// fido2InfoLines is what the fido2-info bring-up verb prints after its device line. The versions, extensions,
// options and pinProtocols lines appear only when the answer carried that key; hmac-secret always does.
func fido2InfoLines(i *ctapInfo) []string {
	var out []string
	if i.Has[1] {
		out = append(out, "versions: "+strings.Join(i.Versions, " "))
	}
	if i.Has[2] {
		out = append(out, "extensions: "+strings.Join(i.Extensions, " "))
	}
	out = append(out, fmt.Sprintf("hmac-secret: %v", i.hasExtension("hmac-secret")))
	if i.Has[4] {
		var os []string
		for _, o := range i.Options {
			os = append(os, fmt.Sprintf("%s=%v", o.Name, o.Value))
		}
		out = append(out, "options: "+strings.Join(os, " "))
	}
	if i.Has[6] {
		out = append(out, fmt.Sprintf("pinProtocols: %v", i.PinProtocols))
	}
	return out
}

// enrollShapeRefusal says why a key cannot be enrolled whatever way its user is verified: no hmac-secret, or only
// a PIN/UV protocol this client does not speak. A field the key does not report NEVER refuses: an absent
// protocol list, an answer with no extensions key (a CTAP2.0 key) all fall through to the behaviour from before
// getInfo was consulted.
func enrollShapeRefusal(i *ctapInfo) error {
	if i.Has[2] && !i.hasExtension("hmac-secret") {
		return errors.New("this key has no hmac-secret extension, which a Nowhere key slot needs")
	}
	if len(i.PinProtocols) > 0 && !i.hasProtocol(1) {
		var ps []string
		for _, p := range i.PinProtocols {
			ps = append(ps, fmt.Sprint(p))
		}
		return fmt.Errorf("this key speaks only PIN/UV protocol(s) %s; this client speaks protocol 1", strings.Join(ps, ", "))
	}
	return nil
}

// errEnrollNeedsKeyPIN and errAssertNeedsKeyPIN name the alwaysUv key the gate cannot drive: one with no
// fingerprint enrolled needs its PIN, and the gate has no field for it yet.
var (
	errEnrollNeedsKeyPIN = errors.New("this key asks for user verification on every use (alwaysUv) and has no fingerprint enrolled, so it needs its PIN, which the gate cannot take yet")
	errAssertNeedsKeyPIN = errors.New("this slot needs the key's user verification, and the key has no fingerprint enrolled; its PIN cannot be taken at the gate yet")
)

// enrollRefusal is the refusal of an enrol that cannot verify the user -- the NFC tap 1, where a pinUvAuthToken
// would not survive the power cycle between the taps: the shape rules, then every alwaysUv key. The USB enrol
// (fido2EnrollOn) sends an alwaysUv key with built-in UV down its own path and calls only enrollShapeRefusal.
func enrollRefusal(i *ctapInfo) error {
	if err := enrollShapeRefusal(i); err != nil {
		return err
	}
	if v, ok := i.option("alwaysUv"); ok && v {
		return errors.New("this key asks for its PIN or fingerprint on every use (alwaysUv), which this client cannot supply over NFC")
	}
	return nil
}

// enrollMakeCredential is makeCredential behind the getInfo probe. A key that answers getInfo badly (an error, a
// status, a body that is not a map) enrols as it did before the probe; a key that reports it cannot work is
// refused before it is asked for a touch.
func enrollMakeCredential(h ctapTransport, rpID string) ([]byte, error) {
	if info, err := ctapGetInfo(h); err == nil {
		if err := enrollRefusal(info); err != nil {
			return nil, fmt.Errorf("enroll refused before the touch: %w", err)
		}
	}
	return makeCredential(h, rpID)
}

// ---- high-level enroll/assert over an opened key (used by the CLI + the login/enroll wiring) ----

// fido2KeyEnroll runs the full enroll against a plugged-in key: makeCredential (hmac-secret on) + a first
// getAssertion to capture HMAC(credKey, freshSalt). Returns the credId + salt to store in the vault slot, the
// hmac output that enrollFido2 wraps DK under, and the uv the enrol itself used -- the slot records it and every
// later sign-in must assert with the same one. Two touches (make, then assert).
func fido2KeyEnroll() (credID, salt, hmacOut []byte, uv bool, err error) {
	dev, err := findFidoHidraw()
	if err != nil {
		return nil, nil, nil, false, err
	}
	h, err := openCTAPHID(dev)
	if err != nil {
		return nil, nil, nil, false, err
	}
	defer h.Close()
	return fido2EnrollOn(h)
}

// fido2EnrollOn is the enroll over an opened key (see fido2KeyEnroll); it asks getInfo exactly once. A key that
// is not alwaysUv (or answers getInfo badly) takes the touch-only path, uv=false. An alwaysUv key with built-in
// UV enrols by its fingerprint: a fresh permMC token for makeCredential and a fresh permGA token for the first
// getAssertion (a token serves one command), uv=true. Any other alwaysUv key is refused before the touch.
func fido2EnrollOn(h ctapTransport) (credID, salt, hmacOut []byte, uv bool, err error) {
	info, ierr := ctapGetInfo(h)
	always := false
	if ierr == nil {
		always, _ = info.option("alwaysUv")
	}
	if !always {
		if ierr == nil {
			if rerr := enrollRefusal(info); rerr != nil {
				return nil, nil, nil, false, fmt.Errorf("enroll refused before the touch: %w", rerr)
			}
		}
		credID, err = makeCredential(h, nowhereRPID)
		if err != nil {
			return nil, nil, nil, false, err
		}
		salt = make([]byte, 32)
		rand.Read(salt)
		hmacOut, err = getAssertionHMAC(h, nowhereRPID, credID, salt)
		if err != nil {
			return nil, nil, nil, false, err
		}
		return credID, salt, hmacOut, false, nil
	}
	if serr := enrollShapeRefusal(info); serr != nil {
		return nil, nil, nil, false, fmt.Errorf("enroll refused before the touch: %w", serr)
	}
	if m, cerr := chooseUV(info); cerr != nil || m != uvBuiltIn {
		if cerr == nil {
			cerr = errEnrollNeedsKeyPIN
		}
		return nil, nil, nil, false, fmt.Errorf("enroll refused before the touch: %w", cerr)
	}
	mc, err := getPinUvAuthToken(h, info, nil, permMC, nowhereRPID)
	if err != nil {
		return nil, nil, nil, false, err
	}
	credID, err = makeCredentialTok(h, nowhereRPID, mc)
	if err != nil {
		return nil, nil, nil, false, err
	}
	salt = make([]byte, 32)
	rand.Read(salt)
	ga, err := getPinUvAuthToken(h, info, nil, permGA, nowhereRPID)
	if err != nil {
		return nil, nil, nil, false, err
	}
	hmacOut, err = getAssertionHMACTok(h, nowhereRPID, credID, salt, ga)
	if err != nil {
		return nil, nil, nil, false, err
	}
	return credID, salt, hmacOut, true, nil
}

// fido2AssertOn reproduces the hmac output for an enrolled (credId, salt) over an opened key. uv is the slot's
// recorded uv: false asserts without user verification (today's path, no getInfo); true needs the key's built-in
// UV and a fresh permGA token for this one assertion, and is refused before the touch for a key without it.
func fido2AssertOn(h ctapTransport, credID, salt []byte, uv bool) ([]byte, error) {
	if !uv {
		return getAssertionHMAC(h, nowhereRPID, credID, salt)
	}
	info, err := ctapGetInfo(h)
	if err != nil {
		return nil, fmt.Errorf("assert refused before the touch: %w", err)
	}
	if am, aerr := chooseUV(info); aerr != nil || am != uvBuiltIn {
		if aerr == nil {
			aerr = errAssertNeedsKeyPIN
		}
		return nil, fmt.Errorf("assert refused before the touch: %w", aerr)
	}
	tok, err := getPinUvAuthToken(h, info, nil, permGA, nowhereRPID)
	if err != nil {
		return nil, err
	}
	return getAssertionHMACTok(h, nowhereRPID, credID, salt, tok)
}

// fido2KeyAssert reproduces the hmac output for an enrolled (credId, salt) at login. uv is the slot's recorded
// uv. One touch (a fingerprint read is the touch).
func fido2KeyAssert(credID, salt []byte, uv bool) ([]byte, error) {
	dev, err := findFidoHidraw()
	if err != nil {
		return nil, err
	}
	h, err := openCTAPHID(dev)
	if err != nil {
		return nil, err
	}
	defer h.Close()
	return fido2AssertOn(h, credID, salt, uv)
}
