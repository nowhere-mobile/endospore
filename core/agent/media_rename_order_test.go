package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// NWP-20261110-09: a rename over a live deferred stub tombstones it only AFTER the loopback rename landed.
func TestSupersedeAfterTombstonesOnlyALandedOp(t *testing.T) {
	const rel = "app.maps/files/maps/two.mwm"
	cases := []struct {
		name     string
		errno    syscall.Errno
		live     bool
		wantDel  bool
		wantFile bool
	}{
		{"failed op over a live stub keeps it", syscall.ENOENT, true, false, false},
		{"landed op over a live stub supersedes it", 0, true, true, true},
		{"landed op over a non-stub takes no tombstone", 0, false, false, false},
		{"failed op over a non-stub passes the errno through", syscall.EXDEV, false, false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := &mediaServer{cacheDir: t.TempDir()}
			calls, deletedInOp := 0, false
			got := supersedeAfter(srv, rel, c.live, func() syscall.Errno {
				calls++
				deletedInOp = srv.isDeleted(rel)
				return c.errno
			})
			if got != c.errno {
				t.Fatalf("errno = %v, want %v", got, c.errno)
			}
			if calls != 1 {
				t.Fatalf("op ran %d times, want 1", calls)
			}
			if deletedInOp {
				t.Fatalf("the tombstone was taken before the op ran")
			}
			if srv.isDeleted(rel) != c.wantDel {
				t.Fatalf("isDeleted = %v, want %v", srv.isDeleted(rel), c.wantDel)
			}
			b, err := os.ReadFile(filepath.Join(srv.cacheDir, ".deleted"))
			if c.wantFile {
				if err != nil || !strings.Contains(string(b), rel+"\n") {
					t.Fatalf(".deleted must list %q: err=%v body=%q", rel, err, b)
				}
			} else if !os.IsNotExist(err) {
				t.Fatalf("no .deleted file expected: err=%v body=%q", err, b)
			}
		})
	}
}

// Renaming one stub over another reaches the loopback as ENOENT (a stub has no bytes in .under). The app is told
// the rename failed, so neither stub may vanish from the overlay or be dropped at the next seal.
func TestOverlayRenameFailedOverStubKeepsIt(t *testing.T) {
	preGateSeal(t)
	base, name, pass, dk, srcB, overlayDir, under, m1 := overlayRaceSetup(t, "od-rename-fail")
	oneRel, twoRel := "app.maps/files/maps/one.mwm", "app.maps/files/maps/two.mwm"
	if err := os.Rename(filepath.Join(overlayDir, "one.mwm"), filepath.Join(overlayDir, "two.mwm")); err == nil {
		t.Fatalf("renaming a stub over a stub must fail (the source has no bytes in .under)")
	}
	for leaf, rel := range map[string]string{"one.mwm": oneRel, "two.mwm": twoRel} {
		st, err := os.Stat(filepath.Join(overlayDir, leaf))
		if err != nil || st.Size() != m1.Deferred[rel].Size {
			t.Fatalf("%s must still stat at its manifest size after the failed rename: err=%v", leaf, err)
		}
	}
	if b, err := os.ReadFile(filepath.Join(srcB, mediaCacheDirName, ".deleted")); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if l == oneRel || l == twoRel {
				t.Fatalf("a failed rename left a tombstone: %q", l)
			}
		}
	} else if !os.IsNotExist(err) {
		t.Fatal(err)
	}
	mapUnders(t, srcB, overlayDir, under)
	pushProfile(base, name, pass, srcB)
	m2 := headManifest(t, base, dk, name, pass)
	for _, rel := range []string{oneRel, twoRel} {
		if d2, ok := m2.Deferred[rel]; !ok || d2.Chunks[0] != m1.Deferred[rel].Chunks[0] {
			t.Fatalf("%s must carry forward unchanged; deferred=%v", rel, keysOf(m2.Deferred))
		}
	}
}
