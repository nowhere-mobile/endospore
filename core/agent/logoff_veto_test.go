package main

import (
	"strings"
	"testing"
)

// NWP-20260922-08: a logoff in flight must veto a cold-lock COMMIT.
//
// The shape this closes, from the backlog row: a cold lock DECIDED BEFORE the LOGOUT, whose commit lands
// minutes later while the seal is still uploading. handleColdLock reads .roamsession once, synchronously, and
// then runs the rest in a goroutine -- so handleLogout's delete cannot stop a lock already past that read. No
// seal failure is needed, and a large profile is the direct selector: the NW-7e77092e940a ticket measured
// periodic seals holding the worker slot for 42 and 56 minutes WHILE SUCCEEDING.
func TestLogoffVetoIsUidKeyed(t *testing.T) {
	t.Cleanup(func() { setLogoffInFlight("") })

	if logoffInFlight("10") {
		t.Fatal("control failed: nothing is in flight yet, so the veto must be false -- otherwise every " +
			"assertion below passes for the wrong reason")
	}
	setLogoffInFlight("10")
	if !logoffInFlight("10") {
		t.Error("user 10's own logoff does not veto its own cold lock -- the veto does nothing")
	}
	// A stale logoff must never veto a LATER session's lock. Same reasoning as the abort path's decidedAt
	// stamp: a session that has already gone must not be able to suppress the at-rest bound of the next one.
	if logoffInFlight("11") {
		t.Error("user 10's logoff vetoes user 11's cold lock -- a departed session would suppress a live " +
			"session's at-rest bound")
	}
	if logoffInFlight("") {
		t.Error("an EMPTY uid matched -- handleColdLock would then veto on a session it could not identify")
	}
}

// ⚠⚠ THE LOAD-BEARING PROPERTY, and the reason the veto is NOT keyed on sealRunKind.
//
// The #125 stall watchdog decides a seal is stuck, clears sealRunKind ("compare-and-clear") and then re-arms
// .roamsession two statements later -- WHILE THE SEAL KEEPS UPLOADING. A veto keyed on sealRunKind would stop
// vetoing at the exact instant the one accidental protection that exists today (handleColdLock's early return
// on an absent marker) is also undone by that re-arm. Both would drop in the same breath, failing OPEN into
// the defect, on a watchdog whose own comment in main.go records that it "fired FALSELY twice in two nights".
//
// So the flag's lifetime is owned by the logoff GOROUTINE. This test pins that: clearing sealRunKind the way
// the watchdog does must leave the veto standing.
func TestLogoffVetoSurvivesTheStallWatchdog(t *testing.T) {
	t.Cleanup(func() {
		setLogoffInFlight("")
		pendingReapMu.Lock()
		sealRunKind = ""
		pendingReapMu.Unlock()
	})

	setLogoffInFlight("10")
	pendingReapMu.Lock()
	sealRunKind = "logoff"
	pendingReapMu.Unlock()
	if !logoffInFlight("10") {
		t.Fatal("control failed: the veto is not set, so the assertion below proves nothing")
	}

	// Exactly what the watchdog does at its unstick.
	pendingReapMu.Lock()
	if sealRunKind == "logoff" {
		sealRunKind = ""
	}
	pendingReapMu.Unlock()

	if !logoffInFlight("10") {
		t.Error("the veto dropped when sealRunKind was cleared. That is the #125 stall-watchdog false " +
			"positive -- which ALSO re-arms .roamsession -- so the veto and the accidental protection would " +
			"vanish together, failing OPEN into the defect at the moment the watchdog is known to be wrong")
	}
}

// The release is compare-and-clear: a finishing logoff must not clear a NEWER session's claim.
func TestLogoffVetoReleaseDoesNotClobberANewerClaim(t *testing.T) {
	t.Cleanup(func() { setLogoffInFlight("") })

	a := setLogoffInFlight("10")
	b := setLogoffInFlight("11") // a new session logged in and is now logging off
	clearLogoffInFlight("10", a)
	if !logoffInFlight("11") {
		t.Error("the old logoff's release cleared the NEW one's claim -- user 11's cold lock could then " +
			"commit mid-logoff, which is the defect, arriving through the release path")
	}
	clearLogoffInFlight("11", b)
	if logoffInFlight("11") {
		t.Error("the owning release did not clear its own claim -- the veto would outlive its logoff and " +
			"suppress every later cold lock for that uid")
	}
}

