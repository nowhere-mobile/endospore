package main

import (
	"fmt"
	"strings"
	"testing"
)

// NWP-20261206-15: the odhold_log section (report_odhold_log.go). Fixtures are `logcat -v threadtime` lines built from
// parts; no test execs logcat.

const odholdCE = "/data/user/10/com.nowhere.chooser/.nowhere-odhold/com.example.app/cache/x"

// odholdTT builds one threadtime line: date, time, priority, tag (padded as logcat pads it), message.
func odholdTT(date, tm, level, tag, msg string) string {
	return fmt.Sprintf("%s %s.123  1234  1250 %s %-8s: %s", date, tm, level, tag, msg)
}

func odholdRaw(lines ...string) []byte {
	return []byte("--------- beginning of main\n" + strings.Join(lines, "\n") + "\n")
}

func TestOdholdLogGroupsRepeats(t *testing.T) {
	msg := "Failed to fixup " + odholdCE + ": Permission denied"
	raw := odholdRaw(
		odholdTT("12-06", "10:00:01", "W", "installd", msg),
		odholdTT("12-06", "10:00:02", "W", "installd", msg),
		odholdTT("12-06", "10:00:05", "W", "installd", msg),
	)
	got := odholdLogLines(raw, "10")
	want := `odhold_log: installd W [Failed to fixup] hold=ce errno=[Permission denied] n=3 first=12-06 10:00:01 last=12-06 10:00:05`
	if len(got) != 1 || got[0] != want {
		t.Errorf("got %q, want [%q]", got, want)
	}
}

func TestOdholdLogHoldClasses(t *testing.T) {
	for _, c := range []struct{ tag, msg, want string }{
		{"installd", "Failed to fixup /data/user_de/10/com.nowhere.chooser/.nowhere-odhold/com.example.app/f: Permission denied", "hold=de errno=[Permission denied]"},
		{"SELinux", "setxattr failed: /data/media/10/Android/data/com.nowhere.chooser/.nowhere-odhold/com.example.app/files/a: Operation not permitted", "hold=ext-data errno=[Operation not permitted]"},
		{"installd", "Failed to fixup /storage/emulated/10/Android/obb/com.nowhere.chooser/.nowhere-odhold/com.example.app/main.obb: Read-only file system", "hold=ext-obb errno=[Read-only file system]"},
		{"installd", "Failed to fixup " + odholdCE + ": Permission denied", "hold=ce errno=[Permission denied]"},
	} {
		got := odholdLogLines(odholdRaw(odholdTT("12-06", "10:00:01", "E", c.tag, c.msg)), "10")
		if len(got) != 1 || !strings.Contains(got[0], c.want) || !strings.HasPrefix(got[0], "odhold_log: "+c.tag+" E ") {
			t.Errorf("%s: got %q, want one line carrying %q", c.msg, got, c.want)
		}
	}
}

func TestOdholdLogUidFilter(t *testing.T) {
	raw := odholdRaw(
		odholdTT("12-06", "10:00:01", "W", "installd", "Failed to fixup /data/user/11/com.nowhere.chooser/.nowhere-odhold/com.example.app/cache/x: Permission denied"),
		odholdTT("12-06", "10:00:02", "E", "SELinux", "setxattr failed: /data/media/11/Android/data/com.nowhere.chooser/.nowhere-odhold/com.example.app/files/a: Operation not permitted"),
		odholdTT("12-06", "10:00:03", "W", "installd", "Failed to fixup /data/user_de/110/com.nowhere.chooser/.nowhere-odhold/com.example.app/f: Permission denied"),
	)
	if got := odholdLogLines(raw, "10"); len(got) != 0 {
		t.Errorf("another user's lines were kept for uid 10: %q", got)
	}
	ours := odholdRaw(odholdTT("12-06", "10:00:01", "W", "installd", "Failed to fixup "+odholdCE+": Permission denied"))
	if got := odholdLogLines(ours, ""); len(got) != 0 {
		t.Errorf("an empty uid kept lines: %q", got)
	}
}

