package main

// NWP-20261024-13: a test that starts goSafe jobs (handleLogout's "logoff", its stall watchdog, the wallet seal, the
// deleted-profile check) must not return while one is still running: a job that outlives its test writes into a state
// dir the test's cleanup already removed, and a path-creating write (os.MkdirAll) puts the t.TempDir() root back with
// nothing to report it. trackGoSafe counts every job from the instant goSafe is called (the start hook runs before
// the go statement), tr.wait joins them, and stateDirMustStayGone fails a test whose temp root exists again once its
// cleanups have run, naming what came back. The self-tests below pin all of it; test-rearm-inbox-tempdir.sh breaks
// each part in turn.
//
// NWP-20261128-35: the stand-in for roamd (cutoffWorkerGated) does this join itself, for every sign-out test. Affected
// CI recorded eleven staging calls in one test's recorder: some op was handed over after its stand-in had stopped, so it
// held the process-wide RW lane for its whole 150 s stall budget, every later test's logoff queued behind it, those
// tests failed at their bounds, and the logoffs they left met the recorder of the test that was running when the lane
// came free. So the stand-in answers until its test's sign-outs have finished, before the stubs and the state dir go.

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type goSafeTracker struct {
	mu     sync.Mutex
	wg     sync.WaitGroup
	live   map[string]int
	parked map[uint64]bool // the goroutine of each live "logoff" job in reapOrReboot's first wait, or past it
	owner  *testing.T
}

// goSafeTrackerNow is the installed tracker, nil when none is.
var goSafeTrackerNow atomic.Pointer[goSafeTracker]

// Installed once and never replaced by a sign-out test: reapWaitHook's own tests save and restore it. A logoff in its
// reap wait is parked: it sleeps 8 s + 12 s and touches no lane, state dir or stub again, so a join does not wait it out.
// END-UNSAVED and a delete enter the same "switch" wait from their own jobs; the handleLogout frame keeps them out.
func init() {
	reapWaitHook = func(phase string) {
		if tr := goSafeTrackerNow.Load(); tr != nil && phase == "switch" && inHandleLogout() {
			tr.park()
		}
	}
}

// goroutineStack is the calling goroutine's stack, as far as a logoff's depth needs.
func goroutineStack() string {
	buf := make([]byte, 16<<10)
	return string(buf[:runtime.Stack(buf, false)])
}

// inHandleLogout reports whether the caller runs in a closure of handleLogout (its "logoff" job).
func inHandleLogout() bool {
	return strings.Contains(goroutineStack(), "nowhereagent.handleLogout.")
}

// goroutineID is the number in the first line of the caller's stack, "goroutine 7 [running]:". The tracker has no other
// link from a job to its goroutine: goSafe calls the start hook on the goroutine that starts the job.
func goroutineID() uint64 {
	f := strings.Fields(goroutineStack())
	if len(f) < 2 || f[0] != "goroutine" {
		panic("no goroutine number in the stack")
	}
	id, err := strconv.ParseUint(f[1], 10, 64)
	if err != nil {
		panic(err)
	}
	return id
}

// park marks the calling goroutine's logoff job as parked, until that job ends.
func (tr *goSafeTracker) park() {
	id := goroutineID()
	tr.mu.Lock()
	tr.parked[id] = true
	tr.mu.Unlock()
}

// trackGoSafe installs the goSafe start hook for the rest of the test; the cleanup uninstalls it. Jobs started before
// the call are not tracked, so it is the first statement of a test that wants to join its own. A second call from the
// same test returns the tracker the first one installed.
func trackGoSafe(t *testing.T) *goSafeTracker {
	t.Helper()
	if cur := goSafeTrackerNow.Load(); cur != nil && cur.owner == t {
		return cur
	}
	tr := &goSafeTracker{live: map[string]int{}, parked: map[uint64]bool{}, owner: t}
	hook := func(job string) func() {
		tr.mu.Lock()
		tr.live[job]++
		tr.mu.Unlock()
		tr.wg.Add(1)
		var once sync.Once
		return func() {
			once.Do(func() {
				id := goroutineID() // done runs on the job's own goroutine
				tr.mu.Lock()
				tr.live[job]--
				delete(tr.parked, id)
				tr.mu.Unlock()
				tr.wg.Done()
			})
		}
	}
	if !goSafeTrack.CompareAndSwap(nil, &hook) {
		t.Fatal("a goSafe start hook is already installed")
	}
	goSafeTrackerNow.Store(tr)
	t.Cleanup(func() { goSafeTrack.Store(nil); goSafeTrackerNow.Store(nil) })
	return tr
}

