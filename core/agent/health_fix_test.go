package main

import (
	"strings"
	"testing"
	"time"
)

// NWP-20261201-10: the Fix a health notice offers. The handlers run through the real handleLogin over a recording conn;
// the seams are package vars, so none of these tests may run in parallel. Each test has its own profile name.

const (
	hfRule = "play-push-frozen"
	hfUID  = "13"
	hfPeer = 13*100000 + 10123 // an app of the session's own Android user
)

type hfRun struct{ dest, name, uid, op string }

// hfSetup gives a test a live session for uid (none when uid is ""), a stub worker answering reply, a clock it can
// move and forgotten Fix state. It returns dest, the recorded worker calls and the clock.
func hfSetup(t *testing.T, name, uid string, peer int, reply string) (string, *[]hfRun, *time.Time) {
	t.Helper()
	dest := dsSetup(t, name, uid, peer)
	var runs []hfRun
	now := time.Unix(1800000000, 0)
	prevWorker, prevNow := healthFixWorker, healthFixNow
	t.Cleanup(func() { healthFixWorker, healthFixNow = prevWorker, prevNow })
	healthFixWorker = func(d, n, u, op string) string {
		runs = append(runs, hfRun{d, n, u, op})
		return reply
	}
	healthFixNow = func() time.Time { return now }
	healthFixState.Lock()
	healthFixState.uid, healthFixState.at = "", map[string]time.Time{}
	healthFixState.Unlock()
	return dest, &runs, &now
}

func TestHealthFixRunsPlayrestartForTheSession(t *testing.T) {
	dest, runs, _ := hfSetup(t, "hf-run", hfUID, hfPeer, "OK")
	if got := dsVerb(t, dest, "HEALTH-FIX", hfRule); got != "OK\n" {
		t.Fatalf("HEALTH-FIX answered %q, want OK", got)
	}
	want := hfRun{dest, "hf-run", hfUID, "playrestart"}
	if len(*runs) != 1 || (*runs)[0] != want {
		t.Fatalf("worker runs = %+v, want exactly %+v", *runs, want)
	}
}

// The production worker goes through the real triggerRoamWorker against a fake init. The read-only lane answers
// ERR-LANE to any pass before the request is written, so an honoured start with OK proves the pass was empty.
func TestHealthFixProductionWorkerCarriesNoPass(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, []abPlan{{lane: laneRO, text: "OK"}})
	if out := healthFixWorker(f.dest, "hf-prod", hfUID, "playrestart"); out != "OK" {
		t.Fatalf("the production healthFixWorker answered %q, want OK", out)
	}
	starts := f.snapshot()
	if len(starts) != 1 || starts[0].ignored || starts[0].svc != laneRO.svc || starts[0].reqOp != "playrestart" {
		t.Fatalf("starts = %+v, want one honoured start of %s carrying op playrestart", starts, laneRO.svc)
	}
}

func TestHealthFixUnknownRule(t *testing.T) {
	dest, runs, _ := hfSetup(t, "hf-unknown", hfUID, hfPeer, "OK")
	if got := dsVerb(t, dest, "HEALTH-FIX", "no-such-rule"); got != "ERR-UNKNOWN-RULE\n" {
		t.Fatalf("an unknown id answered %q", got)
	}
	if len(*runs) != 0 {
		t.Fatalf("an unknown id ran the worker: %+v", *runs)
	}
}

func TestHealthFixNoSession(t *testing.T) {
	dest, runs, _ := hfSetup(t, "hf-nosession", "", 10123, "OK")
	if got := dsVerb(t, dest, "HEALTH-FIX", hfRule); got != "ERR-NOSESSION\n" {
		t.Fatalf("no session answered %q", got)
	}
	if len(*runs) != 0 {
		t.Fatalf("no session ran the worker: %+v", *runs)
	}
}

func TestHealthFixCallers(t *testing.T) {
	for _, c := range []struct {
		label string
		peer  int
		want  string
	}{
		{"the session's own user", hfPeer, "OK\n"},
		{"the gate", 10123, "OK\n"},
		{"root", 0, "OK\n"},
		{"another Android user", 14*100000 + 10123, "DENIED\n"},
		{"an unreadable peer", -1, "DENIED\n"},
	} {
		t.Run(c.label, func(t *testing.T) {
			dest, runs, _ := hfSetup(t, "hf-callers", hfUID, c.peer, "OK")
			if got := dsVerb(t, dest, "HEALTH-FIX", hfRule); got != c.want {
				t.Fatalf("peer %d answered %q, want %q", c.peer, got, c.want)
			}
			if wantRuns := map[string]int{"OK\n": 1, "DENIED\n": 0}[c.want]; len(*runs) != wantRuns {
				t.Fatalf("peer %d: %d worker runs, want %d", c.peer, len(*runs), wantRuns)
			}
		})
	}
}

func TestHealthFixNeverSignsOut(t *testing.T) {
	forbidden := map[string]bool{"out": true, "cleanstorage": true, "coldsweep": true, "logscrub": true, "cutoff": true,
		"cutoffwake": true, "sweepmedia": true, "in": true, "armcred": true, "rekey": true, "bootsweep": true, "dropcaches": true}
	if len(healthFixes) == 0 {
		t.Fatal("healthFixes is empty")
	}
	for id, op := range healthFixes {
		if forbidden[op] {
			t.Errorf("rule %s runs %q, a sign-out or reap op: a Fix must never sign out", id, op)
		}
		if got := laneFor(op); got.svc != laneRO.svc {
			t.Errorf("rule %s op %q rides %s, want the read-only lane %s", id, op, got.svc, laneRO.svc)
		}
		if c := workerWaitCap(op); c <= 0 || c > 15*time.Second {
			t.Errorf("rule %s op %q has slot wait %s, want a bound under the receiver's 20 s", id, op, c)
		}
	}
}

