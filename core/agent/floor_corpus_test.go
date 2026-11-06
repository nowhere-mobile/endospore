package main

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Tests for the floor-corpus verb (NWP-20261119-24, h49 #5). test-floor-corpus.sh --mutate re-runs them against
// broken copies of floor_corpus.go.

func floorCorpusTWrite(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "list.txt")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func floorCorpusTRun(args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	rc := floorCorpusCLI(args, &out, &errb)
	return rc, out.String(), errb.String()
}

func floorCorpusTLastLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	return lines[len(lines)-1]
}

// floorCorpusTCount is the de-duplicated phrase count for n words, each starting with a lower-case letter.
func floorCorpusTCount(n int) int {
	k := n
	if k > floorCorpusGridK {
		k = floorCorpusGridK
	}
	mx := func(a, b int) int {
		if a > b {
			return a
		}
		return b
	}
	return 2 * (k*k*k*k + mx(0, n-k) + 4*mx(0, (n-2)-mx(0, k-2)))
}

func TestFloorCorpusListPrintsOnlyThePasses(t *testing.T) {
	list := floorCorpusTWrite(t, strings.Join([]string{
		"alice alice alice",            // refused: one word repeated
		"correct horse battery staple", // passes: 4 distinct words, 28 characters
		"red fox run",                  // refused: a 3-word phrase of 11 characters
		"",                             // skipped, not counted
		"tangerine-oboe-77\r",          // passes: 17 characters (the \r of a CRLF line is trimmed)
		"tangerine77",                  // refused: 11 characters
		"Mirror lantern quietly",       // passes: 3 words, 22 characters
	}, "\n")+"\n")
	rc, out, errb := floorCorpusTRun(list)
	if rc != 0 {
		t.Fatalf("rc = %d, stderr %q", rc, errb)
	}
	want := `{"p":"correct horse battery staple"}` + "\n" +
		`{"p":"tangerine-oboe-77"}` + "\n" +
		`{"p":"Mirror lantern quietly"}` + "\n"
	if out != want {
		t.Errorf("stdout = %q, want only the three passes in list order %q", out, want)
	}
	if got := floorCorpusTLastLine(errb); got != "6 tested, 3 passed" {
		t.Errorf("last stderr line = %q, want %q", got, "6 tested, 3 passed")
	}
	if strings.Contains(errb, "list:") {
		t.Errorf("stderr has a list: line without --words: %q", errb)
	}
}

