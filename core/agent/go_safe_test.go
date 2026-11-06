package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261014-66: a goroutine the daemon starts must not be able to take the daemon down (go_safe.go). The login
// daemon died on lynx 2026101401 when Wi-Fi dropped seconds after a sign-in: the background finish-tie read the
// profile's tie state, the read panicked (checkRead) on a goroutine with no recover, and the session was lost.
//
// Each test is built so that a regression FAILS it rather than killing the test binary: the in-process tests call
// the code synchronously under their own recover, and the one test that needs a real escaped goroutine panic runs it
// in a child process.

// mustNotPanic runs fn and fails the test if a panic comes out of it -- the panic that, on its own goroutine in the
// daemon, would have ended the process.
func mustNotPanic(t *testing.T, what string, fn func()) {
	t.Helper()
	var p any
	func() {
		defer func() { p = recover() }()
		fn()
	}()
	if p != nil {
		t.Fatalf("%s panicked -- on a daemon goroutine this ends the login daemon and loses the session: %v", what, p)
	}
}

// unreachableErr is the transport error the device logged, minus the host.
var unreachableErr = errors.New(`Post "https://gateway.invalid/caps": dial tcp: lookup gateway.invalid: network is unreachable`)

func TestRunSafeRecoversAStoreReadPanic(t *testing.T) {
	var returned bool
	log := captureStderr(t, func() {
		mustNotPanic(t, "runSafe", func() {
			returned = runSafe("probe", func() { checkRead(unreachableErr) })
		})
	})
	if returned {
		t.Error("runSafe reported a normal return for fn that panicked")
	}
	want := "[logind] probe recovered: store unreachable: " + unreachableErr.Error() + " (NWP-20261014-66)\n"
	if log != want {
		t.Errorf("the recovered line is %q, want exactly one line %q", log, want)
	}
	// Control: fn that returns is reported as returned and logs nothing.
	log = captureStderr(t, func() { returned = runSafe("probe", func() {}) })
	if !returned || log != "" {
		t.Errorf("a normal return: returned=%v, log %q -- want true and no line", returned, log)
	}
}

func TestGoSafeLineRedactsAndKeepsTheStackOfABug(t *testing.T) {
	ref := strings.Repeat("ab", 32)
	got := goSafeLine("x", storeReadErr{errors.New(`Get "https://store.invalid/ref/` + ref + `?X-Amz-Signature=secret": EOF`)}, []byte("STACK"))
	for _, leak := range []string{ref, "X-Amz-Signature", "secret"} {
		if strings.Contains(got, leak) {
			t.Errorf("the recovered line carries %q: %q", leak, got)
		}
	}
	if !strings.Contains(got, "ref/<ref>") || strings.Contains(got, "STACK") {
		t.Errorf("a store read's line is %q: want the ref redacted and no stack", got)
	}
	// A panic that is not a store read is a bug: its stack is the only clue left, so it is kept.
	if got := goSafeLine("x", errors.New("index out of range"), []byte("STACK")); !strings.HasSuffix(got, "\nSTACK") {
		t.Errorf("a bug's line is %q: want its stack after the line", got)
	}
}

// The instance (lynx 2026101401): finishTieAtSignIn against a configured gateway that cannot be reached. It must
// return, say so in one line that names no profile, and leave the worker slot free.
func TestFinishTieAtSignInSurvivesAnUnreachableStore(t *testing.T) {
	t.Setenv("GATEWAY_URL", deadStore(t)) // cap mode, and nothing listens there
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	od, rb, oc := tieFinishDelay, s3RetryBase, capReadCache
	tieFinishDelay, s3RetryBase, capReadCache = 0, time.Millisecond, map[string]capEntry{}
	t.Cleanup(func() { tieFinishDelay, s3RetryBase, capReadCache = od, rb, oc })
	name, pass := "finishtie", "horse battery staple correct"
	dest := t.TempDir()
	if err := markRoamSession(dest, name, pass, "12", hex.EncodeToString(seA)); err != nil {
		t.Fatal(err)
	}
	log := captureStderr(t, func() { mustNotPanic(t, "finishTieAtSignIn", func() { finishTieAtSignIn(dest) }) })
	if !strings.Contains(log, "[logind] finish-tie user 12: the store could not be read -- left for Finish tying and the next sign-in") {
		t.Errorf("no finish-tie line for the failed read; log:\n%s", log)
	}
	if strings.Contains(log, name) {
		t.Errorf("the log names the profile:\n%s", log)
	}
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the worker slot is held (%d) after a finish-tie that never started", n)
	}
}

