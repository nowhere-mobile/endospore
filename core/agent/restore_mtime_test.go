package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20260829-01. untarFrom applied hdr.Mode but never hdr.ModTime, so every file restored at login got the
// wall clock of the RESTORE. The seal writes info.ModTime() straight into the ustar header, so the next
// logoff's tar differed from the previous session in essentially every chunk -- measured on lynx as 62 of
// 1453 chunks skipped and ~1.8 GB re-uploaded on FOUR consecutive login/logoff cycles, with no reboot
// involved. These tests pin the restored mtimes, and then the property that actually matters: a re-seal of a
// freshly restored tree must reproduce the SAME content-addressed chunks.

func seedTree(t *testing.T, root string) map[string]time.Time {
	t.Helper()
	want := map[string]time.Time{}
	for i := 0; i < 12; i++ {
		rel := fmt.Sprintf("app.example/files/sub%d/f%02d.dat", i%3, i)
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, bytes.Repeat([]byte{byte(i)}, 4096+i), 0o644); err != nil {
			t.Fatal(err)
		}
		mt := time.Date(2019, 3, 4, 5, 6, 7+i, 0, time.UTC)
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
		want[rel] = mt
	}
	return want
}

func TestRestorePreservesFileMTimes(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "mtimefiles", "mtime horse battery staple"
	createVault(base, name, pass)

	srcA := t.TempDir()
	want := seedTree(t, srcA)
	pushProfile(base, name, pass, srcA)
	_, srcB := restoreManifest(t, base, name, pass)

	for rel, mt := range want {
		fi, err := os.Stat(filepath.Join(srcB, filepath.FromSlash(rel)))
		if err != nil {
			t.Fatalf("restored %s missing: %v", rel, err)
		}
		if got := fi.ModTime().UTC(); !got.Equal(mt) {
			t.Errorf("restored %s mtime = %v, want %v -- the restore stamped its own clock, so the next seal re-uploads it",
				rel, got, mt)
		}
	}
}

// Directories need a SECOND pass: writing a file into a directory updates that directory's mtime, so a
// stamp applied during the walk is undone by the very next child.
func TestRestorePreservesDirectoryMTimes(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "mtimedirs", "mtime horse battery staple"
	createVault(base, name, pass)

	srcA := t.TempDir()
	seedTree(t, srcA)
	dirRel := "app.example/files/sub0"
	dirMT := time.Date(2018, 11, 12, 13, 14, 15, 0, time.UTC)
	if err := os.Chtimes(filepath.Join(srcA, filepath.FromSlash(dirRel)), dirMT, dirMT); err != nil {
		t.Fatal(err)
	}

	pushProfile(base, name, pass, srcA)
	_, srcB := restoreManifest(t, base, name, pass)

	fi, err := os.Stat(filepath.Join(srcB, filepath.FromSlash(dirRel)))
	if err != nil {
		t.Fatalf("restored dir %s missing: %v", dirRel, err)
	}
	if got := fi.ModTime().UTC(); !got.Equal(dirMT) {
		t.Errorf("restored dir %s mtime = %v, want %v -- a dir stamped before its children land is re-dirtied by them",
			dirRel, got, dirMT)
	}
}

// THE PROPERTY THAT ACTUALLY MATTERS: a login/logoff cycle that changes nothing must re-seal to the SAME
// content-addressed chunks, so the logoff uploads nothing.
//
// It is stated as CONVERGENCE (cycle N vs N+1), not as equality with the very first seal, because
// writeTarEntry emits USTAR, whose mtime field holds WHOLE SECONDS -- Go rounds 750.953s to 751s on write
// (verified directly against writeTarEntry). So a tree whose files carry sub-second mtimes legitimately
// seals to a slightly different header the first time round, then stops changing. Cycle-to-cycle stability
// is the thing a user's data bill actually depends on, and it is what was broken: before the fix EVERY cycle
// differed, forever, because the restore stamped its own clock instead of the recorded one.
func TestResealIsStableAcrossLoginCycles(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "mtimereseal", "mtime horse battery staple"
	createVault(base, name, pass)

	srcA := t.TempDir()
	seedTree(t, srcA)
	pushProfile(base, name, pass, srcA)
	dk := resolveDK(base, name, pass, nil)

	// cycle 1: login -> logoff
	_, srcB := restoreManifest(t, base, name, pass)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)

	// cycle 2: login -> logoff, touching nothing in between.
	// The sleep is LOAD-BEARING, not politeness: USTAR mtimes are whole seconds, and the whole test runs in
	// ~60ms, so without it both restores land in the SAME second and a broken restore that stamps its own
	// clock produces identical headers anyway -- the test passed against the pre-fix code until this was
	// added. Sleeping past a second boundary is what makes "the restore used its own clock" observable.
	time.Sleep(1100 * time.Millisecond)

	_, srcC := restoreManifest(t, base, name, pass)
	pushProfile(base, name, pass, srcC)
	m3 := headManifest(t, base, dk, name, pass)

	if len(m2.Chunks) != len(m3.Chunks) {
		t.Fatalf("two identical login/logoff cycles produced %d then %d chunks", len(m2.Chunks), len(m3.Chunks))
	}
	diff := 0
	for i := range m2.Chunks {
		if m2.Chunks[i] != m3.Chunks[i] {
			diff++
		}
	}
	if diff != 0 {
		t.Fatalf("a login/logoff cycle that changed NOTHING moved %d of %d chunk hashes -- every one is a "+
			"needless re-upload at logoff (NWP-20260828-15: measured as 1391 of 1453 on lynx, ~1.8 GB)",
			diff, len(m2.Chunks))
	}
}
