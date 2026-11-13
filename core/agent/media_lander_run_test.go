package main

// NWP-20261201-14: mediad runs the lander (Q106 S4b, docs/media-after-gate.md §8): TestMediaBgRun R1 to R6, the cases
// test-media-lander-run.sh runs and mutates.

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const mbrWait = 200 * time.Millisecond // the two bounded negative checks: R1 and R4

// mbrProg is a progress writer on its own state directory, the shape of startBgLander's fallback.
func mbrProg(t *testing.T) (*mediaServer, string) {
	t.Helper()
	state := t.TempDir()
	return &mediaServer{progPath: filepath.Join(state, mediaProgressFile)}, state
}

func mbrReadProg(t *testing.T, s *mediaServer) string {
	t.Helper()
	b, err := os.ReadFile(s.progPath)
	if err != nil {
		t.Fatalf("the progress file: %v", err)
	}
	return string(b)
}

func mbrWaitClosed(t *testing.T, c <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-c:
	case <-time.After(30 * time.Second):
		t.Fatalf("%s did not end", what)
	}
}

// mbrLand is one landed rel as the lander reports it: the write's section, then the settlement.
func mbrLand(l *bgLander, rel string) {
	_ = l.commit(func() error { l.onWritten(rel); return nil })
	l.onSettled(rel, true)
}

func mbrList(state string) string {
	b, _ := os.ReadFile(filepath.Join(state, mediaBgListFile))
	return string(b)
}

// R1: mediad stays up while the set is not empty, even with no mounts.
func TestMediaBgRun_R1_MediadServeWaits(t *testing.T) {
	sig := make(chan os.Signal, 1)
	done := make(chan struct{})
	res := make(chan bool, 1)
	go func() { res <- mediadServe(sig, false, done) }()
	select {
	case <-res:
		t.Fatal("no mounts and a running lander: mediadServe returned")
	case <-time.After(mbrWait):
	}
	close(done)
	select {
	case got := <-res:
		if got {
			t.Fatal("a finished lander is not a signal")
		}
	case <-time.After(30 * time.Second):
		t.Fatal("mediadServe did not return when the lander finished")
	}

	if mediadServe(sig, false, nil) {
		t.Fatal("no mounts and no lander reads as a signal")
	}

	closed := make(chan struct{})
	close(closed)
	mounted := make(chan bool, 1)
	go func() { mounted <- mediadServe(sig, true, closed) }()
	select {
	case <-mounted:
		t.Fatal("mounts must serve after the lander is done")
	case <-time.After(mbrWait):
	}
	sig <- syscall.SIGTERM
	select {
	case got := <-mounted:
		if !got {
			t.Fatal("a signal must read as a signal")
		}
	case <-time.After(30 * time.Second):
		t.Fatal("mediadServe did not return on the signal")
	}

	running := make(chan struct{})
	sig <- syscall.SIGTERM
	if !mediadServe(sig, false, running) {
		t.Fatal("no mounts, a running lander and a signal must read as a signal")
	}
}

