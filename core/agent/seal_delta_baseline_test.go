package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261108-05: SEAL-DELTA-WALK's rule-B baseline is the dispatch of the last seal that LANDED, not of the last
// one announced.

// sdbGlobals snapshots and restores every global these tests touch.
func sdbGlobals(t *testing.T) {
	t.Helper()
	oldStart, oldOK := lastSealStartedAt.Load(), lastSealOKAt.Load()
	oldLanded, oldPeriodic := lastLandedSealStartedAt.Load(), periodicSealStartedAt.Load()
	oldBase := sealDeltaBase
	sealDeltaIdxCache.mu.Lock()
	oldName, oldAt, oldCacheOK := sealDeltaIdxCache.name, sealDeltaIdxCache.at, sealDeltaIdxCache.ok
	sealDeltaIdxCache.name, sealDeltaIdxCache.at, sealDeltaIdxCache.ok = "", time.Time{}, false
	sealDeltaIdxCache.mu.Unlock()
	lastSealStartedAt.Store(0)
	lastSealOKAt.Store(0)
	lastLandedSealStartedAt.Store(0)
	periodicSealStartedAt.Store(0)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() {
		lastSealStartedAt.Store(oldStart)
		lastSealOKAt.Store(oldOK)
		lastLandedSealStartedAt.Store(oldLanded)
		periodicSealStartedAt.Store(oldPeriodic)
		sealDeltaBase = oldBase
		sealDeltaIdxCache.mu.Lock()
		sealDeltaIdxCache.name, sealDeltaIdxCache.at, sealDeltaIdxCache.ok = oldName, oldAt, oldCacheOK
		sealDeltaIdxCache.mu.Unlock()
		resetSealStatus()
		clearSealRun()
	})
}

// sdbWorker is a fake worker: it answers every lane request with answer and records each request's line 7 (the
// srcUnit slot, which carries `since`).
func sdbWorker(t *testing.T, dest, answer string) (stop func() []string) {
	t.Helper()
	lanes := []workerLane{laneRW, laneRO, laneCred}
	var mu sync.Mutex
	var seen []string
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for {
			for _, l := range lanes {
				b, err := os.ReadFile(filepath.Join(dest, l.req))
				if err != nil {
					continue
				}
				os.Remove(filepath.Join(dest, l.req))
				lines := strings.Split(string(b), "\n")
				line7 := ""
				if len(lines) > 6 {
					line7 = lines[6]
				}
				mu.Lock()
				seen = append(seen, line7)
				mu.Unlock()
				os.WriteFile(filepath.Join(dest, l.res), []byte(answer+"\n"), 0o600)
			}
			select {
			case <-done:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	return func() []string {
		close(done)
		<-finished
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), seen...)
	}
}

func sdbSession(t *testing.T, name string) string {
	t.Helper()
	dest := t.TempDir()
	if err := markRoamSession(dest, name, "a passphrase for "+name, "12", ""); err != nil {
		t.Fatal(err)
	}
	sealDeltaBase = newHTTPStore(t)
	return dest
}

func TestSealDeltaBaselineIsTheLastLandedDispatch(t *testing.T) {
	sdbGlobals(t)
	dest := sdbSession(t, "deltabase-a")
	t1 := time.Now().Unix() - 120
	noteSealLanded(t1, "OK")
	markSealStarted()
	recordSeal("ERR-PUSH")
	stop := sdbWorker(t, dest, `{"v":1}`)
	got := ropReply(t, func(c net.Conn) { handleSealDeltaWalk(c, dest) })
	seen := stop()
	if len(seen) != 1 || seen[0] != fmt.Sprint(t1) {
		t.Fatalf("the walk's since = %q, want exactly one request carrying the landed seal's dispatch %d", seen, t1)
	}
	if !strings.HasPrefix(got, "OK ") {
		t.Fatalf("reply %q, want an OK frame", got)
	}
}

