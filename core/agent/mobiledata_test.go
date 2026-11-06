package main

// NWP-20261026-06: the daemon's half of session-scoped mobile data (mobiledata.go; the 2026-10-19 decision). roamd's
// half -- what mdapply and mdrelease WRITE -- is core/vendor-common/bin/test-mobiledata.sh; these pin WHEN the daemon
// asks for them, mirroring locglobals_test.go: a claim at every start of a session in front, dropped under the RW slot
// once its session ended, a release at every end, and a verb that serves only the session in front.

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// mdSetup stands in for roamd (every worker call answers reply) on an image that can apply mobile data. The recorder
// is locRec's: the calls it takes carry the same fields.
func mdSetup(t *testing.T, reply string) *locRec {
	t.Helper()
	rec := &locRec{ch: make(chan locCall, 16)}
	prevW, prevS := mobileDataWorker, mobileDataSupported
	mobileDataSupported = func() bool { return true }
	mobileDataWorker = func(dest, op, why, uid string) string {
		_, _, live := readRoamSession(dest)
		c := locCall{op: op, why: why, uid: uid, live: live, coldlock: clwExists(dest, ".coldlock")}
		rec.mu.Lock()
		rec.calls = append(rec.calls, c)
		rec.mu.Unlock()
		rec.ch <- c
		return reply
	}
	t.Cleanup(func() { mobileDataWorker, mobileDataSupported = prevW, prevS })
	return rec
}

func TestMobileDataResumeClaimsAfterTheMarker(t *testing.T) {
	l := crLock(t, crKinds[0])
	rec := mdSetup(t, "OK APPLIED mobile_data=1")
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
		t.Fatalf("the resume was refused (%q)", got)
	}
	c := rec.wait(t, "a resume")
	if c.op != "mdapply" || c.why != "resume" || c.uid != "10" || c.live != "10" || c.coldlock {
		t.Errorf("worker asked %+v, want mdapply/resume for user 10, recorded and no longer cold-locked", c)
	}
}

func TestMobileDataRefusedResumeClaimsNothing(t *testing.T) {
	l := crLock(t, crKinds[0])
	rec := mdSetup(t, "OK APPLIED mobile_data=1")
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	if got := crResume(t, l.dest, "not-the-passphrase"); got == "OK 10" {
		t.Fatal("control failed: a wrong entry resumed")
	}
	rec.none(t, "a refused resume")
}

func TestMobileDataOfflineSignInClaimsAfterTheMarker(t *testing.T) {
	dest := t.TempDir()
	stop := ropWorker(t, dest)
	defer stop()
	rec := mdSetup(t, "OK APPLIED mobile_data=1")
	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, "alice", "correct horse battery", "12"); srv.Close() }()
	buf := make([]byte, 64)
	nr, _ := cli.Read(buf)
	cli.Close()
	if got := strings.TrimSpace(string(buf[:nr])); got != "OK 12" {
		t.Fatalf("offline sign-in replied %q", got)
	}
	c := rec.wait(t, "an offline sign-in")
	if c.op != "mdapply" || c.why != "offline" || c.uid != "12" || c.live != "12" {
		t.Errorf("worker asked %+v, want mdapply/offline for user 12 with .roamsession naming it", c)
	}
}

func TestMobileDataAckReapOfARemovalSwitchReleases(t *testing.T) {
	gatePeer(t, 10123)
	ropReapReset(t)
	t.Cleanup(func() { pendingReapMu.Lock(); pendingLockUID = ""; pendingReapMu.Unlock() })
	rec := mdSetup(t, "OK BASELINE")
	dest := t.TempDir()
	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID = "10", "10"
	pendingReapMu.Unlock()
	if got := driveLogin(t, dest, "ACK-REAP\nSWITCH\n10\n"); got != "OK" {
		t.Fatalf("ACK-REAP replied %q", got)
	}
	if c := rec.wait(t, "a logoff's gate switch"); c.op != "mdrelease" || c.why != "signout" || c.uid != "10" {
		t.Errorf("worker asked %+v, want mdrelease/signout for user 10", c)
	}
	driveLogin(t, dest, "ACK-REAP\nSWITCH\n10\n")
	driveLogin(t, dest, "ACK-REAP\nREAP\n10\n")
	rec.none(t, "a repeated SWITCH ack and the REAP ack")

	pendingReapMu.Lock()
	pendingSwitchUID, pendingLockUID = "11", "11"
	pendingReapMu.Unlock()
	driveLogin(t, dest, "ACK-REAP\nSWITCH\n11\n")
	rec.none(t, "a cold lock's switch (it releases inside its own teardown)")

	mobileDataSupported = func() bool { return false }
	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID = "12", "12"
	pendingReapMu.Unlock()
	driveLogin(t, dest, "ACK-REAP\nSWITCH\n12\n")
	rec.none(t, "an image that cannot apply mobile data")
}

