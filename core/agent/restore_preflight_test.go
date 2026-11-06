package main

import (
	"strings"
	"testing"
)

// NWP-20260919-09. The guard §2 assumed away. These tests are about the states a destination can be in,
// because the one that matters -- a live profile with a DIFFERENT head -- is the one a raw object copy
// overwrites in a single step with nothing saying a word.

// Only a differing ref may block. Absent, identical and tombstoned must not, or the guard is refused
// around within a week: a managed store holds every customer's objects, and a re-run after a partial
// transfer has to be repeatable.
func TestOnlyADifferingHeadBlocksARestore(t *testing.T) {
	for _, tc := range []struct {
		state string
		block bool
	}{
		{"absent", false},
		{"same", false},
		{"tombstone", false},
		{"differs", true},
	} {
		t.Run(tc.state, func(t *testing.T) {
			rep := &PreflightReport{Verdicts: []PreflightVerdict{{Key: "ref/x", State: tc.state}}}
			if tc.state == "differs" {
				rep.Blocking = 1
			}
			if tc.state == "tombstone" {
				rep.Tombstoned = 1
			}
			if got := rep.Safe(); got == tc.block {
				t.Fatalf("state %q: Safe()=%v, want %v -- %s", tc.state, got, !tc.block,
					map[bool]string{
						true:  "a destination holding a different head must REFUSE",
						false: "blocking on this state makes the guard useless and it will be bypassed",
					}[tc.block])
			}
		})
	}
}

// The rollback direction is the actionable part: it is what tells an operator whether they are about to
// destroy newer data or refresh a stale copy. Both refuse; only the wording differs.
func TestTheReportNamesTheRollbackDirection(t *testing.T) {
	rollback := &PreflightReport{
		Blocking: 1,
		Verdicts: []PreflightVerdict{{Key: "ref/x", State: "differs", DestVersion: 9, SrcVersion: 4}},
	}
	s := rollback.summary()
	if !strings.Contains(s, "ROLL THE PROFILE BACK") {
		t.Fatalf("a destination NEWER than the export did not name the rollback: %q", s)
	}
	if !strings.Contains(s, "5") {
		t.Fatalf("the report did not say how many versions would be lost (9-4=5): %q", s)
	}

	stale := &PreflightReport{
		Blocking: 1,
		Verdicts: []PreflightVerdict{{Key: "ref/x", State: "differs", DestVersion: 2, SrcVersion: 7}},
	}
	if s := stale.summary(); !strings.Contains(s, "STALE") {
		t.Fatalf("a destination OLDER than the export should be named as stale, not as a rollback: %q", s)
	}
}

// ⚠ An unreadable head must never read as agreement. Zero means UNKNOWN, and the refusal stands.
func TestAnUnreadableHeadIsNotTreatedAsAgreement(t *testing.T) {
	rep := &PreflightReport{
		Blocking: 1,
		Verdicts: []PreflightVerdict{{Key: "ref/x", State: "differs", DestVersion: 0, SrcVersion: 0}},
	}
	if rep.Safe() {
		t.Fatal("a differing ref whose versions could not be read was treated as safe -- 0 is UNKNOWN, " +
			"not 'version zero', and this is the check-that-could-not-run bug class")
	}
	if s := rep.summary(); !strings.Contains(s, "could not be compared") {
		t.Fatalf("the report hid that it could not compare the versions: %q", s)
	}
}

// The summary must print the counts even when everything is fine, so a pass is auditable.
func TestASafeDestinationStillReportsWhatItSaw(t *testing.T) {
	rep := &PreflightReport{Verdicts: []PreflightVerdict{
		{Key: "ref/a", State: "absent"},
		{Key: "ref/b", State: "same"},
	}}
	if !rep.Safe() {
		t.Fatal("absent + identical must be safe")
	}
	s := rep.summary()
	for _, want := range []string{"1 absent", "1 identical", "of 2 refs"} {
		if !strings.Contains(s, want) {
			t.Fatalf("summary missing %q: %q", want, s)
		}
	}
}

// A tombstoned destination is allowed but must be VISIBLE -- restoring over a delete is a legitimate thing
// to want, and it is invisible otherwise.
func TestRestoringOverADeleteIsAllowedButNamed(t *testing.T) {
	rep := &PreflightReport{
		Tombstoned: 1,
		Verdicts:   []PreflightVerdict{{Key: "ref/x", State: "tombstone"}},
	}
	if !rep.Safe() {
		t.Fatal("a tombstoned destination must not block -- restoring over a delete is legitimate")
	}
	if s := rep.summary(); !strings.Contains(s, "TOMBSTONE") {
		t.Fatalf("the tombstone was not named: %q", s)
	}
}
