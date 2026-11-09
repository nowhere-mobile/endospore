package main

// NWP-20261129-08: the lander (Q106 S4a, docs/media-after-gate.md §8): TestMediaLander_L1 to L11, the cases
// test-media-lander.sh runs and mutates. No test sleeps: every sleep seam records its argument and gives up after a
// fixed number of calls, so a mutant that leaves a rel pending for good fails instead of hanging the run.

import (
	"archive/tar"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

const mlPass = "correct horse battery staple"

var mlDK = []byte("media-lander-test-digest-key-000")

func mlReset(t *testing.T) {
	t.Helper()
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCache = nil
}

// mlFrag is one regular file's tar fragment, as an Ess span holds it.
func mlFrag(t *testing.T, name, body string, mode int64, mt time.Time) []byte {
	t.Helper()
	var b bytes.Buffer
	tw := tar.NewWriter(&b)
	if err := tw.WriteHeader(&tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: mode, Size: int64(len(body)), ModTime: mt}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := tw.Flush(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func mlBody(rel string) string { return "the bytes of " + rel }

// mlRun is one fake head and its seams: a head of one chunk per rel, MT from mts (index order when absent), and a fetch
// seam that counts per rel and asks hook first.
type mlRun struct {
	t       *testing.T
	m       chunkManifest
	rels    map[int]string // region start -> rel
	in      landerInput
	fetched []string
	sleeps  []time.Duration
	damaged []string
	hook    func(rel string) ([]byte, error, bool)
	maxWait int // sleep seam returns false after this many calls
}

func mlNew(t *testing.T, rels []string, mts map[string]int64) *mlRun {
	t.Helper()
	mlReset(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	r := &mlRun{t: t, rels: map[int]string{}, maxWait: 16}
	r.m = chunkManifest{EssIdx: true, Ess: map[string]essRegion{}}
	for i, rel := range rels {
		r.m.Chunks = append(r.m.Chunks, fmt.Sprintf("c%d", i))
		mt := int64(1000 + i)
		if v, ok := mts[rel]; ok {
			mt = v
		}
		r.m.Ess[rel] = essRegion{S: i, E: i + 1, Size: int64(len(mlBody(rel))), MT: mt}
		r.rels[i] = rel
	}
	if bg, _ := bgSplit(r.m); len(bg) != len(rels) {
		t.Fatalf("the fixture head does not split as the test needs: bg=%v, want %v", bg, rels)
	}
	r.in = landerInput{dk: mlDK, ref: "mlref", dest: t.TempDir(), key: []byte("unused")}
	r.in.fetch = func(_ string, _ []byte, _ chunkManifest, reg essRegion) ([]byte, error) {
		rel := r.rels[reg.S]
		r.fetched = append(r.fetched, rel)
		if r.hook != nil {
			if frag, err, handled := r.hook(rel); handled {
				return frag, err
			}
		}
		return mlFrag(t, rel, mlBody(rel), 0o640, time.Unix(1700000000, 0)), nil
	}
	r.in.sleep = func(d time.Duration) bool {
		r.sleeps = append(r.sleeps, d)
		return len(r.sleeps) < r.maxWait
	}
	r.in.onDamaged = func(rel string) { r.damaged = append(r.damaged, rel) }
	return r
}

func (r *mlRun) land() landerCounts {
	r.t.Helper()
	var c landerCounts
	captureStdout(r.t, func() { c = landBackground(r.in, r.m) })
	return c
}

func (r *mlRun) path(rel string) string { return filepath.Join(r.in.dest, filepath.FromSlash(rel)) }

// mlRoster is the landed roster's lines, for an exact comparison.
func mlRoster(t *testing.T, ref string) []string {
	t.Helper()
	var out []string
	for d := range readWalkedDigests(landedRosterFile(ref)) {
		out = append(out, d)
	}
	slices.Sort(out)
	return out
}

func mlDigests(dk []byte, rels ...string) []string {
	out := []string{}
	for _, rel := range rels {
		out = append(out, walkedDigest(dk, rel))
	}
	slices.Sort(out)
	return out
}

func mlWant(t *testing.T, got, want []string, what string) {
	t.Helper()
	if !slices.Equal(got, want) && !(len(got) == 0 && len(want) == 0) {
		t.Fatalf("%s: got %v, want %v", what, got, want)
	}
}

func mlWrite(t *testing.T, p, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func mlRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func mlGone(t *testing.T, p string) {
	t.Helper()
	if _, err := os.Lstat(p); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("%s exists (err=%v), it must not", p, err)
	}
}

// mlNoTemp fails on a `.nwsync-` file anywhere under root.
func mlNoTemp(t *testing.T, root string) {
	t.Helper()
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && strings.HasPrefix(d.Name(), ".nwsync-") {
			t.Fatalf("a temp is left behind: %s", p)
		}
		return nil
	})
}

// L1: a real store. Background rels under DCIM, Pictures and Music land through the real fetchEssSpan with their mode
// and mtime, in landerOrder; the roster holds exactly their digests; one count-only line, no rel and no path.
func TestMediaLander_L1_LandsARealHeadInOrder(t *testing.T) {
	mlReset(t)
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	const name = "mlanderl1"
	a, _ := twoWriters(t, name, mlPass)
	mts := map[string]time.Time{
		"DCIM/Camera/old.jpg": time.Unix(1700000000, 0),
		"DCIM/Camera/new.jpg": time.Unix(1700000600, 0),
		"Pictures/mid.png":    time.Unix(1700000300, 0),
		"Music/newest.mp3":    time.Unix(1700009000, 0),
	}
	want := []string{"DCIM/Camera/new.jpg", "Pictures/mid.png", "DCIM/Camera/old.jpg", "Music/newest.mp3"}
	for rel, mt := range mts {
		a.putAt(rel, mlBody(rel), mt)
		if err := os.Chmod(filepath.Join(a.work, filepath.FromSlash(rel)), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	scope := name + "#media"
	m := headManifestOf(t, a.base, scope, mlPass)
	if bg, _ := bgSplit(m); len(bg) != len(want) {
		t.Fatalf("the head does not split as the test needs: bg=%v", bg)
	}
	mlWant(t, landerOrder(m, []string{"Music/newest.mp3", "DCIM/Camera/old.jpg", "Pictures/mid.png", "DCIM/Camera/new.jpg"}), want, "landerOrder")

	dk := resolveDK(a.base, scope, mlPass, nil)
	ref := profileRefV2(scope, mlPass)
	dest := t.TempDir()
	var fetched []string
	in := landerInput{base: a.base, key: dk, dk: dk, ref: ref, dest: dest,
		fetch: func(base string, key []byte, m chunkManifest, r essRegion) ([]byte, error) {
			for rel, e := range m.Ess {
				if e.S == r.S {
					fetched = append(fetched, rel)
				}
			}
			return fetchEssSpan(base, key, m, r)
		},
		sleep: func(time.Duration) bool { t.Error("a clean run must not sleep"); return false },
	}
	var c landerCounts
	out := captureStdout(t, func() { c = landBackground(in, m) })

	mlWant(t, fetched, want, "fetch order")
	var size int64
	for rel, mt := range mts {
		p := filepath.Join(dest, filepath.FromSlash(rel))
		if got := mlRead(t, p); got != mlBody(rel) {
			t.Fatalf("%s holds %q", rel, got)
		}
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o640 || !st.ModTime().Equal(mt) {
			t.Fatalf("%s: mode %v mtime %v, want 0640 and %v", rel, st.Mode().Perm(), st.ModTime(), mt)
		}
		size += st.Size()
	}
	if c != (landerCounts{landed: 4, bytes: size}) {
		t.Fatalf("counts: %+v", c)
	}
	mlWant(t, mlRoster(t, ref), mlDigests(dk, want...), "the landed roster")
	held := loadLandedRoster(ref, dk)
	for _, rel := range want {
		if !held(rel) {
			t.Fatalf("loadLandedRoster reads %s false", rel)
		}
	}
	if st, err := os.Stat(landedRosterFile(ref)); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("the roster file: %v, %v", st, err)
	}
	mlNoTemp(t, dest)
	wantLine := fmt.Sprintf("media lander: landed 4 file(s), %d bytes; 0 skipped, 0 pending, 0 damaged (NWP-20261129-08)\n", size)
	if !strings.Contains(out, wantLine) || strings.Count(out, "media lander:") != 1 {
		t.Fatalf("the log line: %q, want %q once", out, wantLine)
	}
	for _, leak := range []string{"Camera", "new.jpg", "mid.png", "newest", dest} {
		if strings.Contains(out, leak) {
			t.Fatalf("the log names %q: %q", leak, out)
		}
	}
}

// L2: a kill mid-run and a restart. The restart fetches nothing already landed and resurrects nothing deleted; a file
// planted with no digest (the kill between rename and roster write) is skipped with no fetch and its digest recorded.
func TestMediaLander_L2_RestartFetchesNothingLandedAndResurrectsNothing(t *testing.T) {
	rels := []string{"DCIM/a.jpg", "DCIM/b.jpg", "DCIM/c.jpg", "DCIM/d.jpg"}
	r := mlNew(t, rels, nil)
	order := landerOrder(r.m, rels) // d, c, b, a: newest first
	asks := 0
	r.in.stop = func() bool { asks++; return asks > 2 }
	c := r.land()
	if c.landed != 2 || c.pending != 2 {
		t.Fatalf("first run: %+v", c)
	}
	first := slices.Clone(r.fetched)
	mlWant(t, first, order[:2], "first run's fetches")
	mlWant(t, mlRoster(t, "mlref"), mlDigests(mlDK, first...), "the roster before the stop returned")
	if len(r.sleeps) != 0 {
		t.Fatalf("a stop must not sleep: %v", r.sleeps)
	}

	deleted, planted := first[0], order[2]
	if err := os.Remove(r.path(deleted)); err != nil {
		t.Fatal(err)
	}
	mlWrite(t, r.path(planted), "an app's own file")
	r.fetched, r.in.stop = nil, nil
	c = r.land()

	mlWant(t, r.fetched, order[3:], "second run's fetches")
	mlGone(t, r.path(deleted))
	if got := mlRead(t, r.path(planted)); got != "an app's own file" {
		t.Fatalf("the planted file holds %q", got)
	}
	if c.landed != 1 || c.skipped != 1 || c.pending != 0 {
		t.Fatalf("second run: %+v", c)
	}
	mlWant(t, mlRoster(t, "mlref"), mlDigests(mlDK, rels...), "the roster after the restart")
}

// L3: a present rel holding other bytes keeps them, with no fetch.
func TestMediaLander_L3_PresentRelKeepsItsBytes(t *testing.T) {
	r := mlNew(t, []string{"Pictures/p.png"}, nil)
	mlWrite(t, r.path("Pictures/p.png"), "other bytes")
	c := r.land()
	if got := mlRead(t, r.path("Pictures/p.png")); got != "other bytes" {
		t.Fatalf("the present file holds %q", got)
	}
	mlWant(t, r.fetched, nil, "fetches")
	if c != (landerCounts{skipped: 1}) {
		t.Fatalf("counts: %+v", c)
	}
	mlWant(t, mlRoster(t, "mlref"), mlDigests(mlDK, "Pictures/p.png"), "the roster")
}

// mlRaceFetch makes the fetch seam create the target: an app writes the file between the Lstat and the rename.
func mlRaceFetch(t *testing.T, r *mlRun, rel string) {
	r.hook = func(got string) ([]byte, error, bool) {
		if got == rel {
			mlWrite(t, r.path(rel), "the app won")
		}
		return nil, nil, false
	}
}

func mlAssertRaceLost(t *testing.T, r *mlRun, rel string, c landerCounts) {
	t.Helper()
	if got := mlRead(t, r.path(rel)); got != "the app won" {
		t.Fatalf("the app's file holds %q", got)
	}
	mlNoTemp(t, r.in.dest)
	if c.skipped != 1 {
		t.Fatalf("counts: %+v", c)
	}
	if !loadLandedRoster("mlref", mlDK)(rel) {
		t.Fatal("the dropped copy's digest was not recorded")
	}
}

// L4: a file created in the fetch window survives, the copy is dropped.
func TestMediaLander_L4_FetchWindowRaceKeepsTheAppsFile(t *testing.T) {
	r := mlNew(t, []string{"DCIM/race.jpg"}, nil)
	mlRaceFetch(t, r, "DCIM/race.jpg")
	c := r.land()
	mlAssertRaceLost(t, r, "DCIM/race.jpg", c)
	if c.landed != 0 {
		t.Fatalf("counts: %+v", c)
	}
}

// L5: the same through the forced fallback, and a rel with no race lands through the link with its mode and mtime.
func TestMediaLander_L5_TheFallbackRefusesTheSame(t *testing.T) {
	for name, forced := range map[string]error{"EINVAL": unix.EINVAL, "ENOSYS": unix.ENOSYS} {
		t.Run(name, func(t *testing.T) {
			orig := renameat2
			t.Cleanup(func() { renameat2 = orig })
			renameat2 = func(int, string, int, string, uint) error { return forced }
			r := mlNew(t, []string{"DCIM/race.jpg", "DCIM/clean.jpg"}, nil)
			mlRaceFetch(t, r, "DCIM/race.jpg")
			c := r.land()
			mlAssertRaceLost(t, r, "DCIM/race.jpg", c)
			if c.landed != 1 {
				t.Fatalf("counts: %+v", c)
			}
			st, err := os.Stat(r.path("DCIM/clean.jpg"))
			if err != nil {
				t.Fatal(err)
			}
			if st.Mode().Perm() != 0o640 || !st.ModTime().Equal(time.Unix(1700000000, 0)) {
				t.Fatalf("the fallback's file: mode %v mtime %v", st.Mode().Perm(), st.ModTime())
			}
			if got := mlRead(t, r.path("DCIM/clean.jpg")); got != mlBody("DCIM/clean.jpg") {
				t.Fatalf("the fallback's file holds %q", got)
			}
		})
	}
}

// L5b: an error from renameat2 that is not EINVAL or ENOSYS is a refusal to land, not a reason to try the link.
func TestMediaLander_L5b_ARealRenameErrorTakesNoFallback(t *testing.T) {
	orig := renameat2
	t.Cleanup(func() { renameat2 = orig })
	renameat2 = func(int, string, int, string, uint) error { return unix.EIO }
	r := mlNew(t, []string{"DCIM/x.jpg"}, nil)
	r.maxWait = 1
	c := r.land()
	mlGone(t, r.path("DCIM/x.jpg"))
	mlNoTemp(t, r.in.dest)
	if c.pending != 1 || c.landed != 0 {
		t.Fatalf("counts: %+v", c)
	}
	mlWant(t, mlRoster(t, "mlref"), nil, "the roster")
}

// L6a: an overlaid folder lands in its hidden directory, a sibling of dest as mediad's cache dir is, and nothing appears
// at the overlay's path. The real rename and link guard run from the hidden directory.
func TestMediaLander_L6a_OverlaidFolderLandsInItsHiddenDirectory(t *testing.T) {
	r := mlNew(t, []string{"DCIM/f.jpg", "DCIM/Camera/g.jpg", "Pictures/open.png"}, nil)
	hidden := t.TempDir()
	r.in.unders = map[string]string{r.path("DCIM"): hidden}
	c := r.land()
	if got := mlRead(t, filepath.Join(hidden, "f.jpg")); got != mlBody("DCIM/f.jpg") {
		t.Fatalf("hidden/f.jpg holds %q", got)
	}
	if got := mlRead(t, filepath.Join(hidden, "Camera", "g.jpg")); got != mlBody("DCIM/Camera/g.jpg") {
		t.Fatalf("hidden/Camera/g.jpg holds %q", got)
	}
	mlGone(t, r.path("DCIM"))
	if got := mlRead(t, r.path("Pictures/open.png")); got != mlBody("Pictures/open.png") {
		t.Fatalf("the folder with no overlay holds %q", got)
	}
	mlNoTemp(t, hidden)
	if c.landed != 3 || c.pending != 0 {
		t.Fatalf("counts: %+v", c)
	}
	mlWant(t, mlRoster(t, "mlref"), mlDigests(mlDK, "DCIM/f.jpg", "DCIM/Camera/g.jpg", "Pictures/open.png"), "the roster")
}

// L6b and L6c: a symlink planted inside the hidden directory's subpath. Nothing is written through it, nothing is
// fetched, and no digest is recorded, also when the file behind the link already exists.
func TestMediaLander_L6b_NothingGoesThroughALinkInTheHiddenDirectory(t *testing.T) {
	for name, behind := range map[string]string{"nothing_behind": "", "a_file_behind": "the file behind the link"} {
		t.Run(name, func(t *testing.T) {
			r := mlNew(t, []string{"DCIM/sub/f.jpg"}, nil)
			r.maxWait = 2
			hidden, outside := t.TempDir(), t.TempDir()
			if err := os.Symlink(outside, filepath.Join(hidden, "sub")); err != nil {
				t.Fatal(err)
			}
			if behind != "" {
				mlWrite(t, filepath.Join(outside, "f.jpg"), behind)
			}
			r.in.unders = map[string]string{r.path("DCIM"): hidden}
			c := r.land()
			ents, err := os.ReadDir(outside)
			if err != nil {
				t.Fatal(err)
			}
			switch {
			case behind == "" && len(ents) != 0:
				t.Fatalf("written through the link: %v", ents)
			case behind != "" && mlRead(t, filepath.Join(outside, "f.jpg")) != behind:
				t.Fatal("the file behind the link was changed")
			}
			mlWant(t, r.fetched, nil, "fetches")
			mlWant(t, mlRoster(t, "mlref"), nil, "the roster")
			if c.pending != 1 || c.skipped != 0 || c.landed != 0 {
				t.Fatalf("counts: %+v", c)
			}
		})
	}
}

// L6d: a mountpoint that is a string prefix of the rel's directory does not cover it.
func TestMediaLander_L6d_AMountpointDoesNotCoverItsPrefixSibling(t *testing.T) {
	r := mlNew(t, []string{"Download/ab/f.jpg"}, nil)
	hidden := t.TempDir()
	r.in.unders = map[string]string{r.path("Download/a"): hidden}
	r.land()
	if got := mlRead(t, r.path("Download/ab/f.jpg")); got != mlBody("Download/ab/f.jpg") {
		t.Fatalf("the file holds %q", got)
	}
	if ents, _ := os.ReadDir(hidden); len(ents) != 0 {
		t.Fatalf("the sibling's hidden directory holds %v", ents)
	}
}

// L6e: of two covering mountpoints the longest wins.
func TestMediaLander_L6e_TheLongestMountpointWins(t *testing.T) {
	r := mlNew(t, []string{"DCIM/Camera/f.jpg"}, nil)
	outer, inner := t.TempDir(), t.TempDir()
	r.in.unders = map[string]string{r.path("DCIM"): outer, r.path("DCIM/Camera"): inner}
	r.land()
	if got := mlRead(t, filepath.Join(inner, "f.jpg")); got != mlBody("DCIM/Camera/f.jpg") {
		t.Fatalf("the longer mapping's directory holds %q", got)
	}
	if ents, _ := os.ReadDir(outer); len(ents) != 0 {
		t.Fatalf("the shorter mapping's directory holds %v", ents)
	}
}

// L7a: a rel failing transiently twice then succeeding. The others land in pass 1; the sleeps are 30 s then 60 s.
func TestMediaLander_L7a_TransientErrorsBackOff(t *testing.T) {
	r := mlNew(t, []string{"DCIM/flaky.jpg", "DCIM/ok1.jpg", "Music/ok2.mp3"}, nil)
	tries := 0
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == "DCIM/flaky.jpg" {
			tries++
			if tries <= 2 {
				return nil, errors.New("dial tcp: i/o timeout"), true
			}
		}
		return nil, nil, false
	}
	c := r.land()
	mlWant(t, r.fetched[:3], landerOrder(r.m, []string{"DCIM/flaky.jpg", "DCIM/ok1.jpg", "Music/ok2.mp3"}), "pass 1")
	if tries != 3 || len(r.fetched) != 5 {
		t.Fatalf("tries %d, fetches %v", tries, r.fetched)
	}
	if !slices.Equal(r.sleeps, []time.Duration{30 * time.Second, 60 * time.Second}) {
		t.Fatalf("sleeps: %v", r.sleeps)
	}
	if got := mlRead(t, r.path("DCIM/flaky.jpg")); got != mlBody("DCIM/flaky.jpg") {
		t.Fatalf("the retried file holds %q", got)
	}
	if c.landed != 3 || c.pending != 0 || c.damaged != 0 {
		t.Fatalf("counts: %+v", c)
	}
	mlWant(t, r.damaged, nil, "onDamaged")
}

// L7b: a rel that always fails doubles to the 10 min cap and never asks more, and it stays pending.
func TestMediaLander_L7b_TheWaitStopsAtTheCap(t *testing.T) {
	r := mlNew(t, []string{"DCIM/never.jpg"}, nil)
	r.maxWait = 8
	r.hook = func(string) ([]byte, error, bool) { return nil, errors.New("connection refused"), true }
	c := r.land()
	want := []time.Duration{30 * time.Second, 60 * time.Second, 120 * time.Second, 240 * time.Second,
		480 * time.Second, 600 * time.Second, 600 * time.Second, 600 * time.Second}
	if !slices.Equal(r.sleeps, want) {
		t.Fatalf("sleeps: %v", r.sleeps)
	}
	if c.pending != 1 || c.landed != 0 {
		t.Fatalf("counts: %+v", c)
	}
	mlWant(t, mlRoster(t, "mlref"), nil, "the roster")
}

// L7c: a pass that lands something puts the wait back to 30 s.
func TestMediaLander_L7c_ALandingResetsTheWait(t *testing.T) {
	r := mlNew(t, []string{"DCIM/late.jpg", "DCIM/never.jpg"}, nil)
	r.maxWait = 4
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == "DCIM/never.jpg" || len(r.sleeps) < 2 {
			return nil, errors.New("connection refused"), true
		}
		return nil, nil, false
	}
	r.land()
	want := []time.Duration{30 * time.Second, 60 * time.Second, 30 * time.Second, 60 * time.Second}
	if !slices.Equal(r.sleeps, want) {
		t.Fatalf("sleeps: %v", r.sleeps)
	}
}

// mlAssertDamaged is the shape of every damaged case: one fetch of it (or none), onDamaged once, the others land, no
// digest, no sleep.
func mlAssertDamaged(t *testing.T, r *mlRun, bad string, fetches int, c landerCounts) {
	t.Helper()
	n := 0
	for _, rel := range r.fetched {
		if rel == bad {
			n++
		}
	}
	if n != fetches {
		t.Fatalf("%d fetches of the damaged rel, want %d", n, fetches)
	}
	mlWant(t, r.damaged, []string{bad}, "onDamaged")
	if got := mlRead(t, r.path("Pictures/ok.png")); got != mlBody("Pictures/ok.png") {
		t.Fatalf("the other rel holds %q", got)
	}
	if loadLandedRoster("mlref", mlDK)(bad) {
		t.Fatal("a damaged rel's digest was recorded")
	}
	if c.damaged != 1 || c.landed != 1 || c.pending != 0 {
		t.Fatalf("counts: %+v", c)
	}
	if len(r.sleeps) != 0 {
		t.Fatalf("a damaged rel must not wait: %v", r.sleeps)
	}
}

// L8a: a corrupt fetch: one fetch, onDamaged once, never retried, the others land.
func TestMediaLander_L8a_ACorruptFetchStops(t *testing.T) {
	bad := "DCIM/bad.jpg"
	r := mlNew(t, []string{bad, "Pictures/ok.png"}, nil)
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == bad {
			return nil, errors.New("fetch span [0,1): corrupt chunk in store: blob/c0"), true
		}
		return nil, nil, false
	}
	c := r.land()
	mlAssertDamaged(t, r, bad, 1, c)
	mlGone(t, r.path(bad))
}

