package main

// NWP-20261010-06: the issue report carries THIS SESSION'S lines of /data/system/uiderrors.txt -- the package
// manager's record of the per-user app-data dirs its reconcile destroyed -- and says so honestly when it could not.
// Before this the bundle had no such section at all, so a data-loss ticket arrived without the one file that could
// name what destroyed the data.

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// uiderrorsSample is the shape AOSP's logCriticalInfo appends (SimpleDateFormat default + ": " + msg): the
// AppDataHelper reconcile destroy NWP-20260910-10 suspects, plus a settings line naming the same user's path.
var uiderrorsSample = []string{
	"10/10/26, 5:04 PM: Destroying /data/user_de/10/com.example.biggame due to: com.android.server.pm.PackageManagerException: Package com.example.biggame is unknown",
	"10/10/26, 5:04 PM: Destroying /data/user_de/10/org.mozilla.fennec_fdroid due to: com.android.server.pm.PackageManagerException: Package org.mozilla.fennec_fdroid is not installed for user 10",
	"10/10/26, 5:05 PM: Package com.google.android.apps.authenticator2 lost its data dir /data/user/10/com.google.android.apps.authenticator2; Retaining data and using new",
}

// okReply is a worker reply for user 10 carrying lines, as uiderrorsTail frames it.
func okReply(lines ...string) func() string {
	return func() string { return "OK 4242 0 0 10\n" + strings.Join(lines, "\n") + "\n" }
}

// ⚠ THE PRIVACY FLOOR. /data outlives every session here, nothing truncates the file, and uids restart at 10 every
// boot -- so the file holds an earlier renter's destroys under this session's very uid. Only lines past the sign-in
// floor that name this session's user may leave the worker.
func TestUiderrorsTail_OnlyThisSessionsLinesForThisUser(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "uiderrors.txt")
	before := strings.Join([]string{
		// same uid, prior session
		"10/9/26, 9:00 PM: Destroying /data/user_de/10/com.previous.renter due to: Package com.previous.renter is unknown",
		// earlier, other user
		"10/9/26, 9:01 PM: Destroying /data/user_de/11/com.other.earlier due to: x",
	}, "\n") + "\n"
	after := strings.Join([]string{
		// other user, this boot
		"10/10/26, 5:04 PM: Destroying /data/user_de/11/com.someone.else due to: x",
		// user 0
		"10/10/26, 5:04 PM: Destroying /data/user_de/0/com.android.device due to: x",
		// a uid that merely starts with 10
		"10/10/26, 5:04 PM: Destroying /data/user_de/100/com.uid.hundred due to: x",
		// names no user
		"10/10/26, 5:04 PM: Settings: package restrictions file unreadable",
		// THIS session's user, past the floor
		uiderrorsSample[0],
		// THIS user, adopted storage
		"10/10/26, 5:06 PM: Destroying /mnt/expand/1a2b-3c4d/user/10/com.sd.adopted due to: x",
	}, "\n") + "\n"
	if err := os.WriteFile(p, []byte(before+after), 0o644); err != nil {
		t.Fatal(err)
	}
	floor := fmt.Sprint(len(before))
	got := uiderrorsTail(p, 1<<16, floor, "10")
	// Every line carries "10/10/26" -- a "/10/" in its own date -- so only a path-anchored match tells them apart.
	want := fmt.Sprintf("OK %d %s 4 10\n%s\n%s", len(before)+len(after), floor, uiderrorsSample[0],
		"10/10/26, 5:06 PM: Destroying /mnt/expand/1a2b-3c4d/user/10/com.sd.adopted due to: x")
	if got != want {
		t.Errorf("the tail must hold only this session's user-10 lines:\n got %q\nwant %q", got, want)
	}
	for _, leaked := range []string{"previous.renter", "other.earlier", "someone.else", "android.device", "uid.hundred", "restrictions"} {
		if strings.Contains(got, leaked) {
			t.Errorf("a line from another session or user left the worker: %q", leaked)
		}
	}
	// A floor of 0 is "the file did not exist at sign-in": everything is this session's, still filtered by user.
	if got := uiderrorsTail(p, 1<<16, "0", "10"); !strings.Contains(got, "previous.renter") || strings.Contains(got, "other.earlier") {
		t.Errorf("a zero floor reads from the start and still filters by user: %q", got)
	}
}

