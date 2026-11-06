package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// NWP-20261011-04: THE LOGOFF CUTOFF. docs/product-decisions.md, 2026-10-10, "logoff stops the session's apps at its
// start, before anything is sealed": the first step of a sign-out force-stops every package of the session except the
// chooser, Play services included; then the flush, then the seal. Nothing new can arrive after the cutoff, so nothing
// can be acknowledged and then lost: a message the phone has not received waits on the sender's server.
//
// WHY. The logoff seal walks the scopes in a fixed order (vault/CE first, then #de, #media, #sys, #apps) while every
// app, sandboxed Play/FCM and the network stay live until removeUser. Anything an app wrote after the vault walk --
// minutes on a large profile -- was not sealed, and the loss that matters is a message received and ACKed in that
// window: the server dropped it and the reap destroyed the only copy (docs/backlog.md, "A message delivered while
// logging off can be lost").
//
// THE SPLIT. roamd does the work (`cutoff`, `cutoffwake` in nowhere_roamd.sh): it is the side that can run `am` and
// `pm` (the daemon's domain has no service_manager find on activity -- the #151 silence-alarm note), and its comments
// carry the exclusion set and why each entry is on it. The daemon does the SEQUENCING, because handleLogout's goroutine
// already is the logoff: it orders the sweep, the sync and the seal, and owns every exit that keeps the session.
//
// ⚠ THE CUTOFF IS NEVER A GATE. Whatever roamd answers, the logoff goes on to its seal: a cutoff that could not list
// the packages, or left one running, seals exactly as every logoff did before this slice. Refusing to sign out
// because an app would not stop would strand the user over a protection the decision adds on top.

// The #125 stall watchdog's clock in handleLogout (DIA-20260811-06), hoisted from constants inside it so a test can
// drive the unstick. Production never assigns them. logoffFlushWait is handleLogout's onStop window before the
// cutoff (DIA-20260623-01), hoisted with them (round 7) so the retry tests do not spend it on every sign-out.
// logoffSync is the flush between the sweep and the seal (NWP-20261017-12), hoisted so a test whose watchdog clock
// spans it can replace it: sync(2) waits on every dirty page of the HOST, 3.5 s measured on the shared CI VM.
var (
	logoffStallLimit   = 6 * time.Minute  // no sign of life at all -> fail-safe unstick
	logoffStallHardCap = 90 * time.Minute // absolute backstop for a progress-emitting livelock
	logoffStallTick    = 15 * time.Second
	logoffFlushWait    = 2 * time.Second // lets the last app's onStop commit its pending writes before anything stops it
	logoffSync         = syscall.Sync
)

// logoffStallTicker is the #125 watchdog's tick source in handleLogout, hoisted (NWP-20261110-08) so a test can step
// it by hand instead of racing a real ticker on a loaded runner. It returns the tick channel and its stop. Production
// never assigns it.
var logoffStallTicker = func(d time.Duration) (<-chan time.Time, func()) {
	t := time.NewTicker(d)
	return t.C, t.Stop
}

// logoffCutoff runs roamd's `cutoff` for uid and logs its verdict. It carries no passphrase (roamd needs none to stop
// packages, and a request file that does not hold one cannot leak one). Its liveness counts for the #125 stall
// watchdog the way the sweep's does: it refreshes sealProgAt without touching sealProg, which belongs to the seal.
//
// ⚠ THE ALARM OWNER RIDES roam.req LINE 7 (the per-op srcunit slot, as sealdelta and materializeapp use it) and roamd
// adds it to the keep-set. Chester, 2026-10-11: "Never stop the alarm app". A force-stop cancels the stopped package's
// alarms -- AlarmManagerService removes EVERY alarm of its uid on PACKAGE_RESTARTED -- so stopping the clock app cleared
// the session's next alarm, the sign-out's own post-seal relay then read none, and its clear deleted the gate's copy:
// the alarm never rang. roamd keeps every package sharing the owner's uid for the same reason.
func logoffCutoff(dest, name, uid string) string {
	t0 := time.Now().Round(0) // WALL, not monotonic -- see triggerRoamWorkerKind (NWP-20260913-18)
	owner := alarmOwnerFor(dest, uid)
	setCutoffHold(uid) // before anything is stopped: a clock app the cutoff could not keep must not cost the gate its alarm
	r := triggerRoamWorkerKind(dest, "cutoff", name, "", uid, "", "", owner, "", func(string) {
		pendingReapMu.Lock()
		sealProgAt = time.Now()
		pendingReapMu.Unlock()
	})
	kept := "no alarm owner on record"
	if owner != "" {
		kept = "the alarm owner kept" // never the package: the log says THAT an alarm app was kept, not which
	}
	fmt.Fprintf(os.Stderr, "[logind] logout user %s: cutoff %s in %dms, %s -- the session's apps are stopped before "+
		"the seal (NWP-20261011-04)\n", uid, logVal(r), time.Since(t0).Milliseconds(), kept)
	return r
}

