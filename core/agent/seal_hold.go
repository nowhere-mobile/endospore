package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// NWP-20261011-01 (Chester, 2026-10-11): how long materialisation may hold the periodic seal back is the PROFILE's
// choice -- "lets keep the default 30mins but give user option to change to: i) leave as is (~2mins) ii) 10 mins
// iii) 30 mins iv) as long as materialization runs".
//
// It sets the ONE maximum both holds are read against (od_window.go): the materialise window of a tap AND the #130
// auto sweep's lease. Both are materialisation, so one choice governs both, counted from the one shared anchor
// (sealsHeldSince, or the last seal start if later).
//
//	"2"   about 2 minutes -- the hold this slice replaced (a 90 s window, re-armed once): a periodic seal may take
//	      the worker slot about 2 minutes into a long install, and the install's odrestore then waits for it.
//	"10"  10 minutes.
//	"30"  30 minutes, the DEFAULT. Absent, unreadable or unknown values all mean this.
//	"run" as long as materialisation runs: NO time cap. The hold still ends when no lease is live -- an install
//	      lease lapses 10 minutes after OK and a dead chooser's lease lapses on its own -- but while taps or a sweep
//	      keep leases live, no periodic seal runs. ⚠ WITH THIS OPTION A CRASH OR POWER-OFF CAN LOSE EVERYTHING
//	      SINCE THE LAST SEAL THAT STARTED BEFORE THE TAP SEQUENCE OR SWEEP BEGAN.
//
// WHERE IT LIVES -- the #129 "download over mobile data" mechanism (NWP-20261005-08), for the same reasons: it is
// per profile and must roam, so the chooser keeps it in its own files dir in the roamed user
// (com.nowhere.chooser/files/nowhere-seal-hold, which seals and roams with the profile); the daemon cannot read that
// file in place (the `nowhere` domain is MLS-refused /data/user/<N>), so roamd surfaces it at sign-in into the state
// dir as "<uid> <value>", and the Profile screen's SET-SEAL-HOLD keeps it current mid-session. The sync-interval
// setting was not the model: it is one device-wide file (/data/nowhere/sync-interval) that does not roam.
//
// A CHANGE APPLIES AT THE NEXT SEAL DECISION: SET-SEAL-HOLD writes the state file AND applies the value in memory,
// and syncLoop re-reads the file before every periodic decision. No restart is involved. Both run under sealHoldMu,
// each as one step (file and memory together), so they are ordered: a SET that lands between syncLoop's read and
// its apply can no longer be reverted for a cycle, and two SETs leave file and memory agreeing on the later one.
// SET-SEAL-HOLD is on the concurrent-safe list (it touches only that file and pendingReapMu), so it never queues
// behind a materialise that holds sessionMu for minutes -- it used to, and the chooser's read gave up and told the
// user "next sign-in" while the queued handler applied the value later anyway.
//
// THE SWEEP TOO (Chester, 2026-10-11: "Taps and the sweep"). The one choice caps the #130 auto sweep exactly as it
// caps a tap, so "About 2 minutes" lets a periodic seal take the worker slot about 2 minutes into a sweep, and the
// sweep's remaining apps then wait behind that seal: an Auto install can take longer. The sweep's own fixed
// 30 minutes (autoSweepMaxSealGap, NWP-20261005-01) survives only as the default.

// sealHoldOut is the state-dir file holding "<uid> <value>" for the live session.
const sealHoldOut = "seal-hold.out"

// sealHoldValue is the choice the periodic decision applies: "2", "10", "30", "run", or "" (not known: the
// default). Guarded by pendingReapMu.
var sealHoldValue string

// sealHoldMu orders the two writers of the choice -- SET-SEAL-HOLD and syncLoop's re-read -- so each writes file and
// memory as one step. Lock order: sealHoldMu, then pendingReapMu; never the reverse.
var sealHoldMu sync.Mutex

// normSealHold returns v if it is one of the four choices, "" otherwise.
func normSealHold(v string) string {
	switch v = strings.TrimSpace(v); v {
	case "2", "10", "30", "run":
		return v
	}
	return ""
}

// sealHoldGap maps a choice to the maximum hold: a positive duration, or 0 for no time cap ("run"). Anything that
// is not one of the four choices is the 30-minute default.
func sealHoldGap(v string) time.Duration {
	switch normSealHold(v) {
	case "2":
		return 2 * time.Minute
	case "10":
		return 10 * time.Minute
	case "30":
		return 30 * time.Minute
	case "run":
		return 0
	}
	return autoSweepMaxSealGap // the default: 30 minutes
}

