package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261116-05: ROLLBACK, DELETE-SNAPSHOT and REMOVE-FIDO2-KEY answer BUSY while sessionMu is held. They used to
// wait in handleLogin's blocking Lock behind a materialise, a sign-in or a CLEAN-STORAGE for minutes, past the
// chooser's 90s read, so the screen reported a failure and the change landed later unseen -- a late ROLLBACK then
// reaped the session without a seal. TestStoreVerbsAnswerBusyWhileSessionMuIsHeld and TestStoreVerbsAreTryLocked pin
// the BUSY half; TestStoreVerbDeadlinesOutlastChooserRead pins the second half: ROLLBACK ran on the 60s entry deadline
// and REMOVE-FIDO2-KEY set 60s, so one that completed in 60-90s lost its reply write (#744's rule).
//
// NWP-20261124-10: SET-PIN, ROTATE, ENROLL-FIDO2, FIDO2-NFC-ENROLL-FINISH, SE-TIE and SE-UNTIE joined them. Each
// waited in the same blocking Lock, so a PIN, passphrase, key or tie change the screen reported failed could land
// minutes later. The two BUSY tests below cover all nine.

// storeBusyRequests are the requests, each with its reply when sessionMu is free and dest holds no session. The
// ROTATE request carries a too-short new passphrase, so handleRotate answers WEAK before any marker or store read: a
// strong one would reach the store for a rotation of a profile that is not live.
var storeBusyRequests = []struct{ verb, req, control string }{
	{"ROLLBACK", "ROLLBACK\n0\n", "NONE"},                                              // handleRollback: no .roamsession
	{"DELETE-SNAPSHOT", "DELETE-SNAPSHOT\n1\n", "NONE"},                                // handleDeleteSnapshot: no .roamsession
	{"REMOVE-FIDO2-KEY", "REMOVE-FIDO2-KEY\nAAAA\n", "ERR-NOSESSION"},                  // the arm's own session check
	{"SET-PIN", "SET-PIN\n1234\n", "ERR-NOSESSION"},                                    // the arm reads the PIN, then the session
	{"ROTATE", "ROTATE\nn\no\nshort\n", "WEAK too short — use at least 12 characters"}, // handleRotate: the floor answers first
	{"ENROLL-FIDO2", "ENROLL-FIDO2\n", "ERR-NOSESSION"},                                // the arm's own session check
	{"FIDO2-NFC-ENROLL-FINISH", "FIDO2-NFC-ENROLL-FINISH\n", "ERR-NOSESSION"},          // the arm's own session check
	{"SE-TIE", "SE-TIE\nx\n", "ERR-NOSESSION"},                                         // handleSETie: confirm line, then no session
	{"SE-UNTIE", "SE-UNTIE\nx\n", "ERR-NOSESSION"},                                     // handleSETie: confirm line, then no session
}

// TestStoreVerbsAnswerBusyWhileSessionMuIsHeld: each verb answers BUSY at once while sessionMu is held, and the same
// request reaches its handler once the lock is free (the control). The 5s is a hang guard, not a timing claim: a verb
// that waits for the lock fails by name in replyWhileHeld.
func TestStoreVerbsAnswerBusyWhileSessionMuIsHeld(t *testing.T) {
	t.Setenv("NOWHERE_PASS_FLOOR", "1") // the ROTATE control needs the floor, which a test environment may bypass
	for _, c := range storeBusyRequests {
		func() {
			sessionMu.Lock()
			defer sessionMu.Unlock()
			if got := replyWhileHeld(t, 5*time.Second, c.req, c.verb); got != "BUSY" {
				t.Fatalf("%s while sessionMu is held replied %q, want BUSY", c.verb, got)
			}
		}()
	}
	for _, c := range storeBusyRequests {
		if got := driveLogin(t, t.TempDir(), c.req); got != c.control {
			t.Errorf("%s with sessionMu free replied %q, want %q: the request does not reach its handler", c.verb, got, c.control)
		}
	}
}

// TestStoreVerbsAreTryLocked pins every verb above into handleLogin's TryLock set by source, beside the behavioural
// BUSY above, as TestSetBindingIsTryLocked does for SET-BINDING.
func TestStoreVerbsAreTryLocked(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "handleLogin"))
	for i, l := range body {
		if strings.Contains(l, `name == "BACKUP" || name == "DELETE"`) {
			set := l
			if i+1 < len(body) {
				set += body[i+1] // the condition runs onto a second line
			}
			for _, c := range storeBusyRequests {
				if !strings.Contains(set, `name == "`+c.verb+`"`) {
					t.Errorf("%s must answer BUSY rather than wait for sessionMu: it is not in handleLogin's TryLock set", c.verb)
				}
			}
			return
		}
	}
	t.Fatal("the TryLock set was not found -- this test is stale, not the code")
}

