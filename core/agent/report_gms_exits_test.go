package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// The fixtures follow ApplicationExitInfo.dump and AppExitInfoTracker.dumpHistoryProcessExitInfo in AOSP main
// (frameworks/base), read on 2026-11-08. The GrapheneOS source was not reachable; a handset report is that check.

func init() {
	// No older handleReportIssue test may wait on a lane.
	gmsExitsWorker = func(dest, name, uid string) string { return "" }
}

const (
	gmsExitsTestPersistent = "com.google.android.gms.persistent"
	gmsExitsTestMain       = "com.google.android.gms"
	gmsExitsTestUser       = "10"
	gmsExitsTestNow        = "2021-03-05 00:35:00"
)

// gmsExitBlockText renders one record; the three field lines are arguments so that a test can break exactly one.
func gmsExitBlockText(timeLine, processLine, importanceLine string) string {
	return "      ApplicationExitInfo #0:\n        " + timeLine + "\n        " + processLine + "\n        " + importanceLine + "\n"
}

func gmsExitTimeLine(stamp, user string) string {
	return "timestamp=" + stamp + ".123 pid=4242 realUid=1010123 packageUid=1010123 definingUid=1010123 user=" + user
}

func gmsExitProcessLine(process, reason, sub string) string {
	return "process=" + process + " reason=3 (" + reason + ") subreason=0 (" + sub + ") status=0"
}

const gmsExitsTestImportance = `importance=400 pss=12MB rss=34MB description=crash in com.example.secretapp "quoted-token" state=empty trace=null`

func gmsExitRecord(stamp, user, process, reason, sub string) string {
	return gmsExitBlockText(gmsExitTimeLine(stamp, user), gmsExitProcessLine(process, reason, sub), gmsExitsTestImportance)
}

// gmsExitDump wraps blocks in what roamd pipes to the agent, exit status 0.
func gmsExitDump(blocks ...string) string {
	return "nowhere-now=1614904500 " + gmsExitsTestNow + "\n" +
		"ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)\n" +
		"Last Timestamp of Persistence Into Persistent Storage: 2021-03-05 00:31:00.000\n" +
		"  package: com.google.android.gms\n    HistoricalProcessExit for uid=1010123\n" +
		strings.Join(blocks, "") + "\nnowhere-dump-rc=0\n"
}

// gmsExitsTestMarker makes a session marker of the given age in a new directory.
func gmsExitsTestMarker(t *testing.T, age time.Duration) string {
	t.Helper()
	dest := t.TempDir()
	p := filepath.Join(dest, roamSessionFile)
	if err := os.WriteFile(p, []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	when := time.Now().Add(-age)
	if err := os.Chtimes(p, when, when); err != nil {
		t.Fatal(err)
	}
	return dest
}

func gmsExitsMerged(t *testing.T, reply string, age time.Duration, seed map[string]string) map[string]string {
	t.Helper()
	status := map[string]string{"keep": "this"}
	for k, v := range seed {
		status[k] = v
	}
	mergeGmsExits(status, func() string { return reply }, gmsExitsTestMarker(t, age), false)
	return status
}

func gmsExitsWantKeys(t *testing.T, status map[string]string, want map[string]string) {
	t.Helper()
	got := map[string]string{}
	for k, v := range status {
		if strings.HasPrefix(k, "gms_exit") {
			got[k] = v
		}
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("gms_exit keys = %v, want %v", got, want)
	}
}

func TestGmsExitsTwoRecordsExactLines(t *testing.T) {
	got := parseGmsExits(gmsExitDump(
		gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestPersistent, "LOW_MEMORY", "OTHER"),
		gmsExitRecord("2021-03-05 00:34:00", "10", gmsExitsTestMain, "OTHER", "LOW_MEMORY"),
	), gmsExitsTestUser)
	want := "OK 2 0\nmain reason=OTHER sub=LOW_MEMORY imp=400 age_s=60\npersistent reason=LOW_MEMORY sub=OTHER imp=400 age_s=299\n"
	if got != want {
		t.Errorf("reply =\n%s\nwant\n%s", got, want)
	}
}

