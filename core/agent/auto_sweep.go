package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

// NWP-20261005-01: hold the periodic seal back while the #130 AUTO sweep materialises apps.
//
// Field-measured on frankel 0.5.41 (ticket NW-47c7b5845145, Chester: "Auto install too slow" -- 16 of 24 apps in
// seven hours): each app's own work held the worker slot for 17 s to 5 min (materializeapp) and seconds
// (odrestore), but the periodic seal held it for 4 to 47 MINUTES at a time (out: 780 s, 1374 s, 1705 s, 2827 s),
// and the sweep's ops queued behind it -- odrestore "waited 761045ms" and "waited 1285600ms" for the slot. About
// two minutes of real work per app plus up to one whole seal of waiting, i.e. the ~26 minutes per app observed.
//
// The per-app window (odMaterializeUntil, #204) cannot cover this: it is opened by MATERIALIZE-APP and CLOSED by
// RESTORE-ODDATA -- correct for one tap, but in a sweep the NEXT app's MATERIALIZE-APP arrives only after the
// chooser has installed the APK set, and a periodic seal starts in exactly that gap. userInitiatedOp's priority
// decides only who goes NEXT; it cannot interrupt a seal that already holds the slot.
//
// So the sweep holds a lease of its own: AUTO-SWEEP 1 at the start, renewed by every MATERIALIZE-APP while it is
// live, AUTO-SWEEP 0 at the end. The lease self-expires (autoSweepLease) so a chooser that dies mid-sweep cannot
// suppress seals for long, and it never holds a seal back more than autoSweepMaxSealGap: once that long has passed
// since the last seal started (or since the sweep began, if none has this session), one periodic seal runs anyway.
// Cost, accepted with Chester 2026-10-05: during a sweep a crash or power-off can lose up to that gap of changes
// instead of one sync interval. NWP-20261011-01: that gap is now the profile's choice (seal_hold.go), with this
// 30 minutes as its default, counted from the anchor the sweep shares with the materialise window (od_window.go).

var (
	// autoSweepUntil is when the sweep's lease lapses; zero when no sweep is live. Guarded by pendingReapMu.
	autoSweepUntil time.Time
	// autoSweepBegan is when the live sweep started. Guarded by pendingReapMu.
	autoSweepBegan time.Time
	// autoSweepBeganWall is autoSweepBegan on the WALL clock, for the "ended after" line only. NWP-20261127-05:
	// the monotonic reading stops while the phone sleeps (frankel 0.5.52, NW-84c1d80f5001: a 4 h 20 min sweep
	// logged 4389 s). Guarded by pendingReapMu.
	autoSweepBeganWall time.Time
	// autoSweepRuns counts the sweeps holding the lease. NWP-20261005-02: a resume kick can start a second sweep
	// while a hand-started one runs (device-seen on lynx 2026-10-05, six seconds apart); the two share one queue,
	// so whichever ends first must not release the hold the other still needs. Guarded by pendingReapMu.
	autoSweepRuns int
)

// autoSweepWallNow is the clock the "ended after" line reads: wall time (Round(0) drops the monotonic reading), so a
// suspended stretch counts (the 2026-11-04 entry in docs/product-decisions.md, NW-84c1d80f5001; the same reason as
// NWP-20260913-18's sign-out clocks). A var so a test can replace it. The lease, the hold cap and GET-SWEEP keep the
// monotonic clock on purpose: that is unchanged behaviour, not decided here.
var autoSweepWallNow = func() time.Time { return time.Now().Round(0) }

// NWP-20261113-16: the per-app outcome of a sweep, in login.log. Field-seen on frankel 0.5.48 (ticket
// NW-a805853cb888): a 3072 s sweep through 43 materialises left a report from which whether one app failed to
// fetch, failed to install or waited behind the rest could not be read -- the chooser logged each app's result only
// to logcat, which a report on a user build cannot collect. So the chooser sends AUTO-SWEEP-APP after each app and
// the daemon writes ONE line, built only from validated numbers and a token of this closed set: no package, no
// label, no path. The sweep's end then logs a count per outcome.

