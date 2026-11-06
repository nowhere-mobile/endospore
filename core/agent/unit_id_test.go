package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"
)

// NWP-20261125-17: deviceUnitID's fallback is one id per boot (per process without a state dir), and
// readOrMintUnitID publishes first-writer-wins by link, with a rename when a link is refused.

var unitIDHex32 = regexp.MustCompile(`^[0-9a-f]{32}$`)

// unitIDTestSetup restores the package-level unit-id state after the test.
func unitIDTestSetup(t *testing.T) {
	t.Helper()
	oldPath, oldLock, oldSeam, oldLink := unitIDPath, unitIDBeforeLock, unitIDBeforePublish, unitIDLink
	resetUnitIDFallback()
	t.Cleanup(func() {
		unitIDPath, unitIDBeforeLock, unitIDBeforePublish, unitIDLink = oldPath, oldLock, oldSeam, oldLink
		resetUnitIDFallback()
	})
}

// unitIDUnwritablePath is a path under a regular FILE, so every read and create fails (ENOTDIR), as root too.
func unitIDUnwritablePath(t *testing.T) string {
	t.Helper()
	blk := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blk, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(blk, "unit-id")
}

func unitIDFileContent(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", filepath.Base(path), err)
	}
	return strings.TrimSpace(string(b))
}

