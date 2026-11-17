package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
)

// NWP-20261205-01 (h58 #1, docs/product-decisions.md 2026-11-04): the gate verb that hands the session's chooser the
// line the agent slice (NWP-20261204-01) leaves in $STATE/lastsave.<uid> when the profile's last seal round left a
// scope unsaved. Framing only: the chooser parses the parts. Until that slice is on main no file exists and the verb
// answers NONE.

// lastSaveWire returns "LASTSAVE " + the one line in <dir>/lastsave.<uid> without its LF, or "NONE" when the uid is
// not all digits, the file is absent or unreadable, over 256 bytes (the agent slice's lastSaveMax), not exactly one
// LF-terminated line, or not a v=1 line.
func lastSaveWire(dir, uid string) string {
	if uid == "" || strings.Trim(uid, "0123456789") != "" {
		return "NONE"
	}
	f, err := os.Open(filepath.Join(dir, "lastsave."+uid))
	if err != nil {
		return "NONE"
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 257))
	if err != nil {
		return "NONE"
	}
	if len(b) > 256 {
		return "NONE"
	}
	line, ok := strings.CutSuffix(string(b), "\n")
	if !ok {
		return "NONE"
	}
	if strings.ContainsAny(line, "\r\n") {
		return "NONE"
	}
	if !strings.HasPrefix(line, "v=1 unsaved=") {
		return "NONE"
	}
	return "LASTSAVE " + line
}

// handleGetLastSave answers "GET-LASTSAVE" with lastSaveWire for the live session's own user. No session, a damaged
// marker, a throwaway or offline session (which ran no `in` arm, so a recycled uid's leftover could be read) and any
// other caller all get NONE, the same as no file (blind rule). One count line: no name, no parts, no path. No lock,
// no store, no worker op, no write.
func handleGetLastSave(conn net.Conn, dest string) {
	reply := "NONE"
	_, _, uid := readRoamSession(dest)
	switch {
	case uid == "":
	case localOnlySession(dest):
	case !sessionCaller(conn, uid):
	default:
		reply = lastSaveWire(dest, uid)
	}
	if reply == "NONE" {
		fmt.Fprint(os.Stderr, "[logind] get-lastsave: none\n")
	} else {
		fmt.Fprint(os.Stderr, "[logind] get-lastsave: unsaved\n")
	}
	fmt.Fprint(conn, reply+"\n")
}
