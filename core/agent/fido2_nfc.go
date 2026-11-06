package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

// FIDO2-over-NFC daemon side (#81 item 5 P2). The FP3's NFC controller is owned by Android's NfcService, so
// -- unlike the USB-HID path (roamd opens /dev/hidraw as root) -- the daemon can't touch the tag. Instead the
// CHOOSER holds the tapped key via NfcAdapter reader mode and does the raw IsoDep transceive; the daemon runs
// the CTAP2 command logic IN-PROCESS and shuttles each ISO-DEP APDU to the chooser over the request socket.
// No root, no SELinux, no ssusb host-flip -- the privileged bit (owning the NFC radio) stays in Android's NFC
// stack where it belongs.

// nfcShuttle is a transceiver whose raw ISO-DEP exchange happens in the chooser: write "APDU <hex>", read back
// "RESP <hex>" (the tag's response) or "NFCERR <msg>" (transceive failed / the tag left the field). One line
// per exchange on the request's own connection; a generous per-exchange deadline covers a slow tap-and-hold.
type nfcShuttle struct {
	conn net.Conn
	r    *bufio.Reader
}

// nfcLinkError marks a TRANSPORT failure -- the tag stopped answering, left the field, or the shuttle
// socket broke -- as distinct from a CTAP-level rejection of one credential. The two want OPPOSITE
// handling in a multi-key profile: a rejection means "that credential is not on the tapped key, try the
// next slot", while a dead link means every remaining slot fails the same way, each paying its own full
// timeout. Device-measured on lynx 2026-08-25 (NWP-20260825-01): APDU 2 failed at 404ms, the loop
// advanced to slot 2, and THAT exchange hung the full 30s against a tag that had already stopped
// answering -- which is the whole of the user-visible "hold still ... couldn't sign in".
//
// The rendered strings never reach the chooser: handleFido2NFCAssert answers a bare ERR whatever the
// error, and the chooser learns of a dropped link from its own NFCERR (NfcShuttle.LINK_LOST,
// NWP-20261109-05).
type nfcLinkError struct{ msg string }

func (e *nfcLinkError) Error() string { return e.msg }

func (s *nfcShuttle) transceive(apdu []byte) ([]byte, error) {
	s.conn.SetDeadline(time.Now().Add(30 * time.Second))
	if _, err := fmt.Fprintf(s.conn, "APDU %x\n", apdu); err != nil {
		return nil, &nfcLinkError{fmt.Sprintf("nfc shuttle write: %v", err)}
	}
	line, err := s.r.ReadString('\n')
	if err != nil {
		return nil, &nfcLinkError{fmt.Sprintf("nfc shuttle read: %v", err)}
	}
	line = strings.TrimSpace(line)
	switch {
	case strings.HasPrefix(line, "RESP "):
		b, err := hex.DecodeString(strings.TrimSpace(line[len("RESP "):]))
		if err != nil {
			return nil, fmt.Errorf("nfc shuttle: bad RESP hex: %w", err)
		}
		return b, nil
	case strings.HasPrefix(line, "NFCERR"):
		return nil, &nfcLinkError{"nfc: " + strings.TrimSpace(strings.TrimPrefix(line, "NFCERR"))}
	default:
		return nil, fmt.Errorf("nfc shuttle: unexpected reply %q", line)
	}
}

// The NFC enroll is TWO taps (unlike USB's one plug-in with two touches): an NFC key grants exactly ONE user
// presence per physical tap, and the ceremony needs two presence-gated operations -- makeCredential, then the
// hmac-secret getAssertion (whose output the spec only releases WITH presence; up:false = 0x3b, proven on the
// Yubico C NFC, as was every same-tap combination: 0x34 stale key-agreement, tag-lost on the re-tap wait).
// So: tap 1 = FIDO2-NFC-ENROLL-BEGIN (makeCredential; the credId parks in the daemon between taps), tap 2 =
// FIDO2-NFC-ENROLL-FINISH (assertion + the vault slot write).

