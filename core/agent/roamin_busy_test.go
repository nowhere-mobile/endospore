package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261023-02 (docs/backlog.md §H, "a busy or timed-out sign-in gets its own reply at the gate"): handleRoamIn
// answered BLANK to every reply of runWorkerHeld but OK / NEEDKEY / BLANK NET, so a sign-in met by a worker lane busy
// with an abandoned op (ERR-WORKER-BUSY, NWP-20261022-02) or timed out by the daemon (ERR-TIMEOUT) reached the gate as
// the blind line, or, after restore progress, as the permanent snapshot-rollback offer. These cases drive the real
// handleRoamIn over a pipe. The workerState seam is a package var: none of them may run in parallel.

// roamInBusyDrive signs name/pass in through the real handleRoamIn and returns the reply and the daemon's log.
func roamInBusyDrive(t *testing.T, f *walletFailFixture, name, pass string) (string, string) {
	t.Helper()
	lateWorkDrain(t) // h46 #1: no late sign-in job outlives the test
	var reply string
	out := captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) { handleRoamIn(c, f.dest, name, pass, "21", "", "") })
	})
	return reply, out
}

// TestRoamInBusy_AnAbandonedLaneAnswersBusyWithNothingAsked: the real busy path, for a profile that exists and one that
// does not -- the replies and the log lines are identical, and roamd was asked nothing.
func TestRoamInBusy_AnAbandonedLaneAnswersBusyWithNothingAsked(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, map[string]string{laneRW.svc: "in"})
	prev := workerState
	workerState = func(svc string) string {
		if svc == laneRW.svc {
			return "running"
		}
		return prev(svc)
	}
	t.Cleanup(func() { workerState = prev })

	var replies []string
	for _, c := range []struct{ name, pass string }{
		{walletFailName, walletFailPass},
		{"someone-new", "a passphrase with no profile"},
	} {
		reply, out := roamInBusyDrive(t, f, c.name, c.pass)
		replies = append(replies, reply)
		if reply != "ERR-WORKER-BUSY" {
			t.Errorf("%s: the reply is %q, want ERR-WORKER-BUSY", c.name, reply)
		}
		if !strings.Contains(out, "the worker lane is busy") {
			t.Errorf("%s: the busy log line is missing:\n%s", c.name, out)
		}
		if strings.Contains(out, "roam-in BLANK") {
			t.Errorf("%s: the sign-in was logged as BLANK:\n%s", c.name, out)
		}
		if _, err := os.Stat(filepath.Join(f.dest, laneRW.req)); err == nil {
			t.Errorf("%s: a request was written to roamd on a busy lane", c.name)
		}
		if _, err := os.Stat(filepath.Join(f.dest, ".roamsession")); err == nil {
			t.Errorf("%s: a busy sign-in recorded a roam session", c.name)
		}
	}
	if replies[0] != replies[1] {
		t.Errorf("the busy reply depends on the profile: %q vs %q", replies[0], replies[1])
	}
}

// TestRoamInBusy_ATimedOutWorkerAnswersErrTimeout: the daemon's own ERR-TIMEOUT reaches the gate as itself and records
// no session.
func TestRoamInBusy_ATimedOutWorkerAnswersErrTimeout(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	rwWorker(t, f.dest, map[string]string{"in": "ERR-TIMEOUT"})
	reply, out := roamInBusyDrive(t, f, walletFailName, walletFailPass)
	if reply != "ERR-TIMEOUT" {
		t.Errorf("the reply is %q, want ERR-TIMEOUT", reply)
	}
	if !strings.Contains(out, "the worker timed out (ERR-TIMEOUT)") {
		t.Errorf("the timeout log line is missing:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(f.dest, ".roamsession")); err == nil {
		t.Error("a timed-out sign-in recorded a roam session")
	}
}

// TestRoamInBusy_OtherRepliesAreUnchanged: the controls -- BLANK, BLANK NET and an unknown ERR- answer as before.
func TestRoamInBusy_OtherRepliesAreUnchanged(t *testing.T) {
	for _, c := range []struct{ worker, want string }{
		{"BLANK", "BLANK"},
		{"BLANK NET", "BLANK NET"},
		{"ERR-SOMETHING", "BLANK"},
	} {
		t.Run(c.worker, func(t *testing.T) {
			f := walletFailSetup(t)
			loginWindowState(t)
			resetAbandoned(t, nil)
			rwWorker(t, f.dest, map[string]string{"in": c.worker})
			reply, _ := roamInBusyDrive(t, f, walletFailName, walletFailPass)
			if reply != c.want {
				t.Errorf("worker %q: the reply is %q, want %q", c.worker, reply, c.want)
			}
		})
	}
}
