package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261106-07 (Q065): the failed-sign-in record the gate files with SIGNIN-SHOWN and a gate report carries.

// sfDest is a fresh dest as the gate, with no in-run facts left over from another test (they are package globals).
func sfDest(t *testing.T) string {
	t.Helper()
	asGate(t)
	dest := t.TempDir()
	dropSigninFail(dest)
	t.Cleanup(func() { dropSigninFail(dest) })
	return dest
}

func sfHeld() bool {
	signinFailMu.Lock()
	defer signinFailMu.Unlock()
	return inRunHeld
}

func sfMarker(t *testing.T, dest string) map[string]string {
	t.Helper()
	m := signinFailMarker(dest, time.Now())
	if m == nil {
		t.Fatal("no record was kept")
	}
	if age, err := strconv.Atoi(m["last_signin_failure_age_s"]); err != nil || age < 0 {
		t.Errorf("age %q is not a whole number of seconds", m["last_signin_failure_age_s"])
	}
	return m
}

func TestSigninShown_SlowCarriesNoFacts(t *testing.T) {
	dest := sfDest(t)
	noteInRun("in", 3, 41)
	if got := driveLogin(t, dest, "SIGNIN-SHOWN\nslow\n"); got != "OK" {
		t.Fatalf("reply %q, want OK", got)
	}
	m := sfMarker(t, dest)
	if m["last_signin_failure"] != "slow" {
		t.Errorf("code %q, want slow", m["last_signin_failure"])
	}
	for _, k := range []string{"last_signin_failure_op", "last_signin_failure_stall_s", "last_signin_failure_hold_s"} {
		if _, ok := m[k]; ok {
			t.Errorf("a non-load code carries %s", k)
		}
	}
}

func TestSigninShown_LoadCarriesInRunFacts(t *testing.T) {
	dest := sfDest(t)
	noteInRun("in", 3, 41)
	if got := driveLogin(t, dest, "SIGNIN-SHOWN\nload\n"); got != "OK" {
		t.Fatalf("reply %q, want OK", got)
	}
	m := sfMarker(t, dest)
	if m["last_signin_failure"] != "load" || m["last_signin_failure_op"] != "in" ||
		m["last_signin_failure_stall_s"] != "3" || m["last_signin_failure_hold_s"] != "41" {
		t.Errorf("record %v, want load / in / 3 / 41", m)
	}
}

func TestSigninShown_LoadWithoutFacts(t *testing.T) {
	dest := sfDest(t)
	if got := driveLogin(t, dest, "SIGNIN-SHOWN\nload\n"); got != "OK" {
		t.Fatalf("reply %q, want OK", got)
	}
	m := sfMarker(t, dest)
	if len(m) != 2 || m["last_signin_failure"] != "load" {
		t.Errorf("record %v, want the code and age only", m)
	}
}

func TestSigninShown_RefusesOutsideTheVocabulary(t *testing.T) {
	dest := sfDest(t)
	for _, req := range []string{"blank\n", "x\n", "\n", "Slow\n", "slow \n", "NEEDKEY\n"} {
		if got := driveLogin(t, dest, "SIGNIN-SHOWN\n"+req); got != "ERR-ARGS" {
			t.Errorf("%q replied %q, want ERR-ARGS", req, got)
		}
		if _, err := os.Stat(filepath.Join(dest, signinFailFile)); err == nil {
			t.Fatalf("%q left a record", req)
		}
	}
	for _, code := range []string{"nostore", "unreachable", "slow", "busy", "phone-storage", "phone", "load"} {
		if got := driveLogin(t, dest, "SIGNIN-SHOWN\n"+code+"\n"); got != "OK" {
			t.Errorf("%s replied %q, want OK", code, got)
		}
		if m := signinFailMarker(dest, time.Now()); m["last_signin_failure"] != code {
			t.Errorf("%s was recorded as %v", code, m)
		}
	}
	// A line cut off before its newline (the gate gone mid-send) is no code either.
	dropSigninFail(dest)
	if got := osrReply(func(c net.Conn) { handleSigninShown(c, bufio.NewReader(strings.NewReader("slow")), dest) }); got != "ERR-ARGS" {
		t.Errorf("an unterminated line replied %q, want ERR-ARGS", got)
	}
	if _, err := os.Stat(filepath.Join(dest, signinFailFile)); err == nil {
		t.Error("an unterminated line left a record")
	}
	if err := recordSigninShown(dest, "blank", time.Now()); err == nil {
		t.Error("recordSigninShown accepted blank")
	}
}

