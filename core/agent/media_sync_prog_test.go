package main

// NWP-20261204-19: the post-seal media sync writes a counts-only "sizes" frame per chunk it fetches
// (media_sync_prog.go), so the stall watchdog sees it move. test-media-sync-prog.sh runs these with --mutate.

import (
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type msprogFrame struct {
	phase       string
	done, total int
}

// recordMediaSyncProg replaces the frame writer with a recorder of (phase, done, total) until the test ends.
func recordMediaSyncProg(t *testing.T) *[]msprogFrame {
	t.Helper()
	var frames []msprogFrame
	old := mediaSyncProgWrite
	mediaSyncProgWrite = func(done, total int) {
		ph, _ := progPhase.Load().(string)
		frames = append(frames, msprogFrame{ph, done, total})
	}
	t.Cleanup(func() { mediaSyncProgWrite = old })
	return &frames
}

// msprogPhase sets progPhase to "prepare" (the seal's phase while the sync runs) and restores it at the end.
func msprogPhase(t *testing.T) {
	t.Helper()
	prev, _ := progPhase.Load().(string)
	setProgPhase("prepare")
	t.Cleanup(func() { setProgPhase(prev) })
}

// msprogBody is n bytes of seeded pseudo-random data: the chunker cuts it into ~1 MiB chunks, the same every run.
func msprogBody(n int) string {
	b := make([]byte, n)
	rand.New(rand.NewSource(20261204)).Read(b)
	return string(b)
}

// msprogDeferred seals a ~6 MiB DEFERRED photo on a fresh profile and returns its store, key, head and rel.
func msprogDeferred(t *testing.T, name string) (base string, key []byte, m chunkManifest, rel string) {
	t.Helper()
	deferredMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, name, "correct horse battery staple")
	rel = "DCIM/Camera/IMG_msprog.jpg"
	a.put(rel, msprogBody(6<<20))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	requireDeferred(t, a, rel)
	m = headManifestOf(t, a.base, a.name+"#media", a.pass)
	if n := len(m.Deferred[rel].Chunks); n < 3 {
		t.Fatalf("the fixture photo is %d chunk(s); it must be at least 3 or a per-file frame passes", n)
	}
	return a.base, resolveDK(a.base, a.name+"#media", a.pass, nil), m, rel
}

// msprogEssential seals a ~6 MiB ESSENTIAL file (outside the media trees, so never deferred) on a fresh profile.
func msprogEssential(t *testing.T, name string) (base string, key []byte, m chunkManifest, rel string) {
	t.Helper()
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, name, "correct horse battery staple")
	rel = "Documents/msprog.bin"
	a.put(rel, msprogBody(6<<20))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	m = headManifestOf(t, a.base, a.name+"#media", a.pass)
	r, ok := m.Ess[rel]
	if !ok {
		t.Fatalf("the fixture did not index %s as essential: %v", rel, keysOfEss(m.Ess))
	}
	if r.E-r.S < 2 {
		t.Fatalf("the fixture's span is %d chunk(s); it must be at least 2 or a per-file frame passes", r.E-r.S)
	}
	return a.base, resolveDK(a.base, a.name+"#media", a.pass, nil), m, rel
}

// requireFramePerChunk asserts one "sizes" frame per chunk, done 1..n, total never below done and n at the end,
// and the phase restored.
func requireFramePerChunk(t *testing.T, frames []msprogFrame, n int) {
	t.Helper()
	if len(frames) != n {
		t.Fatalf("the sync wrote %d frame(s) for %d chunk(s); the stall watchdog needs one per chunk: %v", len(frames), n, frames)
	}
	for i, f := range frames {
		if f.phase != "sizes" {
			t.Errorf("frame %d has phase %q; a chunk count must be \"sizes\" or the gate draws it as bytes", i+1, f.phase)
		}
		if f.done != i+1 || f.total < f.done {
			t.Errorf("frame %d is done=%d total=%d; want done=%d and total >= done", i+1, f.done, f.total, i+1)
		}
	}
	if last := frames[n-1]; last.total != n {
		t.Errorf("the last frame plans %d chunk(s); the file has %d", last.total, n)
	}
	if ph, _ := progPhase.Load().(string); ph != "prepare" {
		t.Errorf("the phase after the sync is %q; it must be restored to \"prepare\" for the seal's later frames", ph)
	}
}

func TestMediaSyncProg_ADeferredArrivalWritesAFramePerChunk(t *testing.T) {
	base, key, m, rel := msprogDeferred(t, "msprogdef")
	msprogPhase(t)
	frames := recordMediaSyncProg(t)
	dest := t.TempDir()
	wrote, _ := materializeDeferredArrivals(base, key, m, []string{rel}, dest, 1<<30, &mediaSyncProg{})
	if len(wrote) != 1 {
		t.Fatalf("the deferred photo did not land (wrote %v); nothing below is exercised", wrote)
	}
	requireFramePerChunk(t, *frames, len(m.Deferred[rel].Chunks))
}

func TestMediaSyncProg_AnEssentialSpanWritesAFramePerChunk(t *testing.T) {
	base, key, m, rel := msprogEssential(t, "msprogess")
	msprogPhase(t)
	frames := recordMediaSyncProg(t)
	dest := t.TempDir()
	wrote, _ := materializeCarried(base, key, m, []string{rel}, dest, 1<<30, &mediaSyncProg{})
	if len(wrote) != 1 {
		t.Fatalf("the essential file did not land (wrote %v); nothing below is exercised", wrote)
	}
	r := m.Ess[rel]
	requireFramePerChunk(t, *frames, r.E-r.S)
}

