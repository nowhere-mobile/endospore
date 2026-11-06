package main

import (
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// NWP-20261008-09. Every test here asserts the planted name is gone BY EACH WORD, never by counting <name>
// placeholders: counting is what let DIA-20260807-13's 125 surviving names read as success.

// nameFragments are the pieces of a planted name that must not survive: every run of the qz marker and the ASCII
// letters after it. Every planted word carries the marker; the anchor texts planted inside "qzv #keys (user 9" do not,
// because ordinary log lines hold them too. Nothing BEFORE the marker is part of a fragment, so a word that starts
// with a non-ASCII or punctuation character is still found when only its URL escape, or its tail, survives.
var reNameFragment = regexp.MustCompile(`(?i)qz[a-z]*`)

func nameFragments(name string) []string { return reNameFragment.FindAllString(name, -1) }

func assertNoFragment(t *testing.T, what, name, got string) {
	t.Helper()
	low := strings.ToLower(got)
	for _, f := range nameFragments(name) {
		if strings.Contains(low, strings.ToLower(f)) {
			t.Errorf("%s: %q of the name %q survives in %q", what, f, name, got)
		}
	}
}

// hardNames: spaces; a quote inside, first (alone, then followed by a word, then closed and glued to more), before a
// space, four in a row, around a word; a trailing backslash; an apostrophe; a non-ASCII and a punctuation initial; a
// name that opens with `"<`; and names holding the very texts the scrub rules anchor on. The hard shapes of
// test-log-name-scrub.sh's PLANTS, with the qz marker where the shell uses zq.
var hardNames = []string{"Qzv Qzw", `qza"qzb`, `"qzlead`, `qztrail\`, `qza\qzb qzc`, "O'Qzbrien qzx", "qzv #keys (user 9",
	`"qzlead qzx`, `"qza"qzb qzc`, `ref/export/qzx"qzy qzz`, "qza #qzb", "qza -> ref/export/qzb",
	"qzs: sealed 1 bytes -> ref/export/qzt", "qza BLANKqzc", "qza ERR-qzd",
	"Éqza qzb", "_qza qzb", `qza "qzb" qzc`, `qza qzb"qzc"qzd`, `qza" qzb`, `qza"Éqzb`, `"<qz qzw`, `qza"qzb"qzc"qzd"qze`,
	`qza qzb" qzc`, `qza"qzb: sealed 1 bytes -> ref/export/qzc (blob ab)qzd`, `qza (1/2)qzb\"qzc`}

func TestLogSafeWhatRedactsOnlyExportKeys(t *testing.T) {
	for _, n := range hardNames {
		for _, sfx := range []string{"", "#media"} {
			got := logSafeWhat("PUT ref/export/" + n + sfx)
			if got != "PUT ref/export/<name>" {
				t.Errorf("logSafeWhat(PUT ref/export/%s%s) = %q, want PUT ref/export/<name>", n, sfx, got)
			}
		}
	}
	for _, keep := range []string{"GET blob/0123456789abcdef", "STAT blob/ab", "cap GET ref/4f2a99", "cap PUT"} {
		if got := logSafeWhat(keep); got != keep {
			t.Errorf("logSafeWhat changed a key that names no profile: %q -> %q", keep, got)
		}
	}
}

func TestLogSafeStoreErrRedactsEveryForm(t *testing.T) {
	for _, n := range hardNames {
		what := "PUT ref/export/" + n + "#media"
		errs := []string{
			// minio-go v7.2.0: a *url.Error carries the path-escaped key, and a closed connection repeats it unquoted
			`Put "https://s3.example/b/ref/export/` + escPath(n) + `%23media": EOF`,
			`Connection closed by foreign host https://s3.example/b/ref/export/` + escPath(n) + `%23media. Retry again.`,
			// this package's own errors print the raw key
			"cap GET ref/export/" + n + "#media -> status 500",
			// the gateway read-cap error: query-escaped
			"gateway /cap?op=read&ref=ref%2Fexport%2F" + escQuery(n) + "%23media: 403",
		}
		for _, e := range errs {
			assertNoFragment(t, "logSafeStoreErr", n, logSafeStoreErr(what, errors.New(e)))
		}
	}
	// ...and an error that names no profile passes unchanged: the diagnostic is the point of printing it.
	if got := logSafeStoreErr("GET blob/ab", errors.New("connection reset by peer")); got != "connection reset by peer" {
		t.Errorf("an unrelated error was rewritten: %q", got)
	}
}

// The spellings are derived HERE, not taken from nameSpellings: a spelling nameSpellings dropped would otherwise
// also never be planted. Each is planted with and without the key prefix, because the key regex alone removes an
// escaped spelling that follows `ref/export/`.
func TestRedactNameInRemovesEverySpelling(t *testing.T) {
	for _, n := range hardNames {
		q := strconv.Quote(n)
		for _, s := range []string{n, q[1 : len(q)-1], qnSpelling(n), url.PathEscape(n), url.QueryEscape(n)} {
			for _, ln := range []string{"cap-flush: no write cap for ref/export/" + s + " -- x", "store: " + s + " -- x"} {
				assertNoFragment(t, "redactNameIn", n, redactNameIn(ln, n))
			}
		}
	}
	if got := redactNameIn("x", ""); got != "x" {
		t.Errorf("an empty name must change nothing, got %q", got)
	}
}

// The retry line itself, end to end: a self-hosted store retrying an export write printed the raw key on every
// retry, even one that recovered (LOG (5)).
func TestRetryStoreNeverPrintsAnExportName(t *testing.T) {
	old := s3RetryBase
	s3RetryBase = 0
	defer func() { s3RetryBase = old }()
	for _, n := range hardNames {
		out := captureStderr(t, func() {
			_ = retryStore("PUT ref/export/"+n+"#media", func() error {
				return errors.New(`Put "https://s3.example/b/ref/export/` + escPath(n) + `%23media": EOF`)
			})
		})
		if strings.Count(out, "retry PUT ref/export/<name> (") != 4 {
			t.Errorf("want 4 retry lines naming the redacted key, got %q", out)
		}
		assertNoFragment(t, "retryStore stderr", n, out)
	}
}

// Both export handlers print their error through redactNameIn: the error can carry the export key in any form,
// and the source scan cannot see a name that travels inside an error value.
func TestExportHandlersRedactTheirErrors(t *testing.T) {
	fset := token.NewFileSet()
	for file, fn := range map[string]string{"main.go": "handleExport", "export_media.go": "handleExportMedia"} {
		f, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		var body *ast.BlockStmt
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == fn {
				body = fd.Body
			}
		}
		if body == nil {
			t.Fatalf("%s not found in %s", fn, file)
		}
		werrPrints := 0
		ast.Inspect(body, func(n ast.Node) bool {
			c, ok := n.(*ast.CallExpr)
			if !ok || !isCallTo(c, "fmt", "Fprintf") || len(c.Args) < 2 || !isSel(c.Args[0], "os", "Stderr") {
				return true
			}
			for _, a := range c.Args[2:] {
				if id, ok := a.(*ast.Ident); ok && id.Name == "werr" {
					t.Errorf("%s prints werr bare at %s -- route it through redactNameIn", fn, fset.Position(c.Pos()))
				}
				if ac, ok := a.(*ast.CallExpr); ok && isCallTo(ac, "", "redactNameIn") {
					werrPrints++
				}
			}
			return true
		})
		if werrPrints != 1 {
			t.Errorf("%s: want exactly one error line through redactNameIn, found %d", fn, werrPrints)
		}
	}
}