func TestHealthFixAnswersWorkerFirstLine(t *testing.T) {
	dest, _, _ := hfSetup(t, "hf-firstline", hfUID, hfPeer, " OK \nsecond\n")
	if got := dsVerb(t, dest, "HEALTH-FIX", hfRule); got != "OK\n" {
		t.Fatalf("HEALTH-FIX answered %q, want the worker's first line", got)
	}
}

func TestGetHealthFixAges(t *testing.T) {
	dest, _, now := hfSetup(t, "hf-ages", hfUID, 10123, "OK")
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "NONE\n" {
		t.Fatalf("before a Fix: %q, want NONE", got)
	}
	if got := dsVerb(t, dest, "HEALTH-FIX", hfRule); got != "OK\n" {
		t.Fatalf("the Fix answered %q", got)
	}
	*now = now.Add(75 * time.Second)
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "75\n" {
		t.Fatalf("75 s after the Fix: %q", got)
	}
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", "no-such-rule"); got != "NONE\n" {
		t.Fatalf("an unknown id: %q, want NONE", got)
	}
	*now = now.Add(-10 * time.Minute)
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "0\n" {
		t.Fatalf("a clock that stepped back: %q, want 0", got)
	}
}

func TestGetHealthFixGateOnly(t *testing.T) {
	dest, _, _ := hfSetup(t, "hf-gateonly", hfUID, hfPeer, "OK")
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "DENIED\n" {
		t.Fatalf("the session's own user asked: %q, want DENIED", got)
	}
}

func TestGetHealthFixNewUIDForgets(t *testing.T) {
	dest, _, _ := hfSetup(t, "hf-forget", hfUID, 10123, "OK")
	if got := dsVerb(t, dest, "HEALTH-FIX", hfRule); got != "OK\n" {
		t.Fatalf("the Fix answered %q", got)
	}
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "0\n" {
		t.Fatalf("after the Fix: %q, want 0", got)
	}
	if err := markRoamSession(dest, "hf-forget2", "pw-hf-forget2", "14", ""); err != nil {
		t.Fatal(err)
	}
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "NONE\n" {
		t.Fatalf("a new session uid: %q, want NONE", got)
	}
	if err := markRoamSession(dest, "hf-forget", "pw-hf-forget", hfUID, ""); err != nil {
		t.Fatal(err)
	}
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "NONE\n" {
		t.Fatalf("back on the old uid: %q, want NONE (the Fix was forgotten)", got)
	}
}

func TestHealthFixBusyIsNotRecorded(t *testing.T) {
	dest, _, _ := hfSetup(t, "hf-busy", hfUID, 10123, workerBusy)
	if got := dsVerb(t, dest, "HEALTH-FIX", hfRule); strings.TrimSpace(got) != workerBusy {
		t.Fatalf("a busy worker answered %q", got)
	}
	if got := dsVerb(t, dest, "GET-HEALTH-FIX", hfRule); got != "NONE\n" {
		t.Fatalf("after a busy Fix: %q, want NONE (am did not run)", got)
	}
}

func TestHealthFixVerbsRunWithoutSessionMu(t *testing.T) {
	for _, v := range []string{"HEALTH-FIX", "GET-HEALTH-FIX"} {
		if !concurrentSafeCmd(v) {
			t.Errorf("%s waits on sessionMu: a Fix would queue behind a seal", v)
		}
	}
}

// TestHealthFixAwaitingArmKeepsTheLockFence: GET-HEALTH may wait for P12a's arm, but only while handleLogin has none.
func TestHealthFixAwaitingArmKeepsTheLockFence(t *testing.T) {
	cases := []struct {
		name                     string
		safe, armed, awaitingArm bool
		want                     bool
	}{
		{"awaiting, no arm yet: no handler to judge", false, false, true, false},
		{"awaiting, armed, not lock-free", false, true, true, true},
		{"awaiting, armed, lock-free", true, true, true, false},
		{"not awaiting, armed, not lock-free", false, true, false, true},
		{"not awaiting, no arm, not lock-free", false, false, false, true},
		{"not awaiting, armed, lock-free", true, true, false, false},
	}
	for _, c := range cases {
		if got := gatePollWaits(c.safe, c.armed, c.awaitingArm); got != c.want {
			t.Errorf("%s: gatePollWaits = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestHealthFixLogsOneLineForAFix(t *testing.T) {
	dest, _, _ := hfSetup(t, "hf-logline", hfUID, hfPeer, "OK")
	log := captureStderr(t, func() { dsVerb(t, dest, "HEALTH-FIX", hfRule) })
	if n := strings.Count(log, "[logind] health fix play-push-frozen -> OK\n"); n != 1 {
		t.Fatalf("health fix log lines = %d in %q, want 1", n, log)
	}
	if strings.Contains(log, "hf-logline") {
		t.Fatalf("the log names the profile: %q", log)
	}
}
