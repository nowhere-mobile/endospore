package main

// NWP-20261021-10 (backlog §B, "Legacy `CREATE` + `LOGOFF` can still wipe the shared roam-state tmpfs mid-session --
// and, until `NWP-20260924-04`, at the gate, where it destroyed undelivered sealed telephony records"). The two
// mailbox rules, driven through the real handlers:
//
//   - a delete (Chester, 2026-09-24, product-decisions.md, Open section, answer 2) removes every mailbox file of the
//     session's uid -- bare and per-SIM -- only when a stored profile was deleted (verdict deleted or gone), never for
//     noop, wrongpass or unverified, and never another uid's;
//   - a logoff that re-arms the session (the seal failed, the media sweep did not verify, the watchdog un-stuck a
//     stalled seal) keeps the session's mailbox; its only mailbox write is logoffStageInbox's append (NWP-20261019-04).
//
// These replace two source pins in telrecord_survives_test.go. TestFailedLogoutSealKeepsTheMailbox scanned only the
// failed-seal branch of handleLogout, so a removal in the media-sweep or stall arm, which re-arm the session just the
// same, passed it. TestDeleteRemovesTheSessionMailbox pinned the text `if uid != "" && purged {` and counted
// `purged = true`, so a `purged = false` after the switch passed it; its reason for not driving handleDelete (a real
// rebootNow) stopped being true when NWP-20261017-07 added rebootHook. handleDelete's call into deleteForSession is a
// var (deleteForSessionFn) so each verdict is stubbed. test-mailbox-rules.sh --mutate re-runs this file against
// broken copies of main.go.

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	mbUID      = "61" // the deleted/logged-off session
	mbOtherUID = "62" // another uid's mailbox, which no rule here may touch
)

var mbTag = simTag("8944000000000000001")

func mbPlant(t *testing.T, uid string, perSim bool) {
	t.Helper()
	it := telItem{Kind: "sms", From: "+1", When: 1, Body: "b"}
	if err := appendTelIngest(uid, "", it); err != nil {
		t.Fatal(err)
	}
	want := 1
	if perSim {
		if err := appendTelIngest(uid, mbTag, it); err != nil {
			t.Fatal(err)
		}
		want = 2
	}
	if got := len(mailboxFiles(uid)); got != want {
		t.Fatalf("planted %d mailbox file(s) for uid %s, want %d", got, uid, want)
	}
}

