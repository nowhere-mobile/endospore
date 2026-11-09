package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261106-19: the IDLE-TRACE arm prints only the chooser's trace vocabulary (idle_trace.go).

func TestIdleTraceKeepsTheChooserEvents(t *testing.T) {
	for _, ev := range []string{
		"screen on",
		"arm ms=900000",
		"probe split u=10 explicit=1 ctx=2",
		"abort skip u=10 secure=1 probe=1 match=1",
		"abort ok",
		"abort committed",
		"pushdoze play appid=10123 ok=1",
		"pushdoze-roam applied=2 dropped=0 live=1",
		"pushdoze-roam applied=2 dropped=0 live=1 tries=1",
		"pushdoze-sweep err user=11",
		"defer installs held=12",
		"defer latefire s=4",
		"installs cap reached",
		"fire late=3 screenon=0 live=1 locked=1",
		"cancel userpresent",
		"pushdoze other appid=10330 ok=1",
		"smsnotice sum=0 subst=0 pub=1 icon=1",
		"smsnotice sum=1 subst=-1",
	} {
		if got := idleTraceLine(ev + "\n"); got != ev {
			t.Errorf("idleTraceLine(%q) = %q, want it kept byte for byte", ev, got)
		}
	}
}

func TestIdleTraceDropsFreeText(t *testing.T) {
	for in, want := range map[string]string{
		"arm alice":             "arm ?",
		"screen ms=alice":       "screen ?",
		"alice on":              "trace-unknown",
		"arm ms=":               "arm ?",
		"arm ms=1x":             "arm ?",
		"arm alice=1":           "arm ?",
		"smsnotice subst=alice": "smsnotice ?",
		"":                      "",
		"OK\n":                  "",
	} {
		if got := idleTraceLine(in); got != want {
			t.Errorf("idleTraceLine(%q) = %q, want %q", in, got, want)
		}
	}
	// The cut comes before the check: byte 120 falls right after a complete `ok `, the tail is a name.
	head := "abort" + strings.Repeat(" ok", 38) + " "
	if len(head) != 120 {
		t.Fatalf("test setup: head is %d bytes, want 120", len(head))
	}
	if got := idleTraceLine(head + "alice"); got != strings.TrimSpace(head) || strings.Contains(got, "?") {
		t.Errorf("a line cut at 120 bytes = %q, want the head kept whole", got)
	}
	long := "arm ms=1 " + strings.Repeat("x", 191)
	if got := idleTraceLine(long); got != "arm ms=1 ?" {
		t.Errorf("a 200-byte line = %q, want %q", got, "arm ms=1 ?")
	}
}

func idleTraceLinesOf(out string) []string {
	var ls []string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "[idle] ") {
			ls = append(ls, l)
		}
	}
	return ls
}

func TestIdleTraceArmPrintsTheVocabulary(t *testing.T) {
	for _, c := range []struct{ req, prefix, leak string }{
		{"IDLE-TRACE\narm alice\n", "[idle] arm ? ", "alice"},
		{"IDLE-TRACE\nscreen on\n", "[idle] screen on ", ""},
	} {
		var got string
		out := captureStderr(t, func() { got = driveLogin(t, t.TempDir(), c.req) })
		if got != "OK" {
			t.Fatalf("%q: reply %q, want OK", c.req, got)
		}
		ls := idleTraceLinesOf(out)
		if len(ls) != 1 || !strings.HasPrefix(ls[0], c.prefix) {
			t.Fatalf("%q: idle lines %q, want one starting %q", c.req, ls, c.prefix)
		}
		if c.leak != "" && strings.Contains(out, c.leak) {
			t.Fatalf("%q: the output holds %q:\n%s", c.req, c.leak, out)
		}
	}
}

// idleTraceJavaStrings returns the content of every "..." literal in text.
func idleTraceJavaStrings(text string) []string {
	var out []string
	for i := 0; i < len(text); i++ {
		if text[i] != '"' {
			continue
		}
		var b strings.Builder
		j := i + 1
		for ; j < len(text) && text[j] != '"'; j++ {
			if text[j] == '\\' && j+1 < len(text) {
				j++
			}
			b.WriteByte(text[j])
		}
		out = append(out, b.String())
		i = j
	}
	return out
}

