package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// NWP-20261202-20 (backlog: The phone does not notice when the session's media service stops answering, although
// restarting it brings back the alarm list, the Gallery and shared storage at once; decision: "no LLM in the OS",
// docs/product-decisions.md 2026-11-08): the Fix a health notice offers for a session MediaProvider that stopped
// answering. A check never repairs on its own; only a user's tap on the notice sends this verb.
//
//	MEDIA-RESTART\n -> QUEUED | DENIED | ERR-NOSESSION
//
// QUEUED is answered at once, before any wait. The restart itself runs later, in one goroutine: after any running save,
// as the roamd op mediarestart on the READ-WRITE lane. A MediaProvider stop makes StorageManagerService reset every
// volume of every user (H_RESET; see the `...providers.media.module` keep-list comment in nowhere_roamd.sh), and that
// must not land mid-seal. That is why this is its own verb and not a healthFixes row: every HEALTH-FIX op rides the
// read-only lane and never waits (TestHealthFixNeverSignsOut).

// mediaRestartInterval is one wait between checks for a running save.
const mediaRestartInterval = 10 * time.Second

// mediaRestartMaxWaits bounds the wait by a COUNT of intervals, not by the wall clock, so a test drives it without
// waiting: one seal's expiry plus five minutes.
var mediaRestartMaxWaits = int((sealRunExpiry + 5*time.Minute) / mediaRestartInterval)

// mediaRestartPending is set while one restart is queued or running; a tap meanwhile starts nothing.
var mediaRestartPending atomic.Bool

// mediaRestartSleep is one wait for a running save. Tests replace it.
var mediaRestartSleep = func() { time.Sleep(mediaRestartInterval) }

// mediaRestartWorker sends the op on the read-write lane (laneFor's default). It carries no pass and no chip secret.
var mediaRestartWorker = func(dest, name, uid string) string {
	return triggerRoamWorker(dest, "mediarestart", name, "", uid, "", nil)
}

// handleMediaRestart queues the Fix. The caller must be the live session's own Android user (peerUID / 100000 == the
// session's uid), as daySummaryCaller checks; user 0, root, system and every other user are refused.
func handleMediaRestart(conn net.Conn, dest string) {
	_, _, uid := readRoamSession(dest)
	if !daySummaryUIDOK(uid) {
		fmt.Fprint(conn, "ERR-NOSESSION\n")
		return
	}
	if peer := ownerPeerUID(conn); peer < 0 || strconv.Itoa(peer/100000) != uid {
		fmt.Fprint(os.Stderr, "[logind] MEDIA-RESTART: DENIED, not the live session's user (NWP-20261202-20)\n")
		fmt.Fprint(conn, "DENIED\n")
		return
	}
	if mediaRestartPending.CompareAndSwap(false, true) {
		fmt.Fprint(os.Stderr, "[logind] media restart: queued\n")
		goSafe("media-restart", func() { mediaRestartRun(dest, uid) })
	}
	fmt.Fprint(conn, "QUEUED\n")
}

// mediaRestartRun waits out any running save, re-checks that the queued session is still the live one, then sends the
// op. The read-write lane also serialises it behind a seal that took the slot after the last check.
func mediaRestartRun(dest, uid string) {
	defer mediaRestartPending.Store(false)
	n := 0
	for anySealRunning(time.Now()) {
		if n >= mediaRestartMaxWaits {
			fmt.Fprintf(os.Stderr, "[logind] media restart: gave up after %ds, a save is still running\n",
				n*int(mediaRestartInterval/time.Second))
			return
		}
		mediaRestartSleep()
		n++
	}
	if n > 0 {
		fmt.Fprintf(os.Stderr, "[logind] media restart: waited %ds for a save\n", n*int(mediaRestartInterval/time.Second))
	}
	name, _, now := readRoamSession(dest)
	if now != uid {
		fmt.Fprint(os.Stderr, "[logind] media restart: session ended\n")
		return
	}
	word := "(none)"
	if f := strings.Fields(mediaRestartWorker(dest, name, uid)); len(f) > 0 {
		word = f[0]
	}
	fmt.Fprintf(os.Stderr, "[logind] media restart: -> %s\n", word)
}