// Both commit points must consult it. A veto wired at only one is worse than none: it reads as fixed.
func TestLogoffVetoIsWiredAtBothCheckpoints(t *testing.T) {
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	if !strings.Contains(src, "revoke := coldLockRevoked(decidedAt, lastPresentAt.Load()) || logoffInFlight(uid)") {
		t.Error("Check B no longer ORs in logoffInFlight. That is the LAST REVERSIBLE MOMENT -- the .coldlock " +
			"write below it is the point of no return -- so a lock decided before the logoff would commit")
	}
	// ⚠ PINNED BY ADJACENCY, because `if logoffInFlight(uid) {` appears THREE times -- the pre-reply refusal,
	// Check A, and Check B's log-cause branch. An assertion that merely FOUND one was satisfied by a
	// different site while Check A was disabled, and so was a count of "at least two" (found by mutation,
	// twice). Identify Check A by the line it guards, which is unique to it.
	if !hasCodeLineFollowedBy(src, "if logoffInFlight(uid) {",
		`fmt.Fprintf(os.Stderr, "[logind] cold-lock ABORTED before teardown (logoff in flight`) {
		t.Error("Check A no longer tests logoffInFlight, so a logoff that began while the reply was in " +
			"flight would run the whole teardown -- stopMediad, the credential rekey -- before Check B looked")
	}
	// ⚠ Matched as LIVE CODE LINES, not substrings. A bare strings.Contains is satisfied by the text sitting
	// in a COMMENT, so commenting either of these out left the assertion green -- found by mutation, twice.
	if !hasCodeLinePrefix(src, "defer clearLogoffInFlight(uid,") {
		t.Error("the release is no longer a defer on the logoff goroutine. Owned anywhere else -- especially " +
			"by the stall watchdog's verdict -- the veto fails OPEN while the seal is still uploading")
	}
	if !hasCodeLinePrefix(src, "logoffClaim := setLogoffInFlight(uid)") {
		t.Error("handleLogout no longer CLAIMS the veto, so nothing is ever in flight and every check above " +
			"is inert -- the fix would read as wired while doing nothing at all")
	}
	// ⚠ The PRE-REPLY refusal. Checks A and B run after "OK LOCKING" has gone out, and the chooser re-arms its
	// spent idle alarm only on a reply lacking that token -- so without this, a vetoed lock is silent and the
	// session can end up CE-unlocked with no idle bound and no 12h wipe (the NWP-20260922-07 defect, re-opened
	// through this veto). "OK LOGOFF" is neither LOCKING nor NOSESSION, which makes the unchanged chooser
	// re-arm AND correctly keep holding the cold wakelock.
	if !hasCodeLinePrefix(src, `fmt.Fprint(conn, "OK LOGOFF`) {
		t.Error("handleColdLock no longer refuses a logoff-in-flight BEFORE replying. A late veto cannot tell " +
			"the chooser, so the idle alarm is consumed and never re-armed")
	}
	if !strings.Contains(src, "func handleColdLock(") {
		t.Fatal("control failed: could not find handleColdLock in main.go, so the checks above prove nothing")
	}
}

// hasCodeLine / hasCodeLinePrefix: a line of real code, not a mention inside a comment. The difference is
// load-bearing here -- commenting a call out leaves its text in the file, so strings.Contains still matches,
// and an assertion written that way passes while the thing it pins is gone.
func codeLines(src string) []string {
	var out []string
	for _, ln := range strings.Split(src, "\n") {
		t := strings.TrimSpace(ln)
		if t == "" || strings.HasPrefix(t, "//") {
			continue
		}
		out = append(out, t)
	}
	return out
}

func hasCodeLinePrefix(src, want string) bool {
	for _, t := range codeLines(src) {
		if strings.HasPrefix(t, want) {
			return true
		}
	}
	return false
}

// ⚠ THE SAME-UID CASE, which a uid-only compare-and-clear cannot express -- and which this design's own
// centrepiece creates. The #125 stall watchdog re-arms .roamsession and tells the user they are still signed
// in WHILE THE FIRST SEAL KEEPS UPLOADING, so they can tap Log off again: two logoff goroutines, same uid,
// overlapping. sessionMu orders their synchronous prefixes but not their releases, so without a sequence the
// FIRST goroutine's defer clears the SECOND's claim and the veto is off for the whole retry seal -- the
// longest window there is.
func TestLogoffVetoSurvivesAnOverlappingSameUidRetry(t *testing.T) {
	t.Cleanup(func() { setLogoffInFlight("") })

	first := setLogoffInFlight("10")  // G1: the original logoff
	second := setLogoffInFlight("10") // G2: the retry, after the watchdog re-armed the marker
	if first == second {
		t.Fatal("control failed: two claims got the same sequence, so the assertion below cannot distinguish " +
			"them and would pass for the wrong reason")
	}

	clearLogoffInFlight("10", first) // G1 finally returns and releases
	if !logoffInFlight("10") {
		t.Error("the FIRST logoff's release cleared the RETRY's claim. The veto is now off for the whole of " +
			"the second seal -- 42 to 56 minutes, measured -- which is precisely the window this slice exists " +
			"to protect, re-opened at its widest")
	}

	clearLogoffInFlight("10", second)
	if logoffInFlight("10") {
		t.Error("the owning release did not clear its own claim -- the veto would outlive the logoff and " +
			"suppress every later cold lock for that user")
	}
}

// hasCodeLineFollowedBy: a code line exactly equal to `line`, whose NEXT code line starts with `nextPrefix`.
// Needed because the same guard text appears at three sites here, so "does it exist" and even "are there at
// least two" both passed while the specific one under test was disabled.
func hasCodeLineFollowedBy(src, line, nextPrefix string) bool {
	ls := codeLines(src)
	for i := 0; i+1 < len(ls); i++ {
		if ls[i] == line && strings.HasPrefix(ls[i+1], nextPrefix) {
			return true
		}
	}
	return false
}