func TestGmsExitsOtherUserAndProcessDropped(t *testing.T) {
	got := parseGmsExits(gmsExitDump(
		gmsExitRecord("2021-03-05 00:30:01", "11", gmsExitsTestPersistent, "OTHER", "OTHER"),
		gmsExitRecord("2021-03-05 00:30:02", "10", "com.google.android.gms.unstable", "OTHER", "OTHER"),
		gmsExitRecord("2021-03-05 00:30:03", "10", gmsExitsTestMain, "OTHER", "OTHER"),
	), gmsExitsTestUser)
	want := "OK 1 2\nmain reason=OTHER sub=OTHER imp=400 age_s=297\n"
	if got != want {
		t.Errorf("reply =\n%s\nwant\n%s", got, want)
	}
}

func TestGmsExitsOlderThanSessionDropped(t *testing.T) {
	reply := "OK 2 0\nmain reason=OTHER sub=OTHER imp=400 age_s=100\npersistent reason=OTHER sub=OTHER imp=400 age_s=7200\n"
	gmsExitsWantKeys(t, gmsExitsMerged(t, reply, time.Hour, nil), map[string]string{
		"gms_exits":  "1",
		"gms_exit_1": "main reason=OTHER sub=OTHER imp=400 age_s=100",
	})
}

func TestGmsExitsDescriptionNeverCarried(t *testing.T) {
	reply := parseGmsExits(gmsExitDump(gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestPersistent, "OTHER", "OTHER")), gmsExitsTestUser)
	status := gmsExitsMerged(t, reply, 24*365*100*time.Hour, nil)
	if status["gms_exits"] != "1" {
		t.Fatalf("gms_exits = %q, want 1; reply %q", status["gms_exits"], reply)
	}
	for _, text := range append([]string{reply}, status["gms_exit_1"]) {
		for _, leak := range []string{"secretapp", "quoted-token", "description", "trace", "pss", "rss", "state", "pid", "1010123"} {
			if strings.Contains(text, leak) {
				t.Errorf("%q carries %q", text, leak)
			}
		}
	}
}

func TestGmsExitsLocalClock(t *testing.T) {
	old := time.Local
	t.Cleanup(func() { time.Local = old })
	time.Local = time.FixedZone("TEST+5", 5*3600)
	got := parseGmsExits(gmsExitDump(gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestMain, "OTHER", "OTHER")), gmsExitsTestUser)
	if want := "OK 1 0\nmain reason=OTHER sub=OTHER imp=400 age_s=299\n"; got != want {
		t.Errorf("reply = %q, want %q", got, want)
	}
}

func TestGmsExitsFailedDump(t *testing.T) {
	good := gmsExitDump(gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestMain, "OTHER", "OTHER"))
	cases := map[string]string{
		"rc 1":             strings.Replace(good, "nowhere-dump-rc=0", "nowhere-dump-rc=1", 1),
		"no rc line":       strings.Replace(good, "nowhere-dump-rc=0\n", "", 1),
		"rc not last":      strings.Replace(good, "nowhere-dump-rc=0\n", "nowhere-dump-rc=0\nmore output\n", 1),
		"no framework":     strings.Replace(good, "ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)\n", "", 1),
		"no clock":         strings.Replace(good, "nowhere-now=1614904500 "+gmsExitsTestNow+"\n", "", 1),
		"truncated":        good[:strings.Index(good, "importance=")],
		"denied, no dump":  "nowhere-now=1614904500 " + gmsExitsTestNow + "\n\nnowhere-dump-rc=0\n",
		"nothing on stdin": "",
	}
	for name, dump := range cases {
		t.Run(name, func(t *testing.T) {
			reply := parseGmsExits(dump, gmsExitsTestUser)
			if !strings.HasPrefix(reply, "ERR-DUMP ") {
				t.Fatalf("reply = %q, want ERR-DUMP", reply)
			}
			gmsExitsWantKeys(t, gmsExitsMerged(t, reply, time.Hour, nil), map[string]string{"gms_exits": "not-collected-dump"})
		})
	}
	if got := parseGmsExits(good, "x10"); !strings.HasPrefix(got, "ERR-DUMP ") {
		t.Errorf("a non-digit uid answered %q, want ERR-DUMP", got)
	}
}

