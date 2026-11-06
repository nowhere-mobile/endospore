package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
)

// NWP-20261127-08: a sign-in's archived-placeholder outcomes, as one login.log line.
//
// ChooserActivity.installRoamedAppCode raises a placeholder for each deferred (On-demand / Auto) app whose
// .appcode/<pkg>/_meta the restore staged, and logged each miss to logcat only, which a user-build report does not
// carry. On frankel 0.5.52 eleven On-demand apps came back with no placeholder, and nothing in the report told a
// missing _meta from a refused install. So the chooser counts each deferred row's outcome (PlaceholderTally) and,
// after its loop, sends
//
//	"PLACEHOLDER-OUTCOMES\n<raised> <no-meta> <refused> <group-dep> <error>\n"
//
// -> "OK" | "ERR-ARG". Counts only: no package name, label or path. Each number is 1-5 decimal digits
// (sweepAppNum's rules); anything else is refused and nothing is logged. Lock-free (concurrentSafeCmd): it is sent
// during a sign-in, which holds sessionMu.

// parsePlaceholderOutcomes validates the one line: exactly five single-space-separated numbers, each 0..99999.
func parsePlaceholderOutcomes(line string) (n [5]int, ok bool) {
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

// handlePlaceholderOutcomes reads the one line, writes it to stderr (login.log) and answers OK; ERR-ARG otherwise.
func handlePlaceholderOutcomes(conn net.Conn, r *bufio.Reader) {
	l, err := r.ReadString('\n')
	if err != nil { // a request cut short is refused even when its text would parse
		fmt.Fprint(conn, "ERR-ARG\n")
		return
	}
	n, ok := parsePlaceholderOutcomes(strings.TrimRight(l, "\r\n")) // not TrimSpace: a stray space is refused
	if !ok {
		fmt.Fprint(conn, "ERR-ARG\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] sign-in placeholders: raised=%d no-meta=%d refused=%d group-dep=%d error=%d (NWP-20261127-08)\n",
		n[0], n[1], n[2], n[3], n[4])
	fmt.Fprint(conn, "OK\n")
}
