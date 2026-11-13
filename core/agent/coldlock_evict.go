package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// NWP-20261004-01 (backlog L318): the cold lock's steps just BEFORE the stop, and the eviction re-check AFTER it.
//
// Device-measured on lynx 2026-10-04 (build 2026100401), one cold lock, start to finish:
//
//	16:13:52.276  DevicePolicyManager: Stopping user 15            (the stop itself COMPLETED)
//	16:13:52.514  AccountManagerService: onUserStopped 15
//	16:13:54.721  vold: Files still open after removing key ... Punting busy file clean up to worker thread.
//	16:15:34.039  vold: Waiting for files to close never completed. Files using key ... were not locked!
//	16:24:25.134  UserController.startUser-15-bg-for-600s           (AlarmManager restarting the stopped user)
//	16:25:00      the session's deskclock AND the gate's copy both ring
//
// and for the whole of it system_server held /data/system_ce/15/accounts_ce.db (+ -wal, -shm) open and the file
// read as plaintext SQLite. Three separate things, each fixed in its own layer:
//   - the open file: AccountsDb.close() closed only the DE helper (endospore-accountsdb-close-ce.sh);
//   - the restart: config_allowAlarmsOnStoppedUsers, true by default on Android 17 (the Endospore overlay turns it
//     off, so the gate's #151 copy must now be reliable on its own -- coldLockRelayAlarm below);
//   - the report: the chooser logged "drop_caches after CE-evict" while roamd logged EVICT-INCOMPLETE for the same
//     lock, because the chooser's only signal was the framework's isUserUnlocked.
// What is left when those are fixed is the backstop: evictcheck after vold's retry window, and a wipe when the CE
// is still readable -- only if the session's last save landed (Chester, 2026-10-04: "Wipe unless unsaved").

// coldLockSweepMedia is how the teardown detaches mediad's overlays before the stop. A seam, like coldLockWorker
// and coldLockStopMediad, so the order tests can drive the real teardown without a real worker: the sweep is a
// worker op, and routing it through coldLockWorker would change the op sequence those tests pin to a meaning.
var coldLockSweepMedia = sweepMediaAtLock

// coldLockRelayAlarm is how the teardown hands the session's next alarm to the gate before the stop. A seam for
// the same reason as coldLockSweepMedia.
var coldLockRelayAlarm = relayAlarmAtLock

// coldLockEvictCheck runs roamd's evictcheck op and returns its verdict. A seam so the decision can be tested
// without a worker.
var coldLockEvictCheck = func(dest, uid string) string {
	return triggerRoamWorker(dest, "evictcheck", "x", "", uid, "", nil) // name="x" non-empty for the worker arg check, as dropcaches
}

// coldLockAlarmWait bounds how long the teardown waits for the session's relay to arrive. CredentialService
// answers in well under a second on lynx; the bound only keeps a wedged session from holding the lock open.
var coldLockAlarmWait = 5 * time.Second

// gateAlarmRelays counts SET-GATE-ALARM deliveries. The teardown reads it before asking the session to relay and
// waits for it to move: the count, not the stash file, because a relay of an UNCHANGED time rewrites the file
// with the same bytes and a relay of "no alarm" removes it -- both are answers, and both must end the wait.
var gateAlarmRelays atomic.Int64

// gateAlarmMu orders SET-GATE-ALARM's writes against GET-GATE-ALARM's read-and-clear. SET is off sessionMu
// (NWP-20261007-06) while GET stays on it, so without this a GET could read the old time and then remove a newer one
// SET wrote in between.
var gateAlarmMu sync.Mutex

// gateAlarmReadWait bounds how long GET-GATE-ALARM waits for a cold lock's at-lock relay, from the lock's commit. It
// stays under the gate's 90 s read of the verb, and it is longer than the commit-to-relay stretch: stopMediad, btpark,
// the three release* ops, the switch and the relay.
var gateAlarmReadWait = 60 * time.Second

