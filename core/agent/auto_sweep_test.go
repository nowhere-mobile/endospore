package main

import (
	"bufio"
	"io"
	"net"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261005-01: the #130 auto sweep holds the periodic seal back (auto_sweep.go).

func TestSweepDeferReason(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	began := now.Add(-5 * time.Minute)
	live := now.Add(time.Minute)
	cases := []struct {
		name          string
		until, began  time.Time
		lastSealStart int64
		want          string
	}{
		{"no sweep", time.Time{}, time.Time{}, 0, ""},
		{"live sweep, no seal this session", live, began, 0, "auto-sweep"},
		{"lease lapsed (chooser died)", now.Add(-time.Second), began, 0, ""},
		{"lease ends exactly now", now, began, 0, ""},
		{"live, held for the full gap since it began", live, now.Add(-autoSweepMaxSealGap), 0, ""},
		{"live, last seal before the sweep -> gap counts from the sweep", live, began, began.Add(-time.Hour).Unix(), "auto-sweep"},
		{"live, a seal ran recently -> hold", live, now.Add(-2 * time.Hour), now.Add(-10 * time.Minute).Unix(), "auto-sweep"},
		{"live, the last seal started a full gap ago -> let one through", live, now.Add(-2 * time.Hour), now.Add(-autoSweepMaxSealGap).Unix(), ""},
	}
	for _, c := range cases {
		if got := sweepDeferReason(now, c.until, c.began, c.lastSealStart, autoSweepMaxSealGap); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// sweepState sets and restores the globals the periodic decision reads.
func sweepState(t *testing.T) {
	t.Helper()
	pendingReapMu.Lock()
	pu, pb, po, pl, pr := autoSweepUntil, autoSweepBegan, odMaterializeUntil, loginSettleUntil, autoSweepRuns
	autoSweepUntil, autoSweepBegan, odMaterializeUntil, loginSettleUntil, autoSweepRuns = time.Time{}, time.Time{}, time.Time{}, time.Time{}, 0
	ps0, phe, pls, psh := sealsHeldSince, holdsEndedAt, odLeases, sealHoldValue // NWP-20261011-01: what both holds read
	sealsHeldSince, holdsEndedAt, odLeases, sealHoldValue = time.Time{}, time.Time{}, map[string]time.Time{}, ""
	poc := autoSweepOutcomeCounts // NWP-20261113-16
	autoSweepOutcomeCounts = [len(autoSweepOutcomeTokens)]int{}
	pendingReapMu.Unlock()
	ps := lastSealStartedAt.Load()
	lastSealStartedAt.Store(0)
	t.Cleanup(func() {
		pendingReapMu.Lock()
		autoSweepUntil, autoSweepBegan, odMaterializeUntil, loginSettleUntil, autoSweepRuns = pu, pb, po, pl, pr
		sealsHeldSince, holdsEndedAt, odLeases, sealHoldValue = ps0, phe, pls, psh
		autoSweepOutcomeCounts = poc
		pendingReapMu.Unlock()
		lastSealStartedAt.Store(ps)
	})
}

func periodicNow(t *testing.T) string {
	t.Helper()
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return periodicSealDeferReason(time.Now(), false)
}

func TestAutoSweepHoldsThePeriodicSealAndReleasesIt(t *testing.T) {
	sweepState(t)
	if r := periodicNow(t); r != "" {
		t.Fatalf("control: no sweep, nothing else -> %q, want \"\"", r)
	}
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 1 replied %q", got)
	}
	if r := periodicNow(t); r != "auto-sweep" {
		t.Fatalf("during a sweep the periodic seal reads %q, want auto-sweep", r)
	}
	// The shared guards keep precedence: a materialise window still names itself.
	pendingReapMu.Lock()
	odMaterializeUntil = time.Now().Add(time.Minute)
	pendingReapMu.Unlock()
	if r := periodicNow(t); r != "materialise" {
		t.Errorf("a live materialise window read %q, want materialise (shared guards first)", r)
	}
	pendingReapMu.Lock()
	odMaterializeUntil = time.Time{}
	pendingReapMu.Unlock()
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n0\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 0 replied %q", got)
	}
	if r := periodicNow(t); r != "" {
		t.Errorf("after the sweep ended the periodic seal still reads %q", r)
	}
}

func TestAutoSweepNeverHoldsTheSharedGuardsPath(t *testing.T) {
	// "Back up now" and the logoff seal use syncDeferReason alone: a sweep must not appear there.
	sweepState(t)
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n")
	pendingReapMu.Lock()
	r := syncDeferReason(time.Now(), false, odMaterializeUntil, loginSettleUntil, 0)
	pendingReapMu.Unlock()
	if r != "" {
		t.Errorf("syncDeferReason reads %q during a sweep -- a manual backup or a logoff would be held", r)
	}
}

func TestAutoSweepRenewOnlyExtendsALiveLease(t *testing.T) {
	sweepState(t)
	now := time.Now()
	renewAutoSweep(now)
	pendingReapMu.Lock()
	started := !autoSweepUntil.IsZero()
	pendingReapMu.Unlock()
	if started {
		t.Fatal("a MATERIALIZE-APP with no sweep live STARTED one -- every tap would hold seals for the lease")
	}
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n")
	later := now.Add(5 * time.Minute)
	renewAutoSweep(later)
	pendingReapMu.Lock()
	until := autoSweepUntil
	pendingReapMu.Unlock()
	if !until.Equal(later.Add(autoSweepLease)) {
		t.Errorf("renew left the lease at %v, want %v", until, later.Add(autoSweepLease))
	}
}

func TestAutoSweepRefusesABadArgument(t *testing.T) {
	sweepState(t)
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\nyes\n"); got != "ERR-ARG" {
		t.Errorf("reply %q, want ERR-ARG", got)
	}
	if r := periodicNow(t); r != "" {
		t.Errorf("a refused argument started a hold: %q", r)
	}
}

