package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// #84 P3b -- the go-fuse adapter over mediaServer (P3a): a mountable, read-only overlay per deferred-media dir.
//
// A deferred dir (e.g. app.organicmaps/files/maps) can hold BOTH the big deferred maps (not restored at login)
// AND small essential siblings (restored). So the overlay can't just present the deferred files -- mounting
// over the dir would hide the real siblings. mediaRoot embeds go-fuse's LoopbackNode (which passes the real
// dir through -- siblings, subdirs, everything) and only OVERRIDES lookup/readdir to inject the deferred files,
// which materialize from the store on first open (mediaServer.fetchFile) and then serve from the local cache.
//
// The mount labels like stock /storage (genfscon fuse; no context= option -- see mediaMountOptions for why a
// fixed mount context made file CREATE impossible for every app, NWP-20260901-01); DAC uid (set from the
// app's real dir) still isolates. The low-level FUSE + the Android CANONICAL_PATH patch live in the vendored
// go-fuse (P3e). See docs/on-demand-media.md.

// mediaRoot is the root inode of one overlay mount: a real directory (loopback-passthrough) with the deferred
// files of that dir injected as extra entries.
type mediaRoot struct {
	fs.LoopbackNode // passthrough of the underlying (bind-hidden) real dir: siblings, subdirs, attrs, reads

	srv      *mediaServer
	dir      string          // THIS NODE's rel dir under the user root, e.g. "app.organicmaps/files/maps"
	names    []string        // deferred basenames in this dir (sorted)
	deferSet map[string]bool // names, as a set, for O(1) lookup
	uid, gid uint32          // the owning app uid/gid to present for the injected files (DAC)

	// byDir is the WHOLE mount's deferred index, rel dir -> basenames, SHARED by every node of this mount.
	// NWP-20260829-08: one overlay now serves a subtree, not a single dir. NWP-20260829-07 collapsed the
	// mount set to maximal ancestors because a nested child overlay could never work -- but the ancestor
	// then served its nested dirs as PLAIN PASSTHROUGH, so a deferred file inside one got no stub and was
	// invisible and unfetchable. This is the other half: a child DIRECTORY node is itself a *mediaRoot
	// carrying its own dir, so `names`/`deferSet` are simply byDir[dir] at every depth.
	//
	// A dir absent from byDir yields an empty set and the node behaves exactly as a LoopbackNode does.
	byDir map[string][]string
}

// realPath is the underlying real path of THIS node -- RootData.Path is the mount root's hidden bind, which
// is only the answer for the root node itself.
//
// ⚠ THE SHARP EDGE OF THIS SLICE. Three sites used RootData.Path directly on the assumption that the node IS
// the mount root, which was true while an overlay covered exactly one dir. Missing one now would put a
// nested write-back or materialize in the MOUNT ROOT instead of beside its siblings: not a crash, a quiet
// misplacement that the next seal then records as the file's real location.
func (r *mediaRoot) realPath() string {
	return filepath.Join(r.RootData.Path, r.Path(r.RootData.RootNode.EmbeddedInode()))
}

var (
	_ = (fs.NodeOpendirHandler)((*mediaRoot)(nil))
	_ = (fs.NodeLookuper)((*mediaRoot)(nil))
	_ = (fs.NodeUnlinker)((*mediaRoot)(nil)) // #84 deletion: unlink a deferred stub
	_ = (fs.NodeCreater)((*mediaRoot)(nil))  // #84 write-back: create a new/updated file (real bytes -> .under)
	_ = (fs.NodeRenamer)((*mediaRoot)(nil))  // #84 write-back: rename a temp over a stub (OM's atomic update)
	_ = (fs.NodeGetattrer)((*mediaFile)(nil))
	_ = (fs.NodeSetattrer)((*mediaFile)(nil)) // #84 write-back: an O_TRUNC/ftruncate materializes the stub
	_ = (fs.NodeOpener)((*mediaFile)(nil))
)

// OpendirHandle lists the real dir (passthrough) plus the injected deferred basenames. We override the HANDLE,
// not Readdir: go-fuse's bridge dispatches directory reads to a node's OpendirHandle when it has one, and the
// embedded LoopbackNode provides one (listing only the underlying dir) -- so a plain Readdir override would be
// bypassed. NewListDirStream's result already implements Readdirent, so it is itself a valid dir handle. The
// deferred files aren't on disk (not restored at login), so there's normally no overlap; dup-skip defensively.
func (r *mediaRoot) OpendirHandle(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	ents := make([]fuse.DirEntry, 0, len(r.names)+8)
	if des, err := os.ReadDir(r.realPath()); err == nil { // NWP-20260829-08: THIS node, not the mount root
		for _, de := range des {
			// A deferred name is injected below as a stub -- UNLESS it was superseded: an app UNLINKed it, or a
			// WRITE-BACK replaced it with a real file in the passthrough dir (#84). Once superseded (isDeleted),
			// list the REAL file here instead of the vanished stub.
			if r.deferSet[de.Name()] && !r.srv.isDeleted(path.Join(r.dir, de.Name())) {
				continue
			}
			mode := uint32(fuse.S_IFREG)
			if de.IsDir() {
				mode = fuse.S_IFDIR
			}
			ents = append(ents, fuse.DirEntry{Name: de.Name(), Mode: mode})
		}
	}
	for _, n := range r.names {
		if r.srv.isDeleted(path.Join(r.dir, n)) {
			continue // #84 deletion: the app unlinked this deferred file -> don't list it
		}
		ents = append(ents, fuse.DirEntry{Name: n, Mode: fuse.S_IFREG})
	}
	return fs.NewListDirStream(ents), 0, 0
}

// Lookup serves a deferred file from the store; everything else falls through to the loopback (real siblings,
// subdirs). Injected here (not on disk) so getattr answers the manifest size/mode without a fetch.
func (r *mediaRoot) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	if r.deferSet[name] {
		rel := path.Join(r.dir, name)
		// #84 deletion: an unlinked deferred file is gone -> fall through to the loopback (which sees no real
		// file at this name -> ENOENT, or a real file if a later write-back replaced it), never re-inject the stub.
		if !r.srv.isDeleted(rel) {
			df, ok := r.srv.attr(rel)
			if !ok {
				return nil, syscall.ENOENT
			}
			setFileAttr(&out.Attr, df, r.uid, r.gid)
			child := &mediaFile{srv: r.srv, root: r, rel: rel, df: df, uid: r.uid, gid: r.gid}
			return r.NewInode(ctx, child, fs.StableAttr{Mode: fuse.S_IFREG}), 0
		}
	}
	return r.LoopbackNode.Lookup(ctx, name, out)
}

