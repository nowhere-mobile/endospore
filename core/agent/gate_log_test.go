package main

import (
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// gate.log is carried by a GATE-filed issue report, whose preview renders ON SCREEN AT THE GATE -- where the
// next person to pick the phone up can read it -- and which is posted to a gateway that is supposed to learn
// nothing. So the load-bearing property is not "we filter the input", it is "no caller-supplied string can
// reach the file at all". These tests pin that, plus the two bounds that keep it from evicting ota.log.

func gateLogTestFile(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "gate.log")
	old := gateLogPath
	gateLogPath = p
	t.Cleanup(func() { gateLogPath = old })
	gateLogMu.Lock()
	gateLogPrimed = false
	gateLogMu.Unlock()
	return p
}

// TestGateLogNeverWritesCallerText is THE test. A profile name is the thing that must never appear, and a
// charset filter would not stop one -- "alice" is all lower-case letters. The closed verb set is what does.
func TestGateLogNeverWritesCallerText(t *testing.T) {
	p := gateLogTestFile(t)
	// Every one of these is a plausible leak: a profile name, a package, a path, a passphrase-ish blob, a
	// name that happens to look like one of our own verbs, and a name with an = in it.
	leaks := []string{
		"alice", "odtest44", "com.android.deskclock", "/data/user/10/android",
		"mouseinthehouse", "start-alice", "name=alice", "ui-create-alice",
	}
	for _, bad := range leaks {
		gateLog(bad, "in", 42)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	got := string(b)
	for _, bad := range leaks {
		if strings.Contains(got, bad) {
			t.Errorf("gate.log contains caller text %q -- a closed verb set is the ONLY thing standing between "+
				"a profile name and a report rendered on screen at the gate:\n%s", bad, got)
		}
	}
	if n := strings.Count(got, "trace-unknown"); n != len(leaks) {
		t.Errorf("trace-unknown count = %d, want %d -- a rejected verb must still RECORD the event; a trace "+
			"that vanishes is the failure this file exists to end", n, len(leaks))
	}
}

// NWP-20261013-02: `d` is CLOCK_BOOTTIME seconds between lines, so it advances across a suspend that `m`
// (CLOCK_MONOTONIC) does not see. Until this slice the boot clock was a /proc/uptime read the daemon's domain
// is denied on an enforcing build, so d read 0 on every line on device. Here the boot clock is injected to
// jump 300 s between two lines written back to back: d must carry the 300 while m stays ~0 -- that gap IS
// the suspend. And an unreadable clock writes d=none, never a fabricated number. Since NWP-20261123-18 (h53 #7)
// every gap is a bucket: the 300 s jump is d=lt10m with s=lt10m, the suspend.
func TestGateLogDCarriesTheBootClock(t *testing.T) {
	p := gateLogTestFile(t)
	clock := int64(1000)
	old := bootUptime
	bootUptime = func() (int64, error) { return clock, nil }
	t.Cleanup(func() { bootUptime = old })

	gateLog("ui-create", "", 0)
	clock += 300
	gateLog("ui-destroy", "ms", 120)
	clock += 7
	bootUptime = func() (int64, error) { return 0, os.ErrPermission }
	gateLog("ui-ring", "", 0)

	b, _ := os.ReadFile(p)
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 lines, got %d:\n%s", len(lines), b)
	}
	if !strings.HasPrefix(lines[1], "d=lt10m m=none s=lt10m ui-destroy") {
		t.Errorf("line %q: want d=lt10m (the boot clock advanced 300 s), m=none (no monotonic time passed) "+
			"and s=lt10m (the suspend)", lines[1])
	}
	if !strings.HasPrefix(lines[2], "d=none ") {
		t.Errorf("line %q: an unreadable boot clock must write d=none, not a guess", lines[2])
	}
}

