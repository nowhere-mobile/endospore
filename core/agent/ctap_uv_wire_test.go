package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261025-08: built-in UV wired into the USB enrol (fido2EnrollOn), the assert (fido2AssertOn) and the slot
// loop (assertAnySlot), driven through simCTAP. test-ctap-uv-wire.sh --mutate breaks each rule in turn.

// wireTap is a transport that records every token the key mints (the sim forgets a token once it is used).
type wireTap struct {
	*simCTAP
	toks [][]byte
}

func (w *wireTap) cbor(cmd byte, p []byte) (byte, []byte, error) {
	st, b, err := w.simCTAP.cbor(cmd, p)
	// the token stays outstanding across the kA of the hmac-secret call, so record a token once
	if tok := w.simCTAP.tok; cmd == ctapClientPIN && st == 0 && err == nil && tok != nil &&
		(len(w.toks) == 0 || !bytes.Equal(w.toks[len(w.toks)-1], tok)) {
		w.toks = append(w.toks, append([]byte(nil), w.simCTAP.tok...))
	}
	return st, b, err
}

// wantUVOut is HMAC(credKeyUV, salt), computed independently of the sim's answer path.
func wantUVOut(s *simCTAP, salt []byte) []byte {
	m := hmac.New(sha256.New, s.credKeyUV)
	m.Write(salt)
	return m.Sum(nil)
}

// wireBioEnrol enrols a fresh bio key and returns the sim, the tap, the credId, the salt and the output.
func wireBioEnrol(t *testing.T) (*simCTAP, *wireTap, []byte, []byte, []byte) {
	t.Helper()
	s, _ := uvBio(t)
	w := &wireTap{simCTAP: s}
	id, salt, out, uv, err := fido2EnrollOn(w)
	if err != nil {
		t.Fatal(err)
	}
	if !uv {
		t.Fatal("a built-in-UV enrol returned uv=false: every later sign-in would assert without UV")
	}
	return s, w, id, salt, out
}

func wantTokenRequest(t *testing.T, s *simCTAP, idx int, perms uint64) {
	t.Helper()
	var reqs []*cborMap
	for _, p := range s.callsOf(ctapClientPIN) {
		if sub, _ := p.get(uint64(2)).(uint64); sub == cpGetTokenUsingUV {
			reqs = append(reqs, p)
		}
	}
	if idx >= len(reqs) {
		t.Fatalf("token request #%d missing; only %d sent", idx, len(reqs))
	}
	if reqs[idx].get(uint64(9)) != perms || reqs[idx].get(uint64(0x0a)) != nowhereRPID {
		t.Fatalf("token request #%d perms %v rpId %v, want %d %q", idx, reqs[idx].get(uint64(9)), reqs[idx].get(uint64(0x0a)), perms, nowhereRPID)
	}
}

func TestCtapUVWire_BioEnrolsWithBuiltInUV(t *testing.T) {
	s, w, id, salt, out := wireBioEnrol(t)
	if !bytes.Equal(id, s.credID) || len(salt) != 32 || !bytes.Equal(out, wantUVOut(s, salt)) {
		t.Fatalf("credId %x, salt %x, out %x; want the credId, 32 bytes, HMAC(credKeyUV, salt)", id, salt, out)
	}
	want := []byte{ctapCmdGetInfo, ctapClientPIN, ctapClientPIN, ctapMakeCredential,
		ctapClientPIN, ctapClientPIN, ctapClientPIN, ctapGetAssertion}
	if !bytes.Equal(s.order(), want) {
		t.Fatalf("command order %x, want %x", s.order(), want)
	}
	subs := s.clientPINSubs()
	if len(subs) != 2 || subs[0] != cpGetTokenUsingUV || subs[1] != cpGetTokenUsingUV {
		t.Fatalf("token subCommands = %v, want two 0x%02x and no 0x05/0x09", subs, cpGetTokenUsingUV)
	}
	wantTokenRequest(t, s, 0, simPermMC)
	wantTokenRequest(t, s, 1, simPermGA)
	if len(w.toks) != 2 || bytes.Equal(w.toks[0], w.toks[1]) {
		t.Fatalf("minted %d token(s); the enrol needs two different ones", len(w.toks))
	}
}

