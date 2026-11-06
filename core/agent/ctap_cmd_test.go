package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"strings"
	"testing"
)

// NWP-20261022-07: the CTAP2 command layer (ctap_cmd.go) driven through a ctapTransport. simCTAP answers
// clientPIN, makeCredential and getAssertion the way a CTAP2.1 key does, on top of simAuthenticator
// (ctap_crypto_test.go), and logs every request so the cases can pin what was SENT: no options map on
// makeCredential, up:true and the stored credId under nowhere.mobile on getAssertion, and a 0x34 retried with
// a FRESH getKeyAgreement at most four times. test-ctap-cmd.sh --mutate breaks each rule in ctap_cmd.go.

type simCall struct {
	cmd    byte
	params *cborMap
}

type simCTAP struct {
	t           *testing.T
	auth        *simAuthenticator // priv is the CURRENT key-agreement key
	credID      []byte
	fail34      int           // scripted 0x34 answers left; each one rotates auth.priv
	status      map[byte]byte // forced answer per command byte
	noAT, noED  bool
	noHMACEntry bool
	info        *cborMap // scripted authenticatorGetInfo answer; nil = the key answers 0x01 (unsupported)
	infoRaw     []byte   // a getInfo body that is not a map, sent as is when set
	infoErr     error    // a transport error on getInfo
	calls       []simCall

	// NWP-20261025-07: user verification. All inert at their zero values.
	pin       string // the key's PIN; empty = none set
	builtinUV bool   // a fingerprint is enrolled: subCommand 0x06 works
	uvLocked  bool   // the fingerprint reader is locked: 0x06 answers UV_BLOCKED
	alwaysUv  bool   // makeCredential/getAssertion without a pinUvAuthParam are refused
	credKeyUV []byte // the credential's CredRandomWithUV; a UV assertion's hmac-secret keys off it
	tok       []byte // the last token minted, nil once used (valid for ONE command)
	tokPerms  uint64
	tokRP     string
	tokStatus byte // a forced status on the token subCommands only
	tokLen    int  // length of a minted token; 0 = 32
}

// The authenticator model's own copy of the CTAP2.1 permissions, independent of the client's permMC/permGA, so a
// wrong client constant is caught instead of changing both sides together.
const (
	simPermMC uint64 = 0x01
	simPermGA uint64 = 0x02
)

func newSimCTAP(t *testing.T) *simCTAP {
	t.Helper()
	id := make([]byte, 16)
	rand.Read(id)
	return &simCTAP{t: t, auth: newSimAuthenticator(t), credID: id, status: map[byte]byte{}}
}

func (s *simCTAP) Close() {}

func (s *simCTAP) rotate() {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		s.t.Fatal(err)
	}
	s.auth.priv = k
}

func (s *simCTAP) reply(v any) (byte, []byte, error) {
	b, err := cborEncode(v)
	if err != nil {
		s.t.Fatal(err)
	}
	return 0, b, nil
}

func (s *simCTAP) cbor(cmd byte, params []byte) (byte, []byte, error) {
	m := newCBORMap() // getInfo carries no params
	if len(params) > 0 || cmd != ctapCmdGetInfo {
		v, err := cborDecode(params)
		if err != nil {
			s.t.Fatalf("cmd 0x%02x: malformed request: %v", cmd, err)
		}
		var ok bool
		if m, ok = asCBORMap(v); !ok {
			s.t.Fatalf("cmd 0x%02x: request is not a map", cmd)
		}
	}
	s.calls = append(s.calls, simCall{cmd, m})
	if st, ok := s.status[cmd]; ok {
		return st, nil, nil
	}
	switch cmd {
	case ctapCmdGetInfo:
		switch {
		case s.infoErr != nil:
			return 0, nil, s.infoErr
		case s.infoRaw != nil:
			return 0, s.infoRaw, nil
		case s.info != nil:
			return s.reply(s.info)
		}
		return 0x01, nil, nil
	case ctapClientPIN:
		if m.get(uint64(1)) != uint64(1) {
			return 0x02, nil, nil
		}
		switch m.get(uint64(2)) {
		case uint64(2):
			return s.reply(newCBORMap().put(uint64(1), coseKeyAgreement(s.auth.priv.PublicKey())))
		case uint64(5), uint64(6), uint64(9):
			return s.tokenCmd(m)
		}
		return 0x02, nil, nil
	case ctapMakeCredential:
		return s.makeCredential(m)
	case ctapGetAssertion:
		return s.getAssertion(m)
	}
	return 0x01, nil, nil
}

