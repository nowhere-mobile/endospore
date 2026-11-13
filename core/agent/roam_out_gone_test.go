package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// NWP-20261201-33: the never-called ROAM-OUT verb sealed the live session and rebooted the phone for any admitted
// caller (DECIDED 2026-11-06, h60 #12, docs/product-decisions.md). It is deleted; the verb must now meet the
// legacy-login fallthrough like any unknown first line, which answers BLANK while a session is live and touches nothing.
func TestRoamOutVerbIsGone(t *testing.T) {
	arms := parseLoginArms(t)
	if !arms.has("FIDO2-STATUS") {
		t.Fatal("control: parseLoginArms lost FIDO2-STATUS, so the ROAM-OUT check below proves nothing")
	}
	if arms.has("ROAM-OUT") {
		t.Error(`handleLogin still dispatches "ROAM-OUT"`)
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
		if strings.Contains(src, "handleRoamOut") || strings.Contains(src, `"ROAM-OUT"`) {
			t.Errorf("%s still names handleRoamOut or \"ROAM-OUT\"", filepath.Base(f))
		}
	}
	if !sawControl {
		t.Error(`control: the scan did not read main.go and find "FIDO2-STATUS"`)
	}

	var mu sync.Mutex
	var reboots []string
	old := rebootHook
	rebootHook = func(reason string) bool {
		mu.Lock()
		defer mu.Unlock()
		reboots = append(reboots, reason)
		return true
	}
	t.Cleanup(func() { rebootHook = old })

	dest := t.TempDir()
	writeMarker(t, dest, "roamout-gone\npass\n12\n")
	if got := driveLogin(t, dest, "ROAM-OUT\n12\n"); got != "BLANK" {
		t.Errorf("ROAM-OUT reply %q, want BLANK", got)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err != nil {
		t.Errorf("the live session marker did not survive: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(reboots) != 0 {
		t.Errorf("ROAM-OUT reached rebootNow: %q", reboots)
	}
}
