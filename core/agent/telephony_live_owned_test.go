package main

import "testing"

// NWP-20261005-12: TEL-LIVE-OWNED answers the sign-in owner verdict for whoever is signed in, so the gate can re-run
// it after a bind or unbind. It must match on the live session's profileRefV2 exactly as TEL-OWNED-ICCIDS does.
func TestTelLiveOwnedReply(t *testing.T) {
	useTempBindings(t)
	dest := t.TempDir()
	if got := telLiveOwnedReply(dest); got != "NONE\n" {
		t.Fatalf("no live session: got %q, want NONE", got)
	}
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if got := telLiveOwnedReply(dest); got != "OK 10\n" {
		t.Fatalf("a live session that owns nothing: got %q, want the bare header", got)
	}
	me := profileRefV2("alice", "pw")
	if err := writeBindings([]simBinding{
		{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open", Owners: []bindingOwner{{"refOther", "pub"}, {me, "pub"}}},
		{SubID: 2, ICCID: iccidY, Label: "L", Visibility: "open", Owners: []bindingOwner{{"refOther", "pub"}}},
	}, nil); err != nil {
		t.Fatal(err)
	}
	if got, want := telLiveOwnedReply(dest), "OK 10\n"+iccidX+"\n"; got != want {
		t.Fatalf("bound mid-session: got %q, want %q -- only the SIM this profile owns", got, want)
	}
	// The match is on the credential, as at sign-in: the same name with another passphrase owns nothing.
	if err := markRoamSession(dest, "alice", "other", "11", ""); err != nil {
		t.Fatal(err)
	}
	if got := telLiveOwnedReply(dest); got != "OK 11\n" {
		t.Fatalf("a different credential: got %q, want the bare header", got)
	}
}