// R2: the line alone, its place after the others, and its end.
func TestMediaBgRun_R2_TheLineIsNumbersAndLast(t *testing.T) {
	s, _ := mbrProg(t)
	s.setRestoring(10, 100, 3)
	if got := mbrReadProg(t, s); got != "RESTORING 10 100 3\n" {
		t.Fatalf("alone: %q", got)
	}

	s.progMu.Lock()
	s.active = map[string]fetchProg{"k": {name: "big.map", done: 1, total: 2}}
	s.dmg = map[string]string{"j": "bad.jpg"}
	s.progMu.Unlock()
	s.setRestoring(20, 100, 2)
	want := "LOADING 1 2 1 big.map\nDAMAGED 1 bad.jpg\nRESTORING 20 100 2\n"
	if got := mbrReadProg(t, s); got != want {
		t.Fatalf("with the others: %q, want %q", got, want)
	}

	s.setRestoring(100, 100, 0)
	if got := mbrReadProg(t, s); got != "LOADING 1 2 1 big.map\nDAMAGED 1 bad.jpg\n" {
		t.Fatalf("left 0 must drop only its own line: %q", got)
	}

	s.progMu.Lock()
	s.active, s.dmg = nil, nil
	s.progMu.Unlock()
	s.setRestoring(10, 100, 1)
	s.setRestoring(100, 100, 0)
	if _, err := os.Stat(s.progPath); !os.IsNotExist(err) {
		t.Fatalf("left 0 with nothing else must remove the file: %v", err)
	}

	quiet := &mediaServer{}
	quiet.setRestoring(1, 2, 3) // progPath "": publishes nothing
	quiet.markBgDamaged("a/b.jpg")
	if quiet.restoring.left != 0 || quiet.dmg != nil {
		t.Fatal("a server with no progress path must hold nothing")
	}
}

// A damaged rel is the DAMAGED line, on a key no cache uses, and it is not logged.
func TestMediaBgRun_R2_ADamagedRelIsTheDamagedLine(t *testing.T) {
	s, state := mbrProg(t)
	l := newBgLander(state, t.TempDir(), nil, chunkManifest{}, s)
	l.onStart([]string{"DCIM/bad.jpg"})
	l.onDamaged("DCIM/bad.jpg")
	if got := mbrReadProg(t, s); got != "DAMAGED 1 bad.jpg\n" {
		t.Fatalf("got %q", got)
	}
	for k := range s.dmg {
		if !strings.HasPrefix(k, "bg:") {
			t.Fatalf("the key %q is not under the lander's prefix", k)
		}
	}
	src, err := os.ReadFile("media_server.go")
	if err != nil {
		t.Fatal(err)
	}
	body := regexp.MustCompile(`(?s)func \(s \*mediaServer\) markBgDamaged.*?\n}\n`).Find(src)
	if body == nil || strings.Contains(string(body), "dlog(") {
		t.Fatalf("markBgDamaged must exist and log nothing: %s", body)
	}
}

// After Stop the lander says nothing: a late line would outlive the teardown that removed the file.
func TestMediaBgRun_R2_NothingIsPublishedAfterStop(t *testing.T) {
	s, state := mbrProg(t)
	m := chunkManifest{Ess: map[string]essRegion{"a": {Size: 5}, "b": {Size: 7}}}
	l := newBgLander(state, t.TempDir(), nil, m, s)
	l.onStart([]string{"a", "b"})
	if got := mbrReadProg(t, s); got != "RESTORING 0 12 2\n" {
		t.Fatalf("got %q", got)
	}
	l.Stop()
	mbrLand(l, "a")
	l.onDamaged("b")
	if got := mbrReadProg(t, s); got != "RESTORING 0 12 2\n" {
		t.Fatalf("a publish after Stop: %q", got)
	}
	if got := mbrList(state); got != "" {
		t.Fatalf("a list write after Stop: %q", got)
	}
}