// idleTraceBalanced returns the text between the paren at src[open] and its match, skipping literals.
func idleTraceBalanced(src string, open int, lo, hi byte) string {
	depth := 0
	for i := open; i < len(src); i++ {
		switch src[i] {
		case '"', '\'':
			q := src[i]
			for i++; i < len(src) && src[i] != q; i++ {
				if src[i] == '\\' {
					i++
				}
			}
		case lo:
			depth++
		case hi:
			depth--
			if depth == 0 {
				return src[open+1 : i]
			}
		}
	}
	return src[open+1:]
}

// idleTraceCalls returns the argument text of every `name(` call in src, the definition excluded.
func idleTraceCalls(src, name string) []string {
	var out []string
	for from := 0; ; {
		k := strings.Index(src[from:], name+"(")
		if k < 0 {
			return out
		}
		k += from
		from = k + len(name)
		if k > 0 {
			p := src[k-1]
			if p == ' ' && strings.HasSuffix(src[:k], "void ") || p == '_' ||
				p >= 'a' && p <= 'z' || p >= 'A' && p <= 'Z' || p >= '0' && p <= '9' {
				continue
			}
		}
		out = append(out, idleTraceBalanced(src, k+len(name), '(', ')'))
	}
}

// idleTraceSplitArgs splits an argument list on top-level commas.
func idleTraceSplitArgs(args string) []string {
	var out []string
	depth, start := 0, 0
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case '"', '\'':
			q := args[i]
			for i++; i < len(args) && args[i] != q; i++ {
				if args[i] == '\\' {
					i++
				}
			}
		case '(', '{', '[':
			depth++
		case ')', '}', ']':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, args[start:i])
				start = i + 1
			}
		}
	}
	return append(out, args[start:])
}

func TestIdleTraceVocabularyCoversTheChooser(t *testing.T) {
	files, _ := filepath.Glob("../chooser/src/com/nowhere/chooser/*.java")
	if len(files) == 0 {
		t.Fatal("no chooser sources found under ../chooser/src/com/nowhere/chooser")
	}
	type lit struct{ file, text string }
	var lits []lit
	calls, verdicts, labels := 0, 0, 0
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(raw)
		base := filepath.Base(f)
		for _, a := range idleTraceCalls(src, "idleTrace") {
			calls++
			for _, s := range idleTraceJavaStrings(a) {
				lits = append(lits, lit{base, s})
			}
		}
		if base == "IdleLockGate.java" {
			for _, a := range idleTraceCalls(src, "new Verdict") {
				args := idleTraceSplitArgs(a)
				if len(args) < 4 {
					continue
				}
				if ss := idleTraceJavaStrings(args[3]); len(ss) > 0 {
					verdicts++
					for _, s := range ss {
						lits = append(lits, lit{base, s})
					}
				}
			}
		}
		if k := strings.Index(src, "String pushDozeLabel("); k >= 0 {
			body := idleTraceBalanced(src, k+strings.Index(src[k:], "{"), '{', '}')
			for _, l := range strings.Split(body, "\n") {
				if r := strings.Index(l, "return "); r >= 0 {
					for _, s := range idleTraceJavaStrings(l[r:]) {
						labels++
						lits = append(lits, lit{base, s})
					}
				}
			}
		}
	}
	if calls < 20 || verdicts < 5 || labels < 1 {
		t.Fatalf("the scan found %d idleTrace calls (want >=20), %d Verdict traces (want >=5), %d pushDozeLabel returns (want >=1)",
			calls, verdicts, labels)
	}
	for _, l := range lits {
		for _, tok := range strings.Fields(idleTraceFilter(l.text)) {
			if k, v, ok := strings.Cut(tok, "="); ok {
				if !idleTraceKeys[k] || (v != "" && !idleTraceInt(v)) {
					t.Errorf("%s: literal %q: %q is not a key=integer of the vocabulary", l.file, l.text, tok)
				}
				continue
			}
			if !idleTraceVerbs[tok] && !idleTraceWords[tok] {
				t.Errorf("%s: literal %q: token %q is in neither idleTraceVerbs nor idleTraceWords", l.file, l.text, tok)
			}
		}
	}
}
