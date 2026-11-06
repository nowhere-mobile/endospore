package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261013-31: a ROAM-IN the daemon cannot record is answered ERR-UNRECORDED on BOTH paths. BLANK was wrong
// twice over: after restore progress the chooser renders it as the snapshot-recovery offer (a permanent rollback)
// and without progress as the blind "check your name". The fault is credential-independent -- markRoamSession
// runs before the empty-head throwaway branch -- so a distinct reply is not an existence oracle.

// Driven: .roamsession is a directory, so both of markRoamSession's writes fail.
func TestRoamInOfflineMarkerFailureRepliesUnrecorded(t *testing.T) {
	dest := t.TempDir()
	if err := os.Mkdir(filepath.Join(dest, roamSessionFile), 0o700); err != nil {
		t.Fatal(err)
	}
	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, "alice", "pw", "12"); srv.Close() }()
	buf, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(buf)); got != "ERR-UNRECORDED" {
		t.Fatalf("reply = %q, want ERR-UNRECORDED", got)
	}
	if isLocalSession(dest) || isOfflineSession(dest) {
		t.Error("a refused offline login must not mark any session")
	}
}

// handleRoamIn cannot be driven without a store and worker, so its marker branch is pinned by source: the reply
// written inside `if err := markRoamSession(` ... `{` block in handleRoamIn is ERR-UNRECORDED.
func TestRoamInOnlineMarkerFailureRepliesUnrecorded(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	i := strings.Index(s, "func handleRoamIn(")
	j := strings.Index(s, "func handleRoamInOffline(")
	if i < 0 || j < i {
		t.Fatal("handleRoamIn / handleRoamInOffline not found in order")
	}
	body := s[i:j]
	re := regexp.MustCompile(`(?s)if err := markRoamSession\(dest, name, pass, uid, seSecret\); err != nil \{.*?\n\t\t\}`)
	blk := re.FindString(body)
	if blk == "" {
		t.Fatal("handleRoamIn's markRoamSession failure branch not found")
	}
	if !strings.Contains(blk, `fmt.Fprint(conn, "ERR-UNRECORDED\n")`) || strings.Contains(blk, `"BLANK`) {
		t.Errorf("handleRoamIn marker failure must reply ERR-UNRECORDED and never BLANK:\n%s", blk)
	}
}
