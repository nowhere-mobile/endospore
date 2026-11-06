package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260901-05: OTA-STATUS gains an OPTIONAL SECOND LINE carrying fine-grained progress for the two long
// phases (the payload fetch, then the ~40min VABC slot write), which previously showed the owner nothing but
// an indeterminate spinner and so read as hung.
//
// The contract this pins:
//   - a well-formed ota.prog renders as "PROG <phase> <done> <total>"
//   - ANY malformed / torn / nonsensical input renders as "" so the caller omits the line and the bar stays
//     indeterminate. Rendering a WRONG bar is worse than rendering no bar: a wrong bar is a claim.
//   - done > total is clamped rather than dropped -- writeProg's numerator (bytes actually read) and
//     denominator (a pre-walk stat snapshot) are measured differently and legitimately cross over.
func TestOtaProgLine(t *testing.T) {
	cases := []struct {
		name string
		body string // "" means: do not create the file at all
		want string
	}{
		{"download in flight", "osdownload 524288000 2400000000\n", "PROG osdownload 524288000 2400000000"},
		{"slot write", "oswrite 45 100\n", "PROG oswrite 45 100"},
		{"verifying", "osverify 25 100", "PROG osverify 25 100"}, // no trailing newline
		{"finalizing", "osfinalize 90 100\n", "PROG osfinalize 90 100"},
		{"done", "osdone 100 100\n", "PROG osdone 100 100"},
		{"zero progress is still progress", "oswrite 0 100\n", "PROG oswrite 0 100"},
		{"overshoot is clamped, not dropped", "osdownload 1200 1000\n", "PROG osdownload 1000 1000"},
		{"extra whitespace", "  oswrite   45   100  \n", "PROG oswrite 45 100"},

		// Everything below must produce NO line.
		{"absent file", "", ""},
		{"empty file", "", ""},
		{"two fields (torn write)", "oswrite 45\n", ""},
		{"four fields", "oswrite 45 100 extra\n", ""},
		{"non-numeric done", "oswrite abc 100\n", ""},
		{"non-numeric total", "oswrite 45 abc\n", ""},
		{"zero total would divide by zero", "oswrite 0 0\n", ""},
		{"negative total", "oswrite 45 -100\n", ""},
		{"negative done", "oswrite -1 100\n", ""},
		{"blank line only", "\n", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			if c.body != "" || c.name == "empty file" || c.name == "blank line only" {
				if err := os.WriteFile(filepath.Join(dir, "ota.prog"), []byte(c.body), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if got := otaProgLine(dir); got != c.want {
				t.Errorf("otaProgLine(%q) = %q, want %q", c.body, got, c.want)
			}
		})
	}
}

// The reply is only ever a SECOND line, so a chooser that reads one line (DaemonSocket.roundTrip) is
// unaffected. This pins the prefix so nobody "simplifies" it into an appended field on the DOWNLOADING /
// APPLYING line, which would land inside renderOtaStatus's version field and surface to the user as
// "Downloading update (0.5.11 PROG oswrite 45 100)...".
func TestOtaProgLineIsItsOwnLine(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ota.prog"), []byte("oswrite 45 100\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := otaProgLine(dir)
	if len(got) < 5 || got[:5] != "PROG " {
		t.Fatalf("progress line must be self-identifying and start with %q, got %q", "PROG ", got)
	}
	for _, r := range got {
		if r == '\n' {
			t.Fatalf("otaProgLine must return ONE line with no embedded newline, got %q", got)
		}
	}
}
