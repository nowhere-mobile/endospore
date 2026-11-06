package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261005-18 (the ownership P0): the gate's shield glyph is public by design, and it used to open the owner
// ENROL form whenever no owner secret existed -- so whoever tapped it first became the phone's owner. It must open
// the verify screen only, and verify must refuse when no secret was ever set. Pinned from the chooser source: the
// chooser has no Java test surface, and each of these is one line that would silently reopen the P0.
func TestShieldOpensVerifyOnly(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "ChooserActivity.java"))
	if err != nil {
		t.Fatalf("ChooserActivity.java must be readable from core/agent: %v", err)
	}
	src := string(b)
	body := func(sig string) string {
		i := strings.Index(src, sig)
		if i < 0 {
			t.Fatalf("%q not found -- this test is stale, not the code", sig)
		}
		j := strings.Index(src[i:], "\n    }\n")
		if j < 0 {
			t.Fatalf("no end for %q", sig)
		}
		var keep []string
		for _, l := range strings.Split(src[i:i+j], "\n") {
			if s := strings.TrimSpace(l); !strings.HasPrefix(s, "//") && !strings.HasPrefix(s, "*") && !strings.HasPrefix(s, "/**") {
				keep = append(keep, l)
			}
		}
		return strings.Join(keep, "\n")
	}
	open := body("private void openOwnerMode() {")
	if !strings.Contains(open, "buildOwnerVerifyScreen()") {
		t.Fatal("openOwnerMode no longer opens the verify screen (control)")
	}
	if strings.Contains(open, "buildOwnerEnrollScreen") || strings.Contains(open, "ownerSecretSet") {
		t.Fatal("openOwnerMode can reach the enrol form -- the public shield would hand ownership to the first tap")
	}
	verify := body("private int verifyOwner(String pass) {")
	if !strings.Contains(verify, "if (!ownerSecretSet()) return -1;") {
		t.Fatal("verifyOwner does not refuse when no owner secret exists")
	}
	if strings.Contains(src, `cancel.setText("Not now")`) {
		t.Fatal(`the optional enrol form's "Not now" is back -- the only enrol form is the required one`)
	}
}
