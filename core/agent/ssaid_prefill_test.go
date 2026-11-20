package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261207-16 (the backlog row "On a boot after a flash or an OTA, the bundled apps of every sign-in share one
// ANDROID_ID"): roamd's seedssaid arm counts the settings_ssaid.xml SettingsProvider pre-filled into
// $STATE/ssaid-prefill, and an in-session issue report carries it as status keys.

// Every count differs, so a key read from the wrong group is seen.
const goodSsaidPrefill = "v=1 rows=7 userkey=1 apps=6 distinct=2 largest=5\n"

var ssaidPrefillKeys = []string{"ssaid_prefill", "ssaid_prefill_rows", "ssaid_prefill_userkey", "ssaid_prefill_apps", "ssaid_prefill_distinct", "ssaid_prefill_largest"}

func plantSsaidPrefill(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, ssaidPrefillFile)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func ssaidPrefillSame(t *testing.T, label string, got, want map[string]string) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("%s: %d keys %v, want %v", label, len(got), got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: %s = %q, want %q", label, k, got[k], v)
		}
	}
}

func TestSsaidPrefillShapes(t *testing.T) {
	counts := map[string]string{
		"ssaid_prefill":          "read",
		"ssaid_prefill_rows":     "7",
		"ssaid_prefill_userkey":  "1",
		"ssaid_prefill_apps":     "6",
		"ssaid_prefill_distinct": "2",
		"ssaid_prefill_largest":  "5",
	}
	for _, body := range []string{goodSsaidPrefill, strings.TrimSuffix(goodSsaidPrefill, "\n")} {
		ssaidPrefillSame(t, body, ssaidPrefillStatus(plantSsaidPrefill(t, t.TempDir(), body)), counts)
	}
	ssaidPrefillSame(t, "none", ssaidPrefillStatus(plantSsaidPrefill(t, t.TempDir(), "v=1 none\n")),
		map[string]string{"ssaid_prefill": "none"})
	for _, c := range []string{"link", "notool", "nostate", "format", "convert", "parse"} {
		ssaidPrefillSame(t, c, ssaidPrefillStatus(plantSsaidPrefill(t, t.TempDir(), "v=1 unread="+c+"\n")),
			map[string]string{"ssaid_prefill": "unread_" + c})
	}
}

func TestSsaidPrefillMissing(t *testing.T) {
	if got := ssaidPrefillStatus(filepath.Join(t.TempDir(), ssaidPrefillFile)); len(got) != 0 {
		t.Errorf("no file: %v, want no keys", got)
	}
}

func TestSsaidPrefillMalformed(t *testing.T) {
	for _, c := range []struct{ label, body string }{
		{"oversized", strings.TrimSuffix(goodSsaidPrefill, "\n") + strings.Repeat(" ", ssaidPrefillMaxBytes) + "\n"},
		{"a letter in a count", "v=1 rows=7a userkey=1 apps=6 distinct=2 largest=5\n"},
		{"a trailing extra field", "v=1 rows=7 userkey=1 apps=6 distinct=2 largest=5 x=1\n"},
		{"a name-like token", "v=1 rows=7 userkey=1 apps=6 distinct=2 largest=5 sp1924-alice\n"},
		{"an unknown class", "v=1 unread=other\n"},
		{"a class with a tail", "v=1 unread=link x\n"},
		{"none with a tail", "v=1 none extra\n"},
		{"v=2", "v=2 none\n"},
		{"a free-form line", "v=1 hello\n"},
		{"a value in a count", "v=1 rows=5e1a9c0b7d3f2468 userkey=1 apps=6 distinct=2 largest=5\n"},
		{"an empty file", ""},
		{"two lines", goodSsaidPrefill + goodSsaidPrefill},
		{"ten digits in a count", "v=1 rows=1234567890 userkey=1 apps=6 distinct=2 largest=5\n"},
		{"fields out of order", "v=1 userkey=1 rows=7 apps=6 distinct=2 largest=5\n"},
	} {
		ssaidPrefillSame(t, c.label, ssaidPrefillStatus(plantSsaidPrefill(t, t.TempDir(), c.body)),
			map[string]string{"ssaid_prefill": "unreadable"})
	}
	// A directory at the path cannot be read as the file.
	d := filepath.Join(t.TempDir(), ssaidPrefillFile)
	if err := os.Mkdir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	ssaidPrefillSame(t, "a directory", ssaidPrefillStatus(d), map[string]string{"ssaid_prefill": "unreadable"})
}

func TestSsaidPrefillReportScope(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	plantSsaidPrefill(t, st, "v=1 rows=8817263 userkey=1 apps=8817262 distinct=3 largest=6654321\n")
	for _, c := range []struct {
		label, name string
		deviceScope bool
	}{{"the gate (no name)", "", true}, {"a gate report with a name", "sp1924-gate", true}} {
		r := buildIssueReport(c.name, c.deviceScope, "", nil, nil)
		for _, k := range ssaidPrefillKeys {
			if v, ok := r.Status[k]; ok {
				t.Errorf("%s carries %s=%q, want none of the ssaid_prefill keys", c.label, k, v)
			}
		}
		b, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "8817262") || strings.Contains(string(b), "6654321") {
			t.Errorf("%s: an ssaid_prefill count reached the report", c.label)
		}
	}
	r := buildIssueReport("sp1924-session", false, "", nil, nil)
	for k, want := range map[string]string{
		"ssaid_prefill": "read", "ssaid_prefill_rows": "8817263", "ssaid_prefill_userkey": "1",
		"ssaid_prefill_apps": "8817262", "ssaid_prefill_distinct": "3", "ssaid_prefill_largest": "6654321",
	} {
		if r.Status[k] != want {
			t.Errorf("session report %s = %q, want %q", k, r.Status[k], want)
		}
	}
}
