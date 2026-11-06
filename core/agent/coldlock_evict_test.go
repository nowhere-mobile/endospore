package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261004-01: the eviction re-check, the marker claim, and the lock-time alarm relay (coldlock_evict.go).

func TestSaveLanded(t *testing.T) {
	cases := []struct {
		local         bool
		status, parts string
		lastOK        int64
		want          bool
		why           string
	}{
		{false, "ok", "", 100, true, ""},
		{true, "ok", "", 100, false, "local-only"}, // a throwaway is never in the store, whatever else says
		{false, "ok", "", 0, false, "never-saved"}, // nothing failed, and nothing landed either
		{false, "", "", 0, false, "never-saved"},
		{false, "fail", "", 100, false, "last-save-fail"}, // offline: the case the rule exists for
		{false, "nocredit", "", 100, false, "last-save-nocredit"},
		{false, "refused", "", 100, false, "last-save-refused"},
		{false, "", "", 100, false, "last-save-none"},
		{false, "ok", "apps=refused", 100, false, "last-save-partial"},
	}
	for _, c := range cases {
		got, why := saveLanded(c.local, c.status, c.parts, c.lastOK)
		if got != c.want || why != c.why {
			t.Errorf("saveLanded(local=%v, %q, %q, %d) = (%v, %q), want (%v, %q)",
				c.local, c.status, c.parts, c.lastOK, got, why, c.want, c.why)
		}
	}
}

func TestEvictDecision(t *testing.T) {
	cases := []struct {
		verdict string
		saved   bool
		want    string
	}{
		{"OK EVICTED", true, "OK EVICTED"},
		{"OK EVICTED settled", false, "OK EVICTED"},
		{"ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)", true, "WIPE 15"},
		{"ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)", false, "KEEP UNSAVED last-save-fail"},
		// ⚠ A blind probe is never a wipe and never "evicted", whatever the save state says.
		{"ERR-EVICT-PROBE the control saw [] of user 0's CE, which is unlocked", true, "KEEP PROBE-BLIND"},
		{workerBusy, true, "RETRY busy"},
		{"", true, "RETRY no-verdict"},
		{"ERR-UID", true, "RETRY no-verdict"},
	}
	for _, c := range cases {
		why := ""
		if !c.saved {
			why = "last-save-fail"
		}
		if got := evictDecision(c.verdict, "15", c.saved, why); got != c.want {
			t.Errorf("evictDecision(%q, saved=%v) = %q, want %q", c.verdict, c.saved, got, c.want)
		}
	}
}

// evictConn sends one verb through the REAL dispatcher, so the test also proves the verb is wired.
func evictConn(t *testing.T, dest, req string) string {
	t.Helper()
	cli, srv := net.Pipe()
	go cli.Write([]byte(req))
	reply := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		reply <- string(b)
	}()
	handleLogin(srv, dest) // closes srv itself
	select {
	case s := <-reply:
		cli.Close()
		return strings.TrimRight(s, "\r\n")
	case <-time.After(5 * time.Second):
		t.Fatalf("%q: no reply within 5s", req)
		return ""
	}
}

// evictSetup plants a cold-locked user 15 and a clean last save, and stubs the probe.
func evictSetup(t *testing.T, verdict string) (string, *int) {
	t.Helper()
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("alice\n15\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	calls := 0
	prev := coldLockEvictCheck
	coldLockEvictCheck = func(d, uid string) string {
		calls++
		if uid != "15" {
			t.Errorf("evictcheck asked about user %q, want 15", uid)
		}
		return verdict
	}
	sealMu.Lock()
	prevStatus, prevParts := sealStatus, sealParts
	sealStatus, sealParts = "ok", ""
	sealMu.Unlock()
	prevOK := lastSealOKAt.Load()
	lastSealOKAt.Store(100)
	t.Cleanup(func() {
		coldLockEvictCheck = prev
		sealMu.Lock()
		sealStatus, sealParts = prevStatus, prevParts
		sealMu.Unlock()
		lastSealOKAt.Store(prevOK)
	})
	return dest, &calls
}

func TestEvictRecheckWipesAReadableSavedSession(t *testing.T) {
	dest, calls := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)")
	if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != "WIPE 15" {
		t.Fatalf("reply %q, want WIPE 15", got)
	}
	if *calls != 1 {
		t.Errorf("evictcheck ran %d times, want 1", *calls)
	}
	// The decision claims NOTHING: the wipe's own CLAIM-COLDLOCK does, so a lost reply leaves the marker for the
	// gate's next ask (and for the 12 h wipe) instead of a readable session nobody can find.
	if !clwExists(dest, ".coldlock") {
		t.Error("EVICT-RECHECK removed the marker -- if this reply is lost, nothing would ever wipe the session")
	}
}

