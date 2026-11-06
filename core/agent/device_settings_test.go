package main

// NWP-20261021-07: the automatic-install switch, the install time and the caller's-number switch must answer outside
// sessionMu and say ERR when the setting was not saved (backlog row "P1: every user-facing daemon read/write that
// times out fails SILENTLY, and the silence is indistinguishable from a real answer"). Every path is under t.TempDir().

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// useTempDeviceFlags points the three device-level setting files at fresh temp paths.
func useTempDeviceFlags(t *testing.T) (auto, otime, notice string) {
	t.Helper()
	oldAuto, oldTime := otaAutoPath, otaTimePath
	dir := t.TempDir()
	otaAutoPath = filepath.Join(dir, "ota-auto")
	otaTimePath = filepath.Join(dir, "ota-time")
	t.Cleanup(func() { otaAutoPath, otaTimePath = oldAuto, oldTime })
	return otaAutoPath, otaTimePath, useTempNoticeNumber(t)
}

type deviceSetting struct {
	name    string
	path    func(a, o, n string) string
	setOn   string // a request that stores a value
	file    string // what the file then holds
	getReq  string
	getWant string
	setOff  string // a request that clears
	altOn   string // a different valid value, for the blocked-publish case
}

var deviceSettings = []deviceSetting{
	{"ota-auto", func(a, o, n string) string { return a }, "SET-OTA-AUTO\n1\n", "1\n", "GET-OTA-AUTO\n", "1", "SET-OTA-AUTO\n0\n", "SET-OTA-AUTO\n1\n"},
	{"notice-number", func(a, o, n string) string { return n }, "SET-NOTICE-NUMBER\n1\n", "1\n", "GET-NOTICE-NUMBER\n", "1", "SET-NOTICE-NUMBER\n0\n", "SET-NOTICE-NUMBER\n1\n"},
	{"ota-time", func(a, o, n string) string { return o }, "SET-OTA-TIME\n07:30\n", "07:30\n", "GET-OTA-TIME\n", "07:30", "SET-OTA-TIME\n\n", "SET-OTA-TIME\n08:00\n"},
}

func TestDeviceSettingSetsSaveAndAnswerOK(t *testing.T) {
	asGate(t)
	a, o, n := useTempDeviceFlags(t)
	for _, s := range deviceSettings {
		p := s.path(a, o, n)
		if got := driveLogin(t, t.TempDir(), s.setOn); got != "OK" {
			t.Fatalf("%s: %q replied %q, want OK", s.name, s.setOn, got)
		}
		if b, err := os.ReadFile(p); err != nil || string(b) != s.file {
			t.Fatalf("%s: file = %q (err %v), want %q", s.name, b, err, s.file)
		}
		if got := driveLogin(t, t.TempDir(), s.getReq); got != s.getWant {
			t.Fatalf("%s: GET replied %q, want %q", s.name, got, s.getWant)
		}
		if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
			t.Fatalf("%s: a successful SET left %s.tmp behind (stat err %v)", s.name, p, err)
		}
		if got := driveLogin(t, t.TempDir(), s.setOff); got != "OK" {
			t.Fatalf("%s: %q replied %q, want OK", s.name, s.setOff, got)
		}
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s: the file survived the clear (stat err %v)", s.name, err)
		}
	}
	// An invalid time keeps today's meaning -- it clears -- and answers OK when the clear held.
	if got := driveLogin(t, t.TempDir(), "SET-OTA-TIME\n07:30\n"); got != "OK" {
		t.Fatalf("SET-OTA-TIME 07:30 replied %q", got)
	}
	if got := driveLogin(t, t.TempDir(), "SET-OTA-TIME\n25:99\n"); got != "OK" {
		t.Fatalf("SET-OTA-TIME 25:99 replied %q, want OK", got)
	}
	if _, err := os.Stat(o); !os.IsNotExist(err) {
		t.Fatalf("an invalid install time left the file in place (stat err %v)", err)
	}
	if got := driveLogin(t, t.TempDir(), "GET-OTA-TIME\n"); got != "" {
		t.Fatalf("GET-OTA-TIME after a clear replied %q, want empty", got)
	}
	if got := driveLogin(t, t.TempDir(), "GET-OTA-AUTO\n"); got != "0" {
		t.Fatalf("GET-OTA-AUTO off replied %q", got)
	}
	if got := driveLogin(t, t.TempDir(), "GET-NOTICE-NUMBER\n"); got != "0" {
		t.Fatalf("GET-NOTICE-NUMBER off replied %q", got)
	}
}

