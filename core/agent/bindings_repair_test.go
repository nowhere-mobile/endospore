package main

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261110-02: REPAIR-BINDINGS and SET-SIM-MINE (bindings_repair.go), and the marks GET-BINDINGS lists. Every test
// drives the verbs through handleLogin as the user-0 gate, against a temporary bindings.conf, inbox and link state.

// repairGood is one good line, bound to a ref no other test file uses.
func repairGood(iccid string) string {
	return serializeLine(simBinding{SubID: 2, ICCID: iccid, Label: "L", Visibility: "open",
		Owners: []bindingOwner{{ProfileRef: "refRepairA", TelPub: "pubRepairA"}}})
}

// repairFixture is telFixture with bindings.conf holding body (none when body is ""); it returns the link clock.
func repairFixture(t *testing.T, body string) *int64 {
	t.Helper()
	useTempInbox(t)
	useTempBindings(t)
	useTempIngest(t)
	clk := useArrivalState(t)
	asGate(t)
	if body != "" {
		if err := os.WriteFile(bindingsPath, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return clk
}

func readBindingsFile(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func statBindings(t *testing.T) os.FileInfo {
	t.Helper()
	fi, err := os.Stat(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	return fi
}

// noBindingsTemp fails when a write left its temp file beside bindings.conf.
func noBindingsTemp(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(filepath.Dir(bindingsPath), ".bindings.conf.tmp")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("a temp file was left beside bindings.conf (%v)", err)
	}
}

// TestBindingsRepairAbsentFileIsCleanAndMintsNothing: with no file there is nothing to repair, and no file is minted.
func TestBindingsRepairAbsentFileIsCleanAndMintsNothing(t *testing.T) {
	repairFixture(t, "")
	if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "OK CLEAN" {
		t.Fatalf("REPAIR-BINDINGS with no file answered %q, want OK CLEAN", got)
	}
	if _, err := os.Stat(bindingsPath); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("REPAIR-BINDINGS with no file minted one (%v)", err)
	}
	noBindingsTemp(t)
}

// TestBindingsRepairCleanFileIsUntouched: a clean file, rebuilt or not, is not rewritten.
func TestBindingsRepairCleanFileIsUntouched(t *testing.T) {
	for _, body := range []string{
		"v1\n" + repairGood(iccidX) + "\n",
		"v1\n" + repairGood(iccidX) + "\n#rebuilt\n#mine|" + iccidY + "|\n",
	} {
		repairFixture(t, body)
		before := statBindings(t)
		if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "OK CLEAN" {
			t.Fatalf("REPAIR-BINDINGS of %q answered %q, want OK CLEAN", body, got)
		}
		if b := readBindingsFile(t); string(b) != body {
			t.Fatalf("REPAIR-BINDINGS changed a clean file:\nbefore %q\nafter  %q", body, b)
		}
		if !os.SameFile(before, statBindings(t)) {
			t.Fatalf("REPAIR-BINDINGS rewrote a clean file %q", body)
		}
	}
}

// TestBindingsRepairKeepsGoodLinesDropsDamaged: the repair keeps the good line and the mine record, drops both damaged
// lines, marks the file rebuilt, and raises the horizon of the SIM only a damaged line named, so an arrival on it
// stamped before the repair stays UNRESOLVED.
func TestBindingsRepairKeepsGoodLinesDropsDamaged(t *testing.T) {
	body := "v1\n" + repairGood(iccidX) + "\ngarbage\n#3|" + iccidZ + "|\n#mine|" + iccidY + "|\n"
	clk := repairFixture(t, body)
	if st := parseBindingsText(body); len(st.lines) != 1 || len(st.damaged) != 2 || len(st.mine) != 1 || st.rebuilt {
		t.Fatalf("the fixture is not one good line, two damaged lines and a mine record: %+v", st)
	}
	stampBefore := *clk - 1
	if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "OK REPAIRED 2" {
		t.Fatalf("REPAIR-BINDINGS answered %q, want OK REPAIRED 2", got)
	}
	want := "v1\n" + repairGood(iccidX) + "\n#rebuilt\n#mine|" + iccidY + "|\n"
	if b := readBindingsFile(t); string(b) != want {
		t.Fatalf("the repaired file is\n%q\nwant\n%q", b, want)
	}
	st := readBindingsState()
	if st.flawed || !st.rebuilt || len(st.damaged) != 0 || len(st.mine) != 1 || st.mine[0] != iccidY {
		t.Fatalf("the repaired file reads %+v", st)
	}
	noBindingsTemp(t)
	*clk += 1000
	var before, after lineClass
	underTelMu(func() {
		_, before = arrivalLine(-1, iccidZ, stampBefore)
		_, after = arrivalLine(-1, iccidZ, *clk)
	})
	if before != lineLinkUnknown {
		t.Errorf("an arrival on the damaged line's SIM stamped before the repair resolves as %v, want lineLinkUnknown", before)
	}
	if after != lineDamaged {
		t.Errorf("an arrival on the damaged line's SIM after the repair resolves as %v, want lineDamaged (unresolved in a rebuilt file)", after)
	}
	if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "OK CLEAN" {
		t.Fatalf("a second REPAIR-BINDINGS answered %q, want OK CLEAN", got)
	}
}

// TestBindingsRepairReplacesAnUnreadableFile: a file that cannot be read is replaced by an empty rebuilt one.
func TestBindingsRepairReplacesAnUnreadableFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	repairFixture(t, "v1\n"+repairGood(iccidX)+"\n")
	if err := os.Chmod(bindingsPath, 0); err != nil {
		t.Fatal(err)
	}
	if !readBindingsState().unreadable {
		t.Fatal("the fixture is readable")
	}
	if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "OK REPLACED" {
		t.Fatalf("REPAIR-BINDINGS of an unreadable file answered %q, want OK REPLACED", got)
	}
	if b := readBindingsFile(t); string(b) != "v1\n#rebuilt\n" {
		t.Fatalf("the replacement is %q, want %q", b, "v1\n#rebuilt\n")
	}
	if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); got != "OK\nREBUILT" {
		t.Fatalf("GET-BINDINGS after the replacement answered %q", got)
	}
}

