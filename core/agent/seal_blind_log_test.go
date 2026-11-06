package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// NWP-20260821-04 (ticket NW-b8b659735124): the seal refusal counted unreadable paths but never NAMED
// them, which stranded a real logoff on a user build with "44 path(s) -- fix the permissions" and no way
// to learn which. These tests pin that the walker names the package or scope and the label, and that the cap
// holds. NWP-20261102-03 (Q001 (e)): it names NO path -- the old line printed the path with %q and the error
// with %v, and a *fs.PathError repeats the path unquoted past the log scrub.

// captureStdout runs fn with os.Stdout redirected and returns what it printed. The walker logs via
// fmt.Printf (roamd captures the process's stdout into roam.log), so this is the same channel a device
// report ships.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	done := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		done <- string(b)
	}()
	fn()
	w.Close()
	os.Stdout = old
	return <-done
}

func TestSealWalkNamesUnreadablePaths(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("chmod-000 does not deny root; this test needs an unprivileged runner")
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "ok.txt"), []byte("fine"), 0o600); err != nil {
		t.Fatal(err)
	}
	locked := filepath.Join(root, "com.example.app", "locked")
	if err := os.MkdirAll(locked, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(locked, "secret"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o700) }) // or TempDir cleanup fails

	var tarErr error
	out := captureStdout(t, func() {
		var sink bytes.Buffer
		_, tarErr = tarDirTo(root, &sink)
	})
	if tarErr == nil || !strings.Contains(tarErr.Error(), "refusing to tar a short tree") {
		t.Fatalf("expected the short-tree refusal, got err=%v", tarErr)
	}
	// The scope is whatever blindScopeOf says for this tree's own path: a TempDir under /mnt/... (a runner whose
	// TMPDIR is /mnt/ft) is "ext" by design, one under /tmp is "other". The mapping itself is pinned by
	// TestSealWalkLineScopeIsFixedWord below; this test pins that the refusal's line carries it.
	if !strings.Contains(out, "[walk] unreadable") || !strings.Contains(out, "scope="+blindScopeOf(locked)+" ") {
		t.Fatalf("the refusal did not log an unreadable line with its scope -- the NW-b8b659735124 gap is back.\nout:\n%s", out)
	}
	if !strings.Contains(out, "ctx=") {
		t.Fatalf("the unreadable line carries no SELinux context field (best-effort, but the field must exist):\n%s", out)
	}
	if !strings.Contains(out, "err=permission denied") {
		t.Fatalf("the unreadable line carries no error code:\n%s", out)
	}
	for _, leak := range []string{"locked", "secret", "com.example.app", root, filepath.Base(root)} {
		if strings.Contains(out, leak) {
			t.Fatalf("the unreadable line leaks %q (a path component):\n%s", leak, out)
		}
	}
}

func TestSealWalkLineNamesPackageNotPath(t *testing.T) {
	resetSealBlindPkgs()
	t.Cleanup(resetSealBlindPkgs)
	p := "/data/user/11/com.example/files/secret.jpg"
	out := captureStdout(t, func() {
		sealBlindLog(1, p, &fs.PathError{Op: "open", Path: p, Err: syscall.EACCES})
	})
	for _, want := range []string{"pkg=com.example", "err=permission denied", "ctx="} {
		if !strings.Contains(out, want) {
			t.Fatalf("line lacks %q:\n%s", want, out)
		}
	}
	for _, leak := range []string{"secret.jpg", "/data/user", "files"} {
		if strings.Contains(out, leak) {
			t.Fatalf("line leaks %q:\n%s", leak, out)
		}
	}
	if got := sealBlindPkgList(); len(got) != 1 || got[0] != "com.example" {
		t.Fatalf("the package set for the UI changed: %v", got)
	}
}