// End to end on a real head: the line never names a file, and it goes when the set is empty.
func TestMediaBgRun_R2_EndToEndHoldsNoName(t *testing.T) {
	mlReset(t)
	essentialMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	const name = "mbrr2endtoend"
	a, _ := twoWriters(t, name, mlPass)
	rels := []string{"DCIM/ZQX-a.jpg", "Pictures/ZQX-b.png", "Music/ZQX-c.mp3"}
	var total int64
	for _, rel := range rels {
		a.putAt(rel, mlBody(rel), time.Unix(1700000000, 0))
		total += int64(len(mlBody(rel)))
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	scope := name + "#media"
	m := headManifestOf(t, a.base, scope, mlPass)
	dk := resolveDK(a.base, scope, mlPass, nil)
	dest := t.TempDir()
	mlWrite(t, filepath.Join(dest, "Music", "ZQX-c.mp3"), "the app's own bytes")

	s := &mediaServer{progPath: filepath.Join(state, mediaProgressFile)}
	l := newBgLander(state, dest, nil, m, s)
	in := l.wire(landerInput{base: a.base, key: dk, dk: dk, ref: profileRefV2(scope, mlPass), dest: dest})
	line := regexp.MustCompile(`^RESTORING \d+ ` + fmt.Sprint(total) + ` [1-3]\n$`)
	reads := 0
	in.fetch = func(base string, key []byte, m chunkManifest, r essRegion) ([]byte, error) {
		got := mbrReadProg(t, s)
		reads++
		if !line.MatchString(got) || strings.Contains(got, "ZQX") {
			t.Errorf("the progress file during the run: %q", got)
		}
		return fetchEssSpan(base, key, m, r)
	}
	var c landerCounts
	captureStdout(t, func() { c = landBackground(in, m) })
	if c.landed != 2 || c.skipped != 1 || reads != 2 {
		t.Fatalf("counts %+v, reads %d", c, reads)
	}
	if _, err := os.Stat(s.progPath); !os.IsNotExist(err) {
		b, _ := os.ReadFile(s.progPath)
		t.Fatalf("the set is empty and the file holds %q (%v)", b, err)
	}
	if strings.Contains(mbrList(state), "ZQX-c") {
		t.Fatal("a file the lander did not place must not be listed")
	}
}

// R3: the list's write, its growth and what it names.
func TestMediaBgRun_R3_TheListIsAtomic(t *testing.T) {
	state := t.TempDir()
	f := filepath.Join(state, mediaBgListFile)
	if err := appendMediaBgList(state, []string{"/m/one"}); err != nil {
		t.Fatal(err)
	}
	h, err := os.Open(f)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	if err := appendMediaBgList(state, []string{"/m/two", "/m/three"}); err != nil {
		t.Fatal(err)
	}
	old, err := io.ReadAll(h)
	if err != nil {
		t.Fatal(err)
	}
	if string(old) != "/m/one\n" {
		t.Fatalf("a reader's open file changed: %q", old)
	}
	if got := mbrList(state); got != "/m/one\n/m/two\n/m/three\n" {
		t.Fatalf("two flushes: %q", got)
	}
	st, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", st.Mode().Perm())
	}
	mlGone(t, f+".tmp")
	if err := os.Remove(f); err != nil {
		t.Fatal(err)
	}
	if err := appendMediaBgList(state, []string{"/m/four"}); err != nil {
		t.Fatal(err)
	}
	if got := mbrList(state); got != "/m/four\n" {
		t.Fatalf("a removed list must restart: %q", got)
	}
	if err := appendMediaBgList(state, nil); err != nil {
		t.Fatal(err)
	}
	if got := mbrList(state); got != "/m/four\n" {
		t.Fatalf("an empty flush changed the list: %q", got)
	}
}

func TestMediaBgRun_R3_TheListNamesTheLowerPath(t *testing.T) {
	const rel = "DCIM/under.jpg"
	r := mlNew(t, []string{rel}, nil)
	hidden := t.TempDir()
	r.in.unders = map[string]string{filepath.Join(r.in.dest, "DCIM"): hidden}
	state := t.TempDir()
	s := &mediaServer{progPath: filepath.Join(state, mediaProgressFile)}
	l := newBgLander(state, r.in.dest, r.in.unders, r.m, s)
	r.in = l.wire(r.in)
	if c := r.land(); c.landed != 1 {
		t.Fatalf("counts %+v", c)
	}
	if got := mlRead(t, filepath.Join(hidden, "under.jpg")); got != mlBody(rel) {
		t.Fatalf("the hidden directory holds %q", got)
	}
	mlGone(t, r.path(rel))
	l.finish()
	if got, want := mbrList(state), r.path(rel)+"\n"; got != want {
		t.Fatalf("the list holds %q, want %q", got, want)
	}
}

