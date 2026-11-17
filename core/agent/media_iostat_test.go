package main

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261205-08: mediad's read-latency evidence for the in-session issue report (media_iostat.go).

type mediaIOCounts struct {
	rd, rdbg, stub                         [mediaIOBuckets]int64
	active, bgRuns, bgMs, bgFiles, bgBytes int64
}

func mediaIOSnap() mediaIOCounts {
	var c mediaIOCounts
	for i := 0; i < mediaIOBuckets; i++ {
		c.rd[i], c.rdbg[i], c.stub[i] = mediaIO.rd[i].Load(), mediaIO.rdbg[i].Load(), mediaIO.stub[i].Load()
	}
	c.active, c.bgRuns, c.bgMs = mediaIO.active.Load(), mediaIO.bgRuns.Load(), mediaIO.bgMs.Load()
	c.bgFiles, c.bgBytes = mediaIO.bgFiles.Load(), mediaIO.bgBytes.Load()
	return c
}

func mediaIOSum(r [mediaIOBuckets]int64) int64 {
	var n int64
	for _, v := range r {
		n += v
	}
	return n
}

// mediaIOResetForTest zeroes every counter and restores the seams when the test ends.
func mediaIOResetForTest(t *testing.T) {
	t.Helper()
	start, cpu := mediaIOStart, mediaIOCPU
	zero := func() {
		for i := 0; i < mediaIOBuckets; i++ {
			mediaIO.rd[i].Store(0)
			mediaIO.rdbg[i].Store(0)
			mediaIO.stub[i].Store(0)
		}
		mediaIO.active.Store(0)
		mediaIO.bgRuns.Store(0)
		mediaIO.bgMs.Store(0)
		mediaIO.bgFiles.Store(0)
		mediaIO.bgBytes.Store(0)
	}
	zero()
	t.Cleanup(func() { zero(); mediaIOStart, mediaIOCPU = start, cpu })
}

func TestMediaIOBucket(t *testing.T) {
	for _, tc := range []struct {
		d    time.Duration
		want int
	}{
		{999 * time.Microsecond, 0},
		{time.Millisecond, 1},
		{9999 * time.Microsecond, 1},
		{10 * time.Millisecond, 2},
		{49 * time.Millisecond, 2},
		{50 * time.Millisecond, 3},
		{249 * time.Millisecond, 3},
		{250 * time.Millisecond, 4},
	} {
		if got := mediaIOBucket(tc.d); got != tc.want {
			t.Errorf("mediaIOBucket(%v) = %d, want %d", tc.d, got, tc.want)
		}
	}
}

func TestMediaIOLatencyOnlyRead(t *testing.T) {
	mediaIOResetForTest(t)
	var l mediaIOLat
	for _, op := range []string{"LOOKUP", "OPEN", "WRITE"} {
		l.Add(op, 5*time.Millisecond)
	}
	if c := mediaIOSnap(); mediaIOSum(c.rd)+mediaIOSum(c.rdbg)+mediaIOSum(c.stub) != 0 {
		t.Fatalf("an op that is not READ was counted: %+v", c)
	}
	l.Add("READ", 5*time.Millisecond)
	if c := mediaIOSnap(); c.rd[1] != 1 || mediaIOSum(c.rdbg) != 0 {
		t.Fatalf("a READ with no run active must land in rd[1]: %+v", c)
	}
	bgT := mediaBgBegin()
	l.Add("READ", 5*time.Millisecond)
	if c := mediaIOSnap(); c.rd[1] != 1 || c.rdbg[1] != 1 {
		t.Fatalf("a READ with a run active must land in rdbg[1]: %+v", c)
	}
	mediaBgEnd(bgT, 0, 0)
}

func TestMediaIOBgRun(t *testing.T) {
	mediaIOResetForTest(t)
	mediaBgEnd(mediaBgBegin(), 3, 4096)
	if c := mediaIOSnap(); c.bgRuns != 1 || c.bgFiles != 3 || c.bgBytes != 4096 || c.active != 0 {
		t.Fatalf("one run of 3 files, 4096 bytes: got %+v", c)
	}
	var l mediaIOLat
	a := mediaBgBegin()
	b := mediaBgBegin()
	mediaBgEnd(a, 0, 0)
	l.Add("READ", 0)
	if c := mediaIOSnap(); c.rdbg[0] != 1 || c.rd[0] != 0 {
		t.Fatalf("a READ while one of two runs is still active must land in rdbg: %+v", c)
	}
	mediaBgEnd(b, 0, 0)
	l.Add("READ", 0)
	if c := mediaIOSnap(); c.rd[0] != 1 || c.active != 0 {
		t.Fatalf("a READ after both runs ended must land in rd, gauge 0: %+v", c)
	}
}

