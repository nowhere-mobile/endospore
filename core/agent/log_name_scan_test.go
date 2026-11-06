package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// NWP-20261008-09 (docs/backlog.md, "Profile names survive the on-device log scrub", LOG (6)).
//
// log_scrub takes a profile name out of the logs only when the name is QUOTED: the daemon prints it with %q, and
// logProfile quotes it with the #105 tag outside. A name printed through %s, %v or `+` is bare, and a multi-word
// name then keeps every word after the first on the handset, past reap, boot and power-off. Nothing failed when a
// line did that: the export line printed `-> ref/export/<name>` bare from 2026-06-28 until this slice, and
// billing.go wrapped logProfile in a second %q, which escaped its quotes so the scrub paired the wrong ones.
//
// So this scans every non-test file for a print of a name-bearing identifier that is not quoted, and for logProfile
// under anything but %s/%v. It is a source scan, not a behaviour test, and its gaps are stated: it cannot see a
// name that travels inside a store key (that is log_redact_test.go), inside an os.Args value (no command that prints
// one does so bare today, and the scan does not map which argument is a name), inside a slice or a call (name[:i],
// strings.TrimSpace(name)), or through a local variable printed later.

// nameIdents are the identifiers this package uses for a profile name, or a name with its scope suffix: name,
// profile, scope and scoped (restore-app, scopeFootprint, scope_tie), mname, and nm/sn as readRoamSession and the NFC
// handlers name the session's profile. Not every use of them is a name -- namePrintExempt lists the ones that are not.
// nameSels are the capSession fields that hold one: sess.name (the scope) and sess.base (the profile).
var (
	nameIdents = map[string]bool{"name": true, "profile": true, "scope": true, "scoped": true, "mname": true, "nm": true, "sn": true}
	nameSels   = map[string]bool{"sess.name": true, "sess.base": true, "capSession.name": true, "capSession.base": true}
)

// namePrintExempt: a finding that is NOT a profile name, keyed by "<file> <func> <format or first argument>", with
// the reason. An entry that no longer matches anything fails the test, so this list cannot go stale silently.
var namePrintExempt = map[string]string{
	`main.go handleLogin "%s: write reason: %v"`: "name is the request's first line here, a REKEY-WAIT-* verb (handleLogin " +
		"reuses the variable for the profile name only in the legacy login, which prints it with %q)",
	`telephony_lock.go handleTelCmd "[logind] %s refused: %v\n"`:                                                                  "name is the telephony verb (handleTelCmd's parameter), not a profile",
	`telephony_lock.go handleTelCmd "[logind] %s waited %dms for telMu -> %s\n"`:                                                  "name is the telephony verb (handleTelCmd's parameter), not a profile",
	`catalog.go handleFetchApp "[fetchapp] %s %s: %v\n"`:                                                                          "nm is the APK file name from the catalog entry, not a profile",
	`main.go handleDeleteBinding "[logind] unbind: record deletion incomplete (%d sealed, %d mailbox removed) -> binding kept\n"`: "nm is a count of deleted mailbox records",
	`main.go handleDeleteBinding "[logind] unbind: %d SIM record(s) removed, %d sealed and %d mailbox record file(s) deleted\n"`:  "nm is a count of deleted mailbox records",
	`end_unsaved.go refusalScopeLines "SCOPE %s %s %d"`:                                                                           "scope is roamd's scope token (vault, apps, ...), each passing refusalToken (a-z and -, NWP-20261113-08), not a profile",
}

type namePrint struct {
	file, fn, key, why string
	line               int
}

type namePrintStats struct {
	files, calls, logProfileCalls int
	sawKnownGood                  bool
}

// The line that must be scanned and accepted: a %q name next to a %s value. If the scan stops seeing it, the scan
// has stopped working, and a clean result would mean nothing.
const knownGoodNamePrint = "[logind] logout seal %q user %s (OK); switch+reap queued\n"

func TestNoLogPrintsAProfileNameOutsideQuotes(t *testing.T) {
	fset := token.NewFileSet()
	files := map[string]*ast.File{}
	ents, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, n, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", n, err)
		}
		files[n] = f
	}
	finds, st := scanNamePrints(fset, files)
	if st.files < 50 || st.calls < 400 || st.logProfileCalls < 50 || !st.sawKnownGood {
		t.Fatalf("the scan saw too little to mean anything: %+v (want >= 50 files, >= 400 print calls, >= 50 "+
			"logProfile calls, and the known-good line)", st)
	}
	used := map[string]bool{}
	for _, f := range finds {
		if _, ok := namePrintExempt[f.key]; ok {
			used[f.key] = true
			continue
		}
		t.Errorf("%s:%d (%s): %s -- quote it (%%q, or logProfile under %%s), or exempt it in namePrintExempt with "+
			"the reason it is not a profile name. key %q", f.file, f.line, f.fn, f.why, f.key)
	}
	for k := range namePrintExempt {
		if !used[k] {
			t.Errorf("namePrintExempt entry %q matches nothing any more -- drop it", k)
		}
	}
}

