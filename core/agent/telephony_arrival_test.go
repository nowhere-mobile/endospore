package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// driveSealMms runs handleSealMms over an in-memory pipe and returns its single reply line (#150). dest is
// the state dir it reads .roamsession from (empty/temp = no live session -> the seal-for-next-login path).
func driveSealMms(t *testing.T, dest, iccid string, it telItem) string {
	t.Helper()
	c1, c2 := net.Pipe()
	go func() { handleSealMms(c1, dest, iccid, it); c1.Close() }()
	line, _ := bufio.NewReader(c2).ReadString('\n')
	c2.Close()
	return line
}

// driveSealTel runs handleSealTel over an in-memory pipe and returns its single reply line. dest is the
// state dir it reads .roamsession from (empty/temp = no live session -> the seal-for-next-login path).
func driveSealTel(t *testing.T, dest string, f []string) string {
	t.Helper()
	c1, c2 := net.Pipe()
	go func() { handleSealTel(c1, dest, f); c1.Close() }()
	line, _ := bufio.NewReader(c2).ReadString('\n')
	c2.Close()
	return line
}

// TestHandleSealTelSealsToAllOwners: a shared SIM bound to two profiles seals a copy to EACH, and each
// owner opens exactly its own copy (full body) with its own key -- the arrival half of the #135 data path.
func TestHandleSealTelSealsToAllOwners(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	vA, dkA := vaultWithTelKey(t)
	vB, dkB := vaultWithTelKey(t)
	const refA, refB = "aaaa", "bbbb"
	const iccid = "89440000000000000066"
	if err := setBindingOwner(2, iccid, "Personal", "open", refA, vA.TelPub); err != nil {
		t.Fatal(err)
	}
	if err := setBindingOwner(2, iccid, "Personal", "open", refB, vB.TelPub); err != nil {
		t.Fatal(err)
	}

	reply := driveSealTel(t, t.TempDir(), []string{"sms", "2", iccid, "+15551234567", "1720000000000",
		base64.StdEncoding.EncodeToString([]byte("hello world")), "0", "0"})
	fields := strings.Fields(strings.TrimSpace(reply))
	if len(fields) != 4 || fields[0] != "OK" || fields[1] != "open" || fields[3] != "2" {
		t.Fatalf("reply = %q, want 'OK open <label_b64> 2'", reply)
	}
	if lb, _ := base64.StdEncoding.DecodeString(fields[2]); string(lb) != "Personal" {
		t.Fatalf("label = %q, want Personal", lb)
	}

	gotA := readTelInboxItems(vA, dkA, refA)
	gotB := readTelInboxItems(vB, dkB, refB)
	if len(gotA) != 1 || gotA[0].Body != "hello world" || gotA[0].From != "+15551234567" || gotA[0].Kind != "sms" || gotA[0].SubID != 2 {
		t.Fatalf("owner A ingest = %+v", gotA)
	}
	if len(gotB) != 1 || gotB[0].Body != "hello world" {
		t.Fatalf("owner B ingest = %+v", gotB)
	}
	// A must NOT be able to open B's copy (distinct sealed boxes per pubkey).
	if extra := readTelInboxItems(vA, dkA, refB); len(extra) != 0 {
		t.Fatalf("owner A opened owner B's buffer: %+v", extra)
	}
}

