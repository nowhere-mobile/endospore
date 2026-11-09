package main

// NWP-20261129-08: THE LANDER (Q106, slice S4a): the background restore that places a #media head's user files after
// the gate, one file at a time from its span.
//
// It builds docs/media-after-gate.md §3 (one file at a time from its region), §4 (a file the app created wins), §5
// items 2 and its fail-direction table (the landed roster), §6's retry rule and §10 O4's order. The split it works
// from is bgSplit (S1); the seal reads what it records through loadLandedRoster (S3).
//
// ⚠ NOTHING CALLS landBackground YET. S4b starts it in mediad, and it stays behind NOWHERE_MEDIA_AFTER_GATE.
//
// ⚠ NEVER THROUGH AN OVERLAY. A folder mediad overlays lands in that overlay's hidden real directory. That directory
// sits under mediad's cache dir (`<cacheDir>/.under/<leaf>`, mediafs.go), outside the media root, so its write is
// guarded FROM THE HIDDEN DIRECTORY DOWN: root = dest would be refused by noLinkBelow as outside the root, and
// root = "" would skip the link guard.
//
// Its temps are `.nwsync-*` (writeMaterializedVia), which S3's walks skip (isMediaTempName).

import (
	"archive/tar"
	"bytes"
	"cmp"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const (
	landerBatch   = 32               // landed-roster digests held back before a write
	landerWaitMin = 30 * time.Second // §6: the first wait, and the wait after a pass that landed anything
	landerWaitMax = 10 * time.Minute // §6: the cap
)

// renameat2 is a seam: a test returns EINVAL through it to force renameNoReplace's fallback.
var renameat2 = unix.Renameat2

// renameNoReplace moves tmp to target and never replaces what is there: an existing target returns an error matching
// os.ErrExist. A kernel or filesystem without the flag takes the link fallback, whose EEXIST is the same refusal.
func renameNoReplace(tmp, target string) error {
	err := renameat2(unix.AT_FDCWD, tmp, unix.AT_FDCWD, target, unix.RENAME_NOREPLACE)
	if !errors.Is(err, unix.EINVAL) && !errors.Is(err, unix.ENOSYS) {
		return err
	}
	if err := os.Link(tmp, target); err != nil {
		return err
	}
	_ = os.Remove(tmp) // writeMaterializedVia's deferred Remove tries once more
	return nil
}

// landerOrder is §10 O4's order: rels whose first component is DCIM or Pictures first, then the rest; inside each group
// newest first by essRegion.MT, ties by rel ascending. Pure: it never aliases rels.
func landerOrder(m chunkManifest, rels []string) []string {
	group := func(rel string) int {
		first, _, _ := strings.Cut(rel, "/")
		if first == "DCIM" || first == "Pictures" {
			return 0
		}
		return 1
	}
	out := slices.Clone(rels)
	slices.SortFunc(out, func(a, b string) int {
		return cmp.Or(cmp.Compare(group(a), group(b)),
			cmp.Compare(m.Ess[b].MT, m.Ess[a].MT),
			cmp.Compare(a, b))
	})
	return out
}

// landerTarget resolves where rel lands and the root its link guard starts from. An unders mountpoint covers rel when
// it equals or contains rel's directory, and the longest one wins: the target is that mapping's hidden directory plus
// the remainder, with the hidden directory as root. With none, the target is dest/rel with dest as root. The root is
// never "".
func landerTarget(dest, rel string, unders map[string]string) (target, root string) {
	target = filepath.Join(dest, filepath.FromSlash(rel))
	dir := filepath.Dir(target)
	best := ""
	for mp := range unders {
		covers := dir == mp || strings.HasPrefix(dir, mp+string(filepath.Separator))
		if covers && len(mp) > len(best) {
			best = mp
		}
	}
	if best == "" {
		return target, dest
	}
	hidden := unders[best]
	rest := strings.TrimPrefix(target, best+string(filepath.Separator))
	return filepath.Join(hidden, rest), hidden
}

// landerRelOK refuses a rel that could leave dest. It tests components: a file named IMG..1.jpg is real.
func landerRelOK(rel string) bool {
	return rel != "" && !strings.HasPrefix(rel, "/") && !slices.Contains(strings.Split(rel, "/"), "..")
}

// spanIsOneEntry is true when a span holds its first tar entry and then only zero bytes: that entry's padding and the
// end-of-archive blocks. oneTarEntry reads only the first entry, and a span that is not one entry counts as damaged.
// ⚠ IT TESTS THE BYTES, NOT A SECOND tar Next: Next's io.EOF also covers a meta header with nothing after it and
// anything after the end-of-archive blocks, and its error covers only some of the rest.
func spanIsOneEntry(frag []byte) bool {
	rd := bytes.NewReader(frag)
	tr := tar.NewReader(rd)
	if _, err := tr.Next(); err != nil {
		return false
	}
	if _, err := io.Copy(io.Discard, tr); err != nil {
		return false
	}
	return len(bytes.Trim(frag[len(frag)-rd.Len():], "\x00")) == 0
}

// landerInput is what one landBackground run works on. A nil seam takes its production behaviour.
type landerInput struct {
	base      string
	key       []byte                                                                      // the scope key fetchEssSpan unseals with
	dk        []byte                                                                      // keys the landed roster's digests
	ref       string                                                                      // names the landed roster
	dest      string                                                                      // the media root
	unders    map[string]string                                                           // absolute mountpoint -> hidden real directory
	stop      func() bool                                                                 // asked between files only
	sleep     func(time.Duration) bool                                                    // false: stop
	fetch     func(base string, key []byte, m chunkManifest, r essRegion) ([]byte, error) // default fetchEssSpan
	onDamaged func(rel string)                                                            // once per corrupt rel
}

// landerCounts is one run's result. skipped holds both a rel found present and a copy dropped because a file appeared
// in the fetch window. pending is what is still unresolved at return.
type landerCounts struct {
	landed, skipped, damaged, pending int
	bytes                             int64
}

// landBackground lands bgSplit(m)'s rels minus those the landed roster holds, in landerOrder, and returns when none
// are pending or on a stop.
//
//   - A rel the roster holds is never fetched or written: a landed file the user deleted stays deleted (§5).
//   - A link on the path leaves the rel pending, with no fetch and no digest. It is checked BEFORE the present test,
//     because Lstat follows an intermediate link: a file behind a planted link would record the digest of a file the
//     lander never placed, and the next seal would read the rel as landed and deleted, and drop it.
//   - A present target is skipped with no fetch and its digest recorded: an app's file wins (§4), and this is also the
//     kill between a rename and its roster write (§5).
//   - renameNoReplace closes the fetch window: a file that appeared meanwhile keeps its bytes, the copy is dropped, and
//     the digest is recorded.
//   - A corrupt span leaves the set for this run: onDamaged once, never retried this session. The rel stays in the head
//     and is carried. Any other error leaves the rel pending (§6).
//   - Passes repeat over the pending rels. After a pass that landed anything the wait is 30 s; otherwise it doubles, to
//     a 10 min cap. A skip is not a landing.
//
// Digests are recorded after each rename, in batches: every landerBatch rels, at each pass's end and before a stop is
// honoured. A kill inside a batch is the present-skip above. It logs one line of counts only: a rel names a user's file,
// and a fetch or write error can name a path, so no error is logged here.
func landBackground(in landerInput, m chunkManifest) landerCounts {
	if in.fetch == nil {
		in.fetch = fetchEssSpan
	}
	if in.stop == nil {
		in.stop = func() bool { return false }
	}
	if in.sleep == nil {
		in.sleep = func(d time.Duration) bool { time.Sleep(d); return true }
	}
	if in.onDamaged == nil {
		in.onDamaged = func(string) {}
	}
	held := loadLandedRoster(in.ref, in.dk)
	bg, _ := bgSplit(m)
	var pending []string
	for _, rel := range landerOrder(m, bg) {
		if !held(rel) {
			pending = append(pending, rel)
		}
	}

	var c landerCounts
	var batch []string
	record := func(rel string) {
		batch = append(batch, rel)
		if len(batch) >= landerBatch {
			recordLandedRoster(in.ref, in.dk, batch)
			batch = nil
		}
	}
	damaged := func(rel string) {
		c.damaged++
		in.onDamaged(rel)
	}
	wait := landerWaitMin
	for len(pending) > 0 {
		before := c.landed
		stopped := false
		var next []string
		for i, rel := range pending {
			if in.stop() {
				next = append(next, pending[i:]...)
				stopped = true
				break
			}
			if !landerRelOK(rel) {
				damaged(rel)
				continue
			}
			target, root := landerTarget(in.dest, rel, in.unders)
			if err := noLinkBelow(root, filepath.Dir(target)); err != nil {
				next = append(next, rel)
				continue
			}
			if _, err := os.Lstat(target); err == nil {
				c.skipped++
				record(rel)
				continue
			}
			frag, err := in.fetch(in.base, in.key, m, m.Ess[rel])
			if err != nil {
				if isCorruptErr(err) {
					damaged(rel)
				} else {
					next = append(next, rel)
				}
				continue
			}
			hdr, data, err := oneTarEntry(frag)
			if err != nil || filepath.ToSlash(hdr.Name) != rel || !spanIsOneEntry(frag) {
				damaged(rel)
				continue
			}
			err = writeMaterializedVia(target, root, hdr, data, renameNoReplace)
			if errors.Is(err, os.ErrExist) {
				c.skipped++
				record(rel)
				continue
			}
			if err != nil {
				next = append(next, rel)
				continue
			}
			c.landed++
			c.bytes += int64(len(data))
			record(rel)
		}
		recordLandedRoster(in.ref, in.dk, batch)
		batch = nil
		pending = next
		if stopped || len(pending) == 0 {
			break
		}
		if c.landed > before {
			wait = landerWaitMin
		}
		if !in.sleep(wait) {
			break
		}
		wait = min(wait*2, landerWaitMax)
	}
	c.pending = len(pending)
	fmt.Printf("media lander: landed %d file(s), %d bytes; %d skipped, %d pending, %d damaged (NWP-20261129-08)\n",
		c.landed, c.bytes, c.skipped, c.pending, c.damaged)
	return c
}
