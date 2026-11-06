package main

// NWP-20261020-05: A SESSION'S ISSUE REPORT CARRIES ONLY THE ANR TRACES THAT APPEARED AFTER IT BEGAN.
//
// /data/anr is shared by every session of the boot and nothing records which session wrote a file, so a report
// filed by profile B used to carry profile A's app names. recordAnrSeen snapshots the trace NAMES where a session
// begins; the report leaves out every file named there. A session with no snapshot carries no anr section.

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// anrFixture points anrDir at a temp dir holding anr_old (an earlier session's) and anr_new (this session's).
func anrFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	old := anrDir
	anrDir = dir
	t.Cleanup(func() { anrDir = old })
	for name, pkg := range map[string]string{"anr_old": "com.example.earlier", "anr_new": "com.example.mine"} {
		body := "----- pid 1 at 2026-10-19 -----\nCmd line: " + pkg + "\n\nDALVIK THREADS (1):\n\"main\" prio=5\n"
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestAnrHeaders_LeavesOutEveryTraceTheSnapshotNames(t *testing.T) {
	dir := anrFixture(t)
	lines, _ := anrHeaders(dir, map[string]bool{"anr_old": true}, 100)
	got := joined(t, lines)
	if !strings.Contains(got, "com.example.mine") || strings.Contains(got, "com.example.earlier") {
		t.Errorf("a seen trace must be left out and a new one kept:\n%s", got)
	}
	if lines, srcs := anrHeaders(dir, nil, 100); lines != nil || srcs != nil {
		t.Errorf("a nil snapshot must read nothing (fail closed); got %v %v", lines, srcs)
	}
	lines, _ = anrHeaders(dir, map[string]bool{}, 100)
	got = joined(t, lines)
	if !strings.Contains(got, "com.example.mine") || !strings.Contains(got, "com.example.earlier") {
		t.Errorf("an empty snapshot means every trace is this session's:\n%s", got)
	}
	lines, srcs := anrHeaders(dir, map[string]bool{"anr_old": true, "anr_new": true}, 100)
	if len(lines) != 0 {
		t.Errorf("every trace seen: no lines expected, got %v", lines)
	}
	if s := anrSection(lines, srcs, nil); len(s) != 0 {
		t.Errorf("every trace seen: the section must render nothing, got %v", s)
	}
}

func anrPreview(t *testing.T, dest, req string) issueReport {
	t.Helper()
	cli, srv := net.Pipe()
	go func() { handleReportIssue(srv, dest, req); srv.Close() }()
	buf, _ := io.ReadAll(cli)
	var rep issueReport
	if err := json.Unmarshal(buf, &rep); err != nil {
		t.Fatalf("preview is not JSON: %v\n%s", err, buf)
	}
	return rep
}

func TestReportIssue_AnrSectionIsThisSessionsOnly(t *testing.T) {
	anrFixture(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "testname", "testpass", "12", ""); err != nil {
		t.Fatal(err)
	}
	seen := filepath.Join(dest, anrSeenFile)
	if err := os.WriteFile(seen, []byte("anr_old\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := joined(t, anrPreview(t, dest, `{"preview":true}`).Logs["anr"])
	if !strings.Contains(got, "com.example.mine") || strings.Contains(got, "com.example.earlier") {
		t.Errorf("session report must carry only the new trace:\n%s", got)
	}
	os.Remove(seen)
	if a := anrPreview(t, dest, `{"preview":true}`).Logs["anr"]; len(a) != 0 {
		t.Errorf("no snapshot: no anr section, got %v", a)
	}
	os.WriteFile(seen, []byte("anr_old\n"), 0o600)
	if a := anrPreview(t, dest, `{"preview":true,"gate":true}`).Logs["anr"]; len(a) != 0 {
		t.Errorf("a gate report carries no anr section, got %v", a)
	}
}

func TestRecordAnrSeen(t *testing.T) {
	dir := anrFixture(t)
	if err := os.Mkdir(filepath.Join(dir, "subdir"), 0o755); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	recordAnrSeen(dest)
	seen := readAnrSeen(dest)
	if len(seen) != 2 || !seen["anr_old"] || !seen["anr_new"] {
		t.Errorf("snapshot must list exactly the non-directory entries; got %v", seen)
	}
	if fi, err := os.Stat(filepath.Join(dest, anrSeenFile)); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("snapshot mode: %v %v", fi, err)
	}

	// ENOENT: an EMPTY snapshot, and a trace created afterwards is shown.
	anrDir = filepath.Join(t.TempDir(), "absent")
	dest = t.TempDir()
	recordAnrSeen(dest)
	seen = readAnrSeen(dest)
	if seen == nil || len(seen) != 0 {
		t.Fatalf("an absent anrDir must write an empty snapshot; got %v", seen)
	}
	os.Mkdir(anrDir, 0o755)
	os.WriteFile(filepath.Join(anrDir, "anr_later"), []byte("Cmd line: com.example.later\n"), 0o644)
	lines, _ := anrHeaders(anrDir, seen, 100)
	if !strings.Contains(joined(t, lines), "com.example.later") {
		t.Errorf("a trace created after an empty snapshot is this session's; got %v", lines)
	}

	// Any other read failure leaves NO snapshot, and removes a planted old one.
	file := filepath.Join(t.TempDir(), "regular")
	os.WriteFile(file, []byte("x"), 0o644)
	anrDir = file
	dest = t.TempDir()
	os.WriteFile(filepath.Join(dest, anrSeenFile), []byte("anr_old\n"), 0o600)
	recordAnrSeen(dest)
	if _, err := os.Stat(filepath.Join(dest, anrSeenFile)); !os.IsNotExist(err) {
		t.Errorf("a failed ReadDir must remove the old snapshot (%v)", err)
	}
}

func TestForgetUiderrorsFloorRemovesTheAnrSnapshot(t *testing.T) {
	dest := t.TempDir()
	p := filepath.Join(dest, anrSeenFile)
	os.WriteFile(p, []byte("anr_old\n"), 0o600)
	forgetUiderrorsFloor(dest)
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("the session's end must drop anr.seen (%v)", err)
	}
}

func TestAnrSnapshot_OfflineSignInTakesItAfterTheForget(t *testing.T) {
	dir := anrFixture(t)
	dest := t.TempDir()
	os.WriteFile(filepath.Join(dest, anrSeenFile), []byte("stale_from_earlier\n"), 0o600)
	stop := ropWorker(t, dest)
	defer stop()
	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, "alice", "correct horse battery", "12"); srv.Close() }()
	buf, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(buf)); got != "OK 12" {
		t.Fatalf("offline sign-in replied %q", got)
	}
	_ = dir
	seen := readAnrSeen(dest)
	if len(seen) != 2 || !seen["anr_old"] || !seen["anr_new"] || seen["stale_from_earlier"] {
		t.Errorf("offline sign-in must leave a fresh snapshot of anrDir; got %v", seen)
	}
}

