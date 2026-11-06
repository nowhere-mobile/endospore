package main

// NWP-20260908-21: MID-SESSION SYNC -- the bytes, not just the index.
//
// NWP-20260908-04 made another handset's media survive this handset's seal, which fixed the ACCOUNT. It did
// nothing for the phone in your hand: the carry re-emits spans BY HASH without ever holding the bytes, so the
// file only lands at the next login restore. Told that was the answer, Chester's reply was that signing out
// and back in "is mostly not practical" -- which is the whole reason this exists.

import (
	"archive/tar"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// THE FEATURE. A takes a photo; B seals; B now HAS the photo on disk, in the same session.
func TestMediaSync_AnotherHandsetsPhotoLandsWithoutALogin(t *testing.T) {
	essentialMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	syncOut := filepath.Join(state, "mediasync.list")
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", syncOut)

	a, b := twoWriters(t, "mediasync", "correct horse battery staple")
	ref := profileRefV2("mediasync#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, atLogin) })

	const photo = "DCIM/from-a.jpg"
	const body = "a small photo, under the deferral floor, so it rides the essential tar"
	a.put(photo, body)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}

	// B has never held it. Before B's seal it is not on B's disk -- the negative control, because a fixture
	// that already had the file would pass no matter what the sync did.
	target := filepath.Join(b.work, filepath.FromSlash(photo))
	if _, err := os.Lstat(target); err == nil {
		t.Fatal("the photo is already on B before any sync -- this fixture proves nothing")
	}

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("A's photo did not land on B (%v).\n\n"+
			"The carry keeps it in the ACCOUNT head, so nothing is lost -- but the bytes reach this phone "+
			"only at the next login restore, and signing out mid-session is not something a user can be "+
			"asked to do. That gap is what this slice closes.", err)
	}
	if string(got) != body {
		t.Errorf("the photo landed with the wrong bytes: %q", string(got))
	}

	// And roamd has to be TOLD, or the file is on disk and invisible: nothing in this tree triggers a media
	// scan, and MediaStore does not notice a write it did not mediate (device-proven, NWP-20260908-18).
	list, err := os.ReadFile(syncOut)
	if err != nil {
		t.Fatalf("no media-sync list for roamd (%v) -- the bytes would be on disk and the gallery would never "+
			"show them, which is a fix that looks exactly like no fix", err)
	}
	if !strings.Contains(string(list), target) {
		t.Errorf("the sync list does not name the file that landed.\ngot:  %q\nwant a line: %s",
			string(list), target)
	}
}

// A DELETION MUST NOT BE FETCHED BACK. Same absence, opposite meaning: this rel is one B ITSELF restored, so
// its being gone is the user deleting it. The carry already declines to re-emit it; the sync must not quietly
// fetch it back, or deleting a photo becomes impossible in a way that looks like a feature.
func TestMediaSync_ADeletedFileIsNotFetchedBack(t *testing.T) {
	essentialMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", filepath.Join(state, "mediasync.list"))

	a, b := twoWriters(t, "syncdel", "correct horse battery staple")
	ref := profileRefV2("syncdel#media", "correct horse battery staple")

	const rel = "DCIM/delete-me.jpg"
	a.put(rel, "a photo the user will delete on B")
	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")

	// B logged in holding BOTH -- that is what makes the later absence a deletion rather than a gap.
	b.put(rel, "a photo the user will delete on B")
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, atLogin) })
	b.rm(rel)

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	if _, err := os.Lstat(filepath.Join(b.work, filepath.FromSlash(rel))); err == nil {
		t.Fatal("the sync FETCHED BACK a photo the user deleted. The roster is what separates 'another " +
			"handset published this' from 'I had it and it is gone', and a materialize that ignores it makes " +
			"deletion impossible -- every cycle would put the photo straight back on disk.")
	}
}

// THE NEVER-CLOBBER GUARD, TESTED DIRECTLY -- because the seal cannot reach it.
//
// The carry only ever selects rels the walk did NOT see, so through pushProfile the guard is unreachable and a
// mutation that deletes it survives every end-to-end test above. I found that by running the mutation, not by
// reading the code. But "absent from the walk" is not "absent from disk": a path under a SkipDir, or a file an
// app creates between the walk and this write, is both. So the guard is real, and it is exercised here at the
// only level that can reach it.
func TestMediaSync_MaterializeRefusesToOverwriteAnExistingFile(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "syncdirect", "correct horse battery staple")

	const rel = "DCIM/contested.jpg"
	a.put(rel, "the copy in the account head")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if _, ok := m.Ess[rel]; !ok {
		t.Fatalf("the fixture did not index %s, so nothing below is exercised: %v", rel, keysOfEss(m.Ess))
	}
	key := resolveDK(a.base, a.name+"#media", a.pass, nil)

	// A destination that ALREADY has the file, with different bytes.
	dest := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dest, "DCIM"), 0o755); err != nil {
		t.Fatal(err)
	}
	local := filepath.Join(dest, filepath.FromSlash(rel))
	if err := os.WriteFile(local, []byte("THIS SESSION WROTE THIS"), 0o644); err != nil {
		t.Fatal(err)
	}

	wrote, n := materializeCarried(a.base, key, m, []string{rel}, dest)

	got, err := os.ReadFile(local)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if string(got) != "THIS SESSION WROTE THIS" {
		t.Fatalf("materialize OVERWROTE a file that was already on disk (now %q). untarFrom opens every entry "+
			"O_TRUNC, which is why the whole-scope restore cannot be re-run mid-session; a per-rel materialize "+
			"inherits exactly that hazard unless it refuses a rel that is present.", string(got))
	}
	if len(wrote) != 0 || n != 0 {
		t.Errorf("it reported writing %d file(s)/%d B for a rel it correctly did not touch -- roamd would then "+
			"scan a path nothing changed", len(wrote), n)
	}
}

