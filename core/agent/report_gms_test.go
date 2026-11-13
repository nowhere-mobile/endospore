package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

// NWP-20261201-01. The fixtures follow the print statements of AOSP android15-release and GrapheneOS
// platform_frameworks_base branch 17 (ProcessRecord, ProcessList.dumpProcessOomList, ProcessStateRecord /
// psc/ProcessRecordInternal, ProcessCachedOptimizerRecord). They are not a device dump: none was available.
//
// test-gms-state.sh runs these and convicts each mutant of report_gms.go by the test that names it. The expected words are literals
// on purpose: an assertion against the constant moves with a mutant of that constant.

// So that no older handleReportIssue test waits on a lane.
func init() { gmsStateWorker = func(dest, name, uid string) string { return "" } }

const (
	gmsTestUID = "10"

	gmsFrozenProcs = `Some preamble
  *APP* UID 1010123 ProcessRecord{a1b2c3 4242:com.google.android.gms.persistent/u10a123}
    user #10 uid=1010123 gids={1,2}
    packageList={com.google.android.gms}
    lastActivityTime=-2h5m3s    startUpTime=-1h2m1s500ms    startElapsedTime=-1d5h3m2s10ms
    oom adj: max=1001 curRaw=920 setRaw=920 cur=920 set=920
    curProcState=19 mRepProcState=19 setProcState=19
    lastCompactTime=0 isFreezeExempt=false isPendingFreeze=false isFrozen=true
  *APP* UID 1010123 ProcessRecord{d4e5f6 4300:com.google.android.gms/u10a123}
    user #10 uid=1010123
    lastActivityTime=-1m    startUpTime=-50s    startElapsedTime=-2h10s
    oom adj: max=1001 curRaw=250 setRaw=250 cur=250 set=250
    curProcState=5 mRepProcState=5
    isPendingFreeze=false isFrozen=false
Process LRU list (sorted by oom_adj):
  Proc # 1: not an oom entry here com.google.android.gms.persistent/u10a123 (decoy)
`
	gmsFrozenOom = `Process OOM control:
    Proc #12: cch+20  b/ /CEM  ---- t: 0 4242:com.google.android.gms.persistent/u10a123 (cch-empty)
    Proc # 3: vis     b/ /BTOP ---- t: 0 4300:com.google.android.gms/u10a123 (service)
        com.google.android.gms/.Foo<=Proc{4242:com.google.android.gms.persistent/u10a123}
    Proc #   4: cch   b/ /CEM  ---- t: 0 4400:com.example.chat/u10a55 (cch-empty)
`
	gmsHealthyOom = `Process OOM control:
    Proc # 7: prcp    b/ /FGS  ---- t: 0 4242:com.google.android.gms.persistent/u10a123 (service)
        com.google.android.gms/.GmsCorePersistentService<=Proc{5000:app.grapheneos.gmscompat/u10a200}
    PERS #30: sys     F/ /PER  LCMN t: 0 900:system/1000 (fixed)
`
)

func gmsTestDump(procs, procsRC, oom, oomRC string) string {
	s := "== processes\n" + procs
	if procsRC != "" {
		s += "\nnowhere-dump-rc=" + procsRC + "\n"
	}
	s += "== oom\n" + oom
	if oomRC != "" {
		s += "\nnowhere-dump-rc=" + oomRC + "\n"
	}
	return s
}

func gmsTestKeys(t *testing.T, reply string) map[string]string {
	t.Helper()
	lines := strings.Split(reply, "\n")
	if !strings.HasPrefix(lines[0], "OK ") {
		t.Fatalf("reply is not OK: %q", reply)
	}
	out := map[string]string{"count": strings.TrimPrefix(lines[0], "OK ")}
	for _, ln := range lines[1:] {
		if ln == "--" {
			return out
		}
		k, v, _ := strings.Cut(ln, "=")
		out[k] = v
	}
	t.Fatalf("reply has no -- separator: %q", reply)
	return nil
}

func gmsTestExcerpt(reply string) string {
	_, ex, _ := strings.Cut(reply, "\n--\n")
	return ex
}

