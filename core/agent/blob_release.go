package main

// A blob's release commitment (docs/store-write-authorization.md R5, docs/product-decisions.md 2026-10-20).
//
// Every seal's lease carries, for each blob it names, SHA-256 of a proof only this profile can derive:
//
//	releaseKey = HMAC-SHA256(dk, "nowhere-blob-release-v1")
//	proof      = HMAC-SHA256(releaseKey, "blob/<64 hex>")
//	commit     = hex(SHA-256(proof))
//
// The proof is derivable from the data key and the blob's address alone, so nothing new is stored on the
// phone and nothing new roams. The gateway sees only the hash until a release presents the proof. A blob
// first leased under a different key (an import, a re-key) simply cannot be released early -- the safe
// direction. releaseCommits is computed from refs AT EACH lease call, because doFold rewrites refs (drops the
// previous wallet blob, adds the new one) between them and the gateway refuses a commitment for a key not in
// the request's refs. A commitment is never logged.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

const blobReleaseLabel = "nowhere-blob-release-v1"

func hmacSHA256(key, msg []byte) []byte {
	h := hmac.New(sha256.New, key)
	h.Write(msg)
	return h.Sum(nil)
}

// blobReleaseKey is the per-profile key the proofs are derived under.
func blobReleaseKey(dk []byte) []byte { return hmacSHA256(dk, []byte(blobReleaseLabel)) }

// blobReleaseProof is the 32-byte preimage that releases the blob at key (the full store key blob/<64 hex>).
func blobReleaseProof(dk []byte, key string) []byte {
	return hmacSHA256(blobReleaseKey(dk), []byte(key))
}

// blobReleaseCommit is the lowercase hex SHA-256 of the proof: what a lease sends.
func blobReleaseCommit(dk []byte, key string) string {
	s := sha256.Sum256(blobReleaseProof(dk, key))
	return hex.EncodeToString(s[:])
}

// releaseCommits is blobReleaseCommit for every blob/ key of refs; nil when dk is empty or there is none.
func releaseCommits(dk []byte, refs map[string]int64) map[string]string {
	if len(dk) == 0 {
		return nil
	}
	var out map[string]string
	for k := range refs {
		if !strings.HasPrefix(k, "blob/") {
			continue
		}
		if out == nil {
			out = map[string]string{}
		}
		out[k] = blobReleaseCommit(dk, k)
	}
	return out
}
