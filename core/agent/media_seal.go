package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// #84 -- the seal side of KEEPING the media overlays mounted. P3d tore the overlays down for every seal
// (roamd `out` ran stop_mediad) so the walk saw the real dir; that blinded every RUNNING app about once a
// minute -- the periodic seal's unmount+remount strands a running app's mount-namespace view (raw dir or a
// dead copy), and an app that scans inside the window registers nothing (OrganicMaps "maps gone", proven on
// FP3 2026-07-03). Instead the walker now reads each live overlay's bind-hidden `.under` dir -- the SAME real
// files the overlay passes through -- so the overlay stays mounted for the whole session:
//   - deferred stubs are not in .under (never restored) -> absent from the walk -> carried forward by the
//     manifest (the "present-not-deleted" rule), exactly as if the overlay were down;
//   - real files (essential siblings, new app writes that pass through the loopback) seal normally;
//   - nothing is ever read THROUGH the FUSE mount, so a live overlay can't trigger a fetch storm (cold blob
//     cache) and a dead one can't error/hang the walk.

// mediaOverlayUnders maps each live media-overlay mountpoint under src to its bind-hidden real dir. The
// mapping is unconditional: when the .under bind is MISSING (the reconcile renamed the cache dir out from
// under the mount -- task #92 -- or a sweep raced), the mountpoint still maps to the now-nonexistent under
// path, so the walker SKIPS the dir (nothing readable there) instead of walking through the overlay --
// where every stub reads as a present file and a dead daemon errors the walk. The skipped dir's deferred
// entries are carried forward by pushProfile's seen-set rule; its real siblings miss ONE seal (still on
// disk, re-sealed by the next healthy walk). Self-mapping here is what dropped profile c's whole deferred
// set on 2026-07-03 (TestSealOverlayDropMatrix/brokenUnder).
//
// NWP-20261109-17: a mount table that cannot be opened, or not read whole, is an ERROR, never a short map. An
// overlay missing from the map is walked THROUGH (the header's fetch storm, or a dead mount's reads all failing),
// so the caller must refuse rather than walk on a partial answer.
func mediaOverlayUnders(src string) (map[string]string, error) {
	f, err := os.Open(procSelfMounts)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil // not Linux / no procfs -> no overlays possible
		}
		return nil, err // the table exists but could not be opened: unknown, never empty
	}
	defer f.Close()
	return parseMediaOverlayUndersPub(f, src, publishedMediaUnders())
}

// publishedMediaUnders reads the authoritative mountpoint -> hidden map mediad writes at mount time
// (mediaUndersFile under NOWHERE_STATE). Empty map on any error: the caller then falls back to deriving the
// path from the mount table exactly as before, so a missing or unreadable file degrades rather than breaks.
//
// This is the AUTHORITY for RESOLUTION only. Liveness still comes from /proc/self/mounts, because the file
// records what was mounted, not what still is -- a scope torn down without a clean teardown would otherwise
// point the walk at a dir that is no longer bound.
func publishedMediaUnders() map[string]string {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(st, mediaUndersFile))
	if err != nil {
		return nil
	}
	out := map[string]string{}
	for _, ln := range strings.Split(string(b), "\n") {
		if i := strings.IndexByte(ln, '\t'); i > 0 && i+1 < len(ln) {
			out[ln[:i]] = ln[i+1:]
		}
	}
	return out
}

// underLeaf names the single-component `.under` leaf that mediad binds a deferred rel dir to, and that the
// seal's fallback below looks that bind up by. NWP-20261011-74: it used to be every `/` replaced by `_`,
// which is not injective -- `Pictures/Screenshots` and a top-level `Pictures_Screenshots` both became
// `Pictures_Screenshots`. MkdirAll succeeded on the existing leaf, the second MS_BIND stacked on the first,
// one overlay served the other dir's files with no log line, and the seal recorded them under the first
// dir's rels (backlog: "The mediad hidden-bind path mangles `/` to `_`").
//
// The escape is `_` -> `_u` FIRST, then `/` -> `_s`; every other byte is unchanged. Both codes start with the
// escape character and differ in the byte after it, so the output parses back to exactly one rel: distinct
// rels can never share a leaf, and no leaf contains a `/`. Escaping lengthens the leaf, and a leaf must fit
// NAME_MAX (255 bytes) or the MkdirAll and the bind both fail and the dir is never overlaid; an escaped leaf
// that would not fit is replaced by `_h` + hex(sha256(rel)) (66 bytes). An escaped leaf never has an `h`
// after a `_`, so the two forms cannot collide either.
//
// Both callers MUST use this one function -- mediafs.go's bind and this file's fallback agreeing is the
// whole point. Changing the spelling needs no migration: a leaf only ever exists inside the session's own
// media cache dir (the chooser's files dir in that session's Android user), is read back only through the
// live mount table or the per-session media-unders map in the RAM state dir, and both are gone by the time
// an updated agent runs (an OTA reboots), so no leaf from an older mediad is ever looked up by name.
func underLeaf(rel string) string {
	leaf := strings.ReplaceAll(strings.ReplaceAll(rel, "_", "_u"), "/", "_s")
	if len(leaf) > 255 {
		sum := sha256.Sum256([]byte(rel))
		return "_h" + hex.EncodeToString(sum[:])
	}
	return leaf
}

