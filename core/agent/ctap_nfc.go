package main

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// CTAP2-over-NFC transport (#81 item 5). Unlike the USB-HID binding (which opens /dev/hidraw directly in the
// root worker), the FP3's NFC controller is owned by Android's NfcService -- so the raw ISO-DEP transceive is
// done by the CHOOSER via NfcAdapter reader mode, and this layer just frames CTAP2 commands into ISO 7816-4
// APDUs and shuttles them out through a transceiver callback. Same command shaping as HID -- ctapNFC.cbor
// satisfies ctapTransport, so getKeyAgreement / makeCredential / getAssertionHMAC are unchanged.
//
// Framing (FIDO CTAP2 NFC binding): after SELECTing the FIDO applet, each CTAP2 command rides an NFCCTAP_MSG
// APDU (CLA=0x80 INS=0x10), extended-length encoded so a >255-byte getAssertion body fits without command
// chaining; a long response is pulled back with NFCCTAP_GETRESPONSE (CLA=0x80 INS=0x11) whenever the status
// word is 61xx (more data available). The reassembled response is <ctap-status-byte> || <cbor>, exactly like
// the HID CBOR response.

// transceiver exchanges one raw ISO-DEP APDU for its raw response (data || SW1 SW2). The NFC one writes/reads
// the chooser socket (the chooser holds the live IsoDep tag); tests use an in-memory mock applet.
type transceiver interface {
	transceive(apdu []byte) ([]byte, error)
}

const (
	nfcInsCTAPMsg     = 0x10 // NFCCTAP_MSG: carry a CTAP2 command
	nfcInsCTAPGetResp = 0x11 // NFCCTAP_GETRESPONSE: pull the next chunk of a chained response
	nfcCLA            = 0x80 // proprietary CLA for the NFCCTAP_* instructions
)

// fidoAID is the FIDO applet Application ID selected over NFC (A0000006472F0001).
var fidoAID = []byte{0xA0, 0x00, 0x00, 0x06, 0x47, 0x2F, 0x00, 0x01}

// ctapNFC is one CTAP2 session over an ISO-DEP tag (the applet already SELECTed by openCTAPNFC).
type ctapNFC struct {
	t transceiver
}

// selectFIDO SELECTs the FIDO applet on the tapped key (by name, P1=0x04, Le present: 00 A4 04 00 <Lc> <AID>
// 00). The key answers with its version string ("FIDO_2_0" / "U2F_V2") and SW=9000; we only need the 9000 (the
// version is informational). A missing/other applet (a non-FIDO tag, or a key held away mid-select) yields a
// non-9000 SW -> a clear error, not a wedge. A re-SELECT also RESETS the authenticator's transient CTAP2
// session (its clientPIN key-agreement, any pinUvAuthToken) -- which reselect() below relies on.
func selectFIDO(t transceiver) error {
	sel := append([]byte{0x00, 0xA4, 0x04, 0x00, byte(len(fidoAID))}, fidoAID...)
	sel = append(sel, 0x00)
	resp, err := t.transceive(sel)
	if err != nil {
		return fmt.Errorf("SELECT FIDO applet: %w", err)
	}
	_, sw, err := splitSW(resp)
	if err != nil {
		return err
	}
	if sw != 0x9000 {
		return fmt.Errorf("SELECT FIDO applet: SW=0x%04x (not a FIDO2 security key?)", sw)
	}
	return nil
}

func openCTAPNFC(t transceiver) (*ctapNFC, error) {
	if err := selectFIDO(t); err != nil {
		return nil, err
	}
	return &ctapNFC{t: t}, nil
}

func (n *ctapNFC) Close() {} // the chooser owns the tag lifecycle; nothing to release here

// cbor sends one CTAP2 command as an NFCCTAP_MSG APDU and returns the CTAP2 status + CBOR body, pulling any
// chained continuation (61xx) via NFCCTAP_GETRESPONSE. Matches ctapHID.cbor's contract.
func (n *ctapNFC) cbor(ctapCmd byte, params []byte) (status byte, body []byte, err error) {
	data := append([]byte{ctapCmd}, params...)
	apdu := extendedAPDU(nfcCLA, nfcInsCTAPMsg, 0x00, 0x00, data)
	resp, err := n.t.transceive(apdu)
	if err != nil {
		return 0, nil, err
	}
	full, sw, err := n.collect(resp)
	if err != nil {
		return 0, nil, err
	}
	if sw != 0x9000 {
		return 0, nil, fmt.Errorf("NFCCTAP_MSG SW=0x%04x", sw)
	}
	if len(full) < 1 {
		return 0, nil, errors.New("empty CTAP2 response over NFC")
	}
	return full[0], full[1:], nil // full[0] = CTAP2 status (0x00 = OK)
}

// collect accumulates a (possibly chained) response: while SW1==0x61, SW2 is the number of further bytes the
// key holds, so issue NFCCTAP_GETRESPONSE(Le=SW2) and append until a terminal SW (9000 or an error word).
func (n *ctapNFC) collect(resp []byte) (data []byte, sw uint16, err error) {
	for i := 0; ; i++ {
		if i > 256 { // a well-behaved key terminates in a handful of chunks; bound it so a stuck key can't spin
			return nil, 0, errors.New("NFC response chaining did not terminate")
		}
		chunk, w, e := splitSW(resp)
		if e != nil {
			return nil, 0, e
		}
		data = append(data, chunk...)
		if w>>8 != 0x61 { // not "more data available" -> terminal status word
			return data, w, nil
		}
		le := byte(w & 0xff) // 0x6100 means 256 bytes remain
		resp, err = n.t.transceive([]byte{nfcCLA, nfcInsCTAPGetResp, 0x00, 0x00, le})
		if err != nil {
			return nil, 0, err
		}
	}
}

// extendedAPDU builds a case-4 extended-length APDU: CLA INS P1 P2 | 00 Lc_hi Lc_lo | data | Le_hi Le_lo.
// Extended length lets a >255-byte CTAP2 body (a getAssertion with the hmac-secret extension) ride in one
// APDU (Yubico + most modern NFC keys support it), and Le=0x0000 requests the maximum response length.
func extendedAPDU(cla, ins, p1, p2 byte, data []byte) []byte {
	apdu := []byte{cla, ins, p1, p2}
	if len(data) == 0 {
		return append(apdu, 0x00, 0x00, 0x00) // no Lc; extended Le only
	}
	apdu = append(apdu, 0x00, byte(len(data)>>8), byte(len(data))) // extended Lc
	apdu = append(apdu, data...)
	return append(apdu, 0x00, 0x00) // extended Le = 65536 (max)
}

// splitSW peels the trailing 2-byte status word off an ISO 7816-4 response.
func splitSW(resp []byte) (data []byte, sw uint16, err error) {
	if len(resp) < 2 {
		return nil, 0, errors.New("APDU response shorter than a status word")
	}
	return resp[:len(resp)-2], binary.BigEndian.Uint16(resp[len(resp)-2:]), nil
}
