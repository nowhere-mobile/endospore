package main

// NWP-20261030-08: pin the login-latency trace (NWP-20260820-27). storeTrace.split is how a slow login's cost is
// attributed to the gateway /cap leg, the object-store leg, the KDF or contention (`other`), and the distinct-head
// counter is how redundant ref reads are told from distinct ones; a silent drift (a wrong unit, an un-clamped negative,
// swapped total/distinct, a field read from the wrong counter) would misattribute the next login-latency regression.
// No files are used and nothing here runs in parallel: the counter is process-global.

import "testing"

// traceSample holds six DIFFERENT values, none a whole millisecond, so a field printed from the wrong counter shows.
var traceSample = storeTrace{capN: 3, capNs: 2_500_000, getN: 7, getNs: 11_900_000, kdfN: 1, kdfNs: 40_000_001}

func TestLoginTraceSplitRendersEachFieldInWholeMs(t *testing.T) {
	got := traceSample.split(100)
	want := "cap=3x/2ms store=7x/11ms kdf=1x/40ms other=47ms"
	if got != want {
		t.Fatalf("split(100) = %q, want %q", got, want)
	}
}

func TestLoginTraceSplitClampsOtherAtZero(t *testing.T) {
	// The three ms figures sum to 53: past a 10ms wall clock (concurrent fetches) and exactly equal to a 53ms one.
	for _, c := range []struct {
		totalMs int64
		why     string
	}{{10, "sum past the wall clock"}, {53, "sum equal to the wall clock"}} {
		got := traceSample.split(c.totalMs)
		want := "cap=3x/2ms store=7x/11ms kdf=1x/40ms other=0ms"
		if got != want {
			t.Errorf("split(%d) (%s) = %q, want %q", c.totalMs, c.why, got, want)
		}
	}
}

func TestLoginTraceSinceSubtractsPerField(t *testing.T) {
	a := storeTrace{110, 2_200_000_000, 330, 4_400_000_000, 550, 6_600_000_000}
	b := storeTrace{1, 200_000_000, 3, 400_000_000, 5, 600_000_000}
	d := a.since(b)
	for _, f := range []struct {
		name      string
		got, want int64
	}{
		{"capN", d.capN, a.capN - b.capN},
		{"capNs", d.capNs, a.capNs - b.capNs},
		{"getN", d.getN, a.getN - b.getN},
		{"getNs", d.getNs, a.getNs - b.getNs},
		{"kdfN", d.kdfN, a.kdfN - b.kdfN},
		{"kdfNs", d.kdfNs, a.kdfNs - b.kdfNs},
	} {
		if f.got != f.want {
			t.Errorf("since: %s = %d, want %d", f.name, f.got, f.want)
		}
	}
	if d != (storeTrace{109, 2_000_000_000, 327, 4_000_000_000, 545, 6_000_000_000}) {
		t.Errorf("since = %+v, not the literal per-field difference", d)
	}
}

func TestLoginTraceDistinctCounter(t *testing.T) {
	traceDistinctMu.Lock()
	saved := traceDistinct
	traceDistinct = nil
	traceDistinctMu.Unlock()
	t.Cleanup(func() {
		traceDistinctMu.Lock()
		traceDistinct = saved
		traceDistinctMu.Unlock()
	})
	snapshot := func() (m map[string]int, isNil bool) {
		traceDistinctMu.Lock()
		defer traceDistinctMu.Unlock()
		m = map[string]int{}
		for k, v := range traceDistinct {
			m[k] = v
		}
		return m, traceDistinct == nil
	}

	// A read while the window is closed is a no-op and is not counted by a window opened afterwards.
	traceRead("logintrace-test/x")
	if _, isNil := snapshot(); !isNil {
		t.Fatal("traceRead with the window closed allocated the map")
	}

	traceDistinctBegin()
	for i := 0; i < 3; i++ {
		traceRead("logintrace-test/a")
	}
	traceRead("logintrace-test/b")
	m, isNil := snapshot()
	if isNil {
		t.Fatal("traceDistinctBegin left the map nil")
	}
	if m["logintrace-test/a"] != 3 || m["logintrace-test/b"] != 1 {
		t.Errorf("window holds a=%d b=%d, want a=3 b=1", m["logintrace-test/a"], m["logintrace-test/b"])
	}
	if _, ok := m["logintrace-test/x"]; ok {
		t.Error("a read made while the window was closed was counted by the next window")
	}

	// Lower bounds: a goroutine an earlier test left behind can read the store while the window is open.
	total, distinct := traceDistinctEnd()
	if total < 4 || distinct < 2 || total <= distinct {
		t.Errorf("traceDistinctEnd = (total %d, distinct %d), want total >= 4, distinct >= 2, total > distinct", total, distinct)
	}
	if _, isNil := snapshot(); !isNil {
		t.Error("traceDistinctEnd left the map non-nil")
	}
	if total, distinct := traceDistinctEnd(); total != 0 || distinct != 0 {
		t.Errorf("second traceDistinctEnd = (%d, %d), want (0, 0)", total, distinct)
	}

	// Begin twice in a row resets the window.
	traceDistinctBegin()
	traceRead("logintrace-test/stale")
	traceDistinctBegin()
	if m, _ := snapshot(); m["logintrace-test/stale"] != 0 {
		t.Errorf("a key read before the second Begin survived it: %v", m)
	}
	traceDistinctEnd()
}
