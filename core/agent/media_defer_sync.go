package main

// NWP-20260908-22: mid-session sync, slice 2 -- the DEFERRED tier.
//
// Slice 1 (NWP-20260908-21) lands another handset's ESSENTIAL media mid-session: files under the deferral
// floor, which for user media is 1 MiB. That covers a screenshot (~150 KB) and misses a camera photo
// (~1.6-3 MB), which is the half Chester actually asked about.
//
// ⚠ WHY THIS FETCHES BYTES INSTEAD OF TEACHING mediad TO SERVE A NEW STUB, which is where the design started.
// mediad reads its manifest ONCE at startup (media_server.go) and its mount set is computed then. Two things
// killed the reload:
//
//   - its deferSet/byDir are read on the FUSE hot path with no lock, so injecting entries means adding
//     locking to that path -- a change to the serving code to fix a sync problem; and
//   - a rel landing in a directory that has no overlay needs a NEW mount, and nesting there is the
//     NWP-20260829-04 wedge that cost three consecutive logoff refusals on lynx.
//
// Fetching the bytes needs neither. It trades the on-demand property for visibility, which is why the trade
// is BOUNDED by a per-cycle budget rather than left open.

import (
	"archive/tar"
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// deferredSyncBudget bounds how many bytes ONE cycle may fetch for the deferred tier
// (NOWHERE_MEDIA_SYNC_BUDGET, default 64 MiB). 0 disables the deferred half entirely.
//
// The essential tier needs no budget -- those files are under the deferral floor by definition. The deferred
// tier is the opposite: a 4K video is exactly the thing the on-demand tier exists NOT to fetch. The bound is
// per CYCLE, not per session, and the selection is sorted, so what does not fit what is LEFT of a cycle's
// budget is picked up by a later cycle in the same order: progress is monotonic for every file that fits the
// budget. A file larger than the whole budget can never fit any cycle; it is skipped (not allowed to end the
// cycle) and left to the next login, where it restores as an on-demand stub.
func deferredSyncBudget() int64 {
	if v := strings.TrimSpace(os.Getenv("NOWHERE_MEDIA_SYNC_BUDGET")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n >= 0 {
			return n
		}
	}
	return 64 << 20
}

// fetchDeferredBytes reassembles one deferred file from its own chunk list.
//
// Simpler than the essential path, deliberately: a deferred file is chunked from RAW bytes with no tar
// framing, so there is no header to parse and no neighbour to spill in from. fetchEssSpan only needs its tar
// handling because essential files share one stream.
func fetchDeferredBytes(base string, key []byte, version int, d deferredFile) (b []byte, err error) {
	defer func() {
		if p := recover(); p != nil {
			b, err = nil, fmt.Errorf("fetch deferred: %v", p)
		}
	}()
	var buf bytes.Buffer
	buf.Grow(int(d.Size))
	for i, h := range d.Chunks {
		raw, ue := unpackChunk(unseal(key, getChunk(base, h)), version)
		if ue != nil {
			return nil, fmt.Errorf("unpack chunk %d/%d: %w", i+1, len(d.Chunks), ue)
		}
		buf.Write(raw)
	}
	if int64(buf.Len()) != d.Size {
		// A short reassembly written to disk is a CORRUPT photo that the next walk then seals OVER the good
		// copy in the head -- turning a fetch glitch into account-wide data loss. Refuse: the head still
		// holds the real bytes, and the next cycle tries again.
		return nil, fmt.Errorf("reassembled %d bytes, manifest says %d", buf.Len(), d.Size)
	}
	return buf.Bytes(), nil
}

// newlyArrivedDeferred picks the deferred rels another lineage published that this session has never held.
//
// Exactly the essential tier's discriminator, one index over: in the stored head, NOT in the head this
// session restored, absent locally. The roster is what separates that from "I had it and the user deleted
// it" -- without it every deleted photo would be fetched straight back, every cycle, forever.
//
// "Absent locally" reads correctly through a live overlay: a rel this handset holds is served by mediad as a
// STUB, which stats like a real file, so Lstat finds it. A rel it has never held has no stub to find.
//
// walkedHere names the rels an earlier seal of THIS session walked as real files (restore_receipt.go): a
// photo taken here and sealed by a periodic seal is in the stored head and not in the login roster, so
// without it deleting that photo reads as another handset's arrival and the next seal writes it back. A
// rel it names is skipped on the login roster's meaning: ours, so its absence is a deletion. nil = no
// walked roster, only the login roster decides.
func newlyArrivedDeferred(stored, restored map[string]deferredFile, dest string, walkedHere func(rel string) bool) []string {
	var out []string
	for rel, d := range stored {
		if d.Size <= 0 || len(d.Chunks) == 0 {
			continue
		}
		if _, held := restored[rel]; held {
			continue // in this session's roster: ours, so its absence is a deletion, not an arrival
		}
		if walkedHere != nil && walkedHere(rel) {
			continue // walked by an earlier seal of this session: ours, for the same reason
		}
		if isMediaCachePath(rel) || isAppCodeStagePath(rel) || strings.Contains(rel, "/.nowhere-odhold/") {
			continue // derived caches, install staging and the on-demand hold are never user media
		}
		if rel == "" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "..") {
			continue
		}
		if _, err := os.Lstat(filepath.Join(dest, filepath.FromSlash(rel))); err == nil {
			continue // already here, as a real file or as a mediad stub
		}
		out = append(out, rel)
	}
	sort.Strings(out) // deterministic, so a truncating budget makes the SAME progress every cycle
	return out
}

