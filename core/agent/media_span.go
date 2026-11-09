package main

// NWP-20260908-21: reading ONE file back out of a sealed essential set.
//
// chunkManifest.Ess maps a rel to a half-open span of Chunks, and until now every reader of that index was on
// the PUBLISH side -- the carry re-emits a span by hash, the tombstone filter tests eligibility, the shrink
// guard counts. Nothing ever fetched from one. This is that reader, and it is what makes a mid-session
// materialize possible at all: the alternative is the login restore, which streams the WHOLE scope and opens
// every entry O_TRUNC (untarFrom), so re-running it mid-session would overwrite whatever this session did.
//
// The span is a self-contained tar fragment because the Ess index is only written under the essential-index
// flags and those force sealFileThreshold() to 0 -- one region per file, starting on a header boundary. That
// is an assumption, not a guarantee of the format, so it is pinned by TestEssSpan_IsASelfContainedTarFragment
// rather than trusted.

import (
	"archive/tar"
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// fetchEssSpan returns the raw tar fragment for one Ess region: the region's chunks, fetched, unsealed and
// decompressed, concatenated in order. It does NOT parse the tar -- the caller decides what to do with the
// entry, and keeping the fetch separate from the write is what lets the write refuse to clobber.
//
// Errors rather than panics: getChunk panics on a corrupt blob (correctly -- at login that is fatal and the
// user must know), but a mid-session sync is BEST EFFORT by design. One unreadable rel must cost that rel and
// nothing else; the session keeps running and the next cycle tries again.
func fetchEssSpan(base string, key []byte, m chunkManifest, r essRegion) (frag []byte, err error) {
	if r.S < 0 || r.E > len(m.Chunks) || r.E <= r.S {
		return nil, fmt.Errorf("span [%d,%d) is not backed by the head's %d chunk(s)", r.S, r.E, len(m.Chunks))
	}
	defer func() {
		if p := recover(); p != nil {
			frag, err = nil, fmt.Errorf("fetch span [%d,%d): %v", r.S, r.E, p)
		}
	}()
	var buf bytes.Buffer
	buf.Grow(int(r.Size) + 1024) // the entry plus its 512-byte header and padding
	for i := r.S; i < r.E; i++ {
		b := unseal(key, getChunk(base, m.Chunks[i]))
		b, derr := unpackChunk(b, m.Version)
		if derr != nil {
			return nil, fmt.Errorf("decompress chunk %d of span [%d,%d): %w", i, r.S, r.E, derr)
		}
		buf.Write(b)
	}
	return buf.Bytes(), nil
}

// materializeCarried brings another handset's new media into THIS session, instead of at the next login.
//
// It runs AFTER the head is published, on exactly the rels the carry selected -- "in the account head, never
// in this session's login roster, absent locally". The carry already re-emitted those spans by hash, so the
// account head is correct either way; this only decides whether the bytes are on the phone now or after a
// sign-out and back in, which Chester's answer to that suggestion was that it "is mostly not going to be an
// option".
//
// ⚠ WHY NOT JUST RE-RUN THE LOGIN RESTORE. untarFrom opens every entry O_TRUNC, so re-running a scope restore
// mid-session would overwrite whatever this session did with the copy the head happens to hold. Per-rel is
// not an optimization here, it is the only safe shape -- and it is why fetchEssSpan had to exist.
//
// BEST EFFORT, ALWAYS. A failure costs that one rel and nothing else: the head is already committed, the file
// stays in it, and the next cycle tries again. Nothing here can fail a seal or a logoff.
func materializeCarried(base string, key []byte, m chunkManifest, rels []string, dest string) ([]string, int64) {
	var wrote []string
	var total int64
	waiting := 0
	defer func() { reportAppExtWaiting(waiting) }()
	for _, rel := range rels {
		if rel == "" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "..") {
			continue // a rel out of our own manifest, but the write is the wrong place to start trusting it
		}
		r, ok := m.Ess[rel]
		if !ok {
			continue
		}
		target := filepath.Join(dest, filepath.FromSlash(rel))
		if _, err := os.Lstat(target); err == nil {
			continue // present already: never clobber what this session has
		}
		if _, _, _, _, err := appExtOwner(dest, target); errors.Is(err, errAppExtNotHere) {
			waiting++ // NWP-20261011-47: no package dir to own it; it lands at the next login
			continue
		}
		frag, err := fetchEssSpan(base, key, m, r)
		if err != nil {
			fmt.Printf("  media-sync: %q SKIPPED (%v)\n", rel, errCode(err))
			continue
		}
		hdr, data, err := oneTarEntry(frag)
		if err != nil {
			fmt.Printf("  media-sync: %q SKIPPED (%v)\n", rel, errCode(err))
			continue
		}
		if filepath.ToSlash(hdr.Name) != rel {
			// The index pointed at another file. Writing it would put one handset's photo at another's path.
			fmt.Printf("  media-sync: %q SKIPPED (its span holds %q)\n", rel, hdr.Name)
			continue
		}
		if err := writeMaterialized(target, dest, hdr, data); err != nil {
			if errors.Is(err, errAppExtNotHere) {
				waiting++ // the package dir went away between the check above and the write
				continue
			}
			fmt.Printf("  media-sync: %q SKIPPED (%v)\n", rel, errCode(err))
			continue
		}
		wrote = append(wrote, target)
		total += int64(len(data))
	}
	return wrote, total
}

