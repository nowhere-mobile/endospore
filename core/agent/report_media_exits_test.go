package main

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

// The fixtures follow ApplicationExitInfo.dump in AOSP main (frameworks/base), as report_gms_exits_test.go's do. That
// the media module's process name equals its package name on a handset is the follow-up's check.

func init() {
	// No older handleReportIssue test may wait on a lane.
	mediaExitsWorker = func(dest, name, uid string) string { return "" }
}

const (
	mediaExitsTestAOSP   = "com.android.providers.media.module"
	mediaExitsTestGoogle = "com.google.android.providers.media.module"
)

// mediaExitDump wraps blocks in what roamd pipes to the agent: the clock line, one dump per module name, the rc line.
func mediaExitDump(aosp, google []string) string {
	section := func(pkg string, blocks []string) string {
		return "ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)\n" +
			"Last Timestamp of Persistence Into Persistent Storage: 2021-03-05 00:31:00.000\n" +
			"  package: " + pkg + "\n    HistoricalProcessExit for uid=1010123\n" + strings.Join(blocks, "")
	}
	return "nowhere-now=1614904500 " + gmsExitsTestNow + "\n" + section(mediaExitsTestAOSP, aosp) +
		section(mediaExitsTestGoogle, google) + "\nnowhere-dump-rc=0\n"
}

func mediaExitsMerged(t *testing.T, reply string, age time.Duration, seed map[string]string) map[string]string {
	t.Helper()
	status := map[string]string{"keep": "this"}
	for k, v := range seed {
		status[k] = v
	}
	mergeMediaExits(status, func() string { return reply }, gmsExitsTestMarker(t, age), false)
	return status
}

func mediaExitsWantKeys(t *testing.T, status map[string]string, want map[string]string) {
	t.Helper()
	got := map[string]string{}
	for k, v := range status {
		if strings.HasPrefix(k, "media_exit") {
			got[k] = v
		}
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("media_exit keys = %v, want %v", got, want)
	}
}

// E1: one record per module name, newest first, both under the label media.
func TestMediaExitsTwoRecordsExactLines(t *testing.T) {
	got := parseExitInfo(mediaExitDump(
		[]string{gmsExitRecord("2021-03-05 00:30:01", "10", mediaExitsTestAOSP, "APP CRASH(EXCEPTION)", "UNKNOWN")},
		[]string{gmsExitRecord("2021-03-05 00:34:00", "10", mediaExitsTestGoogle, "USER REQUESTED", "FORCE STOP")},
	), gmsExitsTestUser, mediaExitLabels)
	const l1 = "media reason=USER_REQUESTED sub=FORCE_STOP imp=400 age_s=60"
	const l2 = "media reason=APP_CRASH_EXCEPTION sub=UNKNOWN imp=400 age_s=299"
	if want := "OK 2 0\n" + l1 + "\n" + l2 + "\n"; got != want {
		t.Fatalf("reply =\n%s\nwant\n%s", got, want)
	}
	mediaExitsWantKeys(t, mediaExitsMerged(t, got, 24*365*100*time.Hour, nil), map[string]string{
		"media_exits": "2", "media_exit_1": l1, "media_exit_2": l2,
	})
}

// E2: another user's media record and this user's gms record in the same dump are dropped.
func TestMediaExitsOtherUserAndGmsDropped(t *testing.T) {
	got := parseExitInfo(mediaExitDump(
		[]string{
			gmsExitRecord("2021-03-05 00:30:01", "11", mediaExitsTestAOSP, "OTHER", "OTHER"),
			gmsExitRecord("2021-03-05 00:30:02", "10", gmsExitsTestMain, "OTHER", "OTHER"),
		},
		[]string{gmsExitRecord("2021-03-05 00:30:03", "10", mediaExitsTestGoogle, "OTHER", "OTHER")},
	), gmsExitsTestUser, mediaExitLabels)
	if want := "OK 1 2\nmedia reason=OTHER sub=OTHER imp=400 age_s=297\n"; got != want {
		t.Errorf("reply =\n%s\nwant\n%s", got, want)
	}
}

