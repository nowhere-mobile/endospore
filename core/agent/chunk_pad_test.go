package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261124-22 (h54 #2, slice a): the reader of padded chunks and manifests. Every test here uses its own
// key or profile name, because the blob and content caches are keyed by it.

func chunkPadKey(tag string) []byte {
	k := sha256.Sum256([]byte("chunkpad-" + tag))
	return k[:]
}

// chunkPadRandom is deterministic incompressible bytes: zstd stores them in raw blocks, so the compressed
// length moves one for one with the input length.
func chunkPadRandom(seed int64, n int) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

// chunkPadK is the number of zero bytes after the marker in a padded payload made from a zstd payload p.
func chunkPadK(p, padded []byte) int { return len(padded) - len(p) - 1 }

// chunkPadFindLen finds an input length near `near` whose padded payload has exactly k zeros.
func chunkPadFindLen(t *testing.T, src []byte, near, k int) []byte {
	t.Helper()
	for n := near - 512; n < near+512; n++ {
		if n < 0 || n > len(src) {
			continue
		}
		c := src[:n]
		p := zstdEnc.EncodeAll(c, nil)
		if chunkPadK(p, padChunkPayload(p, chunkPadStep)) == k {
			return c
		}
	}
	t.Fatalf("setup: no input length near %d pads with k=%d", near, k)
	return nil
}

// TestChunkPadSealOverhead pins the constant padChunkPayload counts on: seal() adds the nonce and the tag.
func TestChunkPadSealOverhead(t *testing.T) {
	key := chunkPadKey("overhead")
	for _, n := range []int{0, 1, 4096, chunkPadStep} {
		if got := len(seal(key, make([]byte, n))); got != n+sealOverhead {
			t.Errorf("seal of %d bytes is %d bytes, want %d", n, got, n+sealOverhead)
		}
	}
}

// TestChunkPadRoundTripV3: a version-3 chunk of 0 B, 1 B, and lengths that pad with k = 0, k = 1 and a
// near-full step, stores as a multiple of 256 KiB and reads back byte-identical.
func TestChunkPadRoundTripV3(t *testing.T) {
	key := chunkPadKey("roundtrip")
	src := chunkPadRandom(1, 3*chunkPadStep)
	cases := []struct {
		name string
		c    []byte
		k    int // -1: any
	}{
		{"0 B", []byte{}, -1},
		{"1 B", []byte{0x42}, -1},
		{"k=0", chunkPadFindLen(t, src, chunkPadStep-sealOverhead-1, 0), 0},
		{"k=1", chunkPadFindLen(t, src, chunkPadStep-sealOverhead-2, 1), 1},
		{"k=step-1", chunkPadFindLen(t, src, chunkPadStep-sealOverhead, chunkPadStep-1), chunkPadStep - 1},
	}
	for _, tc := range cases {
		p := zstdEnc.EncodeAll(tc.c, nil)
		padded := padChunkPayload(p, chunkPadStep)
		if tc.k >= 0 && chunkPadK(p, padded) != tc.k {
			t.Fatalf("%s: k=%d, want %d", tc.name, chunkPadK(p, padded), tc.k)
		}
		blob := seal(key, padded)
		if len(blob)%chunkPadStep != 0 {
			t.Errorf("%s: stored length %d is not a multiple of %d", tc.name, len(blob), chunkPadStep)
		}
		got, err := unpackChunk(unseal(key, blob), chunkVersionPadded)
		if err != nil {
			t.Errorf("%s: unpackChunk v3: %v", tc.name, err)
			continue
		}
		if !bytes.Equal(got, tc.c) {
			t.Errorf("%s: v3 round trip gave %d bytes, want the original %d", tc.name, len(got), len(tc.c))
		}
	}
}

// TestChunkPadPayloadShape: the pad is the payload, one 0x80, then zeros, and it never aliases its input.
func TestChunkPadPayloadShape(t *testing.T) {
	p := []byte{1, 2, 3}
	out := padChunkPayload(p, 64)
	if len(out)+sealOverhead != 64 || !bytes.Equal(out[:3], p) || out[3] != chunkPadMarker {
		t.Fatalf("padChunkPayload(%v, 64) = %v", p, out)
	}
	for _, b := range out[4:] {
		if b != 0 {
			t.Fatalf("pad holds a non-zero byte: %v", out)
		}
	}
	out[0] = 9
	if p[0] != 1 {
		t.Fatal("padChunkPayload aliases its input")
	}
	defer func() {
		if recover() == nil {
			t.Error("padChunkPayload(p, 0) did not panic")
		}
	}()
	padChunkPayload(p, 0)
}

// TestChunkPadV3NoMarkerRefused: a version-3 payload with no 0x80 is an error, never decoded as it is.
func TestChunkPadV3NoMarkerRefused(t *testing.T) {
	p := zstdEnc.EncodeAll([]byte("a version-3 chunk with no pad marker"), nil)
	if p[len(p)-1] == 0x00 || p[len(p)-1] == chunkPadMarker {
		t.Fatalf("setup: the frame ends in %#x", p[len(p)-1])
	}
	for name, b := range map[string][]byte{
		"no pad":         p,
		"zeros, no 0x80": append(append([]byte{}, p...), 0, 0),
	} {
		got, err := unpackChunk(b, chunkVersionPadded)
		if err == nil || got != nil {
			t.Errorf("%s: unpackChunk v3 = %d bytes, %v; want nil and an error", name, len(got), err)
		}
	}
}

// TestChunkPadV1Untouched: a V1 chunk is raw and is never stripped, even when it ends like a pad.
func TestChunkPadV1Untouched(t *testing.T) {
	c := []byte("raw v1 bytes\x80\x00\x00")
	got, err := unpackChunk(c, 1)
	if err != nil || !bytes.Equal(got, c) {
		t.Fatalf("unpackChunk v1 = %q, %v; want %q unchanged", got, err, c)
	}
}

// TestChunkPadV2FrameEndingInZeroUntouched: a V2 zstd frame that ends in 0x00 (its checksum) decodes as it
// is; the reader never strips a V2 chunk that zstd accepts.
func TestChunkPadV2FrameEndingInZeroUntouched(t *testing.T) {
	for seed := int64(0); seed < 50000; seed++ {
		c := chunkPadRandom(seed, 64)
		p := zstdEnc.EncodeAll(c, nil)
		if p[len(p)-1] != 0x00 {
			continue
		}
		got, err := unpackChunk(p, 2)
		if err != nil || !bytes.Equal(got, c) {
			t.Fatalf("seed %d: unpackChunk v2 of a frame ending in 0x00 = %d bytes, %v; want the original", seed, len(got), err)
		}
		return
	}
	t.Fatal("setup: no zstd frame ending in 0x00 found")
}

// TestChunkPadV2CarriedPadded: a padded chunk a seal carried into a V2 manifest still reads back.
func TestChunkPadV2CarriedPadded(t *testing.T) {
	src := chunkPadRandom(2, 2*chunkPadStep)
	for _, c := range [][]byte{
		[]byte("a small carried chunk"),
		chunkPadFindLen(t, src, chunkPadStep-sealOverhead-1, 0),
		chunkPadFindLen(t, src, chunkPadStep-sealOverhead-2, 1),
	} {
		padded := padChunkPayload(zstdEnc.EncodeAll(c, nil), chunkPadStep)
		got, err := unpackChunk(padded, 2)
		if err != nil || !bytes.Equal(got, c) {
			t.Errorf("unpackChunk v2 of a padded %d-byte chunk = %d bytes, %v; want the original", len(c), len(got), err)
		}
	}
}

// TestChunkPadV2GarbageRefused: V2 bytes that are neither zstd nor a padded zstd payload are an error, and
// the error is zstd's own on the bytes as given.
func TestChunkPadV2GarbageRefused(t *testing.T) {
	garbage := []byte("this is not a zstd frame at all")
	for name, b := range map[string][]byte{
		"garbage":        garbage,
		"padded garbage": append(append([]byte{}, garbage...), chunkPadMarker, 0, 0, 0),
		"unmarked zeros": append(append([]byte{}, garbage...), 0, 0),
	} {
		_, want := zstdDec.DecodeAll(b, nil)
		got, err := unpackChunk(b, 2)
		if err == nil || got != nil {
			t.Errorf("%s: unpackChunk v2 = %d bytes, %v; want nil and an error", name, len(got), err)
			continue
		}
		if want == nil || err.Error() != want.Error() {
			t.Errorf("%s: unpackChunk v2 error %q, want the original zstd error %q", name, err, want)
		}
	}
}

// TestChunkPadPaddedManifestLoads: a version-3 manifest padded with spaces to a power of two loads with its
// version and chunks intact.
func TestChunkPadPaddedManifestLoads(t *testing.T) {
	base := newHTTPStore(t)
	dk := chunkPadKey("manifest")
	want := chunkManifest{Version: chunkVersionPadded, Chunks: []string{strings.Repeat("a", 64), strings.Repeat("b", 64)}}
	js, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	pt := append(append([]byte{}, cdcMagic...), js...)
	n := 1
	for n <= len(pt) {
		n <<= 1
	}
	pt = append(pt, bytes.Repeat([]byte{' '}, n-len(pt))...)
	if len(pt)&(len(pt)-1) != 0 || pt[len(pt)-1] != ' ' {
		t.Fatalf("setup: padded manifest is %d bytes", len(pt))
	}
	h := postBlob(base, seal(dk, pt))
	m, ml := classifyManifestLoad(base, dk, h)
	if ml != mlOK || m.Version != chunkVersionPadded || strings.Join(m.Chunks, ",") != strings.Join(want.Chunks, ",") {
		t.Fatalf("classifyManifestLoad = %+v, %v; want %+v, mlOK", m, ml, want)
	}
	if l := loadCDCManifest(base, dk, h); l.Version != chunkVersionPadded || len(l.Chunks) != len(want.Chunks) {
		t.Fatalf("loadCDCManifest = %+v; want %+v", l, want)
	}
}

// chunkPadTar is a two-file tar stream and the files it holds.
func chunkPadTar(t *testing.T) ([]byte, map[string][]byte) {
	t.Helper()
	files := map[string][]byte{
		"a-big.bin":   chunkPadRandom(3, 300<<10),
		"b-small.txt": []byte("after the big one"),
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, name := range []string{"a-big.bin", "b-small.txt"} {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: int64(len(files[name])), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(files[name]); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes(), files
}

// chunkPadRestore seals the tar stream in two chunks (pad[i] says whether chunk i is padded), restores it
// through cdcRestore under `version`, and checks every file comes back byte-identical.
func chunkPadRestore(t *testing.T, tag string, version int, pad [2]bool) {
	t.Helper()
	oc, rb := chunkCacheDir, s3RetryBase
	chunkCacheDir, s3RetryBase = "", time.Millisecond
	t.Cleanup(func() { chunkCacheDir, s3RetryBase = oc, rb })
	base := newHTTPStore(t)
	key := chunkPadKey(tag)
	stream, files := chunkPadTar(t)
	half := len(stream) / 2
	m := chunkManifest{Version: version}
	for i, part := range [][]byte{stream[:half], stream[half:]} {
		p := zstdEnc.EncodeAll(part, nil)
		if pad[i] {
			p = padChunkPayload(p, chunkPadStep)
		}
		blob := seal(key, p)
		if pad[i] && len(blob)%chunkPadStep != 0 {
			t.Fatalf("setup: padded chunk %d stores as %d bytes", i, len(blob))
		}
		m.Chunks = append(m.Chunks, postBlob(base, blob))
	}
	dest := t.TempDir()
	var skipped int
	if err := recovered(func() { skipped = cdcRestore(base, key, m, dest) }); err != nil {
		t.Fatalf("cdcRestore v%d: %v", version, err)
	}
	if skipped != 0 {
		t.Fatalf("cdcRestore v%d skipped %d entries", version, skipped)
	}
	for name, want := range files {
		got, err := os.ReadFile(filepath.Join(dest, name))
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("v%d restore of %s: %d bytes, %v; want the original %d", version, name, len(got), err, len(want))
		}
	}
}

// TestChunkPadRestoreV3: a hand-built version-3 manifest restores the original bytes.
func TestChunkPadRestoreV3(t *testing.T) {
	chunkPadRestore(t, "restore-v3", chunkVersionPadded, [2]bool{true, true})
}

// TestChunkPadRestoreV2Mixed: a V2 manifest holding one plain and one carried padded chunk restores the
// original bytes.
func TestChunkPadRestoreV2Mixed(t *testing.T) {
	chunkPadRestore(t, "restore-v2-mixed", 2, [2]bool{false, true})
}

// TestChunkPadSealStillWritesV2: this slice is a reader only; a fresh seal still writes version 2.
func TestChunkPadSealStillWritesV2(t *testing.T) {
	t.Setenv("NOWHERE_COMPRESS", "1")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	pushFenceSeq, pushFenceSampled = 0, false
	base := newHTTPStore(t)
	name, pass := "chunkpad-seal", "chunk pad seal staple battery"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("the seal still writes version two"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	pushFenceSeq, pushFenceSampled = 0, false
	key, mb, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("no head after the push")
	}
	pt := unseal(key, mb)
	if !bytes.HasPrefix(pt, cdcMagic) {
		t.Fatal("head is not a CDC manifest")
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		t.Fatal(err)
	}
	if m.Version != 2 || !bytes.Contains(pt, []byte(`"v":2`)) {
		t.Fatalf("a fresh seal wrote version %d; want 2 (nothing writes version %d yet)", m.Version, chunkVersionPadded)
	}
}
