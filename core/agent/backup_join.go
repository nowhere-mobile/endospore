package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

// NWP-20261201-07, the daemon half of the 2026-11-07 decision (docs/product-decisions.md, "each profile chooses when
// its periodic saves run"): a Back up now tap while a save is running joins that save and is never refused with "try
// again". The reply stays BUSY <why>, so a chooser of either age keeps working; only login.log says "joined". When the
// tap came from the back-online notice and the running save started before the reconnect, that save cannot clear the
// notice, so one more Back up now runs as soon as it ends.
//
// The notice's tap sends `BACKUP\nAFTER <unix seconds of the reconnect>\n` in one write, so the stamp is already in
// the dispatcher's reader and costs no wait. Every other caller sends a bare BACKUP and waits out backupAfterWait.

// backupAfterWait bounds the read of the optional AFTER line. A bare BACKUP holds sessionMu for this long.
var backupAfterWait = 250 * time.Millisecond

// queuedSavePoll is the waiter's tick; queuedSaveDeadline is how long it may wait: one announced seal's whole life.
var queuedSavePoll = 2 * time.Second
var queuedSaveDeadline = sealRunExpiry

// queuedSaveArmed: a waiter is running. Guarded by pendingReapMu, so six taps arm one waiter.
var queuedSaveArmed bool

// queuedSaveStart is the waiter's Back up now, a hook for the tests. It is assigned in init because a package-level
// initializer here is an initialization cycle: startQueuedBackup -> handleBackup -> runQueuedSave -> queuedSaveStart.
var queuedSaveStart func(dest string) string

func init() { queuedSaveStart = startQueuedBackup }

// queuedSaveStep's answers. Every DROP has its own value, so one switch decides both the arm and the log's class.
const (
	queuedStepWait = iota
	queuedStepStart
	queuedDropSessionEnded
	queuedDropSignOut
	queuedDropLanded
	queuedDropNewerSave
)

var queuedDropWord = map[int]string{
	queuedDropSessionEnded: "session-ended",
	queuedDropSignOut:      "sign-out",
	queuedDropLanded:       "landed",
	queuedDropNewerSave:    "newer-save",
}

// parseBackupAfter is the reconnect stamp in exactly `AFTER <1-18 digits>`, 0 for anything else.
func parseBackupAfter(line string) int64 {
	digits, ok := strings.CutPrefix(strings.TrimSpace(line), "AFTER ")
	if !ok || len(digits) < 1 || len(digits) > 18 {
		return 0
	}
	var v int64
	for _, c := range digits {
		if c < '0' || c > '9' {
			return 0
		}
		v = v*10 + int64(c-'0')
	}
	return v
}

// readBackupAfter reads the optional line after BACKUP, then gives the connection back handleLogin's deadline. A line
// cut by the deadline parses as a smaller stamp or as 0, and neither can queue a save the tap did not need.
func readBackupAfter(conn net.Conn, r *bufio.Reader) int64 {
	conn.SetReadDeadline(time.Now().Add(backupAfterWait))
	line, _ := r.ReadString('\n')
	conn.SetDeadline(time.Now().Add(loginConnDeadline))
	return parseBackupAfter(line)
}

// joinsRunningSave: a busy reason that IS a running save. Any other reason (login, user-op-waiting) stays a refusal.
func joinsRunningSave(why string) bool {
	return why == "seal-in-flight" || strings.HasPrefix(why, "seal-run:")
}

// queueFollowUp decides whether a joined tap needs one more save: it carries the reconnect stamp, the running save is
// not a sign-out (that saves everything), the running save was announced before the reconnect and no waiter is armed.
// An announce at the reconnect's own second counts as after it, the chooser's own boundary (BackNowCycle.onLanded).
func queueFollowUp(after int64, kind string, runAt time.Time, armed bool) bool {
	if after <= 0 || strings.HasPrefix(kind, "logoff") || armed {
		return false
	}
	return runAt.IsZero() || runAt.Unix() < after
}

