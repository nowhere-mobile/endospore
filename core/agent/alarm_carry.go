package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"regexp"
	"strings"
)

// NWP-20261129-39: the alarm a sign-out carried, against the alarm the next session has, as one login.log line.
//
// Backlog row "A clock alarm set in a roamed session did not ring, and showed as missed when the clock was opened":
// its path (3), a fresh sign-in whose clock app never registered its alarms again, needed a `dumpsys alarm` on the
// device. So a sign-out seals its next alarm's time in the chooser's files dir (AlarmCarry), and the first relay after
// the next sign-in (CredentialService.relayNextAlarm) sends
//
//	"ALARM-CARRY\nsealed=<past|future|bad> now=<none|same|earlier|later>\n"
//
// -> "OK" | "ERR-ARG". Tokens only: no uid, time, app or profile. Anything else is refused and nothing is logged. A
// reader takes `sealed=future now=none`, before the clock app has run, as path (3). Lock-free (concurrentSafeCmd): a
// relay sends it during a seal or a sign-in, so serialised it would wait behind the work it reports on.

// alarmCarryLine is the one line the verb accepts.
var alarmCarryLine = regexp.MustCompile(`^sealed=(past|future|bad) now=(none|same|earlier|later)$`)

// handleAlarmCarry reads the one line, writes it to stderr (login.log) and answers OK; ERR-ARG otherwise.
func handleAlarmCarry(conn net.Conn, r *bufio.Reader) {
	l, err := r.ReadString('\n')
	if err != nil { // a request cut short is refused even when its text would parse
		fmt.Fprint(conn, "ERR-ARG\n")
		return
	}
	m := alarmCarryLine.FindStringSubmatch(strings.TrimSuffix(l, "\n")) // not TrimSpace: a stray space or CR is refused
	if m == nil {
		fmt.Fprint(conn, "ERR-ARG\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] alarm carry: sealed=%s now=%s (NWP-20261129-39)\n", m[1], m[2])
	fmt.Fprint(conn, "OK\n")
}