// Drives the real materialize as TestMaterializePinnedMakesLocalAndEssential does, over the same two deferred maps,
// but with no overlay mounted: materialize writes only to the .under dir, and overlayRaceSetup self-skips where
// there is no FUSE (the CI runner), which would let this test pass without running.
func TestMediaIOMaterialize(t *testing.T) {
	preGateSeal(t)
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	base := newHTTPStore(t)
	name, pass := "iostatmat", "mat horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	for n, b := range map[string][]byte{"one.mwm": prBytes(6 << 20), "two.mwm": append(prBytes(5<<20), 0xEE)} {
		if err := os.WriteFile(filepath.Join(src, "app.maps/files/maps", n), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	pushProfile(base, name, pass, src)
	dk := resolveDK(base, name, pass, nil)
	m1 := headManifest(t, base, dk, name, pass)
	if len(m1.Deferred) != 2 {
		t.Fatalf("setup: want 2 deferred, got %d", len(m1.Deferred))
	}
	cache := t.TempDir()
	under := filepath.Join(cache, ".under", "app.maps_files_maps")
	if err := os.MkdirAll(under, 0o700); err != nil {
		t.Fatal(err)
	}
	srv := newMediaServer(base, dk, m1, cache)
	before := mediaIOSnap()
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)
	after := mediaIOSnap()
	want := m1.Deferred["app.maps/files/maps/one.mwm"].Size + m1.Deferred["app.maps/files/maps/two.mwm"].Size
	if d := after.bgFiles - before.bgFiles; d != 2 {
		t.Fatalf("bgfiles grew by %d, want the 2 files materialize landed", d)
	}
	if d := after.bgBytes - before.bgBytes; d != want {
		t.Fatalf("bgbytes grew by %d, want %d", d, want)
	}
	if after.bgRuns <= before.bgRuns || after.active != before.active {
		t.Fatalf("materialize must count one run and leave the gauge as it found it: before %+v after %+v", before, after)
	}
}

