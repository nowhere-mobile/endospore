package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A stray tick must not reach the RO lane from another test's daemon. The tests that want a tick turn this on.
func init() { healthEnabled = false }

// The fixtures below use the shapes that the task and the AOSP dump format state: they are shapes, not a capture.
// curRaw is unlike cur in every one, so an adj read from the wrong field fails.
const (
	oomHead = "ACTIVITY MANAGER RUNNING PROCESSES (dumpsys activity oom)\n  OOM levels:\n    -900: SYSTEM_ADJ\n\n" +
		"  Process OOM control (52 total, non-act at 2, non-svc at 3):\n"
	oomTail      = "\n  mHomeProcess: ProcessRecord{1 1:com.other/u11a9}\n"
	oomOther     = "    Proc # 3: fg     T/A/TOP  LCMNFU  t: 0 2222:com.example.app/u11a200 (top-activity)\n        oom: max=1001 curRaw=0 setRaw=0 cur=0 set=0\n        state: cur=TOP  set=TOP  lastPss=1K\n"
	oomHealthy   = "    Proc # 9: prcp   T/ /BFGS LCMNFU  t: 0 10123:com.google.android.gms.persistent/u11a123 (service)\n        com.google.android.gms/.chimera.GmsCorePersistentService<=Proc{9876:app.grapheneos.gmscompat/u11a88}\n        oom: max=1001 curRaw=250 setRaw=250 cur=200 set=200\n        state: cur=BFGS set=BFGS lastPss=1K\n"
	oomFrozen    = "    Proc #38: cch    B/ /CAC  ----  t: 0 10123:com.google.android.gms.persistent/u11a123 (cch-empty)\n        oom: max=1001 curRaw=999 setRaw=999 cur=920 set=920\n        state: cur=CAC  set=CAC  lastPss=1K\n"
	oomOtherUser = "    Proc #40: cch    B/ /CAC  ----  t: 0 10444:com.google.android.gms.persistent/u12a123 (cch-empty)\n        oom: max=1001 curRaw=999 setRaw=999 cur=950 set=950\n        state: cur=CAC  set=CAC  lastPss=1K\n"
)

