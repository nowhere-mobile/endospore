package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// handleRemoveFido2KeyNFC answers REMOVE-FIDO2-KEY-NFC ("REMOVE-FIDO2-KEY-NFC\n<credID>\n"; an empty credID with its
// LF removes every key). base is the store name handleLogin passes ("s3").
//
// NWP-20261208-16, h57 #6 (docs/product-decisions.md 2026-11-04, "nine answers to harvest 57"): this is the NFC
// transport of the key-removal tap. NWP-20261127-02 built the USB-C one (the REMOVE-FIDO2-KEY arm in handleLogin).
//
// h53 #3 (2026-11-02, "seven answers to harvest 53"): a removal needs a fresh tap of a remaining key, or of the key
// itself when it is the last one. The hmac cached at sign-in (.fido2hmac, the env) never confirms it. That rule lives
// in removeFido2KeyTapped, unchanged; this verb only supplies the tap.
//
// One verb, not a begin/finish pair: an NFC key grants one presence per tap, and a removal needs one presence-gated
// operation, the hmac-secret assertion. FIDO2-NFC-ENROLL-FINISH also asserts and writes the vault in one verb.
//
// nfcAssert gets ALL enrolled slots, not only the permitted ones. A tap of the key being removed must still assert,
// so that removeFido2KeyTapped refuses it as ERR-WRONGKEY. The USB path's fido2adopt also asserts any enrolled key.
//
// The tap is written to .fido2hmac only after it opens a fido2 slot of the current head (fido2adopt's rule). A tap
// that opens no slot must not replace a stash that still opens the vault, or the session's next seal fails.
//
// nfcShuttle.transceive sets a 30 s conn deadline on every APDU. So the deadline is set again after the assert, for
// the paid vault write (120 s) plus margin, or a removal that completes after 30 s loses its reply (#744).
//
// No log line names the profile, a credID, an hmac, or error text that could carry them.
func handleRemoveFido2KeyNFC(conn net.Conn, r *bufio.Reader, dest, base string) {
	cid, err := r.ReadString('\n')
	if err != nil {
		fmt.Fprint(os.Stderr, "[logind] remove-fido2-key-nfc: refused -- the credID line did not arrive\n")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	cid = strings.TrimRight(cid, "\r\n")
	nm, ps, ud := readRoamSession(dest)
	if nm == "" || ud == "" {
		fmt.Fprint(conn, "ERR-NOSESSION\n")
		return
	}
	if isLocalSession(dest) || isOfflineSession(dest) {
		fmt.Fprint(conn, "ERR-NOTSTORED\n") // only a real stored profile carries a key slot to remove
		return
	}
	// The NFC shuttle's own deadlines + the paid vault write's 120s + margin; the chooser half reads past both.
	conn.SetDeadline(time.Now().Add(220 * time.Second))
	var v *vault
	var slots []fido2SlotInfo
	func() {
		defer func() { recover() }() // a store hiccup -> no slots -> ERR, not a crash
		if _, hv, isV := readVaultHead(base, nm, ps); isV {
			v, slots = hv, listFido2Slots(hv)
		}
	}()
	if len(slots) == 0 {
		fmt.Fprint(os.Stderr, "[logind] remove-fido2-key-nfc: no enrolled key in the current head\n")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	h, err := nfcAssert(&nfcShuttle{conn: conn, r: r}, slots)
	// Every APDU above set a 30s deadline; the vault write below needs its 120s + margin (#744).
	conn.SetDeadline(time.Now().Add(130 * time.Second))
	if err != nil || len(h) != fido2HMACLen {
		why := "no slot asserted"
		var le *nfcLinkError
		if errors.As(err, &le) {
			why = "link lost"
		}
		fmt.Fprintf(os.Stderr, "[logind] remove-fido2-key-nfc: %s\n", why)
		fmt.Fprint(conn, "ERR-NOKEY\n")
		return
	}
	if fido2DKWith(v, deriveKey(nm, ps), h) == nil {
		fmt.Fprint(os.Stderr, "[logind] remove-fido2-key-nfc: the tap opens no slot of the current head\n")
		fmt.Fprint(conn, "ERR-NOKEY\n")
		return
	}
	if err := stashFido2Hmac(dest, h); err != nil {
		fmt.Fprint(os.Stderr, "[logind] remove-fido2-key-nfc: the tap was not stashed\n")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	loadFido2HmacEnv(dest) // the session's next seals open with the key just tapped, as after fido2adopt
	var still bool
	var rmErr error
	ok := daemonVaultOp(func() error {
		still, rmErr = removeFido2KeyTapped(base, nm, ps, cid, h, seFromSession(dest), dest)
		return rmErr
	})
	if ok {
		if !still { // last key gone -> passphrase-only again; drop the now-irrelevant key material
			os.Remove(filepath.Join(dest, ".fido2hmac"))
			os.Unsetenv("NOWHERE_FIDO2_HMAC")
		}
		fmt.Fprintf(os.Stderr, "[logind] remove-fido2-key-nfc: removed, stillEnrolled=%v\n", still)
		fmt.Fprintf(conn, "OK %v\n", still)
	} else if errors.Is(rmErr, errKeyTapWrong) {
		fmt.Fprint(os.Stderr, "[logind] remove-fido2-key-nfc: refused -- the tapped key cannot confirm it\n")
		fmt.Fprint(conn, "ERR-WRONGKEY\n")
	} else if errors.Is(rmErr, errKeyTapMissing) {
		fmt.Fprint(os.Stderr, "[logind] remove-fido2-key-nfc: refused -- no tap\n")
		fmt.Fprint(conn, "ERR-NOKEY\n")
	} else {
		fmt.Fprint(os.Stderr, "[logind] remove-fido2-key-nfc: the removal failed\n")
		fmt.Fprint(conn, "ERR\n")
	}
}
