package main

import "testing"

// NWP-20260919-01. A MANUAL "Back up now" could not report PARTIAL at all, and could blame this run for an
// earlier one's missing scopes. Every write to sealPartial lived in handleLogout; handleBackup cleared
// sealProg, healed a stale sealFail on success, and never touched the flag set two lines from that one.
//
// These tests are on recordManualSealVerdict + composeSealStatus rather than on handleBackup, because the
// backup path runs a real roamd worker. That is the same split, for the same reason, that #145 S1 used when
// it moved the status truth table into composeSealStatus: the wire answer is what matters and it is the part
// that can be exercised.
//
// ⚠ This is a precondition for seal-then-enumerate (NWP-20260918-13), not a cosmetic status fix. That design
// turns entirely on telling a clean seal from a partial one. An export that trusted this surface would have
// enumerated over a stale head and called it verified. (~~PARTIAL is NORMAL right after a login
// (sys=pending-placement)~~ -- that detail never meant a stale head, and is dropped as benign: NWP-20261008-07.)

// A manual seal that did not store every scope must SAY so -- the whole point of the #118 suffix.
func TestAManualBackupThatDidNotStoreEverythingSaysSo(t *testing.T) {
	resetSealState(t)
	dir := t.TempDir()

	recordManualSealVerdict("OK PARTIAL:apps=refused")

	got := composeSealStatus(dir)
	if len(got) != 1 || got[0] != "DONE PARTIAL:apps=refused" {
		t.Fatalf("a manual seal that left #apps unstored reported %q, want [DONE PARTIAL:apps=refused] -- "+
			"a bare DONE here is the false-clean direction, and it is the one an export would trust", got)
	}
}

// NWP-20261008-07: an account waiting for its authenticator left nothing unstored, so the backup reads clean.
func TestAManualBackupWithAnAccountPendingPlacementIsClean(t *testing.T) {
	resetSealState(t)
	dir := t.TempDir()

	recordManualSealVerdict("OK PARTIAL:sys=pending-placement")

	if got := composeSealStatus(dir); len(got) != 1 || got[0] != "DONE" {
		t.Fatalf("a backup whose only detail was sys=pending-placement reported %q, want [DONE] -- it would tell "+
			"the user their Google account was not saved, which is false", got)
	}
}

// The inverse, and the direction that is easy to introduce by making the write conditional: a CLEAN manual
// seal must not inherit the partial detail of an earlier logoff in the same daemon lifetime.
func TestACleanManualBackupIsNotBlamedForAnEarlierLogoffsMissingScopes(t *testing.T) {
	resetSealState(t)
	dir := t.TempDir()

	// The previous session logged off with #apps unstored. Same daemon, so the flag is still in memory.
	pendingReapMu.Lock()
	sealPartial = "apps=refused"
	pendingReapMu.Unlock()

	// The user logs back in and taps "Back up now". This seal stores everything.
	recordManualSealVerdict("OK")

	got := composeSealStatus(dir)
	if len(got) != 1 || got[0] != "DONE" {
		t.Fatalf("a clean manual seal reported %q, want [DONE] -- the suffix belongs to the run that earned "+
			"it, and reporting a previous session's missing scopes sends the user looking for data that is "+
			"there", got)
	}
}

// #145 S1's heal must survive the change: a successful manual seal still clears a stale FAILED. FAILED is
// reported AHEAD of the partial detail in composeSealStatus, so losing this would hide both.
func TestASuccessfulManualBackupStillHealsAStaleFailure(t *testing.T) {
	resetSealState(t)
	dir := t.TempDir()

	pendingReapMu.Lock()
	sealFail, sealFailWhy = true, "ERR-PUSH"
	pendingReapMu.Unlock()

	recordManualSealVerdict("OK")

	if got := composeSealStatus(dir); len(got) != 1 || got[0] != "DONE" {
		t.Fatalf("after a successful manual seal the status was %q, want [DONE] -- #145 S1's heal", got)
	}
}

// ...and a manual seal that FAILED must not have its failure erased by the new assignment. sealPartial
// accompanies a SUCCESS; a failure is reported by sealFail and must still win.
func TestAFailedManualBackupStillReportsFailed(t *testing.T) {
	resetSealState(t)
	dir := t.TempDir()

	pendingReapMu.Lock()
	sealFail, sealFailWhy = true, "ERR-REFUSED"
	pendingReapMu.Unlock()

	// A verdict that is NOT OK: the heal must not fire, so the failure stands.
	recordManualSealVerdict("ERR-REFUSED")

	got := composeSealStatus(dir)
	if len(got) != 1 || got[0] != "FAILED REFUSED" {
		t.Fatalf("a failed manual seal reported %q, want [FAILED REFUSED] -- a refusal is deterministic and "+
			"the user needs the cause, not a clean DONE", got)
	}
}