// nfcPendingEnroll is tap 1's result awaiting tap 2, keyed to the session's profile so a FINISH can't consume
// a BEGIN from a different login. In-memory only (an abandoned enroll evaporates; nothing store-side happened
// -- the credential is non-resident, so an unfinished makeCredential leaves NOTHING on the key either).
var (
	nfcEnrollMu     sync.Mutex
	nfcEnrollName   string
	nfcEnrollCredID []byte
	nfcEnrollAt     time.Time
)

const nfcEnrollWindow = 3 * time.Minute // tap 2 must follow tap 1 within this window

// fido2NFCEnrollBegin runs tap 1: SELECT + makeCredential (consumes this tap's presence) and parks the credId
// for the FINISH.
func fido2NFCEnrollBegin(t transceiver, name string) error {
	n, err := openCTAPNFC(t)
	if err != nil {
		return err
	}
	defer n.Close()
	credID, err := enrollMakeCredential(n, nowhereRPID)
	if err != nil {
		return err
	}
	nfcEnrollMu.Lock()
	nfcEnrollName, nfcEnrollCredID, nfcEnrollAt = name, credID, time.Now()
	nfcEnrollMu.Unlock()
	return nil
}

// fido2NFCEnrollFinish runs tap 2: take the parked credId, SELECT + hmac-secret assertion (this tap's
// presence), and return the slot parameters for enrollFido2. The pending state is consumed either way.
func fido2NFCEnrollFinish(t transceiver, name string) (credID, salt, hmacOut []byte, err error) {
	nfcEnrollMu.Lock()
	credID, pName, at := nfcEnrollCredID, nfcEnrollName, nfcEnrollAt
	nfcEnrollName, nfcEnrollCredID = "", nil
	nfcEnrollMu.Unlock()
	if len(credID) == 0 || pName != name || time.Since(at) > nfcEnrollWindow {
		return nil, nil, nil, errors.New("no pending enroll (tap 'Tap an NFC key' and start again)")
	}
	n, err := openCTAPNFC(t)
	if err != nil {
		return nil, nil, nil, err
	}
	defer n.Close()
	salt = make([]byte, 32)
	rand.Read(salt)
	hmacOut, err = getAssertionHMAC(n, nowhereRPID, credID, salt)
	if err != nil {
		return nil, nil, nil, err
	}
	return credID, salt, hmacOut, nil
}

// fido2AssertOverNFC reproduces the hmac for an enrolled profile over NFC, trying each enrolled slot (multi-key)
// until one asserts -- the reader session stays open across tries while the key is held on the field. Mirrors
// the USB fido2-hmac loop; the caller supplies the slots read from the resolved vault.
func fido2AssertOverNFC(t transceiver, slots []fido2SlotInfo) ([]byte, error) {
	if len(slots) == 0 {
		return nil, errors.New("not a fido2 profile")
	}
	n, err := openCTAPNFC(t)
	if err != nil {
		return nil, err
	}
	defer n.Close()
	var lastErr error
	for _, s := range slots {
		credID, e1 := base64.StdEncoding.DecodeString(s.CredID)
		salt, e2 := base64.StdEncoding.DecodeString(s.Salt)
		if e1 != nil || e2 != nil {
			continue
		}
		h, err := getAssertionHMAC(n, nowhereRPID, credID, salt)
		if err != nil {
			// ⚠ A DEAD LINK ENDS THE WHOLE ATTEMPT. It is a property of the RF link, not of this
			// credential, so advancing to the next slot cannot succeed -- it only spends another full
			// timeout against a tag that is no longer answering. Only a CTAP-level rejection ("that
			// credential is not on this key") justifies the next slot, which is the multi-key semantic
			// this loop exists for.
			var le *nfcLinkError
			if errors.As(err, &le) {
				return nil, err
			}
			lastErr = err
			continue
		}
		return h, nil
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, errors.New("no enrolled key responded")
}
