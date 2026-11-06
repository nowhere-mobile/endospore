package main

import (
	"errors"
	"go/scanner"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20260904-10: a report filed FROM THE GATE carries why the phone last rebooted. The daemon's reason
// used to reach only login.log, which a gate report excludes on purpose (the blind-login oracle, least
// knowledge, size -- see buildIssueReport), so ticket NW-b477ab1bce0a ("why phone got rebooted during
// profile deletion") could not be answered from its own contents. The reason now lives in its own
// device-level record (lastRebootPath) and rides in status at every scope.

// rebootFixture points the record and the kernel boot_id at temp files and returns the record path.
func rebootFixture(t *testing.T, bootID string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	rec := filepath.Join(dir, "last-reboot")
	bid := filepath.Join(dir, "boot_id")
	if err := os.WriteFile(bid, []byte(bootID+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldRec, oldBid := lastRebootPath, procBootIDPath
	lastRebootPath, procBootIDPath = rec, bid
	t.Cleanup(func() { lastRebootPath, procBootIDPath = oldRec, oldBid })
	return rec
}

func writeRebootRecord(t *testing.T, path string, at int64, bootID, reason string) {
	t.Helper()
	line := strconv.FormatInt(at, 10) + "\t" + bootID + "\t" + reason + "\n"
	if err := os.WriteFile(path, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
}

// uptimeFixture makes this boot `seconds` old by injecting bootUptime (sysinfo(2) in production).
func uptimeFixture(t *testing.T, seconds int64) {
	t.Helper()
	old := bootUptime
	bootUptime = func() (int64, error) { return seconds, nil }
	t.Cleanup(func() { bootUptime = old })
}

// uptimeUnreadable makes bootUptime fail, the way the daemon's /proc/uptime read failed on every enforcing
// build before NWP-20261013-02.
func uptimeUnreadable(t *testing.T) {
	t.Helper()
	old := bootUptime
	bootUptime = func() (int64, error) { return 0, errors.New("permission denied") }
	t.Cleanup(func() { bootUptime = old })
}

var rebootRecordLine = regexp.MustCompile(`^(\d+)\t([^\t\n]+)\t([^\t\n]*)\n$`)

func TestRecordRebootReasonWritesTheExactShape(t *testing.T) {
	rec := rebootFixture(t, "0f1e2d3c-boot-a")
	before := time.Now().Unix()
	recordRebootReason("delete reap NOT consumed in 8s (no watcher?) uid=12")
	after := time.Now().Unix()

	b, err := os.ReadFile(rec)
	if err != nil {
		t.Fatalf("recordRebootReason wrote nothing: %v", err)
	}
	m := rebootRecordLine.FindStringSubmatch(string(b))
	if m == nil {
		t.Fatalf("record is not '<unix>\\t<boot_id>\\t<reason>\\n': %q", b)
	}
	at, _ := strconv.ParseInt(m[1], 10, 64)
	if at < before || at > after {
		t.Errorf("timestamp %d outside [%d, %d]", at, before, after)
	}
	if m[2] != "0f1e2d3c-boot-a" {
		t.Errorf("boot_id = %q, want the kernel's", m[2])
	}
	if m[3] != "delete reap NOT consumed in 8s (no watcher?) uid=12" {
		t.Errorf("reason = %q", m[3])
	}
	if _, err := os.Stat(rec + ".tmp"); err == nil {
		t.Error("temp file left behind after the rename")
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(rec)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Errorf("mode = %o, want 0600", st.Mode().Perm())
		}
	}
}

func TestRecordRebootReasonUnknownBootID(t *testing.T) {
	rec := rebootFixture(t, "x")
	procBootIDPath = filepath.Join(t.TempDir(), "absent")
	recordRebootReason("delete with no session uid")
	b, err := os.ReadFile(rec)
	if err != nil {
		t.Fatal(err)
	}
	if m := rebootRecordLine.FindStringSubmatch(string(b)); m == nil || m[2] != "unknown" {
		t.Fatalf("unreadable boot_id must be recorded as 'unknown', got %q", b)
	}
}

func TestRecordRebootReasonFlattensTheShape(t *testing.T) {
	rec := rebootFixture(t, "b")
	recordRebootReason("two\tfields\nand a line")
	b, err := os.ReadFile(rec)
	if err != nil {
		t.Fatal(err)
	}
	if m := rebootRecordLine.FindStringSubmatch(string(b)); m == nil || m[3] != "two fields and a line" {
		t.Fatalf("a tab or newline in the reason must not break the one-line record, got %q", b)
	}
}

// The keys ride in status at BOTH scopes -- the gate is the one this slice exists for.
func TestReportCarriesLastRebootReasonAtEveryScope(t *testing.T) {
	rec := rebootFixture(t, "boot-after")
	uptimeFixture(t, 60) // this boot started 60s ago; the request was 90s ago -> it landed in 30s
	writeRebootRecord(t, rec, time.Now().Unix()-90, "boot-before", "delete reap NOT consumed in 8s (no watcher?) uid=12")
	for _, tc := range []struct {
		name  string
		scope bool
	}{
		{"", true},       // the gate reporter
		{"alice", false}, // a live session
	} {
		rep := buildIssueReport(tc.name, tc.scope, "", nil, nil)
		if got := rep.Status["last_reboot_reason"]; got != "delete reap NOT consumed in 8s (no watcher?) uid=12" {
			t.Errorf("deviceScope=%v: last_reboot_reason = %q -- the gate report still cannot say why the phone rebooted", tc.scope, got)
		}
		if got := rep.Status["last_reboot_boot_id"]; got != "boot-before" {
			t.Errorf("deviceScope=%v: last_reboot_boot_id = %q", tc.scope, got)
		}
		age, err := strconv.ParseInt(rep.Status["last_reboot_age_s"], 10, 64)
		if err != nil || age < 90 || age > 100 {
			t.Errorf("deviceScope=%v: last_reboot_age_s = %q, want ~90", tc.scope, rep.Status["last_reboot_age_s"])
		}
		if got := rep.Status["last_reboot_pending"]; got != "false" {
			t.Errorf("deviceScope=%v: last_reboot_pending = %q on a later boot, want false", tc.scope, got)
		}
		gap, err := strconv.ParseInt(rep.Status["last_reboot_to_boot_s"], 10, 64)
		if err != nil || gap < 30 || gap > 40 {
			t.Errorf("deviceScope=%v: last_reboot_to_boot_s = %q, want ~30 (request to boot start)", tc.scope, rep.Status["last_reboot_to_boot_s"])
		}
		if got := rep.Status["last_reboot_stale"]; got != "false" {
			t.Errorf("deviceScope=%v: last_reboot_stale = %q; the recorded reboot is the one that started this boot", tc.scope, got)
		}
	}
}

// The record only knows the reboots the daemon (and otad) ISSUED. A power cycle, the chooser's watchdog
// dpm.reboot or a kernel panic leaves the older record in place with pending=false, and a reader who does
// not compare the age against uptime attributes the new reboot to the old cause. The report says it instead.
func TestReportFlagsAStaleRecordWhenAnUnrecordedRebootIntervened(t *testing.T) {
	rec := rebootFixture(t, "boot-z")
	uptimeFixture(t, 120) // this boot is 2 min old ...
	writeRebootRecord(t, rec, time.Now().Unix()-3*86400, "boot-x", "delete reap NOT consumed in 8s (no watcher?) uid=12")
	rep := buildIssueReport("", true, "", nil, nil) // ... and the recorded request is 3 days old
	if got := rep.Status["last_reboot_stale"]; got != "true" {
		t.Fatalf("last_reboot_stale = %q; a 3-day-old request did not start a 2-minute-old boot -- an unrecorded reboot came between", got)
	}
	gap, err := strconv.ParseInt(rep.Status["last_reboot_to_boot_s"], 10, 64)
	if err != nil || gap < 3*86400-120-5 || gap > 3*86400-120+5 {
		t.Errorf("last_reboot_to_boot_s = %q, want ~%d", rep.Status["last_reboot_to_boot_s"], 3*86400-120)
	}
	if got := rep.Status["last_reboot_pending"]; got != "false" {
		t.Errorf("last_reboot_pending = %q; stale is not pending -- the reboot happened, it just was not the last one", got)
	}
	// With uptime unreadable the gap cannot be measured: the two keys are omitted rather than guessed, and
	// uptime_s itself says why.
	uptimeUnreadable(t)
	rep = buildIssueReport("", true, "", nil, nil)
	for _, k := range []string{"last_reboot_to_boot_s", "last_reboot_stale"} {
		if v, ok := rep.Status[k]; ok {
			t.Errorf("%s = %q with uptime unreadable -- a guess, not a measurement", k, v)
		}
	}
	if got := rep.Status["last_reboot_reason"]; got != "delete reap NOT consumed in 8s (no watcher?) uid=12" {
		t.Errorf("last_reboot_reason = %q; the record itself still reads without uptime", got)
	}
}

// Recorded in THIS boot means the reboot never happened -- itself a diagnosis.
func TestReportFlagsARebootThatNeverHappened(t *testing.T) {
	rec := rebootFixture(t, "same-boot")
	writeRebootRecord(t, rec, time.Now().Unix()-5, "same-boot", "delete with no session uid")
	rep := buildIssueReport("", true, "", nil, nil)
	if got := rep.Status["last_reboot_pending"]; got != "true" {
		t.Fatalf("last_reboot_pending = %q; the reason was recorded in this very boot, so the reboot did not happen", got)
	}
}

func TestReportPendingUnknownWhenBootIDUnknown(t *testing.T) {
	rec := rebootFixture(t, "x")
	procBootIDPath = filepath.Join(t.TempDir(), "absent")
	writeRebootRecord(t, rec, time.Now().Unix(), "unknown", "delete with no session uid")
	rep := buildIssueReport("", true, "", nil, nil)
	if got := rep.Status["last_reboot_pending"]; got != "unknown" {
		t.Fatalf("last_reboot_pending = %q; two unreadable boot_ids are not evidence of equality", got)
	}
}

func TestReportOmitsRebootKeysWhenNothingRecorded(t *testing.T) {
	rebootFixture(t, "boot")
	rep := buildIssueReport("", true, "", nil, nil)
	for _, k := range []string{"last_reboot_reason", "last_reboot_age_s", "last_reboot_boot_id", "last_reboot_pending"} {
		if v, ok := rep.Status[k]; ok {
			t.Errorf("%s = %q with no record on disk -- silence must not read as a reason", k, v)
		}
	}
}

// Each malformed shape has its own branch in lastRebootMarker and each must self-declare, never be read as
// a valid record: a non-integer timestamp parsed as 0 would render an age of ~1.7e9 s with a straight face.
func TestReportSelfDeclaresAMalformedRecord(t *testing.T) {
	for _, tc := range []struct{ name, content string }{
		{"too few fields", "garbage\n"},
		{"bad timestamp", "notanumber\tboot-before\tdelete with no session uid\n"},
	} {
		rec := rebootFixture(t, "boot")
		if err := os.WriteFile(rec, []byte(tc.content), 0o600); err != nil {
			t.Fatal(err)
		}
		rep := buildIssueReport("", true, "", nil, nil)
		if got := rep.Status["last_reboot_reason"]; !strings.HasPrefix(got, "unparseable: ") {
			t.Errorf("%s: last_reboot_reason = %q, want a self-declared parse failure", tc.name, got)
		}
		for _, k := range []string{"last_reboot_age_s", "last_reboot_boot_id", "last_reboot_pending", "last_reboot_stale"} {
			if v, ok := rep.Status[k]; ok {
				t.Errorf("%s: %s = %q derived from a record that does not parse", tc.name, k, v)
			}
		}
	}
}

// Present-but-unreadable is the third failure shape (a relabel, a file owned by another uid after a domain
// split), and it must not collapse into the absent case: silence there reads as "nothing was recorded".
func TestReportSelfDeclaresAnUnreadableRecord(t *testing.T) {
	rebootFixture(t, "boot")
	lastRebootPath = t.TempDir() // a directory: ReadFile fails, and not with IsNotExist
	rep := buildIssueReport("", true, "", nil, nil)
	if got := rep.Status["last_reboot_reason"]; !strings.HasPrefix(got, "unreadable: ") {
		t.Fatalf("last_reboot_reason = %q with the record present but unreadable, want 'unreadable: <err>'", got)
	}
}

// The reason is free-form text and goes through the same scrub as every other status value. The contract
// on rebootNow keeps names out of it; this is the backstop for the contract being broken.
func TestLastRebootReasonIsScrubbedLikeStatus(t *testing.T) {
	rec := rebootFixture(t, "boot-after")
	writeRebootRecord(t, rec, time.Now().Unix(), "boot-before", "reaping alice uid=12")
	rep := buildIssueReport("alice", false, "", nil, nil)
	if got := rep.Status["last_reboot_reason"]; got != "reaping <name> uid=12" {
		t.Fatalf("last_reboot_reason = %q -- the reason bypasses statusValue", got)
	}
}

// uptime_s self-declares an unreadable source, like avc and prev_boot. It was silently absent from all three
// of one owner's reports before this.
func TestUptimeUnreadableSelfDeclares(t *testing.T) {
	uptimeUnreadable(t)
	got, ok := bootMarker()["uptime_s"]
	if !ok || got != "unreadable: permission denied" {
		t.Fatalf("uptime_s = %q (present=%v) with uptime unreadable, want 'unreadable: <err>'", got, ok)
	}
	uptimeFixture(t, 12345)
	if got := bootMarker()["uptime_s"]; got != "12345" {
		t.Fatalf("uptime_s = %q, want bootUptime's seconds as an integer", got)
	}
}

// NWP-20261013-02: the PRODUCTION clock answers on this (Linux) host, with a value that is this boot's age.
// The agent's /proc/uptime reader was denied on every enforcing build; sysinfo(2) has nothing to deny, so the
// real bootUptime -- not an injected one -- must yield a positive number, and uptime_s must carry it. A clock
// that returned 0 (or an error) here would put "unreadable" or "0" back in every report. The cross-check
// against /proc/uptime is the TEST HOST's file, read here because the test is not confined; it bounds the
// value to "this boot's age" so a constant cannot pass.
func TestBootUptimeIsTheRealBootClock(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("sysinfo(2) is Linux")
	}
	up, err := bootUptime()
	if err != nil || up <= 0 {
		t.Fatalf("bootUptime() = %d, %v; sysinfo(2) must answer with this boot's age", up, err)
	}
	if got := bootMarker()["uptime_s"]; got != strconv.FormatInt(up, 10) && got != strconv.FormatInt(up+1, 10) {
		t.Errorf("uptime_s = %q, want the real bootUptime (%d) as an integer", got, up)
	}
	b, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return // the host's own file is only a cross-check
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return
	}
	host, err := strconv.ParseFloat(f[0], 64)
	if err != nil {
		return
	}
	if d := float64(up) - host; d < -2 || d > 2 {
		t.Errorf("bootUptime() = %d but the host's boot is %.2fs old -- not the boot clock", up, host)
	}
}

// NWP-20261013-02 SOURCE PIN: no agent source NAMES /proc/uptime in code. The daemon's domain is denied
// proc_uptime on an enforcing build, so a read there fails on device while succeeding on the test host and in
// a `su 0` shell -- every check off the device passes. NWP-20260825-12 moved ONE reader to sysinfo(2) and
// left the rest, which then cost three diagnostics.
//
// It pins the SPELLING, not every possible read: it tokenizes each non-test source with go/scanner (so a
// comment may explain why not, and a `//` inside a string literal cannot hide the rest of the line), and
// flags (see procUptimeLiterals) a literal containing "/proc/uptime", literals joined by + that spell it
// ("/proc/upt" + "ime"), or a "/proc" path literal within a few tokens of one containing "uptime"
// (filepath.Join("/proc", "uptime"), fmt.Sprintf("/proc/%s", "uptime")). A path assembled further apart than
// that gets past it; review is the rest of the guard. A test file may name the path, to cross-check against
// the host's own clock.
func TestNoAgentSourceNamesProcUptime(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("no sources found (%v)", err)
	}
	control := false
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, hit := range procUptimeLiterals(t, f, src, &control) {
			t.Errorf("%s -- use bootUptime (sysinfo(2)), never /proc/uptime", hit)
		}
	}
	if !control {
		t.Fatal("no syscall.Sysinfo call found in any agent source -- the scan is not looking at the agent")
	}
}

