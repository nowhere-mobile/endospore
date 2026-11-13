package main

// #145 S5 (NWP-20260901-29): "changed on this phone since the last save" -- Signal 3, the high estimate.
//
// The exact delta is off the table by design (a byte-true diff is the seal minus the upload; ~1m25 on a real
// profile, and the screen it feeds is opened UNDER TIME PRESSURE, before powering off). What is cheap and
// honest is a stat-only walk with two rules, both chosen to fail toward "not saved":
//
//	rule A (exact, baseline-free): a file the head manifest lists as DEFERRED whose local size or mtime
//	        disagrees with the manifest -- the seal's own deferred predicate minus its RAM-cache conjunct. The
//	        mtime is compared in the RECORD'S OWN unit (seconds for the web importer's, UnixNano for the
//	        seal's; see deferredStatMatches), never one unit against the other.
//	rule B (estimate): a file with NO deferred record whose mtime is at or after the DISPATCH of the last seal
//	        that LANDED (lastLandedSealStartedAt, NWP-20261108-05): a failed, refused or skipped seal never moves
//	        it, and a seal still running has not landed, so its files still count. Skipped entirely when no seal
//	        has landed this daemon lifetime -- with no baseline every old restored file would count, and "your
//	        whole profile is unsaved" at first open is exactly the lie the scan-cache shortcut was rejected for.
//
// The walk runs in the WORKER (RO lane, no passphrase -- the lane refuses one): only endospore_priv can read
// a roamed user's data (system_data_file carries MCS categories; an s0 subject is refused by the CATEGORY
// constraint, not a type rule -- the storagebreakdown lesson). The daemon, which HAS the passphrase, dumps
// the three heads' Deferred indexes to a 0600 tmpfs file first; the worker's agent reads that and the disk.
//
// It walks the .under-SUBSTITUTED tree, never the overlay: a FUSE overlay reports full manifest sizes for
// files never downloaded (storage_breakdown.go's own warning), and the delta must measure the tree the seal
// will actually read. The figure is PLAINTEXT BYTES ON THIS PHONE -- not upload size (chunks dedup and
// compress), and the UI must word it that way. Over-counting (a touched-but-unchanged file) is the safe
// direction; a blind path is COUNTED AND FLAGGED, never folded into the byte figure -- a number over a tree
// it could not read is a claim.

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type sealDeltaIdxEnt struct {
	size  int64
	mtime int64
}

// sealDeltaIdxPath is fixed: the daemon writes it, the worker's agent reads it, both know $STATE.
func sealDeltaIdxPath(dest string) string { return filepath.Join(dest, "sealdelta.idx") }

func sealDeltaIdxKey(scope, rel string) string { return scope + "\x00" + rel }

