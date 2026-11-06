package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20261125-15 (h45 #2, h53 #4, h48 #3): RERUN-REAP re-queues the REAP that a dead daemon lost, for a user that no
// live session and no cold lock holds, and sends no save. The queue is package-global, so nothing here is parallel.

// rrReset clears the four teardown phases and the seal flags, and clears them again at cleanup.
func rrReset(t *testing.T) {
	t.Helper()
	reset := func() {
		pendingReapMu.Lock()
		pendingSwitchUID, pendingReapUID, pendingLockUID, pendingRearmUID = "", "", "", ""
		sealInFlight, sealRunKind = false, ""
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

// rrUsers redirects androidUsersDir to a temp dir that holds user 0 and each uid given.
func rrUsers(t *testing.T, uids ...string) {
	t.Helper()
	dir := useTempUsersDir(t)
	for _, u := range uids {
		if err := os.Mkdir(filepath.Join(dir, u), 0o700); err != nil {
			t.Fatal(err)
		}
	}
}

func rrWrite(t *testing.T, dest, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, name), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func rrQueue(t *testing.T, sw, reap, lock string) {
	t.Helper()
	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID, pendingLockUID = sw, reap, lock
	pendingReapMu.Unlock()
}

// TestRerunReap_QueuesTheReap: a fresh daemon (no session, no cold lock) queues REAP for an existing user, and the
// gate's ACK-REAP retires it.
func TestRerunReap_QueuesTheReap(t *testing.T) {
	rrReset(t)
	rrUsers(t, "13")
	dest := t.TempDir()
	if got := rerunReap(dest, "13", true); got != "OK" {
		t.Fatalf("RERUN-REAP 13 answered %q, want OK", got)
	}
	if got := nextReapAction(); got != "REAP 13" {
		t.Fatalf("the next POLL-REAP answers %q, want REAP 13", got)
	}
	ackReapAction("REAP", "13")
	if got := nextReapAction(); got != "NONE" {
		t.Errorf("after ACK-REAP REAP 13 the queue reads %q, want NONE", got)
	}
}

// TestRerunReap_SendsNoSave pins h53 #4: through the real dispatch, the re-run queues the removal alone. It starts no
// worker op, does not mark a seal in flight and queues no SWITCH.
func TestRerunReap_SendsNoSave(t *testing.T) {
	gatePeer(t, 0)
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK"}})
	rrReset(t)
	rrUsers(t, "13")
	defer waitGateOnly(t)
	reply, _, answered := gateOnlyDrive(t, f.dest, "RERUN-REAP", "13\n", 5*time.Second)
	if !answered || reply != "OK" {
		t.Fatalf("RERUN-REAP 13 from the gate: answered=%v reply=%q, want OK", answered, reply)
	}
	if n := len(f.snapshot()); n != 0 {
		t.Errorf("RERUN-REAP started %d worker op(s), want none (h53 #4: no save)", n)
	}
	pendingReapMu.Lock()
	inFlight, kind, sw := sealInFlight, sealRunKind, pendingSwitchUID
	pendingReapMu.Unlock()
	if inFlight || kind != "" {
		t.Errorf("sealInFlight=%v sealRunKind=%q, want false and empty", inFlight, kind)
	}
	if sw != "" {
		t.Errorf("pendingSwitchUID is %q, want empty (the gate has already switched)", sw)
	}
	if got := nextReapAction(); got != "REAP 13" {
		t.Errorf("the next POLL-REAP answers %q, want REAP 13", got)
	}
}

// TestRerunReap_Refusals: bad input, the live session, the parked cold lock and a user already gone queue nothing.
func TestRerunReap_Refusals(t *testing.T) {
	cases := []struct {
		label, line string
		lf          bool
		session     string
		coldlock    string
		want        string
	}{
		{label: "missing LF", line: "13", lf: false, want: "ERR"},
		{label: "letters", line: "abc", lf: true, want: "ERR"},
		{label: "user 0", line: "0", lf: true, want: "ERR"},
		{label: "uid 9", line: "9", lf: true, want: "ERR"},
		{label: "leading zero", line: "013", lf: true, want: "ERR"},
		{label: "empty", line: "", lf: true, want: "ERR"},
		{label: "leading space", line: " 13", lf: true, want: "ERR"},
		{label: "live session", line: "13", lf: true, session: "rr-live\nrr-pass\n13\n", want: "ERR-LIVE"},
		// An empty pass makes the marker damaged; it still names uid 13, so the verb must still refuse.
		{label: "damaged live marker", line: "13", lf: true, session: "rr-dmg\n\n13\n", want: "ERR-LIVE"},
		{label: "cold lock", line: "13", lf: true, coldlock: "rr-cold\n13\n\n\n\n\n\n", want: "ERR-PARKED"},
		{label: "user gone", line: "14", lf: true, want: "GONE"},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			rrReset(t)
			rrUsers(t, "13")
			dest := t.TempDir()
			if c.session != "" {
				rrWrite(t, dest, roamSessionFile, c.session)
			}
			if c.coldlock != "" {
				rrWrite(t, dest, ".coldlock", c.coldlock)
			}
			if got := rerunReap(dest, c.line, c.lf); got != c.want {
				t.Errorf("RERUN-REAP %q (LF %v) answered %q, want %q", c.line, c.lf, got, c.want)
			}
			if got := nextReapAction(); got != "NONE" {
				t.Errorf("the queue reads %q, want NONE", got)
			}
		})
	}
}

// TestRerunReap_BusyLeavesTheQueue: another uid's queued SWITCH or REAP answers BUSY and stays as it was.
func TestRerunReap_BusyLeavesTheQueue(t *testing.T) {
	for _, c := range []struct{ sw, reap, want string }{
		{reap: "15", want: "REAP 15"},
		{sw: "15", want: "SWITCH 15"},
		{sw: "15", reap: "15", want: "SWITCH 15"},
	} {
		rrReset(t)
		rrUsers(t, "13")
		rrQueue(t, c.sw, c.reap, "")
		if got := rerunReap(t.TempDir(), "13", true); got != "BUSY" {
			t.Errorf("SWITCH=%q REAP=%q queued: RERUN-REAP 13 answered %q, want BUSY", c.sw, c.reap, got)
		}
		pendingReapMu.Lock()
		sw, reap := pendingSwitchUID, pendingReapUID
		pendingReapMu.Unlock()
		if sw != c.sw || reap != c.reap {
			t.Errorf("the queue is SWITCH=%q REAP=%q, want SWITCH=%q REAP=%q", sw, reap, c.sw, c.reap)
		}
		if got := nextReapAction(); got != c.want {
			t.Errorf("the next POLL-REAP answers %q, want %q", got, c.want)
		}
	}
}

// TestRerunReap_BusyDuringAColdLockTeardown: a lone SWITCH for the same uid, or a queued LOCK, is a cold lock's
// teardown; a REAP queued there would remove a user the owner is locking to resume.
func TestRerunReap_BusyDuringAColdLockTeardown(t *testing.T) {
	for _, c := range []struct{ sw, lock, want string }{
		{sw: "13", want: "SWITCH 13"},
		{lock: "13", want: "LOCK 13"},
		{lock: "15", want: "LOCK 15"},
	} {
		rrReset(t)
		rrUsers(t, "13")
		rrQueue(t, c.sw, "", c.lock)
		if got := rerunReap(t.TempDir(), "13", true); got != "BUSY" {
			t.Errorf("SWITCH=%q LOCK=%q queued: RERUN-REAP 13 answered %q, want BUSY", c.sw, c.lock, got)
		}
		if got := nextReapAction(); got != c.want {
			t.Errorf("the next POLL-REAP answers %q, want %q", got, c.want)
		}
	}
}

// TestRerunReap_Idempotent: the same uid's REAP already queued answers OK and changes nothing.
func TestRerunReap_Idempotent(t *testing.T) {
	rrReset(t)
	rrUsers(t, "13")
	dest := t.TempDir()
	rrQueue(t, "13", "13", "")
	if got := rerunReap(dest, "13", true); got != "OK" {
		t.Errorf("SWITCH 13 and REAP 13 queued: RERUN-REAP 13 answered %q, want OK", got)
	}
	if got := nextReapAction(); got != "SWITCH 13" {
		t.Errorf("the next POLL-REAP answers %q, want SWITCH 13", got)
	}
	rrQueue(t, "", "13", "")
	for i := 0; i < 2; i++ {
		if got := rerunReap(dest, "13", true); got != "OK" {
			t.Errorf("REAP 13 queued, call %d: RERUN-REAP 13 answered %q, want OK", i+1, got)
		}
	}
	if got := nextReapAction(); got != "REAP 13" {
		t.Errorf("the next POLL-REAP answers %q, want REAP 13", got)
	}
}

// TestRerunReap_FreeOfSessionMu: the gate's call answers while a DELETE or a CLEAN-STORAGE holds sessionMu.
func TestRerunReap_FreeOfSessionMu(t *testing.T) {
	gatePeer(t, 0)
	f := abFakeInit(t, nil)
	rrReset(t)
	rrUsers(t, "13")
	t.Cleanup(func() { waitGateOnly(t) })
	sessionMu.Lock()
	released := false
	release := func() {
		if !released {
			released = true
			sessionMu.Unlock()
		}
	}
	t.Cleanup(release)
	reply, _, answered := gateOnlyDrive(t, f.dest, "RERUN-REAP", "13\n", 2*time.Second)
	release()
	if !answered || reply != "OK" {
		t.Errorf("RERUN-REAP with sessionMu held: answered=%v reply=%q, want OK at once", answered, reply)
	}
}
