package main

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// NWP-20261022-09: the authenticatorGetInfo probe (ctapGetInfo, enrollRefusal, enrollMakeCredential) driven through
// simCTAP with a scripted getInfo answer. Both enrol paths ask the key what it can do BEFORE the first touch: the
// call logs below pin that no makeCredential is sent to a key that cannot work. test-ctap-getinfo.sh --mutate
// breaks each rule in ctap_cmd.go and fido2_nfc.go.

func strs(ss ...string) []any {
	var out []any
	for _, s := range ss {
		out = append(out, s)
	}
	return out
}

// bioInfo is the answer a YubiKey C Bio gives (alwaysUv, docs/fido2-key-only-login.md §6).
func bioInfo() *cborMap {
	return newCBORMap().
		put(uint64(1), strs("U2F_V2", "FIDO_2_0", "FIDO_2_1_PRE", "FIDO_2_1")).
		put(uint64(2), strs("hmac-secret", "credProtect", "credBlob", "minPinLength")).
		put(uint64(4), newCBORMap().put("rk", true).put("up", true).put("uv", true).put("alwaysUv", true).
			put("credMgmt", true).put("bioEnroll", true).put("clientPin", true).put("pinUvAuthToken", true).
			put("makeCredUvNotRqd", false)).
		put(uint64(6), []any{uint64(2), uint64(1)}).
		put(uint64(0x14), uint64(25))
}

// ctap20Info is a CTAP2.0-shaped answer: no pinUvAuthProtocols, no remaining-discoverable count.
func ctap20Info() *cborMap {
	return newCBORMap().
		put(uint64(1), strs("FIDO_2_0")).
		put(uint64(2), strs("hmac-secret")).
		put(uint64(4), newCBORMap().put("rk", true).put("up", true).put("plat", false))
}

func infoSim(t *testing.T, info *cborMap) *simCTAP {
	s := newSimCTAP(t)
	s.info = info
	return s
}

func wantNoMakeCredential(t *testing.T, s *simCTAP) {
	t.Helper()
	if n := s.count(ctapMakeCredential); n != 0 {
		t.Fatalf("makeCredential was sent %d time(s); calls = %x", n, s.order())
	}
}

func TestCtapGetInfo_BioKeyRefusedByName(t *testing.T) {
	s := infoSim(t, bioInfo())
	id, err := enrollMakeCredential(s, nowhereRPID)
	wantErr(t, err, "enroll refused before the touch", "alwaysUv")
	if id != nil {
		t.Fatalf("credId = %x, want none", id)
	}
	if want := []byte{ctapCmdGetInfo}; !bytes.Equal(s.order(), want) {
		t.Fatalf("calls = %x, want getInfo only", s.order())
	}
}

func TestCtapGetInfo_NoHmacSecretRefused(t *testing.T) {
	s := infoSim(t, newCBORMap().put(uint64(2), strs("credProtect")))
	_, err := enrollMakeCredential(s, nowhereRPID)
	wantErr(t, err, "enroll refused before the touch", "hmac-secret")
	wantNoMakeCredential(t, s)
}

func TestCtapGetInfo_ProtocolRefusal(t *testing.T) {
	two := func(protos ...any) *cborMap {
		return newCBORMap().put(uint64(2), strs("hmac-secret")).put(uint64(6), protos)
	}
	s := infoSim(t, two(uint64(2)))
	_, err := enrollMakeCredential(s, nowhereRPID)
	wantErr(t, err, "enroll refused before the touch", "protocol(s) 2;")
	wantNoMakeCredential(t, s)

	s = infoSim(t, two(uint64(2), uint64(1)))
	id, err := enrollMakeCredential(s, nowhereRPID)
	if err != nil || !bytes.Equal(id, s.credID) {
		t.Fatalf("protocols [2 1]: %x, %v; want the credId", id, err)
	}
}

func TestCtapGetInfo_Ctap20ProceedsToMakeCredential(t *testing.T) {
	s := infoSim(t, ctap20Info())
	id, err := enrollMakeCredential(s, nowhereRPID)
	if err != nil || !bytes.Equal(id, s.credID) {
		t.Fatalf("got %x, %v; want the credId", id, err)
	}
	if want := []byte{ctapCmdGetInfo, ctapMakeCredential}; !bytes.Equal(s.order(), want) {
		t.Fatalf("calls = %x, want getInfo then makeCredential", s.order())
	}
}

func TestCtapGetInfo_BadAnswerFailsOpen(t *testing.T) {
	for name, arm := range map[string]func(*simCTAP){
		"status 0x01":  func(s *simCTAP) { s.status[ctapCmdGetInfo] = 0x01 },
		"transport":    func(s *simCTAP) { s.infoErr = errors.New("link down") },
		"not a map":    func(s *simCTAP) { s.infoRaw = mustCBOR(t, []any{uint64(1)}) },
		"unscripted":   func(s *simCTAP) {},
		"undecodeable": func(s *simCTAP) { s.infoRaw = []byte{0xff} },
	} {
		s := newSimCTAP(t)
		arm(s)
		id, err := enrollMakeCredential(s, nowhereRPID)
		if err != nil || !bytes.Equal(id, s.credID) {
			t.Errorf("%s: got %x, %v; want the credId", name, id, err)
		}
		if n := s.count(ctapMakeCredential); n != 1 {
			t.Errorf("%s: makeCredential sent %d time(s), want 1", name, n)
		}
	}
}