// procUptimeLiterals returns "file:line: literal" for every string literal in src that names /proc/uptime:
// whole; split across literals joined by + ("/proc/upt" + "ime"); or a "/proc" path literal ("/proc",
// "/proc/", "/proc/%s", ...) within a few tokens of a literal containing "uptime", in either order
// (filepath.Join("/proc", "uptime"), fmt.Sprintf("/proc/%s", "uptime")). control is set when the token run
// syscall . Sysinfo is seen.
func procUptimeLiterals(t *testing.T, name string, src []byte, control *bool) []string {
	t.Helper()
	fset := token.NewFileSet()
	file := fset.AddFile(name, fset.Base(), len(src))
	var s scanner.Scanner
	// Mode 0: comments are skipped, which is what lets a comment explain why not.
	s.Init(file, src, func(pos token.Position, msg string) { t.Errorf("%s: scan: %s", pos, msg) }, 0)

	// near is in tokens and covers filepath.Join("/proc", "uptime") and fmt.Sprintf("/proc/%s", "uptime").
	const near = 6
	var hits []string
	lastProc, lastUptime := -100, -100
	judge := func(v string, at string, i int) {
		switch {
		case strings.Contains(v, "/proc/uptime"):
			hits = append(hits, at)
		case v == "/proc" || strings.HasPrefix(v, "/proc/"):
			if i-lastUptime <= near {
				hits = append(hits, at)
			}
			lastProc = i
		case strings.Contains(v, "uptime"):
			if i-lastProc <= near {
				hits = append(hits, at)
			}
			lastUptime = i
		}
	}

	// A run of literals joined by + is judged as ONE value, so a word split across them is still seen.
	var prev [2]string // the two previous tokens, for syscall . Sysinfo
	var group, groupAt string
	groupIdx, open, plus := 0, false, false
	flush := func() {
		if open {
			judge(group, groupAt, groupIdx)
		}
		open, plus = false, false
	}
	for i := 0; ; i++ {
		pos, tok, lit := s.Scan()
		if tok == token.EOF {
			flush()
			break
		}
		if tok == token.IDENT && lit == "Sysinfo" && prev[0] == "." && prev[1] == "syscall" {
			*control = true
		}
		text := lit
		if tok == token.PERIOD {
			text = "."
		}
		prev[1], prev[0] = prev[0], text
		switch tok {
		case token.STRING:
			v, err := strconv.Unquote(lit)
			if err != nil {
				flush()
				continue
			}
			if open && plus {
				group += v
				plus = false
				continue
			}
			flush()
			group, groupAt, groupIdx, open = v, fset.Position(pos).String()+": "+lit, i, true
		case token.ADD:
			if open {
				plus = true
			}
		default:
			flush()
		}
	}
	return hits
}