func unitIDNoTempLeft(t *testing.T, dir string) {
	t.Helper()
	left, err := filepath.Glob(filepath.Join(dir, ".unit-id.*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("temp left behind: %v", left)
	}
}

func TestUnitIDFallbackIsOnePerBoot(t *testing.T) {
	unitIDTestSetup(t)
	unitIDPath = unitIDUnwritablePath(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)

	a := deviceUnitID()
	b := deviceUnitID()
	resetUnitIDFallback() // a second agent process of the same boot
	c := deviceUnitID()
	if a != b || b != c {
		t.Fatalf("fallback ids differ within one boot: %q %q %q", a, b, c)
	}
	if !unitIDHex32.MatchString(a) {
		t.Fatalf("fallback id %q is not 32 lower-case hex", a)
	}
	if got := unitIDFileContent(t, filepath.Join(state, "unit-id.boot")); got != a {
		t.Fatalf("unit-id.boot holds %q, deviceUnitID returned %q", got, a)
	}
	unitIDNoTempLeft(t, state)
}

func TestUnitIDFallbackWithoutStateIsOnePerProcess(t *testing.T) {
	unitIDTestSetup(t)
	unitIDPath = unitIDUnwritablePath(t)
	t.Setenv("NOWHERE_STATE", "")

	a := deviceUnitID()
	b := deviceUnitID()
	if a != b {
		t.Fatalf("fallback ids differ within one process: %q %q", a, b)
	}
	if !unitIDHex32.MatchString(a) {
		t.Fatalf("fallback id %q is not 32 lower-case hex", a)
	}
}

func TestUnitIDFirstWriterWins(t *testing.T) {
	unitIDTestSetup(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "unit-id")
	const competitor = "0123456789abcdef0123456789abcdef"
	unitIDBeforePublish = func(p string) {
		if err := os.WriteFile(p, []byte(competitor), 0o600); err != nil {
			t.Errorf("plant competitor: %v", err)
		}
	}

	got, err := readOrMintUnitID(path)
	if err != nil {
		t.Fatalf("readOrMintUnitID: %v", err)
	}
	if got != competitor {
		t.Fatalf("returned %q, want the first writer's %q", got, competitor)
	}
	if on := unitIDFileContent(t, path); on != competitor {
		t.Fatalf("file holds %q, want the first writer's %q", on, competitor)
	}
	unitIDNoTempLeft(t, dir)
}

func TestUnitIDLinkRefusedStillPersists(t *testing.T) {
	unitIDTestSetup(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "unit-id")
	unitIDLink = func(o, n string) error {
		return &os.LinkError{Op: "link", Old: o, New: n, Err: syscall.EPERM}
	}

	got, err := readOrMintUnitID(path)
	if err != nil {
		t.Fatalf("a refused link must not fail the mint: %v", err)
	}
	if !unitIDHex32.MatchString(got) {
		t.Fatalf("id %q is not 32 lower-case hex", got)
	}
	if on := unitIDFileContent(t, path); on != got {
		t.Fatalf("file holds %q, returned %q", on, got)
	}
	again, err := readOrMintUnitID(path)
	if err != nil || again != got {
		t.Fatalf("second call: %q err=%v, want %q", again, err, got)
	}
	unitIDNoTempLeft(t, dir)
}

func TestUnitIDEmptyFileReminted(t *testing.T) {
	unitIDTestSetup(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "unit-id")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := readOrMintUnitID(path)
	if err != nil {
		t.Fatalf("readOrMintUnitID: %v", err)
	}
	if !unitIDHex32.MatchString(got) {
		t.Fatalf("id %q is not 32 lower-case hex", got)
	}
	if on := unitIDFileContent(t, path); on != got {
		t.Fatalf("file holds %q, returned %q", on, got)
	}
	again, err := readOrMintUnitID(path)
	if err != nil || again != got {
		t.Fatalf("second call: %q err=%v, want %q", again, err, got)
	}
	unitIDNoTempLeft(t, dir)
}

// A caller that saw the empty file before another caller replaced it must return the other caller's id,
// not rename over it (the second call here completes inside the first one's window, before its lock).
func TestUnitIDEmptyRaceKeepsFirstReturnedID(t *testing.T) {
	unitIDTestSetup(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "unit-id")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	var other string
	unitIDBeforeLock = func(p string) {
		unitIDBeforeLock = nil
		var err error
		if other, err = readOrMintUnitID(p); err != nil {
			t.Errorf("second caller: %v", err)
		}
	}

	got, err := readOrMintUnitID(path)
	if err != nil {
		t.Fatalf("readOrMintUnitID: %v", err)
	}
	if got != other {
		t.Fatalf("first caller returned %q, the second caller already returned %q", got, other)
	}
	if on := unitIDFileContent(t, path); on != other {
		t.Fatalf("file holds %q, the second caller already returned %q", on, other)
	}
	unitIDNoTempLeft(t, dir)
}

// A publish waits for another holder of the directory lock (another agent process) and then returns the id
// that holder published, never its own.
func TestUnitIDPublishWaitsForTheDirLock(t *testing.T) {
	unitIDTestSetup(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "unit-id")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	unlock, err := lockUnitIDDir(dir)
	if err != nil {
		t.Fatalf("lockUnitIDDir: %v", err)
	}
	reached := make(chan struct{})
	unitIDBeforeLock = func(string) { close(reached) }
	type res struct {
		id  string
		err error
	}
	done := make(chan res, 1)
	go func() {
		id, err := readOrMintUnitID(path)
		done <- res{id, err}
	}()
	<-reached
	select {
	case r := <-done:
		unlock()
		t.Fatalf("publish returned %q (err=%v) while another holder had the directory lock", r.id, r.err)
	case <-time.After(300 * time.Millisecond):
	}
	const holder = "fedcba9876543210fedcba9876543210"
	if err := os.WriteFile(path, []byte(holder), 0o600); err != nil {
		t.Fatal(err)
	}
	unlock()
	r := <-done
	if r.err != nil || r.id != holder {
		t.Fatalf("returned %q err=%v, want the lock holder's %q", r.id, r.err, holder)
	}
	if on := unitIDFileContent(t, path); on != holder {
		t.Fatalf("file holds %q, want the lock holder's %q", on, holder)
	}
	unitIDNoTempLeft(t, dir)
}

// An existing id that cannot be read is never replaced, even when the link is refused and the directory
// allows a rename. A self-symlink fails every read with ELOOP, as root too; rename would replace it.
func TestUnitIDUnreadableIDNotReplaced(t *testing.T) {
	cases := []struct {
		name string
		when string // when the id turns unreadable: before the call, before the lock, before the publish
	}{
		{"before-call", "call"},
		{"before-lock", "lock"},
		{"before-publish", "publish"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			unitIDTestSetup(t)
			dir := t.TempDir()
			path := filepath.Join(dir, "unit-id")
			loop := func(p string) {
				if err := os.Symlink(filepath.Base(p), p); err != nil {
					t.Errorf("symlink: %v", err)
				}
			}
			switch c.when {
			case "call":
				loop(path)
			case "lock":
				unitIDBeforeLock = loop
			case "publish":
				unitIDBeforePublish = loop
			}
			unitIDLink = func(o, n string) error {
				return &os.LinkError{Op: "link", Old: o, New: n, Err: syscall.EPERM}
			}

			got, err := readOrMintUnitID(path)
			if err == nil {
				t.Fatalf("readOrMintUnitID returned %q, want the read error", got)
			}
			if errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("error %v reads as absence", err)
			}
			fi, lerr := os.Lstat(path)
			if lerr != nil || fi.Mode()&fs.ModeSymlink == 0 {
				t.Fatalf("the unreadable id was replaced (lstat err=%v)", lerr)
			}
			unitIDNoTempLeft(t, dir)
		})
	}

	// Each read returns its own error: the id is unreadable at one read and absent by the next, so a read
	// that dropped its error would go on to mint a regular file where the unreadable id was.
	gone := []struct {
		name string
		when string // the read that sees the unreadable id: the first one, or the one under the lock
	}{
		{"first-read-error-returned", "call"},
		{"locked-read-error-returned", "lock"},
	}
	for _, c := range gone {
		t.Run(c.name, func(t *testing.T) {
			unitIDTestSetup(t)
			dir := t.TempDir()
			path := filepath.Join(dir, "unit-id")
			loop := func(p string) {
				if err := os.Symlink(filepath.Base(p), p); err != nil {
					t.Errorf("symlink: %v", err)
				}
			}
			unlink := func(p string) {
				if err := os.Remove(p); err != nil {
					t.Errorf("remove: %v", err)
				}
			}
			if c.when == "call" {
				loop(path)
				unitIDBeforeLock = unlink
			} else {
				unitIDBeforeLock = loop
				unitIDBeforePublish = unlink
			}
			unitIDLink = func(o, n string) error {
				return &os.LinkError{Op: "link", Old: o, New: n, Err: syscall.EPERM}
			}

			if got, err := readOrMintUnitID(path); err == nil {
				t.Fatalf("readOrMintUnitID returned %q after a read error, want that error", got)
			}
			if fi, err := os.Lstat(path); err == nil && fi.Mode().IsRegular() {
				t.Fatalf("a mint ran after a read error: %s is a regular file", filepath.Base(path))
			}
			unitIDNoTempLeft(t, dir)
		})
	}

	// A mode-0000 id file in a writable dir: the reviewer's case. Root reads it anyway, so it runs only as non-root.
	t.Run("mode-0000", func(t *testing.T) {
		unitIDTestSetup(t)
		dir := t.TempDir()
		path := filepath.Join(dir, "unit-id")
		const kept = "00112233445566778899aabbccddeeff"
		if err := os.WriteFile(path, []byte(kept), 0o000); err != nil {
			t.Fatal(err)
		}
		if _, err := os.ReadFile(path); err == nil {
			t.Skip("running as root: a mode-0000 file is readable")
		}
		unitIDLink = func(o, n string) error {
			return &os.LinkError{Op: "link", Old: o, New: n, Err: syscall.EPERM}
		}
		if got, err := readOrMintUnitID(path); err == nil {
			t.Fatalf("readOrMintUnitID returned %q, want the read error", got)
		}
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
		if on := unitIDFileContent(t, path); on != kept {
			t.Fatalf("the unreadable id was replaced: file holds %q", on)
		}
		unitIDNoTempLeft(t, dir)
	})
}