// L8a2: the real reader's corrupt chunk reads as corrupt, end to end: a blob that does not decrypt under the key.
func TestMediaLander_L8a2_ARealUndecryptableChunkReadsCorrupt(t *testing.T) {
	mlReset(t)
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	const name = "mlanderl8"
	a, _ := twoWriters(t, name, mlPass)
	a.put("DCIM/a.jpg", mlBody("DCIM/a.jpg"))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	scope := name + "#media"
	m := headManifestOf(t, a.base, scope, mlPass)
	dk := resolveDK(a.base, scope, mlPass, nil)
	var damaged []string
	in := landerInput{base: a.base, key: bytes.Repeat([]byte{7}, len(dk)), dk: dk, ref: profileRefV2(scope, mlPass), dest: t.TempDir(),
		onDamaged: func(rel string) { damaged = append(damaged, rel) },
		sleep:     func(time.Duration) bool { t.Error("a corrupt rel must not wait"); return false },
	}
	var c landerCounts
	captureStdout(t, func() { c = landBackground(in, m) })
	mlWant(t, damaged, []string{"DCIM/a.jpg"}, "onDamaged")
	if c != (landerCounts{damaged: 1}) {
		t.Fatalf("counts: %+v", c)
	}
}

// L8b: a span holding another rel counts as damaged. Nothing is written at either rel.
func TestMediaLander_L8b_ASpanHoldingAnotherNameIsDamaged(t *testing.T) {
	bad := "DCIM/bad.jpg"
	r := mlNew(t, []string{bad, "Pictures/ok.png"}, nil)
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == bad {
			return mlFrag(t, "DCIM/other.jpg", "another handset's photo", 0o640, time.Unix(1, 0)), nil, true
		}
		return nil, nil, false
	}
	c := r.land()
	mlAssertDamaged(t, r, bad, 1, c)
	mlGone(t, r.path(bad))
	mlGone(t, r.path("DCIM/other.jpg"))
}

