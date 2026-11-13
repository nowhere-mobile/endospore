package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// NWP-20261108-40: no test reaches the host's sync(2). It waits on every dirty page of the HOST with no limit and
// proves nothing about durability here: on a loaded CI box TestSignOutOfANeverRestoredSession sat in it until the
// 45-minute step limit (NOWHERE-1691 RF-001). init replaces both flush seams for the whole test binary. A future test
// that needs the real flush assigns syscall.Sync to the seam and restores stubHostSync in t.Cleanup.
var flushSeamCalls atomic.Int64

func stubHostSync() { flushSeamCalls.Add(1) }

func init() { logoffSync, sealSync = stubHostSync, stubHostSync }

// flushSeamFile declares the seams, and flushSeams is every seam a device build must initialise to syscall.Sync.
const flushSeamFile = "logoff_cutoff.go"

var flushSeams = []string{"logoffSync", "sealSync"}

// parseAgentSources parses every non-test .go file of core/agent, without comments: the prose in main.go names
// syscall.Sync() too. third_party is vendored code and testdata is not built.
func parseAgentSources(t *testing.T, fset *token.FileSet) map[string]*ast.File {
	t.Helper()
	files := map[string]*ast.File{}
	err := filepath.WalkDir(".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if p == "third_party" || p == "testdata" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		f, err := parser.ParseFile(fset, p, nil, parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		files[p] = f
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if files[flushSeamFile] == nil || files["main.go"] == nil {
		t.Fatalf("the walk found %d files and missed %s or main.go: it would check nothing", len(files), flushSeamFile)
	}
	return files
}

// seamInitialisers returns each package-level var of f with its initialiser.
func seamInitialisers(f *ast.File) map[string]ast.Expr {
	inits := map[string]ast.Expr{}
	for _, decl := range f.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.VAR {
			continue
		}
		for _, spec := range gen.Specs {
			vs := spec.(*ast.ValueSpec)
			for i, name := range vs.Names {
				if i < len(vs.Values) {
					inits[name.Name] = vs.Values[i]
				}
			}
		}
	}
	return inits
}

// isSyncSelector reports whether e is exactly pkg.Sync.
func isSyncSelector(e ast.Expr, pkg string) bool {
	sel, ok := e.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != "Sync" {
		return false
	}
	x, ok := sel.X.(*ast.Ident)
	return ok && x.Name == pkg
}

// A flush outside the seams is a sync(2) no test stub can reach, and a seam that is not syscall.Sync, or a seal that
// lost its flush, is a device that seals before the lazy app writes land.
func TestAgentFlushGoesThroughTheSeams(t *testing.T) {
	fset := token.NewFileSet()
	files := parseAgentSources(t, fset)

	inits := seamInitialisers(files[flushSeamFile])
	allowed := map[ast.Expr]bool{}
	for _, seam := range flushSeams {
		value := inits[seam]
		if !isSyncSelector(value, "syscall") {
			t.Errorf("%s: the seam %s is not initialised to exactly syscall.Sync: the device would not flush", flushSeamFile, seam)
			continue
		}
		allowed[value] = true
	}

	// A function value is as much a flush as a call, so this matches the selector and not only a call of it.
	for _, f := range files {
		locals := map[string]bool{}
		for _, imp := range f.Imports {
			path := strings.Trim(imp.Path.Value, `"`)
			if path != "syscall" && path != "golang.org/x/sys/unix" {
				continue
			}
			if imp.Name != nil {
				locals[imp.Name.Name] = true
			} else {
				locals[path[strings.LastIndex(path, "/")+1:]] = true
			}
		}
		ast.Inspect(f, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "Sync" || allowed[sel] {
				return true
			}
			if x, ok := sel.X.(*ast.Ident); ok && locals[x.Name] {
				t.Errorf("%s: a bare %s.Sync outside the seam declarations: go through logoffSync or sealSync", fset.Position(sel.Pos()), x.Name)
			}
			return true
		})
	}

	// The rule above cannot see a deleted flush. handleLogout's is pinned in logoff_cutoff_test.go.
	for _, fn := range []string{"promoteToStore", "handleBackup"} {
		var body *ast.BlockStmt
		for _, f := range files {
			for _, decl := range f.Decls {
				if d, ok := decl.(*ast.FuncDecl); ok && d.Recv == nil && d.Name.Name == fn {
					body = d.Body
				}
			}
		}
		if body == nil {
			t.Errorf("%s: not found, so its flush is not checked", fn)
			continue
		}
		flushes, firstFlush, firstWorker := 0, token.NoPos, token.NoPos
		ast.Inspect(body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			id, ok := call.Fun.(*ast.Ident)
			if !ok {
				return true
			}
			if id.Name == "sealSync" {
				flushes++
				if firstFlush == token.NoPos || call.Pos() < firstFlush {
					firstFlush = call.Pos()
				}
			}
			if strings.HasPrefix(id.Name, "triggerRoamWorker") && (firstWorker == token.NoPos || call.Pos() < firstWorker) {
				firstWorker = call.Pos()
			}
			return true
		})
		if flushes != 1 || firstWorker == token.NoPos || firstFlush >= firstWorker {
			t.Errorf("%s: %d sealSync call(s), first at %v, first worker call at %v: want exactly one flush before the first worker call",
				fn, flushes, fset.Position(firstFlush), fset.Position(firstWorker))
		}
	}
}