// tokenCmd answers clientPIN subCommands 0x05 / 0x06 / 0x09 the way CTAP2.1 §6.5 does and mints a token.
func (s *simCTAP) tokenCmd(m *cborMap) (byte, []byte, error) {
	ka, _ := asCBORMap(m.get(uint64(3)))
	if ka == nil {
		return 0x02, nil, nil
	}
	platPub, err := parseCOSEKeyAgreement(ka)
	if err != nil {
		return 0x02, nil, nil
	}
	if s.tokStatus != 0 {
		return s.tokStatus, nil, nil
	}
	shared := s.auth.shared(s.t, platPub)
	sub := m.get(uint64(2))
	perms, _ := m.get(uint64(9)).(uint64)
	rp, _ := m.get(uint64(0x0a)).(string)
	if sub == uint64(6) {
		if s.uvLocked {
			return 0x3c, nil, nil
		}
		if !s.builtinUV {
			return 0x01, nil, nil
		}
	} else {
		if s.pin == "" {
			return 0x35, nil, nil
		}
		enc, _ := cborBytes(m.get(uint64(6)))
		want := sha256.Sum256([]byte(s.pin))
		if len(enc) != 16 || !bytes.Equal(aesCBCDec(s.t, shared, enc), want[:16]) {
			s.rotate() // a wrong PIN invalidates the key agreement
			return 0x31, nil, nil
		}
		if sub == uint64(5) { // CTAP2.0 getPinToken: every permission, no rpId
			perms, rp = simPermMC|simPermGA, ""
		}
	}
	if sub != uint64(5) && perms == 0 {
		return 0x02, nil, nil
	}
	n := s.tokLen
	if n == 0 {
		n = 32
	}
	s.tok = make([]byte, n)
	rand.Read(s.tok)
	s.tokPerms, s.tokRP = perms, rp
	return s.reply(newCBORMap().put(uint64(2), aesCBCEnc(s.t, shared, s.tok)))
}

// checkToken verifies a pinUvAuthParam (protocol 1) against the outstanding token, which it then forgets.
func (s *simCTAP) checkToken(param, proto any, cdh any, need uint64, rpID string) byte {
	tok := s.tok
	s.tok = nil
	h, _ := cdh.([]byte)
	p, _ := param.([]byte)
	mac := hmac.New(sha256.New, tok)
	mac.Write(h)
	if tok == nil || proto != uint64(1) || !hmac.Equal(mac.Sum(nil)[:16], p) {
		return 0x33
	}
	if s.tokPerms&need == 0 || (s.tokRP != "" && s.tokRP != rpID) {
		return 0x40
	}
	return 0
}

func (s *simCTAP) makeCredential(m *cborMap) (byte, []byte, error) {
	if m.get(uint64(7)) != nil {
		return 0x27, nil, nil // CTAP2.1: an explicit options map is refused
	}
	if param := m.get(uint64(8)); param != nil {
		rp, _ := asCBORMap(m.get(uint64(2)))
		id, _ := rp.get("id").(string)
		if st := s.checkToken(param, m.get(uint64(9)), m.get(uint64(1)), simPermMC, id); st != 0 {
			return st, nil, nil
		}
	} else if s.alwaysUv {
		return 0x27, nil, nil // measured on a YubiKey C Bio
	}
	rp, _ := asCBORMap(m.get(uint64(2)))
	algs, _ := cborArr(m.get(uint64(4)))
	ext, _ := asCBORMap(m.get(uint64(6)))
	if rp == nil || rp.get("id") != nowhereRPID || len(algs) != 1 || ext == nil || ext.get("hmac-secret") != true {
		return 0x02, nil, nil
	}
	if a, ok := asCBORMap(algs[0]); !ok || a.get("alg") != int64(-7) {
		return 0x02, nil, nil
	}
	ad := authData(0x01)
	if !s.noAT {
		cose := mustCBOR(s.t, coseKeyAgreement(s.auth.priv.PublicKey()))
		ad = authData(0x41, attHead(s.credID), cose)
	}
	return s.reply(newCBORMap().put(uint64(1), "none").put(uint64(2), ad).put(uint64(3), newCBORMap()))
}