// alarmOwnerFor returns the package that owns uid's next alarm clock, as the session's last relay recorded it in
// gate-alarm-src ("<uid>\t<pkg>", SET-GATE-ALARM), or "" when none is recorded, it names another user, or it is not a
// plain package name (it becomes an argument to `am` and `pm` in roamd, which validates it again). The chooser's relay
// at the Log off tap, sent before LOGOUT, is what makes it current.
func alarmOwnerFor(dest, uid string) string {
	gateAlarmMu.Lock()
	b, err := os.ReadFile(filepath.Join(dest, "gate-alarm-src"))
	gateAlarmMu.Unlock()
	if err != nil {
		return ""
	}
	fl := strings.Split(strings.TrimSpace(string(b)), "\t")
	if len(fl) != 2 || fl[0] != uid || !plainPackageName(fl[1]) {
		return ""
	}
	return fl[1]
}

// plainPackageName: letters, digits, '_' and '.', not starting with '-' or '.'. What roamd's cutoff accepts too.
func plainPackageName(p string) bool {
	if p == "" || p[0] == '.' {
		return false
	}
	for _, c := range p {
		if !(c == '.' || c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}

// cutoffHoldUID is the uid whose apps a cutoff has stopped and that no wake or reap has settled since, or "". While it
// is set, SET-GATE-ALARM holds back every relayed CLEAR (round 3 keyed it to THIS sign-out, not to the whole life of the
// logoff goroutine; round 4 holds the user's own clear too, since with the apps stopped it reads the same empty
// getNextAlarmClock()). Set by logoffCutoff before it stops anything; cleared by a wake that runs and has not been
// superseded by a retry (endCutoffHoldUnlessSuperseded), and by the REAP ack (ackReapAction) -- not where the reap is
// queued, because the post-seal relay, kicked asynchronously from inside `out`, can land after that. The REAP ack
// proves the chooser has CALLED dpm.removeUser for the user (it is sent as soon as that call returns, ok or not), not
// that the user is gone: doRemove confirms the removal later, by polling. The session's apps are stopped and its
// removal requested by then, which is what ends the window the hold covers.
var (
	cutoffHoldMu  sync.Mutex
	cutoffHoldUID string
)

func setCutoffHold(uid string) {
	cutoffHoldMu.Lock()
	cutoffHoldUID = uid
	cutoffHoldMu.Unlock()
}

// endCutoffHold settles uid's hold. Compare-and-clear, so a stale settle cannot drop a later sign-out's hold.
func endCutoffHold(uid string) {
	cutoffHoldMu.Lock()
	if cutoffHoldUID == uid {
		cutoffHoldUID = ""
	}
	cutoffHoldMu.Unlock()
}

// cutoffHolding reports whether a cutoff is unsettled. A relayed clear carries no user, and the session signing out is
// the only roamed session there is, so any hold is that session's.
func cutoffHolding() bool {
	cutoffHoldMu.Lock()
	defer cutoffHoldMu.Unlock()
	return cutoffHoldUID != ""
}

// logoffSuperseded reports whether a NEWER logoff of uid than the one holding claim is in flight. claim is the
// sequence setLogoffInFlight handed that logoff (NWP-20260922-08).
func logoffSuperseded(uid string, claim uint64) bool {
	logoffMu.Lock()
	defer logoffMu.Unlock()
	return logoffUID == uid && logoffSeq != claim
}

// logoffVerdictSuperseded reports whether a NEWER logoff of uid than the one holding claim has claimed, and logs the
// verdict this logoff was about to act on when it has (round 6). The #125 stall watchdog tells the user they are still
// signed in while a step keeps running, so they can tap Log off again; that retry claims, and from then on the session
// is the retry's. A superseded logoff acts on nothing it learns: no reap or switch, no FAILED, no refusal licence, no
// sweep count, no re-arm (the retry cleared .roamsession), no BT-marker drop (the retry's own sweep may have set it).
// Its seal verdict is still recorded by the caller (recordSeal), as the late verdict after an unstick is: it is the
// last seal's truth until the retry's own verdict replaces it.
func logoffVerdictSuperseded(uid string, claim uint64, at, verdict string) bool {
	if !logoffSuperseded(uid, claim) {
		return false
	}
	logSupersededVerdict(uid, at, verdict)
	return true
}

func logSupersededVerdict(uid, at, verdict string) {
	fmt.Fprintf(os.Stderr, "[logind] logout user %s: %s verdict %s landed after a newer sign-out of this session "+
		"claimed -- recorded only, NOT acted on: the newer sign-out owns the session (NWP-20261011-04)\n", uid, at, verdict)
}

// endCutoffHoldUnlessSuperseded ends uid's hold for the logoff holding claim, unless a newer logoff of uid has claimed
// since. The hold is keyed by uid, so it cannot tell a retry's hold from this logoff's: a retry can claim while this
// logoff's wake runs -- about 3 min at worst, the cutoffwake's two `settings get` reads, its two budgeted passes, the
// Play kick and its closing list -- and sets its own hold before its cutoff, so an unconditional end here would clear
// it, and the retry's stop, seal and reap would run with relayed clears applied. The check and the clear happen under
// logoffMu, so a retry cannot claim between them: its setCutoffHold always follows its setLogoffInFlight. Lock order
// logoffMu -> cutoffHoldMu; nothing takes them the other way round.
func endCutoffHoldUnlessSuperseded(uid string, claim uint64) bool {
	logoffMu.Lock()
	defer logoffMu.Unlock()
	if logoffUID == uid && logoffSeq != claim {
		return false
	}
	endCutoffHold(uid)
	return true
}

// wakeAfterCutoff undoes the cutoff on an exit of handleLogout that KEEPS the session signed in: a sweep that did not
// verify, a seal that failed or was refused, and the verdict that lands after the #125 stall watchdog un-stuck the
// screen. roamd's `cutoffwake` takes every package the cutoff stopped out of the stopped state again, and restarts
// Play services if it was one of them (nowhere_roamd.sh says exactly what that does and does not restore).
//
// ⚠⚠ THE SUPERSEDE CHECK RUNS UNDER THE RW SLOT, NOT AT THE CALL, and that is the whole reason this does not go
// through triggerRoamWorker. A wake waits for the slot like every RW op, and the stall watchdog tells the user they
// are signed in WHILE the stalled seal still holds it -- so they can tap Log off again. The retry's cutoff can then
// reach the slot BEFORE this wake does (its verdict lands after the retry started), and a wake run after it would
// un-stop the apps the RETRY just stopped, mid-seal: the exact window this slice closes. So a wake whose logoff has
// been superseded does nothing. It loses nothing either: it leaves the record in place, the retry's cutoff adds its own
// stopped set to it, and the retry's own exit -- reap or wake -- settles the union.
//
// NWP-20261125-21: a WAKE PARTIAL answer is asked once more under the same slot. roamd keeps exactly the packages
// still stopped in the record, so the second pass works on those only. At most ONE extra cutoffwake per call, whatever
// the reason: a call that already re-asked for a reply that was not its own does not ask again.
//
// ⚠ THE CALLER MUST NOT HOLD THE RW SLOT. Like every op here it is acquired by this function, and the slot is a cap-1
// channel: a holder that called this would deadlock the lane device-wide (runWorkerHeld's warning).
func wakeAfterCutoff(dest, name, uid string, claim uint64, why string) string {
	laneRW.slot <- struct{}{}
	setRWHolder("cutoffwake")
	defer func() {
		setRWHolder("")
		<-laneRW.slot
	}()
	if logoffSuperseded(uid, claim) {
		fmt.Fprintf(os.Stderr, "[logind] logout user %s: cutoff wake SKIPPED (%s) -- a newer sign-out of this "+
			"session is in flight and its own exit wakes the apps (NWP-20261011-04)\n", uid, why)
		return "SKIP-SUPERSEDED"
	}
	r := runWorkerHeld(laneRW, dest, "cutoffwake", name, "", uid, "", "", "", "", nil)
	asked := false
	if !strings.HasPrefix(r, "WAKE ") {
		// Round 3: not this wake's answer. An op that timed out on this side (a sweep's ERR-TIMEOUT) can still be running in
		// roamd; init then ignores this run's ctl.start and that op's late answer is the next roam.res. It has answered
		// now, so the worker is free: ask once more. cutoffwake is idempotent, so a wake that did run loses nothing.
		fmt.Fprintf(os.Stderr, "[logind] logout user %s: cutoff wake got a reply that is not its own (%q) -- asking "+
			"once more (NWP-20261011-04)\n", uid, r)
		r = runWorkerHeld(laneRW, dest, "cutoffwake", name, "", uid, "", "", "", "", nil)
		asked = true
	}
	if !asked && strings.HasPrefix(r, "WAKE PARTIAL ") {
		// NWP-20261125-21: the budget ran out, or a package would not unstop. roamd kept the packages still stopped in
		// the record, so one more pass, under the slot this call already holds, wakes what it can of them.
		first := r
		r = runWorkerHeld(laneRW, dest, "cutoffwake", name, "", uid, "", "", "", "", nil)
		fmt.Fprintf(os.Stderr, "[logind] logout user %s: cutoff wake answered %s -- asked once more for the packages "+
			"still stopped, which answered %s (NWP-20261125-21)\n", uid, logVal(first), logVal(r))
	}
	// The hold ends only if no retry has claimed while the wake ran: that retry's cutoff set the hold again (same uid),
	// and its own exit settles it. A failed wake still ends it (the session is kept either way).
	held := "ended"
	if !endCutoffHoldUnlessSuperseded(uid, claim) {
		held = "kept for the newer sign-out"
	}
	fmt.Fprintf(os.Stderr, "[logind] logout user %s: cutoff wake %q (%s), alarm hold %s -- the session stays, so its "+
		"apps are taken out of the stopped state again (NWP-20261011-04)\n", uid, r, why, held)
	return r
}