func TestSealDeltaBaselineNoLandedSealIsNOBASE(t *testing.T) {
	sdbGlobals(t)
	dest := sdbSession(t, "deltabase-b")
	markSealStarted()
	recordSeal("ERR-PUSH")
	stop := sdbWorker(t, dest, `{"v":1}`)
	got := ropReply(t, func(c net.Conn) { handleSealDeltaWalk(c, dest) })
	seen := stop()
	if got != "NOBASE" {
		t.Fatalf("reply %q, want NOBASE: no seal landed, a failed dispatch is no baseline", got)
	}
	if len(seen) != 0 {
		t.Fatalf("the walk ran against a failed dispatch: %q", seen)
	}
	if _, err := os.Stat(filepath.Join(dest, laneRO.req)); err == nil {
		t.Fatal("a roamro.req was written")
	}
}

func TestSealDeltaBaselineOnlyAnOKVerdictMovesIt(t *testing.T) {
	sdbGlobals(t)
	now := time.Now().Unix()
	base := now - 300
	lastLandedSealStartedAt.Store(base)
	for _, c := range []struct {
		start int64
		out   string
	}{
		{now - 10, "ERR-PUSH"},
		{now - 10, "SKIP-SUPERSEDED"},
		{now - 10, "ERR-REFUSED"},
		{now - 10, "ERR-NOCREDIT"},
		{base - 60, "OK"},
		{0, "OK"},
	} {
		noteSealLanded(c.start, c.out)
		if got := lastLandedSealStartedAt.Load(); got != base {
			t.Fatalf("noteSealLanded(%d, %q) moved the baseline to %d", c.start, c.out, got)
		}
	}
	noteSealLanded(now-10, "OK PARTIAL:apps=refused")
	if got := lastLandedSealStartedAt.Load(); got != now-10 {
		t.Fatalf("an OK PARTIAL verdict left the baseline at %d, want %d", got, now-10)
	}
}

func TestSealDeltaBaselineResetSealSignalsZeroesIt(t *testing.T) {
	sdbGlobals(t)
	lastLandedSealStartedAt.Store(time.Now().Unix())
	resetSealSignals()
	if got := lastLandedSealStartedAt.Load(); got != 0 {
		t.Fatalf("resetSealSignals left the landed baseline at %d", got)
	}
}

func TestSealDeltaBaselinePeriodicStampIsItsOwn(t *testing.T) {
	sdbGlobals(t)
	pendingReapMu.Lock()
	oldDel := deleteInFlight
	deleteInFlight = false
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		deleteInFlight = oldDel
		pendingReapMu.Unlock()
	})
	if !announcePeriodicSeal() {
		t.Fatal("announcePeriodicSeal refused with no delete in flight")
	}
	p := periodicSealStartedAt.Load()
	if p == 0 || p != lastSealStartedAt.Load() {
		t.Fatalf("periodic stamp %d, lastSealStartedAt %d", p, lastSealStartedAt.Load())
	}
	periodicSealStartedAt.Store(p - 30) // distinguishable within one second
	got := setSealRun("logoff")
	if got == 0 || got != lastSealStartedAt.Load() {
		t.Fatalf("setSealRun returned %d, lastSealStartedAt %d", got, lastSealStartedAt.Load())
	}
	if periodicSealStartedAt.Load() != p-30 {
		t.Fatalf("a later setSealRun moved the periodic stamp to %d", periodicSealStartedAt.Load())
	}
}

