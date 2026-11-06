package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #90: the progress publisher writes a one-line "LOADING <done> <total> <nfiles> <name>" status naming the
// dominant (most-bytes-to-go) in-flight fetch, and REMOVES the file when nothing is left (the chooser reads
// its absence as IDLE and dismisses the notification). Pure file-I/O logic, no store.
func TestMediaProgressPublish(t *testing.T) {
	prog := filepath.Join(t.TempDir(), "media.progress")
	s := &mediaServer{progPath: prog}

	read := func() string {
		b, err := os.ReadFile(prog)
		if err != nil {
			return "" // absent == idle
		}
		return strings.TrimRight(string(b), "\r\n")
	}

	// One fetch in flight -> its line, nfiles=1, name is the basename (path stripped).
	s.progSet("k1", "app.maps/files/maps/China_Guangxi.mwm", 512, 2900)
	if got, want := read(), "LOADING 512 2900 1 China_Guangxi.mwm"; got != want {
		t.Fatalf("single fetch: got %q want %q", got, want)
	}

	// A second, smaller-remaining fetch must NOT become dominant (k1 has 2388 to go, k2 has 100).
	s.progSet("k2", "app.pics/thumb.jpg", 0, 100)
	if got, want := read(), "LOADING 512 2900 2 China_Guangxi.mwm"; got != want {
		t.Fatalf("two fetches, dominant wrong: got %q want %q", got, want)
	}

	// k1 finishes -> the remaining (smaller) fetch is now dominant and nfiles drops to 1.
	s.progDone("k1")
	if got, want := read(), "LOADING 0 100 1 thumb.jpg"; got != want {
		t.Fatalf("after k1 done: got %q want %q", got, want)
	}

	// Last fetch finishes -> file removed (idle).
	s.progDone("k2")
	if _, err := os.Stat(prog); !os.IsNotExist(err) {
		t.Fatalf("idle must remove the progress file, stat err=%v", err)
	}
}

// progSet/progDone must be a hard no-op when progPath is unset (unit tests / a mediad without NOWHERE_STATE) --
// never touch the filesystem, never panic.
func TestMediaProgressDisabledIsNoop(t *testing.T) {
	s := &mediaServer{} // progPath == ""
	s.progSet("k", "x/y.mwm", 1, 2)
	s.progDone("k")
	if s.active != nil {
		t.Fatalf("disabled publisher must not allocate state, active=%v", s.active)
	}
}

// #90 end-to-end: a whole-file fetch advances the published bytes and, on completion, returns to IDLE (the
// deferred progDone removes the file) while installing the correct bytes. Proves the fetch path is wired to
// the publisher and cleans up.
func TestWholeFileFetchProgressIdleAfter(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "progfetch", "loading horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := prBytes(9 << 20)
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), data, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)
	d := m.Deferred[rel]
	if len(d.Chunks) < 2 {
		t.Fatalf("test needs a multi-chunk file, got %d", len(d.Chunks))
	}
	srv := newMediaServer(base, dk, m, t.TempDir())
	srv.progPath = filepath.Join(t.TempDir(), "media.progress")

	cp := filepath.Join(srv.cacheDir, cacheKey(d))
	if err := srv.fetchToCache(rel, d, cp); err != nil {
		t.Fatalf("fetchToCache: %v", err)
	}
	// Correct bytes installed.
	whole, err := os.ReadFile(cp)
	if err != nil || !bytes.Equal(whole, data) {
		t.Fatalf("fetched file mismatch: %d bytes err=%v", len(whole), err)
	}
	// IDLE afterward -> the progress file is gone.
	if _, err := os.Stat(srv.progPath); !os.IsNotExist(err) {
		t.Fatalf("progress must be idle (file removed) after a completed fetch, stat err=%v", err)
	}
}