// sharedGoSafeTracker is the tracker already installed (the test's own, or a parent test's), or a new one for t.
func sharedGoSafeTracker(t *testing.T) *goSafeTracker {
	t.Helper()
	if cur := goSafeTrackerNow.Load(); cur != nil {
		return cur
	}
	return trackGoSafe(t)
}

// rwLaneFree returns once the RW lane has come free: every op queued for it before this call has run, on a FIFO
// channel. A leftover op of an earlier test can hold the lane for its whole 150 s stall budget; a sign-out test started
// behind it would fail at its own bounds and leave a logoff for the next test. The bound is past that budget.
func rwLaneFree(t *testing.T) {
	t.Helper()
	t0 := time.Now()
	select {
	case laneRW.slot <- struct{}{}:
		<-laneRW.slot
	case <-time.After(3 * time.Minute):
		t.Fatalf("the RW lane is still held after 3m by op %q", rwHolderNow())
	}
	if w := time.Since(t0); w > time.Second {
		t.Logf("waited %s for an earlier test's op to free the RW lane", w.Round(time.Millisecond))
	}
}

func rwHolderNow() string {
	op, _ := rwHolderOp.Load().(string)
	return op
}

// joinSignOuts returns once every sign-out this tracker saw can touch nothing more: each logoff has ended or is parked,
// and each stall watchdog and wallet publish has ended. A watchdog on a tick of a second or more is not waited for once
// no seal is in flight: its next tick only exits, and a test's short stall limit always comes with a short tick. It
// fails, naming them, after limit.
func (tr *goSafeTracker) joinSignOuts(t *testing.T, limit time.Duration) {
	t.Helper()
	deadline := time.Now().Add(limit)
	for {
		running := tr.signOutsRunning()
		if running == "" {
			return
		}
		if time.Now().After(deadline) {
			t.Errorf("sign-out jobs still running %s after the test ended: %s", limit, running)
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// signOutsRunning names the jobs joinSignOuts still waits for, "" when there are none.
func (tr *goSafeTracker) signOutsRunning() string {
	tr.mu.Lock()
	logoff, parked, watchdog, wallet := tr.live["logoff"], len(tr.parked), tr.live["logoff-stall-watchdog"], tr.live["logout-wallet"]
	tr.mu.Unlock()
	pendingReapMu.Lock()
	inFlight := sealInFlight
	pendingReapMu.Unlock()
	if logoff <= parked && wallet == 0 && (watchdog == 0 || (!inFlight && logoffStallTick >= time.Second)) {
		return ""
	}
	return fmt.Sprintf("logoff x%d (%d in the reap wait), logoff-stall-watchdog x%d, logout-wallet x%d", logoff, parked, watchdog, wallet)
}

// count is how many jobs named job are live now.
func (tr *goSafeTracker) count(job string) int {
	tr.mu.Lock()
	defer tr.mu.Unlock()
	return tr.live[job]
}

// wait returns once every tracked job has ended, or fails naming each job still live, with its count, after limit.
func (tr *goSafeTracker) wait(t *testing.T, limit time.Duration) {
	t.Helper()
	ended := make(chan struct{})
	go func() { tr.wg.Wait(); close(ended) }()
	select {
	case <-ended:
	case <-time.After(limit):
		tr.mu.Lock()
		var still []string
		for job, n := range tr.live {
			if n > 0 {
				still = append(still, job+" x"+strconv.Itoa(n))
			}
		}
		tr.mu.Unlock()
		sort.Strings(still)
		t.Errorf("goSafe jobs still running %s after the test ended: %s", limit, strings.Join(still, ", "))
	}
}

// dirCameBack waits settle, then lists the paths under root, relative to it and slash-separated, if root exists
// again; nil if it does not. An empty re-created root is ["."].
func dirCameBack(root string, settle time.Duration) []string {
	time.Sleep(settle)
	if _, err := os.Lstat(root); err != nil {
		return nil
	}
	var got []string
	filepath.Walk(root, func(p string, _ os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr == nil {
			got = append(got, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(got)
	return got
}

// stateDirMustStayGone registers a cleanup that fails the test if root() exists again after the cleanups registered
// later than this one (the TempDir removal among them) have run. It removes what came back, so the guard leaves
// nothing behind. An empty root() (the test ended before it made the dir) is skipped.
func stateDirMustStayGone(t *testing.T, root func() string) {
	t.Helper()
	t.Cleanup(func() {
		r := root()
		if r == "" {
			return
		}
		if got := dirCameBack(r, 500*time.Millisecond); got != nil {
			os.RemoveAll(r)
			t.Errorf("the state dir %s was re-created after the test's cleanup removed it; it holds %v", r, got)
		}
	})
}

func TestGoroutineWait_GuardSeesALateWriter(t *testing.T) {
	for _, wait := range []bool{true, false} {
		wait := wait
		name := "wait=false"
		if wait {
			name = "wait=true"
		}
		t.Run(name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "root")
			if err := os.MkdirAll(root, 0o700); err != nil {
				t.Fatal(err)
			}
			tr := trackGoSafe(t)
			goSafe("goroutine-wait-probe", func() {
				time.Sleep(300 * time.Millisecond)
				os.MkdirAll(filepath.Join(root, "x", "y"), 0o700)
			})
			if wait {
				tr.wait(t, 5*time.Second)
			}
			os.RemoveAll(root)
			got := dirCameBack(root, 800*time.Millisecond)
			defer os.RemoveAll(root)
			if wait {
				if len(got) != 0 {
					t.Errorf("waited for the job, yet %v came back", got)
				}
				return
			}
			if strings.Join(got, ",") != ".,x,x/y" {
				t.Errorf("a late writer re-created %v, want [. x x/y]", got)
			}
		})
	}
}

// RF-001, NWP-20261128-35: a test that returns while its logoff runs. The stand-in must keep answering until that logoff
// has staged, so the one call lands in this test's recorder, with the state dir and the marker still there.
func TestGoroutineWait_TheStandInJoinsARunningLogoff(t *testing.T) {
	const uid = "68"
	var calls func() []stageCall
	t.Run("returns with the logoff running", func(t *testing.T) {
		dest := rearmSession(t, uid)
		t.Cleanup(resetMediaStuck)
		calls = recordStaging(t, dest)
		rearmNoSync(t)
		cutoffWorker(t, dest, rearmAnswers(map[string]string{"sweepmedia": "ERR-MEDIA-SWEEP 1"}),
			map[string]time.Duration{"cutoff": 300 * time.Millisecond})
		ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	})
	if logoffInFlight(uid) {
		t.Error("the logoff outlived its test")
	}
	wantOneStaging(t, "joined logoff", calls(), uid)
}

// The reap wait is 20 s of sleep that touches nothing, so a join stops at it: a landed sign-out test must not pay for
// it. The first wait is 30 s here, so a slow runner does not end it before the check below.
func TestGoroutineWait_TheJoinDoesNotWaitOutTheReap(t *testing.T) {
	const uid = "69"
	old := reapSwitchWait
	reapSwitchWait = 30 * time.Second
	t.Cleanup(func() { reapSwitchWait = old })
	t.Run("a landed sign-out", func(t *testing.T) { landedLogoff(t, uid, "OK 3") })
	if !logoffInFlight(uid) {
		t.Error("the stand-in's cleanup waited for the logoff's reap wait to end")
	}
	// It leaves the veto to its own defer, as a landed sign-out does; the next claim in the package replaces it.
}

// RF-001, NWP-20261128-35: a parked logoff that has ended must not stand in for another logoff that is still running.
// A count of parks does that, and the stand-in then stops while the second logoff still needs it.
func TestGoroutineWait_AnEndedParkDoesNotCoverALiveLogoff(t *testing.T) {
	tr := trackGoSafe(t)
	parked, release := make(chan struct{}), make(chan struct{})
	first := make(chan struct{})
	goSafe("logoff", func() {
		defer close(first)
		tr.park()
		close(parked)
		<-release
	})
	<-parked
	if got := tr.signOutsRunning(); got != "" {
		t.Errorf("a parked logoff still counts as running: %s", got)
	}
	close(release)
	<-first
	deadline := time.Now().Add(rearmHang)
	for tr.count("logoff") != 0 {
		if time.Now().After(deadline) {
			t.Fatal("the first logoff never ended")
		}
		time.Sleep(time.Millisecond)
	}
	stop := make(chan struct{})
	goSafe("logoff", func() { <-stop })
	got := tr.signOutsRunning()
	close(stop)
	tr.wait(t, rearmHang)
	if got == "" {
		t.Error("the join counted the ended logoff's park for a live logoff that never parked")
	}
}

// The first reap wait of another job is not a logoff's. END-UNSAVED's "reap-or-reboot" job enters the same wait.
func TestGoroutineWait_AnotherJobsReapWaitParksNoLogoff(t *testing.T) {
	tr := trackGoSafe(t)
	inWait, stop := make(chan struct{}), make(chan struct{})
	goSafe("reap-or-reboot", func() {
		reapWaitHook("switch")
		close(inWait)
		<-stop
	})
	<-inWait
	goSafe("logoff", func() { <-stop })
	got := tr.signOutsRunning()
	close(stop)
	tr.wait(t, rearmHang)
	if got == "" {
		t.Error("the join counted another job's reap wait for a live logoff that never parked")
	}
}

// A sign-out test does not start behind another test's op on the RW lane.
func TestGoroutineWait_ASignOutTestWaitsForAHeldLane(t *testing.T) {
	laneRW.slot <- struct{}{}
	var released atomic.Bool
	done := make(chan struct{})
	go func() {
		defer close(done)
		time.Sleep(300 * time.Millisecond)
		released.Store(true)
		<-laneRW.slot
	}()
	cutoffSession(t, "67")
	if !released.Load() {
		t.Error("cutoffSession returned with another op still on the RW lane")
	}
	<-done
}

func TestGoroutineWait_TracksAtStart(t *testing.T) {
	tr := trackGoSafe(t)
	release := make(chan struct{})
	goSafe("goroutine-wait-probe", func() { <-release })
	if n := tr.count("goroutine-wait-probe"); n != 1 {
		t.Fatalf("live count right after goSafe returned is %d, want 1", n)
	}
	close(release)
	tr.wait(t, 5*time.Second)
	if n := tr.count("goroutine-wait-probe"); n != 0 {
		t.Errorf("live count after the job ended is %d, want 0", n)
	}
}

func TestGoroutineWait_PanickingJobEnds(t *testing.T) {
	tr := trackGoSafe(t)
	captureStderr(t, func() {
		goSafe("goroutine-wait-probe", func() { panic("goroutine-wait probe") })
		tr.wait(t, 5*time.Second)
	})
	if n := tr.count("goroutine-wait-probe"); n != 0 {
		t.Errorf("live count after a panicking job is %d, want 0", n)
	}
}

// The hook must run before the go statement: a count taken inside the new goroutine misses a job goSafe has started
// and the scheduler has not yet run.
func TestGoroutineWait_HookBeforeGoStatement(t *testing.T) {
	f, err := parser.ParseFile(token.NewFileSet(), "go_safe.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range f.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Name.Name != "goSafe" {
			continue
		}
		var hook, goStmt token.Pos
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.Ident:
				if x.Name == "goSafeTrack" && hook == 0 {
					hook = x.Pos()
				}
			case *ast.GoStmt:
				if goStmt == 0 {
					goStmt = x.Pos()
				}
			}
			return true
		})
		if hook == 0 || goStmt == 0 {
			t.Fatalf("goSafe: hook reference at %v, go statement at %v -- both must exist", hook, goStmt)
		}
		if hook > goStmt {
			t.Error("goSafe consults goSafeTrack only after (or inside) its go statement")
		}
		return
	}
	t.Fatal("go_safe.go has no goSafe")
}