// atLockRelayWaitStarted runs when a GET-GATE-ALARM starts to wait for the relay. A test hook.
var atLockRelayWaitStarted = func() {}

// The at-lock relay marker (NWP-20261129-26): set while a committed cold lock's relay has not ended. Its own mutex,
// because gateAlarmMu is what SET-GATE-ALARM needs to deliver the relay that a reader waits for.
var (
	atLockRelayMu    sync.Mutex
	atLockRelayDone  chan struct{}
	atLockRelayUntil time.Time
)

// beginAtLockRelay marks the relay in flight, until gateAlarmReadWait from now.
func beginAtLockRelay() {
	atLockRelayMu.Lock()
	defer atLockRelayMu.Unlock()
	atLockRelayDone = make(chan struct{})
	atLockRelayUntil = time.Now().Round(0).Add(gateAlarmReadWait)
}

// endAtLockRelay ends the mark and frees every waiting reader. A second call does nothing.
func endAtLockRelay() {
	atLockRelayMu.Lock()
	defer atLockRelayMu.Unlock()
	if atLockRelayDone != nil {
		close(atLockRelayDone)
		atLockRelayDone = nil
	}
}

// atLockRelayInFlight reports a marked relay inside its bound, with the teardown that set the mark still running: a
// marker never outlives its teardown, so no later read waits on it.
func atLockRelayInFlight() bool {
	atLockRelayMu.Lock()
	live := atLockRelayDone != nil && time.Now().Round(0).Before(atLockRelayUntil)
	atLockRelayMu.Unlock()
	return live && coldLockInFlight()
}

// waitForAtLockRelay holds a GET-GATE-ALARM back while a relay is in flight, bounded, and returns at once for every
// other verb. The gate reads the stash once per onResume, and that read clears it, so an answer sent before the relay
// lands leaves the relayed alarm with no reader: on an offline phone nothing then rings. It holds no lock while it
// waits: SET-GATE-ALARM takes gateAlarmMu to deliver the relay, and the gate's ACK-REAP takes sessionMu.
func waitForAtLockRelay(name string) {
	if name != "GET-GATE-ALARM" || !atLockRelayInFlight() {
		return
	}
	atLockRelayMu.Lock()
	done, until := atLockRelayDone, atLockRelayUntil
	atLockRelayMu.Unlock()
	if done == nil {
		return // the relay ended between the two reads
	}
	atLockRelayWaitStarted()
	t0 := time.Now().Round(0)
	bound := time.NewTimer(time.Until(until))
	defer bound.Stop()
	how := "relay ended"
	select {
	case <-done:
	case <-bound.C:
		how = "bound"
	}
	fmt.Fprintf(os.Stderr, "[logind] gate alarm read waited %dms for the cold lock's alarm relay (%s)\n",
		time.Since(t0).Milliseconds(), how)
}

// sweepMediaAtLock detaches the session's media overlays while the user is still running, so the stop's key
// removal does not start out FILES_BUSY on them. It runs inside the teardown's RW hold (rwHeld), like btpark. A
// failure does not stop the lock -- the user is past the point of no return -- but it is said, and dropcaches
// sweeps again after the stop.
func sweepMediaAtLock(dest, name, pass, uid string) {
	if out := coldLockWorker(dest, "coldsweep", name, pass, uid, "", true); out != "OK" {
		fmt.Fprintf(os.Stderr, "[logind] cold-lock media sweep for user %s returned [%s] -- completing the lock; "+
			"dropcaches sweeps again after the stop\n", uid, out)
	}
}

