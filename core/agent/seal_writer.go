package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// NWP-20261201-12 (h62 #4): the evidence for the periodic save's change test. Each push names what it found changed
// since the last seal, by writer class and data kind. The line reaches roam.log, which outlives every wipe, so it
// holds counts and the fixed words below: never a package, path, profile or file name.

// sealWriterClasses and sealWriterKinds are the print order. sealWriterLine builds its text from these lists only.
var (
	sealWriterClasses = []string{"play", "platform", "nowhere", "held", "app", "other"}
	sealWriterKinds   = []string{"cache", "db", "prefs", "files", "nobackup", "appdir", "other"}
)

// sealWriterParts returns the package a rel files under, whether that is the On-demand hold, and the component after
// the package. next is "" when a rel has no package (a media folder, a bare Android) or nothing after it. A held rel
// needs a component under <pkg>, the file shapes of dropPkgForFileRel.
func sealWriterParts(rel string) (pkg string, held bool, next string) {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	switch {
	case len(parts) >= 4 && parts[0] == chooserPkg && parts[1] == odHoldDirName:
		return parts[2], true, parts[3]
	case len(parts) >= 6 && parts[0] == "Android" && (parts[1] == "data" || parts[1] == "obb") &&
		parts[2] == chooserPkg && parts[3] == odHoldDirName:
		return parts[4], true, parts[5]
	}
	pkg = attrPkgForRel(rel)
	if pkg == "" {
		pkg = parts[0]
	}
	at := 0
	if parts[0] == "Android" {
		at = 2
	}
	if (strings.Contains(pkg, ".") || pkg == "android") && at+1 < len(parts) && parts[at] == pkg {
		next = parts[at+1]
	}
	return pkg, false, next
}

// sealWriterClass names who owns a rel. It takes a rel and not a group unit, so a large file and a group member
// classify alike in every scope.
func sealWriterClass(rel string) string {
	pkg, held, _ := sealWriterParts(rel)
	switch {
	case held:
		return "held"
	case pkg == "com.google.android.gms" || pkg == "com.google.android.gsf" || pkg == "com.android.vending":
		return "play"
	case strings.HasPrefix(pkg, "com.nowhere."):
		return "nowhere"
	case pkg == "android" || strings.HasPrefix(pkg, "com.android.") ||
		strings.HasPrefix(pkg, "app.grapheneos.") || strings.HasPrefix(pkg, "org.lineageos."):
		return "platform"
	case strings.Contains(pkg, "."):
		return "app"
	}
	return "other"
}

// sealWriterKind names the kind of data a rel is, from the component after its package.
func sealWriterKind(rel string) string {
	_, _, next := sealWriterParts(rel)
	switch {
	case next == "cache" || next == "code_cache":
		return "cache"
	case next == "databases":
		return "db"
	case next == "shared_prefs":
		return "prefs"
	case next == "files":
		return "files"
	case next == "no_backup":
		return "nobackup"
	case strings.HasPrefix(next, "app_"):
		return "appdir"
	}
	return "other"
}

// sealWriterTally is one walk's count of what it found changed. The keys of its maps are words of the fixed lists.
type sealWriterTally struct {
	since  time.Time      // when the last seal committed: groupcache.<tag>'s ModTime; zero = no baseline
	groups map[string]int // group misses by class
	files  map[string]int // changed regular files by class
	kinds  map[string]int // changed regular files by kind
}

// reset starts the counters of a new walk. It keeps since, which belongs to the cache load and not to the walk.
func (t *sealWriterTally) reset() {
	t.groups, t.files, t.kinds = map[string]int{}, map[string]int{}, map[string]int{}
}

// setSealWriterSince sets the baseline. newFileScanCache records the real one; tests use this seam.
func (sc *fileScanCache) setSealWriterSince(since time.Time) {
	if sc == nil {
		return
	}
	sc.mu.Lock()
	defer sc.mu.Unlock()
	sc.writer.since = since
}

// noteWriterGroupMiss counts one group the cache could not serve, under the class of its first regular member. A
// mixed group files under that member. A group of directories and symlinks has no regular member and no count.
func (sc *fileScanCache) noteWriterGroupMiss(g []walkEnt) {
	if sc == nil {
		return
	}
	for _, e := range g {
		if e.info != nil && e.info.Mode().IsRegular() {
			class := sealWriterClass(e.rel)
			sc.mu.Lock()
			defer sc.mu.Unlock()
			if sc.writer.groups == nil {
				sc.writer.reset()
			}
			sc.writer.groups[class]++
			return
		}
	}
}

// noteWriterFile counts one regular file the walk handles, when it was written at or after the baseline. It uses the
// FileInfo the walk already has: no stat and no read. since is when the last seal COMMITTED, so a file written during
// that seal's walk, after that walk read it, counts as a group miss and not as a changed file.
func (sc *fileScanCache) noteWriterFile(rel string, info os.FileInfo) {
	if sc == nil || !info.Mode().IsRegular() {
		return
	}
	class, kind := sealWriterClass(rel), sealWriterKind(rel)
	sc.mu.Lock()
	defer sc.mu.Unlock()
	if sc.writer.since.IsZero() || info.ModTime().Before(sc.writer.since) {
		return
	}
	if sc.writer.files == nil {
		sc.writer.reset()
	}
	sc.writer.files[class]++
	sc.writer.kinds[kind]++
}

// sealWriterStats returns this walk's tally for the push log line, as a copy.
func (sc *fileScanCache) sealWriterStats() sealWriterTally {
	if sc == nil {
		return sealWriterTally{}
	}
	sc.mu.Lock()
	defer sc.mu.Unlock()
	copyOf := func(m map[string]int) map[string]int {
		c := make(map[string]int, len(m))
		for k, v := range m {
			c[k] = v
		}
		return c
	}
	return sealWriterTally{since: sc.writer.since, groups: copyOf(sc.writer.groups), files: copyOf(sc.writer.files), kinds: copyOf(sc.writer.kinds)}
}

// sealWriterCounts prints one count per word, in the word list's order.
func sealWriterCounts(words []string, m map[string]int) string {
	out := make([]string, 0, len(words))
	for _, w := range words {
		out = append(out, fmt.Sprintf("%s=%d", w, m[w]))
	}
	return strings.Join(out, " ")
}

// sealWriterLine is the text of the push line after the profile. A forced full re-hash misses every group, so it has
// no group count to give. With no baseline there is no time to compare a file with.
func sealWriterLine(t sealWriterTally, forceFull bool) string {
	groups := "groups not counted (full re-hash)"
	if !forceFull {
		groups = "groups " + sealWriterCounts(sealWriterClasses, t.groups)
	}
	if t.since.IsZero() {
		return groups + "; files not counted (no baseline)"
	}
	return groups + "; files " + sealWriterCounts(sealWriterClasses, t.files) + "; kinds " + sealWriterCounts(sealWriterKinds, t.kinds)
}