// Unlink of a DEFERRED stub tombstones it (#84 deletion): the file stops being served/listed at once and the
// next seal drops it from Deferred (the tombstone overrides the present-not-deleted carry-forward). Enables an
// app to UPDATE a media file it owns -- e.g. Organic Maps deletes the old <region>.mwm before writing the new
// one. A real sibling (essential file, or an app write that passed through the loopback) unlinks normally.
func (r *mediaRoot) Unlink(ctx context.Context, name string) syscall.Errno {
	if r.deferSet[name] {
		// NWP-20261202-17: the late heal (media_heal_late.go) checks the tombstone, renames and tombstones under
		// this lock. So an unlink either tombstones the stub before the heal looks (the heal then lands nothing),
		// or finds the landed file and unlinks it through the loopback. Without it a deleted file came back.
		r.srv.landMu.Lock()
		defer r.srv.landMu.Unlock()
	}
	if r.deferSet[name] && !r.srv.isDeleted(path.Join(r.dir, name)) {
		rel := path.Join(r.dir, name)
		// NWP-20261127-06: a tombstone that did not reach .deleted would not reach the seal either, so the
		// unlink fails and the stub stays listed and served (the RAM tombstone is taken back).
		if err := r.srv.markDeleted(rel); err != nil {
			r.srv.unmarkDeleted(rel)
			dlog("mediad: UNLINK deferred %q failed, stub kept (tombstone not persisted): %v", rel, errCode(err))
			if errno := fs.ToErrno(err); errno != 0 {
				return errno
			}
			return syscall.EIO
		}
		dlog("mediad: UNLINK deferred %q (tombstoned; dropped at next seal)", rel)
		return 0
	}
	return r.LoopbackNode.Unlink(ctx, name)
}

// Create writes a real file into the passthrough dir (#84 write-back). A brand-new name (not a stub) just passes
// through. This is the path an app takes to write an UPDATED map (e.g. Organic Maps: delete old then create new,
// or download straight to the final name). If the name is a live deferred stub, it is SUPERSEDED only by a create
// that landed: the loopback creates the real file under .under first, and only when it returns 0 is the stub
// tombstoned, so the overlay stops serving it (isDeleted) and the seal drops the old deferred entry -- the next seal
// re-chunks the real file from the walk. The tombstone is durable (.deleted), so taking it before the op made a
// failed create delete a stub the app was told it could not replace; same class as the Rename fix
// (NWP-20261110-09), the same order here (NWP-20261127-04). Create is reached only on a NEGATIVE lookup: on Linux
// the kernel looks up first and Lookup serves a live stub, so an O_CREAT over a stub arrives as OPEN
// (openForWrite). The live arm is therefore an ordering pinned at source level (test-media-writeopen-order.sh). It
// does not use supersedeAfter, whose log line says RENAME.
func (r *mediaRoot) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	rel := path.Join(r.dir, name)
	live := r.deferSet[name] && !r.srv.isDeleted(rel)
	inode, fh, fuseFlags, errno := r.LoopbackNode.Create(ctx, name, flags, mode, out)
	if live && errno == 0 {
		r.srv.markDeleted(rel)
		dlog("mediad: CREATE over deferred %q (stub superseded by write-back)", rel)
	}
	return inode, fh, fuseFlags, errno
}

// supersedeAfter runs op and, only when op landed (returned 0) over a live deferred stub, tombstones rel so the stub
// yields to the real file (#84 write-back). A failed op takes no tombstone: the stub stays served and sealed. op's
// errno is returned unchanged.
func supersedeAfter(srv *mediaServer, rel string, live bool, op func() syscall.Errno) syscall.Errno {
	errno := op()
	if errno == 0 && live {
		srv.markDeleted(rel)
		dlog("mediad: RENAME over deferred %q (stub superseded by write-back)", rel)
	}
	return errno
}

// Rename supports OM's atomic-update pattern: a freshly-downloaded temp file is renamed OVER the old
// <region>.mwm (#84 write-back). If the destination is a live deferred stub, the stub yields ONLY to a rename that
// landed: supersedeAfter tombstones it after the loopback returns 0, so the real renamed file takes over (same
// supersession as Create). A rename that fails leaves both names as they were -- served, listed and sealed: a stub
// has no bytes in .under, so renaming one stub over another reaches the loopback as ENOENT, and the destination must
// not vanish for a rename the app was told failed. go-fuse's loopback Rename extracts the destination's embedded
// LoopbackNode and refuses a cross-root (different overlay) rename with EXDEV, so this only fires for a rename WITHIN
// one overlay dir -- OM's case.
func (r *mediaRoot) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	nr, ok := newParent.(*mediaRoot)
	if !ok {
		return r.LoopbackNode.Rename(ctx, name, newParent, newName, flags)
	}
	rel := path.Join(nr.dir, newName)
	live := nr.deferSet[newName] && !nr.srv.isDeleted(rel)
	return supersedeAfter(nr.srv, rel, live, func() syscall.Errno {
		return r.LoopbackNode.Rename(ctx, name, newParent, newName, flags)
	})
}

// mediaFile is one deferred file. getattr answers from the manifest (cheap, no fetch); a READ open materializes
// the file into the cache (mediaServer.fetchFile / range serving) and hands back a loopback fd over the cached
// copy, so reads are local. A WRITE open supersedes the stub with a real file in the passthrough dir
// (openForWrite, #84 write-back) -- as do Create/Rename on the parent dir for the atomic temp+rename pattern.
type mediaFile struct {
	fs.Inode
	srv      *mediaServer
	root     *mediaRoot // parent overlay root, for the write-back materialize path (#84)
	rel      string
	df       deferredFile
	uid, gid uint32
}

func (f *mediaFile) Getattr(ctx context.Context, fh fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	setFileAttr(&out.Attr, f.df, f.uid, f.gid)
	return 0
}

// Setattr on a deferred stub MATERIALIZES it for write-back (#84): the kernel doesn't deliver O_TRUNC atomically
// here, so an O_TRUNC open lands as an OPEN (openForWrite, which already made the real file) followed by a
// SETATTR(size=0) that would otherwise hit an unimplemented op and fail the whole open with ENOTSUP. Also covers
// an explicit ftruncate/chmod on a stub. Create the real file if it isn't there yet (empty for a truncate-to-0,
// else seeded from the store so a grow/chmod keeps existing bytes), tombstone the stub, then apply size/mode.
//
// ⚠ BUT ONLY FOR A SIZE OR A MODE (NWP-20260908-19). This used to materialize for ANY Setattr, and the one that
// carries neither is a CHOWN -- which a stub cannot persist in the first place: its owner is synthetic, filled
// from f.uid/f.gid by Getattr and overwritten with the same pair on the way out of this function. So the fetch
// bought nothing but the download. Device-proven on lynx 2026-09-08: a `chown -R` over a mounted DCIM/Camera
// pulled a 1.6 MB photo out of the store and left mediad logging the materialize by name.
//
// It is not hypothetical on the fleet. roamd's reown_ext_appdata is a `chown -R` over
// /data/media/$uid/Android/{data,obb}/<pkg>, and odrestore runs it on EVERY on-demand app tap -- exactly the
// tree overlayed for that app's deferred media -- so a tap downloaded the deferred set of the app the
// on-demand tier exists to keep light. nowhere_roamd.sh asserted the opposite ("a chown that the FUSE rejects
// is harmless"); the FUSE does not reject it, and that comment is corrected in the same slice.
func (f *mediaFile) Setattr(ctx context.Context, fh fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	if f.root == nil {
		return syscall.EROFS
	}
	underPath := filepath.Join(f.root.realPath(), path.Base(f.rel)) // NWP-20260829-08: THIS node, not the mount root
	if _, err := os.Stat(underPath); os.IsNotExist(err) {
		_, wantSize := in.GetSize()
		_, wantMode := in.GetMode()
		if !wantSize && !wantMode {
			// Ownership- or timestamp-only: nothing this node can persist, so answer from the stub and keep it
			// deferred. Falling through would fetch the whole file to service a request whose result is
			// discarded by the out.Owner assignment at the bottom of this function.
			setFileAttr(&out.Attr, f.df, f.uid, f.gid)
			return 0
		}
		if sz, ok := in.GetSize(); ok && sz == 0 {
			fd, e := syscall.Open(underPath, syscall.O_CREAT|syscall.O_WRONLY|syscall.O_TRUNC, uint32(f.df.Mode)&0o777)
			if e != nil {
				return fs.ToErrno(e)
			}
			syscall.Close(fd)
		} else {
			cp, e := f.srv.fetchFile(f.rel)
			if e != nil {
				fmt.Fprintf(os.Stderr, "mediad: setattr %q: seed fetch failed: %v\n", f.rel, errCode(e))
				return syscall.EIO
			}
			if e := copyFile(cp, underPath, os.FileMode(f.df.Mode)&os.ModePerm); e != nil {
				return fs.ToErrno(e)
			}
		}
		f.srv.markDeleted(f.rel)
		dlog("mediad: SETATTR materialized deferred stub %q for write-back", f.rel)
	}
	if sz, ok := in.GetSize(); ok {
		if e := os.Truncate(underPath, int64(sz)); e != nil {
			return fs.ToErrno(e)
		}
	}
	if m, ok := in.GetMode(); ok {
		os.Chmod(underPath, os.FileMode(m&0o777))
	}
	var st syscall.Stat_t
	if e := syscall.Stat(underPath, &st); e != nil {
		return fs.ToErrno(e)
	}
	out.FromStat(&st)
	out.Owner = fuse.Owner{Uid: f.uid, Gid: f.gid}
	return 0
}

