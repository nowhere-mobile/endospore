package main

// NWP-20260922-05: serve the LIVE session's profile name to the session itself.
//
// WHY THIS VERB HAD TO EXIST. Until this slice the roamed Android user was CREATED with the bare profile
// name -- `dpm.createAndManageUser(admin, name, ...)` -- and the chooser's own comment said why: "The user
// NAME is what the system's 'Switching to <name>' dialog shows". That made `pm list users`,
// `/data/system/users/<id>.xml` and every user-switcher surface into a PROFILE LIST, which is the one
// thing AGENTS.md says must not exist: "the absence of a profile list is the security property". The user
// is now created with the device brand instead, so the Profile screen can no longer learn who it is from
// UserManager.getUserName() and has to ask the daemon, which holds the live session in `.roamsession`.
//
// ⚠ THIS IS THE THIRD SURFACE OF ONE DEFECT. #110 made the switch MESSAGE nameless and clears the
// system's session messages at every boot; NWP-20260922-02 kept the resting screen uniform across
// profiles. Both fixed a neighbouring surface and left the user RECORD itself carrying the name.
//
// ⚠ SCOPED TO THE OWNER, AND IT FAILS CLOSED. A name is exactly what this slice exists to stop leaking,
// so it is not served to anyone who cannot prove they are the session it belongs to: the caller's Android
// userId (SO_PEERCRED, uid/100000 -- the same identity GET-TELINGEST uses) must equal the uid recorded in
// the marker. An unavailable peer credential answers NONE rather than the name, matching the `puid <= 0`
// precedent; a check that cannot identify the caller must not answer.

import (
	"fmt"
	"net"
	"strconv"
)

// handleGetSessionName answers "GET-SESSION-NAME" with the live session's profile name, or NONE.
//
// NONE covers every negative case deliberately -- no live session, an unidentifiable caller, or a caller
// that is not this session's user. They are indistinguishable to the caller ON PURPOSE: a distinct error
// for "wrong user" would confirm that SOME session is live, which is a weaker form of the same leak.
func handleGetSessionName(conn net.Conn, dest string) {
	// The STRICT reader, deliberately: readRoamSession answers ("","","") for anything that is not a COMPLETE
	// marker, so a DAMAGED one is refused here even though GET-SESSION-TYPE (a bare os.Stat) still calls the
	// session STORED. That disagreement is priced, not overlooked. readRoamSessionState would hand back the
	// partial fields -- but the field-observed damage is a LOST UID LINE (the frankel shape), which is exactly
	// the field this verb scopes on, so the permissive reader could not serve that case either; and a marker
	// whose lines have SHIFTED would put some other value in the name slot. roamsession_marker.go's own rule
	// is to act on partial fields "only where a partial value is the safe direction", and handing out a
	// profile name is not that place. The cost of refusing is bounded to the two wire-carrying actions, by the
	// gate rule in ProfileActivity.profileName() -- the screen itself stays whole without a name.
	name, _, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	puid := peerUID(conn)
	if puid <= 0 {
		fmt.Fprint(conn, "NONE\n") // fail closed: cannot identify the caller -> do not name the profile
		return
	}
	if strconv.Itoa(puid/100000) != uid {
		fmt.Fprint(conn, "NONE\n") // a different user asked; tell it nothing, not even that a session exists
		return
	}
	fmt.Fprintf(conn, "%s\n", name)
}
