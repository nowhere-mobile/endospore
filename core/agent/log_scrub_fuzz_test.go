package main

import (
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261008-09 (docs/backlog.md, "Profile names survive the on-device log scrub"). test-log-name-scrub.sh holds
// log_scrub's program to hand-picked names, and every review of it found a name none of them was: a non-ASCII initial
// after a quote, a quote before a space, four quotes in a row, a name that holds a rule's own anchor text. This test
// runs the shell's OWN program (LOG_SCRUB_SED, read from nowhere_roamd.sh) under sed on names GENERATED from the pieces
// those findings were made of, in every shape a device holds -- the lines written today, the lines older builds wrote,
// and those lines as the previous program (LOG_SCRUB_SED_PREV) left them, since every reap and boot ran it over them --
// and holds issueNameRules, the issue reporter's mirror, to the same output line for line.
//
// What it requires, per line: no word of the name survives (bar the accepted bound below); a second pass changes
// nothing; a line written today changes in its quoted tokens and nowhere else; an old line of an ordinary name keeps
// its diagnostics; and the Go mirror gives exactly sed's output. The accepted bound, as nowhere_roamd.sh states it:
// an OLD bare line whose name opens with a closed quoted token keeps the words after it. It is exempt from the leak
// check only, so the fixed point still pins the order of rules 3 and 4, which only such names show.

var (
	fuzzWords = []string{"qza", "qzb", "qzc", "qzd", "Éqze", "Жqzf", "李qzg", "_qzh", "@qzi", "(qzj", ".qzk", "-qzl", "1qzm"}
	fuzzSeps  = []string{" ", " ", `"`, `"`, `\`, "'", "#", " #", " -> user ", " (user ", " ERR-", " BLANK", " NEEDKEY",
		": ", " (", ")", "<name>", `"<name>"`, "<", "ref/export/", " (blob ab)", ": sealed 1 bytes -> ref/export/",
		" (1/2)", " p:1a2b", `\"`, `""`, "&", "?", "%2F", "%22", " -- refusing to renew a footprint it cannot see", "→", "/",
		") -- only content-", ": cap-flush: gateway returned no write cap for ref/export/"}
	fuzzDate = "Mon Oct  8 12:00:00 EDT 2026"

	reFuzzBareVerb = regexp.MustCompile(`^\[(roamd\] (IN|OUT|GRANT)|mediad\] start) `)
	// a name that holds a heal's own anchor text can steer that heal on its own line today: diagnostics, never the name
	reFuzzAnchorish = regexp.MustCompile(`<name>|: sealed|ref/export/| \([0-9]+/[0-9]+\)| -- refusing| -> (adopting|NFC-first|requesting)| (Mon|Tue|Wed|Thu|Fri|Sat|Sun) |cap-flush|-- only content-`)
	reFuzzPlain     = regexp.MustCompile(`^[^"\\#():<>/&?%]*$`)
	reFuzzQuoted    = regexp.MustCompile(`"(?:[^"\\]|\\.)*"`)
)

// fuzzNames: every hard name, a product of separators around three words with a lead and a tail, random names from
// the pieces, and ordinary multi-word names. Seeded, so a failure reproduces.
func fuzzNames() []string {
	seen := map[string]bool{}
	var out []string
	add := func(n string) {
		if !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	for _, n := range hardNames {
		add(n)
	}
	seps := []string{" ", `"`, ` "`, `" `, `\`, " #", " -> user ", " (user ", `\"`, "'", ": "}
	for _, s1 := range seps {
		for _, s2 := range seps {
			for _, lead := range []string{"", `"`, "É", "_"} {
				for _, tail := range []string{"", `"`, "qzd", `"qzd`, `" qzd`, `\`} {
					add(lead + "qza" + s1 + "qzb" + s2 + "qzc" + tail)
				}
			}
		}
	}
	r := rand.New(rand.NewSource(20261008))
	for i := 0; i < 1500; i++ {
		var b strings.Builder
		if r.Intn(10) < 3 {
			b.WriteString([]string{`"`, `\`, "<", `"<`, " ", "'", "#"}[r.Intn(7)])
		}
		b.WriteString(fuzzWords[r.Intn(len(fuzzWords))])
		for k := r.Intn(4); k > 0; k-- {
			b.WriteString(fuzzSeps[r.Intn(len(fuzzSeps))])
			b.WriteString(fuzzWords[r.Intn(len(fuzzWords))])
		}
		if r.Intn(10) < 3 {
			b.WriteString([]string{`"`, `\`, "#", " ", "'", ")"}[r.Intn(6)])
		}
		add(b.String())
	}
	for i := 0; i < 300; i++ {
		var parts []string
		for k := 1 + r.Intn(4); k > 0; k-- {
			parts = append(parts, fuzzWords[r.Intn(8)])
		}
		add(strings.Join(parts, []string{" ", "'", "-", "."}[r.Intn(4)]))
	}
	return out
}

// fuzzNewLines: the lines written today -- qn for roamd and mediad, %q and logProfile for the daemon, redactNameIn
// and logSafeWhat for its errors. qn and %q spell these names the same.
func fuzzNewLines(n string) []string {
	q := fmt.Sprintf("%q", n)
	var out []string
	for _, vt := range [][2]string{{"OUT", "#keys sealed (3 pkg, 1 fresh, 0 dropped)"}, {"OUT", "(user 11) +de +media"},
		{"OUT", "ERR-NOCREDIT"}, {"IN", "NEEDKEY (2FA, no key asserted)"}, {"IN", "-> user 11 (+de +media)"},
		{"IN", "BLANK NET (the store could not be reached)"}, {"IN", "#sys accounts staged (hold) ce=NO de=yes -> user 11"},
		{"GRANT", "#sys accounts placed ce=NO de=yes + reloaded -> user 11"},
		{"GRANT", "#sys placed a ROW-EMPTY accounts db -- NOT marking .had_account (NWP-20260903-14)"},
		{"IN", "#keys restored (2 bundle(s))"}, {"OUT", "ERR-REFUSED PARTIAL:apps -- a seal guard refused"}} {
		out = append(out, "[roamd] "+vt[0]+" "+q+" "+vt[1]+" "+fuzzDate)
	}
	return append(out,
		"[roamd] fido2-enroll OK for "+q+" "+fuzzDate,
		"[roamd] fido2 profile "+q+" -> requesting the security key "+fuzzDate,
		"[mediad] start "+q+" -> user 11 "+fuzzDate,
		"push: profile "+q+" p:1a2b #media",
		"[logind] roam-in "+q+" -> user 12",
		`[logind] roam-in `+q+`: open "/data/x y": permission denied`,
		"[logind] export "+q+": sealed 2048 bytes (7-day expiry applied)",
		`[logind] export `+q+`: Put "https://s3.example/b/ref/<ref>": EOF`,
		"[logind] export-media "+q+": pinned manifest (3 files, 12 bytes, 7-day expiry applied)",
		"[logind] pay-rent "+q+": pay-rent: cannot measure "+q+" p:1a2b -- refusing to renew a footprint it cannot see",
		"[logind] pay-rent "+q+": paid through epoch 12 (1 token(s) spent)",
		"mediad: serving 3 files for "+q+" p:1a2b",
		`  retry PUT ref/export/<name> (2/5): Put "https://s3.example/b/ref/export/<name>": EOF`)
}

// fuzzOldLines: the lines older builds wrote -- bare after the verb, bare and then raw-quoted fido2, the export key
// bare (success, retry, URL and cap-flush errors, minio's closed-connection error), a %q name before a second quoted
// token, and payRent's logProfile under a second %q.
func fuzzOldLines(n string) []string {
	q := fmt.Sprintf("%q", n)
	var out []string
	for _, vt := range [][2]string{{"OUT", "#keys sealed (3 pkg, 1 fresh, 0 dropped)"}, {"OUT", "(user 11) +de +media"},
		{"OUT", "ERR-NOCREDIT"}, {"IN", "NEEDKEY (2FA, no key asserted)"}, {"IN", "-> user 11 (+de +media)"},
		{"IN", "BLANK NET"}, {"IN", "#sys accounts staged (hold) ce=NO de=yes -> user 11"},
		{"GRANT", "#sys accounts placed ce=NO de=yes + reloaded -> user 11"}} {
		out = append(out, "[roamd] "+vt[0]+" "+n+" "+vt[1]+" "+fuzzDate)
	}
	esc := escPath(n)
	return append(out,
		"[mediad] start "+n+" -> user 11 "+fuzzDate,
		`[roamd] fido2-enroll OK for "`+n+`" `+fuzzDate,
		`[roamd] fido2 profile "`+n+`" -> requesting the security key `+fuzzDate,
		"[roamd] fido2-enroll OK for "+n+" "+fuzzDate,
		"[roamd] fido2 profile "+n+" -> adopting the NFC pre-asserted hmac "+fuzzDate,
		"push: profile "+q+" p:1a2b #media",
		"[logind] roam-in "+q+" -> user 12",
		`[logind] roam-in `+q+`: open "/data/x y": permission denied`,
		"[logind] export "+q+": sealed 2048 bytes -> ref/export/"+n+" (blob 0123456789ab)",
		`  retry PUT ref/export/`+n+`#media (2/5): Put "https://s3.example/b/ref/export/`+esc+`%23media": EOF`,
		`  retry PUT ref/export/`+n+` (3/5): Put "https://s3.example/b/ref/export/`+esc+`": EOF`,
		`  retry PUT ref/export/`+n+`#media (4/5): Connection closed by foreign host https://s3.example/b/ref/export/`+esc+`%23media. Retry again.`,
		`[logind] export `+q+`: Put "https://s3.example/b/ref/export/`+esc+`": EOF`,
		`[logind] export `+q+`: Connection closed by foreign host https://s3.example/b/ref/export/`+esc+`. Retry again.`,
		`[logind] export-media `+q+`: Put "https://s3.example/b/ref/export/`+esc+`%23media": EOF`,
		"[logind] export "+q+": cap-flush: gateway returned no write cap for ref/export/"+n,
		"[logind] export-media "+q+": cap-flush: gateway returned no write cap for ref/export/"+n+"#media",
		"[logind] export "+q+": cap-flush: the gateway listed a POINTER as already present (ref/export/"+n+
			") -- only content-addressed blobs are ever skippable; skipping a ref would silently drop this write",
		"[logind] pay-rent "+q+": pay-rent: cannot measure "+fmt.Sprintf("%q", q+" p:1a2b")+" -- refusing to renew a footprint it cannot see",
		"[logind] pay-rent "+q+": pay-rent: cannot measure "+fmt.Sprintf("%q", q)+" -- refusing to renew a footprint it cannot see")
}

// fuzzOldDiag: what the heals must leave of an ORDINARY name's old lines (no quote, backslash or anchor text in it).
var fuzzOldDiag = [][2]string{{"[roamd] OUT", "(user 11) +de +media"}, {"[roamd] OUT", "ERR-NOCREDIT"},
	{"[roamd] OUT", "#keys sealed (3 pkg"}, {"[roamd] IN", "NEEDKEY (2FA"}, {"[roamd] IN", "BLANK NET"},
	{"[roamd] IN", "-> user 11 (+de +media)"}, {"[roamd] GRANT", "#sys accounts placed ce=NO de=yes + reloaded"},
	{"[mediad] start", "-> user 11"}, {"[roamd] fido2 profile", "-> requesting the security key"},
	{"[roamd] fido2 profile", "-> adopting the NFC"}, {"[logind] export", "sealed 2048 bytes -> ref/export/"},
	{"  retry", "(2/5): Put"}, {"  retry", "(3/5): Put"}, {"  retry", "(4/5): Connection closed"},
	{"[logind] export", ": Connection closed by foreign host"}, {"[logind] export", "cap-flush: gateway returned no write cap"},
	{"[logind] export", "cap-flush: the gateway listed a POINTER"}, {"[logind] pay-rent", "-- refusing to renew"},
	{"[logind] roam-in", ": permission denied"}, {"[logind] roam-in", "-> user 12"}, {"push: profile", "p:1a2b #media"}}

func roamdScrubProgram(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, name+"='") && strings.HasSuffix(l, "'") {
			got = append(got, l[len(name)+2:len(l)-1])
		}
	}
	if len(got) != 1 || got[0] == "" {
		t.Fatalf("want exactly one one-line %s='...' in nowhere_roamd.sh, found %d", name, len(got))
	}
	return got[0]
}

// runSed runs a sed program over lines, one per line, through a FILE (as -f): what log_scrub does with -E "$_p".
func runSed(t *testing.T, sed, prog string, lines []string) []string {
	t.Helper()
	pf := filepath.Join(t.TempDir(), "prog.sed")
	if err := os.WriteFile(pf, []byte(prog+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(sed, "-E", "-f", pf)
	cmd.Stdin = strings.NewReader(strings.Join(lines, "\n") + "\n")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("sed: %v", err)
	}
	got := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(got) != len(lines) {
		t.Fatalf("sed returned %d lines for %d", len(got), len(lines))
	}
	return got
}

type fuzzRow struct{ kind, name, line string }

func TestLogScrubHoldsOnGeneratedNames(t *testing.T) {
	// No sed means nothing checked: fail, never skip (see TestScrubMirrorIsTheShellsProgram).
	sed, err := exec.LookPath("sed")
	if err != nil {
		t.Fatal("sed is not on PATH: this test runs log_scrub's own program and cannot check anything without it")
	}
	prog := roamdScrubProgram(t, "LOG_SCRUB_SED")
	prev := roamdScrubProgram(t, "LOG_SCRUB_SED_PREV")

	names := fuzzNames()
	var rows []fuzzRow
	var olds []fuzzRow
	for _, n := range names {
		for _, l := range fuzzNewLines(n) {
			rows = append(rows, fuzzRow{"new", n, l})
		}
		for _, l := range fuzzOldLines(n) {
			olds = append(olds, fuzzRow{"old", n, l})
		}
	}
	rows = append(rows, olds...)
	oldLines := make([]string, len(olds))
	for i, r := range olds {
		oldLines[i] = r.line
	}
	for i, p := range runSed(t, sed, prev, oldLines) {
		rows = append(rows, fuzzRow{"prev", olds[i].name, p})
	}
	lines := make([]string, len(rows))
	for i, r := range rows {
		lines[i] = r.line
	}
	keep := []string{`[restore] skip "net.thunderbird.android/databases/global.db": denied`,
		`[roamd] GRANT -> 12 perms + 3 INTERNET default(s) (user 11)`,
		`[roamd] GRANT (com.example.app) -> 2 perms + 1 INTERNET default(s) (user 11)`,
		`[roamd] #apps staged 3 pkg(s), 120 KiB, in 40ms (NWP-20261005-04)`,
		`[roamd] seedssaid staged 0123ABCDEF.. user 11 (#210)`}
	must := []string{"net.thunderbird.android/databases/global.db", "12 perms + 3 INTERNET default(s) (user 11)",
		"2 perms + 1 INTERNET default(s) (user 11)", "#apps staged 3 pkg(s)", "seedssaid staged <redacted>.. user 11"}

	p1 := runSed(t, sed, prog, append(lines, keep...))
	p2 := runSed(t, sed, prog, p1)

	// A POSITIVE control: the previous program, run the same way, must leak on these rows -- or a leak check that
	// cannot see a leak would pass here having checked nothing.
	leaks := 0
	for _, l := range runSed(t, sed, prev, lines) {
		if strings.Contains(strings.ToLower(l), "qz") {
			leaks++
		}
	}
	if leaks < 1000 {
		t.Fatalf("the previous program leaks on only %d of %d rows -- the generated lines no longer carry the shapes it missed", leaks, len(lines))
	}

	fails := map[string][]string{}
	fail := func(kind string, r fuzzRow, got string) {
		if len(fails[kind]) < 4 {
			fails[kind] = append(fails[kind], fmt.Sprintf("name %q (%s)\n      in:  %s\n      out: %s", r.name, r.kind, r.line, got))
		} else {
			fails[kind] = append(fails[kind], "")
		}
	}
	for i, r := range rows {
		a, b := p1[i], p2[i]
		boundA := r.kind == "old" && reFuzzBareVerb.MatchString(r.line) && strings.HasPrefix(r.name, `"`) && strings.Contains(r.name[1:], `"`)
		if !boundA && strings.Contains(strings.ToLower(a), "qz") {
			fail("a word of the name survives", r, a)
		}
		if a != b {
			fail("a second pass changes the line (not a fixed point)", r, a+"\n      2nd: "+b)
		}
		if r.kind == "new" && !reFuzzAnchorish.MatchString(r.name) {
			if want := reFuzzQuoted.ReplaceAllString(r.line, `"<name>"`); a != want {
				fail("a line written today changed outside its quoted tokens", r, a+"\n      want: "+want)
			}
		}
		if r.kind == "old" && reFuzzPlain.MatchString(r.name) {
			for _, d := range fuzzOldDiag {
				if strings.HasPrefix(r.line, d[0]) && strings.Contains(r.line, d[1]) && !strings.Contains(a, d[1]) {
					fail("an old line of an ordinary name lost its diagnostics", r, a)
				}
			}
		}
		if g := applyIssueNameRules(r.line); g != a {
			fail("the issue reporter's mirror differs from the shell", r, a+"\n      go:  "+g)
		}
	}
	kept := strings.Join(p2[len(lines):], "\n")
	for _, m := range must {
		if !strings.Contains(kept, m) {
			t.Errorf("after two passes the program ate %q:\n%s", m, kept)
		}
	}
	if strings.Contains(strings.Join(p1[len(lines):], "\n"), "0123ABCDEF") {
		t.Error("the ssaid seed prefix survives")
	}
	for kind, ex := range fails {
		var shown []string
		for _, e := range ex {
			if e != "" {
				shown = append(shown, e)
			}
		}
		t.Errorf("%s: %d line(s), e.g.\n    %s", kind, len(ex), strings.Join(shown, "\n    "))
	}
	if len(rows) < 100000 {
		t.Fatalf("only %d rows generated -- the generator no longer produces what this test was sized for", len(rows))
	}
	t.Logf("%d names, %d lines", len(names), len(rows))
}
