package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261011-21: GET-USAGE's NONE arm leaves a line in login.log. On 2026-09-10 the Storage screen showed a bare
// dash and nothing anywhere said why; the cause (an absent .roamsession, NWP-20260910-02) had to be inferred from a
// screenshot plus a code read. These pin the reply the chooser reads AND the line the issue reporter carries.

const getUsageNoneLine = "[logind] GET-USAGE -> NONE: no live session recorded (.roamsession absent or empty)\n"

// getUsageReply drives handleGetUsage over a pipe and returns the raw reply bytes and everything it wrote to stderr.
func getUsageReply(t *testing.T, dest string) (reply, stderr string) {
	t.Helper()
	stderr = captureStderr(t, func() {
		c1, c2 := net.Pipe()
		go func() {
			handleGetUsage(c2, dest)
			c2.Close()
		}()
		raw, err := io.ReadAll(c1)
		if err != nil {
			t.Fatalf("reading the GET-USAGE reply: %v", err)
		}
		reply = string(raw)
	})
	return reply, stderr
}

func TestGetUsageWithNoSessionMarkerRepliesNoneAndSaysWhy(t *testing.T) {
	dest := t.TempDir() // no .roamsession: the state the 2026-09-10 handset was in
	reply, stderr := getUsageReply(t, dest)
	if reply != "NONE\n" {
		t.Errorf("reply = %q, want exactly %q -- the chooser's usageNoAnswer keys on it", reply, "NONE\n")
	}
	if strings.Count(stderr, getUsageNoneLine) != 1 {
		t.Errorf("stderr = %q, want the line %q exactly once.\n"+
			"  Without it a NONE reaches the screen with nothing in login.log to say which failure it was.",
			stderr, getUsageNoneLine)
	}
}

// The line is the NONE arm's, not a GET-USAGE banner: a session that IS recorded must not log it. A complete
// marker plus .localsession takes the LOCAL arm, which needs no store, so this stays offline.
func TestGetUsageWithALiveSessionDoesNotLogNone(t *testing.T) {
	dest := t.TempDir()
	writeMarker(t, dest, tName+"\n"+tPass+"\n11\n")
	if err := os.WriteFile(filepath.Join(dest, ".localsession"), nil, 0o600); err != nil {
		t.Fatalf("stage .localsession: %v", err)
	}
	reply, stderr := getUsageReply(t, dest)
	if reply != "LOCAL\n" {
		t.Errorf("reply = %q, want %q", reply, "LOCAL\n")
	}
	if strings.Contains(stderr, "GET-USAGE -> NONE") {
		t.Errorf("a recorded session logged the NONE line: %q", stderr)
	}
	if strings.Contains(stderr, tName) || strings.Contains(stderr, tPass) {
		t.Errorf("stderr carries a session value: %q", stderr)
	}
}