// The fixture is TestRangeServesChunkGranular's.
func TestMediaIOStubRead(t *testing.T) {
	tr := trackGoSafe(t)
	defer tr.wait(t, 10*time.Second)
	var srv *mediaServer
	stateDirMustStayGone(t, func() string {
		if srv == nil {
			return ""
		}
		return filepath.Dir(srv.cacheDir)
	})
	preGateSeal(t)
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "iostatstub", "stub horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755); err != nil {
		t.Fatal(err)
	}
	rel := "app.maps/files/maps/region.mwm"
	if err := os.WriteFile(filepath.Join(src, rel), prBytes(9<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	dk := resolveDK(base, name, pass, nil)
	m := headManifest(t, base, dk, name, pass)
	if !m.Deferred[rel].rangeable() {
		t.Fatal("setup: the file must be a range-mapped deferred file")
	}
	srv = newMediaServer(base, dk, m, t.TempDir())
	ctx := context.Background()

	before := mediaIOSum(mediaIOSnap().stub)
	h := &mediaRangeHandle{f: &mediaFile{srv: srv, rel: rel, df: m.Deferred[rel]}}
	if _, errno := h.Read(ctx, make([]byte, 4096), 0); errno != 0 {
		t.Fatalf("stub read: errno %v", errno)
	}
	h.Release(ctx)
	if d := mediaIOSum(mediaIOSnap().stub) - before; d != 1 {
		t.Fatalf("one stub read counted %d, want 1", d)
	}
	bad := &mediaRangeHandle{f: &mediaFile{srv: srv, rel: "app.maps/files/maps/absent.mwm"}}
	if _, errno := bad.Read(ctx, make([]byte, 4096), 0); errno == 0 {
		t.Fatal("a read of a rel the server does not hold must fail")
	}
	bad.Release(ctx)
	if d := mediaIOSum(mediaIOSnap().stub) - before; d != 2 {
		t.Fatalf("a failed stub read must count too: total %d, want 2", d)
	}
}

func TestMediaIOLine(t *testing.T) {
	mediaIOResetForTest(t)
	now := time.Unix(1_800_000_000, 0)
	mediaIOStart = now.Add(-42 * time.Second)
	mediaIOCPU = func() int64 { return 7 }
	for i := 0; i < mediaIOBuckets; i++ {
		mediaIO.rd[i].Store(int64(i + 1))
		mediaIO.rdbg[i].Store(int64(10 * i))
		mediaIO.stub[i].Store(int64(100 + i))
	}
	mediaIO.bgRuns.Store(2)
	mediaIO.bgMs.Store(3500)
	mediaIO.bgFiles.Store(4)
	mediaIO.bgBytes.Store(123456)
	got := mediaIOLine(10, now)
	want := "v=1 u=10 up=42 rd=1/2/3/4/5 rdbg=0/10/20/30/40 stub=100/101/102/103/104 bg=2 bgms=3500 bgfiles=4 bgbytes=123456 cpums=7"
	if got != want {
		t.Fatalf("mediaIOLine:\n got %q\nwant %q", got, want)
	}
	if !mediaIOLineRE.MatchString(got) {
		t.Fatalf("mergeMediaIO's grammar refuses mediaIOLine's own output: %q", got)
	}
}

func TestMediaIOMerge(t *testing.T) {
	mediaIOResetForTest(t)
	dest := t.TempDir()
	line := mediaIOLine(10, time.Now())
	write := func(s string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dest, mediaIOFile), []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	merge := func(uid string, device bool) (string, bool) {
		st := map[string]string{"media_io": "sent by the caller"}
		mergeMediaIO(st, dest, uid, device)
		v, ok := st["media_io"]
		return v, ok
	}

	// no file: nothing, and a caller-sent value is dropped
	if v, ok := merge("10", false); ok {
		t.Fatalf("no file must add nothing, got %q", v)
	}
	write(line + "\n")
	v, ok := merge("10", false)
	if !ok || !regexp.MustCompile(`^`+regexp.QuoteMeta(line)+` age=[0-9]+$`).MatchString(v) {
		t.Fatalf("session scope, this uid: got %q (present %v)", v, ok)
	}
	if v, ok := merge("10", true); ok {
		t.Fatalf("device scope must add nothing, got %q", v)
	}
	if v, ok := merge("11", false); ok {
		t.Fatalf("another session's uid must add nothing, got %q", v)
	}
	if v, ok := merge("", false); ok {
		t.Fatalf("no live session must add nothing, got %q", v)
	}
	for _, bad := range []string{
		line + " x=1",
		strings.Replace(line, " bg=0 ", " bg=1a ", 1),
		strings.Replace(line, " bg=0 ", " bg=/data/user/10 ", 1),
		strings.Replace(line, " rd=0/0/0/0/0 ", " rd=0/0/0/0 ", 1),
	} {
		if bad == line {
			t.Fatalf("a bad case did not change the line: %q", bad)
		}
		write(bad + "\n")
		if v, _ := merge("10", false); v != "unreadable" {
			t.Errorf("a damaged file %q must merge as unreadable, got %q", bad, v)
		}
		if v, ok := merge("10", true); ok {
			t.Errorf("device scope must add nothing even for a damaged file, got %q", v)
		}
	}
}

// Source pin: the latency map is set before the serve loop starts, every overlay mounts through it, and runMediad
// clears an old file and starts the publisher.
func TestMediaIOMountWiring(t *testing.T) {
	code := func(file, fn string) string {
		t.Helper()
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		lines := stripComments(funcBody(t, string(b), fn))
		trail := regexp.MustCompile(`\s+//.*$`)
		for i, l := range lines {
			lines[i] = trail.ReplaceAllString(l, "")
		}
		return strings.Join(lines, "\n")
	}
	serve := code("mediafs.go", "serveMediaScope")
	if !strings.Contains(serve, "mediaMountServe(target, root, mediaMountOptions())") || strings.Contains(serve, "fs.Mount(") {
		t.Error("serveMediaScope must mount through mediaMountServe, never fs.Mount")
	}
	ms := code("media_iostat.go", "mediaMountServe")
	rec, gs := strings.Index(ms, "RecordLatencies(mediaIOLat{})"), strings.Index(ms, "goSafe(")
	if rec < 0 || gs < 0 || rec > gs {
		t.Errorf("mediaMountServe must call RecordLatencies before the serve loop starts (RecordLatencies at %d, goSafe at %d)", rec, gs)
	}
	run := code("mediafs.go", "runMediad")
	if !strings.Contains(run, "os.Remove(filepath.Join(stateDir, mediaIOFile))") {
		t.Error("runMediad must remove an earlier mediad's media.iostat")
	}
	if !strings.Contains(run, `goSafeLoop("media iostat", func() { mediaIOPublish(stateDir, u) })`) {
		t.Error("runMediad must start the media iostat publisher")
	}
}
