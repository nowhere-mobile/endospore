package main

import (
	"strings"
	"testing"
)

// NWP-20261130-01: every SMS and MMS row carries its SIM's tag in a slot of its own, so the session's chooser can file
// it under that SIM's subscription (docs/product-decisions.md, 2026-11-06). The rest of the wire stays as it was: an
// untagged row parses as before, a call row is byte-identical, and a sealed copy goes only when its row is named by an
// acknowledgement. core/agent/test-telingest-sim-slot.sh runs these plain and with --mutate.

func TestSimSlotRoundTrips(t *testing.T) {
	tx := simTag(iccidX)
	sms := strings.TrimRight(serializeTelIngest([]telItem{{Kind: "sms", From: "+1", When: 7, Body: "hi"}}, tx), "\n")
	if want := "sms 7 0 0 " + b64tok("+1") + " " + b64tok("hi") + " sim:" + tx; sms != want {
		t.Fatalf("sms row = %q, want %q", sms, want)
	}
	mms := strings.TrimRight(serializeTelIngest([]telItem{{Kind: "mms", From: "+1", When: 8}}, tx), "\n")
	f := strings.Fields(mms)
	if len(f) != 4 || f[0] != "mms" || f[1] != "8" || f[3] != "sim:"+tx {
		t.Fatalf("mms row = %q, want mms <when> <json> sim:<tag>", mms)
	}
	for _, row := range []string{sms, sms + " 2", mms, mms + " 2"} {
		if got := rowTag(row); got != tx {
			t.Fatalf("rowTag(%q) = %q, want %q", row, got, tx)
		}
	}
}

func TestUntaggedRowParsesAsBefore(t *testing.T) {
	for _, it := range []telItem{{Kind: "sms", From: "+1", When: 7, Body: "hi"}, {Kind: "mms", From: "+1", When: 8}} {
		for _, tag := range []string{"", "not-a-tag"} {
			row := serializeTelIngest([]telItem{it}, tag)
			if strings.Contains(row, "sim:") {
				t.Fatalf("tag %q added a slot: %q", tag, row)
			}
		}
	}
	for _, row := range []string{
		"sms 1 0 0 KzE aGk=", "sms 1 0 0 KzE aGk= 2", "sms 1 0 0 KzE -", "mms 1 e30=", "mms 1 e30= 1",
	} {
		if got := rowTag(row); got != "" {
			t.Fatalf("rowTag(%q) = %q, want none", row, got)
		}
	}
}

func TestCallRowUnchangedBySlot(t *testing.T) {
	tx := simTag(iccidX)
	it := telItem{Kind: "call", From: "+1", When: 5, CallType: 3, DurSec: 2}
	if got, want := serializeTelIngest([]telItem{it}, tx), "call 5 3 2 "+b64tok("+1")+" -"+tx+"\n"; got != want {
		t.Fatalf("tagged call row = %q, want %q", got, want)
	}
	if got, want := serializeTelIngest([]telItem{it}, ""), "call 5 3 2 "+b64tok("+1")+" -\n"; got != want {
		t.Fatalf("untagged call row = %q, want %q", got, want)
	}
}

func TestSimSlotOnlyAtItsPosition(t *testing.T) {
	tx := simTag(iccidX)
	for _, row := range []string{
		"sms 1 0 0 KzE sim:" + tx,         // the body slot, not the tag's
		"sms 1 0 0 KzE aGk= 1 sim:" + tx,  // after a retry token
		"sms 1 0 0 KzE aGk= sim:zz",       // not a tag
		"sms 1 0 0 KzE aGk= sim:",         // empty
		"sms 1 0 0 KzE aGk= " + tx,        // no prefix
		"mms 1 sim:" + tx,                 // the JSON slot
		"mms 1 e30= 1 sim:" + tx,          // after a retry token
		"mms 1 e30= sim:ABCDEF0123456789", // upper case is not a tag
		"call 5 3 0 KzE - sim:" + tx,      // a call row has no such slot
		"fax 1 2 3 4 5 sim:" + tx,         // not a row kind that has one
	} {
		if got := rowTag(row); got != "" {
			t.Fatalf("rowTag(%q) = %q, want none", row, got)
		}
	}
}

