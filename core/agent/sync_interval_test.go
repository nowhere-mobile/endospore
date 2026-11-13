package main

import (
	"os"
	"path/filepath"
	"testing"
)

// clampSyncInterval keeps the user-settable seal cadence in [15s, 1 day].
func TestClampSyncInterval(t *testing.T) {
	cases := map[int]int{
		1:       15,    // below floor -> floor
		14:      15,    // just below floor
		15:      15,    // floor
		30:      30,    // a preset
		120:     120,   // a preset
		300:     300,   // 5 min preset
		900:     900,   // the default
		86400:   86400, // ceiling (1 day)
		1000000: 86400, // above ceiling -> ceiling
	}
	for in, want := range cases {
		if got := clampSyncInterval(in); got != want {
			t.Errorf("clampSyncInterval(%d) = %d, want %d", in, got, want)
		}
	}
}

// The periodic save runs every 15 minutes by default (docs/product-decisions.md 2026-11-10), a stored
// /data/nowhere/sync-interval still overrides it, and a stored value the gate no longer offers still applies,
// clamped to [15, 86400] (NWP-20261202-19).
func TestSyncIntervalDefault_FifteenMinutes(t *testing.T) {
	if syncIntervalDefault != 900 {
		t.Errorf("syncIntervalDefault = %d, want 900 (15 minutes, the 2026-11-10 decision)", syncIntervalDefault)
	}
	t.Setenv("NOWHERE_SYNC_INTERVAL", "")
	oldPath := syncIntervalPath
	t.Cleanup(func() { syncIntervalPath = oldPath })
	syncIntervalPath = filepath.Join(t.TempDir(), "sync-interval")
	if got := syncIntervalGet(); got != 900 {
		t.Errorf("syncIntervalGet with no stored value = %d, want 900 (the 15-minute default)", got)
	}
	for _, c := range []struct {
		stored string
		want   int
		why    string
	}{
		{"30", 30, "a stored choice the gate no longer offers still applies"},
		{"10", 15, "a stored value below the floor is clamped to 15"},
		{"1800", 1800, "a stored choice overrides the default"},
	} {
		if err := os.WriteFile(syncIntervalPath, []byte(c.stored+"\n"), 0o600); err != nil {
			t.Fatalf("write %s: %v", syncIntervalPath, err)
		}
		if got := syncIntervalGet(); got != c.want {
			t.Errorf("syncIntervalGet with stored %q = %d, want %d: %s", c.stored, got, c.want, c.why)
		}
	}
}
