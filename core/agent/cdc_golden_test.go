package main

// Goldens for the bytes the agent seals for an essential file and for where it cuts a stream into chunks
// (NWP-20261104-10).
//
// The six vectors below are the ones this agent emitted at 8a6f3098 (2026-09-10); nowhere-cloud
// cmd/importwasm/cdc_golden_test.go pins the web importer to the same six. A deliberate change to any input (the gear
// table, cdcMin/cdcMax/cdcMask, the zstd level or a klauspost/compress bump, the convergent nonce, the tar header
// shape) re-chunks every profile once and must update both repos together. A vector that stops reproducing is a
// finding, never a line to edit.
//
// The six fixture files are periodic (byte i = (31i+n) mod 251), so their gear hash never meets the mask and each is
// a single chunk under any gear table: they pin the tar, zstd, the seal and cdcMax, but not where chunks are cut.
// TestCDCBoundariesGolden pins the cut. Its lengths were computed in Python from the rule as written, never by this
// package: a splitmix64 gear table from seed 0x9E3779B97F4A7C15; h = (h<<1) + gear[b] mod 2^64; a cut when
// len >= cdcMin and (len >= cdcMax or h & cdcMask == 0); h reset after each cut.

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const (
	cdcGoldMtime     = 1700000000
	cdcGoldStreamLen = 13631488
	cdcGoldStreamSHA = "b627c42c5fdbc949fea6b3153e5e0d0fa92ea708d70ce8c2d5a3507f798c3f9a"
)

var cdcGoldVectors = []struct {
	n, tarLen int
	hash      string
}{
	{0, 512, "a344c5f7877d2a919b0c6a1f2eae67c8b559e43c69c0edd59b658709239de603"},
	{1, 1024, "2e819d3edcc76d9fc983288e836e139210297c80e4b39d1c5c5e644bb6beab28"},
	{1000, 1536, "0e944302605fdd68985dca18ca09854638fc8cb6004366fbf4aa1ffc26530ede"},
	{307200, 307712, "2529138ff2fb4a09b6562b2d0ce5f8eea301de56a0d435eebfec4bb3cf3e9ca7"},
	{921600, 922112, "07398eadd12b402f5cfb77a1217a1186c8205cd63b65b590c1cc80f0a2b5b78e"},
	{1536000, 1536512, "503ba9daeb945b82d08e434d3964ee636bfd77750cceb2afe09e6f4f1dc4c8c6"},
}

var cdcGoldBoundaries = []int{408509, 381668, 1213161, 932519, 1843999, 1530440, 291848, 404692, 667334, 4194304, 1763014}

func cdcGoldKey() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i * 7)
	}
	return k
}

func cdcGoldFileBytes(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte((i*31 + n) % 251)
	}
	return b
}

// cdcGoldWriteFile writes b at root/rel with mode 0600 (chmod after the write, so the umask cannot change it) and
// mtime 1700000000, and returns its Lstat.
func cdcGoldWriteFile(t *testing.T, root, rel string, b []byte) (string, os.FileInfo) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, 0o600); err != nil {
		t.Fatal(err)
	}
	mt := time.Unix(cdcGoldMtime, 0)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	return p, info
}

// cdcGoldStream is sha256("nowhere-cdc-gold:<i>") for i = 0..262143 (8 MiB) followed by 5 MiB of zeros.
func cdcGoldStream() []byte {
	s := make([]byte, 0, cdcGoldStreamLen)
	for i := 0; i < 262144; i++ {
		d := sha256.Sum256([]byte(fmt.Sprintf("nowhere-cdc-gold:%d", i)))
		s = append(s, d[:]...)
	}
	return append(s, make([]byte, 5<<20)...)
}

func TestEssentialChunksGolden(t *testing.T) {
	key := cdcGoldKey()
	root := t.TempDir()
	for _, v := range cdcGoldVectors {
		t.Run(fmt.Sprintf("n=%d", v.n), func(t *testing.T) {
			rel := fmt.Sprintf("DCIM/f%d.bin", v.n)
			p, info := cdcGoldWriteFile(t, root, rel, cdcGoldFileBytes(v.n))
			var buf bytes.Buffer
			torn, err := writeEntryTarChecked(&buf, p, info, rel)
			if err != nil || torn {
				t.Fatalf("writeEntryTarChecked: torn=%v err=%v", torn, err)
			}
			if buf.Len() != v.tarLen {
				t.Fatalf("tar fragment is %d bytes, want %d", buf.Len(), v.tarLen)
			}
			var chunks [][]byte
			cdcSplit(bytes.NewReader(buf.Bytes()), func(c []byte) { chunks = append(chunks, c) })
			if len(chunks) != 1 {
				t.Fatalf("cdcSplit made %d chunks, want 1", len(chunks))
			}
			sum := sha256.Sum256(seal(key, packChunk(chunks[0], true)))
			if got := hex.EncodeToString(sum[:]); got != v.hash {
				t.Errorf("sealed chunk hash %s, want %s", got, v.hash)
			}
		})
	}
}

func TestCDCBoundariesGolden(t *testing.T) {
	s := cdcGoldStream()
	sum := sha256.Sum256(s)
	if len(s) != cdcGoldStreamLen || hex.EncodeToString(sum[:]) != cdcGoldStreamSHA {
		t.Fatalf("fixture built wrong: %d bytes, sha256 %x (want %d, %s)", len(s), sum, cdcGoldStreamLen, cdcGoldStreamSHA)
	}
	var got []int
	cdcSplit(bytes.NewReader(s), func(c []byte) { got = append(got, len(c)) })
	if fmt.Sprint(got) != fmt.Sprint(cdcGoldBoundaries) {
		t.Fatalf("chunk lengths\n got %v\nwant %v", got, cdcGoldBoundaries)
	}
}

func TestEssentialEntryTarHeaderShape(t *testing.T) {
	rel := "DCIM/shape.bin"
	p, info := cdcGoldWriteFile(t, t.TempDir(), rel, []byte("abc"))
	var buf bytes.Buffer
	if torn, err := writeEntryTarChecked(&buf, p, info, rel); err != nil || torn {
		t.Fatalf("writeEntryTarChecked: torn=%v err=%v", torn, err)
	}
	// header block + one padded data block; an end-of-archive trailer would make it 2048
	if buf.Len() != 1024 {
		t.Fatalf("fragment is %d bytes, want 1024 (header + padded data, no trailer)", buf.Len())
	}
	tr := tar.NewReader(bytes.NewReader(buf.Bytes()))
	h, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if h.Typeflag != tar.TypeReg || h.Name != rel || h.Size != 3 {
		t.Errorf("typeflag %q name %q size %d", h.Typeflag, h.Name, h.Size)
	}
	if h.Uid != 0 || h.Gid != 0 || h.Uname != "" || h.Gname != "" {
		t.Errorf("owner %d:%d %q:%q, want 0:0 empty names", h.Uid, h.Gid, h.Uname, h.Gname)
	}
	if h.ModTime.Unix() != cdcGoldMtime {
		t.Errorf("mtime %d, want %d", h.ModTime.Unix(), cdcGoldMtime)
	}
	if data, _ := io.ReadAll(tr); string(data) != "abc" {
		t.Errorf("data %q", data)
	}
	if _, err := tr.Next(); err != io.EOF {
		t.Errorf("second Next() = %v, want io.EOF", err)
	}
}
