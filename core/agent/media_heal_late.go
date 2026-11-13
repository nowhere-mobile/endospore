package main

// NWP-20261202-17: the vault heal of unkept apps, after landing.
//
// docs/product-decisions.md 2026-10-26, #2: a sign-in waits only for what must be on the phone when the user
// lands, and the vault heal may run after landing. With NOWHERE_HEAL_AFTER_LANDING=1 (roamd `in`) restoreHeal
// leaves the vault entries of every app NOT in the keep set deferred ("after landing", media_heal.go), and this
// file lands them from mediad once the overlays are up. Until a file lands, mediad serves it on demand, as it
// serves every deferred file.
//
// What stays in the sign-in, and why:
//   - #de: mediad does not serve it, so an entry left for later would be a file its app cannot read.
//   - a kept app's vault entries: hold_ondemand parks a kept app's data, in any mode, before any install. A file
//     landed here would go into the app's placeholder skeleton instead of parking with its data, so this pass
//     also skips an app that is in the keep file or has a hold dir ("parked").
//
// The carry. A late rel is not on the heal list, so a seal before it lands carries it with its chunks. A landed
// rel is a real file the walk seals essential, and its tombstone -- written only after the rename -- drops the
// deferred entry. A seal can walk the dir BEFORE the rename and read the tombstone AFTER it: the walk did not see
// the file, and the tombstone alone would drop the entry, so the file would be in neither half of the head. So
// the landing records the rel in <cacheDir>/.landed before its tombstone, and the carry (pushProfile) keeps the
// deferred entry of a landed, tombstoned rel the walk did not see while the file is on disk (mediaLateLanded).
// Each failure leaves the stub served and carried, so a restarted mediad re-runs this pass for what is left
// (isDeleted skips what already landed).
//
// An app that unlinks the stub while a copy is made: the final tombstone check, the rename and the tombstone run
// under s.landMu, and Unlink of a stub takes the same lock, so a successful unlink is never undone.

import (
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// healLateRename lands a temp file without replacing a real one; a seam for tests.
var healLateRename = renameNoReplace

// healLateResult is one pass's count: landed files and bytes, the files left deferred, and why (the reasons map
// also counts "exists", a rel the app wrote first, which is handled and not left).
type healLateResult struct {
	landed  int
	bytes   int64
	left    int
	reasons map[string]int
}

// healLate lands the vault's deferred files of unkept apps into their real dirs (undersByDir), one at a time.
// It returns at once for a scope that still defers (#media): those entries are the on-demand split itself.
func (s *mediaServer) healLate(scope, userDir string, undersByDir map[string]string) healLateResult {
	res := healLateResult{reasons: map[string]int{}}
	if scopeDefersMedia(scope) {
		return res
	}
	start := time.Now()
	keep := map[string]string{}
	keepUnreadable := false
	b, err := os.ReadFile(filepath.Join(userDir, chooserPkg, "files", "nowhere-appkeep"))
	switch {
	case err == nil:
		keep = parseKeepModes(b)
	case !errors.Is(err, os.ErrNotExist):
		keepUnreadable = true // cannot tell which apps are parked: land none
	}
	rels := make([]string, 0, len(s.deferred))
	for rel := range s.deferred {
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	skip := func(why string) {
		res.left++
		res.reasons[why]++
	}
	reserve := healReserve()
	ctx := map[string]string{}
	for _, rel := range rels {
		d := s.deferred[rel]
		if d.Size <= 0 || len(d.Chunks) == 0 {
			skip("empty")
			continue
		}
		if isMediaCachePath(rel) || isAppCodeStagePath(rel) || strings.Contains(rel, "/"+odHoldDirName+"/") {
			skip("never-restored class")
			continue
		}
		if s.isDeleted(rel) {
			skip("deleted")
			continue
		}
		hidden, ok := undersByDir[path.Dir(rel)]
		if !ok {
			skip("no overlay")
			continue
		}
		pkg, _, hasDir := strings.Cut(rel, "/")
		if hasDir && healLateParked(userDir, pkg, keep, keepUnreadable) {
			skip("parked")
			continue
		}
		pkgDir := filepath.Join(userDir, pkg)
		if fi, err := os.Lstat(pkgDir); !hasDir || pkg == "" || err != nil || !fi.IsDir() {
			skip("no package dir")
			continue
		}
		if free, err := healFreeBytes(hidden); err != nil || free-2*d.Size < reserve {
			skip("space") // the cache copy and the landed copy
			continue
		}
		switch why := s.healLateLand(rel, d, hidden, pkgDir, ctx); why {
		case "":
			res.landed++
			res.bytes += d.Size
		case "exists":
			res.reasons[why]++
		default:
			skip(why)
		}
	}
	dlog("mediad: vault heal after landing: landed %d (%d B), left %d %v [%dms] (NWP-20261202-17)",
		res.landed, res.bytes, res.left, res.reasons, time.Since(start).Milliseconds())
	return res
}

// healLateParked reports whether hold_ondemand parks (or may park) this app's data: it is in the keep file, it
// has a hold dir, or the keep file cannot be read. Never land into a placeholder skeleton.
func healLateParked(userDir, pkg string, keep map[string]string, keepUnreadable bool) bool {
	if keepUnreadable {
		return true
	}
	if _, kept := keep[pkg]; kept {
		return true
	}
	_, err := os.Lstat(filepath.Join(userDir, chooserPkg, odHoldDirName, pkg))
	return err == nil
}

// healLateLand lands one file: fetch, a temp file in the real dir, the size, the recorded mode, the package
// dir's owner, the recorded mtime, the dir's MCS level, a rename that never replaces, then the tombstone.
// Returns "" when landed, "exists" when a real file was there first (tombstoned, temp removed), else the reason
// the file stays deferred. Every path that does not land removes the temp.
func (s *mediaServer) healLateLand(rel string, d deferredFile, hidden, pkgDir string, ctx map[string]string) string {
	cp, err := s.fetchFile(rel)
	if err != nil {
		return "fetch"
	}
	src, err := os.Open(cp)
	if err != nil {
		return "fetch"
	}
	defer src.Close()
	tmp, err := os.CreateTemp(hidden, ".nwseed-*")
	if err != nil {
		return "write"
	}
	tmpName := tmp.Name()
	landed := false
	defer func() {
		if !landed {
			os.Remove(tmpName)
		}
	}()
	n, err := io.Copy(tmp, src)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "write"
	}
	if n != d.Size {
		return "fetch"
	}
	if perm := os.FileMode(d.Mode).Perm(); perm != 0 {
		if err := os.Chmod(tmpName, perm); err != nil {
			return "write"
		}
	}
	// Not best effort: a file mediad owns, in an app's private dir, locks the app out of its own file.
	uid, gid, ok := materializeOwnerOf(pkgDir)
	if !ok {
		return "owner"
	}
	if err := materializeChown(tmpName, uid, gid); err != nil {
		return "owner"
	}
	if mt := deferredMTimeNanos(d.MTime); mt != 0 {
		t := time.Unix(0, mt)
		_ = os.Chtimes(tmpName, t, t) // best effort, as in materialize: a failure costs a re-upload, never data
	}
	inheritSELinuxLevel(tmpName, hidden, ctx)
	dst := filepath.Join(hidden, path.Base(rel))
	s.landMu.Lock()
	defer s.landMu.Unlock()
	if s.isDeleted(rel) {
		return "deleted" // the app unlinked or replaced the stub while the copy was made: its choice stands
	}
	if err := healLateRename(tmpName, dst); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return "rename"
		}
		// A real file is the truth: the app wrote it first. Drop the stub, keep the file.
		if err := s.markDeleted(rel); err != nil {
			s.unmarkDeleted(rel)
			return "tombstone"
		}
		return "exists"
	}
	landed = true
	// Before the tombstone: a seal that reads the tombstone after its walk also finds this line (mediaLateLanded).
	if err := s.appendLanded(rel); err != nil {
		os.Remove(dst)
		return "landed record"
	}
	if err := s.markDeleted(rel); err != nil {
		// The seal reads only the file: without the line it would carry the stub over a real file. Take the
		// landed copy back so the stub stays the one truth this session.
		os.Remove(dst)
		s.unmarkDeleted(rel)
		return "tombstone"
	}
	return ""
}

