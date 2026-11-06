package main

import "errors"

// ---- Padded chunks and manifests (h54 #2, slice a: the READER; NWP-20261124-22) ----
// docs/product-decisions.md, 2026-11-02, h54 #2: chunks in every scope are padded so the stored object is a
// multiple of 256 KiB, and manifests to a power of two, so the store sees size buckets instead of exact
// lengths. A reader that accepts padding ships and reaches every phone BEFORE any writer pads. This file is
// that reader; nothing in the seal writes version 3 yet (slice b, behind its flag). Format: docs/storage.md.
//
// A version-3 chunk is seal(key, zstd(chunk) || 0x80 || 0x00*k), k >= 0. The 0x80 marks where the pad
// starts: zstd(chunk) may itself end in 0x00 bytes (its checksum), so stripping zeros alone could eat data.
// 0x80 can never start a zstd frame (0x28...) or a skippable frame (0x5?...), so zstd never reads the pad
// as a frame. A padded manifest is cdcMagic || JSON || 0x20*n; json.Unmarshal already ignores the spaces,
// so it reads with no code change.
const (
	chunkVersionPadded = 3         // a manifest whose chunks are all padded
	chunkPadMarker     = 0x80      // the one byte between the zstd payload and the zero pad
	chunkPadStep       = 256 << 10 // the decided stored-length multiple of a padded chunk
	sealOverhead       = 12 + 16   // what seal() adds: the GCM nonce and the tag
)

var errChunkPadMarker = errors.New("padded chunk: no 0x80 pad marker")

// unpadChunk strips a chunk's pad: the trailing 0x00 bytes, then exactly one 0x80. A payload with no 0x80
// before its trailing zeros is an error, never a payload to decode as it is.
func unpadChunk(b []byte) ([]byte, error) {
	i := len(b)
	for i > 0 && b[i-1] == 0x00 {
		i--
	}
	if i == 0 || b[i-1] != chunkPadMarker {
		return nil, errChunkPadMarker
	}
	return b[:i-1], nil
}

// decodeChunk is zstd DecodeAll without its partial output: on an error it returns nil, so a caller can
// never pass on half a chunk.
func decodeChunk(b []byte) ([]byte, error) {
	out, err := zstdDec.DecodeAll(b, nil)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// padChunkPayload is unpadChunk's inverse: p || 0x80 || the fewest zeros that make the SEALED length
// (len(p)+1+zeros+sealOverhead) a multiple of storedMultiple. It returns a new slice and never aliases p.
// It has no caller in the seal yet: the tests use it, and so will the writer (slice b). A storedMultiple
// <= 0 is a programming error, not data, so it panics.
func padChunkPayload(p []byte, storedMultiple int) []byte {
	if storedMultiple <= 0 {
		panic("padChunkPayload: storedMultiple must be > 0")
	}
	n := len(p) + 1 + sealOverhead
	zeros := (storedMultiple - n%storedMultiple) % storedMultiple
	out := make([]byte, len(p)+1+zeros)
	copy(out, p)
	out[len(p)] = chunkPadMarker
	return out
}
