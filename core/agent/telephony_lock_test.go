package main

import (
	"bufio"
	"encoding/base64"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20260927-09: the telephony verbs serialize on telMu, never on sessionMu. Before this slice they waited on
// sessionMu behind every login, logoff CLEAN-STORAGE, delete and materialise, and the chooser gave up first: on
// lynx 2026-09-27 a text to the unbound SIM 19 s after a logoff waited behind a 43.6 s CLEAN-STORAGE and left no
// trace at all.

// telRequests is one well-formed request per telephony verb, each answered without a store or a live session.
func telRequests() map[string]string {
	body := base64.StdEncoding.EncodeToString([]byte("x"))
	return map[string]string{
		"SEAL-TEL":          "SEAL-TEL\nsms\n9\n" + iccidX + "\n+1\n1\n" + body + "\n0\n0\n",
		"SEAL-MMS":          "SEAL-MMS\n9\n" + iccidX + "\n-\n1\n-\n1\n-\n-\n" + body + "\n",
		"GET-TELINGEST":     "GET-TELINGEST\n",
		"ACK-TELINGEST":     "ACK-TELINGEST\n",
		"RESTAGE-TELINGEST": "RESTAGE-TELINGEST\ncall 5 3 0 KzE - 1\n",
	}
}

// telReplies is what each of telRequests gets with no binding and a pipe peer (peerUID -1).
var telReplies = map[string]string{
	"SEAL-TEL": "NONE", "SEAL-MMS": "NONE", "GET-TELINGEST": "NONE", "ACK-TELINGEST": "OK", "RESTAGE-TELINGEST": "ERR",
}

func telFixture(t *testing.T) {
	t.Helper()
	useTempInbox(t)
	useTempBindings(t)
	useTempIngest(t)
	useArrivalState(t)
	asGate(t) // SEAL-TEL and SEAL-MMS answer only the user-0 gate (NWP-20260930-04/-05); the other telephony verbs read peerUID, not this seam
}

// driveLoginAsync runs driveLogin in the background and returns its reply channel.
func driveLoginAsync(t *testing.T, dest, req string) chan string {
	t.Helper()
	c := make(chan string, 1)
	go func() { c <- driveLogin(t, dest, req) }()
	return c
}

// TestTelVerbsNeverWaitForSessionMu: every telephony verb answers while sessionMu is held -- the exact state of the
// lynx loss, where a CLEAN-STORAGE held it for 43.6 s.
func TestTelVerbsNeverWaitForSessionMu(t *testing.T) {
	telFixture(t)
	sessionMu.Lock()
	held := true
	defer func() {
		if held {
			sessionMu.Unlock()
		}
	}()
	for verb, req := range telRequests() {
		if !telCmd(verb) {
			t.Fatalf("%s is not routed to handleTelCmd", verb)
		}
		select {
		case got := <-driveLoginAsync(t, t.TempDir(), req):
			if got != telReplies[verb] {
				t.Fatalf("%s replied %q while sessionMu was held, want %q", verb, got, telReplies[verb])
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%s waited on sessionMu: no reply in 3 s while a session op held it", verb)
		}
	}
	sessionMu.Unlock()
	held = false
}

// TestTelVerbsSerializeOnTelMu: while telMu is held no telephony verb answers, and each answers once it is free.
// Together with the test above: they serialize on telMu, and on telMu alone.
func TestTelVerbsSerializeOnTelMu(t *testing.T) {
	telFixture(t)
	for verb, req := range telRequests() {
		telMu.Lock()
		reply := driveLoginAsync(t, t.TempDir(), req)
		select {
		case got := <-reply:
			telMu.Unlock()
			t.Fatalf("%s answered %q while telMu was held", verb, got)
		case <-time.After(300 * time.Millisecond):
		}
		telMu.Unlock()
		select {
		case got := <-reply:
			if got != telReplies[verb] {
				t.Fatalf("%s replied %q, want %q", verb, got, telReplies[verb])
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%s did not answer after telMu was released", verb)
		}
	}
}

// TestTelRequestIsReadBeforeTheLock: the whole request -- here an MMS far over the 4 KiB a reader buffers -- is
// consumed while telMu is still held. The old handler read its fields only after the lock, so a wait past the 60 s
// connection deadline sealed whatever had been buffered: an MMS without its picture.
func TestTelRequestIsReadBeforeTheLock(t *testing.T) {
	telFixture(t)
	big := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("p", 64<<10)))
	req := "SEAL-MMS\n9\n" + iccidX + "\n-\n1\n-\n1\n-\n-\n" + big + "\n"
	cli, srv := net.Pipe()
	defer cli.Close()
	telMu.Lock()
	locked := true
	defer func() {
		if locked {
			telMu.Unlock()
		}
	}()
	go handleLogin(srv, t.TempDir())
	wrote := make(chan error, 1)
	go func() { _, err := cli.Write([]byte(req)); wrote <- err }() // net.Pipe: returns once every byte is read
	select {
	case err := <-wrote:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the request was not read while telMu was held: a wait could cut it short")
	}
	telMu.Unlock()
	locked = false
	line, _ := bufio.NewReader(cli).ReadString('\n')
	if strings.TrimSpace(line) != "NONE" {
		t.Fatalf("reply %q, want NONE", line)
	}
}

// TestTelReadersRefuseAShortOrBadRequest: a field cut off before its newline, or an MMS part that is not base64, is
// refused rather than sealed. The old readers discarded both errors: a truncated field was sealed as it stood, and a
// bad part as an empty one. (A SEAL-TEL body that is not base64 is kept: TestSealTelKeepsADesyncedRequest.)
func TestTelReadersRefuseAShortOrBadRequest(t *testing.T) {
	rd := func(s string) *bufio.Reader { return bufio.NewReader(strings.NewReader(s)) }
	body := base64.StdEncoding.EncodeToString([]byte("hello"))
	good := "sms\n2\n" + iccidX + "\n+1\n7\n" + body + "\n0\n0\n"
	if f, a, err := readSealTel(rd(good)); err != nil || a != nil || len(f) != 8 || f[5] != body {
		t.Fatalf("a good SEAL-TEL: %q, %v", f, err)
	}
	for what, req := range map[string]string{
		"a field cut off before its newline": strings.TrimSuffix(good, "\n"),
		"a missing field":                    "sms\n2\n" + iccidX + "\n+1\n7\n" + body + "\n0\n",
	} {
		if _, _, err := readSealTel(rd(req)); err == nil {
			t.Fatalf("SEAL-TEL with %s was accepted", what)
		}
	}
	part := base64.StdEncoding.EncodeToString([]byte("picture"))
	mms := "2\n" + iccidX + "\n-\n7\n-\n1\n-\n-\n" + part + "\n"
	iccid, it, a, err := readSealMms(rd(mms))
	if err != nil || a != nil || iccid != iccidX || len(it.Parts) != 1 || string(it.Parts[0].Data) != "picture" || it.Kind != "mms" || it.When != 7 {
		t.Fatalf("a good SEAL-MMS: %q %+v %v", iccid, it, err)
	}
	for what, req := range map[string]string{
		"a part cut off before its newline": strings.TrimSuffix(mms, "\n"),
		"a missing part":                    "2\n" + iccidX + "\n-\n7\n-\n2\n-\n-\n" + part + "\n",
		"part data that is not base64":      "2\n" + iccidX + "\n-\n7\n-\n1\n-\n-\nnot base64!\n",
		"a bad part count":                  "2\n" + iccidX + "\n-\n7\n-\nmany\n",
	} {
		if _, _, _, err := readSealMms(rd(req)); err == nil {
			t.Fatalf("SEAL-MMS with %s was accepted", what)
		}
	}
}

// TestSealTelKeepsADesyncedRequest: the shipped chooser sends a text's <from> raw, so a sender ID with a newline
// shifts the later fields and <body> is no longer base64. The arrival must still get its reply -- NONE for an unbound
// SIM, so the chooser posts the unassigned-SIM notice; OK for a bound one, sealed -- never ERR, which leaves no trace.
func TestSealTelKeepsADesyncedRequest(t *testing.T) {
	telFixture(t)
	req := func(iccid string) string { // nine lines where eight are expected: <from> is "+1\nx"
		return "SEAL-TEL\nsms\n2\n" + iccid + "\n+1\nx\n1720000000000\n" + base64.StdEncoding.EncodeToString([]byte("hi")) + "\n0\n0\n"
	}
	if got := driveLogin(t, t.TempDir(), req(iccidY)); got != "NONE" {
		t.Fatalf("an unbound SIM's desynced request replied %q, want NONE", got)
	}
	v, _ := vaultWithTelKey(t)
	if err := setBindingOwner(2, iccidX, "L", "open", "refD", v.TelPub); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), req(iccidX)); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("a bound SIM's desynced request replied %q, want OK", got)
	}
	if l := listSealed("refD"); len(l) != 1 {
		t.Fatalf("the bound SIM's desynced arrival was not sealed: %v", l)
	}
}