func TestMobileDataColdLockReleasesInsideItsHold(t *testing.T) {
	dest, rec, _ := clwSetup(t)
	prevW, prevS := mobileDataWorker, mobileDataSupported
	mobileDataSupported = func() bool { return true }
	mobileDataWorker = func(dest, op, why, uid string) string { return "" }
	t.Cleanup(func() { mobileDataWorker, mobileDataSupported = prevW, prevS })
	clwLock(t, dest, 0)
	if !clwWaitFor(3*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the cold lock never completed")
	}
	calls := rec.snapshot()
	mr, bp, n := -1, -1, 0
	for i, c := range calls {
		switch c.op {
		case "mdrelease":
			mr, n = i, n+1
		case "btpark":
			bp = i
		}
	}
	if n != 1 {
		t.Fatalf("ops = %v, want exactly one mdrelease", rec.ops())
	}
	c := calls[mr]
	if !c.rwHeld || c.slotLen != 1 {
		t.Errorf("mdrelease ran outside the teardown's hold (rwHeld=%v slot=%d)", c.rwHeld, c.slotLen)
	}
	if !c.coldlock || c.roamsession {
		t.Errorf("mdrelease ran before the point of no return (coldlock=%v roamsession=%v)", c.coldlock, c.roamsession)
	}
	if bp < 0 || mr < bp {
		t.Errorf("ops = %v, want mdrelease after btpark", rec.ops())
	}
	if c.switchUID != "" {
		t.Errorf("the switch was published BEFORE the release -- the gate shows with the session's mobile data choice")
	}
}

func TestMobileDataClearingAGoneUsersMarkerReleases(t *testing.T) {
	users := useTempUsersDir(t)
	if err := os.MkdirAll(filepath.Join(users, "10"), 0o700); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	rec := mdSetup(t, "OK APPLIED mobile_data=1")
	if got := clearMarkerOfGoneUser(dest); got != "" {
		t.Fatalf("control: user 10 exists, but clearMarkerOfGoneUser cleared %q", got)
	}
	rec.none(t, "a marker whose user still exists")
	if err := os.RemoveAll(filepath.Join(users, "10")); err != nil {
		t.Fatal(err)
	}
	if got := clearMarkerOfGoneUser(dest); got != "10" {
		t.Fatalf("clearMarkerOfGoneUser = %q, want 10", got)
	}
	if c := rec.wait(t, "a release once the gone user's marker is cleared"); c.op != "mdrelease" || c.why != "gone" || c.uid != "10" {
		t.Errorf("worker asked %+v, want mdrelease/gone for user 10", c)
	}
	clearMarkerOfGoneUser(dest)
	rec.none(t, "a second pass over a marker that is already gone")
}

func TestMobileDataClaimIsDroppedUnderTheSlotOnceItsSessionEnded(t *testing.T) {
	ropReapReset(t)
	t.Cleanup(func() { pendingReapMu.Lock(); pendingLockUID = ""; pendingReapMu.Unlock() })
	run := func(dest, op string) (string, []string) {
		stop := ropWorker(t, dest)
		out := runWorkerHeld(laneRW, dest, op, "live", "", "10", "", "", "", "", nil)
		return out, stop()
	}
	dest := t.TempDir()
	if out, ops := run(dest, "mdapply"); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("no session: %q, worker saw %v -- want SKIP-ENDED and nothing written", out, ops)
	}
	if err := markRoamSession(dest, "bob", "pw", "11", ""); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest, "mdapply"); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("another user is live: %q, %v", out, ops)
	}
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest, "mdapply"); out != "ERR-PIN-TEST" || len(ops) != 1 || ops[0] != "mdapply" {
		t.Fatalf("the live session's claim: %q, %v -- want it handed to the worker", out, ops)
	}
	for _, flag := range []*string{&pendingSwitchUID, &pendingReapUID, &pendingLockUID} {
		pendingReapMu.Lock()
		*flag = "10"
		pendingReapMu.Unlock()
		if out, ops := run(dest, "mdapply"); out != "SKIP-ENDED" || len(ops) != 0 {
			t.Errorf("a session queued to be switched out: %q, %v", out, ops)
		}
		pendingReapMu.Lock()
		*flag = ""
		pendingReapMu.Unlock()
	}
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("alice\n10\n\nnokey\nnopin\nx\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest, "mdapply"); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("a cold-locked session: %q, %v", out, ops)
	}
	if out, ops := run(t.TempDir(), "mdrelease"); out != "ERR-PIN-TEST" || len(ops) != 1 {
		t.Errorf("a release with no session: %q, %v -- a release must always reach roamd", out, ops)
	}
}

