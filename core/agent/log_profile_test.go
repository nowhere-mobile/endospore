package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// DIA-20260812-01. logProfile lifts the SCOPE out of the quotes so the reap's scrub can still redact the NAME
// while the scope survives for diagnosis. The safety property is therefore not "does it look right" but "is the
// name still inside quotes" -- because log_scrub only redacts quoted runs. While writing this change I briefly
// produced exactly that bug: two push lines were switched to %s while still passing the raw profile, which would
// have written the profile name UNQUOTED into roam.log on every seal and walked straight back into #39. These
// tests exist to make that failure impossible to reintroduce silently.

// scrub mirrors the reap's blanket redaction (nowhere_roamd.sh LOG_SCRUB_SED, rule 2): every quoted run becomes
// "<name>", ESCAPE-AWARE (NWP-20261008-09: %q escapes a `"` inside the name, and the old `"[^"]*"` stopped there).
// Deliberately the SAME shape as the shell, so a divergence here is a real divergence -- and
// TestScrubMirrorIsTheShellsProgram fails if the shell's program stops carrying it.
var scrub = regexp.MustCompile(`"(?:[^"\\]|\\.)*"`)

func scrubbed(s string) string { return scrub.ReplaceAllString(s, `"<name>"`) }

// The mirror is only worth anything while it IS the shell's rule. A missing roamd fails here rather than skipping:
// a test that skips when it cannot see what it guards passes having checked nothing.
func TestScrubMirrorIsTheShellsProgram(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Fatal(err)
	}
	var prog string
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "LOG_SCRUB_SED='") {
			prog = l
		}
	}
	const want = `/^\[restore\]/! s/"([^"\\]|\\.)*"/"<name>"/g`
	if !strings.Contains(prog, want) {
		t.Fatalf("roamd's LOG_SCRUB_SED no longer carries the quoted rule this file mirrors (%s) -- update both "+
			"together. Program: %q", want, prog)
	}
}

// NWP-20261008-09: names holding a quote, a backslash, an apostrophe or spaces leave no word behind. The old
// mirror left `ne"` of `ja"ne`, which is the shape the device's scrub left too.
func TestLogProfileHardNamesLeaveNoFragment(t *testing.T) {
	for _, name := range []string{`qz"vwx`, `"qzlead`, `qztrail\`, `qza\qzb qzc`, "O'Qzbrien qzx", "qzv #keys x"} {
		for _, scope := range []string{"", "#media", "#sys"} {
			got := logProfile(name + scope)
			after := scrubbed(got)
			for _, f := range strings.FieldsFunc(name, func(r rune) bool { return strings.ContainsRune(` "\'`, r) }) {
				if len(f) >= 3 && strings.Contains(after, f) {
					t.Errorf("%q of the name %q survives the scrub: logProfile=%q scrubbed=%q", f, name, got, after)
				}
			}
		}
	}
}

// #105 (DIA-20260816-15): logProfile now appends a short per-boot salted tag (" p:xxxx") OUTSIDE the quotes
// so two lines about the same profile can be correlated after the scrub -- the thing whose absence blocked a
// live P0 (task #5). These helpers let the assertions below keep testing the SAFETY properties (the name
// stays inside the quotes; the scope survives; an unknown suffix is never lifted out) without pinning the
// exact byte-for-byte output, which is what the tag necessarily changes.
var tagRe = regexp.MustCompile(` p:[0-9a-f]{4}`)

func detag(s string) string { return tagRe.ReplaceAllString(s, "") }

func TestLogProfileKeepsTheNameInsideQuotes(t *testing.T) {
	// The whole point: whatever logProfile emits, the name must not survive the scrub.
	for _, name := range []string{"odtest6", "alice", "a name with spaces", "vending"} {
		for _, scope := range []string{"", "#apps", "#de", "#media", "#sys", "#keys", "#wallet"} {
			got := logProfile(name + scope)
			if after := scrubbed(got); strings.Contains(after, name) {
				t.Errorf("name %q SURVIVES the scrub: logProfile=%q scrubbed=%q", name, got, after)
			}
		}
	}
}

