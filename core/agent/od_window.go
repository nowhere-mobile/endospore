package main

import (
	"fmt"
	"os"
	"time"
)

// NWP-20261011-01: the on-demand materialise window (odMaterializeUntil, #204) covers the WHOLE tap.
//
// The window holds periodic seals back so that a tapped app's own worker ops do not queue behind one: the
// fetch (MATERIALIZE-APP -> worker `materializeapp`) and, after the chooser has installed the APK set, the
// data move and permission grant (RESTORE-ODDATA -> worker `odrestore`). Until this slice it was a flat 90 s,
// armed before the fetch and re-armed for 90 s after it. A large app outlives that twice over: the fetch of a
// several-hundred-MB APK set runs for minutes, and the chooser's PackageInstaller commit of the same set ran
// ~4 minutes on lynx (gms, 243 MB). Once the 90 s lapsed a periodic seal took the worker slot, and odrestore
// waited for the whole seal -- login.log shows waits of 285 s to 21 minutes.
//
// LEASES ARE PER PACKAGE (odLeases). The window is open while any package's lease is live; odMaterializeUntil
// is kept equal to the latest of them, so every reader of it is unchanged. A package's lease has three phases:
//
//  1. FETCH. MATERIALIZE-APP opens the package's lease for odFetchLease and, while its worker op is in flight
//     (waiting for the slot or running), renews it every odRenewEvery. The renewal goroutine has exited before
//     the lease is settled, so a late renewal can never re-open a lease that has just been ended.
//  2. INSTALL. A fetch that succeeded AND whose reply reached the chooser extends the lease to odInstallLease,
//     the chooser's own hard bound on waiting for a PackageInstaller commit (UnarchiveService.installApks,
//     10 minutes). That package's RESTORE-ODDATA then ends it.
//  3. END. A failed fetch ends the package's lease at once. So does a reply the chooser was no longer there to
//     read (it timed out or died): nobody is going to install. A chooser that dies AFTER reading OK leaves the
//     install lease to lapse on its own. Ending one package's lease never touches another's: a second tap that
//     fails, or the first tap's RESTORE-ODDATA, leaves the other's install hold alone.
//
// EVERY PATH THAT ENDS A SESSION, OR BEGINS ONE, RESETS THE WINDOW (resetOdWindow): all leases go, the shared
// anchor below goes, the auto sweep's lease goes (the sweep belongs to the session whose chooser ran it), and
// odWindowEpoch is bumped, so a renewal or install lease the old session still has in flight cannot re-open one. Ending: a LOGOUT whose seal landed and a throwaway's LOGOUT (never one that fails and
// re-arms the session), DELETE, ROLLBACK, the gate's cold-lock wipe (CLAIM-COLDLOCK), and a marker naming a user
// that is gone. Beginning: ROAM-IN, ROAM-IN-OFFLINE, and resetSessionSignals (CREATE, the legacy LOGIN). The
// daemon dying ends them all trivially: they live only in memory.
//
// HOW LONG ONE TAP HOLDS SEALS BACK: for its fetch -- the worker op's wait for the slot plus its run, which the
// worker's stall watchdog ends after 150 s without progress and its hard cap after 60 minutes -- plus at most
// odInstallLease (10 minutes) after OK reaches the chooser. And never past THE MAXIMUM below, whichever comes
// first: in practice min(fetch + 10 min, the profile's maximum) -- 30 minutes unless the profile chose otherwise.
//
// THE MAXIMUM, AND ITS ONE ANCHOR. No periodic seal is held back -- by materialise leases, an auto sweep's lease
// (NWP-20261005-01), or both -- once the maximum has passed since the later of sealsHeldSince and the last seal
// start; then one seal runs anyway. The maximum is the PROFILE's choice (seal_hold.go): about 2 minutes, 10, 30
// (the default), or none at all ("as long as materialisation runs", where only the leases ending ends the hold). sealsHeldSince is ONE anchor, shared by this window and the sweep
// (periodicSealDeferReason passes it to sweepDeferReason): the start of the current hold EPISODE. An episode
// begins when a hold begins with none live AND a seal has started since the previous episode's holds all ended
// (holdsEndedAt); a hold that begins while another is live, or after a pause in which no seal started, continues
// it. So overlapping holds cannot each count their own maximum, and a pause cannot restart the count when
// nothing was sealed in it. No grace period is needed: the seal, not the length of the pause, decides.
//
// ⚠ THE COST OF THAT BOUND, STATED: it is counted from the last seal START, so a tap right after a long seal gets
// little protection. A seal that took 25 minutes leaves a tap starting as it ends about 5 minutes before the next
// periodic seal may take the slot, and its odrestore can then wait for that seal, as before this slice. That is
// the promise working as decided, not a defect; a shorter maximum leaves less, "as long as materialisation runs"
// leaves the whole tap.
//
// ONLY THE PERIODIC SEAL IS HELD. "Back up now" ignores this window, as the sweep record already states for the
// sweep: a manual backup is the user's explicit choice, and if it takes the worker slot during an install, that
// install's odrestore waits for it. The logoff seal never consulted the window and still does not: a logoff during
// a tap waits only for the worker op actually running (bounded by the worker's own stall watchdog), as before.

