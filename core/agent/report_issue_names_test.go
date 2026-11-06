package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261008-09 (docs/backlog.md, "Profile names survive the on-device log scrub"). The issue reporter is the
// path by which a name left in a log reaches the gateway, so it carries the same rules as log_scrub and is tested
// on the same shapes: every word of the planted name, never a count of placeholders. hardNames, assertNoFragment
// and escPath are in log_redact_test.go.

// qnSpelling is what nowhere_roamd.sh's qn writes between the quotes: only `\` and `"` escaped.
func qnSpelling(n string) string { return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(n) }

const issueDate = "Mon Oct  8 12:00:00 EDT 2026"

// issueNewLines are the shapes a name sits in since this slice: qn (roamd, mediad) and %q (the daemon, logProfile).
func issueNewLines(n string) []string {
	q, qn := fmt.Sprintf("%q", n), `"`+qnSpelling(n)+`"`
	return []string{
		`[roamd] OUT ` + qn + ` (user 11) +de +media`,
		`[roamd] IN ` + qn + ` #sys accounts staged (hold) ce=NO de=yes -> user 11`,
		`[roamd] GRANT ` + qn + ` #sys accounts placed ce=NO de=yes + reloaded -> user 11`,
		`[roamd] fido2 profile ` + qn + ` -> requesting the security key ` + issueDate,
		`[roamd] fido2-enroll OK for ` + qn + ` ` + issueDate,
		`[mediad] start ` + qn + ` -> user 11 ` + issueDate,
		`push: profile ` + q + ` p:1a2b #media`,
		`[logind] roam-in ` + q + ` -> user 12`,
		`[logind] roam-in ` + q + `: open "/data/x y": permission denied`,
		`[logind] export ` + q + `: sealed 2048 bytes (blob 0123456789ab)`,
		`[logind] export ` + q + `: Put "https://s3.example/b/ref/export/<name>": EOF`,
		`[logind] export-media ` + q + `: pinned manifest abc123 (3 files, 12 bytes)`,
		`[logind] pay-rent ` + q + `: pay-rent: cannot measure ` + q + ` p:1a2b -- refusing`,
		`[logind] pay-rent ` + q + `: paid through epoch 12 (1 token(s) spent)`,
	}
}

// issueOldLines are the shapes written before it: bare after the verb, bare and then raw-quoted fido2, the export
// key bare (and URL-escaped, quoted and not), a %q name before a second quoted token, and payRent's logProfile
// wrapped in a second %q.
func issueOldLines(n string) []string {
	q := fmt.Sprintf("%q", n)
	return []string{
		`[roamd] OUT ` + n + ` (user 11) +de +media`,
		`[roamd] OUT ` + n + ` ERR-NOCREDIT`,
		`[roamd] OUT ` + n + ` #keys sealed (3 pkg, 1 fresh, 0 dropped)`,
		`[roamd] IN ` + n + ` #sys accounts staged (hold) ce=NO de=yes -> user 11`,
		`[roamd] IN ` + n + ` NEEDKEY (2FA, no key asserted)`,
		`[roamd] IN ` + n + ` BLANK NET (the store could not be reached)`,
		`[roamd] GRANT ` + n + ` #sys accounts placed ce=yes de=yes + reloaded -> user 11`,
		`[mediad] start ` + n + ` -> user 11 ` + issueDate,
		`[roamd] fido2-enroll OK for "` + n + `" ` + issueDate,
		`[roamd] fido2 profile "` + n + `" -> adopting the NFC pre-asserted hmac ` + issueDate,
		`[roamd] fido2-enroll OK for ` + n + ` ` + issueDate,
		`[roamd] fido2 profile ` + n + ` -> requesting the security key ` + issueDate,
		`push: profile ` + q + ` p:1a2b #media`,
		`[logind] roam-in ` + q + `: open "/data/x y": permission denied`,
		`[logind] export ` + q + `: sealed 2048 bytes -> ref/export/` + n + ` (blob 0123456789ab)`,
		`  retry PUT ref/export/` + n + `#media (2/5): Put "https://s3.example/b/ref/export/` + escPath(n) + `%23media": EOF`,
		`  retry PUT ref/export/` + n + `#media (4/5): Connection closed by foreign host https://s3.example/b/ref/export/` + escPath(n) + `%23media. Retry again.`,
		`[logind] export ` + q + `: Put "https://s3.example/b/ref/export/` + escPath(n) + `": EOF`,
		`[logind] export-media ` + q + `: Put "https://s3.example/b/ref/export/` + escPath(n) + `%23media": EOF`,
		`[logind] export ` + q + `: cap-flush: gateway returned no write cap for ref/export/` + n,
		`[logind] export ` + q + `: cap-flush: the gateway listed a POINTER as already present (ref/export/` + n +
			`) -- only content-addressed blobs are ever skippable; skipping a ref would silently drop this write`,
		`[logind] pay-rent ` + q + `: pay-rent: cannot measure ` + fmt.Sprintf("%q", q+" p:1a2b") + ` -- refusing to renew a footprint it cannot see`,
		`[logind] pay-rent ` + q + `: pay-rent: cannot measure ` + fmt.Sprintf("%q", q) + ` -- refusing to renew a footprint it cannot see`,
	}
}