func TestSealDeltaBaselineEachSealPathPassesItsOwnStamp(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	src := func(n ast.Node) string {
		var b strings.Builder
		printer.Fprint(&b, fset, n)
		return b.String()
	}
	callName := func(s ast.Stmt) (string, *ast.CallExpr) {
		es, ok := s.(*ast.ExprStmt)
		if !ok {
			return "", nil
		}
		ce, ok := es.X.(*ast.CallExpr)
		if !ok {
			return "", nil
		}
		id, ok := ce.Fun.(*ast.Ident)
		if !ok {
			return "", nil
		}
		return id.Name, ce
	}
	// NWP-20261117-18: the manual path's verdict lives in manualSaveDone, as `if seq := recordSealLanded(out); ...`,
	// and noteSealLanded there takes the stamp handleBackup passes it (checked below).
	verdictCall := func(s ast.Stmt) (string, *ast.CallExpr) {
		if is, ok := s.(*ast.IfStmt); ok {
			as, ok := is.Init.(*ast.AssignStmt)
			if !ok || len(as.Rhs) != 1 {
				return "", nil
			}
			ce, ok := as.Rhs[0].(*ast.CallExpr)
			if !ok {
				return "", nil
			}
			id, ok := ce.Fun.(*ast.Ident)
			if !ok {
				return "", nil
			}
			return id.Name, ce
		}
		return callName(s)
	}
	want := map[string]string{
		"syncLoop":       "periodicSealStartedAt.Load()",
		"manualSaveDone": "start",
		"promoteToStore": "promoteStart",
	}
	for fn, stamp := range want {
		var decl *ast.FuncDecl
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == fn {
				decl = fd
			}
		}
		if decl == nil {
			t.Errorf("%s not found in main.go", fn)
			continue
		}
		found := 0
		ast.Inspect(decl, func(n ast.Node) bool {
			blk, ok := n.(*ast.BlockStmt)
			if !ok {
				return true
			}
			for i, s := range blk.List {
				name, ce := verdictCall(s)
				if (name != "recordSeal" && name != "recordSealLanded") || len(ce.Args) != 1 || src(ce.Args[0]) != "out" {
					continue
				}
				found++
				if i+1 >= len(blk.List) {
					t.Errorf("%s: recordSeal(out) is the last statement; noteSealLanded must follow", fn)
					continue
				}
				nn, nc := callName(blk.List[i+1])
				if nn != "noteSealLanded" || len(nc.Args) != 2 {
					t.Errorf("%s: the statement after recordSeal(out) is %q, want noteSealLanded(<stamp>, out)", fn, src(blk.List[i+1]))
					continue
				}
				if got := src(nc.Args[0]); got != stamp || src(nc.Args[1]) != "out" {
					t.Errorf("%s: noteSealLanded(%s, %s), want its own stamp %s", fn, got, src(nc.Args[1]), stamp)
				}
				if strings.Contains(src(blk.List[i+1]), "lastSealStartedAt") {
					t.Errorf("%s: noteSealLanded reads lastSealStartedAt at verdict time", fn)
				}
			}
			return true
		})
		if found != 1 {
			t.Errorf("%s: found %d recordSeal(out) statements, want 1", fn, found)
		}
	}
	var backup *ast.FuncDecl
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == "handleBackup" {
			backup = fd
		}
	}
	if backup == nil {
		t.Fatal("handleBackup not found in main.go")
	}
	done := 0
	ast.Inspect(backup, func(n ast.Node) bool {
		if es, ok := n.(*ast.ExprStmt); ok {
			if name, ce := callName(es); name == "manualSaveDone" {
				done++
				if got := src(ce); got != "manualSaveDone(out, comp, manualStart)" {
					t.Errorf("handleBackup: %s, want manualSaveDone(out, comp, manualStart) -- the manual stamp is its own", got)
				}
			}
		}
		return true
	})
	if done != 1 {
		t.Errorf("handleBackup: found %d manualSaveDone statements, want 1", done)
	}
	origins := []struct{ fn, text string }{
		{"announcePeriodicSeal", "periodicSealStartedAt.Store(markSealStarted())"},
		{"handleBackup", "manualStart = markSealStarted()"},
		{"promoteToStore", "promoteStart := setSealRun(\"promote\")"},
	}
	for _, o := range origins {
		var body string
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == o.fn {
				body = src(fd)
			}
		}
		if !strings.Contains(body, o.text) {
			t.Errorf("%s no longer holds %q", o.fn, o.text)
		}
	}
}
