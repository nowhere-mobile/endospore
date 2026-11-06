package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// NWP-20261025-07: the CTAP2 user-verification token (ctap_uv.go) and pinUvAuthParam on makeCredential /
// getAssertion (ctap_cmd.go), driven against simCTAP. test-ctap-uv.sh --mutate breaks each rule in turn.

const uvTestPIN = "481516"

// uvSim is a sim answering info, with a UV-side credential key, and the key's info decoded the production way.
func uvSim(t *testing.T, info *cborMap) (*simCTAP, *ctapInfo) {
	t.Helper()
	s := newSimCTAP(t)
	s.info = info
	s.credKeyUV = make([]byte, 32)
	rand.Read(s.credKeyUV)
	i, err := ctapGetInfo(s)
	if err != nil {
		t.Fatal(err)
	}
	s.calls = nil
	return s, i
}

// uvBio is a YubiKey C Bio with a fingerprint enrolled and a PIN set too.
func uvBio(t *testing.T) (*simCTAP, *ctapInfo) {
	s, i := uvSim(t, bioInfo())
	s.alwaysUv, s.builtinUV, s.pin = true, true, uvTestPIN
	return s, i
}

func uvPINInfo(tokenOpt bool) *cborMap {
	return newCBORMap().
		put(uint64(1), strs("FIDO_2_0", "FIDO_2_1")).
		put(uint64(2), strs("hmac-secret")).
		put(uint64(4), newCBORMap().put("alwaysUv", true).put("clientPin", true).put("pinUvAuthToken", tokenOpt).
			put("makeCredUvNotRqd", false)).
		put(uint64(6), []any{uint64(1)})
}

// uvPINSim is a key with no fingerprint and a PIN set.
func uvPINSim(t *testing.T, tokenOpt bool) (*simCTAP, *ctapInfo) {
	s, i := uvSim(t, uvPINInfo(tokenOpt))
	s.alwaysUv, s.pin = true, uvTestPIN
	return s, i
}

func uvPINFn(pin string) (func() (string, error), *int) {
	n := 0
	return func() (string, error) { n++; return pin, nil }, &n
}

func (s *simCTAP) clientPINSubs() []uint64 {
	var out []uint64
	for _, p := range s.callsOf(ctapClientPIN) {
		if sub, _ := p.get(uint64(2)).(uint64); sub != 2 { // 2 = getKeyAgreement
			out = append(out, sub)
		}
	}
	return out
}

// noPIN fails when the PIN is in an error's text or in any request the key was sent.
func noPIN(t *testing.T, s *simCTAP, pin string, errs ...error) {
	t.Helper()
	for _, e := range errs {
		if e != nil && strings.Contains(e.Error(), pin) {
			t.Errorf("error %q carries the PIN", e)
		}
	}
	for _, c := range s.calls {
		if bytes.Contains(mustCBOR(t, c.params), []byte(pin)) {
			t.Errorf("request 0x%02x carries the PIN in the clear", c.cmd)
		}
	}
}

func TestCtapUV_BioKeyUsesBuiltInUV(t *testing.T) {
	s, i := uvBio(t)
	pin, n := uvPINFn(uvTestPIN)
	tok, err := getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
	if err != nil {
		t.Fatal(err)
	}
	if *n != 0 {
		t.Errorf("the PIN was asked for %d time(s) on a key with built-in UV", *n)
	}
	if subs := s.clientPINSubs(); len(subs) != 1 || subs[0] != cpGetTokenUsingUV {
		t.Fatalf("token subCommands = %v, want [0x%02x] only", subs, cpGetTokenUsingUV)
	}
	req := s.callsOf(ctapClientPIN)[1]
	if req.get(uint64(9)) != permMC || req.get(uint64(0x0a)) != nowhereRPID || req.get(uint64(6)) != nil {
		t.Errorf("request perms %v rpId %v pinHashEnc %v", req.get(uint64(9)), req.get(uint64(0x0a)), req.get(uint64(6)))
	}
	s.calls = nil
	if _, err := makeCredentialTok(s, nowhereRPID, tok); err != nil {
		t.Fatal(err)
	}
	mc := s.callsOf(ctapMakeCredential)
	if p, _ := mc[0].get(uint64(8)).([]byte); len(p) != 16 || mc[0].get(uint64(9)) != uint64(1) {
		t.Errorf("makeCredential carries pinUvAuthParam %x protocol %v", mc[0].get(uint64(8)), mc[0].get(uint64(9)))
	}
}