// autoSweepOutcomeTokens is the closed vocabulary of AUTO-SWEEP-APP, in the order the sweep's summary prints it.
var autoSweepOutcomeTokens = [...]string{"installed", "already", "restore-only", "fetch-failed", "install-failed", "stopped", "error", "busy", "needs-play", "older-copy"}

// autoSweepOutcomeCounts counts each token reported while a sweep held the lease. Guarded by pendingReapMu.
var autoSweepOutcomeCounts [len(autoSweepOutcomeTokens)]int

// autoSweepLease is how long one renewal keeps the lease live. Longer than one app's materialise plus its install
// gap (the daemon's own ceiling for one materialise is 20 minutes, but that is a stall bound, not a typical app);
// short enough that a dead chooser releases seals within minutes.
var autoSweepLease = 10 * time.Minute

// autoSweepMaxSealGap bounds how long a sweep may hold the periodic seal back when the profile chose nothing: the
// default of the seal-hold choice (seal_hold.go), which governs the sweep and the materialise window alike.
var autoSweepMaxSealGap = 30 * time.Minute

// sweepDeferReason is "auto-sweep" when a live sweep should hold this periodic seal back, "" otherwise. PURE, like
// syncDeferReason, so the whole table is tested. lastSealStart is lastSealStartedAt (unix seconds, 0 = none this
// session). maxGap is the profile's maximum (seal_hold.go); 0 is none, and the sweep then holds while its lease is
// live.
func sweepDeferReason(now, until, began time.Time, lastSealStart int64, maxGap time.Duration) string {
	if until.IsZero() || !now.Before(until) {
		return ""
	}
	ref := began
	if lastSealStart > 0 {
		if t := time.Unix(lastSealStart, 0); t.After(ref) {
			ref = t
		}
	}
	if maxGap > 0 && now.Sub(ref) >= maxGap {
		return "" // held long enough: let one seal through
	}
	return "auto-sweep"
}

// periodicSealDeferReason is syncLoop's whole decision for one PERIODIC cycle: the shared guards first, then the
// auto-sweep hold. Periodic only -- a manual "Back up now" calls syncDeferReason alone and the logoff seal consults
// neither, so a sweep never holds them back. The caller holds pendingReapMu.
func periodicSealDeferReason(now time.Time, sealBusy bool) string {
	if r := syncDeferReason(now, sealBusy, odWindowNow(now), loginSettleUntil, userOpWaiting.Load()); r != "" {
		return r
	}
	// NWP-20261011-01: counted from the anchor shared with the materialise window, so a sweep and taps that
	// overlap hold seals back for at most one autoSweepMaxSealGap between them, not one each.
	return sweepDeferReason(now, autoSweepUntil, holdAnchorLocked(autoSweepBegan), lastSealStartedAt.Load(), holdCapLocked())
}

// renewAutoSweep extends a LIVE sweep's lease; it never starts one. Called by MATERIALIZE-APP.
func renewAutoSweep(now time.Time) {
	pendingReapMu.Lock()
	if !autoSweepUntil.IsZero() && now.Before(autoSweepUntil) {
		autoSweepUntil = now.Add(autoSweepLease)
	}
	pendingReapMu.Unlock()
}

// sweepLiveFor reports whether a sweep's lease is live at now, and how long ago it began.
func sweepLiveFor(now, until, began time.Time) (bool, time.Duration) {
	if until.IsZero() || !now.Before(until) {
		return false, 0
	}
	if began.IsZero() {
		return true, 0
	}
	return true, now.Sub(began)
}

