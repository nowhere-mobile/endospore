package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20260917-13: the worker request is published by temp + rename, never written in place. A lost-start roamd
// (runWorkerHeld's recovery restarts the service while req is still pending) can already be parsing req when the
// next request is written, and an O_TRUNC os.WriteFile handed it an empty or half-written file. roamd's side --
// all seven lines read from ONE open -- is pinned by core/vendor-common/bin/test-roam-req-parse.sh.

// reqWriteCalls parses main.go and returns, for each named function, every call it makes whose first argument is
// the identifier `req` (or an expression built on it), keyed by the callee as "pkg.Func" or "Func".
func reqWriteCalls(t *testing.T, funcs ...string) map[string]map[string][]*ast.CallExpr {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{}
	for _, n := range funcs {
		want[n] = true
	}
	out := map[string]map[string][]*ast.CallExpr{}
	for _, d := range f.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Recv != nil || !want[fd.Name.Name] {
			continue
		}
		calls := map[string][]*ast.CallExpr{}
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			c, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			var callee string
			switch fn := c.Fun.(type) {
			case *ast.Ident:
				callee = fn.Name
			case *ast.SelectorExpr:
				if x, ok := fn.X.(*ast.Ident); ok {
					callee = x.Name + "." + fn.Sel.Name
				}
			}
			if callee != "" {
				calls[callee] = append(calls[callee], c)
			}
			return true
		})
		out[fd.Name.Name] = calls
	}
	for _, n := range funcs {
		if _, ok := out[n]; !ok {
			t.Fatalf("func %s not found in main.go -- the guard would pass on nothing", n)
		}
	}
	return out
}

func isIdent(e ast.Expr, name string) bool {
	id, ok := e.(*ast.Ident)
	return ok && id.Name == name
}

// The request write must never be an in-place os.WriteFile of req, in triggerRoamWorkerKind or in the body it
// hands off to once the slot is held (runWorkerHeld, NWP-20260923-03).
func TestRoamReqNotWrittenInPlace(t *testing.T) {
	all := reqWriteCalls(t, "triggerRoamWorkerKind", "runWorkerHeld")
	for fn, calls := range all {
		for _, callee := range []string{"os.WriteFile", "os.Create", "os.OpenFile"} {
			for _, c := range calls[callee] {
				if len(c.Args) > 0 && isIdent(c.Args[0], "req") {
					t.Errorf("%s writes req in place with %s: a lost-start roamd parsing it reads a torn request "+
						"(NWP-20260917-13) -- publish it with writeAtomic(req+\".tmp\", req, ...)", fn, callee)
				}
			}
		}
	}
	// Positive control: the atomic write is actually there, so the absence above is not an absence of any write.
	var found bool
	for _, c := range all["runWorkerHeld"]["writeAtomic"] {
		if len(c.Args) != 3 || !isIdent(c.Args[1], "req") {
			continue
		}
		b, ok := c.Args[0].(*ast.BinaryExpr)
		if !ok || b.Op != token.ADD || !isIdent(b.X, "req") {
			continue
		}
		if lit, ok := b.Y.(*ast.BasicLit); ok && lit.Value == `".tmp"` {
			found = true
		}
	}
	if !found {
		t.Errorf(`runWorkerHeld no longer publishes the request with writeAtomic(req+".tmp", req, ...)`)
	}
}

// The temp name must be read by nothing: not any lane's req (roamd and the lost-start check read those), res or
// progress file.
func TestRoamReqTempNameIsNobodysFile(t *testing.T) {
	lanes := []workerLane{laneRW, laneRO, laneCred}
	for _, l := range lanes {
		tmp := l.req + ".tmp"
		for _, o := range lanes {
			for _, name := range []string{o.req, o.res, o.prog} {
				if tmp == name {
					t.Errorf("lane %s's request temp %q is lane %s's own file", l.svc, tmp, o.svc)
				}
			}
		}
	}
}

