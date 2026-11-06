package main

// NWP-20261123-04 (docs/backlog.md, "`#media` walks its whole tree at every seal even when it uploads nothing"):
// a #media push whose walk finds exactly what the last landed #media seal found ends after the walk.
//
// On frankel 0.5.51 five of five #media pushes uploaded 0 KiB and kept the same generation, yet each spent
// 6.1-9.2 s AFTER the walk -- the essential carry over the head's rels, the manifest build and seal, the net-skip
// pass, a putHead of the value already stored, the receipt and the roster -- with the roamd worker held throughout.
//
// THE KEY IS THE ONE THE GROUP CACHE ALREADY TRUSTS. walkChunks folds every entry it handles, in walk order, into
// a SHA-256 over (rel, mode, size for a regular file, mtime ns): the fields groupCacheKey and the scan cache reuse
// a group or a file on. The digest opens with the walk's policy inputs (threshold, on-demand split, budget, pins,
// tiers, the defer and drop lists), because for #media the pin and tier files live outside the walked tree and a
// change there re-tiers a file without touching it.
//
// THE RECORD is one line, `<head> <digest hex>`, in $NOWHERE_BLOBCACHE/mnochange.<content-cache tag> (the state
// tmpfs, beside sealcount.<tag>). It is written only after a #media seal whose head was put and whose post-publish
// materialise left nothing to fetch, and only once that head is committed (after capFlush in cap mode); every
// #media seal that takes the full path removes it first. No profile name and no rel are in the file or in the log.
//
// THE EARLY END needs every condition in mediaNoChange: any doubt is today's full path. It runs no carry, no
// manifest, no lease and no head write, and leaves the receipt, the roster and the record as they are.

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"hash"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// mediaNoChangeLine is the one line a no-change #media push prints: the profile (logProfile), the head it kept
// (short) and the walk's duration.
const mediaNoChangeLine = "push: profile %s (#media) no change since gen %s -- walk %s, nothing built or written (NWP-20261123-04)\n"

// walkDigest is walkChunks' running digest of one walk.
type walkDigest struct {
	h hash.Hash
	b [8]byte
}

func (d *walkDigest) u32(v uint32) { binary.BigEndian.PutUint32(d.b[:4], v); d.h.Write(d.b[:4]) }
func (d *walkDigest) i64(v int64)  { binary.BigEndian.PutUint64(d.b[:], uint64(v)); d.h.Write(d.b[:]) }
func (d *walkDigest) str(s string) { d.u32(uint32(len(s))); d.h.Write([]byte(s)) }

// newWalkDigest starts a digest with the walk's policy inputs, every set in sorted order.
func newWalkDigest(threshold int64, od bool, budget int64, pins map[string]bool, tiers map[string]mediaTier,
	forceDef, dropPkgs map[string]bool) *walkDigest {
	d := &walkDigest{h: sha256.New()}
	d.str("nowhere-media-nochange v1")
	d.i64(threshold)
	if od {
		d.u32(1)
	} else {
		d.u32(0)
	}
	d.i64(budget)
	set := func(m map[string]bool) {
		ks := make([]string, 0, len(m))
		for k, on := range m {
			if on {
				ks = append(ks, k)
			}
		}
		sort.Strings(ks)
		d.u32(uint32(len(ks)))
		for _, k := range ks {
			d.str(k)
		}
	}
	set(pins)
	ts := make([]string, 0, len(tiers))
	for k, v := range tiers {
		ts = append(ts, k+"="+strconv.Itoa(int(v)))
	}
	sort.Strings(ts)
	d.u32(uint32(len(ts)))
	for _, s := range ts {
		d.str(s)
	}
	set(forceDef)
	set(dropPkgs)
	return d
}

// add folds one walk entry: rel, mode, size for a regular file, mtime ns for every entry.
func (d *walkDigest) add(rel string, info os.FileInfo) {
	d.str(filepath.ToSlash(rel))
	d.u32(uint32(info.Mode()))
	if info.Mode().IsRegular() {
		d.i64(info.Size())
	}
	d.i64(info.ModTime().UnixNano())
}

func (d *walkDigest) sum() string { return hex.EncodeToString(d.h.Sum(nil)) }

// mediaNoChangePath is the record's path, "" when there is no state dir or no tag (then nothing is read or written).
func mediaNoChangePath(tag string) string {
	dir := os.Getenv("NOWHERE_BLOBCACHE")
	if dir == "" || tag == "" {
		return ""
	}
	return filepath.Join(dir, "mnochange."+tag)
}

// readMediaNoChange returns the record's head and digest; ok is false for a missing or malformed record.
func readMediaNoChange(tag string) (head, digest string, ok bool) {
	p := mediaNoChangePath(tag)
	if p == "" {
		return "", "", false
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "", "", false
	}
	f := strings.Fields(string(b))
	if len(f) != 2 {
		return "", "", false
	}
	return f[0], f[1], true
}

// writeMediaNoChange records the head a #media seal landed and its walk digest (temp file, then rename).
func writeMediaNoChange(tag, head, digest string) {
	p := mediaNoChangePath(tag)
	if p == "" || head == "" || digest == "" {
		removeMediaNoChange(tag)
		return
	}
	tmp := p + ".tmp"
	if os.WriteFile(tmp, []byte(head+" "+digest+"\n"), 0o600) != nil || os.Rename(tmp, p) != nil {
		os.Remove(tmp)
		removeMediaNoChange(tag)
	}
}

