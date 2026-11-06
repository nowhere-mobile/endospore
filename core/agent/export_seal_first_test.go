package main

import (
	"errors"
	"strings"
	"testing"
)

// NWP-20260919-10. Seal-then-enumerate. The whole design turns on refusing states that LOOK fine, so every
// test here is about a state that a naive check would let through.

// ⚠ THE ONE THE DESIGN EXISTS FOR. A seal that finished PARTIAL still says OK, and its suffix is built to
// be ignorable. Enumerating over it captures a stale head for the unsealed scope and calls it verified.
func TestAPartialSealRefusesTheExport(t *testing.T) {
	got := exportSealState(false, "", false, "", "apps=refused", 1700000000)
	if !strings.HasPrefix(got, "ERR-SEAL-PARTIAL") {
		t.Fatalf("a PARTIAL seal produced %q, want ERR-SEAL-PARTIAL -- this is the exact state that makes "+
			"an export capture a stale head and report success", got)
	}
	if !strings.Contains(got, "apps=refused") {
		t.Fatalf("the reply did not name which scope was left behind: %q", got)
	}
}

// NWP-20261008-07: a Google account still waiting for its authenticator is not a stale head -- the session cannot
// have changed it -- so it must not block an export, which it did in every session where no Play app was opened.
func TestAnAccountPendingPlacementDoesNotBlockTheExport(t *testing.T) {
	parts := sealPartsOf("OK PARTIAL:sys=pending-placement")
	if got := exportSealState(false, "", false, "", parts, 1700000000); got != "" {
		t.Fatalf("a seal whose only detail was sys=pending-placement refused the export: %q", got)
	}
	parts = sealPartsOf("OK PARTIAL:apps=refused,sys=pending-placement")
	if got := exportSealState(false, "", false, "", parts, 1700000000); got != "ERR-SEAL-PARTIAL apps=refused" {
		t.Fatalf("a real partial beside a pending placement = %q, want ERR-SEAL-PARTIAL apps=refused", got)
	}
}

// ⚠ "NOTHING FAILED" IS NOT "A SEAL HAPPENED". An idle session reports clean by construction, so a check
// that only looked for failure would enumerate a session whose live state was never written.
func TestASessionThatNeverSealedRefusesTheExport(t *testing.T) {
	if got := exportSealState(false, "", false, "", "", 0); got != "ERR-NO-SEAL" {
		t.Fatalf("a session with no seal produced %q, want ERR-NO-SEAL -- an idle session looks clean, and "+
			"exporting it would hand back the PREVIOUS logoff's objects while the screen said complete", got)
	}
}

// A seal in flight must not be enumerated across: the heads move underneath the walk.
func TestASealInFlightIsBusyNotClean(t *testing.T) {
	if got := exportSealState(true, "", false, "", "", 1700000000); got != "BUSY" {
		t.Fatalf("a seal in flight produced %q, want BUSY", got)
	}
	// An ANNOUNCED run with the flag not yet set is the same hazard -- this is the pair NWP-20260901-25
	// added precisely because a periodic seal announced itself to nothing.
	if got := exportSealState(false, "periodic", false, "", "", 1700000000); got != "BUSY" {
		t.Fatalf("an announced periodic run produced %q, want BUSY", got)
	}
}

// A failed seal refuses, and names the cause when there is one -- the three causes need opposite advice.
func TestAFailedSealRefusesAndNamesTheCause(t *testing.T) {
	got := exportSealState(false, "", true, "ERR-REFUSED", "", 1700000000)
	if !strings.HasPrefix(got, "ERR-SEAL-FAILED") {
		t.Fatalf("a failed seal produced %q, want ERR-SEAL-FAILED", got)
	}
	if got == "ERR-SEAL-FAILED" {
		t.Fatalf("the cause was dropped: %q -- a guard refusal is deterministic and retrying reproduces it, "+
			"so the advice differs from a transient failure", got)
	}
	// An unknown cause still refuses, bare.
	if got := exportSealState(false, "", true, "", "", 1700000000); got != "ERR-SEAL-FAILED" {
		t.Fatalf("a failed seal with no known cause produced %q, want a bare ERR-SEAL-FAILED", got)
	}
}

// Only a clean, landed seal permits the export.
func TestACleanLandedSealPermitsTheExport(t *testing.T) {
	if got := exportSealState(false, "", false, "", "", 1700000000); got != "" {
		t.Fatalf("a clean landed seal produced %q, want '' (permitted)", got)
	}
}

// ⚠ ORDER MATTERS: a FAILED seal that also left partial detail must report the failure, not the partial.
// The failure is the more serious verdict and the one the user has to act on.
func TestAFailedSealOutranksItsPartialDetail(t *testing.T) {
	got := exportSealState(false, "", true, "ERR-PUSH", "apps=refused", 1700000000)
	if !strings.HasPrefix(got, "ERR-SEAL-FAILED") {
		t.Fatalf("a failed seal carrying partial detail reported %q, want the FAILURE to win", got)
	}
}

// ...and BUSY outranks everything, including a stale failure from the previous run.
func TestBusyOutranksAStaleFailure(t *testing.T) {
	if got := exportSealState(true, "manual", true, "ERR-PUSH", "apps=refused", 0); got != "BUSY" {
		t.Fatalf("a live seal over stale failure state reported %q, want BUSY", got)
	}
}

// The wire reply is keyed to a SENTINEL, not to prose, so rewording a message cannot change which verb a
// caller receives.
func TestTheUnmeasuredReplyIsKeyedToASentinelNotProse(t *testing.T) {
	if !isUnmeasuredExport(errExportUnmeasured) {
		t.Fatal("the unmeasured sentinel was not recognised")
	}
	if isUnmeasuredExport(errExportNothingStored) {
		t.Fatal("the blank-login refusal was misreported as unmeasured -- they are different wire replies")
	}
	if isUnmeasuredExport(errors.New(errExportUnmeasured.Error())) {
		t.Fatal("a look-alike error with identical TEXT was accepted -- the check is matching prose, which " +
			"is exactly what the sentinel exists to avoid")
	}
}

// This protocol is line-delimited: an embedded newline would split one reply into two and desynchronise
// every later read on the connection.
func TestAnErrorReplyCannotSplitTheWire(t *testing.T) {
	got := oneLine("two\nlines\r\nand more")
	if strings.ContainsAny(got, "\r\n") {
		t.Fatalf("oneLine left a line break in %q -- the next read would take it as a new reply", got)
	}
}