func TestOdholdLogDropsLinesOutsideTheHold(t *testing.T) {
	raw := odholdRaw(
		odholdTT("12-06", "10:00:01", "W", "installd", "Failed to fixup /data/user/10/com.example.app/cache/x: Permission denied"),
		odholdTT("12-06", "10:00:02", "W", "installdx", "Failed to fixup "+odholdCE+": Permission denied"),
		odholdTT("12-06", "10:00:03", "W", "vold", "Failed to fixup "+odholdCE+": Permission denied"),
		"not a threadtime line "+odholdCE+": Permission denied",
	)
	if got := odholdLogLines(raw, "10"); len(got) != 0 {
		t.Errorf("a line outside the hold or from another tag was kept: %q", got)
	}
}

func TestOdholdLogHeadAllowlist(t *testing.T) {
	for _, msg := range []string{
		"Failed to fixup com.example.app at " + odholdCE + ": Permission denied",
		"Failed 2 times " + odholdCE + ": Permission denied",
		"Failed \"x\" " + odholdCE + ": Permission denied",
	} {
		got := odholdLogLines(odholdRaw(odholdTT("12-06", "10:00:01", "W", "installd", msg)), "10")
		if len(got) != 1 || !strings.Contains(got[0], " [other] hold=ce") {
			t.Errorf("%q: got %q, want the head class [other]", msg, got)
		}
		for _, ln := range got {
			if strings.Contains(ln, "example") || strings.Contains(ln, " 2 ") {
				t.Errorf("%q: the head leaked: %q", msg, ln)
			}
		}
	}
}

func TestOdholdLogErrnoClasses(t *testing.T) {
	for _, c := range []struct{ tail, want string }{
		{": Bad thing", "errno=[other]"},
		{": Error 13", "errno=[other]"},
		{": secret.db", "errno=[other]"},
		{"", "errno=[] "},
		{": Too many levels of symbolic links", "errno=[Too many levels of symbolic links]"},
	} {
		got := odholdLogLines(odholdRaw(odholdTT("12-06", "10:00:01", "W", "installd", "Failed to fixup "+odholdCE+c.tail)), "10")
		if len(got) != 1 || !strings.Contains(got[0], c.want) {
			t.Errorf("tail %q: got %q, want %q", c.tail, got, c.want)
		}
	}
}

func TestOdholdLogCap(t *testing.T) {
	var lines []string
	for i := 0; i < 50; i++ {
		head := "Failed " + string(rune('a'+i/26)) + string(rune('a'+i%26))
		lines = append(lines, odholdTT("12-06", "10:00:01", "W", "installd", head+" "+odholdCE+": Permission denied"))
	}
	got := odholdLogLines(odholdRaw(lines...), "10")
	if len(got) != 41 || got[40] != "odhold_log: 10 more group(s) cut" {
		t.Errorf("got %d lines (last %q), want 40 groups plus the cut line", len(got), got[len(got)-1])
	}
}

func TestOdholdLogNoIdentifiers(t *testing.T) {
	raw := odholdRaw(
		odholdTT("12-06", "10:00:01", "W", "installd", "Failed to fixup "+odholdCE+": Permission denied"),
		odholdTT("12-06", "10:00:02", "W", "installd", "Failed to fixup /data/user_de/10/com.nowhere.chooser/.nowhere-odhold/com.example.app/cache/x: No such file or directory"),
		odholdTT("12-06", "10:00:03", "E", "SELinux", "setxattr failed: /data/media/10/Android/data/com.nowhere.chooser/.nowhere-odhold/com.example.app/cache/x: Operation not permitted"),
		odholdTT("12-06", "10:00:04", "W", "installd", "Failed to fixup com.example.app "+odholdCE+": cache/x"),
	)
	sec := odholdLogSection(odholdLogLines(raw, "10"), []diagSource{{name: "/system/bin/logcat"}}, nil)
	if len(sec) != 4 {
		t.Fatalf("got %d lines, want 4: %q", len(sec), sec)
	}
	for _, ln := range sec {
		for _, bad := range []string{"com.example.app", "cache/x", "/data/", "/10/", "nowhere-odhold"} {
			if strings.Contains(ln, bad) {
				t.Errorf("%q carries %q", ln, bad)
			}
		}
	}
	// The scrub must leave the head and the errno readable: a double-quoted token would come back as "<name>".
	joined := strings.Join(sec, "\n")
	for _, want := range []string{"[Failed to fixup] hold=ce errno=[Permission denied]", "[setxattr failed:] hold=ext-data errno=[Operation not permitted]"} {
		if !strings.Contains(joined, want) {
			t.Errorf("the scrubbed section lost %q: %q", want, sec)
		}
	}
}