func TestFloorCorpusWordsAreDeterministicAndBounded(t *testing.T) {
	src := []string{"w0", "w1", "w2", "W1", "w3", "", "w4", "w5", "w6", "w7", "w8", "w9", "w10", "w11", "w12", "w13"}
	var b strings.Builder
	for i, w := range src {
		if w == "" {
			b.WriteString("\n")
			continue
		}
		b.WriteString(w + " " + strconv.Itoa(1000-i) + "\n")
	}
	wl := floorCorpusTWrite(t, b.String())
	words, err := floorCorpusReadWords(wl, 12)
	if err != nil {
		t.Fatal(err)
	}
	wantWords := []string{"w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8", "w9", "w10", "w11"}
	if !reflect.DeepEqual(words, wantWords) {
		t.Fatalf("words = %q, want %q", words, wantWords)
	}

	// The literals pin the helper too: 162 (N = 3), 20020 (N = 12), 21900 (N = 200, the defaults).
	if floorCorpusTCount(3) != 162 || floorCorpusTCount(12) != 20020 || floorCorpusTCount(200) != 21900 {
		t.Fatalf("floorCorpusTCount is wrong: %d %d %d", floorCorpusTCount(3), floorCorpusTCount(12), floorCorpusTCount(200))
	}
	ph := floorCorpusPhrases(words)
	if len(ph) != 20020 {
		t.Errorf("12 words give %d phrases, want 20020", len(ph))
	}
	if len(ph) == 0 || ph[0] != "w0 w0 w0 w0" {
		t.Errorf("first phrase is not %q", "w0 w0 w0 w0")
	}
	have := map[string]int{}
	for _, p := range ph {
		have[p]++
	}
	for _, p := range []string{"w3 w3 w3 w3", "W3 W3 W3 W3", "w0 w0 w1 w2", "w9 w10 w11 w9", "W9 W10 W11 W9", "w11 w11 w11 w11"} {
		if have[p] == 0 {
			t.Errorf("phrase %q is missing", p)
		}
	}
	for p, n := range have {
		if n > 1 {
			t.Errorf("phrase %q appears %d times", p, n)
		}
	}
	if again := floorCorpusPhrases(words); !reflect.DeepEqual(ph, again) {
		t.Errorf("a second call returned a different slice")
	}
	if got := len(floorCorpusPhrases(words[:3])); got != 162 {
		t.Errorf("3 words give %d phrases, want 162", got)
	}

	var big strings.Builder
	for i := 0; i < 300; i++ {
		w := "w"
		for n := i; ; n /= 26 {
			w += string(rune('a' + n%26))
			if n < 26 {
				break
			}
		}
		big.WriteString(w + " 1\n")
	}
	bigPath := floorCorpusTWrite(t, big.String())
	top, err := floorCorpusReadWords(bigPath, floorCorpusTop)
	if err != nil {
		t.Fatal(err)
	}
	if len(top) != 200 {
		t.Fatalf("the default top read %d words, want 200", len(top))
	}
	if got := len(floorCorpusPhrases(top)); got != 21900 || got != floorCorpusTCount(200) {
		t.Errorf("the defaults give %d phrases, want 21900", got)
	}

	list := floorCorpusTWrite(t, "correct horse battery staple\n")
	rc1, out1, err1 := floorCorpusTRun(list, "--words", wl, "--top", "12")
	rc2, out2, err2 := floorCorpusTRun(list, "--words", wl, "--top", "12")
	if rc1 != 0 || rc2 != 0 {
		t.Fatalf("rc = %d / %d, stderr %q", rc1, rc2, err1)
	}
	if out1 != out2 || err1 != err2 {
		t.Errorf("two runs with the same input gave different output")
	}
	if !strings.Contains(err1, "words: 20020 tested, ") {
		t.Errorf("stderr = %q, want a words: 20020 tested line", err1)
	}
}

