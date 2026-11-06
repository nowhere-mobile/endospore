package main

import (
	"fmt"
	"os"
	"strings"
)

// NWP-20261027-08: SESSION DEVICE TOGGLES -- the daemon's half (docs/product-decisions.md, 2026-10-19, item 3).
//
// A signed-in profile can flip four device-wide toggles -- airplane mode, battery saver, Data Saver and NFC -- and each
// outlives its sign-out. There is no profile choice here and no verb: roamd's dtclaim RECORDS the gate's values when a
// session comes to the front (it writes nothing), and dtrelease puts them back; the session's own value is never kept.
// The daemon only decides WHEN, exactly as locglobals.go does for the location globals and mobiledata.go for mobile data
// (whose structure this file mirrors). roamd is the only writer -- this domain cannot run `settings` -- and
// nowhere_roamd.sh defines the two ops and their replies (NWP-20261027-05).
//
// Every site that claims or releases the location globals does the same here: a claim at sign-in, offline sign-in and
// resume, dropped by runWorkerHeld under the RW slot when its session is no longer the one in front (locClaimRefusal);
// a release at the gate switch of a removal, inside the cold lock's hold, and when a gone user's marker is cleared.

// devTogglesBinary is what roamd's ops run. Its presence is the test for "this image can record and restore them".
const devTogglesBinary = "/system/bin/cmd"

// devTogglesSupported reports whether the worker's tool exists. A variable so a test can stand on a host that has no
// such file -- which is every test host, so no test that does not opt in ever reaches the worker from here.
var devTogglesSupported = func() bool {
	_, err := os.Stat(devTogglesBinary)
	return err == nil
}

// devTogglesWorker runs roamd's dtclaim or dtrelease for uid, with a reason token in the name slot (lowercase letters;
// roamd logs it, and nothing else, beside the uid). A variable so a test can stand in for roamd.
var devTogglesWorker = func(dest, op, why, uid string) string {
	return triggerRoamWorker(dest, op, why, "", uid, "", nil)
}

// claimDevToggles records the gate's toggle values for the session uid and returns roamd's verdict, or "NONE" without
// a worker run where it cannot be done.
func claimDevToggles(dest, uid, why string) string {
	if !devTogglesSupported() {
		return "NONE"
	}
	out := devTogglesWorker(dest, "dtclaim", why, uid)
	if !strings.HasPrefix(out, "OK") {
		fmt.Fprintf(os.Stderr, "[logind] devtoggles: %s claim for user %s answered %s (NWP-20261027-08)\n",
			why, uid, logVal(locReplyToken(out)))
	}
	return out
}

// claimDevTogglesAsync is claimDevToggles off the caller's path, correct in any order for claimLocGlobalsAsync's reason.
func claimDevTogglesAsync(dest, uid, why string) {
	if !devTogglesSupported() {
		return
	}
	goSafe("devtoggles-claim", func() { claimDevToggles(dest, uid, why) })
}

// releaseDevTogglesAsync puts the gate's values back for a session that is no longer in front, off the caller's path.
// roamd leaves the values alone if another session owns them by the time it runs.
func releaseDevTogglesAsync(dest, uid, why string) {
	if !devTogglesSupported() {
		return
	}
	goSafe("devtoggles-release", func() {
		if out := devTogglesWorker(dest, "dtrelease", why, uid); !strings.HasPrefix(out, "OK") {
			fmt.Fprintf(os.Stderr, "[logind] devtoggles: %s release for user %s answered %s -- the reap and the boot "+
				"sweep put the gate's values back (NWP-20261027-08)\n", why, uid, logVal(locReplyToken(out)))
		}
	})
}

// releaseDevTogglesAtLock is the cold lock's release, inside the teardown's RW hold and before the switch is
// published, so the gate is never in front of the session's toggles. A resume claims again.
func releaseDevTogglesAtLock(dest, uid string) {
	if !devTogglesSupported() {
		return
	}
	if out := coldLockWorker(dest, "dtrelease", "coldlock", "", uid, "", true); !strings.HasPrefix(out, "OK") {
		fmt.Fprintf(os.Stderr, "[logind] cold-lock devtoggles release for user %s answered %s -- completing the lock; "+
			"the reap and the boot sweep put the gate's values back (NWP-20261027-08)\n", uid, logVal(locReplyToken(out)))
	}
}