func TestAutoSweepEndWithoutABeginIsHarmless(t *testing.T) {
	sweepState(t)
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n0\n"); got != "OK" {
		t.Errorf("reply %q, want OK", got)
	}
}

func TestMarkSessionClearsAPreviousSessionsSweep(t *testing.T) {
	sweepState(t)
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n")
	markSession(t.TempDir(), "alice", "pw")
	if r := periodicNow(t); r != "" {
		t.Errorf("a new sign-in inherited the previous session's sweep hold: %q", r)
	}
}

// The periodic loop must use the combined decision; the hold is invisible otherwise.
func TestSyncLoopUsesThePeriodicDecision(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if !strings.Contains(src, "func syncLoop(") {
		t.Fatal("control failed: no syncLoop in main.go, so this check proves nothing")
	}
	i := strings.Index(src, "func syncLoop(")
	j := strings.Index(src[i:], "\n}\n")
	if j < 0 || !strings.Contains(src[i:i+j], "reason = periodicSealDeferReason(time.Now(), inFlEff)") {
		t.Error("syncLoop no longer decides through periodicSealDeferReason -- the auto-sweep hold would never apply")
	}
}

// NWP-20261005-02: GET-SWEEP, which the idle cold lock asks before waiting for installs.
func TestGetSweepReportsTheLease(t *testing.T) {
	sweepState(t)
	if got := evictConn(t, t.TempDir(), "GET-SWEEP\n"); got != "NONE" {
		t.Fatalf("no sweep: reply %q, want NONE", got)
	}
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n")
	if got := evictConn(t, t.TempDir(), "GET-SWEEP\n"); !strings.HasPrefix(got, "LIVE ") {
		t.Fatalf("live sweep: reply %q, want LIVE <secs>", got)
	}
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n0\n")
	if got := evictConn(t, t.TempDir(), "GET-SWEEP\n"); got != "NONE" {
		t.Errorf("after the sweep ended: reply %q, want NONE -- the lock would keep waiting for nothing", got)
	}
}