func TestGmsStateFrozenSession(t *testing.T) {
	reply := parseGmsState(gmsTestDump(gmsFrozenProcs, "0", gmsFrozenOom, "0"), gmsTestUID)
	want := map[string]string{
		"count":                        "2",
		"gms_persistent_adj":           "920",
		"gms_persistent_procstate":     "CEM",
		"gms_persistent_frozen":        "yes",
		"gms_persistent_started_s_ago": "104582",
		"gms_persistent_held_by":       "none",
		"gms_main_adj":                 "250",
		"gms_main_procstate":           "BTOP",
		"gms_main_frozen":              "no",
		"gms_main_started_s_ago":       "7210",
	}
	if got := gmsTestKeys(t, reply); !reflect.DeepEqual(got, want) {
		t.Errorf("frozen session keys\n got %v\nwant %v", got, want)
	}
	ex := gmsTestExcerpt(reply)
	for _, keep := range []string{"oom adj: max=1001 curRaw=920", "isFrozen=true", "startElapsedTime=-1d5h3m2s10ms", "Proc #12:", "curProcState=19"} {
		if !strings.Contains(ex, keep) {
			t.Errorf("excerpt lost %q:\n%s", keep, ex)
		}
	}
	for _, gone := range []string{"packageList", "gids=", "Some preamble", "decoy"} {
		if strings.Contains(ex, gone) {
			t.Errorf("excerpt holds %q, which is on no allowlist:\n%s", gone, ex)
		}
	}
}

func TestGmsStateHealthyHeldByGmsCompat(t *testing.T) {
	procs := strings.Replace(gmsFrozenProcs, "isFrozen=true", "isFrozen=false", 1)
	keys := gmsTestKeys(t, parseGmsState(gmsTestDump(procs, "0", gmsHealthyOom, "0"), gmsTestUID))
	if keys["gms_persistent_held_by"] != "gmscompat" || keys["gms_persistent_frozen"] != "no" || keys["gms_persistent_procstate"] != "FGS" {
		t.Errorf("healthy session keys: %v", keys)
	}
	if keys["gms_main_procstate"] != "absent" {
		t.Errorf("main has no oom entry here, procstate must be absent: %v", keys)
	}
}

// Decoy records come FIRST, so a parser with no user filter takes them.
func TestGmsStateOtherUsersAndAppsIgnored(t *testing.T) {
	const decoyProcs = `  *APP* UID 10123 ProcessRecord{111 11:com.google.android.gms.persistent/u0a123}
    oom adj: max=1001 curRaw=1 setRaw=1 cur=111 set=1
    MARKER-OTHER-USER isFrozen=false
  *APP* UID 1110123 ProcessRecord{222 22:com.google.android.gms.persistent/u11a123}
    oom adj: max=1001 curRaw=1 setRaw=1 cur=222 set=1
  *APP* UID 1099123 ProcessRecord{333 33:com.google.android.gms.persistent/u10a123i4}
    oom adj: max=1001 curRaw=1 setRaw=1 cur=333 set=1
  *APP* UID 1010124 ProcessRecord{444 44:com.google.android.gms.unstable/u10a123}
    oom adj: max=1001 curRaw=1 setRaw=1 cur=444 set=1
  *APP* UID 1010055 ProcessRecord{555 55:com.example.chat/u10a55}
    oom adj: max=1001 curRaw=1 setRaw=1 cur=555 set=1
    MARKER-OTHER-APP isFrozen=true
`
	const decoyOom = `    Proc # 1: fg b/ /TOP  ---- t: 0 11:com.google.android.gms.persistent/u0a123 (top)
    Proc # 2: fg b/ /TOP  ---- t: 0 22:com.google.android.gms.persistent/u11a123 (top)
        com.example.other/.Svc<=Proc{9:com.example.other/u11a9}
`
	reply := parseGmsState(gmsTestDump(decoyProcs+gmsFrozenProcs, "0", decoyOom+gmsFrozenOom, "0"), gmsTestUID)
	keys := gmsTestKeys(t, reply)
	if keys["gms_persistent_adj"] != "920" || keys["gms_persistent_procstate"] != "CEM" || keys["gms_persistent_held_by"] != "none" {
		t.Errorf("a decoy record was read: %v", keys)
	}
	for _, leak := range []string{"MARKER-OTHER", "com.example", "unstable", "/u11a", "/u0a", "cur=111", "cur=222", "cur=333", "cur=444", "cur=555"} {
		if strings.Contains(reply, leak) {
			t.Errorf("reply holds %q from a record it must drop:\n%s", leak, reply)
		}
	}

	onlyDecoys := gmsTestKeys(t, parseGmsState(gmsTestDump(decoyProcs, "0", decoyOom, "0"), gmsTestUID))
	if onlyDecoys["count"] != "0" || onlyDecoys["gms_persistent_adj"] != "absent" {
		t.Errorf("only other users' and apps' records: must read absent: %v", onlyDecoys)
	}
}