func TestMediaSyncProg_NothingFetchedWritesNothing(t *testing.T) {
	present := func(t *testing.T, rel string) string {
		dest := t.TempDir()
		p := filepath.Join(dest, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("this session holds it"), 0o644); err != nil {
			t.Fatal(err)
		}
		return dest
	}
	check := func(t *testing.T, what string, frames []msprogFrame, p *mediaSyncProg) {
		t.Helper()
		if len(frames) != 0 || p.done != 0 || p.total != 0 {
			t.Errorf("%s: nothing was fetched, yet the sync wrote %d frame(s) (done=%d total=%d)", what, len(frames), p.done, p.total)
		}
	}
	t.Run("deferred", func(t *testing.T) {
		base, key, m, rel := msprogDeferred(t, "msprognodef")
		frames := recordMediaSyncProg(t)
		p := &mediaSyncProg{}
		materializeDeferredArrivals(base, key, m, nil, t.TempDir(), 1<<30, p)
		check(t, "no rels", *frames, p)
		materializeDeferredArrivals(base, key, m, []string{rel}, present(t, rel), 1<<30, p)
		check(t, "a rel already on disk", *frames, p)
	})
	t.Run("essential", func(t *testing.T) {
		base, key, m, rel := msprogEssential(t, "msprognoess")
		frames := recordMediaSyncProg(t)
		p := &mediaSyncProg{}
		materializeCarried(base, key, m, nil, t.TempDir(), 1<<30, p)
		check(t, "no rels", *frames, p)
		materializeCarried(base, key, m, []string{rel}, present(t, rel), 1<<30, p)
		check(t, "a rel already on disk", *frames, p)
	})
}

// THE SEAL'S OWN SYNC WRITES IT. B's periodic #media seal lands A's deferred photo; in direct mode (no capFlush, so
// no lease-leg "sizes" frame) the sync must write one "sizes 1 1" frame, and it must reach roam.progress. The
// sync's frames are recorded at mediaSyncProgWrite on their way to the file: the seal's own frames end at the same
// "sizes 1 1 media" in this fixture, so the file's last line alone cannot say the sync wrote it (round 66's
// integration: with the sync's prog nil the test still passed, test-media-sync-prog.sh M5).
func TestMediaSyncProg_TheSyncOfASealWritesIt(t *testing.T) {
	a, b := syncOversizeFixture(t, "msprogseal", "1000000")
	const photo = "DCIM/Camera/IMG_msprog_seal.jpg"
	publishDeferred(t, a, photo, 300)
	if capMode() {
		t.Fatal("the fixture runs in cap mode; capFlush's lease leg could write the \"sizes\" frame this test reads")
	}
	prog := filepath.Join(t.TempDir(), "roam.progress")
	t.Setenv("NOWHERE_PROGRESS", prog)
	var syncFrames []msprogFrame
	write := mediaSyncProgWrite
	mediaSyncProgWrite = func(done, total int) {
		ph, _ := progPhase.Load().(string)
		syncFrames = append(syncFrames, msprogFrame{ph, done, total})
		write(done, total)
	}
	t.Cleanup(func() { mediaSyncProgWrite = write })
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	if !landed(b, photo) {
		t.Fatal("B's seal did not land A's photo; nothing below is exercised")
	}
	got, err := os.ReadFile(prog)
	if err != nil {
		t.Fatalf("read %s: %v", prog, err)
	}
	// The photo is one chunk, so the sync's one frame is "sizes 1 1", and the file still ends at it: nothing the seal
	// writes after the sync may leave a later line.
	if len(syncFrames) != 1 || syncFrames[0] != (msprogFrame{"sizes", 1, 1}) {
		t.Fatalf("the seal's sync wrote frames %v, want exactly one {sizes 1 1}: the sync must write a frame per chunk "+
			"or the stall watchdog sees nothing move while it runs", syncFrames)
	}
	if line := strings.TrimSpace(string(got)); line != "sizes 1 1 media" {
		t.Fatalf("the last frame of a seal whose sync fetched a one-chunk file is %q, want \"sizes 1 1 media\": the "+
			"sync must write a frame per chunk or the stall watchdog sees nothing move while it runs", line)
	}
}

func TestMediaSyncProg_NilIsSilent(t *testing.T) {
	t.Run("deferred", func(t *testing.T) {
		base, key, m, rel := msprogDeferred(t, "msprognildef")
		frames := recordMediaSyncProg(t)
		if b, err := fetchDeferredBytes(base, key, m.Version, m.Deferred[rel], nil); err != nil || int64(len(b)) != m.Deferred[rel].Size {
			t.Fatalf("fetchDeferredBytes with a nil prog: err=%v len=%d", err, len(b))
		}
		if wrote, _ := materializeDeferredArrivals(base, key, m, []string{rel}, t.TempDir(), 1<<30, nil); len(wrote) != 1 {
			t.Fatalf("materializeDeferredArrivals with a nil prog landed %v", wrote)
		}
		if len(*frames) != 0 {
			t.Errorf("a nil prog wrote %d frame(s): %v", len(*frames), *frames)
		}
	})
	t.Run("essential", func(t *testing.T) {
		base, key, m, rel := msprogEssential(t, "msprognioess")
		frames := recordMediaSyncProg(t)
		if _, err := fetchEssSpan(base, key, m, m.Ess[rel], nil); err != nil {
			t.Fatalf("fetchEssSpan with a nil prog: %v", err)
		}
		if wrote, _ := materializeCarried(base, key, m, []string{rel}, t.TempDir(), 1<<30, nil); len(wrote) != 1 {
			t.Fatalf("materializeCarried with a nil prog landed %v", wrote)
		}
		if len(*frames) != 0 {
			t.Errorf("a nil prog wrote %d frame(s): %v", len(*frames), *frames)
		}
	})
}
