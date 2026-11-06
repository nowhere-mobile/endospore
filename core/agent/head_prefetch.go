package main

// Head-blob prefetch (NWP-20260820-33): warm the login's head/manifest BLOBS into a content-addressed
// tmpfs cache from the LOGIN DAEMON, in the background, while the chooser is still creating the Android
// user -- so the six per-scope restore invocations that follow find those bytes locally instead of each
// paying its own gateway /cap + presigned GET for them.
//
// WHY THIS SHAPE AND NOT THE FIVE THAT CAME BEFORE IT. Head resolution measured 14,665ms of an 82s login
// (NWP-20260820-31): cap 18/5127ms + store 20/8380ms + kdf 11/1150ms + other 8ms. Five designs to reduce it
// were adversarially reviewed and ALL refuted -- the full consolidation widens the untar->reown window with
// installd live (the DIA-20260625-03 delete shape); persisting capReadCache writes read-capabilities to
// disk; and staging the HEAD DECISION (ref -> hash) fatally bypassed the #139 deleted-profile gate, because
// headRef probes per-unit heads that deleteProfile fences but does not purge, so "a staged record exists"
// does NOT imply "not deleted". The full record is in worklog NWP-20260820-33.
//
// What survives is this, and it is safe BY CONSTRUCTION rather than by argument:
//
//   PREFETCH THE CONTENT-ADDRESSED BLOBS, NEVER THE HEAD DECISION.
//
//   - Every ref probe stays LIVE in every restore process. profileDeleted stays unconditional. Blind login,
//     the #139 refusal and its heal are byte-for-byte untouched.
//   - The cache holds only CIPHERTEXT named by its own sha256 (the same property as the store itself, and
//     the same mechanism nowhere_otad.sh already ships as NOWHERE_CHUNK_CACHE). cacheRead re-hashes on every
//     read and drops a mismatch, so a torn or corrupted entry self-heals into a live fetch.
//   - A content-addressed entry CANNOT GO STALE. If a concurrent seal advances the head, the live ref probe
//     returns a DIFFERENT hash, the cache simply misses, and the fetch goes to the network. This is why the
//     headRef "NOT memoized -- a cached ref could go stale -> FALSE BLANK LOGIN" warning (main.go) is not
//     bent here: the ref is never cached, only the bytes a ref was already observed to point at.
//   - Nothing passphrase-derived touches disk: not a ref, not a key, not a cap URL, not an HMAC of any of
//     them. Filenames are the blobs' own public sha256 hashes.
//
// LIFECYCLE. Fired from handleSeedSsaid -- the one daemon op the chooser calls BETWEEN createAndManageUser
// and startUserInBackground on every real login -- so the ~2.8s of network here overlaps the ~2s the chooser
// spends creating/starting the user plus its own pre-ROAM-IN work, instead of sitting on the critical path.
// Purely opportunistic: nothing waits for it, nothing checks it ran, and every miss falls through to today's
// live fetch. Worst case (crash, offline, wrong pass, races) is exactly the pre-change login. roamd clears
// the directory at the end of `in)` to reclaim tmpfs; a leftover from a failed login is a few hundred KB of
// ciphertext on a RAM tmpfs that the next login overwrites and power-off wipes.
//
// BLIND LOGIN. Only HITS are staged: a wrong passphrase or unknown profile derives refs that probe to
// nothing, so nothing is staged and the restores take today's path unchanged. The prefetch itself is
// backgrounded and gates nothing, so it adds no user-observable timing difference between blank and real.

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// headBlobCacheDir is derived from NOWHERE_STATE rather than its own env var so the daemon (env from
// nowhere_login.sh) and the per-scope restore processes (env from nowhere_roamd.sh) agree by construction.
// Empty when NOWHERE_STATE is unset (host CLI, tests) -> the whole feature is inert.
func headBlobCacheDir() string {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return ""
	}
	return filepath.Join(st, "headblobs")
}

// headBlobGet is getBlob with the prefetch cache in front of it. On a hit the bytes were verified against
// their own hash by cacheRead; on a miss the live getBlob runs exactly as before this change (including its
// fail() on absence -- absence after a successful ref resolve is store corruption and must stay loud), and
// the fetched bytes are written back so a second scope needing the same blob hits.
func headBlobGet(base, hash string) []byte {
	dir := headBlobCacheDir()
	if b, ok := cacheRead(dir, hash); ok {
		return b
	}
	b := getHeadBlob(base, hash) // #116: never cache or return bytes we have not proven
	cacheWrite(dir, hash, b)
	return b
}

