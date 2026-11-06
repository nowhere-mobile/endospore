package main

// NWP-20261112-09: the publish fence's SEQUENCE half fails closed, like its markers. An unreadable or garbled
// `.seq` reads -1 and blocks every sampled publish; a bump is temp + rename and reports its failure; a lift
// bumps before it removes and removes nothing when it cannot bump; an arm whose bump fails returns false.
// test-fence-seq.sh --mutate convicts each of those against these tests.

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fenceSeqTestPath() string { return filepath.Join(sealFenceDir(), sealFenceSeqName) }

// fenceSeqPlantTmpDir makes `.seq.tmp` a non-empty DIRECTORY, so a bump's temp write fails and the temp
// cannot be removed either.
func fenceSeqPlantTmpDir(t *testing.T) {
	t.Helper()
	tmp := filepath.Join(sealFenceDir(), sealFenceSeqTmpName)
	if err := os.MkdirAll(tmp, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "keep"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func fenceSeqWrite(t *testing.T, content string) {
	t.Helper()
	if err := os.MkdirAll(sealFenceDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fenceSeqTestPath(), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// S1: a `.seq` that exists but cannot be read is -1, not 0, and a push whose sample was -1 is refused.
func TestFenceSeqUnreadableReadsMinusOne(t *testing.T) {
	fenceTestEnv(t)
	if err := os.MkdirAll(fenceSeqTestPath(), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := sealFenceSeq(); got != -1 {
		t.Fatalf("sealFenceSeq() with .seq a directory = %d, want -1 (unreadable must not read as never armed)", got)
	}
	pushFenceSeq, pushFenceSampled = sealFenceSeq(), true
	if !sealFencePublishBlocked("ref/" + strings.Repeat("e1", 32)) {
		t.Fatal("an unfenced publish passed although the fence sequence was unreadable at the sample and now")
	}
}

// S2: garbled content is -1 and blocks; a well-formed counter is read exactly and compared.
func TestFenceSeqGarbledReadsMinusOne(t *testing.T) {
	fenceTestEnv(t)
	ref := "ref/" + strings.Repeat("e2", 32)
	fenceSeqWrite(t, "x\n")
	if got := sealFenceSeq(); got != -1 {
		t.Fatalf("sealFenceSeq() of %q = %d, want -1", "x\n", got)
	}
	pushFenceSeq, pushFenceSampled = sealFenceSeq(), true
	if !sealFencePublishBlocked(ref) {
		t.Fatal("a garbled fence sequence did not block the publish")
	}
	fenceSeqWrite(t, "7\n")
	pushFenceSeq, pushFenceSampled = sealFenceSeq(), true
	if pushFenceSeq != 7 {
		t.Fatalf("sealFenceSeq() of %q = %d, want 7", "7\n", pushFenceSeq)
	}
	if sealFencePublishBlocked(ref) {
		t.Fatal("an unmoved fence sequence blocked the publish")
	}
	fenceSeqWrite(t, "8\n")
	if !sealFencePublishBlocked(ref) {
		t.Fatal("a fence sequence that moved 7 -> 8 did not block the publish")
	}
}

// S3 (control): no fence dir at all is 0, and a push that sampled 0 publishes.
func TestFenceSeqAbsentReadsZero(t *testing.T) {
	fenceTestEnv(t)
	if got := sealFenceSeq(); got != 0 {
		t.Fatalf("sealFenceSeq() with no fence dir = %d, want 0", got)
	}
	pushFenceSeq, pushFenceSampled = sealFenceSeq(), true
	if sealFencePublishBlocked("ref/" + strings.Repeat("e3", 32)) {
		t.Fatal("a publish with no fence at all was blocked")
	}
}

// S4: a lift whose bump fails removes no marker and reports false; the sequence is unchanged.
func TestFenceSeqFailedLiftRemovesNothing(t *testing.T) {
	fenceTestEnv(t)
	a, b := strings.Repeat("a4", 32), strings.Repeat("b4", 32)
	if !armSealFence([]string{a, b}) {
		t.Fatal("arm failed")
	}
	if got := sealFenceSeq(); got != 1 {
		t.Fatalf("sequence after one arm = %d, want 1", got)
	}
	fenceSeqPlantTmpDir(t)
	ok := liftSealFence([]string{a, b})
	if !sealFenceBlocks(a) || !sealFenceBlocks(b) {
		t.Fatal("a lift whose sequence bump failed removed a marker: the fence is cleared without moving")
	}
	if got := sealFenceSeq(); got != 1 {
		t.Fatalf("sequence after a failed lift = %d, want 1", got)
	}
	if ok {
		t.Fatal("liftSealFence reported success although the sequence could not be advanced")
	}
}

// S5: an arm whose bump fails returns false, and the markers it wrote stay.
func TestFenceSeqFailedArmBumpReturnsFalse(t *testing.T) {
	fenceTestEnv(t)
	a, b := strings.Repeat("a5", 32), strings.Repeat("b5", 32)
	if err := os.MkdirAll(sealFenceDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	fenceSeqPlantTmpDir(t)
	if armSealFence([]string{a, b}) {
		t.Fatal("armSealFence reported success although the sequence could not be advanced")
	}
	if !sealFenceBlocks(a) || !sealFenceBlocks(b) {
		t.Fatal("the markers of an arm whose bump failed are missing")
	}
}

// S6: a bump replaces `.seq` by rename: a reader holding the old file still reads the old complete value, and
// no temp is left behind.
func TestFenceSeqBumpIsAtomicRename(t *testing.T) {
	fenceTestEnv(t)
	fenceSeqWrite(t, "3\n")
	f, err := os.Open(fenceSeqTestPath())
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sealFenceMu.Lock()
	err = bumpSealFenceSeqLocked(sealFenceDir())
	sealFenceMu.Unlock()
	if err != nil {
		t.Fatalf("bump: %v", err)
	}
	old, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	if string(old) != "3\n" {
		t.Fatalf("the old .seq read %q after a bump, want %q: the bump rewrote the file in place", old, "3\n")
	}
	if _, err := os.Lstat(filepath.Join(sealFenceDir(), sealFenceSeqTmpName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf(".seq.tmp after a bump: %v, want it gone", err)
	}
	if got := sealFenceSeq(); got != 4 {
		t.Fatalf("sequence after the bump = %d, want 4", got)
	}
}

// Control: a lift with nothing armed bumps nothing and succeeds; a lift of armed markers bumps and removes them.
func TestFenceSeqLiftBumpsOnlyWhenSomethingIsArmed(t *testing.T) {
	fenceTestEnv(t)
	a := strings.Repeat("a7", 32)
	if !liftSealFence([]string{a}) {
		t.Fatal("a lift with nothing armed reported failure")
	}
	if got := sealFenceSeq(); got != 0 {
		t.Fatalf("sequence after a no-op lift = %d, want 0", got)
	}
	if !armSealFence([]string{a}) {
		t.Fatal("arm failed")
	}
	if !liftSealFence([]string{a}) {
		t.Fatal("lift failed")
	}
	if sealFenceBlocks(a) {
		t.Fatal("the marker survived a successful lift")
	}
	if got := sealFenceSeq(); got != 2 {
		t.Fatalf("sequence after arm + lift = %d, want 2", got)
	}
}