// L8c: a span holding two entries, the first with the right name, counts as damaged.
func TestMediaLander_L8c_ASpanOfTwoEntriesIsDamaged(t *testing.T) {
	bad := "DCIM/bad.jpg"
	r := mlNew(t, []string{bad, "Pictures/ok.png"}, nil)
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == bad {
			return append(mlFrag(t, bad, "first", 0o640, time.Unix(1, 0)), mlFrag(t, "DCIM/second.jpg", "second", 0o640, time.Unix(1, 0))...), nil, true
		}
		return nil, nil, false
	}
	c := r.land()
	mlAssertDamaged(t, r, bad, 1, c)
	mlGone(t, r.path(bad))
}

// L8c2: a span that is not a tar fragment counts as damaged.
func TestMediaLander_L8c2_ASpanThatIsNotATarIsDamaged(t *testing.T) {
	bad := "DCIM/bad.jpg"
	r := mlNew(t, []string{bad, "Pictures/ok.png"}, nil)
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == bad {
			return []byte("this is not a tar fragment"), nil, true
		}
		return nil, nil, false
	}
	c := r.land()
	mlAssertDamaged(t, r, bad, 1, c)
	mlGone(t, r.path(bad))
}

// mlTail is what a damaged span holds after a valid first entry and its padding.
func mlTail(t *testing.T) map[string][]byte {
	t.Helper()
	second := mlFrag(t, "DCIM/second.jpg", "second", 0o640, time.Unix(1, 0))
	var pax bytes.Buffer
	pw := tar.NewWriter(&pax)
	if err := pw.WriteHeader(&tar.Header{Name: "DCIM/second.jpg", Typeflag: tar.TypeReg, Mode: 0o640, Size: 6, ModTime: time.Unix(1, 0),
		Format: tar.FormatPAX, PAXRecords: map[string]string{"comment": "a meta header"}}); err != nil {
		t.Fatal(err)
	}
	return map[string][]byte{
		"invalid_header":        bytes.Repeat([]byte{0x78}, 512),
		"truncated_header":      second[:100],
		"header_with_no_body":   second[:512],
		"meta_header_with_none": pax.Bytes()[:1024],
		"a_single_stray_byte":   {0x78},
		"bytes_after_the_end":   append(make([]byte, 1024), 0x78),
		"entry_after_the_end":   append(make([]byte, 1024), second...),
		"one_zero_block_first":  append(make([]byte, 512), 0x78),
	}
}