var (
	// odLeases maps a package to the end of its lease. Guarded by pendingReapMu.
	odLeases = map[string]time.Time{}
	// sealsHeldSince is when the first hold (a materialise lease or an auto sweep) since the last seal start
	// began; zero when there has been none. The one anchor of the maximum (see above). Guarded by pendingReapMu.
	sealsHeldSince time.Time
	// holdsEndedAt is the latest instant a hold (a lease, or the sweep) ended; it decides whether the next hold
	// begins a new episode. Guarded by pendingReapMu.
	holdsEndedAt time.Time
	// odWindowEpoch counts resets. An extension carrying an older epoch belongs to a session that has ended
	// and is dropped. Guarded by pendingReapMu.
	odWindowEpoch uint64
)

var (
	// odFetchLease is how long one open or renewal keeps a package's lease live during its fetch. Also the lease
	// RESTORE-ODDATA arms when it arrives with none open (the install-heal path, NWP-20260903-11).
	odFetchLease = 90 * time.Second
	// odRenewEvery is how often a materialise still in flight renews its fetch lease. Well inside the lease, so a
	// renewal that runs late by a tick or two never lets the lease lapse mid-fetch.
	odRenewEvery = 30 * time.Second
	// odInstallLease covers the chooser's install after a successful fetch: its hard bound on waiting for the
	// PackageInstaller commit is 10 minutes (UnarchiveService.installApks). It is also how long a chooser that
	// dies after reading OK can hold seals back.
	odInstallLease = 10 * time.Minute
)

// noteHoldEndLocked records that a hold ended at t. The caller holds pendingReapMu.
func noteHoldEndLocked(t time.Time) {
	if t.After(holdsEndedAt) {
		holdsEndedAt = t
	}
}

// noteHoldStartLocked is called when a hold begins with no other hold live -- a materialise lease while no lease
// and no sweep is live, or a sweep while no lease is live. It begins a new episode (moves the anchor to now) only
// when there was none, or a seal has started since the previous episode's holds all ended; otherwise the new
// hold continues the old count. The caller holds pendingReapMu.
func noteHoldStartLocked(now time.Time) {
	if !autoSweepUntil.IsZero() && !now.Before(autoSweepUntil) {
		noteHoldEndLocked(autoSweepUntil) // a sweep whose lease lapsed ended then
	}
	if sealsHeldSince.IsZero() {
		sealsHeldSince = now
		return
	}
	if ls := lastSealStartedAt.Load(); ls > 0 && !time.Unix(ls, 0).Before(holdsEndedAt.Truncate(time.Second)) {
		sealsHeldSince = now
	}
}

// holdAnchorLocked is the anchor the maximum counts from, falling back to fallback when no hold has noted one
// (a sweep lease set directly). The caller holds pendingReapMu.
func holdAnchorLocked(fallback time.Time) time.Time {
	if sealsHeldSince.IsZero() {
		return fallback
	}
	return sealsHeldSince
}