func TestCtapGetInfo_Decode(t *testing.T) {
	s := infoSim(t, bioInfo())
	i, err := ctapGetInfo(s)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"U2F_V2", "FIDO_2_0", "FIDO_2_1_PRE", "FIDO_2_1"}; !reflect.DeepEqual(i.Versions, want) {
		t.Errorf("versions = %v", i.Versions)
	}
	if want := []string{"hmac-secret", "credProtect", "credBlob", "minPinLength"}; !reflect.DeepEqual(i.Extensions, want) {
		t.Errorf("extensions = %v", i.Extensions)
	}
	if len(i.Options) != 9 || i.Options[0].Name != "rk" || i.Options[8].Name != "makeCredUvNotRqd" {
		t.Errorf("options = %v, want nine in the key's order", i.Options)
	}
	if v, ok := i.option("alwaysUv"); !v || !ok {
		t.Errorf("alwaysUv = %v, %v", v, ok)
	}
	if v, ok := i.option("makeCredUvNotRqd"); v || !ok {
		t.Errorf("makeCredUvNotRqd = %v, %v; want false, present", v, ok)
	}
	if v, ok := i.option("plat"); v || ok {
		t.Errorf("plat = %v, %v; want absent", v, ok)
	}
	if want := []uint64{2, 1}; !reflect.DeepEqual(i.PinProtocols, want) {
		t.Errorf("pinProtocols = %v", i.PinProtocols)
	}
	if i.RemainingDiscoverable != 25 {
		t.Errorf("remaining = %d, want 25", i.RemainingDiscoverable)
	}
	for _, k := range []uint64{1, 2, 4, 6, 0x14} {
		if !i.Has[k] {
			t.Errorf("Has[%#x] = false", k)
		}
	}

	i, err = ctapGetInfo(infoSim(t, ctap20Info()))
	if err != nil {
		t.Fatal(err)
	}
	if i.RemainingDiscoverable != -1 || i.Has[6] || i.Has[0x14] || len(i.PinProtocols) != 0 {
		t.Errorf("CTAP2.0 answer: remaining %d, Has %v", i.RemainingDiscoverable, i.Has)
	}

	// a wrong-typed key or element is skipped, never a panic
	i, err = ctapGetInfo(infoSim(t, newCBORMap().
		put(uint64(1), "FIDO_2_0").
		put(uint64(2), []any{uint64(7), "hmac-secret"}).
		put(uint64(4), newCBORMap().put(uint64(9), true).put("up", true)).
		put(uint64(6), []any{"x", uint64(1)}).
		put(uint64(0x14), "many")))
	if err != nil {
		t.Fatal(err)
	}
	if i.Has[1] || i.Has[0x14] || i.RemainingDiscoverable != -1 {
		t.Errorf("wrong-typed keys were taken: %v, %d", i.Has, i.RemainingDiscoverable)
	}
	if !reflect.DeepEqual(i.Extensions, []string{"hmac-secret"}) || !reflect.DeepEqual(i.PinProtocols, []uint64{1}) ||
		len(i.Options) != 1 || i.Options[0].Name != "up" {
		t.Errorf("elements: ext %v, protos %v, options %v", i.Extensions, i.PinProtocols, i.Options)
	}

	// remainingDiscoverableCredentials is unsigned: a negative integer is wrong-typed and stays absent
	for _, neg := range []int64{-1, -2} {
		i, err = ctapGetInfo(infoSim(t, newCBORMap().put(uint64(1), []any{"FIDO_2_0"}).put(uint64(0x14), neg)))
		if err != nil {
			t.Fatal(err)
		}
		if i.Has[0x14] || i.RemainingDiscoverable != -1 {
			t.Errorf("negative 0x14 (%d) was taken: Has %v, remaining %d", neg, i.Has, i.RemainingDiscoverable)
		}
	}
}

func TestCtapGetInfo_Status27NamesBothCauses(t *testing.T) {
	s := newSimCTAP(t)
	s.status[ctapMakeCredential] = 0x27
	_, err := makeCredential(s, nowhereRPID)
	wantErr(t, err, "0x27", "explicit default option", "requires user verification", "PIN or fingerprint")
	s.status[ctapMakeCredential] = 0x2e
	_, err = makeCredential(s, nowhereRPID)
	if err == nil || err.Error() != "makeCredential: CTAP2 status 0x2e" {
		t.Fatalf("0x2e: %v, want today's text", err)
	}
}