// TestGateLogGrammar pins the whole line shape. If a future edit widens it, this is what refuses.
func TestGateLogGrammar(t *testing.T) {
	p := gateLogTestFile(t)
	gateLog("ui-create", "", 0)
	gateLog("relay-set", "in", -17) // negative `in` is a real case: an alarm already in the past (in=past)
	gateLog("ui-destroy", "ms", 120)
	gateLog("relay-set", "badkey", 9) // an unknown key is dropped, the event survives
	b, _ := os.ReadFile(p)
	const gap = `(none|lt10s|lt1m|lt10m|lt1h|ge1h)`
	line := regexp.MustCompile(`^d=` + gap + ` m=` + gap + ` s=` + gap + ` [a-z-]+( (in=(past|under1h|1to12h|over12h)|(ms|fields)=-?\d+))?$`)
	for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		if !line.MatchString(l) {
			t.Errorf("line %q does not match the closed grammar", l)
		}
	}
	if strings.Contains(string(b), "badkey") {
		t.Errorf("an unknown key reached the file:\n%s", string(b))
	}
	if !strings.Contains(string(b), "relay-set\n") {
		t.Errorf("the event with the rejected key was dropped entirely; it must survive WITHOUT the key:\n%s", string(b))
	}
}

// TestGateLogInIsBucketed pins decision #33 (2026-10-22, docs/product-decisions.md): `in=` is written as one of
// four buckets, never as a countdown. An exact countdown plus a report's created_at and uptime_s rebuilds the
// alarm's wall-clock time, which the gate report shows to whoever holds the phone. Each edge is checked from
// both sides, through gateLog (the file's one writer) and through the GATE-TRACE path a chooser line takes.
func TestGateLogInIsBucketed(t *testing.T) {
	p := gateLogTestFile(t)
	cases := []struct {
		sec  int
		want string
	}{
		{-86400, "past"}, {-1, "past"},
		{0, "under1h"}, {3599, "under1h"},
		{3600, "1to12h"}, {43200, "1to12h"},
		{43201, "over12h"}, {gateAlarmInSeconds("4102444800000"), "over12h"}, // 2100-01-01
	}
	for _, c := range cases {
		gateLog("relay-set", "in", c.sec)
	}
	v, k, n := gateTraceLine("armed in=7200")
	gateLog(v, k, n)

	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) != len(cases)+1 {
		t.Fatalf("want %d lines, got %d:\n%s", len(cases)+1, len(lines), b)
	}
	for i, c := range cases {
		want := " relay-set in=" + c.want
		if !strings.HasSuffix(lines[i], want) {
			t.Errorf("in=%d wrote %q, want the bucket %q (#33: a bucket, never a countdown)", c.sec, lines[i], want)
		}
	}
	if want := " armed in=1to12h"; !strings.HasSuffix(lines[len(cases)], want) {
		t.Errorf("GATE-TRACE \"armed in=7200\" wrote %q, want the bucket %q", lines[len(cases)], want)
	}
	// Anchored to a WHOLE integer value: a bare `in=-?[0-9]` would also match the bucket token "1to12h".
	if regexp.MustCompile(`(?m)\bin=-?[0-9]+$`).Match(b) {
		t.Errorf("gate.log carries an exact in= countdown (#33 asks for one of four buckets):\n%s", b)
	}
}

