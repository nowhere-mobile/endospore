package main

import (
	"fmt"
	"os"
	"strings"
)

// NWP-20261210-05: THE SESSION'S CLAIMS IN ONE WORKER RUN. Backlog row "A nearly empty profile takes about 85 s from
// submit to home; target under 60 s", cause (4).
//
// A session that comes to the front -- a sign-in (handleRoamIn), an offline sign-in (handleRoamInOffline) or a cold-lock
// resume (handleResume) -- claims three device globals: the location globals (locglobals.go), mobile data and data
// roaming (mobiledata.go) and the device toggles (devtoggles.go). Each claim was its own roamd run (locapply, mdapply,
// dtclaim). Every worker run re-reads both confs, logs its own `conf merge:` line and queues for the one RW slot, ahead
// of vpnup and grant, so the three claims cost three starts. roamd's sessclaim runs the same three claim bodies, in the
// same order, in one run.
//
// The claim rules are not changed here; each stays the one its file states, from docs/product-decisions.md: "network
// location and geocoding are off by default, and on only for the profile that turns them on, while it is signed in";
// "a profile can turn mobile data on or off for its own session; whenever it is not in front, the phone goes back to the
// gate's value"; "a profile can share its connection, its mobile-data switch covers data roaming, and the device-wide
// toggles a session flips are put back when it leaves". runWorkerHeld drops a sessclaim under the RW slot when its
// session is no longer the one in front (locClaimRefusal), as it drops each single claim. The live switches
// (APPLY-LOCATION, APPLY-MOBILE-DATA) and every release keep their single ops.

// sessionClaimParts is the part list roamd's sessclaim takes on line 7: the claims this image supports, in the fixed
// order loc, md, dt, or "" when it supports none.
func sessionClaimParts() string {
	var p []string
	if locGlobalsSupported() {
		p = append(p, "loc")
	}
	if mobileDataSupported() {
		p = append(p, "md")
	}
	if devTogglesSupported() {
		p = append(p, "dt")
	}
	return strings.Join(p, ",")
}

// sessionClaimsWorker runs roamd's sessclaim for uid: the reason token in the name slot (lowercase letters; roamd logs
// it, and nothing else, beside the uid) and the parts in the srcunit slot. A variable so a test can stand in for roamd.
var sessionClaimsWorker = func(dest, why, uid, parts string) string {
	return triggerRoamWorkerKind(dest, "sessclaim", why, "", uid, "", "", parts, "", nil)
}

// claimSessionGlobals makes the session uid's claims in one worker run. Nothing runs when the image supports none. A
// field that is not OK is logged with the line its single claim logged; a reply that is not three fields (SKIP-ENDED,
// ERR-*, a busy worker) is logged once.
func claimSessionGlobals(dest, uid, why string) {
	parts := sessionClaimParts()
	if parts == "" {
		return
	}
	out := sessionClaimsWorker(dest, why, uid, parts)
	f := strings.Split(strings.TrimRight(out, "\r\n"), ";")
	if len(f) != 3 {
		fmt.Fprintf(os.Stderr, "[logind] sessclaim: %s claim for user %s answered %s (NWP-20261210-05)\n",
			why, uid, logVal(locReplyToken(out)))
		return
	}
	asked := "," + parts + ","
	if strings.Contains(asked, ",loc,") && !strings.HasPrefix(f[0], "OK") {
		fmt.Fprintf(os.Stderr, "[logind] locglobals: %s claim for user %s answered %s (NWP-20261016-45)\n",
			why, uid, logVal(locReplyToken(f[0])))
	}
	if strings.Contains(asked, ",md,") && !strings.HasPrefix(f[1], "OK") {
		fmt.Fprintf(os.Stderr, "[logind] mobiledata: %s claim for user %s answered %s (NWP-20261026-06)\n",
			why, uid, logVal(locReplyToken(f[1])))
	}
	if strings.Contains(asked, ",dt,") && !strings.HasPrefix(f[2], "OK") {
		fmt.Fprintf(os.Stderr, "[logind] devtoggles: %s claim for user %s answered %s (NWP-20261027-08)\n",
			why, uid, logVal(locReplyToken(f[2])))
	}
}

// claimSessionGlobalsAsync is claimSessionGlobals off the caller's path: a sign-in or resume does not wait on the worker
// slot for it. Correct in any order, because roamd reads each choice from the session's own prefs when it runs, and
// runWorkerHeld drops it if the session has ended by then.
func claimSessionGlobalsAsync(dest, uid, why string) {
	if sessionClaimParts() == "" {
		return
	}
	goSafe("session-claims", func() { claimSessionGlobals(dest, uid, why) })
}
