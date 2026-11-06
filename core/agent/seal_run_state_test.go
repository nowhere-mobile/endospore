package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20260901-25 (#145 S1): the seal run-state truth table. Before this, SEAL-STATUS knew only the
// logoff/manual progress channel (sealInFlight) -- a PERIODIC seal announced itself to nothing, so the
// status answered DONE while gigabytes were mid-upload (the #124 shape with a confident UI on top), and a
// "Back up now" tapped during one queued a full redundant second cycle.

func resetSealState(t *testing.T) {
	t.Helper()
	pendingReapMu.Lock()
	sealInFlight, sealRunKind, sealFail, sealFailWhy, sealPartial, sealProg = false, "", false, "", "", ""
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealFail, sealFailWhy, sealPartial, sealProg = false, "", false, "", "", ""
		pendingReapMu.Unlock()
	})
}

// A periodic seal must render as SEALING with its kind on the second line -- not DONE.
func TestSealStatusPeriodicIsLive(t *testing.T) {
	resetSealState(t)
	dir := t.TempDir()
	setSealRun("periodic")
	got := composeSealStatus(dir)
	if len(got) != 2 || got[0] != "SEALING " || got[1] != "KIND periodic" {
		t.Fatalf("composeSealStatus = %q, want [SEALING , KIND periodic]", got)
	}
	// And with the agent's own progress file present, its content is served (#125: the file is the truth).
	if err := os.WriteFile(filepath.Join(dir, "roam.progress"), []byte("save 5 10 media\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got = composeSealStatus(dir)
	if len(got) != 2 || got[0] != "SEALING save 5 10 media" {
		t.Fatalf("with progress file: %q, want SEALING save 5 10 media + KIND", got)
	}
}

// A LIVE run outranks a stale FAILED. After a failed-but-signed-in logoff (#86), sealFail stayed latched and
// every manual backup's poll spun on the old verdict for its whole run.
func TestSealStatusLiveOutranksStaleFail(t *testing.T) {
	resetSealState(t)
	pendingReapMu.Lock()
	sealFail, sealFailWhy = true, ""
	pendingReapMu.Unlock()
	setSealRun("manual")
	got := composeSealStatus(t.TempDir())
	if len(got) != 2 || got[0] != "SEALING " || got[1] != "KIND manual" {
		t.Fatalf("live manual over stale fail: %q, want [SEALING , KIND manual]", got)
	}
}

// The pre-existing single-line shapes are byte-identical: old readers parse line 1 and nothing else.
func TestSealStatusLegacyShapesUnchanged(t *testing.T) {
	resetSealState(t)
	dir := t.TempDir()
	if got := composeSealStatus(dir); len(got) != 1 || got[0] != "DONE" {
		t.Fatalf("idle: %q, want [DONE]", got)
	}
	pendingReapMu.Lock()
	sealPartial = "apps=refused"
	pendingReapMu.Unlock()
	if got := composeSealStatus(dir); len(got) != 1 || got[0] != "DONE PARTIAL:apps=refused" {
		t.Fatalf("partial: %q", got)
	}
	pendingReapMu.Lock()
	sealPartial = ""
	sealFail = true
	pendingReapMu.Unlock()
	if got := composeSealStatus(dir); len(got) != 1 || got[0] != "FAILED" {
		t.Fatalf("failed idle: %q, want [FAILED]", got)
	}
	// A logoff/manual seal that set ONLY sealInFlight (no announced kind) stays ONE line -- the pre-S1 wire
	// shape exactly, so a chooser reading a single line sees precisely what it always saw.
	pendingReapMu.Lock()
	sealFail = false
	sealInFlight = true
	sealProg = "prepare 1 2"
	pendingReapMu.Unlock()
	if got := composeSealStatus(dir); len(got) != 1 || got[0] != "SEALING prepare 1 2" {
		t.Fatalf("inFlight only: %q, want [SEALING prepare 1 2]", got)
	}
}

// clearSealRun before recordSeal: a status read must never pair a fresh verdict with a stale live-kind.
func TestClearSealRun(t *testing.T) {
	resetSealState(t)
	setSealRun("periodic")
	clearSealRun()
	if got := composeSealStatus(t.TempDir()); len(got) != 1 || got[0] != "DONE" {
		t.Fatalf("after clear: %q, want [DONE]", got)
	}
}

// The widened BUSY: a manual tap during an ANNOUNCED run (periodic above all) must refuse, or it queues a
// full redundant second cycle behind the unbounded writer lane -- the exact #145 complaint.
func TestManualBackupBusyDuringAnnouncedRun(t *testing.T) {
	resetSealState(t)
	setSealRun("periodic")
	pendingReapMu.Lock()
	busy := syncDeferReason(time.Now(), sealInFlight, odMaterializeUntil, loginSettleUntil, userOpWaiting.Load()) != "" ||
		sealRunKind != ""
	pendingReapMu.Unlock()
	if !busy {
		t.Fatal("manual backup not BUSY during an announced periodic seal")
	}
	clearSealRun()
	pendingReapMu.Lock()
	busy = syncDeferReason(time.Now(), sealInFlight, odMaterializeUntil, loginSettleUntil, userOpWaiting.Load()) != "" ||
		sealRunKind != ""
	pendingReapMu.Unlock()
	if busy {
		t.Fatal("manual backup still BUSY with no run live")
	}
}