func (s *simCTAP) getAssertion(m *cborMap) (byte, []byte, error) {
	rp, _ := m.get(uint64(1)).(string)
	tokenOK := false
	if m.get(uint64(6)) != nil { // the token is bound to the request's own RP, checked before anything else
		if st := s.checkToken(m.get(uint64(6)), m.get(uint64(7)), m.get(uint64(2)), simPermGA, rp); st != 0 {
			return st, nil, nil
		}
		tokenOK = true
	}
	if rp != nowhereRPID {
		return 0x02, nil, nil
	}
	list, _ := cborArr(m.get(uint64(3)))
	if len(list) == 0 {
		return 0x2e, nil, nil
	}
	entry, _ := asCBORMap(list[0])
	if entry == nil {
		return 0x2e, nil, nil
	}
	if id, _ := entry.get("id").([]byte); !bytes.Equal(id, s.credID) {
		return 0x2e, nil, nil
	}
	opts, _ := asCBORMap(m.get(uint64(5)))
	if opts == nil || opts.get("up") != true {
		return 0x3b, nil, nil
	}
	uvd := false
	if tokenOK {
		uvd = true
	} else if s.alwaysUv {
		return 0x36, nil, nil
	}
	if s.fail34 > 0 { // the NFC key dropped its state: only a fresh getKeyAgreement can succeed
		s.fail34--
		s.rotate()
		return 0x34, nil, nil
	}
	exts, _ := asCBORMap(m.get(uint64(4)))
	var hs *cborMap
	if exts != nil {
		hs, _ = asCBORMap(exts.get("hmac-secret"))
	}
	if hs == nil {
		return 0x02, nil, nil
	}
	ka, _ := asCBORMap(hs.get(uint64(1)))
	saltEnc, _ := cborBytes(hs.get(uint64(2)))
	saltAuth, _ := cborBytes(hs.get(uint64(3)))
	if ka == nil || len(saltEnc) != 32 {
		return 0x02, nil, nil
	}
	platPub, err := parseCOSEKeyAgreement(ka)
	if err != nil {
		return 0x02, nil, nil
	}
	shared := s.auth.shared(s.t, platPub)
	mac := hmac.New(sha256.New, shared)
	mac.Write(saltEnc)
	if !hmac.Equal(mac.Sum(nil)[:16], saltAuth) {
		return 0x34, nil, nil
	}
	credKey := s.auth.credKey
	if uvd {
		credKey = s.credKeyUV
	}
	out := hmac.New(sha256.New, credKey)
	out.Write(aesCBCDec(s.t, shared, saltEnc))
	encOut := aesCBCEnc(s.t, shared, out.Sum(nil))
	ad := authData(0x01)
	if !s.noED {
		ext := newCBORMap().put("hmac-secret", encOut)
		if s.noHMACEntry {
			ext = newCBORMap().put("other", true)
		}
		ad = authData(0x81, mustCBOR(s.t, ext))
	}
	return s.reply(newCBORMap().put(uint64(2), ad))
}

func (s *simCTAP) callsOf(cmd byte) []*cborMap {
	var out []*cborMap
	for _, c := range s.calls {
		if c.cmd == cmd {
			out = append(out, c.params)
		}
	}
	return out
}

func (s *simCTAP) count(cmd byte) int { return len(s.callsOf(cmd)) }

func (s *simCTAP) order() []byte {
	var o []byte
	for _, c := range s.calls {
		o = append(o, c.cmd)
	}
	return o
}

