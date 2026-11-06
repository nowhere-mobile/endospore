package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// dn-1105 #1 (docs/product-decisions.md 2026-10-21) for the previous boot's kernel tail (NWP-20261126-15). logd
// mirrors audit records into the kernel log, so pstore's console carries the same denials the avc section filters.
// At device scope a denial in prev_boot is kept only as deviceScopeDenials keeps it; every other line stays.

var pbFixture = []string{
	"init: Reboot start, reason: reboot,userrequested",
	"avc: denied { read } for pid=4242 scontext=u:r:untrusted_app:s0:c1,c2 tcontext=u:object_r:nowhere_media_file:s0 tclass=file app=com.example.departed",
	"avc: denied { write } for pid=77 scontext=u:r:nowhere:s0 tcontext=u:object_r:system_data_file:s0 tclass=dir app=com.example.other",
	"avc: denied { open } for pid=88 tcontext=u:object_r:update_engine:s0 tclass=file",
	"Kernel panic - not syncing: watchdog bite",
}

const (
	pbHeader       = "--- console-ramoops-0 ---"
	pbNowhereKept  = "avc: denied { write } for pid=77 scontext=u:r:nowhere:s0 tcontext=u:object_r:system_data_file:s0 tclass=dir"
	pbNoScontextOp = "{ open }"
)

// pbSetup points pstoreDir at a temp dir holding one console-ramoops-0 with pbFixture, and stubs the avc sources
// so no real logcat or dmesg runs.
func pbSetup(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_DIR", t.TempDir())
	orig := pstoreDir
	t.Cleanup(func() { pstoreDir = orig })
	pstoreDir = t.TempDir()
	if err := os.WriteFile(filepath.Join(pstoreDir, "console-ramoops-0"), []byte(strings.Join(pbFixture, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	stubAvc(t, [][]string{{"/test/none"}}, nil, nil)
}

func pbIndex(lines []string, want string) int {
	for i, ln := range lines {
		if ln == want {
			return i
		}
	}
	return -1
}

func TestPrevBootDeviceScopeReport(t *testing.T) {
	pbSetup(t)
	lines := buildIssueReport("", true, "", nil, nil).Logs["prev_boot"]
	all := strings.Join(lines, "\n")
	for _, bad := range []string{"untrusted_app", "app=", "com.example.", pbNoScontextOp} {
		if strings.Contains(all, bad) {
			t.Errorf("device-scope prev_boot carries %q:\n%s", bad, all)
		}
	}
	hdr, ini, den, pan := pbIndex(lines, pbHeader), pbIndex(lines, pbFixture[0]), pbIndex(lines, pbNowhereKept), pbIndex(lines, pbFixture[4])
	if hdr < 0 || ini < 0 || den < 0 || pan < 0 {
		t.Fatalf("device-scope prev_boot lost a line it must keep (header %d, init %d, nowhere denial %d, panic %d):\n%s",
			hdr, ini, den, pan, all)
	}
	if !(hdr < ini && ini < den && den < pan) {
		t.Errorf("device-scope prev_boot reordered its lines (header %d, init %d, nowhere denial %d, panic %d):\n%s",
			hdr, ini, den, pan, all)
	}
}

func TestPrevBootDeviceScopeSessionControl(t *testing.T) {
	pbSetup(t)
	lines := buildIssueReport("sess", false, "", nil, nil).Logs["prev_boot"]
	for _, want := range append([]string{pbHeader}, pbFixture...) {
		if pbIndex(lines, want) < 0 {
			t.Errorf("session-scope prev_boot lost %q:\n%s", want, strings.Join(lines, "\n"))
		}
	}
}

func TestPrevBootDeviceScopeFilter(t *testing.T) {
	cases := []struct {
		name     string
		in, want []string
	}{
		{"fixture", append([]string{pbHeader}, pbFixture...), []string{pbHeader, pbFixture[0], pbNowhereKept, pbFixture[4]}},
		{"nil", nil, []string{}},
		{"empty", []string{}, []string{}},
	}
	for _, c := range cases {
		if got := deviceScopePrevBoot(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: deviceScopePrevBoot\n got %q\nwant %q", c.name, got, c.want)
		}
	}
}