// odHoldRef is the instant the maximum counts from -- the later of the anchor and the last seal start (unix
// seconds, 0 = none) -- and which of the two it is, for the log.
func odHoldRef(since time.Time, lastSealStart int64) (time.Time, string) {
	ref, why := since, "holds (materialise windows, auto sweeps) have kept seals back since"
	if lastSealStart > 0 {
		if t := time.Unix(lastSealStart, 0); t.After(ref) {
			ref, why = t, "the last seal started"
		}
	}
	return ref, why
}

// odWindowFor is the materialise window as the periodic seal must see it: until while it is live and the hold
// has not yet reached maxGap (from odHoldRef), zero otherwise. maxGap 0 is no maximum: the window then holds for as
// long as it is live. PURE, like sweepDeferReason.
func odWindowFor(now, until, since time.Time, lastSealStart int64, maxGap time.Duration) time.Time {
	if until.IsZero() || !now.Before(until) {
		return time.Time{}
	}
	if ref, _ := odHoldRef(since, lastSealStart); maxGap > 0 && !ref.IsZero() && now.Sub(ref) >= maxGap {
		return time.Time{} // held long enough: let one seal through
	}
	return until
}

// sweepLiveLocked reports whether an auto sweep's lease is live at now. The caller holds pendingReapMu.
func sweepLiveLocked(now time.Time) bool {
	return !autoSweepUntil.IsZero() && now.Before(autoSweepUntil)
}

// odWindowNow is odWindowFor over the live state. The caller holds pendingReapMu.
func odWindowNow(now time.Time) time.Time {
	return odWindowFor(now, odMaterializeUntil, sealsHeldSince, lastSealStartedAt.Load(), holdCapLocked())
}

// odCapNote says why a live window no longer holds the periodic seal, or "" when it is not live or still holds.
// The caller holds pendingReapMu.
func odCapNote(now time.Time) string {
	if !now.Before(odMaterializeUntil) || !odWindowNow(now).IsZero() {
		return ""
	}
	ref, why := odHoldRef(sealsHeldSince, lastSealStartedAt.Load())
	return fmt.Sprintf("%s %s ago, the maximum is %s", why, now.Sub(ref).Round(time.Second), holdCapText(holdCapLocked()))
}

// odPruneLocked drops lapsed leases and recomputes odMaterializeUntil. The caller holds pendingReapMu.
func odPruneLocked(now time.Time) {
	odMaterializeUntil = time.Time{}
	for pkg, u := range odLeases {
		if !now.Before(u) {
			delete(odLeases, pkg)
			noteHoldEndLocked(u)
		} else if u.After(odMaterializeUntil) {
			odMaterializeUntil = u
		}
	}
}

// extendOdLeaseLocked moves pkg's lease out to now+lease, never in. A lease opening with no hold live notes a
// hold start. A call carrying an epoch older than odWindowEpoch does nothing and reports false. The caller holds
// pendingReapMu.
func extendOdLeaseLocked(pkg string, epoch uint64, now time.Time, lease time.Duration) bool {
	if epoch != odWindowEpoch {
		return false
	}
	odPruneLocked(now)
	if len(odLeases) == 0 {
		switch {
		case !sweepLiveLocked(now):
			noteHoldStartLocked(now)
		case sealsHeldSince.IsZero(): // a live sweep that noted no anchor: the hold began with it
			sealsHeldSince = holdAnchorLocked(autoSweepBegan)
			if sealsHeldSince.IsZero() {
				sealsHeldSince = now
			}
		}
	}
	if until := now.Add(lease); odLeases[pkg].Before(until) {
		odLeases[pkg] = until
	}
	odPruneLocked(now)
	return true
}

// extendOdLease is extendOdLeaseLocked under pendingReapMu.
func extendOdLease(pkg string, epoch uint64, now time.Time, lease time.Duration) bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return extendOdLeaseLocked(pkg, epoch, now, lease)
}

// armOdLease opens (or extends) pkg's lease in the CURRENT epoch. RESTORE-ODDATA's arm.
func armOdLease(pkg string, now time.Time, lease time.Duration) {
	pendingReapMu.Lock()
	extendOdLeaseLocked(pkg, odWindowEpoch, now, lease)
	pendingReapMu.Unlock()
}