// TestGoSafeHelperProcess is not a test: it is a child process for TestGoSafeKeepsTheProcessAlive, where a goroutine
// panic that escapes ends the process instead of the test binary.
func TestGoSafeHelperProcess(t *testing.T) {
	switch os.Getenv("NOWHERE_GOSAFE_HELPER") {
	case "":
		return
	case "once":
		done := make(chan struct{})
		goSafe("helper", func() {
			defer close(done)
			checkRead(unreachableErr)
		})
		<-done
	case "loop":
		goSafeSleep = func(time.Duration) {}
		var runs atomic.Int32
		done := make(chan struct{})
		goSafeLoop("helper loop", func() {
			if runs.Add(1) == 1 {
				checkRead(unreachableErr) // the first pass panics; the loop must be started again
			}
			close(done) // the second pass returns, which ends it
		})
		<-done
	}
	time.Sleep(300 * time.Millisecond) // an escaped panic has ended the process well before this
	os.Stdout.WriteString("SURVIVED\n")
	os.Exit(0)
}

func TestGoSafeKeepsTheProcessAlive(t *testing.T) {
	for _, mode := range []string{"once", "loop"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestGoSafeHelperProcess$", "-test.count=1")
		cmd.Env = append(os.Environ(), "NOWHERE_GOSAFE_HELPER="+mode)
		out, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(out), "SURVIVED") {
			t.Errorf("%s: the process did not survive a goroutine's store-read panic (err %v):\n%s", mode, err, out)
			continue
		}
		if !strings.Contains(string(out), "recovered: store unreachable: ") {
			t.Errorf("%s: no recovered line:\n%s", mode, out)
		}
	}
}

// goStmtAllowed lists the `go` statements that do NOT go through goSafe, keyed "<file> <function>", with how many
// each function holds and why. Every one runs only in a short-lived WORKER process (the verbs roamd spawns), never in
// the login daemon or mediad -- TestEveryGoroutineGoesThroughGoSafe proves that from the call graph, so moving one
// into a daemon path fails here. In a worker a panic ending the process is the contract (roamd reads the exit), and
// for the tar pipe writers a recover would be WRONG: their CloseWithError is not deferred, so a recovered panic would
// leave the reading end blocked forever instead of failing the seal.
var goStmtAllowed = map[string]struct {
	n   int
	why string
}{
	"incremental_seal.go walkChunks": {3, "the seal walk's tar pipe writers, inside pushProfile (the `push` worker)"},
	"main.go pushProfile":            {3, "the `push` worker: progress ticker, upload workers, the tar pipe writer"},
	"main.go cdcRestore":             {3, "the `restore` worker: chunk dispatcher, fetchers (they recover into the result, NWP-20261013-05), ordered writer"},
	"media_heal.go healFetchOrdered": {2, "restore-app / media heal, both worker verbs; the fetchers recover into the result"},
}