func TestGmsExitsDeviceScope(t *testing.T) {
	status := map[string]string{"gms_exits": "99", "gms_exit_1": "forged", "gms_exit_x": "forged", "keep": "this"}
	called := false
	mergeGmsExits(status, func() string { called = true; return "OK 0 0" }, gmsExitsTestMarker(t, time.Hour), true)
	gmsExitsWantKeys(t, status, map[string]string{})
	if called {
		t.Error("a device-scope report asked the worker")
	}
	if status["keep"] != "this" {
		t.Error("a key of another prefix was deleted")
	}
}

func TestGmsExitsLaneAndCap(t *testing.T) {
	if got := laneFor("gmsexits"); got.svc != laneRO.svc {
		t.Errorf("laneFor(gmsexits).svc = %q, want the read-only lane", got.svc)
	}
	if c := workerWaitCap("gmsexits"); c <= 0 || c > gmsExitsWait {
		t.Errorf("workerWaitCap(gmsexits) = %s, want > 0 and <= %s", c, gmsExitsWait)
	}
}

func TestGmsExitsCapKeepsNewest(t *testing.T) {
	var blocks []string
	var want []string
	for i := 0; i < 11; i++ {
		// i = 0 is the oldest, so the reply must hold the records of i = 10 down to i = 3.
		blocks = append(blocks, gmsExitRecord(fmt.Sprintf("2021-03-05 00:%02d:00", 20+i), "10", gmsExitsTestMain, "OTHER", "OTHER"))
	}
	for i := 10; i >= 3; i-- {
		want = append(want, fmt.Sprintf("main reason=OTHER sub=OTHER imp=400 age_s=%d", (15-i)*60))
	}
	got := parseGmsExits(gmsExitDump(blocks...), gmsExitsTestUser)
	if wantReply := "OK 8 3\n" + strings.Join(want, "\n") + "\n"; got != wantReply {
		t.Errorf("reply =\n%s\nwant\n%s", got, wantReply)
	}
	keys := map[string]string{"gms_exits": "8"}
	for i, ln := range want {
		keys[fmt.Sprintf("gms_exit_%d", i+1)] = ln
	}
	gmsExitsWantKeys(t, gmsExitsMerged(t, got, 24*365*100*time.Hour, nil), keys)
}

func TestGmsExitsTimeout(t *testing.T) {
	oldWorker, oldWait := gmsExitsWorker, gmsExitsWait
	release := make(chan struct{})
	t.Cleanup(func() { close(release); gmsExitsWorker, gmsExitsWait = oldWorker, oldWait })
	gmsExitsWorker = func(dest, name, uid string) string { <-release; return "OK 0 0" }
	gmsExitsWait = 20 * time.Millisecond
	status := map[string]string{}
	dest := gmsExitsTestMarker(t, time.Hour)
	mergeGmsExits(status, func() string { return fetchGmsExits(dest, "p", gmsExitsTestUser) }, dest, false)
	gmsExitsWantKeys(t, status, map[string]string{"gms_exits": "not-collected-timeout"})
}

