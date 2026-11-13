package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20260903-09 (#147). The keyguard arm queued on the RW worker slot behind whole seals.
//
// The defect was a QUEUE POSITION, not a bug in any op: armcred and rekey are sub-second lock_settings
// calls, and laneFor sent them to the RW lane, where a seal, restore or materialise holds the single slot
// for minutes. Field measurement (NW-600f775808fc, frankel 0.5.16, 2026-09-02): a periodic seal HELD the
// slot 125s, armcred WAITED 73.7s behind it, inside the cold-lock path. On the login path the same wait is
// the "just logged in, walked away while it restores" window -- the session screen sits unprotected until
// the arm lands. Three prior slices narrowed neighbours of this (#83's enqueue-and-ack, -19's login window,
// -25-11's user-op priority) and the row stayed open because none of them changed WHERE THE OP WAITS.
//
// So the assertions here are about routing and lane isolation -- the properties whose loss silently
// recreates the wait. Everything tested is a pure function or package state; no device needed.

func TestCredOpsRideTheCredLane(t *testing.T) {
	for _, op := range []string{"armcred", "rekey"} {
		if got := laneFor(op); got.svc != laneCred.svc {
			t.Errorf("laneFor(%q).svc = %q, want %q -- the keyguard arm is back to waiting behind seals (#147)",
				op, got.svc, laneCred.svc)
		}
	}
}

func TestCredLaneMembershipIsExactlyTwoOps(t *testing.T) {
	// The membership bar (see laneCred's comment) is deliberately high: sub-second, no store, no roamed
	// tree, needs a credential. Every op known to the worker protocol is enumerated so a NEW op cannot
	// drift onto the cred lane without editing this list -- the same discipline as the shell side's
	// allowlist, enforced from the caller's side.
	rw := []string{"in", "out", "grant", "seed-home", "seedssaid", "dropssaid", "btwipe", "sweepmedia", "cleanstorage",
		"odrestore", "materializeapp", "stageapp", "fido2-enroll", "delete", "capture", "promote",
		"coldsweep", "evictcheck", // NWP-20261004-01: the cold lock's pre-stop op and its re-check (alarmrelay moved to RO)
		"cutoff", "cutoffwake", // NWP-20261011-04: the logoff cutoff stops packages for SECONDS, on the session's own lane
		"logscrub", // NWP-20261027-02: a failed sign-in's log scrub rides the RW lane, never the cred lane
		"bootwake"} // NWP-20261114-01: the sign-in boot wake sends broadcasts for up to two budgets, on the RW lane
	for _, op := range rw {
		if got := laneFor(op); got.svc == laneCred.svc {
			t.Errorf("laneFor(%q) rides the CRED lane -- that lane runs CONCURRENT with seals, and %q does "+
				"not meet the membership bar (sub-second, no store, no roamed tree)", op, op)
		}
	}
	ro := []string{"storagebreakdown", "sealdelta", "uiderrors",
		"alarmrelay", // NWP-20261108-02 (Q183): one `am startservice`, uid only, must not queue behind an abandoned RW op
		"gmsstate",   // NWP-20261201-01: two read-only activity-manager dumps for an issue report
		"gmsexits"}   // NWP-20261201-02: one `dumpsys activity exit-info`, uid only, for an issue report
	for _, op := range ro {
		if got := laneFor(op); got.svc != laneRO.svc {
			t.Errorf("laneFor(%q).svc = %q, want the RO lane -- this test is not about them, but moving "+
				"them would be its own regression", op, got.svc)
		}
	}
}

func TestLanesShareNoState(t *testing.T) {
	// Each lane's req/res/prog basenames and its slot channel must be distinct across all three lanes: a
	// shared file corrupts a concurrent op's request, and a shared slot re-serialises the lanes -- which is
	// the entire defect, reintroduced quietly.
	lanes := []workerLane{laneRW, laneRO, laneCred}
	names := map[string]string{}
	for _, l := range lanes {
		for _, f := range []string{l.req, l.res, l.prog} {
			if prior, dup := names[f]; dup {
				t.Errorf("lane file %q is shared between %q and %q -- concurrent ops would clobber each other", f, prior, l.svc)
			}
			names[f] = l.svc
		}
	}
	if laneCred.slot == laneRW.slot || laneCred.slot == laneRO.slot {
		t.Error("laneCred shares a slot channel with another lane -- the arm is re-serialised behind that lane's ops")
	}
	if cap(laneCred.slot) != 1 {
		t.Errorf("laneCred slot cap = %d, want 1 (cred ops serialise with EACH OTHER, exactly like the RO lane)", cap(laneCred.slot))
	}
}

func TestCredLaneServiceNameStaysUnderThePropertyPrefix(t *testing.T) {
	// ctl.start$nowhere_roamd is a PREFIX match in property_contexts (no `exact` keyword), which is the
	// entire reason this lane ships with no sepolicy change -- the .rc comment carries the argument. A
	// rename that leaves the prefix breaks ctl.start with an avc denial that is silent until the first
	// cold-lock on an enforcing build.
	const prefix = "nowhere_roamd"
	if len(laneCred.svc) < len(prefix) || laneCred.svc[:len(prefix)] != prefix {
		t.Errorf("laneCred.svc = %q does not start with %q -- ctl.start$ property coverage is lost", laneCred.svc, prefix)
	}
}

// NWP-20261015-32: the Keystore census is retired from the agent and roamd (keystore2 still writes the file).
// Source pins, so a revert that re-adds the verb or the op is caught.
func TestKeystoreCensusServingStaysRetired(t *testing.T) {
	m, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(m), `"GET-KEYSTORE-NS"`) || strings.Contains(string(m), `case "keystorens"`) {
		t.Error("main.go serves GET-KEYSTORE-NS / keystorens again -- the census has no reader (NWP-20261015-32)")
	}
	if _, err := os.Stat("keystore_census.go"); err == nil {
		t.Error("keystore_census.go is back -- the census handler was retired (NWP-20261015-32)")
	}
	b, err := os.ReadFile("../vendor-common/bin/nowhere_roamd.sh")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "\n  keystorens)") {
		t.Error("nowhere_roamd.sh has a keystorens op arm again (NWP-20261015-32)")
	}
	// NWP-20261126-13 split the prune: the map is renamed over from keystore-map.reap, the census and the keep-list are
	// rewritten in place by their own loop, so the census guard reads that loop.
	if !strings.Contains(string(b), `for _ksf in "$KS_KEEP" "$KS_CENSUS"`) {
		t.Error("the reap prune of the census file is gone, but keystore2 still writes it -- amnesia guard")
	}
}
