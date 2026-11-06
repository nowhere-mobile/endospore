package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #49: ROAM-IN-OFFLINE lands an EMPTY session with NO store I/O -- marked LOCAL (seals gated off, so it can
// never overwrite the real stored head, #72) AND OFFLINE (distinguishes it from an intentional throwaway), with
// the roam session recorded so a later online re-auth reuses the creds, and the roamed apps/prefs surfaces
// cleared so provisioning installs base apps only.
func TestHandleRoamInOffline(t *testing.T) {
	dest := t.TempDir()
	os.WriteFile(filepath.Join(dest, "apps.out"), []byte("com.example.stale\n"), 0o600) // must be cleared

	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, "alice", "correct horse battery", "12"); srv.Close() }()
	buf, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(buf)); got != "OK 12" {
		t.Fatalf("reply = %q, want %q", got, "OK 12")
	}

	if !isLocalSession(dest) {
		t.Error("offline session must be marked LOCAL (seals gated off)")
	}
	if !isOfflineSession(dest) {
		t.Error("offline session must be marked OFFLINE")
	}
	if n, p, u := readRoamSession(dest); n != "alice" || p != "correct horse battery" || u != "12" {
		t.Errorf("roam session = (%q,%q,%q), want (alice, correct horse battery, 12)", n, p, u)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "apps.out")); len(b) != 0 {
		t.Errorf("apps.out must be cleared to base-only, got %q", b)
	}

	// A resolved ONLINE login later clears the offline marker (defensive path in handleRoamIn).
	clearOfflineSession(dest)
	if isOfflineSession(dest) {
		t.Error("clearOfflineSession should remove the marker")
	}
	if !isLocalSession(dest) {
		t.Error("clearing OFFLINE must not touch the LOCAL marker")
	}
}

// Missing name/uid -> BLANK, no markers written.
func TestHandleRoamInOfflineBlank(t *testing.T) {
	dest := t.TempDir()
	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, "", "pw", ""); srv.Close() }()
	buf, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(buf)); got != "BLANK" {
		t.Fatalf("reply = %q, want BLANK", got)
	}
	if isOfflineSession(dest) || isLocalSession(dest) {
		t.Error("a rejected offline login must not mark any session")
	}
}