// want is HMAC(credKey, salt), computed independently of the sim's answer path.
func (s *simCTAP) want(salt []byte) []byte {
	m := hmac.New(sha256.New, s.auth.credKey)
	m.Write(salt)
	return m.Sum(nil)
}

func (s *simCTAP) enroll() []byte {
	s.t.Helper()
	id, err := makeCredential(s, nowhereRPID)
	if err != nil {
		s.t.Fatal(err)
	}
	return id
}

func wantErr(t *testing.T, err error, subs ...string) {
	t.Helper()
	if err == nil {
		t.Fatalf("want an error containing %q, got nil", subs)
	}
	for _, s := range subs {
		if !strings.Contains(err.Error(), s) {
			t.Fatalf("error %q lacks %q", err, s)
		}
	}
}

func TestCtapCmd_HmacSecretRoundTrip(t *testing.T) {
	s := newSimCTAP(t)
	id := s.enroll()
	if !bytes.Equal(id, s.credID) {
		t.Fatalf("credId = %x, want %x", id, s.credID)
	}
	salt := bytes.Repeat([]byte{7}, 32)
	got, err := getAssertionHMAC(s, nowhereRPID, id, salt)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, s.want(salt)) {
		t.Fatalf("output = %x, want HMAC(credKey, salt) = %x", got, s.want(salt))
	}
	s.rotate() // the key presents a different agreement key; the second call must follow it
	again, err := getAssertionHMAC(s, nowhereRPID, id, salt)
	if err != nil || !bytes.Equal(again, got) {
		t.Fatalf("second call = %x, %v; want %x", again, err, got)
	}
	other, err := getAssertionHMAC(s, nowhereRPID, id, bytes.Repeat([]byte{8}, 32))
	if err != nil || bytes.Equal(other, got) || len(other) != 32 {
		t.Fatalf("a different salt gave %x, %v", other, err)
	}
}

func TestCtapCmd_MakeCredentialRequestShape(t *testing.T) {
	s := newSimCTAP(t)
	s.enroll()
	if len(s.calls) != 1 || s.calls[0].cmd != ctapMakeCredential || s.count(ctapClientPIN) != 0 {
		t.Fatalf("calls = %x, want exactly one makeCredential and no clientPIN", s.order())
	}
	p := s.calls[0].params
	if p.get(uint64(7)) != nil {
		t.Error("makeCredential sent an options map (key 7): a CTAP2.1 key answers 0x27")
	}
	rp, _ := asCBORMap(p.get(uint64(2)))
	if rp == nil || rp.get("id") != "nowhere.mobile" {
		t.Errorf("rp = %v, want id nowhere.mobile", p.get(uint64(2)))
	}
	algs, _ := cborArr(p.get(uint64(4)))
	if len(algs) != 1 {
		t.Fatalf("pubKeyCredParams = %v", algs)
	}
	if a, _ := asCBORMap(algs[0]); a == nil || a.get("alg") != int64(-7) {
		t.Errorf("alg = %v, want -7", algs[0])
	}
	ext, _ := asCBORMap(p.get(uint64(6)))
	if ext == nil || ext.get("hmac-secret") != true {
		t.Errorf("extensions = %v, want hmac-secret true", p.get(uint64(6)))
	}
}

