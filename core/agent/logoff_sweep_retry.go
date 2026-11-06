package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// NWP-20261117-03 (decided 2026-10-28, docs/product-decisions.md, the fifth bullet): a sign-out whose media sweep
// did not verify retries the sweep by itself, bounded, instead of leaving the user to tap Log off again. On frankel
// (NW-a17e164b51d3) the passes left 90, then 46, then 24 mounts: every attempt made progress, and every one was
// refused, one tap at a time. THE GUARD STAYS: the loop only re-runs the sweep. Nothing here seals, and the caller
// still seals only after a sweep that answered OK -- never over a surviving mount.

// The numbers are this slice's (NWP-20261117-03). Each gap is longer than the last, and the three gaps (50 s) plus
// their sweeps fit inside logoffStallLimit, because every gap refreshes sealProgAt at least once a second.
var (
	logoffSweepRetries    = 3
	logoffSweepRetryGaps  = []time.Duration{5 * time.Second, 15 * time.Second, 30 * time.Second}
	logoffSweepRetryStep  = time.Second               // the longest silence a gap allows the stall watchdog
	logoffSweepRetrySleep = sleepRefreshingStallClock // the gap; tests replace it
)

// sleepRefreshingStallClock sleeps d in steps of at most logoffSweepRetryStep and, after each step, takes the
// liveness signal as the sweep's own callback does: sealProgAt, never sealProg (the "Saving…" bar is the seal's).
// So the #125 stall watchdog never reads a gap as silence.
func sleepRefreshingStallClock(d time.Duration) {
	for d > 0 {
		s := min(d, logoffSweepRetryStep)
		time.Sleep(s)
		d -= s
		pendingReapMu.Lock()
		sealProgAt = time.Now()
		pendingReapMu.Unlock()
	}
}

// sweepMountsLeft reads the n in "ERR-MEDIA-SWEEP <n>", the mounts roamd's sweepmedia left. ok is false for UNREAD,
// a worker error (ERR-TIMEOUT, ERR-WORKER-BUSY, ...), no number, or a negative number, and n is then 0: an
// unreadable count is never "fewer", and only the ok flags stop a number followed by an unreadable reply from
// reading as a fall to 0.
func sweepMountsLeft(reply string) (n int, ok bool) {
	rest, found := strings.CutPrefix(reply, errMediaSweep+" ")
	if !found {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(rest))
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

// logoffSweepGap is the gap before retry i (1-based). The index is clamped to the last gap.
func logoffSweepGap(i int) time.Duration {
	return logoffSweepRetryGaps[min(i, len(logoffSweepRetryGaps))-1]
}

// logoffSweepWithRetries runs the logoff's media sweep (run) and, while it does not answer OK, runs it again:
// retry 1 always follows a failed first attempt; each later retry runs only when the last attempt left strictly
// fewer mounts than the one before it; at most logoffSweepRetries retries. Before each retry it stops when a newer
// sign-out of uid has claimed (that sign-out owns the session) or the #125 stall watchdog has un-stuck the screen
// (the user was told they are signed in, so a sweep would tear down the media of a session in use). It returns the
// last attempt's reply, for the caller's failure arm or seal exactly as one sweep's reply was.
//
// Counting: every failed attempt but the last is counted here (noteMediaSweepFailed), just before the retry that
// replaces it; the caller's failure arm counts the last (logoffSweepFailed). So a stop after any retry licenses
// RESTART-UNSAVED (restartUnsavedAfter). A logoff that stops before a retry counts nothing here: a superseded
// logoff acts on nothing it learns (logoffVerdictSuperseded).
//
// A retry after a sweep that timed out answers ERR-WORKER-BUSY while the abandoned sweep still runs
// (runWorkerHeld's abandoned-lane check): unreadable, so the loop stops after that one retry.
func logoffSweepWithRetries(uid string, claim uint64, name string, run func() string) string {
	r := run() // attempt 1: the sweep every logoff ran before this slice
	if r == "OK" {
		return r
	}
	prev, prevOK := 0, false
	cur, curOK := sweepMountsLeft(r)
	before := "none" // the count of the attempt before the last, as logged; attempt 1 has none
	for i := 1; ; i++ {
		why := "first retry"
		if i > 1 {
			fell := prevOK && curOK && cur < prev
			if !fell {
				stop := "did not fall"
				if !prevOK || !curOK {
					stop = "unreadable"
				}
				logSweepRetryStop(uid, i-1, curOK, cur, r, before, stop)
				return r
			}
			why = "the count fell"
		}
		if i > logoffSweepRetries {
			logSweepRetryStop(uid, i-1, curOK, cur, r, before, "three retries")
			return r
		}
		gap := logoffSweepGap(i)
		fmt.Fprintf(os.Stderr, "[logind] logout user %s: media sweep retry %d of %d in %s (%s; mounts left %s, "+
			"before %s) (NWP-20261117-03)\n", uid, i, logoffSweepRetries, gap, why, sweepCountText(curOK, cur, r), before)
		logoffSweepRetrySleep(gap)
		if logoffVerdictSuperseded(uid, claim, "media sweep retry", r) {
			logSweepRetryStop(uid, i-1, curOK, cur, r, before, "superseded")
			return r
		}
		pendingReapMu.Lock()
		unstuck := sealUnstuck
		pendingReapMu.Unlock()
		if unstuck {
			logSweepRetryStop(uid, i-1, curOK, cur, r, before, "un-stuck")
			return r
		}
		noteMediaSweepFailed(name, uid) // the attempt this retry replaces
		prev, prevOK, before = cur, curOK, sweepCountText(curOK, cur, r)
		r = run()
		if r == "OK" {
			fmt.Fprintf(os.Stderr, "[logind] logout user %s: media sweep retries stop after %d: verified (mounts left "+
				"before %s) (NWP-20261117-03)\n", uid, i, before)
			return r
		}
		cur, curOK = sweepMountsLeft(r)
	}
}

// sweepCountText prints a mount count, or "unreadable" with the reply quoted (a reply holds no mount path).
func sweepCountText(ok bool, n int, reply string) string {
	if ok {
		return strconv.Itoa(n)
	}
	return fmt.Sprintf("unreadable %q", reply)
}

// logSweepRetryStop logs why the retries stop, with the last attempt's count and the one before it.
func logSweepRetryStop(uid string, retries int, curOK bool, cur int, reply, before, why string) {
	fmt.Fprintf(os.Stderr, "[logind] logout user %s: media sweep retries stop after %d: %s (mounts left %s, before "+
		"%s) (NWP-20261117-03)\n", uid, retries, why, sweepCountText(curOK, cur, reply), before)
}