func TestCtapUVWire_BioAssertNeedsTheRecordedUV(t *testing.T) {
	s, w, id, salt, out := wireBioEnrol(t)
	s.calls, w.toks = nil, nil
	got, err := fido2AssertOn(w, id, salt, true)
	if err != nil || !bytes.Equal(got, out) {
		t.Fatalf("uv=true assert: %x, %v; want the enrol's output", got, err)
	}
	want := []byte{ctapCmdGetInfo, ctapClientPIN, ctapClientPIN, ctapClientPIN, ctapGetAssertion}
	if !bytes.Equal(s.order(), want) {
		t.Fatalf("command order %x, want %x", s.order(), want)
	}
	wantTokenRequest(t, s, 0, simPermGA)
	if got, err = fido2AssertOn(w, id, salt, true); err != nil || !bytes.Equal(got, out) {
		t.Fatalf("second uv=true assert: %x, %v", got, err)
	}
	if len(w.toks) != 2 || bytes.Equal(w.toks[0], w.toks[1]) {
		t.Fatalf("minted %d token(s) for two assertions; each needs its own fresh one", len(w.toks))
	}
	if _, err := fido2AssertOn(w, id, salt, false); err == nil || !strings.Contains(err.Error(), "0x36") {
		t.Fatalf("uv=false assert on an alwaysUv key: %v, want 0x36: a slot recorded uv=false could never open it", err)
	}
}

func TestCtapUVWire_PINOnlyKeyRefusedByName(t *testing.T) {
	s, _ := uvPINSim(t, true)
	id, salt, out, uv, err := fido2EnrollOn(s)
	wantErr(t, err, "enroll refused before the touch", "PIN")
	if id != nil || salt != nil || out != nil || uv {
		t.Fatal("a refused enrol returned key material")
	}
	if want := []byte{ctapCmdGetInfo}; !bytes.Equal(s.order(), want) {
		t.Fatalf("command order %x, want getInfo only", s.order())
	}

	s, _ = uvPINSim(t, true)
	_, err = fido2AssertOn(s, []byte("credential-id"), make([]byte, 32), true)
	wantErr(t, err, "assert refused before the touch", "PIN")
	if s.count(ctapGetAssertion) != 0 || len(s.clientPINSubs()) != 0 {
		t.Fatalf("command order %x, want getInfo only", s.order())
	}
	if !errors.Is(err, errAssertNeedsKeyPIN) {
		t.Fatalf("assert refusal %v does not wrap errAssertNeedsKeyPIN", err)
	}
}

func TestCtapUVWire_Ctap20KeyTakesTodaysPath(t *testing.T) {
	s := infoSim(t, ctap20Info())
	id, salt, out, uv, err := fido2EnrollOn(s)
	if err != nil || uv {
		t.Fatalf("enrol: uv=%v, %v; want uv=false", uv, err)
	}
	if !bytes.Equal(id, s.credID) || !bytes.Equal(out, s.want(salt)) {
		t.Fatalf("credId %x out %x", id, out)
	}
	want := []byte{ctapCmdGetInfo, ctapMakeCredential, ctapClientPIN, ctapGetAssertion}
	if !bytes.Equal(s.order(), want) || s.count(ctapCmdGetInfo) != 1 {
		t.Fatalf("command order %x, want %x with one getInfo", s.order(), want)
	}
	if len(s.clientPINSubs()) != 0 {
		t.Fatalf("token subCommands %v on a key that is not alwaysUv", s.clientPINSubs())
	}

	s.calls = nil
	got, err := fido2AssertOn(s, id, salt, false)
	if err != nil || !bytes.Equal(got, out) {
		t.Fatalf("uv=false assert: %x, %v", got, err)
	}
	if want := []byte{ctapClientPIN, ctapGetAssertion}; !bytes.Equal(s.order(), want) {
		t.Fatalf("uv=false assert order %x, want %x (no getInfo)", s.order(), want)
	}

	s = newSimCTAP(t) // a key that does not answer getInfo enrols as before
	_, _, _, uv, err = fido2EnrollOn(s)
	if err != nil || uv {
		t.Fatalf("no-getInfo enrol: uv=%v, %v", uv, err)
	}
	if want := []byte{ctapCmdGetInfo, ctapMakeCredential, ctapClientPIN, ctapGetAssertion}; !bytes.Equal(s.order(), want) {
		t.Fatalf("no-getInfo order %x, want %x", s.order(), want)
	}
}

