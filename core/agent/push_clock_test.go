package main

import (
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261117-33: a push's summary and its upload figure name the wall time and the minutes asleep beside the
// monotonic time, which stops in suspend (push_clock.go has the why and frankel's ticket).

func TestPushClockRender(t *testing.T) {
	for _, c := range []struct {
		name       string
		mono, wall time.Duration
		want       string
	}{
		{"equal clocks print today's text", 7*time.Minute + 24*time.Second, 7*time.Minute + 24*time.Second, "in 7m24s"},
		{"a 13-minute suspend (frankel)", 7*time.Minute + 24*time.Second, 20*time.Minute + 35*time.Second, "in 7m24s (wall 20m35s, asleep 13m11s)"},
		{"sub-second above prints the old form", 10 * time.Second, 10*time.Second + 999*time.Millisecond, "in 10s"},
		{"sub-second below prints the old form", 10 * time.Second, 9*time.Second + 500*time.Millisecond, "in 10s"},
		{"wall below mono is clamped", 10 * time.Second, 5 * time.Second, "in 10s (wall 5s, asleep 0s)"},
		{"exactly a second is noted", 10 * time.Second, 11 * time.Second, "in 10s (wall 11s, asleep 1s)"},
		{"rounded to the millisecond", 1234400 * time.Microsecond, 1234400 * time.Microsecond, "in 1.234s"},
	} {
		got := pushClock(c.mono, c.wall)
		if got != c.want {
			t.Errorf("%s: pushClock(%v, %v) = %q, want %q", c.name, c.mono, c.wall, got, c.want)
		}
		if strings.Contains(got, "asleep -") {
			t.Errorf("%s: pushClock(%v, %v) = %q: asleep is never negative (a backward clock step is clamped)", c.name, c.mono, c.wall, got)
		}
	}
}

func TestPushClockSplit(t *testing.T) {
	n, w, b := atomic.LoadInt64(&capFlushNanos), atomic.LoadInt64(&capFlushWallNanos), atomic.LoadInt64(&capFlushBytes)
	t.Cleanup(func() {
		atomic.StoreInt64(&capFlushNanos, n)
		atomic.StoreInt64(&capFlushWallNanos, w)
		atomic.StoreInt64(&capFlushBytes, b)
	})
	atomic.StoreInt64(&capFlushNanos, int64(5*time.Second))
	atomic.StoreInt64(&capFlushWallNanos, int64(5*time.Minute+5*time.Second))
	atomic.StoreInt64(&capFlushBytes, 2048<<10)
	if got, want := pushSplit(time.Now().Add(-10*time.Second)), "upload 5s/2048KiB (wall 5m5s, asleep 5m0s), local "; !strings.HasPrefix(got, want) {
		t.Errorf("an upload the phone slept through: pushSplit = %q, want prefix %q", got, want)
	}
	atomic.StoreInt64(&capFlushWallNanos, int64(5*time.Second))
	if got, want := pushSplit(time.Now().Add(-10*time.Second)), "upload 5s/2048KiB, local "; !strings.HasPrefix(got, want) {
		t.Errorf("an upload with no suspend: pushSplit = %q, want today's prefix %q", got, want)
	}
}

// TestPushClockSourceReadings pins that each wall figure is a Sub of two Round(0) readings. No unit test can
// suspend the clock, and a wall time computed from monotonic readings would compile, pass every rendering test,
// and always show asleep 0 -- the exact defect this slice fixes.
func TestPushClockSourceReadings(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	count := func(lines []string, sub string) int {
		k := 0
		for _, l := range lines {
			if strings.Contains(l, sub) {
				k++
			}
		}
		return k
	}
	want := func(fn string, lines []string, sub string, n int, why string) {
		t.Helper()
		if k := count(lines, sub); k != n {
			t.Errorf("%s: %d line(s) hold %q, want %d -- %s", fn, k, sub, n, why)
		}
	}
	const monoWhy = "a wall time computed from monotonic readings always shows asleep 0"

	pp := stripComments(funcBody(t, src, "pushProfile"))
	want("pushProfile", pp, "t0 := time.Now()", 1, "t0 stays the monotonic reading")
	want("pushProfile", pp, "t0w := t0.Round(0)", 1, monoWhy)
	want("pushProfile", pp, "pushClock(time.Since(t0), time.Now().Round(0).Sub(t0w))", 2, "both summary lines print pushClock; "+monoWhy)
	want("pushProfile", pp, "time.Since(t0).Round(time.Millisecond)", 0, "a summary left on the monotonic-only figure")
	want("pushProfile", pp, "in %s [%s]", 0, "a summary left on the old `in %s` format")
	for _, c := range []struct{ head, form string }{
		{`"push: profile %s (vault) -> `, "gen %s v%d %s [%s]"},
		{`"push: profile %s -> `, "gen %s %s [%s]"},
	} {
		found := false
		for i, l := range pp {
			if !strings.Contains(l, c.head) {
				continue
			}
			found = true
			if !strings.Contains(l, c.form) {
				t.Errorf("pushProfile: the summary %s… does not print %q: %s", c.head, c.form, strings.TrimSpace(l))
			}
			if i+1 >= len(pp) || !strings.Contains(pp[i+1], "pushClock(time.Since(t0), time.Now().Round(0).Sub(t0w)), pushSplit(t0))") {
				t.Errorf("pushProfile: the summary %s… does not take pushClock's two readings as its duration", c.head)
			}
		}
		if !found {
			t.Errorf("pushProfile: summary %s… not found -- this test is stale, not the code", c.head)
		}
	}

	cf := stripComments(funcBody(t, src, "capFlush"))
	want("capFlush", cf, "tFlushW := tFlush.Round(0)", 1, monoWhy)
	want("capFlush", cf, "atomic.AddInt64(&capFlushWallNanos, int64(time.Now().Round(0).Sub(tFlushW)))", 1, monoWhy)
	want("capFlush", cf, "atomic.AddInt64(&capFlushNanos, int64(time.Since(tFlush)))", 1, "the upload's monotonic figure stays")

	ps := stripComments(funcBody(t, src, "pushSplit"))
	want("pushSplit", ps, "upw := time.Duration(atomic.LoadInt64(&capFlushWallNanos))", 1, "the upload figure names its wall time")
	want("pushSplit", ps, "sleepNote(up, upw)", 1, "the upload figure names its wall time and the minutes asleep")
}
