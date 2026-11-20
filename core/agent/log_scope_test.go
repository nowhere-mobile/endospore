package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261203-27 (docs/backlog.md, "The log scrub and the issue-report scrub eat the `#scope` of a quoted
// `name#scope` token: every mediad line loses `#media`").
//
// mediad serves the `name#media` scope, and serveMediaScope printed that scoped name with %q, so both scrubs took
// `"x#media"` whole and every mediad line read `"<name>"` with no scope. The fix is at the emitter, as #652 did
// for the push lines (logProfile in main.go): the scope goes OUTSIDE the quotes. The scrubs do not change, because
// a profile name is free text and may hold '#' (Q001 (e), docs/product-decisions.md 2026-10-20).

// scopedServeFuncs are the functions that print the scoped name mediad serves. The scan must find each of them.
var scopedServeFuncs = []string{"serveMediaScope", "mediadHealFilter"}

// TestMediadServeLinesKeepTheScope runs serveMediaScope on a real store and puts every line it prints through both
// scrubs: the issue report's (applyIssueNameRules) and the on-disk one (log_scrub's own sed program).
func TestMediadServeLinesKeepTheScope(t *testing.T) {
	// No sed means nothing checked: fail, never skip (see TestLogScrubHoldsOnGeneratedNames).
	sed, err := exec.LookPath("sed")
	if err != nil {
		t.Fatal("sed is not on PATH: this test runs log_scrub's own program and cannot check anything without it")
	}
	prog := roamdScrubProgram(t, "LOG_SCRUB_SED")

	// A name of its own (the blob caches are keyed by DK), with a space and a quote in it.
	name, pass := "zq scope \"x", "scope lines battery staple"
	serve := func(base string) ([]string, []mediaMount) {
		var mounts []mediaMount
		out := captureStderr(t, func() {
			mounts = serveMediaScope(base, name+"#media", pass, t.TempDir(), t.TempDir(), t.TempDir())
		})
		var lines []string
		for _, l := range strings.Split(out, "\n") {
			if strings.HasPrefix(l, "mediad:") {
				lines = append(lines, l)
			}
		}
		return lines, mounts
	}
	has := func(lines []string, sub string) bool {
		for _, l := range lines {
			if strings.Contains(l, sub) {
				return true
			}
		}
		return false
	}

	// Case 1: an empty store.
	empty, _ := serve(newHTTPStore(t))
	if !has(empty, "mediad: profile ") || !has(empty, " empty/absent -> nothing to serve") {
		t.Errorf("empty store: no `empty/absent` profile line among %q", empty)
	}

	// Case 2: one small file in name#media, too small to defer, so the manifest and "no deferred" lines print.
	base := newHTTPStore(t)
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("scope"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#media", pass, src)
	full, mounts := serve(base)
	if mounts != nil {
		t.Errorf("a scope with nothing deferred must mount nothing, got %d mount(s)", len(mounts))
	}
	if !has(full, " manifest v") || !has(full, " has no deferred media -> nothing to serve") {
		t.Errorf("one small file: no `manifest v` and `has no deferred media` lines among %q", full)
	}

	lines := append(empty, full...)
	n := 0
	for _, l := range lines {
		if strings.HasPrefix(l, "mediad: profile ") {
			n++
		}
	}
	if n < 2 {
		t.Fatalf("want at least two `mediad: profile` lines, captured %d: %q", n, lines)
	}
	sh := runSed(t, sed, prog, lines)
	for i, l := range lines {
		goOut := applyIssueNameRules(l)
		if !strings.Contains(goOut, " #media") || strings.Contains(goOut, "zq") {
			t.Errorf("issue-report scrub: %q -> %q, want ` #media` kept and no `zq`", l, goOut)
		}
		if !strings.Contains(sh[i], " #media") || strings.Contains(sh[i], "zq") {
			t.Errorf("log_scrub: %q -> %q, want ` #media` kept and no `zq`", l, sh[i])
		}
		if sh[i] != goOut {
			t.Errorf("the two scrubs disagree on %q: log_scrub %q, issue report %q", l, sh[i], goOut)
		}
	}
}

// TestNoMediadLineQuotesARawScopedName scans the package's source: no dlog line quotes a profile with `profile %q`,
// and the two functions that print mediad's scoped name never put `name` under a %q.
func TestNoMediadLineQuotesARawScopedName(t *testing.T) {
	paths, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	found := map[string]bool{}
	viaLogProfile := 0
	for _, p := range paths {
		if strings.HasSuffix(p, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, p, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			c, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			if _, from, ok := printShape(c); ok {
				for _, a := range c.Args[min(from, len(c.Args)):] {
					if isCallExprTo(a, "", "logProfile") {
						viaLogProfile++
						break
					}
				}
			}
			if !isCallTo(c, "", "dlog") && !isCallTo(c, "", "dlogv") || len(c.Args) == 0 {
				return true
			}
			if s, ok := constString(c.Args[0]); ok && strings.Contains(s, "profile %q") {
				t.Errorf("%s: a log line quotes a raw profile with `profile %%q` (%q): print it as %%s with logProfile",
					fset.Position(c.Pos()), s)
			}
			return true
		})
		for _, d := range f.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Recv != nil || fd.Body == nil || !containsStr(scopedServeFuncs, fd.Name.Name) {
				continue
			}
			found[fd.Name.Name] = true
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				c, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				fi, from, ok := printShape(c)
				if !ok || fi < 0 || fi >= len(c.Args) {
					return true
				}
				s, ok := constString(c.Args[fi])
				if !ok {
					return true
				}
				for k, v := range fmtVerbs(s) {
					if v != 'q' || from+k >= len(c.Args) {
						continue
					}
					if id, ok := c.Args[from+k].(*ast.Ident); ok && id.Name == "name" {
						t.Errorf("%s: %s prints the scoped name under %%q (%q): its scope is lost to the scrub, "+
							"print it as %%s with logProfile(name)", fset.Position(c.Pos()), fd.Name.Name, s)
					}
				}
				return true
			})
		}
	}
	for _, fn := range scopedServeFuncs {
		if !found[fn] {
			t.Errorf("control: function %s not found in the package: the scan checked nothing there", fn)
		}
	}
	if viaLogProfile < 8 {
		t.Errorf("control: only %d print call(s) pass logProfile(...): want at least 8, or the scan saw too little", viaLogProfile)
	}
}

func containsStr(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// fmtVerbs returns the verb letter of each argument-taking directive in a format, in order. It skips `%%` and
// flags, width and precision; the formats it reads take no `*` or indexed arguments.
func fmtVerbs(format string) []byte {
	var out []byte
	for i := 0; i < len(format); i++ {
		if format[i] != '%' {
			continue
		}
		i++
		for i < len(format) && strings.IndexByte("+-# 0123456789.", format[i]) >= 0 {
			i++
		}
		if i < len(format) && format[i] != '%' {
			out = append(out, format[i])
		}
	}
	return out
}
