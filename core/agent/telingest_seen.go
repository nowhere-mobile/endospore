package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
)

// NWP-20261129-02: can a session read the SMS and MMS a delivery run inserted, as one login.log line.
//
// On GrapheneOS 2026110200 the provider can hide the rows TelIngest inserts from that session's readers, and a text
// can lose its MMS addr or part rows. All of that showed in logcat at most, which a user-build report does not carry,
// so a report could not tell a hidden row from a delivered one. After a sign-in or resume delivery TelIngest reads each
// row it inserted back as the session's reader (TelSeen) and sends
//
//	"TELINGEST-SEEN\n<sms> <sms hidden> <mms> <mms hidden> <unknown> <addr not inserted> <parts not inserted>\n"
//
// -> "OK" | "ERR-ARG". Counts only: no number, body or time. Each number is 1-5 decimal digits (sweepAppNum's rules);
// anything else is refused and nothing is logged. Lock-free (concurrentSafeCmd): it is sent from a session whose seals
// hold sessionMu for minutes.

// parseTelIngestSeen validates the one line: exactly seven single-space-separated numbers, each 0..99999.
func parseTelIngestSeen(line string) (n [7]int, ok bool) {
	f := strings.Split(line, " ")
	if len(f) != len(n) {
		return n, false
	}
	for i := range n {
		v, good := sweepAppNum(f[i], 5, 0, 99999)
		if !good {
			return n, false
		}
		n[i] = v
	}
	return n, true
}

// handleTelIngestSeen reads the one line, writes it to stderr (login.log) and answers OK; ERR-ARG otherwise.
func handleTelIngestSeen(conn net.Conn, r *bufio.Reader) {
	l, err := r.ReadString('\n')
	if err != nil { // a request cut short is refused even when its text would parse
		fmt.Fprint(conn, "ERR-ARG\n")
		return
	}
	n, ok := parseTelIngestSeen(strings.TrimRight(l, "\r\n")) // not TrimSpace: a stray space is refused
	if !ok {
		fmt.Fprint(conn, "ERR-ARG\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] telingest read-back: sms inserted=%d hidden=%d, mms inserted=%d hidden=%d, unknown=%d, mms addr not inserted=%d, mms parts not inserted=%d (NWP-20261129-02)\n",
		n[0], n[1], n[2], n[3], n[4], n[5], n[6])
	fmt.Fprint(conn, "OK\n")
}
