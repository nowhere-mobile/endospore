package main

// NWP-20261201-14: MEDIAD RUNS THE LANDER (Q106, slice S4b, docs/media-after-gate.md §3, §6 and §8).
//
// startBgLander starts landBackground on the #media head this session restored, behind NOWHERE_MEDIA_AFTER_GATE. mediad
// stays up while the lander's set is not empty, even with no mount (mediadServe). The lander publishes
// RESTORING <done B> <total B> <files left> (numbers only) and lists what it landed in $STATE/media-bg.list for S5's
// media scan. That list is a plaintext file-name list, so the reap removes it (isSessionFileList).
//
// ⚠ STOP BEFORE ANY UNMOUNT. A file landed into an overlay's hidden directory after its bind is gone lands in an orphan
// directory, its digest reads as landed, and the next seal drops it as a deletion. Each write therefore runs under mu,
// and Stop takes mu: when Stop returns, no write is in progress and none can start. runMediad calls Stop before its
// teardown. A landed path joins the list inside that same section (onWritten): a Stop right after a write still flushes
// it, because the file and its digest exist and S5's scan has no other way to learn the name.
//
// Lock order is mu, then the server's progMu. After Stop the lander publishes nothing and writes no list, so a late
// progress line cannot outlive the teardown that removed it. It logs fixed words and counts: a rel names a user's file.

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// mediaBgListFile is the landed-path list in the state tmpfs, one path per line.
const mediaBgListFile = "media-bg.list"

// mediaScopeServer is the #media scope's server when serveMediaScope made one: the lander publishes through it, so its
// line and that server's LOADING line share one writer.
var mediaScopeServer atomic.Pointer[mediaServer]

// bgResolveKey is a seam: a test panics through it. resolveKey's fail() panics, and startBgLander runs with mounts live.
var bgResolveKey = resolveKey

// bgLander is one mediad's run of landBackground.
type bgLander struct {
	mu       sync.Mutex    // held across each write, each publish and each list flush; Stop takes it
	stopped  atomic.Bool   // set under mu
	done     chan struct{} // closed when landBackground has returned
	wake     chan struct{} // closed by Stop: ends a back-off wait
	stateDir string
	dest     string
	unders   map[string]string
	m        chunkManifest
	prog     *mediaServer
	doneB    int64    // guarded by mu
	totalB   int64    // guarded by mu
	left     int      // guarded by mu
	list     []string // landed paths not flushed yet, guarded by mu
}

func newBgLander(stateDir, dest string, unders map[string]string, m chunkManifest, prog *mediaServer) *bgLander {
	return &bgLander{done: make(chan struct{}), wake: make(chan struct{}), stateDir: stateDir, dest: dest, unders: unders, m: m, prog: prog}
}

// wire returns in with this lander's stop rule, progress and list on its seams.
func (l *bgLander) wire(in landerInput) landerInput {
	in.stop = l.stopped.Load
	in.sleep = l.sleep
	in.commit = l.commit
	in.onStart = l.onStart
	in.onSettled = l.onSettled
	in.onWritten = l.onWritten
	in.onDamaged = l.onDamaged
	return in
}

// commit runs one write under mu, and refuses it once Stop has run.
func (l *bgLander) commit(write func() error) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stopped.Load() {
		return errLanderStopped
	}
	return write()
}

// sleep is the end of a pass that left rels pending: the list is flushed, then a back-off wait that Stop ends.
func (l *bgLander) sleep(d time.Duration) bool {
	l.unlessStopped(l.flushListLocked)
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-l.wake:
		return false
	case <-t.C:
		return true
	}
}

// Stop returns with no write in progress and none to come, and with the list flushed. A nil lander is a no-op.
func (l *bgLander) Stop() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stopped.Swap(true) {
		return
	}
	close(l.wake)
	l.flushListLocked()
}

// doneC is closed when the run has ended. A nil lander has none.
func (l *bgLander) doneC() <-chan struct{} {
	if l == nil {
		return nil
	}
	return l.done
}

// unlessStopped runs fn under mu, and not at all once Stop has run.
func (l *bgLander) unlessStopped(fn func()) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stopped.Load() {
		return
	}
	fn()
}

func (l *bgLander) publishLocked() { l.prog.setRestoring(l.doneB, l.totalB, l.left) }