func TestFloorCorpusWordsGoThroughTheRule(t *testing.T) {
	wl := floorCorpusTWrite(t, "lantern 9\nmirror 8\nquietly 7\nharbour 6\nmeadow 5\n")
	list := floorCorpusTWrite(t, "correct horse battery staple\ntangerine77\n")
	rc, out, errb := floorCorpusTRun(list, "--words", wl)
	if rc != 0 {
		t.Fatalf("rc = %d, stderr %q", rc, errb)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	printed := map[string]bool{}
	for _, l := range lines {
		if !strings.HasPrefix(l, `{"p":"`) || !strings.HasSuffix(l, `"}`) {
			t.Fatalf("stdout line %q is not a {\"p\": ...} record", l)
		}
		p := strings.TrimSuffix(strings.TrimPrefix(l, `{"p":"`), `"}`)
		if ok, _ := passphraseStrong("", p); !ok {
			t.Errorf("printed %q, which the shipped rule refuses", p)
		}
		printed[p] = true
	}
	for _, p := range []string{"lantern lantern lantern lantern", "Lantern Lantern Lantern Lantern"} {
		if printed[p] {
			t.Errorf("printed %q: one word repeated must be refused", p)
		}
	}
	if !printed["lantern mirror quietly harbour"] || !printed["Lantern Mirror Quietly Harbour"] {
		t.Errorf("a grid phrase that passes the rule is not printed")
	}
	var wPassed int
	for _, l := range strings.Split(errb, "\n") {
		if strings.HasPrefix(l, "words: ") {
			f := strings.Fields(l)
			wPassed, _ = strconv.Atoi(f[3])
		}
	}
	if wPassed == 0 || wPassed != len(lines)-1 {
		t.Errorf("stderr words: passed = %d, want %d (stdout lines less the one list pass); stderr %q", wPassed, len(lines)-1, errb)
	}
	if got := floorCorpusTLastLine(errb); got != strconv.Itoa(2+floorCorpusTCount(5))+" tested, "+strconv.Itoa(len(lines))+" passed" {
		t.Errorf("last stderr line = %q", got)
	}
}

func TestFloorCorpusUsage(t *testing.T) {
	list := floorCorpusTWrite(t, "correct horse battery staple\n")
	for _, c := range []struct {
		rc   int
		args []string
	}{
		{2, nil},
		{2, []string{list, "--words"}},
		{2, []string{list, "--words", list, "--top", "0"}},
		{2, []string{list, "--words", list, "--top", "x"}},
		{2, []string{list, "--top", "5"}},
		{2, []string{list, list}},
		{1, []string{filepath.Join(t.TempDir(), "absent.txt")}},
		{1, []string{list, "--words", filepath.Join(t.TempDir(), "absent.txt")}},
	} {
		rc, out, errb := floorCorpusTRun(c.args...)
		if rc != c.rc || out != "" || errb == "" {
			t.Errorf("args %q: rc = %d stdout %q stderr %q, want rc %d, no stdout and a reason", c.args, rc, out, errb, c.rc)
		}
	}
}

// TestFloorCorpusCallsTheShippedRule is the source pin: floor_corpus.go calls passphraseStrong once, with an empty
// profile name, and holds no rule of its own.
func TestFloorCorpusCallsTheShippedRule(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "floor_corpus.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	forbidden := map[string]bool{
		"floorMinChars": true, "floorMinWords": true, "commonPasswords": true, "isKeyboardWalk": true,
		"walkWindow": true, "repeatsAUnit": true, "allSameRune": true, "distinctCount": true,
		"floorCheckCLI": true, "floorEnforced": true,
	}
	var funcs []string
	ast.Inspect(f, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.CallExpr:
			if id, ok := x.Fun.(*ast.Ident); ok && id.Name == "passphraseStrong" {
				calls++
				if lit, ok := x.Args[0].(*ast.BasicLit); !ok || lit.Value != `""` {
					t.Errorf("passphraseStrong's profile name is not the empty literal")
				}
			}
		case *ast.Ident:
			if forbidden[x.Name] {
				t.Errorf("floor_corpus.go uses %s: a piece of the rule outside passphraseStrong", x.Name)
			}
		case *ast.BasicLit:
			if x.Kind == token.STRING {
				for _, r := range []string{"too short", "different words", "repetitive"} {
					if strings.Contains(x.Value, r) {
						t.Errorf("floor_corpus.go holds a reason of the rule: %s", x.Value)
					}
				}
			}
		case *ast.FuncDecl:
			funcs = append(funcs, x.Name.Name)
		}
		return true
	})
	if calls != 1 {
		t.Errorf("floor_corpus.go calls passphraseStrong %d times, want exactly 1", calls)
	}
	sort.Strings(funcs)
	want := []string{"floorCorpusCLI", "floorCorpusCheck", "floorCorpusEmit", "floorCorpusPhrases", "floorCorpusReadWords"}
	if !reflect.DeepEqual(funcs, want) {
		t.Errorf("floor_corpus.go funcs = %q, want %q", funcs, want)
	}
	m, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(m), "case \"floor-corpus\":") ||
		!strings.Contains(string(m), "os.Exit(floorCorpusCLI(os.Args[2:], os.Stdout, os.Stderr))") {
		t.Errorf("main.go does not dispatch floor-corpus to floorCorpusCLI")
	}
}