// prefetchHeadBlobs resolves the six login scopes' heads and stages their blobs. Safe to call from the
// long-lived daemon: every panic path (getBlob's fail on a flaky store, offline retries exhausting) is
// recovered, and the goroutines it spawns each recover independently.
func prefetchHeadBlobs(base, name, pass string) {
	defer func() { recover() }()
	if headBlobCacheDir() == "" || name == "" || pass == "" {
		return
	}
	t0 := time.Now()

	// The six scopes of a login, matching nowhere_roamd.sh's in) chain: the bare vault, then #de, #sys,
	// #media, #apps, #keys. (#wallet is daemon-side and small; the media tiers ride #media.)
	scopes := []string{name, name + "#de", name + "#sys", name + "#media", name + "#apps", name + "#keys"}

	// Phase 0 -- derive the refs SERIALLY. Each scoped name is its own Argon2 (64 MiB, 4 threads); serial
	// keeps peak memory at one derivation, and the daemon's process-wide memo keeps every later use (the
	// probes below, and this daemon's own post-restore work) free. ~630ms total.
	type cand struct{ scope, v2, lg string }
	cands := make([]cand, 0, len(scopes))
	capKeys := make([]string, 0, len(scopes)*2)
	for _, s := range scopes {
		v2, lg := profileRefV2(s, pass), profileRefLegacy(s, pass)
		cands = append(cands, cand{s, v2, lg})
		capKeys = append(capKeys, "ref/"+v2, "ref/"+lg)
	}

	// Phase 1 -- ONE batched /caps POST for every candidate ref, then probe the six heads concurrently
	// (presigned GETs only, since the cap URLs are now warm). prefetchReadCaps is the mechanism the chunk
	// path has shipped since #71; it is best-effort and an old gateway just means per-key /cap fallbacks.
	// Under NOWHERE_MULTIDEVICE headRef probes unit-head refs this warm-up did not cover -- those pay their
	// own /cap each, which is correct and merely slower.
	prefetchReadCaps(capKeys)
	heads := make([]string, len(cands)) // "" = no head (blank/tombstoned/absent) -> nothing staged
	var wg sync.WaitGroup
	for i := range cands {
		wg.Add(1)
		goSafe("head-prefetch probe", func() {
			defer wg.Done()
			defer func() { recover() }()
			ref, val, have := headRef(base, cands[i].scope, pass)
			if !have { // non-cap backend: the probe did not carry the value; read it (same second call as a restore)
				val = getRef(base, ref)
			}
			heads[i] = val
		})
	}
	wg.Wait()

	// Phase 2 -- ONE batched /caps POST for the discovered head blobs, then fetch them concurrently into the
	// cache. The bare scope's head may be a vault; its (plaintext) Manifest field names one more blob, fetched
	// in the same goroutine -- no DK, no vault open, no signature check here. The CONSUMER still runs
	// parseVault/openVaultDK/verifyVault/checkRollback exactly once, exactly as today.
	blobKeys := make([]string, 0, len(heads)+1)
	for _, h := range heads {
		if h != "" {
			blobKeys = append(blobKeys, "blob/"+h)
		}
	}
	if len(blobKeys) == 0 {
		fmt.Fprintf(os.Stderr, "[logind] head-prefetch: no heads (blank or offline) in %dms\n", time.Since(t0).Milliseconds())
		return
	}
	prefetchReadCaps(blobKeys)
	var staged int64
	var stagedMu sync.Mutex
	for i := range cands {
		if heads[i] == "" {
			continue
		}
		wg.Add(1)
		goSafe("head-prefetch blob", func() {
			defer wg.Done()
			defer func() { recover() }() // a single flaky blob must not sink the rest of the burst
			b := headBlobGet(base, heads[i])
			n := int64(1)
			if v, isV := parseVault(b); isV && v.Manifest != "" {
				headBlobGet(base, v.Manifest)
				n++
			}
			stagedMu.Lock()
			staged += n
			stagedMu.Unlock()
		})
	}
	wg.Wait()
	fmt.Fprintf(os.Stderr, "[logind] head-prefetch: staged %d blob(s) in %dms\n", staged, time.Since(t0).Milliseconds())
}
