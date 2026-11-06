package main

import (
	"strings"
	"testing"
)

// NWP-20261029-03 (docs/backlog.md §B, "A failed sign-in left the typed profile name in cleartext in login.log ..."):
// a busy or timed-out sign-in schedules no scrub, so the daemon's own two log lines for them must name the uid, never
// the typed name. The workerState seam is a package var: none of these may run in parallel.

// roamInBusyNameLeaks fails the test for every spelling of name that out carries.
func roamInBusyNameLeaks(t *testing.T, out, name string) {
	t.Helper()
	for _, sp := range nameSpellings(name) {
		if strings.Contains(out, sp) {
			t.Errorf("the log carries the typed name as %q:\n%s", sp, out)
		}
	}
}

func roamInBusyNameBusyLane(t *testing.T) {
	t.Helper()
	resetAbandoned(t, map[string]string{laneRW.svc: "in"})
	prev := workerState
	workerState = func(svc string) string {
		if svc == laneRW.svc {
			return "running"
		}
		return prev(svc)
	}
	t.Cleanup(func() { workerState = prev })
}

func TestRoamInBusyName_ABusySignInLogsTheUidNotTheName(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	roamInBusyNameBusyLane(t)
	const name = "zq-rbn-busy"
	reply, out := roamInBusyDrive(t, f, name, "a passphrase nobody has")
	if reply != "ERR-WORKER-BUSY" {
		t.Errorf("the reply is %q, want ERR-WORKER-BUSY", reply)
	}
	if !strings.Contains(out, "the worker lane is busy") || !strings.Contains(out, "user 21") {
		t.Errorf("the busy line is missing or does not name the uid:\n%s", out)
	}
	roamInBusyNameLeaks(t, out, name)
}

func TestRoamInBusyName_ABusySignInWithQuoteAndBackslashLogsNoName(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	roamInBusyNameBusyLane(t)
	const name = `zq-rbn"q\b`
	reply, out := roamInBusyDrive(t, f, name, "a passphrase nobody has")
	if reply != "ERR-WORKER-BUSY" {
		t.Errorf("the reply is %q, want ERR-WORKER-BUSY", reply)
	}
	if !strings.Contains(out, "the worker lane is busy") {
		t.Errorf("the busy line is missing:\n%s", out)
	}
	roamInBusyNameLeaks(t, out, name)
}

func TestRoamInBusyName_ATimedOutSignInLogsTheUidNotTheName(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	rwWorker(t, f.dest, map[string]string{"in": "ERR-TIMEOUT"})
	const name = "zq-rbn-timeout"
	reply, out := roamInBusyDrive(t, f, name, "a passphrase nobody has")
	if reply != "ERR-TIMEOUT" {
		t.Errorf("the reply is %q, want ERR-TIMEOUT", reply)
	}
	if !strings.Contains(out, "the worker timed out (ERR-TIMEOUT)") || !strings.Contains(out, "user 21") {
		t.Errorf("the timeout line is missing or does not name the uid:\n%s", out)
	}
	roamInBusyNameLeaks(t, out, name)
}

// Control: a BLANK keeps its quoted name (the scrub covers it), which shows the capture sees names at all.
func TestRoamInBusyName_ABlankSignInStillLogsTheQuotedName(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	rwWorker(t, f.dest, map[string]string{"in": "BLANK"})
	const name = "zq-rbn-blank"
	reply, out := roamInBusyDrive(t, f, name, "a passphrase nobody has")
	if reply != "BLANK" {
		t.Errorf("the reply is %q, want BLANK", reply)
	}
	if !strings.Contains(out, `roam-in BLANK "zq-rbn-blank"`) {
		t.Errorf("the BLANK line no longer carries the quoted name:\n%s", out)
	}
}