func TestGmsExitsFetchAsksOnlyForADigitUser(t *testing.T) {
	old := gmsExitsWorker
	t.Cleanup(func() { gmsExitsWorker = old })
	var gotName, gotUID string
	gmsExitsWorker = func(dest, name, uid string) string { gotName, gotUID = name, uid; return "OK 0 0" }
	if got := fetchGmsExits(t.TempDir(), "p", "12"); got != "OK 0 0" || gotName != "p" || gotUID != "12" {
		t.Errorf("fetch answered %q and asked (%q, %q)", got, gotName, gotUID)
	}
	gotUID = "unset"
	for _, uid := range []string{"", "1x"} {
		if got := fetchGmsExits(t.TempDir(), "p", uid); got != "" || gotUID != "unset" {
			t.Errorf("uid %q: fetch answered %q and asked uid %q, want no worker call", uid, got, gotUID)
		}
	}
}

func TestGmsExitsRealFrameworkWords(t *testing.T) {
	for in, want := range map[string]string{
		"APP CRASH(EXCEPTION)":  "APP_CRASH_EXCEPTION",
		"OTHER KILLS BY SYSTEM": "OTHER_KILLS_BY_SYSTEM",
		"FREEZER BINDER IOCTL":  "FREEZER_BINDER_IOCTL",
		"LOW_MEMORY":            "LOW_MEMORY",
	} {
		got := parseGmsExits(gmsExitDump(gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestMain, in, in)), gmsExitsTestUser)
		if line := "main reason=" + want + " sub=" + want + " imp=400 age_s=299\n"; got != "OK 1 0\n"+line {
			t.Errorf("%q: reply %q, want the line %q", in, got, line)
		}
	}
}

func TestGmsExitsBadWordIsUnparsed(t *testing.T) {
	for _, word := range []string{"com.example.app", "lower", "DIGIT1", `QUOTE"D`, strings.Repeat("A", 41), ""} {
		got := parseGmsExits(gmsExitDump(gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestMain, word, "OTHER")), gmsExitsTestUser)
		if want := "OK 1 0\nmain reason=unparsed sub=OTHER imp=400 age_s=299\n"; got != want {
			t.Errorf("word %q: reply %q, want %q", word, got, want)
		}
	}
}

func TestGmsExitsReplyMapping(t *testing.T) {
	for reply, want := range map[string]string{
		"":                        "not-collected-empty",
		"ERR-LANE":                "not-collected-lane",
		workerBusy:                "not-collected-lane",
		"ERR-TIMEOUT something":   "not-collected-timeout",
		"ERR-DUMP no clock line":  "not-collected-dump",
		"ERR-READ the agent died": "not-collected-dump",
		"junk":                    "not-collected-malformed",
		"OKAY 1 0":                "not-collected-malformed",
		"OK 2 0\nmain reason=OTHER sub=OTHER imp=4 age_s=1": "not-collected-malformed",
		"OK 0 0\nmain reason=OTHER sub=OTHER imp=4 age_s=1": "not-collected-malformed",
		"ERR-" + strings.Repeat("Z", 20):                    "not-collected-malformed",
	} {
		gmsExitsWantKeys(t, gmsExitsMerged(t, reply, time.Hour, nil), map[string]string{"gms_exits": want})
	}
}

func TestGmsExitsMarkerAbsent(t *testing.T) {
	status := map[string]string{"gms_exit_3": "forged"}
	called := false
	mergeGmsExits(status, func() string { called = true; return "OK 0 0" }, t.TempDir(), false)
	gmsExitsWantKeys(t, status, map[string]string{"gms_exits": "unread-session-start"})
	if called {
		t.Error("the worker was asked although the session's start is not known")
	}
}

func TestGmsExitsNegativeAgeAndBadLine(t *testing.T) {
	got := parseGmsExits(gmsExitDump(gmsExitRecord("2021-03-05 00:40:00", "10", gmsExitsTestMain, "OTHER", "OTHER")), gmsExitsTestUser)
	if got != "OK 0 1\n" {
		t.Errorf("a record after the clock line answered %q, want OK 0 1", got)
	}
	reply := "OK 2 0\nmain reason=OTHER sub=OTHER imp=4 age_s=1 description=com.example.secretapp\npersistent reason=OTHER sub=OTHER imp=4 age_s=2\n"
	gmsExitsWantKeys(t, gmsExitsMerged(t, reply, time.Hour, nil), map[string]string{
		"gms_exits":  "2",
		"gms_exit_1": "unparsed",
		"gms_exit_2": "persistent reason=OTHER sub=OTHER imp=4 age_s=2",
	})
}

