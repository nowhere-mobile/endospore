package main

import (
	"fmt"
	"net"
	"os"
	"strings"
)

// NWP-20261026-06: SESSION-SCOPED MOBILE DATA -- the daemon's half (docs/product-decisions.md, 2026-10-19).
//
// A signed-in profile cannot turn mobile data on or off: only user 0 can, and on Nowhere user 0 is the gate. The
// choice follows the session in front instead, exactly as the location globals do (locglobals.go, which says WHEN and
// whose header this file mirrors): roamd's mdapply applies the profile's own choice (and, with none, keeps the gate's
// value), and mdrelease puts the gate's value back. roamd is the only writer -- this domain cannot run `settings` --
// and nowhere_roamd.sh defines the two ops and their replies.
//
// Every site that claims or releases the location globals does the same here: a claim at sign-in, offline sign-in,
// resume and the Profile screen's live switch (APPLY-MOBILE-DATA), dropped by runWorkerHeld under the RW slot when its
// session is no longer the one in front (locClaimRefusal); a release at the gate switch of a removal, inside the cold
// lock's hold, and when a gone user's marker is cleared.

// mobileDataBinary is what roamd's ops run. Its presence is the test for "this image can apply the choice".
const mobileDataBinary = "/system/bin/cmd"

// mobileDataSupported reports whether the worker's tool exists. A variable so a test can stand on a host that has no
// such file -- which is every test host, so no test that does not opt in ever reaches the worker from here.
var mobileDataSupported = func() bool {
	_, err := os.Stat(mobileDataBinary)
	return err == nil
}

// mobileDataWorker runs roamd's mdapply or mdrelease for uid, with a reason token in the name slot (lowercase letters;
// roamd logs it, and nothing else, beside the uid). A variable so a test can stand in for roamd.
var mobileDataWorker = func(dest, op, why, uid string) string {
	return triggerRoamWorker(dest, op, why, "", uid, "", nil)
}

// claimMobileData applies the session uid's own mobile-data choice and returns roamd's verdict, or "NONE" without a
// worker run where it cannot be applied.
func claimMobileData(dest, uid, why string) string {
	if !mobileDataSupported() {
		return "NONE"
	}
	out := mobileDataWorker(dest, "mdapply", why, uid)
	if !strings.HasPrefix(out, "OK") {
		fmt.Fprintf(os.Stderr, "[logind] mobiledata: %s claim for user %s answered %s (NWP-20261026-06)\n",
			why, uid, logVal(locReplyToken(out)))
	}
	return out
}

// claimMobileDataAsync is claimMobileData off the caller's path, correct in any order for claimLocGlobalsAsync's reason.
func claimMobileDataAsync(dest, uid, why string) {
	if !mobileDataSupported() {
		return
	}
	goSafe("mobiledata-claim", func() { claimMobileData(dest, uid, why) })
}

// releaseMobileDataAsync puts the gate's value back for a session that is no longer in front, off the caller's path.
// roamd leaves the value alone if another session owns it by the time it runs.
func releaseMobileDataAsync(dest, uid, why string) {
	if !mobileDataSupported() {
		return
	}
	goSafe("mobiledata-release", func() {
		if out := mobileDataWorker(dest, "mdrelease", why, uid); !strings.HasPrefix(out, "OK") {
			fmt.Fprintf(os.Stderr, "[logind] mobiledata: %s release for user %s answered %s -- the reap and the boot "+
				"sweep put the gate's value back (NWP-20261026-06)\n", why, uid, logVal(locReplyToken(out)))
		}
	})
}

// releaseMobileDataAtLock is the cold lock's release, inside the teardown's RW hold and before the switch is
// published, so the gate is never in front of the session's choice. A resume claims it again.
func releaseMobileDataAtLock(dest, uid string) {
	if !mobileDataSupported() {
		return
	}
	if out := coldLockWorker(dest, "mdrelease", "coldlock", "", uid, "", true); !strings.HasPrefix(out, "OK") {
		fmt.Fprintf(os.Stderr, "[logind] cold-lock mobiledata release for user %s answered %s -- completing the lock; "+
			"the reap and the boot sweep put the gate's value back (NWP-20261026-06)\n", uid, logVal(locReplyToken(out)))
	}
}

// handleApplyMobileData is APPLY-MOBILE-DATA: the Profile screen's Mobile data switch has just written the session's
// choice into its prefs; apply it now. Only the session's own chooser may ask (sessionCaller); the reply is roamd's
// one-line verdict ("OK APPLIED mobile_data=<v>", "ERR-MD ...", "SKIP-ENDED"), and NONE for anyone else.
func handleApplyMobileData(conn net.Conn, dest string) {
	_, _, uid := readRoamSession(dest)
	if uid == "" || !sessionCaller(conn, uid) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(conn, "%s\n", locReplyToken(claimMobileData(dest, uid, "live")))
}