// handleGetSweep is "GET-SWEEP": "LIVE <seconds since it began>" while an auto sweep's lease is live, else "NONE".
// NWP-20261005-02: the user-0 gate's idle cold lock asks it before committing, to wait for installs (per profile,
// capped). A pure read under pendingReapMu -- on the lock-free allowlist, because the asker is a broadcast receiver
// with a 2 s budget and sessionMu can be held for minutes by the very materialise it is asking about.
func handleGetSweep(conn net.Conn) {
	pendingReapMu.Lock()
	live, age := sweepLiveFor(time.Now(), autoSweepUntil, autoSweepBegan)
	pendingReapMu.Unlock()
	if live {
		fmt.Fprintf(conn, "LIVE %d\n", int(age.Seconds()))
		return
	}
	fmt.Fprint(conn, "NONE\n")
}

// handleAutoSweep is "AUTO-SWEEP\n1\n" (the sweep starts) or "AUTO-SWEEP\n0\n" (it ended). The end of the last
// running sweep also logs its per-outcome count (NWP-20261113-16) and resets it.
func handleAutoSweep(conn net.Conn, r *bufio.Reader) {
	l, _ := r.ReadString('\n')
	now := time.Now()
	switch strings.TrimSpace(l) {
	case "1":
		pendingReapMu.Lock()
		if autoSweepUntil.IsZero() || !now.Before(autoSweepUntil) {
			// A fresh hold. A lapsed lease also drops any count it carried: those sweeps' processes are gone.
			autoSweepBegan, autoSweepRuns = now, 0
			// NWP-20261127-05: the wall start, set only at a fresh hold; a joining sweep does not move it.
			autoSweepBeganWall = autoSweepWallNow()
			autoSweepOutcomeCounts = [len(autoSweepOutcomeTokens)]int{} // NWP-20261113-16: a fresh tally too
			// NWP-20261011-01: the maximum shares one anchor with the materialise window (od_window.go). A sweep
			// that starts while a materialise lease is live continues that hold's count.
			odPruneLocked(now)
			if len(odLeases) == 0 || sealsHeldSince.IsZero() {
				noteHoldStartLocked(now)
			}
		}
		autoSweepRuns++
		runs := autoSweepRuns
		autoSweepUntil = now.Add(autoSweepLease)
		capText := holdCapText(holdCapLocked())
		pendingReapMu.Unlock()
		fmt.Fprintf(os.Stderr, "[logind] auto sweep started (%d running): periodic seals held for up to %s (NWP-20261005-01)\n",
			runs, capText)
		fmt.Fprint(conn, "OK\n")
	case "0":
		pendingReapMu.Lock()
		if autoSweepRuns > 0 {
			autoSweepRuns--
		}
		runs := autoSweepRuns
		var held time.Duration
		var outcomes string
		if runs == 0 {
			outcomes = autoSweepOutcomesLocked() // NWP-20261113-16
			// NWP-20261127-05: wall time from the first start of the hold, so a suspended stretch counts. Read only
			// while autoSweepBegan is set: resetOdWindow clears that one at a session boundary, and a late END must
			// then log 0s, not the age of a stale wall start.
			if !autoSweepBegan.IsZero() && !autoSweepBeganWall.IsZero() {
				held = autoSweepWallNow().Sub(autoSweepBeganWall)
				if held < 0 {
					held = 0 // the wall clock was set back during the sweep
				}
			}
			noteHoldEndLocked(now) // NWP-20261011-01: the hold episode's end, for the shared anchor (od_window.go)
			autoSweepUntil, autoSweepBegan, autoSweepBeganWall = time.Time{}, time.Time{}, time.Time{}
		}
		pendingReapMu.Unlock()
		if runs > 0 {
			fmt.Fprintf(os.Stderr, "[logind] auto sweep ended, %d still running: seals stay held\n", runs)
		} else {
			fmt.Fprintf(os.Stderr, "[logind] auto sweep ended after %ds: periodic seals resume\n", int(held.Seconds()))
			fmt.Fprintf(os.Stderr, "[logind] auto sweep outcomes: %s\n", outcomes)
		}
		fmt.Fprint(conn, "OK\n")
	default:
		fmt.Fprint(conn, "ERR-ARG\n")
	}
}

