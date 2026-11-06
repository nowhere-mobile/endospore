package main

import (
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// NWP-20261120-06 (Q167, docs/product-decisions.md 2026-10-20): CREATE and CREATE-CODE stream
// "PROGRESS create <done> <total>" lines before their verdict, as ROAM-IN streams its restore. A re-create over a
// deleted name runs the purge (deleteProfileSEProg) before the new head lands; its ticks were inert in the login
// daemon, which has no NOWHERE_PROGRESS, so the gate sat on a frozen bar for the whole purge and a purge past the
// connection's deadline lost the reply. A fresh create streams the same first and last lines, so the bar names
// nothing: no line carries the profile, the purge or a delete, and only the duration differs.

// createProgTotal is the scale of every create progress line: the purge's own (deleteProfileSE ticks 1..20 of 20).
const createProgTotal = 20

// createProgWindow is how far each progress line rolls the connection's deadline forward.
var createProgWindow = 120 * time.Second

// createProgLine is one progress line of a create's reply.
func createProgLine(done, total int) string {
	return fmt.Sprintf("PROGRESS create %d %d\n", done, total)
}

// createProgRelay returns the prog func createAndReply hands to the create: each call rolls conn's deadline forward
// createProgWindow and writes one line, under a mutex. Deadline and write errors are ignored: a gone reader must not
// fail a create that may still land (the Q048 memo then serves the words).
func createProgRelay(conn net.Conn) func(done, total int) {
	var mu sync.Mutex
	return func(done, total int) {
		mu.Lock()
		defer mu.Unlock()
		_ = conn.SetDeadline(time.Now().Add(createProgWindow))
		_, _ = io.WriteString(conn, createProgLine(done, total))
	}
}
