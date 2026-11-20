package main

// NWP-20261210-13: backlog row "After a refused sign-out the session stays signed in, but its On-demand media stays
// detached for the rest of the session". The logoff stops mediad before its media sweep; when that sweep does not
// verify, the session is kept, and its refusal arm now kicks mediad once, after the re-arm, as END-UNSAVED's undo
// does. These tests drive the real handleLogout through cutoffWorker with logoffRefusalKickMediad wrapped by a counter
// that calls the REAL kickMediad; test-logoff-refusal-mediad.sh re-runs them against broken copies of main.go.

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// refusalKick is what the counting hook saw at one call of logoffRefusalKickMediad.
type refusalKick struct {
	markerPresent bool // .roamsession existed in dest
	sealInFlight  bool // the logoff's seal veto was still set
}

// countRefusalKicks wraps logoffRefusalKickMediad: each call is recorded, then handed to the real kickMediad.
func countRefusalKicks(t *testing.T) func() []refusalKick {
	t.Helper()
	var mu sync.Mutex
	var kicks []refusalKick
	old := logoffRefusalKickMediad
	logoffRefusalKickMediad = func(dest string) {
		_, err := os.Stat(filepath.Join(dest, ".roamsession"))
		pendingReapMu.Lock()
		inFlight := sealInFlight
		pendingReapMu.Unlock()
		mu.Lock()
		kicks = append(kicks, refusalKick{err == nil, inFlight})
		mu.Unlock()
		kickMediad(dest)
	}
	t.Cleanup(func() { logoffRefusalKickMediad = old })
	return func() []refusalKick {
		mu.Lock()
		defer mu.Unlock()
		return append([]refusalKick(nil), kicks...)
	}
}

// refusalMainGo is the source the placement test reads: main.go, or the mutant copy the suite names.
func refusalMainGo(t *testing.T) string {
	t.Helper()
	p := os.Getenv("NOWHERE_REFUSAL_MAIN_GO")
	if p == "" {
		p = "main.go"
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestLogoffRefusalKick_KeptSessionGetsMediaBack(t *testing.T) {
	const uid = "1984"
	kicks := countRefusalKicks(t) // registered first, so it is restored after the worker's cleanup joins the logoff
	dest := cutoffSession(t, uid)
	t.Cleanup(resetMediaStuck)
	ops := cutoffWorker(t, dest, map[string]string{"cutoff": "OK 3", "sweepmedia": "ERR-MEDIA-SWEEP 1",
		"cutoffwake": "WAKE OK 3"}, nil)
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	logoffDone(t, uid, 2*time.Minute)
	if got, want := ops(), []string{"cutoff", "sweepmedia", "sweepmedia", "cutoffwake"}; !sameOps(got, want) {
		t.Fatalf("handed roamd %v, want %v -- this test drives the media-sweep refusal arm", got, want)
	}
	got := kicks()
	if len(got) != 1 {
		t.Fatalf("the refusal arm kicked mediad %d time(s), want 1 -- the kept session's media stays detached "+
			"until the next periodic seal's self-heal kick", len(got))
	}
	if !got[0].markerPresent {
		t.Error("the kick ran before the re-arm: .roamsession was absent, so kickMediad stands down")
	}
	if got[0].sealInFlight {
		t.Error("the kick ran before logoffSweepFailed: sealInFlight was still set, so kickMediad stands down")
	}
	// stopMediad removed mediad.req at the start of the logoff, so only the refusal arm's kick can have written it.
	b, err := os.ReadFile(filepath.Join(dest, "mediad.req"))
	if err != nil {
		t.Fatalf("no fresh mediad.req after the refused sign-out: %v -- the real kickMediad stood down or never ran", err)
	}
	if lines := strings.Split(string(b), "\n"); len(lines) < 3 || lines[2] != uid {
		t.Errorf("mediad.req line 3 is not user %s: %q", uid, b)
	}
}

func TestLogoffRefusalKick_LandedSignOutDoesNotKick(t *testing.T) {
	const uid = "1985"
	kicks := countRefusalKicks(t)
	landedLogoffIn(t, uid, "OK 3", nil)
	logoffDone(t, uid, 2*time.Minute)
	if n := len(kicks()); n != 0 {
		t.Fatalf("a sign-out whose seal landed kicked mediad %d time(s) -- that session is reaped", n)
	}
}

func TestLogoffRefusalKick_Placement(t *testing.T) {
	body := stripComments(funcBody(t, refusalMainGo(t), "handleLogout"))
	const kick = "logoffRefusalKickMediad(dest)"
	var at []int
	arm, armEnd, noKeep, noKeepEnd, failed, rearm, ret := -1, -1, -1, -1, -1, -1, -1
	for i, l := range body {
		s := strings.TrimSpace(l)
		if strings.Contains(l, "logoffRefusalKickMediad(") {
			at = append(at, i)
			if s != kick {
				t.Errorf("the kick statement is %q, want %q", s, kick)
			}
		}
		switch {
		case arm < 0 && l == "\t\tif swept != \"OK\" {":
			arm = i
		case arm >= 0 && armEnd < 0 && l == "\t\t}":
			armEnd = i
		case arm >= 0 && armEnd < 0 && noKeep < 0 && strings.HasPrefix(s, "if noKeep {"):
			noKeep = i
		case noKeep >= 0 && noKeepEnd < 0 && l == "\t\t\t}":
			noKeepEnd = i
		case arm >= 0 && armEnd < 0 && s == "logoffSweepFailed(name, uid)":
			failed = i
		case arm >= 0 && armEnd < 0 && strings.Contains(s, `"logout media sweep did not verify, re-arm")`):
			rearm = i
		case arm >= 0 && armEnd < 0 && l == "\t\t\treturn":
			ret = i
		}
	}
	if arm < 0 || armEnd < 0 || noKeep < 0 || noKeepEnd < 0 || failed < 0 || rearm < 0 || ret < 0 {
		t.Fatalf("the refusal arm's shape was not found (arm %d-%d, noKeep %d-%d, logoffSweepFailed %d, re-arm %d, "+
			"return %d) -- this test is stale, not the code", arm, armEnd, noKeep, noKeepEnd, failed, rearm, ret)
	}
	if len(at) != 1 {
		t.Fatalf("handleLogout calls logoffRefusalKickMediad %d time(s) at body lines %v, want once", len(at), at)
	}
	k := at[0]
	if k <= arm || k >= armEnd {
		t.Errorf("the kick (line %d) is outside the refusal arm (%d-%d)", k, arm, armEnd)
	}
	if k >= noKeep && k <= noKeepEnd {
		t.Errorf("the kick (line %d) is inside the noKeep block (%d-%d) -- that session is reaped", k, noKeep, noKeepEnd)
	}
	if k <= failed || k <= rearm || k >= ret {
		t.Errorf("the kick (line %d) must follow logoffSweepFailed (%d) and the re-arm (%d) and precede the arm's "+
			"return (%d)", k, failed, rearm, ret)
	}
}