func TestSigninShown_IsGateOnly(t *testing.T) {
	if !gateOnlyCmd("SIGNIN-SHOWN") {
		t.Error("SIGNIN-SHOWN is not in gateOnlyCmd")
	}
	if !slices.Contains(gateOnlyVerbs, "SIGNIN-SHOWN") {
		t.Error("SIGNIN-SHOWN is not in gateOnlyVerbs")
	}
	dest := sfDest(t)
	asCaller(t, 1010123, 10123) // a roamed session's chooser
	if got := driveLogin(t, dest, "SIGNIN-SHOWN\nslow\n"); got != "DENIED" {
		t.Errorf("a roamed caller got %q, want DENIED", got)
	}
	if _, err := os.Stat(filepath.Join(dest, signinFailFile)); err == nil {
		t.Error("a roamed caller planted a record")
	}
}

func TestSigninShown_AnswersWhileSessionMuIsHeld(t *testing.T) {
	sfDest(t)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if got := replyWhileHeld(t, 5*time.Second, "SIGNIN-SHOWN\nslow\n", "SIGNIN-SHOWN"); got != "OK" {
		t.Errorf("reply %q, want OK", got)
	}
}

func TestSigninFail_EveryAttemptDropsIt(t *testing.T) {
	cases := []struct {
		name string
		run  func(dest string) string
	}{
		{"handleRoamIn", func(d string) string { return osrReply(func(c net.Conn) { handleRoamIn(c, d, "", "", "", "", "") }) }},
		{"handleRoamInOffline", func(d string) string { return osrReply(func(c net.Conn) { handleRoamInOffline(c, d, "", "", "") }) }},
		{"handleCreate", func(d string) string { return osrReply(func(c net.Conn) { handleCreate(c, d, "", "") }) }},
		{"handleCreateCode", func(d string) string { return osrReply(func(c net.Conn) { handleCreateCode(c, d, "", "", "") }) }},
		{"handleResume", func(d string) string { return osrReply(func(c net.Conn) { handleResume(c, d, "x") }) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dest := sfDest(t)
			path := filepath.Join(dest, signinFailFile)
			if err := os.WriteFile(path, []byte("slow\t1\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path+".tmp", []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
			noteInRun("in", 1, 2)
			if got := tc.run(dest); got == "NO-REPLY" {
				t.Fatalf("%s did not return", tc.name)
			}
			for _, p := range []string{path, path + ".tmp"} {
				if _, err := os.Stat(p); err == nil {
					t.Errorf("%s left %s", tc.name, filepath.Base(p))
				}
			}
			if sfHeld() {
				t.Errorf("%s left the in-run facts", tc.name)
			}
		})
	}
}

// The drop runs before the OTA refusal, so an ERR-OTA attempt drops the record too.
func TestSigninFail_DropPrecedesOtaRefusal(t *testing.T) {
	cases := []struct {
		name string
		run  func(dest string) string
	}{
		{"handleRoamIn", func(d string) string {
			return osrReply(func(c net.Conn) { handleRoamIn(c, d, "n", "p", "12", "", "") })
		}},
		{"handleRoamInOffline", func(d string) string { return osrReply(func(c net.Conn) { handleRoamInOffline(c, d, "n", "p", "12") }) }},
		{"handleCreate", func(d string) string { return osrReply(func(c net.Conn) { handleCreate(c, d, "n", "p") }) }},
		{"handleCreateCode", func(d string) string { return osrReply(func(c net.Conn) { handleCreateCode(c, d, "n", "p", "code") }) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			osrStore(t)
			dest := sfDest(t)
			if err := os.WriteFile(filepath.Join(dest, "ota.res"), []byte("APPLYING\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(dest, signinFailFile)
			if err := os.WriteFile(path, []byte("slow\t1\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path+".tmp", []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
			noteInRun("in", 1, 2)
			if got := tc.run(dest); got != "ERR-OTA" {
				t.Fatalf("%s replied %q, want ERR-OTA", tc.name, got)
			}
			for _, p := range []string{path, path + ".tmp"} {
				if _, err := os.Stat(p); err == nil {
					t.Errorf("an ERR-OTA %s left %s", tc.name, filepath.Base(p))
				}
			}
			if sfHeld() {
				t.Errorf("an ERR-OTA %s left the in-run facts", tc.name)
			}
		})
	}
}

var sfLine = regexp.MustCompile(`^[a-z-]+\t[0-9]+(\t[a-z]+\t[0-9]+\t[0-9]+)?$`)

func TestSigninFail_FileGrammar(t *testing.T) {
	dest := sfDest(t)
	noteInRun("in", 3, 41)
	for _, code := range []string{"slow", "phone-storage", "load"} {
		if err := recordSigninShown(dest, code, time.Now()); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(filepath.Join(dest, signinFailFile))
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		if !strings.HasSuffix(s, "\n") || strings.Count(s, "\n") != 1 || !sfLine.MatchString(strings.TrimSuffix(s, "\n")) {
			t.Errorf("%s: file %q is not one record line", code, s)
		}
		if fi, _ := os.Stat(filepath.Join(dest, signinFailFile)); fi == nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("%s: file is not 0600", code)
		}
	}
}

func TestSigninFail_GateReportCarriesIt(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	dest := sfDest(t)
	noteInRun("in", 3, 41)
	if err := recordSigninShown(dest, "load", time.Now()); err != nil {
		t.Fatal(err)
	}
	rep := anrPreview(t, dest, `{"preview":true,"gate":true,"status":{"last_signin_failure":"forged","last_signin_failure_op":"forged"}}`)
	want := map[string]string{"last_signin_failure": "load", "last_signin_failure_op": "in",
		"last_signin_failure_stall_s": "3", "last_signin_failure_hold_s": "41"}
	for k, v := range want {
		if rep.Status[k] != v {
			t.Errorf("gate report %s = %q, want %q", k, rep.Status[k], v)
		}
	}
	if _, err := strconv.Atoi(rep.Status["last_signin_failure_age_s"]); err != nil {
		t.Errorf("gate report age %q", rep.Status["last_signin_failure_age_s"])
	}
	// No record: a chooser-sent key does not stand in for it.
	dropSigninFail(dest)
	rep = anrPreview(t, dest, `{"preview":true,"gate":true,"status":{"last_signin_failure":"forged"}}`)
	if v, ok := rep.Status["last_signin_failure"]; ok {
		t.Errorf("no record, yet the report says %q", v)
	}

	st := map[string]string{}
	if err := recordSigninShown(dest, "slow", time.Now()); err != nil {
		t.Fatal(err)
	}
	mergeSigninFail(st, dest, false, time.Now())
	if len(st) != 0 {
		t.Errorf("session scope merged %v", st)
	}
	// A session-scope preview asks the RO worker lane for uiderrors (the report_uiderrors_test.go precedent):
	// unstubbed it waits uiderrorsWait and leaves a goroutine holding that lane.
	origWorker := uiderrorsWorker
	uiderrorsWorker = func(d, n, u string) string { return "ERR-STUB not asked in this test" }
	t.Cleanup(func() { uiderrorsWorker = origWorker })
	if err := markRoamSession(dest, "sfreportname", "sfreportpass", "12", ""); err != nil {
		t.Fatal(err)
	}
	rep = anrPreview(t, dest, `{"preview":true}`)
	for k := range rep.Status {
		if strings.HasPrefix(k, "last_signin_failure") {
			t.Errorf("a session report carries %s", k)
		}
	}

	path := filepath.Join(dest, signinFailFile)
	os.WriteFile(path, []byte("bogus\t1\n"), 0o600)
	if m := signinFailMarker(dest, time.Now()); !strings.HasPrefix(m["last_signin_failure"], "unparseable: ") || len(m) != 1 {
		t.Errorf("malformed file read as %v", m)
	}
	os.Remove(path)
	os.Mkdir(path, 0o700)
	if m := signinFailMarker(dest, time.Now()); !strings.HasPrefix(m["last_signin_failure"], "unreadable: ") {
		t.Errorf("unreadable file read as %v", m)
	}
}

func TestInRunFacts(t *testing.T) {
	t0 := time.Unix(1000, 0)
	for _, tc := range []struct {
		name            string
		last, now       time.Time
		wantStall, want int64
	}{
		{"never changed", time.Time{}, t0.Add(41 * time.Second), 41, 41},
		{"changed before t0", t0.Add(-5 * time.Second), t0.Add(41 * time.Second), 41, 41},
		{"changed after t0", t0.Add(38 * time.Second), t0.Add(41 * time.Second), 3, 41},
		{"now before t0", time.Time{}, t0.Add(-time.Second), 0, 0},
		{"truncates", t0.Add(38 * time.Second), t0.Add(41900 * time.Millisecond), 3, 41},
	} {
		stall, hold := inRunFacts(t0, tc.last, tc.now)
		if stall != tc.wantStall || hold != tc.want {
			t.Errorf("%s: stall %d hold %d, want %d %d", tc.name, stall, hold, tc.wantStall, tc.want)
		}
	}
}