// L8c3: a valid first entry followed by anything but zero bytes is damaged, before any write or digest.
func TestMediaLander_L8c3_AMalformedTailIsDamaged(t *testing.T) {
	for name, tail := range mlTail(t) {
		t.Run(name, func(t *testing.T) {
			bad := "DCIM/bad.jpg"
			r := mlNew(t, []string{bad, "Pictures/ok.png"}, nil)
			r.hook = func(rel string) ([]byte, error, bool) {
				if rel == bad {
					return append(mlFrag(t, bad, "first", 0o640, time.Unix(1, 0)), tail...), nil, true
				}
				return nil, nil, false
			}
			c := r.land()
			mlAssertDamaged(t, r, bad, 1, c)
			mlGone(t, r.path(bad))
		})
	}
}

// L8c4: a header-aligned span lands: padded, ended with the two zero blocks, or a body of whole blocks with no padding.
func TestMediaLander_L8c4_AHeaderAlignedSpanLands(t *testing.T) {
	const rel = "DCIM/good.jpg"
	whole := strings.Repeat("b", 1024)
	var closed bytes.Buffer
	tw := tar.NewWriter(&closed)
	if err := tw.WriteHeader(&tar.Header{Name: rel, Typeflag: tar.TypeReg, Mode: 0o640, Size: 5, ModTime: time.Unix(1, 0)}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write([]byte("short")); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	for name, span := range map[string]struct {
		frag []byte
		body string
	}{
		"padded":          {mlFrag(t, rel, "short", 0o640, time.Unix(1, 0)), "short"},
		"end_of_archive":  {closed.Bytes(), "short"},
		"whole_blocks":    {mlFrag(t, rel, whole, 0o640, time.Unix(1, 0)), whole},
		"padding_cut_off": {mlFrag(t, rel, "short", 0o640, time.Unix(1, 0))[:517], "short"},
	} {
		t.Run(name, func(t *testing.T) {
			r := mlNew(t, []string{rel}, nil)
			r.hook = func(string) ([]byte, error, bool) { return span.frag, nil, true }
			c := r.land()
			if got := mlRead(t, r.path(rel)); got != span.body {
				t.Fatalf("the file holds %q", got)
			}
			if c.landed != 1 || c.damaged != 0 {
				t.Fatalf("counts: %+v", c)
			}
			mlWant(t, mlRoster(t, "mlref"), mlDigests(mlDK, rel), "the roster")
		})
	}
}

// L8d: a rel with a `..` component is damaged, with no fetch, and nothing lands outside dest.
func TestMediaLander_L8d_ARelThatLeavesDestIsDamaged(t *testing.T) {
	bad := "DCIM/../../escape.jpg"
	r := mlNew(t, []string{bad, "Pictures/ok.png"}, nil)
	c := r.land()
	mlAssertDamaged(t, r, bad, 0, c)
	mlGone(t, filepath.Join(filepath.Dir(r.in.dest), "escape.jpg"))
}

// L8e: `..` inside a name is a real file name.
func TestMediaLander_L8e_DotsInsideANameLand(t *testing.T) {
	r := mlNew(t, []string{"DCIM/IMG..1.jpg"}, nil)
	if c := r.land(); c.landed != 1 {
		t.Fatalf("counts: %+v", c)
	}
	if got := mlRead(t, r.path("DCIM/IMG..1.jpg")); got != mlBody("DCIM/IMG..1.jpg") {
		t.Fatalf("the file holds %q", got)
	}
}

// L9: the order, over MT ties and folders. The input slice is not aliased.
func TestMediaLander_L9_Order(t *testing.T) {
	m := chunkManifest{Ess: map[string]essRegion{
		"Android/media/p/a.bin": {MT: 900},
		"DCIM/b.jpg":            {MT: 100},
		"DCIM/a.jpg":            {MT: 100},
		"DCIM2/x.jpg":           {MT: 999},
		"Download/d.pdf":        {MT: 500},
		"Movies/m.mp4":          {MT: 500},
		"Music/n.mp3":           {MT: 700},
		"Pictures/c.png":        {MT: 300},
		"Pictures/z.png":        {MT: 100},
	}}
	in := []string{"Music/n.mp3", "DCIM/b.jpg", "Movies/m.mp4", "Pictures/z.png", "DCIM2/x.jpg", "Android/media/p/a.bin",
		"Download/d.pdf", "DCIM/a.jpg", "Pictures/c.png"}
	orig := slices.Clone(in)
	want := []string{"Pictures/c.png", "DCIM/a.jpg", "DCIM/b.jpg", "Pictures/z.png",
		"DCIM2/x.jpg", "Android/media/p/a.bin", "Music/n.mp3", "Download/d.pdf", "Movies/m.mp4"}
	mlWant(t, landerOrder(m, in), want, "landerOrder")
	mlWant(t, in, orig, "the input slice")
}

// L10: digests are written in batches of 32, and all of them by the end.
func TestMediaLander_L10_TheRosterIsWrittenEvery32(t *testing.T) {
	var rels []string
	for i := 0; i < 40; i++ {
		rels = append(rels, fmt.Sprintf("DCIM/f%02d.jpg", i))
	}
	r := mlNew(t, rels, nil)
	seen := -1
	r.hook = func(string) ([]byte, error, bool) {
		if len(r.fetched) == 34 {
			seen = len(mlRoster(t, "mlref"))
		}
		return nil, nil, false
	}
	r.land()
	if seen != 32 {
		t.Fatalf("the roster held %d digests when the 34th fetch started, want 32", seen)
	}
	mlWant(t, mlRoster(t, "mlref"), mlDigests(mlDK, rels...), "the final roster")
}

// L11: recordLandedRoster unions, and "" (receipts off) is a no-op that a run survives.
func TestMediaLander_L11_RecordLandedRosterUnions(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	recordLandedRoster("mlu", mlDK, []string{"DCIM/a.jpg"})
	recordLandedRoster("mlu", mlDK, []string{"DCIM/b.jpg", "DCIM/a.jpg"})
	recordLandedRoster("mlu", mlDK, nil)
	mlWant(t, mlRoster(t, "mlu"), mlDigests(mlDK, "DCIM/a.jpg", "DCIM/b.jpg"), "the union")
	ents, err := os.ReadDir(restoreReceiptDir())
	if err != nil || len(ents) != 1 {
		t.Fatalf("the receipts directory: %v, %v", ents, err)
	}

	recordLandedRoster("", mlDK, []string{"DCIM/a.jpg"})
	t.Setenv("NOWHERE_STATE", "")
	recordLandedRoster("mlu", mlDK, []string{"DCIM/a.jpg"}) // nowhere to write: no panic, nothing to read back
	if loadLandedRoster("mlu", mlDK)("DCIM/a.jpg") {
		t.Fatal("receipts off: nothing can read as landed")
	}
}