// reportAppExtWaiting is the one line a materialize pass prints for the app-external rels it left for the next
// login (NWP-20261011-47). A count only: a rel under Android/data names a package, and which apps a profile
// holds is not something this log gets to list (the #39 roster shape).
func reportAppExtWaiting(n int) {
	if n > 0 {
		fmt.Printf("  media-sync: %d app-specific file(s) wait for the next login (app not installed here)\n", n)
	}
}

// oneTarEntry reads the single entry an Ess span holds. A span that carries no entry, or more than one, means
// the per-file alignment assumption has broken -- pinned by TestEssSpan_IsASelfContainedTarFragment -- so say
// so rather than write half of something.
func oneTarEntry(frag []byte) (*tar.Header, []byte, error) {
	tr := tar.NewReader(bytes.NewReader(frag))
	hdr, err := tr.Next()
	if err != nil {
		return nil, nil, fmt.Errorf("span is not a tar fragment: %w", err)
	}
	if hdr.Typeflag != tar.TypeReg {
		return nil, nil, fmt.Errorf("span entry %q is not a regular file", hdr.Name)
	}
	data, err := io.ReadAll(tr)
	if err != nil {
		return nil, nil, fmt.Errorf("read span entry %q: %w", hdr.Name, err)
	}
	if int64(len(data)) != hdr.Size {
		return nil, nil, fmt.Errorf("span entry %q is short: %d of %d bytes", hdr.Name, len(data), hdr.Size)
	}
	return hdr, data, nil
}

// writeMaterialized lands one file: temp-then-rename so a reader never sees a partial photo, the recorded mode
// and mtime, and the OWNERSHIP OF ITS PARENT DIRECTORY.
//
// ⚠ THE OWNERSHIP IS PER-FILE ON PURPOSE. roamd fixes the tree after a LOGIN restore with remap_tree, a
// `chown -R` over /data/media/$uid -- and mid-session that is not available: mediad has overlays mounted by
// then, a chown of a deferred stub is a SETATTR that mediad answers by fetching the whole file from the store
// (NWP-20260908-19), and `restorecon -R -D` fails outright on a mounted directory with ENOTSUP. So the write
// carries its own ownership and touches nothing else. The SELinux label needs no help: a file created in the
// media tree inherits its parent's type, which is what the walk and MediaProvider both expect.
//
// ⚠ EXCEPT AN APP'S OWN EXTERNAL DATA (NWP-20261011-47). Android/{data,obb}/<pkg> is app-owned
// (appUid:ext_data_rw / appUid:ext_obb_rw), not media_rw, and the pass-through DAC-checks the owner -- so a
// file landed there with the root's owner, under a directory this code created root-owned, locks the app out
// of its own files until the next login's reown_ext_appdata (roamd) puts the subtree back. Such a rel takes
// its owner from the package dir already on this handset, for the file AND every directory created beneath
// it. With no package dir here there is no owner to take: errAppExtNotHere, nothing written, and the file
// lands at the next login restore, where reown_ext_appdata owns it once the app is installed.
//
// ⚠ NO LINK ON THE WAY (NWP-20261110-05). The write runs as root into whatever directory the path resolves to,
// so a symlink an app planted at a level below the scope root would redirect it anywhere the daemon may write.
// noLinkBelow refuses before anything is created and again before the temp file is. root == "" skips the walk
// (media_sync_test.go's empty_root_is_never_looked_up pins that such a write lands); both production callers
// pass the scope root.
func writeMaterialized(target, root string, hdr *tar.Header, data []byte) error {
	return writeMaterializedVia(target, root, hdr, data, os.Rename)
}

