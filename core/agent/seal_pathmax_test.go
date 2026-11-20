package main

// NWP-20261203-29: the backlog row "A file in an app's data whose path is longer than PATH_MAX is neither sealed nor
// counted as unreadable: the sign-out seals OK and no log names it" (device-proof S9 on lynx, 2026-11-11).
//
// TestSealPathMax_* pin the refusal: a path past PATH_MAX makes both seal walks blind, the tar walk refuses, and the
// refusal names the app (never the path). The walkers already did this on main, so these are pins; the suite's M1
// mutant convicts them.
//
// TestSealUnfetchedLocal_* pin the evidence line: the walk skips a listed-unfetched package's dir without reading it
// (S9's plant was likely under one), and a seal now counts the local files that dir held outside cache/ and
// code_cache/, counts only.

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// spmDeepTree builds <root>/com.example.app/files/<200-char dir>/... with fd-relative calls (an absolute mkdir
// past PATH_MAX fails) until the directory just created has an absolute path longer than 4096 bytes, then puts
// leaf.txt inside it. The cwd is never changed; t.TempDir's openat-based RemoveAll cleans the tree up.
func spmDeepTree(t *testing.T) (root, deepest string) {
	t.Helper()
	root = t.TempDir()
	files := filepath.Join(root, "com.example.app", "files")
	if err := os.MkdirAll(files, 0o700); err != nil {
		t.Fatal(err)
	}
	fd, err := unix.Open(files, unix.O_RDONLY|unix.O_DIRECTORY, 0)
	if err != nil {
		t.Fatal(err)
	}
	name := strings.Repeat("d", 200)
	p := files
	for len(p) <= 4096 {
		if err := unix.Mkdirat(fd, name, 0o700); err != nil {
			unix.Close(fd)
			t.Fatalf("mkdirat at depth %d: %v", len(p), err)
		}
		nfd, err := unix.Openat(fd, name, unix.O_RDONLY|unix.O_DIRECTORY, 0)
		unix.Close(fd)
		if err != nil {
			t.Fatalf("openat at depth %d: %v", len(p), err)
		}
		fd = nfd
		p += "/" + name
	}
	lf, err := unix.Openat(fd, "leaf.txt", unix.O_CREAT|unix.O_WRONLY, 0o600)
	if err != nil {
		unix.Close(fd)
		t.Fatal(err)
	}
	unix.Write(lf, []byte("abc"))
	unix.Close(lf)
	unix.Close(fd)
	if len(p) <= 4096 {
		t.Fatalf("deepest path is %d bytes, want > 4096: the tree is too short to test PATH_MAX", len(p))
	}
	return root, p
}

func TestSealPathMax_WalkAndTarRefuse(t *testing.T) {
	resetSealBlindPkgs()
	t.Cleanup(resetSealBlindPkgs)
	root, deepest := spmDeepTree(t)
	if len(deepest) <= 4096 {
		t.Fatalf("deepest path is %d bytes, want > 4096", len(deepest))
	}
	next := 0
	emit := func([]byte) int { i := next; next++; return i }
	cached := func(string) int { return 0 }
	var blind int
	var tarErr error
	out := captureStdout(t, func() {
		_, _, _, _, blind, _, _, _ = walkChunks(root, newFileScanCache(make([]byte, 32)), 4096, true, false,
			nil, nil, nil, nil, 0, emit, cached, func(int64) {}, nil)
		var buf bytes.Buffer
		_, tarErr = tarDirTo(root, &buf)
	})
	if blind < 1 {
		t.Errorf("walkChunks blind = %d over a path past PATH_MAX, want >= 1: the seal would publish a short tree", blind)
	}
	if tarErr == nil || !strings.Contains(tarErr.Error(), "refusing to tar a short tree") {
		t.Errorf("tarDirTo err = %v over a path past PATH_MAX, want the 'refusing to tar a short tree' refusal", tarErr)
	}
	if !strings.Contains(out, "[walk] unreadable") {
		t.Errorf("no '[walk] unreadable' line in the walk's output:\n%s", out)
	}
	if want := "err=" + errCode(syscall.ENAMETOOLONG); !strings.Contains(out, want) {
		t.Errorf("the walk's output holds no %q:\n%s", want, out)
	}
	for _, leak := range []string{strings.Repeat("d", 200), "leaf.txt", root} {
		if strings.Contains(out, leak) {
			t.Errorf("the walk's output leaks %.40q...:\n%s", leak, out)
		}
	}
}

func TestSealPathMax_RefusalNamesTheApp(t *testing.T) {
	resetSealBlindPkgs()
	t.Cleanup(resetSealBlindPkgs)
	name := strings.Repeat("d", 200)
	p := "/data/user/15/com.example.app/files/" + strings.TrimSuffix(strings.Repeat(name+"/", 21), "/")
	if len(p) <= 4096 {
		t.Fatalf("test path is %d bytes, want > 4096", len(p))
	}
	if got := blindPkgOf(p); got != "com.example.app" {
		t.Errorf("blindPkgOf(<path past PATH_MAX>) = %q, want %q", got, "com.example.app")
	}
	out := captureStdout(t, func() {
		sealBlindLog(1, p, &fs.PathError{Op: "lstat", Path: p, Err: syscall.ENAMETOOLONG})
	})
	if got, want := sealBlindPkgList(), []string{"com.example.app"}; !reflect.DeepEqual(got, want) {
		t.Errorf("sealBlindPkgList() = %v, want %v: the refusal would not name the app", got, want)
	}
	if !strings.Contains(out, "pkg=com.example.app") {
		t.Errorf("the [walk] line does not name the app:\n%s", out)
	}
	if strings.Contains(out, name) {
		t.Errorf("the [walk] line leaks a path component:\n%s", out)
	}
}