func TestGmsStateUnreadDump(t *testing.T) {
	procKeys := []string{"gms_persistent_adj", "gms_persistent_frozen", "gms_persistent_started_s_ago", "gms_main_adj", "gms_main_frozen", "gms_main_started_s_ago"}
	oomKeys := []string{"gms_persistent_procstate", "gms_persistent_held_by", "gms_main_procstate"}
	for _, tc := range []struct {
		label        string
		procRC       string
		oomRC        string
		unreadKeys   []string
		unaffected   string
		unaffectedIs string
	}{
		{"processes rc 1", "1", "0", procKeys, "gms_persistent_procstate", "CEM"},
		{"processes no rc line", "", "0", procKeys, "gms_persistent_procstate", "CEM"},
		{"oom rc 1", "0", "1", oomKeys, "gms_persistent_adj", "920"},
		{"oom no rc line", "0", "", oomKeys, "gms_persistent_adj", "920"},
	} {
		reply := parseGmsState(gmsTestDump(gmsFrozenProcs, tc.procRC, gmsFrozenOom, tc.oomRC), gmsTestUID)
		keys := gmsTestKeys(t, reply)
		for _, k := range tc.unreadKeys {
			if keys[k] != "unread" {
				t.Errorf("%s: %s = %q, want unread", tc.label, k, keys[k])
			}
		}
		if keys[tc.unaffected] != tc.unaffectedIs {
			t.Errorf("%s: %s = %q, want %q from the dump that was read", tc.label, tc.unaffected, keys[tc.unaffected], tc.unaffectedIs)
		}
	}
	// A dump that did not run shows nothing in the excerpt either.
	if ex := gmsTestExcerpt(parseGmsState(gmsTestDump(gmsFrozenProcs, "1", gmsFrozenOom, "1"), gmsTestUID)); strings.TrimSpace(ex) != "" {
		t.Errorf("an unread dump reached the excerpt:\n%s", ex)
	}
}

func TestGmsStateMissingOrMalformedFieldIsUnparsed(t *testing.T) {
	for _, tc := range []struct {
		label, old, new, key string
		inOom                bool
	}{
		{"no oom adj line", "    oom adj: max=1001 curRaw=920 setRaw=920 cur=920 set=920\n", "", "gms_persistent_adj", false},
		{"adj not a number", "curRaw=920 setRaw=920 cur=920 set=920", "curRaw=920 setRaw=920 cur=abc set=920", "gms_persistent_adj", false},
		{"no isFrozen", "isPendingFreeze=false isFrozen=true", "isPendingFreeze=false", "gms_persistent_frozen", false},
		{"isFrozen not a bool", "isFrozen=true", "isFrozen=maybe", "gms_persistent_frozen", false},
		{"no start time", "    startElapsedTime=-1d5h3m2s10ms", "", "gms_persistent_started_s_ago", false},
		{"start time unset", "startElapsedTime=-1d5h3m2s10ms", "startElapsedTime=--", "gms_persistent_started_s_ago", false},
		{"start time in the future", "startElapsedTime=-1d5h3m2s10ms", "startElapsedTime=+5m", "gms_persistent_started_s_ago", false},
		{"start time garbage", "startElapsedTime=-1d5h3m2s10ms", "startElapsedTime=-5x", "gms_persistent_started_s_ago", false},
		{"start time overflow", "startElapsedTime=-1d5h3m2s10ms", "startElapsedTime=-99999999999999999999d", "gms_persistent_started_s_ago", false},
		{"state empty", "b/ /CEM  ----", "b/ /  ----", "gms_persistent_procstate", true},
		{"state unknown", "b/ /CEM  ----", "b/ /??  ----", "gms_persistent_procstate", true},
	} {
		procs, oom := gmsFrozenProcs, gmsFrozenOom
		if tc.inOom {
			oom = strings.Replace(oom, tc.old, tc.new, 1)
		} else {
			procs = strings.Replace(procs, tc.old, tc.new, 1)
		}
		if procs == gmsFrozenProcs && oom == gmsFrozenOom {
			t.Fatalf("%s: the fixture edit did not apply", tc.label)
		}
		if got := gmsTestKeys(t, parseGmsState(gmsTestDump(procs, "0", oom, "0"), gmsTestUID))[tc.key]; got != "unparsed" {
			t.Errorf("%s: %s = %q, want unparsed", tc.label, tc.key, got)
		}
	}
}

