package main

import (
	"fmt"
	"testing"
)

// NWP-20261124-02 (docs/product-decisions.md 2026-11-02 #1): the automatic snapshots keep 1 recent + 1 hourly +
// 5 daily, a slot reserved per tier, capped at 7. Pruning runs at every seal on the previous result, so these
// tests feed seals one at a time through pruneSnapshots, as pushSnapshot does, and check what survives.

const (
	snapTiersHourWin = int64(6 * 3600)
	snapTiersDayWin  = int64(5 * 86400)
	snapTiersT0      = int64(20000) * 86400 // a fixed, day-aligned epoch
)

// snapTiersDefaults clears every retention knob, so snapEnv gives each its default.
func snapTiersDefaults(t *testing.T) {
	for _, k := range []string{"NOWHERE_SNAP_MANUAL", "NOWHERE_SNAP_AUTO", "NOWHERE_SNAP_AUTO_RECENT",
		"NOWHERE_SNAP_AUTO_HOURLY", "NOWHERE_SNAP_AUTO_HOURS", "NOWHERE_SNAP_AUTO_DAYS"} {
		t.Setenv(k, "")
	}
}

// snapTiersSeal prepends one seal at time ts to the newest-first hist and prunes it at now = ts.
func snapTiersSeal(hist []headSnap, v uint64, ts int64, kind string) []headSnap {
	s := headSnap{Version: v, Manifest: fmt.Sprintf("m%d", v), Time: ts, Kind: kind}
	return pruneSnapshots(append([]headSnap{s}, hist...), ts)
}

// snapTiersDump renders the kept entries with their ages, for a readable failure.
func snapTiersDump(hist []headSnap, now int64) string {
	out := ""
	for _, s := range hist {
		out += fmt.Sprintf("\n  v%d kind=%q age=%.2fh day=%d", s.Version, s.Kind, float64(now-s.Time)/3600, s.Time/86400)
	}
	return out
}

// snapTiersCheckOrder fails unless hist is strictly newest-first by Version.
func snapTiersCheckOrder(t *testing.T, hist []headSnap, now int64) {
	t.Helper()
	for i := 1; i < len(hist); i++ {
		if hist[i].Version >= hist[i-1].Version {
			t.Fatalf("history not newest-first at %d:%s", i, snapTiersDump(hist, now))
		}
	}
}

// snapTiersDaily returns the automatic entries older than the hourly window and their distinct day buckets.
// It fails if any automatic entry is older than the day window.
func snapTiersDaily(t *testing.T, hist []headSnap, now int64) (daily []headSnap, buckets map[int64]bool) {
	t.Helper()
	buckets = map[int64]bool{}
	for _, s := range hist {
		if s.Kind == "manual" {
			continue
		}
		age := now - s.Time
		if age > snapTiersDayWin {
			t.Fatalf("an automatic entry older than the day window was kept:%s", snapTiersDump(hist, now))
		}
		if age > snapTiersHourWin {
			daily = append(daily, s)
			buckets[s.Time/86400] = true
		}
	}
	return daily, buckets
}

// 30 days of automatic seals 120 s apart: the history reaches days back, one per day, not just a few hours.
func TestSnapTiersThirtyDaysOfTwoMinuteSeals(t *testing.T) {
	snapTiersDefaults(t)
	var hist []headSnap
	var v uint64
	var now int64
	for ts := snapTiersT0; ts < snapTiersT0+30*86400; ts += 120 {
		v++
		now = ts
		hist = snapTiersSeal(hist, v, ts, "")
		if len(hist) > 7 {
			t.Fatalf("automatic cap 7 exceeded at seal %d:%s", v, snapTiersDump(hist, now))
		}
		if ts == snapTiersT0+3*86400 {
			if span := hist[0].Time - hist[len(hist)-1].Time; span <= 2*86400 {
				t.Fatalf("after 3 days the history spans only %.2fh, want more than 2 days:%s",
					float64(span)/3600, snapTiersDump(hist, now))
			}
		}
	}
	snapTiersCheckOrder(t, hist, now)
	if hist[0].Version != v {
		t.Fatalf("the newest entry is v%d, want the last seal v%d:%s", hist[0].Version, v, snapTiersDump(hist, now))
	}
	young := 0
	for _, s := range hist[1:] {
		if s.Kind == "manual" {
			t.Fatalf("a manual entry appeared from automatic seals:%s", snapTiersDump(hist, now))
		}
		if now-s.Time <= snapTiersHourWin {
			young++
		}
	}
	if young < 1 {
		t.Fatalf("no entry inside the hourly window besides the newest:%s", snapTiersDump(hist, now))
	}
	daily, buckets := snapTiersDaily(t, hist, now)
	if len(daily) != 5 || len(buckets) != 5 {
		t.Fatalf("want 5 entries older than the hourly window in 5 day buckets, got %d in %d:%s",
			len(daily), len(buckets), snapTiersDump(hist, now))
	}
	if age := now - hist[len(hist)-1].Time; age <= 4*86400 {
		t.Fatalf("the oldest entry is %.2fh old, want more than 4 days:%s", float64(age)/3600, snapTiersDump(hist, now))
	}
}