func TestMediaBgRun_R3_WhatIsListedAndWhen(t *testing.T) {
	s, state := mbrProg(t)
	dest := t.TempDir()
	l := newBgLander(state, dest, nil, chunkManifest{}, s)
	rels := []string{"DCIM/a\nb.jpg", "DCIM/c\rd.jpg", "DCIM/present.jpg", "DCIM/real.jpg"}
	var batch []string
	for i := 0; i < landerBatch-1; i++ {
		batch = append(batch, fmt.Sprintf("Music/%02d.mp3", i))
	}
	l.onStart(append(append([]string{}, rels...), batch...))
	mbrLand(l, rels[0])
	mbrLand(l, rels[1])
	l.onSettled(rels[2], false)
	mbrLand(l, rels[3])
	if got := mbrList(state); got != "" {
		t.Fatalf("a flush below a batch: %q", got)
	}
	for _, rel := range batch {
		mbrLand(l, rel)
	}
	got := mbrList(state)
	if n := strings.Count(got, "\n"); n != landerBatch {
		t.Fatalf("a full batch wrote %d line(s): %q", n, got)
	}
	if !strings.HasPrefix(got, filepath.Join(dest, "DCIM/real.jpg")+"\n") {
		t.Fatalf("the list: %q", got)
	}
	for _, bad := range []string{"\r", "a\nb", "present"} {
		if strings.Contains(got, bad) {
			t.Fatalf("the list holds %q: %q", bad, got)
		}
	}

	stopped, stoppedState := mbrProg(t)
	sl := newBgLander(stoppedState, dest, nil, chunkManifest{}, stopped)
	sl.onStart([]string{"DCIM/one.jpg", "DCIM/two.jpg"})
	mbrLand(sl, "DCIM/one.jpg")
	sl.Stop()
	if got, want := mbrList(stoppedState), filepath.Join(dest, "DCIM/one.jpg")+"\n"; got != want {
		t.Fatalf("Stop must flush: %q, want %q", got, want)
	}

	for _, n := range []string{"media-bg.list", "media-bg.list.tmp"} {
		if !isSessionFileList(n) {
			t.Fatalf("%s is a plaintext file-name list and the reap must take it", n)
		}
	}
}

// R4: Stop waits for a write in progress, and none starts after it.
func TestMediaBgRun_R4_StopWaitsForAWrite(t *testing.T) {
	s, state := mbrProg(t)
	l := newBgLander(state, t.TempDir(), nil, chunkManifest{}, s)
	inWrite := make(chan struct{})
	release := make(chan struct{})
	committed := make(chan error, 1)
	go func() {
		committed <- l.commit(func() error { close(inWrite); <-release; return nil })
	}()
	mbrWaitClosed(t, inWrite, "the write")
	stopped := make(chan struct{})
	go func() { l.Stop(); close(stopped) }()
	select {
	case <-stopped:
		close(release)
		t.Fatal("Stop returned with a write in progress")
	case <-time.After(mbrWait):
	}
	close(release)
	mbrWaitClosed(t, stopped, "Stop")
	if err := <-committed; err != nil {
		t.Fatalf("the write in progress: %v", err)
	}

	ran := false
	if err := l.commit(func() error { ran = true; return nil }); err != errLanderStopped {
		t.Fatalf("a commit after Stop: %v", err)
	}
	if ran {
		t.Fatal("a commit after Stop ran its write")
	}
	l.Stop() // a second Stop is a no-op
	var none *bgLander
	none.Stop()
	if none.doneC() != nil {
		t.Fatal("a nil lander has no done channel")
	}
}