// TestHandleSealTelCallVisibility: a call on a "private" SIM still seals the full call metadata to the
// owner (dial governs only the gate notice), and the reply carries the dial for the caller.
func TestHandleSealTelCallVisibility(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	v, dk := vaultWithTelKey(t)
	const ref = "cccc"
	const iccid = "89000000000000000001"
	if err := setBindingOwner(1, iccid, "Fi", "private", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	reply := driveSealTel(t, t.TempDir(), []string{"call", "1", iccid, "+15559998888", "1720000009999", "", "3", "42"})
	fields := strings.Fields(strings.TrimSpace(reply))
	if len(fields) != 4 || fields[0] != "OK" || fields[1] != "private" || fields[3] != "1" {
		t.Fatalf("reply = %q, want 'OK private <label> 1'", reply)
	}
	got := readTelInboxItems(v, dk, ref)
	if len(got) != 1 || got[0].Kind != "call" || got[0].CallType != 3 || got[0].DurSec != 42 || got[0].From != "+15559998888" {
		t.Fatalf("call ingest = %+v", got)
	}
}

// TestHandleSealTelUnboundIsNone pins the INTERIM reply. Decided is a device-owner inbox (product-decisions.md
// 2026-09-01 and 2026-09-24; backlog "inbound is DROPPED, not delivered to the device owner"); when it lands
// this test flips to asserting the owner seal.
func TestHandleSealTelUnboundIsNone(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	reply := driveSealTel(t, t.TempDir(), []string{"sms", "9", "9999", "+1", "1",
		base64.StdEncoding.EncodeToString([]byte("x")), "0", "0"})
	if strings.TrimSpace(reply) != "NONE" {
		t.Fatalf("unbound SIM reply = %q, want NONE", reply)
	}
}

func TestHandleSealTelBadKind(t *testing.T) {
	reply := driveSealTel(t, t.TempDir(), []string{"video", "1", "1", "+1", "1", "", "0", "0"})
	if !strings.HasPrefix(strings.TrimSpace(reply), "ERR") {
		t.Fatalf("bad kind reply = %q, want ERR", reply)
	}
}

// TestHandleSealTelLiveDelivery (#149): when a bound owner is the session logged in RIGHT NOW (its creds
// match .roamsession), the item is staged plaintext to that session's live ingest file and the reply
// carries "LIVE <uid>" -- not left as an unstaged sealed blob (which would double-deliver at the owner's next
// login): its sealed copy is only pending until the session acknowledges it (NWP-20261006-05).
func TestHandleSealTelLiveDelivery(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	dir := t.TempDir()
	oldBase := telIngestBase
	telIngestBase = dir // appendTelIngest writes telingest.<uid>.<simTag> here
	t.Cleanup(func() { telIngestBase = oldBase })

	name, pass := "alice", "correct horse battery staple"
	ref := profileRefV2(name, pass)
	v, dk := vaultWithTelKey(t) // TelPub for the binding; dk to open the pending copy
	const iccid = "89440000000000000066"
	if err := setBindingOwner(2, iccid, "Personal", "open", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	// The live session: name\npass\nuid\nseSecret. uid 11 is the logged-in roamed user.
	if err := os.WriteFile(filepath.Join(dir, ".roamsession"), []byte(name+"\n"+pass+"\n11\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	reply := driveSealTel(t, dir, []string{"sms", "2", iccid, "+15551234567", "1720000000000",
		base64.StdEncoding.EncodeToString([]byte("2FA 123456")), "0", "0"})
	fields := strings.Fields(strings.TrimSpace(reply))
	if len(fields) != 6 || fields[0] != "OK" || fields[3] != "0" || fields[4] != "LIVE" || fields[5] != "11" {
		t.Fatalf("reply = %q, want 'OK open <label> 0 LIVE 11'", reply)
	}
	// The plaintext row is staged to telingest.11 for the live chooser (its sealed copy only pending, below).
	b, err := os.ReadFile(telIngestPath("11", simTag(iccid)))
	if err != nil {
		t.Fatalf("telingest.11 not staged: %v", err)
	}
	row := strings.Fields(strings.TrimSpace(string(b)))
	// NWP-20261130-01: the row carries its SIM's tag in its own seventh slot.
	if len(row) != 7 || row[0] != "sms" || row[1] != "1720000000000" || row[6] != simSlotPrefix+simTag(iccid) {
		t.Fatalf("staged row = %q, want the sms live row with its SIM slot", b)
	}
	from, _ := base64.StdEncoding.DecodeString(row[4])
	body, _ := base64.StdEncoding.DecodeString(row[5])
	if string(from) != "+15551234567" || string(body) != "2FA 123456" {
		t.Fatalf("staged from/body = %q / %q", from, body)
	}
	// Its sealed copy is kept PENDING for user 11 only (NWP-20261006-05), and the session's ack drops it, so a
	// delivered row does not come back at the next login.
	assertLivePendingAcked(t, v, dk, ref, "11", "sms 1720000000000")
}

// assertLivePendingAcked: a live row leaves no unstaged sealed copy, exactly one copy pending for the live uid, and
// none once that session acknowledges the row.
func assertLivePendingAcked(t *testing.T, v *vault, dk []byte, ref, uid, key string) {
	t.Helper()
	if l := listSealed(ref); l != nil {
		t.Fatalf("live item was ALSO sealed to the inbox as an unstaged blob: %v", l)
	}
	p := listPending(ref)
	if len(p) != 1 || pendingUID(p[0]) != uid || len(readTelInboxItems(v, dk, ref)) != 1 {
		t.Fatalf("pending copies = %v, want one openable copy for user %s", p, uid)
	}
	if n := ackPending(uid, []string{key}); n != 1 || listPending(ref) != nil {
		t.Fatalf("the session's ack removed %d and left %v", n, listPending(ref))
	}
}

// TestHandleSealMmsSealsToOwner (#150 P2): a downloaded MMS (subject + text + binary image) seals to the
// SIM's bound owner and opens back with every part intact -- the arrival half of the MMS data path.
func TestHandleSealMmsSealsToOwner(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	v, dk := vaultWithTelKey(t)
	const ref = "mmms1"
	const iccid = "89440000000000000066"
	if err := setBindingOwner(2, iccid, "Personal", "open", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	img := bytes.Repeat([]byte{0xFF, 0xD8, 0xFF, 0x00}, 1000)
	it := telItem{Kind: "mms", SubID: 2, From: "+15551234567", When: 1720000000000, Subject: "pics",
		Parts: []mmsPart{
			{ContentType: "application/smil", Name: "s.xml", Data: []byte("<smil/>")},
			{ContentType: "text/plain", Name: "t.txt", Data: []byte("look at this")},
			{ContentType: "image/jpeg", Name: "p.jpg", Data: img},
		}}
	reply := driveSealMms(t, t.TempDir(), iccid, it)
	fields := strings.Fields(strings.TrimSpace(reply))
	if len(fields) != 4 || fields[0] != "OK" || fields[1] != "open" || fields[3] != "1" {
		t.Fatalf("reply = %q, want 'OK open <label_b64> 1'", reply)
	}
	got := readTelInboxItems(v, dk, ref)
	if len(got) != 1 || got[0].Kind != "mms" || got[0].From != "+15551234567" || got[0].Subject != "pics" || len(got[0].Parts) != 3 {
		t.Fatalf("mms ingest = %+v", got)
	}
	if got[0].Parts[1].ContentType != "text/plain" || string(got[0].Parts[1].Data) != "look at this" {
		t.Fatalf("text part = %+v", got[0].Parts[1])
	}
	if !bytes.Equal(got[0].Parts[2].Data, img) {
		t.Fatal("image part bytes corrupted through the seal")
	}
}

// TestHandleSealMmsLiveDelivery (#150): an MMS to a bound owner who is signed in RIGHT NOW is staged
// plaintext (parts and all) to that session's live ingest as an "mms" JSON row and the reply carries
// "LIVE <uid>" -- its sealed copy only pending until the session acknowledges it (NWP-20261006-05). The MMS
// twin of the SMS live path (#149); without it a logged-in owner's MMS was only sealed "for next login" and lost
// on a reboot-logoff / power-off.
func TestHandleSealMmsLiveDelivery(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	dir := t.TempDir()
	oldBase := telIngestBase
	telIngestBase = dir // appendTelIngest writes telingest.<uid>.<simTag> here
	t.Cleanup(func() { telIngestBase = oldBase })

	name, pass := "alice", "correct horse battery staple"
	ref := profileRefV2(name, pass)
	v, dk := vaultWithTelKey(t) // TelPub for the binding; dk to open the pending copy
	const iccid = "89440000000000000066"
	if err := setBindingOwner(2, iccid, "Personal", "open", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	// The live session: name\npass\nuid\nseSecret. uid 11 is the logged-in roamed user.
	if err := os.WriteFile(filepath.Join(dir, ".roamsession"), []byte(name+"\n"+pass+"\n11\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	img := bytes.Repeat([]byte{0xFF, 0xD8, 0xFF, 0x00}, 1000)
	it := telItem{Kind: "mms", SubID: 2, From: "+15551234567", When: 1720000000000, Subject: "pics",
		Parts: []mmsPart{
			{ContentType: "text/plain", Name: "t.txt", Data: []byte("look at this")},
			{ContentType: "image/jpeg", Name: "p.jpg", Data: img},
		}}
	reply := driveSealMms(t, dir, iccid, it)
	fields := strings.Fields(strings.TrimSpace(reply))
	if len(fields) != 6 || fields[0] != "OK" || fields[3] != "0" || fields[4] != "LIVE" || fields[5] != "11" {
		t.Fatalf("reply = %q, want 'OK open <label> 0 LIVE 11'", reply)
	}
	// The live row is an "mms <when> <telItem_json_b64>" line staged for the live chooser (its sealed copy only pending).
	b, err := os.ReadFile(telIngestPath("11", simTag(iccid)))
	if err != nil {
		t.Fatalf("telingest.11 not staged: %v", err)
	}
	row := strings.Fields(strings.TrimSpace(string(b)))
	// NWP-20261130-01: the row carries its SIM's tag in its own fourth slot.
	if len(row) != 4 || row[0] != "mms" || row[1] != "1720000000000" || row[3] != simSlotPrefix+simTag(iccid) {
		t.Fatalf("staged row = %q, want an mms live row with its SIM slot", b)
	}
	j, err := base64.StdEncoding.DecodeString(row[2])
	if err != nil {
		t.Fatalf("mms row payload not base64: %v", err)
	}
	var staged telItem
	if err := json.Unmarshal(j, &staged); err != nil {
		t.Fatalf("mms row payload not telItem JSON: %v", err)
	}
	if staged.Subject != "pics" || len(staged.Parts) != 2 || !bytes.Equal(staged.Parts[1].Data, img) {
		t.Fatalf("staged mms = %+v (want subject + 2 parts, image intact)", staged)
	}
	assertLivePendingAcked(t, v, dk, ref, "11", "mms 1720000000000")
}

// TestHandleSealMmsOversizeStripped: an over-cap MMS degrades to a content-free notice (media dropped,
// from/subject kept) + the reply carries STRIPPED, rather than failing to seal.
func TestHandleSealMmsOversizeStripped(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	v, dk := vaultWithTelKey(t)
	const ref = "mmms2"
	const iccid = "89440000000000000067"
	if err := setBindingOwner(3, iccid, "Personal", "open", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	it := telItem{Kind: "mms", SubID: 3, From: "+15550001111", When: 42, Subject: "huge",
		Parts: []mmsPart{{ContentType: "image/jpeg", Data: make([]byte, maxTelItemBytes+1)}}}
	reply := driveSealMms(t, t.TempDir(), iccid, it)
	fields := strings.Fields(strings.TrimSpace(reply))
	if len(fields) != 5 || fields[0] != "OK" || fields[3] != "1" || fields[4] != "STRIPPED" {
		t.Fatalf("oversize reply = %q, want 'OK open <label> 1 STRIPPED'", reply)
	}
	got := readTelInboxItems(v, dk, ref)
	if len(got) != 1 || len(got[0].Parts) != 0 || got[0].Subject != "huge" || got[0].From != "+15550001111" || got[0].Note != "too-large" {
		t.Fatalf("stripped mms = %+v (want no parts, subject+from kept, note=too-large)", got)
	}
}

// TestHandleSealMmsUnboundIsNone pins the INTERIM reply -- same note as TestHandleSealTelUnboundIsNone.
func TestHandleSealMmsUnboundIsNone(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	reply := driveSealMms(t, t.TempDir(), "9999", telItem{Kind: "mms", SubID: 9, From: "+1", When: 1})
	if strings.TrimSpace(reply) != "NONE" {
		t.Fatalf("unbound MMS reply = %q, want NONE", reply)
	}
}
