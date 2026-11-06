package main

// NWP-20261105-01 -- mediad's and the mid-session media sync's log lines print a session's media paths QUOTED.
//
// mediad's stderr is /data/nowhere/mediad.log and the media-sync lines reach roam.log through the seal's stdout.
// roamd's log_scrub keeps both as a tail across every reap and boot and redacts QUOTED tokens only, and a
// session-scope issue report carries mediad.log through the same rule (applyIssueNameRules). A bare rel in a line
// -- or in an error the line prints, since an *fs.PathError repeats its path unquoted -- therefore outlives its
// profile and reaches the next profile's report. Q001 (e) (docs/product-decisions.md, 2026-10-20) decided this is a
// leak past the scrub; NWP-20261102-03 fixed it for the seal walk (sealUnreadableKeepLine). This is the same
// invariant for the four media files.

import (
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"sync"
	"testing"
)

var mlpFiles = []string{"mediafs.go", "media_server.go", "media_defer_sync.go", "media_span.go"}

// mlpPathIdents are the names a session path travels under in these files; mlpPathSels the selector forms.
var mlpPathIdents = map[string]bool{"rel": true, "target": true, "hidden": true, "dir": true, "pp": true, "cur": true}
var mlpPathSels = map[string]bool{"f.rel": true, "f.path": true, "mt.target": true, "hdr.Name": true}

// mlpKnownGood is a line that already quoted before this slice: the scan must have seen it, or it saw nothing.
const mlpKnownGood = "mediad: profile %q empty/absent -> nothing to serve"

// mlpExempt is keyed "<file> <func> <quoted format>". A stale entry fails.
var mlpExempt = map[string]string{
	`media_server.go evictCache "mediad: evicted %s (%d bytes) under storage pressure -- free=%d floor=%d cap=%d total=%d"`: "a cache file name: cacheKey (sha256 of the chunk list), not the user's file name",
	`media_server.go initPart "mediad: fresh .part %s (%d chunks, size %d) -- cache was COLD/absent for this file"`:         "a cache file name: cacheKey plus .part, not the user's file name",
}

// mlpHasPath: the expression holds a session-path identifier or selector. The Sel of a selector is never matched as
// a bare name, so s.cacheDir and d.Size do not count.
func mlpHasPath(e ast.Expr) bool {
	found := false
	var walk func(n ast.Node) bool
	walk = func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.SelectorExpr:
			if id, ok := x.X.(*ast.Ident); ok && mlpPathSels[id.Name+"."+x.Sel.Name] {
				found = true
			}
			ast.Inspect(x.X, walk)
			return false
		case *ast.Ident:
			if mlpPathIdents[x.Name] {
				found = true
			}
		}
		return true
	}
	ast.Inspect(e, walk)
	return found
}

// mlpShape: where the format string sits in a print or error call of interest.
func mlpShape(c *ast.CallExpr) (fmtIdx int, isErrorf, ok bool) {
	switch {
	case isCallTo(c, "", "dlog"), isCallTo(c, "", "dlogv"), isCallTo(c, "fmt", "Printf"):
		return 0, false, true
	case isCallTo(c, "fmt", "Errorf"):
		return 0, true, true
	case isCallTo(c, "fmt", "Fprintf") && len(c.Args) > 0 && isSel(c.Args[0], "os", "Stderr"):
		return 1, false, true
	}
	return 0, false, false
}