func TestMobileDataVerbServesOnlyTheSessionInFront(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	rec := mdSetup(t, "OK APPLIED mobile_data=1\nsecond line\x00")

	locPeer(t, 10123) // the gate (user 0)
	if got := driveLogin(t, dest, "APPLY-MOBILE-DATA\n"); got != "NONE" {
		t.Errorf("a gate caller got %q, want NONE", got)
	}
	locPeer(t, 11*100000+10123) // an app of another user
	if got := driveLogin(t, dest, "APPLY-MOBILE-DATA\n"); got != "NONE" {
		t.Errorf("another user's caller got %q, want NONE", got)
	}
	locPeer(t, 10*100000+10123)
	if got := driveLogin(t, t.TempDir(), "APPLY-MOBILE-DATA\n"); got != "NONE" {
		t.Errorf("with no session the reply was %q, want NONE", got)
	}
	rec.none(t, "refused callers")

	// Held, to prove the verb runs free (concurrentSafeCmd): a materialise can hold sessionMu for minutes.
	sessionMu.Lock()
	done := make(chan string, 1)
	go func() { done <- driveLogin(t, dest, "APPLY-MOBILE-DATA\n") }()
	var got string
	select {
	case got = <-done:
		sessionMu.Unlock()
	case <-time.After(5 * time.Second):
		sessionMu.Unlock()
		<-done
		t.Fatal("APPLY-MOBILE-DATA waited on sessionMu")
	}
	if got != "OK APPLIED mobile_data=1" {
		t.Errorf("the session's reply %q, want the worker's first line", got)
	}
	if c := rec.wait(t, "the live switch"); c.op != "mdapply" || c.why != "live" || c.uid != "10" {
		t.Errorf("worker asked %+v, want mdapply/live for user 10", c)
	}

	mobileDataSupported = func() bool { return false }
	if got := driveLogin(t, dest, "APPLY-MOBILE-DATA\n"); got != "NONE" {
		t.Errorf("without support the reply was %q, want NONE", got)
	}
	rec.none(t, "an image that cannot apply mobile data")
}

func TestMobileDataHelpersAreInertWithoutSupport(t *testing.T) {
	rec := mdSetup(t, "OK")
	mobileDataSupported = func() bool { return false }
	if got := claimMobileData(t.TempDir(), "10", "live"); got != "NONE" {
		t.Errorf("claimMobileData = %q", got)
	}
	claimMobileDataAsync(t.TempDir(), "10", "signin")
	releaseMobileDataAsync(t.TempDir(), "10", "signout")
	prevW := coldLockWorker
	asked := 0
	coldLockWorker = func(dest, op, name, pass, uid, se string, rwHeld bool) string { asked++; return "OK" }
	releaseMobileDataAtLock(t.TempDir(), "10")
	coldLockWorker = prevW
	rec.none(t, "the helpers on an image that cannot apply mobile data")
	if asked != 0 {
		t.Errorf("releaseMobileDataAtLock dispatched %d op(s)", asked)
	}
}

// Each claim comes after its session marker is written and a refusal to write it has returned; the sign-in's before the
// throwaway branch, the resume's after the cold-lock marker is gone (TestEverySignInClaimsLocGlobalsAfterTheMarker).
func TestMobileDataEverySignInClaimsAfterTheMarker(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	fn := func(from, to string) string {
		t.Helper()
		i, j := strings.Index(s, from), strings.Index(s, to)
		if i < 0 || j < i {
			t.Fatalf("%s not found", from)
		}
		return s[i:j]
	}
	at := func(body, name, needle string) int {
		t.Helper()
		if n := strings.Count(body, needle); n != 1 {
			t.Fatalf("%q appears %d times in %s, want 1", needle, n, name)
		}
		return strings.Index(body, needle)
	}
	in := fn("func handleRoamIn(", "func handleRoamInOffline(")
	mark := at(in, "handleRoamIn", "if err := markRoamSession(dest, name, pass, uid, seSecret); err != nil {")
	refused := at(in, "handleRoamIn", `fmt.Fprint(conn, "ERR-UNRECORDED\n")`)
	claim := at(in, "handleRoamIn", `claimMobileDataAsync(dest, uid, "signin")`)
	throwaway := at(in, "handleRoamIn", `if head == "" {`+"\n\t\t\tmarkLocalSession(dest)")
	if !(mark < refused && refused < claim && claim < throwaway) {
		t.Errorf("sign-in order: marker %d, refusal %d, claim %d, throwaway branch %d", mark, refused, claim, throwaway)
	}
	off := fn("func handleRoamInOffline(", "func handleRelogin(")
	mark = at(off, "handleRoamInOffline", `if err := markRoamSession(dest, name, pass, uid, ""); err != nil {`)
	refused = at(off, "handleRoamInOffline", `fmt.Fprint(conn, "ERR-UNRECORDED\n")`)
	claim = at(off, "handleRoamInOffline", `claimMobileDataAsync(dest, uid, "offline")`)
	if !(mark < refused && refused < claim) {
		t.Errorf("offline order: marker %d, refusal %d, claim %d", mark, refused, claim)
	}
	res := fn("func handleResume(", "func purgeLocalProfileState(")
	mark = at(res, "handleResume", "if err := markRoamSession(dest, name, pass, uid, se); err != nil {")
	gone := at(res, "handleResume", `os.Remove(filepath.Join(dest, ".coldlock"))`)
	claim = at(res, "handleResume", `claimMobileDataAsync(dest, uid, "resume")`)
	if !(mark < gone && gone < claim) {
		t.Errorf("resume order: marker %d, cold-lock marker removed %d, claim %d", mark, gone, claim)
	}
}
