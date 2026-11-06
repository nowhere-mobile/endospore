package main

import (
	"bytes"
	"fmt"
	"testing"
)

// mockApplet is an in-memory ISO-DEP FIDO applet: it answers SELECT, and for an NFCCTAP_MSG it serves a canned
// CTAP2 response -- optionally split into 61xx-chained chunks so the NFCCTAP_GETRESPONSE reassembly is tested.
type mockApplet struct {
	selectSW   uint16 // status word to return on SELECT (0x9000 = ok)
	respFull   []byte // the full CTAP2 response (status byte || cbor) to serve for the next NFCCTAP_MSG
	chunkSize  int    // 0 = serve whole; >0 = serve chunkSize bytes per response, chaining via 61xx
	pending    []byte // bytes not yet served (drives NFCCTAP_GETRESPONSE)
	lastCmd    byte   // the CTAP command byte the applet received (round-trip check)
	lastParams []byte // the CTAP params the applet received
}

func swBytes(sw uint16) []byte { return []byte{byte(sw >> 8), byte(sw)} }

func (m *mockApplet) transceive(apdu []byte) ([]byte, error) {
	switch {
	case len(apdu) >= 2 && apdu[0] == 0x00 && apdu[1] == 0xA4: // SELECT
		return append([]byte("U2F_V2"), swBytes(m.selectSW)...), nil
	case len(apdu) >= 7 && apdu[0] == nfcCLA && apdu[1] == nfcInsCTAPMsg: // NFCCTAP_MSG (extended Lc)
		lc := int(apdu[5])<<8 | int(apdu[6])
		if len(apdu) < 7+lc {
			return nil, fmt.Errorf("mock: NFCCTAP_MSG Lc=%d but only %d body bytes", lc, len(apdu)-7)
		}
		data := apdu[7 : 7+lc]
		m.lastCmd = data[0]
		m.lastParams = append([]byte(nil), data[1:]...)
		m.pending = append([]byte(nil), m.respFull...)
		return m.serveChunk(), nil
	case len(apdu) >= 4 && apdu[0] == nfcCLA && apdu[1] == nfcInsCTAPGetResp: // NFCCTAP_GETRESPONSE
		return m.serveChunk(), nil
	}
	return nil, fmt.Errorf("mock: unexpected APDU % x", apdu)
}

// serveChunk returns the next chunk of m.pending: the whole remainder + 9000 when it fits, else chunkSize bytes
// + 61xx (xx = bytes still held, capped at 0xff).
func (m *mockApplet) serveChunk() []byte {
	if m.chunkSize <= 0 || len(m.pending) <= m.chunkSize {
		out := append(append([]byte(nil), m.pending...), 0x90, 0x00)
		m.pending = nil
		return out
	}
	chunk := m.pending[:m.chunkSize]
	m.pending = m.pending[m.chunkSize:]
	more := len(m.pending)
	if more > 0xff {
		more = 0xff
	}
	return append(append([]byte(nil), chunk...), 0x61, byte(more))
}

// The transport round-trips a CTAP2 command/response over NFC framing, whole and 61xx-chained, and the applet
// sees the exact command byte + params we framed (proves extendedAPDU encoding + collect() reassembly).
func TestCtapNFCRoundTrip(t *testing.T) {
	respBody := []byte{0xa2, 0x01, 0x18, 0x2a, 0x02, 0x43, 0x01, 0x02, 0x03} // arbitrary CBOR body
	full := append([]byte{0x00}, respBody...)                                // CTAP2 status 0x00 || body
	params := []byte{0xAA, 0xBB, 0xCC}

	for _, chunk := range []int{0, 4, 1} { // whole response, coarse chaining, byte-at-a-time chaining
		m := &mockApplet{selectSW: 0x9000, respFull: full, chunkSize: chunk}
		n, err := openCTAPNFC(m)
		if err != nil {
			t.Fatalf("openCTAPNFC (chunk=%d): %v", chunk, err)
		}
		status, body, err := n.cbor(ctapGetAssertion, params)
		if err != nil {
			t.Fatalf("cbor (chunk=%d): %v", chunk, err)
		}
		if status != 0x00 {
			t.Fatalf("chunk=%d: status=0x%02x want 0x00", chunk, status)
		}
		if !bytes.Equal(body, respBody) {
			t.Fatalf("chunk=%d: body=% x want % x", chunk, body, respBody)
		}
		if m.lastCmd != ctapGetAssertion {
			t.Fatalf("chunk=%d: applet saw cmd 0x%02x want 0x%02x", chunk, m.lastCmd, ctapGetAssertion)
		}
		if !bytes.Equal(m.lastParams, params) {
			t.Fatalf("chunk=%d: applet saw params % x want % x", chunk, m.lastParams, params)
		}
	}
}

// A non-9000 SELECT (a non-FIDO tag, or the key pulled mid-select) is a clear error, not a wedge.
func TestCtapNFCSelectFails(t *testing.T) {
	if _, err := openCTAPNFC(&mockApplet{selectSW: 0x6a82}); err == nil { // 6A82 = file/applet not found
		t.Fatal("openCTAPNFC accepted a non-FIDO applet (SW != 9000)")
	}
}

// A non-9000 status word on the CTAP message itself surfaces as an error.
func TestCtapNFCMsgErrorSW(t *testing.T) {
	m := &mockApplet{selectSW: 0x9000, respFull: []byte{0x00}, chunkSize: 0}
	n, err := openCTAPNFC(m)
	if err != nil {
		t.Fatal(err)
	}
	// Force a terminal error SW by making the applet return only an error word (no data path hits it): a
	// zero-length pending with a non-9000 terminal isn't reachable via serveChunk, so drive it directly.
	bad := &badSWApplet{}
	n.t = bad
	if _, _, err := n.cbor(ctapGetAssertion, nil); err == nil {
		t.Fatal("cbor accepted a non-9000 message status word")
	}
}

type badSWApplet struct{}

func (badSWApplet) transceive(apdu []byte) ([]byte, error) { return []byte{0x6f, 0x00}, nil } // 6F00 = no precise diagnosis

// extendedAPDU encodes case-4 extended-length correctly (3-byte Lc, 2-byte Le), and Le-only when there's no data.
func TestExtendedAPDU(t *testing.T) {
	got := extendedAPDU(nfcCLA, nfcInsCTAPMsg, 0x00, 0x00, []byte{1, 2, 3})
	want := []byte{0x80, 0x10, 0x00, 0x00, 0x00, 0x00, 0x03, 1, 2, 3, 0x00, 0x00}
	if !bytes.Equal(got, want) {
		t.Fatalf("extendedAPDU=% x want % x", got, want)
	}
	got = extendedAPDU(nfcCLA, nfcInsCTAPGetResp, 0x00, 0x00, nil)
	want = []byte{0x80, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00}
	if !bytes.Equal(got, want) {
		t.Fatalf("empty extendedAPDU=% x want % x", got, want)
	}
	// A >255-byte body must extend Lc without command chaining (the reason we use extended length).
	big := make([]byte, 300)
	a := extendedAPDU(nfcCLA, nfcInsCTAPMsg, 0, 0, big)
	if a[4] != 0x00 || a[5] != 0x01 || a[6] != 0x2c { // Lc = 0x012c = 300
		t.Fatalf("extended Lc for 300 bytes = % x, want 00 01 2c", a[4:7])
	}
}