func TestEvictRecheckKeepsAnUnsavedSession(t *testing.T) {
	dest, _ := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)")
	sealMu.Lock()
	sealStatus = "fail" // the phone was offline: the last periodic seal failed
	sealMu.Unlock()
	if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != "KEEP UNSAVED last-save-fail" {
		t.Fatalf("reply %q, want KEEP UNSAVED last-save-fail", got)
	}
}

func TestEvictRecheckKeepsAThrowaway(t *testing.T) {
	dest, _ := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)")
	markLocalSession(dest)
	if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != "KEEP UNSAVED local-only" {
		t.Fatalf("reply %q, want KEEP UNSAVED local-only", got)
	}
}

func TestEvictRecheckReportsEvicted(t *testing.T) {
	dest, _ := evictSetup(t, "OK EVICTED")
	if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != "OK EVICTED" {
		t.Fatalf("reply %q, want OK EVICTED", got)
	}
}

func TestEvictRecheckNeverWipesOnABlindProbe(t *testing.T) {
	dest, _ := evictSetup(t, "ERR-EVICT-PROBE the control saw [] of user 0's CE, which is unlocked")
	if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != "KEEP PROBE-BLIND" {
		t.Fatalf("reply %q, want KEEP PROBE-BLIND", got)
	}
}

// A resumed (or wiped) session has no marker: nothing to probe, and above all nothing to wipe -- the CE of a
// session the owner just resumed into is readable because it SHOULD be.
func TestEvictRecheckStandsDownWithoutTheMarker(t *testing.T) {
	dest, calls := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)")
	os.Remove(filepath.Join(dest, ".coldlock"))
	if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != "OK GONE" {
		t.Fatalf("reply %q, want OK GONE", got)
	}
	if *calls != 0 {
		t.Errorf("evictcheck ran %d times with no cold-locked session", *calls)
	}
}

func TestEvictRecheckStandsDownForAnotherUidsMarker(t *testing.T) {
	dest, calls := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/16/accounts_ce.db(PLAINTEXT)")
	if got := evictConn(t, dest, "EVICT-RECHECK\n16\n"); got != "OK GONE" {
		t.Fatalf("reply %q, want OK GONE", got)
	}
	if *calls != 0 {
		t.Errorf("evictcheck ran %d times for a uid that is not the cold-locked one", *calls)
	}
}

// A live session's seal state is not the cold-locked one's (markSession resets it at every login).
func TestEvictRecheckNeverDecidesOnALiveSessionsSaveState(t *testing.T) {
	dest, calls := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)")
	if err := markRoamSession(dest, "bob", "pw2", "16", ""); err != nil {
		t.Fatal(err)
	}
	if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != "KEEP LIVE-SESSION 16" {
		t.Fatalf("reply %q, want KEEP LIVE-SESSION 16", got)
	}
	if *calls != 0 {
		t.Errorf("evictcheck ran %d times while another session was live", *calls)
	}
}

func TestEvictRecheckRefusesABadUid(t *testing.T) {
	dest, calls := evictSetup(t, "OK EVICTED")
	for _, u := range []string{"0", "9", "x", ""} {
		if got := evictConn(t, dest, "EVICT-RECHECK\n"+u+"\n"); got != "ERR-UID" {
			t.Errorf("uid %q: reply %q, want ERR-UID", u, got)
		}
	}
	if *calls != 0 {
		t.Errorf("evictcheck ran %d times for refused uids", *calls)
	}
}

