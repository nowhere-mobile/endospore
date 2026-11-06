package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261006-03: after a ROAM-IN or RESUME replies OK, the chooser still prepares the user before it switches in
// and kicks the login's own delivery run. An arrival in that gap used to be kicked LIVE into a session that could not
// take it yet. The bring-up is now held past the reply until the session's own GET-TELINGEST claims, or a cap.
func resetStaging(t *testing.T) {
	t.Helper()
	underTelMu(func() { telStagingUID, telStagingUntil = "", time.Time{} })
	t.Cleanup(func() { underTelMu(func() { telStagingUID, telStagingUntil = "", time.Time{} }) })
}

func holds(uid string) (h bool) {
	underTelMu(func() { h = telStagingHolds(uid) })
	return h
}

func TestHeldBringUpEndsAtTheSessionsOwnClaim(t *testing.T) {
	resetStaging(t)
	useTempIngest(t)
	if err := beginTelStaging("10", true); err != nil {
		t.Fatal(err)
	}
	if !holdTelStagingUntilClaim("10") {
		t.Fatal("a bring-up still current did not hold")
	}
	if !holds("10") {
		t.Fatal("a held bring-up does not hold arrivals back")
	}
	if holds("11") {
		t.Fatal("another user's arrivals are held back")
	}
	var w bytes.Buffer
	underTelMu(func() { serveGetTelIngest(&w, 10*100000+123) }) // user 10's chooser claims (uid 1000123)
	if holds("10") {
		t.Fatal("the session's own claim did not end the hold -- live delivery would stay off until the cap")
	}
}

// A held bring-up survives its handler's deferred end; one never held does not.
func TestHandlerEndLeavesAHeldBringUp(t *testing.T) {
	resetStaging(t)
	if err := beginTelStaging("10", true); err != nil {
		t.Fatal(err)
	}
	holdTelStagingUntilClaim("10")
	endTelStaging("10") // the handler returns
	if !holds("10") {
		t.Fatal("the handler's return ended a held bring-up -- the gap before the switch is open again")
	}
	if err := beginTelStaging("11", true); err != nil {
		t.Fatal(err)
	}
	endTelStaging("11") // a failed sign-in: never held
	if holds("11") {
		t.Fatal("a bring-up that was never held outlived its handler")
	}
}

func TestHeldBringUpExpiresAtTheCap(t *testing.T) {
	resetStaging(t)
	if err := beginTelStaging("10", true); err != nil {
		t.Fatal(err)
	}
	holdTelStagingUntilClaim("10")
	underTelMu(func() { telStagingUntil = time.Now().Add(-time.Second) }) // the cap has passed
	if holds("10") {
		t.Fatal("a hold past its cap still holds -- a session whose run never came would stay silent")
	}
}

// While the handler itself runs (no hold yet) a claim must not end it: there is no switched-in session to claim, and
// the handler's own defer ends it.
func TestHandlerStagingIsNotEndedByAClaim(t *testing.T) {
	resetStaging(t)
	useTempIngest(t)
	if err := beginTelStaging("10", true); err != nil {
		t.Fatal(err)
	}
	var w bytes.Buffer
	underTelMu(func() { serveGetTelIngest(&w, 10*100000+123) })
	if !holds("10") {
		t.Fatal("a claim ended a bring-up whose handler is still running")
	}
}

// A newer bring-up wins: holding an older uid after another has begun does nothing.
func TestHoldDoesNotTakeANewerBringUp(t *testing.T) {
	resetStaging(t)
	if err := beginTelStaging("10", true); err != nil {
		t.Fatal(err)
	}
	if err := beginTelStaging("11", true); err != nil {
		t.Fatal(err)
	}
	if holdTelStagingUntilClaim("10") {
		t.Fatal("an older bring-up held over a newer one")
	}
	if !holds("11") || holds("10") {
		t.Fatal("the newer bring-up is not the one held")
	}
}

// End to end through the arrival hand-off: during a held bring-up a bound owner's arrival is appended for the
// session WITHOUT a live kick; once the session's own run has claimed, the next one is kicked live.
func TestArrivalDuringHeldBringUpIsNotKicked(t *testing.T) {
	resetStaging(t)
	useTempInbox(t)
	useTempIngest(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	v, _ := vaultWithTelKey(t)
	b := simBinding{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open",
		Owners: []bindingOwner{{profileRefV2("alice", "pw"), v.TelPub}}}
	if err := beginTelStaging("10", false); err != nil {
		t.Fatal(err)
	}
	holdTelStagingUntilClaim("10")
	var appended string
	var kick bool
	underTelMu(func() { _, appended, kick = deliverToOwners(dest, b, testSMS) })
	if appended != "10" || kick {
		t.Fatalf("held bring-up: appended=%q kick=%v, want the session's mailbox and NO kick", appended, kick)
	}
	var w bytes.Buffer
	underTelMu(func() { serveGetTelIngest(&w, 10*100000+5) })
	underTelMu(func() { _, appended, kick = deliverToOwners(dest, b, testSMS) })
	if appended != "10" || !kick {
		t.Fatalf("after the session's own claim: appended=%q kick=%v, want a live kick", appended, kick)
	}
}

// Both bring-up handlers hold on their OK reply, after the deferred endTelStaging is registered (which then leaves a
// held bring-up alone). Pinned from source: the handlers need a store and a worker to drive.
func TestBringUpHandlersHoldAtTheirOKReply(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"handleRoamIn", "handleResume"} {
		body := strings.Join(stripComments(funcBody(t, string(b), fn)), "\n")
		iDefer := strings.Index(body, "defer endTelStaging(uid)")
		iHold := strings.Index(body, "holdTelStagingUntilClaim(uid)")
		if iDefer < 0 || iHold < 0 || iHold < iDefer {
			t.Errorf("%s does not hold its bring-up past the OK reply (defer at %d, hold at %d)", fn, iDefer, iHold)
		}
	}
}

// The cap is what keeps a session whose own run never comes from going silent: past it, an arrival is kicked live
// again even though the bring-up was never claimed.
func TestArrivalPastTheCapIsKickedLive(t *testing.T) {
	resetStaging(t)
	useTempInbox(t)
	useTempIngest(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	v, _ := vaultWithTelKey(t)
	b := simBinding{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open",
		Owners: []bindingOwner{{profileRefV2("alice", "pw"), v.TelPub}}}
	if err := beginTelStaging("10", false); err != nil {
		t.Fatal(err)
	}
	holdTelStagingUntilClaim("10")
	underTelMu(func() { telStagingUntil = time.Now().Add(-time.Second) })
	var appended string
	var kick bool
	underTelMu(func() { _, appended, kick = deliverToOwners(dest, b, testSMS) })
	if appended != "10" || !kick {
		t.Fatalf("past the cap: appended=%q kick=%v, want a live kick", appended, kick)
	}
}
