package main

// NWP-20260907-11: no refusal message anywhere may hand the reader an errand, or name one cause as fact.
//
// Chester rejected "If another device is signed in to this profile, sign out there and try again" on
// 2026-09-07. Three reasons, all of which survived review: it makes OUR concurrency race the user's
// errand; it names one cause for a verdict with several (any local keyslot change moves the head too);
// and it asserts a product claim about multi-device inside an error string.
//
// ⚠ IT WAS IN FIVE PLACES AND EACH ROUND OF FIXING FOUND MORE. Two were fixed first, then reviewing that
// fix found two more, and then a DEVICE LOG found the fifth -- the agent's own diagnostic line, missed
// because the earlier passes were grepping the chooser. That is exactly the shape a test exists to stop,
// so this walks the source rather than trusting anyone to grep it again.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// forbidden is what may not appear in any user- or ticket-facing refusal text. Each entry is a phrase
// that either hands the reader an errand or asserts a single cause.
var forbidden = []string{
	"sign out there",
	"sign out of the other device",
	"That is another device signed into this",
}

// TestNoRefusalMessageAsksTheReaderToActOnAnotherDevice walks the agent and chooser sources and fails on
// any forbidden phrase outside a comment. Comments are exempt on purpose: the fixes deliberately QUOTE the
// old wording so the next reader learns why it went, and a test that forbade the quotes would delete the
// explanation along with the defect.
func TestNoRefusalMessageAsksTheReaderToActOnAnotherDevice(t *testing.T) {
	roots := []string{".", filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser")}
	checked := 0
	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			t.Skipf("cannot read %s (%v) -- this test needs the source tree", root, err)
		}
		for _, e := range entries {
			n := e.Name()
			if e.IsDir() || strings.HasSuffix(n, "_test.go") {
				continue
			}
			if !strings.HasSuffix(n, ".go") && !strings.HasSuffix(n, ".java") {
				continue
			}
			b, err := os.ReadFile(filepath.Join(root, n))
			if err != nil {
				t.Fatalf("read %s: %v", n, err)
			}
			checked++
			for i, line := range strings.Split(string(b), "\n") {
				trimmed := strings.TrimSpace(line)
				// Skip comments: the corrections quote the old wording deliberately.
				if strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "*") ||
					strings.HasPrefix(trimmed, "/*") {
					continue
				}
				for _, bad := range forbidden {
					if strings.Contains(line, bad) {
						t.Errorf("%s:%d contains %q outside a comment.\n"+
							"    A refusal message may state what is true and say it usually clears. It may "+
							"NOT tell the reader to act on another handset, and it may NOT name one cause "+
							"as fact -- any local keyslot change (a key enrolled or revoked, a PIN set, a "+
							"passphrase rotated) moves the head too. Proven on lynx 2026-09-07, twice.",
							filepath.Join(root, n), i+1, bad)
					}
				}
			}
		}
	}
	if checked == 0 {
		t.Fatal("no source files checked -- the test would pass vacuously")
	}
	t.Logf("checked %d source files", checked)
}