func TestClaimColdLock(t *testing.T) {
	gatePeer(t, 10123)
	dest := t.TempDir()
	cl := filepath.Join(dest, ".coldlock")
	os.WriteFile(cl, []byte("alice\n15\n\n\n\n\n\n"), 0o600)

	if got := evictConn(t, dest, "CLAIM-COLDLOCK\n16\n"); got != "GONE" {
		t.Errorf("claim for another uid: reply %q, want GONE", got)
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("a claim for ANOTHER uid removed the marker")
	}
	if got := evictConn(t, dest, "CLAIM-COLDLOCK\n15\n"); got != "OK" {
		t.Errorf("claim for the marker's uid: reply %q, want OK", got)
	}
	if clwExists(dest, ".coldlock") {
		t.Error("a successful claim left the marker")
	}
	// The resume race: once the marker is gone -- resumed, or claimed by the other wipe -- a claim must say so.
	if got := evictConn(t, dest, "CLAIM-COLDLOCK\n15\n"); got != "GONE" {
		t.Errorf("second claim: reply %q, want GONE -- the wipe would then remove a session the owner resumed into", got)
	}
}

// relaySetup stubs the worker so alarmrelay "runs" and optionally delivers a SET-GATE-ALARM after a delay.
func relaySetup(t *testing.T, deliverAfter time.Duration, reply string) *int {
	t.Helper()
	asked := 0
	prevW, prevWait := coldLockWorker, coldLockAlarmWait
	coldLockAlarmWait = 400 * time.Millisecond
	coldLockWorker = func(dest, op, name, pass, uid, se string, rwHeld bool) string {
		if op != "alarmrelay" || !rwHeld || uid != "15" {
			t.Errorf("worker got op=%q rwHeld=%v uid=%q, want alarmrelay inside the hold for 15", op, rwHeld, uid)
		}
		if pass != "" {
			t.Errorf("worker got a passphrase for alarmrelay -- the RO lane refuses one, so the ask would never run")
		}
		asked++
		if deliverAfter >= 0 {
			go func() { time.Sleep(deliverAfter); gateAlarmRelays.Add(1) }()
		}
		return reply
	}
	t.Cleanup(func() {
		coldLockWorker, coldLockAlarmWait = prevW, prevWait
		time.Sleep(deliverAfter + 50*time.Millisecond) // let a stray delivery land before the next test reads the count
	})
	return &asked
}

func TestRelayAlarmAtLockReturnsWhenTheRelayArrives(t *testing.T) {
	asked := relaySetup(t, 50*time.Millisecond, "OK")
	t0 := time.Now()
	relayAlarmAtLock(t.TempDir(), "alice", "pw", "15")
	if *asked != 1 {
		t.Fatalf("the session was asked %d times, want 1", *asked)
	}
	if d := time.Since(t0); d >= coldLockAlarmWait {
		t.Errorf("returned after %s -- it did not notice the delivery and waited out the whole bound", d)
	}
}

func TestRelayAlarmAtLockIsBounded(t *testing.T) {
	relaySetup(t, -1, "OK") // the session never answers
	t0 := time.Now()
	relayAlarmAtLock(t.TempDir(), "alice", "pw", "15")
	d := time.Since(t0)
	if d < coldLockAlarmWait {
		t.Errorf("returned after %s with nothing delivered -- it must wait for the relay up to the bound", d)
	}
	if d > coldLockAlarmWait+time.Second {
		t.Errorf("returned after %s -- the wait is not bounded by coldLockAlarmWait (%s)", d, coldLockAlarmWait)
	}
}

func TestRelayAlarmAtLockDoesNotWaitWhenTheAskFailed(t *testing.T) {
	relaySetup(t, -1, "ERR-LANE")
	t0 := time.Now()
	relayAlarmAtLock(t.TempDir(), "alice", "pw", "15")
	if d := time.Since(t0); d >= coldLockAlarmWait {
		t.Errorf("waited %s for a relay the session was never asked for", d)
	}
}

// The count the teardown waits on must move on EVERY delivery -- a time, a cleared alarm, and an unchanged time
// alike -- through the real SET-GATE-ALARM handler.
func TestSetGateAlarmCountsEveryDelivery(t *testing.T) {
	dest := t.TempDir()
	for _, line := range []string{"1791145500000\t15\tcom.android.deskclock", "0", "1791145500000\t15\tcom.android.deskclock"} {
		before := gateAlarmRelays.Load()
		if got := evictConn(t, dest, "SET-GATE-ALARM\n"+line+"\n"); got != "OK" {
			t.Fatalf("SET-GATE-ALARM %q replied %q", line, got)
		}
		if gateAlarmRelays.Load() == before {
			t.Errorf("SET-GATE-ALARM %q did not move the relay count -- a teardown waiting for it would time out", line)
		}
	}
}