// lateLandedName is the file in the CE cache dir where healLateLand records each rel it landed, one per line.
const lateLandedName = ".landed"

// appendLanded appends rel+"\n" to <cacheDir>/.landed, first ending a torn last line (as appendTombstone does).
func (s *mediaServer) appendLanded(rel string) error {
	s.tombMu.Lock()
	defer s.tombMu.Unlock()
	f, err := os.OpenFile(filepath.Join(s.cacheDir, lateLandedName), os.O_APPEND|os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	line := rel + "\n"
	st, err := f.Stat()
	if err == nil && st.Size() > 0 {
		var b [1]byte
		if _, err = f.ReadAt(b[:], st.Size()-1); err == nil && b[0] != '\n' {
			line = "\n" + line
		}
	}
	if err == nil {
		var n int
		if n, err = f.Write([]byte(line)); err == nil && n != len(line) {
			err = io.ErrShortWrite
		}
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// mediaLateLanded returns the rels the late heal landed in the CE scope sealed from src, for the carry. The
// carry must read it AFTER mediaTombstones: the line is written before the tombstone, so a tombstone the carry
// saw always has its line here. Missing -> empty.
func mediaLateLanded(src string) map[string]bool {
	out := map[string]bool{}
	b, err := os.ReadFile(src + "/" + mediaCacheRel + "/" + lateLandedName)
	if err != nil {
		return out
	}
	for _, ln := range strings.Split(string(b), "\n") {
		if ln != "" {
			out[ln] = true
		}
	}
	return out
}

// lateLandedUnwalked reports whether the carry must keep a tombstoned deferred entry: the late heal landed it,
// the walk did not see it (it walked the dir before the rename), and the file is on disk now (the app has not
// deleted it). Its deferred chunks are the landed file's bytes, so the head keeps them in that one form; the next
// seal walks the file and seals it essential.
func lateLandedUnwalked(src, rel string, landed, seen map[string]bool) bool {
	if !landed[rel] || seen[rel] {
		return false
	}
	fi, err := os.Lstat(filepath.Join(src, filepath.FromSlash(rel)))
	return err == nil && fi.Mode().IsRegular()
}