func TestParseGmsOom(t *testing.T) {
	section := func(entries ...string) string { return oomHead + strings.Join(entries, "") + oomTail }
	for _, c := range []struct {
		name, dump, uid, want string
	}{
		{"healthy, bound, adj from cur= and not curRaw=", section(oomOther, oomHealthy), "11", "gms adj=200 state=BFGS bound=1"},
		{"the frankel shape", section(oomOther, oomFrozen), "11", "gms adj=920 state=CAC bound=0"},
		{"only another user's gms", section(oomOther, oomOtherUser), "11", "gms ABSENT"},
		{"this user's gms beside another user's", section(oomOtherUser, oomFrozen), "11", "gms adj=920 state=CAC bound=0"},
		{"another user's GmsCompat does not bind", section(strings.Replace(oomHealthy, "gmscompat/u11a88", "gmscompat/u12a88", 1)), "11", "gms adj=200 state=BFGS bound=0"},
		{"a GmsCompat binding of the next entry does not bind", section(oomFrozen, strings.Replace(oomHealthy, "com.google.android.gms.persistent/u11a123", "com.example.other/u11a55", 1)), "11", "gms adj=920 state=CAC bound=0"},
		{"gms named only in another entry's reason line", section(strings.Replace(oomOther, "        oom:", "        com.a/.B<=Proc{1:com.google.android.gms.persistent/u11a123}\n        oom:", 1)), "11", "gms ABSENT"},
		{"a persistent-process header", section(strings.Replace(oomFrozen, "Proc #38", "PERS #38", 1)), "11", "gms adj=920 state=CAC bound=0"},
		{"negative adj", section(strings.Replace(oomFrozen, " cur=920", " cur=-800", 1)), "11", "gms adj=-800 state=CAC bound=0"},
		{"an entry after the section ended", oomHead + oomOther + oomTail + oomFrozen, "11", "gms ABSENT"},
		{"no section", "ACTIVITY MANAGER\n" + oomFrozen, "11", "ERR-PARSE no-section"},
		{"no oom line", section(strings.Replace(oomFrozen, "        oom: max=1001 curRaw=999 setRaw=999 cur=920 set=920\n", "", 1)), "11", "ERR-PARSE no-adj"},
		{"an oom line with only curRaw", section(strings.Replace(oomFrozen, " cur=920 set=920", "", 1)), "11", "ERR-PARSE no-adj"},
		{"a non-numeric adj", section(strings.Replace(oomFrozen, " cur=920", " cur=abc", 1)), "11", "ERR-PARSE no-adj"},
		{"no state line", section(strings.Replace(oomFrozen, "        state: cur=CAC  set=CAC  lastPss=1K\n", "", 1)), "11", "gms adj=920 state=- bound=0"},
		{"an empty uid", section(oomFrozen), "", "ERR-PARSE no-uid"},
		{"a non-numeric uid", section(oomFrozen), "1.", "ERR-PARSE no-uid"},
		{"a dumpsys that printed nothing", "", "11", "ERR-PARSE no-section"},
	} {
		if got := parseGmsOom(c.dump, c.uid); got != c.want {
			t.Errorf("%s: parseGmsOom = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestHealthOomLineLimits(t *testing.T) {
	if got := healthOomLine(strings.NewReader(""), "11"); got != "ERR-PARSE no-section" {
		t.Errorf("empty input: %q", got)
	}
	long := oomHead + strings.Repeat("x", healthOomMaxBytes) + "\n"
	if got := healthOomLine(strings.NewReader(long), "11"); got != "ERR-PARSE too-long" {
		t.Errorf("a dump over the limit: %q, want ERR-PARSE too-long (a cut-off dump must not read as ABSENT)", got)
	}
	if got := healthOomLine(strings.NewReader(oomHead+oomFrozen+oomTail), "11"); got != "gms adj=920 state=CAC bound=0" {
		t.Errorf("a good dump: %q", got)
	}
}

func TestHealthProbeReplyForms(t *testing.T) {
	for _, bad := range []string{"", "ERR-WORKER-BUSY", "ERR-TIMEOUT", "ERR-LANE", "ERR-NOSESSION", "ERR-READ the agent printed nothing",
		"ERR-PARSE no-section", "gms", "gms adj=x state=CAC bound=0", "gms adj=920 state=CAC bound=2",
		"gms adj=920 state=com.example.app bound=0", "gms adj=920 state=CAC bound=0\nextra", "ABSENT"} {
		if p := parseHealthProbeReply(bad); p.measured {
			t.Errorf("%q read as measured: %+v", bad, p)
		}
	}
	if p := parseHealthProbeReply("gms ABSENT\n"); !p.measured || !p.absent {
		t.Errorf("gms ABSENT: %+v", p)
	}
	if p := parseHealthProbeReply("gms adj=-800 state=- bound=1\n"); !p.measured || p.absent || p.adj != -800 || p.state != "-" || !p.bound {
		t.Errorf("a good reply: %+v", p)
	}
}

// ppfBad and ppfGood are one bad and one good measured check. t0 is an arbitrary wall time.
var (
	ppfBad  = healthProbe{measured: true, adj: 920, state: "CAC"}
	ppfGood = healthProbe{measured: true, adj: 200, state: "BFGS", bound: true}
	ppfNone = healthProbe{measured: true, absent: true}
	ppfT0   = time.Unix(1800000000, 0)
)

func ppfFresh() *healthRuleResult { return &healthRuleResult{verdict: healthUnmeasured} }

func TestPlayPushFrozenTimeBoundary(t *testing.T) {
	r := ppfFresh()
	applyPlayPushFrozen(r, ppfBad, ppfT0)
	if r.verdict != healthClear || !r.badSince.Equal(ppfT0) {
		t.Fatalf("first bad check: verdict %s badSince %v", r.verdict, r.badSince)
	}
	applyPlayPushFrozen(r, ppfBad, ppfT0.Add(14*time.Minute+59*time.Second))
	if r.verdict == healthFiring {
		t.Fatal("FIRING at 14m59s of bad checks, want not yet")
	}
	applyPlayPushFrozen(r, ppfBad, ppfT0.Add(15*time.Minute))
	if r.verdict != healthFiring {
		t.Fatalf("at 15m of bad checks: verdict %s, want FIRING", r.verdict)
	}
}

func TestPlayPushFrozenGoodCheckResets(t *testing.T) {
	r := ppfFresh()
	applyPlayPushFrozen(r, ppfBad, ppfT0)
	applyPlayPushFrozen(r, ppfGood, ppfT0.Add(10*time.Minute))
	if r.verdict != healthClear || !r.badSince.IsZero() {
		t.Fatalf("a good check: verdict %s badSince %v", r.verdict, r.badSince)
	}
	applyPlayPushFrozen(r, ppfBad, ppfT0.Add(16*time.Minute))
	if r.verdict == healthFiring {
		t.Fatal("FIRING 6 minutes after a good check: the good check did not reset the run")
	}
	if !r.badSince.Equal(ppfT0.Add(16 * time.Minute)) {
		t.Fatalf("badSince %v, want the first bad check after the good one", r.badSince)
	}
}

func TestPlayPushFrozenCondition(t *testing.T) {
	for _, c := range []struct {
		name string
		p    healthProbe
		bad  bool
	}{
		{"adj 920, bound", healthProbe{measured: true, adj: 920, bound: true}, false},
		{"adj 899, not bound", healthProbe{measured: true, adj: 899}, false},
		{"adj 900, not bound", healthProbe{measured: true, adj: 900}, true},
		{"adj 920, not bound", healthProbe{measured: true, adj: 920}, true},
		{"adj 999, not bound", healthProbe{measured: true, adj: 999}, true},
	} {
		r := ppfFresh()
		applyPlayPushFrozen(r, c.p, ppfT0)
		applyPlayPushFrozen(r, c.p, ppfT0.Add(healthPlayFrozenAfter))
		if got := r.verdict == healthFiring; got != c.bad {
			t.Errorf("%s: verdict %s, want bad=%v", c.name, r.verdict, c.bad)
		}
		if r.fields != true || r.adj != c.p.adj {
			t.Errorf("%s: the measured fields were not kept: %+v", c.name, r)
		}
	}
}

func TestPlayPushFrozenUnmeasuredChangesNothing(t *testing.T) {
	r := ppfFresh()
	applyPlayPushFrozen(r, healthProbe{}, ppfT0)
	if r.verdict != healthUnmeasured || !r.checkedAt.IsZero() || !r.badSince.IsZero() {
		t.Fatalf("an unmeasured first check: %+v", r)
	}
	applyPlayPushFrozen(r, ppfBad, ppfT0)
	before := *r
	applyPlayPushFrozen(r, healthProbe{}, ppfT0.Add(14*time.Minute))
	if *r != before {
		t.Fatalf("an unmeasured check moved the result:\n got %+v\nwant %+v", *r, before)
	}
	applyPlayPushFrozen(r, healthProbe{}, ppfT0.Add(15*time.Minute))
	if r.verdict == healthFiring {
		t.Fatal("an unmeasured check fired the rule")
	}
	applyPlayPushFrozen(r, ppfBad, ppfT0.Add(16*time.Minute))
	if r.verdict != healthFiring {
		t.Fatalf("an unmeasured gap reset the run: verdict %s", r.verdict)
	}
	before = *r
	applyPlayPushFrozen(r, healthProbe{}, ppfT0.Add(20*time.Minute))
	if *r != before {
		t.Fatalf("FIRING did not hold across an unmeasured check: %+v", r)
	}
}

func TestPlayPushFrozenAbsentIsNotApplicable(t *testing.T) {
	r := ppfFresh()
	applyPlayPushFrozen(r, ppfBad, ppfT0)
	applyPlayPushFrozen(r, ppfNone, ppfT0.Add(time.Minute))
	if r.verdict != healthNotApplicable || !r.badSince.IsZero() || r.fields || !r.checkedAt.Equal(ppfT0.Add(time.Minute)) {
		t.Fatalf("ABSENT: %+v", r)
	}
}

func TestPlayPushFrozenFiringEnds(t *testing.T) {
	for name, end := range map[string]struct {
		p    healthProbe
		want string
	}{"good": {ppfGood, healthClear}, "absent": {ppfNone, healthNotApplicable}} {
		r := ppfFresh()
		applyPlayPushFrozen(r, ppfBad, ppfT0)
		applyPlayPushFrozen(r, ppfBad, ppfT0.Add(15*time.Minute))
		applyPlayPushFrozen(r, end.p, ppfT0.Add(20*time.Minute))
		if r.verdict != end.want || !r.badSince.IsZero() {
			t.Errorf("%s: %+v, want verdict %s and badSince cleared", name, r, end.want)
		}
	}
}

func TestPlayPushFrozenClockStepBackHoldsFiring(t *testing.T) {
	r := ppfFresh()
	applyPlayPushFrozen(r, ppfBad, ppfT0)
	applyPlayPushFrozen(r, ppfBad, ppfT0.Add(15*time.Minute))
	applyPlayPushFrozen(r, ppfBad, ppfT0.Add(-time.Hour))
	if r.verdict != healthFiring {
		t.Fatalf("a clock step back ended FIRING: %+v", r)
	}
}

// healthFixture replaces the checks' seams and clears the results, restoring all of them when the test ends. The
// clock it returns is the one healthNow reads.
func healthFixture(t *testing.T, replies ...string) (clock *time.Time, sent *[][3]string, logged *[]string) {
	t.Helper()
	prevEn, prevProbe, prevNow, prevLog, prevState := healthEnabled, healthProbeWorker, healthNow, healthLog, healthState
	t.Cleanup(func() {
		healthEnabled, healthProbeWorker, healthNow, healthLog, healthState = prevEn, prevProbe, prevNow, prevLog, prevState
	})
	c, s, l := ppfT0, [][3]string{}, []string{}
	healthEnabled, healthState = true, nil
	healthNow = func() time.Time { return c }
	healthLog = func(line string) { l = append(l, line) }
	healthProbeWorker = func(dest, name, uid string) string {
		s = append(s, [3]string{dest, name, uid})
		if len(s) > len(replies) {
			return "ERR-TIMEOUT"
		}
		return replies[len(s)-1]
	}
	return &c, &s, &l
}

func healthSession(t *testing.T, dest, name, uid string) {
	t.Helper()
	if err := markRoamSession(dest, name, "pw-"+name, uid, ""); err != nil {
		t.Fatal(err)
	}
}

func TestHealthTickNoSessionSendsNoProbe(t *testing.T) {
	_, sent, _ := healthFixture(t)
	healthState = newHealthResults("31")
	if healthTick(t.TempDir()) || len(*sent) != 0 {
		t.Fatalf("no session: a probe was sent: %v", *sent)
	}
	if healthState != nil {
		t.Fatal("no session: the results were not dropped")
	}
}

func TestHealthTickUidZeroSendsNoProbe(t *testing.T) {
	_, sent, _ := healthFixture(t)
	healthState = newHealthResults("31")
	dest := t.TempDir()
	healthSession(t, dest, "hctest01", "0")
	if healthTick(dest) || len(*sent) != 0 {
		t.Fatalf("uid 0: a probe was sent: %v", *sent)
	}
	if healthState != nil {
		t.Fatal("uid 0: the results were not dropped")
	}
}

func TestHealthTickDisabledSendsNoProbe(t *testing.T) {
	_, sent, _ := healthFixture(t)
	healthEnabled = false
	dest := t.TempDir()
	healthSession(t, dest, "hctest02", "31")
	if healthTick(dest) || len(*sent) != 0 {
		t.Fatalf("disabled: a probe was sent: %v", *sent)
	}
}

func TestHealthTickNewUidStartsFresh(t *testing.T) {
	clock, _, _ := healthFixture(t, "gms adj=920 state=CAC bound=0", "gms adj=920 state=CAC bound=0", "gms adj=920 state=CAC bound=0")
	dest := t.TempDir()
	healthSession(t, dest, "hctest03", "31")
	healthTick(dest)
	*clock = clock.Add(20 * time.Minute)
	healthTick(dest)
	if healthState.results[0].verdict != healthFiring {
		t.Fatalf("the same uid after 20 minutes: %+v", healthState.results[0])
	}
	healthSession(t, dest, "hctest04", "32")
	*clock = clock.Add(5 * time.Minute)
	healthTick(dest)
	if healthState.uid != "32" || healthState.checks != 1 || healthState.results[0].verdict != healthClear || !healthState.results[0].badSince.Equal(*clock) {
		t.Fatalf("a new uid kept the old results: %+v", healthState)
	}
}

func TestHealthTickFeedsTheRuleAndLogsVerdictChanges(t *testing.T) {
	clock, sent, logged := healthFixture(t, "gms adj=200 state=BFGS bound=1", "ERR-WORKER-BUSY", "gms adj=920 state=CAC bound=0", "gms adj=920 state=CAC bound=0", "gms adj=920 state=CAC bound=0", "gms ABSENT")
	dest := t.TempDir()
	name := "hctest05"
	healthSession(t, dest, name, "33")
	for i := 0; i < 2; i++ {
		healthTick(dest)
		*clock = clock.Add(5 * time.Minute)
	}
	healthTick(dest) // the first bad check: CLEAR stays CLEAR
	*clock = clock.Add(17 * time.Minute)
	healthTick(dest) // CLEAR -> FIRING
	*clock = clock.Add(5 * time.Minute)
	healthTick(dest) // FIRING holds
	*clock = clock.Add(5 * time.Minute)
	healthTick(dest) // FIRING -> NOT-APPLICABLE
	if len(*sent) != 6 || (*sent)[0] != [3]string{dest, name, "33"} {
		t.Fatalf("probes: %v", *sent)
	}
	if healthState.checks != 6 {
		t.Fatalf("checks = %d, want 6 (every probe sent)", healthState.checks)
	}
	want := []string{
		"[logind] health play-push-frozen: UNMEASURED -> CLEAR (adj=200 bound=1)",
		"[logind] health play-push-frozen: CLEAR -> FIRING (adj=920 bound=0 bad_for=17m)",
		"[logind] health play-push-frozen: FIRING -> NOT-APPLICABLE",
	}
	if strings.Join(*logged, "\n") != strings.Join(want, "\n") {
		t.Fatalf("login.log lines:\n%s\nwant:\n%s", strings.Join(*logged, "\n"), strings.Join(want, "\n"))
	}
	for _, l := range *logged {
		if strings.Contains(l, name) {
			t.Errorf("a log line names the profile: %s", l)
		}
	}
}

// TestHealthProbeWorkerAsksTheReadOnlyLane runs the real request: the op, the lane and an empty passphrase line.
func TestHealthProbeWorkerAsksTheReadOnlyLane(t *testing.T) {
	dest := t.TempDir()
	got := make(chan string, 1)
	done := make(chan struct{})
	defer close(done)
	go func() {
		for {
			if b, err := os.ReadFile(filepath.Join(dest, laneRO.req)); err == nil && strings.Count(string(b), "\n") >= 7 {
				os.Remove(filepath.Join(dest, laneRO.req))
				os.WriteFile(filepath.Join(dest, laneRO.res), []byte("gms ABSENT\n"), 0o600)
				got <- string(b)
				return
			}
			select {
			case <-done:
				return
			case <-time.After(10 * time.Millisecond):
			}
		}
	}()
	if reply := healthProbeWorker(dest, "hctest06", "34"); strings.TrimSpace(reply) != "gms ABSENT" {
		t.Fatalf("reply %q", reply)
	}
	lines := strings.Split(<-got, "\n")
	if lines[0] != "healthprobe" || lines[1] != "hctest06" || lines[2] != "" || lines[3] != "34" {
		t.Fatalf("request %q, want op healthprobe, this name, an empty pass line and the uid", lines[:4])
	}
}

func TestHealthNowIsWallClock(t *testing.T) {
	if n := healthNow(); n != n.Round(0) {
		t.Fatal("healthNow carries a monotonic reading: elapsed times would exclude suspend (NWP-20260913-18)")
	}
}

func TestHealthEveryAndTheRuleSet(t *testing.T) {
	if healthEvery != 5*time.Minute || healthPlayFrozenAfter != 15*time.Minute {
		t.Fatalf("healthEvery %v, healthPlayFrozenAfter %v", healthEvery, healthPlayFrozenAfter)
	}
	if len(healthRules) != 1 || healthRules[0].id != "play-push-frozen" || healthRules[0].statusKey != "health_play_push_frozen" {
		t.Fatalf("healthRules: %+v", healthRules)
	}
}

func healthVerb(t *testing.T, dest string) string {
	t.Helper()
	c := &dsConn{r: strings.NewReader("GET-HEALTH\n")}
	handleLogin(c, dest)
	return c.out.String()
}

func TestHealthGetHealthDeniesANonGatePeer(t *testing.T) {
	healthFixture(t)
	dest := dsSetup(t, "hctest07", "35", 35*100000+10123)
	healthState = newHealthResults("35")
	if got := healthVerb(t, dest); got != "DENIED\n" {
		t.Fatalf("a roamed app asked: %q, want DENIED", got)
	}
}

func TestHealthGetHealthContract(t *testing.T) {
	clock, _, _ := healthFixture(t)
	dest := dsSetup(t, "hctest08", "36", 10123)
	healthState = newHealthResults("36")
	if got := healthVerb(t, dest); got != "play-push-frozen UNMEASURED -1\n" {
		t.Fatalf("before any measured check: %q", got)
	}
	healthState.results[0].verdict, healthState.results[0].checkedAt = healthFiring, clock.Add(-42*time.Second)
	if got := healthVerb(t, dest); got != "play-push-frozen FIRING 42\n" {
		t.Fatalf("a measured check 42 s ago: %q", got)
	}
	healthState.results[0].checkedAt = clock.Add(time.Hour)
	if got := healthVerb(t, dest); got != "play-push-frozen FIRING 0\n" {
		t.Fatalf("a clock step back: %q, want age 0", got)
	}
}

func TestHealthGetHealthNone(t *testing.T) {
	healthFixture(t)
	dest := dsSetup(t, "hctest09", "37", 10123)
	if got := healthVerb(t, dest); got != "NONE\n" {
		t.Fatalf("no stored results: %q", got)
	}
	healthState = newHealthResults("99")
	if got := healthVerb(t, dest); got != "NONE\n" {
		t.Fatalf("another uid's results: %q", got)
	}
	noSession := dsSetup(t, "hctest10", "", 10123)
	healthState = newHealthResults("37")
	if got := healthVerb(t, noSession); got != "NONE\n" {
		t.Fatalf("no live session: %q", got)
	}
}

func TestHealthGetHealthAnswersWhileSessionMuIsHeld(t *testing.T) {
	healthFixture(t)
	gatePeer(t, 10123)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if got := replyWhileHeld(t, 5*time.Second, "GET-HEALTH\n", "GET-HEALTH"); got != "NONE" {
		t.Fatalf("reply %q", got)
	}
}

func healthBadResult(clock time.Time) healthRuleResult {
	return healthRuleResult{verdict: healthFiring, checkedAt: clock.Add(-30 * time.Second), badSince: clock.Add(-20 * time.Minute),
		fields: true, adj: 920, state: "CAC"}
}

func TestMergeHealthSessionScope(t *testing.T) {
	clock, _, _ := healthFixture(t)
	healthState = newHealthResults("38")
	healthState.checks = 4
	healthState.results[0] = healthBadResult(*clock)
	st := map[string]string{"keep": "k"}
	mergeHealth(st, "38", false)
	if got := st["health_play_push_frozen"]; got != "FIRING age=30 adj=920 state=CAC bound=0 bad_for=1170" {
		t.Errorf("health_play_push_frozen = %q", got)
	}
	if st["health_checks"] != "4" || st["keep"] != "k" {
		t.Errorf("status: %v", st)
	}
	for k, v := range st {
		if k != "keep" && (strings.Contains(v, ".") || strings.Contains(v, "hctest")) {
			t.Errorf("%s holds a name: %q", k, v)
		}
	}
}

func TestMergeHealthKnownFieldsOnly(t *testing.T) {
	clock, _, _ := healthFixture(t)
	healthState = newHealthResults("39")
	for _, c := range []struct {
		r    healthRuleResult
		want string
	}{
		{healthRuleResult{verdict: healthUnmeasured}, "UNMEASURED"},
		{healthRuleResult{verdict: healthNotApplicable, checkedAt: *clock}, "NOT-APPLICABLE age=0"},
		{healthRuleResult{verdict: healthClear, checkedAt: *clock, fields: true, adj: 200, state: "-", bound: true}, "CLEAR age=0 adj=200 bound=1"},
	} {
		healthState.results[0] = c.r
		st := map[string]string{}
		mergeHealth(st, "39", false)
		if got := st["health_play_push_frozen"]; got != c.want {
			t.Errorf("value %q, want %q", got, c.want)
		}
	}
}

func TestMergeHealthAddsNothingAtDeviceScopeOrForAnotherUid(t *testing.T) {
	clock, _, _ := healthFixture(t)
	healthState = newHealthResults("40")
	healthState.results[0] = healthBadResult(*clock)
	for _, c := range []struct {
		uid    string
		device bool
	}{{"40", true}, {"41", false}, {"", false}} {
		st := map[string]string{"keep": "k"}
		mergeHealth(st, c.uid, c.device)
		if len(st) != 1 {
			t.Errorf("uid %q device %v: %v", c.uid, c.device, st)
		}
	}
	mergeHealth(nil, "40", false) // a nil map must not panic
}

func TestMergeHealthRemovesCallerKeysAtEveryScope(t *testing.T) {
	healthFixture(t)
	for _, c := range []struct {
		uid    string
		device bool
	}{{"", true}, {"42", true}, {"42", false}} {
		st := map[string]string{"health_play_push_frozen": "CLEAR", "health_checks": "7", "health_extra": "x", "keep": "k"}
		mergeHealth(st, c.uid, c.device)
		if len(st) != 1 || st["keep"] != "k" {
			t.Errorf("uid %q device %v: %v", c.uid, c.device, st)
		}
	}
}

// TestHealthReachesTheIssueReport is the row's "the results reach the issue report": a real handleReportIssue preview.
func TestHealthReachesTheIssueReport(t *testing.T) {
	clock, _, _ := healthFixture(t)
	dest := dsSetup(t, "hctest11", "43", 43*100000+10123)
	healthState = newHealthResults("43")
	healthState.results[0] = healthBadResult(*clock)
	prevWorker := uiderrorsWorker
	t.Cleanup(func() { uiderrorsWorker = prevWorker })
	uiderrorsWorker = func(string, string, string) string { return "" }
	for _, req := range []string{
		`{"preview":true,"status":{"health_extra":"caller"}}`,
		`{"preview":true,"gate":true,"status":{"health_extra":"caller"}}`,
	} {
		c := &dsConn{r: strings.NewReader("")}
		handleReportIssue(c, dest, req)
		out := c.out.String()
		gate := strings.Contains(req, `"gate":true`)
		if strings.Contains(out, "health_extra") {
			t.Errorf("%s: a caller-sent health_ key survived: %s", req, out)
		}
		if has := strings.Contains(out, `"health_play_push_frozen": "FIRING age=30`); has == gate {
			t.Errorf("%s: health_play_push_frozen present=%v, want %v: %s", req, has, !gate, out)
		}
	}
}

func TestHealthProbeIsWired(t *testing.T) {
	if laneFor("healthprobe").svc != laneRO.svc {
		t.Error("healthprobe must ride the RO lane: a check must not wait behind a seal")
	}
	if workerWaitCap("healthprobe") != 10*time.Second {
		t.Errorf("workerWaitCap(healthprobe) = %v, want 10s", workerWaitCap("healthprobe"))
	}
	if !concurrentSafeCmd("GET-HEALTH") {
		t.Error("GET-HEALTH must be concurrent-safe: the gate must not wait behind a seal for a RAM read")
	}
	m, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(m)
	if n := strings.Count(src, `goSafeLoop("health-check loop", func() { healthLoop(dest) })`); n != 1 {
		t.Errorf("the health-check loop is started %d times, want 1", n)
	}
	start := strings.Index(src, "func loginDaemon(")
	end := strings.Index(src[start:], "\nfunc ")
	if start < 0 || !strings.Contains(src[start:][:end+1], `goSafeLoop("health-check loop"`) {
		t.Error("the health-check loop must start inside loginDaemon")
	}
	if !strings.Contains(src, `case "healthoom":`) {
		t.Error(`main() lost case "healthoom"`)
	}
	b, err := os.ReadFile("../vendor-common/bin/nowhere_roamd.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"|alarmrelay|healthprobe", "\n  healthprobe)\n", `"$AGENT" healthoom "$uid" > "$RES.part"`} {
		if !strings.Contains(string(b), want) {
			t.Errorf("nowhere_roamd.sh lost %q -- every check would be unmeasured", want)
		}
	}
}
