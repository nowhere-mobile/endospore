package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeSiblingsLog writes body to <dir>/roam.log and returns the path.
func writeSiblingsLog(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, "roam.log")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

const siblingsGoodLine = "[roamd] bootsweep siblings: softap=u:object_r:wifi_data_file:s0/w1 scorecard=absent health=?/w0 " +
	"suggest=unreachable netstats=u:object_r:apex_tethering_data_file:s0/w0 netpolicy=u:object_r:system_data_file:s0/w1 " +
	"wifidir=u:object_r:wifi_data_file:s0/w1 Thu Nov 12 10:00:00 UTC 2026"

const siblingsGoodWant = "softap=u:object_r:wifi_data_file:s0/w1 scorecard=absent health=?/w0 suggest=unreachable " +
	"netstats=u:object_r:apex_tethering_data_file:s0/w0 netpolicy=u:object_r:system_data_file:s0/w1 " +
	"wifidir=u:object_r:wifi_data_file:s0/w1"

// T1: the LAST `[roamd] bootsweep siblings:` line wins; an earlier one and a later line of another shape are not read.
func TestBootsweepSiblingsStatus_LastRoamdLineWins(t *testing.T) {
	first := "[roamd] bootsweep siblings: softap=absent scorecard=absent health=absent suggest=absent netstats=absent " +
		"netpolicy=absent wifidir=absent Wed Nov 11 09:00:00 UTC 2026"
	body := first + "\n[roamd] bootsweep: staging=0 Wed Nov 11 09:00:01 UTC 2026\n" + siblingsGoodLine + "\r\n" +
		"[roamd] reap uid 10 done\n[mediad] x siblings: softap=absent\n"
	p := writeSiblingsLog(t, t.TempDir(), body)
	if got := bootsweepSiblingsStatus(p); got != siblingsGoodWant {
		t.Fatalf("bootsweepSiblingsStatus = %q, want %q", got, siblingsGoodWant)
	}
}

// T2: only the four value shapes are copied; a category list, a path or a word reads OTHER.
func TestBootsweepSiblingsStatus_ValueShapes(t *testing.T) {
	line := "[roamd] bootsweep siblings: softap=u:object_r:wifi_data_file:s0/w1 scorecard=?/w0 health=absent " +
		"suggest=unreachable netstats=u:object_r:x:s0:c512,c768/w1 netpolicy=/data/misc/apexdata/x wifidir=alice " +
		"Thu Nov 12 10:00:00 UTC 2026\n"
	p := writeSiblingsLog(t, t.TempDir(), line)
	want := "softap=u:object_r:wifi_data_file:s0/w1 scorecard=?/w0 health=absent suggest=unreachable " +
		"netstats=OTHER netpolicy=OTHER wifidir=OTHER"
	if got := bootsweepSiblingsStatus(p); got != want {
		t.Fatalf("bootsweepSiblingsStatus = %q, want %q", got, want)
	}
}

// T3: a key the line lacks reads missing; an unknown key and the date words are never copied.
func TestBootsweepSiblingsStatus_MissingKeyAndNoForeignText(t *testing.T) {
	line := "[roamd] bootsweep siblings: softap=absent scorecard=absent name=alice suggest=absent netstats=absent " +
		"netpolicy=absent wifidir=absent Thu Nov 12 10:00:00 UTC 2026\n"
	p := writeSiblingsLog(t, t.TempDir(), line)
	want := "softap=absent scorecard=absent health=missing suggest=absent netstats=absent netpolicy=absent wifidir=absent"
	got := bootsweepSiblingsStatus(p)
	if got != want {
		t.Fatalf("bootsweepSiblingsStatus = %q, want %q", got, want)
	}
	for _, bad := range []string{"alice", "name", "Thu", "UTC", "2026", "10:00:00"} {
		if strings.Contains(got, bad) {
			t.Fatalf("result %q carries %q", got, bad)
		}
	}
}

// T4: an absent file, a directory at the path and a file with no siblings line are three different answers.
func TestBootsweepSiblingsStatus_AbsentDirNone(t *testing.T) {
	d := t.TempDir()
	if got := bootsweepSiblingsStatus(filepath.Join(d, "roam.log")); got != "none (no roam.log)" {
		t.Fatalf("absent file: got %q, want %q", got, "none (no roam.log)")
	}
	dirPath := filepath.Join(d, "isdir")
	if err := os.Mkdir(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := bootsweepSiblingsStatus(dirPath); got != "unreadable" {
		t.Fatalf("directory: got %q, want %q", got, "unreadable")
	}
	p := writeSiblingsLog(t, d, "[roamd] bootsweep: staging=0\n[roamd] reap uid 10 done\n")
	if got := bootsweepSiblingsStatus(p); got != "none" {
		t.Fatalf("no siblings line: got %q, want %q", got, "none")
	}
}

// T5: only the last bootsweepSiblingsTailBytes are read, so a line pushed out of the tail reads none.
func TestBootsweepSiblingsStatus_TailBound(t *testing.T) {
	var b strings.Builder
	b.WriteString(siblingsGoodLine + "\n")
	filler := "[roamd] filler " + strings.Repeat("x", 64) + "\n"
	for b.Len() < 3<<20 {
		b.WriteString(filler)
	}
	p := writeSiblingsLog(t, t.TempDir(), b.String())
	if got := bootsweepSiblingsStatus(p); got != "none" {
		t.Fatalf("line outside the tail: got %q, want %q", got, "none")
	}
}

// T6: the key is in the report at gate AND session scope; the gate report still carries no roam.log section.
func TestBootsweepSiblingsStatus_BothScopes(t *testing.T) {
	d := t.TempDir()
	t.Setenv("NOWHERE_DIR", d)
	writeSiblingsLog(t, d, siblingsGoodLine+"\n")
	for _, deviceScope := range []bool{true, false} {
		r := buildIssueReport("sibprofile", deviceScope, "", nil, nil)
		if got := r.Status["bootsweep_siblings"]; got != siblingsGoodWant {
			t.Fatalf("deviceScope=%v: bootsweep_siblings = %q, want %q", deviceScope, got, siblingsGoodWant)
		}
		if _, ok := r.Logs["roam.log"]; deviceScope && ok {
			t.Fatalf("deviceScope=true: the report carries a roam.log section")
		}
	}
}
