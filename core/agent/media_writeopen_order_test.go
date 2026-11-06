package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// NWP-20261127-04: a write open over a live deferred stub tombstones it only AFTER the real file opened, so a write
// open that failed (EACCES, ENOSPC, EMFILE) keeps the stub served, listed and sealed.

const writeOpenRel = "app.maps/files/maps/one.mwm"

// failWriteOpen makes openForWrite's open(2) fail with EACCES for the rest of the test. Call it BEFORE
// overlayRaceSetup: the swap then lands before the mount starts, and the restore runs after the unmount.
func failWriteOpen(t *testing.T) {
	t.Helper()
	orig := writeOpenFile
	t.Cleanup(func() { writeOpenFile = orig })
	writeOpenFile = func(string, int, uint32) (int, error) { return -1, syscall.EACCES }
}

// openOverStubMustFail opens one.mwm through the overlay with flags and fails the test if the open landed.
func openOverStubMustFail(t *testing.T, overlayDir string, flags int) {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(overlayDir, "one.mwm"), flags, 0o644)
	if err == nil {
		f.Close()
		t.Fatalf("the write open (flags %#x) must fail when the real file cannot be opened", flags)
	}
}

// assertNoUnderCopy fails the test if a failed open left the stub's real file or a seed temp in .under.
func assertNoUnderCopy(t *testing.T, under string) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(under, "one.mwm")); !os.IsNotExist(err) {
		t.Fatalf("a failed write open must leave no file at the stub's .under path: err=%v", err)
	}
	seeds, err := filepath.Glob(filepath.Join(under, ".nwseed-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(seeds) != 0 {
		t.Fatalf("a failed write open left a seed temp: %v", seeds)
	}
}

// assertStubKept checks a failed write open left the stub served at its manifest size, untombstoned, and carried
// forward unchanged by the next seal.
func assertStubKept(t *testing.T, base, name, pass string, dk []byte, srcB, overlayDir, under string, m1 chunkManifest) {
	t.Helper()
	st, err := os.Stat(filepath.Join(overlayDir, "one.mwm"))
	if err != nil || st.Size() != m1.Deferred[writeOpenRel].Size {
		t.Fatalf("one.mwm must still stat at its manifest size after the failed write open: err=%v", err)
	}
	if b, err := os.ReadFile(filepath.Join(srcB, mediaCacheDirName, ".deleted")); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if l == writeOpenRel {
				t.Fatalf("a failed write open left a tombstone: %q", l)
			}
		}
	} else if !os.IsNotExist(err) {
		t.Fatal(err)
	}
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	if d2, ok := m2.Deferred[writeOpenRel]; !ok || d2.Chunks[0] != m1.Deferred[writeOpenRel].Chunks[0] {
		t.Fatalf("%s must carry forward unchanged; deferred=%v", writeOpenRel, keysOf(m2.Deferred))
	}
}

// A plain O_WRONLY open (the non-seeding path) whose open(2) fails keeps the stub.
func TestOverlayWriteOpenFailedOverStubKeepsIt(t *testing.T) {
	preGateSeal(t)
	failWriteOpen(t)
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-wopen-fail")
	openOverStubMustFail(t, overlayDir, os.O_WRONLY)
	assertNoUnderCopy(t, under)
	assertStubKept(t, base, name, pass, dk, srcB, overlayDir, under, m1)
}

// An O_RDWR open (the seeding path) whose seed copy landed but whose open(2) then failed keeps the stub and removes
// the seed copy this open made.
func TestOverlayRdwrOpenFailedOverStubKeepsIt(t *testing.T) {
	preGateSeal(t)
	failWriteOpen(t)
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-rdwr-fail")
	openOverStubMustFail(t, overlayDir, os.O_RDWR)
	assertNoUnderCopy(t, under)
	assertStubKept(t, base, name, pass, dk, srcB, overlayDir, under, m1)
}

// O_CREAT on a live stub arrives as OPEN (the kernel looks up first and Lookup serves the stub), so it reaches
// openForWrite and keeps the stub when the open fails.
func TestOverlayCreatFlagOverStubKeepsIt(t *testing.T) {
	preGateSeal(t)
	failWriteOpen(t)
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-creat-fail")
	openOverStubMustFail(t, overlayDir, os.O_CREATE|os.O_WRONLY)
	assertNoUnderCopy(t, under)
	assertStubKept(t, base, name, pass, dk, srcB, overlayDir, under, m1)
}

// A write open that lands still supersedes the stub: .deleted lists it and the overlay answers the real file.
func TestOverlayWriteOpenOverStubSupersedes(t *testing.T) {
	preGateSeal(t)
	_, _, _, _, srcB, overlayDir, _, _ := overlayRaceSetup(t, "od-wopen-ok")
	f, err := os.OpenFile(filepath.Join(overlayDir, "one.mwm"), os.O_WRONLY, 0)
	if err != nil {
		t.Fatalf("a write open over a stub must land: %v", err)
	}
	f.Close()
	b, err := os.ReadFile(filepath.Join(srcB, mediaCacheDirName, ".deleted"))
	if err != nil || !strings.Contains(string(b), writeOpenRel+"\n") {
		t.Fatalf(".deleted must list %q after a landed write open: err=%v body=%q", writeOpenRel, err, b)
	}
	st, err := os.Stat(filepath.Join(overlayDir, "one.mwm"))
	if err != nil || st.Size() != 0 {
		t.Fatalf("one.mwm must now answer the real (empty) file: err=%v", err)
	}
}