func TestCtapCmd_GetAssertionRequestShape(t *testing.T) {
	s := newSimCTAP(t)
	id := s.enroll()
	if _, err := getAssertionHMAC(s, nowhereRPID, id, make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	g := s.callsOf(ctapGetAssertion)
	if len(g) != 1 {
		t.Fatalf("getAssertion calls = %d", len(g))
	}
	p := g[0]
	if p.get(uint64(1)) != "nowhere.mobile" {
		t.Errorf("rpId = %v", p.get(uint64(1)))
	}
	list, _ := cborArr(p.get(uint64(3)))
	if len(list) != 1 {
		t.Fatalf("allowList = %v", list)
	}
	e, _ := asCBORMap(list[0])
	if e == nil {
		t.Fatalf("allowList[0] = %v", list[0])
	}
	if cid, _ := e.get("id").([]byte); !bytes.Equal(cid, id) || e.get("type") != "public-key" {
		t.Errorf("allowList[0] = %v, want the stored credId", list[0])
	}
	o, _ := asCBORMap(p.get(uint64(5)))
	if o == nil || o.get("up") != true {
		t.Errorf("options = %v, want up true", p.get(uint64(5)))
	}
}

func TestCtapCmd_Retry34FreshKeyAgreement(t *testing.T) {
	s := newSimCTAP(t)
	id := s.enroll()
	s.calls = nil
	s.fail34 = 2
	salt := bytes.Repeat([]byte{3}, 32)
	got, err := getAssertionHMAC(s, nowhereRPID, id, salt)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, s.want(salt)) {
		t.Fatalf("output = %x, want %x", got, s.want(salt))
	}
	if s.count(ctapClientPIN) != 3 || s.count(ctapGetAssertion) != 3 {
		t.Fatalf("clientPIN %d, getAssertion %d; want 3 and 3", s.count(ctapClientPIN), s.count(ctapGetAssertion))
	}
	if want := []byte{6, 2, 6, 2, 6, 2}; !bytes.Equal(s.order(), want) {
		t.Fatalf("order = %x, want %x (one getKeyAgreement per attempt)", s.order(), want)
	}
}

func TestCtapCmd_Retry34Bounded(t *testing.T) {
	s := newSimCTAP(t)
	id := s.enroll()
	s.calls = nil
	s.fail34 = 4
	_, err := getAssertionHMAC(s, nowhereRPID, id, make([]byte, 32))
	wantErr(t, err, "0x34", "after 4 attempts")
	if n := s.count(ctapGetAssertion); n != 4 {
		t.Fatalf("getAssertion calls = %d, want 4", n)
	}
}

func TestCtapCmd_OtherStatusNoRetry(t *testing.T) {
	for _, st := range []byte{0x2e, 0x3b} {
		s := newSimCTAP(t)
		id := s.enroll()
		s.status[ctapGetAssertion] = st
		_, err := getAssertionHMAC(s, nowhereRPID, id, make([]byte, 32))
		wantErr(t, err, "getAssertion", fmt.Sprintf("0x%02x", st))
		if n := s.count(ctapGetAssertion); n != 1 {
			t.Errorf("status 0x%02x: getAssertion calls = %d, want 1", st, n)
		}
	}
	s := newSimCTAP(t) // a credId the key does not hold answers 0x2e on its own
	s.enroll()
	_, err := getAssertionHMAC(s, nowhereRPID, []byte("unknown"), make([]byte, 32))
	wantErr(t, err, "0x2e")
	if n := s.count(ctapGetAssertion); n != 1 {
		t.Errorf("unknown credId: getAssertion calls = %d, want 1", n)
	}
}

func TestCtapCmd_KeyAgreementRefused(t *testing.T) {
	s := newSimCTAP(t)
	id := s.enroll()
	s.status[ctapClientPIN] = 0x31
	_, err := getAssertionHMAC(s, nowhereRPID, id, make([]byte, 32))
	wantErr(t, err, "getKeyAgreement", "0x31")
	if n := s.count(ctapGetAssertion); n != 0 {
		t.Errorf("getAssertion sent %d time(s) after a refused key agreement", n)
	}
}

func TestCtapCmd_ResponseRefusals(t *testing.T) {
	salt := make([]byte, 32)

	s := newSimCTAP(t)
	id := s.enroll()
	s.noED = true
	_, err := getAssertionHMAC(s, nowhereRPID, id, salt)
	wantErr(t, err, "no extensions")

	s = newSimCTAP(t)
	id = s.enroll()
	s.noHMACEntry = true
	_, err = getAssertionHMAC(s, nowhereRPID, id, salt)
	wantErr(t, err, "no hmac-secret output")

	s = newSimCTAP(t)
	s.noAT = true
	_, err = makeCredential(s, nowhereRPID)
	wantErr(t, err, "no credential id")

	s = newSimCTAP(t)
	s.status[ctapMakeCredential] = 0x27
	_, err = makeCredential(s, nowhereRPID)
	wantErr(t, err, "makeCredential", "0x27")
}
