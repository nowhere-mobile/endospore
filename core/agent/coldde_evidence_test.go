package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261206-23 (backlog: During a cold lock, AccountManagerService's own handler thread re-creates an EMPTY
// `accounts_de.db` for the stopped user): the last cold-lock resume's figures in $STATE/coldde-unpark reach an
// in-session issue report as eight coldde_* status keys.

const goodColdDeUnpark = "v=1 found=1 after_park_s=39 db_bytes=4096 wal_bytes=32992 emails=0 ss_fds=5 pkgs_delta_s=-2 pkgr_delta_s=17\n"

var coldDeKeys = []string{"coldde_found", "coldde_after_park_s", "coldde_db_bytes", "coldde_wal_bytes", "coldde_emails",
	"coldde_ss_fds", "coldde_pkgs_delta_s", "coldde_pkgr_delta_s"}

func plantColdDeUnpark(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, coldDeUnparkFile)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func wantColdDe(t *testing.T, label string, got, want map[string]string) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("%s: %d keys %v, want %v", label, len(got), got, want)
	}
	for k, v := range want {
		if g, ok := got[k]; !ok || g != v {
			t.Errorf("%s: %s = %q (present %v), want %q", label, k, g, ok, v)
		}
	}
}

func TestColdDeUnparkStatusParses(t *testing.T) {
	want := map[string]string{
		"coldde_found": "1", "coldde_after_park_s": "39", "coldde_db_bytes": "4096", "coldde_wal_bytes": "32992",
		"coldde_emails": "0", "coldde_ss_fds": "5", "coldde_pkgs_delta_s": "-2", "coldde_pkgr_delta_s": "17",
	}
	for _, body := range []string{goodColdDeUnpark, strings.TrimSuffix(goodColdDeUnpark, "\n")} {
		wantColdDe(t, "found=1 "+body, coldDeUnparkStatus(plantColdDeUnpark(t, t.TempDir(), body)), want)
	}
	na := "v=1 found=0 after_park_s=na db_bytes=na wal_bytes=na emails=na ss_fds=na pkgs_delta_s=na pkgr_delta_s=na\n"
	wantColdDe(t, "found=0", coldDeUnparkStatus(plantColdDeUnpark(t, t.TempDir(), na)), map[string]string{
		"coldde_found": "0", "coldde_after_park_s": "na", "coldde_db_bytes": "na", "coldde_wal_bytes": "na",
		"coldde_emails": "na", "coldde_ss_fds": "na", "coldde_pkgs_delta_s": "na", "coldde_pkgr_delta_s": "na",
	})
}

func TestColdDeUnparkStatusMissing(t *testing.T) {
	if got := coldDeUnparkStatus(filepath.Join(t.TempDir(), coldDeUnparkFile)); len(got) != 0 {
		t.Errorf("no file: %v, want no keys", got)
	}
}

func TestColdDeUnparkStatusRefuses(t *testing.T) {
	long := strings.TrimSuffix(goodColdDeUnpark, "\n") + " " + strings.Repeat("x", 299-len(goodColdDeUnpark)) + "\n"
	if len(long) != 300 {
		t.Fatalf("the oversize fixture is %d bytes, want 300", len(long))
	}
	for _, c := range []struct{ label, body string }{
		{"an email in a value", "v=1 found=1 after_park_s=39 db_bytes=4096 wal_bytes=0 emails=a@b.example ss_fds=5 pkgs_delta_s=1 pkgr_delta_s=2\n"},
		{"a path in a value", "v=1 found=1 after_park_s=39 db_bytes=/data/system_de/10/accounts_de.db wal_bytes=0 emails=0 ss_fds=5 pkgs_delta_s=1 pkgr_delta_s=2\n"},
		{"an extra trailing field", strings.TrimSuffix(goodColdDeUnpark, "\n") + " extra=4\n"},
		{"a missing field", "v=1 found=1 after_park_s=39 db_bytes=4096 wal_bytes=32992 emails=0 pkgs_delta_s=-2 pkgr_delta_s=17\n"},
		{"v=2", "v=2" + strings.TrimPrefix(goodColdDeUnpark, "v=1")},
		{"two lines", goodColdDeUnpark + goodColdDeUnpark},
		{"300 bytes", long},
	} {
		got := coldDeUnparkStatus(plantColdDeUnpark(t, t.TempDir(), c.body))
		if len(got) != 1 || got["coldde_evidence"] != "unreadable" {
			t.Errorf("%s: %v, want exactly coldde_evidence=unreadable", c.label, got)
		}
		for k, v := range got {
			if strings.ContainsAny(v, "@/") {
				t.Errorf("%s: %s=%q copies text from the file", c.label, k, v)
			}
		}
	}
	// A directory at the path cannot be read as the file.
	d := filepath.Join(t.TempDir(), coldDeUnparkFile)
	if err := os.Mkdir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := coldDeUnparkStatus(d); len(got) != 1 || got["coldde_evidence"] != "unreadable" {
		t.Errorf("a directory: %v, want exactly coldde_evidence=unreadable", got)
	}
}

func TestSessionReportCarriesColdDeKeys(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	plantColdDeUnpark(t, st, goodColdDeUnpark)
	want := map[string]string{
		"coldde_found": "1", "coldde_after_park_s": "39", "coldde_db_bytes": "4096", "coldde_wal_bytes": "32992",
		"coldde_emails": "0", "coldde_ss_fds": "5", "coldde_pkgs_delta_s": "-2", "coldde_pkgr_delta_s": "17",
	}
	r := buildIssueReportWith("cde1901-session", false, "", nil, nil, nil)
	for k, v := range want {
		if r.Status[k] != v {
			t.Errorf("session report %s = %q, want %q", k, r.Status[k], v)
		}
	}
	if v, ok := r.Status["coldde_evidence"]; ok {
		t.Errorf("a well-formed file still reports coldde_evidence=%q", v)
	}
	r = buildIssueReportWith("cde1901-session", true, "", nil, nil, nil)
	for _, k := range append(coldDeKeys, "coldde_evidence") {
		if v, ok := r.Status[k]; ok {
			t.Errorf("a gate (deviceScope) report carries %s=%q, want none of the coldde keys", k, v)
		}
	}
}