// Behaviour of the helper the request write relies on: exact bytes, mode 0600, the temp gone, and a failed rename
// leaving neither a temp nor a half request behind.
func TestRoamReqWriteAtomic(t *testing.T) {
	dir := t.TempDir()
	req := filepath.Join(dir, laneRW.req)
	body := "in\nprofile-a\n  pass\\ $x\n10\n\n\nunit-src-7\n"
	if err := os.WriteFile(req, []byte("out\nprofile-b\nold\n11\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeAtomic(req+".tmp", req, []byte(body)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(req)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != body {
		t.Errorf("req holds %q, want %q", got, body)
	}
	if st, err := os.Stat(req); err == nil && st.Mode().Perm() != 0o600 {
		t.Errorf("req mode is %o, want 600 (it holds the passphrase)", st.Mode().Perm())
	}
	if _, err := os.Stat(req + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("the .tmp was left behind (stat err %v)", err)
	}

	// A destination that cannot be renamed over (a non-empty directory): the call fails and cleans its temp.
	bad := filepath.Join(dir, "blocked.req")
	if err := os.MkdirAll(filepath.Join(bad, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := writeAtomic(bad+".tmp", bad, []byte(body)); err == nil {
		t.Error("writeAtomic over a non-empty directory reported success")
	}
	if _, err := os.Stat(bad + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("a failed publish left its .tmp behind (stat err %v)", err)
	}
}

// exprHasStringLit reports whether e holds the string literal s anywhere inside it (filepath.Join(dest, s), a + s, ...).
func exprHasStringLit(e ast.Expr, s string) bool {
	var found bool
	ast.Inspect(e, func(n ast.Node) bool {
		if lit, ok := n.(*ast.BasicLit); ok && lit.Kind == token.STRING && lit.Value == `"`+s+`"` {
			found = true
		}
		return !found
	})
	return found
}

// NWP-20261123-21: mediad.req is published by temp + rename too. kickMediad has several callers and none is
// serialised against another, so an in-place write can truncate the req while a starting launcher is between two
// of its reads: a torn or mixed request (NWP-20260917-13). The launcher's side -- all four lines read from ONE
// open -- is pinned by core/vendor-common/bin/test-mediad-req-parse.sh.
func TestMediadReqNotWrittenInPlace(t *testing.T) {
	calls := reqWriteCalls(t, "kickMediad")["kickMediad"]
	for _, callee := range []string{"os.WriteFile", "os.Create", "os.OpenFile"} {
		for _, c := range calls[callee] {
			if len(c.Args) > 0 && exprHasStringLit(c.Args[0], "mediad.req") {
				t.Errorf("kickMediad writes mediad.req in place with %s: a launcher parsing it reads a torn or mixed "+
					"request (NWP-20260917-13) -- publish it with writeAtomic(<dest>/mediad.req.tmp, <dest>/mediad.req, ...)", callee)
			}
		}
	}
	// Positive control: the atomic write is actually there, so the absence above is not an absence of any write.
	var found bool
	for _, c := range calls["writeAtomic"] {
		if len(c.Args) == 3 && exprHasStringLit(c.Args[0], "mediad.req.tmp") && exprHasStringLit(c.Args[1], "mediad.req") {
			found = true
		}
	}
	if !found {
		t.Errorf(`kickMediad no longer publishes mediad.req with writeAtomic(filepath.Join(dest, "mediad.req.tmp"), filepath.Join(dest, "mediad.req"), ...)`)
	}
	if len(calls["mediadReqMu.Lock"]) != 1 || len(calls["mediadReqMu.Unlock"]) != 1 {
		t.Errorf("kickMediad no longer takes mediadReqMu around its mediad.req publish (Lock %d, Unlock %d calls): two "+
			"kicks share mediad.req.tmp, so one can truncate the inode the other has just published",
			len(calls["mediadReqMu.Lock"]), len(calls["mediadReqMu.Unlock"]))
	}
}

// NWP-20261123-21: every kick publishes through the ONE path mediad.req.tmp, so the publish must be serialised. This
// stages the interleaving that an unserialised writeAtomic loses: kick A has written mediad.req.tmp and holds
// mediadReqMu, not yet renamed. Kick B must not touch that inode until A releases the lock -- with no lock, B's
// O_TRUNC empties the inode A then renames into place, and the launcher reads an empty request.
func TestMediadReqPublishIsSerialised(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "mrqser", "pw-ser", "10", ""); err != nil {
		t.Fatal(err)
	}
	tmp, req := filepath.Join(dest, "mediad.req.tmp"), filepath.Join(dest, "mediad.req")
	reqA := "mrqser\npw-A\n10\n\n"
	mediadReqMu.Lock()
	locked := true
	defer func() {
		if locked {
			mediadReqMu.Unlock()
		}
	}()
	if err := os.WriteFile(tmp, []byte(reqA), 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { kickMediad(dest); close(done) }()
	// Kick B runs while A still holds the lock. Give it ample time to reach the publish.
	changed := clwWaitFor(500*time.Millisecond, func() bool {
		b, err := os.ReadFile(tmp)
		return err != nil || string(b) != reqA || clwExists(dest, "mediad.req")
	})
	if changed {
		b, err := os.ReadFile(tmp)
		t.Fatalf("kick B wrote mediad.req.tmp (now %q, err %v) or mediad.req while kick A held mediadReqMu with its "+
			"own request staged there: an unserialised publish can empty the inode A renames into place", b, err)
	}
	// Kick A publishes its whole request and releases the lock.
	if err := os.Rename(tmp, req); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(req); string(b) != reqA {
		t.Fatalf("kick A's published request reads %q, want %q", b, reqA)
	}
	mediadReqMu.Unlock()
	locked = false
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("kick B did not finish within 5 s of the lock's release")
	}
	// Control: B did publish once the lock was free, so the stand-off above was the lock and not a skipped kick.
	if b, _ := os.ReadFile(req); string(b) != "mrqser\npw-ser\n10\n\n" {
		t.Fatalf("control failed: after the lock's release mediad.req reads %q, want kick B's whole request", b)
	}
	if clwExists(dest, "mediad.req.tmp") {
		t.Error("kick B left mediad.req.tmp behind")
	}
}
