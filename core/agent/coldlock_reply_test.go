package main

import (
	"bufio"
	"net"
	"strings"
	"testing"
)

// NWP-20260922-07: handleColdLock's reply must say whether a lock actually STARTED.
//
// WHY THIS IS PINNED. The chooser's idle backstop re-arms its alarm on every reply that is NOT a positive
// "LOCKING". That is not cosmetic: the alarm is already spent by the time the reply arrives (sIdleArmed stays
// true, and the screen-off armer then refuses to arm for the rest of the session), so a reply the chooser
// reads as "a lock started" when none did costs the session its at-rest bound entirely -- no idle cold lock
// and no 12h hard wipe, since armWipeWatcher's only caller is inside doColdLock. The reachable shape is a
// logoff: handleLogout removes .roamsession FIRST and then seals for what has been measured at 42 and 56
// minutes, so every idle fire in that window lands here on the no-session path.
//
// The token is therefore a CROSS-PROCESS CONTRACT, and both directions are asserted: the no-session reply
// must not contain the positive token, and it must still start with OK so that every existing caller which
// only looks for OK is unaffected.
func TestColdLockReplyDistinguishesNoSession(t *testing.T) {
	dest := t.TempDir() // no .roamsession -> the "nothing to lock" path

	server, client := net.Pipe()
	done := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(client).ReadString('\n')
		done <- line
	}()
	handleColdLock(server, dest, 0)
	server.Close()
	reply := strings.TrimRight(<-done, "\r\n")
	client.Close()

	if !strings.HasPrefix(reply, "OK") {
		t.Errorf("reply %q does not start with OK -- every existing caller that only checks for OK would now "+
			"read this as a failure", reply)
	}
	if !strings.Contains(reply, "NOSESSION") {
		t.Errorf("reply %q does not say NOSESSION. The chooser cannot then tell 'nothing to lock' from a lock "+
			"that started, and will stop re-arming the idle alarm it has already spent", reply)
	}
	// ⚠ The load-bearing half. If the no-session reply ever gained the positive token, the chooser would treat
	// a logoff window as a successful lock and silently drop the session's at-rest bound.
	if strings.Contains(reply, "LOCKING") {
		t.Errorf("reply %q contains the POSITIVE token on the no-session path -- the chooser would believe a "+
			"lock started when none did, and would not re-arm", reply)
	}
}

// The positive token must exist in the source that answers a real lock. The locking path IS driven by behaviour
// now -- coldlock_wait_order_test.go's clwLock runs the real teardown through the coldLockWorker seam -- but that
// check only looks for the substring "LOCKING". This one pins the EXACT "OK LOCKING\n" token the chooser keys
// on, and the coldLockStarts++ increment TestColdLockRefusesASecondConcurrentTeardown needs. A control asserts
// the probe can actually find text in this file, so "not found" can never be a silent pass.
func TestColdLockPositiveTokenExists(t *testing.T) {
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	if !strings.Contains(src, `"OK LOCKING\n"`) {
		t.Errorf(`main.go no longer emits "OK LOCKING\n". The chooser keys its idle re-arm on that exact token; ` +
			`without it every successful cold lock is read as "no lock" and the alarm is re-armed needlessly`)
	}
	// ⚠ The concurrent-teardown test counts coldLockStarts to tell a refusal from a second teardown. If that
	// increment is ever removed the counter never moves, the difference is always 0, and that test passes
	// VACUOUSLY with the guard deleted -- found by mutation, which is the only reason this line exists.
	// Matched as a WHOLE LINE, not as a substring: a bare strings.Contains is satisfied by the token sitting
	// in a comment, which is exactly how the first version of this assertion survived the increment being
	// commented out. A commented line trims to "// coldLockStarts++" and does not compare equal.
	hasIncrement := false
	for _, ln := range strings.Split(src, "\n") {
		if strings.TrimSpace(ln) == "coldLockStarts++" {
			hasIncrement = true
			break
		}
	}
	if !hasIncrement {
		t.Error("main.go no longer increments coldLockStarts. TestColdLockRefusesASecondConcurrentTeardown " +
			"measures spawns with it, so without the increment that test proves nothing and would pass with " +
			"the concurrency guard removed")
	}
	if !strings.Contains(src, "func handleColdLock(") {
		t.Fatal("control failed: could not find handleColdLock in main.go, so the check above proves nothing")
	}
}

// NWP-20260922-07 (review fix): only ONE cold-lock teardown at a time.
//
// The chooser now re-arms its idle alarm on every fire that produced no lock -- correct for the alarm, but it
// means an AMBIGUOUS outcome can send a second COLD-LOCK-IDLE while the first teardown is still running. The
// read times out at 5s while the daemon is still blocked on sessionMu ("a materialise/login/logoff holds it
// for MINUTES"), the chooser concludes "no lock" and retries. .roamsession is not removed until late in the
// teardown, so without this guard the second request finds a live session and starts a SECOND goroutine:
// stopMediad and btpark twice, and a second rekey handed --old unlockSecret when the first already moved the
// credential to cred -- ERR-REKEY on the credential path, mid cold lock. That is #124 blast radius.
//
// The refusal answers LOCKING, which is the honest reply (a lock IS in flight) and is also what stops the
// chooser re-arming: the running teardown reaches cancelIdleWatcher itself.
func TestColdLockRefusesASecondConcurrentTeardown(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}

	coldLockMu.Lock()
	coldLockRunning = true // stand in for a teardown already running
	before := coldLockStarts
	coldLockMu.Unlock()
	t.Cleanup(func() { coldLockMu.Lock(); coldLockRunning = false; coldLockMu.Unlock() })

	server, client := net.Pipe()
	done := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(client).ReadString('\n')
		done <- line
	}()
	handleColdLock(server, dest, 0)
	server.Close()
	reply := strings.TrimRight(<-done, "\r\n")
	client.Close()

	if !strings.Contains(reply, "LOCKING") {
		t.Errorf("reply %q -- a refusal must still say LOCKING, or the chooser re-arms an alarm that the "+
			"running teardown is about to cancel itself", reply)
	}
	// The guard must NOT have taken ownership: the teardown that is genuinely running owns the flag, and a
	// refusal that cleared it would let a third request start a real second teardown.
	coldLockMu.Lock()
	still := coldLockRunning
	coldLockMu.Unlock()
	if !still {
		t.Error("the refusal cleared coldLockRunning -- it does not own the flag, and clearing it re-opens " +
			"exactly the concurrent teardown this guard exists to prevent")
	}
	// ⚠ THE LOAD-BEARING ASSERTION. The reply alone cannot tell a refusal from a second teardown -- BOTH
	// answer LOCKING -- so a test that checked only the reply passed with the guard deleted (caught by
	// mutation). Count the goroutines actually spawned instead.
	coldLockMu.Lock()
	started := coldLockStarts - before
	coldLockMu.Unlock()
	if started != 0 {
		t.Errorf("a SECOND teardown goroutine was spawned (%d) while one was already running -- stopMediad and "+
			"btpark would run twice, and the second rekey gets --old unlockSecret after the first moved the "+
			"credential, which is ERR-REKEY on the credential path mid cold lock (#124 blast radius)", started)
	}
}