// mbSnapshot reads every mailbox file under telIngestBase.
func mbSnapshot(t *testing.T) map[string][]byte {
	t.Helper()
	ents, err := os.ReadDir(telIngestBase)
	if err != nil {
		t.Fatal(err)
	}
	snap := map[string][]byte{}
	for _, e := range ents {
		if !e.Type().IsRegular() || !strings.HasPrefix(e.Name(), "telingest.") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(telIngestBase, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		snap[e.Name()] = b
	}
	if len(snap) == 0 {
		t.Fatal("no mailbox file was planted")
	}
	return snap
}

// mbKept asserts every snapshot file whose name keep accepts is still there, byte for byte.
func mbKept(t *testing.T, what string, snap map[string][]byte, keep func(name string) bool) {
	t.Helper()
	for name, want := range snap {
		if !keep(name) {
			continue
		}
		got, err := os.ReadFile(filepath.Join(telIngestBase, name))
		if err != nil {
			t.Errorf("%s: %s is gone: %v", what, name, err)
		} else if !bytes.Equal(got, want) {
			t.Errorf("%s: %s changed", what, name)
		}
	}
}

// mbRemoved asserts every snapshot file whose name sel accepts is gone.
func mbRemoved(t *testing.T, what string, snap map[string][]byte, sel func(name string) bool) {
	t.Helper()
	n := 0
	for name := range snap {
		if !sel(name) {
			continue
		}
		n++
		if _, err := os.Stat(filepath.Join(telIngestBase, name)); !os.IsNotExist(err) {
			t.Errorf("%s: %s is still there (stat error %v)", what, name, err)
		}
	}
	if n == 0 {
		t.Fatalf("%s: nothing was selected -- the test is stale", what)
	}
}

func mbOfUID(uid string) func(string) bool {
	return func(name string) bool {
		return name == "telingest."+uid || strings.HasPrefix(name, "telingest."+uid+".")
	}
}

func mbAll(string) bool { return true }

func mbQueue() (sw, rp string) {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return pendingSwitchUID, pendingReapUID
}

type mbRun struct {
	e      *rfpEnv
	dest   string
	snap   map[string][]byte
	marker []byte
	reply  string
	sw, rp string
	ln, lp string
}

// mbDelete drives the real handleDelete with deleteForSession stubbed to verdict, over a marker of the given shape
// and a mailbox for mbUID (bare and per-SIM) and one for mbOtherUID. wantReboot names the reboot reason the daemon's
// fallback goroutine must reach: the test waits for it before returning (a cleanup, so it runs after a Fatal too),
// because once newRfpEnv's cleanup has run rebootHook is nil and the real rebootNow would run on the host.
func mbDelete(t *testing.T, verdict string, complete bool, wantReboot string) *mbRun {
	t.Helper()
	e := newRfpEnv(t)
	// Long enough that the queue can be read after the reply, before the fallback clears it; newRfpEnv's cleanup
	// restores the production value.
	reapSwitchWait = 200 * time.Millisecond
	r := &mbRun{e: e, dest: t.TempDir()}
	old := deleteForSessionFn
	deleteForSessionFn = func(base, name, pass, ln, lp string, _ []byte) string {
		r.ln, r.lp = ln, lp
		return verdict
	}
	t.Cleanup(func() { deleteForSessionFn = old })
	if complete {
		if err := markRoamSession(r.dest, "alice", "correct horse", mbUID, ""); err != nil {
			t.Fatal(err)
		}
	} else {
		writeMarker(t, r.dest, "alice\ncorrect horse\n")
	}
	var err error
	if r.marker, err = os.ReadFile(filepath.Join(r.dest, ".roamsession")); err != nil {
		t.Fatal(err)
	}
	mbPlant(t, mbUID, true)
	mbPlant(t, mbOtherUID, false)
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
	r.reply = ropReply(t, func(c net.Conn) { handleDelete(c, r.dest, "alice", "typed pass", -1) })
	r.sw, r.rp = mbQueue()
	return r
}

func (r *mbRun) wantMarkerGone(t *testing.T, gone bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(r.dest, ".roamsession"))
	if gone {
		if !os.IsNotExist(err) {
			t.Errorf("the marker is still there (%v)", err)
		}
	} else if err != nil || !bytes.Equal(b, r.marker) {
		t.Errorf("the marker changed (%v)", err)
	}
}

func (r *mbRun) wantQueue(t *testing.T, uid string) {
	t.Helper()
	if r.sw != uid || r.rp != uid {
		t.Errorf("reap queue = (switch %q, reap %q), want both %q", r.sw, r.rp, uid)
	}
}

func (r *mbRun) wantReply(t *testing.T, want string) {
	t.Helper()
	if r.reply != want {
		t.Errorf("reply %q, want %q", r.reply, want)
	}
}

func (r *mbRun) wantStubSawMarker(t *testing.T) {
	t.Helper()
	if r.ln != "alice" || r.lp != "correct horse" {
		t.Errorf("deleteForSession was given (%q, %q), want the marker's credentials", r.ln, r.lp)
	}
}

func mbWantPurged(t *testing.T, verdict, reply string) {
	r := mbDelete(t, verdict, true, "delete reap NOT consumed")
	r.wantReply(t, reply)
	r.wantStubSawMarker(t)
	mbRemoved(t, verdict, r.snap, mbOfUID(mbUID))
	mbKept(t, verdict, r.snap, mbOfUID(mbOtherUID))
	r.wantMarkerGone(t, true)
	r.wantQueue(t, mbUID)
}

