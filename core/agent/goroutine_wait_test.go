package main

// NWP-20261024-13: a test that starts goSafe jobs (handleLogout's "logoff", its stall watchdog, the wallet seal, the
// deleted-profile check) must not return while one is still running: a job that outlives its test writes into a state
// dir the test's cleanup already removed, and a path-creating write (os.MkdirAll) puts the t.TempDir() root back with
// nothing to report it. trackGoSafe counts every job from the instant goSafe is called (the start hook runs before
// the go statement), tr.wait joins them, and stateDirMustStayGone fails a test whose temp root exists again once its
// cleanups have run, naming what came back. The self-tests below pin all of it; test-rearm-inbox-tempdir.sh breaks
// each part in turn.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type goSafeTracker struct {
	mu   sync.Mutex
	wg   sync.WaitGroup
	live map[string]int
}

// trackGoSafe installs the goSafe start hook for the rest of the test; the cleanup uninstalls it. Jobs started before
// the call are not tracked, so it is the first statement of a test that wants to join its own.
func trackGoSafe(t *testing.T) *goSafeTracker {
	t.Helper()
	tr := &goSafeTracker{live: map[string]int{}}
	hook := func(job string) func() {
		tr.mu.Lock()
		tr.live[job]++
		tr.mu.Unlock()
		tr.wg.Add(1)
		var once sync.Once
		return func() {
			once.Do(func() {
				tr.mu.Lock()
				tr.live[job]--
				tr.mu.Unlock()
				tr.wg.Done()
			})
		}
	}
	if !goSafeTrack.CompareAndSwap(nil, &hook) {
		t.Fatal("a goSafe start hook is already installed")
	}
	t.Cleanup(func() { goSafeTrack.Store(nil) })
	return tr
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