// A publish that cannot land answers ERR and leaves the previous file byte-identical.
func TestDeviceSettingBlockedPublishAnswersERRAndKeepsPrevious(t *testing.T) {
	asGate(t)
	a, o, n := useTempDeviceFlags(t)
	for _, s := range deviceSettings {
		p := s.path(a, o, n)
		if got := driveLogin(t, t.TempDir(), s.setOn); got != "OK" {
			t.Fatalf("%s: first SET replied %q", s.name, got)
		}
		before, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(p+".tmp", 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(p+".tmp", "x"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		req := s.altOn
		if s.name == "ota-time" {
			req = "SET-OTA-TIME\n08:00\n"
		}
		if got := driveLogin(t, t.TempDir(), req); got != "ERR" {
			t.Fatalf("%s: SET with an unwritable temp path replied %q, want ERR", s.name, got)
		}
		after, err := os.ReadFile(p)
		if err != nil || !bytes.Equal(before, after) {
			t.Fatalf("%s: file after a failed SET = %q (err %v), want %q", s.name, after, err, before)
		}
	}
}

// A clear that cannot remove the file answers ERR.
func TestDeviceSettingFailedRemoveAnswersERR(t *testing.T) {
	asGate(t)
	a, o, n := useTempDeviceFlags(t)
	for _, s := range deviceSettings {
		p := s.path(a, o, n)
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(p, "x"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := driveLogin(t, t.TempDir(), s.setOff); got != "ERR" {
			t.Fatalf("%s: %q with an undeletable path replied %q, want ERR", s.name, s.setOff, got)
		}
	}
}

// A rename that fails answers ERR and leaves no temp file behind.
func TestDeviceSettingFailedRenameLeavesNoTemp(t *testing.T) {
	asGate(t)
	a, o, n := useTempDeviceFlags(t)
	for _, s := range deviceSettings {
		p := s.path(a, o, n)
		if err := os.MkdirAll(p, 0o700); err != nil { // empty: the .tmp write succeeds, rename(file -> dir) fails
			t.Fatal(err)
		}
		if got := driveLogin(t, t.TempDir(), s.setOn); got != "ERR" {
			t.Fatalf("%s: SET with a directory at the path replied %q, want ERR", s.name, got)
		}
		if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
			t.Fatalf("%s: a failed SET left %s.tmp behind (stat err %v)", s.name, p, err)
		}
	}
}

// All five verbs (and GET-OTA-AUTO, the control) answer within a second while sessionMu is held.
func TestDeviceSettingVerbsAnswerWhileSessionMuIsHeld(t *testing.T) {
	asGate(t)
	useTempDeviceFlags(t)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	for _, c := range []struct{ req, verb, want string }{
		{"SET-OTA-AUTO\n1\n", "SET-OTA-AUTO", "OK"},
		{"GET-OTA-AUTO\n", "GET-OTA-AUTO", "1"},
		{"SET-OTA-TIME\n06:15\n", "SET-OTA-TIME", "OK"},
		{"GET-OTA-TIME\n", "GET-OTA-TIME", "06:15"},
		{"SET-NOTICE-NUMBER\n1\n", "SET-NOTICE-NUMBER", "OK"},
		{"GET-NOTICE-NUMBER\n", "GET-NOTICE-NUMBER", "1"},
	} {
		if got := replyWhileHeld(t, time.Second, c.req, c.verb); got != c.want {
			t.Fatalf("%s replied %q while sessionMu was held, want %q", c.verb, got, c.want)
		}
	}
}

// The caller's-number pair stays owner-mode: a caller that is not the gate is refused, and nothing is written.
func TestNoticeNumberStillDeniedToANonGateCaller(t *testing.T) {
	asCaller(t, 10999, 10123)
	_, _, notice := useTempDeviceFlags(t)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	for _, req := range []string{"GET-NOTICE-NUMBER\n", "SET-NOTICE-NUMBER\n1\n"} {
		if got := replyWhileHeld(t, time.Second, req, req); got != "DENIED" {
			t.Fatalf("%q from a non-gate caller replied %q, want DENIED", req, got)
		}
	}
	if _, err := os.Stat(notice); !os.IsNotExist(err) {
		t.Fatalf("a refused caller wrote the notice-number file (stat err %v)", err)
	}
}