// TestUnitIDFallbackLogsOncePerProcess: a process that falls back first to the per-process tier and then,
// once the state dir exists, to the per-boot tier logs one content-free line, naming the first tier. The
// reverse transition logs one line too.
func TestUnitIDFallbackLogsOncePerProcess(t *testing.T) {
	for _, tc := range []struct {
		name, firstTier string
		stateFirst      bool
	}{
		{"process then boot", "per-process id", false},
		{"boot then process", "per-boot id", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			unitIDTestSetup(t)
			unitIDPath = unitIDUnwritablePath(t)
			state := filepath.Join(t.TempDir(), "state")
			t.Setenv("NOWHERE_STATE", state)
			setState := func(on bool) {
				var err error
				if on {
					err = os.MkdirAll(state, 0o700)
				} else {
					err = os.RemoveAll(state)
				}
				if err != nil {
					t.Fatal(err)
				}
			}

			var ids []string
			out := captureStderr(t, func() {
				setState(tc.stateFirst)
				ids = append(ids, deviceUnitID())
				setState(!tc.stateFirst)
				ids = append(ids, deviceUnitID())
			})
			var lines []string
			for _, l := range strings.Split(out, "\n") {
				if strings.Contains(l, "unit-id:") {
					lines = append(lines, l)
				}
			}
			if len(lines) != 1 {
				t.Fatalf("got %d fallback log lines, want one per process: %q", len(lines), lines)
			}
			if !strings.Contains(lines[0], tc.firstTier) {
				t.Fatalf("fallback line %q does not name the first tier (%s)", lines[0], tc.firstTier)
			}
			for _, id := range ids {
				if strings.Contains(out, id) {
					t.Fatalf("fallback log carries an id: %q", out)
				}
			}
		})
	}
}
