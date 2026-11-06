package main

// NWP-20260908-19: A CHOWN ON A DEFERRED STUB MUST NOT DOWNLOAD THE FILE.
//
// mediad answers a Setattr on a stub by materializing it -- fetching the WHOLE file from the store into
// .under and tombstoning the stub. That is right for a truncate (write-back needs real bytes) and pure waste
// for an ownership change, because a stub's owner is SYNTHETIC: Getattr fills it from f.uid/f.gid and
// Setattr overwrites out.Owner with the same pair on the way out. The chown is discarded either way -- so the
// only thing the fetch buys is the download.
//
// IT IS REACHABLE ON THE SHIPPED FLEET. roamd's reown_ext_appdata is a `chown -R` over
// /data/media/$uid/Android/{data,obb}/<pkg>, and odrestore runs it on EVERY on-demand app tap
// (nowhere_roamd.sh) -- exactly the tree mediad overlays for that app's deferred media. So a tap silently
// pulls down every deferred stub under the app it just installed, defeating the deferral for precisely the
// apps the on-demand tier exists to keep light. The script says the opposite in as many words --
// "a chown that the FUSE rejects is harmless" -- and the FUSE does not reject it.
//
// Measured on lynx 2026-09-08 (build 2026090803, throwaway profile): a chown -R over a mounted DCIM/Camera
// left mediad logging "SETATTR materialized deferred stub ... for write-back" and a 1.6 MB photo in .under
// that was not there a moment earlier.

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestOverlayChownOnStubDoesNotMaterialize(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-chown")
	oneRel := "app.maps/files/maps/one.mwm"
	stub := filepath.Join(overlayDir, "one.mwm")

	// The bug needs .under to be EMPTY for this rel -- once a real file exists the materialize block is
	// skipped and a chown proves nothing. Assert the precondition rather than assume it.
	if _, err := os.Stat(filepath.Join(under, "one.mwm")); err == nil {
		t.Fatalf("setup: one.mwm is already materialized in .under, so this test cannot observe a fetch")
	}

	// A chown through the overlay. Same uid/gid the stub already reports, so the call needs no privilege and
	// still carries FATTR_UID|FATTR_GID down to mediad -- which is all it takes.
	if err := os.Chown(stub, os.Getuid(), os.Getgid()); err != nil {
		t.Fatalf("chown a deferred stub through the overlay: %v", err)
	}

	if _, err := os.Stat(filepath.Join(under, "one.mwm")); err == nil {
		t.Fatalf("a CHOWN materialized the deferred stub: one.mwm is now a real file in .under. mediad fetched " +
			"the whole file from the store to service an ownership change it then discards (Setattr overwrites " +
			"out.Owner with the synthetic pair regardless). On the fleet this fires on every on-demand app tap, " +
			"via roamd reown_ext_appdata, and downloads the deferred set of the app that was meant to stay light.")
	}

	// And the stub must still BE a stub end to end: same deferred entry, same chunks, after the next seal.
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	d2, ok := m2.Deferred[oneRel]
	if !ok {
		t.Fatalf("one.mwm left the deferred set after a chown; deferred=%v", keysOf(m2.Deferred))
	}
	if d2.Chunks[0] != m1.Deferred[oneRel].Chunks[0] {
		t.Errorf("one.mwm was re-chunked after a chown -- it was materialized and re-sealed as new bytes, " +
			"which is the same waste seen from the store side rather than the disk side")
	}
}

// THE CONTROL: a TRUNCATE must still materialize. The fix narrows Setattr, and narrowing it too far would
// break #84 write-back -- an app updating a map in place needs the real bytes on disk.
func TestOverlayTruncateOnStubStillMaterializes(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	_, _, _, _, _, overlayDir, under, _ := overlayRaceSetup(t, "od-trunc")
	if err := os.Truncate(filepath.Join(overlayDir, "one.mwm"), 1024); err != nil {
		t.Fatalf("truncate a deferred stub through the overlay: %v", err)
	}
	fi, err := os.Stat(filepath.Join(under, "one.mwm"))
	if err != nil {
		t.Fatalf("a truncate must still materialize the stub (write-back needs real bytes): %v", err)
	}
	if fi.Size() != 1024 {
		t.Errorf("materialized file is %d bytes, want the truncated 1024", fi.Size())
	}
}

// NWP-20261011-41: A TIMES-ONLY SETATTR (utimensat) ON A DEFERRED STUB MUST NOT DOWNLOAD THE FILE EITHER.
//
// The backlog row NWP-20260829-05 found the same fall-through for timestamps: a SETATTR carrying only
// atime/mtime took the materialize arm, called fetchFile and tombstoned the stub -- so a touch or an
// mtime-preserving copy through a live overlay de-deferred every file it walked. NWP-20260908-19's guard
// (`if !wantSize && !wantMode` in mediaFile.Setattr) covers it, but only the chown above was ever tested;
// this pins the times-only half so a guard narrowed back to ownership alone fails here.
func TestOverlayUtimesOnStubDoesNotMaterialize(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-utimes")
	oneRel := "app.maps/files/maps/one.mwm"
	stub := filepath.Join(overlayDir, "one.mwm")

	// Same precondition as the chown test: with a real file in .under the materialize block is skipped.
	if _, err := os.Stat(filepath.Join(under, "one.mwm")); err == nil {
		t.Fatalf("setup: one.mwm is already materialized in .under, so this test cannot observe a fetch")
	}

	// A time the stub does not already report, so the kernel cannot elide the call: FATTR_ATIME|FATTR_MTIME
	// and nothing else reach mediad. Owner-only privilege is enough (the test owns the mount).
	fi, err := os.Stat(stub)
	if err != nil {
		t.Fatalf("stat the deferred stub through the overlay: %v", err)
	}
	when := fi.ModTime().Add(-48 * time.Hour).Truncate(time.Second)
	if err := os.Chtimes(stub, when, when); err != nil {
		t.Fatalf("set times on a deferred stub through the overlay: %v", err)
	}

	if _, err := os.Stat(filepath.Join(under, "one.mwm")); err == nil {
		t.Fatalf("a times-only SETATTR materialized the deferred stub: one.mwm is now a real file in .under. " +
			"mediad fetched the whole file from the store to service a utimensat a stub cannot persist, and " +
			"tombstoned the deferred entry -- anything touching mtimes through a live overlay de-defers what it walks.")
	}

	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	d2, ok := m2.Deferred[oneRel]
	if !ok {
		t.Fatalf("one.mwm left the deferred set after a times-only setattr; deferred=%v", keysOf(m2.Deferred))
	}
	if d2.Chunks[0] != m1.Deferred[oneRel].Chunks[0] {
		t.Errorf("one.mwm was re-chunked after a times-only setattr -- it was materialized and re-sealed as new bytes")
	}
}