// prevScrub is the program log_scrub ran before this slice (nowhere_roamd.sh LOG_SCRUB_SED_PREV), applied at every
// reap and boot since DIA-20260807: a device holds what it left of the old lines, not the lines themselves.
var (
	prevScrubWord = []*regexp.Regexp{regexp.MustCompile(`(\[roamd\] (?:IN|OUT|GRANT) )[^ ]+`), regexp.MustCompile(`(\[mediad\] start )[^ ]+`)}
	prevScrubQuot = regexp.MustCompile(`"[^"]*"`)
)

func prevScrub(l string) string {
	for _, re := range prevScrubWord {
		l = re.ReplaceAllString(l, "${1}<name>")
	}
	if !strings.HasPrefix(l, "[restore]") {
		l = prevScrubQuot.ReplaceAllString(l, `"<name>"`)
	}
	return l
}

// issueNameLines: every shape, including the old ones after the previous scrub.
func issueNameLines(n string) []string {
	out := append([]string{}, issueNewLines(n)...)
	for _, l := range issueOldLines(n) {
		out = append(out, l, prevScrub(l))
	}
	return out
}

// scrubAllKept runs every line through scrubIssueLine and fails unless every one is KEPT: a line dropped by a drop
// keyword would pass the leak check having checked nothing.
func scrubAllKept(t *testing.T, what string, lines, secrets []string) []string {
	t.Helper()
	var got []string
	for _, ln := range lines {
		out, keep := scrubIssueLine(ln, secrets)
		if !keep {
			t.Errorf("%s: the line was DROPPED, so it proves nothing: %q", what, ln)
			continue
		}
		got = append(got, out)
	}
	return got
}

func TestIssueReportDropsEveryWordOfADepartedName(t *testing.T) {
	for _, n := range hardNames {
		lines := issueNameLines(n)
		for i, got := range scrubAllKept(t, "departed name "+n, lines, nameSpellings("currentuser")) {
			assertNoFragment(t, "departed name, line "+lines[i], n, got)
		}
	}
}

// The live name, through buildIssueReport itself: the literal pass is the only rule that reaches a [restore] line
// (the quoted rules spare them, because they quote file paths), so a name holding `"` or `\` was only redacted
// there once the pass knew its escaped spellings (nameSpellings). The second [restore] line proves the log reached
// the scrubber and was kept.
func TestIssueReportDropsEveryWordOfTheLiveName(t *testing.T) {
	for _, n := range hardNames {
		dir := t.TempDir()
		t.Setenv("NOWHERE_DIR", dir)
		log := `[restore] skip "files/` + qnSpelling(n) + `.txt": denied` + "\n" +
			`[restore] skip "net.thunderbird.android/databases/global.db": denied` + "\n"
		if err := os.WriteFile(filepath.Join(dir, "login.log"), []byte(log), 0o600); err != nil {
			t.Fatal(err)
		}
		rep := buildIssueReport(n, false, "", nil, nil)
		joined := strings.Join(rep.Logs["login.log"], "\n")
		if !strings.Contains(joined, `[restore] skip "files/`) || !strings.Contains(joined, "net.thunderbird.android") {
			t.Fatalf("%q: the [restore] lines did not reach the report, so it proves nothing: %q", n, joined)
		}
		body, err := json.Marshal(rep)
		if err != nil {
			t.Fatal(err)
		}
		assertNoFragment(t, "live name via buildIssueReport", n, string(body))
	}
}

