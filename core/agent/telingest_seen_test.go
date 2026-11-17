package main

import (
	"bufio"
	"io"
	"net"
	"reflect"
	"strings"
	"testing"
	"time"
)

// NWP-20261129-02: TELINGEST-SEEN, a delivery run's read-back counts -- one strictly-typed login.log line.

const telIngestSeenMark = "telingest read-back"

// telIngestSeen sends one TELINGEST-SEEN through the real dispatcher. body must end in "\n": evictConn never closes
// the client's write side, so a short body waits out the connection deadline.
func telIngestSeen(t *testing.T, body string) (reply, logged string) {
	t.Helper()
	d := t.TempDir()
	logged = captureStderr(t, func() {
		reply = evictConn(t, d, "TELINGEST-SEEN\n"+body)
	})
	return strings.TrimRight(reply, "\r\n"), logged
}

// telIngestSeenOne sends body and wants OK and exactly the one marked line want.
func telIngestSeenOne(t *testing.T, body, want string) {
	t.Helper()
	reply, logged := telIngestSeen(t, body)
	if reply != "OK" {
		t.Errorf("%q: reply %q, want OK", body, reply)
	}
	var lines []string
	for _, l := range strings.Split(logged, "\n") {
		if strings.Contains(l, telIngestSeenMark) {
			lines = append(lines, l)
		}
	}
	if len(lines) != 1 || lines[0] != want {
		t.Errorf("%q: logged %q, want exactly %q", body, lines, want)
	}
}

func TestTelIngestSeenLogsCounts(t *testing.T) {
	for _, c := range []struct{ body, want string }{
		{"0 0 0 0 0 0 0\n", "[logind] telingest read-back: sms inserted=0 hidden=0, mms inserted=0 hidden=0, unknown=0, mms addr not inserted=0, mms parts not inserted=0 (NWP-20261129-02)"},
		{"7 6 5 4 3 2 1\n", "[logind] telingest read-back: sms inserted=7 hidden=6, mms inserted=5 hidden=4, unknown=3, mms addr not inserted=2, mms parts not inserted=1 (NWP-20261129-02)"},
		{"99999 99999 99999 99999 99999 99999 99999\n", "[logind] telingest read-back: sms inserted=99999 hidden=99999, mms inserted=99999 hidden=99999, unknown=99999, mms addr not inserted=99999, mms parts not inserted=99999 (NWP-20261129-02)"},
	} {
		telIngestSeenOne(t, c.body, c.want)
	}
}

// NWP-20261204-11: nine numbers log the same text with the two default-SMS-SIM counts before the work id.
func TestTelIngestSeenLogsNineCounts(t *testing.T) {
	for _, c := range []struct{ body, want string }{
		{"0 0 0 0 0 0 0 0 0\n", "[logind] telingest read-back: sms inserted=0 hidden=0, mms inserted=0 hidden=0, unknown=0, mms addr not inserted=0, mms parts not inserted=0, mms off the default SMS SIM=0, default SMS SIM not in session=0 (NWP-20261129-02)"},
		{"9 8 7 6 5 4 3 2 1\n", "[logind] telingest read-back: sms inserted=9 hidden=8, mms inserted=7 hidden=6, unknown=5, mms addr not inserted=4, mms parts not inserted=3, mms off the default SMS SIM=2, default SMS SIM not in session=1 (NWP-20261129-02)"},
		{"99999 99999 99999 99999 99999 99999 99999 99999 99999\n", "[logind] telingest read-back: sms inserted=99999 hidden=99999, mms inserted=99999 hidden=99999, unknown=99999, mms addr not inserted=99999, mms parts not inserted=99999, mms off the default SMS SIM=99999, default SMS SIM not in session=99999 (NWP-20261129-02)"},
	} {
		telIngestSeenOne(t, c.body, c.want)
	}
}

func TestTelIngestSeenRefusesBadLines(t *testing.T) {
	for _, body := range []string{
		"1 2 3 4 5 6\n",            // six numbers
		"1 2 3 4 5 6 7 8\n",        // eight numbers
		"1 2 3 4 5 6 7 8 9 10\n",   // ten numbers
		"1 a 3 4 5 6 7\n",          // a letter
		"-1 2 3 4 5 6 7\n",         // a sign
		"+1 2 3 4 5 6 7\n",         // a sign
		"100000 2 3 4 5 6 7\n",     // six digits
		"1 2 3 4 5 6 7 8 100000\n", // nine numbers, one of six digits
		"1 2 3 4 5 6 7 8 x\n",      // nine fields, a letter
		"1  2 3 4 5 6 7\n",         // an empty field
		" 1 2 3 4 5 6 7\n",         // a leading space
		"1 2 3 4 5 6 7 \n",         // a trailing space
		"1 2 3 4 5 6 7 8 9 \n",     // nine numbers, a trailing space
		"1\t2 3 4 5 6 7\n",         // a tab
		"\n",                       // the empty line
	} {
		reply, logged := telIngestSeen(t, body)
		if reply != "ERR-ARG" {
			t.Errorf("%q: reply %q, want ERR-ARG", body, reply)
		}
		if strings.Contains(logged, telIngestSeenMark) {
			t.Errorf("%q: a refused request logged %q", body, logged)
		}
	}
}

// A request cut short answers at once (the reader's EOF), never with a line, even when its text would parse.
// Direct call: through evictConn a short body waits out the connection deadline.
func TestTelIngestSeenRefusesATruncatedRequest(t *testing.T) {
	for _, body := range []string{"", "1 2 3 4 5 6 7", "1 2 3 4 5 6 7 8 9"} {
		cli, srv := net.Pipe()
		got := make(chan string, 1)
		logged := captureStderr(t, func() {
			go func() { b, _ := io.ReadAll(cli); got <- string(b) }()
			handleTelIngestSeen(srv, bufio.NewReader(strings.NewReader(body)))
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
		if strings.Contains(logged, telIngestSeenMark) {
			t.Errorf("%q: a truncated request logged %q", body, logged)
		}
	}
}

func TestTelIngestSeenIsConcurrentSafe(t *testing.T) {
	if !concurrentSafeCmd("TELINGEST-SEEN") {
		t.Fatal("TELINGEST-SEEN is serialised on sessionMu, which a session's seals hold for minutes")
	}
}

func TestTelIngestSeenParse(t *testing.T) {
	for _, c := range []struct {
		line string
		want []int
	}{
		{"1 2 3 4 5 6 7", []int{1, 2, 3, 4, 5, 6, 7}},
		{"1 2 3 4 5 6 7 8 9", []int{1, 2, 3, 4, 5, 6, 7, 8, 9}},
	} {
		if n, ok := parseTelIngestSeen(c.line); !ok || !reflect.DeepEqual(n, c.want) {
			t.Errorf("parse(%q) = %v, %v", c.line, n, ok)
		}
	}
	for _, l := range []string{"", "1 2 3 4 5 6", "1 2 3 4 5 6 7 8", "1 2 3 4 5 6 123456", "1 2 3 4 5 6 x",
		"1 2 3 4 5 6 7 8 9 10", "1 2 3 4 5 6 7 8 123456"} {
		if _, ok := parseTelIngestSeen(l); ok {
			t.Errorf("parse(%q) accepted", l)
		}
	}
}