func (f *mediaFile) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	if flags&(syscall.O_WRONLY|syscall.O_RDWR) != 0 {
		return f.openForWrite(flags) // #84 write-back: an app overwriting a deferred map in place
	}
	// #84 P4: an entry with a range map is served CHUNK-granular -- open is free, each read fetches only the
	// chunk(s) covering it (media_server.go "range-granular serving"). Whole-file-on-open remains for pre-Pz
	// entries only: OrganicMaps opens every registered map at startup, and whole-file turned that one app
	// launch into a full re-download of the deferred set every fresh session (proven on FP3 2026-07-03).
	dlogv("mediad: OPEN %q rangeable=%v size=%d chunks=%d", f.rel, f.df.rangeable(), f.df.Size, len(f.df.Chunks)) // #84 search trace (NOWHERE_MEDIA_DEBUG)
	if f.df.rangeable() {
		return &mediaRangeHandle{f: f}, fuse.FOPEN_KEEP_CACHE, 0
	}
	cp, err := f.srv.fetchFile(f.rel)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mediad: %v\n", errCode(err)) // never logs creds; the rel inside is quoted for the scrub
		return nil, 0, syscall.EIO                           // a corrupt/offline fetch -> a clean I/O error, not a hang
	}
	fd, err := syscall.Open(cp, syscall.O_RDONLY, 0)
	if err != nil {
		return nil, 0, fs.ToErrno(err)
	}
	return fs.NewLoopbackFile(fd), fuse.FOPEN_KEEP_CACHE, 0
}

// writeOpenFile is openForWrite's open(2): a test seam, never reassigned in production.
var writeOpenFile = syscall.Open

// openForWrite materializes a deferred stub the app opened for WRITE (#84 write-back): the stub is superseded by
// a REAL file in the passthrough dir. Create the real file at the underlying path, and only once it is OPEN
// tombstone the deferred entry (the overlay stops serving the stub and the seal drops it), then hand back a
// loopback fd so the app's writes land on disk and seal from the walk. The tombstone is durable (.deleted), so
// taking it before the open made a failed open (EACCES, ENOSPC on a full /data, EMFILE) delete a map the app was
// told it could not open: the next seal dropped it from Deferred. Same class as the Rename fix (NWP-20261110-09);
// fixed the same way (NWP-20261127-04). A failed open after a seed removes the seed copy this call made: a live
// stub has no bytes in .under, so nothing else is lost. An O_CREAT over a live stub reaches here too: on Linux the
// kernel looks up first and Lookup serves the stub, so the open arrives as OPEN, not CREATE. Whether the real file is first SEEDED with the deferred bytes is
// writeOpenSeeds' rule: a read-modify-write (O_RDWR) and an append (O_APPEND) keep the existing bytes, so they
// FETCH first -- and if that seed fetch fails (offline/corrupt) the open fails rather than silently truncating
// the map. An append is never a full overwrite: the kernel takes the size from the stub's Getattr and places
// every write at that offset. Residuals: (a) this mount has no CAP_ATOMIC_O_TRUNC, so the kernel strips O_TRUNC
// from every open and truncates by a follow-up SETATTR; an O_WRONLY|O_APPEND|O_TRUNC open arrives as
// O_WRONLY|O_APPEND, seeds (one fetch) and is then truncated by Setattr -- correct, only wasteful. (b) A plain
// O_WRONLY (no append) cannot be told apart from a stripped O_TRUNC open, so it still creates the file empty.
// Most apps (OrganicMaps) write atomically via temp+rename (mediaRoot.Rename) instead.
func (f *mediaFile) openForWrite(flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	if f.root == nil {
		return nil, 0, syscall.EROFS // defensive: a served stub always carries its overlay root
	}
	underPath := filepath.Join(f.root.realPath(), path.Base(f.rel)) // NWP-20260829-08: THIS node, not the mount root
	// Seed the real file with the deferred file's current bytes whenever the open keeps them (writeOpenSeeds);
	// otherwise it is a full overwrite and the file is created empty, with no fetch, so it works offline.
	seeded := false
	if writeOpenSeeds(flags) {
		cp, err := f.srv.fetchFile(f.rel)
		if err != nil {
			fmt.Fprintf(os.Stderr, "mediad: write-open %q: seed fetch failed: %v\n", f.rel, errCode(err))
			return nil, 0, syscall.EIO
		}
		if err := copyFile(cp, underPath, os.FileMode(f.df.Mode)&os.ModePerm); err != nil {
			return nil, 0, fs.ToErrno(err)
		}
		seeded = true
	}
	// FUSE supplies explicit per-write offsets, so strip O_APPEND (else the loopback fd would double-apply it).
	fd, err := writeOpenFile(underPath, int(flags)&^syscall.O_APPEND|os.O_CREATE, uint32(f.df.Mode)&0o777)
	if err != nil {
		if seeded {
			os.Remove(underPath) // this call made the seed copy; a live stub has no bytes in .under
		}
		return nil, 0, fs.ToErrno(err)
	}
	f.srv.markDeleted(f.rel) // the stub yields only to an open real file; the seal drops the deferred entry
	dlog("mediad: WRITE-OPEN %q (deferred stub materialized for write-back)", f.rel)
	return fs.NewLoopbackFile(fd), 0, 0
}

// writeOpenSeeds reports whether a write open of a deferred stub must start from the stub's current bytes: it
// does not truncate and is either a read-write open or an append.
func writeOpenSeeds(flags uint32) bool {
	if flags&syscall.O_TRUNC != 0 {
		return false
	}
	return flags&syscall.O_ACCMODE == syscall.O_RDWR || flags&syscall.O_APPEND != 0
}