// writeMaterializedVia is writeMaterialized with its last step passed in: finalize moves the finished temp to target.
// The lander passes renameNoReplace (media_lander.go). A finalize error leaves no temp, through the deferred Remove.
func writeMaterializedVia(target, root string, hdr *tar.Header, data []byte, finalize func(tmp, target string) error) error {
	dir := filepath.Dir(target)
	if root != "" {
		if err := noLinkBelow(root, dir); err != nil {
			return err
		}
	}
	pkgDir, uid, gid, appExt, err := appExtOwner(root, target)
	if err != nil {
		return err
	}
	if appExt {
		if err := mkdirOwnedBelow(pkgDir, dir, uid, gid); err != nil {
			return err
		}
	} else if err := os.MkdirAll(dir, 0o770); err != nil {
		return err
	}
	if root != "" {
		// A link raced in between the walk above and the creation: caught before CreateTemp.
		if err := noLinkBelow(root, dir); err != nil {
			return err
		}
	}
	mode := os.FileMode(hdr.Mode) & os.ModePerm
	if mode == 0 {
		mode = 0o660
	}
	tmp, err := os.CreateTemp(dir, ".nwsync-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once the rename succeeds
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return err
	}
	// ⚠ OWNERSHIP COMES FROM THE SCOPE ROOT, NOT THE PARENT DIRECTORY. That is what roamd's remap_tree does
	// after a login restore -- "re-own the whole restored tree to the uid:gid Android gave DIR itself" -- and
	// the first device run showed why the parent is the wrong source: the landed screenshot came out
	// uid=0 gid=1023, root-owned, because its own directory had been created by this same code path and had
	// nothing better to inherit. It worked (MediaProvider decoded it) but it is not what a real photo looks
	// like, and the pass-through DAC-checks the OWNER. Falling back to the parent keeps the old behaviour if
	// the root cannot be stat'd, which through a live FUSE overlay is possible.
	if appExt {
		// Not best effort here: a file the app cannot read is the failure this branch exists to prevent.
		if err := materializeChown(tmpName, uid, gid); err != nil {
			return err
		}
	} else {
		ok := false
		if root != "" {
			uid, gid, ok = materializeOwnerOf(root)
		}
		if !ok {
			uid, gid, ok = materializeOwnerOf(dir)
		}
		if ok {
			_ = materializeChown(tmpName, uid, gid)
		}
	}
	if !hdr.ModTime.IsZero() {
		_ = os.Chtimes(tmpName, hdr.ModTime, hdr.ModTime)
	}
	return finalize(tmpName, target)
}

// errLinkOnPath and errNotDirOnPath: noLinkBelow's refusals. Their text names no path (a rel under Android/data
// names the package), so errCode prints them as they are.
var (
	errLinkOnPath     = errors.New("a link sits on the path")
	errNotDirOnPath   = errors.New("a non-directory sits on the path")
	errDirOutsideRoot = errors.New("the target dir is not beneath its scope root")
)

// noLinkBelow walks every component from root (exclusive) to dir (inclusive) with Lstat and refuses a symlink
// (errLinkOnPath) or an existing component that is not a directory (errNotDirOnPath). A missing component ends
// the walk: the caller creates it next. A dir outside root is errDirOutsideRoot.
//
// THE THREAT: another handset's file is landed as root, and an app that owns a directory below the scope root
// can replace a level with a symlink to somewhere the daemon's domain may write (e.g. /data/nowhere); Stat,
// MkdirAll and Rename all follow it. Found by reading the code, not seen on a device. Same refusal as
// media_heal.go healMkdirs ("a link sits on the path") and ingest_handoff.go ingestStagingDirOK, which Lstats
// every component for the same reason.
func noLinkBelow(root, dir string) error {
	rel, err := filepath.Rel(root, dir)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return errDirOutsideRoot
	}
	if rel == "." {
		return nil
	}
	p := root
	for _, seg := range strings.Split(rel, string(filepath.Separator)) {
		p = filepath.Join(p, seg)
		st, err := os.Lstat(p)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return errLinkOnPath
		}
		if !st.IsDir() {
			return errNotDirOnPath
		}
	}
	return nil
}

// errAppExtNotHere: the rel is an app's own external data and that app's package dir is not on this handset.
// The callers count it and say so once, without the rel: a rel under Android/data names the package.
var errAppExtNotHere = errors.New("the app's external data dir is not on this handset")

// materializeChown and materializeOwnerOf are seams for the tests, which cannot chown a fixture apart from its
// scope root without root and so could not otherwise tell whose owner a landed file took.
var materializeChown = os.Chown

