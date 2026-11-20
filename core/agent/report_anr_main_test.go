package main

// NWP-20261208-18: A SESSION REPORT CARRIES A NOWHERE PROCESS'S ANR MAIN STACK AND ITS BINDER TARGETS.
//
// Backlog row "An issue report cuts the ANR section at 60 lines, so a chooser ANR arrives without its main thread's
// stack or the name of the process it was waiting on". For a com.nowhere.* trace anrHeaders now also carries the
// "main" block (at most maxIssueAnrMainLines, two traces) and the Cmd line of each process an outgoing transaction of
// that process waits on, read from the same trace. Other apps keep the header cut, and the header cut of every trace
// is counted on its own, so the new lines never take another trace's header lines.

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// anrMainTrace is the row's ANR in the ART layout: process pid with cmd, two outgoing transactions (to 1457, and to
// 1460:12 which has no block), a main block of `frames` lines past the "main" line, a "Signal Catcher" thread whose
// frames must never be carried, then system_server's block (pid 1457) and a transaction of another process (999).
// frame names the frames (MainFrame<i>); no name holds a word the scrub drops or redacts.
func anrMainTrace(pid, cmd, frame string, frames int) string {
	var b strings.Builder
	b.WriteString("----- pid " + pid + " at 2026-11-17 01:11:40.123-0500 -----\n")
	b.WriteString("Cmd line: " + cmd + "\n")
	b.WriteString("ABI: 'arm64'\n")
	b.WriteString("outgoing transaction 1: 0000000000000000 from " + pid + ":" + pid + " to 1457 code 10 flags 10 pri 0:120 r1 elapsed 5349ms\n")
	b.WriteString("outgoing transaction 2: 0000000000000000 from " + pid + ":4601 to 1460:12 code 3 flags 10 pri 0:120 r1 elapsed 812ms\n")
	b.WriteString("\nDALVIK THREADS (3):\n")
	b.WriteString("\"main\" prio=5 tid=1 Native\n")
	for i := 1; i <= frames; i++ {
		n := strconv.Itoa(i)
		b.WriteString("  at com.nowhere.chooser." + frame + n + ".call(" + frame + n + ".java:" + n + ")\n")
	}
	b.WriteString("\n\"Signal Catcher\" daemon prio=10 tid=2 Runnable\n")
	b.WriteString("  at com.nowhere.test.CatcherOnly.run(CatcherOnly.java:3)\n")
	b.WriteString("\n----- end " + pid + " -----\n\n")
	b.WriteString("----- pid 1457 at 2026-11-17 01:11:40.200-0500 -----\n")
	b.WriteString("Cmd line: system_server\n\n")
	b.WriteString("DALVIK THREADS (1):\n\"main\" prio=5 tid=1 Native\n")
	b.WriteString("  at com.android.server.SystemServerOnly.loop(SystemServerOnly.java:5)\n\n")
	b.WriteString("----- end 1457 -----\n")
	b.WriteString("outgoing transaction 9: 0000000000000000 from 999:999 to 1458 code 1 flags 10 pri 0:120 r1 elapsed 10ms\n")
	return b.String()
}