// TestEveryGoroutineGoesThroughGoSafe is the class pin: an AST walk of every non-test file finds every `go`
// statement. The only one allowed is goSafe's own `go runSafe(name, fn)`; the rest must be in goStmtAllowed, and an
// allow-listed function must be unreachable from the daemons' entry points (loginDaemon, runMediad) in a
// conservative call graph -- an edge for every package-level identifier a body names and every method name it
// selects, so a function value passed around still counts as reached.
func TestEveryGoroutineGoesThroughGoSafe(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var parsed []*ast.File
	names := map[string]string{} // parsed file -> base name
	top := map[string]bool{}     // package-level funcs and vars; methods as "M.<name>"
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		parsed = append(parsed, af)
		names[fset.Position(af.Pos()).Filename] = filepath.Base(f)
		for _, d := range af.Decls {
			switch d := d.(type) {
			case *ast.FuncDecl:
				top[declKey(d)] = true
			case *ast.GenDecl:
				for _, s := range d.Specs {
					if vs, ok := s.(*ast.ValueSpec); ok {
						for _, n := range vs.Names {
							top[n.Name] = true
						}
					}
				}
			}
		}
	}
	refs := func(n ast.Node) map[string]bool {
		r := map[string]bool{}
		ast.Inspect(n, func(x ast.Node) bool {
			switch x := x.(type) {
			case *ast.SelectorExpr:
				if top["M."+x.Sel.Name] {
					r["M."+x.Sel.Name] = true
				}
			case *ast.Ident:
				if top[x.Name] {
					r[x.Name] = true
				}
			}
			return true
		})
		return r
	}
	// UNION, never assign: a method is keyed by its name alone ("M.take"), and this package has methods of the same
	// name on different types. Assigning kept only the last file's body, so an earlier one's calls vanished from the
	// graph -- an allow-listed function reached only through it read as unreachable.
	edges := map[string]map[string]bool{}
	addEdges := func(owner string, r map[string]bool) {
		if edges[owner] == nil {
			edges[owner] = map[string]bool{}
		}
		for k := range r {
			edges[owner][k] = true
		}
	}
	found := map[string]int{}
	var bad []string
	goSafeStmts := 0
	for _, af := range parsed {
		file := names[fset.Position(af.Pos()).Filename]
		imports := fileImports(af)
		for _, d := range af.Decls {
			owner := ""
			var body ast.Node
			switch d := d.(type) {
			case *ast.FuncDecl:
				if d.Body == nil {
					continue
				}
				owner, body = declKey(d), d.Body
			case *ast.GenDecl: // var x = func() { go ... }: a statement outside any function
				body = d
				for _, s := range d.Specs {
					if vs, ok := s.(*ast.ValueSpec); ok && len(vs.Names) > 0 {
						owner = vs.Names[0].Name
						for _, n := range vs.Names {
							addEdges(n.Name, refs(vs))
						}
					}
				}
			}
			if owner == "" {
				continue
			}
			if fd, ok := d.(*ast.FuncDecl); ok {
				addEdges(owner, refs(fd.Body))
			}
			ast.Inspect(body, func(n ast.Node) bool {
				key := file + " " + owner
				// The other ways to start a goroutine count as a raw `go` too: time.AfterFunc and context.AfterFunc
				// run their func on a goroutine of their own, and (*sync.WaitGroup).Go is `go` with an Add and a Done.
				// Matched on any REFERENCE, not only a call, so `f := time.AfterFunc` is caught too.
				if what := goroutineStarter(n, imports); what != "" {
					found[key]++
					if _, ok := goStmtAllowed[key]; !ok {
						bad = append(bad, fmt.Sprintf("%s:%d (%s): %s starts a goroutine with no recover -- run its body "+
							"through goSafe (go_safe.go) or allow-list it", file, fset.Position(n.Pos()).Line, owner, what))
					}
					return false // one finding per reference
				}
				g, ok := n.(*ast.GoStmt)
				if !ok {
					return true
				}
				if owner == "goSafe" {
					goSafeStmts++
					if c, ok := g.Call.Fun.(*ast.Ident); !ok || c.Name != "runSafe" {
						bad = append(bad, key+": goSafe's go statement is not `go runSafe(name, fn)`")
					}
					return true
				}
				found[key]++
				if _, ok := goStmtAllowed[key]; !ok {
					bad = append(bad, fmt.Sprintf("%s:%d (%s): a raw go statement -- start it with goSafe or goSafeLoop (go_safe.go)",
						file, fset.Position(g.Pos()).Line, owner))
				}
				return true
			})
		}
	}
	if goSafeStmts != 1 {
		t.Errorf("goSafe holds %d go statements, want exactly its one `go runSafe(name, fn)`", goSafeStmts)
	}
	for k, a := range goStmtAllowed {
		if found[k] != a.n {
			t.Errorf("allow-list %q expects %d go statement(s), found %d -- update the entry or remove it", k, a.n, found[k])
		}
	}
	sort.Strings(bad)
	for _, b := range bad {
		t.Error(b)
	}
	reached := map[string]bool{}
	stack := []string{"loginDaemon", "runMediad"}
	for _, r := range stack {
		if !top[r] {
			t.Fatalf("daemon entry point %s not found: the reachability half of this pin would prove nothing", r)
		}
	}
	for len(stack) > 0 {
		x := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if reached[x] {
			continue
		}
		reached[x] = true
		for y := range edges[x] {
			stack = append(stack, y)
		}
	}
	// Controls: the graph must see the daemon's own background work, or "unreachable" below means nothing.
	for _, must := range []string{"finishTieAtSignIn", "syncLoop", "M.maybePrefetch", "reapOrReboot"} {
		if !reached[must] {
			t.Errorf("control: %s is not reached from the daemon entry points -- the call graph is broken", must)
		}
	}
	for k := range goStmtAllowed {
		if fn := k[strings.IndexByte(k, ' ')+1:]; reached[fn] {
			t.Errorf("allow-listed %q is reachable from a daemon entry point: its goroutines run in the daemon and must go through goSafe", k)
		}
	}
}

