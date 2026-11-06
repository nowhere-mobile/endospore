package main

// The blobs a deleted snapshot frees, computed strictly, and the two ends of letting them go: the seal workers'
// blob cache and the gateway's POST /release (docs/product-decisions.md 2026-10-19 and 2026-10-20, NWP-20261029-09).
//
// DELETE-SNAPSHOT calls all of it from releaseDeletedSnapshot (snapshot_delete.go, NWP-20261029-10).

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// releaseBatchMax is the gateway's cap on entries in one POST /release.
const releaseBatchMax = 4096

var errManifestUnreadable = errors.New("manifest unreadable")

// manifestBlobsStrict adds blob/<manifest> and every essential and Deferred chunk of the sealed CDC manifest to
// into. A manifest that decrypts under dk and is not a CDC manifest (the creation state createVault seals as an
// empty tar, which the first seal pushes into History; a pre-CDC head) is a whole-tar blob that names only itself,
// so only blob/<manifest> is added (NWP-20261113-14): billing.go's addCDCChunks leases it the same way and
// classifyManifestLoad reads it as mlNotCDC, real and readable. That is correct for both callers. For a profile
// delete it releases the creation-state blob with the rest: the profile's own, sealed under its DK, named by
// nothing else. For a snapshot delete a kept non-CDC entry protects exactly its own blob, which is all it names,
// and a removed one frees exactly its blob. Before NWP-20261113-14 it was an error, so every profile delete
// released nothing early.
//
// Unlike addManifestChunks (billing.go), which is best-effort on purpose -- skipping a manifest only under-leases
// -- every other failure here is an error and into is left untouched: a skipped KEPT manifest would put its chunks
// in the release set. That is a fetch that panics (getBlob reports a missing blob that way), a decrypt that panics
// (a wrong key included), CDC magic followed by JSON that does not parse (corrupt, not legacy) and an empty hash.
// A panic is recovered into the error. The panic value is dropped: it names a blob.
func manifestBlobsStrict(base string, dk []byte, manifestHash string, into map[string]bool) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = errManifestUnreadable
		}
	}()
	if manifestHash == "" {
		return errors.New("empty manifest hash")
	}
	pt := unseal(dk, getBlob(base, manifestHash))
	if !bytes.HasPrefix(pt, cdcMagic) {
		into["blob/"+manifestHash] = true
		return nil
	}
	var m chunkManifest
	if json.Unmarshal(pt[len(cdcMagic):], &m) != nil {
		return errors.New("manifest does not parse")
	}
	found := map[string]bool{"blob/" + manifestHash: true}
	for _, ch := range m.Chunks {
		if ch != "" {
			found["blob/"+ch] = true
		}
	}
	for _, d := range m.Deferred {
		for _, ch := range d.Chunks {
			if ch != "" {
				found["blob/"+ch] = true
			}
		}
	}
	for k := range found {
		into[k] = true
	}
	return nil
}

// snapshotReleaseSet is the store keys only removed references: every blob of removed's manifest that neither the
// live head nor any kept History entry names. Any manifest that cannot be read returns (nil, err) -- nothing is
// released when anything is unknown. A removed manifest equal to the live one or to a kept entry's (a rollback
// leaves one; snapshot_delete.go says so) frees nothing, with no error.
//
// Only the bare vault has snapshots: scope heads (#media, #apps, ...) and re-key progress are sealed under other
// keys and cannot name a bare chunk. The gateway re-leases (and so un-marks) any blob a later seal of any handset
// names; a blob a handset's cache believes present is NOWHERE-730's.
func snapshotReleaseSet(base string, dk []byte, removed headSnap, kept *vault) (map[string]bool, error) {
	// A manifest the live head or a kept entry also names frees nothing: say so before reading any blob, so a store
	// that cannot be reached cannot turn this no-op into an error.
	if removed.Manifest != "" && kept != nil {
		if removed.Manifest == kept.Manifest {
			return map[string]bool{}, nil
		}
		for _, h := range kept.History {
			if removed.Manifest == h.Manifest {
				return map[string]bool{}, nil
			}
		}
	}
	keep := map[string]bool{}
	if kept != nil {
		if kept.Manifest != "" {
			if err := manifestBlobsStrict(base, dk, kept.Manifest, keep); err != nil {
				return nil, err
			}
		}
		for _, h := range kept.History {
			if err := manifestBlobsStrict(base, dk, h.Manifest, keep); err != nil {
				return nil, err
			}
		}
	}
	free := map[string]bool{}
	if err := manifestBlobsStrict(base, dk, removed.Manifest, free); err != nil {
		return nil, err
	}
	for k := range keep {
		delete(free, k)
	}
	return free, nil
}

