package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	"github.com/hanwen/go-fuse/v2/fuse"
)

// NWP-20261209-01: a file moved into an overlaid media folder could not be opened until the next seal (frankel,
// kernel 6.18). The move crossed a mount (EXDEV), the app copied the file in through MediaProvider, and mediad gave
// the copy MediaProvider's owner and a 0600 mode. These tests pin the two halves of the fix: one mount per app
// media root (mediaMountAnchors), and every new entry takes the tree's owner and its requested mode (fixNew), through
// a descriptor confined to the overlay's own tree. The Mode/Owner tests drive the real operations through go-fuse's
// raw bridge (fs.NewNodeFS), so they need no /dev/fuse and use no symbol this slice adds.

func mkdirs(t *testing.T, root string, rels ...string) {
	t.Helper()
	for _, r := range rels {
		if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(r)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMediaMountAnchorsWidenAppMediaRoot(t *testing.T) {
	user := t.TempDir()
	shared := "Android/media/com.app/App/Media/.Shared"
	video := "Android/media/com.app/App/Media/App Video"
	mkdirs(t, user, shared, video, "DCIM/Camera", "Android/data/com.x/files/maps", "Android/media/com.gone")
	dirs := map[string][]string{shared: {"a.tmp"}, video: {"v.mp4"}}

	out, n := mediaMountAnchors(dirs, user, true)
	if n != 1 {
		t.Fatalf("anchors added = %d, want 1", n)
	}
	if ns, ok := out["Android/media/com.app"]; !ok || len(ns) != 0 {
		t.Fatalf("the app media root must be a key with no names: %v", out)
	}
	if got := mediaMountRoots(out); !reflect.DeepEqual(got, []string{"Android/media/com.app"}) {
		t.Fatalf("mount roots = %v, want the one app media root", got)
	}
	if len(dirs) != 2 {
		t.Fatalf("the input map must not change: %v", dirs)
	}

	// The CE scope never widens.
	if out, n := mediaMountAnchors(dirs, user, false); n != 0 || len(out) != 2 {
		t.Fatalf("the CE scope must not widen: n=%d out=%v", n, out)
	}
	// A top-level dir, Android/data, and an app media root that does not exist get no anchor.
	other := map[string][]string{
		"DCIM/Camera":                    {"p.jpg"},
		"Android/data/com.x/files/maps":  {"m.mwm"},
		"Android/media/com.missing/Pics": {"q.jpg"},
	}
	if out, n := mediaMountAnchors(other, user, true); n != 0 || len(out) != 3 {
		t.Fatalf("no anchor expected here: n=%d out=%v", n, out)
	}
}

// The reported case: .Shared and the video folder are under ONE hidden root, so the move is a rename in one mount.
func TestMediaMountAnchorsRenameIsOneMount(t *testing.T) {
	user := t.TempDir()
	shared := "Android/media/com.app/App/Media/.Shared"
	video := "Android/media/com.app/App/Media/App Video"
	mkdirs(t, user, shared, video)
	out, _ := mediaMountAnchors(map[string][]string{shared: {"a.tmp"}, video: {"v.mp4"}}, user, true)
	roots := mediaMountRoots(out)
	if len(roots) != 1 {
		t.Fatalf("want one mount, got %v", roots)
	}
	_, unders := stageUnders(out, roots[0], "/hidden")
	if unders[shared] != "/hidden/App/Media/.Shared" || unders[video] != "/hidden/App/Media/App Video" {
		t.Fatalf("both dirs must map under the one hidden root: %v", unders)
	}
}

func TestMediaTreeOwnerFollowsRemapTree(t *testing.T) {
	user := t.TempDir()
	var ust syscall.Stat_t
	if err := syscall.Stat(user, &ust); err != nil {
		t.Fatal(err)
	}
	want := fuse.Owner{Uid: ust.Uid, Gid: ust.Gid}
	rootSt := syscall.Stat_t{Uid: ust.Uid + 4242, Gid: ust.Gid + 4243}
	for _, d := range []string{"Android/media/com.app/App", "DCIM/Camera"} {
		if o := mediaTreeOwner(user, d, rootSt); o == nil || *o != want {
			t.Fatalf("%s: want the user dir's owner %+v, got %+v", d, want, o)
		}
	}
	appOwn := fuse.Owner{Uid: rootSt.Uid, Gid: rootSt.Gid}
	for _, d := range []string{"Android/data/com.x/files", "Android/obb/com.x"} {
		if o := mediaTreeOwner(user, d, rootSt); o == nil || *o != appOwn {
			t.Fatalf("%s: want the overlay root's owner %+v, got %+v", d, appOwn, o)
		}
	}
	if o := mediaTreeOwner(filepath.Join(user, "absent"), "DCIM/Camera", rootSt); o != nil {
		t.Fatalf("an unreadable user dir must keep go-fuse's owner: %+v", o)
	}
}

// RF-001 regression: the app can replace the new entry, or a dir above it, between the op and the fix. Nothing
// outside the overlay's tree may change, and neither may a different inode inside it.
func TestFixNewStaysInsideTheTree(t *testing.T) {
	uid, gid, _ := movedOwner(t)
	rfs, under, root := bridgeOverlay(t, uid, gid)
	var mk fuse.EntryOut
	if st := rfs.Mkdir(nil, &fuse.MkdirIn{InHeader: callerOf(1), Mode: 0o755}, "Video", &mk); st != fuse.OK {
		t.Fatalf("mkdir: %v", st)
	}
	var cr fuse.CreateOut
	if s := rfs.Create(nil, &fuse.CreateIn{InHeader: callerOf(mk.NodeId), Flags: syscall.O_WRONLY, Mode: 0o644}, "v.mp4", &cr); s != fuse.OK {
		t.Fatalf("create: %v", s)
	}
	rfs.Release(nil, &fuse.ReleaseIn{InHeader: fuse.InHeader{NodeId: cr.NodeId}, Fh: cr.Fh})
	video, ok := root.EmbeddedInode().GetChild("Video").Operations().(*mediaRoot)
	if !ok {
		t.Fatal("Video is not a mediaRoot")
	}

	outside := t.TempDir()
	target := filepath.Join(outside, "v.mp4")
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(target, 0o600); err != nil {
		t.Fatal(err)
	}
	before := statOf(t, target)
	unchanged := func(what, p string, want syscall.Stat_t) {
		t.Helper()
		if got := statOf(t, p); got.Mode != want.Mode || got.Uid != want.Uid || got.Gid != want.Gid {
			t.Errorf("%s: %s changed to %o %d:%d (was %o %d:%d)", what, p, got.Mode, got.Uid, got.Gid, want.Mode, want.Uid, want.Gid)
		}
	}
	vp := filepath.Join(under, "Video", "v.mp4")

	// 1. The new entry itself is now a symlink out of the tree.
	if err := os.Remove(vp); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, vp); err != nil {
		t.Fatal(err)
	}
	for _, ino := range []uint64{cr.Attr.Ino, 0} {
		video.fixNew("v.mp4", ino, 0o664, true, &fuse.Attr{})
	}
	unchanged("a symlink at the new name", target, before)

	// 2. The parent dir is now a symlink to an outside dir that holds the same name.
	if err := os.Rename(filepath.Join(under, "Video"), filepath.Join(under, "Video.old")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(under, "Video")); err != nil {
		t.Fatal(err)
	}
	video.fixNew("v.mp4", 0, 0o664, true, &fuse.Attr{})
	unchanged("a symlinked parent dir", target, before)
	if err := os.Remove(filepath.Join(under, "Video")); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(under, "Video.old"), filepath.Join(under, "Video")); err != nil {
		t.Fatal(err)
	}

	// 3. A different inode inside the tree now holds the name (a hard link to another file of the tree).
	other := filepath.Join(under, ".Shared", "h.tmp")
	if err := os.Remove(vp); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(other, vp); err != nil {
		t.Fatal(err)
	}
	was := statOf(t, other)
	video.fixNew("v.mp4", cr.Attr.Ino, 0o664, true, &fuse.Attr{})
	unchanged("a different inode at the new name", other, was)
}

