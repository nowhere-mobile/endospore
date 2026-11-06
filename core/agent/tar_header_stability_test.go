package main

import (
	"archive/tar"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestSealTarHeaderIgnoresAtimeAndCtime pins what the backlog row "The seal's tar is PAX, not USTAR" (NWP-20260830-02)
// got wrong. tar.FileInfoHeader fills AccessTime/ChangeTime, but writeTarEntry never sets hdr.Format, and with Format
// unspecified Go's tar.Writer picks USTAR when the header fits, rounds ModTime and zeroes atime/ctime. The row's
// FormatUSTAR evidence only covers an EXPLICIT FormatUSTAR, which the seal never sets. So a read (atime) or a
// metadata change (ctime) must not change a single sealed byte. If this fails, do NOT "fix" writeTarEntry in place:
// it changes the bytes of every entry and costs a full re-upload of every profile (bump tarEntryFormat, ask Chester).
func TestSealTarHeaderIgnoresAtimeAndCtime(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "f.bin")
	dir := filepath.Join(root, "d")
	if err := os.WriteFile(file, []byte("sealed bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}

	seal := func(p, rel string) []byte {
		t.Helper()
		info, err := os.Lstat(p)
		if err != nil {
			t.Fatal(err)
		}
		var buf bytes.Buffer
		if err := writeEntryTar(&buf, p, info, rel); err != nil {
			t.Fatal(err)
		}
		return buf.Bytes()
	}

	for _, c := range []struct {
		name, path, rel string
		dir             bool
	}{{"file", file, "f.bin", false}, {"dir", dir, "d/", true}} {
		t.Run(c.name, func(t *testing.T) {
			before := seal(c.path, c.rel)
			info, err := os.Lstat(c.path)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.Chtimes(c.path, time.Now().Add(time.Hour), info.ModTime()); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(c.path, info.Mode().Perm()); err != nil { // moves ctime
				t.Fatal(err)
			}
			after := seal(c.path, c.rel)
			if !bytes.Equal(before, after) {
				t.Fatalf("header bytes changed when only atime/ctime moved")
			}
			if len(before) < 512 {
				t.Fatalf("short entry: %d bytes", len(before))
			}
			if tf := before[156]; tf == 'x' || tf == 'g' {
				t.Fatalf("first block typeflag %q: the seal wrote a PAX header", tf)
			}
			if c.dir && len(before) != 512 {
				t.Fatalf("dir entry is %d bytes, want 512", len(before))
			}
			hdr, err := tar.NewReader(bytes.NewReader(before)).Next()
			if err != nil && err != io.EOF {
				t.Fatal(err)
			}
			if hdr.Format != tar.FormatUSTAR {
				t.Fatalf("format = %v, want USTAR", hdr.Format)
			}
		})
	}
}
