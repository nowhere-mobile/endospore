package main

import (
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

// NWP-20261117-28: an issue report carries Android's own boot reason (boot_reason, boot_reason_last,
// boot_reason_history) at every scope, read by /system/bin/getprop; "unread" when the read is empty or refused.

var bootReasonKeys = []string{"boot_reason", "boot_reason_last", "boot_reason_history"}

// bootPropFixture answers readBootProp from props; a prop not in the map fails like a refused read.
func bootPropFixture(t *testing.T, props map[string]string) {
	t.Helper()
	old := readBootProp
	readBootProp = func(p string) (string, error) {
		v, ok := props[p]
		if !ok {
			return "", errors.New("exit status 1")
		}
		return v, nil
	}
	t.Cleanup(func() { readBootProp = old })
}

var frankelBootProps = map[string]string{
	"ro.boot.bootreason":              "reset,warm,ecc_ras_error\n",
	"sys.boot.reason.last":            "reboot,ota\n",
	"persist.sys.boot.reason.history": "reboot,ota,1729814328\nwarm,1729000000\n",
}

func wantFrankelBootReason(t *testing.T, label string, st map[string]string) {
	t.Helper()
	want := map[string]string{
		"boot_reason":         "reset,warm,ecc_ras_error",
		"boot_reason_last":    "reboot,ota",
		"boot_reason_history": "reboot,ota,<num>; warm,<num>",
	}
	for k, w := range want {
		if got, ok := st[k]; !ok || got != w {
			t.Errorf("%s: status[%q] = %q (present %v), want %q", label, k, got, ok, w)
		}
	}
	if strings.Contains(st["boot_reason_history"], "\n") {
		t.Errorf("%s: boot_reason_history holds a newline: %q", label, st["boot_reason_history"])
	}
}

func TestBootReasonCarriesTheThreeProperties(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, frankelBootProps)
	r := buildIssueReport("brprofile1294a", false, "", nil, nil)
	wantFrankelBootReason(t, "session scope", r.Status)
}

func TestBootReasonGateScopeCarriesThem(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, frankelBootProps)
	wantFrankelBootReason(t, "gate scope, no name", buildIssueReport("", true, "", nil, nil).Status)
	wantFrankelBootReason(t, "gate scope, a name", buildIssueReport("brprofile1294b", true, "", nil, nil).Status)
}

func TestBootReasonUnreadWhenRefused(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, map[string]string{})
	for _, deviceScope := range []bool{false, true} {
		st := buildIssueReport("brprofile1294c", deviceScope, "", nil, nil).Status
		for _, k := range bootReasonKeys {
			if got := st[k]; got != "unread" {
				t.Errorf("deviceScope=%v: status[%q] = %q, want unread (a refused read)", deviceScope, k, got)
			}
		}
	}
}

func TestBootReasonUnreadWhenEmpty(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, map[string]string{
		"ro.boot.bootreason":              "",
		"sys.boot.reason.last":            "\n",
		"persist.sys.boot.reason.history": "  \n\n",
	})
	for _, deviceScope := range []bool{false, true} {
		st := buildIssueReport("brprofile1294d", deviceScope, "", nil, nil).Status
		for _, k := range bootReasonKeys {
			if got := st[k]; got != "unread" {
				t.Errorf("deviceScope=%v: status[%q] = %q, want unread (an empty read is never \"no reboot\")", deviceScope, k, got)
			}
		}
	}
}

func TestBootReasonHistoryCapped(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	var b strings.Builder
	for i := 0; i < 200; i++ {
		fmt.Fprintf(&b, "reboot,userrequested_%d\n", i)
	}
	bootPropFixture(t, map[string]string{"persist.sys.boot.reason.history": b.String()})
	v := buildIssueReport("brprofile1294e", true, "", nil, nil).Status["boot_reason_history"]
	if len(v) > 512 || len(v) < 500 {
		t.Errorf("boot_reason_history is %d bytes, want 500..512 (capped at 512)", len(v))
	}
	if !strings.HasPrefix(v, "reboot,userrequested_0; reboot,userrequested_1; ") {
		t.Errorf("boot_reason_history does not start with the first lines: %.80q", v)
	}
	if !utf8.ValidString(v) {
		t.Errorf("boot_reason_history is not valid UTF-8")
	}

	// The 512-byte boundary inside a two-byte rune: the cut backs off to the rune's start.
	bootPropFixture(t, map[string]string{"persist.sys.boot.reason.history": "x" + strings.Repeat("é", 300)})
	v = buildIssueReport("brprofile1294e", true, "", nil, nil).Status["boot_reason_history"]
	if len(v) != 511 || !utf8.ValidString(v) {
		t.Errorf("multi-byte cut: %d bytes, valid UTF-8 %v; want 511 and valid", len(v), utf8.ValidString(v))
	}
}

func TestBootReasonScrubbed(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, map[string]string{
		"ro.boot.bootreason":              "reboot,brprofile1294f",
		"sys.boot.reason.last":            "reboot,brprofile1294f",
		"persist.sys.boot.reason.history": "reboot,brprofile1294f,1729814328",
	})
	for _, deviceScope := range []bool{false, true} {
		st := buildIssueReport("brprofile1294f", deviceScope, "", nil, nil).Status
		for _, k := range bootReasonKeys {
			if strings.Contains(st[k], "brprofile1294f") || !strings.Contains(st[k], "<name>") {
				t.Errorf("deviceScope=%v: status[%q] = %q, want the name scrubbed by statusValue", deviceScope, k, st[k])
			}
		}
	}
}

// TestBootReasonReadsByAbsolutePath pins the getprop path in readBootProp's source: the daemon's PATH may lack
// /system/bin, so a bare "getprop" would fail on the device and every report would say unread.
func TestBootReasonReadsByAbsolutePath(t *testing.T) {
	f, err := parser.ParseFile(token.NewFileSet(), "report_issue.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var lits []string
	found := false
	ast.Inspect(f, func(n ast.Node) bool {
		vs, ok := n.(*ast.ValueSpec)
		if !ok || len(vs.Names) != 1 || vs.Names[0].Name != "readBootProp" {
			return true
		}
		found = true
		for _, v := range vs.Values {
			ast.Inspect(v, func(m ast.Node) bool {
				if bl, ok := m.(*ast.BasicLit); ok && bl.Kind == token.STRING {
					if s, err := strconv.Unquote(bl.Value); err == nil {
						lits = append(lits, s)
					}
				}
				return true
			})
		}
		return false
	})
	if !found {
		t.Fatal("report_issue.go declares no var readBootProp")
	}
	abs := false
	for _, s := range lits {
		if s == "/system/bin/getprop" {
			abs = true
		}
		if s == "getprop" {
			t.Errorf("readBootProp runs a bare \"getprop\": the daemon's PATH may lack /system/bin")
		}
	}
	if !abs {
		t.Errorf("readBootProp does not run \"/system/bin/getprop\" (string literals: %q): the daemon's PATH may lack /system/bin", lits)
	}
}
