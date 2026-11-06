package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261115-01 (dn-1023 #4): DROP-SSAID, the gate's clean-up of an abandoned sign-in's SSAID files. The seams are
// the gate-only tests' (abFakeInit, gatePeer, gateOnlyDrive), so nothing here is parallel.

// dropSsaidCapture wraps the fake worker so each start records the WHOLE request before the fake removes it.
func dropSsaidCapture(t *testing.T, dest string) func() []string {
	t.Helper()
	var mu sync.Mutex
	var reqs []string
	prev := workerStart
	t.Cleanup(func() { workerStart = prev })
	workerStart = func(svc string) {
		f := filepath.Join(dest, laneRW.req)
		if b, err := os.ReadFile(f); err == nil {
			mu.Lock()
			reqs = append(reqs, string(b))
			mu.Unlock()
		}
		prev(svc)
	}
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), reqs...)
	}
}

func dropSsaidFixture(t *testing.T, plan []abPlan) (*abInit, func() []string) {
	t.Helper()
	f := abFakeInit(t, plan)
	resetAbandoned(t, nil)
	return f, dropSsaidCapture(t, f.dest)
}

func dropSsaidAsk(t *testing.T, dest, rest string) string {
	t.Helper()
	reply, _, answered := gateOnlyDrive(t, dest, "DROP-SSAID", rest, 10*time.Second)
	if !answered {
		t.Fatalf("DROP-SSAID %q: no reply within 10 s", rest)
	}
	return reply
}

func TestDropSsaid_GateSendsTheOpAndRelaysTheReply(t *testing.T) {
	gatePeer(t, 10123)
	f, reqs := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: "OK 2"}})
	defer waitGateOnly(t)
	if got := dropSsaidAsk(t, f.dest, "17\n"); got != "OK 2" {
		t.Errorf("reply %q, want the worker's OK 2", got)
	}
	got := reqs()
	if len(got) != 1 {
		t.Fatalf("%d worker request(s), want 1", len(got))
	}
	lines := strings.Split(got[0], "\n")
	if len(lines) < 4 || lines[0] != "dropssaid" || lines[1] != "x" || lines[2] != "" || lines[3] != "17" {
		t.Errorf("the request is %q, want op dropssaid, name x, an empty pass and uid 17", got[0])
	}
}

func TestDropSsaid_BadUidNoWorker(t *testing.T) {
	gatePeer(t, 10123)
	for _, rest := range []string{"\n", "abc\n", "9\n", "-12\n", "+17\n"} {
		f, _ := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: "OK 0"}})
		if got := dropSsaidAsk(t, f.dest, rest); got != "ERR-UID" {
			t.Errorf("uid %q: reply %q, want ERR-UID", rest, got)
		}
		waitGateOnly(t)
		if n := len(f.snapshot()); n != 0 {
			t.Errorf("uid %q: %d worker start(s), want none", rest, n)
		}
	}
}

func TestDropSsaid_LiveSessionUidRefused(t *testing.T) {
	gatePeer(t, 10123)
	for _, rest := range []string{"17\n", "017\n"} {
		f, _ := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: "OK 2"}})
		if err := markRoamSession(f.dest, "dropssaid-live", "pw", "17", ""); err != nil {
			t.Fatal(err)
		}
		if got := dropSsaidAsk(t, f.dest, rest); got != "ERR-LIVE" {
			t.Errorf("uid %q of the live session: reply %q, want ERR-LIVE", rest, got)
		}
		waitGateOnly(t)
		if n := len(f.snapshot()); n != 0 {
			t.Errorf("uid %q of the live session: %d worker start(s), want none", rest, n)
		}
	}
}

func TestDropSsaid_ColdLockedUidRefused(t *testing.T) {
	gatePeer(t, 10123)
	f, _ := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: "OK 2"}})
	defer waitGateOnly(t)
	if err := os.WriteFile(filepath.Join(f.dest, ".coldlock"), []byte("dropssaid-cold\n17\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := dropSsaidAsk(t, f.dest, "17\n"); got != "ERR-LIVE" {
		t.Errorf("uid of the cold-locked session: reply %q, want ERR-LIVE", got)
	}
	if n := len(f.snapshot()); n != 0 {
		t.Errorf("uid of the cold-locked session: %d worker start(s), want none", n)
	}
}

// TestDropSsaid_OtherUidStillRuns: the guard compares the uid; a marker for another user does not refuse.
func TestDropSsaid_OtherUidStillRuns(t *testing.T) {
	gatePeer(t, 10123)
	f, reqs := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: "OK 0"}})
	defer waitGateOnly(t)
	if err := markRoamSession(f.dest, "dropssaid-other", "pw", "15", ""); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.dest, ".coldlock"), []byte("dropssaid-cold2\n16\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := dropSsaidAsk(t, f.dest, "17\n"); got != "OK 0" {
		t.Errorf("reply %q, want OK 0", got)
	}
	if n := len(reqs()); n != 1 {
		t.Errorf("%d worker request(s), want 1", n)
	}
}

// TestDropSsaid_EmptyWorkerReplyIsErr: a reply of blanks only is taken by runWorkerHeld (an empty file reads as "not
// written yet") and trims to "", which the handler answers as ERR, never as an empty line.
func TestDropSsaid_EmptyWorkerReplyIsErr(t *testing.T) {
	gatePeer(t, 10123)
	f, _ := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: " "}})
	defer waitGateOnly(t)
	if got := dropSsaidAsk(t, f.dest, "17\n"); got != "ERR" {
		t.Errorf("an empty worker reply was relayed as %q, want ERR", got)
	}
}

func TestDropSsaid_RoamedCallerDenied(t *testing.T) {
	gatePeer(t, gateRoamedA)
	f, _ := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: "OK 2"}})
	defer waitGateOnly(t)
	if got := dropSsaidAsk(t, f.dest, "17\n"); got != "DENIED" {
		t.Errorf("a roamed caller got %q, want DENIED", got)
	}
	if n := len(f.snapshot()); n != 0 {
		t.Errorf("a roamed caller: %d worker start(s), want none", n)
	}
}
