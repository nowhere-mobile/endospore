package main

import (
	"bufio"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261127-08: PLACEHOLDER-OUTCOMES, a sign-in's placeholder outcome counts -- one strictly-typed login.log line.

// placeholderOutcomes sends one PLACEHOLDER-OUTCOMES through the real dispatcher. body must end in "\n": evictConn
// never closes the client's write side, so a short body waits out the connection deadline.
func placeholderOutcomes(t *testing.T, body string) (reply, logged string) {
	t.Helper()
	d := t.TempDir()
	logged = captureStderr(t, func() {
		reply = evictConn(t, d, "PLACEHOLDER-OUTCOMES\n"+body)
	})
	return strings.TrimRight(reply, "\r\n"), logged
}

func TestPlaceholderOutcomesLogsCounts(t *testing.T) {
	for _, c := range []struct{ body, want string }{
		{"3 11 0 2 1\n", "[logind] sign-in placeholders: raised=3 no-meta=11 refused=0 group-dep=2 error=1 (NWP-20261127-08)"},
		{"0 0 0 0 0\n", "[logind] sign-in placeholders: raised=0 no-meta=0 refused=0 group-dep=0 error=0 (NWP-20261127-08)"},
		{"99999 99999 99999 99999 99999\n", "[logind] sign-in placeholders: raised=99999 no-meta=99999 refused=99999 group-dep=99999 error=99999 (NWP-20261127-08)"},
	} {
		reply, logged := placeholderOutcomes(t, c.body)
		if reply != "OK" {
			t.Errorf("%q: reply %q, want OK", c.body, reply)
		}
		var lines []string
		for _, l := range strings.Split(logged, "\n") {
			if strings.Contains(l, "sign-in placeholders") {
				lines = append(lines, l)
			}
		}
		if len(lines) != 1 || lines[0] != c.want {
			t.Errorf("%q: logged %q, want exactly %q", c.body, lines, c.want)
		}
	}
}

func TestPlaceholderOutcomesRefusesBadLines(t *testing.T) {
	for _, body := range []string{
		"1 2 3 4\n",        // four numbers
		"1 2 3 4 5 6\n",    // six numbers
		"-1 2 3 4 5\n",     // a sign
		"+1 2 3 4 5\n",     // a sign
		"1 a 3 4 5\n",      // a letter
		"100000 1 1 1 1\n", // six digits
		"1  2 3 4 5\n",     // an empty field
		" 1 2 3 4 5\n",     // a leading space
		"1 2 3 4 5 \n",     // a trailing space
		"1\t2 3 4 5\n",     // a tab
		"\n",               // the empty line
	} {
		reply, logged := placeholderOutcomes(t, body)
		if reply != "ERR-ARG" {
			t.Errorf("%q: reply %q, want ERR-ARG", body, reply)
		}
		if strings.Contains(logged, "sign-in placeholders") {
			t.Errorf("%q: a refused request logged %q", body, logged)
		}
	}
}

// A request cut short answers at once (the reader's EOF), never with a line, even when its text would parse.
// Direct call: through evictConn a short body waits out the connection deadline.
func TestPlaceholderOutcomesRefusesATruncatedRequest(t *testing.T) {
	for _, body := range []string{"", "1 2 3 4 5"} {
		cli, srv := net.Pipe()
		got := make(chan string, 1)
		logged := captureStderr(t, func() {
			go func() { b, _ := io.ReadAll(cli); got <- string(b) }()
			handlePlaceholderOutcomes(srv, bufio.NewReader(strings.NewReader(body)))
			srv.Close()
		})
		select {
		case reply := <-got:
			if strings.TrimRight(reply, "\r\n") != "ERR-ARG" {
				t.Errorf("%q: reply %q, want ERR-ARG", body, reply)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%q: no reply within 3s", body)
		}
		cli.Close()
		if strings.Contains(logged, "sign-in placeholders") {
			t.Errorf("%q: a truncated request logged %q", body, logged)
		}
	}
}

func TestPlaceholderOutcomesIsConcurrentSafe(t *testing.T) {
	if !concurrentSafeCmd("PLACEHOLDER-OUTCOMES") {
		t.Fatal("PLACEHOLDER-OUTCOMES is serialised on sessionMu, which the sign-in that sends it holds")
	}
}

func TestPlaceholderOutcomesParse(t *testing.T) {
	if n, ok := parsePlaceholderOutcomes("1 2 3 4 5"); !ok || n != [5]int{1, 2, 3, 4, 5} {
		t.Errorf("parse(1 2 3 4 5) = %v, %v", n, ok)
	}
	for _, l := range []string{"", "1 2 3 4", "1 2 3 4 5 6", "1 2 3 4 123456", "1 2 3 4 x"} {
		if _, ok := parsePlaceholderOutcomes(l); ok {
			t.Errorf("parse(%q) accepted", l)
		}
	}
}
