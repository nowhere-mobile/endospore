package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261014-26. The fail direction of the #media clean-receipt (an interrupted restore must still raise
// INCOMPLETE) rests on two things: the receipt is CLEARED before a #media restore starts, and it is WRITTEN
// only at the clean end. Both lived inline in main()'s restore case, where no test reached them, and before
// NWP-20260822-07 the clear ran inert with every log reporting success. These tests drive the extracted
// clearMediaRestoreReceipt / finishRestore, and pin roamd's own clear to the source line before the restore.

func writeOK(t *testing.T, st string) string {
	t.Helper()
	f := filepath.Join(st, mediaRestoreOKFile)
	if err := os.WriteFile(f, []byte("ok\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

func mediaReceiptEnv(t *testing.T, phase string) string {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	t.Setenv("NOWHERE_PHASE", phase)
	return st
}

// R1: a stale "ok" from an earlier login is gone once a #media restore begins.
func TestClearMediaRestoreReceipt_MediaPhaseRemovesStale(t *testing.T) {
	st := mediaReceiptEnv(t, "media")
	f := writeOK(t, st)
	clearMediaRestoreReceipt()
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Fatal("a stale media.restore-ok must be removed when a #media restore begins")
	}
}

// R2: any other phase never owns the file.
func TestClearMediaRestoreReceipt_OtherPhaseLeavesIt(t *testing.T) {
	st := mediaReceiptEnv(t, "vault")
	f := writeOK(t, st)
	clearMediaRestoreReceipt()
	if _, err := os.Stat(f); err != nil {
		t.Fatal("a non-media restore must not touch media.restore-ok")
	}
}

// R3: a restore with skipped entries writes nothing and says INCOMPLETE.
func TestFinishRestore_SkippedWritesNothing(t *testing.T) {
	st := mediaReceiptEnv(t, "media")
	ref := profileRefV2("rcptprof", "rcptpass")
	out := captureStdout(t, func() { finishRestore("rcptprof", "rcptpass", "deadbeef", 1) })
	if _, err := os.Stat(filepath.Join(st, mediaRestoreOKFile)); !os.IsNotExist(err) {
		t.Error("an INCOMPLETE restore must not write the media clean-receipt")
	}
	if haveRestoreReceipt(ref) {
		t.Error("an INCOMPLETE restore must not write the #72 receipt")
	}
	if !strings.Contains(out, "INCOMPLETE -- 1 entry could not be written") {
		t.Errorf("INCOMPLETE line missing from stdout: %q", out)
	}
}

// R4: a clean #media restore writes the #72 receipt, the roster and the media receipt.
func TestFinishRestore_CleanMediaWritesReceipts(t *testing.T) {
	st := mediaReceiptEnv(t, "media")
	ref := profileRefV2("rcptprof", "rcptpass")
	captureStdout(t, func() { finishRestore("rcptprof", "rcptpass", "deadbeef", 0) })
	if !mediaRestoreWasClean(st) {
		t.Error("a clean #media restore must write the media clean-receipt")
	}
	if !haveRestoreReceipt(ref) {
		t.Error("a clean restore must write the #72 receipt")
	}
}

// R5: a clean non-media restore never writes the media receipt.
func TestFinishRestore_CleanVaultNoMediaReceipt(t *testing.T) {
	st := mediaReceiptEnv(t, "vault")
	ref := profileRefV2("rcptprof", "rcptpass")
	captureStdout(t, func() { finishRestore("rcptprof", "rcptpass", "deadbeef", 0) })
	if _, err := os.Stat(filepath.Join(st, mediaRestoreOKFile)); !os.IsNotExist(err) {
		t.Error("a non-media restore must not write the media clean-receipt")
	}
	if !haveRestoreReceipt(ref) {
		t.Error("a clean restore must write the #72 receipt")
	}
}

// R6: the whole fail direction. A stale "ok", the restore clears it, the restore is interrupted short
// (skipped > 0): mediad must raise INCOMPLETE for a recreated deferred dir.
func TestInterruptedMediaRestoreStillRaisesIncomplete(t *testing.T) {
	st := mediaReceiptEnv(t, "media")
	writeOK(t, st)
	clearMediaRestoreReceipt()
	captureStdout(t, func() { finishRestore("rcptprof", "rcptpass", "deadbeef", 2) })
	s := &mediaServer{}
	s.markIncomplete("com.example.app")
	if !s.incomplete["com.example.app"] {
		t.Fatal("an interrupted #media restore must still raise INCOMPLETE")
	}
}

// The roamd half: the clear must precede the #media restore in source order. Before NWP-20260822-07 it sat
// ~130 lines BELOW, deleting the receipt the restore had just written. Since NWP-20261020-01 the clear moves
// media.restore-ok into the commit arm's park ($PARK) instead of deleting it, so a sign-in that does not land
// can put it back. A move reaches the park only if this run made it, so the file is out of $STATE when the
// restores begin only if the delete that stands in for the moves is the else of a CHECKED mkdir: noPark pins
// that whole if/else line for line, not the delete loop alone. This is a source pin; test-in-refused-noop.sh
// NP1-NP5 run the arm with a park that cannot be made.
func TestRoamdClearsMediaReceiptBeforeMediaRestore(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	noPark := strings.Join([]string{
		`      rm -rf "$PARK" 2>> "$LOG"`,
		`      if mkdir "$PARK" 2>> "$LOG"; then`,
		`        _parked=1`,
		`      else`,
		`        for _pn in restore-receipts media.restore-ok .btlogoff .had_account .fido2hmac .fido2slots; do rm -rf "$STATE/$_pn" 2>> "$LOG"; done`,
		`        print -r -- "[roamd] IN $(qn "$name") could not make the park -- per-login state deleted, not parked $(date)" >> "$LOG"`,
		`      fi`,
	}, "\n") + "\n"
	clr := strings.Index(src, `for _pn in media.restore-ok .btlogoff .had_account; do [ -e "$STATE/$_pn" ] && mv "$STATE/$_pn" "$PARK/"`)
	del := strings.Index(src, noPark)
	rs := strings.Index(src, `NOWHERE_PHASE=media "$AGENT" restore`)
	if clr < 0 || rs < 0 {
		t.Fatalf("anchors missing (clear=%d restore=%d)", clr, rs)
	}
	if del < 0 {
		t.Fatal(`roamd's delete of media.restore-ok when it cannot make the park must be the else of a checked mkdir "$PARK", block as pinned (NWP-20261020-01), or the file can still be in $STATE when the restores begin`)
	}
	if clr > rs {
		t.Fatal(`roamd's clear of media.restore-ok (moved into the park, NWP-20261020-01) must precede the #media restore, or it clears the fresh receipt`)
	}
	if del > rs {
		t.Fatal(`roamd's clear of media.restore-ok when it cannot make the park (deleted, NWP-20261020-01) must precede the #media restore, or it deletes the fresh receipt`)
	}
}
