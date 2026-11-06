package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261113-04: handleRotate took no seal guard, and the periodic seal does not take the dispatcher's sessionMu. A
// passphrase change that overlapped a periodic seal withheld a pointer the seal had moved, reported COMMITTED with no
// plan carry, and the seal failed its lease with HTTP 403. A live session's ROTATE now answers BUSY while any seal is
// running or queued, and the periodic loop announces no seal while a rotation holds the window.

// rotateSealFixture resets the announce state and the delete and rotate windows, now and on cleanup.
func rotateSealFixture(t *testing.T) {
	t.Helper()
	reset := func() {
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealRunAt, deleteInFlight, rotateInFlight = false, "", time.Time{}, false, false
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

func rotateWindowHeld() bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return rotateInFlight
}

const rsbOld, rsbNew = "horse battery staple correct", "a completely different passphrase"

// rotateRefusedThenAllowed: with the seal state arm() sets, the live session's rotation is BUSY and touches nothing;
// once the seal is gone, the same rotation (still from the OLD passphrase, so nothing was written) commits.
func rotateRefusedThenAllowed(t *testing.T, name string, arm func()) {
	t.Helper()
	dest := capRotateFixture(t)
	rotateSealFixture(t)
	calls := stubRekey(t, "OK")
	if createVault("s3", name, rsbOld) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	liveMarker(t, dest, name, rsbOld, "10", "")
	arm()
	if got := rotateVerb(t, dest, name, rsbOld, rsbNew); got != "BUSY" {
		t.Fatalf("the live session's rotation during a seal replied %q, want BUSY", got)
	}
	if len(*calls) != 0 {
		t.Errorf("a BUSY rotation re-keyed the keyguard %d time(s), want 0", len(*calls))
	}
	if rotateWindowHeld() {
		t.Error("a refused rotation left rotateInFlight set")
	}
	if _, _, ok := resolveKey("s3", name, rsbOld); !ok {
		t.Error("the old passphrase no longer opens the profile after a BUSY rotation")
	}
	rotateSealFixture(t)
	if got := rotateVerb(t, dest, name, rsbOld, rsbNew); got != "OK 0" {
		t.Fatalf("control: the rotation with no seal replied %q, want OK 0", got)
	}
	if len(*calls) != 1 {
		t.Errorf("control: the keyguard was re-keyed %d time(s), want 1", len(*calls))
	}
	if rotateWindowHeld() {
		t.Error("rotateInFlight stayed set after the rotation returned")
	}
}

// (a) A queued periodic counts however old its stamp: sealAnnounced's test, not anySealRunning's expiring one.
func TestRotateSealBusyWhileAPeriodicIsQueued(t *testing.T) {
	rotateRefusedThenAllowed(t, "rsbusy-kind", func() {
		pendingReapMu.Lock()
		sealRunKind, sealRunAt = "periodic", time.Now().Add(-sealRunExpiry-time.Minute)
		pendingReapMu.Unlock()
	})
}

// (b) A logoff or manual seal in flight.
func TestRotateSealBusyWhileASealIsInFlight(t *testing.T) {
	rotateRefusedThenAllowed(t, "rsbusy-inflight", func() {
		pendingReapMu.Lock()
		sealInFlight = true
		pendingReapMu.Unlock()
	})
}

// (c) BUSY is a named reply, so only the live session gets it: anyone else's rotation keeps the blind answer.
func TestRotateSealBusyOnlyForTheLiveSession(t *testing.T) {
	dest := capRotateFixture(t)
	rotateSealFixture(t)
	calls := stubRekey(t, "OK")
	const mark = "rsbusy-mark"
	if createVault("s3", mark, rsbOld) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	liveMarker(t, dest, mark, rsbOld, "10", "")
	setSealRun("periodic")
	if got := rotateVerb(t, dest, "rsbusy-other", rsbOld, rsbNew); got == "BUSY" {
		t.Error("a rotation for a profile the marker does not name was answered BUSY")
	}
	if got := rotateVerb(t, dest, mark, "not the session passphrase", rsbNew); got == "BUSY" {
		t.Error("a rotation whose old passphrase is not the marker's was answered BUSY")
	}
	if len(*calls) != 0 {
		t.Errorf("a non-live rotation re-keyed the keyguard %d time(s), want 0", len(*calls))
	}
}

// (d) While a rotation holds the window the periodic loop defers and the announce refuses; both return after.
func TestRotateSealBusyHoldsThePeriodicSealOff(t *testing.T) {
	rotateSealFixture(t)
	now := time.Now()
	for _, c := range []struct {
		what string
		arm  func()
	}{
		{"sealInFlight", func() { sealInFlight = true }},
		{"a fresh announce", func() { sealRunKind, sealRunAt = "periodic", now }},
		{"an expired announce", func() { sealRunKind, sealRunAt = "periodic", now.Add(-sealRunExpiry-time.Minute) }},
	} {
		pendingReapMu.Lock()
		c.arm()
		pendingReapMu.Unlock()
		if beginRotate(now) {
			t.Errorf("beginRotate claimed the window with %s", c.what)
		}
		if rotateWindowHeld() {
			t.Errorf("a refused beginRotate (%s) set rotateInFlight", c.what)
		}
		rotateSealFixture(t)
	}

	if !beginRotate(now) {
		t.Fatal("beginRotate refused with no seal running or queued")
	}
	pendingReapMu.Lock()
	got := deleteDeferLocked("")
	kept := deleteDeferLocked("login")
	deleteInFlight = true
	both := deleteDeferLocked("")
	deleteInFlight = false
	pendingReapMu.Unlock()
	if got != "rotate-in-flight" {
		t.Errorf("defer reason with a rotation in flight = %q, want rotate-in-flight", got)
	}
	if kept != "login" {
		t.Errorf("a hold's reason must stand during a rotation; got %q", kept)
	}
	if both != "delete-in-flight" {
		t.Errorf("with a delete and a rotation both set the reason is %q, want delete-in-flight", both)
	}
	if announcePeriodicSeal() {
		t.Error("announcePeriodicSeal announced during a rotation")
	}
	if k := func() string { pendingReapMu.Lock(); defer pendingReapMu.Unlock(); return sealRunKind }(); k != "" {
		t.Errorf("a refused announce left sealRunKind=%q", k)
	}

	endRotate()
	pendingReapMu.Lock()
	after := deleteDeferLocked("")
	pendingReapMu.Unlock()
	if after != "" {
		t.Errorf("defer reason after endRotate = %q, want none", after)
	}
	if !announcePeriodicSeal() {
		t.Error("announcePeriodicSeal refused after endRotate")
	}
}

// (e) The guard is the first thing handleRotate does for the live session: before the SE read, the keyguard re-key
// and the vault rotation. syncLoop's refused-announce line names both windows.
func TestRotateSealBusySourceOrder(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\nfunc handleRotate(")
	if i < 0 {
		t.Fatal("handleRotate not found in main.go")
	}
	body := src[i:]
	if j := strings.Index(body, "\n}\n"); j >= 0 {
		body = body[:j]
	}
	guard := strings.Index(body, "beginRotate(")
	if guard < 0 {
		t.Fatal("handleRotate does not call beginRotate")
	}
	for _, later := range []string{"readRoamSessionSE(", "rekeyKeyguard(", "rotateVaultVerdict("} {
		k := strings.Index(body, later)
		if k < 0 {
			t.Errorf("handleRotate no longer calls %s", later)
		} else if guard > k {
			t.Errorf("handleRotate calls %s before beginRotate", later)
		}
	}
	for _, want := range []string{`say("BUSY")`, "defer endRotate()"} {
		if !strings.Contains(body, want) {
			t.Errorf("handleRotate no longer contains %s", want)
		}
	}
	if !strings.Contains(src, "periodic seal deferred: delete-or-rotate-in-flight") {
		t.Error("syncLoop's refused-announce line does not name the rotation")
	}
}

// (f) RF-001: the BUSY line prints the marker's uid only when it looks like one. A marker that lost its uid line reads
// as (name, pass, se_secret), live still holds, and the third field is the secure-element secret: the refusal must not
// log it. A real uid is still named.
func TestRotateSealBusyLogNeverPrintsAShiftedSecret(t *testing.T) {
	dest := capRotateFixture(t)
	rotateSealFixture(t)
	stubRekey(t, "OK")
	const name = "rsbusy-shifted"
	secret := strings.Repeat("5eca1d0b", 8)
	writeMarker(t, dest, name+"\n"+rsbOld+"\n"+secret+"\n")
	setSealRun("periodic")
	var got string
	log := captureStderr(t, func() { got = rotateVerb(t, dest, name, rsbOld, rsbNew) })
	if got != "BUSY" {
		t.Fatalf("the live session's rotation on a shifted marker during a seal replied %q, want BUSY", got)
	}
	if strings.Contains(log, secret) {
		t.Error("the BUSY log printed the shifted marker's secure-element secret")
	}
	if !strings.Contains(log, "rotate user set: BUSY") {
		t.Errorf("the BUSY log does not render the shifted uid field as its presence; got %q", log)
	}

	rotateSealFixture(t)
	liveMarker(t, dest, name, rsbOld, "10", "")
	setSealRun("periodic")
	log = captureStderr(t, func() { got = rotateVerb(t, dest, name, rsbOld, rsbNew) })
	if got != "BUSY" {
		t.Fatalf("control: the rotation on a complete marker replied %q, want BUSY", got)
	}
	if !strings.Contains(log, "rotate user 10: BUSY") {
		t.Errorf("the BUSY log no longer names a real uid; got %q", log)
	}
}