// storeBusyArmDeadline returns the seconds of the last conn.SetDeadline in handleLogin's `if name == "<arm>" {` arm
// before the line that holds call, or -1 if there is none. It tracks brace depth, unlike the DELETE pin's first-bare-`}`
// rule: REMOVE-FIDO2-KEY has an `if nm == "" { ... }` block before its SetDeadline, which would stop that rule early.
// No line walked in these arms holds a brace inside a string literal, so a plain count is exact.
func storeBusyArmDeadline(t *testing.T, h []string, arm, call string) int {
	t.Helper()
	start := -1
	for i, l := range h {
		if strings.TrimSpace(l) == `if name == "`+arm+`" {` {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatalf("handleLogin has no %q arm -- this test is stale, not the code", arm)
	}
	secs, depth := -1, 1
	for _, l := range h[start+1:] {
		if strings.Contains(l, call) {
			return secs
		}
		if m := deleteDeadlineLine.FindStringSubmatch(l); m != nil {
			secs, _ = strconv.Atoi(m[1])
		}
		depth += strings.Count(l, "{") - strings.Count(l, "}")
		if depth <= 0 {
			break
		}
	}
	t.Fatalf("the %s arm closes without calling %s -- this test is stale, not the code", arm, call)
	return -1
}

// TestStoreVerbDeadlinesOutlastChooserRead: the ROLLBACK and REMOVE-FIDO2-KEY arms raise handleLogin's 60s entry
// deadline past the chooser's read before they call their handler, as DELETE's (#744) and DELETE-SNAPSHOT's do. The
// chooser's 90s read itself is pinned against chooserDeleteReadMillis by TestDeleteDeadlineOutlastsChooserRead.
// ROLLBACK is still read through sendDaemon. REMOVE-FIDO2-KEY waits on a tap since NWP-20261127-02, so its caller
// reads through DaemonSocket.roundTrip, longer than the arm's deadline.
func TestStoreVerbDeadlinesOutlastChooserRead(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	h := stripComments(funcBody(t, string(b), "handleLogin"))
	for _, c := range []struct{ arm, call string }{
		{"ROLLBACK", "handleRollback("},
		{"REMOVE-FIDO2-KEY", "daemonVaultOp("},
	} {
		secs := storeBusyArmDeadline(t, h, c.arm, c.call)
		if secs < 0 {
			t.Errorf("the %s arm calls %s on handleLogin's 60s entry deadline: a completed one that takes longer "+
				"loses its reply write (#744)", c.arm, c.call)
			continue
		}
		if secs*1000 <= chooserDeleteReadMillis {
			t.Errorf("the %s arm's deadline is %ds, not longer than the chooser's %dms read: one that completes "+
				"inside the read window can still lose its reply (#744)", c.arm, secs, chooserDeleteReadMillis)
		}
	}

	jb, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "ProfileActivity.java"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(jb), `sendDaemon("ROLLBACK\n"`) {
		t.Errorf("ProfileActivity no longer sends ROLLBACK through sendDaemon -- re-price the daemon's deadline against the new caller")
	}
	// NWP-20261127-02: REMOVE-FIDO2-KEY waits on a tap, so the chooser reads it through DaemonSocket.roundTrip with a
	// read LONGER than the arm's deadline, as ADOPT-FIDO2's caller does: the reply always arrives before the read ends.
	rm := removeKeyRoundTrip.FindAllStringSubmatch(string(jb), -1)
	if len(rm) != 1 {
		t.Fatalf("ProfileActivity sends REMOVE-FIDO2-KEY through DaemonSocket.roundTrip %d time(s), want 1 -- "+
			"re-price the daemon's deadline against the new caller", len(rm))
	}
	read, _ := strconv.Atoi(rm[0][1])
	if secs := storeBusyArmDeadline(t, h, "REMOVE-FIDO2-KEY", "daemonVaultOp("); read <= secs*1000 {
		t.Errorf("the chooser reads REMOVE-FIDO2-KEY for %dms, not longer than the arm's %ds deadline: a removal "+
			"that completes near the deadline loses its reply in the chooser", read, secs)
	}
}

// removeKeyRoundTrip is ProfileActivity's REMOVE-FIDO2-KEY send; group 1 is its read in ms.
var removeKeyRoundTrip = regexp.MustCompile(`DaemonSocket\.roundTrip\("REMOVE-FIDO2-KEY\\n" \+ credID \+ "\\n", (\d+)\)`)
