package main

import (
	"errors"
	"os"
	"strings"
	"testing"
)

// NWP-20261016-21: a rollback that fails leaves the session alive, and an arrival during its store round trip was
// sealed (the marker was down). The failure branch now stages the inbox for the surviving session, and the Profile
// screen kicks a delivery run. test-rollback-inbox.sh re-runs this file against broken copies of the sources.

const rbInboxUID = "11"

// rbInboxStore stands up a profile (pass-only, or hardened with the returned secret) with one sealed telephony item
// in its inbox, and returns the store, the profile ref the item was sealed under and the vault.
func rbInboxStore(t *testing.T, name, pass string, hardened bool) (base, ref string, se []byte) {
	t.Helper()
	telFixture(t)
	base = newHTTPStore(t)
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if hardened {
		se = []byte("this-handsets-strongbox-secret")
		if err := enrollSE(base, name, pass, se); err != nil {
			t.Fatalf("enrollSE: %v", err)
		}
	}
	v, ok := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !ok || v.TelPub == "" {
		t.Fatal("the stored vault has no telephony key")
	}
	ref = profileRefV2(name, pass)
	if err := sealItemToInbox(ref, v.TelPub, simTag(iccidX), telItem{Kind: "sms", From: "+15550000001", When: 42, Body: "during"}); err != nil {
		t.Fatal(err)
	}
	return base, ref, se
}

func rbInboxRows(t *testing.T) []string {
	t.Helper()
	b, err := claimTelIngest(rbInboxUID)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) == 0 {
		return nil
	}
	return strings.Split(strings.TrimRight(string(b), "\n"), "\n")
}

func TestRollbackInbox_StagesForAPassOnlyProfile(t *testing.T) {
	base, ref, _ := rbInboxStore(t, "rbpass", "horse battery staple correct", false)
	stageTelInboxForLiveSession(base, "rbpass", "horse battery staple correct", rbInboxUID, nil)
	// The row is queued, and the sealed copy is kept pending for this session (RESUME's handling): staging again
	// must not queue it twice.
	stageTelInboxForLiveSession(base, "rbpass", "horse battery staple correct", rbInboxUID, nil)
	rows := rbInboxRows(t)
	if len(rows) != 1 || !strings.HasPrefix(rows[0], "sms 42 ") {
		t.Fatalf("mailbox rows %q, want exactly the one sealed arrival", rows)
	}
	if p := listPending(ref); len(p) != 1 || pendingUID(p[0]) != rbInboxUID {
		t.Errorf("pending copies %q, want the one sealed copy kept for session %s until it acknowledges the row (2026-10-06)", p, rbInboxUID)
	}
}

func TestRollbackInbox_AppendsToWhatTheMailboxHolds(t *testing.T) {
	base, _, _ := rbInboxStore(t, "rbappend", "horse battery staple correct", false)
	if err := appendTelIngest(rbInboxUID, simTag(iccidX), telItem{Kind: "sms", From: "+15550000002", When: 7, Body: "live"}); err != nil {
		t.Fatal(err)
	}
	stageTelInboxForLiveSession(base, "rbappend", "horse battery staple correct", rbInboxUID, nil)
	if rows := rbInboxRows(t); len(rows) != 2 {
		t.Fatalf("mailbox rows %q, want the live row and the staged one", rows)
	}
}

func TestRollbackInbox_HardenedStagesOnlyWithItsSecret(t *testing.T) {
	const name, pass = "rbhard", "horse battery staple correct"
	base, _, se := rbInboxStore(t, name, pass, true)
	stageTelInboxForLiveSession(base, name, pass, rbInboxUID, nil)
	if rows := rbInboxRows(t); len(rows) != 0 {
		t.Fatalf("staged %q for a hardened profile with no secret", rows)
	}
	stageTelInboxForLiveSession(base, name, pass, rbInboxUID, se)
	if rows := rbInboxRows(t); len(rows) != 1 {
		t.Fatalf("mailbox rows %q, want the one arrival staged with the captured secret", rows)
	}
}

func TestRollbackInbox_ADeadStoreStagesNothingAndDoesNotPanic(t *testing.T) {
	_, ref, _ := rbInboxStore(t, "rbdead", "horse battery staple correct", false)
	stageTelInboxForLiveSession("http://127.0.0.1:1", "rbdead", "horse battery staple correct", rbInboxUID, nil)
	if rows := rbInboxRows(t); len(rows) != 0 {
		t.Fatalf("staged %q with the store unreachable", rows)
	}
	if len(listSealed(ref)) != 1 {
		t.Error("the sealed copy must stay for the next login when the store cannot be reached")
	}
}

func rbInboxHandlerBody(t *testing.T) []string {
	t.Helper()
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	return stripComments(funcBody(t, string(b), "handleRollback"))
}