// fileImports maps each name a file refers to an import by -- its alias, or the last element of its path -- to the
// import path, so a starter is matched however its package is spelled (`import tm "time"`). A dot import is keyed ".".
func fileImports(af *ast.File) map[string]string {
	m := map[string]string{}
	for _, is := range af.Imports {
		path, err := strconv.Unquote(is.Path.Value)
		if err != nil {
			continue
		}
		name := path[strings.LastIndexByte(path, '/')+1:]
		if is.Name != nil {
			name = is.Name.Name
		}
		if name == "." {
			m["."+path] = path
			continue
		}
		m[name] = path
	}
	return m
}

// goroutineStarter names n when it refers to something that starts a goroutine the way a `go` statement does:
// time.AfterFunc or context.AfterFunc, through whatever name the file imports them by (or a dot import), called or
// taken as a value; or any .Go selector (sync.WaitGroup's; an errgroup's alike). "" otherwise.
func goroutineStarter(n ast.Node, imports map[string]string) string {
	switch x := n.(type) {
	case *ast.SelectorExpr:
		if pkg, ok := x.X.(*ast.Ident); ok && x.Sel.Name == "AfterFunc" {
			if path := imports[pkg.Name]; path == "time" || path == "context" {
				return path + ".AfterFunc"
			}
		}
		if x.Sel.Name == "Go" {
			return "a .Go call"
		}
	case *ast.Ident:
		if x.Name == "AfterFunc" && (imports[".time"] != "" || imports[".context"] != "") {
			return "a dot-imported AfterFunc"
		}
	}
	return ""
}

func declKey(d *ast.FuncDecl) string {
	if d.Recv != nil {
		return "M." + d.Name.Name
	}
	return d.Name.Name
}

// Round 2 (NWP-20261014-66): a recover is not an undo. Each test below is a place where recovering left state worse
// than the crash it replaced, until the state was released from a defer.

// The restart watchdog: a panic before its give-back used to leave the session local, RESTART-STATUS PENDING and the
// marker on disk -- never sealing, and LOGOUT answering BUSY until power-off.
func TestRestartWatchdogGivesTheSessionBackWhenItPanics(t *testing.T) {
	f := euSetup(t)
	if err := writeRestartMarker(f.dest, "alice", euUID); err != nil {
		t.Fatal(err)
	}
	markLocalSession(f.dest)
	setRestartState("PENDING", "alice", euUID)
	laneRW.slot <- struct{}{} // the slot RESTART-UNSAVED hands the watchdog
	h := restartHooks{reboot: func(string) {}, wait: func() { panic(errors.New("wait hook failed")) }, bound: time.Second}
	log := captureStderr(t, func() {
		mustNotPanic(t, "runSafe", func() { runSafe("restart-watchdog", func() { restartDidNotHappen(f.dest, "alice", euUID, h) }) })
	})
	if n := len(laneRW.slot); n != 0 {
		t.Errorf("the RW slot is still held (%d) -- every seal would wait on it", n)
	}
	if isLocalSession(f.dest) {
		t.Error("the session is still marked local: it would never seal again")
	}
	if _, err := os.Stat(filepath.Join(f.dest, restartMarkerFile)); !os.IsNotExist(err) {
		t.Errorf("the restart marker is still there (%v)", err)
	}
	restartMu.Lock()
	st := restartState
	restartMu.Unlock()
	if st != "FAILED" || restartPending() {
		t.Errorf("RESTART-STATUS is %q, want FAILED -- PENDING makes LOGOUT answer BUSY", st)
	}
	if f.kicks != 1 {
		t.Errorf("mediad kicked %d time(s), want 1 (the give-back revives the session's media)", f.kicks)
	}
	if !strings.Contains(log, "the restart watchdog failed before it settled -- giving the session back") {
		t.Errorf("no give-back line:\n%s", log)
	}
}