// The pin's own matcher, run against the shapes it must convict and the ones it must leave alone -- so a
// regression in the tokenizer walk shows here rather than as a pin that silently passes everything.
func TestProcUptimeMatcherShapes(t *testing.T) {
	convict := map[string]string{
		"literal":       "package p\nvar a = \"/proc/uptime\"\n",
		"after-slashes": "package p\nvar a, b = \"x // y\", \"/proc/uptime\"\n",
		"in-raw-string": "package p\nvar a = `/proc/uptime`\n",
		"join":          "package p\nvar a = filepath.Join(\"/proc\", \"uptime\")\n",
		"concat":        "package p\nvar a = \"/proc/\" + \"uptime\"\n",
		"join-reversed": "package p\nvar a = []string{\"uptime\", \"/proc\"}\n",
		"sprintf":       "package p\nvar a = fmt.Sprintf(\"/proc/%s\", \"uptime\")\n",
		"split-word":    "package p\nvar a = \"/proc/upt\" + \"ime\"\n",
		"split-3-ways":  "package p\nvar a = \"/pr\" + \"oc/up\" + `time`\n",
		"concat-ident":  "package p\nvar a = \"/proc/\" + name + \"uptime\"\n",
	}
	for name, src := range convict {
		var c bool
		if got := procUptimeLiterals(t, name+".go", []byte(src), &c); len(got) == 0 {
			t.Errorf("%s: %q not convicted", name, src)
		}
	}
	acquit := map[string]string{
		"comment":       "package p\n// reads /proc/uptime -- no longer\nvar a = 1\n",
		"block-comment": "package p\n/* \"/proc\", \"uptime\" */\nvar a = 1\n",
		"far-apart":     "package p\nvar a = \"/proc\"\nvar b, c, d, e, f, g = 1, 2, 3, 4, 5, \"uptime\"\n",
		"uptime_s":      "package p\nvar a = m[\"uptime_s\"]\n",
		"other-proc":    "package p\nvar a = \"/proc/self/status\"\n",
		"proc-far":      "package p\nvar a = \"/proc/self/stat\"\nvar b, c, d, e, f = 1, 2, 3, 4, \"uptime_s\"\n",
	}
	for name, src := range acquit {
		var c bool
		if got := procUptimeLiterals(t, name+".go", []byte(src), &c); len(got) != 0 {
			t.Errorf("%s: %q convicted (%v), but it reads nothing", name, src, got)
		}
	}
	var c bool
	procUptimeLiterals(t, "ctl.go", []byte("package p\nfunc f() { syscall.Sysinfo(nil) }\n"), &c)
	if !c {
		t.Error("the syscall . Sysinfo control does not fire on a real call")
	}
}