func TestSealWalkLineMediaScopeOnly(t *testing.T) {
	resetSealBlindPkgs()
	t.Cleanup(resetSealBlindPkgs)
	p := "/data/media/0/DCIM/x.jpg"
	out := captureStdout(t, func() {
		sealBlindLog(1, p, &fs.PathError{Op: "open", Path: p, Err: syscall.EACCES})
	})
	if !strings.Contains(out, "scope=media") || strings.Contains(out, "pkg=") {
		t.Fatalf("a media path must log scope=media and no pkg:\n%s", out)
	}
	for _, leak := range []string{"DCIM", "x.jpg", "/data/media"} {
		if strings.Contains(out, leak) {
			t.Fatalf("line leaks %q:\n%s", leak, out)
		}
	}
}

// Never skipped: this is what convicts a scope derived from the path's own components on a root runner.
func TestSealWalkLineScopeIsFixedWord(t *testing.T) {
	resetSealBlindPkgs()
	t.Cleanup(resetSealBlindPkgs)
	for _, c := range []struct{ p, want string }{
		{"/data/misc/secretdir/leaf.bin", "other"},
		{"/storage/emulated/0/Pictures/p.png", "ext"},
		{"/mnt/media_rw/1A2B-3C4D/DCIM/x.jpg", "ext"},
		{"/data/user_de/11", "de"},
		{"/data/user/11", "ce"},
		{"/data/media", "media"},
	} {
		out := captureStdout(t, func() {
			sealBlindLog(1, c.p, &fs.PathError{Op: "open", Path: c.p, Err: syscall.EACCES})
		})
		if !strings.Contains(out, "scope="+c.want+" ") {
			t.Fatalf("%s: want scope=%s:\n%s", c.p, c.want, out)
		}
		_, tail, _ := strings.Cut(out, "unreadable ")
		for _, seg := range strings.Split(c.p, "/") {
			if len(seg) > 4 && seg != c.want && strings.Contains(tail, seg) {
				t.Fatalf("%s: line carries the path segment %q:\n%s", c.p, seg, out)
			}
		}
	}
}

func TestErrCodeUnwrapsPathErrors(t *testing.T) {
	pe := &fs.PathError{Op: "open", Path: "/data/user/13/com.whatsapp/files/photo", Err: syscall.EACCES}
	for name, c := range map[string]struct {
		err  error
		want string
	}{
		"path":    {pe, "permission denied"},
		"link":    {&os.LinkError{Op: "rename", Old: "/a/secret1", New: "/b/secret2", Err: syscall.EACCES}, "permission denied"},
		"syscall": {os.NewSyscallError("lgetxattr", syscall.EACCES), "permission denied"},
		"wrapped": {fmt.Errorf("walk: %w", pe), "permission denied"},
		"plain":   {errors.New("boom"), "boom"},
		"nil":     {nil, "none"},
	} {
		if got := errCode(c.err); got != c.want {
			t.Errorf("%s: errCode = %q, want %q", name, got, c.want)
		}
	}
}

func TestSealWalkKeepLineHasNoPath(t *testing.T) {
	err := &fs.PathError{Op: "open", Path: "/data/media/0/DCIM/x.jpg", Err: syscall.EACCES}
	got := sealUnreadableKeepLine("DCIM/x.jpg", "deferred record", err)
	want := "[seal] \"DCIM/x.jpg\" unreadable -> keeping the stored deferred record: permission denied\n"
	if got != want {
		t.Fatalf("keep line = %q, want %q", got, want)
	}
	if strings.Contains(got, "/data/media") {
		t.Fatalf("keep line carries the path: %q", got)
	}
}

func TestSealBlindLogCapsTheFlood(t *testing.T) {
	out := captureStdout(t, func() {
		for i := 1; i <= sealBlindLogMax+5; i++ {
			sealBlindLog(i, "/data/user/11/com.example/f", os.ErrPermission)
		}
	})
	if n := strings.Count(out, "[walk] unreadable"); n != sealBlindLogMax {
		t.Fatalf("logged %d path lines, want exactly sealBlindLogMax=%d", n, sealBlindLogMax)
	}
	if strings.Count(out, "elided") != 1 {
		t.Fatalf("the one-line elision marker is missing or repeated:\n%s", out)
	}
}
