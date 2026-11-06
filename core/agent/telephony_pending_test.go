package main

import (
	"bufio"
	"net"
	"strings"
	"testing"
)

// NWP-20261006-05 (option (b), Chester 2026-10-06): a sealed copy is kept, PENDING for the session it was handed to,
// until that session's chooser acknowledges inserting the row; a session that ends first leaves the copy for the
// profile's next sign-in.

func stageTwo(t *testing.T, ref, tag string) (*vault, []byte) {
	t.Helper()
	v, dk := vaultWithTelKey(t)
	for _, w := range []int64{101, 102} {
		if err := sealItemToInbox(ref, v.TelPub, tag, telItem{Kind: "sms", From: "+1", When: w, Body: "b"}); err != nil {
			t.Fatal(err)
		}
	}
	return v, dk
}

func TestHandedOffCopiesStayPendingUntilAcked(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	const ref = "refP"
	v, dk := stageTwo(t, ref, "")
	if n, err := stageTelInbox(v, dk, ref, "12"); n != 2 || err != nil {
		t.Fatalf("stage = %d, %v; want 2", n, err)
	}
	if l := listSealed(ref); l != nil {
		t.Fatalf("unstaged blobs left after the hand-off: %v", l)
	}
	p := listPending(ref)
	if len(p) != 2 || pendingUID(p[0]) != "12" || pendingUID(p[1]) != "12" {
		t.Fatalf("pending copies = %v, want two for user 12 -- the hand-off must keep a copy until the insert", p)
	}
	if n := ackPending("12", []string{"sms 101"}); n != 1 {
		t.Fatalf("ack of one landed row removed %d copies, want 1", n)
	}
	if l := listPending(ref); len(l) != 1 {
		t.Fatalf("after one ack, %d pending left, want 1 (the row not acknowledged)", len(l))
	}
	// Another session's ack does not touch user 12's copies.
	if n := ackPending("13", []string{"sms 102"}); n != 0 {
		t.Fatalf("user 13 acknowledged user 12's row (%d removed)", n)
	}
}

// The point of (b): a session that ends before inserting leaves the copy, and the profile's NEXT sign-in (a new uid)
// gets the row again -- and its copy becomes pending for that new session.
func TestPendingForAnEndedSessionIsStagedAtTheNextSignIn(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	const ref = "refP"
	v, dk := stageTwo(t, ref, "")
	if n, _ := stageTelInbox(v, dk, ref, "12"); n != 2 {
		t.Fatalf("first stage = %d, want 2", n)
	}
	if _, err := claimTelIngest("12"); err != nil { // user 12's chooser claims, then the session ends unacknowledged
		t.Fatal(err)
	}
	removeMailboxes("12")
	if n, err := stageTelInbox(v, dk, ref, "14"); n != 2 || err != nil {
		t.Fatalf("next sign-in stage = %d, %v; want both rows again", n, err)
	}
	for _, p := range listPending(ref) {
		if pendingUID(p) != "14" {
			t.Fatalf("a re-staged copy is still pending for the ended session: %s", p)
		}
	}
	if keys := mailboxKeys("14"); !keys["sms 101"] || !keys["sms 102"] {
		t.Fatalf("the new session's mailbox lacks the rows: %v", keys)
	}
}

// A resume of the SAME session must not queue a row twice while it still waits in the mailbox; once it has been
// claimed and never acknowledged, the resume stages it again.
func TestResumeDoesNotRestageARowStillQueued(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	const ref = "refP"
	v, dk := stageTwo(t, ref, "")
	stageTelInbox(v, dk, ref, "12")
	if n, _ := stageTelInbox(v, dk, ref, "12"); n != 0 {
		t.Fatalf("a resume staged %d rows that were still queued", n)
	}
	if strings.Count(string(mustClaim(t, "12")), "\n") != 2 {
		t.Fatal("the mailbox does not hold each row exactly once")
	}
	if n, _ := stageTelInbox(v, dk, ref, "12"); n != 2 {
		t.Fatalf("after a claim with no ack, a resume staged %d rows, want both", n)
	}
}

func mustClaim(t *testing.T, uid string) []byte {
	t.Helper()
	b, err := claimTelIngest(uid)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// A live arrival keeps a pending copy for the live session; an ack drops it.
func TestLiveArrivalKeepsAPendingCopy(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	v, _ := vaultWithTelKey(t)
	ref := profileRefV2("alice", "pw")
	b := simBinding{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open", Owners: []bindingOwner{{ref, v.TelPub}}}
	var appended string
	underTelMu(func() { _, appended, _ = deliverToOwners(dest, b, testSMS) })
	if appended != "10" {
		t.Fatalf("not delivered live: %q", appended)
	}
	p := listPending(ref)
	if len(p) != 1 || pendingUID(p[0]) != "10" || blobTag(p[0]) != simTag(iccidX) {
		t.Fatalf("live arrival pending copies = %v, want one for user 10 tagged with its SIM", p)
	}
	if n := ackPending("10", []string{itemRowKey(testSMS)}); n != 1 || listPending(ref) != nil {
		t.Fatalf("the ack removed %d and left %v", n, listPending(ref))
	}
}

// An unassign deletes the SIM's pending copies with its sealed ones (the 2026-09-24 decision).
func TestUnassignDeletesPendingCopies(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	const ref = "refP"
	v, dk := stageTwo(t, ref, simTag(iccidX))
	stageTelInbox(v, dk, ref, "12")
	if len(listPending(ref)) != 2 {
		t.Fatal("setup: no pending copies")
	}
	if n, err := deleteSimBlobs(simTag(iccidX)); n != 2 || err != nil {
		t.Fatalf("unassign deleted %d, %v; want both pending copies", n, err)
	}
}

// The verb: a caller with no peer credentials is refused, and a malformed count is refused before any read of keys.
func TestAckTelRowsVerb(t *testing.T) {
	useTempInbox(t)
	for _, c := range []struct{ req, want string }{
		{"1\nsms 1\n", "ERR"},    // net.Pipe has no peer uid
		{"x\n", "ERR count"},     // not a number
		{"99999\n", "ERR count"}, // over the cap
	} {
		server, client := net.Pipe()
		done := make(chan string, 1)
		go func() {
			l, _ := bufio.NewReader(client).ReadString('\n')
			done <- strings.TrimSpace(l)
		}()
		handleTelCmd(server, bufio.NewReader(strings.NewReader(c.req)), t.TempDir(), "ACK-TELROWS")
		server.Close()
		if got := <-done; got != c.want {
			t.Errorf("ACK-TELROWS %q -> %q, want %q", c.req, got, c.want)
		}
		client.Close()
	}
}
