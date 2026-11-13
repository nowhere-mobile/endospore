package main

// NWP-20261010-06: THE uiderrors FLOOR LIVES EXACTLY AS LONG AS ITS SESSION.
//
// roamd's `in` records the floor (the file's size at sign-in) and the report shows only lines past it. The floor
// sits in the state dir, and handleLogout -- the real Arc-2 logoff -- does not wipe that dir. So without the daemon
// dropping it, an older session's floor survived logout, and an OFFLINE sign-in (which never runs `in`) read from
// it: its report then said "appended since this session signed in" about the previous session's lines. These tests
// drive the two paths that can be driven and pin the rest in the source.

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func plantFloor(t *testing.T, dest string) string {
	t.Helper()
	p := filepath.Join(dest, uiderrorsFloorFile)
	if err := os.WriteFile(p, []byte("123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// Logout, then an OFFLINE sign-in: the report must say NOT collected, never present the earlier session's lines.
func TestUiderrorsFloor_OfflineSignInAfterALogoutIsNotCollected(t *testing.T) {
	dest := t.TempDir()
	floor := plantFloor(t, dest) // what S1's online sign-in left behind
	stop := ropWorker(t, dest)   // answers the btwipe at once, instead of the 150 s stall budget
	defer stop()
	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, "alice", "correct horse battery", "12"); srv.Close() }()
	buf, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(buf)); got != "OK 12" {
		t.Fatalf("offline sign-in replied %q", got)
	}
	if _, err := os.Stat(floor); !os.IsNotExist(err) {
		t.Fatalf("an offline sign-in kept the previous session's floor (%v) -- its report would read that session's lines as its own", err)
	}
	// The chain the device runs: roamd reads the (now absent) floor file into the agent's argument.
	b, _ := os.ReadFile(floor)
	p := filepath.Join(t.TempDir(), "uiderrors.txt")
	os.WriteFile(p, []byte("10/10/26, 5:04 PM: Destroying /data/user_de/12/com.previous.session due to: x\n"), 0o644)
	got := joined(t, uiderrorsSection(func() string { return uiderrorsTail(p, 1<<16, string(b), "12") }, nil))
	if !strings.Contains(got, "NOT collected -- ERR-NOFLOOR") || strings.Contains(got, "previous.session") {
		t.Errorf("an offline session's report must say NOT collected (no floor):\n%s", got)
	}
}

// A throwaway's logout ends its session on the spot -- nothing re-arms it -- so its floor goes with it.
func TestUiderrorsFloor_ThrowawayLogoutDropsIt(t *testing.T) {
	ropStore(t)
	ropReapReset(t)
	dest := ropThrowaway(t, ropName, ropPass)
	floor := plantFloor(t, dest)
	stop := ropWorker(t, dest)
	got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	time.Sleep(200 * time.Millisecond)
	stop()
	if got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	if _, err := os.Stat(floor); !os.IsNotExist(err) {
		t.Errorf("a throwaway logout kept its floor (%v)", err)
	}
}

// fileFuncBody is syncloop_lock_test.go's funcBody over a file read here, joined back into one string.
func fileFuncBody(t *testing.T, file, name string) string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Join(funcBody(t, string(b), name), "\n")
}

// The paths that cannot be driven cheaply, pinned in the source: every one that ENDS a session drops the floor,
// and none that CONTINUES one does -- a cold lock resumes, a rotate or promote keeps the session, a re-armed
// logoff is the wedged session whose report needs its lines most (NWP-20260910-10).
func TestUiderrorsFloor_DroppedWhereASessionEndsAndOnlyThere(t *testing.T) {
	const call = "forgetUiderrorsFloor(dest)"
	for _, c := range []struct{ file, fn string }{
		{"main.go", "handleRoamInOffline"}, {"main.go", "handleDelete"}, {"main.go", "handleRollback"},
		{"coldlock_evict.go", "handleClaimColdLock"}, {"roamsession_marker.go", "clearMarkerOfGoneUser"},
	} {
		if !strings.Contains(fileFuncBody(t, c.file, c.fn), call) {
			t.Errorf("%s ends a session but does not drop its uiderrors floor", c.fn)
		}
	}
	for _, fn := range []string{"coldLockTeardown", "handleResume", "handleRotate", "handlePromote2", "handleRoamIn"} {
		if strings.Contains(fileFuncBody(t, "main.go", fn), call) {
			t.Errorf("%s continues (or, for handleRoamIn, re-records) a session, yet drops its floor", fn)
		}
	}
	// CLEAR-COLDLOCK must NOT drop it: its one caller is the chooser's #123 supersede, AFTER a fresh sign-in, so the
	// floor there is the NEW session's (TestUiderrorsFloor_ClearColdLockKeepsTheNewSessionsFloor drives it).
	m, _ := os.ReadFile("main.go")
	src := string(m)
	if i := strings.Index(src, `if name == "CLEAR-COLDLOCK" {`); i < 0 {
		t.Error("no CLEAR-COLDLOCK branch to check")
	} else if j := strings.Index(src[i:], "return"); strings.Contains(src[i:i+j], call) {
		t.Error("CLEAR-COLDLOCK drops the floor -- it runs after a fresh sign-in, so that is the NEW session's floor")
	}
	// handleLogout: once in the throwaway branch, once where the seal LANDED -- never where .roamsession goes,
	// because a refused or failed seal re-arms that same session.
	lo := fileFuncBody(t, "main.go", "handleLogout")
	if n := strings.Count(lo, call); n != 2 {
		t.Errorf("handleLogout drops the floor %d times, want 2 (throwaway branch, landed seal)", n)
	}
	landed := strings.Index(lo, "seal landed -> NOW switch")
	if landed < 0 {
		t.Fatal("handleLogout no longer has the landed-seal anchor")
	}
	// NWP-20261014-66: the landed values are set inside the verdict's critical section (a closure released from a
	// defer), and the two keep-signed-in arms act after it; the landed path starts once the second arm has returned.
	arm := strings.Index(lo, `"late logout verdict after unstick, re-arm")`)
	if arm < landed {
		t.Fatal("handleLogout no longer has the unstuck arm's re-arm after the verdict section")
	}
	after := lo[arm:]
	after = after[strings.Index(after, "return")+len("return"):] // past the arm's own return
	if k := strings.Index(after, call); k < 0 || strings.Contains(after[:k], "return") {
		t.Error("handleLogout's second drop is not on the landed-seal path -- a wedged logoff would lose its floor, or a landed one keep it")
	}
}

// The #123 supersede: a fresh sign-in's `in` has committed ITS floor, then the chooser clears the superseded cold
// lock's marker. That clear must leave the floor alone, or every session signed in over a cold lock -- the default
// resumable-cold path -- reports NOT collected for its whole life.
func TestUiderrorsFloor_ClearColdLockKeepsTheNewSessionsFloor(t *testing.T) {
	gatePeer(t, 10123)
	dest := t.TempDir()
	// the superseded session's marker, and the new session's floor from its own `in`
	os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("alice\n15\n\n\n\n\n\n"), 0o600)
	floor := plantFloor(t, dest)
	if got := evictConn(t, dest, "CLEAR-COLDLOCK\n"); got != "OK" {
		t.Fatalf("CLEAR-COLDLOCK replied %q", got)
	}
	if clwExists(dest, ".coldlock") {
		t.Fatal("CLEAR-COLDLOCK kept the marker; the test is not exercising the branch")
	}
	if b, err := os.ReadFile(floor); err != nil || strings.TrimSpace(string(b)) != "123" {
		t.Errorf("CLEAR-COLDLOCK took the new session's floor (%q, %v)", b, err)
	}
}