// copyFile copies src -> dst with the given mode. It seeds three write-back callers, each of which writes dst into
// the overlay's backing dir (the .under bind of the app's real dir): mediaFile.Setattr (a size or mode change on a
// deferred stub), mediaFile.openForWrite (the O_RDWR / O_APPEND seed, so a partial overwrite keeps the untouched
// remainder) and mediaServer.materialize (the #108 pin pass and the #129 Tier-2 prefetch).
// NWP-20261115-03: a cut copy is a LOSS, not a retry. The stub is not tombstoned on a failure, so the app still
// reads the right bytes, but the seal does not read through the overlay: walkChunks walks .under in its place,
// finds the cut real file at the stub's rel, marks the rel seen and chunks it, and the deferred carry skips a seen
// rel. So a copy cut short (ENOSPC part way through a 700 MB map) was sealed over the stored whole file. copyFile
// now copies into a temp in dst's own directory (the same dir, so the rename stays inside the bind mount -- a
// rename across mounts is EXDEV; the short .nwseed-* prefix keeps a long name inside NAME_MAX), closes it, chmods
// it to mode (CreateTemp makes 0600) and only then renames it over dst. Any failure removes the temp and leaves
// dst exactly as it was. Same rule as healFile (media_heal.go) and writeMaterialized (media_span.go).
// Residual: a mediad killed mid-copy, or a seal that opens the temp in the instant between its close and its
// rename, can leave a .nwseed-* entry for the seal, as writeMaterialized's .nwsync-* can.
func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".nwseed-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // a no-op once the rename has landed
	if _, err := copyFileData(tmp, in); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return err
	}
	return os.Rename(tmpName, dst)
}

// copyFileData is copyFile's byte copy: a seam so a test can cut a copy part way, as ENOSPC does. Production never
// reassigns it.
var copyFileData = io.Copy

// mediaRangeHandle serves one open of a range-mapped deferred file. Each Read ensures just its byte range is
// local (ensureRange) then preads from the part/complete cache file. The fd is opened lazily on the first
// read and HELD: promotion renames part -> complete, and a rename never invalidates an open fd (same inode),
// so a long-lived reader seamlessly rides the promotion.
type mediaRangeHandle struct {
	f  *mediaFile
	mu sync.Mutex
	fd *os.File
}

var _ = (fs.FileReader)((*mediaRangeHandle)(nil))
var _ = (fs.FileReleaser)((*mediaRangeHandle)(nil))

