package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261025-11: the never-called SEED-MEDIA verb was root-acting surface any admitted caller could reach
// (DECIDED 2026-10-18, docs/product-decisions.md). It is deleted; the verb must now meet the legacy-login
// fallthrough like any unknown first line.
func TestSeedMediaVerbIsGone(t *testing.T) {
	arms := parseLoginArms(t)
	if !arms.has("FIDO2-STATUS") {
		t.Fatal("control: parseLoginArms lost FIDO2-STATUS, so the SEED-MEDIA check below proves nothing")
	}
	if arms.has("SEED-MEDIA") {
		t.Error(`handleLogin still dispatches "SEED-MEDIA"`)
	}

	files, err := filepath.Glob(filepath.Join(agentDir(), "*.go"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no agent sources found: %v", err)
	}
	sawControl := false
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		if filepath.Base(f) == "main.go" && strings.Contains(src, `"FIDO2-STATUS"`) {
			sawControl = true
		}
		if strings.Contains(src, "handleSeedMedia") || strings.Contains(src, `"SEED-MEDIA"`) {
			t.Errorf("%s still names handleSeedMedia or \"SEED-MEDIA\"", filepath.Base(f))
		}
	}
	if !sawControl {
		t.Error(`control: the scan did not read main.go and find "FIDO2-STATUS"`)
	}

	dest := t.TempDir()
	writeMarker(t, dest, "alice\npass\n12\n")
	if got := driveLogin(t, dest, "SEED-MEDIA\n12\n/nonexistent-archive.tar\n"); got != "BLANK" {
		t.Errorf("SEED-MEDIA reply %q, want BLANK", got)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err != nil {
		t.Errorf("the live session marker did not survive: %v", err)
	}
}

// mustRead is shared by many suites; it lived in import_media_test.go, which went with the verb.
func mustRead(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}