// The scan must catch the shapes that actually leaked, and pass the ones that are safe. Run on snippets, so the
// check survives the fix of the real lines (the mutation check of the real tree is run by hand, see the worklog).
func TestNamePrintScanCatchesTheKnownShapes(t *testing.T) {
	cases := []struct {
		src  string
		want int
	}{
		// the export line before NWP-20261008-09, verbatim
		{`fmt.Fprintf(os.Stderr, "[logind] export %q: sealed %d bytes -> ref/export/%s (blob %s)\n", name, len(bundle), name, blob[:12])`, 1},
		// billing.go before NWP-20261008-09: logProfile wrapped in a second %q
		{`fmt.Errorf("pay-rent: cannot measure %q -- refusing", logProfile(name))`, 1},
		{`fmt.Println("x " + name)`, 1},
		{`fmt.Printf("%v", name)`, 1},
		{`fmt.Printf("%*s %s", 3, "a", name)`, 1},
		{`dlog("serving %s", name)`, 1},
		{`fail("x: " + name)`, 1},
		{`retryStore("PUT ref/export/"+name, nil)`, 1},
		{`fmt.Fprintf(os.Stderr, "x " + name + " %d\n", 3)`, 1},
		{`fmt.Printf("%s", logProfile(name))`, 0},
		{`fmt.Printf("%q", name)`, 0},
		{`fmt.Printf("%q %s", name, logProfile(name))`, 0},
		{`fmt.Fprintf(conn, "%s\n", name)`, 0},             // a reply to the chooser over its socket, not a log
		{`fmt.Printf("%s", headKey(base, name, pass))`, 0}, // a function of the name is not the name
		{`fmt.Printf("%d %s", len(name), uid)`, 0},
		{`fmt.Printf("%s", nm)`, 1},
		{`fmt.Printf("%q", nm)`, 0},
		{`fmt.Printf("%#q", name)`, 1}, // backquoted: log_scrub matches only double quotes
		{`fmt.Printf("%+q", name)`, 0}, // still double-quoted, ASCII escapes
		{`fmt.Printf("%s", scope)`, 1},
		{`fmt.Printf("%s", sess.base)`, 1},
		{`fmt.Printf("%q", sess.base)`, 0},
		{`fmt.Printf("%s", dom.name)`, 0}, // a media basename, not a profile
	}
	for _, c := range cases {
		src := "package main\nfunc f() {\n" + c.src + "\n}\n"
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, "snippet.go", src, 0)
		if err != nil {
			t.Fatalf("parse %q: %v", c.src, err)
		}
		finds, _ := scanNamePrints(fset, map[string]*ast.File{"snippet.go": f})
		if len(finds) != c.want {
			t.Errorf("%s: %d finding(s), want %d: %+v", c.src, len(finds), c.want, finds)
		}
	}
}

func scanNamePrints(fset *token.FileSet, files map[string]*ast.File) ([]namePrint, namePrintStats) {
	var out []namePrint
	var st namePrintStats
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, fname := range names {
		st.files++
		for _, d := range files[fname].Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if isCallTo(call, "", "logProfile") {
					st.logProfileCalls++
				}
				fmtIdx, argsFrom, ok := printShape(call)
				if !ok {
					return true
				}
				st.calls++
				add := func(key, why string) {
					out = append(out, namePrint{file: fname, fn: fd.Name.Name, key: fname + " " + fd.Name.Name + " " + key,
						why: why, line: fset.Position(call.Pos()).Line})
				}
				if fmtIdx < 0 { // Print-shaped: no verbs, so a bare name anywhere is unquoted
					for _, a := range call.Args[argsFrom:] {
						if hasBareName(a) {
							add(firstArgKey(call, argsFrom), "a profile name printed with no quotes")
							break
						}
					}
					return true
				}
				format, lit := constString(call.Args[fmtIdx])
				if hasBareName(call.Args[fmtIdx]) {
					add(firstArgKey(call, fmtIdx), "a profile name concatenated into the format")
				}
				if !lit {
					return true // a non-literal format: nothing to pair; a name in its args is caught as bare below
				}
				if format == knownGoodNamePrint {
					st.sawKnownGood = true
				}
				verbs, sharp, indexed := formatVerbs(format)
				if indexed {
					add(strconv.Quote(format), "an indexed verb (%[n]) -- this scan cannot pair it; rewrite or extend the scan")
					return true
				}
				for i, a := range call.Args[fmtIdx+1:] {
					v := byte(0)
					if i < len(verbs) {
						v = verbs[i]
					}
					switch {
					case isIdentIn(a) || isNameSel(a):
						if v != 'q' {
							add(strconv.Quote(format), fmt.Sprintf("a profile name under %%%c", v))
						} else if i < len(sharp) && sharp[i] {
							add(strconv.Quote(format), "a profile name under %#q (backquoted; log_scrub matches only double quotes)")
						}
					case isCallExprTo(a, "", "logProfile"):
						if v != 's' && v != 'v' {
							add(strconv.Quote(format), fmt.Sprintf("logProfile under %%%c (it quotes the name itself)", v))
						}
					case hasBareName(a):
						add(strconv.Quote(format), "a profile name concatenated into an argument")
					}
				}
				return true
			})
		}
	}
	return out, st
}