// bootStartedAt's UNIT: bootUptime is seconds, and a boot 3600 s old began an hour ago. A Millisecond or a
// missing scale would put the boot 3.6 s ago, and the spill sweep would then delete every spill older than
// that -- including ones a seal started this boot is still streaming from.
func TestBootStartedAtIsNowMinusUptimeSeconds(t *testing.T) {
	uptimeFixture(t, 3600)
	boot, ok := bootStartedAt()
	if !ok {
		t.Fatal("bootStartedAt() not ok with a readable clock")
	}
	want := time.Now().Add(-time.Hour)
	if d := boot.Sub(want); d < -3*time.Second || d > 3*time.Second {
		t.Fatalf("bootStartedAt() = %v, want ~%v (now - 3600 s); off by %v", boot, want, d)
	}
	uptimeUnreadable(t)
	if _, ok := bootStartedAt(); ok {
		t.Fatal("bootStartedAt() ok with the clock unreadable -- its caller deletes on this answer")
	}
}

// SOURCE PIN on the device-scope contract. The record is read at every scope, including the on-screen gate
// preview, so a profile name in a reason would be an existence oracle with no network. Every rebootNow call
// must pass a string literal, optionally '+ uid' (a per-boot integer that identifies nobody). And every reboot
// the daemon issues must go THROUGH rebootNow: a bypass leaves a stale reason on disk, and the next report
// would explain the wrong reboot (three bare setprop calls did exactly that before this slice).
//
// Two shapes the first cut of this pin let through, both found by review mutation: a call behind `go ` or
// `defer ` (the pin only looked at lines STARTING with the call), and a bypass whose text was byte-identical
// to a line inside rebootNow's own body (the body was excluded by line TEXT, not position). So: the call is
// matched wherever it sits in the code portion of a line, and rebootNow's body is excluded by line INDEX.
var (
	rebootCallAt   = regexp.MustCompile(`\brebootNow\(`)
	rebootCallForm = regexp.MustCompile(`^rebootNow\("(?:[^"\\]|\\.)*"(?: \+ uid)?\)`)
)

