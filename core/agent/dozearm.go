package main

// NWP-20261117-06 (dn-1023 #3, docs/product-decisions.md 2026-10-24): the login daemon keeps, in RAM and per Android
// user, whether the gate's login apply of a session's own Doze choices armed (ChooserActivity.applyRoamedDozeApps).
// The session's capture (DozeAppsMirror.capture) asks before it writes files/nowhere-doze-apps, so a session whose
// apply failed seals nothing over the record it restored. The mark never roams and never reaches a file: a daemon
// restart forgets it, and the capture then runs as before this slice. It is per uid because an unarmed session that
// cold-locks keeps its mark while another profile signs in and sends its own DOZE-ARM, and reads unarmed when it
// resumes. Every sign-in sends one, so a later sign-in that reuses a uid replaces the entry; nothing resets it.

import (
	"bufio"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
)

var (
	dozeArmMu   sync.Mutex
	dozeUnarmed = map[string]bool{} // Android user id -> that session's login apply did not arm
)

// handleDozeArm is DOZE-ARM: "DOZE-ARM\n<uid>\n<armed|unarmed>\n" -> OK | DENIED | ERR request. Only the user-0 gate
// may send it, and the refusal comes before the request is read (the handleOwnerKey shape).
func handleDozeArm(conn net.Conn, r *bufio.Reader) {
	if !ownerCallerOK(ownerPeerUID(conn)) {
		fmt.Fprint(conn, "DENIED\n")
		return
	}
	u, _ := r.ReadString('\n')
	m, _ := r.ReadString('\n')
	n, err := strconv.Atoi(strings.TrimRight(u, "\r\n"))
	mode := strings.TrimRight(m, "\r\n")
	if err != nil || n <= 0 || (mode != "armed" && mode != "unarmed") {
		fmt.Fprint(conn, "ERR request\n")
		return
	}
	uid := strconv.Itoa(n)
	dozeArmMu.Lock()
	dozeUnarmed[uid] = mode == "unarmed"
	dozeArmMu.Unlock()
	fmt.Fprint(conn, "OK\n")
}

// handleGetDozeArm is GET-DOZE-ARM: "GET-DOZE-ARM\n" -> UNARMED | ARMED | NONE. Only the live session's own user is
// answered (sessionCaller against .roamsession's uid); any other caller, or no session, reads NONE.
func handleGetDozeArm(conn net.Conn, dest string) {
	_, _, uid := readRoamSession(dest)
	if uid == "" || !sessionCaller(conn, uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	dozeArmMu.Lock()
	unarmed := dozeUnarmed[uid]
	dozeArmMu.Unlock()
	if unarmed {
		fmt.Fprint(conn, "UNARMED\n")
		return
	}
	fmt.Fprint(conn, "ARMED\n")
}
