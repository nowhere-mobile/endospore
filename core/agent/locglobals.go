package main

import (
	"fmt"
	"net"
	"os"
	"strings"
)

// NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS -- the daemon's half.
//
// GrapheneOS's network location (Settings.Global network_location) and geocoding (Settings.Global geocoder) are
// settings of the WHOLE DEVICE, and GrapheneOS lets only user 0 change them; on Nowhere user 0 is the gate, so no
// signed-in profile could ever turn either on. They now follow the session in front (docs/product-decisions.md,
// 2026-10-16): the profile's own choice lives in its nowhere-prefs (netloc=1 / geocoder=1, absent = Off), roamd's
// locapply applies it, and roamd's locrelease, the reap and the boot sweep put the baseline (both 0) back. roamd is
// the only writer -- this domain cannot run `settings` -- and nowhere_roamd.sh carries the design note.
//
// What this file decides is WHEN:
//   - a CLAIM at every start of a session in front: sign-in (handleRoamIn), an offline sign-in (handleRoamInOffline),
//     a cold-lock resume (handleResume), all after .roamsession names the session, and the Profile screen's live
//     switch (APPLY-LOCATION). runWorkerHeld drops a claim whose session is no longer the one in front, UNDER the RW
//     slot every claim and release share, so a claim queued behind a seal cannot land after its session ended;
//   - a RELEASE at every end: the gate switch of a sign-out that removes the session (ACK-REAP of a SWITCH whose REAP
//     is queued -- a logoff, END-UNSAVED, a delete, a rollback, a throwaway's sign-out), a cold lock, inside its own
//     RW hold (releaseLocAtLock), and a sign-in the chooser abandoned and removed without telling the daemon
//     (clearMarkerOfGoneUser). The reap (cleanstorage) and the boot sweep are roamd's own backstops, and roamd counts
//     an owner whose user no longer exists as no owner, so neither keeps a removed session's choice.

// locProviderAPK is GrapheneOS's network-location and geocoding provider. Its presence is the one test, made the same
// way here, in roamd (LOC_PROVIDER_APK, loc_supported) and in the chooser (ProfileActivity.LOC_PROVIDER_APK), for "this
// image has the two settings". Diaspore (LineageOS) ships neither, so there nothing is sent and nothing is written.
const locProviderAPK = "/system/priv-app/NetworkLocation/NetworkLocation.apk"

// locGlobalsSupported reports whether this image has the provider. A variable so a test can stand on a host that has
// no such file -- which is every test host, so no test that does not opt in ever reaches the worker from here.
var locGlobalsSupported = func() bool {
	_, err := os.Stat(locProviderAPK)
	return err == nil
}

// locGlobalsWorker runs roamd's locapply or locrelease for uid, with a reason token in the name slot (lowercase
// letters; roamd logs it, and nothing else, beside the uid). A variable so a test can stand in for roamd.
var locGlobalsWorker = func(dest, op, why, uid string) string {
	return triggerRoamWorker(dest, op, why, "", uid, "", nil)
}

// claimLocGlobals applies the session uid's own location choice and returns roamd's verdict. "OK UNAVAILABLE" without
// a worker run on an image with no provider.
func claimLocGlobals(dest, uid, why string) string {
	if !locGlobalsSupported() {
		return "OK UNAVAILABLE"
	}
	out := locGlobalsWorker(dest, "locapply", why, uid)
	if !strings.HasPrefix(out, "OK") {
		fmt.Fprintf(os.Stderr, "[logind] locglobals: %s claim for user %s answered %s (NWP-20261016-45)\n",
			why, uid, logVal(locReplyToken(out)))
	}
	return out
}

// claimLocGlobalsAsync is claimLocGlobals off the caller's path: a sign-in or resume does not wait on the worker
// slot for it. Correct in any order, because roamd reads the choice from the session's own prefs when it runs, and
// runWorkerHeld drops it if the session has ended by then.
func claimLocGlobalsAsync(dest, uid, why string) {
	if !locGlobalsSupported() {
		return
	}
	goSafe("locglobals-claim", func() { claimLocGlobals(dest, uid, why) })
}

// releaseLocGlobalsAsync restores the baseline for a session that is no longer in front, off the caller's path (the
// ACK-REAP verb must answer at once). roamd leaves the globals alone if another session owns them by the time it
// runs, so a late release can never switch off the session that replaced this one.
func releaseLocGlobalsAsync(dest, uid, why string) {
	if !locGlobalsSupported() {
		return
	}
	goSafe("locglobals-release", func() {
		if out := locGlobalsWorker(dest, "locrelease", why, uid); !strings.HasPrefix(out, "OK") {
			fmt.Fprintf(os.Stderr, "[logind] locglobals: %s release for user %s answered %s -- the reap and the boot "+
				"sweep put the baseline back (NWP-20261016-45)\n", why, uid, logVal(locReplyToken(out)))
		}
	})
}

// releaseLocAtLock is the cold lock's release: inside the teardown's RW hold, past the point of no return and before
// the switch is published, so the gate is never in front of the session's choice. A resume claims it again.
func releaseLocAtLock(dest, uid string) {
	if !locGlobalsSupported() {
		return
	}
	if out := coldLockWorker(dest, "locrelease", "coldlock", "", uid, "", true); !strings.HasPrefix(out, "OK") {
		fmt.Fprintf(os.Stderr, "[logind] cold-lock locglobals release for user %s answered %s -- completing the lock; "+
			"the reap and the boot sweep put the baseline back (NWP-20261016-45)\n", uid, logVal(locReplyToken(out)))
	}
}

// locClaimRefusal is why a claim for uid must not run now, or "" when it may: uid must be the session .roamsession
// names, an Android user that still exists, neither cold-locked nor queued to be switched out, removed or stopped.
// Asked under the RW slot.
func locClaimRefusal(dest, uid string) string {
	if uid == "" {
		return "no user"
	}
	if _, _, live := readRoamSession(dest); live != uid {
		return "it is not the live session"
	}
	// A sign-in the chooser abandoned and removed, whose marker the daemon still wrote: nothing would release it.
	if androidUserGone(uid) {
		return "the user no longer exists"
	}
	if coldLockedUID(dest) == uid {
		return "the session is cold-locked"
	}
	pendingReapMu.Lock()
	ending := uid == pendingSwitchUID || uid == pendingReapUID || uid == pendingLockUID
	pendingReapMu.Unlock()
	if ending {
		return "the session is being switched out"
	}
	return ""
}

// handleApplyLocation is APPLY-LOCATION: the Profile screen's Location services switch has just written the
// session's choice into its prefs; apply it now. Only the session's own chooser may ask (sessionCaller), and the reply
// is roamd's verdict -- "OK APPLIED network_location=<v> geocoder=<v>" when both read back as written.
func handleApplyLocation(conn net.Conn, dest string) {
	_, _, uid := readRoamSession(dest)
	if uid == "" || !sessionCaller(conn, uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(conn, "%s\n", locReplyToken(claimLocGlobals(dest, uid, "live")))
}

// locReplyToken reduces a worker reply to its first line, at most 80 characters of the set roamd's verdicts use.
func locReplyToken(reply string) string {
	if i := strings.IndexByte(reply, '\n'); i >= 0 {
		reply = reply[:i]
	}
	var b strings.Builder
	for _, r := range reply {
		if b.Len() >= 80 {
			break
		}
		if r == ' ' || r == '-' || r == '_' || r == '=' || r == ',' || r == '?' || (r >= 'A' && r <= 'Z') ||
			(r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}