// A lapsed lease (a chooser that died mid-sweep) must read as no sweep, or the lock waits on a corpse.
func TestSweepLiveFor(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	if live, _ := sweepLiveFor(now, time.Time{}, time.Time{}); live {
		t.Error("no lease read as live")
	}
	if live, _ := sweepLiveFor(now, now.Add(-time.Second), now.Add(-time.Hour)); live {
		t.Error("a lapsed lease read as live")
	}
	if live, age := sweepLiveFor(now, now.Add(time.Minute), now.Add(-90*time.Second)); !live || age != 90*time.Second {
		t.Errorf("live lease: got (%v, %v), want (true, 1m30s)", live, age)
	}
}

// NWP-20261005-02: two sweeps overlapping (a resume kick during a hand-started one) share the hold; the first to
// end must not release it while the other still runs.
func TestOverlappingSweepsShareTheHold(t *testing.T) {
	sweepState(t)
	d := t.TempDir()
	evictConn(t, d, "AUTO-SWEEP\n1\n")
	evictConn(t, d, "AUTO-SWEEP\n1\n")
	evictConn(t, d, "AUTO-SWEEP\n0\n")
	if r := periodicNow(t); r != "auto-sweep" {
		t.Fatalf("one of two sweeps ended and the hold went with it: %q", r)
	}
	evictConn(t, d, "AUTO-SWEEP\n0\n")
	if r := periodicNow(t); r != "" {
		t.Errorf("both sweeps ended but the hold stayed: %q", r)
	}
}

// A lapsed lease forgets the count of sweeps whose processes died, so the next sweep's END releases the hold.
func TestALapsedLeaseForgetsDeadSweeps(t *testing.T) {
	sweepState(t)
	d := t.TempDir()
	evictConn(t, d, "AUTO-SWEEP\n1\n") // this sweep's process dies: no END ever comes
	pendingReapMu.Lock()
	autoSweepUntil = time.Now().Add(-time.Second) // its lease lapses
	pendingReapMu.Unlock()
	evictConn(t, d, "AUTO-SWEEP\n1\n")
	evictConn(t, d, "AUTO-SWEEP\n0\n")
	if r := periodicNow(t); r != "" {
		t.Errorf("the dead sweep's count kept the hold after the live sweep ended: %q", r)
	}
}

// NWP-20261113-16: AUTO-SWEEP-APP, one app's outcome in a sweep -- one strictly-typed login.log line, no package.

var sweepOutcomeTokens = []string{"installed", "already", "restore-only", "fetch-failed", "install-failed", "stopped", "error", "busy", "needs-play", "older-copy"}

// sweepApp sends one AUTO-SWEEP-APP through the real dispatcher and returns its reply and the stderr it wrote.
func sweepApp(t *testing.T, d, i, n, outcome, ms string) (reply, logged string) {
	t.Helper()
	logged = captureStderr(t, func() {
		reply = evictConn(t, d, "AUTO-SWEEP-APP\n"+i+"\n"+n+"\n"+outcome+"\n"+ms+"\n")
	})
	return reply, logged
}

// sweepLog sends one AUTO-SWEEP verb and returns the "auto sweep" lines it logged.
func sweepLog(t *testing.T, d, arg string) []string {
	t.Helper()
	var reply string
	logged := captureStderr(t, func() { reply = evictConn(t, d, "AUTO-SWEEP\n"+arg+"\n") })
	if reply != "OK" {
		t.Fatalf("AUTO-SWEEP %s replied %q", arg, reply)
	}
	return sweepLines(logged)
}

// sweepLines is the "auto sweep" lines of s, so unrelated stderr noise does not count.
func sweepLines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if strings.Contains(l, "auto sweep ") {
			out = append(out, l)
		}
	}
	return out
}

var sweepEndLine = regexp.MustCompile(`^\[logind\] auto sweep ended after \d+s: periodic seals resume$`)

// sweepEnd ends the last running sweep and returns its outcomes line, after checking the unchanged end line.
func sweepEnd(t *testing.T, d string) string {
	t.Helper()
	lines := sweepLog(t, d, "0")
	if len(lines) != 2 || !sweepEndLine.MatchString(lines[0]) {
		t.Fatalf("AUTO-SWEEP 0 logged %q, want the unchanged end line then the outcomes line", lines)
	}
	return lines[1]
}

