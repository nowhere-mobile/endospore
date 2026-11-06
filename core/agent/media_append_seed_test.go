package main

import (
	"bytes"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// NWP-20261109-01: an append to a deferred media file keeps the file's bytes. The kernel sends every append at
// the stub's size, so a backing file created empty would hold that many zeros before the tail.

func TestWriteOpenSeeds(t *testing.T) {
	for _, tc := range []struct {
		name  string
		flags uint32
		want  bool
	}{
		{"O_RDWR", syscall.O_RDWR, true},
		{"O_RDWR|O_TRUNC", syscall.O_RDWR | syscall.O_TRUNC, false},
		{"O_WRONLY", syscall.O_WRONLY, false},
		{"O_WRONLY|O_APPEND", syscall.O_WRONLY | syscall.O_APPEND, true},
		{"O_WRONLY|O_APPEND|O_TRUNC", syscall.O_WRONLY | syscall.O_APPEND | syscall.O_TRUNC, false},
		{"O_RDWR|O_APPEND", syscall.O_RDWR | syscall.O_APPEND, true},
		{"O_RDONLY", syscall.O_RDONLY, false},
	} {
		if got := writeOpenSeeds(tc.flags); got != tc.want {
			t.Errorf("writeOpenSeeds(%s) = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestOverlayAppendKeepsDeferredBytes(t *testing.T) {
	preGateSeal(t) // a vault head an older handset wrote; serving it is unchanged
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-append")
	oneRel := "app.maps/files/maps/one.mwm"
	f, err := os.OpenFile(filepath.Join(overlayDir, "one.mwm"), os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatalf("open a deferred stub for append: %v", err)
	}
	if _, err := f.Write([]byte("TAIL")); err != nil {
		f.Close()
		t.Fatalf("append: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	want := append(prBytes(6<<20), "TAIL"...)
	if b, err := os.ReadFile(filepath.Join(overlayDir, "one.mwm")); err != nil || !bytes.Equal(b, want) {
		t.Fatalf("overlay must serve the original bytes plus the tail: err=%v len=%d want=%d equal=%v", err, len(b), len(want), bytes.Equal(b, want))
	}
	if b, err := os.ReadFile(filepath.Join(under, "one.mwm")); err != nil || !bytes.Equal(b, want) {
		t.Fatalf("the real file must hold the original bytes plus the tail: err=%v len=%d want=%d equal=%v", err, len(b), len(want), bytes.Equal(b, want))
	}
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	if d2, ok := m2.Deferred[oneRel]; !ok || d2.Size != int64(6<<20+4) {
		t.Fatalf("one.mwm must seal at %d bytes; deferred=%v", 6<<20+4, keysOf(m2.Deferred))
	}
	if twoRel := "app.maps/files/maps/two.mwm"; m2.Deferred[twoRel].Chunks[0] != m1.Deferred[twoRel].Chunks[0] {
		t.Fatalf("two.mwm (untouched) must carry forward unchanged; deferred=%v", keysOf(m2.Deferred))
	}
}