func TestMediaLogLinesQuotePaths(t *testing.T) {
	fset := token.NewFileSet()
	count, sawKnownGood := 0, false
	usedExempt := map[string]bool{}
	for _, name := range mlpFiles {
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		for _, decl := range f.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				c, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				idx, isErrorf, ok := mlpShape(c)
				if !ok || idx >= len(c.Args) {
					return true
				}
				format, lit := constString(c.Args[idx])
				if !lit {
					return true
				}
				count++
				if format == mlpKnownGood {
					sawKnownGood = true
				}
				key := name + " " + fd.Name.Name + " " + strconv.Quote(format)
				at := fset.Position(c.Pos())
				verbs, sharp, indexed := formatVerbs(format)
				var problems []string
				if indexed {
					problems = append(problems, "an indexed verb defeats the scan")
				}
				for i, a := range c.Args[idx+1:] {
					var v byte
					if i < len(verbs) {
						v = verbs[i]
					}
					if mlpHasPath(a) && (v != 'q' || sharp[min(i, len(sharp)-1)]) {
						problems = append(problems, "a session path under %"+string(v)+", want %q")
					}
					if id, ok := a.(*ast.Ident); ok && !isErrorf && (id.Name == "err" || id.Name == "e") {
						problems = append(problems, "an error printed raw: print errCode("+id.Name+")")
					}
				}
				if len(problems) == 0 {
					return true
				}
				if _, ex := mlpExempt[key]; ex {
					usedExempt[key] = true
					return true
				}
				t.Errorf("%s: %s: %s", at, strconv.Quote(format), strings.Join(problems, "; "))
				return true
			})
		}
	}
	for k, why := range mlpExempt {
		if !usedExempt[k] {
			t.Errorf("stale exemption (%s): %s", why, k)
		}
	}
	if count < 30 || !sawKnownGood {
		t.Fatalf("the scan saw %d matching calls (known-good line seen: %v); want >= 30 and the known-good line", count, sawKnownGood)
	}
}

const mlpRel = "DCIM/Camera/IMG trip one.jpg"

func mlpAssertScrubbed(t *testing.T, what, line string) {
	t.Helper()
	if !strings.Contains(line, strconv.Quote(mlpRel)) {
		t.Errorf("%s: the rel is not quoted: %q", what, line)
	}
	scrubbed := applyIssueNameRules(line)
	for _, w := range []string{"IMG", "trip", "one.jpg", "DCIM", "Camera"} {
		if strings.Contains(scrubbed, w) {
			t.Errorf("%s: %q survives the issue report's name rules: %q", what, w, scrubbed)
		}
	}
}

func TestMediaDamagedLineIsScrubbed(t *testing.T) {
	out := captureStderr(t, func() {
		s := &mediaServer{}
		s.markDamaged("k", mlpRel, 0)
		s.markDamaged("k2", mlpRel, -1)
	})
	n := 0
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "CORRUPT") {
			n++
			mlpAssertScrubbed(t, "markDamaged", line)
		}
	}
	if n != 2 {
		t.Fatalf("want 2 CORRUPT lines, got %d in %q", n, out)
	}
}

func TestMediaFetchErrorQuotesItsPath(t *testing.T) {
	d := deferredFile{Chunks: []string{strings.Repeat("ab", 32)}, Size: 7}
	s := &mediaServer{
		deferred: map[string]deferredFile{mlpRel: d},
		cacheDir: t.TempDir(),
		locks:    map[string]*sync.Mutex{},
		damaged:  map[string]map[int]bool{cacheKey(d): {-1: true}},
	}
	_, err := s.fetchFile(mlpRel)
	if err == nil {
		t.Fatal("fetchFile of a damaged file succeeded")
	}
	if !errors.Is(err, errDamagedChunk) {
		t.Fatalf("the error no longer wraps errDamagedChunk: %v", err)
	}
	mlpAssertScrubbed(t, "fetchFile error text", err.Error())
	mlpAssertScrubbed(t, "fetchFile errCode", "mediad: "+errCode(err))
}

func TestMediaSyncSkippedLineIsScrubbed(t *testing.T) {
	m := chunkManifest{Ess: map[string]essRegion{mlpRel: {S: 0, E: 1}}} // Chunks empty: fetchEssSpan refuses it
	var wrote []string
	out := captureStdout(t, func() {
		wrote, _ = materializeCarried("", nil, m, []string{mlpRel}, t.TempDir())
	})
	if len(wrote) != 0 {
		t.Fatalf("wrote %v", wrote)
	}
	n := 0
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "SKIPPED") {
			n++
			mlpAssertScrubbed(t, "media-sync SKIPPED", line)
		}
	}
	if n != 1 {
		t.Fatalf("want 1 SKIPPED line, got %d in %q", n, out)
	}
}
