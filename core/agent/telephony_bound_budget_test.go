package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261019-02: the bound inbox has a soft line as well as a hard one, and its pending copies count against it.

// lowerBoundBudget sets the bound soft and hard lines for one test.
func lowerBoundBudget(t *testing.T, soft, hard int64) {
	t.Helper()
	oldS, oldH := telBoundBudgetSoft, telBoundBudgetHard
	telBoundBudgetSoft, telBoundBudgetHard = soft, hard
	t.Cleanup(func() { telBoundBudgetSoft, telBoundBudgetHard = oldS, oldH })
}

// plantBlob writes n bytes under dir as name (published, so telStoreUsage weighs it).
func plantBlob(t *testing.T, dir, name string, n int) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), make([]byte, n), 0o600); err != nil {
		t.Fatal(err)
	}
}

func budgetMms() telItem {
	return telItem{Kind: "mms", SubID: 1, From: "+15550001111", When: 42, Subject: "trip",
		Parts: []mmsPart{{ContentType: "image/jpeg", Data: make([]byte, 3<<10)}}}
}

// openOnly opens the single sealed blob in ref's buffer.
func openOnly(t *testing.T, dk []byte, v *vault, ref string) telItem {
	t.Helper()
	paths := listSealed(ref)
	if len(paths) != 1 {
		t.Fatalf("want 1 sealed blob, got %v", paths)
	}
	return openOwnerItem(t, telephonyPriv(v, dk), paths[0])
}

// (a) pending copies weigh on the bound budget: with .pend files up to the hard line, both writers refuse.
func TestBoundBudget_PendingCopiesCount(t *testing.T) {
	useTempInbox(t)
	lowerBoundBudget(t, 1<<10, 4<<10)
	dir := telInboxDir("refB")
	plantBlob(t, dir, "0123456789abcdef.0123456789abcdef.12.0123456789abcdef.pend", 4<<10)
	if err := bufferPending("refB", "", "12", "sms 1", "x"); err != errTelBoundFull {
		t.Fatalf("bufferPending over a pend-filled store = %v, want errTelBoundFull", err)
	}
	if err := bufferSealed("refB", "", "x"); err != errTelBoundFull {
		t.Fatalf("bufferSealed over a pend-filled store = %v, want errTelBoundFull", err)
	}
}

// (b) over the soft line an MMS for an offline owner is kept without its media.
func TestBoundBudget_MmsStrippedOverSoft(t *testing.T) {
	useTempInbox(t)
	lowerBoundBudget(t, 1<<10, 1<<20)
	v, dk := vaultWithTelKey(t)
	plantBlob(t, telInboxDir("other"), "0123456789abcdef.seal", 2<<10)
	if err := sealItemToInbox("refB", v.TelPub, "", budgetMms()); err != nil {
		t.Fatal(err)
	}
	got := openOnly(t, dk, v, "refB")
	if len(got.Parts) != 0 || got.Note != "too-large" || got.From != "+15550001111" || got.Subject != "trip" || got.When != 42 {
		t.Fatalf("stripped bound MMS = %+v (want no parts, note too-large, from/subject/when intact)", got)
	}
}

// (c) under the soft line the same MMS keeps its media and carries no note.
func TestBoundBudget_MmsWholeUnderSoft(t *testing.T) {
	useTempInbox(t)
	lowerBoundBudget(t, 1<<20, 2<<20)
	v, dk := vaultWithTelKey(t)
	if err := sealItemToInbox("refB", v.TelPub, "", budgetMms()); err != nil {
		t.Fatal(err)
	}
	got := openOnly(t, dk, v, "refB")
	if len(got.Parts) != 1 || got.Note != "" {
		t.Fatalf("under-soft bound MMS = %d parts, note %q; want 1 part, empty note", len(got.Parts), got.Note)
	}
}

// (d) an SMS and a call past the soft line have no media to shed: kept whole, with an empty Note.
func TestBoundBudget_NonMmsKeptWholePastSoft(t *testing.T) {
	useTempInbox(t)
	lowerBoundBudget(t, 1<<10, 1<<20)
	v, dk := vaultWithTelKey(t)
	plantBlob(t, telInboxDir("other"), "0123456789abcdef.seal", 2<<10)
	items := []telItem{
		{Kind: "sms", SubID: 1, From: "+15550002222", When: 7, Body: "hello"},
		{Kind: "call", SubID: 1, From: "+15550003333", When: 8, CallType: 3},
	}
	for i, it := range items {
		ref := "ref" + string(rune('A'+i))
		if err := sealItemToInbox(ref, v.TelPub, "", it); err != nil {
			t.Fatal(err)
		}
		got := openOnly(t, dk, v, ref)
		if got.Note != "" || got.Body != it.Body || got.From != it.From || got.CallType != it.CallType {
			t.Fatalf("%s past soft = %+v, want it whole with an empty Note", it.Kind, got)
		}
	}
}

// (e) a LIVE owner's mailbox row keeps its media; only the pending copy in the store is stripped.
func TestBoundBudget_LiveRowWholePendingCopyStripped(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	lowerBoundBudget(t, 1<<10, 1<<20)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	v, dk := vaultWithTelKey(t)
	ref := profileRefV2("alice", "pw")
	plantBlob(t, telInboxDir("other"), "0123456789abcdef.seal", 2<<10)
	b := simBinding{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open", Owners: []bindingOwner{{ref, v.TelPub}}}
	it := budgetMms()
	var appended string
	underTelMu(func() { _, appended, _ = deliverToOwners(dest, b, it) })
	if appended != "10" {
		t.Fatalf("not delivered live: %q", appended)
	}
	if row := mustClaim(t, "10"); len(row) < 3<<10 {
		t.Fatalf("live mailbox row is %d bytes, want the whole MMS (>= 3 KiB of media)", len(row))
	}
	p := listPending(ref)
	if len(p) != 1 {
		t.Fatalf("pending copies = %v, want one", p)
	}
	if blobTag(p[0]) != simTag(iccidX) || pendingUID(p[0]) != "10" {
		t.Fatalf("pending copy %s lost its SIM tag or session", p[0])
	}
	got := openOwnerItem(t, telephonyPriv(v, dk), p[0])
	if len(got.Parts) != 0 || got.Note != "too-large" || got.Subject != "trip" {
		t.Fatalf("pending copy = %+v, want stripped (no parts, note too-large, subject kept)", got)
	}
}

// (f) each budget weighs its own base: a full owner store does not strip a bound MMS.
func TestBoundBudget_OwnerStoreDoesNotWeighOnBound(t *testing.T) {
	useTempInbox(t)
	useTempOwnerInbox(t)
	lowerBoundBudget(t, 64<<10, 1<<20)
	v, dk := vaultWithTelKey(t)
	plantBlob(t, ownerInboxBase, "0123456789abcdef.seal", 128<<10)
	if err := sealItemToInbox("refB", v.TelPub, "", budgetMms()); err != nil {
		t.Fatal(err)
	}
	got := openOnly(t, dk, v, "refB")
	if len(got.Parts) != 1 || got.Note != "" {
		t.Fatalf("bound MMS with an empty bound store = %d parts, note %q; want it whole", len(got.Parts), got.Note)
	}
}