// TestBindingsRepairWriteFaultIsErrIo: a write that fails answers ERR io and leaves the old file as it was.
func TestBindingsRepairWriteFaultIsErrIo(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes into a read-only directory")
	}
	body := "v1\n" + repairGood(iccidX) + "\ngarbage\n"
	repairFixture(t, body)
	dir := filepath.Dir(bindingsPath)
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "ERR io" {
		t.Fatalf("REPAIR-BINDINGS with a read-only directory answered %q, want ERR io", got)
	}
	if b := readBindingsFile(t); string(b) != body {
		t.Fatalf("a failed repair changed the file to %q", b)
	}
}

// TestBindingsRepairDirectoryAtThePathIsErrIo: a directory at bindingsPath (TestAnUnreadableFileIsRefused's fixture)
// reads as unreadable and cannot be replaced, so the repair answers ERR io and the directory stays. Runs as root too.
func TestBindingsRepairDirectoryAtThePathIsErrIo(t *testing.T) {
	repairFixture(t, "")
	if err := os.Mkdir(bindingsPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "ERR io" {
		t.Fatalf("REPAIR-BINDINGS with a directory at the path answered %q, want ERR io", got)
	}
	if fi, err := os.Stat(bindingsPath); err != nil || !fi.IsDir() {
		t.Fatalf("the directory at the path did not stay (%v)", err)
	}
	noBindingsTemp(t)
}

// TestBindingsRepairSetSimMineRoundTrip: a SIM of a rebuilt file is marked mine, listed, marked again (UNCHANGED, also
// in its padded spelling, the same SIM), and unmarked.
func TestBindingsRepairSetSimMineRoundTrip(t *testing.T) {
	repairFixture(t, "v1\n"+repairGood(iccidX)+"\n#rebuilt\n")
	if got := driveLogin(t, t.TempDir(), "SET-SIM-MINE\n"+iccidY+"\n1\n"); got != "OK" {
		t.Fatalf("SET-SIM-MINE answered %q, want OK", got)
	}
	want := "OK\n2|" + iccidX + "|" + b64s("L") + "|open|1\nREBUILT\nMINE " + iccidY
	if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); got != want {
		t.Fatalf("GET-BINDINGS answered\n%q\nwant\n%q", got, want)
	}
	before := statBindings(t)
	for _, ic := range []string{iccidY, iccidY + "F"} {
		if got := driveLogin(t, t.TempDir(), "SET-SIM-MINE\n"+ic+"\n1\n"); got != "OK UNCHANGED" {
			t.Fatalf("SET-SIM-MINE %q again answered %q, want OK UNCHANGED", ic, got)
		}
	}
	if !os.SameFile(before, statBindings(t)) {
		t.Fatal("an UNCHANGED SET-SIM-MINE rewrote the file")
	}
	if got := driveLogin(t, t.TempDir(), "SET-SIM-MINE\n"+iccidY+"F\n0\n"); got != "OK" {
		t.Fatalf("SET-SIM-MINE 0 answered %q, want OK", got)
	}
	if st := readBindingsState(); len(st.mine) != 0 || !st.rebuilt || st.flawed || len(st.lines) != 1 {
		t.Fatalf("after SET-SIM-MINE 0 the file reads %+v", st)
	}
}