// E3: a record older than the session (a reused user id) is dropped.
func TestMediaExitsOlderThanSessionDropped(t *testing.T) {
	reply := "OK 2 0\nmedia reason=OTHER sub=OTHER imp=400 age_s=100\nmedia reason=APP_CRASH_EXCEPTION sub=UNKNOWN imp=400 age_s=7200\n"
	mediaExitsWantKeys(t, mediaExitsMerged(t, reply, time.Hour, nil), map[string]string{
		"media_exits":  "1",
		"media_exit_1": "media reason=OTHER sub=OTHER imp=400 age_s=100",
	})
}

// E4: no description, trace, memory, state, pid, uid or package text reaches the reply or a key.
func TestMediaExitsDescriptionNeverCarried(t *testing.T) {
	reply := parseExitInfo(mediaExitDump(
		[]string{gmsExitRecord("2021-03-05 00:30:01", "10", mediaExitsTestAOSP, "OTHER", "OTHER")}, nil,
	), gmsExitsTestUser, mediaExitLabels)
	status := mediaExitsMerged(t, reply, 24*365*100*time.Hour, nil)
	if status["media_exits"] != "1" {
		t.Fatalf("media_exits = %q, want 1; reply %q", status["media_exits"], reply)
	}
	for _, text := range []string{reply, status["media_exit_1"]} {
		for _, leak := range []string{"secretapp", "quoted-token", "description", "trace", "pss", "rss", "state", "pid", "1010123", "providers"} {
			if strings.Contains(text, leak) {
				t.Errorf("%q carries %q", text, leak)
			}
		}
	}
}

// E5: a device-scope report carries no media key and deletes a caller's; session scope deletes a caller's too.
func TestMediaExitsDeviceScope(t *testing.T) {
	status := map[string]string{"media_exits": "99", "media_exit_1": "forged", "media_exit_x": "forged", "keep": "this"}
	called := false
	mergeMediaExits(status, func() string { called = true; return "OK 0 0" }, gmsExitsTestMarker(t, time.Hour), true)
	mediaExitsWantKeys(t, status, map[string]string{})
	if called {
		t.Error("a device-scope report asked the worker")
	}
	if status["keep"] != "this" {
		t.Error("a key of another prefix was deleted")
	}
	session := mediaExitsMerged(t, "OK 0 0", time.Hour, map[string]string{"media_exit_9": "forged", "media_exits": "99"})
	mediaExitsWantKeys(t, session, map[string]string{"media_exits": "0"})
}

// E6: a worker that does not answer costs one honest key.
func TestMediaExitsTimeout(t *testing.T) {
	oldWorker, oldWait := mediaExitsWorker, mediaExitsWait
	release := make(chan struct{})
	t.Cleanup(func() { close(release); mediaExitsWorker, mediaExitsWait = oldWorker, oldWait })
	mediaExitsWorker = func(dest, name, uid string) string { <-release; return "OK 0 0" }
	mediaExitsWait = 20 * time.Millisecond
	status := map[string]string{}
	dest := gmsExitsTestMarker(t, time.Hour)
	mergeMediaExits(status, func() string { return fetchMediaExits(dest, "p", gmsExitsTestUser) }, dest, false)
	mediaExitsWantKeys(t, status, map[string]string{"media_exits": "not-collected-timeout"})
}