// NWP-20260908-24: A LANDED FILE TAKES ITS OWNERSHIP FROM THE SCOPE ROOT, NOT ITS OWN DIRECTORY.
//
// The first device run landed the screenshot as uid=0 gid=1023 -- root-owned -- because its directory had
// been created by this same code path and had nothing better to inherit. It worked (MediaProvider decoded
// the file) but it is not what a real photo looks like, and the storage pass-through DAC-checks the OWNER,
// so "it happened to work" is the whole of the argument for leaving it.
//
// roamd's remap_tree is the reference behaviour: after a login restore it re-owns the tree to "the uid:gid
// Android gave DIR itself", meaning the scope root. This does the same, per file, because mid-session
// remap_tree is unavailable (NWP-20260908-19).
//
// The two lookups and the chown go through the materializeOwnerOf / materializeChown seams, so this runs as any
// user: the first form chowned a real fixture apart and skipped unless root, which the CI runner is not, so
// nothing ever executed the root-before-parent order.
func TestMediaSync_OwnershipComesFromTheScopeRootNotTheParentDir(t *testing.T) {
	type owner struct {
		uid, gid int
		ok       bool
	}
	cases := []struct {
		name      string
		emptyRoot bool
		owners    func(root, dir string) map[string]owner
		chownErr  error
		want      []owner // one entry per expected chown (ok is unused)
	}{
		{
			name: "root_wins_over_a_root_owned_dir",
			owners: func(root, dir string) map[string]owner {
				return map[string]owner{root: {1023, 1023, true}, dir: {0, 0, true}}
			},
			want: []owner{{uid: 1023, gid: 1023}},
		},
		{
			name: "dir_when_the_root_cannot_be_read",
			owners: func(root, dir string) map[string]owner {
				return map[string]owner{root: {0, 0, false}, dir: {1023, 9997, true}}
			},
			want: []owner{{uid: 1023, gid: 9997}},
		},
		{
			name:   "no_owner_no_chown",
			owners: func(root, dir string) map[string]owner { return map[string]owner{} },
		},
		{
			name: "a_failing_chown_is_best_effort",
			owners: func(root, dir string) map[string]owner {
				return map[string]owner{root: {1023, 1023, true}}
			},
			chownErr: errors.New("operation not permitted"),
			want:     []owner{{uid: 1023, gid: 1023}},
		},
		{
			name:      "empty_root_is_never_looked_up",
			emptyRoot: true,
			owners: func(root, dir string) map[string]owner {
				// The "" entry is a trap: a lookup of "" would both be recorded and chown to 0:0.
				return map[string]owner{"": {0, 0, true}, dir: {1023, 9997, true}}
			},
			want: []owner{{uid: 1023, gid: 9997}},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := t.TempDir()
			target := filepath.Join(root, "Pictures", "Screenshots", "landed.png")
			dir := filepath.Dir(target)
			owners := c.owners(root, dir)
			var looked []string
			var chowns []chownRec
			oldChown, oldOwnerOf := materializeChown, materializeOwnerOf
			t.Cleanup(func() { materializeChown, materializeOwnerOf = oldChown, oldOwnerOf })
			materializeOwnerOf = func(path string) (int, int, bool) {
				looked = append(looked, path)
				o := owners[path]
				return o.uid, o.gid, o.ok
			}
			materializeChown = func(path string, uid, gid int) error {
				chowns = append(chowns, chownRec{path, uid, gid})
				return c.chownErr
			}
			rootArg := root
			if c.emptyRoot {
				rootArg = ""
			}
			hdr := &tar.Header{Mode: 0o660, ModTime: time.Unix(1788000000, 0)}
			if err := writeMaterialized(target, rootArg, hdr, []byte("bytes")); err != nil {
				t.Fatalf("writeMaterialized: %v (a media file's ownership is best effort)", err)
			}
			if b, err := os.ReadFile(target); err != nil || string(b) != "bytes" {
				t.Fatalf("landed file = %q, %v; want the bytes", b, err)
			}
			if c.emptyRoot {
				for _, p := range looked {
					if p == "" {
						t.Errorf("the empty scope root was looked up; lookups = %q", looked)
					}
				}
			}
			if len(chowns) != len(c.want) {
				t.Fatalf("chowns = %+v, want %d of the temp file", chowns, len(c.want))
			}
			for i, w := range c.want {
				got := chowns[i]
				if got.uid != w.uid || got.gid != w.gid {
					t.Errorf("landed file is chowned to %d:%d, want %d:%d (the SCOPE ROOT's ownership, else the "+
						"parent directory's only when the root cannot be read). Taking it from the parent "+
						"directory first is what produced a root-owned screenshot on the first device run "+
						"(NWP-20260908-24): the parent had been created by this same code path, so there "+
						"was nothing correct to inherit.", got.uid, got.gid, w.uid, w.gid)
				}
				if filepath.Dir(got.path) != dir || !strings.HasPrefix(filepath.Base(got.path), ".nwsync-") {
					t.Errorf("chown path %q, want the .nwsync-* temp file in %q, not the final target", got.path, dir)
				}
			}
		})
	}
}