// autoSweepOutcomeIndex is tok's index in autoSweepOutcomeTokens, -1 for anything else.
func autoSweepOutcomeIndex(tok string) int {
	for k, t := range autoSweepOutcomeTokens {
		if t == tok {
			return k
		}
	}
	return -1
}

// sweepAppNum parses 1..maxDigits ASCII digits (no sign, no space) and requires the value in [lo, hi].
func sweepAppNum(s string, maxDigits, lo, hi int) (int, bool) {
	if len(s) == 0 || len(s) > maxDigits {
		return 0, false
	}
	v := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
	}
	if v < lo || v > hi {
		return 0, false
	}
	return v, true
}

// parseSweepApp validates AUTO-SWEEP-APP's four lines: 1 <= i <= n <= 9999, an outcome of the closed set (its
// index k), 0 <= ms <= 86400000. PURE.
func parseSweepApp(iRaw, nRaw, outRaw, msRaw string) (i, n, k, ms int, ok bool) {
	var okI, okN, okMs bool
	i, okI = sweepAppNum(iRaw, 4, 1, 9999)
	n, okN = sweepAppNum(nRaw, 4, 1, 9999)
	ms, okMs = sweepAppNum(msRaw, 8, 0, 86400000)
	k = autoSweepOutcomeIndex(outRaw)
	if !okI || !okN || !okMs || k < 0 || i > n {
		return 0, 0, 0, 0, false
	}
	return i, n, k, ms, true
}

// autoSweepOutcomesLocked is the sweep's summary -- "<tok>=<count>" for each nonzero count in the fixed order, or
// "none reported" -- and resets the counts. The caller holds pendingReapMu.
func autoSweepOutcomesLocked() string {
	var parts []string
	for k, c := range autoSweepOutcomeCounts {
		if c > 0 {
			parts = append(parts, fmt.Sprintf("%s=%d", autoSweepOutcomeTokens[k], c))
		}
	}
	autoSweepOutcomeCounts = [len(autoSweepOutcomeTokens)]int{}
	if len(parts) == 0 {
		return "none reported"
	}
	return strings.Join(parts, " ")
}

// handleAutoSweepApp is "AUTO-SWEEP-APP\n<i>\n<n>\n<outcome>\n<ms>\n" -> "OK" | "ERR-ARG": app i of the sweep's n
// ended with outcome after ms milliseconds. NWP-20261113-16. On OK it logs ONE line to login.log, built from the
// three validated numbers and the token taken from autoSweepOutcomeTokens (never the wire string), and counts the
// outcome while a sweep holds the lease; a line with no live sweep is logged but not counted. Anything else --
// a bad number, a token outside the set, a line cut short -- answers ERR-ARG and logs nothing. It never renews the
// lease (MATERIALIZE-APP does) and touches no store and no session file: it is on the lock-free allowlist.
func handleAutoSweepApp(conn net.Conn, r *bufio.Reader) {
	var f [4]string
	for x := range f {
		l, err := r.ReadString('\n')
		if err != nil {
			fmt.Fprint(conn, "ERR-ARG\n")
			return
		}
		f[x] = strings.TrimRight(l, "\r\n") // not TrimSpace: a token with a space is refused
	}
	i, n, k, ms, ok := parseSweepApp(f[0], f[1], f[2], f[3])
	if !ok {
		fmt.Fprint(conn, "ERR-ARG\n")
		return
	}
	now := time.Now()
	pendingReapMu.Lock()
	if !autoSweepUntil.IsZero() && now.Before(autoSweepUntil) {
		autoSweepOutcomeCounts[k]++
	}
	pendingReapMu.Unlock()
	fmt.Fprintf(os.Stderr, "[logind] auto sweep app %d/%d: %s in %dms\n", i, n, autoSweepOutcomeTokens[k], ms)
	fmt.Fprint(conn, "OK\n")
}