// E7: a failed dump (no framework header, or a non-zero exit status) is not-collected-dump, never "no exits".
func TestMediaExitsFailedDump(t *testing.T) {
	good := mediaExitDump([]string{gmsExitRecord("2021-03-05 00:30:01", "10", mediaExitsTestAOSP, "OTHER", "OTHER")}, nil)
	for name, dump := range map[string]string{
		"no framework header": strings.ReplaceAll(good, "ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)\n", ""),
		"rc 1":                strings.Replace(good, "nowhere-dump-rc=0", "nowhere-dump-rc=1", 1),
	} {
		t.Run(name, func(t *testing.T) {
			reply := parseExitInfo(dump, gmsExitsTestUser, mediaExitLabels)
			if !strings.HasPrefix(reply, "ERR-DUMP ") {
				t.Fatalf("reply = %q, want ERR-DUMP", reply)
			}
			mediaExitsWantKeys(t, mediaExitsMerged(t, reply, time.Hour, nil), map[string]string{"media_exits": "not-collected-dump"})
		})
	}
}

// E8: the lift of NWP-20261208-06 is behaviour-neutral for gms. The literals were printed by origin/main's
// parseGmsExits and mergeGmsExits (f46f99be4) for these inputs, before the lift.
func TestMediaExitsGmsGoldenUnchanged(t *testing.T) {
	broken := gmsExitBlockText(gmsExitTimeLine("2021-03-05 00:33:00", "10"), gmsExitProcessLine(gmsExitsTestMain, "OTHER", "OTHER"), "noimportance")
	got := parseGmsExits(gmsExitDump(
		gmsExitRecord("2021-03-05 00:30:01", "10", gmsExitsTestPersistent, "APP CRASH(EXCEPTION)", "UNKNOWN"),
		gmsExitRecord("2021-03-05 00:34:00", "10", gmsExitsTestMain, "USER REQUESTED", "FORCE STOP"),
		gmsExitRecord("2021-03-05 00:31:00", "11", gmsExitsTestMain, "OTHER", "OTHER"),
		gmsExitRecord("2021-03-05 00:32:00", "10", "com.google.android.gms.unstable", "OTHER", "OTHER"),
		broken,
	), gmsExitsTestUser)
	if want := "OK 2 3\nmain reason=USER_REQUESTED sub=FORCE_STOP imp=400 age_s=60\npersistent reason=APP_CRASH_EXCEPTION sub=UNKNOWN imp=400 age_s=299\n"; got != want {
		t.Errorf("parseGmsExits =\n%q\nwant\n%q", got, want)
	}
	status := gmsExitsMerged(t, "OK 3 0\nmain reason=OTHER sub=OTHER imp=400 age_s=100\npersistent reason=OTHER sub=OTHER imp=400 age_s=7200\nmain reason=bad\n",
		time.Hour, map[string]string{"gms_exit_9": "forged"})
	want := map[string]string{"gms_exit_1": "main reason=OTHER sub=OTHER imp=400 age_s=100", "gms_exit_2": "unparsed", "gms_exits": "2", "keep": "this"}
	if fmt.Sprint(status) != fmt.Sprint(want) {
		t.Errorf("mergeGmsExits status = %v, want %v", status, want)
	}
}

func TestMediaExitsLaneAndCap(t *testing.T) {
	if got := laneFor("mediaexits"); got.svc != laneRO.svc {
		t.Errorf("laneFor(mediaexits).svc = %q, want the read-only lane", got.svc)
	}
	if c := workerWaitCap("mediaexits"); c <= 0 || c > mediaExitsWait {
		t.Errorf("workerWaitCap(mediaexits) = %s, want > 0 and <= %s", c, mediaExitsWait)
	}
}

func TestMediaExitsCapKeepsNewest(t *testing.T) {
	var blocks []string
	var want []string
	for i := 0; i < 11; i++ {
		// i = 0 is the oldest, so the reply must hold the records of i = 10 down to i = 3.
		blocks = append(blocks, gmsExitRecord(fmt.Sprintf("2021-03-05 00:%02d:00", 20+i), "10", mediaExitsTestAOSP, "OTHER", "OTHER"))
	}
	for i := 10; i >= 3; i-- {
		want = append(want, fmt.Sprintf("media reason=OTHER sub=OTHER imp=400 age_s=%d", (15-i)*60))
	}
	got := parseExitInfo(mediaExitDump(blocks, nil), gmsExitsTestUser, mediaExitLabels)
	if wantReply := "OK 8 3\n" + strings.Join(want, "\n") + "\n"; got != wantReply {
		t.Errorf("reply =\n%s\nwant\n%s", got, wantReply)
	}
	keys := map[string]string{"media_exits": "8"}
	for i, ln := range want {
		keys[fmt.Sprintf("media_exit_%d", i+1)] = ln
	}
	mediaExitsWantKeys(t, mediaExitsMerged(t, got, 24*365*100*time.Hour, nil), keys)
}

