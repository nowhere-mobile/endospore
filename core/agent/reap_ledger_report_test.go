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
// NWP-20261203-01: reap_ledger_fw counts the rows whose fw= is restart / unknown and whose pm:ownerless= is above 0.
// NWP-20261203-22: reap_ledger_keys counts the keys=notsealed rows and, of those, the kwhy=no-receipt ones.

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
	wantReapFw      = "restart=0 unknown=0 pmleft=0" // no planted row carries fw= or pm:, so each counts as none
	wantReapKeys    = "notsealed=1 norcpt=0"
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
		"reap_ledger_fw":      wantReapFw,
		"reap_ledger_keys":    wantReapKeys,
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
	for _, k := range []string{"reap_ledger_classes", "reap_ledger_userdir", "reap_ledger_fw", "reap_ledger_keys"} {
		if _, ok := r.Status[k]; ok {
			t.Errorf("an unreadable ledger still reports %s", k)
		}
	}
}

func TestReapLedgerReport_L4NoIdentity(t *testing.T) {
	plantReapLedger(t, plantedReapLedger+
		"1700000123 uid=48151 class=residue keys=sealed survives:/data/user/48151/plantedprofilex userdir=anchor:blind,polls:0,after:0 census:files:1 other=0\n"+
		"plantedprofilex was here\n"+
		"1700000125 uid=48153 class=clean keys=notsealed survives: userdir=anchor:ok,polls:1,after:0 census:none kwhy=no-receipt\n")
	t.Setenv("NOWHERE_DIR", t.TempDir())
	for _, deviceScope := range []bool{true, false} {
		r := buildIssueReport("rlprofile918", deviceScope, "", nil, nil)
		if got := r.Status["reap_ledger_keys"]; got != "notsealed=2 norcpt=1" {
			t.Errorf("scope=%v reap_ledger_keys = %q, want %q", deviceScope, got, "notsealed=2 norcpt=1")
		}
		b, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{"48151", "1700000123", "plantedprofilex", "48153", "1700000125"} {
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
			"reap_ledger_fw":      wantReapFw,
			"reap_ledger_keys":    wantReapKeys,
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

// NWP-20261203-01: fw=restart and fw=unknown count each; fw=same does not. pm:ownerless=<n> counts when n is above 0;
// pm:unread, ownerless=0, a value that is not a number and a row with no pm: field do not.
func TestReapLedgerReport_L9Framework(t *testing.T) {
	got := reapLedgerCounts(plantReapLedger(t,
		"1700000301 uid=41 class=clean keys=sealed survives: userdir=anchor:ok,polls:1,after:0 census:none fw=restart pm:ownerless=2,shared=1,declperm=1\n"+
			"1700000302 uid=42 class=husk keys=sealed survives:/data/user/42 userdir=anchor:ok,polls:1,after:0 census:none fw=unknown pm:unread\n"+
			"1700000303 uid=43 class=residue keys=sealed survives:/data/user_de/43 userdir=anchor:ok,polls:1,after:0 census:none fw=same pm:ownerless=0,shared=0,declperm=0\n"+
			"1700000304 uid=44 class=clean keys=sealed survives: userdir=anchor:ok,polls:1,after:0 census:none fw=restart pm:ownerless=0,shared=0,declperm=0\n"+
			"1700000305 uid=45 class=clean keys=sealed survives: userdir=anchor:ok,polls:1,after:0 census:none fw=same pm:ownerless=3,shared=0,declperm=0\n"+
			"1700000306 uid=46 class=residue keys=sealed survives:/data/user/46 userdir=anchor:ok,polls:1,after:0 census:none\n"+
			"1700000307 uid=47 class=residue keys=sealed survives:/data/user/47 userdir=anchor:ok,polls:1,after:0 census:none fw=same pm:ownerless=x,shared=0,declperm=0\n"))
	want := map[string]string{
		"reap_ledger_rows":    "7",
		"reap_ledger_classes": "boot=0 clean=3 gaveup=0 husk=1 other=0 recheck=0 residue=3 retried=0",
		"reap_ledger_fw":      "restart=2 unknown=1 pmleft=2",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}

// NWP-20261203-01: the fw= and pm: fields add counts only; no uid or time reaches reap_ledger_fw or the report.
func TestReapLedgerReport_L10FwNoIdentity(t *testing.T) {
	p := plantReapLedger(t, "1700000401 uid=48153 class=clean keys=sealed survives: userdir=anchor:ok,polls:1,after:0 census:none fw=restart pm:ownerless=1,shared=1,declperm=1\n")
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bad := []string{"48153", "1700000401"}
	got := reapLedgerCounts(p)["reap_ledger_fw"]
	if got != "restart=1 unknown=0 pmleft=1" {
		t.Errorf("reap_ledger_fw = %q, want %q", got, "restart=1 unknown=0 pmleft=1")
	}
	for _, s := range bad {
		if strings.Contains(got, s) {
			t.Errorf("reap_ledger_fw = %q carries %q", got, s)
		}
	}
	for _, deviceScope := range []bool{true, false} {
		r := buildIssueReport("rlprofile1203", deviceScope, "", nil, nil)
		if r.Status["reap_ledger_fw"] != "restart=1 unknown=0 pmleft=1" {
			t.Errorf("scope=%v reap_ledger_fw = %q", deviceScope, r.Status["reap_ledger_fw"])
		}
		b, err := json.Marshal(r)
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

// NWP-20261203-22: reap_ledger_keys counts rows with exactly keys=notsealed and, of those, exactly kwhy=no-receipt; a
// kwhy on a sealed or recheck row, another class, or no kwhy field counts nothing for norcpt.
func TestReapLedgerReport_L11KeysWhy(t *testing.T) {
	got := reapLedgerCounts(plantReapLedger(t, "1700000301 uid=41 class=clean keys=notsealed survives: userdir=anchor:ok,polls:1,after:0 census:none kwhy=no-receipt\n"+
		"1700000302 uid=42 class=husk keys=notsealed survives:/data/user/42 userdir=anchor:ok,polls:1,after:0 census:none fw=1 kwhy=no-receipt\n"+
		"1700000303 uid=43 class=clean keys=notsealed survives: userdir=anchor:ok,polls:1,after:0 census:none kwhy=rc5\n"+
		"1700000304 uid=44 class=clean keys=notsealed survives: userdir=anchor:ok,polls:1,after:0 census:none kwhy=none\n"+
		"1700000305 uid=45 class=clean keys=notsealed survives: userdir=anchor:ok,polls:1,after:0 census:none\n"+
		"1700000306 uid=46 class=clean keys=sealed survives: userdir=anchor:ok,polls:1,after:0 census:none kwhy=no-receipt\n"+
		"1700000307 uid=47 class=recheck userdir=recheck:ok census:files:1 other=0 kwhy=no-receipt\n"+
		"1700000308 uid=48 class=clean keys=notsealedx survives: userdir=anchor:ok,polls:1,after:0 census:none kwhy=no-receipt\n"))
	if want := "notsealed=5 norcpt=2"; got["reap_ledger_keys"] != want {
		t.Errorf("reap_ledger_keys = %q, want %q", got["reap_ledger_keys"], want)
	}
	empty := reapLedgerCounts(plantReapLedger(t, ""))
	if _, ok := empty["reap_ledger_classes"]; !ok || empty["reap_ledger_keys"] != "notsealed=0 norcpt=0" {
		t.Errorf("an empty ledger = %v, want reap_ledger_classes and reap_ledger_keys %q", empty, "notsealed=0 norcpt=0")
	}
	if v, ok := reapLedgerCounts(filepath.Join(t.TempDir(), "missing"))["reap_ledger_keys"]; ok {
		t.Errorf("an absent ledger reports reap_ledger_keys = %q", v)
	}
}