func TestMediaBgRun_R4_AFetchReleasedAfterStopWritesNothing(t *testing.T) {
	const rel = "DCIM/late.jpg"
	r := mlNew(t, []string{rel, "Music/next.mp3"}, nil)
	hidden := t.TempDir()
	r.in.unders = map[string]string{filepath.Join(r.in.dest, "DCIM"): hidden}
	state := t.TempDir()
	s := &mediaServer{progPath: filepath.Join(state, mediaProgressFile)}
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	r.hook = func(string) ([]byte, error, bool) {
		once.Do(func() { close(entered) })
		<-release
		return nil, nil, false
	}
	l := newBgLander(state, r.in.dest, r.in.unders, r.m, s)
	r.in = l.wire(r.in)
	res := make(chan landerCounts, 1)
	go func() { res <- landBackground(r.in, r.m) }()
	mbrWaitClosed(t, entered, "the fetch")
	l.Stop()
	close(release)
	var c landerCounts
	select {
	case c = <-res:
	case <-time.After(30 * time.Second):
		t.Fatal("the run did not end after Stop")
	}
	mlGone(t, filepath.Join(hidden, "late.jpg"))
	mlGone(t, r.path(rel))
	if got := mlRoster(t, r.in.ref); len(got) != 0 {
		t.Fatalf("the roster holds %v", got)
	}
	if c.pending < 1 || c.landed != 0 {
		t.Fatalf("counts %+v", c)
	}
}

// RF-001: a Stop between a finished write and its settlement. The file and its digest exist, so the list must name it.
func TestMediaBgRun_R4_StopRightAfterAWriteStillLists(t *testing.T) {
	const rel = "DCIM/boundary.jpg"
	r := mlNew(t, []string{rel}, nil)
	state := t.TempDir()
	s := &mediaServer{progPath: filepath.Join(state, mediaProgressFile)}
	l := newBgLander(state, r.in.dest, nil, r.m, s)
	r.in = l.wire(r.in)
	commit := r.in.commit
	r.in.commit = func(write func() error) error {
		err := commit(write)
		l.Stop()
		return err
	}
	if c := r.land(); c.landed != 1 {
		t.Fatalf("counts %+v", c)
	}
	if got := mlRead(t, r.path(rel)); got != mlBody(rel) {
		t.Fatalf("the file holds %q", got)
	}
	if got := mlRoster(t, r.in.ref); len(got) != 1 {
		t.Fatalf("the roster holds %v", got)
	}
	if got, want := mbrList(state), r.path(rel)+"\n"; got != want {
		t.Fatalf("the list holds %q, want %q", got, want)
	}
}

// A copy dropped because a file appeared in the fetch window is not the lander's file: the list does not name it.
func TestMediaBgRun_R3_ADroppedCopyIsNotListed(t *testing.T) {
	const rel = "DCIM/raced.jpg"
	r := mlNew(t, []string{rel}, nil)
	r.hook = func(string) ([]byte, error, bool) {
		mlWrite(t, r.path(rel), "the app's own bytes")
		return nil, nil, false
	}
	state := t.TempDir()
	s := &mediaServer{progPath: filepath.Join(state, mediaProgressFile)}
	l := newBgLander(state, r.in.dest, nil, r.m, s)
	r.in = l.wire(r.in)
	if c := r.land(); c.skipped != 1 || c.landed != 0 {
		t.Fatalf("counts %+v", c)
	}
	l.finish()
	if got := mbrList(state); got != "" {
		t.Fatalf("the list holds %q", got)
	}
}