func TestUiderrorsTail_EveryOtherOutcomeIsNamed(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "uiderrors.txt")
	if got := uiderrorsTail(p, 1<<10, "0", "10"); got != "ABSENT\n" {
		t.Errorf("a missing file with a zero floor must answer ABSENT, got %q", got)
	}
	if got := uiderrorsTail(p, 1<<10, "500", "10"); !strings.HasPrefix(got, "ERR-SHRUNK ") {
		t.Errorf("a file that existed at sign-in and is gone must not read as never-written, got %q", got)
	}
	body := strings.Join(uiderrorsSample, "\n") + "\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ floor, uid, want string }{
		{"", "10", "ERR-NOFLOOR "},
		{"x", "10", "ERR-NOFLOOR "},
		{"0", "", "ERR-NOUID "},
		{"0", "1/0", "ERR-NOUID "},
		{fmt.Sprint(len(body) + 1), "10", "ERR-SHRUNK "},
	} {
		if got := uiderrorsTail(p, 1<<10, c.floor, c.uid); !strings.HasPrefix(got, c.want) {
			t.Errorf("floor=%q uid=%q: got %q, want a %s reply", c.floor, c.uid, got, c.want)
		}
	}
	// The byte bound cuts mid-line: the fragment is dropped, so every line shown carries its own date.
	got := uiderrorsTail(p, int64(len(uiderrorsSample[2])+10), "0", "10")
	// Exact, withheld count included: a kept fragment ("...r user 10") names no path, so it would be COUNTED as a
	// withheld line -- a number the reader trusts as "lines about other users" -- even where it is not shown.
	if want := fmt.Sprintf("OK %d 0 0 10\n%s", len(body), uiderrorsSample[2]); got != want {
		t.Errorf("the bound was not cut at a line start:\n got %q\nwant %q", got, want)
	}
	if os.Getuid() != 0 {
		locked := filepath.Join(dir, "locked")
		if err := os.Mkdir(locked, 0o000); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(locked, 0o700)
		// A denied directory search is EACCES, not ENOENT -- it must never read as "the file does not exist".
		if got := uiderrorsTail(filepath.Join(locked, "uiderrors.txt"), 1<<10, "0", "10"); !strings.HasPrefix(got, "ERR-READ ") ||
			!strings.Contains(got, "permission denied") {
			t.Errorf("an unreadable path must answer ERR-READ with the reason, got %q", got)
		}
		if _, err := uiderrorsFloor(filepath.Join(locked, "uiderrors.txt")); err == nil {
			t.Error("an unreadable path must not yield a floor: a floor of 0 would let every earlier line through")
		}
	}
	if f, err := uiderrorsFloor(p); err != nil || f != int64(len(body)) {
		t.Errorf("floor = %d, %v; want the file's size %d", f, err, len(body))
	}
	if f, err := uiderrorsFloor(filepath.Join(dir, "nope")); err != nil || f != 0 {
		t.Errorf("an absent file's floor = %d, %v; want 0", f, err)
	}
}

func TestUiderrorsSection_IsAlwaysHonest(t *testing.T) {
	got := joined(t, uiderrorsSection(okReply(uiderrorsSample...), []string{"alice"}))
	for _, want := range []string{
		"uiderrors: 3 line(s) naming user 10 were appended to /data/system/uiderrors.txt since this session signed in (0B at sign-in, 4242B now); 0 line(s) about other users or none are withheld",
		"one writer, the app-data reconcile at a user start", "an absent line proves nothing about them",
		"Destroying /data/user_de/10/com.example.biggame due to:", "org.mozilla.fennec_fdroid is not installed for user 10"} {
		if !strings.Contains(got, want) {
			t.Errorf("a readable file must render with its lines intact; missing %q:\n%s", want, got)
		}
	}
	notCollected := []struct {
		name string
		f    func() string
	}{
		{"nil fetch (no worker)", nil},
		{"read refused by policy", func() string { return "ERR-READ open /data/system/uiderrors.txt: permission denied\n" }},
		{"no sign-in floor", func() string { return "ERR-NOFLOOR no sign-in floor was recorded for this session\n" }},
		{"file rewritten since sign-in", func() string { return "ERR-SHRUNK the file held 900B at sign-in and holds 10B now\n" }},
		{"old roamd, no such op", func() string { return "ERR-LANE\n" }},
		{"busy worker", func() string { return "ERR-WORKER-BUSY" }},
		{"worker never answered", func() string { return "ERR-TIMEOUT the worker did not answer within 20s" }},
		{"empty reply", func() string { return "" }},
		{"no session to address", func() string { return fetchUiderrors("", "", "") }},
		{"no user id to filter by", func() string { return fetchUiderrors("", "alice", "") }},
		{"malformed (no OK header)", func() string { return strings.Join(uiderrorsSample, "\n") }},
		{"old two-field OK header", func() string { return "OK 4242\n" + uiderrorsSample[0] }},
		{"reason trips a drop keyword", func() string { return "ERR-READ the password store is busy" }},
	}
	for _, c := range notCollected {
		name, got := c.name, joined(t, uiderrorsSection(c.f, nil))
		if !strings.Contains(got, "uiderrors: NOT collected -- ") || !strings.Contains(got, "this does NOT mean no app data was destroyed") {
			t.Errorf("%s: an uncollected file must say so, never render as a quiet section:\n%s", name, got)
		}
		if strings.Contains(got, "Destroying") {
			t.Errorf("%s: a reply without the five-field OK header must not be rendered as file content:\n%s", name, got)
		}
	}
	if got := joined(t, uiderrorsSection(func() string { return "ERR-READ open /data/system/uiderrors.txt: permission denied" }, nil)); !strings.Contains(got, "permission denied") {
		t.Errorf("the reason a read failed must reach the ticket -- it is what names the missing policy:\n%s", got)
	}
	if got := joined(t, uiderrorsSection(func() string { return fetchUiderrors("", "alice", "") }, nil)); !strings.Contains(got, "no user id") {
		t.Errorf("a missing uid must say why nothing could be asked:\n%s", got)
	}
	if got := joined(t, uiderrorsSection(func() string { return "ABSENT\n" }, nil)); !strings.Contains(got, "does not exist") || strings.Contains(got, "NOT collected") ||
		!strings.Contains(got, "proves nothing about them") {
		t.Errorf("ENOENT is evidence about the reconcile only, and must read as exactly that:\n%s", got)
	}
	if got := joined(t, uiderrorsSection(okReply(), nil)); !strings.Contains(got, "uiderrors: 0 line(s) naming user 10") {
		t.Errorf("a read that found nothing for this session must say it was read:\n%s", got)
	}
}