// printShape says whether a call writes text a log can carry, and where its format and arguments are: fmtIdx is
// the format's index, or -1 for a Print-shaped call; argsFrom is where the printed values start. Fprint* counts only
// when it writes to os.Stderr or os.Stdout -- to a connection it is a reply to the chooser, not a log line.
func printShape(c *ast.CallExpr) (fmtIdx, argsFrom int, ok bool) {
	toStd := len(c.Args) > 0 && (isSel(c.Args[0], "os", "Stderr") || isSel(c.Args[0], "os", "Stdout"))
	switch {
	case isCallTo(c, "fmt", "Printf"), isCallTo(c, "fmt", "Errorf"), isCallTo(c, "fmt", "Sprintf"),
		isCallTo(c, "", "dlog"), isCallTo(c, "", "dlogv"):
		return 0, 1, len(c.Args) > 0
	case isCallTo(c, "fmt", "Fprintf"):
		return 1, 2, toStd && len(c.Args) > 1
	case isCallTo(c, "fmt", "Print"), isCallTo(c, "fmt", "Println"), isCallTo(c, "errors", "New"),
		isCallTo(c, "", "fail"), isCallTo(c, "", "panic"):
		return -1, 0, true
	case isCallTo(c, "", "retryStore"):
		return -1, 0, len(c.Args) > 0
	case isCallTo(c, "fmt", "Fprint"), isCallTo(c, "fmt", "Fprintln"):
		return -1, 1, toStd
	}
	return 0, 0, false
}

func isCallTo(c *ast.CallExpr, pkg, fn string) bool {
	if pkg == "" {
		id, ok := c.Fun.(*ast.Ident)
		return ok && id.Name == fn
	}
	return isSel(c.Fun, pkg, fn)
}

func isCallExprTo(e ast.Expr, pkg, fn string) bool {
	c, ok := e.(*ast.CallExpr)
	return ok && isCallTo(c, pkg, fn)
}

func isSel(e ast.Expr, pkg, sel string) bool {
	s, ok := e.(*ast.SelectorExpr)
	if !ok || s.Sel.Name != sel {
		return false
	}
	id, ok := s.X.(*ast.Ident)
	return ok && id.Name == pkg
}

func isIdentIn(e ast.Expr) bool {
	id, ok := e.(*ast.Ident)
	return ok && nameIdents[id.Name]
}

func isNameSel(e ast.Expr) bool {
	s, ok := e.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	id, ok := s.X.(*ast.Ident)
	return ok && nameSels[id.Name+"."+s.Sel.Name]
}

// hasBareName: a name identifier as an operand of a `+` chain (or alone, or parenthesised). A name passed INTO a
// call (logProfile(name), headKey(base, name, pass)) is that function's business, not a print of the name.
func hasBareName(e ast.Expr) bool {
	switch x := e.(type) {
	case *ast.Ident:
		return nameIdents[x.Name]
	case *ast.SelectorExpr:
		return isNameSel(x)
	case *ast.ParenExpr:
		return hasBareName(x.X)
	case *ast.BinaryExpr:
		return x.Op == token.ADD && (hasBareName(x.X) || hasBareName(x.Y))
	}
	return false
}

// constString folds a string literal or a `+` chain of them.
func constString(e ast.Expr) (string, bool) {
	switch x := e.(type) {
	case *ast.BasicLit:
		if x.Kind != token.STRING {
			return "", false
		}
		s, err := strconv.Unquote(x.Value)
		return s, err == nil
	case *ast.ParenExpr:
		return constString(x.X)
	case *ast.BinaryExpr:
		if x.Op != token.ADD {
			return "", false
		}
		a, ok1 := constString(x.X)
		b, ok2 := constString(x.Y)
		return a + b, ok1 && ok2
	}
	return "", false
}

func firstArgKey(c *ast.CallExpr, i int) string {
	if i < len(c.Args) {
		if s, ok := constString(c.Args[i]); ok {
			return strconv.Quote(s)
		}
	}
	return "(non-literal)"
}

// formatVerbs returns the verb consumed by each argument, in order, and whether its flags held `#`: a `*` width or
// precision consumes an argument too (recorded as '*'). indexed reports an explicit %[n], which this scan does not
// pair.
func formatVerbs(f string) (verbs []byte, sharp []bool, indexed bool) {
	for i := 0; i < len(f); i++ {
		if f[i] != '%' {
			continue
		}
		i++
		if i < len(f) && f[i] == '%' {
			continue
		}
		hash := false
		for i < len(f) && strings.IndexByte("+-# 0", f[i]) >= 0 {
			hash = hash || f[i] == '#'
			i++
		}
		for ; i < len(f); i++ {
			c := f[i]
			if c == '[' {
				return verbs, sharp, true
			}
			if c == '*' {
				verbs, sharp = append(verbs, '*'), append(sharp, false)
				continue
			}
			if (c >= '0' && c <= '9') || c == '.' {
				continue
			}
			verbs, sharp = append(verbs, c), append(sharp, hash)
			break
		}
	}
	return verbs, sharp, false
}