func removeMediaNoChange(tag string) {
	if p := mediaNoChangePath(tag); p != "" {
		os.Remove(p)
	}
}

// capBracketEmpty: in cap mode, the open bracket has buffered no blob and no ref, so the deferred capFlush leases
// nothing. Always true outside cap mode.
func capBracketEmpty() bool {
	if !capMode() {
		return true
	}
	capWriteMu.Lock()
	defer capWriteMu.Unlock()
	return capCur == nil || (len(capCur.blobs) == 0 && len(capCur.refs) == 0)
}

// mediaTombstonesEmpty reports whether every tombstones file mediaTombstones reads is absent or an empty regular
// file. It reads no content: a file that holds only blank lines, a directory, or a path it cannot stat is a doubt,
// and a doubt is the full path (the seal then reads the file as it does today).
func mediaTombstonesEmpty(src string) bool {
	paths := []string{src + "/" + mediaCacheRel + "/.deleted"}
	if p := os.Getenv("NOWHERE_MEDIA_TOMBSTONES"); p != "" {
		paths = append(paths, p)
	}
	for _, p := range paths {
		fi, err := os.Lstat(p)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			continue
		case err != nil, !fi.Mode().IsRegular(), fi.Size() != 0:
			return false
		}
	}
	return true
}

// mediaNoChangeIn is what pushProfile knows right after the walk.
type mediaNoChangeIn struct {
	tag       string // contentCacheTagFor(dk)
	head      string // the head this push read at its start (getRef)
	rcptHead  string // the session receipt's head
	digest    string // this walk's digest
	src       string // the walked tree (for the tombstones)
	forceFull bool   // sealCounterNext chose a full re-hash
	blind     int    // paths the walk could not read
	dropped   int64  // bytes the walk dropped
	discard   int    // torn deferred reads
	deferred  int    // deferred files freshly chunked
	perr      error  // the chunk pool's error, read after pwg.Wait
}

// mediaNoChange reports whether this #media push may end after its walk. Every false removes the record, so a
// full-path seal that then fails or is refused leaves none behind.
func mediaNoChange(in mediaNoChangeIn) bool {
	ok := func() bool {
		rh, rd, found := readMediaNoChange(in.tag)
		switch {
		case !found:
			return false
		case in.head == "" || rh != in.head: // another writer moved the stored head
			return false
		case rh != in.rcptHead: // the session does not hold that head
			return false
		case in.digest == "" || rd != in.digest: // the walk found something else
			return false
		case in.forceFull:
			return false
		case in.blind != 0 || in.dropped != 0 || in.discard != 0 || in.deferred != 0 || in.perr != nil:
			return false
		case !mediaTombstonesEmpty(in.src): // a delete through mediad is not a walked change
			return false
		case os.Getenv("NOWHERE_SEAL_FORCE") != "":
			return false
		case !capBracketEmpty():
			return false
		}
		return true
	}()
	if !ok {
		removeMediaNoChange(in.tag)
	}
	return ok
}

// mediaNoChangePending is a record a #media seal staged at its end. mediaNoChangeCommit publishes it once the head
// is committed: in cap mode that is the deferred capFlush, after the seal's last line.
type mediaNoChangePending struct{ tag, head, digest string }

// mediaNoChangeAfterSeal runs once a #media seal has put its head and run the post-publish materialise. It stages
// (head, digest) only when no guard refused the head pointer (refusedPtr: pushProfile reads sealStaleHit and
// sealFenceHit, which only a bracket's owner may name, NWP-20261009-07) and that materialise left nothing to fetch: every
// carried rel to land is on disk, and no deferred arrival is still absent. Otherwise it removes the record and
// stages nothing, so the next push takes the full path and the materialise retries. It never writes the record:
// mediaNoChangeCommit does, after the head commit.
func mediaNoChangeAfterSeal(tag, head, digest, src string, toLand []string, carryRan bool,
	oldDef, restoredDef map[string]deferredFile, walkedHere func(string) bool, refusedPtr bool) *mediaNoChangePending {
	if sealRefused || refusedPtr {
		removeMediaNoChange(tag)
		return nil
	}
	for _, rel := range toLand {
		if _, err := os.Lstat(filepath.Join(src, filepath.FromSlash(rel))); err != nil {
			removeMediaNoChange(tag)
			return nil
		}
	}
	if carryRan && deferredSyncBudget() > 0 && len(oldDef) > 0 && len(newlyArrivedDeferred(oldDef, restoredDef, src, walkedHere)) > 0 {
		removeMediaNoChange(tag)
		return nil
	}
	return &mediaNoChangePending{tag: tag, head: head, digest: digest}
}

// mediaNoChangeCommit runs in pushProfile's defers, after capFlush. flushed is true when the head commit returned
// normally: always in direct mode (putHead wrote the head inline), and in cap mode only when capFlush returned
// without a panic. It writes a staged record only when that commit also refused no pointer (refusedPtr: the fence or
// the stale check, which capFlush reports through sealFenceHit and sealStaleHit and pushProfile reads after it) and
// no stop or refusal ended the seal; on any other outcome it removes the record.
func mediaNoChangeCommit(p *mediaNoChangePending, flushed, refusedPtr bool) {
	if p == nil {
		return
	}
	if !flushed || refusedPtr || sealRefused || sealStopped.Load() {
		removeMediaNoChange(p.tag)
		return
	}
	writeMediaNoChange(p.tag, p.head, p.digest)
}