// The phone seals only 8 h a day (off at night) for 10 days: the daily tier still fills, the cap still holds.
func TestSnapTiersGapAndSparseSeals(t *testing.T) {
	snapTiersDefaults(t)
	var hist []headSnap
	var v uint64
	var now int64
	for ts := snapTiersT0; ts < snapTiersT0+10*86400; ts += 120 {
		if h := (ts % 86400) / 3600; h < 8 || h >= 16 {
			continue
		}
		v++
		now = ts
		hist = snapTiersSeal(hist, v, ts, "")
		if len(hist) > 7 {
			t.Fatalf("automatic cap 7 exceeded at seal %d:%s", v, snapTiersDump(hist, now))
		}
	}
	snapTiersCheckOrder(t, hist, now)
	if _, buckets := snapTiersDaily(t, hist, now); len(buckets) != 5 {
		t.Fatalf("want 5 distinct day buckets older than the hourly window, got %d:%s",
			len(buckets), snapTiersDump(hist, now))
	}
}

// A manual save every 6 h among 3 days of automatic seals: the newest 4 manual stay, pinned, and take no
// automatic slot.
func TestSnapTiersManualUntouched(t *testing.T) {
	snapTiersDefaults(t)
	var hist []headSnap
	var manualFed []uint64 // newest first
	var v uint64
	var now int64
	for ts := snapTiersT0; ts < snapTiersT0+3*86400; ts += 120 {
		v++
		now = ts
		kind := ""
		if (ts-snapTiersT0)%21600 == 0 {
			kind = "manual"
			manualFed = append([]uint64{v}, manualFed...)
		}
		hist = snapTiersSeal(hist, v, ts, kind)
		if len(hist) > 11 {
			t.Fatalf("4 manual + 7 automatic = 11 exceeded at seal %d:%s", v, snapTiersDump(hist, now))
		}
	}
	snapTiersCheckOrder(t, hist, now)
	var manual []uint64
	auto := 0
	for _, s := range hist {
		if s.Kind == "manual" {
			manual = append(manual, s.Version)
		} else {
			auto++
		}
	}
	if fmt.Sprint(manual) != fmt.Sprint(manualFed[:4]) {
		t.Fatalf("manual entries %v, want the newest 4 fed %v:%s", manual, manualFed[:4], snapTiersDump(hist, now))
	}
	if auto > 7 {
		t.Fatalf("%d automatic entries, want at most 7:%s", auto, snapTiersDump(hist, now))
	}
	if hist[0].Kind != "" || hist[0].Version != v {
		t.Fatalf("the newest entry is not the last automatic seal v%d:%s", v, snapTiersDump(hist, now))
	}
	young := 0
	for _, s := range hist[1:] {
		if s.Kind == "" && now-s.Time <= snapTiersHourWin {
			young++
		}
	}
	if young < 1 {
		t.Fatalf("no automatic entry inside the hourly window besides the newest:%s", snapTiersDump(hist, now))
	}
	if _, buckets := snapTiersDaily(t, hist, now); len(buckets) < 3 {
		t.Fatalf("want at least 3 day buckets of automatic entries older than the hourly window, got %d:%s",
			len(buckets), snapTiersDump(hist, now))
	}
}

// RF-001: an expired automatic entry drops even when it is the NEWEST. After six days unused, the first changed
// seal pushes the outgoing head with its six-day-old seal time; the recent tier must not keep it past the five-day
// day window. A manual save beside it stays pinned.
func TestSnapTiersExpiredNewestDrops(t *testing.T) {
	snapTiersDefaults(t)
	now := snapTiersT0 + 10*86400
	got := pruneSnapshots([]headSnap{{Version: 3, Time: now - 6*86400, Manifest: "m3"}}, now)
	if len(got) != 0 {
		t.Fatalf("kept an automatic entry six days old as the newest; the day window is five days:%s",
			snapTiersDump(got, now))
	}
	got = pruneSnapshots([]headSnap{
		{Version: 5, Time: now - 6*86400, Manifest: "m5"},
		{Version: 4, Time: now - 7*86400, Manifest: "m4", Kind: "manual"},
		{Version: 3, Time: now - 8*86400, Manifest: "m3"},
	}, now)
	if len(got) != 1 || got[0].Version != 4 || got[0].Kind != "manual" {
		t.Fatalf("want only the pinned manual v4, the expired automatic v5 and v3 dropped:%s", snapTiersDump(got, now))
	}
	// A first seal's outgoing head has no seal time (Time 0): no known age, so the recent tier keeps it.
	got = pruneSnapshots([]headSnap{{Version: 1, Manifest: "m1"}}, now)
	if len(got) != 1 || got[0].Version != 1 {
		t.Fatalf("dropped the first seal's outgoing head (no seal time) from the recent tier:%s", snapTiersDump(got, now))
	}
}