// workerBlobCachePath is the file the seal WORKERS use: blobCachePath() when NOWHERE_BLOBCACHE is set, else the
// same file under NOWHERE_STATE (roamd exports NOWHERE_STATE as NOWHERE_BLOBCACHE for its workers; the login daemon
// has only NOWHERE_STATE), else "". Both go through blobCachePathIn so the tag cannot diverge. If the daemon's
// GATEWAY_URL ever differed from roamd's this names a file no worker reads: the eviction removes nothing, and
// NOWHERE-736 records the generation beside the wrong file -- the worker's own record then mismatches, so
// NOWHERE-730's guard drops its whole cache, the safe direction.
func workerBlobCachePath() string {
	if os.Getenv("NOWHERE_BLOBCACHE") != "" {
		return blobCachePath()
	}
	return blobCachePathIn(os.Getenv("NOWHERE_STATE"))
}

// blobCacheEvict removes keys (blob/<hex>) from the blob cache file at path and from the in-memory set when it is
// loaded, returning how many lines it removed from the file. The file is rewritten through a temp file in the same
// directory and renamed over it, 0600. A missing file or an empty path removes nothing.
func blobCacheEvict(path string, keys map[string]bool) (int, error) {
	if path == "" {
		return 0, nil
	}
	drop := map[string]bool{}
	for k := range keys {
		if h := strings.TrimPrefix(k, "blob/"); h != k && h != "" {
			drop[h] = true
		}
	}
	blobCacheMu.Lock()
	defer blobCacheMu.Unlock()
	if blobCache != nil {
		for h := range drop {
			delete(blobCache, h)
		}
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	var keep []string
	n := 0
	for _, line := range strings.Split(string(b), "\n") {
		t := strings.TrimSpace(line)
		if t == "" {
			continue
		}
		if drop[t] {
			n++
			continue
		}
		keep = append(keep, t)
	}
	if n == 0 {
		return 0, nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".blobcache-evict-*")
	if err != nil {
		return 0, err
	}
	abort := func(err error) (int, error) {
		tmp.Close()
		os.Remove(tmp.Name())
		return 0, err
	}
	if err := tmp.Chmod(0o600); err != nil {
		return abort(err)
	}
	if len(keep) > 0 {
		if _, err := tmp.WriteString(strings.Join(keep, "\n") + "\n"); err != nil {
			return abort(err)
		}
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return 0, err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return 0, err
	}
	return n, nil
}

// releaseBlobs presents the release proofs (store key -> preimage hex) to the gateway's POST /release in batches
// of at most releaseBatchMax, in key order, and returns the keys the gateway released across every batch. A 404 or
// 405 (a gateway that predates the endpoint) stops and returns what it has with that status and no error, so the
// caller can say the gateway does not release early; any other non-200 or a transport error stops and returns
// what it has with the error. A key, a preimage or a commitment is never logged or put in an error.
func (g *gatewayClient) releaseBlobs(proofs map[string]string) (released []string, status int, err error) {
	keys := make([]string, 0, len(proofs))
	for k := range proofs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for start := 0; start < len(keys); start += releaseBatchMax {
		end := start + releaseBatchMax
		if end > len(keys) {
			end = len(keys)
		}
		batch := make(map[string]string, end-start)
		for _, k := range keys[start:end] {
			batch[k] = proofs[k]
		}
		var out struct {
			Released []string `json:"released"`
		}
		code, reason, perr := g.postJSONReasonOn(g.leaseClient(len(batch)), "/release",
			map[string]any{"release": batch}, &out)
		if perr != nil {
			return released, code, perr
		}
		if code == http.StatusNotFound || code == http.StatusMethodNotAllowed {
			return released, code, nil
		}
		if code != http.StatusOK {
			return released, code, fmt.Errorf("gateway /release: status %d: %s", code, reason)
		}
		released = append(released, out.Released...)
	}
	return released, http.StatusOK, nil
}