// A live name that is also a word the structural rules anchor on must not open a hole for a DEPARTED name: the
// literal pass runs after the structural rules for exactly this reason, and this pins it.
func TestIssueReportAnchorWordLiveNamesKeepDepartedNamesOut(t *testing.T) {
	for _, live := range []string{"out", "grant", "roamd", "start", "mediad", "ref", "user", "blank", "export"} {
		for _, n := range hardNames {
			lines := issueNameLines(n)
			for i, got := range scrubAllKept(t, "live "+live, lines, nameSpellings(live)) {
				assertNoFragment(t, "live name "+live+", line "+lines[i], n, got)
			}
		}
	}
}

// The rules stay NARROW: [restore] file paths and the diagnostic text around a name still reach support.
func TestIssueReportNameRulesKeepTheDiagnostics(t *testing.T) {
	cases := map[string]string{
		`[restore] skip "net.thunderbird.android/databases/global.db": denied`:               "net.thunderbird.android",
		`[roamd] OUT "Qzv Wxk" (user 11) +de +media -- PARTIAL: apps=refused`:                "PARTIAL: apps=refused",
		`[roamd] OUT "Qzv Wxk" #keys sealed (3 pkg, 1 fresh, 0 dropped)`:                     "#keys sealed (3 pkg",
		`[roamd] IN "Qzv Wxk" #sys accounts staged (hold) ce=NO de=yes -> user 11`:           "#sys accounts staged (hold) ce=NO de=yes",
		`[roamd] GRANT "Qzv Wxk" #sys accounts placed ce=NO de=yes + reloaded -> user 11`:    "ce=NO de=yes + reloaded",
		`[roamd] GRANT checkin kicked for user 11 (android_id bootstrap)`:                    "kicked for user 11",
		`[roamd] GRANT -> 12 perms + 3 INTERNET default(s) (user 11)`:                        "12 perms + 3 INTERNET default(s)",
		`[roamd] GRANT (com.example.app) -> 2 perms + 1 INTERNET default(s) (user 11)`:       "2 perms + 1 INTERNET default(s)",
		`[roamd] #apps staged 3 pkg(s), 120 KiB, in 40ms (NWP-20261005-04)`:                  "#apps staged 3 pkg(s)",
		`[logind] export "Qzv Wxk": sealed 2048 bytes (blob 0123456789ab)`:                   "sealed 2048 bytes (blob",
		`[logind] pay-rent "Qzv Wxk": pay-rent: cannot measure "Qzv Wxk" p:1a2b -- refusing`: "p:1a2b -- refusing",
		`  retry PUT ref/export/Qzv Wxk (2/5): Put "https://s3.example/b/x": EOF`:            "(2/5): Put",
		`[logind] roam-in "Qzv Wxk": open "/data/x y": permission denied`:                    `: open "<name>": permission denied`,
		`[logind] export-media "Qzv Wxk": pinned manifest abc123 (3 files, 12 bytes)`:        "pinned manifest abc123 (3 files",
		`[roamd] seedssaid staged 0123ABCDEF.. user 11 (#210)`:                               "seedssaid staged <redacted>.. user 11",
	}
	for in, want := range cases {
		got, keep := scrubIssueLine(in, nil)
		if !keep || !strings.Contains(got, want) {
			t.Errorf("%q -> %q (keep %v): lost %q", in, got, keep, want)
		}
	}
	// ...and the ssaid seed prefix itself is gone: it is a passphrase verifier, not a name, and too short for the
	// hex rule, so only issueNameRules' rule 6 takes it out.
	if got, _ := scrubIssueLine(`[roamd] seedssaid staged 0123ABCDEF.. user 11 (#210)`, nil); strings.Contains(got, "0123ABCDEF") {
		t.Errorf("the ssaid seed prefix survives: %q", got)
	}
}