// TestGateLogCapNeverExceedsFortyLines. Forty is not a taste: trimIssueReport halves the biggest section
// only when it has MORE than 40 lines, so a section at or under 40 is carried whole or dropped whole. A
// half-eaten alarm trace reads as "the alarm was never scheduled", which is worse than no trace.
func TestGateLogCapNeverExceedsFortyLines(t *testing.T) {
	p := gateLogTestFile(t)
	for i := 0; i < 200; i++ {
		gateLog("ui-create", "ms", i)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	// ⚠ 40 AND 4096 ARE WRITTEN OUT AS LITERALS HERE, DELIBERATELY. Asserting against gateLogMaxLines would
	// make this test restate the code: raise the constant and the assertion rises with it, which is exactly
	// what a mutation check caught on the first draft. 40 is not ours to choose freely -- it is
	// trimIssueReport's halving threshold, and the whole point is that a gate trace is never half-eaten.
	if len(lines) > 40 {
		t.Errorf("gate.log has %d lines; the cap must be 40 or fewer -- ABOVE 40 trimIssueReport halves the "+
			"biggest section, and a trace missing its beginning reads as 'the alarm was never scheduled'",
			len(lines))
	}
	if gateLogMaxLines > 40 {
		t.Errorf("gateLogMaxLines = %d; it may not exceed trimIssueReport's halving threshold of 40",
			gateLogMaxLines)
	}
	if len(b) > 4096 {
		t.Errorf("gate.log is %d bytes; the cap must be 4096 or fewer so it can never be the reason ota.log "+
			"is evicted from a gate report", len(b))
	}
	// It must keep the NEWEST lines: the tail is the part next to the failure being reported.
	if !strings.Contains(string(b), "ms=199") {
		t.Errorf("the newest line was rotated away; rotation must drop the OLDEST:\n%s", string(b))
	}
}

// TestGateAlarmInSecondsNeverCarriesAnInstant. The countdown IS the privacy control -- an absolute alarm
// time describes a person's routine, and this file is read at the gate by whoever holds the phone.
func TestGateAlarmInSecondsNeverCarriesAnInstant(t *testing.T) {
	if got := gateAlarmInSeconds("not-a-number"); got != 0 {
		t.Errorf("unparseable = %d, want 0 (we could not tell, rather than an invented horizon)", got)
	}
	if got := gateAlarmInSeconds(""); got != 0 {
		t.Errorf("empty = %d, want 0", got)
	}
	// A far-future instant must render as a bounded countdown, never as the instant itself.
	p := gateLogTestFile(t)
	gateLog("relay-set", "in", gateAlarmInSeconds("4102444800000")) // 2100-01-01
	b, _ := os.ReadFile(p)
	if strings.Contains(string(b), "4102444800000") {
		t.Errorf("an absolute epoch reached the file:\n%s", string(b))
	}
}

// TestGateTraceLineIsClosed pins the wire parser used by the GATE-TRACE verb, since that is the path a
// hostile or buggy sender actually reaches.
func TestGateTraceLineIsClosed(t *testing.T) {
	cases := []struct{ in, verb, key string }{
		{"ui-create", "ui-create", ""},
		{"ui-destroy ms=12", "ui-destroy", "ms"},
		{"  ui-ring  ", "ui-ring", ""},
		{"", "trace-unknown", ""},
		{"alice ms=1", "alice", "ms"},             // gateLog rejects the verb; the parser is not where that happens
		{"ui-create note=hello", "ui-create", ""}, // a non-integer value is dropped whole
	}
	for _, c := range cases {
		v, k, _ := gateTraceLine(c.in)
		if v != c.verb || k != c.key {
			t.Errorf("gateTraceLine(%q) = (%q,%q), want (%q,%q)", c.in, v, k, c.verb, c.key)
		}
	}
}

// gateLogTestGap moves both of gateLog's clocks on before the next line: the injected boot clock by boot
// seconds, and the monotonic reading of the previous line back by mono seconds, so the next line's m is mono.
func gateLogTestGap(t *testing.T, clock *int64, boot, mono int64) {
	t.Helper()
	gateLogMu.Lock()
	gateLogPrevMono = gateLogPrevMono.Add(-time.Duration(mono) * time.Second)
	gateLogMu.Unlock()
	*clock += boot
}

// gateLogTestClock injects the boot clock gateLog reads and returns it, so a test can move it.
func gateLogTestClock(t *testing.T) *int64 {
	t.Helper()
	clock := int64(1000)
	old := bootUptime
	bootUptime = func() (int64, error) { return clock, nil }
	t.Cleanup(func() { bootUptime = old })
	return &clock
}

func gateLogTestLines(t *testing.T, p string) []string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return strings.Split(strings.TrimRight(string(b), "\n"), "\n")
}

// TestGateGapBucketEdges pins h53 #7 (docs/product-decisions.md, 2026-11-02): d=, m= and s= are buckets, and
// every edge is checked from both sides, directly and through gateLog. The edges are the decision's drafts,
// for Chester to correct; the zero bucket is the word "none", never the digit 0.
func TestGateGapBucketEdges(t *testing.T) {
	cases := []struct {
		sec  int
		want string
	}{
		{-5, "none"}, {0, "none"},
		{1, "lt10s"}, {9, "lt10s"},
		{10, "lt1m"}, {59, "lt1m"},
		{60, "lt10m"}, {599, "lt10m"},
		{600, "lt1h"}, {3599, "lt1h"},
		{3600, "ge1h"}, {86400, "ge1h"},
	}
	for _, c := range cases {
		if got := gateGapBucket(c.sec); got != c.want {
			t.Errorf("gateGapBucket(%d) = %q, want %q", c.sec, got, c.want)
		}
	}

	p := gateLogTestFile(t)
	clock := gateLogTestClock(t)
	gateLog("start", "", 0)
	for _, c := range cases {
		if c.sec < 0 {
			continue // a gap cannot be negative through gateLog: the direct call above covers it
		}
		gateLogTestGap(t, clock, int64(c.sec), int64(c.sec))
		gateLog("ui-ring", "", 0)
		lines := gateLogTestLines(t, p)
		last := lines[len(lines)-1]
		if want := "d=" + c.want + " m=" + c.want + " s=none ui-ring"; last != want {
			t.Errorf("a %d s gap with no suspend wrote %q, want %q", c.sec, last, want)
		}
	}
}

