package main

// NWP-20261002-03: GET-DOZE-APPS is framed so the gate can tell a FAILED read from "this profile has no choices".
// The gate arms its live Doze record only on a read it knows succeeded; an unframed empty reply let a failed read
// pass as an empty set, and a live capture could then seal a shrunken record.

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func getDozeAppsReply(t *testing.T, dest string) string {
	t.Helper()
	server, client := net.Pipe()
	done := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(client)
		done <- string(b)
	}()
	handleGetDozeApps(server, dest)
	server.Close()
	reply := <-done
	client.Close()
	return reply
}

func TestGetDozeAppsFramesTheSet(t *testing.T) {
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, "doze-apps.out"), []byte("a.b\nc.d\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, want := getDozeAppsReply(t, dest), "OK\na.b\nc.d\n"; got != want {
		t.Errorf("reply %q, want %q -- the set must follow an OK header", got, want)
	}
}

func TestGetDozeAppsEmptySetIsStillOK(t *testing.T) {
	dest := t.TempDir() // a profile with no choices, or an offline roam-in: the file exists and is empty
	if err := os.WriteFile(filepath.Join(dest, "doze-apps.out"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got, want := getDozeAppsReply(t, dest), "OK\n"; got != want {
		t.Errorf("reply %q, want %q -- an empty set is a successful read", got, want)
	}
}

func TestGetDozeAppsHeaderAndSetAreOneWrite(t *testing.T) {
	dest := t.TempDir() // a reply torn after a separately written header would read as a complete, empty set
	if err := os.WriteFile(filepath.Join(dest, "doze-apps.out"), []byte("a.b\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	server, client := net.Pipe()
	first := make(chan string, 1)
	go func() {
		buf := make([]byte, 256)
		n, _ := client.Read(buf) // net.Pipe hands over one Write per Read when the buffer is large enough
		first <- string(buf[:n])
		io.Copy(io.Discard, client)
	}()
	handleGetDozeApps(server, dest)
	server.Close()
	got := <-first
	client.Close()
	if want := "OK\na.b\n"; got != want {
		t.Errorf("first read %q, want %q -- the header and the set must be written together", got, want)
	}
}

func TestGetDozeAppsMissingFileIsERR(t *testing.T) {
	dest := t.TempDir() // roamd removes the file when its copy fails; never written means never surfaced
	if got, want := getDozeAppsReply(t, dest), "ERR\n"; got != want {
		t.Errorf("reply %q, want %q -- a failed read must not look like an empty set", got, want)
	}
}