// materializeDeferredArrivals fetches another handset's new large media, up to a byte budget.
func materializeDeferredArrivals(base string, key []byte, m chunkManifest, rels []string, dest string,
	budget int64) ([]string, int64) {
	var wrote []string
	var total int64
	waiting := 0
	oversize := 0
	defer func() { reportAppExtWaiting(waiting) }()
	defer func() {
		if oversize > 0 {
			fmt.Printf("  media-sync: %d deferred file(s) larger than the per-cycle budget (%d B) wait for the next login\n",
				oversize, budget)
		}
	}()
	for _, rel := range rels {
		d, ok := m.Deferred[rel]
		if !ok {
			continue
		}
		target := filepath.Join(dest, filepath.FromSlash(rel))
		// NWP-20261011-47: an app's own Android/{data,obb}/<pkg> file whose app is not installed here has no
		// owner to take (writeMaterialized) -- checked before the budget so it neither costs a download every
		// cycle nor ends the cycle's budget early; it lands at the next login restore.
		if _, _, _, _, err := appExtOwner(dest, target); errors.Is(err, errAppExtNotHere) {
			waiting++
			continue
		}
		// A file bigger than the WHOLE budget can never fit a cycle: breaking on it would end every cycle at
		// 0 B and starve every arrival sorted after it. Skip it, fetch nothing, and say how many.
		if d.Size > budget {
			oversize++
			continue
		}
		if total+d.Size > budget {
			// Name what was left. A budget that truncates silently reads as "there was nothing more", which
			// is the same shape as a carry that selects nothing and says so in no log line.
			fmt.Printf("  media-sync: deferred budget spent at %d B -- %q and any after it wait for the next cycle\n",
				total, rel)
			break
		}
		if _, err := os.Lstat(target); err == nil {
			continue // re-checked here as well: selection and write are not one atomic step
		}
		b, err := fetchDeferredBytes(base, key, m.Version, d)
		if err != nil {
			fmt.Printf("  media-sync: %q SKIPPED (%v)\n", rel, errCode(err))
			continue
		}
		// A deferred entry records mode and an mtime in UnixNano; there is no tar header to take them from,
		// so synthesise the one writeMaterialized needs and keep a single write path for both tiers.
		hdr := &tar.Header{Mode: int64(d.Mode), ModTime: time.Unix(0, d.MTime)}
		if err := writeMaterialized(target, dest, hdr, b); err != nil {
			if errors.Is(err, errAppExtNotHere) {
				waiting++ // the package dir went away between the check above and the write
				continue
			}
			fmt.Printf("  media-sync: %q SKIPPED (%v)\n", rel, errCode(err))
			continue
		}
		wrote = append(wrote, target)
		total += int64(len(b))
	}
	return wrote, total
}