// underRel reads a leaf underLeaf wrote back to its rel: `_u` -> `_`, `_s` -> `/`, every other byte unchanged.
// ok is false for the hashed `_h` form (the sha256 of a rel too long to escape cannot be read back) and for a
// name underLeaf never writes (a `_` followed by any other byte, or a trailing `_`). The storage breakdown uses
// it to count a `.under` bind's real files where their real paths belong (NWP-20261016-49).
func underRel(leaf string) (string, bool) {
	var b strings.Builder
	for i := 0; i < len(leaf); i++ {
		if leaf[i] != '_' {
			b.WriteByte(leaf[i])
			continue
		}
		if i++; i == len(leaf) {
			return "", false
		}
		switch leaf[i] {
		case 'u':
			b.WriteByte('_')
		case 's':
			b.WriteByte('/')
		default:
			return "", false
		}
	}
	return b.String(), true
}

// procSelfMounts is the mount table overlay liveness is read from; a var so tests can point it elsewhere.
var procSelfMounts = "/proc/self/mounts"

// mediaUndersFn lets tests inject an overlay map without real mounts; production uses mediaOverlayUnders. It
// returns an error when the mount table could not be read whole.
var mediaUndersFn = mediaOverlayUnders

// parseMediaOverlayUnders keeps the original signature for the existing tests, which inject a mount table
// with no published map (the pre-DIA-20260816-13 behaviour).
func parseMediaOverlayUnders(r io.Reader, src string) map[string]string {
	m, _ := parseMediaOverlayUndersPub(r, src, nil)
	return m
}