// followUpWord is the login.log vocabulary for what a joined tap did about a follow-up.
func followUpWord(kind string, armed, queued bool) string {
	switch {
	case queued:
		return "queued"
	case strings.HasPrefix(kind, "logoff"):
		return "none for a sign-out"
	case armed:
		return "already queued"
	}
	return "not needed"
}

// backupJoinLocked is the join's decision, taken under pendingReapMu in the same hold as backupBusyReason so two taps
// cannot both arm a waiter. It returns the log word and whether the caller starts the waiter, after its unlock.
func backupJoinLocked(why string, after int64) (word string, queue bool) {
	if !joinsRunningSave(why) {
		return "", false
	}
	armed := queuedSaveArmed
	queue = queueFollowUp(after, sealRunKind, sealRunAt, armed)
	if queue {
		queuedSaveArmed = true
	}
	return followUpWord(sealRunKind, armed, queue), queue
}

// queuedSaveStep is one waiter tick. Pure; the caller holds pendingReapMu and passes the globals in. landed is
// lastLandedSealStartedAt, the announce stamp of the last save that landed.
func queuedSaveStep(now time.Time, armedUID, liveUID, kind string, runAt time.Time, sealBusy bool, loginWin time.Time, userWaiting int32, landed, after int64) int {
	switch {
	case liveUID != armedUID:
		return queuedDropSessionEnded
	case strings.HasPrefix(kind, "logoff"):
		return queuedDropSignOut
	case landed >= after:
		return queuedDropLanded
	case kind != "" && !runAt.IsZero() && runAt.Unix() >= after && now.Sub(runAt) <= sealRunExpiry:
		return queuedDropNewerSave
	}
	if backupBusyReason(now, sealBusy, loginWin, userWaiting, kind, runAt) != "" {
		return queuedStepWait
	}
	return queuedStepStart
}

// runQueuedSave is the waiter: it holds no lock while it sleeps and no worker lane at all. The defer clears the flag
// on a panic too, or no follow-up could ever be queued again in this daemon's life.
func runQueuedSave(dest, armedUID string, after int64) {
	defer func() {
		pendingReapMu.Lock()
		queuedSaveArmed = false
		pendingReapMu.Unlock()
	}()
	drop := func(why string) { fmt.Fprintf(os.Stderr, "[logind] queued save dropped: %s\n", why) }
	deadline := time.Now().Add(queuedSaveDeadline)
	for {
		time.Sleep(queuedSavePoll)
		now := time.Now()
		if !now.Before(deadline) {
			drop("expired")
			return
		}
		_, _, liveUID := readRoamSession(dest)
		pendingReapMu.Lock()
		step := queuedSaveStep(now, armedUID, liveUID, sealRunKind, sealRunAt, sealInFlight, loginSettleUntil, userOpWaiting.Load(), lastLandedSealStartedAt.Load(), after)
		pendingReapMu.Unlock()
		switch step {
		case queuedStepWait:
		case queuedStepStart:
			switch reply := queuedSaveStart(dest); {
			case reply == "OK":
				fmt.Fprint(os.Stderr, "[logind] queued save started (follow-up to a save from before the reconnect)\n")
				return
			case strings.HasPrefix(reply, "BUSY"):
				continue
			default:
				drop("session-ended")
				return
			}
		default:
			drop(queuedDropWord[step])
			return
		}
	}
}

// replyRecorder is the connection startQueuedBackup hands to handleBackup, which only writes to it.
type replyRecorder struct {
	net.Conn
	b strings.Builder
}

func (c *replyRecorder) Write(p []byte) (int, error) { return c.b.Write(p) }

// startQueuedBackup is a plain Back up now from the waiter: the dispatcher's TryLock, then handleBackup with no stamp,
// so its claim, its goroutine, its verdict and its landed stamp have one copy. It returns the reply's first line.
func startQueuedBackup(dest string) string {
	if !sessionMu.TryLock() {
		return "BUSY"
	}
	defer sessionMu.Unlock()
	c := &replyRecorder{}
	handleBackup(c, dest)
	line, _, _ := strings.Cut(c.b.String(), "\n")
	return line
}
