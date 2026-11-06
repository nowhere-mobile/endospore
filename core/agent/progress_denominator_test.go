package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260821-12. writeProg's numerator (bytes actually read+chunked) and denominator (a pre-chunk stat
// snapshot) are measured differently, so a file that GROWS mid-seal -- normal, because the seal runs while
// the session is live -- pushes done past total. Reported on device as "Preparing … 1.2 GB of 1.1 GB".
// The seal is right to overshoot (walkChunks' "nb = the EXACT plaintext bytes" note in incremental_seal.go / the #400 fix); the estimate is what was stale.
// These pin that the emitted line never shows done > total, and never does so by shrinking done.

// progPhase is a package-global atomic.Value that OVERRIDES NOWHERE_PHASE and is sticky for the whole
// process (setProgPhase; capFlush flips it to "save" mid-seal). A sibling test leaving it set is what made
// the first cut of this file fail with "normal frame altered: save 300 1000" -- the numbers were right, the
// phase was inherited. Pin it per test and RESTORE it, so these tests neither depend on nor create pollution.
func fixProgPhase(t *testing.T, p string) {
	t.Helper()
	prev, _ := progPhase.Load().(string)
	setProgPhase(p)
	t.Cleanup(func() { setProgPhase(prev) })
}

func readProgLine(t *testing.T, path string) (phase string, done, total string) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("no progress file written: %v", err)
	}
	f := strings.Fields(strings.TrimSpace(string(b)))
	if len(f) < 3 {
		t.Fatalf("malformed progress line %q", string(b))
	}
	return f[0], f[1], f[2]
}

func TestProgressDenominatorGrowsRatherThanClampingDone(t *testing.T) {
	dir := t.TempDir()
	pf := filepath.Join(dir, "progress")
	t.Setenv("NOWHERE_PROGRESS", pf)
	fixProgPhase(t, "prepare")

	// the overshoot: a live session appended 200 bytes between the stat pass and the read
	writeProg(1200, 1000)
	_, done, total := readProgLine(t, pf)
	if done != "1200" {
		t.Fatalf("done=%s -- the numerator must NOT be clamped; the bytes were really read", done)
	}
	if total != "1200" {
		t.Fatalf("total=%s, want 1200 -- the denominator must grow to meet it, not stay stale", total)
	}
}

func TestProgressNormalCaseUntouched(t *testing.T) {
	dir := t.TempDir()
	pf := filepath.Join(dir, "progress")
	t.Setenv("NOWHERE_PROGRESS", pf)
	fixProgPhase(t, "prepare")

	writeProg(300, 1000)
	ph, done, total := readProgLine(t, pf)
	if ph != "prepare" || done != "300" || total != "1000" {
		t.Fatalf("normal frame altered: %s %s %s", ph, done, total)
	}
	// and the exact-completion frame stays exact
	writeProg(1000, 1000)
	if _, d, tt := readProgLine(t, pf); d != "1000" || tt != "1000" {
		t.Fatalf("completion frame altered: %s of %s", d, tt)
	}
}

// The empty-frame suppression predates this change (DIA-20260625-04: an empty DE/media seal must not reset
// the bar to 0%) and must survive it -- growing the denominator must never resurrect a total<=0 frame.
func TestProgressStillSuppressesEmptyFrames(t *testing.T) {
	dir := t.TempDir()
	pf := filepath.Join(dir, "progress")
	t.Setenv("NOWHERE_PROGRESS", pf)
	fixProgPhase(t, "prepare")

	writeProg(0, 0)
	if _, err := os.Stat(pf); !os.IsNotExist(err) {
		t.Fatal("a total<=0 frame was written -- the empty-seal suppression is broken")
	}
	writeProg(5, 0) // done>0 with no total is still an empty frame, not an excuse to invent total=5
	if _, err := os.Stat(pf); !os.IsNotExist(err) {
		t.Fatal("total<=0 with done>0 was written -- the grow rule must not defeat the suppression")
	}
}
