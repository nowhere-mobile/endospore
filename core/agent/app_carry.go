package main

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// #91 slice 5c: the CARRY half. The index half (NWP-20260906-16) made an installed app's bytes nameable;
// this makes them survive a seal by a handset that never received the app.
//
// WHY A CARRY AND NOT A MERGE. The #apps head is a SINGLE account-shared head and every seal already reads and
// decrypts it, so nothing here fetches, decrypts another lineage's data, or re-uploads: a carried package is
// re-emitted BY HASH out of the manifest this seal already holds, and it stays leased because addCDCChunks
// leases every hash the head NAMES. No device ever trusts a claim about bytes it has not itself read -- the
// property that ruled out splicing a range map published by another device.
//
// ⚠ manifest.tsv IS THE OTHER HALF OF THE PROBLEM AND IS EASY TO MISS. It is a WHOLE-SCOPE index written at
// the stage root, roamd gates the entire #apps login restore on its presence, and the chooser installs
// strictly from it. Carrying an app's APK bytes without its LINE puts the bytes on disk where nothing will
// ever install them. And it cannot be spliced chunk-wise: two lineages' copies in one tar means untarFrom's
// O_TRUNC lets the later one win outright, destroying a whole lineage's package index. So the lines are
// unioned in PLAINTEXT into the staged file BEFORE the walk, and the tar and the index then agree by
// construction with no restore-side change at all.

// appManifestRel is the whole-scope package index roamd writes at the #apps stage root (nowhere_roamd.sh:
// `MAN="$STAGE/manifest.tsv"`). One line per package: pkg \t versionCode \t sideloaded \t mode \t apk...
const appManifestRel = "manifest.tsv"

// appManifestLines parses a staged manifest.tsv into pkg -> its VERBATIM line. Verbatim because the columns
// past the first are not ours to reconstruct: the mode column decides installed-vs-on-demand at restore, and
// the apk basenames are the install set. A malformed or empty line is skipped rather than guessed at.
func appManifestLines(src string) map[string]string {
	b, err := os.ReadFile(filepath.Join(src, appManifestRel))
	if err != nil {
		return nil
	}
	out := map[string]string{}
	for _, ln := range strings.Split(string(b), "\n") {
		if ln = strings.TrimRight(ln, "\r"); ln == "" {
			continue
		}
		pkg := ln
		if i := strings.IndexByte(ln, '\t'); i > 0 {
			pkg = ln[:i]
		}
		// Defensive: a path separator in a package column would mean the producer wrote paths, and every
		// consumer here keys directories by this token.
		if pkg == "" || strings.ContainsAny(pkg, "/\\") {
			continue
		}
		out[pkg] = ln
	}
	return out
}

// carryablePackages is the set this seal must carry: named by the stored head, absent from this stage, and not
// deliberately removed. Sorted, so a seal is reproducible in a log and in a test.
//
// ABSENT IS DECIDED BY THE STAGE DIRECTORY, not by the walk, because this has to run BEFORE the walk -- the
// manifest.tsv union must be in place for the walk to seal it. roamd rebuilds the stage from scratch every
// seal and creates <pkg>/ for each app it stages, so a missing directory is exactly "this handset did not
// stage it", which is the condition `live_code_dir` silently produces.
func carryablePackages(src string, oldApps map[string]string, drop map[string]bool) []string {
	var out []string
	for pkg := range oldApps {
		if _, err := os.Stat(filepath.Join(src, pkg)); err == nil {
			continue // staged by this handset -> the walk owns it
		}
		// A deliberate removal is a deletion, not an absence -- the same predicate, and the same sentence,
		// the #204 deferred carry already uses.
		if dropPkgForFileRel(pkg+"/base.apk", drop) {
			continue
		}
		out = append(out, pkg)
	}
	sort.Strings(out)
	return out
}

// unionAppManifest writes the carried packages' lines into the staged manifest.tsv, so the sealed tar and the
// sealed index describe the same set. Returns the packages whose lines were added.
//
// ⚠ THIS WRITES INTO THE DIRECTORY push WAS HANDED, which is a real change to what `push` does and is called
// out here rather than buried. It is bounded: only under NOWHERE_CARRY_ESSENTIAL, only the #apps scope, and
// the directory in question is roamd's own scratch stage (/data/nowhere/appcode-stage), rebuilt from nothing
// on every seal -- never a live data tree. The alternative, rewriting the index at RESTORE, keeps push
// read-only but adds new code to the path #124/#200 protect hardest and lets a bad splice hide behind a
// regenerated index.
//
// Idempotent by package: a stage that already lists a package is left alone, so a re-run cannot duplicate a
// line. Atomic (tmp + rename) so a crash mid-write cannot leave the index the whole restore is gated on
// truncated.
func reconcileAppManifest(src string, carry []string, oldApps map[string]string, drop map[string]bool) (added, removed []string, err error) {
	have := appManifestLines(src)
	var add []string
	for _, pkg := range carry {
		if _, dup := have[pkg]; dup {
			continue
		}
		ln, ok := oldApps[pkg]
		if !ok || ln == "" {
			continue // no line to carry -> carrying the bytes would install nothing; skip the package entirely
		}
		add = append(add, ln)
		added = append(added, pkg)
	}
	// NWP-20260906-18: REMOVE the line of anything the effective drop set deletes -- this device's own
	// uninstalls AND the account tombstones. Suppressing a package's APK files without pruning its LINE
	// leaves the sealed index promising an app whose bytes are not in the tar, so the next login tries to
	// install a package with no APKs. The index has to describe exactly what the seal contains.
	for pkg := range have {
		if pkg != "" && drop[pkg] {
			removed = append(removed, pkg)
		}
	}
	if len(add) == 0 && len(removed) == 0 {
		return nil, nil, nil
	}
	sort.Strings(removed)
	// Rebuilt from the surviving lines plus the carried ones, rather than appended to, because a removal
	// cannot be expressed by appending.
	keepOrder := make([]string, 0, len(have))
	for pkg := range have {
		keepOrder = append(keepOrder, pkg)
	}
	sort.Strings(keepOrder)
	var out []string
	for _, pkg := range keepOrder {
		if drop[pkg] {
			continue
		}
		out = append(out, have[pkg])
	}
	out = append(out, add...)
	body := ""
	if len(out) > 0 {
		body = strings.Join(out, "\n") + "\n"
	}
	p := filepath.Join(src, appManifestRel)
	tmp := p + ".tmp"
	if werr := os.WriteFile(tmp, []byte(body), 0o600); werr != nil {
		return nil, nil, werr
	}
	if rerr := os.Rename(tmp, p); rerr != nil {
		os.Remove(tmp)
		return nil, nil, rerr
	}
	return added, removed, nil
}

