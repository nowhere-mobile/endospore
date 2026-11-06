package main

import (
	"bufio"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #98 / #631: the third line ("Office\tpw\t0") carries the per-network MAC mode as a third field and must come back byte
// for byte -- the chooser parses it at the gate (core/chooser/tests/wifi-mirror).
// WIFI-MIRROR stores the roamed session's ssid\tpsk lines; GET-WIFI-MIRROR hands them to a USER-0 caller
// exactly once (deleted before the reply) and fails closed for a peer whose uid can't be read.
func TestWifiMirrorRoundTrip(t *testing.T) {
	dest := t.TempDir()

	// Store: count + lines ride the same bufio.Reader the daemon dispatch uses.
	cli, srv := net.Pipe()
	go func() {
		handleWifiMirror(srv, dest, bufio.NewReader(strings.NewReader("3\nOviya\thunter2 pass\nCafe Open\t\nOffice\tpw\t0\n")))
		srv.Close()
	}()
	b, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(b)); got != "OK" {
		t.Fatalf("WIFI-MIRROR: got %q want OK", got)
	}

	// Fetch over a REAL unix socketpair (peer uid = ours, < 100000 -> allowed), one-shot.
	got := unixRoundTrip(t, func(c net.Conn) { handleGetWifiMirror(c, dest) })
	if want := "OK\nOviya\thunter2 pass\nCafe Open\t\nOffice\tpw\t0\n"; got != want {
		t.Fatalf("GET-WIFI-MIRROR: got %q want %q", got, want)
	}
	if got := strings.TrimSpace(unixRoundTrip(t, func(c net.Conn) { handleGetWifiMirror(c, dest) })); got != "NONE" {
		t.Fatalf("second GET-WIFI-MIRROR: got %q want NONE (one-shot)", got)
	}

	// Fail closed without peer credentials (net.Pipe is not a unix socket).
	cli2, srv2 := net.Pipe()
	go func() {
		handleWifiMirror(srv2, dest, bufio.NewReader(strings.NewReader("1\nHome\tpw\n")))
		srv2.Close()
	}()
	io.ReadAll(cli2)
	cli3, srv3 := net.Pipe()
	go func() { handleGetWifiMirror(srv3, dest); srv3.Close() }()
	b3, _ := io.ReadAll(cli3)
	if got := strings.TrimSpace(string(b3)); got != "NONE" {
		t.Fatalf("pipe caller: got %q want NONE (fail closed)", got)
	}
}

// Malformed inputs never store anything: zero/absurd counts, lines without a tab.
func TestWifiMirrorRejectsMalformed(t *testing.T) {
	dest := t.TempDir()
	for _, in := range []string{"0\n", "99\n", "x\n", "1\nno-tab-here\n"} {
		cli, srv := net.Pipe()
		go func() { handleWifiMirror(srv, dest, bufio.NewReader(strings.NewReader(in))); srv.Close() }()
		b, _ := io.ReadAll(cli)
		if got := strings.TrimSpace(string(b)); got != "ERR" {
			t.Fatalf("input %q: got %q want ERR", in, got)
		}
	}
}

// NWP-20261020-30 (spec F4): the WIFI-MIRROR log line states the lines STORED and how many were skipped, not
// the count the request claimed.
func wifiMirrorLogged(t *testing.T, in string) (log, stored string) {
	t.Helper()
	dest := t.TempDir()
	log = captureStderr(t, func() {
		cli, srv := net.Pipe()
		go func() { handleWifiMirror(srv, dest, bufio.NewReader(strings.NewReader(in))); srv.Close() }()
		b, _ := io.ReadAll(cli)
		if got := strings.TrimSpace(string(b)); got != "OK" {
			t.Fatalf("input %q: got %q want OK", in, got)
		}
	})
	b, err := os.ReadFile(filepath.Join(dest, ".wifimirror"))
	if err != nil {
		t.Fatalf("read .wifimirror: %v", err)
	}
	return log, string(b)
}

func TestWifiMirrorLogCountsSkippedLine(t *testing.T) {
	log, stored := wifiMirrorLogged(t, "3\nA\tp1\nno-tab\nC\tp3\n")
	if want := "wifi-mirror: 2 network(s) queued for the gate (1 of 3 line(s) skipped)\n"; !strings.Contains(log, want) {
		t.Fatalf("log %q lacks %q", log, want)
	}
	if want := "A\tp1\nC\tp3\n"; stored != want {
		t.Fatalf(".wifimirror: got %q want %q", stored, want)
	}
}

func TestWifiMirrorLogCountsOverlongLine(t *testing.T) {
	log, _ := wifiMirrorLogged(t, "2\nA\tp1\n"+strings.Repeat("x", 300)+"\tpw\n")
	if want := "wifi-mirror: 1 network(s) queued for the gate (1 of 2 line(s) skipped)\n"; !strings.Contains(log, want) {
		t.Fatalf("log %q lacks %q", log, want)
	}
}

// Control: nothing skipped, no clause. Passes before and after the change.
func TestWifiMirrorLogCleanRequestHasNoSkippedClause(t *testing.T) {
	log, _ := wifiMirrorLogged(t, "3\nA\tp1\nB\tp2\nC\tp3\n")
	if want := "wifi-mirror: 3 network(s) queued for the gate\n"; !strings.Contains(log, want) {
		t.Fatalf("log %q lacks %q", log, want)
	}
}