func TestCtapUV_BuiltInUVWithoutTokenOptionNeverTakesPIN(t *testing.T) {
	info := newCBORMap().
		put(uint64(1), strs("FIDO_2_0")).
		put(uint64(2), strs("hmac-secret")).
		put(uint64(4), newCBORMap().put("uv", true).put("clientPin", true)).
		put(uint64(6), []any{uint64(1)})
	s, i := uvSim(t, info)
	s.alwaysUv, s.builtinUV, s.pin = true, true, uvTestPIN
	pin, n := uvPINFn(uvTestPIN)
	_, err := getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
	if !errors.Is(err, errBuiltInUVUnsupported) {
		t.Fatalf("err = %v, want errBuiltInUVUnsupported", err)
	}
	if *n != 0 || len(s.clientPINSubs()) != 0 {
		t.Errorf("pin asked %d time(s), token subCommands %v", *n, s.clientPINSubs())
	}
}

func TestCtapUV_PINOnlyKey(t *testing.T) {
	s, i := uvPINSim(t, true)
	pin, n := uvPINFn(uvTestPIN)
	tok, err := getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
	if err != nil {
		t.Fatal(err)
	}
	if *n != 1 {
		t.Errorf("the PIN was asked for %d time(s), want 1", *n)
	}
	if subs := s.clientPINSubs(); len(subs) != 1 || subs[0] != cpGetTokenUsingPIN {
		t.Fatalf("token subCommands = %v, want [0x%02x]", subs, cpGetTokenUsingPIN)
	}
	req := s.callsOf(ctapClientPIN)[1]
	if h, _ := req.get(uint64(6)).([]byte); len(h) != 16 || req.get(uint64(9)) != permMC || req.get(uint64(0x0a)) != nowhereRPID {
		t.Errorf("request pinHashEnc %x perms %v rpId %v", req.get(uint64(6)), req.get(uint64(9)), req.get(uint64(0x0a)))
	}
	if _, err := makeCredentialTok(s, nowhereRPID, tok); err != nil {
		t.Fatal(err)
	}
	noPIN(t, s, uvTestPIN)
}

func TestCtapUV_PINOnlyKeyWithoutTokenOption(t *testing.T) {
	s, i := uvPINSim(t, false)
	pin, _ := uvPINFn(uvTestPIN)
	tok, err := getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
	if err != nil {
		t.Fatal(err)
	}
	if subs := s.clientPINSubs(); len(subs) != 1 || subs[0] != cpGetPinToken {
		t.Fatalf("token subCommands = %v, want [0x%02x]", subs, cpGetPinToken)
	}
	req := s.callsOf(ctapClientPIN)[1]
	if req.get(uint64(9)) != nil || req.get(uint64(0x0a)) != nil || req.get(uint64(6)) == nil {
		t.Errorf("a CTAP2.0 getPinToken must carry the PIN hash and no permissions or rpId: %v", req)
	}
	if _, err := makeCredentialTok(s, nowhereRPID, tok); err != nil {
		t.Fatal(err)
	}
}

func TestCtapUV_NilPINFuncIsRefusedBeforeAnyCommand(t *testing.T) {
	s, i := uvPINSim(t, true)
	_, err := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
	if !errors.Is(err, errKeyPINNeeded) {
		t.Fatalf("err = %v, want errKeyPINNeeded", err)
	}
	if len(s.calls) != 0 {
		t.Errorf("%x sent before the refusal", s.order())
	}
}

func TestCtapUV_NoUserVerificationIsRefusedBeforeAnyCommand(t *testing.T) {
	info := newCBORMap().
		put(uint64(1), strs("FIDO_2_1")).
		put(uint64(4), newCBORMap().put("alwaysUv", true).put("uv", false).put("clientPin", false).put("pinUvAuthToken", true)).
		put(uint64(6), []any{uint64(1)})
	s, i := uvSim(t, info)
	pin, n := uvPINFn(uvTestPIN)
	_, err := getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
	if !errors.Is(err, errNoUserVerification) {
		t.Fatalf("err = %v, want errNoUserVerification", err)
	}
	if len(s.calls) != 0 || *n != 0 {
		t.Errorf("%x sent, pin asked %d time(s)", s.order(), *n)
	}
}

