package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261129-35 (h59 #13, docs/product-decisions.md 2026-11-05): the device owner's caller's-number opt-in reaches
// the unassigned line's own gate notice. sealUnboundToOwner's OWNER and NONE replies carry "number" when it is on, the
// same token on both, so the notice never tells a kept arrival from an unkept one. FULL carries no token.

// unboundNumberStates are the opt-in's three states: the flag file's content (absent when not written) and the token
// each reply must carry.
var unboundNumberStates = []struct {
	name, content string
	write         bool
	tail          string
}{
	{"on", "1\n", true, " number\n"},
	{"off", "0\n", true, "\n"},
	{"no file", "", false, "\n"},
}

// setUnboundNumberState puts the opt-in in one state, on a flag path the test owns.
func setUnboundNumberState(t *testing.T, path, content string, write bool) {
	t.Helper()
	if !write {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		return
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func unboundNumberSMS() arrivalReq {
	return arrivalReq{verb: "SEAL-TEL", it: telItem{Kind: "sms", SubID: 2, From: "+15551239999", When: 1, Body: "hi"}}
}

func TestUnboundNumberOwnerReply(t *testing.T) {
	mintOwnerKey(t)
	path := useTempNoticeNumber(t)
	for _, st := range unboundNumberStates {
		setUnboundNumberState(t, path, st.content, st.write)
		sms := unboundNumberSMS()
		mms := arrivalReq{verb: "SEAL-MMS", it: telItem{Kind: "mms", SubID: 2, From: "+15551239999", When: 2, Subject: "s"}}
		for _, a := range []*arrivalReq{&sms, &mms} {
			want := "OWNER" + st.tail
			if reply, verdict := sealUnboundToOwner(a); reply != want || verdict != telVerdictOwner {
				t.Errorf("%s, %s: reply %q / %q, want %q / telVerdictOwner", st.name, a.verb, reply, verdict, want)
			}
		}
	}
}

func TestUnboundNumberNoneReply(t *testing.T) {
	useTempOwnerKey(t) // no key minted: the arrival is an accepted loss
	useTempOwnerInbox(t)
	path := useTempNoticeNumber(t)
	for _, st := range unboundNumberStates {
		setUnboundNumberState(t, path, st.content, st.write)
		a := unboundNumberSMS()
		want := "NONE" + st.tail
		if reply, verdict := sealUnboundToOwner(&a); reply != want || verdict != telVerdictUnbound {
			t.Errorf("%s: reply %q / %q, want %q / telVerdictUnbound", st.name, reply, verdict, want)
		}
	}
}

// FULL raises the loss notice, which shows no number: the token stays off it whatever the opt-in says.
func TestUnboundNumberFullUnchanged(t *testing.T) {
	mintOwnerKey(t)
	path := useTempNoticeNumber(t)
	oldS, oldH := telOwnerBudgetSoft, telOwnerBudgetHard
	telOwnerBudgetSoft, telOwnerBudgetHard = 1<<10, 2<<10
	t.Cleanup(func() { telOwnerBudgetSoft, telOwnerBudgetHard = oldS, oldH })
	for _, st := range unboundNumberStates {
		setUnboundNumberState(t, path, st.content, st.write)
		a := arrivalReq{verb: "SEAL-TEL", it: telItem{Kind: "sms", SubID: 2, From: "+1", When: 1, Body: strings.Repeat("x", 4096)}}
		if reply, verdict := sealUnboundToOwner(&a); reply != "FULL\n" || verdict != telVerdictOwnerFull {
			t.Errorf("%s: reply %q / %q, want FULL / telVerdictOwnerFull", st.name, reply, verdict)
		}
	}
}

// The daemon's replies are the lines the fixture holds the chooser's TelArrival.parse to.
func TestUnboundNumberRepliesMatchTheWireFixture(t *testing.T) {
	_, reps := telWireFixture(t)
	lines := map[string]string{}
	for _, r := range reps {
		lines[r.name] = r.line
	}
	path := useTempNoticeNumber(t)
	seal := func(t *testing.T, row, content string) {
		t.Helper()
		line, ok := lines[row]
		if !ok {
			t.Fatalf("the wire fixture has no REPLY row %q", row)
		}
		setUnboundNumberState(t, path, content, true)
		a := unboundNumberSMS()
		if reply, _ := sealUnboundToOwner(&a); reply != line+"\n" {
			t.Errorf("row %s: the daemon answers %q, the fixture holds %q", row, reply, line)
		}
	}
	t.Run("owner", func(t *testing.T) {
		mintOwnerKey(t)
		seal(t, "owner", "0\n")
		seal(t, "owner-number", "1\n")
	})
	t.Run("none", func(t *testing.T) {
		useTempOwnerKey(t)
		useTempOwnerInbox(t)
		seal(t, "none", "0\n")
		seal(t, "none-number", "1\n")
	})
}

// A retry of one arrival repeats what was answered, even after the owner has changed the opt-in, and seals nothing new.
func TestUnboundNumberReplayRepeatsTheAnswer(t *testing.T) {
	useTempInbox(t)
	useArrivalState(t)
	useTempBindings(t) // no bindings -> the SIM is unbound
	mintOwnerKey(t)
	path := useTempNoticeNumber(t)
	setUnboundNumberState(t, path, "1\n", true)

	req := v2Tel(arrivalID(9135), "sms", 2, "89990000000000000135", "+15551239135", late, "body")
	if got := driveLogin(t, t.TempDir(), req); got != "OWNER number" {
		t.Fatalf("first answer = %q, want OWNER number", got)
	}
	setUnboundNumberState(t, path, "", false)
	if got := driveLogin(t, t.TempDir(), req); got != "OWNER number" {
		t.Fatalf("retry after the opt-in went off = %q, want OWNER number (replayed)", got)
	}
	if n := len(listOwnerSealed()); n != 1 {
		t.Fatalf("the retry changed the store: %d items, want 1", n)
	}
}