func TestCtapUVWire_AssertAnySlotPassesEachSlotsUV(t *testing.T) {
	orig := fido2KeyAssertFn
	t.Cleanup(func() { fido2KeyAssertFn = orig })
	var seen []bool
	fido2KeyAssertFn = func(credID, salt []byte, uv bool) ([]byte, error) {
		seen = append(seen, uv)
		return nil, errors.New("stub: no key")
	}
	b64 := func(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
	slots := []fido2SlotInfo{
		{CredID: b64([]byte("cred-one")), Salt: b64(make([]byte, 32)), UV: true},
		{CredID: b64([]byte("cred-two")), Salt: b64(make([]byte, 32)), UV: false},
	}
	if _, err := assertAnySlot(slots); err == nil {
		t.Fatal("stubbed assertions all failed, assertAnySlot returned no error")
	}
	if len(seen) != 2 || !seen[0] || seen[1] {
		t.Fatalf("assertions ran with uv = %v, want [true false]", seen)
	}
}

func TestCtapUVWire_EnrollArmPassesTheEnrolsUV(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(src)
	start := strings.Index(text, `case "fido2-enroll":`)
	if start < 0 {
		t.Fatal(`main.go has no case "fido2-enroll":`)
	}
	arm := text[start:]
	if end := strings.Index(arm[1:], "\n\tcase \""); end >= 0 {
		arm = arm[:end+1]
	} else {
		t.Fatal("the fido2-enroll arm has no following case")
	}
	if !strings.Contains(arm, "enrollFido2(") {
		t.Fatal("control failed: the fido2-enroll arm does not call enrollFido2(")
	}
	if !regexp.MustCompile(`EncodeToString\(h\),\s*uv,\s*"usb"`).MatchString(arm) {
		t.Error("the fido2-enroll arm does not pass the enrol's uv to enrollFido2")
	}
	if regexp.MustCompile(`EncodeToString\(h\),\s*false,`).MatchString(arm) {
		t.Error("the fido2-enroll arm records a literal false: a built-in-UV slot would be asserted without UV")
	}
}

// uvWireSlots stubs fido2KeyAssertFn with answer (called with the 0-based call number) over three slots and returns
// what assertAnySlot returned and how many slots it asked.
func uvWireSlots(t *testing.T, answer func(call int) ([]byte, error)) ([]byte, error, int) {
	t.Helper()
	orig := fido2KeyAssertFn
	t.Cleanup(func() { fido2KeyAssertFn = orig })
	calls := 0
	fido2KeyAssertFn = func(credID, salt []byte, uv bool) ([]byte, error) {
		calls++
		return answer(calls - 1)
	}
	b64 := func(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
	var slots []fido2SlotInfo
	for _, c := range []string{"cred-one", "cred-two", "cred-three"} {
		slots = append(slots, fido2SlotInfo{CredID: b64([]byte(c)), Salt: b64(make([]byte, 32))})
	}
	h, err := assertAnySlot(slots)
	return h, err, calls
}

// NWP-20261113-09: a dead USB link is a property of the port, so the next slot is not asked.
func TestCtapUVWire_AssertAnySlotStopsAtADeadLink(t *testing.T) {
	dead := &hidLinkError{errors.New("stub: hidraw read")}
	_, err, calls := uvWireSlots(t, func(int) ([]byte, error) { return nil, dead })
	var le *hidLinkError
	if calls != 1 || !errors.As(err, &le) || le != dead {
		t.Fatalf("%d slot(s) asked, error %v; want 1 and the link error", calls, err)
	}
}

// NWP-20261113-09: no key on the port is not something the next slot can change either.
func TestCtapUVWire_AssertAnySlotStopsWhenNoKeyIsPlugged(t *testing.T) {
	_, err, calls := uvWireSlots(t, func(int) ([]byte, error) { return nil, fmt.Errorf("x: %w", errNoFidoHidraw) })
	if calls != 1 || !errors.Is(err, errNoFidoHidraw) {
		t.Fatalf("%d slot(s) asked, error %v; want 1 and errNoFidoHidraw", calls, err)
	}
}

// NWP-20261113-09, the control: a CTAP-level rejection (that credential is not on this key) still reaches the next key.
func TestCtapUVWire_AssertAnySlotTriesTheNextSlotAfterARejection(t *testing.T) {
	want := []byte("slot-two-hmac")
	h, err, calls := uvWireSlots(t, func(call int) ([]byte, error) {
		if call == 0 {
			return nil, errors.New("getAssertion: CTAP2 status 0x2e")
		}
		return want, nil
	})
	if calls != 2 || err != nil || !bytes.Equal(h, want) {
		t.Fatalf("%d slot(s) asked, hmac %q, error %v; want 2, %q, nil", calls, h, err, want)
	}
}