func TestOdholdLogSectionHeaders(t *testing.T) {
	bad := odholdLogSection(nil, []diagSource{{name: "/system/bin/logcat", err: "exit status 1"}}, nil)
	if len(bad) != 1 || !strings.HasPrefix(bad[0], "odhold_log: NO source could be read -- /system/bin/logcat (exit status 1)") ||
		!strings.Contains(bad[0], "this does NOT mean installd left the hold alone") {
		t.Errorf("unreadable source: got %q", bad)
	}
	clean := odholdLogSection(nil, []diagSource{{name: "/system/bin/logcat"}}, nil)
	if len(clean) != 1 || clean[0] != "odhold_log: sources readable, no installd or SELinux line names this session's on-demand hold in the captured window" {
		t.Errorf("readable, empty source: got %q", clean)
	}
}

// odholdStubDiag routes readDiagFn by argv: the odhold command gets raw, every other collector an error.
func odholdStubDiag(t *testing.T, raw []byte, calls *int) {
	t.Helper()
	prev := readDiagFn
	t.Cleanup(func() { readDiagFn = prev })
	readDiagFn = func(name string, argv ...string) ([]byte, diagSource) {
		if strings.Contains(strings.Join(argv, " "), "installd:*") {
			*calls++
			return raw, diagSource{name: name}
		}
		return nil, diagSource{name: name, err: "stubbed"}
	}
}

func TestOdholdLogMergeScope(t *testing.T) {
	calls := 0
	odholdStubDiag(t, odholdRaw(odholdTT("12-06", "10:00:01", "W", "installd", "Failed to fixup "+odholdCE+": Permission denied")), &calls)
	rep := issueReport{}
	mergeOdholdLog(&rep, "10", true)
	if _, ok := rep.Logs["odhold_log"]; ok || calls != 0 {
		t.Errorf("device scope: key present=%v, logcat read %d time(s); want neither", ok, calls)
	}
	rep = issueReport{}
	mergeOdholdLog(&rep, "10", false)
	if got := rep.Logs["odhold_log"]; len(got) != 1 || !strings.Contains(got[0], "hold=ce") || calls != 1 {
		t.Errorf("session scope: got %q after %d read(s)", got, calls)
	}
	rep = issueReport{}
	mergeOdholdLog(&rep, "", false)
	if got := rep.Logs["odhold_log"]; len(got) != 1 || got[0] != "odhold_log: this session's user id is unknown -- not collected" {
		t.Errorf("session scope, no uid: got %q", got)
	}
}

// TestOdholdLogReachesTheIssueReport drives a real handleReportIssue preview, as TestHealthReachesTheIssueReport.
func TestOdholdLogReachesTheIssueReport(t *testing.T) {
	dest := dsSetup(t, "odhlogt1", "10", 10*100000+10123)
	calls := 0
	odholdStubDiag(t, odholdRaw(odholdTT("12-06", "10:00:01", "W", "installd", "Failed to fixup "+odholdCE+": Permission denied")), &calls)
	prevWorker := uiderrorsWorker
	t.Cleanup(func() { uiderrorsWorker = prevWorker })
	uiderrorsWorker = func(string, string, string) string { return "" }
	for _, req := range []string{`{"preview":true}`, `{"preview":true,"gate":true}`} {
		c := &dsConn{r: strings.NewReader("")}
		handleReportIssue(c, dest, req)
		out := c.out.String()
		gate := strings.Contains(req, `"gate":true`)
		if has := strings.Contains(out, `"odhold_log"`) && strings.Contains(out, "[Failed to fixup] hold=ce"); has == gate {
			t.Errorf("%s: odhold_log present=%v, want %v: %s", req, has, !gate, out)
		}
	}
}