func (h *mediaRangeHandle) Read(ctx context.Context, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	p, err := h.f.srv.ensureRange(h.f.rel, off, int64(len(dest)))
	if err != nil {
		fmt.Fprintf(os.Stderr, "mediad: %v\n", errCode(err))
		return nil, syscall.EIO // corrupt/offline fetch -> clean I/O error, not a hang
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.fd == nil {
		f, oerr := os.Open(p)
		if oerr != nil {
			return nil, fs.ToErrno(oerr)
		}
		h.fd = f
	}
	n, rerr := h.fd.ReadAt(dest, off)
	if rerr != nil && rerr != io.EOF {
		return nil, fs.ToErrno(rerr)
	}
	return fuse.ReadResultData(dest[:n]), 0
}

func (h *mediaRangeHandle) Release(ctx context.Context) syscall.Errno {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.fd != nil {
		h.fd.Close()
		h.fd = nil
	}
	return 0
}

func setFileAttr(a *fuse.Attr, df deferredFile, uid, gid uint32) {
	a.Mode = fuse.S_IFREG | (df.Mode & 0o777)
	a.Size = uint64(df.Size)
	a.Owner = fuse.Owner{Uid: uid, Gid: gid}
	a.Nlink = 1 // st_nlink 0 reads as "deleted" to some scanners
	a.Blksize = 4096
	a.Blocks = (a.Size + 511) / 512
	// deferredFile.MTime is UnixNano (walkChunks stats with ModTime().UnixNano(); the carry-forward compares
	// it against the same). fuse.Attr wants SECONDS + nsec. Feeding nanos as seconds put st_mtime around year
	// 56 billion; bionic's localtime() returns NULL on that and toybox strftime dereferences it -- so stat,
	// ls -l, and ANY app scanning the dir SEGFAULTED on an unfetched stub, making the deferred maps look
	// wiped when the data was fine in the head (proven on FP3 2026-07-03). Mirror into atime/ctime so a stub
	// stats like a normal file rather than one born in 1970.
	// NWP-20260828-18: through deferredMTimeNanos, because the web importer writes SECONDS into this field
	// while the seal writes nanos. Dividing a seconds value by 1e9 pinned every web-imported stub to 1 Jan
	// 1970 -- the opposite end of the same unit bug this comment already warns about.
	if mt := deferredMTimeNanos(df.MTime); mt > 0 {
		a.Mtime = uint64(mt / 1e9)
		a.Mtimensec = uint32(mt % 1e9)
		a.Atime, a.Atimensec = a.Mtime, a.Mtimensec
		a.Ctime, a.Ctimensec = a.Mtime, a.Mtimensec
	}
}

// newMediaRoot builds the overlay root node for `dir`, loopback-rooted at underPath (the real dir's contents,
// which on-device is a bind-hidden copy so the mount-over doesn't recurse; in tests it's just a real dir).
// newMediaRoot builds a single-dir overlay. Kept as the narrow entry point (and for the existing tests);
// newMediaOverlay is the general one that serves a whole subtree.
func newMediaRoot(srv *mediaServer, dir string, names []string, underPath string, uid, gid uint32) (*mediaRoot, error) {
	return newMediaOverlay(srv, dir, map[string][]string{dir: names}, underPath, uid, gid)
}

// newMediaOverlay builds the overlay for ONE mount that serves rootDir AND every deferred dir beneath it.
// byDir is the mount's whole deferred index (rel dir -> basenames); it is shared, never copied per node.
func newMediaOverlay(srv *mediaServer, rootDir string, byDir map[string][]string, underPath string, uid, gid uint32) (*mediaRoot, error) {
	var st syscall.Stat_t
	if err := syscall.Stat(underPath, &st); err != nil {
		return nil, err
	}
	if byDir == nil {
		byDir = map[string][]string{}
	}
	mk := func(dir string) *mediaRoot {
		names := byDir[dir]
		set := make(map[string]bool, len(names))
		for _, n := range names {
			set[n] = true
		}
		return &mediaRoot{srv: srv, dir: dir, names: names, deferSet: set, uid: uid, gid: gid, byDir: byDir}
	}
	root := mk(rootDir)
	root.LoopbackNode = fs.LoopbackNode{RootData: &fs.LoopbackRoot{Path: underPath, Dev: uint64(st.Dev)}}
	// Every child DIRECTORY becomes a mediaRoot for its own rel dir, so stubs are injected at any depth.
	// go-fuse routes all six child-construction paths (Lookup/Mkdir/Mknod/Create/Symlink/Link) through this
	// one hook, so there is no site to forget. Non-directories stay plain LoopbackNodes, exactly as before.
	root.RootData.NewNode = func(rd *fs.LoopbackRoot, parent *fs.Inode, name string, cst *syscall.Stat_t) fs.InodeEmbedder {
		if cst != nil && cst.Mode&syscall.S_IFMT == syscall.S_IFDIR {
			pd := rootDir
			if pr, ok := parent.Operations().(*mediaRoot); ok {
				pd = pr.dir
			}
			child := mk(path.Join(pd, name))
			child.LoopbackNode = fs.LoopbackNode{RootData: rd}
			return child
		}
		return &fs.LoopbackNode{RootData: rd}
	}
	root.RootData.RootNode = root
	return root, nil
}

// ensureDeferredDir recreates a missing deferred dir under userDir: every missing path component is created
// owned like its nearest EXISTING ancestor (the app's uid:gid, so the app can traverse and write siblings)
// and the topmost created component is restorecon -R'd so SELinux labels match the app-data tree (a
// root-created dir would otherwise carry the wrong context and the per-app MLS categories would be missing).
// relDir is OS-separator form, relative to userDir.
func ensureDeferredDir(userDir, relDir string) error {
	// Find the deepest existing ancestor + the topmost component we will create.
	cur := filepath.Join(userDir, relDir)
	topCreated := cur
	anc := filepath.Dir(cur)
	for {
		if _, err := os.Stat(anc); err == nil {
			break
		}
		topCreated = anc
		next := filepath.Dir(anc)
		if next == anc || len(next) <= len(userDir) {
			break
		}
		anc = next
	}
	var ast syscall.Stat_t
	if err := syscall.Stat(anc, &ast); err != nil {
		return fmt.Errorf("no existing ancestor for %q: %w", cur, err)
	}
	if err := os.MkdirAll(cur, 0o700); err != nil {
		return err
	}
	// Re-own every created component (topCreated..cur) to the ancestor's owner.
	for p := cur; len(p) >= len(topCreated); p = filepath.Dir(p) {
		os.Chown(p, int(ast.Uid), int(ast.Gid))
		if p == topCreated {
			break
		}
	}
	// DIA-20260806-15: -D REMOVED. It made restorecon descend into app data, which reaches libselinux's
	// pkgdir_selabel_lookup() -- and that function mutates a process-global cache entry
	// (`info->uid += userid_from_path * AID_USER_OFFSET`), so the Nth lookup of a package in one restorecon
	// process derives a userid of N x the real one and stamps a drifting MCS category on every entry.
	// Measured on lynx: 1,189 mislabelled entries across every category-bearing package in the roamed user,
	// apps crashing on their own databases. Without -D restorecon does not descend, which is exactly what we
	// want here: a file created inside an app-data directory already inherits that directory's context.
	exec.Command("/system/bin/restorecon", "-R", topCreated).Run() // best-effort; no-op off-device
	return nil
}

// mediaMountOptions is the production mount config. AllowOther lets the app (a different uid) read through
// the mount, and DirectMount uses mount(2) directly -- Android has no fusermount helper (the spike proved
// go-fuse falls back to a missing /bin/fusermount without it).
//
// NWP-20260901-01: NO context= OPTION ANY MORE, and the reason is load-bearing. The mount used to carry
// context=u:object_r:nowhere_media_file:s0 as "the MLS bridge that lets any app category read it" -- which
// was true for READING, and fatal for CREATING. A context= mount forces EVERY object to the fixed context,
// including the not-yet-existing file evaluated by the create check, and the platform MLS constraint
//
//	(mlsconstrain (file (create relabelfrom relabelto))
//	   (and (eq l2 h2) (or (eq l1 l2) (eq t1 mlstrustedsubject))))
//
// honours ONLY mlstrustedsubject -- unlike the read/write/unlink constraints it has no mlstrustedobject
// clause. An app at s0:cNNN creating at fixed s0 fails `eq l1 l2` forever, so NO app could ever create a
// file in an overlaid dir, however many TE allows we shipped: Chester's downloads into Download died at
// 0 bytes on every attempt (lynx, 2026-08-31; the temp-file create was the denial, which is also why
// Organic Maps' rename-into-the-overlay write-back path worked while direct creates never could).
//
// Without context=, the mount labels the way stock /storage does: the superblock and lookups fall back to
// genfscon fuse (`u:object_r:fuse:s0`, mlstrustedobject, and appdomain minus isolated/ephemeral/sandbox
// already holds full create/write/unlink on it in the platform policy) -- and the CREATE check evaluates
// the COMPUTED new-file context, whose level inherits the creating app's own categories, so `eq l1 l2`
// holds and the constraint passes. Verified against the running policy on lynx before writing this.
//
// The sepolicy counterpart: endospore_mediad gains fuse:filesystem { mount unmount } (it already held
// fuse:filesystem relabelfrom -- the old mount was BORN fuse and relabelled by context=; now it just stays
// fuse). The nowhere_media_file type and its grants remain for the kill-switch below and for Diaspore.
//
// NOWHERE_MEDIA_MOUNT_CONTEXT is the kill-switch: set it to a full context string to restore the old
// fixed-label behaviour (e.g. while bisecting a labelling regression in the field). Default unset = new.
func mediaMountOptions() *fs.Options {
	opts := &fs.Options{}
	if ctx := os.Getenv("NOWHERE_MEDIA_MOUNT_CONTEXT"); ctx != "" {
		opts.MountOptions.Options = []string{"context=" + ctx}
	}
	opts.MountOptions.FsName = "nowhere_media"
	opts.MountOptions.Name = "nowheremedia"
	opts.MountOptions.AllowOther = true
	opts.MountOptions.DirectMount = true
	opts.MountOptions.Debug = os.Getenv("NOWHERE_MEDIAD_DEBUG") == "1"
	// NWP-20261113-44: NEVER negotiate FUSE passthrough. go-fuse asks for CAP_PASSTHROUGH by default, and a kernel
	// with upstream passthrough (6.9+; frankel runs 6.18, every other fleet device 6.1, which lacks it) grants it and
	// sets this mount's s_stack_depth to MaxStackDepth (1). MediaProvider's FUSE stacks on top of ours, and its own
	// passthrough open of a file in an overlaid dir then fails the kernel's stacking check (backing s_stack_depth >=
	// its max_stack_depth), which its FuseDaemon turns into EFAULT: on frankel, 0.5.56, every new photo, screenshot
	// and download in a folder with deferred media failed and left an empty file behind (beta tickets
	// NW-a2f8bee5b817, NW-01ac9f2e0b0a). Our handles are loopback fds served by mediad either way; passthrough only
	// skipped mediad on reads and writes, which a deferred overlay does not need.
	opts.MountOptions.DisabledCapabilities |= fuse.CAP_PASSTHROUGH
	return opts
}

type mediaMount struct {
	server *fuse.Server
	target string // the FUSE mountpoint (userDir/dir)
	hidden string // the bind-hidden copy of the real dir we passthrough
}

// dlog writes a one-line diagnostic to BOTH stderr (the file log) and logcat (tag "nowhere"), so on-device
// debugging works even when /data/nowhere/*.log is SELinux-unreadable from adb (adb's su:s0 can't read the
// daemon's private-labeled logs, and can't setenforce). Best-effort: the `log` exec never blocks or fails the
// caller. Contains STATUS only, never creds. (DIA-20260705-84 -- mediad serve-failure debugging.)
//
// A session path (a rel, a mount target, a hidden dir) is printed QUOTED (%q), and an error through errCode, so
// log_scrub and the issue report's name rules take it out of mediad.log (Q001 (e), NWP-20261105-01). The logcat
// copy sent here is RAM, cleared at boot, and out of scope.
func dlog(format string, a ...interface{}) {
	msg := fmt.Sprintf(format, a...)
	fmt.Fprintln(os.Stderr, msg)
	_ = exec.Command("/system/bin/log", "-t", "nowhere", msg).Run()
}

// mediaDebug gates the HIGH-FREQUENCY per-open / per-fetch tracing (every file OPEN, whole-file fetch, prefetch
// start/complete). Off by default so normal operation stays quiet in logcat; set NOWHERE_MEDIA_DEBUG=1 to
// re-enable the search/serve trace (used to diagnose the 2026-07-05 search slowdown). Error + lifecycle events
// (evictions, prefetch-stopped-with-error, mount/serve status) still log unconditionally via dlog.
var mediaDebug = os.Getenv("NOWHERE_MEDIA_DEBUG") != ""

// dlogv is dlog gated on mediaDebug -- for the noisy per-operation traces only.
func dlogv(format string, a ...interface{}) {
	if mediaDebug {
		dlog(format, a...)
	}
}

// runMediad is the `nowhere_agent mediad` daemon: mount an on-demand media overlay over every deferred dir of a
// roamed session, then serve until told to stop (SIGTERM at logoff-reap / cold-lock), tearing every mount down
// cleanly. Usage: mediad <store> <name> <pass> <userDir> <cacheDir> [<mediaDir> <mediaCacheDir>]. The optional
// 6th/7th args add the EXTERNAL-media scope (ref name#media over /data/media/<uid>) -- Organic Maps' offline
// maps live there, sealed to name#media, and were captured-but-unserved because mediad only ever ran the CE
// scope (#129 external-media serve gap). Needs CAP_SYS_ADMIN (runs su:s0 / the nowhere_mediad domain).
// appCodeRelDir is the chooser's on-demand APK staging dir, relative to /data/user/<N>. Deferred entries
// under it must never be served as a media overlay -- see the guard in serveMediaScope.
const appCodeRelDir = "com.nowhere.chooser/files/.appcode"

// isAppCodeStagingDir reports whether a deferred-entry dir lives in that staging area. Exact match or a
// PATH-COMPONENT prefix only -- a sibling named ".appcodex" must NOT be swallowed, which is why this is not
// a bare HasPrefix on the string.
func isAppCodeStagingDir(dir string) bool {
	return dir == appCodeRelDir || strings.HasPrefix(dir, appCodeRelDir+"/")
}

func runMediad(args []string) {
	if len(args) < 5 {
		fmt.Fprintln(os.Stderr, "usage: nowhere_agent mediad <store> <name> <pass> <userDir> <cacheDir> [<mediaDir> <mediaCacheDir>]")
		os.Exit(2)
	}
	base, name, pass, userDir, cacheDir := args[0], args[1], args[2], args[3], args[4]
	goSafeTag.Store("[mediad]") // NWP-20261014-66: a goroutine this daemon recovers says whose it was
	stateDir := os.Getenv("NOWHERE_STATE")
	if stateDir != "" {
		// DIA-20260816-13: truncate the overlay map before ANY scope appends to it. A SIGKILL'd previous
		// instance (ctl.stop is a SIGKILL) leaves its lines behind, and a stale mountpoint->hidden pair is
		// worse than none: the walk would read a dir that is no longer bound.
		os.Remove(filepath.Join(stateDir, mediaUndersFile))
		// NWP-20261201-14: a run with no mounts can leave a DAMAGED name for the session. Only a served scope cleared
		// the file before, so a later sign-in that serves nothing would relay another profile's file name.
		os.Remove(filepath.Join(stateDir, mediaProgressFile))
	}

	// NWP-20261006-10: never serve a profile into a session it does not open in (tied to another phone's chip): its
	// #media is keyed by the passphrase, so it WOULD serve (locked_head.go). NWP-20261124-07: nor when its bare head
	// could not be read -- a store failure is never "not locked".
	locked, unreadable := scopeOwnerLocked(base, name+"#media", pass)
	if unreadable {
		dlog("mediad: the store could not be read for this profile's head -> serving nothing (NWP-20261124-07)")
		return
	}
	if locked {
		dlog("mediad: profile does not open on this phone -> exiting")
		return
	}
	var allMounts []mediaMount
	allMounts = append(allMounts, serveMediaScope(base, name, pass, userDir, cacheDir, stateDir)...)
	// #129: also serve the EXTERNAL-media scope when the launcher passed it (only if /data/media/<uid> exists).
	// Same key/vault, a DIFFERENT store ref (name#media) + userDir (/data/media/<uid>): its Deferred index holds
	// the offline maps, and serveMediaScope's Tier-2 prefetch re-materializes them to disk after login.
	if len(args) >= 7 {
		allMounts = append(allMounts, serveMediaScope(base, name+"#media", pass, args[5], args[6], stateDir)...)
	}
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(ch)
	// NWP-20261201-14: the #media background restore. It keeps this daemon up with no mount at all (§3).
	var lander *bgLander
	if len(args) >= 7 {
		lander = startBgLander(base, name+"#media", pass, args[5], stateDir, allMounts)
	}
	if len(allMounts) == 0 && lander == nil {
		dlog("mediad: nothing mounted -> exiting")
		return
	}
	dlog("mediad: serving %d overlay(s) total for %q", len(allMounts), name)

	// Serve until told to stop; then unmount every overlay + drop its bind, so no stale FUSE mount is left
	// behind. NEVER blanket-abort /sys/fs/fuse/connections -- that kills Android's own storage FUSE (spike).
	if !mediadServe(ch, len(allMounts) > 0, lander.doneC()) {
		dlog("mediad: background restore finished, nothing mounted -> exiting")
		return
	}
	// ⚠ STOP THE LANDER FIRST. A file landed into an overlay's hidden directory after its bind is gone lands in an
	// orphan directory, its digest reads as landed, and the next seal drops it as a deletion.
	lander.Stop()
	if stateDir != "" {
		os.Remove(filepath.Join(stateDir, mediaUndersFile))   // DIA-20260816-13: the overlay map dies with the mounts
		os.Remove(filepath.Join(stateDir, mediaProgressFile)) // #90: clear the "Loading…" line so it can't linger
	}
	for _, mt := range allMounts {
		if err := mt.server.Unmount(); err != nil {
			fmt.Fprintf(os.Stderr, "mediad: unmount %q: %v\n", mt.target, errCode(err))
		}
		syscall.Unmount(mt.hidden, syscall.MNT_DETACH)
	}
	fmt.Fprintln(os.Stderr, "mediad: unmounted all overlays, exiting")
}

// stageUnders maps every deferred dir covered by a mount rooted at `dir` -- `dir` itself included -- to
// its real location under that mount's bind, alongside the deferred index for the same subtree.
//
// It is deliberately PURE and returns the mapping instead of writing it: NWP-20260829-25 published
// straight into undersByDir from inside this loop, which sits above two mount-failure exits, so a failed
// mount left live-looking entries pointing at a detached dir. Returning the map forces the caller to
// choose a publish point, and the only correct one is after the mount succeeds (NWP-20260829-26).
// pinsFingerprint renders a pin set as a stable string so the poll in serveMediaScope can tell a CHANGED set
// from an unchanged one without re-running materializePins every 20 seconds. Sorted because neither side has a
// dependable order: loadPins returns a map, and the chooser writes the file from a Set (NWP-20260829-27).
func pinsFingerprint(pins map[string]bool) string {
	if len(pins) == 0 {
		return ""
	}
	ks := make([]string, 0, len(pins))
	for k := range pins {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return strings.Join(ks, "\n")
}

func stageUnders(dirs map[string][]string, dir, hidden string) (map[string][]string, map[string]string) {
	sub := map[string][]string{}
	unders := map[string]string{}
	for d, ns := range dirs {
		// `dir+"/"`, never a bare prefix: a sibling like "Images2" shares "Images" as a string prefix but
		// is NOT under it, and mapping it here would point its files into the wrong mount's bind.
		if d == dir || strings.HasPrefix(d, dir+"/") {
			sub[d] = ns
			unders[d] = filepath.Join(hidden, filepath.FromSlash(strings.TrimPrefix(d, dir)))
		}
	}
	return sub, unders
}

// serveMediaScope resolves ONE profile scope's manifest, mounts an on-demand overlay over each of its deferred
// dirs under userDir, and starts that scope's pin-materialize + Tier-2 background-prefetch goroutines. Returns
// the mounts for the caller to tear down at SIGTERM. A scope with no deferred media (or an absent/legacy
// manifest) mounts nothing and returns nil -- so a profile whose maps are all in name#media still serves them
// even though the CE scope is empty. Factored out of runMediad so one mediad process serves BOTH the CE and the
// external-media scope (#129).
func serveMediaScope(base, name, pass, userDir, cacheDir, stateDir string) []mediaMount {
	key, manifestBlob, ok := resolveKey(base, name, pass)
	if !ok {
		dlog("mediad: profile %q empty/absent -> nothing to serve", name)
		return nil
	}
	pt := unseal(key, manifestBlob)
	if !bytes.HasPrefix(pt, cdcMagic) {
		dlog("mediad: profile %q legacy (no deferred index) -> nothing to serve", name)
		return nil
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		dlog("mediad: manifest parse %q: %v", name, errCode(err))
		return nil
	}
	dlog("mediad: profile %q manifest v%d: %d deferred file(s), %d essential chunk(s), userDir=%s", name, m.Version, len(m.Deferred), len(m.Chunks), userDir)
	// NWP-20260923-02: the vault no longer defers, and this sign-in's restore already put every deferred file
	// it could on the phone (media_heal.go). Do not serve those. An overlay over a dir whose files are already
	// real is not harmless: roamd cannot chown through it, which is how an on-demand app's data hand-back
	// failed forever (Play's files/phonesky-download-service). No list means the heal never ran this session:
	// serve everything, as before this build. (#media still defers: healListFile is "" for it.)
	m.Deferred = mediadHealFilter(name, pass, stateDir, m.Deferred)
	if len(m.Deferred) == 0 {
		dlog("mediad: profile %q has no deferred media -> nothing to serve", name)
		return nil
	}
	srv := newMediaServer(base, key, m, cacheDir)
	if st := stateDir; st != "" {
		// #90: publish on-access fetch progress to the RAM state tmpfs for the chooser's "Loading your media"
		// notification (relayed via the login daemon's GET-MEDIA-STATUS). Clear any line left by a SIGKILL'd
		// previous instance so a stale "LOADING" can't outlive it. (Shared file across scopes: the CE scope
		// usually has 0 deferred and returns above, so in practice only the media scope writes it.)
		srv.progPath = filepath.Join(st, mediaProgressFile)
		if isSharedMediaScope(name) {
			mediaScopeServer.Store(srv) // NWP-20261201-14: the lander publishes through this scope's server
		}
		os.Remove(srv.progPath)
		srv.appProgPath = filepath.Join(st, mediaAppProgFile) // #129 P5: per-app Tier-2 progress for the ring
		os.Remove(srv.appProgPath)
	}

	hideBase := filepath.Join(cacheDir, ".under")
	os.MkdirAll(hideBase, 0o700)
	// DIA-20260816-13: publish the authoritative mountpoint -> hidden map for the seal walk. APPEND, because
	// both scopes (CE and external) call this function and each contributes its own overlays; runMediad
	// truncates once before the first call. Best-effort: if this cannot be written the walk falls back to the
	// mount-table parse exactly as before, so a failure here degrades rather than breaks.
	var undersOut *os.File
	if stateDir != "" {
		if f, err := os.OpenFile(filepath.Join(stateDir, mediaUndersFile), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			undersOut = f
			defer undersOut.Close()
		}
	}
	var mounts []mediaMount
	undersByDir := map[string]string{} // #108: rel dir -> its .under (hidden) real path, for the pin materialize
	// NWP-20260829-04: mount one overlay per MAXIMAL deferred dir, in a deterministic order. Ranging the
	// map directly mounted nested dirs too, in random order, which wedged logoff -- see mediaMountRoots for
	// the full mechanism. Three ordered stages, and the ORDER OF THE STAGES IS LOAD-BEARING:
	//   1. drop .appcode BEFORE the collapse, so no ancestor can inherit chooser APK staging;
	//   2. scar-heal EVERY remaining deferred dir (roots AND the nested ones an ancestor will now cover)
	//      before any bind, so every mkdir lands on the real f2fs path and never through a live overlay;
	//   3. mount only the maximal dirs.
	dirs := srv.deferredDirs()
	for dir := range dirs {
		if isAppCodeStagingDir(dir) {
			dlog("mediad: NOT overlaying app-code staging %q (fetched directly, not served -- NWP-20260825-10)", dir)
			delete(dirs, dir)
		}
	}
	// Stage 2: the #92 scar-heal, over every deferred dir including the ones about to be collapsed. A nested
	// dir is now reached through its ancestor's bind rather than by its own mount, and a dir missing under
	// that bind is just as stranded as it was before -- so it still has to be recreated here.
	for dir := range dirs {
		target := filepath.Join(userDir, filepath.FromSlash(dir))
		var st syscall.Stat_t
		if err := syscall.Stat(target, &st); err == nil {
			continue
		}
		if e := ensureDeferredDir(userDir, filepath.FromSlash(dir)); e != nil {
			dlog("mediad: %q: %q not present and recreate failed (%v)", dir, target, errCode(e))
			continue
		}
		if err := syscall.Stat(target, &st); err != nil {
			dlog("mediad: %q: %q still not present (%v)", dir, target, errCode(err))
			continue
		}
		dlog("mediad: recreated missing deferred dir %q", target)
		srv.markIncomplete(pinnedApp(dir))
	}
	for _, dir := range mediaMountRoots(dirs) {
		names := dirs[dir]
		// The .appcode exclusion and the #92 scar-heal both moved ABOVE the collapse (NWP-20260829-04):
		// the first must run before an ancestor can inherit the staging dir, the second must cover the
		// nested dirs this root now serves as passthrough. All that is left here is the stat the mount needs.
		target := filepath.Join(userDir, filepath.FromSlash(dir))
		var st syscall.Stat_t
		if err := syscall.Stat(target, &st); err != nil {
			dlog("mediad: skip %q: %q not present (%v)", dir, target, errCode(err))
			continue
		}
		// Bind the real dir to a hidden path first, then mount the overlay OVER the real dir with the passthrough
		// rooted at the bind -- otherwise the loopback would recurse into its own mount.
		hidden := filepath.Join(hideBase, underLeaf(dir)) // injective -- see underLeaf (NWP-20261011-74)
		os.MkdirAll(hidden, 0o700)
		if err := syscall.Mount(target, hidden, "", syscall.MS_BIND, ""); err != nil {
			fmt.Fprintf(os.Stderr, "mediad: bind %q -> %q failed: %v\n", target, hidden, errCode(err))
			continue
		}
		// Isolate the bind from mount PROPAGATION. On Android /data/user/<uid> is a shared/slave subtree, so
		// `hidden` (a bind peer of `target`) would RECEIVE the FUSE overlay we mount over `target` next -- and
		// the loopback passthrough (rooted at `hidden`) would then recurse into its own overlay on every
		// getattr: one goroutine + one blocked OS thread per level, crashing the daemon with
		// `fatal error: thread exhaustion` the instant an app scans the dir (proven on-device 2026-07-03).
		// MS_PRIVATE detaches `hidden` so it stays a plain view of the real files; the overlay over `target`
		// still propagates into the app's namespace (a different mountpoint on the same shared subtree).
		if err := syscall.Mount("", hidden, "", syscall.MS_PRIVATE, ""); err != nil {
			fmt.Fprintf(os.Stderr, "mediad: make-private %q failed: %v\n", hidden, errCode(err))
			syscall.Unmount(hidden, syscall.MNT_DETACH)
			continue
		}
		// NWP-20260829-08: hand this mount the deferred index for its WHOLE subtree, not just its own dir.
		// -07 collapsed nested dirs into this ancestor; without their entries the ancestor serves them as
		// plain passthrough and their deferred files get no stub at all.
		//
		// NWP-20260829-26: STAGED, not published. The undersByDir writes land below, once the mount is
		// live -- see the publish site for what a premature write costs.
		sub, subUnders := stageUnders(dirs, dir, hidden)
		root, err := newMediaOverlay(srv, dir, sub, hidden, st.Uid, st.Gid)
		if err != nil {
			fmt.Fprintf(os.Stderr, "mediad: root %q: %v\n", target, errCode(err))
			syscall.Unmount(hidden, syscall.MNT_DETACH)
			continue
		}
		server, err := fs.Mount(target, root, mediaMountOptions())
		if err != nil {
			fmt.Fprintf(os.Stderr, "mediad: mount %q failed: %v\n", target, errCode(err))
			syscall.Unmount(hidden, syscall.MNT_DETACH)
			continue
		}
		dlog("mediad: mounted %d deferred file(s) across %d dir(s) over %q", len(names), len(sub), target)
		mounts = append(mounts, mediaMount{server: server, target: target, hidden: hidden})
		// PUBLISH ONLY NOW. materialize resolves a file's real location through
		// undersByDir[path.Dir(rel)], fetches the bytes, writes them there, and then markDeleted()s
		// the rel -- so an entry for a dir with NO live mount is silent, permanent data loss: both
		// failure paths above MNT_DETACH `hidden` but leave it existing as a plain dir (os.MkdirAll
		// made it), so the lookup HITS, the copy SUCCEEDS into that orphan, the file is tombstoned
		// out of the manifest, and the log even says `MATERIALIZED ... (kept offline)`.
		for d, u := range subUnders {
			undersByDir[d] = u
		}
		if undersOut != nil {
			// Tab-separated: neither a mountpoint nor a hidden path can contain a tab or a newline on this
			// device (the mountpoint is the user dir plus a rel dir, the hidden path the cache dir plus
			// underLeaf of that rel dir, which only rewrites `_` and `/`), so no quoting is needed.
			fmt.Fprintf(undersOut, "%s\t%s\n", target, hidden)
		}
	}
	if len(mounts) == 0 {
		dlog("mediad: profile %q nothing mounted", name)
		return nil
	}
	dlog("mediad: serving %d overlay(s) for %q", len(mounts), name)

	// #108: a PINNED app's deferred media is fetched to local + written into the passthrough dir (background),
	// so it stops being deferred and the next seal keeps it essential (restored at login). No-op when nothing is
	// pinned; idempotent (a fetch is a cache hit, a tombstoned file is skipped).
	//
	// NWP-20260829-27: POLLED, not read once at start. This used to be a one-shot read plus a chooser "kick":
	// PIN-MATERIALIZE -> kickMediad -> `setprop ctl.start nowhere_mediad`. But init IGNORES ctl.start for a
	// service that is already RUNNING, and mediad runs for the WHOLE session -- the launcher EXECs the agent, so
	// it IS init's tracked main process. So a pin toggled mid-session never reached materializePins at all,
	// while logind logged "mediad kicked" as though it had. Device-proven on lynx 2026-08-29: pin written
	// 20:13:04, mediad still the 19:59:23 process, SIX "mediad kicked" lines, ZERO "pinned" materialize lines --
	// the user's "keep this app offline" did nothing until the next login and told them it had worked.
	// This is the SAME reasoning the Tier-2 arm below already documents ("a one-shot check here would ALWAYS
	// miss it -- POLL instead"); it was never applied to pins. Polling makes the kick advisory: it still matters
	// when mediad is NOT running, and is harmless when it is. Its own goroutine, so a long Tier-2 pass cannot
	// delay a pin the user is waiting on.
	// NWP-20261202-17: the vault heal of unkept apps, which the sign-in left for after landing (media_heal_late.go).
	// Once per scope, now that undersByDir holds only live overlays; healLate returns at once for #media.
	goSafe("vault heal", func() { srv.healLate(name, userDir, undersByDir) })
	goSafeLoop("pin loop", func() {
		last := "" // no legal fingerprint is empty, so the first non-empty set always triggers a pass
		for {
			pins := loadPins(userDir)
			fp := pinsFingerprint(pins)
			// Only on CHANGE: a steady pin must not re-walk the deferred set every 20s. A repeat pass is cheap
			// (cache hit / tombstone skip) but the walk itself is not free.
			if fp != last {
				last = fp
				if len(pins) > 0 {
					// stillOK parks the pass the moment the set changes again, so an UNPIN can call off a fetch
					// already in flight -- on a large app that is gigabytes the user just asked to stop.
					srv.materializePins(pins, loadBudget(userDir), undersByDir, func() bool {
						return pinsFingerprint(loadPins(userDir)) == fp
					})
				}
			}
			time.Sleep(20 * time.Second)
		}
	})
	// #129 P3/P4: Tier-2 background prefetch, gated on the chooser's Wi-Fi + idle/charging arm. The gate almost
	// always arms AFTER mediad started (login happens first; the watcher arms ~30s later), so a one-shot check
	// here would ALWAYS miss it -- POLL prefetch.armed instead. When armed, run one Tier-2 pass (it skips
	// already-materialized / non-Tier-2 files and pauses via stillOK the moment the gate closes), then re-check.
	// Inert until armed -> never prefetches on cellular / at capacity. The goroutine dies with mediad (SIGTERM
	// at cold-lock). Same background fetch -> .under -> tombstone promotion as pins; the over-budget excess stays
	// deferred (on-demand). This is the path that re-materializes the offline maps for the external-media scope.
	goSafeLoop("tier2-prefetch loop", func() {
		for {
			if prefetchArmed() {
				// NWP-20260829-29: tiers + pins are read LIVE on every pass, so a tier change takes effect within
				// one poll instead of waiting for a seal to stamp it into the manifest -- which for an
				// importer-band path never happens at all.
				srv.prefetchTier2(loadTier2Budget(userDir), undersByDir, loadTiers(userDir), loadPins(userDir), prefetchArmed)
			}
			time.Sleep(20 * time.Second)
		}
	})

	return mounts
}