// anrMainDir writes the named traces into a temp dir, oldest first (each one a minute newer than the one before), and
// points anrDir at it for the test.
func anrMainDir(t *testing.T, files ...[2]string) string {
	t.Helper()
	dir := t.TempDir()
	old := anrDir
	anrDir = dir
	t.Cleanup(func() { anrDir = old })
	base := time.Now().Add(-time.Hour)
	for i, f := range files {
		p := filepath.Join(dir, f[0])
		if err := os.WriteFile(p, []byte(f[1]), 0o644); err != nil {
			t.Fatal(err)
		}
		mt := base.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func anrMainCount(lines []string, sub string) int {
	n := 0
	for _, ln := range lines {
		if strings.Contains(ln, sub) {
			n++
		}
	}
	return n
}

func TestAnrMain_NowhereTraceCarriesMainAndTargets(t *testing.T) {
	dir := anrMainDir(t, [2]string{"anr_mine", anrMainTrace("4539", "com.nowhere.chooser", "MainFrame", 70)})
	lines, _ := anrHeaders(dir, map[string]bool{}, maxIssueAnrLines)
	got := joined(t, lines)
	for i := 1; i <= 70; i++ {
		if f := "MainFrame" + strconv.Itoa(i) + ".call("; !strings.Contains(got, f) {
			t.Errorf("main frame %d of 70 is missing (the old 60-line cut):\n%s", i, got)
			break
		}
	}
	for _, want := range []string{
		"anr main (nowhere process, 71 lines):",
		"anr target pid 1457: system_server",
		"anr target pid 1460: not in trace",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "1458") {
		t.Errorf("a transaction of another process (999 -> 1458) must not give a target:\n%s", got)
	}
	if strings.Contains(got, "CatcherOnly") {
		t.Errorf("the main block ends at its blank line; a Signal Catcher frame was carried:\n%s", got)
	}
	if strings.Contains(got, "SystemServerOnly") {
		t.Errorf("only the Nowhere process's main stack is carried, not system_server's:\n%s", got)
	}
}

func TestAnrMain_OtherAppsKeepTheHeaderCut(t *testing.T) {
	other := anrMainTrace("5000", "com.example.other", "OtherFrame", 70)
	dir := anrMainDir(t,
		[2]string{"anr_mine", anrMainTrace("4539", "com.nowhere.chooser", "MainFrame", 70)},
		[2]string{"anr_other", other})
	lines, _ := anrHeaders(dir, map[string]bool{}, maxIssueAnrLines)
	got := joined(t, lines)
	if strings.Contains(got, "OtherFrame") {
		t.Errorf("another app's trace must keep the header cut; its main frames were carried:\n%s", got)
	}
	if n := anrMainCount(lines, "anr main ("); n != 1 {
		t.Errorf("want exactly one main stack (the Nowhere trace's), got %d:\n%s", n, got)
	}
	if n := anrMainCount(lines, "anr target pid "); n != 2 {
		t.Errorf("want exactly the Nowhere trace's two target lines, got %d:\n%s", n, got)
	}
	sep, head := strings.Index(got, "--- anr_mine ---"), strings.Index(got, "anr main (")
	if sep < 0 || head < sep {
		t.Errorf("the main stack must follow the Nowhere trace's own separator:\n%s", got)
	}
}

func TestAnrMain_StackCutAt120(t *testing.T) {
	// The cap counts lines of the main block, the "main" line included: a 200-line block ("main" + 199 frames)
	// carries the "main" line and frames 1-119.
	dir := anrMainDir(t, [2]string{"anr_mine", anrMainTrace("4539", "com.nowhere.chooser", "MainFrame", 199)})
	lines, _ := anrHeaders(dir, map[string]bool{}, maxIssueAnrLines)
	got := joined(t, lines)
	if !strings.Contains(got, "anr main (nowhere process, 120 lines, cut at 120):") {
		t.Errorf("want the cut noted in the heading:\n%s", got)
	}
	if !strings.Contains(got, "MainFrame119.call(") || strings.Contains(got, "MainFrame120.call(") {
		t.Errorf("want frames up to 119 and none past it:\n%s", got)
	}
	if n := anrMainCount(lines, ".call(MainFrame"); n != 119 {
		t.Errorf("want 119 frames past the \"main\" line, got %d", n)
	}
}

func TestAnrMain_HeadersOfOtherTracesUnchanged(t *testing.T) {
	older := "----- pid 6000 at 2026-11-17 00:50:00.000-0500 -----\nCmd line: com.example.older\n" +
		"Subject: Input dispatching timed out\nABI: 'arm64'\nBuild type: optimized\n" +
		"Zygote loaded classes=1000 post zygote classes=200\nDumping registered class loaders\n" +
		"Intern table: 4000 strong; 100 weak\nJNI: CheckJNI is off\nHeap: 25% free\n\n" +
		"DALVIK THREADS (1):\n\"main\" prio=5 tid=1 Native\n  at com.example.OlderFrame.run(OlderFrame.java:1)\n"
	dir := anrMainDir(t,
		[2]string{"anr_app", older},
		[2]string{"anr_mine", anrMainTrace("4539", "com.nowhere.chooser", "MainFrame", 70)})
	lines, _ := anrHeaders(dir, map[string]bool{}, maxIssueAnrLines)
	got := joined(t, lines)
	if !strings.Contains(got, "MainFrame70.call(") {
		t.Fatalf("the newer Nowhere trace must carry its main stack:\n%s", got)
	}
	want := []string{"--- anr_app ---"}
	for _, ln := range strings.Split(older, "\n") {
		s := strings.TrimSpace(ln)
		if strings.HasPrefix(s, "DALVIK THREADS") {
			break
		}
		if s != "" {
			want = append(want, s)
		}
	}
	at := -1
	for i, ln := range lines {
		if ln == want[0] {
			at = i
			break
		}
	}
	if at < 0 || at+len(want) > len(lines) {
		t.Fatalf("the older trace's header is missing (the main lines took its share of the 60):\n%s", got)
	}
	for i, w := range want {
		if lines[at+i] != w {
			t.Errorf("older trace header line %d: got %q, want %q", i, lines[at+i], w)
		}
	}
	if strings.Contains(got, "OlderFrame") {
		t.Errorf("another app's main frame was carried:\n%s", got)
	}
}

func TestAnrMain_ThroughTheReport(t *testing.T) {
	anrMainDir(t, [2]string{"anr_mine", anrMainTrace("4539", "com.nowhere.chooser", "MainFrame", 70)})
	dest := t.TempDir()
	if err := markRoamSession(dest, "anrmainprofile", "anrmainphrase", "12", ""); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, anrSeenFile), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	rep := anrPreview(t, dest, `{"preview":true}`)
	got := strings.Join(rep.Logs["anr"], "\n")
	for _, want := range []string{"MainFrame1.call(", "MainFrame70.call(", "anr target pid 1457: system_server"} {
		if !strings.Contains(got, want) {
			t.Errorf("a session report's anr section is missing %q:\n%s", want, got)
		}
	}
	rep = anrPreview(t, dest, `{"preview":true,"gate":true}`)
	if _, ok := rep.Logs["anr"]; ok {
		t.Errorf("a gate (device-scope) report must carry no anr section; got %v", rep.Logs["anr"])
	}
}
