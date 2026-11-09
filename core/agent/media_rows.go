package main

// NWP-20261130-02: THE LIST OF MEDIA NOT YET DOWNLOADED, FOR roamd's media-insert (backlog §B "On the DEFAULT tier
// the Gallery is empty: MediaStore never learns a deferred file exists"; docs/product-decisions.md, 2026-11-06).
//
// Only the manifest holds the deferred entries, and the manifest dies with the restore. So the #media restore leaves
// $NOWHERE_STATE/media.rows for roamd, which hands it to `nowhere_db_fix media-insert` and removes it. NOWHERE_STATE is
// tmpfs, the file is 0600, and it holds file names and metadata, never a file's content. No line prints a name from it.
//
// Each record is four NUL-terminated fields, so a tab or a newline in a name cannot split one:
//
//	<size>\0<mtime seconds>\0<parent of rel, lower-cased as Java does>\0<rel>\0
//
// The third field exists because bucket_id is the Java hash of the lower-cased parent and C has no Unicode table.
// The helper still computes every column; only the fold comes from here.

import (
	"bytes"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const mediaRowsFile = "media.rows"

// clearMediaRowsList drops an earlier sign-in's list before a #media restore begins, so a restore that dies early
// leaves nothing for roamd to insert. Other phases never own the file.
func clearMediaRowsList() {
	if os.Getenv("NOWHERE_PHASE") == "media" {
		if st := os.Getenv("NOWHERE_STATE"); st != "" {
			os.Remove(filepath.Join(st, mediaRowsFile))
		}
	}
}

// mediaRowRel reports whether MediaProvider would index rel, judged from the name alone. Out: an app's private
// Android/data and Android/obb (in any letter case: the media tree is case-insensitive), a hidden segment, and anything
// that is not a clean relative path in valid UTF-8. .nomedia is mediaRowsHasNomedia's: it needs the disk.
func mediaRowRel(rel string) bool {
	if rel == "" || !utf8.ValidString(rel) || strings.ContainsRune(rel, 0) {
		return false
	}
	segs := strings.Split(rel, "/")
	for _, s := range segs {
		if s == "" || strings.HasPrefix(s, ".") {
			return false
		}
	}
	if len(segs) >= 2 && strings.EqualFold(segs[0], "Android") &&
		(strings.EqualFold(segs[1], "data") || strings.EqualFold(segs[1], "obb")) {
		return false
	}
	return true
}

// mediaRowsHasNomedia reports whether dir (relative to dest, "." for the root) or an ancestor holds a .nomedia.
// .nomedia files restore before the gate (docs/media-after-gate.md §2), so they are on disk by now. AOSP ignores one
// directly in a default top-level folder; this obeys it, so those files get no row and a scan can still add them.
func mediaRowsHasNomedia(dest, dir string, memo map[string]bool) bool {
	if v, ok := memo[dir]; ok {
		return v
	}
	_, err := os.Lstat(filepath.Join(dest, dir, ".nomedia"))
	v := err == nil
	if !v && dir != "." {
		v = mediaRowsHasNomedia(dest, path.Dir(dir), memo)
	}
	memo[dir] = v
	return v
}

// writeMediaRowsList writes the list, sorted, even with no record: a restore that deferred nothing still replaces it.
// It never fails the restore: a file it cannot write only leaves the Gallery as it was.
func writeMediaRowsList(deferred map[string]deferredFile, dest string) {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return
	}
	rels := make([]string, 0, len(deferred))
	for rel := range deferred {
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	var b bytes.Buffer
	memo := map[string]bool{}
	for _, rel := range rels {
		if path.Base(rel) == ".nomedia" { // normally on disk by now; a deferred one hides its folder just the same
			memo[path.Dir(rel)] = true
		}
	}
	for _, rel := range rels {
		if !mediaRowRel(rel) || mediaRowsHasNomedia(dest, path.Dir(rel), memo) {
			continue
		}
		d := deferred[rel]
		parent := ""
		if dir := path.Dir(rel); dir != "." {
			parent = javaLowerRoot(dir)
		}
		for _, field := range []string{strconv.FormatInt(d.Size, 10), strconv.FormatInt(deferredMTimeNanos(d.MTime)/1e9, 10), parent, rel} {
			b.WriteString(field)
			b.WriteByte(0)
		}
	}
	list := filepath.Join(st, mediaRowsFile)
	if err := os.WriteFile(list, b.Bytes(), 0o600); err != nil {
		os.Remove(list)
		fmt.Printf("restore: media rows list not written (%T)\n", err)
	}
}

// javaLowerRoot is Java's String.toLowerCase(Locale.ROOT). unicode.ToLower is the same rune by rune but for Java's two
// special cases: U+0130 becomes i + U+0307, and a final capital sigma becomes ς.
func javaLowerRoot(s string) string {
	rs := []rune(s)
	var b strings.Builder
	for i, r := range rs {
		switch r {
		case 0x130:
			b.WriteString("i̇")
		case 0x3A3:
			if javaFinalSigma(rs, i) {
				b.WriteRune(0x3C2)
			} else {
				b.WriteRune(0x3C3)
			}
		default:
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}

// javaFinalSigma is Unicode's Final_Sigma condition: a cased letter before position i and none after it, each side
// skipping case-ignorable characters. '/' is not case-ignorable, so a path segment ends the search.
func javaFinalSigma(rs []rune, i int) bool {
	before := false
	for j := i - 1; j >= 0 && !before; j-- {
		if javaCased(rs[j]) {
			before = true
		} else if !javaCaseIgnorable(rs[j]) {
			break
		}
	}
	if !before {
		return false
	}
	for j := i + 1; j < len(rs); j++ {
		if javaCased(rs[j]) {
			return false
		}
		if !javaCaseIgnorable(rs[j]) {
			break
		}
	}
	return true
}

func javaCased(r rune) bool { return unicode.IsUpper(r) || unicode.IsLower(r) || unicode.IsTitle(r) }

func javaCaseIgnorable(r rune) bool {
	return unicode.In(r, unicode.Mn, unicode.Me, unicode.Cf, unicode.Lm, unicode.Sk) || strings.ContainsRune("'.:·’‘․‧", r)
}