func TestLogProfileExposesTheScope(t *testing.T) {
	cases := map[string]string{
		"odtest6#apps":   "#apps",
		"odtest6#de":     "#de",
		"odtest6#media":  "#media",
		"odtest6#sys":    "#sys",
		"odtest6#keys":   "#keys",
		"odtest6#wallet": "#wallet",
	}
	for in, want := range cases {
		after := scrubbed(logProfile(in))
		if !strings.Contains(after, want) {
			t.Errorf("%s: scope lost through the scrub -- got %q, want it to contain %q", in, after, want)
		}
		if detag(after) != `"<name>" `+want {
			t.Errorf("%s: scrubbed form is %q, expected %q once the #105 tag is removed", in, after, `"<name>" `+want)
		}
	}
}

func TestLogProfileUnscopedIsUnchangedBehaviour(t *testing.T) {
	if got := detag(logProfile("odtest6")); got != `"odtest6"` {
		t.Errorf("unscoped profile should be plain %%q once the #105 tag is removed, got %q", got)
	}
	if after := detag(scrubbed(logProfile("odtest6"))); after != `"<name>"` {
		t.Errorf("unscoped profile must scrub to \"<name>\", got %q", after)
	}
}

func TestLogProfileRefusesUnknownSuffixes(t *testing.T) {
	// A name that merely CONTAINS '#' must not have its tail lifted out of the quotes -- that would be a leak
	// dressed up as a scope. Only the closed allowlist is ever exposed.
	for _, in := range []string{"foo#secret", "foo#APPS", "foo#apps2", "foo#", "foo#media#secret"} {
		got := logProfile(in)
		after := scrubbed(got)
		if after != `"<name>"` {
			t.Errorf("%q: expected full redaction to \"<name>\", got %q (raw %q)", in, after, got)
		}
	}
}

func TestLogProfileLastHashSoNameKeepsItsOwn(t *testing.T) {
	// "alpha#beta#media" is a name containing '#', scoped to media. The name's own '#' must stay inside the
	// quotes, so LastIndex is required -- Index would split at the wrong '#' and push "beta#media" outside.
	//
	// The fixture deliberately avoids the words "name"/"my": the redaction placeholder is literally <name>, so a
	// fixture containing that substring makes the leak assertion below fire on the placeholder itself. The first
	// cut of this test did exactly that and failed for that reason, not because the code was wrong.
	got := logProfile("alpha#beta#media")
	if detag(got) != `"alpha#beta" #media` {
		t.Errorf("got %q, want %q once the #105 tag is removed", got, `"alpha#beta" #media`)
	}
	after := scrubbed(got)
	if strings.Contains(after, "alpha") || strings.Contains(after, "beta") {
		t.Errorf("name leaked past the scrub: %q", after)
	}
	if detag(after) != `"<name>" #media` {
		t.Errorf("scrubbed form is %q, want %q once the #105 tag is removed", after, `"<name>" #media`)
	}
}

// #105 (DIA-20260816-15). The tag exists to make two lines about the SAME profile correlatable after the
// scrub. These pin the properties that make it safe to have at all.

func TestProfileTagCorrelatesTheSameProfile(t *testing.T) {
	a := scrubbed(logProfile("odtest6"))
	b := scrubbed(logProfile("odtest6#media"))
	ta, tb := tagRe.FindString(a), tagRe.FindString(b)
	if ta == "" || tb == "" {
		t.Fatalf("no tag emitted: %q / %q", a, b)
	}
	if ta != tb {
		t.Errorf("same profile must tag identically across scopes: %q vs %q", ta, tb)
	}
	if c := tagRe.FindString(scrubbed(logProfile("someoneelse"))); c == ta {
		t.Errorf("different profiles must not share a tag (%q)", c)
	}
}

func TestProfileTagNeverLeaksTheName(t *testing.T) {
	for _, n := range []string{"odtest6", "alice", "a name with spaces", "vending"} {
		after := scrubbed(logProfile(n))
		if strings.Contains(after, n) {
			t.Errorf("name %q survives in %q", n, after)
		}
	}
}

func TestProfileTagWithheldForUnknownSuffixes(t *testing.T) {
	// An unknown suffix must redact to EXACTLY "<name>" -- no tag. Tagging would hash the whole string, so
	// foo#secret and foo#other would render different tags and a reader could tell the suffixes apart.
	for _, in := range []string{"foo#secret", "foo#APPS", "foo#apps2", "foo#", "foo#media#secret"} {
		if after := scrubbed(logProfile(in)); after != `"<name>"` {
			t.Errorf("%q: expected exactly \"<name>\" with no tag, got %q", in, after)
		}
	}
}
