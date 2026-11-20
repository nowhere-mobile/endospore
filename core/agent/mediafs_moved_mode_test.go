package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// NWP-20261209-01: the behavioural half of the moved-in-file fix, checked by stat through the real operations. This
// file uses no symbol the slice adds (newMediaOverlay and go-fuse's raw bridge only), so it compiles against the code
// before the fix and fails there: mediad's umask masked the requested mode, and a new entry kept its creator's owner.
// mediafs_moved_owner_test.go holds the unit and confinement tests of the new helpers.

// movedOwner is the overlay-root owner the behavioural tests give newMediaOverlay, and whether a new entry can be
// re-owned to it here. As root: an owner no FUSE caller has. Else: our uid and a supplementary group, the one chown a
// non-root process may make. Each candidate is tried on a scratch file first: in a user namespace a group can be
// listed but unmapped (the overflow gid 65534), and the chown then fails with EINVAL. With no candidate that works,
// owned is false and only the mode is checked here; TestMovedInEntryRequestsTreeOwner checks the owner half anyway.
func movedOwner(t *testing.T) (uid, gid uint32, owned bool) {
	t.Helper()
	probe := filepath.Join(t.TempDir(), "probe")
	if err := os.WriteFile(probe, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	works := func(u, g uint32) bool { return os.Lchown(probe, int(u), int(g)) == nil }
	if os.Getuid() == 0 && works(4242, 4243) {
		return 4242, 4243, true
	}
	groups, _ := syscall.Getgroups()
	for _, g := range groups {
		if g != os.Getegid() && works(uint32(os.Getuid()), uint32(g)) {
			return uint32(os.Getuid()), uint32(g), true
		}
	}
	t.Logf("no root and no usable supplementary group: the owner half is not checked by stat here")
	return uint32(os.Getuid()), uint32(os.Getgid()), false
}

// bridgeOverlay builds an overlay over a fresh under dir holding .Shared/h.tmp (made directly, as before the mount)
// and returns go-fuse's raw bridge over it, the under dir, and the overlay root.
func bridgeOverlay(t *testing.T, uid, gid uint32) (fuse.RawFileSystem, string, *mediaRoot) {
	t.Helper()
	under := t.TempDir()
	if err := os.Mkdir(filepath.Join(under, ".Shared"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(under, ".Shared", "h.tmp"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := newMediaServer("", nil, chunkManifest{}, t.TempDir())
	root, err := newMediaOverlay(srv, "Android/media/com.app", nil, under, uid, gid)
	if err != nil {
		t.Fatal(err)
	}
	return fs.NewNodeFS(root, &fs.Options{}), under, root
}

// callerOf is MediaProvider's FUSE thread as the kernel names it in a request: an owner unlike the tree's.
func callerOf(nodeID uint64) fuse.InHeader {
	return fuse.InHeader{NodeId: nodeID, Caller: fuse.Caller{Owner: fuse.Owner{Uid: 10123, Gid: 10123}}}
}

func statOf(t *testing.T, p string) syscall.Stat_t {
	t.Helper()
	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func lookupID(t *testing.T, rfs fuse.RawFileSystem, parent uint64, name string) uint64 {
	t.Helper()
	var out fuse.EntryOut
	if st := rfs.Lookup(nil, &fuse.InHeader{NodeId: parent}, name, &out); st != fuse.OK {
		t.Fatalf("lookup: %v", st)
	}
	return out.NodeId
}

// The reported case, driven through the real operations: MediaProvider creates the copy (CREATE 0664), makes a dir
// (MKDIR 0775) or a node (MKNOD 0664), and an app's move within one app media root arrives as RENAME. Under init's umask 077 each new entry
// must still carry the mode its caller asked for, and every entry the tree's owner, checked by stat.
func TestMovedInEntryTakesTreeOwnerAndMode(t *testing.T) {
	old := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(old) })
	uid, gid, owned := movedOwner(t)
	rfs, under, _ := bridgeOverlay(t, uid, gid)
	checkOwner := func(what string, st syscall.Stat_t) {
		t.Helper()
		if owned && (st.Uid != uid || st.Gid != gid) {
			t.Errorf("%s: owner %d:%d, want the tree's %d:%d", what, st.Uid, st.Gid, uid, gid)
		}
	}

	var mk fuse.EntryOut
	if st := rfs.Mkdir(nil, &fuse.MkdirIn{InHeader: callerOf(1), Mode: 0o775}, "Video", &mk); st != fuse.OK {
		t.Fatalf("mkdir: %v", st)
	}
	st := statOf(t, filepath.Join(under, "Video"))
	if st.Mode&0o7777 != 0o775 {
		t.Errorf("a new dir has mode %o, want the requested 0775", st.Mode&0o7777)
	}
	checkOwner("a new dir", st)

	var cr fuse.CreateOut
	in := &fuse.CreateIn{InHeader: callerOf(mk.NodeId), Flags: syscall.O_WRONLY, Mode: 0o664}
	if s := rfs.Create(nil, in, "copy.mp4", &cr); s != fuse.OK {
		t.Fatalf("create: %v", s)
	}
	rfs.Release(nil, &fuse.ReleaseIn{InHeader: fuse.InHeader{NodeId: cr.NodeId}, Fh: cr.Fh})
	st = statOf(t, filepath.Join(under, "Video", "copy.mp4"))
	if st.Mode&0o7777 != 0o664 {
		t.Errorf("a created file has mode %o, want the requested 0664", st.Mode&0o7777)
	}
	checkOwner("a created file", st)
	if cr.Attr.Mode&0o7777 != 0o664 || (owned && (cr.Attr.Uid != uid || cr.Attr.Gid != gid)) {
		t.Errorf("the created entry's reply must report the fixed mode and owner: %o %d:%d", cr.Attr.Mode&0o7777, cr.Attr.Uid, cr.Attr.Gid)
	}

	var mn fuse.EntryOut
	if s := rfs.Mknod(nil, &fuse.MknodIn{InHeader: callerOf(mk.NodeId), Mode: syscall.S_IFIFO | 0o664}, "pipe", &mn); s != fuse.OK {
		t.Fatalf("mknod: %v", s)
	}
	st = statOf(t, filepath.Join(under, "Video", "pipe"))
	if st.Mode&0o7777 != 0o664 {
		t.Errorf("a new node has mode %o, want the requested 0664", st.Mode&0o7777)
	}
	checkOwner("a new node", st)

	shared := lookupID(t, rfs, 1, ".Shared")
	if s := rfs.Rename(nil, &fuse.RenameIn{InHeader: callerOf(shared), Newdir: mk.NodeId}, "h.tmp", "v.mp4"); s != fuse.OK {
		t.Fatalf("a move within one app media root must be a rename: %v", s)
	}
	st = statOf(t, filepath.Join(under, "Video", "v.mp4"))
	if st.Mode&0o7777 != 0o600 {
		t.Errorf("a renamed file must keep its own mode: %o", st.Mode&0o7777)
	}
	checkOwner("a renamed file", st)
}

// A real mount, where the environment has FUSE: the move between two folders of one app media root is a rename,
// not EXDEV, and the moved and created files carry the tree's owner by stat.
func TestOverlayMountMoveIsRename(t *testing.T) {
	uid, gid, owned := movedOwner(t)
	under := t.TempDir()
	if err := os.Mkdir(filepath.Join(under, ".Shared"), 0o755); err != nil {
		t.Fatal(err)
	}
	srv := newMediaServer("", nil, chunkManifest{}, t.TempDir())
	root, err := newMediaOverlay(srv, "Android/media/com.app", nil, under, uid, gid)
	if err != nil {
		t.Fatal(err)
	}
	mnt := t.TempDir()
	server, err := fs.Mount(mnt, root, &fs.Options{})
	if err != nil {
		t.Skipf("no usable FUSE in this environment: %v", err)
	}
	defer server.Unmount()

	tmp := filepath.Join(mnt, ".Shared", "h.tmp")
	if err := os.WriteFile(tmp, []byte("v"), 0o664); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(mnt, "Video"), 0o775); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, filepath.Join(mnt, "Video", "v.mp4")); err != nil {
		t.Fatalf("a move within one app media root must be a rename: %v", err)
	}
	for _, p := range []string{filepath.Join(under, "Video"), filepath.Join(under, "Video", "v.mp4")} {
		if st := statOf(t, p); owned && (st.Uid != uid || st.Gid != gid) {
			t.Errorf("%s: owner %d:%d, want %d:%d", p, st.Uid, st.Gid, uid, gid)
		}
	}
}
