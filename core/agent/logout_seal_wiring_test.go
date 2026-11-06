package main

import (
	"os"
	"strings"
	"testing"
)

// handleLogout's two keep-the-session-signed-in arms are WIRING, and wiring is what the behavioural tests in
// credit_reason_test.go and roamsession_marker_test.go cannot reach: they drive logoffSealFailed,
// sealVerdictLog and rearmRoamSession directly, so all three call sites can be swapped back to their
// predecessors and every one of those tests still passes.
//
// FOUND BY MUTATION, not by reading. Rebasing NWP-20260904-09 onto a main that had gained NWP-20260904-08
// put both slices in the same two lines, and the resolution was written by hand. Mutating each of the three
// composed calls back -- logoffSealFailed to the old inline block, sealVerdictLog to a bare out,
// rearmRoamSession to markRoamSession -- left the suite GREEN all three times. That is the same shape as the
// orphaned helper delete_bindings_test.go pins against, and the same reason reboot_reason_test.go pins its
// call sites: a helper can be perfect and simply not called.
//
// WHY EACH LINE MATTERS, so a future edit knows what it is breaking rather than just that a test failed:
//
//   - logoffSealFailed, NOT the inline SEAL-STATUS block. It is that block PLUS recordSeal. The first
//     over-quota seal of a session is very often the logoff one (the large delta is written late), and
//     without recordSeal that verdict never reaches sealStatus/sealReason: SEAL-DELTA carries no reason for
//     it and the stashed gateway text sits unconsumed in the tmpfs. This is the exact case ticket
//     NW-e9ef5316ad0a was in -- a logoff refused for credit, with nothing able to say why.
//
//   - sealVerdictLog(out), NOT out. It appends the gateway's own refusal text to an ERR-NOCREDIT, which on a
//     user build is the only channel that can separate an unfunded profile from a metering-key bug.
//
//   - rearmRoamSession, NOT markRoamSession. Same write, plus a loud log when it fails. These arms KEEP the
//     user signed in, so a silently missing marker means no periodic seal and a logoff that later finds "no
//     session" -- the failure NWP-20260904-08 exists to stop being silent.
//
// Line-based and comment-stripped, deliberately: these are whole statements, and prose in this file's own
// history names all three identifiers.
func TestHandleLogoutKeepSignedInArmsAreWired(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := funcBody(t, string(b), "handleLogout")
	code := make([]string, 0, len(body))
	for _, l := range body {
		if s := strings.TrimSpace(l); s != "" && !strings.HasPrefix(s, "//") {
			code = append(code, s)
		}
	}
	joined := strings.Join(code, "\n")

	// COUNTS, not mere presence. Both of these appear in BOTH keep-signed-in arms (the failed seal and the
	// late verdict after the stall watchdog un-sticks it), so `strings.Contains` is satisfied by one survivor
	// and a mutation of the other passes -- which is exactly what happened when this test was first written:
	// swapping the first sealVerdictLog(out) back to a bare out was NOT CONVICTED.
	for _, want := range []struct {
		call string
		min  int
		why  string
	}{
		{"logoffSealFailed(out)", 1,
			"the failed-logoff arm must record the verdict, not just set the SEAL-STATUS fields -- " +
				"a logoff-time 402 otherwise never reaches sealStatus/sealReason (NW-e9ef5316ad0a)"},
		{"sealVerdictLog(out)", 2,
			"BOTH keep-signed-in arms must log the gateway's refusal reason on an ERR-NOCREDIT, the " +
				"failed seal and the late verdict after the unstick (NWP-20260904-09)"},
		{"rearmRoamSession(dest, name, pass, uid, seSecret,", 2,
			"an arm that keeps the session signed in must re-arm the marker LOUDLY -- a silent write " +
				"failure means no periodic seal and a logoff that finds no session (NWP-20260904-08)"},
	} {
		if n := strings.Count(joined, want.call); n < want.min {
			t.Errorf("handleLogout calls %s %d time(s), want at least %d: %s",
				want.call, n, want.min, want.why)
		}
	}

	// And no seal verdict may reach a log line raw. Every Fprintf in these arms formats (name, uid, verdict),
	// so a trailing `uid, out)` is the un-wrapped form this slice replaced.
	for _, l := range code {
		if strings.Contains(l, "uid, out)") {
			t.Errorf("handleLogout logs a raw verdict (%q) -- it must pass through sealVerdictLog so an "+
				"ERR-NOCREDIT names the gateway's reason", l)
		}
	}

	// Both keep-signed-in arms re-arm; neither may fall back to the silent write. markRoamSession is correct
	// elsewhere in the file (the login path checks its error itself), so this is scoped to handleLogout.
	for _, l := range code {
		if strings.Contains(l, "markRoamSession(") && !strings.Contains(l, "rearmRoamSession(") {
			t.Errorf("handleLogout calls markRoamSession directly (%q) -- a keep-signed-in arm must use "+
				"rearmRoamSession so a failed marker write is not silent", l)
		}
	}

	// The predecessor of logoffSealFailed was an inline sealFailWhy assignment. If it reappears here the
	// helper has been inlined again and recordSeal has almost certainly been dropped with it.
	if strings.Contains(joined, "sealFailWhy = out") {
		t.Error("handleLogout sets sealFailWhy inline again -- that is logoffSealFailed's body minus " +
			"recordSeal, which is exactly the bug the NWP-20260904-09 review fixed")
	}
}
