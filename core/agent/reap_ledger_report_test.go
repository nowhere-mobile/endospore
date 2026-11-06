package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// NWP-20261107-14 (Q143): an issue report carries the reap ledger's counts per class, never a uid or a name.
// NWP-20261114-25 (#67): the reap retry's gaveup and retried rows count as their own classes, never as other.

const plantedReapLedger = "1700000001 uid=11 class=clean keys=sealed survives: userdir=anchor:ok,polls:1,after:0,atanchor census:files:2 other=0\n" +
	"1700000002 uid=12 class=husk keys=sealed survives:/data/user/12 userdir=anchor:timeout,polls:20,after:0 census:none\n" +
	"1700000003 uid=13 class=residue keys=notsealed survives:/data/user_de/13 userdir=anchor:blind,polls:0,after:0 census:none\n" +
	"1700000004 uid=14 class=clean keys=sealed survives: userdir=anchor:timeout,polls:20,after:0 census:none\n" +
	"1700000005 uid=15 class=recheck userdir=recheck:ok census:files:1 other=0\n" +
	"1700000006 userdir ctx=boot uid=16 cleared files:1 other=0\n" +
	"1700000007 userdir ctx=boot uid=17 LEFT unreadable\n" +
	"1700000008 uid=18 class=gaveup tries=3 survives:/data/user/18\n" +
	"1700000010 uid=19 class=gaveup tries=3 survives:/data/user_de/19\n" +
	"1700000011 uid=20 class=retried tries=1 survives:\n" +
	"this is not a ledger row\n" +
	"\n"

const (
	wantReapRows    = "11"
	wantReapClasses = "boot=2 clean=2 gaveup=2 husk=1 other=1 recheck=1 residue=1 retried=1"
	wantReapUserdir = "blind=1 timeout=2"
)

func pointReapLedgerAt(t *testing.T, p string) {
	t.Helper()
	old := reapLedgerPath
	reapLedgerPath = p
	t.Cleanup(func() { reapLedgerPath = old })
}

func plantReapLedger(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "reap-ledger")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	pointReapLedgerAt(t, p)
	return p
}

