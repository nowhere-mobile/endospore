package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// writeAtomicFile publishes the device flags, the sync interval and the signed catalog and index through the synced
// writeConfDurable (NWP-20261126-19): the temp file is synced before the rename, and a failed sync leaves the old
// file and no temp file, so a power cut never leaves an empty file that reads back as the default.

// atomicFileFailSync makes confFileSync fail until the test ends and returns a pointer to its call count.
func atomicFileFailSync(t *testing.T) *int {
	t.Helper()
	old := confFileSync
	calls := 0
	confFileSync = func(*os.File) error { calls++; return errors.New("injected sync failure") }
	t.Cleanup(func() { confFileSync = old })
	return &calls
}

func atomicFileNoTmp(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("%s.tmp is left behind (stat err %v)", path, err)
	}
}

// The temp file is synced exactly once, before the rename: at the sync, path still holds the old bytes.
func TestWriteAtomicFileSyncsBeforeTheRename(t *testing.T) {
	path := filepath.Join(t.TempDir(), "catalog.json")
	oldB, newB := []byte("old\n"), []byte("new\n")
	if err := os.WriteFile(path, oldB, 0o600); err != nil {
		t.Fatal(err)
	}
	realSync := confFileSync
	t.Cleanup(func() { confFileSync = realSync })
	calls := 0
	var atSync []byte
	confFileSync = func(f *os.File) error {
		calls++
		atSync, _ = os.ReadFile(path)
		return realSync(f)
	}
	if err := writeAtomicFile(path, newB); err != nil {
		t.Fatalf("writeAtomicFile: %v", err)
	}
	if calls != 1 {
		t.Fatalf("confFileSync called %d times, want 1: the publish is not synced before the rename", calls)
	}
	if !bytes.Equal(atSync, oldB) {
		t.Errorf("at the sync path held %q, want the old %q: the rename ran before the sync", atSync, oldB)
	}
	if got, _ := os.ReadFile(path); !bytes.Equal(got, newB) {
		t.Errorf("path holds %q after the publish, want %q", got, newB)
	}
	atomicFileNoTmp(t, path)
}

// A failed sync returns the error, keeps the old file and leaves no temp file.
func TestWriteAtomicFileFailedSyncKeepsTheOldFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.json")
	oldB := []byte("old\n")
	if err := os.WriteFile(path, oldB, 0o600); err != nil {
		t.Fatal(err)
	}
	calls := atomicFileFailSync(t)
	if err := writeAtomicFile(path, []byte("new\n")); err == nil {
		t.Error("writeAtomicFile returned nil after a failed sync")
	}
	if *calls == 0 {
		t.Error("writeAtomicFile did not publish through the synced temp file (confFileSync was never called)")
	}
	if got, _ := os.ReadFile(path); !bytes.Equal(got, oldB) {
		t.Errorf("path holds %q after a failed sync, want the old %q", got, oldB)
	}
	atomicFileNoTmp(t, path)
}

// otaAutoSet through a failed sync answers an error and the flag stays off; through the real sync it is on.
func TestWriteAtomicFileThroughTheDeviceFlag(t *testing.T) {
	oldPath := otaAutoPath
	t.Cleanup(func() { otaAutoPath = oldPath })
	otaAutoPath = filepath.Join(t.TempDir(), "ota-auto")
	realSync := confFileSync
	atomicFileFailSync(t)
	if err := otaAutoSet(true); err == nil {
		t.Error("otaAutoSet(true) returned nil after a failed sync: the OK was not durable")
	}
	if got := otaAutoGet(); got != "0" {
		t.Errorf("otaAutoGet after a failed sync = %q, want \"0\"", got)
	}
	atomicFileNoTmp(t, otaAutoPath)
	confFileSync = realSync
	if err := otaAutoSet(true); err != nil {
		t.Fatalf("otaAutoSet(true): %v", err)
	}
	if got := otaAutoGet(); got != "1" {
		t.Errorf("otaAutoGet = %q, want \"1\"", got)
	}
	atomicFileNoTmp(t, otaAutoPath)
}

// syncIntervalSet through a failed sync answers an error and the default stays; through the real sync it is set.
func TestWriteAtomicFileThroughTheSyncInterval(t *testing.T) {
	t.Setenv("NOWHERE_SYNC_INTERVAL", "")
	oldPath := syncIntervalPath
	t.Cleanup(func() { syncIntervalPath = oldPath })
	syncIntervalPath = filepath.Join(t.TempDir(), "sync-interval")
	realSync := confFileSync
	atomicFileFailSync(t)
	if err := syncIntervalSet(300); err == nil {
		t.Error("syncIntervalSet(300) returned nil after a failed sync: the OK was not durable")
	}
	if got := syncIntervalGet(); got != syncIntervalDefault {
		t.Errorf("syncIntervalGet after a failed sync = %d, want the default %d", got, syncIntervalDefault)
	}
	atomicFileNoTmp(t, syncIntervalPath)
	confFileSync = realSync
	if err := syncIntervalSet(300); err != nil {
		t.Fatalf("syncIntervalSet(300): %v", err)
	}
	if got := syncIntervalGet(); got != 300 {
		t.Errorf("syncIntervalGet = %d, want 300", got)
	}
	atomicFileNoTmp(t, syncIntervalPath)
}