// liveFixture binds iccid to a profile and signs that profile in as uid 11, as TestHandleSealTelLiveDelivery does.
func liveFixture(t *testing.T, dest, iccid string) {
	t.Helper()
	name, pass := "alice", "correct horse battery staple"
	v, _ := vaultWithTelKey(t)
	if err := setBindingOwner(2, iccid, "Personal", "open", profileRefV2(name, pass), v.TelPub); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".roamsession"), []byte(name+"\n"+pass+"\n11\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// TestArrivalDuringBringUpIsQueuedNotKicked: while a ROAM-IN or RESUME handler is bringing uid 11 up, an arrival for
// it is appended to its mailbox but the reply carries no LIVE; the login's own delivery run claims the row. Once the
// handler ends, arrivals go live.
func TestArrivalDuringBringUpIsQueuedNotKicked(t *testing.T) {
	telFixture(t)
	dest := t.TempDir()
	liveFixture(t, dest, iccidX)
	sms := []string{"sms", "2", iccidX, "+15551234567", "1720000000000", base64.StdEncoding.EncodeToString([]byte("hi")), "0", "0"}
	mms := telItem{Kind: "mms", SubID: 2, From: "+15551234567", When: 1720000000001,
		Parts: []mmsPart{{ContentType: "text/plain", Name: "t.txt", Data: []byte("x")}}}

	if err := beginTelStaging("11", false); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { endTelStaging("11") })
	for what, reply := range map[string]string{
		"SMS": driveSealTel(t, dest, sms),
		"MMS": driveSealMms(t, dest, iccidX, mms),
	} {
		if f := strings.Fields(reply); len(f) != 4 || f[0] != "OK" || f[3] != "0" {
			t.Fatalf("%s during the bring-up replied %q, want 'OK <vis> <label> 0' with no LIVE", what, reply)
		}
	}
	b, err := os.ReadFile(telIngestPath("11", simTag(iccidX)))
	if err != nil || strings.Count(string(b), "\n") != 2 {
		t.Fatalf("mailbox = %q, %v; want the SMS and the MMS queued for the session", b, err)
	}
	if l := listSealed(profileRefV2("alice", "correct horse battery staple")); l != nil {
		t.Fatalf("a queued arrival was also sealed: %v", l)
	}

	endTelStaging("11")
	if f := strings.Fields(driveSealTel(t, dest, sms)); len(f) != 6 || f[4] != "LIVE" || f[5] != "11" {
		t.Fatalf("after the bring-up the reply is %q, want LIVE 11", f)
	}
}

