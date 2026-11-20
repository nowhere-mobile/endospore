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
//
// NWP-20261204-22 (docs/backlog.md, "0.5.52's `#media` no-change exit does not fire on frankel"): THE TOMBSTONES ARE
// IN THE DIGEST. The record's digest is mediaNoChangeDigest: the walk digest folded with mediaTombstonesKey, a hash
// of both tombstones files mediaTombstones reads. mediad only appends to them, so a guard that refused any
// non-empty file kept a session from the exit for good after its first deletion, although the seal had already
// read it. Now the exit needs the tombstones byte for byte as the record's seal read them: a line appended since,
// or a path the key cannot read, is the full path. Each push that takes the full path prints one line naming the
// guard (mediaNoChangeWhy, a closed set), and so does each seal that keeps no record. No head, digest or rel.

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

// mediaNoChangeFullLine is the one line a #media push prints when it takes the full path: the profile (logProfile),
// the guard that refused the exit (a mediaNoChangeWhy token) and how many of the two tombstones files hold a
// non-empty file (mediaTombstonesCount), so a report tells a tombstone change from a walk change.
const mediaNoChangeFullLine = "push: profile %s (#media) full path: %s tombs=%d (NWP-20261204-22)\n"

// mediaNoChangeNotKeptLine is the line a #media seal prints when it keeps no record: the profile and the reason
// (a mediaNoChangeWhy token).
const mediaNoChangeNotKeptLine = "push: profile %s (#media) no-change record not kept: %s (NWP-20261204-22)\n"

// mediaNoChangeWhy is the closed set of reasons, in arm order: the nine that refuse the exit (mediaNoChangeReason),
// then the five that keep no record (mediaNoChangeAfterSeal, mediaNoChangeCommit). Every printed reason is one of
// these literals, never text built from data.
var mediaNoChangeWhy = [...]string{
	"no-record", "head-moved", "receipt-head", "digest-doubt", "digest-changed", "forced-full", "walk-doubt",
	"seal-force", "cap-bracket",
	"refused", "not-landed", "arrivals-waiting", "not-flushed", "stopped",
}

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

// mediaTombstonePaths are the two tombstones files mediaTombstones (media_seal.go) reads, in its order: the CE one
// under the tree, then $NOWHERE_MEDIA_TOMBSTONES when set. An unset variable keeps its slot empty.
func mediaTombstonePaths(src string) [2]string {
	return [2]string{src + "/" + mediaCacheRel + "/.deleted", os.Getenv("NOWHERE_MEDIA_TOMBSTONES")}
}

// mediaTombstonesKey is a hex SHA-256 over (slot index, length, bytes) of each tombstones path that holds a
// non-empty regular file. An absent, empty or unset path adds nothing, so those are one state, and the key of
// nothing is still a key. A path it cannot stat, one that is not a regular file, or a read error is a doubt:
// ("", false), and a doubt is the full path.
func mediaTombstonesKey(src string) (string, bool) {
	d := &walkDigest{h: sha256.New()}
	d.str("nowhere-media-tombstones v1")
	for i, p := range mediaTombstonePaths(src) {
		if p == "" {
			continue
		}
		fi, err := os.Lstat(p)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			continue
		case err != nil, !fi.Mode().IsRegular():
			return "", false
		case fi.Size() == 0:
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return "", false
		}
		if len(b) == 0 {
			continue
		}
		d.u32(uint32(i))
		d.i64(int64(len(b)))
		d.h.Write(b)
	}
	return d.sum(), true
}

// mediaTombstonesCount is how many of the two tombstones paths hold a non-empty regular file (0-2). It reads no
// content; it only feeds the tombs= field of mediaNoChangeFullLine.
func mediaTombstonesCount(src string) int {
	n := 0
	for _, p := range mediaTombstonePaths(src) {
		if p == "" {
			continue
		}
		if fi, err := os.Lstat(p); err == nil && fi.Mode().IsRegular() && fi.Size() != 0 {
			n++
		}
	}
	return n
}

// mediaNoChangeDigest folds the walk digest and the tombstones key into the record's digest. "" (a doubt) when the
// walk gave none or the key is a doubt.
func mediaNoChangeDigest(walk, key string, ok bool) string {
	if walk == "" || !ok {
		return ""
	}
	d := &walkDigest{h: sha256.New()}
	d.str("nowhere-media-nochange-digest v1")
	d.str(walk)
	d.str(key)
	return d.sum()
}