func TestReapLedgerReport_L1EveryRowShape(t *testing.T) {
	got := reapLedgerCounts(plantReapLedger(t, plantedReapLedger))
	want := map[string]string{
		"reap_ledger_rows":    wantReapRows,
		"reap_ledger_classes": wantReapClasses,
		"reap_ledger_userdir": wantReapUserdir,
	}
	if len(got) != len(want) {
		t.Fatalf("keys = %v, want exactly %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}

func TestReapLedgerReport_L2Absent(t *testing.T) {
	got := reapLedgerCounts(filepath.Join(t.TempDir(), "missing"))
	if len(got) != 1 || got["reap_ledger_rows"] != "0 (no ledger)" {
		t.Fatalf("absent ledger = %v", got)
	}
}

func TestReapLedgerReport_L3Unreadable(t *testing.T) {
	d := t.TempDir()
	got := reapLedgerCounts(d)
	v := got["reap_ledger_rows"]
	if len(got) != 1 || !strings.HasPrefix(v, "unreadable: ") || strings.Contains(v, d) {
		t.Fatalf("unreadable ledger = %v", got)
	}
	pointReapLedgerAt(t, d)
	r := buildIssueReport("rlprofile918", true, "", nil, nil)
	if r.Status["reap_ledger_rows"] != v {
		t.Errorf("report rows = %q, want %q", r.Status["reap_ledger_rows"], v)
	}
	for _, k := range []string{"reap_ledger_classes", "reap_ledger_userdir"} {
		if _, ok := r.Status[k]; ok {
			t.Errorf("an unreadable ledger still reports %s", k)
		}
	}
}

func TestReapLedgerReport_L4NoIdentity(t *testing.T) {
	plantReapLedger(t, plantedReapLedger+
		"1700000123 uid=48151 class=residue keys=sealed survives:/data/user/48151/plantedprofilex userdir=anchor:blind,polls:0,after:0 census:files:1 other=0\n"+
		"plantedprofilex was here\n")
	t.Setenv("NOWHERE_DIR", t.TempDir())
	for _, deviceScope := range []bool{true, false} {
		b, err := json.Marshal(buildIssueReport("rlprofile918", deviceScope, "", nil, nil))
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{"48151", "1700000123", "plantedprofilex"} {
			if strings.Contains(string(b), bad) {
				t.Errorf("scope=%v: %q reached the report", deviceScope, bad)
			}
		}
	}
}

func TestReapLedgerReport_L5BothScopes(t *testing.T) {
	plantReapLedger(t, plantedReapLedger)
	t.Setenv("NOWHERE_DIR", t.TempDir())
	for _, deviceScope := range []bool{true, false} {
		r := buildIssueReport("rlprofile918", deviceScope, "", nil, nil)
		for k, want := range map[string]string{
			"reap_ledger_rows":    wantReapRows,
			"reap_ledger_classes": wantReapClasses,
			"reap_ledger_userdir": wantReapUserdir,
		} {
			if r.Status[k] != want {
				t.Errorf("scope=%v %s = %q, want %q", deviceScope, k, r.Status[k], want)
			}
		}
	}
}

func TestReapLedgerReport_L6TailBound(t *testing.T) {
	var sb strings.Builder
	for sb.Len() < reapLedgerTailBytes+40<<10 {
		sb.WriteString("1700000009 uid=21 class=clean keys=sealed survives: userdir=anchor:ok,polls:1,after:0 census:none\n")
	}
	data := sb.String()
	tail := data[len(data)-reapLedgerTailBytes:]
	want := strings.Count(tail[strings.IndexByte(tail, '\n')+1:], "\n")
	got := reapLedgerCounts(plantReapLedger(t, data))
	if got["reap_ledger_rows"] != strconv.Itoa(want) {
		t.Errorf("rows = %q, want %d", got["reap_ledger_rows"], want)
	}
	if !strings.Contains(got["reap_ledger_classes"], "other=0") {
		t.Errorf("a partial first line was counted: %q", got["reap_ledger_classes"])
	}
}

func TestReapLedgerReport_L7EverySixClasses(t *testing.T) {
	got := reapLedgerCounts(plantReapLedger(t, "1700000201 uid=31 class=clean survives:\n"+
		"1700000202 uid=32 class=husk survives:/data/user/32\n"+
		"1700000203 uid=33 class=recheck userdir=recheck:ok\n"+
		"1700000204 uid=34 class=residue survives:/data/user_de/34\n"+
		"1700000205 uid=35 class=gaveup tries=3 survives:/data/user/35\n"+
		"1700000206 uid=36 class=gaveup tries=3 survives:/data/user/36\n"+
		"1700000207 uid=37 class=gaveup tries=3 survives:/data/user/37\n"+
		"1700000208 uid=38 class=retried tries=2 survives:\n"+
		"1700000209 userdir ctx=boot uid=39 cleared files:1 other=0\n"+
		"1700000210 uid=40 class=bogus\n"))
	want := map[string]string{
		"reap_ledger_rows":    "10",
		"reap_ledger_classes": "boot=1 clean=1 gaveup=3 husk=1 other=1 recheck=1 residue=1 retried=1",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}

func TestReapLedgerReport_L8RetryNoIdentity(t *testing.T) {
	p := plantReapLedger(t, plantedReapLedger+
		"1700000124 uid=48152 class=gaveup tries=3 survives:/data/misc_de/48152/plantedgaveupx\n")
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bad := []string{"48152", "1700000124", "plantedgaveupx", "misc_de", "tries"}
	counts := reapLedgerCounts(p)
	if !strings.Contains(counts["reap_ledger_classes"], " gaveup=3 ") {
		t.Errorf("the planted gaveup row was not counted: %q", counts["reap_ledger_classes"])
	}
	for k, v := range counts {
		for _, s := range bad {
			if strings.Contains(v, s) {
				t.Errorf("%s = %q carries %q", k, v, s)
			}
		}
	}
	for _, deviceScope := range []bool{true, false} {
		b, err := json.Marshal(buildIssueReport("rlprofile1191", deviceScope, "", nil, nil))
		if err != nil {
			t.Fatal(err)
		}
		for _, s := range bad {
			if strings.Contains(string(b), s) {
				t.Errorf("scope=%v: %q reached the report", deviceScope, s)
			}
		}
	}
}