// TestEndTelStagingKeepsANewerBringUp: a bring-up that ends does not end one that began after it.
func TestEndTelStagingKeepsANewerBringUp(t *testing.T) {
	telFixture(t)
	if err := beginTelStaging("11", false); err != nil {
		t.Fatal(err)
	}
	if err := beginTelStaging("12", false); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { endTelStaging("12") })
	endTelStaging("11")
	var got string
	underTelMu(func() { got = telStagingUID })
	if got != "12" {
		t.Fatalf("telStagingUID = %q after the older bring-up ended, want 12", got)
	}
}

// TestStagingKeepsARowQueuedDuringBringUp is the regression this slice had to avoid. A roam-in used to remove the
// uid's mailboxes at staging; with arrivals no longer waiting behind the login, one can now queue a row between the
// marker and the staging, and that removal would destroy it. The stale leftovers go at the bring-up instead.
func TestStagingKeepsARowQueuedDuringBringUp(t *testing.T) {
	telFixture(t)
	dest := t.TempDir()
	tz := simTag("89440000000000000033")
	if err := appendTelIngest("11", tz, testSMS); err != nil { // a stale leftover of a recycled uid
		t.Fatal(err)
	}
	if err := beginTelStaging("11", true); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { endTelStaging("11") })
	liveFixture(t, dest, iccidX) // the marker now names the session
	sms := []string{"sms", "2", iccidX, "+15551234567", "1720000000000", base64.StdEncoding.EncodeToString([]byte("hi")), "0", "0"}
	if reply := driveSealTel(t, dest, sms); !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("SEAL-TEL reply %q", reply)
	}
	v, dk := vaultWithTelKey(t)
	const ref = "backlogref"
	if err := sealItemToInbox(ref, v.TelPub, simTag(iccidY), telItem{Kind: "sms", From: "+2", When: 5, Body: "backlog"}); err != nil {
		t.Fatal(err)
	}
	if n, err := stageTelInboxLocked(v, dk, ref, "11"); n != 1 || err != nil {
		t.Fatalf("stage = %d, %v; want 1, nil", n, err)
	}
	b, err := claimTelIngest("11")
	if err != nil {
		t.Fatal(err)
	}
	rows := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	queued, backlog := 0, 0
	for _, r := range rows {
		if strings.HasPrefix(r, "sms 1720000000000 ") {
			queued++
		}
		if strings.HasPrefix(r, "sms 5 ") {
			backlog++
		}
	}
	if len(rows) != 2 || queued != 1 || backlog != 1 { // per-SIM files are served in tag order, so not by position
		t.Fatalf("claimed %q; want the queued arrival and the staged backlog, and not the stale leftover", rows)
	}
}

