package main

// NWP-20261127-16: every process of one boot tags a profile alike. loadOrMintLogTagSalt publishes a new salt by
// os.Link, so the first writer wins and every other caller adopts the file's bytes, never its own.

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// logTagSaltDirNames returns the names in dir, so a test can see that no temp file was left behind.
func logTagSaltDirNames(t *testing.T, dir string) []string {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read dir: %v", err)
	}
	var names []string
	for _, e := range ents {
		names = append(names, e.Name())
	}
	return names
}

func logTagSaltOnlyTheFile(t *testing.T, dir string) {
	t.Helper()
	if names := logTagSaltDirNames(t, dir); len(names) != 1 || names[0] != "logtag.salt" {
		t.Fatalf("state dir holds %q, want only logtag.salt (a temp file was left behind)", names)
	}
}

func TestLogTagSaltFirstWriterWins(t *testing.T) {
	dir := t.TempDir()
	const n = 16
	var (
		start   = make(chan struct{})
		ready   sync.WaitGroup
		done    sync.WaitGroup
		results [n][]byte
		oks     [n]bool
	)
	for i := 0; i < n; i++ {
		ready.Add(1)
		done.Add(1)
		go func(i int) {
			defer done.Done()
			ready.Done()
			<-start
			results[i], oks[i] = loadOrMintLogTagSalt(dir)
		}(i)
	}
	ready.Wait()
	close(start)
	done.Wait()
	file, err := os.ReadFile(filepath.Join(dir, "logtag.salt"))
	if err != nil || len(file) != 16 {
		t.Fatalf("logtag.salt: %d bytes, err %v; want 16 bytes", len(file), err)
	}
	for i := 0; i < n; i++ {
		if !oks[i] {
			t.Fatalf("caller %d: ok=false on a writable state dir", i)
		}
		if !bytes.Equal(results[i], file) {
			t.Fatalf("caller %d kept a salt that is not the file's: two processes of one boot would tag a profile differently", i)
		}
	}
	logTagSaltOnlyTheFile(t, dir)
}

func TestLogTagSaltLosesTheLinkRace(t *testing.T) {
	dir := t.TempDir()
	final := filepath.Join(dir, "logtag.salt")
	winner := []byte("winner-salt-0123")
	logTagSaltBeforeLink = func() {
		if err := os.WriteFile(final, winner, 0o600); err != nil {
			t.Errorf("write the winner's salt: %v", err)
		}
	}
	t.Cleanup(func() { logTagSaltBeforeLink = nil })
	got, ok := loadOrMintLogTagSalt(dir)
	if !ok || !bytes.Equal(got, winner) {
		t.Fatalf("lost the link race and returned %x (ok=%v), want the winner's %x", got, ok, winner)
	}
	if file, _ := os.ReadFile(final); !bytes.Equal(file, winner) {
		t.Fatalf("the loser overwrote the winner's file: %x", file)
	}
	logTagSaltOnlyTheFile(t, dir)
}

func TestLogTagSaltAdoptsAnExistingSalt(t *testing.T) {
	dir := t.TempDir()
	final := filepath.Join(dir, "logtag.salt")
	have := []byte("existing-salt-16")
	if err := os.WriteFile(final, have, 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(final, old, old); err != nil {
		t.Fatal(err)
	}
	got, ok := loadOrMintLogTagSalt(dir)
	if !ok || !bytes.Equal(got, have) {
		t.Fatalf("returned %x (ok=%v), want the existing %x", got, ok, have)
	}
	st, err := os.Stat(final)
	if err != nil {
		t.Fatal(err)
	}
	if file, _ := os.ReadFile(final); !bytes.Equal(file, have) || !st.ModTime().Equal(old) {
		t.Fatalf("an existing salt was rewritten: %x, mtime %v, want %x, mtime %v", file, st.ModTime(), have, old)
	}
	logTagSaltOnlyTheFile(t, dir)
}

func TestLogTagSaltReplacesACutFile(t *testing.T) {
	dir := t.TempDir()
	final := filepath.Join(dir, "logtag.salt")
	if err := os.WriteFile(final, []byte("short"), 0o600); err != nil {
		t.Fatal(err)
	}
	first, ok := loadOrMintLogTagSalt(dir)
	if !ok || len(first) != 16 {
		t.Fatalf("a 5-byte file: returned %d bytes (ok=%v), want a 16-byte salt", len(first), ok)
	}
	if file, _ := os.ReadFile(final); !bytes.Equal(file, first) {
		t.Fatalf("the returned salt is not the file's: %x vs %x", first, file)
	}
	st, err := os.Stat(final)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("logtag.salt mode %v, want 0600", st.Mode().Perm())
	}
	second, ok := loadOrMintLogTagSalt(dir)
	if !ok || !bytes.Equal(second, first) {
		t.Fatalf("the second call returned %x (ok=%v), want the replaced %x", second, ok, first)
	}
	logTagSaltOnlyTheFile(t, dir)
}

// TestLogTagSaltFallbackHelperProcess is not a test: TestLogTagSaltUnusableStateFallsBack re-executes the test
// binary to run it, so logTagSalt's Once is that fresh process's own and no package global here is reset.
func TestLogTagSaltFallbackHelperProcess(t *testing.T) {
	if os.Getenv("NOWHERE_LOGTAG_SALT_HELPER") != "1" {
		return
	}
	b := logTagSalt()
	tag := profileTag("someone")
	if len(b) != 16 || !strings.HasPrefix(tag, " p:") || len(tag) != 7 {
		fmt.Printf("FALLBACK BAD: %d-byte salt, tag %q\n", len(b), tag)
		os.Exit(1)
	}
	fmt.Println("FALLBACK OK: 16-byte salt")
	os.Exit(0)
}

func TestLogTagSaltUnusableStateFallsBack(t *testing.T) {
	dir := t.TempDir()
	st := filepath.Join(dir, "state")
	if err := os.WriteFile(st, []byte("a regular file, not a dir"), 0o600); err != nil {
		t.Fatal(err)
	}
	if b, ok := loadOrMintLogTagSalt(st); ok || b != nil {
		t.Fatalf("a state path that is a regular file: returned %x, ok=%v; want nil, ok=false", b, ok)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestLogTagSaltFallbackHelperProcess$", "-test.count=1")
	cmd.Env = append(os.Environ(), "NOWHERE_LOGTAG_SALT_HELPER=1", "NOWHERE_STATE="+st)
	out, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(out), "FALLBACK OK: 16-byte salt") {
		t.Fatalf("logTagSalt's fallback on an unusable state dir: err %v\n%s", err, out)
	}
	if names := logTagSaltDirNames(t, dir); len(names) != 1 || names[0] != "state" {
		t.Fatalf("the fallback left %q beside the state file", names)
	}
}