func TestMailboxRules_DeleteDeletedRemovesTheSessionsMailboxes(t *testing.T) {
	mbWantPurged(t, "deleted", "OK")
}

func TestMailboxRules_DeleteGoneRemovesTheSessionsMailboxes(t *testing.T) {
	mbWantPurged(t, "gone", "OK GONE")
}

func TestMailboxRules_DeleteNoopKeepsEveryMailbox(t *testing.T) {
	r := mbDelete(t, "noop", true, "delete reap NOT consumed")
	r.wantReply(t, "OK")
	mbKept(t, "noop", r.snap, mbAll)
	r.wantMarkerGone(t, true)
	r.wantQueue(t, mbUID)
}

func TestMailboxRules_DeleteWrongPassTouchesNothing(t *testing.T) {
	r := mbDelete(t, "wrongpass", true, "")
	r.wantReply(t, "NOTFOUND")
	mbKept(t, "wrongpass", r.snap, mbAll)
	r.wantMarkerGone(t, false)
	r.wantQueue(t, "")
}

func TestMailboxRules_DeleteUnverifiedTouchesNothing(t *testing.T) {
	r := mbDelete(t, "unverified", true, "")
	r.wantReply(t, "ERR-STORE")
	mbKept(t, "unverified", r.snap, mbAll)
	r.wantMarkerGone(t, false)
	r.wantQueue(t, "")
}

// A marker that lost its uid names no session, so no mailbox is removed -- of any uid -- and the no-uid reboot
// fallback is what ends the session.
func TestMailboxRules_DeleteWithNoUidRemovesNoMailbox(t *testing.T) {
	r := mbDelete(t, "deleted", false, "delete with no session uid")
	r.wantReply(t, "OK")
	mbKept(t, "no uid", r.snap, mbAll)
	r.wantMarkerGone(t, true)
	r.wantQueue(t, "")
}

// mbLogoff drives handleLogout of a stored session through worker answers that make it re-arm, and asserts the
// session's mailbox is byte-identical afterwards. Exactly one logoffStageInbox call must have been made, so a run
// that never reached a re-arm arm cannot pass.
func mbLogoff(t *testing.T, uid string, answers map[string]string, hold map[string]time.Duration, stall bool) {
	t.Helper()
	useTempIngest(t)
	dest := rearmSession(t, uid)
	calls := recordStaging(t, dest)
	mbPlant(t, uid, true)
	snap := mbSnapshot(t)
	if stall {
		shortStall(t, 300*time.Millisecond)
	}
	cutoffWorker(t, dest, answers, hold)
	ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
	if stall {
		deadline := time.Now().Add(15 * time.Second)
		for len(calls()) == 0 {
			if time.Now().After(deadline) {
				t.Fatal("the watchdog's unstick never re-armed the session")
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	logoffDone(t, uid, 20*time.Second)
	if n := len(calls()); n != 1 {
		t.Fatalf("%d re-arm staging calls, want 1 -- the run did not reach a re-arm arm", n)
	}
	mbKept(t, "re-armed logoff", snap, mbAll)
	if got := len(mailboxFiles(uid)); got != 2 {
		t.Errorf("%d mailbox files left for uid %s, want 2", got, uid)
	}
}

func TestMailboxRules_AFailedLogoffSealKeepsTheMailbox(t *testing.T) {
	mbLogoff(t, "91", rearmAnswers(map[string]string{"out": "ERR-PUSH 1"}), nil, false)
}

func TestMailboxRules_AFailedMediaSweepKeepsTheMailbox(t *testing.T) {
	t.Cleanup(resetMediaStuck)
	mbLogoff(t, "92", rearmAnswers(map[string]string{"sweepmedia": "ERR-MEDIA-SWEEP 1"}), nil, false)
}

func TestMailboxRules_AStalledSealKeepsTheMailbox(t *testing.T) {
	mbLogoff(t, "93", rearmAnswers(nil), map[string]time.Duration{"out": 2 * time.Second}, true)
}