func TestNewEntryLogCarriesNoName(t *testing.T) {
	const leaf = "secret-holiday-photo-4711.jpg"
	uid, gid, _ := movedOwner(t)
	rfs, under, root := bridgeOverlay(t, uid, gid)
	var mk fuse.EntryOut
	if st := rfs.Mkdir(nil, &fuse.MkdirIn{InHeader: callerOf(1), Mode: 0o755}, "private-album-0815", &mk); st != fuse.OK {
		t.Fatalf("mkdir: %v", st)
	}
	album := root.EmbeddedInode().GetChild("private-album-0815").Operations().(*mediaRoot)
	if err := os.Symlink("/", filepath.Join(under, "private-album-0815", "link-"+leaf)); err != nil {
		t.Fatal(err)
	}
	got := captureStderr(t, func() {
		album.fixNew(leaf, 0, 0o664, true, &fuse.Attr{})             // absent: the confined open fails
		album.fixNew("link-"+leaf, 12345, 0o664, true, &fuse.Attr{}) // a different inode at the name
	})
	if !strings.Contains(got, "confined open") || !strings.Contains(got, "a different inode") {
		t.Fatalf("both refusal lines must be logged: %q", got)
	}
	for _, bad := range []string{leaf, "private-album-0815", under} {
		if strings.Contains(got, bad) {
			t.Fatalf("a new-entry log line carries a name (%q): %q", bad, got)
		}
	}
	src, err := os.ReadFile("mediafs.go")
	if err != nil {
		t.Fatal(err)
	}
	const head = `dlog("mediad: %d overlay root(s) widened to an app media root (NWP-20261209-01)", widened)`
	if !strings.Contains(string(src), head) {
		t.Fatalf("the widened log line must print a count only: %s", head)
	}
}

