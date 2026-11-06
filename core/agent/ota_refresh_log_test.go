package main

// NWP-20261117-38: the per-caller limit on the OTA-REFRESH branch's `[ota] OTA-REFRESH forced` line
// (ota_refresh_log.go). Backlog row "`[ota] OTA-REFRESH forced` lines crowd the issue report's login.log tail: every
// gate appearance and every OTA wake alarm forces a refresh that logs one".

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

type otaRefreshLogCall struct {
	at  time.Duration // since midnight
	tag string
}

// otaRefreshLogDay is the row's day: the gate every 2 min, the wake alarm every 2 h from 00:30, two power
// connections and three taps on Check for updates, in time order.
func otaRefreshLogDay() []otaRefreshLogCall {
	var calls []otaRefreshLogCall
	for m := 0; m < 24*60; m += 2 {
		calls = append(calls, otaRefreshLogCall{time.Duration(m) * time.Minute, "gate"})
	}
	for h := 0; h < 24; h += 2 {
		calls = append(calls, otaRefreshLogCall{time.Duration(h)*time.Hour + 30*time.Minute, "alarm"})
	}
	for _, at := range []time.Duration{8*time.Hour + 10*time.Minute, 19*time.Hour + 40*time.Minute} {
		calls = append(calls, otaRefreshLogCall{at, "power"})
	}
	for _, at := range []time.Duration{9 * time.Hour, 9*time.Hour + 5*time.Minute, 9*time.Hour + 10*time.Minute} {
		calls = append(calls, otaRefreshLogCall{at, "tap"})
	}
	sort.SliceStable(calls, func(i, j int) bool { return calls[i].at < calls[j].at })
	return calls
}

// otaRefreshLogRun drives a fresh limiter on a fake clock through calls and returns it and its printed lines.
func otaRefreshLogRun(calls []otaRefreshLogCall) (*otaRefreshLogger, []string) {
	t0 := time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC)
	cur := t0
	l := newOtaRefreshLogger(func() time.Time { return cur })
	var out []string
	for _, c := range calls {
		cur = t0.Add(c.at)
		if s, ok := l.line(c.tag); ok {
			out = append(out, strings.TrimSuffix(s, "\n"))
		}
	}
	return l, out
}

var otaRefreshLogLineRE = regexp.MustCompile(`^\[ota\] OTA-REFRESH forced \(caller=([a-z]+)\)(?: \(\+(\d+) folded since ([0-9hms]+)\))?$`)

func TestOtaRefreshLogADayIsBoundedPerCaller(t *testing.T) {
	calls := otaRefreshLogDay()
	l, lines := otaRefreshLogRun(calls)
	want := map[string]int{}
	for _, c := range calls {
		want[c.tag]++
	}
	printed, folded := map[string]int{}, map[string]int{}
	foldedGate := false
	for _, ln := range lines {
		m := otaRefreshLogLineRE.FindStringSubmatch(ln)
		if m == nil {
			t.Fatalf("a printed line is not in the limiter's format: %q", ln)
		}
		printed[m[1]]++
		if m[2] != "" {
			n, _ := strconv.Atoi(m[2])
			folded[m[1]] += n
			if m[1] == "gate" {
				foldedGate = true
			}
		}
	}
	for tag, n := range map[string]int{"gate": 24, "alarm": 12, "power": 2, "tap": 3} {
		if printed[tag] != n {
			t.Errorf("caller=%s printed %d lines over the day, want %d (gate: one per hour; alarm and power: every call, each "+
				"more than an hour apart and in its own window; tap: every call)", tag, printed[tag], n)
		}
	}
	for _, tag := range []string{"gate", "alarm", "power"} {
		if printed[tag] > 24 {
			t.Errorf("caller=%s printed %d lines in a day, more than one per hour", tag, printed[tag])
		}
		if got := printed[tag] + folded[tag] + l.folded[tag]; got != want[tag] {
			t.Errorf("caller=%s: %d printed + %d folded on the lines + %d still pending = %d, want the %d calls it had",
				tag, printed[tag], folded[tag], l.folded[tag], got, want[tag])
		}
	}
	if printed["tap"] != want["tap"] || folded["tap"] != 0 {
		t.Errorf("caller=tap printed %d of %d calls with %d folded: a person's Check for updates must always print",
			printed["tap"], want["tap"], folded["tap"])
	}
	if !foldedGate {
		t.Errorf("no caller=gate line carries a ` (+<n> folded since <ago>)` count: the folded calls are lost")
	}
	if len(lines) >= len(calls) {
		t.Errorf("the day printed %d lines for %d calls: nothing was limited", len(lines), len(calls))
	}
}

