package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// NWP-20261201-10 (backlog: The phone cannot tell its user about a known fault it could detect; decision: "no LLM in
// the OS", docs/product-decisions.md 2026-11-08): the Fix a health notice offers. A check never repairs on its own and
// never signs a profile out; these verbs run only when the user taps Fix, and the watcher reads GET-HEALTH-FIX to learn
// whether a check after the Fix still fires, which is what puts Sign out on the notice.
//
//	HEALTH-FIX\n<id>\n     -> DENIED | ERR-UNKNOWN-RULE | ERR-NOSESSION | the worker's first line (OK, ERR-WORKER-BUSY, ...)
//	GET-HEALTH-FIX\n<id>\n -> whole seconds since this session's last Fix of that rule | NONE | DENIED

// healthFixes maps a rule id to the roamd op its Fix runs. ⚠ Every op here must ride the read-only lane and must never
// sign out, stop a user or touch data; TestHealthFixNeverSignsOut holds that for each row.
var healthFixes = map[string]string{"play-push-frozen": "playrestart"}

// healthFixNow is a WALL instant: Round(0) drops the monotonic reading, which stops during suspend and would make a
// Fix look younger than the check that followed it (the NWP-20260913-18 trap).
var healthFixNow = func() time.Time { return time.Now().Round(0) }

// healthFixWorker carries no pass and no chip secret: the read-only lane refuses both, on both sides.
var healthFixWorker = func(dest, name, uid, op string) string {
	return triggerRoamWorker(dest, op, name, "", uid, "", nil)
}

// healthFixState is RAM only: a daemon restart forgets the Fixes, which offers Fix again, the safer direction.
var healthFixState = struct {
	sync.Mutex
	uid string
	at  map[string]time.Time
}{at: map[string]time.Time{}}

// healthFixForUIDLocked forgets every Fix of an earlier session. The caller holds healthFixState.
func healthFixForUIDLocked(uid string) {
	if healthFixState.uid != uid {
		healthFixState.uid = uid
		healthFixState.at = map[string]time.Time{}
	}
}

func healthFixRecord(uid, id string, at time.Time) {
	healthFixState.Lock()
	defer healthFixState.Unlock()
	healthFixForUIDLocked(uid)
	healthFixState.at[id] = at
}

func healthFixLast(uid, id string) (time.Time, bool) {
	healthFixState.Lock()
	defer healthFixState.Unlock()
	healthFixForUIDLocked(uid)
	at, ok := healthFixState.at[id]
	return at, ok
}

// handleHealthFix runs a rule's Fix. The caller is the gate or the live session's own user (the notice's button fires
// in that user); any other caller is refused before the argument is read. Only an OK is recorded: ERR-WORKER-BUSY means
// `am` did not run, and recording it would offer Sign out for a Fix that never happened.
func handleHealthFix(conn net.Conn, r *bufio.Reader, dest string) {
	name, _, uid := readRoamSession(dest)
	peer := ownerPeerUID(conn)
	if !gateCallerOK(peer) && !(peer >= 0 && daySummaryUIDOK(uid) && strconv.Itoa(peer/100000) == uid) {
		fmt.Fprint(os.Stderr, "[logind] HEALTH-FIX: DENIED, not the gate or the live session's user\n")
		fmt.Fprint(conn, "DENIED\n")
		return
	}
	id, _ := daySummaryArg(r)
	op, known := healthFixes[id]
	if !known {
		fmt.Fprint(conn, "ERR-UNKNOWN-RULE\n")
		return
	}
	if !daySummaryUIDOK(uid) {
		fmt.Fprint(conn, "ERR-NOSESSION\n")
		return
	}
	word, _, _ := strings.Cut(healthFixWorker(dest, name, uid, op), "\n")
	word = strings.TrimSpace(word)
	if word == "OK" {
		healthFixRecord(uid, id, healthFixNow())
	}
	fmt.Fprintf(os.Stderr, "[logind] health fix %s -> %s\n", id, word)
	fmt.Fprintf(conn, "%s\n", word)
}

// handleGetHealthFix answers the gate's watcher only. The age is clamped at 0 for a wall clock that stepped back.
func handleGetHealthFix(conn net.Conn, r *bufio.Reader, dest string) {
	if !gateCallerOK(ownerPeerUID(conn)) {
		fmt.Fprint(conn, "DENIED\n")
		return
	}
	id, _ := daySummaryArg(r)
	_, _, uid := readRoamSession(dest)
	if !daySummaryUIDOK(uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	at, ok := healthFixLast(uid, id)
	if !ok {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	age := int64(healthFixNow().Sub(at) / time.Second)
	if age < 0 {
		age = 0
	}
	fmt.Fprintf(conn, "%d\n", age)
}
