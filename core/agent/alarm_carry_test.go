package main

import (
	"bufio"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261129-39: ALARM-CARRY, the alarm a sign-out carried against the next session's -- one strictly-typed login.log line.

// alarmCarry sends one ALARM-CARRY through the real dispatcher. body must end in "\n": evictConn never closes the
// client's write side, so a short body waits out the connection deadline.
func alarmCarry(t *testing.T, body string) (reply, logged string) {
	t.Helper()
	d := t.TempDir()
	logged = captureStderr(t, func() {
		reply = evictConn(t, d, "ALARM-CARRY\n"+body)
	})
	return strings.TrimRight(reply, "\r\n"), logged
}

// alarmCarryLogLines is every line a request logged for this verb.
func alarmCarryLogLines(logged string) (lines []string) {
	for _, l := range strings.Split(logged, "\n") {
		if strings.Contains(l, "alarm carry") {
			lines = append(lines, l)
		}
	}
	return lines
}

func TestAlarmCarryLogsOneLine(t *testing.T) {
	for _, sealed := range []string{"past", "future", "bad"} {
		for _, now := range []string{"none", "same", "earlier", "later"} {
			tokens := "sealed=" + sealed + " now=" + now
			reply, logged := alarmCarry(t, tokens+"\n")
			if reply != "OK" {
				t.Errorf("%q: reply %q, want OK", tokens, reply)
			}
			want := "[logind] alarm carry: " + tokens + " (NWP-20261129-39)"
			if lines := alarmCarryLogLines(logged); len(lines) != 1 || lines[0] != want {
				t.Errorf("%q: logged %q, want exactly %q", tokens, lines, want)
			}
		}
	}
}

func TestAlarmCarryRefusesBadLines(t *testing.T) {
	for _, body := range []string{
		"sealed=soon now=none\n",          // an unknown sealed token
		"sealed=past now=never\n",         // an unknown now token
		"sealed=word now=word\n",          // any other word
		"sealed=past\n",                   // a missing field
		"now=none\n",                      // a missing field
		"sealed=past now=none extra\n",    // an extra field
		"now=none sealed=past\n",          // swapped fields
		"sealed=past now=none \n",         // a trailing space
		" sealed=past now=none\n",         // a leading space
		"sealed=past  now=none\n",         // two spaces
		"sealed=past\tnow=none\n",         // a tab
		"sealed=past now=none\r\n",        // a carriage return
		"SEALED=PAST NOW=NONE\n",          // upper case
		"sealed=past1 now=none\n",         // a digit in a token
		"sealed=past now=1762400000000\n", // a time
		"\n",                              // the empty line
	} {
		reply, logged := alarmCarry(t, body)
		if reply != "ERR-ARG" {
			t.Errorf("%q: reply %q, want ERR-ARG", body, reply)
		}
		if lines := alarmCarryLogLines(logged); len(lines) != 0 {
			t.Errorf("%q: a refused request logged %q", body, lines)
		}
	}
}

// A request cut short answers at once (the reader's EOF), never with a line, even when its text would parse.
// Direct call: through evictConn a short body waits out the connection deadline.
func TestAlarmCarryRefusesACutRequest(t *testing.T) {
	for _, body := range []string{"", "sealed=past now=none"} {
		cli, srv := net.Pipe()
		got := make(chan string, 1)
		logged := captureStderr(t, func() {
			go func() { b, _ := io.ReadAll(cli); got <- string(b) }()
			handleAlarmCarry(srv, bufio.NewReader(strings.NewReader(body)))
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
		if lines := alarmCarryLogLines(logged); len(lines) != 0 {
			t.Errorf("%q: a cut request logged %q", body, lines)
		}
	}
}

func TestAlarmCarryIsConcurrentSafe(t *testing.T) {
	if !concurrentSafeCmd("ALARM-CARRY") {
		t.Fatal("ALARM-CARRY is serialised on sessionMu, which the seal or the sign-in behind the relay can hold")
	}
}