// TestGateLogGapsAreBucketed drives gateLog with both clocks faked: s= is the suspend, d - m when that is 2 or
// more. A difference of 1 is rounding (gateUptimeSeconds rounds up, m rounds down), so it writes s=none.
func TestGateLogGapsAreBucketed(t *testing.T) {
	p := gateLogTestFile(t)
	clock := gateLogTestClock(t)
	gateLog("start", "", 0)
	cases := []struct {
		boot, mono int64
		want       string
	}{
		{70, 70, "d=lt10m m=lt10m s=none ui-ring"},
		{1675, 1674, "d=lt1h m=lt1h s=none ui-ring"},
		{1700, 100, "d=lt1h m=lt10m s=lt1h ui-ring"},
	}
	for _, c := range cases {
		gateLogTestGap(t, clock, c.boot, c.mono)
		gateLog("ui-ring", "", 0)
		lines := gateLogTestLines(t, p)
		if last := lines[len(lines)-1]; last != c.want {
			t.Errorf("a %d s boot gap with %d s monotonic wrote %q, want %q", c.boot, c.mono, last, c.want)
		}
	}
	bootUptime = func() (int64, error) { return 0, os.ErrPermission }
	gateLog("ui-ring", "", 0)
	lines := gateLogTestLines(t, p)
	if last := lines[len(lines)-1]; !strings.HasPrefix(last, "d=none ") {
		t.Errorf("an unreadable boot clock wrote %q, want d=none", last)
	}
}

// TestGateLogNeverWritesAnExactElapsedTime is the no-exact-time property (h53 #7): for many random gaps, every
// line carries d=, m= and s= exactly once, each as one of the six bucket tokens. ms= and fields= are other keys
// and stay integers.
func TestGateLogNeverWritesAnExactElapsedTime(t *testing.T) {
	p := gateLogTestFile(t)
	clock := gateLogTestClock(t)
	bucket := map[string]bool{"none": true, "lt10s": true, "lt1m": true, "lt10m": true, "lt1h": true, "ge1h": true}
	r := rand.New(rand.NewSource(1123))
	keys := []string{"", "in", "ms", "fields"}
	var all []string
	gateLog("start", "", 0)
	for i := 0; i < 300; i++ {
		boot := r.Int63n(20000)
		mono := r.Int63n(boot + 1)
		gateLogTestGap(t, clock, boot, mono)
		gateLog("ui-ring", keys[i%len(keys)], r.Intn(100000)-50000)
		lines := gateLogTestLines(t, p)
		last := lines[len(lines)-1]
		all = append(all, last)
		seen := map[string]int{}
		for _, tok := range strings.Fields(last) {
			k, v, ok := strings.Cut(tok, "=")
			if !ok || (k != "d" && k != "m" && k != "s") {
				continue
			}
			seen[k]++
			if !bucket[v] {
				t.Errorf("a %d s boot gap with %d s monotonic wrote %s=%q, not a bucket: %q", boot, mono, k, v, last)
			}
		}
		for _, k := range []string{"d", "m", "s"} {
			if seen[k] != 1 {
				t.Errorf("line %q carries %s= %d times, want exactly once", last, k, seen[k])
			}
		}
	}
	if exact := regexp.MustCompile(`\b[dms]=[0-9]+\b`); exact.MatchString(strings.Join(all, "\n")) {
		t.Errorf("gate.log carries an exact elapsed time (h53 #7 asks for a bucket):\n%s", strings.Join(all, "\n"))
	}
}