func TestOtaRefreshLogKeepsSignInLinesInTheReportTail(t *testing.T) {
	var session []string
	for i := 0; i < 10; i++ {
		session = append(session,
			fmt.Sprintf("[login] session %d sign-in OK", i),
			fmt.Sprintf("[logout] session %d sign-out OK", i))
	}
	calls := otaRefreshLogDay()
	_, day := otaRefreshLogRun(calls)
	keeps := func(dayLines []string) bool {
		log := strings.Join(append(append([]string{}, session...), dayLines...), "\n") + "\n"
		kept := strings.Join(scrubIssueLog([]byte(log), nil), "\n")
		for _, s := range session {
			if !strings.Contains(kept, s) {
				return false
			}
		}
		return true
	}
	if !keeps(day) {
		t.Errorf("a day of %d forced-refresh calls (%d printed lines) pushed the sign-in and sign-out lines out of the "+
			"report's last %d login.log lines", len(calls), len(day), maxIssueLogLines)
	}
	// Control: one line per call, as before NWP-20261117-38, loses them. Without this the test proves nothing.
	var every []string
	for _, c := range calls {
		every = append(every, "[ota] OTA-REFRESH forced (caller="+c.tag+")")
	}
	if keeps(every) {
		t.Fatalf("control: %d unlimited lines did not push the sign-in lines out of a %d-line tail; the test is too weak",
			len(every), maxIssueLogLines)
	}
}

func TestOtaRefreshLogUnknownTagPrintsAsOther(t *testing.T) {
	raws := []string{"weird-tag-123", "", "gate\x1b[2J"}
	var calls []otaRefreshLogCall
	for i, r := range raws {
		calls = append(calls, otaRefreshLogCall{time.Duration(i) * time.Minute, r})
	}
	calls = append(calls, otaRefreshLogCall{2 * time.Hour, "weird-tag-123"})
	_, lines := otaRefreshLogRun(calls)
	want := []string{
		"[ota] OTA-REFRESH forced (caller=other)",
		"[ota] OTA-REFRESH forced (caller=other) (+2 folded since 2h0m0s)",
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Errorf("unknown tags printed\n%q\nwant\n%q\n(one window for the class `other`, the raw value never echoed)",
			lines, want)
	}
	for _, ln := range lines {
		for _, r := range raws[:1] {
			if strings.Contains(ln, r) {
				t.Errorf("line %q echoes the raw tag %q", ln, r)
			}
		}
		if strings.Contains(ln, "\x1b") {
			t.Errorf("line %q echoes a control character from the raw tag", ln)
		}
	}
}

func TestOtaRefreshLogTapAlwaysPrints(t *testing.T) {
	var calls []otaRefreshLogCall
	for i := 0; i < 10; i++ {
		calls = append(calls, otaRefreshLogCall{time.Duration(i) * time.Second, "tap"})
	}
	calls = append(calls, otaRefreshLogCall{9 * time.Second, "gate"})
	_, lines := otaRefreshLogRun(calls)
	if len(lines) != 11 {
		t.Fatalf("ten taps and one gate call printed %d lines, want 11:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	for _, ln := range lines[:10] {
		if ln != "[ota] OTA-REFRESH forced (caller=tap)" {
			t.Errorf("tap printed %q, want the plain tap line", ln)
		}
	}
	if lines[10] != "[ota] OTA-REFRESH forced (caller=gate)" {
		t.Errorf("the gate's first call after ten taps printed %q: the taps used the gate's window", lines[10])
	}
}

func TestOtaRefreshLogBranchDoesNotPrintItself(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\tif name == \"OTA-REFRESH\" {")
	j := strings.Index(src, "\tif name == \"OTA-NOTES\" {")
	if i < 0 || j < i {
		t.Fatalf("main.go: cannot cut the OTA-REFRESH branch (start %d, OTA-NOTES %d)", i, j)
	}
	br := src[i:j]
	if !strings.Contains(br, "otaRefreshLog.note(os.Stderr, tag)") {
		t.Errorf("the OTA-REFRESH branch no longer logs through otaRefreshLog.note(os.Stderr, tag)")
	}
	if strings.Contains(br, "OTA-REFRESH forced") {
		t.Errorf("the OTA-REFRESH branch prints `OTA-REFRESH forced` itself, past the per-caller limit")
	}
	for _, s := range []string{"kickOtaRefresh()", `"CHECKING\n"`, `"DONE\n"`, `"NOSTORE\n"`} {
		if !strings.Contains(br, s) {
			t.Errorf("the OTA-REFRESH branch lost %s: only its log line was to change", s)
		}
	}
}

func TestOtaRefreshLogWindowIsWallClock(t *testing.T) {
	l := newOtaRefreshLogger(time.Now) // bare time.Now, as the package var
	if _, ok := l.line("gate"); !ok {
		t.Fatal("the first gate call did not print")
	}
	l.mu.Lock()
	last := l.last["gate"]
	l.mu.Unlock()
	if hasMonotonic(last) {
		t.Errorf("the window stamp carries a monotonic reading: that clock stops while the phone sleeps, so an idle " +
			"phone would fold the 2-hourly alarm lines for days (NWP-20260824-03); keep the Round(0)")
	}
}
