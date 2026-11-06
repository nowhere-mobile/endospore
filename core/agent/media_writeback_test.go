package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// #84 write-back. An app WRITES an updated media file through the overlay (Organic Maps updating a map). The
// real bytes land in the passthrough dir (.under); a stub the write supersedes is tombstoned so the overlay
// stops serving it and the seal drops the OLD deferred entry, while the walk re-chunks the NEW file. These use
// the real-FUSE overlayRaceSetup harness (two deferred maps one.mwm/two.mwm + an essential index.json) and the
// undersMapped seal injection (mediaUndersFn -> the .under bind) that mirrors mediad's live-overlay seal.

// mapUnders wires the seal walk to read this overlay's .under bind (the everyday live-overlay state).
func mapUnders(t *testing.T, srcB, overlayDir, under string) {
	prev := mediaUndersFn
	mediaUndersFn = func(s string) (map[string]string, error) {
		if s == srcB {
			return map[string]string{overlayDir: under}, nil
		}
		return nil, nil
	}
	t.Cleanup(func() { mediaUndersFn = prev })
}

// A brand-new file written through the overlay passes through to .under, lists in the overlay, and the seal
// captures it as a new deferred entry -- while the untouched deferred maps carry forward.
func TestOverlayCreateWritesThroughAndSeals(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-create")
	newContent := append(prBytes(3<<20), 0x33) // >threshold -> a deferred map; distinct from one/two
	if err := os.WriteFile(filepath.Join(overlayDir, "three.mwm"), newContent, 0o644); err != nil {
		t.Fatalf("create a new file through the overlay: %v", err)
	}
	// It really landed in the passthrough dir (so the seal, which reads .under, will find it).
	if b, err := os.ReadFile(filepath.Join(under, "three.mwm")); err != nil || !bytes.Equal(b, newContent) {
		t.Fatalf("new file not in .under: err=%v len=%d", err, len(b))
	}
	// It lists in the overlay alongside the deferred stubs.
	if _, err := os.Stat(filepath.Join(overlayDir, "three.mwm")); err != nil {
		t.Fatalf("new file must list/stat through the overlay: %v", err)
	}
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	if _, ok := m2.Deferred["app.maps/files/maps/three.mwm"]; !ok {
		t.Fatalf("new map not sealed as deferred; deferred=%v", keysOf(m2.Deferred))
	}
	for _, keep := range []string{"one.mwm", "two.mwm"} {
		rel := "app.maps/files/maps/" + keep
		if d2, ok := m2.Deferred[rel]; !ok || d2.Chunks[0] != m1.Deferred[rel].Chunks[0] {
			t.Fatalf("untouched deferred %s must carry forward unchanged; deferred=%v", keep, keysOf(m2.Deferred))
		}
	}
}

// OM's atomic update: download to a temp file, rename OVER the old <region>.mwm. The rename supersedes the
// deferred stub -- the overlay serves the new bytes at once, and the seal re-chunks one.mwm while two.mwm carries.
func TestOverlayRenameOverStubSupersedes(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-rename")
	oneRel := "app.maps/files/maps/one.mwm"
	newContent := append(prBytes(2<<20), 0x55) // the "updated" map, distinct from the original one.mwm
	tmp := filepath.Join(overlayDir, "one.mwm.downloading")
	if err := os.WriteFile(tmp, newContent, 0o644); err != nil {
		t.Fatalf("write temp through the overlay: %v", err)
	}
	if err := os.Rename(tmp, filepath.Join(overlayDir, "one.mwm")); err != nil {
		t.Fatalf("rename temp over the deferred stub: %v", err)
	}
	// The overlay now serves the NEW bytes at one.mwm (stub superseded), and .under holds the real file.
	if b, err := os.ReadFile(filepath.Join(overlayDir, "one.mwm")); err != nil || !bytes.Equal(b, newContent) {
		t.Fatalf("overlay must serve the renamed-in bytes at one.mwm: err=%v equal=%v", err, bytes.Equal(b, newContent))
	}
	if _, err := os.Stat(filepath.Join(under, "one.mwm")); err != nil {
		t.Fatalf("renamed file must be in .under: %v", err)
	}
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	if d2, ok := m2.Deferred[oneRel]; !ok || d2.Chunks[0] == m1.Deferred[oneRel].Chunks[0] {
		t.Fatalf("one.mwm must be RE-CHUNKED to the updated content (superseded), not the old chunks; deferred=%v", keysOf(m2.Deferred))
	}
	if twoRel := "app.maps/files/maps/two.mwm"; m2.Deferred[twoRel].Chunks[0] != m1.Deferred[twoRel].Chunks[0] {
		t.Fatalf("two.mwm (untouched) must carry forward unchanged; deferred=%v", keysOf(m2.Deferred))
	}
}

// Opening a deferred stub for writing (O_WRONLY|O_TRUNC) materializes it to a real file: the write lands on
// disk, the overlay serves the new content, and the seal supersedes the deferred entry.
func TestOverlayWriteOpenStubMaterializes(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-wopen")
	oneRel := "app.maps/files/maps/one.mwm"
	newContent := bytes.Repeat([]byte{0x77}, 8192) // >=threshold -> stays deferred; trivially distinct
	f, err := os.OpenFile(filepath.Join(overlayDir, "one.mwm"), os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		t.Fatalf("open a deferred stub for write (was EROFS before write-back): %v", err)
	}
	if _, err := f.Write(newContent); err != nil {
		f.Close()
		t.Fatalf("write to the materialized stub: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if b, err := os.ReadFile(filepath.Join(overlayDir, "one.mwm")); err != nil || !bytes.Equal(b, newContent) {
		t.Fatalf("overlay must serve the overwritten bytes: err=%v equal=%v len=%d", err, bytes.Equal(b, newContent), len(b))
	}
	if b, err := os.ReadFile(filepath.Join(under, "one.mwm")); err != nil || !bytes.Equal(b, newContent) {
		t.Fatalf("overwritten file must be a real file in .under: err=%v", err)
	}
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	if d2, ok := m2.Deferred[oneRel]; !ok || d2.Chunks[0] == m1.Deferred[oneRel].Chunks[0] {
		t.Fatalf("one.mwm must be re-chunked to the overwritten content; deferred=%v", keysOf(m2.Deferred))
	}
}