func TestCtapUV_WrongPINNamesTheStatusNotThePIN(t *testing.T) {
	s, i := uvPINSim(t, true)
	s.pin = "907263"
	pin, _ := uvPINFn(uvTestPIN) // the user types the wrong one
	_, err := getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
	wantErr(t, err, "PIN_INVALID", "0x31")
	noPIN(t, s, uvTestPIN, err)
	noPIN(t, s, s.pin, err)
}

func TestCtapUV_LockedFingerprintNeverFallsBackToPIN(t *testing.T) {
	s, i := uvBio(t)
	s.uvLocked = true
	pin, n := uvPINFn(uvTestPIN)
	_, err := getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
	if !errors.Is(err, errUVBlocked) {
		t.Fatalf("err = %v, want errUVBlocked", err)
	}
	wantErr(t, err, "UV_BLOCKED")
	if *n != 0 {
		t.Errorf("the PIN was asked for %d time(s) after a locked fingerprint", *n)
	}
	if subs := s.clientPINSubs(); len(subs) != 1 || subs[0] != cpGetTokenUsingUV {
		t.Errorf("token subCommands = %v, want only [0x%02x]", subs, cpGetTokenUsingUV)
	}
}

func TestCtapUV_StatusesAreNamed(t *testing.T) {
	names := map[byte]string{
		0x31: "PIN_INVALID", 0x32: "PIN_BLOCKED", 0x34: "PIN_AUTH_BLOCKED", 0x35: "PIN_NOT_SET",
		0x36: "PUAT_REQUIRED", 0x3c: "UV_BLOCKED", 0x3f: "UV_INVALID", 0x40: "UNAUTHORIZED_PERMISSION",
	}
	for st, name := range names {
		s, i := uvBio(t)
		s.tokStatus = st
		_, err := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
		wantErr(t, err, name)
		s, i = uvPINSim(t, true)
		s.tokStatus = st
		pin, _ := uvPINFn(uvTestPIN)
		_, err = getPinUvAuthToken(s, i, pin, permMC, nowhereRPID)
		wantErr(t, err, name)
		noPIN(t, s, uvTestPIN, err)
	}
}

func TestCtapUV_TokenLengthIsChecked(t *testing.T) {
	for _, n := range []int{16, 32} {
		s, i := uvBio(t)
		s.tokLen = n
		if _, err := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID); err != nil {
			t.Errorf("a %d-byte token: %v", n, err)
		}
	}
	for _, n := range []int{48, 64} {
		s, i := uvBio(t)
		s.tokLen = n
		_, err := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
		wantErr(t, err, "pinUvAuthToken is")
	}
}

func TestCtapUV_UVAssertionUsesCredRandomWithUV(t *testing.T) {
	s, i := uvBio(t)
	mc, err := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
	if err != nil {
		t.Fatal(err)
	}
	id, err := makeCredentialTok(s, nowhereRPID, mc)
	if err != nil {
		t.Fatal(err)
	}
	salt := bytes.Repeat([]byte{5}, 32)
	wantUV := hmac.New(sha256.New, s.credKeyUV)
	wantUV.Write(salt)
	var outs [][]byte
	for k := 0; k < 2; k++ {
		ga, err := getPinUvAuthToken(s, i, nil, permGA, nowhereRPID)
		if err != nil {
			t.Fatal(err)
		}
		s.calls = nil
		got, err := getAssertionHMACTok(s, nowhereRPID, id, salt, ga)
		if err != nil {
			t.Fatal(err)
		}
		outs = append(outs, got)
		p := s.callsOf(ctapGetAssertion)[0]
		if b, _ := p.get(uint64(6)).([]byte); len(b) != 16 || p.get(uint64(7)) != uint64(1) {
			t.Errorf("getAssertion carries pinUvAuthParam %x protocol %v", p.get(uint64(6)), p.get(uint64(7)))
		}
	}
	if !bytes.Equal(outs[0], wantUV.Sum(nil)) || !bytes.Equal(outs[0], outs[1]) {
		t.Fatalf("UV outputs %x / %x, want HMAC(credKeyUV, salt) = %x both times", outs[0], outs[1], wantUV.Sum(nil))
	}
	_, err = getAssertionHMACTok(s, nowhereRPID, id, salt, nil)
	wantErr(t, err, "0x36")
	s.alwaysUv = false
	plain, err := getAssertionHMAC(s, nowhereRPID, id, salt)
	if err != nil || !bytes.Equal(plain, s.want(salt)) || bytes.Equal(plain, outs[0]) {
		t.Fatalf("no-token output %x, %v: want HMAC(credKey, salt) %x, different from the UV one", plain, err, s.want(salt))
	}
}

