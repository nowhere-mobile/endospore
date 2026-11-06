package main

// DIA-20260809-05: a failed seal must say WHY.
//
// The cause used to be destroyed twice on its way to the user: roamd collapsed every non-zero agent exit
// into the single string ERR-PUSH, and the daemon then reduced that to a boolean. So a seal that failed for
// lack of storage credit and one that failed because the store was unreachable arrived identical, and the
// chooser told the credit user to "check your connection".
//
// That is not merely unhelpful, it is the worst available instruction: it tells them to WAIT, and waiting
// ends at power-off, which on this device is the wipe. The two causes need opposite actions -- an offline
// seal retries by itself, a credit one never will.

import "testing"

func TestSealReasonSurvivesRoamdsVerdict(t *testing.T) {
	cases := []struct {
		out  string
		want string
	}{
		{"OK", "ok"},
		{"OK 3", "ok"}, // roamd's OK can carry a count
		{"ERR-NOCREDIT", "nocredit"},
		{"ERR-PUSH", "fail"},
		{"ERR-TIMEOUT", "fail"},
		{"", "fail"}, // no verdict at all is a failure, never a silent success
	}
	for _, c := range cases {
		resetSealStatus()
		recordSeal(c.out)
		if got := sealStatusGet(); got != c.want {
			t.Errorf("recordSeal(%q) -> %q, want %q", c.out, got, c.want)
		}
	}
}

// The distinguishing case, stated on its own because it is the whole point: no-credit must NOT be reported
// as a generic failure, or the notice built on it goes back to blaming the network.
func TestNoCreditIsNotJustAFailure(t *testing.T) {
	resetSealStatus()
	recordSeal("ERR-NOCREDIT")
	if sealStatusGet() == "fail" {
		t.Fatal("a credit failure was flattened to a generic one -- the user would be told to check their connection")
	}
	resetSealStatus()
	recordSeal("ERR-PUSH")
	if sealStatusGet() == "nocredit" {
		t.Fatal("a transport failure was reported as a credit problem -- the user would be told to pay for nothing")
	}
}