// carryPkgOf maps a manifest rel to the package that owns it -- "<pkg>/..." at the #apps stage root. The stage
// root also holds manifest.tsv itself, which belongs to no package and must never be carried per-package: it
// is unioned in plaintext instead.
func carryPkgOf(rel string) string {
	rel = filepath.ToSlash(rel)
	i := strings.IndexByte(rel, '/')
	if i <= 0 {
		return ""
	}
	return rel[:i]
}

// adoptDormantApps moves into the stage the dormant shape roamd prepared for a package the stored head's app index
// does not name (NWP-20261128-01). roamd's carry branch (NWP-20261119-02) stages NOTHING for an On-demand/Auto
// package with no live copy or a differing version, and leaves the carry to the index. A head sealed before 0.5.51
// has no index (Apps is written only under the carry), so over one the carry had nothing to carry from: the
// package's _meta and its manifest.tsv line left the head while its deferred APKs stayed, and every later seal kept
// it lost. roamd now writes that package's flag-off dormant shape (<pkg>/, its _meta, a line naming no APK) into a
// side directory, and this adopts one exactly when the agent's own reading of the stored index cannot carry it.
//
// THE STORED INDEX WINS. A package oldApps names is skipped: the carry re-emits its stored line, _meta and APKs
// together, which is NWP-20261119-02's rule that a _meta is never sealed beside APK bytes it does not describe. A
// package the drop set deletes is skipped (a deliberate removal), and so is one this handset staged.
//
// An error adopts nothing: the moved directories are put back and the index is left as it was. The error holds no
// path, because the caller logs it and roam.log outlives every wipe. Sorted, so a log and a test read the same.
func adoptDormantApps(src, dormant string, oldApps map[string]string, drop map[string]bool) (adopted []string, err error) {
	lines := appManifestLines(dormant)
	staged := appManifestLines(src)
	var pkgs []string
	for pkg := range lines {
		if pkg == "." || pkg == ".." || oldApps[pkg] != "" {
			continue
		}
		if dropPkgForFileRel(pkg+"/base.apk", drop) {
			continue
		}
		if _, dup := staged[pkg]; dup {
			continue
		}
		if _, serr := os.Lstat(filepath.Join(src, pkg)); serr == nil {
			continue // staged by this handset -> the walk owns it
		}
		if fi, lerr := os.Lstat(filepath.Join(dormant, pkg)); lerr != nil || !fi.IsDir() {
			continue
		}
		pkgs = append(pkgs, pkg)
	}
	if len(pkgs) == 0 {
		return nil, nil
	}
	sort.Strings(pkgs)
	// bareErr strips the path an os error carries, so the caller's log line cannot name a package.
	bareErr := func(err error) error {
		var pe *os.PathError
		if errors.As(err, &pe) {
			return pe.Err
		}
		var le *os.LinkError
		if errors.As(err, &le) {
			return le.Err
		}
		return err
	}
	undo := func(n int) {
		for _, pkg := range pkgs[:n] {
			os.Rename(filepath.Join(src, pkg), filepath.Join(dormant, pkg))
		}
	}
	for i, pkg := range pkgs {
		if rerr := os.Rename(filepath.Join(dormant, pkg), filepath.Join(src, pkg)); rerr != nil {
			undo(i)
			return nil, bareErr(rerr)
		}
	}
	keepOrder := make([]string, 0, len(staged))
	for pkg := range staged {
		keepOrder = append(keepOrder, pkg)
	}
	sort.Strings(keepOrder)
	out := make([]string, 0, len(staged)+len(pkgs))
	for _, pkg := range keepOrder {
		out = append(out, staged[pkg])
	}
	for _, pkg := range pkgs {
		out = append(out, lines[pkg])
	}
	p := filepath.Join(src, appManifestRel)
	tmp := p + ".tmp"
	if werr := os.WriteFile(tmp, []byte(strings.Join(out, "\n")+"\n"), 0o600); werr != nil {
		os.Remove(tmp)
		undo(len(pkgs))
		return nil, bareErr(werr)
	}
	if rerr := os.Rename(tmp, p); rerr != nil {
		os.Remove(tmp)
		undo(len(pkgs))
		return nil, bareErr(rerr)
	}
	return pkgs, nil
}