// The owner half where the test process may not chown (no root, no mapped supplementary group, as on the CI runner):
// fixNewChown records the owner fixNew asks for, per inode, and reports success. Every entry the real operations make
// (MKDIR, CREATE, MKNOD) and the destination of a RENAME must be asked to take the tree's owner, and each make's
// reply must report it.
func TestMovedInEntryRequestsTreeOwner(t *testing.T) {
	const uid, gid = 4242, 4243
	asked := map[uint64][2]int{}
	old := fixNewChown
	fixNewChown = func(fd, u, g int) error {
		var st syscall.Stat_t
		if err := syscall.Fstat(fd, &st); err != nil {
			return err
		}
		asked[st.Ino] = [2]int{u, g}
		return nil
	}
	t.Cleanup(func() { fixNewChown = old })
	rfs, under, _ := bridgeOverlay(t, uid, gid)
	check := func(what, p string, reply *fuse.Attr) {
		t.Helper()
		st := statOf(t, filepath.Join(under, p))
		if got, ok := asked[st.Ino]; !ok || got != [2]int{uid, gid} {
			t.Errorf("%s: fixNew asked for owner %v (asked: %v), want the tree's %d:%d", what, got, ok, uid, gid)
		}
		if reply != nil && (reply.Uid != uid || reply.Gid != gid) {
			t.Errorf("%s: the reply reports owner %d:%d, want the tree's %d:%d", what, reply.Uid, reply.Gid, uid, gid)
		}
	}

	var mk fuse.EntryOut
	if st := rfs.Mkdir(nil, &fuse.MkdirIn{InHeader: callerOf(1), Mode: 0o775}, "Video", &mk); st != fuse.OK {
		t.Fatalf("mkdir: %v", st)
	}
	check("a new dir", "Video", &mk.Attr)

	var cr fuse.CreateOut
	if s := rfs.Create(nil, &fuse.CreateIn{InHeader: callerOf(mk.NodeId), Flags: syscall.O_WRONLY, Mode: 0o664}, "copy.mp4", &cr); s != fuse.OK {
		t.Fatalf("create: %v", s)
	}
	rfs.Release(nil, &fuse.ReleaseIn{InHeader: fuse.InHeader{NodeId: cr.NodeId}, Fh: cr.Fh})
	check("a created file", "Video/copy.mp4", &cr.Attr)

	var mn fuse.EntryOut
	if s := rfs.Mknod(nil, &fuse.MknodIn{InHeader: callerOf(mk.NodeId), Mode: syscall.S_IFIFO | 0o664}, "pipe", &mn); s != fuse.OK {
		t.Fatalf("mknod: %v", s)
	}
	check("a new node", "Video/pipe", &mn.Attr)

	shared := lookupID(t, rfs, 1, ".Shared")
	if s := rfs.Rename(nil, &fuse.RenameIn{InHeader: callerOf(shared), Newdir: mk.NodeId}, "h.tmp", "v.mp4"); s != fuse.OK {
		t.Fatalf("a move within one app media root must be a rename: %v", s)
	}
	check("a renamed file", "Video/v.mp4", nil)
}
