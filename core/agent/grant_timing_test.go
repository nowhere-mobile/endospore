package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261119-07 (backlog: 0.5.49's grant op runs the Keystore sweep, ...): roamd's grant arm writes its bundle count
// and step timings to $STATE/grant-timing, and an in-session issue report carries them as four status keys.

const goodGrantTiming = "v=1 bundles=2 keystore_ms=118000 perms_ms=3100 total_ms=122550\n"

var grantTimingKeys = []string{"grant_bundles", "grant_keystore_ms", "grant_perms_ms", "grant_total_ms", "grant_timing"}

func plantGrantTiming(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, grantTimingFile)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestGrantTimingWellFormed(t *testing.T) {
	for _, body := range []string{goodGrantTiming, strings.TrimSuffix(goodGrantTiming, "\n")} {
		got := grantTimingStatus(plantGrantTiming(t, t.TempDir(), body))
		want := map[string]string{
			"grant_bundles":     "2",
			"grant_keystore_ms": "118000",
			"grant_perms_ms":    "3100",
			"grant_total_ms":    "122550",
		}
		if len(got) != len(want) {
			t.Errorf("%q: %d keys %v, want %v", body, len(got), got, want)
		}
		for k, v := range want {
			if got[k] != v {
				t.Errorf("%q: %s = %q, want %q", body, k, got[k], v)
			}
		}
	}
}

func TestGrantTimingMissing(t *testing.T) {
	if got := grantTimingStatus(filepath.Join(t.TempDir(), grantTimingFile)); len(got) != 0 {
		t.Errorf("no file: %v, want no keys", got)
	}
}

func TestGrantTimingMalformed(t *testing.T) {
	for _, c := range []struct{ label, body string }{
		{"letters in bundles", "v=1 bundles=ab keystore_ms=1 perms_ms=2 total_ms=3\n"},
		{"letters in total", "v=1 bundles=2 keystore_ms=1 perms_ms=2 total_ms=3x\n"},
		{"a sixth field", "v=1 bundles=2 keystore_ms=1 perms_ms=2 total_ms=3 extra=4\n"},
		{"a name-like token", "v=1 bundles=2 keystore_ms=1 perms_ms=2 total_ms=5 gt1347-alice\n"},
		{"a name in a value", "v=1 bundles=gt1347-alice keystore_ms=1 perms_ms=2 total_ms=3\n"},
		{"v=2", "v=2 bundles=2 keystore_ms=1 perms_ms=2 total_ms=3\n"},
		{"fields out of order", "v=1 keystore_ms=1 bundles=2 perms_ms=2 total_ms=3\n"},
		{"an empty file", ""},
		{"two lines", goodGrantTiming + goodGrantTiming},
		{"a negative value", "v=1 bundles=2 keystore_ms=-1 perms_ms=2 total_ms=3\n"},
		{"an empty value", "v=1 bundles= keystore_ms=1 perms_ms=2 total_ms=3\n"},
	} {
		got := grantTimingStatus(plantGrantTiming(t, t.TempDir(), c.body))
		if len(got) != 1 || got["grant_timing"] != "unreadable" {
			t.Errorf("%s: %v, want exactly grant_timing=unreadable", c.label, got)
		}
	}
	// A directory at the path cannot be read as the file.
	d := filepath.Join(t.TempDir(), grantTimingFile)
	if err := os.Mkdir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := grantTimingStatus(d); len(got) != 1 || got["grant_timing"] != "unreadable" {
		t.Errorf("a directory: %v, want exactly grant_timing=unreadable", got)
	}
}

func TestGrantTimingReportScope(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	plantGrantTiming(t, st, goodGrantTiming)
	for _, c := range []struct {
		label, name string
		deviceScope bool
	}{{"the gate (no name)", "", true}, {"a gate report with a name", "gt1347-gate", true}} {
		r := buildIssueReport(c.name, c.deviceScope, "", nil, nil)
		for _, k := range grantTimingKeys {
			if v, ok := r.Status[k]; ok {
				t.Errorf("%s carries %s=%q, want none of the grant keys", c.label, k, v)
			}
		}
		b, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "122550") || strings.Contains(string(b), "118000") {
			t.Errorf("%s: a grant figure reached the report", c.label)
		}
	}
	r := buildIssueReport("gt1347-session", false, "", nil, nil)
	for k, want := range map[string]string{
		"grant_bundles": "2", "grant_keystore_ms": "118000", "grant_perms_ms": "3100", "grant_total_ms": "122550",
	} {
		if r.Status[k] != want {
			t.Errorf("session report %s = %q, want %q", k, r.Status[k], want)
		}
	}
	if _, ok := r.Status["grant_timing"]; ok {
		t.Errorf("a well-formed file still reports grant_timing=%q", r.Status["grant_timing"])
	}
}
