package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

// NWP-20261115-01 (dn-1023 #4, docs/product-decisions.md 2026-10-24): DROP-SSAID removes the SSAID material a sign-in
// that did not land can leave in users/<uid>. SEED-SSAID stages nowhere-ssaid-seed there before the roam-in, and once
// the patched SettingsProvider consumed it settings_ssaid.xml holds the same 64 hex: both are a verifier of the
// profile's passphrase, in cleartext. roamd's `in` op removes them on its own non-OK verdicts, but the agent-side
// outcomes in which `in` never runs or its OK is overturned (NOSTORE, an empty name or uid, ERR-REQ, a worker timeout,
// ERR-UNRECORDED, the chooser giving up at 120 s) reach only the gate's stopRoamUser, a bare removeUser. The gate sends
// this verb after that removeUser has returned. The full CLEAN-STORAGE reap was not chosen: the retry sign-in would
// wait up to 20 s behind it (Q039).
//
// Wire: "DROP-SSAID\n<uid>\n" -> "OK <removed>" | "ERR-UID" | "ERR-LIVE" | "ERR-LINK" | "ERR-RM" | "ERR". Gate-only
// (owner_key.go gateOnlyCmd): a roamed caller would remove another user's SSAID files. Not in concurrentSafeCmd, so
// it serializes on sessionMu; the op rides the RW lane (laneFor's default), behind any roam-in of the same uid.
//
// The daemon refuses the uid of the live session and of a cold-locked session (ERR-LIVE): their SSAID state is in
// use. The RESIDUAL of that guard: a sign-in the daemon finishes after the chooser gave up leaves a marker naming the
// removed uid until clearMarkerOfGoneUser drops it, and a DROP-SSAID in that window answers ERR-LIVE and removes
// nothing. The material then stays until the framework's delete of users/<uid>, the id's next user or the boot sweep.
func handleDropSsaid(conn net.Conn, dest string, r *bufio.Reader) {
	line, _ := r.ReadString('\n')
	raw := strings.TrimRight(line, "\r\n")
	n, ok := 0, raw != ""
	for _, c := range raw {
		if c < '0' || c > '9' {
			ok = false
			break
		}
	}
	if ok {
		var err error
		n, err = strconv.Atoi(raw)
		ok = err == nil && n >= 10
	}
	if !ok {
		// Never the raw request line.
		fmt.Fprint(os.Stderr, "[logind] drop-ssaid refused: not a roamed uid (dn-1023 #4)\n")
		fmt.Fprint(conn, "ERR-UID\n")
		return
	}
	// The canonical form: "017" must not slip past the string compare below.
	uid := strconv.Itoa(n)
	_, _, live := readRoamSession(dest)
	_, cold, _, _, _, _ := readColdLock(dest)
	if uid == live || uid == cold {
		fmt.Fprintf(os.Stderr, "[logind] drop-ssaid user %s -> ERR-LIVE (dn-1023 #4)\n", uid)
		fmt.Fprint(conn, "ERR-LIVE\n")
		return
	}
	out := strings.TrimSpace(triggerRoamWorker(dest, "dropssaid", "x", "", uid, "", nil))
	if out == "" {
		out = "ERR"
	}
	fmt.Fprintf(os.Stderr, "[logind] drop-ssaid user %s -> %s (dn-1023 #4)\n", uid, out)
	fmt.Fprintf(conn, "%s\n", out)
}