// relayAlarmAtLock asks the session for its next alarm and waits, bounded, for the answer to reach the daemon.
//
// ⚠ WHY AT THE LOCK, AND NOT ONLY AFTER EACH SEAL. #151's periodic relay rides the post-seal claims kick, and that
// kick fires only when the vault push happened -- so a phone that is OFFLINE (airplane mode at bedtime) never
// relays the alarm set before it. That was hidden while the framework restarted the stopped user around each
// alarm and its own clock rang; with the restart off, the gate's copy is the only ring there is.
//
// The op rides the read-only lane (NWP-20261108-02, Q183), which refuses a passphrase: it needs only the uid, so
// the ask carries an empty pass and a cold lock taken behind an abandoned RW op still relays.
func relayAlarmAtLock(dest, name, pass, uid string) {
	before := gateAlarmRelays.Load()
	t0 := time.Now().Round(0)
	if out := coldLockWorker(dest, "alarmrelay", name, "", uid, "", true); out != "OK" {
		fmt.Fprintf(os.Stderr, "[logind] cold-lock alarm relay for user %s: ask returned [%s] -- the gate keeps "+
			"the last periodic relay\n", uid, out)
		return
	}
	for time.Since(t0) < coldLockAlarmWait {
		if gateAlarmRelays.Load() != before {
			fmt.Fprintf(os.Stderr, "[logind] cold-lock alarm relay for user %s arrived in %dms (#151)\n",
				uid, time.Since(t0).Milliseconds())
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "[logind] cold-lock alarm relay for user %s: NOTHING arrived in %s -- the gate keeps "+
		"the last periodic relay, which an offline session may never have sent\n", uid, coldLockAlarmWait)
}

// saveLanded is the "unless unsaved" half of the wipe rule: true only when this session's last seal verdict was a
// clean OK and an OK has landed at all. Anything else -- a failed, refused or over-quota last seal, a PARTIAL one,
// or no seal this session -- means the session holds changes the store does not, and a wipe would destroy them.
// A PARTIAL here is what sealPartsOf leaves, which never holds sys=pending-placement (NWP-20261008-07): a save
// partial only for that detail reads as a clean OK, so the session counts as saved and a failed eviction wipes
// it at the re-check. Chester decided that on 2026-10-08, after -07 had already made it so
// (docs/product-decisions.md).
func saveLanded(local bool, status, parts string, lastOKAt int64) (bool, string) {
	switch {
	case local:
		return false, "local-only" // a throwaway is never sealed (.localsession)
	case lastOKAt == 0:
		return false, "never-saved"
	case status != "ok":
		if status == "" {
			status = "none"
		}
		return false, "last-save-" + status
	case parts != "":
		return false, "last-save-partial"
	}
	return true, ""
}

// evictDecision turns evictcheck's verdict into the reply EVICT-RECHECK sends. Pure, so the whole table is tested.
//
//	OK EVICTED                   nothing readable: the lock holds
//	WIPE <uid>                   still readable after vold gave up, and the last save landed
//	KEEP UNSAVED <why>           still readable, but a wipe would destroy changes the store does not have
//	KEEP PROBE-BLIND             the probe's control could not see user 0's CE, so it proves nothing
//	RETRY <why>                  no verdict (worker busy or no answer); ask again
func evictDecision(verdict, uid string, saved bool, why string) string {
	switch v := strings.TrimSpace(verdict); {
	case strings.HasPrefix(v, "OK EVICTED"):
		return "OK EVICTED"
	case strings.HasPrefix(v, "ERR-EVICT-INCOMPLETE"):
		if saved {
			return "WIPE " + uid
		}
		return "KEEP UNSAVED " + why
	case strings.HasPrefix(v, "ERR-EVICT-PROBE"):
		return "KEEP PROBE-BLIND"
	case v == workerBusy:
		return "RETRY busy"
	default:
		return "RETRY no-verdict"
	}
}

// handleEvictRecheck is "EVICT-RECHECK\n<uid>\n" from the gate, sent once vold's retry window after the stop has
// passed. It runs under sessionMu (it is not a concurrent-safe verb), which is what makes the marker check below
// mean something: RESUME also holds sessionMu, verifies, and drops .coldlock before it lets go, so this sees
// either a session still cold-locked or one already resumed -- never a resume half done, whose decrypted CE would
// look exactly like a failed eviction.
func handleEvictRecheck(conn net.Conn, dest string, r *bufio.Reader) {
	u, _ := r.ReadString('\n')
	uid := strings.TrimSpace(u)
	if n, err := strconv.Atoi(uid); err != nil || n < 10 {
		fmt.Fprint(conn, "ERR-UID\n")
		return
	}
	reply := func(s string) {
		fmt.Fprintf(os.Stderr, "[logind] evict-recheck user %s -> %s\n", uid, s)
		fmt.Fprintf(conn, "%s\n", s)
	}
	if _, cl, _, _, _, _ := readColdLock(dest); cl != uid {
		reply("OK GONE") // resumed, wiped, or another session's marker: nothing of this lock is parked
		return
	}
	if name, _, liveUID := readRoamSession(dest); name != "" {
		// A session is LIVE while this one sits cold-locked, so the seal signals below are not this session's:
		// a sign-in resets them once its marker is written (NWP-20261030-02). Deciding on another identity's save state is the one thing
		// this must never do.
		reply("KEEP LIVE-SESSION " + liveUID)
		return
	}
	verdict := coldLockEvictCheck(dest, uid)
	sealMu.Lock()
	status, parts := sealStatus, sealParts
	sealMu.Unlock()
	saved, why := saveLanded(isLocalSession(dest), status, parts, lastSealOKAt.Load())
	// ⚠ Brackets, not %q: the reap's log_scrub rewrites EVERY quoted string in login.log to "<name>", so a quoted
	// verdict survived only until the session it describes was removed -- device-seen on lynx 2026-10-04, where the
	// WIPE run's line read `evictcheck said "<name>"`. Nothing in the verdict is a name (paths carry the uid only).
	landed := "save landed"
	if !saved {
		landed = "save NOT landed: " + why
	}
	fmt.Fprintf(os.Stderr, "[logind] evict-recheck user %s: evictcheck said [%s] (%s)\n",
		uid, strings.TrimSpace(verdict), landed)
	reply(evictDecision(verdict, uid, saved, why))
}

// savedWipeDecision is the reply EVICT-RECHECK-SAVED sends once it has the save state. Pure, so the table is tested.
//
//	WIPE <uid>                   the last save landed: the profile chose to be erased once saved, so erase it
//	KEEP UNSAVED <why>           a wipe would destroy changes the store does not have; the gate's wipe= bound applies
func savedWipeDecision(saved bool, why, uid string) string {
	if saved {
		return "WIPE " + uid
	}
	return "KEEP UNSAVED " + why
}

// handleEvictRecheckSaved is "EVICT-RECHECK-SAVED\n<uid>\n" from the gate (Q138, docs/product-decisions.md,
// 2026-10-20): the answer on the save alone, for a profile that chose "Right away, once saved" in the erase picker.
// EVICT-RECHECK answers WIPE only for a CE that stayed readable, so for a CE that did evict its OK EVICTED hides
// whether the last save landed; this verb does not look at the eviction at all (no coldLockEvictCheck, no worker
// op), because that profile chose to be erased once saved, whatever the eviction found. The gate (NWP-20261106-12's
// consumer, NOWHERE-895) asks it only for such a profile; the wipe= fallback (1 h for that choice) stays the bound
// for KEEP UNSAVED. Like EVICT-RECHECK it is not concurrent-safe: it holds sessionMu, which orders it against RESUME
// (see handleEvictRecheck), and it claims nothing -- the wipe's own CLAIM-COLDLOCK does.
func handleEvictRecheckSaved(conn net.Conn, dest string, r *bufio.Reader) {
	u, _ := r.ReadString('\n')
	uid := strings.TrimSpace(u)
	if n, err := strconv.Atoi(uid); err != nil || n < 10 {
		fmt.Fprint(conn, "ERR-UID\n")
		return
	}
	reply := func(s string) {
		// ⚠ Brackets, never %q: see handleEvictRecheck -- the reap's log_scrub rewrites quoted strings.
		fmt.Fprintf(os.Stderr, "[logind] evict-recheck-saved user %s -> [%s]\n", uid, s)
		fmt.Fprintf(conn, "%s\n", s)
	}
	if _, cl, _, _, _, _ := readColdLock(dest); cl != uid {
		reply("OK GONE")
		return
	}
	if name, _, liveUID := readRoamSession(dest); name != "" {
		reply("KEEP LIVE-SESSION " + liveUID) // the seal signals are the live session's, not the parked one's
		return
	}
	sealMu.Lock()
	status, parts := sealStatus, sealParts
	sealMu.Unlock()
	saved, why := saveLanded(isLocalSession(dest), status, parts, lastSealOKAt.Load())
	reply(savedWipeDecision(saved, why, uid))
}

// handleClaimColdLock is "CLAIM-COLDLOCK\n<uid>\n": drop the .coldlock marker ONLY if it is still this uid's, and
// say whether it was. The gate's wipes (the 12 h one and the failed-eviction one) claim before they remove
// anything: under sessionMu this is atomic against RESUME, so a person who resumed between the wipe's decision and
// its claim keeps their session -- the claim answers GONE and the wipe stands down. CLEAR-COLDLOCK, which clears
// unconditionally, stays for the callers that are clearing a marker they know is stale.
func handleClaimColdLock(conn net.Conn, dest string, r *bufio.Reader) {
	u, _ := r.ReadString('\n')
	uid := strings.TrimSpace(u)
	if _, cl, _, _, _, _ := readColdLock(dest); cl == "" || cl != uid {
		fmt.Fprintf(os.Stderr, "[logind] claim-coldlock user %s: GONE (marker is [%s])\n", uid, cl)
		fmt.Fprint(conn, "GONE\n")
		return
	}
	os.Remove(filepath.Join(dest, ".coldlock"))
	os.Remove(filepath.Join(dest, nfcHmacStash(true))) // a resume assertion dies with its marker (NWP-20260924-01)
	// NWP-20261013-20 (decided 2026-10-15): the wipe publishes nothing, so credit a never-restored session holds is
	// lost, and the gate is told. Read before clearLocalSession, which ends a throwaway's local mark.
	noteCreditLostAtWipe(dest, uid, isLocalSession(dest))
	// NWP-20261030-03 (decided 2026-10-20, "a cold-lock wipe removes the wiped session's wallet at once"): the wiped
	// session's bearer tokens leave the state tmpfs now, not at the next sign-in or power-off. The wipe holds no
	// credentials, so it cannot publish; removeWallet bumps the generation first, so a writer still in its lease
	// window fails its save check and does not write the file back. A claim or spend after the session's last wallet
	// save is lost, as the next sign-in's removal (handleRoamIn) already loses it. AFTER the note, which reads this
	// file and its generation; the .creditlost notice survives (removeWallet never removes it). Both wipe arms reach
	// here only through ChooserActivity.coldWipe (ColdWipeReceiver.onReceive, the 12-hour alarm, and evictRecheck's
	// WIPE arm), so this verb is the whole surface.
	removeWallet(walletPathFor(dest))
	clearLocalSession(dest)    // a wiped cold-locked throwaway ends here too, as CLEAR-COLDLOCK
	forgetUiderrorsFloor(dest) // NWP-20261010-06: as CLEAR-COLDLOCK, the session is over
	resetOdWindow()            // NWP-20261011-01: and so are its materialise leases
	fmt.Fprintf(os.Stderr, "[logind] claim-coldlock user %s: claimed for the wipe\n", uid)
	fmt.Fprint(conn, "OK\n")
}