// writeSealDeltaIdx serialises the three heads' Deferred indexes: one "scope\trel\tsize\tmtime" line each.
// Rels are metadata, not content, and the file is 0600 on the root-owned tmpfs -- the same exposure class as
// media-unders, which has carried overlay rels there since #84.
func writeSealDeltaIdx(path string, scopes map[string]map[string]deferredFile) error {
	var b strings.Builder
	for scope, def := range scopes {
		for rel, d := range def {
			fmt.Fprintf(&b, "%s\t%s\t%d\t%d\n", scope, rel, d.Size, d.MTime)
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func readSealDeltaIdx(path string) map[string]sealDeltaIdxEnt {
	out := map[string]sealDeltaIdxEnt{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		p := strings.SplitN(sc.Text(), "\t", 4)
		if len(p) != 4 {
			continue
		}
		sz, e1 := strconv.ParseInt(p[2], 10, 64)
		mt, e2 := strconv.ParseInt(p[3], 10, 64)
		if e1 != nil || e2 != nil {
			continue
		}
		out[sealDeltaIdxKey(p[0], p[1])] = sealDeltaIdxEnt{size: sz, mtime: mt}
	}
	return out
}

// NWP-20261126-06 (h56 #6, option 2): the deletion half of the row's case (3). The walk is stat-only, so a file
// that is gone is never visited and counted nowhere: a 169 MB deletion read "No new changes since the last save."
// The daemon now also writes sealdelta.listed, the files the store is known to hold: the #media head's Deferred
// and Ess rels, and the vault and #de scan caches (files of 1 MiB or more) of the last LANDED seal. A listed file
// the walk does not meet, and that a stat confirms absent, counts as deleted. A small app file is in no list, so
// its deletion is not counted. sealDeltaNoCacheScope marks a scope whose cache the daemon did not read (no landed
// seal, a seal dispatched since, or a cache older than the landed seal): its deletions are unknown, not zero.
const sealDeltaNoCacheScope = "#nocache"

func sealDeltaListedPath(dest string) string { return filepath.Join(dest, "sealdelta.listed") }

// writeSealDeltaListed writes one "scope\trel\tsize" line per listed file, then one "#nocache\tscope" line per
// scope whose cache was not read. 0600 on the same tmpfs as sealdelta.idx, written to a temp file and renamed.
func writeSealDeltaListed(path string, listed map[string]map[string]int64, noCache []string) error {
	var b strings.Builder
	for scope, files := range listed {
		for rel, size := range files {
			fmt.Fprintf(&b, "%s\t%s\t%d\n", scope, rel, size)
		}
	}
	for _, scope := range noCache {
		fmt.Fprintf(&b, "%s\t%s\n", sealDeltaNoCacheScope, scope)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// readSealDeltaListed maps sealDeltaIdxKey(scope, rel) to the listed size. A "#nocache" line becomes the key
// sealDeltaIdxKey(sealDeltaNoCacheScope, scope); no walk root has that scope, so the walk never meets it.
func readSealDeltaListed(path string) map[string]int64 {
	out := map[string]int64{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		p := strings.SplitN(sc.Text(), "\t", 3)
		if len(p) == 2 && p[0] == sealDeltaNoCacheScope && p[1] != "" {
			out[sealDeltaIdxKey(sealDeltaNoCacheScope, p[1])] = 0
			continue
		}
		if len(p) != 3 || p[0] == sealDeltaNoCacheScope || p[1] == "" {
			continue
		}
		sz, err := strconv.ParseInt(p[2], 10, 64)
		if err != nil {
			continue
		}
		out[sealDeltaIdxKey(p[0], p[1])] = sz
	}
	return out
}

type sealDeltaWalkOut struct {
	V              int      `json:"v"`
	Since          int64    `json:"since"`
	ChangedBytes   int64    `json:"changedBytes"`
	ChangedFiles   int64    `json:"changedFiles"`
	DeferredBytes  int64    `json:"deferredChangedBytes"`
	DeferredFiles  int64    `json:"deferredChangedFiles"`
	Blind          int64    `json:"blind"`
	DeletedBytes   int64    `json:"deletedBytes"` // NWP-20261126-06: listed or Deferred files now gone
	DeletedFiles   int64    `json:"deletedFiles"`
	DeletedUnknown []string `json:"deletedUnknown,omitempty"` // scopes whose scan cache was not read
}

// sealDeltaWalk applies the two rules over the given scope roots. unders maps an overlaid ABSOLUTE dir to
// the real backing dir (mediaUndersFn's shape); the walk descends the backing dir under the overlaid dir's
// rel, and never reads through the overlay itself. listed (sealdelta.listed) feeds the deletion pass only; nil
// counts no deletion.
func sealDeltaWalk(roots map[string]string, unders map[string]string, idx map[string]sealDeltaIdxEnt, listed map[string]int64, since int64) sealDeltaWalkOut {
	out := sealDeltaWalkOut{V: 1, Since: since}
	met := map[string]bool{}       // every entry the walk read, as sealDeltaIdxKey(scope, rel)
	var blindPre, skipPre []string // dirs it could not read, and the seal's skips: a key under one is not known gone
	var walkDir func(scope, dir, relBase string)
	walkDir = func(scope, dir, relBase string) {
		ents, err := os.ReadDir(dir)
		if err != nil {
			blindPre = append(blindPre, sealDeltaIdxKey(scope, relBase))
			out.Blind++
			return
		}
		for _, e := range ents {
			p := filepath.Join(dir, e.Name())
			rel := e.Name()
			if relBase != "" {
				rel = relBase + "/" + e.Name()
			}
			met[sealDeltaIdxKey(scope, rel)] = true
			if e.IsDir() {
				// The seal's own skips, mirrored: derived media caches and the transient install staging
				// and Play's download cache (NWP-20261102-01) and a fetch stage (NWP-20261130-03) are never sealed, so counting them would inflate the estimate with bytes no save moves.
				if strings.HasPrefix(e.Name(), mediaCacheDirName) || isAppCodeStagePath(rel) || isPlayDownloadPath(rel) || isOdFetchStagePath(rel) {
					skipPre = append(skipPre, sealDeltaIdxKey(scope, rel))
					continue
				}
				if u, ok := unders[p]; ok {
					walkDir(scope, u, rel) // measure the real tree the seal reads, not the overlay
					continue
				}
				walkDir(scope, p, rel)
				continue
			}
			if !e.Type().IsRegular() {
				continue
			}
			fi, err := e.Info()
			if err != nil {
				out.Blind++
				continue
			}
			if ent, ok := idx[sealDeltaIdxKey(scope, rel)]; ok {
				// rule A: deferred record vs local reality -- exact, baseline-free.
				if !deferredStatMatches(fi, ent) {
					out.DeferredBytes += fi.Size()
					out.DeferredFiles++
				}
				continue
			}
			// rule B: mtime at/after the last dispatch. Disabled with no baseline (since==0).
			if since > 0 && fi.ModTime().Unix() >= since {
				out.ChangedBytes += fi.Size()
				out.ChangedFiles++
			}
		}
	}
	for scope, root := range roots {
		walkDir(scope, root, "")
	}
	sealDeltaCountDeleted(&out, roots, unders, idx, listed, met, blindPre, skipPre)
	return out
}

// sealDeltaCountDeleted is the deletion pass. A listed or Deferred key counts once, when the walk did not meet it,
// no blind dir or seal skip covers it, and a stat of its path says it does not exist. A head-Deferred key (one idx
// holds, from whichever map) counts only under a live overlay: a stub never downloaded is not in .under, so the
// walk never meets it, but the overlay shows it. Outside a live overlay a stub and a deleted file look the same.
func sealDeltaCountDeleted(out *sealDeltaWalkOut, roots, unders map[string]string, idx map[string]sealDeltaIdxEnt, listed map[string]int64, met map[string]bool, blindPre, skipPre []string) {
	counted := map[string]bool{}
	count := func(key string, size int64, deferred bool) {
		if met[key] || counted[key] {
			return
		}
		scope, rel, _ := strings.Cut(key, "\x00")
		root, ok := roots[scope]
		if !ok || rel == "" {
			return
		}
		if sealDeltaUnderPrefix(key, blindPre) || sealDeltaUnderPrefix(key, skipPre) {
			return
		}
		if deferred && !sealDeltaUnderOverlay(filepath.Join(root, rel), unders) {
			return
		}
		if _, err := os.Lstat(filepath.Join(root, rel)); !errors.Is(err, fs.ErrNotExist) {
			return
		}
		counted[key] = true
		out.DeletedBytes += size
		out.DeletedFiles++
	}
	var unknown []string
	for k, size := range listed {
		scope, rel, _ := strings.Cut(k, "\x00")
		if scope == sealDeltaNoCacheScope {
			unknown = append(unknown, rel)
			continue
		}
		_, inIdx := idx[k] // a #media head-Deferred rel is in BOTH files: the overlay rule must reach it here
		count(k, size, inIdx)
	}
	for k, ent := range idx {
		count(k, ent.size, true) // no skip of listed keys: counted[] alone stops the second count
	}
	sort.Strings(unknown)
	out.DeletedUnknown = unknown
}

// sealDeltaUnderPrefix reports whether key (scope\x00rel) is a prefix key or under one. An empty prefix rel is the
// whole scope.
func sealDeltaUnderPrefix(key string, pres []string) bool {
	scope, rel, _ := strings.Cut(key, "\x00")
	for _, pk := range pres {
		ps, pre, _ := strings.Cut(pk, "\x00")
		if ps != scope {
			continue
		}
		if pre == "" || rel == pre || strings.HasPrefix(rel, pre+"/") {
			return true
		}
	}
	return false
}

// sealDeltaUnderOverlay reports whether path is inside an overlaid dir (a key of unders).
func sealDeltaUnderOverlay(path string, unders map[string]string) bool {
	for d := range unders {
		if strings.HasPrefix(path, d+"/") {
			return true
		}
	}
	return false
}

// deferredStatMatches reports whether a file on disk still matches its deferred record: equal size and an
// equal mtime IN THE RECORD'S OWN UNIT. deferredFile.MTime is UnixNano when the seal wrote it and unix seconds
// when the web importer did (mtimeSecondsCeiling tells them apart; NWP-20260829-29 fixed the same unit bug in
// the seal's carry comparison). Comparing seconds against a seal record can never match, so every deferred
// file was counted as changed on every visit. Not "both through deferredMTimeNanos": a seconds record against a
// file with a sub-second mtime would then never match.
func deferredStatMatches(fi os.FileInfo, ent sealDeltaIdxEnt) bool {
	if fi.Size() != ent.size {
		return false
	}
	if ent.mtime < mtimeSecondsCeiling {
		return fi.ModTime().Unix() == ent.mtime
	}
	return fi.ModTime().UnixNano() == ent.mtime
}

// runSealDeltaWalkCLI is the worker-side entry: sealdeltawalk <uid> <since>. Root in the endospore_priv
// domain (the only one that can read a roamed user's MCS-categorised data); prints one JSON object.
func runSealDeltaWalkCLI(uid, sinceArg string) {
	since, _ := strconv.ParseInt(strings.TrimSpace(sinceArg), 10, 64)
	roots := map[string]string{
		"vault": "/data/user/" + uid,
		"de":    "/data/user_de/" + uid,
		"media": "/data/media/" + uid,
	}
	idx := readSealDeltaIdx(sealDeltaIdxPath("/data/nowhere/state"))
	listed := readSealDeltaListed(sealDeltaListedPath("/data/nowhere/state"))
	unders := map[string]string{}
	for _, r := range roots {
		m, _ := mediaUndersFn(r) // the estimate only stats, and a stat through a stub fetches nothing
		for k, v := range m {
			unders[k] = v
		}
	}
	out := sealDeltaWalk(roots, unders, idx, listed, since)
	b, err := json.Marshal(out)
	if err != nil {
		fmt.Println("{}")
		return
	}
	os.Stdout.Write(b)
	fmt.Println()
}