// A re-staged row goes back to its SIM's mailbox with its slot and its retry count, and an unassign in between drops
// it, as a call row always was.
func TestRestageKeepsTaggedSmsOnItsSim(t *testing.T) {
	useTempIngest(t)
	useTempBindings(t)
	if err := setBindingOwner(1, iccidX, "X", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	tx, ty := simTag(iccidX), simTag(iccidY)
	row := "sms 9 0 0 KzE aGk= sim:" + tx + " 1"
	if dropped, err := restageTelIngest("12", row); dropped || err != nil {
		t.Fatalf("restage on a bound SIM: dropped=%v err=%v", dropped, err)
	}
	mustExist(t, "the SIM's mailbox", telIngestPath("12", tx))
	if got := strings.TrimSpace(string(mustClaim(t, "12"))); got != row {
		t.Fatalf("re-staged row = %q, want %q", got, row)
	}
	if dropped, err := restageTelIngest("12", "mms 9 e30= sim:"+ty+" 1"); !dropped || err != nil {
		t.Fatalf("restage on an unbound SIM: dropped=%v err=%v, want the row dropped", dropped, err)
	}
}

// A chooser that predates the slot reads "sim:<tag>" as a retry that does not parse, so it re-stages the row without
// the slot. The claim's record still finds the row's SIM.
func TestOlderChooserRestageStaysOnItsSim(t *testing.T) {
	useTempIngest(t)
	useTempBindings(t)
	if err := setBindingOwner(1, iccidX, "X", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	tx := simTag(iccidX)
	if err := appendTelIngest("13", tx, telItem{Kind: "sms", From: "+1", When: 9, Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	mustClaim(t, "13")
	if dropped, err := restageTelIngest("13", "sms 9 0 0 KzE aGk= 1"); dropped || err != nil {
		t.Fatalf("restage: dropped=%v err=%v", dropped, err)
	}
	mustExist(t, "the SIM's mailbox", telIngestPath("13", tx))
}

// The chooser's TelSub.simTag must agree with this. The Java suite pins the same two inputs and the same answer.
func TestSimTagGoldenVector(t *testing.T) {
	for _, iccid := range []string{"89014103211118510720", "89014103211118510720f"} {
		if got := simTag(iccid); got != "cb8e5339c47c9acc" {
			t.Fatalf("simTag(%q) = %q", iccid, got)
		}
	}
}

// The interim: a row its session could not read back is never named by ACK-TELROWS, so its sealed copy stays and the
// next sign-in serves it again, with its slot. A named row's copy goes.
func TestUnacknowledgedRowStaysPending(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	const ref = "refSimSlotPending"
	tx := simTag(iccidX)
	v, dk := stageTwo(t, ref, tx)
	if n, err := stageTelInbox(v, dk, ref, "12"); n != 2 || err != nil {
		t.Fatalf("stage = %d, %v; want 2", n, err)
	}
	mustClaim(t, "12")
	if n := ackPending("12", []string{"sms 101"}); n != 1 {
		t.Fatalf("the ack of the row that read back removed %d copies, want 1", n)
	}
	if l := listPending(ref); len(l) != 1 {
		t.Fatalf("%d copies left, want the one row that was not acknowledged", len(l))
	}
	removeMailboxes("12")
	if n, err := stageTelInbox(v, dk, ref, "14"); n != 1 || err != nil {
		t.Fatalf("next sign-in stage = %d, %v; want the unacknowledged row", n, err)
	}
	got := strings.TrimSpace(string(mustClaim(t, "14")))
	if f := strings.Fields(got); len(f) != 7 || f[1] != "102" || f[6] != "sim:"+tx {
		t.Fatalf("the next sign-in was served %q, want only row 102 with its slot", got)
	}
}
