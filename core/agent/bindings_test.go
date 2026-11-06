package main

import (
	"path/filepath"
	"testing"
)

func useTempBindings(t *testing.T) {
	t.Helper()
	old := bindingsPath
	bindingsPath = filepath.Join(t.TempDir(), "bindings.conf")
	t.Cleanup(func() { bindingsPath = old })
}

func ownerRefs(b simBinding) map[string]string {
	m := map[string]string{}
	for _, o := range b.Owners {
		m[o.ProfileRef] = o.TelPub
	}
	return m
}

func TestBindingsRoundTrip(t *testing.T) {
	in := []simBinding{
		{SubID: 1, ICCID: "8901000000000001", Label: "Alex's line", Visibility: "open",
			Owners: []bindingOwner{{"aa11", "UHViMQ=="}, {"bb22", "UHViMg=="}}},
		{SubID: 2, ICCID: "8901000000000002", Label: "Work", Visibility: "private",
			Owners: []bindingOwner{{"cc33", "UHViMw=="}}},
	}
	got := parseBindings(serializeBindings(in))
	if len(got) != 2 {
		t.Fatalf("round-trip lost SIMs: %d", len(got))
	}
	if got[0].SubID != 1 || got[0].ICCID != "8901000000000001" || got[0].Label != "Alex's line" || got[0].Visibility != "open" {
		t.Fatalf("SIM0 fields wrong: %+v", got[0])
	}
	if len(got[0].Owners) != 2 || ownerRefs(got[0])["aa11"] != "UHViMQ==" || ownerRefs(got[0])["bb22"] != "UHViMg==" {
		t.Fatalf("SIM0 owners wrong: %+v", got[0].Owners)
	}
	if got[1].Visibility != "private" || len(got[1].Owners) != 1 {
		t.Fatalf("SIM1 wrong: %+v", got[1])
	}
}

func TestSetBindingOwnerManyToMany(t *testing.T) {
	useTempBindings(t)
	// Bind profile A to the SIM.
	if err := setBindingOwner(3, "89ICCID", "Family", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	// Bind profile B to the SAME SIM -> many-to-many.
	if err := setBindingOwner(3, "89ICCID", "Family", "notify", "refB", "pubB"); err != nil {
		t.Fatal(err)
	}
	bs := readBindings()
	if len(bs) != 1 {
		t.Fatalf("expected 1 SIM, got %d", len(bs))
	}
	if len(bs[0].Owners) != 2 {
		t.Fatalf("expected 2 owners (many-to-many), got %d", len(bs[0].Owners))
	}
	// label + visibility take the latest write.
	if bs[0].Visibility != "notify" || bs[0].Label != "Family" {
		t.Fatalf("SIM attrs not updated: %+v", bs[0])
	}
	// Re-bind A with a rotated pubkey -> still 2 owners, A's pub updated.
	if err := setBindingOwner(3, "89ICCID", "Family", "notify", "refA", "pubA2"); err != nil {
		t.Fatal(err)
	}
	bs = readBindings()
	if len(bs[0].Owners) != 2 || ownerRefs(bs[0])["refA"] != "pubA2" {
		t.Fatalf("re-bind should update A's pub in place, keep 2 owners: %+v", bs[0].Owners)
	}
}

func TestRemoveBindingOwner(t *testing.T) {
	useTempBindings(t)
	setBindingOwner(4, "89X", "Shared", "open", "refA", "pubA")
	setBindingOwner(4, "89X", "Shared", "open", "refB", "pubB")
	// Remove one owner -> the other remains, SIM stays.
	if n, err := removeBindingOwner("89X", "refA"); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	bs := readBindings()
	if len(bs) != 1 || len(bs[0].Owners) != 1 || bs[0].Owners[0].ProfileRef != "refB" {
		t.Fatalf("after removing A, expected only B: %+v", bs)
	}
	// Remove the last owner -> SIM dropped.
	if n, err := removeBindingOwner("89X", "refB"); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	if len(readBindings()) != 0 {
		t.Fatal("removing the last owner should drop the SIM")
	}
	// Whole-SIM removal (empty profileRef).
	setBindingOwner(5, "89Y", "L", "open", "r1", "p1")
	setBindingOwner(5, "89Y", "L", "open", "r2", "p2")
	if n, err := removeBindingOwner("89Y", ""); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	if len(readBindings()) != 0 {
		t.Fatal("empty profileRef should drop the whole SIM")
	}
}

func TestBindingForSubID(t *testing.T) {
	useTempBindings(t)
	setBindingOwner(7, "89STABLE", "L", "open", "r", "p")
	// No ICCID on the arrival -> the sub_id fallback.
	if b, ok := bindingForSubID(7, ""); !ok || b.ICCID != "89STABLE" {
		t.Fatalf("sub_id lookup failed: %+v %v", b, ok)
	}
	// The ICCID is the key whatever the sub_id, which renumbers across reboots.
	if b, ok := bindingForSubID(99, "89STABLE"); !ok || b.ICCID != "89STABLE" {
		t.Fatalf("ICCID lookup failed: %+v %v", b, ok)
	}
	// Neither matches.
	if _, ok := bindingForSubID(99, "89NOPE"); ok {
		t.Fatal("unknown SIM must not match")
	}
}

func TestLabelSurvivesSpecialChars(t *testing.T) {
	useTempBindings(t)
	label := "A|B:C,D — café ☎"
	if err := setBindingOwner(1, "89L", label, "open", "r", "p"); err != nil {
		t.Fatal(err)
	}
	bs := readBindings()
	if len(bs) != 1 || bs[0].Label != label {
		t.Fatalf("label with delimiter/unicode chars corrupted: %q", bs[0].Label)
	}
}

func TestVisibilityNormalize(t *testing.T) {
	for in, want := range map[string]string{"OPEN": "open", "Notify": "notify", "private": "private", "garbage": "open", "": "open"} {
		if got := normVisibility(in); got != want {
			t.Fatalf("normVisibility(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestParseSkipsGarbage: only a line that reads back byte for byte is a binding (NWP-20260930-04). A half-parsed line
// -- here a label that is not base64 -- is damaged, not kept with its bad field defaulted as it used to be.
func TestParseSkipsGarbage(t *testing.T) {
	s := "v1\n# comment\nnot-enough-fields\n1|89|bad_b64_@@|open|r:p\n2|90|TA==|open|r:p\n"
	bs := parseBindings(s)
	if len(bs) != 1 || bs[0].ICCID != "90" || len(bs[0].Owners) != 1 {
		t.Fatalf("expected the 1 good line from mixed input, got %+v", bs)
	}
	if st := parseBindingsText(s); len(st.damaged) != 3 || !st.flawed {
		t.Fatalf("expected the 3 other lines damaged, got %+v", st)
	}
}
