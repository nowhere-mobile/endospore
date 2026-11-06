package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

// RERUN-REAP (NWP-20261125-15): the gate puts back the REAP that a dead daemon lost.
//
// The teardown queue (pendingSwitchUID, pendingReapUID, pendingLockUID) lives only in this daemon's RAM. When the
// daemon dies after the gate acked a removal's SWITCH and before the gate took its REAP, the restarted daemon answers
// NONE. The removed profile's user then keeps running, with its CE unlocked, until a reboot (lynx 2026102201, user
// 13). Backlog row: "A deleted profile's user stays running, with its CE unlocked, when the login daemon dies between
// the delete's SWITCH and its REAP ...".
//
// The rule: the verb queues the REAP of one user that no live session and no parked cold lock holds. It does nothing
// else. The gate's next POLL-REAP answers "REAP <uid>", and the existing watcher removes the user and sends
// CLEAN-STORAGE.
//
// Three decisions bind it (docs/product-decisions.md):
//   - h45 #2 (2026-10-25): after its own deadline, the gate asks the restarted daemon to re-run the teardown with
//     this verb, for a delete and a sign-out alike. The daemon does not reboot: a reboot loses the pending telephony
//     records of every profile.
//   - h53 #4 (2026-11-02): a sign-out's re-run is the removal alone. It sends no save and shows no prompt. The
//     Keystore push takes the end-of-session stash, as the orphan removal does (roamd cleanstorage, which the gate's
//     CLEAN-STORAGE after the REAP starts). So this verb starts no worker op, no seal and no goroutine, does not set
//     sealInFlight, and never calls reapOrReboot.
//   - h48 #3 (2026-10-30): when a sign-out's re-run also fails, the gate removes the user itself, the fallback h45 #2
//     gave a delete.
//
// BUSY: any SWITCH, REAP or LOCK already queued for another teardown answers BUSY, and so does a lone SWITCH or a LOCK
// for the same uid. That shape is a cold lock's teardown in progress, and a REAP queued there would remove a user that
// the owner is locking to resume. A REAP already queued for the same uid answers OK (the gate may repeat the call).
//
// The live uid comes from readRoamSessionState, not readRoamSession: readRoamSession reads a damaged marker as no
// session, and here "no session" is not the safe direction. A damaged marker that still names the uid refuses.
//
// The gate's half (its deadline on a SWITCH that no REAP follows, this call, and the h48 #3 removal) is the next
// slice. Until then nothing sends this verb.

// rerunReap decides one RERUN-REAP request and returns its reply line. line is the uid line without its LF; haveLF
// says whether the LF was there.
func rerunReap(dest, line string, haveLF bool) string {
	uid := strings.TrimRight(line, "\r")
	if !haveLF || !rerunReapUIDOK(uid) {
		return "ERR"
	}
	if _, _, live, _ := readRoamSessionState(dest); live == uid {
		return "ERR-LIVE"
	}
	if coldLockedUID(dest) == uid {
		return "ERR-PARKED"
	}
	if androidUserGone(uid) {
		return "GONE"
	}
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	if pendingReapUID == uid {
		return "OK"
	}
	if pendingSwitchUID != "" || pendingReapUID != "" || pendingLockUID != "" {
		return "BUSY"
	}
	pendingReapUID = uid // pendingSwitchUID stays empty: the gate has already switched
	return "OK"
}

// rerunReapUIDOK accepts a canonical decimal uid of a secondary user (10 or more): no sign, no space, no leading zero,
// so that the queue and androidUsersDir/<uid> compare as the same string.
func rerunReapUIDOK(s string) bool {
	if s == "" || len(s) > 9 {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	n, err := strconv.Atoi(s)
	return err == nil && n >= 10 && strconv.Itoa(n) == s
}

// handleRerunReap reads "<uid>\n", answers one line and logs it. refusedGateOnlyCaller has already refused a caller
// outside user 0.
func handleRerunReap(conn net.Conn, r *bufio.Reader, dest string) {
	line, err := r.ReadString('\n')
	haveLF := err == nil && strings.HasSuffix(line, "\n")
	line = strings.TrimSuffix(line, "\n")
	reply := rerunReap(dest, line, haveLF)
	u := strings.TrimRight(line, "\r")
	if reply == "ERR" {
		u = strconv.Quote(line)
	}
	fmt.Fprintf(os.Stderr, "[logind] rerun-reap uid=%s: %s (h45 #2, h53 #4)\n", u, reply)
	fmt.Fprintf(conn, "%s\n", reply)
}
