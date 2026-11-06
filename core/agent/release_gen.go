package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// NWP-20261029-04: THE RELEASE GENERATION -- how another handset learns that a snapshot delete released chunks.
//
// A phone's tmpfs blob cache says "this chunk is in the store", and postBlob, the content cache, the incremental
// scan cache and deferredChunksKnown all dedup through blobCacheKnown without leasing or uploading a cached chunk.
// When a snapshot is deleted on handset A and its unshared chunks are released (docs/product-decisions.md,
// 2026-10-20), handset B's cache still names them; B's next seal would publish a head naming collected chunks.
// Nothing in a head said so. vault.ReleaseGen is that signal: each delete bumps it, and a handset whose head
// carries a generation different from the one its cache was filled under drops the cache before it seals or
// seeds it (pushProfile and the restore arm of main()).
//
// Every file here lives beside the blob cache in the state dir (in roamd /data/nowhere/state, the RAM tmpfs mount
// that docs/threat-model.md section 2 excludes), so it is not a durable /data/nowhere path and needs no
// threat-model row. Every function is a no-op when cachePath is "" (NOWHERE_BLOBCACHE unset: no cache, the
// always-stat behaviour).

// relGenHeadKey is THE spelling of the head identity a release generation is recorded under: pushProfile, the
// restore and NOWHERE-736's snapshot delete all use it.
func relGenHeadKey(base, name, pass string) string { return headKey(base, name, pass) }

// relGenTag names a head in the file without the profile name or passphrase.
func relGenTag(headKey string) string {
	sum := sha256.Sum256([]byte("nowhere-relgen\x00" + headKey))
	return hex.EncodeToString(sum[:])[:16]
}

func relGenPath(cachePath string) string { return cachePath + ".relgen" }

// relGenSeen reads the generation the cache was last filled under for this head. Lines are `<tag> <gen>`; the
// last line for a tag wins and a malformed line is ignored.
func relGenSeen(cachePath, headKey string) (uint64, bool) {
	if cachePath == "" {
		return 0, false
	}
	b, err := os.ReadFile(relGenPath(cachePath))
	if err != nil {
		return 0, false
	}
	tag := relGenTag(headKey)
	var gen uint64
	ok := false
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 || f[0] != tag {
			continue
		}
		n, err := strconv.ParseUint(f[1], 10, 64)
		if err != nil {
			continue
		}
		gen, ok = n, true
	}
	return gen, ok
}

// relGenRecord rewrites the file with this head's line replaced (temp file in the same dir, then rename, 0600).
func relGenRecord(cachePath, headKey string, gen uint64) error {
	if cachePath == "" {
		return nil
	}
	p, tag := relGenPath(cachePath), relGenTag(headKey)
	var keep []string
	if b, err := os.ReadFile(p); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			f := strings.Fields(line)
			if len(f) != 2 || f[0] == tag {
				continue
			}
			if _, err := strconv.ParseUint(f[1], 10, 64); err == nil {
				keep = append(keep, f[0]+" "+f[1])
			}
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	keep = append(keep, fmt.Sprintf("%s %d", tag, gen))
	tmp, err := os.CreateTemp(filepath.Dir(p), filepath.Base(p)+".tmp")
	if err != nil {
		return err
	}
	fail := func(err error) error {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		return fail(err)
	}
	if _, err := tmp.WriteString(strings.Join(keep, "\n") + "\n"); err != nil {
		return fail(err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), p); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// blobCacheDrop removes the cache file AND resets the in-memory set, so the next blobCacheInit reloads it empty.
// The content, scan and deferred caches need no drop: each reuses a chunk only through blobCacheKnown, so an
// empty blob cache makes all three miss.
func blobCacheDrop(cachePath string) {
	if cachePath == "" {
		return
	}
	blobCacheMu.Lock()
	defer blobCacheMu.Unlock()
	os.Remove(cachePath)
	blobCache = nil
}

// distrustBlobCacheIfReleased drops the cache when this head's release generation differs from the one the cache
// was filled under (or is non-zero with no record), and records the generation. A head that never had a snapshot
// deleted (generation 0, no record) keeps today's warm path. `!=`, never `<`: a generation that went DOWN (a head
// rebuilt by an image that drops the field) is distrusted too.
func distrustBlobCacheIfReleased(cachePath, headKey string, gen uint64) (dropped bool) {
	if cachePath == "" {
		return false
	}
	seen, ok := relGenSeen(cachePath, headKey)
	if gen == 0 && !ok {
		return false
	}
	if !ok || seen != gen {
		blobCacheDrop(cachePath)
		if err := relGenRecord(cachePath, headKey, gen); err != nil {
			fmt.Printf("relgen: could not record release generation %d: %v -- the next seal drops the cache again\n", gen, err)
		}
		return true
	}
	return false
}

// relGenAtRestore runs in main()'s restore arm for a BARE profile, after resolveKeyHeadForLogin and before
// cdcRestore seeds the cache. headBlobGet is a cache hit when the state dir is set (the restore just fetched
// this head). A failed read is logged and ignored: the restore then seeds as before and the next seal, which
// compares the head's generation with the record, drops the cache -- the safe direction.
func relGenAtRestore(base, profile, pass, head string) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Printf("restore: profile %s: release generation not checked (%s) -- the next seal checks it\n", logProfile(profile), logSafeErrText(r))
		}
	}()
	var gen uint64
	if v, isV := parseVault(headBlobGet(base, head)); isV {
		gen = v.ReleaseGen // a legacy head is generation 0
	}
	if distrustBlobCacheIfReleased(blobCachePath(), relGenHeadKey(base, profile, pass), gen) {
		fmt.Printf("restore: profile %s: a snapshot was deleted since this phone's chunk cache was filled -- the cache is dropped before this restore seeds it (release generation %d)\n", logProfile(profile), gen)
	}
}