// uploadBlobs: a panic in done used to escape the worker's recover holding mu, so the other workers blocked on mu and
// the seal hung holding the cap bracket. It must reach the caller as a panic, which fails the seal.
func TestUploadBlobsPanicInDoneFailsTheSealInsteadOfHanging(t *testing.T) {
	r := uploadBlobsWithin(t, blobWork(64), 8, func(capBlobRef, *[]byte) {}, func(b capBlobRef) {
		if b.off == 5 {
			panic("done failed")
		}
	})
	if fmt.Sprint(r) != "done failed" {
		t.Errorf("uploadBlobs ended with %v, want it to re-panic the worker's \"done failed\"", r)
	}
}

// goSafeLoop: a deterministic panic comes back every pass. The restarts back off to the cap, and only the first
// goSafeLoopStacks passes print a stack -- and a pass that ran longer than the cap before it failed starts BOTH
// budgets again (round 3): its own panic prints a stack and the backoff restarts at the base.
func TestGoSafeLoopBacksOffAndStopsPrintingTheStack(t *testing.T) {
	sl, p0, pm, ns, nw := goSafeSleep, goSafeLoopPause, goSafeLoopMaxPause, goSafeLoopStacks, goSafeNow
	t.Cleanup(func() {
		goSafeSleep, goSafeLoopPause, goSafeLoopMaxPause, goSafeLoopStacks, goSafeNow = sl, p0, pm, ns, nw
	})
	// Everything below is touched only by the loop's goroutine until done is closed.
	var pauses []time.Duration
	now := time.Unix(1_800_000_000, 0)
	goSafeSleep = func(d time.Duration) { pauses = append(pauses, d) }
	goSafeNow = func() time.Time { return now }
	goSafeLoopPause, goSafeLoopMaxPause, goSafeLoopStacks = time.Second, 20*time.Second, 3
	runs := 0
	done := make(chan struct{})
	log := captureStderr(t, func() {
		goSafeLoop("backoff", func() {
			runs++
			switch {
			case runs == 9:
				now = now.Add(30 * time.Second) // a long healthy pass, then the same panic
				panic(errors.New("deterministic bug"))
			case runs <= 12:
				panic(errors.New("deterministic bug"))
			}
			close(done)
		})
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("the loop never got past its panics")
		}
	})
	want := []time.Duration{1, 2, 4, 8, 16, 20, 20, 20, 1, 2, 4, 8}
	for i := range want {
		want[i] *= time.Second
	}
	if fmt.Sprint(pauses) != fmt.Sprint(want) {
		t.Errorf("restart pauses %v, want %v (doubling to the cap, from the base again after the long pass)", pauses, want)
	}
	if n := strings.Count(log, "backoff recovered: deterministic bug"); n != 12 {
		t.Errorf("%d recovered line(s), want 12", n)
	}
	// Stacks: passes 1-3, then 9-11 once the long pass reset the budget; 4-8 and 12 are one line each.
	if n := strings.Count(log, "[running]:"); n != 6 {
		t.Errorf("%d stack(s) printed, want 6 (3, then 3 more after the reset)", n)
	}
	if n := strings.Count(log, "(stack omitted: this loop has panicked before)"); n != 6 {
		t.Errorf("%d omitted-stack note(s), want 6", n)
	}
}