func parseMediaOverlayUndersPub(r io.Reader, src string, pub map[string]string) (map[string]string, error) {
	// DIA-20260813-06 (#135): RESOLVE each overlay's .under bind from the mount table instead of computing it
	// from one assumed layout. The computed path (<src>/<mediaCacheRel>/.under/<leaf>) is only correct when
	// src IS the user dir (CE scope). The EXTERNAL scope's binds live in the CHOOSER's files dir under
	// /data/user/<uid> -- a different root AND a different cache dir (.nowhere-media-ext) -- so for
	// src=/data/media/<uid> the computed path never exists and the walker SKIPPED the whole overlaid subtree:
	// on 2026-08-13 that silently dropped ~58MB of fetched-local ContentDownload from every #media walk, the
	// shrink guard (correctly) refused the collapsed manifest, and the session could not log off at all. The
	// binds are themselves mounts, so the same table that names the overlays names their real dirs: match by
	// underLeaf(rel) (the .under entry's basename), scoped to this src's uid, preferring the canonical /data
	// path over its /data_mirror and /mnt propagation aliases.
	uid := src[strings.LastIndex(src, "/")+1:]
	var overlays []string
	unders := map[string]string{} // underLeaf(rel) -> the live .under bind's real mountpoint
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1<<20) // NWP-20261109-17: a 1 MiB line; the 64 KiB default ended the scan silently
	for sc.Scan() {
		fld := strings.Fields(sc.Text())
		if len(fld) < 3 {
			continue
		}
		mnt := unescapeMountPath(fld[1])
		if fld[2] == "fuse.nowheremedia" && strings.HasPrefix(mnt, src+"/") {
			overlays = append(overlays, mnt)
			continue
		}
		if strings.HasPrefix(mnt, "/data_mirror/") || strings.HasPrefix(mnt, "/mnt/") {
			continue // propagation aliases of the same bind; the canonical /data path is what the walk reads
		}
		if i := strings.LastIndex(mnt, "/.under/"); i >= 0 && strings.Contains(mnt, "/"+uid+"/") {
			base := mnt[i+len("/.under/"):]
			if base != "" && !strings.Contains(base, "/") {
				if _, dup := unders[base]; !dup {
					unders[base] = mnt
				}
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err // a read error or an over-long line: the rest of the table is unknown, never absent
	}
	if len(overlays) == 0 {
		return nil, nil
	}
	out := make(map[string]string, len(overlays))
	for _, mp := range overlays {
		// The leaf is underLeaf(rel), the same function runMediad binds with. Built with explicit "/" --
		// /proc/mounts paths are always slash-form.
		// DIA-20260816-13: mediad's published map FIRST. It is the only source that is correct for BOTH
		// scopes -- the derivation below assumes src is the user dir, which is false for the external scope.
		if under, ok := pub[mp]; ok && under != "" {
			out[mp] = under
			continue
		}
		rel := strings.TrimPrefix(mp, src+"/")
		leaf := underLeaf(rel)
		if under, ok := unders[leaf]; ok {
			out[mp] = under
			continue
		}
		// No live bind found (the reconcile renamed the cache dir out from under the mount -- task #92 -- or a
		// sweep raced): fall back to the computed path, which for a missing bind maps to a nonexistent dir ON
		// PURPOSE, so the walker SKIPS the dir (deferred entries carried by the seen-set) instead of walking
		// through the overlay. Self-mapping here is what dropped profile c's whole deferred set on 2026-07-03
		// (TestSealOverlayDropMatrix/brokenUnder).
		// DIA-20260816-13: SAY SO. This fallback deliberately maps to a nonexistent dir so the walker SKIPS
		// rather than walking through the overlay (where every stub reads as a present file) -- that part is
		// correct and is kept. What was wrong is that it happened in SILENCE: the skip made the manifest
		// collapse, the shrink guard refused it, and the refusal blamed "likely a partial restore", pointing
		// whoever read it at the wrong layer entirely. One line here is the difference between a two-hour
		// investigation and a grep.
		fmt.Fprintf(os.Stderr, "[seal] media overlay %s UNRESOLVED (no published map entry, no live .under bind) -> skipping its subtree; this scope's manifest will be short\n", mp)
		out[mp] = src + "/" + mediaCacheRel + "/.under/" + leaf
	}
	return out, nil
}

// mediaTombstones reads the deletion tombstones for the scope being sealed -- one rel per line, which
// #84’s Unlink handler appends when an app removes a deferred file (e.g. Organic Maps deleting an old map
// while writing the updated one). The Deferred carry-forward drops these rels -- the ONE positive-deletion
// signal that overrides the "not-seen-so-carry-forward" data-safety rule (an unseen file is normally kept;
// an explicit unlink is a real delete). Missing/unreadable -> nil, so a phase or profile with no media
// cache is unaffected.
//
// ⚠ THE FILE IS NOT ALWAYS INSIDE THE TREE. Each mediad instance writes to its OWN cache dir, and only the
// CE one lives under the tree it serves -- see the two call sites below.
func mediaTombstones(src string) map[string]bool {
	out := map[string]bool{}
	read := func(p string) {
		b, err := os.ReadFile(p)
		if err != nil {
			return
		}
		for _, ln := range strings.Split(string(b), "\n") {
			if ln = strings.TrimSpace(ln); ln != "" {
				out[ln] = true
			}
		}
	}
	// The CE scope: mediad caches INSIDE the tree being sealed, so the path is computable from src.
	read(src + "/" + mediaCacheRel + "/.deleted")
	// NWP-20260908-03: #media does NOT work that way, and computing it from src read a file the device never
	// writes -- so EXTERNAL on-demand media deletions never propagated at ALL. The external mediad serves
	// /data/media/<uid> but caches under the CHOOSER’s CE dir in `.nowhere-media-ext`: a different root AND
	// a different basename. That is exactly the mistake DIA-20260813-06 fixed for the overlay binds -- "the
	// computed path is only correct when src IS the user dir ... for src=/data/media/<uid> the computed path
	// never exists" -- and this call site was missed. That fix resolved the binds from the mount table; a
	// tombstone file is not a mount, so the path comes from roamd instead, which is the process that knows it.
	// Empty for every scope with no serving daemon, which leaves the CE behaviour above byte-identical.
	if p := os.Getenv("NOWHERE_MEDIA_TOMBSTONES"); p != "" {
		read(p)
	}
	if len(out) == 0 {
		return nil // unchanged contract: no tombstones is nil, not an empty map
	}
	return out
}

// unescapeMountPath decodes the octal escapes /proc/mounts uses for space, tab, newline and backslash.
func unescapeMountPath(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			switch s[i+1 : i+4] {
			case "040":
				b.WriteByte(' ')
				i += 3
				continue
			case "011":
				b.WriteByte('\t')
				i += 3
				continue
			case "012":
				b.WriteByte('\n')
				i += 3
				continue
			case "134":
				b.WriteByte('\\')
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
