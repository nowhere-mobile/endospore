package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"unicode/utf8"
)

// NWP-20261117-28: an issue report carries Android's own boot reason (boot_reason, boot_reason_last,
// boot_reason_history) at every scope, read by /system/bin/getprop; "unread" when the read is empty or refused.

var bootReasonKeys = []string{"boot_reason", "boot_reason_last", "boot_reason_history"}

// bootPropFixture answers readBootProp from props; a prop not in the map fails like a refused read. It also points the
// file sources at an empty temp dir (bootSourcesFixture), so no test reads the host's /proc or /dev/__properties__.
func bootPropFixture(t *testing.T, props map[string]string) {
	t.Helper()
	bootSourcesFixture(t)
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

// prodReadBootFile and prodOpenPropFile are the package's own readers, captured before any test replaces them.
var prodReadBootFile, prodOpenPropFile = readBootFile, openPropFile

// bootSourcesFixture points bootconfigPath, cmdlinePath and propAreaDir at an empty temp dir: the two files do not
// exist (absent) and the property dir is empty (propfiles=none). It puts back the package's own readers, so a reader
// an earlier step replaced does not carry over. Cleanups run LIFO, so the first call's cleanup restores the originals.
func bootSourcesFixture(t *testing.T) string {
	t.Helper()
	oldBC, oldCL, oldPA, oldRead, oldOpen := bootconfigPath, cmdlinePath, propAreaDir, readBootFile, openPropFile
	t.Cleanup(func() {
		bootconfigPath, cmdlinePath, propAreaDir, readBootFile, openPropFile = oldBC, oldCL, oldPA, oldRead, oldOpen
	})
	d := t.TempDir()
	bootconfigPath = filepath.Join(d, "bootconfig")
	cmdlinePath = filepath.Join(d, "cmdline")
	propAreaDir = filepath.Join(d, "__properties__")
	readBootFile, openPropFile = prodReadBootFile, prodOpenPropFile
	if err := os.Mkdir(propAreaDir, 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

// writeBootSource writes content to *path (bootconfigPath or cmdlinePath, already inside the fixture's temp dir).
func writeBootSource(t *testing.T, path *string, content string) {
	t.Helper()
	if err := os.WriteFile(*path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
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

// NWP-20261204-13: getprop in u:r:nowhere:s0 answered empty on user builds (NW-132f, NW-81dd). boot_reason falls back
// to androidboot.bootreason from /proc/bootconfig, then /proc/cmdline; boot_reason_src names the source and
// boot_reason_read says per source why a read did not answer.

func wantBootStatus(t *testing.T, label string, st map[string]string, want map[string]string) {
	t.Helper()
	for k, w := range want {
		if got, ok := st[k]; !ok || got != w {
			t.Errorf("%s: status[%q] = %q (present %v), want %q", label, k, got, ok, w)
		}
	}
}

func TestBootReasonFallsBackToBootconfig(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, map[string]string{})
	writeBootSource(t, &bootconfigPath, "androidboot.serialno = \"SERIAL123\"\nandroidboot.bootreason = \"reset,warm,ecc_ras_error\"\nandroidboot.hardware = \"husky\"\n")
	want := map[string]string{
		"boot_reason":         "reset,warm,ecc_ras_error",
		"boot_reason_src":     "bootconfig",
		"boot_reason_last":    "unread",
		"boot_reason_history": "unread",
	}
	wantBootStatus(t, "gate scope", buildIssueReport("", true, "", nil, nil).Status, want)
	wantBootStatus(t, "session scope", buildIssueReport("brprofile1839a", false, "", nil, nil).Status, want)
}

func TestBootReasonFallsBackToCmdlineOnlyTheReason(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, map[string]string{})
	writeBootSource(t, &cmdlinePath, "console=x androidboot.serialno=SERIAL123 androidboot.bootreason=reboot,ota\n")
	for _, deviceScope := range []bool{false, true} {
		r := buildIssueReport("brprofile1839b", deviceScope, "", nil, nil)
		label := fmt.Sprintf("deviceScope=%v", deviceScope)
		wantBootStatus(t, label, r.Status, map[string]string{
			"boot_reason":     "reboot,ota",
			"boot_reason_src": "cmdline",
		})
		b, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "SERIAL123") {
			t.Errorf("%s: the report carries the serial number from /proc/cmdline", label)
		}
	}
}

func TestBootReasonGetpropWinsOverFiles(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, frankelBootProps)
	writeBootSource(t, &bootconfigPath, "androidboot.bootreason = \"reboot,bootconfig\"\n")
	writeBootSource(t, &cmdlinePath, "androidboot.bootreason=reboot,cmdline\n")
	for _, deviceScope := range []bool{false, true} {
		st := buildIssueReport("brprofile1839c", deviceScope, "", nil, nil).Status
		label := fmt.Sprintf("deviceScope=%v", deviceScope)
		wantFrankelBootReason(t, label, st)
		wantBootStatus(t, label, st, map[string]string{
			"boot_reason_src":  "getprop",
			"boot_reason_read": "getprop=ok,ok,ok; bootconfig=found; cmdline=found; propfiles=none",
		})
	}
}

func TestBootReasonMalformedValueNotTaken(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	long := strings.Repeat("a", 129)
	rows := []struct {
		src, content string
	}{
		{"bootconfig", "androidboot.bootreason = \"a b\"\n"},
		{"bootconfig", "androidboot.bootreason = \"" + long + "\"\n"},
		{"bootconfig", "androidboot.bootreason = \"x;rm\"\n"},
		{"cmdline", "androidboot.bootreason=" + long + "\n"},
		{"cmdline", "androidboot.bootreason=x;rm\n"},
		{"cmdline", "console=x androidboot.bootreason=\n"},
	}
	for i, row := range rows {
		bootPropFixture(t, map[string]string{})
		path := &bootconfigPath
		if row.src == "cmdline" {
			path = &cmdlinePath
		}
		writeBootSource(t, path, row.content)
		st := buildIssueReport("brprofile1839d", true, "", nil, nil).Status
		label := fmt.Sprintf("row %d (%s %.40q)", i, row.src, row.content)
		wantBootStatus(t, label, st, map[string]string{"boot_reason": "unread", "boot_reason_src": "none"})
		if !strings.Contains(st["boot_reason_read"], row.src+"=nokey") {
			t.Errorf("%s: boot_reason_read = %q, want %s=nokey", label, st["boot_reason_read"], row.src)
		}
	}

	// The parsers, directly.
	v128 := strings.Repeat("b", 128)
	if v, ok := bootReasonFromBootconfig("androidboot.bootreason = \"" + v128 + "\""); !ok || v != v128 {
		t.Errorf("bootconfig: a 128-byte value = %q, %v; want it taken", v, ok)
	}
	if v, ok := bootReasonFromBootconfig("androidboot.bootreason = \"" + long + "\""); ok {
		t.Errorf("bootconfig: a 129-byte value taken: %q", v)
	}
	if v, ok := bootReasonFromCmdline("androidboot.bootreason=" + v128); !ok || v != v128 {
		t.Errorf("cmdline: a 128-byte value = %q, %v; want it taken", v, ok)
	}
	if v, ok := bootReasonFromCmdline("androidboot.bootreason=" + long); ok {
		t.Errorf("cmdline: a 129-byte value taken: %q", v)
	}
	// The cmdline is whitespace-separated: "a b" is the token androidboot.bootreason=a, then b. Intended.
	if v, ok := bootReasonFromCmdline("androidboot.bootreason=a b"); !ok || v != "a" {
		t.Errorf("cmdline \"androidboot.bootreason=a b\" = %q, %v; want \"a\", true", v, ok)
	}
	for _, in := range []string{"androidboot.bootreason = \"reboot\"", "androidboot.bootreason = reboot", "  androidboot.bootreason=reboot  "} {
		if v, ok := bootReasonFromBootconfig("x = \"y\"\n" + in + "\n"); !ok || v != "reboot" {
			t.Errorf("bootconfig %q = %q, %v; want \"reboot\", true", in, v, ok)
		}
	}
	// The key must be exactly androidboot.bootreason.
	if v, ok := bootReasonFromBootconfig("androidboot.bootreason_x = \"reboot\""); ok {
		t.Errorf("bootconfig: another key taken: %q", v)
	}
	if v, ok := bootReasonFromCmdline("xandroidboot.bootreason=reboot"); ok {
		t.Errorf("cmdline: another key taken: %q", v)
	}
}

// eacces is the error a refused open returns, without a chmod, so the case also runs as root.
func eacces(p string) error { return &fs.PathError{Op: "open", Path: p, Err: syscall.EACCES} }

// propAreaFixture makes the named empty files in propAreaDir.
func propAreaFixture(t *testing.T, names ...string) {
	t.Helper()
	for _, n := range names {
		if err := os.WriteFile(filepath.Join(propAreaDir, n), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestBootReasonReadSaysWhyPerSource(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	bootPropFixture(t, map[string]string{"ro.boot.bootreason": "", "sys.boot.reason.last": "\n", "persist.sys.boot.reason.history": ""})
	propAreaFixture(t, "u:object_r:bootloader_boot_reason_prop:s0", "u:object_r:last_boot_reason_prop:s0", "u:object_r:default_prop:s0")
	read, open := readBootFile, openPropFile
	readBootFile = func(p string) ([]byte, error) {
		if p == bootconfigPath {
			return nil, eacces(p)
		}
		return read(p)
	}
	openPropFile = func(p string) error {
		if filepath.Base(p) == "u:object_r:bootloader_boot_reason_prop:s0" {
			return eacces(p)
		}
		return open(p)
	}
	want := "getprop=empty,empty,empty; bootconfig=denied; cmdline=absent; propfiles=bootloader_boot_reason_prop:denied,last_boot_reason_prop:ok"
	for _, deviceScope := range []bool{false, true} {
		st := buildIssueReport("brprofile1839e", deviceScope, "", nil, nil).Status
		wantBootStatus(t, fmt.Sprintf("deviceScope=%v", deviceScope), st, map[string]string{
			"boot_reason_read": want, "boot_reason": "unread", "boot_reason_src": "none",
		})
	}

	// getprop errors -> failed; the property dir does not exist -> absent.
	bootPropFixture(t, map[string]string{"sys.boot.reason.last": "reboot\n"})
	propAreaDir = filepath.Join(t.TempDir(), "missing")
	st := buildIssueReport("brprofile1839e", true, "", nil, nil).Status
	wantBootStatus(t, "getprop failed, no prop dir", st, map[string]string{
		"boot_reason_read": "getprop=failed,ok,failed; bootconfig=absent; cmdline=absent; propfiles=absent",
	})
}

var reBootReasonRead = regexp.MustCompile(`^getprop=(ok|empty|failed),(ok|empty|failed),(ok|empty|failed); bootconfig=(found|nokey|denied|absent|error); cmdline=(found|nokey|denied|absent|error); propfiles=(denied|absent|error|none|[A-Za-z0-9_.\-]+:(ok|denied|error)(,[A-Za-z0-9_.\-]+:(ok|denied|error))*)$`)

func TestBootReasonReadIsFixedVocabulary(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	scenarios := map[string]func(t *testing.T){
		"bootconfig found": func(t *testing.T) {
			writeBootSource(t, &bootconfigPath, "androidboot.bootreason = \"reboot\"\n")
		},
		"cmdline found": func(t *testing.T) {
			writeBootSource(t, &cmdlinePath, "console=x androidboot.serialno=SERIAL123 androidboot.bootreason=reboot,ota\n")
		},
		"malformed": func(t *testing.T) {
			writeBootSource(t, &bootconfigPath, "androidboot.bootreason = \"x;rm\"\n")
			writeBootSource(t, &cmdlinePath, "garbage /secret/dir\n")
		},
		"EIO with a path": func(t *testing.T) {
			readBootFile = func(p string) ([]byte, error) {
				return nil, &fs.PathError{Op: "read", Path: "/secret/dir", Err: syscall.EIO}
			}
			openPropFile = func(p string) error { return &fs.PathError{Op: "open", Path: "/secret/dir", Err: syscall.EIO} }
			propAreaFixture(t, "u:object_r:bootloader_boot_reason_prop:s0", "u:object_r:a,b:c_boot_reason:s0")
		},
		"a plain error": func(t *testing.T) {
			readBootFile = func(p string) ([]byte, error) { return nil, errors.New("permission denied /secret/dir") }
			openPropFile = func(p string) error { return eacces(p) }
			propAreaFixture(t, "u:object_r:last_boot_reason_prop:s0")
		},
		"prop dir absent, files denied": func(t *testing.T) {
			readBootFile = func(p string) ([]byte, error) { return nil, eacces(p) }
			propAreaDir = filepath.Join(t.TempDir(), "missing")
		},
	}
	for name, setup := range scenarios {
		for _, props := range []map[string]string{{}, frankelBootProps, {"ro.boot.bootreason": ""}} {
			bootPropFixture(t, props)
			setup(t)
			for _, deviceScope := range []bool{false, true} {
				st := buildIssueReport("brprofile1839f", deviceScope, "", nil, nil).Status
				got := st["boot_reason_read"]
				if !reBootReasonRead.MatchString(got) {
					t.Errorf("%s: boot_reason_read = %q, not the fixed vocabulary", name, got)
				}
				for _, bad := range []string{"/", "errno", "input/output", "permission", "secret"} {
					if strings.Contains(got, bad) {
						t.Errorf("%s: boot_reason_read = %q holds %q", name, got, bad)
					}
				}
				switch src := st["boot_reason_src"]; src {
				case "getprop", "bootconfig", "cmdline", "none":
				default:
					t.Errorf("%s: boot_reason_src = %q, not getprop|bootconfig|cmdline|none", name, src)
				}
			}
		}
	}
}
