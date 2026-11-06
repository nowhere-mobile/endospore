package main

// NWP-20261028-01 (backlog §C, "On a dead network a sign-in takes minutes to go local and an offline delete outlasts
// the screen's wait"). A DELETE against a store the daemon cannot reach panics out of deleteForSession (checkRead's
// storeReadErr) with nothing written to the chooser, which rendered "the phone didn't answer, so the delete may or may
// not have gone through". handleDelete now answers ERR-STORE and keeps the session. These tests drive the real
// handleDelete; test-delete-unreachable.sh --mutate re-runs them against broken copies of main.go.

import (
	"errors"
	"fmt"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// durRun drives handleDelete over a marker for mbUID with deleteForSessionFn replaced by fn, and returns the reply.
// wantReboot, when set, names the reboot reason the reap fallback of a successful delete must reach: the test waits
// for it in a cleanup (registered after newRfpEnv's, so it runs first) before the process globals are restored.
func durRun(t *testing.T, wantReboot string, fn func(base, name, pass, ln, lp string, se []byte) string) (reply, dest string) {
	t.Helper()
	e := newRfpEnv(t)
	ropReapReset(t)
	reapSwitchWait = 200 * time.Millisecond
	dest = t.TempDir()
	old := deleteForSessionFn
	deleteForSessionFn = fn
	t.Cleanup(func() { deleteForSessionFn = old })
	if err := markRoamSession(dest, "dur-alice", "dur correct horse", mbUID, ""); err != nil {
		t.Fatal(err)
	}
	if wantReboot != "" {
		t.Cleanup(func() {
			deadline := time.Now().Add(5 * time.Second)
			for time.Now().Before(deadline) {
				for _, why := range e.rebooted() {
					if strings.Contains(why, wantReboot) {
						return
					}
				}
				time.Sleep(10 * time.Millisecond)
			}
			t.Errorf("the fallback never reached rebootHook with %q (got %q)", wantReboot, e.rebooted())
		})
	}
	reply = ropReply(t, func(c net.Conn) {
		// A panic out of handleDelete is the bug under test: report it as a reply instead of crashing the binary.
		defer func() {
			if r := recover(); r != nil {
				fmt.Fprintf(c, "PANIC %v", r)
			}
		}()
		handleDelete(c, dest, "dur-alice", "dur typed pass", -1)
	})
	return reply, dest
}

func durWantKept(t *testing.T, dest string) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err != nil {
		t.Errorf(".roamsession did not survive: %v", err)
	}
	if sw, rp := mbQueue(); sw != "" || rp != "" {
		t.Errorf("reap queue = (switch %q, reap %q), want both empty", sw, rp)
	}
}

func TestDeleteUnreachable_StoreReadPanicAnswersErrStore(t *testing.T) {
	reply, dest := durRun(t, "", func(string, string, string, string, string, []byte) string {
		panic(storeReadErr{errors.New("dial tcp: no route")})
	})
	if reply != "ERR-STORE" {
		t.Errorf("reply %q, want ERR-STORE", reply)
	}
	durWantKept(t, dest)
}

func TestDeleteUnreachable_OtherPanicsPropagateWithNothingWritten(t *testing.T) {
	for _, tc := range []struct {
		label string
		val   any
	}{
		{"string", "corrupt blob"},
		{"plain error", errors.New("not a transport failure")},
	} {
		t.Run(tc.label, func(t *testing.T) {
			newRfpEnv(t)
			ropReapReset(t)
			old := deleteForSessionFn
			deleteForSessionFn = func(string, string, string, string, string, []byte) string { panic(tc.val) }
			t.Cleanup(func() { deleteForSessionFn = old })
			dest := t.TempDir()
			if err := markRoamSession(dest, "dur-bob", "dur correct horse", mbUID, ""); err != nil {
				t.Fatal(err)
			}
			cli, srv := net.Pipe()
			defer cli.Close()
			var got any
			done := make(chan struct{})
			go func() {
				defer close(done)
				defer func() { got = recover(); srv.Close() }()
				handleDelete(srv, dest, "dur-bob", "dur typed pass", -1)
			}()
			buf := make([]byte, 64)
			n, _ := cli.Read(buf)
			<-done
			if got == nil {
				t.Fatalf("the panic was swallowed")
			}
			if n != 0 {
				t.Errorf("wrote %q to the conn before panicking", buf[:n])
			}
		})
	}
}

func TestDeleteUnreachable_RealDeleteAgainstADeadStore(t *testing.T) {
	srv := httptest.NewServer(nil)
	dead := srv.URL
	srv.Close()
	reply, dest := durRun(t, "", func(_, name, pass, ln, lp string, _ []byte) string {
		return deleteForSession(dead, name, pass, ln, lp, nil)
	})
	if reply != "ERR-STORE" {
		t.Errorf("reply %q, want ERR-STORE", reply)
	}
	durWantKept(t, dest)
}

func TestDeleteUnreachable_OtherVerdictsUnchanged(t *testing.T) {
	for _, tc := range []struct{ verdict, reply string }{
		{"wrongpass", "NOTFOUND"},
		{"unverified", "ERR-STORE"},
		{"deleted", "OK"},
	} {
		t.Run(tc.verdict, func(t *testing.T) {
			want := ""
			if tc.verdict == "deleted" {
				want = "delete reap NOT consumed"
			}
			reply, dest := durRun(t, want, func(string, string, string, string, string, []byte) string { return tc.verdict })
			if reply != tc.reply {
				t.Errorf("reply %q, want %q", reply, tc.reply)
			}
			if tc.verdict == "deleted" {
				if sw, rp := mbQueue(); sw != mbUID || rp != mbUID {
					t.Errorf("reap queue = (%q, %q), want both %q", sw, rp, mbUID)
				}
			} else {
				durWantKept(t, dest)
			}
		})
	}
}