func TestMediaExitsFetchAsksOnlyForADigitUser(t *testing.T) {
	old := mediaExitsWorker
	t.Cleanup(func() { mediaExitsWorker = old })
	var gotName, gotUID string
	mediaExitsWorker = func(dest, name, uid string) string { gotName, gotUID = name, uid; return "OK 0 0" }
	if got := fetchMediaExits(t.TempDir(), "p", "12"); got != "OK 0 0" || gotName != "p" || gotUID != "12" {
		t.Errorf("fetch answered %q and asked (%q, %q)", got, gotName, gotUID)
	}
	gotUID = "unset"
	for _, uid := range []string{"", "1x"} {
		if got := fetchMediaExits(t.TempDir(), "p", uid); got != "" || gotUID != "unset" {
			t.Errorf("uid %q: fetch answered %q and asked uid %q, want no worker call", uid, got, gotUID)
		}
	}
}

// The real handler asks the worker at session scope, a gate preview of the same session asks nothing, and the call
// sits in report_issue.go right after the gms one.
func TestMediaExitsReportHandlerIsWired(t *testing.T) {
	src, err := os.ReadFile("report_issue.go")
	if err != nil {
		t.Fatal(err)
	}
	const call = "\tmergeMediaExits(rep.Status, func() string { return fetchMediaExits(dest, name, uid) }, dest, deviceScope)\n"
	i := strings.Index(string(src), "\tmergeGmsExits(")
	if i < 0 {
		t.Fatal("report_issue.go holds no mergeGmsExits call")
	}
	after := string(src[i:])
	after = after[strings.Index(after, "\n")+1:]
	if j := strings.Index(after, "\n"); j < 0 || !strings.HasPrefix(after[j+1:], call) {
		t.Errorf("report_issue.go: the line after mergeGmsExits (and its comment) is not %q", call)
	}

	old, oldGms, oldUiderrors := mediaExitsWorker, gmsExitsWorker, uiderrorsWorker
	t.Cleanup(func() { mediaExitsWorker, gmsExitsWorker, uiderrorsWorker = old, oldGms, oldUiderrors })
	uiderrorsWorker = func(d, n, u string) string { return "" } // the report's other workers must not wait on a lane
	gmsExitsWorker = func(d, n, u string) string { return "" }
	dest := t.TempDir()
	if err := markRoamSession(dest, "mediaexits-wired", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	asked := 0
	mediaExitsWorker = func(d, name, uid string) string {
		asked++
		if d != dest || name != "mediaexits-wired" || uid != "10" {
			t.Errorf("the worker was asked with (%q, %q, %q)", d, name, uid)
		}
		return "OK 1 0\nmedia reason=USER_REQUESTED sub=FORCE_STOP imp=4 age_s=0\n"
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
	rep := preview(`{"preview":true,"status":{"media_exit_7":"forged"}}`)
	mediaExitsWantKeys(t, rep.Status, map[string]string{"media_exits": "1", "media_exit_1": "media reason=USER_REQUESTED sub=FORCE_STOP imp=4 age_s=0"})
	if asked != 1 {
		t.Errorf("a session report asked the worker %d time(s), want 1", asked)
	}
	rep = preview(`{"preview":true,"gate":true,"status":{"media_exit_7":"forged"}}`)
	mediaExitsWantKeys(t, rep.Status, map[string]string{})
	if asked != 1 {
		t.Errorf("a gate report asked the worker (%d asks in all, want 1)", asked)
	}
}
