package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261202-34 (h50 #1, docs/product-decisions.md 2026-11-01): roamd's od_watched merges this session's timed du
// reads into $STATE/od-grow-timing, and an in-session issue report carries them as five status keys.

const goodOdGrowTiming = "v=1 vols=2 reads=37 du_ms=81234 max_ms=4567 kib=7340032\n"

var odGrowTimingKeys = []string{"od_grow_vols", "od_grow_reads", "od_grow_du_ms", "od_grow_du_max_ms", "od_grow_kib", "od_grow_timing"}

func plantOdGrowTiming(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, odGrowTimingFile)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestOdGrowTimingWellFormed(t *testing.T) {
	for _, body := range []string{goodOdGrowTiming, strings.TrimSuffix(goodOdGrowTiming, "\n")} {
		got := odGrowTimingStatus(plantOdGrowTiming(t, t.TempDir(), body))
		want := map[string]string{
			"od_grow_vols":      "2",
			"od_grow_reads":     "37",
			"od_grow_du_ms":     "81234",
			"od_grow_du_max_ms": "4567",
			"od_grow_kib":       "7340032",
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

func TestOdGrowTimingMissing(t *testing.T) {
	if got := odGrowTimingStatus(filepath.Join(t.TempDir(), odGrowTimingFile)); len(got) != 0 {
		t.Errorf("no file: %v, want no keys", got)
	}
}

func TestOdGrowTimingMalformed(t *testing.T) {
	for _, c := range []struct{ label, body string }{
		{"a letter in vols", "v=1 vols=2a reads=3 du_ms=4 max_ms=5 kib=6\n"},
		{"a letter in kib", "v=1 vols=2 reads=3 du_ms=4 max_ms=5 kib=x\n"},
		{"a sixth field", "v=1 vols=2 reads=3 du_ms=4 max_ms=5 kib=6 extra=7\n"},
		{"a name-like token", "v=1 vols=2 reads=3 du_ms=4 max_ms=5 kib=6 og1784-alice\n"},
		{"a path in a value", "v=1 vols=2 reads=3 du_ms=4 max_ms=5 kib=/data/media/0\n"},
		{"oversized", "v=1 vols=2 reads=3 du_ms=4 max_ms=5 kib=6" + strings.Repeat(" ", odGrowTimingMaxBytes) + "\n"},
		{"two lines", goodOdGrowTiming + goodOdGrowTiming},
		{"v=2", "v=2 vols=2 reads=3 du_ms=4 max_ms=5 kib=6\n"},
		{"fields out of order", "v=1 reads=3 vols=2 du_ms=4 max_ms=5 kib=6\n"},
		{"an empty file", ""},
		{"a negative value", "v=1 vols=2 reads=3 du_ms=-4 max_ms=5 kib=6\n"},
		{"an empty value", "v=1 vols= reads=3 du_ms=4 max_ms=5 kib=6\n"},
		{"ten digits in vols", "v=1 vols=1234567890 reads=3 du_ms=4 max_ms=5 kib=6\n"},
	} {
		got := odGrowTimingStatus(plantOdGrowTiming(t, t.TempDir(), c.body))
		if len(got) != 1 || got["od_grow_timing"] != "unreadable" {
			t.Errorf("%s: %v, want exactly od_grow_timing=unreadable", c.label, got)
		}
	}
	// A directory at the path cannot be read as the file.
	d := filepath.Join(t.TempDir(), odGrowTimingFile)
	if err := os.Mkdir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := odGrowTimingStatus(d); len(got) != 1 || got["od_grow_timing"] != "unreadable" {
		t.Errorf("a directory: %v, want exactly od_grow_timing=unreadable", got)
	}
}

func TestOdGrowTimingReportScope(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	plantOdGrowTiming(t, st, goodOdGrowTiming)
	for _, c := range []struct {
		label, name string
		deviceScope bool
	}{{"the gate (no name)", "", true}, {"a gate report with a name", "og1784-gate", true}} {
		r := buildIssueReport(c.name, c.deviceScope, "", nil, nil)
		for _, k := range odGrowTimingKeys {
			if v, ok := r.Status[k]; ok {
				t.Errorf("%s carries %s=%q, want none of the od_grow keys", c.label, k, v)
			}
		}
		b, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "7340032") || strings.Contains(string(b), "81234") {
			t.Errorf("%s: an od_grow figure reached the report", c.label)
		}
	}
	r := buildIssueReport("og1784-session", false, "", nil, nil)
	for k, want := range map[string]string{
		"od_grow_vols": "2", "od_grow_reads": "37", "od_grow_du_ms": "81234", "od_grow_du_max_ms": "4567", "od_grow_kib": "7340032",
	} {
		if r.Status[k] != want {
			t.Errorf("session report %s = %q, want %q", k, r.Status[k], want)
		}
	}
	if _, ok := r.Status["od_grow_timing"]; ok {
		t.Errorf("a well-formed file still reports od_grow_timing=%q", r.Status["od_grow_timing"])
	}
}