// mediaNoChangeIn is what pushProfile knows right after the walk.
type mediaNoChangeIn struct {
	tag       string // contentCacheTagFor(dk)
	head      string // the head this push read at its start (getRef)
	rcptHead  string // the session receipt's head
	digest    string // mediaNoChangeDigest of this walk and the tombstones ("" = a doubt)
	forceFull bool   // sealCounterNext chose a full re-hash
	blind     int    // paths the walk could not read
	dropped   int64  // bytes the walk dropped
	discard   int    // torn deferred reads
	deferred  int    // deferred files freshly chunked
	perr      error  // the chunk pool's error, read after pwg.Wait
}

// mediaNoChange reports whether this #media push may end after its walk. Every false removes the record, so a
// full-path seal that then fails or is refused leaves none behind.
func mediaNoChange(in mediaNoChangeIn) bool { return mediaNoChangeReason(in) == "" }

// mediaNoChangeReason is mediaNoChange with the guard that refused: "" when the push may end after its walk, else
// that guard's mediaNoChangeWhy token. Every token removes the record.
func mediaNoChangeReason(in mediaNoChangeIn) string {
	why := func() string {
		rh, rd, found := readMediaNoChange(in.tag)
		switch {
		case !found:
			return "no-record"
		case in.head == "" || rh != in.head: // another writer moved the stored head
			return "head-moved"
		case rh != in.rcptHead: // the session does not hold that head
			return "receipt-head"
		case in.digest == "": // the walk or the tombstones key is a doubt
			return "digest-doubt"
		case rd != in.digest: // the walk or the tombstones found something else
			return "digest-changed"
		case in.forceFull:
			return "forced-full"
		case in.blind != 0 || in.dropped != 0 || in.discard != 0 || in.deferred != 0 || in.perr != nil:
			return "walk-doubt"
		case os.Getenv("NOWHERE_SEAL_FORCE") != "":
			return "seal-force"
		case !capBracketEmpty():
			return "cap-bracket"
		}
		return ""
	}()
	if why != "" {
		removeMediaNoChange(in.tag)
	}
	return why
}

// mediaNoChangePending is a record a #media seal staged at its end. mediaNoChangeCommit publishes it once the head
// is committed: in cap mode that is the deferred capFlush, after the seal's last line.
type mediaNoChangePending struct{ tag, head, digest string }

// mediaNoChangeAfterSeal runs once a #media seal has put its head and run the post-publish materialise. It stages
// (head, digest) only when no guard refused the head pointer (refusedPtr: pushProfile reads sealStaleHit and
// sealFenceHit, which only a bracket's owner may name, NWP-20261009-07) and that materialise left nothing to fetch: every
// carried rel to land is on disk, and no deferred arrival is still absent. Otherwise it removes the record and
// stages nothing, so the next push takes the full path and the materialise retries. It never writes the record:
// mediaNoChangeCommit does, after the head commit. The string is the mediaNoChangeWhy token when it staged nothing
// ("refused", "not-landed", "arrivals-waiting"), "" with a staged record.
func mediaNoChangeAfterSeal(tag, head, digest, src string, toLand []string, carryRan bool,
	oldDef, restoredDef map[string]deferredFile, walkedHere func(string) bool, refusedPtr bool) (*mediaNoChangePending, string) {
	if sealRefused || refusedPtr {
		removeMediaNoChange(tag)
		return nil, "refused"
	}
	for _, rel := range toLand {
		if _, err := os.Lstat(filepath.Join(src, filepath.FromSlash(rel))); err != nil {
			removeMediaNoChange(tag)
			return nil, "not-landed"
		}
	}
	if carryRan && deferredSyncBudget() > 0 && len(oldDef) > 0 && len(newlyArrivedDeferred(oldDef, restoredDef, src, walkedHere)) > 0 {
		removeMediaNoChange(tag)
		return nil, "arrivals-waiting"
	}
	return &mediaNoChangePending{tag: tag, head: head, digest: digest}, ""
}

// mediaNoChangeCommit runs in pushProfile's defers, after capFlush. flushed is true when the head commit returned
// normally: always in direct mode (putHead wrote the head inline), and in cap mode only when capFlush returned
// without a panic. It writes a staged record only when that commit also refused no pointer (refusedPtr: the fence or
// the stale check, which capFlush reports through sealFenceHit and sealStaleHit and pushProfile reads after it) and
// no stop or refusal ended the seal; on any other outcome it removes the record and returns the mediaNoChangeWhy
// token ("not-flushed", "refused", "stopped"). "" when there was nothing staged or the record was written.
func mediaNoChangeCommit(p *mediaNoChangePending, flushed, refusedPtr bool) string {
	if p == nil {
		return ""
	}
	why := ""
	switch {
	case !flushed:
		why = "not-flushed"
	case refusedPtr || sealRefused:
		why = "refused"
	case sealStopped.Load():
		why = "stopped"
	}
	if why != "" {
		removeMediaNoChange(p.tag)
		return why
	}
	writeMediaNoChange(p.tag, p.head, p.digest)
	return ""
}
