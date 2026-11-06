package main

import (
	"strconv"
	"testing"
)

// resetLostStarts zeroes the daemon-lifetime counter for a test and restores it afterwards.
func resetLostStarts(t *testing.T) {
	t.Helper()
	prev := roamLostStarts.Load()
	roamLostStarts.Store(0)
	t.Cleanup(func() { roamLostStarts.Store(prev) })
}

// TestNoteLostStartCounts (NWP-20261011-35) pins that every #83 lost-start recovery is counted and that the
// returned value is the new count, which numbers the recovery's log line.
func TestNoteLostStartCounts(t *testing.T) {
	resetLostStarts(t)
	if n := noteLostStart("materializeapp"); n != 1 {
		t.Fatalf("first noteLostStart = %d, want 1", n)
	}
	if n := noteLostStart("bootsweep"); n != 2 {
		t.Fatalf("second noteLostStart = %d, want 2", n)
	}
	if n := roamLostStarts.Load(); n != 2 {
		t.Fatalf("roamLostStarts = %d after two recoveries, want 2", n)
	}
}

// TestIssueReportCarriesLostStarts (NWP-20261011-35): the count must reach the report at BOTH scopes. Before
// this slice it went only to stderr, which a gate report excludes, so 24 recoveries on one device went unseen.
func TestIssueReportCarriesLostStarts(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	resetLostStarts(t)
	roamLostStarts.Store(24)
	want := strconv.FormatInt(roamLostStarts.Load(), 10)
	for _, c := range []struct {
		name  string
		scope bool
	}{{"", true}, {"x", false}} {
		rep := buildIssueReport(c.name, c.scope, "", nil, nil)
		if got, ok := rep.Status["roam_lost_starts"]; !ok || got != want {
			t.Errorf("deviceScope=%v: status roam_lost_starts = %q (present=%v), want %q", c.scope, got, ok, want)
		}
	}
}
