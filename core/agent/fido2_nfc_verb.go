package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// nfcAssert is the seam the NFC verb asserts through, so a test supplies the hmac without a mock applet.
var nfcAssert = fido2AssertOverNFC

// handleFido2NFCAssert answers FIDO2-NFC-ASSERT and FIDO2-NFC-RESUME (verb names which). base is the store
// name handleLogin passes ("s3").
func handleFido2NFCAssert(conn net.Conn, r *bufio.Reader, dest, base, verb string) {
	// #81 item 5: at LOGIN, assert the tapped NFC key -> the hmac the restore needs. "FIDO2-NFC-ASSERT\n
	// <name>\n<pass>\n". The chooser holds the tag + shuttles APDUs; we compute the hmac and pre-stash it to
	// .fido2hmac.pre, which roamd's "in" op adopts instead of flipping USB host + asserting (no key sits in
	// the USB-C port on the NFC path). Blind login: a wrong passphrase / non-fido2 profile returns a generic
	// ERR the chooser maps to the uniform "couldn't sign in", the same as any failed login.
	nl, _ := r.ReadString('\n')
	pl, _ := r.ReadString('\n')
	nm := strings.TrimRight(nl, "\r\n")
	ps := strings.TrimRight(pl, "\r\n")
	// ⚠ NWP-20260823-12: RESUME and FRESH LOGIN are now DIFFERENT VERBS, because they need opposite
	// behaviour and the daemon cannot tell them apart from name+secret alone -- the chooser sends this same
	// handler from both the resume prompt and the fresh-login form. -11 keyed its behaviour off the parked
	// MARKER instead, which was wrong in both directions:
	//   - a FRESH sign-in of a profile that happens to have a PIN-flagged cold-lock parked (exactly the
	//     documented recovery from a mistyped PIN: "Not you? Sign in as someone else", which is UI-only and
	//     LEAVES the marker parked) was REFUSED outright, correct passphrase and all;
	//   - and that same login skipped the head lookup, so it never staged .fido2slots.pre, so roamd's commit
	//     arm cleared the stash with nothing to promote and the session's NEXT cold-lock baked an empty
	//     line 7 -- reinstating the very strand this whole arc exists to remove, invisibly to USB testers.
	// A separate verb also keeps an OLD chooser working against a new agent (it sends ...-ASSERT, which is
	// the fresh-login path, i.e. pre-11 behaviour) rather than blocking on a protocol line it never sends.
	isResume := verb == "FIDO2-NFC-RESUME"
	var slots []fido2SlotInfo
	if isResume {
		// The marker is the ONLY source here, whatever the session (NWP-20261017-03). The typed secret is not
		// proven at this point: resolving a head with it would send refs derived from a stranger's guess to the
		// gateway and put it in the KDF cache. A marker with no usable spec answers ERR below.
		slots = parseSlotSpec(coldLockSlots(dest))
		if len(slots) == 0 {
			fmt.Fprintf(os.Stderr, "[logind] nfc-resume %q: no usable slot spec\n", nm)
			fmt.Fprint(conn, "ERR\n")
			return
		}
	} else {
		func() {
			defer func() { recover() }() // a store hiccup -> empty slots -> ERR, not a crash
			if v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, nm, ps)))); isV {
				slots = listFido2Slots(v)
			}
		}()
		if len(slots) == 0 {
			fmt.Fprint(conn, "ERR\n") // wrong pass / no profile / not a fido2 profile -> generic (blind)
			return
		}
		// EVERY committing login must stage its spec, or roamd's commit-arm reset leaves the session with
		// none and its next cold-lock is unresumable. A spec that cannot be staged stops the login here,
		// before the key is asserted, with the same generic ERR (NWP-20261112-15).
		if err := stashFido2SlotsPre(dest, slots); err != nil {
			fmt.Fprintf(os.Stderr, "[logind] nfc-assert %q: slot spec not staged\n", nm)
			fmt.Fprint(conn, "ERR\n")
			return
		}
	}
	conn.SetDeadline(time.Now().Add(90 * time.Second))
	h, err := nfcAssert(&nfcShuttle{conn: conn, r: r}, slots)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] nfc-assert %q: %v\n", nm, err)
		fmt.Fprint(conn, "ERR\n")
		return
	}
	// NWP-20260924-01: a RESUME assertion lands in its OWN file. .fido2hmac.pre is the login `in` op's, and the
	// resume used to adopt it too -- so a fresh-login assert made with the TYPIST's own profile and key satisfied
	// a keyed resume of somebody else's session.
	if err := os.WriteFile(filepath.Join(dest, nfcHmacStash(isResume)), []byte(hex.EncodeToString(h)), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] nfc-assert %q: pre-stash: %v\n", nm, err)
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprint(conn, "OK\n")
}