func TestCtapUV_TokenAssertionNot34Retried(t *testing.T) {
	s, i := uvBio(t)
	mc, _ := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
	id, err := makeCredentialTok(s, nowhereRPID, mc)
	if err != nil {
		t.Fatal(err)
	}
	ga, err := getPinUvAuthToken(s, i, nil, permGA, nowhereRPID)
	if err != nil {
		t.Fatal(err)
	}
	s.calls = nil
	s.fail34 = 1
	_, err = getAssertionHMACTok(s, nowhereRPID, id, make([]byte, 32), ga)
	wantErr(t, err, "0x34", "not retried")
	if n := s.count(ctapGetAssertion); n != 1 {
		t.Errorf("getAssertion sent %d times, want 1", n)
	}
}

func TestCtapUV_PermissionsAreCheckedPerCommand(t *testing.T) {
	s, i := uvBio(t)
	mc, _ := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
	id, err := makeCredentialTok(s, nowhereRPID, mc)
	if err != nil {
		t.Fatal(err)
	}
	wrong, _ := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
	_, err = getAssertionHMACTok(s, nowhereRPID, id, make([]byte, 32), wrong)
	wantErr(t, err, "0x40")
	again, _ := getPinUvAuthToken(s, i, nil, permGA, nowhereRPID)
	if _, err := getAssertionHMACTok(s, nowhereRPID, id, make([]byte, 32), again); err != nil {
		t.Fatal(err)
	}
	_, err = getAssertionHMACTok(s, nowhereRPID, id, make([]byte, 32), again)
	wantErr(t, err, "0x33") // one token, one command
}

func TestCtapUV_PINCallbackErrorNeverCarriesThePIN(t *testing.T) {
	s, i := uvPINSim(t, true)
	cb := func() (string, error) { return uvTestPIN, fmt.Errorf("rejected %s", uvTestPIN) }
	_, err := getPinUvAuthToken(s, i, cb, permMC, nowhereRPID)
	if !errors.Is(err, errKeyPINUnavailable) {
		t.Fatalf("got %v, want errKeyPINUnavailable", err)
	}
	noPIN(t, s, uvTestPIN, err)
	if n := len(s.clientPINSubs()); n != 0 {
		t.Errorf("%d token subcommand(s) sent after the PIN callback failed", n)
	}
}

func TestCtapUV_TokenIsBoundToTheRequestsRP(t *testing.T) {
	s, i := uvBio(t)
	mc, _ := getPinUvAuthToken(s, i, nil, permMC, nowhereRPID)
	id, err := makeCredentialTok(s, nowhereRPID, mc)
	if err != nil {
		t.Fatal(err)
	}
	other, _ := getPinUvAuthToken(s, i, nil, permGA, "other.example")
	_, err = getAssertionHMACTok(s, nowhereRPID, id, make([]byte, 32), other)
	wantErr(t, err, "0x40") // minted for another RP
	right, _ := getPinUvAuthToken(s, i, nil, permGA, nowhereRPID)
	if _, err := getAssertionHMACTok(s, nowhereRPID, id, make([]byte, 32), right); err != nil {
		t.Fatalf("a token for the request's own RP was refused: %v", err)
	}
	// a request for another RP is judged against that RP: its own token passes the binding
	// check and reaches the RP check (0x02), where the nowhere token is refused first
	onOther, _ := getPinUvAuthToken(s, i, nil, permGA, "other.example")
	_, err = getAssertionHMACTok(s, "other.example", id, make([]byte, 32), onOther)
	wantErr(t, err, "0x02")
}