// The call sites, pinned in source order: a new session takes the snapshot, a continuing one never retakes it.
func TestAnrSnapshot_TakenWhereASessionBeginsAndOnlyThere(t *testing.T) {
	const call = "recordAnrSeen(dest)"
	in := fileFuncBody(t, "main.go", "handleRoamIn")
	if strings.Count(in, call) != 1 {
		t.Fatalf("handleRoamIn must call %s exactly once", call)
	}
	mark := strings.Index(in, "markRoamSession(dest, name, pass, uid, seSecret)")
	callAt := strings.Index(in, call)
	if mark < 0 || callAt < mark {
		t.Fatalf("handleRoamIn must take the snapshot after markRoamSession")
	}
	// Everything between the markRoamSession call and the snapshot must be the whole error block: it ends in a
	// return and its closing brace, so a call placed inside the branch (or before the return) fails here.
	between := in[mark:callAt]
	// NWP-20261030-02's resetSealSignals() also belongs right after the block (a new identity is recorded): drop it and
	// any comment lines from the tail before checking that the block is complete.
	between = regexp.MustCompile(`(?:\s*(?://[^\n]*|resetSealSignals\(\)))*\s*$`).ReplaceAllString(between, "")
	if !strings.Contains(between, "ERR-UNRECORDED") || !regexp.MustCompile(`return\s*\}\s*$`).MatchString(between) {
		t.Errorf("handleRoamIn must take the snapshot after the complete markRoamSession error block (return and closing brace)")
	}
	off := fileFuncBody(t, "main.go", "handleRoamInOffline")
	if strings.Count(off, call) != 1 || strings.Index(off, call) < strings.Index(off, "forgetUiderrorsFloor(dest)") ||
		!strings.Contains(off, "forgetUiderrorsFloor(dest)") {
		t.Errorf("handleRoamInOffline must call %s exactly once, after forgetUiderrorsFloor", call)
	}
	for _, fn := range []string{"handleResume", "handleRotate", "handlePromote2"} {
		if strings.Contains(fileFuncBody(t, "main.go", fn), "recordAnrSeen(") {
			t.Errorf("%s continues a session and must not retake its anr snapshot", fn)
		}
	}
}