func TestAutoSweepAppLogsEachOutcome(t *testing.T) {
	sweepState(t)
	d := t.TempDir()
	for _, tok := range sweepOutcomeTokens {
		reply, logged := sweepApp(t, d, "3", "7", tok, "1234")
		if reply != "OK" {
			t.Errorf("%s: reply %q, want OK", tok, reply)
		}
		want := "[logind] auto sweep app 3/7: " + tok + " in 1234ms"
		if got := sweepLines(logged); len(got) != 1 || got[0] != want {
			t.Errorf("%s: logged %q, want exactly %q", tok, got, want)
		}
	}
	for _, c := range [][3]string{{"1", "1", "0"}, {"9999", "9999", "86400000"}} {
		reply, logged := sweepApp(t, d, c[0], c[1], "installed", c[2])
		want := "[logind] auto sweep app " + c[0] + "/" + c[1] + ": installed in " + c[2] + "ms"
		if got := sweepLines(logged); reply != "OK" || len(got) != 1 || got[0] != want {
			t.Errorf("boundary %v: reply %q, logged %q, want OK and %q", c, reply, got, want)
		}
	}
}

func TestAutoSweepAppRefusesABadRequest(t *testing.T) {
	sweepState(t)
	d := t.TempDir()
	if got := evictConn(t, d, "AUTO-SWEEP\n1\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 1 replied %q", got)
	}
	cases := []struct{ why, i, n, outcome, ms string }{
		{"i=0", "0", "4", "installed", "5"},
		{"i>n", "5", "4", "installed", "5"},
		{"n=10000", "1", "10000", "installed", "5"},
		{"i empty", "", "4", "installed", "5"},
		{"i signed", "+1", "4", "installed", "5"},
		{"negative ms", "1", "4", "installed", "-1"},
		{"non-numeric ms", "1", "4", "installed", "abc"},
		{"ms with a unit", "1", "4", "installed", "5ms"},
		{"signed ms", "1", "4", "installed", "+5"},
		{"ms past a day", "1", "4", "installed", "86400001"},
		{"empty ms", "1", "4", "installed", ""},
		{"unknown token", "1", "4", "unknown", "5"},
		{"token with a space", "1", "4", "installed now", "5"},
		{"token with a trailing space", "1", "4", "installed ", "5"},
		{"token with a leading space", "1", "4", " installed", "5"},
		{"package-shaped token", "1", "4", "com.example.app", "5"},
		{"token in another case", "1", "4", "Installed", "5"},
		{"empty token", "1", "4", "", "5"},
	}
	for _, c := range cases {
		reply, logged := sweepApp(t, d, c.i, c.n, c.outcome, c.ms)
		if reply != "ERR-ARG" {
			t.Errorf("%s: reply %q, want ERR-ARG", c.why, reply)
		}
		if strings.Contains(logged, "auto sweep app") {
			t.Errorf("%s: a refused request logged %q", c.why, logged)
		}
	}
	if got := sweepEnd(t, d); got != "[logind] auto sweep outcomes: none reported" {
		t.Errorf("refused requests were counted: %q", got)
	}
}

