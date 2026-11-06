package main

import (
	"fmt"
	"net"
	"strings"
)

// NWP-20261005-12: re-run the sign-in owner verdict when a binding changes under a LIVE session.
//
// The verdict is decided once, at sign-in: TEL-OWNER blocks a non-owner (no_sms + no_outgoing_calls), and
// TEL-OWNED-ICCIDS scopes an owner to the SIMs it owns. A bind or unbind made later, at the gate, changed nothing
// for the session already running, so a profile that became a SIM's owner mid-session stayed blocked until its next
// sign-in (frankel 0.5.41, 2026-10-05: Messaging could not load, and a text that arrived in that window was handed
// to the blocked session). The gate does not hold the live session's credentials, so it cannot ask TEL-OWNED-ICCIDS
// itself; this verb answers the same question for whoever is signed in.
//
//	TEL-LIVE-OWNED\n -> "OK <uid>\n<iccid>\n..."  every SIM the live session owns (none past the header = owns none)
//	                 -> "NONE\n"                   no live session, or a caller outside user 0
//
// Gate-only (user 0), like GET-RELOGIN: the reply says which SIMs the signed-in profile owns, which an app inside a
// session has no business learning. The match is the sign-in one exactly -- profileRefV2 over the live session's
// name and passphrase -- so a throwaway owns nothing here too.
func handleTelLiveOwned(conn net.Conn, dest string) {
	if !gateCallerOK(ownerPeerUID(conn)) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprint(conn, telLiveOwnedReply(dest))
}

// telLiveOwnedReply builds TEL-LIVE-OWNED's reply from the live session and bindings.conf.
func telLiveOwnedReply(dest string) string {
	name, pass, uid := liveSession(dest)
	if name == "" || uid == "" {
		return "NONE\n"
	}
	var out strings.Builder
	out.WriteString("OK " + uid + "\n")
	for _, iccid := range ownedICCIDs(profileRefV2(name, pass)) {
		out.WriteString(iccid + "\n")
	}
	return out.String()
}

// ownedICCIDs lists the ICCID of every bound SIM whose owners include ref, in bindings order.
func ownedICCIDs(ref string) []string {
	var out []string
	for _, b := range readBindings() {
		for _, o := range b.Owners {
			if o.ProfileRef == ref {
				out = append(out, b.ICCID)
				break
			}
		}
	}
	return out
}
