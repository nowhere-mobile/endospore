package main

// NWP-20261102-09 (Q034, Chester 2026-10-20): a DELETE whose session marker has no uid used to reboot the phone at
// once and lose every other profile's pending sealed texts and calls. handleDelete now reads the caller's Android
// user from the socket (peerUID, as GET-TELINGEST and GET-INGEST do) and, when the marker names no uid and the
// caller is a roamed user, switches to the gate and removes that user like any delete. User 0, a system caller or an
// unreadable peer keeps the reboot with its hold. The marker's uid wins when it has one. These tests drive the real
// handleDelete; test-delete-peer-uid.sh --mutate re-runs them against broken copies of main.go.

import (
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

const (
	dpuPeer      = 1210123 // SO_PEERCRED uid of an app in Android user 12
	dpuUID       = "12"
	dpuOtherUID  = "63"
	dpuMarkerUID = "15"
	dpuName      = "dpu-carol"
)

type dpuRun struct {
	e      *rfpEnv
	reply  string
	sw, rp string
	snap   map[string][]byte
	ln, lp string
}

// dpuDelete drives handleDelete with deleteForSession stubbed to verdict. markerUID "" writes NO marker at all;
// wantReboot is the reason the fallback goroutine must reach before the test ends (waited for in a cleanup, so the
// stubbed rebootHook is still installed when it fires).
func dpuDelete(t *testing.T, verdict, markerUID string, peer int, wantReboot string) *dpuRun {
	t.Helper()
	e := newRfpEnv(t)
	reapSwitchWait = 200 * time.Millisecond // long enough to read the queue after the reply
	r := &dpuRun{e: e}
	old := deleteForSessionFn
	deleteForSessionFn = func(base, name, pass, ln, lp string, _ []byte) string {
		r.ln, r.lp = ln, lp
		return verdict
	}
	t.Cleanup(func() { deleteForSessionFn = old })
	dest := t.TempDir()
	mbPlant(t, dpuUID, true)
	mbPlant(t, dpuOtherUID, false)
	if markerUID != "" {
		if err := markRoamSession(dest, dpuName, "dpu correct horse", markerUID, ""); err != nil {
			t.Fatal(err)
		}
		mbPlant(t, markerUID, true)
	}
	r.snap = mbSnapshot(t)
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
	r.reply = ropReply(t, func(c net.Conn) { handleDelete(c, dest, dpuName, "dpu typed pass", peer) })
	r.sw, r.rp = mbQueue()
	return r
}

func (r *dpuRun) wantQueue(t *testing.T, uid string) {
	t.Helper()
	if r.sw != uid || r.rp != uid {
		t.Errorf("reap queue = (switch %q, reap %q), want both %q", r.sw, r.rp, uid)
	}
}

func (r *dpuRun) wantReply(t *testing.T, want string) {
	t.Helper()
	if r.reply != want {
		t.Errorf("reply %q, want %q", r.reply, want)
	}
}

func TestDeletePeer_NoMarkerUserCallerReapsItsUser(t *testing.T) {
	r := dpuDelete(t, "deleted", "", dpuPeer, "delete reap NOT consumed in 8s (no watcher?) uid="+dpuUID)
	r.wantReply(t, "OK")
	r.wantQueue(t, dpuUID)
	log := r.e.log()
	if !strings.Contains(log, "uid="+dpuUID+" from the caller's socket") {
		t.Errorf("no log line naming uid %s as taken from the caller's socket:\n%s", dpuUID, log)
	}
	for _, l := range strings.Split(log, "\n") {
		if strings.Contains(l, "from the caller's socket") && strings.Contains(l, dpuName) {
			t.Errorf("the derivation line names the profile: %q", l)
		}
	}
	for _, why := range r.e.rebooted() {
		if strings.Contains(why, "delete with no session uid") {
			t.Errorf("the no-uid reboot ran for a caller that names its user: %q", why)
		}
	}
}

func TestDeletePeer_NoMarkerUserCallerPurgedRemovesItsMailboxes(t *testing.T) {
	r := dpuDelete(t, "deleted", "", dpuPeer, "delete reap NOT consumed")
	mbRemoved(t, "deleted", r.snap, mbOfUID(dpuUID))
	mbKept(t, "deleted", r.snap, mbOfUID(dpuOtherUID))
}

func TestDeletePeer_NoMarkerUserCallerNoopKeepsMailboxes(t *testing.T) {
	r := dpuDelete(t, "noop", "", dpuPeer, "delete reap NOT consumed")
	r.wantReply(t, "OK")
	r.wantQueue(t, dpuUID)
	mbKept(t, "noop", r.snap, mbAll)
}

func TestDeletePeer_NoMarkerUserZeroCallerReboots(t *testing.T) {
	r := dpuDelete(t, "deleted", "", 1000, "delete with no session uid")
	r.wantReply(t, "OK")
	r.wantQueue(t, "")
	mbKept(t, "deleted", r.snap, mbAll)
	for _, why := range r.e.rebooted() {
		if strings.Contains(why, "uid=0") {
			t.Errorf("user 0 was queued for a reap: %q", why)
		}
	}
}

func TestDeletePeer_NoMarkerUnknownCallerReboots(t *testing.T) {
	r := dpuDelete(t, "deleted", "", -1, "delete with no session uid")
	r.wantReply(t, "OK")
	r.wantQueue(t, "")
	mbKept(t, "deleted", r.snap, mbAll)
}

func TestDeletePeer_MarkerUIDBeatsThePeer(t *testing.T) {
	r := dpuDelete(t, "deleted", dpuMarkerUID, dpuPeer, "delete reap NOT consumed in 8s (no watcher?) uid="+dpuMarkerUID)
	r.wantReply(t, "OK")
	r.wantQueue(t, dpuMarkerUID)
	mbRemoved(t, "deleted", r.snap, mbOfUID(dpuMarkerUID))
	mbKept(t, "deleted", r.snap, mbOfUID(dpuUID))
	if strings.Contains(r.e.log(), "from the caller's socket") {
		t.Error("the caller's uid was consulted although the marker named one")
	}
}

func TestDeletePeer_DamagedMarkerUserCallerReapsItsUser(t *testing.T) {
	e := newRfpEnv(t)
	reapSwitchWait = 200 * time.Millisecond
	var ln, lp string
	old := deleteForSessionFn
	deleteForSessionFn = func(base, name, pass, l, p string, _ []byte) string { ln, lp = l, p; return "deleted" }
	t.Cleanup(func() { deleteForSessionFn = old })
	dest := t.TempDir()
	writeMarker(t, dest, dpuName+"\ndpu correct horse\n")
	t.Cleanup(func() {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			for _, why := range e.rebooted() {
				if strings.Contains(why, "delete reap NOT consumed") {
					return
				}
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Errorf("the fallback never reached rebootHook (got %q)", e.rebooted())
	})
	reply := ropReply(t, func(c net.Conn) { handleDelete(c, dest, dpuName, "dpu typed pass", dpuPeer) })
	sw, rp := mbQueue()
	if reply != "OK" || sw != dpuUID || rp != dpuUID {
		t.Errorf("reply %q queue (%q, %q), want OK and %q", reply, sw, rp, dpuUID)
	}
	if ln != dpuName || lp != "dpu correct horse" {
		t.Errorf("deleteForSession was given (%q, %q), want the damaged marker's credentials", ln, lp)
	}
}

func TestDeletePeer_DispatcherPassesThePeerUID(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, l := range stripComments(funcBody(t, string(b), "handleLogin")) {
		if strings.Contains(l, "handleDeleteFn(") {
			found = true
			if !strings.Contains(l, "peerUID(conn)") {
				t.Errorf("the DELETE arm does not pass peerUID(conn): %s", strings.TrimSpace(l))
			}
		}
	}
	if !found {
		t.Fatal("handleLogin has no handleDeleteFn call -- this test is stale, not the code")
	}
}