// TestBindingsRepairSetSimMineRefusals: a flawed file asks for the repair first, a file that is not rebuilt needs no
// mark, an unreadable one is damaged, and a malformed request is ERR; none of them writes.
func TestBindingsRepairSetSimMineRefusals(t *testing.T) {
	req := "SET-SIM-MINE\n" + iccidY + "\n1\n"
	for _, c := range []struct{ body, req, want string }{
		{"v1\n" + repairGood(iccidX) + "\n2|garbage\n#rebuilt\n", req, "ERR repair"},
		{"v1\n2|garbage\n", req, "ERR repair"},
		{"v1\n" + repairGood(iccidX) + "\n", req, "OK NOTREBUILT"},
		{"v1\n#rebuilt\n", "SET-SIM-MINE\n89|1\n1\n", "ERR"},
		{"v1\n#rebuilt\n", "SET-SIM-MINE\n" + iccidY + "\n2\n", "ERR"},
		{"v1\n#rebuilt\n", "SET-SIM-MINE\n\n1\n", "ERR"},
		{"v1\n#rebuilt\n", "SET-SIM-MINE\n" + iccidY[:6] + "\r" + iccidY[6:] + "\n1\n", "ERR"},
		{"v1\n#rebuilt\n", "SET-SIM-MINE\n" + iccidY + "\r\r\n1\n", "ERR"},
		{"v1\n#rebuilt\n", "SET-SIM-MINE\n" + iccidY + "\r\n1\n", "ERR"},
		{"v1\n#rebuilt\n", "SET-SIM-MINE\n" + iccidY + "\n1\r\n", "ERR"},
	} {
		repairFixture(t, c.body)
		before := statBindings(t)
		if got := driveLogin(t, t.TempDir(), c.req); got != c.want {
			t.Fatalf("%q on %q answered %q, want %q", c.req, c.body, got, c.want)
		}
		if b := readBindingsFile(t); string(b) != c.body || !os.SameFile(before, statBindings(t)) {
			t.Fatalf("%q on %q wrote the file: %q", c.req, c.body, b)
		}
	}
	repairFixture(t, "")
	if err := os.Mkdir(bindingsPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), req); got != "ERR damaged" {
		t.Fatalf("SET-SIM-MINE with a directory at the path answered %q, want ERR damaged", got)
	}
	if fi, err := os.Stat(bindingsPath); err != nil || !fi.IsDir() {
		t.Fatalf("the directory at the path did not stay (%v)", err)
	}
}

