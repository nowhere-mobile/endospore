package main

import (
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261114-13: the ring signal for the first-run OS agreement screen with DRAFT text.
//
// ⚠ THE "off" CASES ARE THE LOAD-BEARING ONES. Prod bakes no ring, so an unset key must answer "off", and so
// must every near miss: a typo in a conf has to hide a DRAFT legal screen, never show it.
func TestOsAgreementMode(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  bool
		val  string
		want string
	}{
		{"unset is off (a prod image)", false, "", "off"},
		{"empty is off", true, "", "off"},
		{"draft is draft", true, "draft", "draft"},
		{"surrounding whitespace is trimmed", true, " draft ", "draft"},
		{"upper case is off", true, "DRAFT", "off"},
		{"on is off", true, "on", "off"},
		{"1 is off", true, "1", "off"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setOsAgreementEnv(t, tc.set, tc.val)
			if got := osAgreementMode(); got != tc.want {
				t.Errorf("NOWHERE_OS_AGREEMENT set=%v %q: osAgreementMode() = %q, want %q", tc.set, tc.val, got, tc.want)
			}
		})
	}
}

// TestGetOsAgreementVerb drives the verb through handleLogin, the way the chooser asks it.
func TestGetOsAgreementVerb(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  bool
		val  string
		want string
	}{
		{"ring image answers draft", true, "draft", "draft"},
		{"prod image answers off", false, "", "off"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setOsAgreementEnv(t, tc.set, tc.val)
			if got := driveOsAgreement(t); got != tc.want {
				t.Errorf("GET-OS-AGREEMENT with NOWHERE_OS_AGREEMENT set=%v %q: reply %q, want %q", tc.set, tc.val, got, tc.want)
			}
		})
	}
}

func setOsAgreementEnv(t *testing.T, set bool, val string) {
	t.Helper()
	t.Setenv("NOWHERE_OS_AGREEMENT", val)
	if !set {
		// t.Setenv registers the restore; Unsetenv makes the key ABSENT, the state a prod device is in.
		if err := os.Unsetenv("NOWHERE_OS_AGREEMENT"); err != nil {
			t.Fatal(err)
		}
	}
}

// driveOsAgreement sends one GET-OS-AGREEMENT line and returns the trimmed reply. A daemon without the verb reads
// the line as a legacy login and waits for more input, so the reply is bounded: after 5 s the test closes the pipe,
// and the empty reply fails the test instead of holding the run for the daemon's own read timeout.
func driveOsAgreement(t *testing.T) string {
	t.Helper()
	cli, srv := net.Pipe()
	defer cli.Close()
	go func() { cli.Write([]byte("GET-OS-AGREEMENT\n")) }()
	got := make(chan string, 1)
	go func() { b, _ := io.ReadAll(cli); got <- string(b) }()
	done := make(chan struct{})
	go func() { handleLogin(srv, t.TempDir()); close(done) }() // closes srv itself
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		srv.Close()
		cli.Close()
		<-done
	}
	return strings.TrimSpace(<-got)
}