func TestGmsStateAgeForms(t *testing.T) {
	for in, want := range map[string]string{"0": "0", "-500ms": "0", "-2s10ms": "2", "-5m": "300", "-1h1m1s": "3661", "-1d": "86400"} {
		if got, ok := gmsAgoSeconds(in); !ok || got != want {
			t.Errorf("gmsAgoSeconds(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "-", "--", "+5m", "5m", "-1x"} {
		if got, ok := gmsAgoSeconds(in); ok {
			t.Errorf("gmsAgoSeconds(%q) = %q, want not ok", in, got)
		}
	}
}

func TestGmsStateAdjSourceRewritten(t *testing.T) {
	oom := func(line string) string {
		return "    Proc # 7: prcp    b/ /FGS  ---- t: 0 4242:com.google.android.gms.persistent/u10a123 (service)\n" + line + "\n"
	}
	reply := parseGmsState(gmsTestDump(gmsFrozenProcs, "0", oom("        com.example.chat/.Pusher<=Proc{7:com.example.chat/u10a55}"), "0"), gmsTestUID)
	if got := gmsTestKeys(t, reply)["gms_persistent_held_by"]; got != "other" {
		t.Errorf("held_by = %q, want other", got)
	}
	if strings.Contains(reply, "com.example.chat") {
		t.Errorf("the other app's package reached the reply:\n%s", reply)
	}
	if !strings.Contains(gmsTestExcerpt(reply), "        <app><=<app>") {
		t.Errorf("the <= line was not rewritten:\n%s", gmsTestExcerpt(reply))
	}

	reply = parseGmsState(gmsTestDump(gmsFrozenProcs, "0", oom("        com.google.android.gms/.P<=Proc{5:com.google.android.gmsfoo/u10a5}"), "0"), gmsTestUID)
	if strings.Contains(reply, "gmsfoo") || !strings.Contains(reply, "com.google.android.gms/.P<=<app>") {
		t.Errorf("a look-alike package was kept, or the target lost:\n%s", reply)
	}

	reply = parseGmsState(gmsTestDump(gmsFrozenProcs, "0", oom("        com.google.android.gms/.P<={null}"), "0"), gmsTestUID)
	if got := gmsTestKeys(t, reply)["gms_persistent_held_by"]; got != "unparsed" {
		t.Errorf("held_by with a {null} source = %q, want unparsed", got)
	}
	if !strings.Contains(reply, "com.google.android.gms/.P<={null}") {
		t.Errorf("the fixed word {null} was lost:\n%s", reply)
	}

	reply = parseGmsState(gmsTestDump(gmsFrozenProcs, "0", gmsHealthyOom, "0"), gmsTestUID)
	if !strings.Contains(reply, "com.google.android.gms/.GmsCorePersistentService<=Proc{5000:app.grapheneos.gmscompat/u10a200}") {
		t.Errorf("the GmsCompat binding must stay readable:\n%s", reply)
	}
}

func TestGmsStateExcerptIsBounded(t *testing.T) {
	var b strings.Builder
	b.WriteString("  *APP* UID 1 ProcessRecord{a 1:com.google.android.gms.persistent/u10a1}\n")
	for i := 0; i < 200; i++ {
		b.WriteString("    isFrozen=false\n")
	}
	if n := len(strings.Split(gmsTestExcerpt(parseGmsState(gmsTestDump(b.String(), "0", "", "0"), gmsTestUID)), "\n")); n > gmsMaxExcerptLines+1 {
		t.Errorf("excerpt has %d lines", n)
	}
}

func TestGmsStateBadUidIsAnError(t *testing.T) {
	for _, uid := range []string{"", "1x", "../0"} {
		if got := parseGmsState(gmsTestDump(gmsFrozenProcs, "0", gmsFrozenOom, "0"), uid); !strings.HasPrefix(got, "ERR-UID") {
			t.Errorf("uid %q: reply %q", uid, got)
		}
	}
}

func gmsTestReport(status map[string]string) issueReport {
	return issueReport{Status: status, Logs: map[string][]string{}}
}

func TestGmsStateDeviceScopeCarriesNothing(t *testing.T) {
	rep := gmsTestReport(map[string]string{"gms_persistent_adj": "1", "gms_x": "y", "other": "kept"})
	mergeGmsState(&rep, func() string {
		t.Error("the worker was asked for a device-scope report")
		return "OK 0\n--\n"
	}, true)
	if len(rep.Status) != 1 || rep.Status["other"] != "kept" {
		t.Errorf("status at device scope: %v", rep.Status)
	}
	if _, got := rep.Logs["gms"]; got {
		t.Errorf("device scope has a gms section: %v", rep.Logs["gms"])
	}
}

func TestGmsStateSessionScopeDropsCallerKeys(t *testing.T) {
	rep := gmsTestReport(map[string]string{"gms_persistent_adj": "1", "gms_x": "y"})
	mergeGmsState(&rep, func() string { return parseGmsState(gmsTestDump(gmsFrozenProcs, "0", gmsFrozenOom, "0"), gmsTestUID) }, false)
	if _, got := rep.Status["gms_x"]; got {
		t.Error("a caller-sent gms_x survived at session scope")
	}
	if rep.Status["gms_persistent_adj"] != "920" || rep.Status["gms_state"] != "ok" {
		t.Errorf("status: %v", rep.Status)
	}
}

func TestGmsStateExcerptSurvivesTheScrub(t *testing.T) {
	rep := gmsTestReport(nil)
	mergeGmsState(&rep, func() string { return parseGmsState(gmsTestDump(gmsFrozenProcs, "0", gmsHealthyOom, "0"), gmsTestUID) }, false)
	got := strings.Join(rep.Logs["gms"], "\n")
	for _, want := range []string{"gms: 2 of 2", "com.google.android.gms.persistent/u10a123", "isFrozen=true", "startElapsedTime=-1d5h3m2s10ms", "cur=920", "app.grapheneos.gmscompat"} {
		if !strings.Contains(got, want) {
			t.Errorf("the scrub removed %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, `"`) {
		t.Errorf("a double quote reads as a name to the scrub:\n%s", got)
	}

	rep = gmsTestReport(nil)
	mergeGmsState(&rep, func() string { return "OK 1\ngms_main_adj=1\n--\n  *APP* carol-profile\n" }, false, "carol-profile")
	if got := strings.Join(rep.Logs["gms"], "\n"); strings.Contains(got, "carol-profile") {
		t.Errorf("the profile name reached the section:\n%s", got)
	}
}

func TestGmsStateValuesAreRevalidated(t *testing.T) {
	rep := gmsTestReport(nil)
	mergeGmsState(&rep, func() string {
		return "OK 2\ngms_persistent_adj=hello\ngms_main_adj=-800\ngms_persistent_frozen=yes;rm\ngms_main_frozen=no\n" +
			"gms_persistent_held_by=me\ngms_main_procstate=cem\ngms_persistent_started_s_ago=12a\ngms_extra=1\n--\n"
	}, false)
	for k, want := range map[string]string{
		"gms_persistent_adj": "unparsed", "gms_main_adj": "-800", "gms_persistent_frozen": "unparsed", "gms_main_frozen": "no",
		"gms_persistent_held_by": "unparsed", "gms_main_procstate": "unparsed", "gms_persistent_started_s_ago": "unparsed",
		"gms_persistent_procstate": "unparsed", // missing from the reply
	} {
		if rep.Status[k] != want {
			t.Errorf("%s = %q, want %q", k, rep.Status[k], want)
		}
	}
	if _, got := rep.Status["gms_extra"]; got {
		t.Error("an unknown key in the reply reached the status")
	}
}

func gmsWantNotCollected(t *testing.T, label string, rep issueReport, wantInHead string) {
	t.Helper()
	if rep.Status["gms_state"] != "not-collected" {
		t.Errorf("%s: gms_state = %q", label, rep.Status["gms_state"])
	}
	if len(rep.Logs["gms"]) != 1 {
		t.Fatalf("%s: section %v, want one header", label, rep.Logs["gms"])
	}
	h := rep.Logs["gms"][0]
	if !strings.Contains(h, "gms: NOT collected -- ") || !strings.Contains(h, "does NOT mean Play services was healthy") || !strings.Contains(h, wantInHead) {
		t.Errorf("%s: header %q, want it to hold %q", label, h, wantInHead)
	}
	for k := range rep.Status {
		if strings.HasPrefix(k, "gms_") && k != "gms_state" {
			t.Errorf("%s: %s is set on a report that collected nothing", label, k)
		}
	}
}

func TestGmsStateFailureSaysNotCollected(t *testing.T) {
	for _, tc := range []struct{ label, reply, wantInHead string }{
		{"lane refused", "ERR-LANE", "the worker refused the op"},
		{"empty", "", "the worker returned nothing"},
		{"read error", "ERR-READ the agent printed nothing", "ERR-READ the agent printed nothing"},
		{"no protocol header", "  Proc #1: com.example.chat", "reply was malformed"},
		{"bad count", "OK nine\n--\n", "reply was malformed"},
		{"drop keyword", "ERR-READ the password was wrong", "the reason was withheld by the scrub"},
	} {
		rep := gmsTestReport(nil)
		reply := tc.reply
		mergeGmsState(&rep, func() string { return reply }, false)
		gmsWantNotCollected(t, tc.label, rep, tc.wantInHead)
		if strings.Contains(rep.Logs["gms"][0], "com.example.chat") {
			t.Errorf("%s: a reply with no protocol header was echoed: %q", tc.label, rep.Logs["gms"][0])
		}
	}
	rep := gmsTestReport(nil)
	mergeGmsState(&rep, nil, false)
	gmsWantNotCollected(t, "nil fetch", rep, "no worker was asked")
}

func TestGmsStateFetchIsBounded(t *testing.T) {
	prevWorker, prevWait := gmsStateWorker, gmsStateWait
	t.Cleanup(func() { gmsStateWorker, gmsStateWait = prevWorker, prevWait })
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	gmsStateWorker = func(dest, name, uid string) string { <-release; return "OK 0" }
	gmsStateWait = 20 * time.Millisecond

	rep := gmsTestReport(nil)
	mergeGmsState(&rep, func() string { return fetchGmsState("d", "n", "10") }, false)
	gmsWantNotCollected(t, "timeout", rep, "ERR-TIMEOUT")

	called := false
	gmsStateWorker = func(dest, name, uid string) string { called = true; return "" }
	if got := fetchGmsState("d", "", "10"); !strings.HasPrefix(got, "ERR-NOSESSION") || called {
		t.Errorf("no profile: reply %q, worker called %v", got, called)
	}
}

func TestGmsStateReachesTheReportOnlyInSession(t *testing.T) {
	var calls [][3]string
	prev := gmsStateWorker
	t.Cleanup(func() { gmsStateWorker = prev })
	gmsStateWorker = func(d, n, u string) string {
		calls = append(calls, [3]string{d, n, u})
		return parseGmsState(gmsTestDump(gmsFrozenProcs, "0", gmsFrozenOom, "0"), gmsTestUID)
	}
	dest := rcSetup(t, "gmsprof1705", gmsTestUID)
	rep := rcPreview(t, dest, `{"preview":true,"status":{"gms_persistent_adj":"1","gms_x":"y"}}`)
	if want := [][3]string{{dest, "gmsprof1705", gmsTestUID}}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("worker calls %v, want %v", calls, want)
	}
	if rep.Status["gms_state"] != "ok" || rep.Status["gms_persistent_adj"] != "920" || rep.Status["gms_persistent_frozen"] != "yes" {
		t.Errorf("status: %v", rep.Status)
	}
	if _, got := rep.Status["gms_x"]; got {
		t.Error("a caller-sent gms_x survived")
	}
	if len(rep.Logs["gms"]) == 0 {
		t.Error("the report has no gms section")
	}

	calls = nil
	rep = rcPreview(t, dest, `{"preview":true,"gate":true,"status":{"gms_persistent_adj":"1"}}`)
	if len(calls) != 0 {
		t.Errorf("a gate report asked the worker: %v", calls)
	}
	for k := range rep.Status {
		if strings.HasPrefix(k, "gms_") {
			t.Errorf("a gate report has %s", k)
		}
	}
	if _, got := rep.Logs["gms"]; got {
		t.Error("a gate report has a gms section")
	}
}

func TestGmsStateRidesTheReadOnlyLane(t *testing.T) {
	if got := laneFor("gmsstate"); got.svc != laneRO.svc {
		t.Errorf("gmsstate rides %q, want the read-only lane", got.svc)
	}
	if workerWaitCap("gmsstate") <= 0 {
		t.Error("gmsstate must have a bounded slot wait: an unbounded one hangs the report preview behind a seal")
	}
}

// The worker side and the daemon side are one protocol held in two files; pin that they still name each other, and
// that the report trims the section, runs the merge before its trim, and sends the section to the worker with no
// passphrase. (test-gms-state.sh runs the shell side itself.)
func TestGmsStateWorkerOpIsWired(t *testing.T) {
	b, err := os.ReadFile("../vendor-common/bin/nowhere_roamd.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"|gmsstate) ;;", "  gmsstate)\n", `"$AGENT" gmsstate "$uid" > "$RES.part"`} {
		if !strings.Contains(string(b), want) {
			t.Errorf("nowhere_roamd.sh lost %q -- every report would say NOT collected", want)
		}
	}
	m, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(m), `case "gmsstate": // gmsstate <uid>`) {
		t.Error("main.go has no gmsstate subcommand -- roamd would run an agent that does not know the op")
	}
	r, err := os.ReadFile("report_issue.go")
	if err != nil {
		t.Fatal(err)
	}
	_, handler, found := strings.Cut(string(r), "func handleReportIssue(")
	if !found {
		t.Fatal("report_issue.go has no handleReportIssue")
	}
	crashes, gms, trim := strings.Index(handler, "mergeCrashes(&rep"), strings.Index(handler, "mergeGmsState(&rep"), strings.Index(handler, "trimIssueReport(&rep)")
	if crashes < 0 || gms < crashes || trim < gms {
		t.Errorf("handleReportIssue must call mergeCrashes, mergeGmsState, trimIssueReport in that order: %d %d %d", crashes, gms, trim)
	}
	g, err := os.ReadFile("report_gms.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(g), `triggerRoamWorker(dest, "gmsstate", name, "", uid, "", nil)`) {
		t.Error("the gmsstate request must carry no passphrase: the read-only lane refuses one")
	}
	at := -1
	for i, k := range issueTrimOrder {
		if k == "gms" {
			at = i
		}
	}
	if at < 0 || at+1 >= len(issueTrimOrder) || issueTrimOrder[at+1] != "uiderrors" {
		t.Errorf("issueTrimOrder must list gms just before uiderrors: %v", issueTrimOrder)
	}
}
