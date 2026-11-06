package main

// NWP-20260907-15: a conf flag nothing exports is inert, and nothing in this tree noticed.
//
// NWP-20260907-13 documented NOWHERE_SEQ_GUARD in nowhere.conf.example and wired no export. The agent
// reads it with os.Getenv, so setting it in the conf would have changed nothing, measured nothing, and
// looked exactly like a guard that never fires -- the most expensive possible failure for a flag whose
// only purpose was measurement. It was fixed in NWP-20260907-14, an hour later, and only because the next
// step happened to be "turn it on".
//
// ⚠ NEITHER A TEST NOR A DOC COULD HAVE CAUGHT IT. Every agent test sets the environment variable
// directly, so it passes whether or not anything on a device would ever set it. The gap is between the
// CONF FILE and the PROCESS ENVIRONMENT, and until now nothing asserted across that boundary. The same
// shape produced multi-device.md's stale "roamd does not set NOWHERE_CARRY_ESSENTIAL" note.

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestEveryDocumentedConfFlagIsExportedByADaemon reads the flags nowhere.conf.example tells an operator
// they may set, and requires each to be exported by at least one system daemon. An operator who sets a
// flag we document is entitled to have it reach the process that reads it.
func TestEveryDocumentedConfFlagIsExportedByADaemon(t *testing.T) {
	root := filepath.Join("..", "vendor-common")
	confPath := filepath.Join(root, "etc", "nowhere.conf.example")
	conf, err := os.ReadFile(confPath)
	if err != nil {
		t.Skipf("cannot read %s (%v) -- this test needs the source tree", confPath, err)
	}

	// Both the live form (FLAG=value) and the commented example form (#FLAG=value) are a promise to the
	// operator: the file is a menu, and a commented line is how every optional flag is presented.
	// NWP-20260921-11: widened from NOWHERE_* to the *_URL family too. The narrow form did not cover
	// GATEWAY_URL, CATALOG_URL or INDEX_URL -- three documented keys whose export could have been
	// dropped with nothing noticing, which is the same gap this test exists for. STOREFRONT_URL is
	// named the same way as its siblings deliberately, so widening here is what keeps it covered.
	flagRe := regexp.MustCompile(`(?m)^#?\s*(NOWHERE_[A-Z0-9_]+|[A-Z][A-Z0-9_]*_URL)=`)
	seen := map[string]bool{}
	var flags []string
	for _, m := range flagRe.FindAllStringSubmatch(string(conf), -1) {
		if !seen[m[1]] {
			seen[m[1]] = true
			flags = append(flags, m[1])
		}
	}
	if len(flags) == 0 {
		t.Fatal("no NOWHERE_* flags found in nowhere.conf.example -- the test is reading the wrong file " +
			"or the wrong shape, so it would pass vacuously")
	}

	// Everything the device side could export from: the daemons, not the test-*.sh suites beside them
	// (NWP-20261024-06: a suite's mutation text satisfied the export parser below).
	scripts := daemonScripts(t)
	var daemons string
	for _, f := range scripts {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		daemons += string(b)
	}

	// NWP-20260921-11: collect the names a daemon actually exports, instead of substring-matching
	// "export <NAME>".
	//
	// ⚠⚠ THE SUBSTRING FORM ONLY EVER CHECKED THE FIRST NAME ON A LINE. `export CATALOG_URL INDEX_URL`
	// contains "export CATALOG_URL" but NOT "export INDEX_URL", so INDEX_URL -- which is exported, and
	// always was -- would have been reported as inert, while any key added to the tail of an existing
	// export line would be reported as broken no matter how correctly it was wired. A guard that cannot
	// distinguish "not exported" from "not first on its line" is the same class of defect as the one it
	// was written to catch, so it is fixed here rather than worked around by giving each key its own line.
	// ⚠ AND `export` IS NOT ALWAYS THE FIRST WORD. nowhere_login.sh guards one of them --
	// `[ -n "${NOWHERE_SYNC_INTERVAL:-}" ] && export NOWHERE_SYNC_INTERVAL` -- so an anchored `^export`
	// match reports a correctly-wired flag as inert. Match `export` anywhere in a NON-COMMENT line
	// instead; skipping comment lines is what keeps the original rule that a bare mention does not count.
	exportRe := regexp.MustCompile(`\bexport\s+((?:[A-Za-z_][A-Za-z0-9_]*(?:=\S*)?[ \t]*)+)`)
	nameRe := regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	exported := map[string]bool{}
	for _, ln := range strings.Split(daemons, "\n") {
		if strings.HasPrefix(strings.TrimSpace(ln), "#") {
			continue
		}
		for _, m := range exportRe.FindAllStringSubmatch(ln, -1) {
			for _, tok := range strings.Fields(m[1]) {
				if i := strings.IndexByte(tok, '='); i > 0 {
					tok = tok[:i] // `export FOO="${FOO:-0}"` -> FOO
				}
				if nameRe.MatchString(tok) {
					exported[tok] = true
				}
			}
		}
	}
	if len(exported) == 0 {
		t.Fatal("no exported names parsed from the daemon scripts -- the parser is wrong and every " +
			"assertion below would pass vacuously")
	}

	for _, f := range flags {
		// The flag reaches a process only if a daemon EXPORTS it. A bare mention in a comment does not
		// count, which is exactly the distinction that was missed.
		if !exported[f] {
			t.Errorf("%s is documented in nowhere.conf.example but no daemon in core/vendor-common/bin "+
				"exports it.\n"+
				"    Setting it on a device would therefore do NOTHING, silently. That is not a missing "+
				"feature, it is a promise to the operator that the file does not keep -- and it is how "+
				"NOWHERE_SEQ_GUARD shipped inert on 2026-09-07.\n"+
				"    Fix: add `export %s=\"${%s:-<default>}\"` to nowhere_roamd.sh (and nowhere_login.sh "+
				"if the daemon's own paths read it), beside NOWHERE_MULTIDEVICE.", f, f, f)
		}
	}
	t.Logf("checked %d documented flag(s) against %d daemon script(s)", len(flags), len(scripts))
}