func TestGmsExitsCallerKeysDeletedAtSessionScope(t *testing.T) {
	status := gmsExitsMerged(t, "OK 0 0", time.Hour, map[string]string{"gms_exit_9": "forged", "gms_exits": "99"})
	gmsExitsWantKeys(t, status, map[string]string{"gms_exits": "0"})
	if status["keep"] != "this" {
		t.Error("a key of another prefix was deleted")
	}
}

func TestGmsExitsFormatDriftIsNotCollected(t *testing.T) {
	const noBlock = "ERR-DUMP no exit-info block parsed"
	goodTime := gmsExitTimeLine("2021-03-05 00:30:01", "10")
	goodProcess := gmsExitProcessLine(gmsExitsTestPersistent, "OTHER", "OTHER")
	for name, block := range map[string]string{
		"extra field after user":  gmsExitBlockText(goodTime+" extra=1", goodProcess, gmsExitsTestImportance),
		"process without status":  gmsExitBlockText(goodTime, "process="+gmsExitsTestPersistent+" reason=3 (OTHER) subreason=0 (OTHER)", gmsExitsTestImportance),
		"importance not a number": gmsExitBlockText(goodTime, goodProcess, "importance=foreground pss=12MB"),
		"month 13":                gmsExitBlockText(gmsExitTimeLine("2021-13-05 00:30:01", "10"), goodProcess, gmsExitsTestImportance),
	} {
		t.Run(name, func(t *testing.T) {
			reply := parseGmsExits(gmsExitDump(block), gmsExitsTestUser)
			if reply != noBlock {
				t.Fatalf("reply = %q, want %q", reply, noBlock)
			}
			gmsExitsWantKeys(t, gmsExitsMerged(t, reply, time.Hour, nil), map[string]string{"gms_exits": "not-collected-dump"})
		})
	}
}

func TestGmsExitsHonestReplies(t *testing.T) {
	complete := gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestMain, "OTHER", "OTHER")
	broken := gmsExitBlockText(gmsExitTimeLine("2021-03-05 00:30:01", "10")+" extra=1", gmsExitProcessLine(gmsExitsTestMain, "OTHER", "OTHER"), gmsExitsTestImportance)
	cases := []struct {
		name, dump, reply, key string
	}{
		{"no blocks", gmsExitDump(), "OK 0 0\n", "0"},
		{"only another user", gmsExitDump(gmsExitRecord("2021-03-05 00:30:01", "11", gmsExitsTestMain, "OTHER", "OTHER")), "OK 0 1\n", "0"},
		{"only a negative age", gmsExitDump(gmsExitRecord("2021-03-05 00:40:00", "10", gmsExitsTestMain, "OTHER", "OTHER")), "OK 0 1\n", "0"},
		{"one complete, one broken", gmsExitDump(complete, broken), "OK 1 1\nmain reason=OTHER sub=OTHER imp=400 age_s=299\n", "1"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := parseGmsExits(c.dump, gmsExitsTestUser)
			if got != c.reply {
				t.Fatalf("reply = %q, want %q", got, c.reply)
			}
			if status := gmsExitsMerged(t, got, 24*365*100*time.Hour, nil); status["gms_exits"] != c.key {
				t.Errorf("gms_exits = %q, want %q", status["gms_exits"], c.key)
			}
		})
	}
}