func TestUiderrorsSection_KeepsTheNewestLinesWithinItsBound(t *testing.T) {
	var lines []string
	for i := 0; i < maxIssueUiderrorsLines+80; i++ {
		lines = append(lines, fmt.Sprintf("10/10/26, 5:04 PM: Destroying /data/user_de/10/com.pkg.n%03d due to: x", i))
	}
	got := uiderrorsSection(okReply(lines...), nil)
	if len(got) != maxIssueUiderrorsLines+1 { // + the header
		t.Fatalf("rendered %d lines, want the bound %d plus a header", len(got), maxIssueUiderrorsLines)
	}
	if !strings.Contains(got[len(got)-1], fmt.Sprintf("com.pkg.n%03d", maxIssueUiderrorsLines+79)) || strings.Contains(strings.Join(got, "\n"), "com.pkg.n000 ") {
		t.Errorf("the bound must keep the NEWEST lines (the destroy being reported is recent):\n%s", got[len(got)-1])
	}
}

// Session scope carries it; the GATE never does, and never even asks the worker.
func TestUiderrorsRidesTheSessionReportOnly(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	calls := 0
	fetch := func() string { calls++; return okReply(uiderrorsSample[0])() }
	rep := buildIssueReport("alice", false, "", nil, fetch)
	if got := strings.Join(rep.Logs["uiderrors"], "\n"); !strings.Contains(got, "com.example.biggame") {
		t.Errorf("the session report does not carry the uiderrors lines:\n%s", got)
	}
	if calls != 1 {
		t.Errorf("the worker was asked %d times for one report, want 1", calls)
	}
	gate := buildIssueReport("", true, "", nil, fetch)
	if _, ok := gate.Logs["uiderrors"]; ok || calls != 1 {
		t.Errorf("the gate report collected uiderrors (present=%v, worker asked %d times in total) -- it names departed sessions' apps", ok, calls)
	}
}

// THE DAEMON REALLY ASKS. Every other test hands buildIssueReport a fetch of its own, so a handler that passed nil
// would stay green while every field report said "no worker was asked (not a device build)".
func TestHandleReportIssueAsksTheWorkerForThisSessionsUser(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "correct horse battery staple", "10", ""); err != nil {
		t.Fatal(err)
	}
	var gotDest, gotName, gotUID string
	orig := uiderrorsWorker
	uiderrorsWorker = func(d, n, u string) string {
		gotDest, gotName, gotUID = d, n, u
		return okReply("10/10/26, 5:04 PM: Destroying /data/user_de/10/com.stub.pkg due to: x")()
	}
	defer func() { uiderrorsWorker = orig }()

	srv, cli := net.Pipe()
	defer cli.Close()
	go func() { handleReportIssue(srv, dest, `{"preview":true}`); srv.Close() }()
	cli.SetDeadline(time.Now().Add(60 * time.Second))
	var rep issueReport
	if err := json.NewDecoder(cli).Decode(&rep); err != nil {
		t.Fatalf("no preview came back: %v", err)
	}
	if gotDest != dest || gotName != "alice" || gotUID != "10" {
		t.Errorf("the worker was asked with dest=%q name=%q uid=%q, want this session's (%q, alice, 10)", gotDest, gotName, gotUID, dest)
	}
	if got := strings.Join(rep.Logs["uiderrors"], "\n"); !strings.Contains(got, "com.stub.pkg") {
		t.Errorf("REPORT-ISSUE did not carry the worker's answer -- a nil fetch reads as 'not a device build' on every device:\n%s", got)
	}
}