// holdCapLocked is the maximum the live choice sets, for a materialise window and the auto sweep alike; 0 = none.
// The caller holds pendingReapMu.
func holdCapLocked() time.Duration { return sealHoldGap(sealHoldValue) }

// holdWakeAfter is how long syncLoop should sleep after deferring a seal for a hold that counts from ref with
// maximum maxGap: until the maximum lets a seal through, if that comes before a whole interval would, else the
// interval. A deferred cycle used to sleep the whole interval, so "About 2 minutes" held a seal for up to one
// interval (2 minutes by default, up to a day if the profile set one) past its own maximum. PURE.
func holdWakeAfter(now, ref time.Time, maxGap, interval time.Duration) time.Duration {
	if maxGap <= 0 || ref.IsZero() {
		return interval // no maximum: only the hold ending releases the seal, and that is not a time we know
	}
	left := ref.Add(maxGap).Sub(now) + time.Second // a second past the edge, so the decision is on the far side
	switch {
	case left < time.Second:
		return time.Second
	case left < interval:
		return left
	}
	return interval
}

// holdWakeLocked is holdWakeAfter for the hold that deferred this cycle (reason "materialise" or "auto-sweep"); any
// other reason sleeps the interval. The caller holds pendingReapMu.
func holdWakeLocked(now time.Time, reason string, interval time.Duration) time.Duration {
	ls := lastSealStartedAt.Load()
	switch reason {
	case "materialise":
		ref, _ := odHoldRef(sealsHeldSince, ls)
		return holdWakeAfter(now, ref, holdCapLocked(), interval)
	case "auto-sweep":
		ref, _ := odHoldRef(holdAnchorLocked(autoSweepBegan), ls)
		return holdWakeAfter(now, ref, holdCapLocked(), interval)
	}
	return interval
}

// sealHoldRefreshHook runs between refreshSealHold's read and its apply; a seam for the ordering test.
var sealHoldRefreshHook = func() {}

// refreshSealHold re-reads session user uid's choice from the state dir and applies it, as one step under
// sealHoldMu. It reports whether the maximum changed, and the maximum's text for the log.
func refreshSealHold(dest, uid string) (bool, string) {
	sealHoldMu.Lock()
	defer sealHoldMu.Unlock()
	v := sealHoldFor(dest, uid)
	sealHoldRefreshHook()
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return applySealHoldLocked(v), holdCapText(holdCapLocked())
}

// handleSetSealHold is "SET-SEAL-HOLD\n<2|10|30|run>\n<user id>\n": record the live session's choice and apply it,
// as one step under sealHoldMu. The chooser sends the Android user it runs as, and a SET is applied only to the
// session of that user: one that arrives late, after its session ended and another began, must not set the new
// profile's choice. ERR when there is no live session, the user is not the session's, or the file cannot be
// written; the chooser then says the choice applies from the next sign-in, which the roaming copy makes true.
func handleSetSealHold(dest, v, uid string) (string, bool, string) {
	sealHoldMu.Lock()
	defer sealHoldMu.Unlock()
	nm, _, su := readRoamSession(dest)
	if nm == "" || su == "" || strings.TrimSpace(uid) != su {
		return "ERR", false, ""
	}
	if err := setSealHold(dest, su, v); err != nil {
		dlog("SET-SEAL-HOLD: %v", err)
		return "ERR", false, ""
	}
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return "OK", applySealHoldLocked(v), holdCapText(holdCapLocked())
}

// holdCapText renders a maximum for the log.
func holdCapText(gap time.Duration) string {
	if gap <= 0 {
		return "as long as materialisation runs"
	}
	return gap.String()
}

// sealHoldFor is session user uid's choice from the state dir, "" when there is none for that uid.
func sealHoldFor(dest, uid string) string {
	if uid == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(dest, sealHoldOut))
	if err != nil {
		return ""
	}
	f := strings.Fields(string(b))
	if len(f) != 2 || f[0] != uid {
		return "" // another session's value is never answered for this one
	}
	return normSealHold(f[1])
}

// setSealHold records session user uid's choice in the state dir (the SET-SEAL-HOLD verb). An unknown value is
// recorded as the default.
func setSealHold(dest, uid, v string) error {
	if v = normSealHold(v); v == "" {
		v = "30"
	}
	return os.WriteFile(filepath.Join(dest, sealHoldOut), []byte(uid+" "+v+"\n"), 0o600)
}

// applySealHoldLocked makes v the live choice and reports whether the maximum changed. The caller holds
// pendingReapMu.
func applySealHoldLocked(v string) bool {
	v = normSealHold(v)
	changed := sealHoldGap(v) != sealHoldGap(sealHoldValue)
	sealHoldValue = v
	return changed
}