func TestGmsExitsChangedHeaderOpensABlock(t *testing.T) {
	const header = "      ApplicationExitInfo #0 (cached):\n"
	goodProcess := gmsExitProcessLine(gmsExitsTestMain, "OTHER", "OTHER")
	broken := header + "        " + gmsExitTimeLine("2021-03-05 00:30:01", "10") + " extra=1\n        " + goodProcess + "\n        " + gmsExitsTestImportance + "\n"
	if got := parseGmsExits(gmsExitDump(broken), gmsExitsTestUser); got != "ERR-DUMP no exit-info block parsed" {
		t.Errorf("a changed header with a broken line answered %q, want the failed-read reply", got)
	}
	good := header + "        " + gmsExitTimeLine("2021-03-05 00:30:01", "10") + "\n        " + goodProcess + "\n        " + gmsExitsTestImportance + "\n"
	if got, want := parseGmsExits(gmsExitDump(good), gmsExitsTestUser), "OK 1 0\nmain reason=OTHER sub=OTHER imp=400 age_s=299\n"; got != want {
		t.Errorf("a changed header with good lines answered %q, want %q", got, want)
	}
}

func TestGmsExitsKeyValuesHaveTheFixedShape(t *testing.T) {
	reply := parseGmsExits(gmsExitDump(
		gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestPersistent, "APP CRASH(EXCEPTION)", "UNKNOWN"),
	), gmsExitsTestUser)
	status := gmsExitsMerged(t, reply, 24*365*100*time.Hour, nil)
	shape := regexp.MustCompile(`^(persistent|main) reason=[A-Z_]+ sub=[A-Z_]+ imp=[0-9]+ age_s=[0-9]+$`)
	if !shape.MatchString(status["gms_exit_1"]) {
		t.Errorf("gms_exit_1 = %q", status["gms_exit_1"])
	}
}

// The real handler asks the worker at session scope, and a gate preview of the same session asks nothing.
func TestGmsExitsReportHandlerIsWired(t *testing.T) {
	old, oldUiderrors := gmsExitsWorker, uiderrorsWorker
	t.Cleanup(func() { gmsExitsWorker, uiderrorsWorker = old, oldUiderrors })
	uiderrorsWorker = func(d, n, u string) string { return "" } // the report's other worker must not wait on a lane
	dest := t.TempDir()
	if err := markRoamSession(dest, "gmsexits-wired", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	asked := 0
	gmsExitsWorker = func(d, name, uid string) string {
		asked++
		if d != dest || name != "gmsexits-wired" || uid != "10" {
			t.Errorf("the worker was asked with (%q, %q, %q)", d, name, uid)
		}
		return "OK 1 0\nmain reason=OTHER sub=OTHER imp=4 age_s=0\n"
	}
	marker := filepath.Join(dest, roamSessionFile)
	past := time.Now().Add(-time.Hour)
	if err := os.Chtimes(marker, past, past); err != nil {
		t.Fatal(err)
	}
	preview := func(req string) issueReport {
		srv, cli := net.Pipe()
		defer cli.Close()
		go func() { handleReportIssue(srv, dest, req); srv.Close() }()
		cli.SetDeadline(time.Now().Add(60 * time.Second))
		var rep issueReport
		if err := json.NewDecoder(cli).Decode(&rep); err != nil {
			t.Fatalf("no preview came back: %v", err)
		}
		return rep
	}
	rep := preview(`{"preview":true,"status":{"gms_exit_7":"forged"}}`)
	gmsExitsWantKeys(t, rep.Status, map[string]string{"gms_exits": "1", "gms_exit_1": "main reason=OTHER sub=OTHER imp=4 age_s=0"})
	if asked != 1 {
		t.Errorf("a session report asked the worker %d time(s), want 1", asked)
	}
	rep = preview(`{"preview":true,"gate":true,"status":{"gms_exit_7":"forged"}}`)
	gmsExitsWantKeys(t, rep.Status, map[string]string{})
	if asked != 1 {
		t.Errorf("a gate report asked the worker (%d asks in all, want 1)", asked)
	}
}