// The scrub must keep what the section is FOR -- package names, user ids, paths, reasons -- and still kill every
// planted secret. Only the drop keywords may cost a line, and they are asserted to.
func TestUiderrorsSurvivesTheScrub(t *testing.T) {
	planted := []string{"alice", "9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddccbbaa9988", "AKIAIOSFODNN7EXAMPLE", "+14155550123",
		"bob@example.com", "a4:83:e7:11:22:33"}
	lines := append(append([]string{}, uiderrorsSample...),
		"10/10/26, 5:06 PM: Destroying /data/user/10/com.example.alice.sync due to: token=9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddccbbaa9988",
		"10/10/26, 5:06 PM: Package com.example.dialer has mismatched uid at /data/user/10/com.example.dialer; caller +14155550123 owner bob@example.com",
		"10/10/26, 5:07 PM: Destroying /data/user_de/10/com.example.bt due to: bond a4:83:e7:11:22:33 key AKIAIOSFODNN7EXAMPLE",
		"10/10/26, 5:08 PM: Wiping /data/user/10/com.example.vault: password store rebuilt", // a drop keyword: the line goes whole
	)
	got := joined(t, uiderrorsSection(okReply(lines...), []string{"alice"}))
	for _, sec := range planted {
		if strings.Contains(got, sec) {
			t.Errorf("SECRET LEAKED through the uiderrors section: %q\n%s", sec, got)
		}
	}
	for _, keep := range []string{"com.example.biggame", "org.mozilla.fennec_fdroid", "com.google.android.apps.authenticator2",
		"/data/user_de/10/", "is not installed for user 10", "com.example.dialer has mismatched uid", "com.example.bt due to:"} {
		if !strings.Contains(got, keep) {
			t.Errorf("the scrub ate %q, which is what the section exists to carry:\n%s", keep, got)
		}
	}
	if strings.Contains(got, "com.example.vault") {
		t.Errorf("a line holding a drop keyword must be dropped whole:\n%s", got)
	}
}

// uiderrorsJSON marshals a section the way the gateway stores it, for the sweep in report_issue_test.go.
func uiderrorsJSON(t *testing.T, rep issueReport) string {
	t.Helper()
	b, err := json.Marshal(rep.Logs["uiderrors"])
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// The worker side and the daemon side are one protocol held in two files; pin that they still name each other.
// (test-uiderrors-op.sh runs the shell side itself.)
func TestUiderrorsWorkerOpIsWired(t *testing.T) {
	if got := laneFor("uiderrors"); got.svc != laneRO.svc {
		t.Errorf("uiderrors rides %q, want the read-only lane", got.svc)
	}
	if workerWaitCap("uiderrors") <= 0 {
		t.Error("uiderrors must have a bounded slot wait: an unbounded one hangs the report preview behind a seal")
	}
	b, err := os.ReadFile("../vendor-common/bin/nowhere_roamd.sh")
	if err != nil {
		t.Fatal(err)
	}
	roamd := string(b)
	for _, want := range []string{
		"storagebreakdown|sealdelta|uiderrors|alarmrelay) ;;", "  uiderrors)\n",
		`"$AGENT" uiderrorstail "$(cat "$STATE/uiderrors.floor" 2>/dev/null)" "$uid" > "$RES.part"`,
		`_uefloor=$(uiderrors_floor_take)`, `uiderrors_floor_commit "$_uefloor"`, `"$AGENT" uiderrorsfloor`} {
		if !strings.Contains(roamd, want) {
			t.Errorf("nowhere_roamd.sh lost %q -- every report would say NOT collected", want)
		}
	}
	m, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`case "uiderrorstail":`, `case "uiderrorsfloor":`} {
		if !strings.Contains(string(m), want) {
			t.Errorf("main.go has no %s subcommand -- roamd would run an agent that does not know the op", want)
		}
	}
}