// A request cut short answers at once (the reader's EOF), never with a line. Direct call: evictConn never closes
// the client's write side, so a short body there waits out the connection deadline.
func TestAutoSweepAppRefusesATruncatedRequest(t *testing.T) {
	sweepState(t)
	for _, body := range []string{"1\n2\n", "1\n2\ninstalled\n5"} {
		cli, srv := net.Pipe()
		got := make(chan string, 1)
		logged := captureStderr(t, func() {
			go func() { b, _ := io.ReadAll(cli); got <- string(b) }()
			handleAutoSweepApp(srv, bufio.NewReader(strings.NewReader(body)))
			srv.Close()
		})
		select {
		case reply := <-got:
			if strings.TrimRight(reply, "\r\n") != "ERR-ARG" {
				t.Errorf("%q: reply %q, want ERR-ARG", body, reply)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%q: no reply within 3s", body)
		}
		cli.Close()
		if strings.Contains(logged, "auto sweep app") {
			t.Errorf("%q: a truncated request logged %q", body, logged)
		}
	}
}

func TestAutoSweepAppCountsAndTheEndSummarises(t *testing.T) {
	sweepState(t)
	d := t.TempDir()
	sweepLog(t, d, "1")
	// NWP-20261118-05: app 4 met a busy worker lane, so it was never attempted; it counts as busy, not fetch-failed.
	for _, c := range [][2]string{{"1", "installed"}, {"2", "fetch-failed"}, {"3", "installed"}, {"4", "busy"}} {
		if reply, _ := sweepApp(t, d, c[0], "4", c[1], "100"); reply != "OK" {
			t.Fatalf("app %s: reply %q", c[0], reply)
		}
	}
	if got := sweepEnd(t, d); got != "[logind] auto sweep outcomes: installed=2 fetch-failed=1 busy=1" {
		t.Errorf("summary %q, want installed=2 fetch-failed=1 busy=1", got)
	}
	// The end reset the counts: a stray end reports nothing.
	if got := sweepEnd(t, d); got != "[logind] auto sweep outcomes: none reported" {
		t.Errorf("a second end re-reported the counts: %q", got)
	}
	// Two overlapping sweeps: the first end (one still running) prints no outcomes line; the last prints both apps.
	sweepLog(t, d, "1")
	sweepLog(t, d, "1")
	sweepApp(t, d, "1", "2", "already", "7")
	if lines := sweepLog(t, d, "0"); len(lines) != 1 || lines[0] != "[logind] auto sweep ended, 1 still running: seals stay held" {
		t.Errorf("an end with a sweep still running logged %q", lines)
	}
	sweepApp(t, d, "2", "2", "error", "7")
	if got := sweepEnd(t, d); got != "[logind] auto sweep outcomes: already=1 error=1" {
		t.Errorf("overlapping sweeps' summary %q, want already=1 error=1", got)
	}
}

// NWP-20261118-05: "busy" is in the closed set, after every older token, so the summary prints it after them; a token
// that differs from it by case or by a trailing space is refused.
func TestParseSweepAppAcceptsBusy(t *testing.T) {
	i, n, k, ms, ok := parseSweepApp("2", "5", "busy", "300000")
	if !ok || i != 2 || n != 5 || ms != 300000 || k != 7 || autoSweepOutcomeTokens[k] != "busy" {
		t.Errorf("parseSweepApp(2, 5, busy, 300000) = %d %d %d %d %v, want 2 5 7 300000 true", i, n, k, ms, ok)
	}
	for _, bad := range []string{"Busy", "busy ", " busy", "BUSY"} {
		if _, _, _, _, ok := parseSweepApp("2", "5", bad, "300000"); ok {
			t.Errorf("parseSweepApp accepted the outcome %q", bad)
		}
	}
}

// NWP-20261119-15: "needs-play" (a Play client with no Play stack kept its placeholder) is in the closed set at index
// 8, so the summary prints it after every older token. It is no longer last: "older-copy" follows it
// (NWP-20261126-07). A near miss and an unknown token are still refused.
func TestAutoSweepAppAcceptsNeedsPlay(t *testing.T) {
	i, n, k, ms, ok := parseSweepApp("2", "5", "needs-play", "300000")
	if !ok || i != 2 || n != 5 || ms != 300000 || k != 8 || autoSweepOutcomeTokens[k] != "needs-play" {
		t.Errorf("parseSweepApp(2, 5, needs-play, 300000) = %d %d %d %d %v, want 2 5 8 300000 true", i, n, k, ms, ok)
	}
	for _, bad := range []string{"Needs-play", "needs-play ", " needs-play", "needs_play", "needsplay", "nope"} {
		if _, _, _, _, ok := parseSweepApp("2", "5", bad, "300000"); ok {
			t.Errorf("parseSweepApp accepted the outcome %q", bad)
		}
	}
}

// NWP-20261126-07 (h50 #3): "older-copy" (the fetched copy was older than its placeholder, so it was not installed
// and the sweep does not fetch it again this session) is in the closed set, last, so the summary prints it after every
// older token; a case variant, a near miss and an unknown token are refused.
func TestAutoSweepAppAcceptsOlderCopy(t *testing.T) {
	i, n, k, ms, ok := parseSweepApp("2", "5", "older-copy", "300000")
	if !ok || i != 2 || n != 5 || ms != 300000 || k != 9 || autoSweepOutcomeTokens[k] != "older-copy" {
		t.Errorf("parseSweepApp(2, 5, older-copy, 300000) = %d %d %d %d %v, want 2 5 9 300000 true", i, n, k, ms, ok)
	}
	for _, bad := range []string{"Older-copy", "OLDER-COPY", "older-copy ", " older-copy", "older_copy", "oldercopy", "older"} {
		if _, _, _, _, ok := parseSweepApp("2", "5", bad, "300000"); ok {
			t.Errorf("parseSweepApp accepted the outcome %q", bad)
		}
	}
}

func TestAutoSweepAppCountsResetByAFreshHold(t *testing.T) {
	sweepState(t)
	d := t.TempDir()
	sweepLog(t, d, "1")
	sweepApp(t, d, "1", "2", "installed", "10")
	pendingReapMu.Lock()
	autoSweepUntil = time.Now().Add(-time.Second) // the chooser died: its lease lapsed, no END came
	pendingReapMu.Unlock()
	sweepLog(t, d, "1") // a fresh hold
	sweepApp(t, d, "1", "1", "fetch-failed", "10")
	if got := sweepEnd(t, d); got != "[logind] auto sweep outcomes: fetch-failed=1" {
		t.Errorf("summary %q, want fetch-failed=1 -- the dead sweep's count leaked into the fresh one", got)
	}
}

func TestAutoSweepAppWithNoLiveSweepIsNotCounted(t *testing.T) {
	check := func(t *testing.T, d string) {
		t.Helper()
		reply, logged := sweepApp(t, d, "1", "1", "stopped", "10")
		if got := sweepLines(logged); reply != "OK" || len(got) != 1 || got[0] != "[logind] auto sweep app 1/1: stopped in 10ms" {
			t.Fatalf("with no live sweep: reply %q, logged %q, want OK and the line", reply, got)
		}
		if got := sweepEnd(t, d); got != "[logind] auto sweep outcomes: none reported" {
			t.Errorf("summary %q, want none reported -- a line with no live sweep was counted", got)
		}
	}
	t.Run("no lease", func(t *testing.T) {
		sweepState(t)
		check(t, t.TempDir())
	})
	t.Run("lapsed lease", func(t *testing.T) {
		sweepState(t)
		d := t.TempDir()
		sweepLog(t, d, "1")
		pendingReapMu.Lock()
		autoSweepUntil = time.Now().Add(-time.Second)
		runs := autoSweepRuns
		pendingReapMu.Unlock()
		if runs != 1 {
			t.Fatalf("control: %d sweeps running, want 1", runs)
		}
		check(t, d)
	})
}

// The sweep's materialises hold sessionMu for minutes; the per-app line must not queue behind them.
func TestAutoSweepAppAnswersWhileSessionMuIsHeld(t *testing.T) {
	sweepState(t)
	if !concurrentSafeCmd("AUTO-SWEEP-APP") {
		t.Fatal("AUTO-SWEEP-APP is serialised on sessionMu")
	}
	d := t.TempDir()
	sessionMu.Lock() // a materialise in progress
	defer sessionMu.Unlock()
	done := make(chan string, 1)
	go func() { done <- evictConn(t, d, "AUTO-SWEEP-APP\n1\n2\ninstalled\n5\n") }()
	select {
	case got := <-done:
		if got != "OK" {
			t.Fatalf("AUTO-SWEEP-APP replied %q", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("AUTO-SWEEP-APP waited on the session lock a materialise holds")
	}
}