// The wiring: handleRollback hardcodes the "s3" store, so a behavioural test cannot reach it.
//
// rollbackHeadStore returns no error that wraps errStoreUnreachable (its reads answer "" and become plain errors); a
// transport panic is recovered into one inside handleRollback, and a skip would save nothing, so every failure stages.
func TestRollbackInbox_FailureBranchStagesAfterTheRearmAndBeforeTheReply(t *testing.T) {
	body := rbInboxHandlerBody(t)
	rearm, call, reply, headRolled := -1, -1, -1, -1
	for i, l := range body {
		s := strings.TrimSpace(l)
		switch {
		case strings.HasPrefix(s, "rearmRoamSession("):
			rearm = i
		case strings.Contains(s, "stageTelInboxForLiveSession("):
			if call >= 0 {
				t.Errorf("stageTelInboxForLiveSession is called twice in handleRollback")
			}
			call = i
			if s != `stageTelInboxForLiveSession("s3", name, pass, uid, seFromHex(seSecret))` {
				t.Errorf("the staging is not handed the captured secret: %s", s)
			}
		case s == `fmt.Fprint(conn, "NOSNAP\n") // stale list -> tell the user to pick again, not to check their connection`:
			reply = i
		case strings.HasPrefix(s, "clearLocalSession("):
			headRolled = i
		}
	}
	if rearm < 0 || call < 0 || reply < 0 || headRolled < 0 {
		t.Fatalf("handleRollback changed shape (rearm %d, stage %d, reply %d, success %d) -- this test is stale, not the code", rearm, call, reply, headRolled)
	}
	if !(rearm < call && call < reply) {
		t.Errorf("order is rearm %d, stage %d, reply %d; the marker must be back before staging, and the rows staged before the chooser is told", rearm, call, reply)
	}
	if call > headRolled {
		t.Errorf("the staging is on the success branch (line %d, success starts %d)", call, headRolled)
	}
	for _, l := range body {
		if strings.Contains(l, "errStoreUnreachable") && strings.Contains(strings.Join(body, "\n"), "stageTelInboxForLiveSession") {
			t.Errorf("handleRollback skips on errStoreUnreachable; rollbackHead never returns it, so that skip is dead code")
		}
		if strings.Contains(l, "seFromSession(") {
			t.Errorf("handleRollback re-reads the marker it removed: %s", strings.TrimSpace(l))
		}
	}
}

// telMu must never wait on the network: the helper reads the store first and takes it only inside
// stageTelInboxLocked. A source pin, because a test cannot see which lock a store round trip ran under.
func TestRollbackInbox_HelperNeverHoldsTelMuAcrossTheStoreReads(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "stageTelInboxForLiveSession"))
	reads, stage := -1, -1
	for i, l := range body {
		if strings.Contains(l, "telMu") || strings.Contains(l, "underTelMu") {
			t.Errorf("the helper takes telMu itself: %s", strings.TrimSpace(l))
		}
		if strings.Contains(l, "getHeadBlob(") {
			reads = i
		}
		if strings.Contains(l, "stageTelInboxLocked(") {
			stage = i
		}
	}
	if reads < 0 || stage < 0 || reads > stage {
		t.Errorf("the store reads (line %d) must precede stageTelInboxLocked (line %d)", reads, stage)
	}
}

// The Profile screen starts this session's delivery run on any reply that is not OK, off the UI thread.
func TestRollbackInbox_ChooserKicksDeliveryOnAFailedRollback(t *testing.T) {
	b, err := os.ReadFile("../chooser/src/com/nowhere/chooser/ProfileActivity.java")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `sendDaemon("ROLLBACK\n"`)
	if i < 0 {
		t.Fatal("the ROLLBACK send moved")
	}
	end := strings.Index(src[i:], "showSnapshots();")
	if end < 0 {
		t.Fatal("the ROLLBACK handler's end moved")
	}
	blk := src[i : i+end]
	guard := strings.Index(blk, `if (!SnapshotCopy.rolledBack(r)) {`)
	kick := strings.Index(blk, `startService(new android.content.Intent(this, CredentialService.class).putExtra("telingest", true));`)
	ui := strings.Index(blk, "runOnUiThread(")
	if guard < 0 || kick < 0 || ui < 0 {
		t.Fatalf("the failed-rollback kick is missing (guard %d, start %d, ui %d)", guard, kick, ui)
	}
	if !(guard < kick && kick < ui) {
		t.Errorf("the kick must sit in the non-OK guard (%d < %d) and before runOnUiThread (%d)", guard, kick, ui)
	}
}

// The common Wi-Fi-cut failure is a PANIC out of the store reads, not a returned error. With the marker already
// down it must be recovered into the failure branch: ERR to the chooser and the session re-armed.
func TestRollbackInbox_ATransportPanicReArmsTheSessionAndAnswersERR(t *testing.T) {
	f := rbSetup(t)
	rollbackHead = func(base, name, pass string, v uint64, se []byte) (uint64, error) {
		panic(storeReadErr{errors.New("dial tcp: network is unreachable")})
	}
	if got := f.roll(); got != "ERR" {
		t.Fatalf("got %q, want ERR", got)
	}
	if n, _, u := readRoamSession(f.dest); n != "alice" || u != "10" {
		t.Errorf("the session was not re-armed after a transport failure (%q, %q)", n, u)
	}
}

// A store read that panics inside the helper is logged, not swallowed: the sealed copies stay for the next login.
func TestRollbackInbox_ADeadStoreLogsThatStagingWasSkipped(t *testing.T) {
	log := captureStderr(t, func() {
		stageTelInboxForLiveSession("http://127.0.0.1:1", "rbdead2", "horse battery staple correct", rbInboxUID, nil)
	})
	if !strings.Contains(log, "telephony hand-off skipped") || strings.Contains(log, "horse battery") {
		t.Errorf("log %q: want the skip logged, and never the passphrase", log)
	}
}
