package main

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260821-06 (ticket NW-b8b659735124). AliExpress's U4 WebView plants symlinks in its v8_cache -- the
// first app data we carry containing any. The seal used to count them BLIND (denied lstat) and refuse every
// logoff. The fix: the seal SKIPS symlinks (not blind), and the restore REJECTS any link entry. Nothing
// creates a symlink, so the tar-slip root-write escape that a carry-and-recreate design would open (found in
// adversarial review) cannot exist. These tests pin exactly that.

func sealRestoreRoundtrip(t *testing.T, src, dst string) int {
	t.Helper()
	var buf bytes.Buffer
	if _, err := tarDirTo(src, &buf); err != nil {
		t.Fatalf("tarDirTo: %v", err)
	}
	return untarFrom(dst, &buf)
}

// A session whose app planted symlinks must SEAL cleanly (0 skipped by the walk itself -- the walk succeeds;
// the links are simply not emitted) and RESTORE with the real files intact and NO links present.
func TestSymlinksAreSkippedNotBlindAndNotCarried(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	sub := filepath.Join(src, "com.alibaba.aliexpresshd", "cache", "v8")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "real"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	// the shapes AliExpress actually plants + the dangerous ones: relative, absolute-internal, absolute-external.
	mklink := func(target, name string) {
		if err := os.Symlink(target, filepath.Join(sub, name)); err != nil {
			t.Fatal(err)
		}
	}
	mklink("real", "rel")
	mklink(filepath.Join(sub, "real"), "abs_internal")
	mklink("/etc/passwd", "abs_external")

	// The seal must SUCCEED. If a symlink were still counted blind, pushProfile would refuse -- but tarDirTo
	// is the walk under test here and it must simply not emit the links. The real regression assertion is
	// that the roundtrip does not error and the restore is clean.
	if skipped := sealRestoreRoundtrip(t, src, dst); skipped != 0 {
		t.Fatalf("restore skipped %d entries, want 0 (no link entries should reach the restore at all)", skipped)
	}
	// the real file roamed
	if b, err := os.ReadFile(filepath.Join(dst, "com.alibaba.aliexpresshd", "cache", "v8", "real")); err != nil || string(b) != "payload" {
		t.Fatalf("real file did not roam: %v %q", err, b)
	}
	// no link of any kind reached the restore tree
	for _, name := range []string{"rel", "abs_internal", "abs_external"} {
		if _, err := os.Lstat(filepath.Join(dst, "com.alibaba.aliexpresshd", "cache", "v8", name)); !os.IsNotExist(err) {
			t.Fatalf("%s reached the restore tree -- symlinks must not be carried", name)
		}
	}
}

// The escape found in adversarial review: a self-link + a redirect-link + a file, all lexically contained,
// that physically escape the restore root. The restore must reject the link entries so the escape cannot
// even begin. This is the regression test for the fatal finding.
func TestRestoreRejectsTheTarSlipEscapeChain(t *testing.T) {
	dst := t.TempDir()
	outside := filepath.Dir(dst) // the parent the escape aims at

	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	// E1: self-link makes lexical depth exceed physical depth
	tw.WriteHeader(&tar.Header{Name: "deep", Typeflag: tar.TypeSymlink, Linkname: "."})
	// E2: lexically dst/out_content (contained), physically parent(dst)/out_content (escapes) via dst/deep->.
	tw.WriteHeader(&tar.Header{Name: "deep/out", Typeflag: tar.TypeSymlink, Linkname: "../out_content"})
	// E3: the payload write that would land outside the root through the intermediate link
	tw.WriteHeader(&tar.Header{Name: "out/pwned", Typeflag: tar.TypeReg, Mode: 0o600, Size: 5})
	tw.Write([]byte("PWNED"))
	tw.Close()

	skipped := untarFrom(dst, &buf)
	if skipped < 2 {
		t.Fatalf("expected both link entries rejected (skipped>=2), got %d", skipped)
	}
	// the smoking gun: nothing was written outside the restore root
	if _, err := os.Lstat(filepath.Join(outside, "out_content")); !os.IsNotExist(err) {
		t.Fatal("ESCAPE: out_content was created OUTSIDE the restore root")
	}
	if _, err := os.Lstat(filepath.Join(outside, "out_content", "pwned")); !os.IsNotExist(err) {
		t.Fatal("ESCAPE: a root write landed outside the restore root")
	}
	// and no link was created inside either
	if fi, err := os.Lstat(filepath.Join(dst, "deep")); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		t.Fatal("a rejected symlink was nevertheless created inside the root")
	}
}

func TestHardlinkEntriesAlsoRejected(t *testing.T) {
	dst := t.TempDir()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	tw.WriteHeader(&tar.Header{Name: "hl", Typeflag: tar.TypeLink, Linkname: "some/target"})
	tw.Close()
	if skipped := untarFrom(dst, &buf); skipped != 1 {
		t.Fatalf("hardlink entry skipped=%d, want 1", skipped)
	}
	if _, err := os.Lstat(filepath.Join(dst, "hl")); !os.IsNotExist(err) {
		t.Fatal("a hardlink entry produced a file")
	}
}

func TestFileWriteNeverGoesThroughASquattingLink(t *testing.T) {
	dst := t.TempDir()
	outside := t.TempDir()
	victim := filepath.Join(outside, "victim")
	if err := os.WriteFile(victim, []byte("untouched"), 0o600); err != nil {
		t.Fatal(err)
	}
	// a link squatting at the write target BEFORE the restore (prior partial restore / hostile ordering)
	if err := os.Symlink(victim, filepath.Join(dst, "f")); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	tw.WriteHeader(&tar.Header{Name: "f", Typeflag: tar.TypeReg, Mode: 0o600, Size: 6})
	tw.Write([]byte("inject"))
	tw.Close()

	if skipped := untarFrom(dst, &buf); skipped != 0 {
		t.Fatalf("skipped=%d, want 0 (the squatting link is replaced by the real file)", skipped)
	}
	if b, _ := os.ReadFile(victim); string(b) != "untouched" {
		t.Fatalf("ROOT WRITE WENT THROUGH THE LINK: victim=%q", b)
	}
	if fi, err := os.Lstat(filepath.Join(dst, "f")); err != nil || fi.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("target is still a link or missing, want a regular file")
	}
}
