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
// or, since NWP-20261204-11, the same seven followed by two more:
//
//	"... <parts not inserted> <mms off the default SMS SIM> <default SMS SIM not in session>\n"
//
// for the backlog row "On GrapheneOS 2026110200 an MMS delivered into a session can arrive without its sender or its
// parts on a two-SIM phone": MmsProvider checks the addr and part inserts against the default SMS subscription, so a
// report says whether that condition arose beside the addr and parts not inserted. A seven-number line logs the same
// text as before, byte for byte. The chooser and the agent ship in one image; an older agent meets a nine-number line
// only on a hand hot-patch, and it answers ERR-ARG (the line is lost, nothing else changes).
//
// -> "OK" | "ERR-ARG". Counts only: no number, body or time. Each number is 1-5 decimal digits (sweepAppNum's rules);
// anything else is refused and nothing is logged. Lock-free (concurrentSafeCmd): it is sent from a session whose seals
// hold sessionMu for minutes.

// parseTelIngestSeen validates the one line: exactly seven or exactly nine single-space-separated numbers, each
// 0..99999.
func parseTelIngestSeen(line string) (n []int, ok bool) {
	f := strings.Split(line, " ")
	if len(f) != 7 && len(f) != 9 {
		return nil, false
	}
	n = make([]int, len(f))
	for i := range f {
		v, good := sweepAppNum(f[i], 5, 0, 99999)
		if !good {
			return nil, false
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
	ext := "" // NWP-20261204-11: a seven-number line logs the older text byte for byte
	if len(n) == 9 {
		ext = fmt.Sprintf(", mms off the default SMS SIM=%d, default SMS SIM not in session=%d", n[7], n[8])
	}
	fmt.Fprintf(os.Stderr, "[logind] telingest read-back: sms inserted=%d hidden=%d, mms inserted=%d hidden=%d, unknown=%d, mms addr not inserted=%d, mms parts not inserted=%d%s (NWP-20261129-02)\n",
		n[0], n[1], n[2], n[3], n[4], n[5], n[6], ext)
	fmt.Fprint(conn, "OK\n")
}