func spmWrite(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestSealUnfetchedLocal_CountsOnlyThePackageDir(t *testing.T) {
	t.Setenv("NOWHERE_DROP_LIST", "")
	t.Setenv("NOWHERE_DEFER_LIST", "")
	const pkgA, pkgB, pkgC = "com.example.unfa", "com.example.unfb", "com.example.unfc"
	hold := chooserPkg + "/" + odHoldDirName + "/" + pkgA
	root := t.TempDir()
	spmWrite(t, root, pkgA+"/files/x", "xxx")
	spmWrite(t, root, pkgA+"/cache/c", "cc")
	spmWrite(t, root, pkgA+"/code_cache/k", "kk")
	spmWrite(t, root, pkgB+"/cache/b", "bb")
	spmWrite(t, root, pkgC+"/files/y", "CMARKER-y")
	spmWrite(t, root, hold+"/files/z", "zzzzz")

	var emitted bytes.Buffer
	next := 0
	emit := func(c []byte) int { emitted.Write(c); i := next; next++; return i }
	cached := func(string) int { return 0 }
	_, seen, _, _, blind, _, st, _ := walkChunksExcl(root, newFileScanCache(make([]byte, 32)), 4096, true, false,
		nil, nil, nil, nil, 0, emit, cached, func(int64) {}, nil, map[string]bool{pkgA: true, pkgB: true})
	if st.unfLocalPkgs != 1 || st.unfLocalFiles != 1 || st.unfLocalBytes != 3 {
		t.Errorf("unfetched local: pkgs %d, files %d, bytes %d; want pkgs 1, files 1, bytes 3",
			st.unfLocalPkgs, st.unfLocalFiles, st.unfLocalBytes)
	}
	if blind != 0 {
		t.Errorf("blind = %d, want 0: counting the skipped dirs must never change blind", blind)
	}
	for rel := range seen {
		for _, skipped := range []string{pkgA, pkgB, hold} {
			if rel == skipped || strings.HasPrefix(rel, skipped+"/") {
				t.Errorf("seen holds %q under the skipped %q: the skip changed", rel, skipped)
			}
		}
	}
	for _, skipped := range []string{pkgA + "/", pkgB + "/", odHoldDirName + "/" + pkgA, "xxx", "zzzzz"} {
		if bytes.Contains(emitted.Bytes(), []byte(skipped)) {
			t.Errorf("the emitted seal holds %q: the skip changed", skipped)
		}
	}
	if !bytes.Contains(emitted.Bytes(), []byte(pkgC+"/files/y")) || !bytes.Contains(emitted.Bytes(), []byte("CMARKER-y")) {
		t.Errorf("the emitted seal does not hold %s/files/y: the unlisted package is no longer walked", pkgC)
	}
}

func TestSealUnfetchedLocal_LineIsCountsOnly(t *testing.T) {
	const prof = "odtest-spm-line"
	st := walkStats{unfLocalPkgs: 1, unfLocalFiles: 1, unfLocalBytes: 3}
	want := fmt.Sprintf("push: profile %q%s unfetched: 1 skipped package dir(s) held 1 local file(s), 3 byte(s) outside cache/ the seal did not read (NWP-20261203-29)\n",
		prof, profileTag(prof))
	got := unfetchedLocalLine(prof, st)
	if got != want {
		t.Errorf("unfetchedLocalLine =\n%q\nwant\n%q", got, want)
	}
	if strings.Contains(got, "com.") || strings.Contains(got, os.TempDir()) {
		t.Errorf("the line holds a package name or a path: %q", got)
	}
}

// TestSealUnfetchedLocal_UnreadableEntriesCountTowardTheBound pins that an entry the count cannot read still counts
// toward unfetchedLocalMax (RF-001): a readable dir without search permission makes every child's lstat fail, and the
// count must stop at the bound, not visit them all. The readable files that sort after that dir prove it stopped.
func TestSealUnfetchedLocal_UnreadableEntriesCountTowardTheBound(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores the directory's mode, so no child lstat fails")
	}
	pkg := filepath.Join(t.TempDir(), "com.example.unfbound")
	locked := filepath.Join(pkg, "files", "a-locked")
	if err := os.MkdirAll(locked, 0o700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < unfetchedLocalMax+20; i++ {
		f, err := os.Create(filepath.Join(locked, fmt.Sprintf("e%05d", i)))
		if err != nil {
			t.Fatal(err)
		}
		f.Close()
	}
	for _, z := range []string{"z1", "z2", "z3"} {
		spmWrite(t, pkg, "files/"+z, "zz")
	}
	if err := os.Chmod(locked, 0o400); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o700) })
	if _, err := os.Lstat(filepath.Join(locked, "e00000")); err == nil {
		t.Skip("the dir's mode did not stop a child lstat here")
	}
	if f, b := unfetchedLocalFiles(pkg); f != 0 || b != 0 {
		t.Errorf("unfetchedLocalFiles = files %d, bytes %d; want 0, 0: the %d unreadable entries did not count toward the %d-entry bound",
			f, b, unfetchedLocalMax+20, unfetchedLocalMax)
	}
}