var materializeOwnerOf = func(path string) (uid, gid int, ok bool) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, 0, false
	}
	sys, isSys := st.Sys().(*syscall.Stat_t)
	if !isSys {
		return 0, 0, false
	}
	return int(sys.Uid), int(sys.Gid), true
}

// appExtOwnerDir returns the package dir an app's EXTERNAL private data rel lives under --
// root/Android/data/<pkg> or root/Android/obb/<pkg>, the two trees reown_ext_appdata re-owns to the app -- and
// false for any other rel. Android/media is not one of them: it is the user's MediaStore-indexed content and
// stays on the scope root's owner, as roamd leaves it. Same prefix parsing as pinnedApp.
func appExtOwnerDir(root, rel string) (dir string, isAppExt bool) {
	rel = strings.TrimPrefix(filepath.ToSlash(rel), "/")
	for _, kind := range []string{"data", "obb"} {
		pfx := "Android/" + kind + "/"
		if !strings.HasPrefix(rel, pfx) {
			continue
		}
		rest := rel[len(pfx):]
		i := strings.IndexByte(rest, '/')
		if i <= 0 || rest[:i] == "." || rest[:i] == ".." {
			return "", false // no package segment: a file directly in Android/data is nobody's private data
		}
		return filepath.Join(root, "Android", kind, rest[:i]), true
	}
	return "", false
}

// appExtOwner resolves whose a landed target is when it is app-external data: the package dir and its owner.
// errAppExtNotHere when that dir cannot be stat'd -- in practice because the app is not installed here; either
// way there is no owner to give the file, and writing it media_rw-owned is the lock-out this exists to prevent. The callers also run it
// BEFORE fetching, so a rel that cannot land does not cost a download every cycle.
func appExtOwner(root, target string) (pkgDir string, uid, gid int, appExt bool, err error) {
	if root == "" {
		return "", 0, 0, false, nil
	}
	rel, rerr := filepath.Rel(root, target)
	if rerr != nil {
		return "", 0, 0, false, nil
	}
	if pkgDir, appExt = appExtOwnerDir(root, rel); !appExt {
		return "", 0, 0, false, nil
	}
	uid, gid, ok := materializeOwnerOf(pkgDir)
	if !ok {
		return "", 0, 0, true, errAppExtNotHere
	}
	return pkgDir, uid, gid, true, nil
}

// mkdirOwnedBelow creates dir one level at a time beneath pkgDir and gives each directory IT created the
// package's owner; one that already exists is left exactly as it is. MkdirAll cannot do this: it does not say
// which levels it made, and a dir that was already here has whatever owner the login gave it.
func mkdirOwnedBelow(pkgDir, dir string, uid, gid int) error {
	rel, err := filepath.Rel(pkgDir, dir)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return errors.New("the target dir is not beneath its package dir")
	}
	if rel == "." {
		return nil
	}
	p := pkgDir
	for _, seg := range strings.Split(rel, string(filepath.Separator)) {
		p = filepath.Join(p, seg)
		if err := os.Mkdir(p, 0o770); err != nil {
			// Lstat, not Stat: a level that exists as a link is a refusal, not "already here".
			if st, serr := os.Lstat(p); serr == nil && st.IsDir() {
				continue // already here: not ours to re-own
			}
			return err
		}
		if err := materializeChown(p, uid, gid); err != nil {
			// A root-owned dir would lock the app out of everything later landed beneath it, and the next cycle
			// would find it present and leave it. Take it back out rather than leave that behind.
			_ = os.Remove(p)
			return err
		}
	}
	return nil
}

// writeMediaSyncList hands the freshly-landed paths to roamd, which is the only side that can make them
// VISIBLE: bytes on disk are not in MediaStore, and nothing in this tree ever triggered a media scan --
// what makes a LOGIN work is the volume mount at user start, and there is no mid-session equivalent
// (NWP-20260908-18). The agent cannot do it itself: the scan has to be issued as the roamed user.
//
// A file rather than stdout, because roamd already reads the agent through files and parsing a log line for
// a filesystem path is how a space in a filename becomes a bug.
func writeMediaSyncList(paths []string) {
	out := strings.TrimSpace(os.Getenv("NOWHERE_MEDIA_SYNC_OUT"))
	if out == "" || len(paths) == 0 {
		return
	}
	_ = os.MkdirAll(filepath.Dir(out), 0o700)
	_ = os.WriteFile(out, []byte(strings.Join(paths, "\n")+"\n"), 0o600)
}