func (l *bgLander) onStart(pending []string) {
	l.unlessStopped(func() {
		l.left = len(pending)
		for _, rel := range pending {
			l.totalB += l.m.Ess[rel].Size
		}
		l.publishLocked()
	})
}

func (l *bgLander) onSettled(rel string, _ bool) {
	l.unlessStopped(func() {
		l.doneB += l.m.Ess[rel].Size
		l.left--
		l.publishLocked()
	})
}

// onWritten lists a landed path. commit calls it under mu, so it takes no lock.
func (l *bgLander) onWritten(rel string) {
	if strings.ContainsAny(rel, "\n\r") { // the list is one path per line
		return
	}
	p := filepath.Join(l.dest, filepath.FromSlash(rel))
	l.list = append(l.list, p)
	if len(l.list) >= landerBatch {
		l.flushListLocked()
	}
}

func (l *bgLander) onDamaged(rel string) {
	l.unlessStopped(func() {
		l.left--
		l.prog.markBgDamaged(rel)
		l.publishLocked()
	})
}

// flushListLocked writes the held paths out. A failed write keeps them for the next flush.
func (l *bgLander) flushListLocked() {
	if appendMediaBgList(l.stateDir, l.list) == nil {
		l.list = nil
	}
}

// finish ends a run that was not stopped: the last pass's paths are flushed, and a run that a recovered panic ended
// leaves no RESTORING line behind.
func (l *bgLander) finish() {
	l.unlessStopped(func() {
		l.flushListLocked()
		if l.left > 0 {
			l.left = 0
			l.publishLocked()
		}
	})
}

// appendMediaBgList adds paths to the list by temp file and rename in the same directory, 0600: a reader holds the old
// list or the new one, never a torn line. An absent list starts again from paths.
func appendMediaBgList(stateDir string, paths []string) error {
	if len(paths) == 0 {
		return nil
	}
	f := filepath.Join(stateDir, mediaBgListFile)
	old, err := os.ReadFile(f)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	tmp := f + ".tmp"
	if err := os.WriteFile(tmp, append(old, []byte(strings.Join(paths, "\n")+"\n")...), 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, f); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// mediadServe is mediad's wait, and says whether a signal ended it. Mounts wait for a signal only: they serve after the
// lander is done. With no mounts mediad lives as long as the lander, and with neither there is nothing to wait for.
func mediadServe(sig <-chan os.Signal, haveMounts bool, landerDone <-chan struct{}) (signalled bool) {
	if haveMounts {
		<-sig
		return true
	}
	if landerDone == nil {
		return false
	}
	select {
	case <-sig:
		return true
	case <-landerDone:
		return false
	}
}

// startBgLander starts the lander on the head this session restored, or returns nil. It is that head, never the current
// one: S3's seal reads the landed roster against the restored head, and a lander on a newer head would record rels the
// seal does not expect. Each refusal logs one fixed word, so the log never says which profile had what.
func startBgLander(base, scope, pass, mediaDir, stateDir string, mounts []mediaMount) *bgLander {
	refuse := func(why string) *bgLander {
		dlog("mediad: background restore not started: %s (NWP-20261201-14)", why)
		return nil
	}
	if !mediaAfterGateOn() {
		return refuse("flag off")
	}
	if !isSharedMediaScope(scope) || stateDir == "" {
		return refuse("not eligible")
	}
	ref := profileRefV2(scope, pass)
	rh := loginRosterHead(ref)
	if rh == "" || rh == loginRosterNone {
		return refuse("no restored head")
	}
	if !aftergateActive(ref, rh) {
		return refuse("no split")
	}
	var key []byte
	var ok bool
	if err := recovered(func() { key, _, ok = bgResolveKey(base, scope, pass) }); err != nil || !ok {
		return refuse("store")
	}
	m, load := classifyManifestLoad(base, key, rh)
	if load != mlOK {
		return refuse("manifest")
	}
	unders := make(map[string]string, len(mounts))
	for _, mt := range mounts {
		unders[mt.target] = mt.hidden
	}
	prog := mediaScopeServer.Load()
	if prog == nil {
		prog = &mediaServer{progPath: filepath.Join(stateDir, mediaProgressFile)}
	}
	l := newBgLander(stateDir, mediaDir, unders, m, prog)
	in := l.wire(landerInput{base: base, key: key, dk: key, ref: ref, dest: mediaDir, unders: unders})
	goSafe("media lander", func() {
		defer close(l.done)
		defer l.finish()
		landBackground(in, m)
	})
	return l
}