// A wait in the back-off ends on Stop, and each wait flushes what the pass landed.
func TestMediaBgRun_R4_StopEndsTheWait(t *testing.T) {
	s, state := mbrProg(t)
	l := newBgLander(state, t.TempDir(), nil, chunkManifest{}, s)
	l.onStart([]string{"DCIM/a.jpg", "DCIM/b.jpg"})
	mbrLand(l, "DCIM/a.jpg")
	res := make(chan bool, 1)
	go func() { res <- l.sleep(time.Hour) }()
	deadline := time.Now().Add(30 * time.Second)
	for mbrList(state) == "" && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if mbrList(state) == "" {
		t.Fatal("the end of a pass did not flush the list")
	}
	l.Stop()
	select {
	case got := <-res:
		if got {
			t.Fatal("a wait Stop ended must read as stop")
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Stop did not end the wait")
	}
}

// R5: a real head and every gate.
func TestMediaBgRun_R5_Start(t *testing.T) {
	mlReset(t)
	essentialMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	mediaScopeServer.Store(nil)
	t.Cleanup(func() { mediaScopeServer.Store(nil) })
	const name = "mbrr5start"
	const rel = "DCIM/Camera/r5.jpg"
	a, _ := twoWriters(t, name, mlPass)
	a.putAt(rel, mlBody(rel), time.Unix(1700000000, 0))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	scope := name + "#media"
	rh := a.head("#media")
	ref := profileRefV2(scope, mlPass)
	dest := t.TempDir()
	marker := func(body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(aftergateFile(ref)), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(aftergateFile(ref), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	start := func() *bgLander { return startBgLander(a.base, scope, mlPass, dest, state, nil) }
	refused := func(what string, f func() *bgLander) {
		t.Helper()
		if l := f(); l != nil {
			l.Stop()
			mbrWaitClosed(t, l.done, "the run")
			t.Fatalf("%s: a lander started", what)
		}
		mlGone(t, filepath.Join(dest, filepath.FromSlash(rel)))
	}

	writeLoginRoster(ref, rh)
	refused("no marker", start)
	marker("deadbeef")
	refused("a marker naming another head", start)
	marker(rh)
	writeLoginRosterNone(ref)
	refused("the roster none", start)
	writeLoginRoster(ref, rh)

	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "")
	refused("the flag off", start)
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	refused("a scope that is not #media", func() *bgLander { return startBgLander(a.base, name, mlPass, dest, state, nil) })
	refused("no state directory", func() *bgLander { return startBgLander(a.base, scope, mlPass, dest, "", nil) })
	orig := bgResolveKey
	bgResolveKey = func(string, string, string) ([]byte, []byte, bool) { panic("a store failure") }
	refused("a store that panics", start)
	bgResolveKey = orig

	l := start()
	if l == nil {
		t.Fatal("every gate holds and no lander started")
	}
	mbrWaitClosed(t, l.done, "the run")
	p := filepath.Join(dest, filepath.FromSlash(rel))
	if got := mlRead(t, p); got != mlBody(rel) {
		t.Fatalf("landed %q", got)
	}
	if !loadLandedRoster(ref, resolveDK(a.base, scope, mlPass, nil))(rel) {
		t.Fatal("the landed roster does not hold the rel")
	}
	if got := mbrList(state); got != p+"\n" {
		t.Fatalf("the list: %q", got)
	}
	mlGone(t, filepath.Join(state, mediaProgressFile))
}

// R6: runMediad's order, from its source.
func TestMediaBgRun_R6_StopPrecedesTheTeardown(t *testing.T) {
	src, err := os.ReadFile("mediafs.go")
	if err != nil {
		t.Fatal(err)
	}
	body := regexp.MustCompile(`(?s)func runMediad\(.*?\n}\n`).FindString(string(src))
	if body == "" {
		t.Fatal("runMediad not found")
	}
	before := func(a, b string, s string) {
		t.Helper()
		i, j := strings.Index(s, a), strings.Index(s, b)
		if i < 0 || j < 0 || i >= j {
			t.Fatalf("%q (at %d) must precede %q (at %d)", a, i, b, j)
		}
	}
	before("signal.Notify(", "startBgLander(", body)
	before("os.Remove(filepath.Join(stateDir, mediaProgressFile))", "serveMediaScope(", body)
	_, after, ok := strings.Cut(body, "mediadServe(")
	if !ok {
		t.Fatal("runMediad does not wait through mediadServe")
	}
	before("lander.Stop()", "os.Remove(", after)
	before("lander.Stop()", ".Unmount(", after)
}
