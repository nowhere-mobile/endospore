package main

// build_warning_floor_durable_test.go -- the build warning's seq floor is published through a synced temp file
// (NWP-20261123-30): a failed sync leaves the old floor and no temp, and only a new object is synced and written.

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// bwdFailSync makes buildWarningFloorSync fail, counting its calls; restored at cleanup.
func bwdFailSync(t *testing.T) *int {
	t.Helper()
	n := new(int)
	old := buildWarningFloorSync
	buildWarningFloorSync = func(*os.File) error {
		*n++
		return errors.New("injected sync failure")
	}
	t.Cleanup(func() { buildWarningFloorSync = old })
	return n
}

// bwdCountSync counts buildWarningFloorSync's calls and still syncs; restored at cleanup.
func bwdCountSync(t *testing.T) *int {
	t.Helper()
	n := new(int)
	old := buildWarningFloorSync
	buildWarningFloorSync = func(f *os.File) error {
		*n++
		return old(f)
	}
	t.Cleanup(func() { buildWarningFloorSync = old })
	return n
}

// bwdNoTmp fails the test when a temp file is left beside the floor.
func bwdNoTmp(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path + ".tmp"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a temp file was left beside the floor: %v", err)
	}
}

func TestBuildWarningFloorDurableFailedSyncKeepsFloor(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	before := "3 " + bwfHash(bwfFresh(k, 3, "0.5.45")) + "\n"
	if err := os.WriteFile(floor, []byte(before), 0o600); err != nil {
		t.Fatal(err)
	}
	n := bwdFailSync(t)
	w, err := acceptBuildWarning(floor, bwfFresh(k, 4, "0.5.45"), bwNow)
	if err != nil || w == nil || w.Seq != 4 {
		t.Fatalf("a failed floor sync suppressed the warning: %+v, %v", w, err)
	}
	if *n < 1 {
		t.Errorf("the floor was not published through the synced temp file (sync calls %d)", *n)
	}
	if got, ok := bwfRead(t, floor); !ok || got != before {
		t.Errorf("a failed sync changed the floor: %q (present %v), want %q", got, ok, before)
	}
	bwdNoTmp(t, floor)
}

func TestBuildWarningFloorDurableFailedSyncNoFloor(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	n := bwdFailSync(t)
	w, err := acceptBuildWarning(floor, bwfFresh(k, 4, "0.5.45"), bwNow)
	if err != nil || w == nil || w.Seq != 4 {
		t.Fatalf("a failed floor sync suppressed the warning: %+v, %v", w, err)
	}
	if *n < 1 {
		t.Errorf("the floor was not published through the synced temp file (sync calls %d)", *n)
	}
	if got, ok := bwfRead(t, floor); ok {
		t.Errorf("a failed sync created the floor: %q", got)
	}
	bwdNoTmp(t, floor)
}

func TestBuildWarningFloorDurableSyncsOnce(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	n := bwdCountSync(t)
	env := bwfFresh(k, 4, "0.5.45")
	if w, err := acceptBuildWarning(floor, env, bwNow); err != nil || w == nil || w.Seq != 4 {
		t.Fatalf("a new object was not accepted: %+v, %v", w, err)
	}
	if *n != 1 {
		t.Errorf("a new accept synced the floor %d times, want 1", *n)
	}
	if got, _ := bwfRead(t, floor); got != "4 "+bwfHash(env)+"\n" {
		t.Errorf("floor = %q, want seq 4 and the envelope's hash", got)
	}
	if seq, h, err := readBuildWarningFloor(floor); err != nil || seq != 4 || h != bwfHash(env) {
		t.Errorf("readBuildWarningFloor = %d, %q, %v", seq, h, err)
	}
	bwdNoTmp(t, floor)

	*n = 0
	if w, err := acceptBuildWarning(floor, env, bwNow+3600); err != nil || w == nil || w.Seq != 4 {
		t.Fatalf("the same object was not re-accepted: %+v, %v", w, err)
	}
	if *n != 0 {
		t.Errorf("a same-object re-accept synced the floor %d times, want 0 (nothing is written)", *n)
	}
}

func TestBuildWarningFloorDurableMissingDir(t *testing.T) {
	floor := filepath.Join(t.TempDir(), "missing", "build-warning-seq")
	if err := writeBuildWarningFloor(floor, 4, strings.Repeat("ab", 32)); err == nil {
		t.Fatal("a floor write at a missing dir reported success")
	}
	if _, err := os.Lstat(filepath.Dir(floor)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("something was created at the floor's dir: %v", err)
	}
}
