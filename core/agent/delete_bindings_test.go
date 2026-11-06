package main

import (
	"os"
	"testing"
)

// NWP-20260903-21 (#136 A3): a DELIBERATE profile delete must drop that profile from every SIM binding.
//
// handleDelete purged every store scope, removed .roamsession and queued the reap -- but never touched
// bindings.conf, a file the amnesia sweep deliberately spares. So the strongest teardown a user can
// invoke left the departed profileRefV2 and its telephony pubkey bound to the SIM across every reboot:
// TEL-OWNER kept answering YES for an identity that no longer exists, and inbound traffic kept being sealed
// to a pubkey nobody can open.
//
// removeBindingOwner is keyed by ICCID because the owner-mode UI unbinds ONE SIM. A delete is different in
// kind: the profile is gone from the device, so it must leave EVERY SIM, which is what these pin.

func TestDeleteDropsTheProfileFromEverySIM(t *testing.T) {
	useTempBindings(t)
	// Two SIMs, both owned by A; the second is SHARED with B.
	if err := setBindingOwner(1, "8901000000000001", "line one", "open", "aaaa1111", "pubA"); err != nil {
		t.Fatal(err)
	}
	if err := setBindingOwner(2, "8901000000000002", "line two", "open", "aaaa1111", "pubA"); err != nil {
		t.Fatal(err)
	}
	if err := setBindingOwner(2, "8901000000000002", "line two", "open", "bbbb2222", "pubB"); err != nil {
		t.Fatal(err)
	}

	n, err := removeBindingOwnerEverywhere("aaaa1111")
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("A owned TWO SIMs; per-ICCID thinking is exactly the bug: changed %d", n)
	}

	// SIM 1 had only A -> the whole SIM goes (a binding with nobody to deliver to is meaningless).
	if _, ok := bindingForSubID(1, "8901000000000001"); ok {
		t.Error("a SIM whose only owner was deleted must not still resolve an owner")
	}
	// SIM 2 was SHARED -> it survives, carrying B alone. Deleting one identity must not unbind another.
	b2, ok := bindingForSubID(2, "8901000000000002")
	if !ok {
		t.Fatal("a SHARED SIM must survive the deletion of one of its owners")
	}
	owners := ownerRefs(b2)
	if _, still := owners["aaaa1111"]; still {
		t.Error("the deleted profile is STILL bound to the shared SIM")
	}
	if owners["bbbb2222"] != "pubB" {
		t.Errorf("the surviving owner was damaged: %v", owners)
	}
}

// The guard that keeps a no-op delete from MINTING persistent state: writeBindings does MkdirAll + create,
// so an unconditional write would leave an empty bindings.conf on any device that never had one -- new
// persistent user-0 state created by a delete, which is the opposite of the point.
func TestNoMatchWritesNothingAtAll(t *testing.T) {
	useTempBindings(t)
	n, err := removeBindingOwnerEverywhere("aaaa1111")
	if err != nil || n != 0 {
		t.Fatalf("no bindings file: want (0, nil), got (%d, %v)", n, err)
	}
	if _, err := os.Stat(bindingsPath); !os.IsNotExist(err) {
		t.Fatal("a delete with nothing to unbind MINTED a bindings.conf")
	}

	// Same again with a real file present but no matching owner: the file must be left exactly as it was.
	if err := setBindingOwner(1, "8901000000000001", "line one", "open", "bbbb2222", "pubB"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := removeBindingOwnerEverywhere("aaaa1111"); err != nil || n != 0 {
		t.Fatalf("unrelated profile: want (0, nil), got (%d, %v)", n, err)
	}
	after, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatalf("a non-matching delete rewrote bindings.conf:%s%q%s->%s%q", "\n", before, "\n", "\n", after)
	}
}

// The empty ref must never be treated as "match everything" -- that would unbind every SIM on the device.
func TestEmptyRefUnbindsNothing(t *testing.T) {
	useTempBindings(t)
	if err := setBindingOwner(1, "8901000000000001", "line one", "open", "aaaa1111", "pubA"); err != nil {
		t.Fatal(err)
	}
	if n, err := removeBindingOwnerEverywhere(""); err != nil || n != 0 {
		t.Fatalf("empty ref: want (0, nil), got (%d, %v)", n, err)
	}
	if _, ok := bindingForSubID(1, "8901000000000001"); !ok {
		t.Fatal("an empty profileRef wiped a live binding")
	}
}
