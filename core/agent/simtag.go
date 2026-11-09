package main

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// NWP-20260924-07 -- which SIM a telephony record came in on. Chester, 2026-09-24: anything delivered while a SIM
// is bound to a profile is that profile's content, and at an unassign the records that came in on THAT SIM are
// deleted at that moment, for every owner the unassign drops (*"lets make the unbind at a sim level?"*). For that a
// record has to say which SIM it came in on: its sealed payload holds the sub id, but the agent cannot open
// another profile's blob, and a mailbox row carries no sub id at all. So every record is tagged at arrival with
// simTag(its binding's ICCID) -- in the sealed blob's file name, in the per-SIM mailbox file's name, for a call row
// in its body slot, which the chooser echoes back verbatim on a RESTAGE, and since NWP-20261130-01 for an SMS or MMS
// row in a "sim:<tag>" slot of its own, which the chooser maps to a subscription (serializeTelIngest, TelSub).

// normICCID is the one comparison form of an ICCID, the same rule as the chooser's iccEq: trimmed, lower-case,
// one trailing 'f' filler stripped. The same SIM shows up with and without the filler nibble (Chester, lynx
// 2026-07-18); the chooser matched loosely while the agent compared exactly, so "Unbind all" on the padded form
// silently unbound nothing.
func normICCID(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	return strings.TrimSuffix(s, "f")
}

// simTag names a SIM in a file name without writing its ICCID there: the first 16 hex characters of a hash of
// the normalised ICCID. bindings.conf already holds the ICCID in the clear for the same root reader, so this is
// tidiness rather than secrecy -- but it is a stable name for the SIM, so it is never logged.
func simTag(iccid string) string {
	h := sha256.Sum256([]byte("nowhere-sim|" + normICCID(iccid)))
	return hex.EncodeToString(h[:])[:16]
}

// isSimTag reports whether s has the shape of a simTag: exactly 16 lower-case hex characters.
func isSimTag(s string) bool {
	if len(s) != 16 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