func TestRebootReasonsAreProfileFree(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		lines := strings.Split(src, "\n")
		bodyStart, bodyEnd := -1, -1 // rebootNow's own lines, by INDEX
		if strings.Contains(src, "\nfunc rebootNow(") {
			body := funcBody(t, src, "rebootNow")
			for i, l := range lines {
				if strings.HasPrefix(l, "func rebootNow(") {
					bodyStart, bodyEnd = i, i+len(body)-1
					break
				}
			}
			if !strings.Contains(strings.Join(stripComments(body), "\n"), "recordRebootReason(") {
				t.Errorf("%s: rebootNow no longer records its reason -- a gate report cannot say why the phone rebooted again", f)
			}
		}
		for i, l := range lines {
			s := strings.TrimSpace(l)
			if strings.HasPrefix(s, "//") {
				continue
			}
			code := l
			if j := strings.Index(code, " // "); j >= 0 {
				code = code[:j]
			}
			for _, loc := range rebootCallAt.FindAllStringIndex(code, -1) {
				if loc[0] >= 5 && code[loc[0]-5:loc[0]] == "func " {
					continue // the declaration
				}
				calls++
				if call := code[loc[0]:]; !rebootCallForm.MatchString(call) {
					t.Errorf("%s:%d: %q -- a reboot reason must be a literal, optionally + uid (device scope by contract)", f, i+1, strings.TrimSpace(code))
				}
			}
			inBody := i >= bodyStart && i <= bodyEnd
			if (strings.Contains(code, "sys.powerctl") || strings.Contains(code, "/system/bin/reboot")) && !inBody {
				t.Errorf("%s:%d: %q -- a reboot outside rebootNow leaves a stale reason on disk", f, i+1, strings.TrimSpace(code))
			}
		}
	}
	if calls < 5 {
		t.Fatalf("found %d rebootNow calls, expected at least 5 (delete x2, logoff x3) -- the pin is stale, not the code", calls)
	}
}