// TestBindingsRepairSetSimMineRaisesTheHorizon: a mark changes the inbox an arrival on the SIM resolves to, so only an
// arrival from the mark on is the device owner's; one stamped while the SIM was unresolved stays UNRESOLVED.
func TestBindingsRepairSetSimMineRaisesTheHorizon(t *testing.T) {
	clk := repairFixture(t, "v1\n#rebuilt\n")
	marked := *clk
	if got := driveLogin(t, t.TempDir(), "SET-SIM-MINE\n"+iccidY+"\n1\n"); got != "OK" {
		t.Fatalf("SET-SIM-MINE answered %q, want OK", got)
	}
	*clk += 1000
	var before, after lineClass
	underTelMu(func() {
		_, before = arrivalLine(-1, iccidY, marked-1)
		_, after = arrivalLine(-1, iccidY, marked+500)
	})
	if before != lineLinkUnknown {
		t.Errorf("an arrival stamped before the mark resolves as %v, want lineLinkUnknown", before)
	}
	if after != lineUnbound {
		t.Errorf("an arrival stamped after the mark resolves as %v, want lineUnbound (the device owner's line)", after)
	}
}

// TestBindingsRepairGetBindingsListsTheMarks: GET-BINDINGS lists REBUILT and the mine records after the SIM lines and
// before DAMAGED, and a rebuilt file with no good line answers them, not NONE.
func TestBindingsRepairGetBindingsListsTheMarks(t *testing.T) {
	for _, c := range []struct{ body, want string }{
		{"v1\n#rebuilt\n#mine|" + iccidY + "|\n", "OK\nREBUILT\nMINE " + iccidY},
		{"v1\n#rebuilt\n", "OK\nREBUILT"},
		{"v1\n#rebuilt\n#mine|" + iccidY + "|\n#3|" + iccidZ + "|\n", "OK\nREBUILT\nMINE " + iccidY + "\nDAMAGED"},
		{"v1\n" + repairGood(iccidX) + "\n#rebuilt\n#mine|" + iccidY + "|\n#3|" + iccidZ + "|\n",
			"OK\n2|" + iccidX + "|" + b64s("L") + "|open|1\nREBUILT\nMINE " + iccidY + "\nDAMAGED"},
		{"v1\n" + repairGood(iccidX) + "\n", "OK\n2|" + iccidX + "|" + b64s("L") + "|open|1"},
		{"v1\n", "NONE"},
	} {
		repairFixture(t, c.body)
		if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); got != c.want {
			t.Errorf("GET-BINDINGS of %q answered\n%q\nwant\n%q", c.body, got, c.want)
		}
	}
}

// TestBindingsRepairVerbsAnswerBusyWhileSessionMuIsHeld: both verbs write bindings.conf, so a held sessionMu answers
// BUSY at once and writes nothing -- never a write queued behind a login that lands after the owner saw a failure.
func TestBindingsRepairVerbsAnswerBusyWhileSessionMuIsHeld(t *testing.T) {
	for _, c := range []struct{ body, req string }{
		{"v1\n" + repairGood(iccidX) + "\ngarbage\n", "REPAIR-BINDINGS\n"},
		{"v1\n" + repairGood(iccidX) + "\n#rebuilt\n", "SET-SIM-MINE\n" + iccidY + "\n1\n"},
	} {
		repairFixture(t, c.body)
		func() {
			sessionMu.Lock()
			defer sessionMu.Unlock()
			if got := replyWhileHeld(t, 5*time.Second, c.req, c.req); got != "BUSY" {
				t.Fatalf("%q while sessionMu is held replied %q, want BUSY", c.req, got)
			}
		}()
		if b := readBindingsFile(t); !bytes.Equal(b, []byte(c.body)) {
			t.Fatalf("a BUSY %q changed bindings.conf to %q", c.req, b)
		}
		if got := driveLogin(t, t.TempDir(), c.req); !strings.HasPrefix(got, "OK") {
			t.Fatalf("%q with sessionMu free answered %q", c.req, got)
		}
	}
}