// syncLoop runs under goSafeLoop, which starts it again after a panic: every lock it takes is released from a defer,
// and a seal run it announces is withdrawn from one, or the restarted loop (and every handler on the same mutex)
// would wedge, or SEAL-STATUS would keep reporting a periodic seal that is not running.
func TestSyncLoopReleasesItsLocksFromDefers(t *testing.T) {
	fset := token.NewFileSet()
	af, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var body *ast.BlockStmt
	for _, d := range af.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == "syncLoop" {
			body = fd.Body
		}
	}
	if body == nil {
		t.Fatal("no syncLoop in main.go")
	}
	locks, deferredClear := 0, false
	ast.Inspect(body, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.DeferStmt:
			if c, ok := n.Call.Fun.(*ast.FuncLit); ok {
				ast.Inspect(c, func(x ast.Node) bool {
					if ce, ok := x.(*ast.CallExpr); ok {
						if id, ok := ce.Fun.(*ast.Ident); ok && id.Name == "clearSealRunIf" {
							deferredClear = true
						}
					}
					return true
				})
			}
			return false // a deferred Unlock is the point
		case *ast.ExprStmt:
			if c, ok := n.X.(*ast.CallExpr); ok {
				if se, ok := c.Fun.(*ast.SelectorExpr); ok {
					switch se.Sel.Name {
					case "Lock", "TryLock":
						locks++
					case "Unlock":
						t.Errorf("main.go:%d: syncLoop releases a lock with a plain Unlock -- a panic before it leaves the "+
							"mutex held; take it in a func with `defer ...Unlock()`", fset.Position(c.Pos()).Line)
					}
				}
			}
		case *ast.IfStmt: // `if sessionMu.TryLock() {`
			if c, ok := n.Cond.(*ast.CallExpr); ok {
				if se, ok := c.Fun.(*ast.SelectorExpr); ok && se.Sel.Name == "TryLock" {
					locks++
				}
			}
		}
		return true
	})
	if locks < 3 {
		t.Errorf("control: found %d lock acquisitions in syncLoop, want at least 3 -- the scan is looking at the wrong code", locks)
	}
	if !deferredClear {
		t.Error("syncLoop's periodic seal-run announce is not withdrawn from a defer")
	}
}

// NWP-20261128-14: a tracked job's done reports its end only after runSafe has written the job's recovered line, so
// a test that waits for it may put os.Stderr back. done reads the log at the moment it runs: the order is judged
// there, with no thread interleaving. It also records whether the job's body has run, so a done that fires before
// the job starts fails too. done does not call recover(): on a goSafe that runs done mid-unwind, that would swallow
// the job's panic.
func TestGoSafeTrackedDoneAfterRecoveredLine(t *testing.T) {
	const job, text = "gosafe-track-order", "gosafe-track: a tracked job panicked"
	logPath := filepath.Join(t.TempDir(), "stderr")
	lf, err := os.Create(logPath)
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = lf
	t.Cleanup(func() { os.Stderr = old; lf.Close() })
	var ran atomic.Bool
	var sawRan bool
	var lines int
	ended := make(chan struct{})
	hook := func(j string) func() {
		if j != job {
			return nil
		}
		return func() {
			b, _ := os.ReadFile(logPath)
			sawRan, lines = ran.Load(), strings.Count(string(b), job+" recovered: "+text)
			close(ended)
		}
	}
	if !goSafeTrack.CompareAndSwap(nil, &hook) {
		t.Fatal("a goSafe start hook is already installed")
	}
	t.Cleanup(func() { goSafeTrack.Store(nil) })
	goSafe(job, func() { ran.Store(true); panic(text) })
	select {
	case <-ended:
	case <-time.After(10 * time.Second):
		t.Fatal("the tracked job's done never ran") // a hang guard only, never the assertion
	}
	if !sawRan {
		t.Error("done ran before the job's body: a test that waits for it restores os.Stderr before the job logs")
	}
	if lines != 1 {
		t.Errorf("done saw %d recovered lines for the job, want 1: it ran before runSafe logged the panic", lines)
	}
}