// TestResumeBringUpKeepsTheMailbox: a resume's mailbox is its own session's (a re-staged row, an arrival from before
// the lock), so its bring-up removes nothing.
func TestResumeBringUpKeepsTheMailbox(t *testing.T) {
	telFixture(t)
	if err := appendTelIngest("12", simTag(iccidX), testSMS); err != nil {
		t.Fatal(err)
	}
	if err := beginTelStaging("12", false); err != nil {
		t.Fatal(err)
	}
	endTelStaging("12")
	mustExist(t, "the resuming session's mailbox", telIngestPath("12", simTag(iccidX)))
}

// TestBindingWritersHoldTelMu: an unassign, a bind and a delete's binding purge each wait for telMu. That the
// unassign holds it across both of its steps is pinned by TestUnassignHoldsTelMuAcrossRecordsAndUnbind.
func TestBindingWritersHoldTelMu(t *testing.T) {
	telFixture(t)
	asGate(t) // SET-BINDING and DELETE-BINDING answer only the user-0 gate (NWP-20260930-01)
	v, _ := vaultWithTelKey(t)
	if err := setBindingOwner(2, iccidX, "L", "open", "refA", v.TelPub); err != nil {
		t.Fatal(err)
	}
	// Warm the key cache: the purge derives the ref (Argon2) before it takes telMu, and a slow derivation inside the
	// 300 ms window below would pass this test with no lock at all.
	profileRefV2("nobody", "nothing")
	for what, run := range map[string]func() string{
		"SET-BINDING": func() string {
			return driveLogin(t, t.TempDir(), "SET-BINDING\n3\n"+iccidY+"\n"+b64s("L")+"\nopen\nrefB\n"+v.TelPub+"\n")
		},
		"DELETE-BINDING":         func() string { return driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n") },
		"purgeLocalProfileState": func() string { purgeLocalProfileState("nobody", "nothing"); return "done" },
	} {
		telMu.Lock()
		done := make(chan string, 1)
		go func() { done <- run() }()
		select {
		case got := <-done:
			telMu.Unlock()
			t.Fatalf("%s finished (%q) while telMu was held", what, got)
		case <-time.After(300 * time.Millisecond):
		}
		telMu.Unlock()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Fatalf("%s did not finish after telMu was released", what)
		}
	}
}

// TestUnassignHoldsTelMuAcrossRecordsAndUnbind pins handleDeleteBinding's record deletion AND its unbind inside one
// telMu hold: an arrival sealed or queued between the two would carry the tag of a SIM that is then unbound, and
// outlive the unassign. The behavioural test above sees only that it waits for telMu somewhere.
func TestUnassignHoldsTelMuAcrossRecordsAndUnbind(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	lines := stripComments(funcBody(t, string(b), "handleDeleteBinding"))
	at := func(s string) int {
		for i, l := range lines {
			if strings.Contains(l, s) {
				return i
			}
		}
		return -1
	}
	lock, unlock := at("telMu.Lock()"), at("defer telMu.Unlock()")
	blobs, unbind := at("deleteSimBlobs("), at("removeBindingOwner(")
	if lock < 0 || unlock != lock+1 || blobs < unlock || unbind < blobs {
		t.Fatalf("handleDeleteBinding must take telMu, and defer its release, before deleting records, and hold it through the unbind (lock %d, defer %d, records %d, unbind %d)", lock, unlock, blobs, unbind)
	}
	body := strings.Join(lines, "\n")
	if strings.Count(body, "telMu.Unlock()") != 1 || strings.Contains(body, "underTelMu(") {
		t.Fatal("handleDeleteBinding releases or re-takes telMu between its record deletion and its unbind")
	}
}

// TestDeleteDropsTheSessionUnderTelMu pins handleDelete's marker and mailbox removal inside one telMu hold, so an
// arrival either lands in the mailbox before it is removed, or seals with no live session after.
func TestDeleteDropsTheSessionUnderTelMu(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	lines := stripComments(funcBody(t, string(b), "handleDelete"))
	start := -1
	for i, l := range lines {
		if strings.Contains(l, "underTelMu(func() {") {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatal("handleDelete takes no telMu hold")
	}
	var marker, mailbox int = -1, -1
	for i, l := range lines {
		if strings.Contains(l, `os.Remove(filepath.Join(dest, ".roamsession"))`) {
			marker = i
		}
		if strings.Contains(l, "removeMailboxes(uid)") {
			mailbox = i
		}
	}
	end := -1
	for i := start + 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "})" {
			end = i
			break
		}
	}
	if marker <= start || mailbox <= start || marker >= end || mailbox >= end {
		t.Fatalf("the marker (%d) and mailbox (%d) removals must both sit inside the telMu hold (%d..%d)", marker, mailbox, start, end)
	}
}