func TestCtapGetInfo_InfoLines(t *testing.T) {
	i, err := ctapGetInfo(infoSim(t, bioInfo()))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"versions: U2F_V2 FIDO_2_0 FIDO_2_1_PRE FIDO_2_1",
		"extensions: hmac-secret credProtect credBlob minPinLength",
		"hmac-secret: true",
		"options: rk=true up=true uv=true alwaysUv=true credMgmt=true bioEnroll=true clientPin=true pinUvAuthToken=true makeCredUvNotRqd=false",
		"pinProtocols: [2 1]",
	}
	if got := fido2InfoLines(i); !reflect.DeepEqual(got, want) {
		t.Errorf("lines = %q\nwant %q", got, want)
	}
	i, err = ctapGetInfo(infoSim(t, ctap20Info()))
	if err != nil {
		t.Fatal(err)
	}
	got := fido2InfoLines(i)
	for _, l := range got {
		if strings.HasPrefix(l, "pinProtocols:") {
			t.Errorf("CTAP2.0 answer printed %q", l)
		}
	}
	if len(got) != 4 || got[3] != "options: rk=true up=true plat=false" {
		t.Errorf("CTAP2.0 lines = %q", got)
	}
}

// nfcSim frames simCTAP behind SELECT and NFCCTAP_MSG, the way an ISO-DEP FIDO applet does.
type nfcSim struct{ s *simCTAP }

func (n nfcSim) transceive(apdu []byte) ([]byte, error) {
	if len(apdu) >= 2 && apdu[0] == 0x00 && apdu[1] == 0xA4 {
		return append([]byte("U2F_V2"), swBytes(0x9000)...), nil
	}
	if len(apdu) >= 7 && apdu[0] == nfcCLA && apdu[1] == nfcInsCTAPMsg {
		lc := int(apdu[5])<<8 | int(apdu[6])
		data := apdu[7 : 7+lc]
		status, body, err := n.s.cbor(data[0], data[1:])
		if err != nil {
			return nil, err
		}
		return append(append([]byte{status}, body...), swBytes(0x9000)...), nil
	}
	return nil, errors.New("nfcSim: unexpected APDU")
}

func TestCtapGetInfo_NFCEnrollBeginRefusesBio(t *testing.T) {
	reset := func() {
		nfcEnrollMu.Lock()
		nfcEnrollName, nfcEnrollCredID = "", nil
		nfcEnrollMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
	s := infoSim(t, bioInfo())
	err := fido2NFCEnrollBegin(nfcSim{s}, "profile")
	wantErr(t, err, "enroll refused before the touch", "alwaysUv")
	wantNoMakeCredential(t, s)
	nfcEnrollMu.Lock()
	parked := nfcEnrollCredID
	nfcEnrollMu.Unlock()
	if parked != nil {
		t.Fatalf("a credId was parked: %x", parked)
	}

	s = infoSim(t, ctap20Info()) // the same path parks the credId of a key that can work
	if err := fido2NFCEnrollBegin(nfcSim{s}, "profile"); err != nil {
		t.Fatal(err)
	}
	nfcEnrollMu.Lock()
	parked = nfcEnrollCredID
	nfcEnrollMu.Unlock()
	if !bytes.Equal(parked, s.credID) {
		t.Fatalf("parked %x, want %x", parked, s.credID)
	}
}

func TestCtapGetInfo_EnrollOn(t *testing.T) {
	s := infoSim(t, ctap20Info())
	id, salt, out, uv, err := fido2EnrollOn(s)
	if err != nil {
		t.Fatal(err)
	}
	if uv || !bytes.Equal(id, s.credID) || len(salt) != 32 || !bytes.Equal(out, s.want(salt)) {
		t.Fatalf("uv %v, credId %x, salt %x, out %x; want false, the credId, 32 bytes, HMAC(credKey, salt)", uv, id, salt, out)
	}

	// A key that is alwaysUv with built-in UV enrols over USB, by its fingerprint (NWP-20261025-08).
	s, _ = uvBio(t)
	id, salt, out, uv, err = fido2EnrollOn(s)
	if err != nil {
		t.Fatal(err)
	}
	if !uv || !bytes.Equal(id, s.credID) || len(salt) != 32 || !bytes.Equal(out, wantUVOut(s, salt)) {
		t.Fatalf("uv %v, credId %x, salt %x, out %x; want true, the credId, 32 bytes, HMAC(credKeyUV, salt)", uv, id, salt, out)
	}
}

// fido2EnrollOn refuses a key the shape rules refuse, by name, before makeCredential.
func TestCtapGetInfo_EnrollOnRefusesShape(t *testing.T) {
	s := infoSim(t, newCBORMap().put(uint64(2), strs("credProtect")))
	_, _, _, _, err := fido2EnrollOn(s)
	wantErr(t, err, "enroll refused before the touch", "hmac-secret")
	wantNoMakeCredential(t, s)

	s = infoSim(t, newCBORMap().put(uint64(2), strs("hmac-secret")).put(uint64(6), []any{uint64(2)}))
	_, _, _, _, err = fido2EnrollOn(s)
	wantErr(t, err, "enroll refused before the touch", "protocol(s) 2;")
	wantNoMakeCredential(t, s)
}