// endOdLeaseLocked ends pkg's lease and no other. The caller holds pendingReapMu.
func endOdLeaseLocked(pkg string, now time.Time) {
	if _, had := odLeases[pkg]; had {
		delete(odLeases, pkg)
		noteHoldEndLocked(now)
	}
	odPruneLocked(now)
}

// endOdLease is endOdLeaseLocked under pendingReapMu. RESTORE-ODDATA's close.
func endOdLease(pkg string, now time.Time) {
	pendingReapMu.Lock()
	endOdLeaseLocked(pkg, now)
	pendingReapMu.Unlock()
}

// resetOdWindow ends every hold at a session boundary: it drops every lease, the anchor and the auto sweep's lease,
// and bumps the epoch, so whatever the old session still has in flight cannot re-open the window. An AUTO-SWEEP 0
// the old session's chooser sends late finds no sweep to end (handleAutoSweep floors its count at zero). It also
// forgets the old profile's seal-hold choice (seal_hold.go) and its save mode with the gate's last network report
// (save_mode.go): until the new session's are read, the defaults apply.
func resetOdWindow() {
	pendingReapMu.Lock()
	odLeases = map[string]time.Time{}
	odMaterializeUntil, sealsHeldSince, holdsEndedAt = time.Time{}, time.Time{}, time.Time{}
	autoSweepUntil, autoSweepBegan, autoSweepRuns = time.Time{}, time.Time{}, 0
	sealHoldValue = ""
	saveModeValue, saveNetUnmetered, saveNetAt = "", false, time.Time{}
	odWindowEpoch++
	pendingReapMu.Unlock()
}

// beginOdMaterialise opens pkg's lease for one MATERIALIZE-APP and returns the epoch its renewals carry.
func beginOdMaterialise(pkg string, now time.Time) uint64 {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	extendOdLeaseLocked(pkg, odWindowEpoch, now, odFetchLease)
	return odWindowEpoch
}

// odRenewHook runs between a renewal tick and its extension; a seam for the stray-renewal test.
var odRenewHook = func() {}

// renewOdWhile renews pkg's fetch lease every odRenewEvery until stop is closed.
func renewOdWhile(pkg string, epoch uint64, stop <-chan struct{}) {
	t := time.NewTicker(odRenewEvery)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case now := <-t.C:
			odRenewHook()
			extendOdLease(pkg, epoch, now, odFetchLease)
		}
	}
}

// How a MATERIALIZE-APP ended, for settleOdMaterialise.
type odOutcome int

const (
	odAbandoned  odOutcome = iota // the reply did not reach the chooser (or the handler never got that far)
	odFailed                      // the reply reached the chooser and was not OK
	odInstalling                  // OK reached the chooser, which now installs and then sends RESTORE-ODDATA
)

func (o odOutcome) String() string {
	switch o {
	case odInstalling:
		return "fetched, held for the install"
	case odFailed:
		return "fetch failed, its lease ended"
	}
	return "reply not read (chooser gone), its lease ended"
}

// settleOdMaterialise ends one MATERIALIZE-APP's fetch lease: odInstalling extends pkg's lease to the install
// lease (in its own epoch only), anything else ends pkg's lease. Other packages' leases are untouched.
func settleOdMaterialise(pkg string, epoch uint64, outcome odOutcome, now time.Time) {
	pendingReapMu.Lock()
	what := outcome.String()
	if outcome == odInstalling {
		if !extendOdLeaseLocked(pkg, epoch, now, odInstallLease) {
			what = "fetched after its session ended, not held"
		}
	} else if epoch == odWindowEpoch {
		endOdLeaseLocked(pkg, now)
	}
	until, n := odMaterializeUntil, len(odLeases)
	pendingReapMu.Unlock()
	left := "none"
	if until.After(now) {
		left = until.Sub(now).Round(time.Second).String()
	}
	fmt.Fprintf(os.Stderr, "[logind] materialise window: %s; %d lease(s) live, window %s left (NWP-20261011-01)\n",
		what, n, left)
}
