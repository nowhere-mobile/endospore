package main

import (
	"archive/tar"
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// h60 #9: a skip line names the package or a scope word and the error code. A file at a user root has no package,
// whatever blindPkgOf returns for it, and no part of the entry's name reaches the line.
func TestRestoreSkipLineSubject(t *testing.T) {
	for _, c := range []struct{ dir, name, want string }{
		{"/data/user/10", "com.example.app/databases/nwpleaf.db", "pkg=com.example.app"},
		{"/data/user_de/0", "com.example.app/shared_prefs/x.xml", "pkg=com.example.app"},
		{"/data/media/0", "DCIM/Camera/nwpleaf.jpg", "scope=media"},
		{"/data/user/10", "IMG_0001", "scope=ce"},
		{"/data/nowhere/x", "a/b", "scope=other"},
	} {
		got := restoreSkipLine(c.dir, c.name, "", syscall.ENOENT)
		if want := "[restore] skip " + c.want + ": no such file or directory\n"; got != want {
			t.Errorf("%s + %s:\n got %q\nwant %q", c.dir, c.name, got, want)
		}
		for _, leak := range []string{"nwpleaf", "databases", "shared_prefs", "DCIM", "IMG_0001", "/"} {
			if strings.Contains(got, leak) {
				t.Errorf("%s + %s: the line carries %q: %q", c.dir, c.name, leak, got)
			}
		}
	}
	const app, inner = "com.example.app", "/data/user/10/com.example.app/databases/nwpleaf.db"
	perr := &fs.PathError{Op: "open", Path: inner, Err: syscall.ENOENT}
	got := restoreSkipLine("/data/user/10", app+"/databases/nwpleaf.db", "", perr)
	if !strings.Contains(got, "no such file or directory") || strings.Contains(got, "nwpleaf") {
		t.Errorf("a *fs.PathError must print as its code alone: %q", got)
	}
	got = restoreSkipLine("/data/user/10", app+"/databases/nwpleaf.db", "mkdir parent", perr)
	if want := "[restore] skip pkg=" + app + ": mkdir parent: no such file or directory\n"; got != want {
		t.Errorf("with a step word:\n got %q\nwant %q", got, want)
	}
}

// Three of untarFrom's four skip lines, driven by real failures: the *fs.PathError each one receives repeats a path
// unquoted, past the scrub, so the whole output is held free of the entry names and of the restore root. Plain
// errnos, not permission ones, so this holds as root. The copy line is TestUntarSkipLineCarriesNoPresignedQuery.
func TestRestoreSkipLinesCarryNoPath(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "blk"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "isdir-nwpleaf"), 0o700); err != nil {
		t.Fatal(err)
	}
	var stream bytes.Buffer
	tw := tar.NewWriter(&stream)
	for _, h := range []*tar.Header{
		{Name: "blk/nwpleafdir/", Mode: 0o700, Typeflag: tar.TypeDir},
		{Name: "blk/nwpleaf.db", Mode: 0o600, Typeflag: tar.TypeReg},
		{Name: "isdir-nwpleaf", Mode: 0o600, Typeflag: tar.TypeReg},
	} {
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	var skipped int
	out := captureStderr(t, func() { skipped = untarFrom(dir, &stream) })
	if skipped != 3 {
		t.Errorf("untarFrom returned %d, want 3\n%s", skipped, out)
	}
	// The scope word comes from the root, and t.TempDir follows TMPDIR: under /mnt it is `ext`. The literal `other`
	// is pinned by TestRestoreSkipLineSubject.
	subj := "[restore] skip scope=" + blindScopeOf(dir)
	want := []string{subj + ": dir: not a directory", subj + ": mkdir parent: not a directory", subj + ": is a directory"}
	var got []string
	for _, ln := range strings.Split(out, "\n") {
		if strings.HasPrefix(ln, "[restore] skip ") {
			got = append(got, ln)
		}
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("the skip lines:\n got %q\nwant %q", got, want)
	}
	for _, leak := range []string{"nwpleaf", "blk", dir} {
		if strings.Contains(out, leak) {
			t.Errorf("the output carries %q, quoted or not:\n%s", leak, out)
		}
	}
}