// escPath is minio-go v7.2.0's EncodePath: every byte outside A-Za-z0-9 and -_.~/ as %XX, so a non-ASCII rune goes
// as its UTF-8 bytes. escQuery is the gateway's query escaping.
func escPath(n string) string {
	var b strings.Builder
	for i := 0; i < len(n); i++ {
		c := n[i]
		if 'A' <= c && c <= 'Z' || 'a' <= c && c <= 'z' || '0' <= c && c <= '9' || strings.IndexByte("-_.~/", c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
func escQuery(n string) string { return url.QueryEscape(n) }

// NWP-20261009-02: since the store binds write caps, a head key is the profile string (ref/<profileRefV2>) and a
// presigned URL's query is a live cap. A net/http *url.Error from a cap PUT or GET carries the whole URL, and the
// gateway's fallback error carries the key query-escaped. Both are cut down to what diagnoses a failure.
const (
	redactHeadHex = "4f2a99d0c1b2a3e4f5061728394a5b6c7d8e9f00112233445566778899aabbcc"
	redactBlobHex = "0e1d2c3b4a5968778695a4b3c2d1e0f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
)

func presignedCapErr() error {
	return &url.Error{Op: "Put", URL: "https://acct.r2.example/nowhere/ref/" + redactHeadHex +
		"?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=TESTKEYID%2F20261009%2Fauto%2Fs3%2Faws4_request" +
		"&X-Amz-Date=20261009T000000Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host&X-Amz-Signature=" + redactBlobHex,
		Err: errors.New("dial tcp: i/o timeout")}
}

func TestLogSafeStoreErrStripsCapQueriesAndHeadKeys(t *testing.T) {
	for _, c := range []struct {
		what string
		err  error
	}{
		{"cap PUT", presignedCapErr()},
		{"cap GET ref/" + redactHeadHex, errors.New("gateway /cap?op=write&ref=ref%2F" + redactHeadHex + ": 403 Forbidden")},
		{"cap GET ref/" + redactHeadHex, errors.New("cap GET ref/" + redactHeadHex + " -> 500")},
	} {
		got := logSafeStoreErr(c.what, c.err)
		for _, leak := range []string{redactHeadHex, "X-Amz-", "Signature", "TESTKEYID"} {
			if strings.Contains(got, leak) {
				t.Errorf("logSafeStoreErr(%q) kept %q: %s", c.what, leak, got)
			}
		}
	}
	if got := logSafeStoreErr("cap PUT", presignedCapErr()); !strings.Contains(got, "ref/<ref>") ||
		!strings.Contains(got, "dial tcp: i/o timeout") {
		t.Errorf("the redaction removed the diagnostic too: %s", got)
	}
	// A blob's content hash names bytes, not a profile: it stays, because it is what a failure is about.
	blob := errors.New("cap GET blob/" + redactBlobHex + " -> 500")
	if got := logSafeStoreErr("cap GET blob/"+redactBlobHex, blob); got != blob.Error() {
		t.Errorf("a blob error was rewritten: %q", got)
	}
}

// The retry line itself, end to end: capGet's label printed `cap GET ref/<64 hex>` raw on every retry, and the
// error after it the full presigned URL.
func TestRetryStoreNeverPrintsAHeadKeyOrACapQuery(t *testing.T) {
	old := s3RetryBase
	s3RetryBase = 0
	defer func() { s3RetryBase = old }()
	out := captureStderr(t, func() {
		_ = retryStore("cap GET ref/"+redactHeadHex, func() error { return presignedCapErr() })
	})
	if strings.Count(out, "retry cap GET ref/<ref> (") != 4 {
		t.Errorf("want 4 retry lines naming the redacted head key, got %q", out)
	}
	for _, leak := range []string{redactHeadHex, "X-Amz-Signature", "X-Amz-Credential"} {
		if strings.Contains(out, leak) {
			t.Errorf("the retry lines kept %q: %s", leak, out)
		}
	}
}
