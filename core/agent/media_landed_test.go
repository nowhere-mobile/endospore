package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261114-34: a background run that makes files local raises $NOWHERE_STATE/media.landed, so the gate can start the
// session's media rescan; a run that lands nothing leaves it alone.

func readLanded(t *testing.T, stateDir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(stateDir, mediaLandedFile))
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func TestBumpMediaLandedCountsFromOneAndRecoversFromGarbage(t *testing.T) {
	st := t.TempDir()
	bumpMediaLanded(st, "test")
	bumpMediaLanded(st, "test")
	if got := readLanded(t, st); got != "2" {
		t.Fatalf("two bumps from an absent counter: got %q, want 2", got)
	}
	if err := os.WriteFile(filepath.Join(st, mediaLandedFile), []byte("not a number\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	bumpMediaLanded(st, "test")
	if got := readLanded(t, st); got != "1" {
		t.Fatalf("an unreadable counter starts again from 1: got %q", got)
	}
	if fi, err := os.Stat(filepath.Join(st, mediaLandedFile)); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("counter must be 0600: %v %v", fi, err)
	}
	if _, err := os.Stat(filepath.Join(st, mediaLandedFile+".tmp")); !os.IsNotExist(err) {
		t.Fatalf("the temp file must be renamed away, stat err %v", err)
	}
	bumpMediaLanded("", "test") // no state dir: a no-op, never a write into the working directory
	if _, err := os.Stat(mediaLandedFile); !os.IsNotExist(err) {
		t.Fatalf("an empty state dir must write nothing, stat err %v", err)
	}
}

func TestMaterializeRaisesTheLandedCounterOnlyWhenItLandsFiles(t *testing.T) {
	preGateSeal(t)
	base, _, _, dk, srcB, _, under, m1 := overlayRaceSetup(t, "od-landed")
	const rel = "app.maps/files/maps/one.mwm"
	if _, ok := m1.Deferred[rel]; !ok {
		t.Fatalf("harness must leave %s deferred; deferred=%v", rel, keysOf(m1.Deferred))
	}
	st := t.TempDir()
	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	srv.stateDir = st

	// A pin set that selects nothing lands nothing: no counter.
	srv.materializePins(map[string]bool{"app.none": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)
	if got := readLanded(t, st); got != "" {
		t.Fatalf("a run that landed nothing must not raise the counter, got %q", got)
	}
	// No live overlay for the file's dir: skipped, nothing landed, no counter.
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{}, nil)
	if got := readLanded(t, st); got != "" {
		t.Fatalf("a run whose files all skipped must not raise the counter, got %q", got)
	}
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)
	if _, err := os.Stat(filepath.Join(under, "one.mwm")); err != nil {
		t.Fatalf("control: the pin run must land the file: %v", err)
	}
	if got := readLanded(t, st); got != "1" {
		t.Fatalf("a run that landed a file must raise the counter to 1, got %q", got)
	}
}

func TestLanderFinishRaisesTheLandedCounterOnlyWhenItWrote(t *testing.T) {
	st := t.TempDir()
	prog := &mediaServer{progPath: filepath.Join(st, mediaProgressFile)}
	l := newBgLander(st, t.TempDir(), nil, chunkManifest{}, prog)
	l.finish()
	if got := readLanded(t, st); got != "" {
		t.Fatalf("a lander that wrote nothing must not raise the counter, got %q", got)
	}
	l2 := newBgLander(st, t.TempDir(), nil, chunkManifest{}, prog)
	l2.mu.Lock()
	l2.onWritten("DCIM/Camera/a.jpg")
	l2.mu.Unlock()
	l2.finish()
	if got := readLanded(t, st); got != "1" {
		t.Fatalf("a lander that wrote a file must raise the counter at finish, got %q", got)
	}
}

// NWP-20261116-38: mounting the #media overlays raises the counter, so the gate rescans while the files waiting in the
// store are visible; a start that mounted no #media overlay leaves it alone.
func TestAnnounceMediaOverlaysRaisesTheCounterOnlyForMediaMounts(t *testing.T) {
	st := t.TempDir()
	announceMediaOverlays(st, 0)
	if got := readLanded(t, st); got != "" {
		t.Fatalf("no #media overlay mounted: the counter must stay absent, got %q", got)
	}
	announceMediaOverlays(st, 3)
	if got := readLanded(t, st); got != "1" {
		t.Fatalf("three #media overlays mounted: got %q, want 1", got)
	}
	announceMediaOverlays("", 3) // no state dir: a no-op
	if _, err := os.Stat(mediaLandedFile); !os.IsNotExist(err) {
		t.Fatalf("an empty state dir must write nothing, stat err %v", err)
	}
}

// NWP-20261116-38: runMediad must announce the #media scope's mounts, after the counter is reset and once they are up.
// A source pin, because runMediad mounts real FUSE overlays and is not run by the unit tests.
func TestRunMediadAnnouncesTheMediaScopeMounts(t *testing.T) {
	b, err := os.ReadFile("mediafs.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "func runMediad(")
	if i < 0 {
		t.Fatal("runMediad not found")
	}
	body := src[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	reset := strings.Index(body, "os.Remove(filepath.Join(stateDir, mediaLandedFile))")
	serve := strings.Index(body, `serveMediaScope(base, name+"#media", pass, args[5], args[6], stateDir)`)
	count := strings.Index(body, "mediaMounts = len(ext)")
	call := strings.Index(body, "announceMediaOverlays(stateDir, mediaMounts)")
	if reset < 0 || serve < 0 || count < 0 || call < 0 {
		t.Fatalf("runMediad must reset the counter, serve #media, count its mounts and announce them: reset=%d serve=%d count=%d call=%d", reset, serve, count, call)
	}
	if !(reset < serve && serve < count && count < call) {
		t.Fatalf("order must be reset < serve #media < count < announce: %d %d %d %d", reset, serve, count, call)
	}
}
