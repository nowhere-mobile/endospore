package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// NWP-20260924-07. At an unassign the records that came in on that SIM are deleted, for every owner it drops,
// at that moment, and none of those owners' records from their other SIMs (Chester, 2026-09-24,
// product-decisions.md, Open section: answer 2 and its two confirmations). These tests pin the tag every
// record now carries, and the DELETE-BINDING that acts on it.

const iccidX, iccidY = "89440000000000000011", "89440000000000000022"

var testSMS = telItem{Kind: "sms", From: "+1", When: 1, Body: "b"}

func TestSimTagIsOneNamePerSIM(t *testing.T) {
	tx := simTag(iccidX)
	for _, spelling := range []string{iccidX + "F", iccidX + "f", " " + iccidX + "\t", strings.ToUpper(iccidX)} {
		if simTag(spelling) != tx {
			t.Fatalf("simTag(%q) differs from simTag(%q): one SIM must have one tag", spelling, iccidX)
		}
	}
	if simTag(iccidY) == tx {
		t.Fatal("two SIMs share a tag")
	}
	if !isSimTag(tx) || strings.Contains(normICCID(iccidX), tx) {
		t.Fatalf("simTag = %q: want 16 lower-case hex that does not spell the ICCID", tx)
	}
	for _, bad := range []string{"", "-", tx[:15], tx + "0", strings.ToUpper(tx), "0123456789abcdeg"} {
		if isSimTag(bad) {
			t.Fatalf("isSimTag(%q) = true", bad)
		}
	}
	if normICCID(" \t") != "" {
		t.Fatal("a blank ICCID must normalise to empty, so the verbs can refuse it")
	}
}

// TestBindingLookupPrefersTheICCID: a SIM bound by hand stores sub_id -1, so two of them share a sub_id.
// The sub_id-first lookup gave a record from one of them the other's owners -- and now the other's tag.
func TestBindingLookupPrefersTheICCID(t *testing.T) {
	useTempBindings(t)
	if err := setBindingOwner(-1, iccidX, "X", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	if err := setBindingOwner(-1, iccidY, "Y", "open", "refB", "pubB"); err != nil {
		t.Fatal(err)
	}
	for _, spelling := range []string{iccidY, iccidY + "F"} {
		if b, ok := bindingForSubID(-1, spelling); !ok || b.ICCID != iccidY {
			t.Fatalf("lookup of %q by ICCID returned %+v, %v; want the Y binding", spelling, b, ok)
		}
	}
	if b, ok := bindingForSubID(-1, ""); ok {
		t.Fatalf("sub_id -1 is what a SIM bound by hand stores; with no ICCID it must match nothing, got %+v", b)
	}
	if err := setBindingOwner(4, "89440000000000000044", "W", "open", "refW", "pubW"); err != nil {
		t.Fatal(err)
	}
	if b, ok := bindingForSubID(4, ""); !ok || b.ICCID != "89440000000000000044" {
		t.Fatalf("with no ICCID a real sub_id must still match: %+v, %v", b, ok)
	}
	if b, ok := bindingForSubID(4, "89440000000000000055"); ok {
		t.Fatalf("an unbound SIM that names itself must not match by a sub_id it inherited: %+v", b)
	}
	if _, ok := bindingForSubID(5, ""); ok {
		t.Fatal("an unknown sub_id with no ICCID must not match")
	}
	// A padded re-bind is the same SIM, not a second one.
	if err := setBindingOwner(3, iccidX+"F", "X", "open", "refC", "pubC"); err != nil {
		t.Fatal(err)
	}
	bs := readBindings()
	if len(bs) != 3 {
		t.Fatalf("a padded re-bind created another SIM: %+v", bs)
	}
	for _, b := range bs {
		if b.ICCID == iccidX && len(b.Owners) != 2 {
			t.Fatalf("the padded re-bind must add an owner to X: %+v", b)
		}
	}
	if err := setBindingOwner(3, " f ", "X", "open", "refC", "pubC"); err == nil {
		t.Fatal("an ICCID that normalises to empty must be refused")
	}
}

// TestRemoveBindingOwnerCountsAndWritesOnlyOnChange: the reply the owner sees depends on the count, and a no-op
// must not rewrite the file (nor create one).
func TestRemoveBindingOwnerCountsAndWritesOnlyOnChange(t *testing.T) {
	useTempBindings(t)
	if n, err := removeBindingOwner(iccidX, ""); n != 0 || err != nil {
		t.Fatalf("no bindings file: %d, %v", n, err)
	}
	if _, err := os.Stat(bindingsPath); !os.IsNotExist(err) {
		t.Fatalf("a no-op created the bindings file (err %v)", err)
	}
	if err := setBindingOwner(1, iccidX, "X", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(bindingsPath, old, old); err != nil {
		t.Fatal(err)
	}
	for _, c := range [][2]string{{iccidY, ""}, {iccidX, "refZ"}, {"", ""}} {
		if n, err := removeBindingOwner(c[0], c[1]); n != 0 || err != nil {
			t.Fatalf("removeBindingOwner(%q, %q) = %d, %v; want 0, nil", c[0], c[1], n, err)
		}
	}
	if fi, err := os.Stat(bindingsPath); err != nil || !fi.ModTime().Equal(old) {
		t.Fatalf("a no-op rewrote the bindings file (err %v)", err)
	}
	if n, err := removeBindingOwner(iccidX+"F", ""); n != 1 || err != nil || len(readBindings()) != 0 {
		t.Fatalf("the padded form must remove X: %d, %v, %+v", n, err, readBindings())
	}
}

func TestSealedBlobNamesCarryTheSIM(t *testing.T) {
	useTempInbox(t)
	v, dk := vaultWithTelKey(t)
	const ref = "reftest"
	tx := simTag(iccidX)
	if err := sealItemToInbox(ref, v.TelPub, tx, testSMS); err != nil {
		t.Fatal(err)
	}
	if err := sealItemToInbox(ref, v.TelPub, "", testSMS); err != nil {
		t.Fatal(err)
	}
	_, opened := readTelInbox(v, dk, ref)
	tags := map[string]int{}
	for _, p := range opened {
		tags[blobTag(p)]++
	}
	if len(opened) != 2 || tags[tx] != 1 || tags[""] != 1 {
		t.Fatalf("opened %v; want one blob tagged X and one untagged", opened)
	}
	for _, bad := range []string{"x.seal", tx + ".seal", "." + tx + ".0123456789abcdef.seal", tx + ".0123456789abcdef.seal.tmp"} {
		if blobTag(bad) != "" {
			t.Fatalf("blobTag(%q) must be empty", bad)
		}
	}
}

// TestArrivalTagsSealedRecordsWithTheirSIM: an SMS and an MMS sealed for a profile that is not signed in are named
// for the SIM they came in on -- the binding's SIM, found by ICCID even when the sub_id has renumbered and the
// binding was stored in the padded spelling.
func TestArrivalTagsSealedRecordsWithTheirSIM(t *testing.T) {
	useTempInbox(t)
	useTempBindings(t)
	v, _ := vaultWithTelKey(t)
	const ref = "arrref"
	if err := setBindingOwner(2, iccidX+"F", "L", "open", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	if err := setBindingOwner(7, iccidY, "L", "open", "otherref", v.TelPub); err != nil {
		t.Fatal(err)
	}
	reply := driveSealTel(t, t.TempDir(), []string{"sms", "7", iccidX, "+15551234567", "1720000000000",
		base64.StdEncoding.EncodeToString([]byte("hi")), "0", "0"})
	if !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("SEAL-TEL reply %q", reply)
	}
	mms := telItem{Kind: "mms", SubID: 7, From: "+15551234567", When: 1720000000001,
		Parts: []mmsPart{{ContentType: "text/plain", Name: "t.txt", Data: []byte("x")}}}
	if reply := driveSealMms(t, t.TempDir(), iccidX, mms); !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("SEAL-MMS reply %q", reply)
	}
	l := listSealed(ref)
	if len(l) != 2 {
		t.Fatalf("want the SMS and the MMS sealed for X's owner, got %v", l)
	}
	for _, p := range l {
		if blobTag(p) != simTag(iccidX) {
			t.Fatalf("%s is not tagged with the SIM it came in on", filepath.Base(p))
		}
	}
	if l := listSealed("otherref"); l != nil {
		t.Fatalf("the sub_id matched Y's binding and sealed to its owner: %v", l)
	}
	// An unbound SIM that inherited Y's sub_id is unbound, not Y.
	reply = driveSealTel(t, t.TempDir(), []string{"sms", "7", "89440000000000000099", "+15551234567", "1720000000002",
		base64.StdEncoding.EncodeToString([]byte("hi")), "0", "0"})
	if !strings.HasPrefix(reply, "NONE") {
		t.Fatalf("an unbound SIM's SMS replied %q, want NONE", reply)
	}
	if l := listSealed("otherref"); l != nil {
		t.Fatalf("an unbound SIM's SMS was sealed to the owner of a SIM that once had its sub_id: %v", l)
	}
}

// TestStageSplitsBySIM: a login's hand-off writes one mailbox per SIM, and a SIM whose write fails keeps exactly
// its own sealed copies while the others are handed off and dropped.
func TestStageSplitsBySIM(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	v, dk := vaultWithTelKey(t)
	const ref, uid = "reftest", "12"
	tx, ty := simTag(iccidX), simTag(iccidY)
	for _, tag := range []string{tx, tx, ty, ""} {
		if err := sealItemToInbox(ref, v.TelPub, tag, testSMS); err != nil {
			t.Fatal(err)
		}
	}
	// A fresh roam-in's uid is new: a mailbox already there is a stale leftover and must not be served with it. It
	// goes at the bring-up (beginTelStaging, NWP-20260927-09), before any arrival can queue a row for the session.
	tz := simTag("89440000000000000033")
	if err := appendTelIngest(uid, tz, testSMS); err != nil {
		t.Fatal(err)
	}
	if err := appendTelIngest("120", tx, testSMS); err != nil {
		t.Fatal(err)
	}
	if err := beginTelStaging(uid, true); err != nil {
		t.Fatal(err)
	}
	endTelStaging(uid)
	if _, err := os.Stat(telIngestPath(uid, tz)); !os.IsNotExist(err) {
		t.Fatalf("a roam-in's bring-up left the uid's stale mailbox (err %v)", err)
	}
	mustExist(t, "another uid's mailbox", telIngestPath("120", tx))
	if n, err := stageTelInbox(v, dk, ref, uid); n != 4 || err != nil {
		t.Fatalf("stage = %d, %v; want 4, nil", n, err)
	}
	for tag, rows := range map[string]int{tx: 2, ty: 1, "": 1} {
		b, err := os.ReadFile(telIngestPath(uid, tag))
		if err != nil || strings.Count(string(b), "\n") != rows {
			t.Fatalf("mailbox for tag %q = %q, %v; want %d rows", tag, b, err, rows)
		}
	}
	if l := listSealed(ref); l != nil {
		t.Fatalf("handed-off blobs were not dropped: %v", l)
	}

	// Y's mailbox cannot be written (a non-empty directory sits on its path). The session claims and acknowledges
	// the first hand-off, so its pending copies (NWP-20261006-05) are not staged again below.
	if _, err := claimTelIngest(uid); err != nil {
		t.Fatal(err)
	}
	if n := ackPending(uid, []string{itemRowKey(testSMS)}); n != 4 {
		t.Fatalf("ack of the first hand-off removed %d pending copies, want 4", n)
	}
	if err := os.MkdirAll(filepath.Join(telIngestPath(uid, ty), "occupied"), 0o700); err != nil {
		t.Fatal(err)
	}
	for round := 1; round <= 2; round++ {
		for _, tag := range []string{tx, ty} {
			if err := sealItemToInbox(ref, v.TelPub, tag, testSMS); err != nil {
				t.Fatal(err)
			}
		}
		n, err := stageTelInbox(v, dk, ref, uid)
		if n != 1 || err == nil {
			t.Fatalf("round %d: stage = %d, %v; want X's 1 staged and Y's failure reported", round, n, err)
		}
		left := listSealed(ref)
		ys := 0
		for _, p := range left {
			if blobTag(p) != ty {
				t.Fatalf("round %d: a blob that was handed off stayed: %s", round, p)
			}
			ys++
		}
		if ys != round {
			t.Fatalf("round %d: %d of Y's sealed blobs kept, want %d", round, ys, round)
		}
	}
}

// TestClaimTakesOnlyThisUIDsMailboxes: the claim serves every mailbox of the uid, bare first, and nothing else --
// not uid 10's for uid 1, not a temp, not an orphan of the old rename-aside claim.
func TestClaimTakesOnlyThisUIDsMailboxes(t *testing.T) {
	dir := useTempIngest(t)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	tx, ty, tz := simTag(iccidX), simTag(iccidY), simTag("89440000000000000033")
	files := map[string]string{
		"telingest.1":                "sms 1 0 0 - -", // no trailing newline: a rollback that itself failed
		"telingest.1." + tx:          "call 2 3 0 - -" + tx + "\n",
		"telingest.1." + ty:          "call 3 3 0 - -" + ty + "\n",
		"telingest.10":               "uid10\n",
		"telingest.100." + tx:        "uid100\n",
		"telingest.1." + tx + ".tmp": "temp\n",
		"telingest.1.claim.3":        "orphan\n",
		"telingest.1.nottag":         "junk\n",
	}
	for n, c := range files {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(c), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(dir, "telingest.1."+tz), 0o700); err != nil { // not a regular file
		t.Fatal(err)
	}
	tags := []string{tx, ty}
	sort.Strings(tags)
	want := files["telingest.1"] + "\n" + files["telingest.1."+tags[0]] + files["telingest.1."+tags[1]]
	b, err := claimTelIngest("1")
	if err != nil || string(b) != want {
		t.Fatalf("claim = %q, %v; want %q", b, err, want)
	}
	for n := range files {
		_, err := os.Stat(filepath.Join(dir, n))
		taken := n == "telingest.1" || n == "telingest.1."+tx || n == "telingest.1."+ty
		if taken != os.IsNotExist(err) {
			t.Fatalf("%s: taken=%v but stat err %v", n, taken, err)
		}
	}
	if err := removeMailboxes("10"); err != nil {
		t.Fatal(err)
	}
	mustExist(t, "uid 100's mailbox", filepath.Join(dir, "telingest.100."+tx))
	if _, err := os.Stat(filepath.Join(dir, "telingest.10")); !os.IsNotExist(err) {
		t.Fatalf("removeMailboxes left uid 10's mailbox (err %v)", err)
	}
}

// TestCallRowCarriesItsSIM: the chooser re-stages only call rows, echoing the body slot verbatim, so that slot is
// where a call row keeps its tag. An SMS row never carries one in-band, even a forged one.
func TestCallRowCarriesItsSIM(t *testing.T) {
	useTempIngest(t)
	tx := simTag(iccidX)
	call := strings.TrimRight(serializeTelIngest([]telItem{{Kind: "call", From: "+1", When: 5, CallType: 3}}, tx), "\n")
	if f := strings.Fields(call); len(f) != 6 || f[5] != "-"+tx {
		t.Fatalf("call row = %q; want its body slot to be -<tag>", call)
	}
	sms := strings.TrimRight(serializeTelIngest([]telItem{testSMS}, tx), "\n")
	if f := strings.Fields(sms); len(f) != 6 || f[5] != b64tok(testSMS.Body) {
		t.Fatalf("sms row = %q; its body slot must still be the body", sms)
	}
	for row, want := range map[string]string{
		call: tx, call + " 2": tx, sms: "", "call 5 3 0 KzE - 1": "", "call 5 3 0 KzE -zz 1": "",
		"sms 1 0 0 - -" + tx: "", "mms 1 abc": "", "": "",
	} {
		if got := rowTag(row); got != want {
			t.Fatalf("rowTag(%q) = %q, want %q", row, got, want)
		}
	}
	if err := appendTelIngestRaw("12", call+" 1"); err != nil {
		t.Fatal(err)
	}
	mustExist(t, "X's mailbox", telIngestPath("12", tx))
	if _, err := os.Stat(telIngestPath("12", "")); !os.IsNotExist(err) {
		t.Fatalf("a tagged row went to the bare mailbox (err %v)", err)
	}
}

// TestRestageDropsARowWhoseSIMWasUnassigned: a row the chooser held while its SIM was unassigned must not come
// back; the unassign deleted everything else that came in on that SIM. The RESTAGE-TELINGEST verb
// (serveRestageTelIngest) is exercised directly -- its replies, and that it drops that row -- not grepped.
func TestRestageDropsARowWhoseSIMWasUnassigned(t *testing.T) {
	useTempIngest(t)
	useTempBindings(t)
	if err := setBindingOwner(1, iccidX, "X", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	tx, ty := simTag(iccidX), simTag(iccidY)
	rowX := "call 5 3 0 KzE -" + tx + " 1"
	rowY := "call 6 3 0 KzE -" + ty + " 1"
	if dropped, err := restageTelIngest("12", rowX); dropped || err != nil {
		t.Fatalf("a bound SIM's row: dropped=%v, %v", dropped, err)
	}
	if dropped, err := restageTelIngest("12", rowY); !dropped || err != nil {
		t.Fatalf("an unassigned SIM's row: dropped=%v, %v; want dropped", dropped, err)
	}
	if dropped, err := restageTelIngest("12", "call 7 3 0 KzE - 1"); dropped || err != nil {
		t.Fatalf("an untagged row: dropped=%v, %v", dropped, err)
	}
	mustExist(t, "X's mailbox", telIngestPath("12", tx))
	mustExist(t, "the bare mailbox", telIngestPath("12", ""))
	if _, err := os.Stat(telIngestPath("12", ty)); !os.IsNotExist(err) {
		t.Fatalf("the unassigned SIM's row was put back (err %v)", err)
	}
	// The verb itself (RESTAGE-TELINGEST), exercised against a fresh ingest dir so the calls above cannot satisfy it.
	dir := useTempIngest(t)
	puid := 12*100000 + 10123
	var b bytes.Buffer
	serveRestageTelIngest(&b, -1, rowX)
	if b.String() != "ERR\n" {
		t.Fatalf("puid -1: reply %q, want ERR", b.String())
	}
	if ents, err := os.ReadDir(dir); !os.IsNotExist(err) && (err != nil || len(ents) != 0) {
		t.Fatalf("puid -1 wrote to the ingest dir: %v, %v", ents, err)
	}
	b.Reset()
	serveRestageTelIngest(&b, puid, rowY)
	if b.String() != "OK\n" {
		t.Fatalf("an unassigned SIM's row: reply %q, want OK so the chooser stops retrying it", b.String())
	}
	if _, err := os.Stat(telIngestPath("12", ty)); !os.IsNotExist(err) {
		t.Fatalf("RESTAGE-TELINGEST put the unassigned SIM's row back (err %v)", err)
	}
	b.Reset()
	serveRestageTelIngest(&b, puid, rowX)
	if b.String() != "OK\n" {
		t.Fatalf("a bound SIM's row: reply %q, want OK", b.String())
	}
	mustExist(t, "X's mailbox via RESTAGE-TELINGEST", telIngestPath("12", tx))
	b.Reset()
	serveRestageTelIngest(&b, puid, "")
	if b.String() != "OK\n" {
		t.Fatalf("an empty row: reply %q, want OK", b.String())
	}
}

// TestRestagedSMSReturnsToItsSIM (NWP-20261005-15): an SMS row carries no in-row tag, so its SIM is remembered at
// claim time. A re-staged SMS goes back to the mailbox it was claimed from -- which an unassign deletes -- and is
// dropped if its SIM was unassigned while the chooser held it. Without the claim record it went to the bare mailbox.
func TestRestagedSMSReturnsToItsSIM(t *testing.T) {
	useTempIngest(t)
	useTempBindings(t)
	if err := setBindingOwner(1, iccidX, "X", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	tx, ty := simTag(iccidX), simTag(iccidY)
	smsX := "sms 101 0 0 KzE aGk="
	smsY := "sms 102 0 0 KzE aGk="
	if err := appendMailbox("12", tx, smsX+"\n"); err != nil {
		t.Fatal(err)
	}
	if err := appendMailbox("12", ty, smsY+"\n"); err != nil {
		t.Fatal(err)
	}
	if b, err := claimTelIngest("12"); err != nil || strings.Count(string(b), "\n") != 2 {
		t.Fatalf("claim = %q, %v; want both rows", b, err)
	}
	// The chooser appends its retry token; the key is the kind and the arrival ms, so it still matches.
	if dropped, err := restageTelIngest("12", smsX+" 1"); dropped || err != nil {
		t.Fatalf("a bound SIM's SMS: dropped=%v, %v", dropped, err)
	}
	mustExist(t, "X's mailbox", telIngestPath("12", tx))
	if _, err := os.Stat(telIngestPath("12", "")); !os.IsNotExist(err) {
		t.Fatalf("the re-staged SMS went to the bare mailbox, which no unassign deletes (err %v)", err)
	}
	if dropped, err := restageTelIngest("12", smsY+" 1"); !dropped || err != nil {
		t.Fatalf("an unassigned SIM's SMS: dropped=%v, %v; want dropped", dropped, err)
	}
	// The record is taken on use: a second re-stage of the same row has no SIM to return to.
	if dropped, err := restageTelIngest("12", smsY+" 2"); dropped || err != nil {
		t.Fatalf("an SMS with no claim record: dropped=%v, %v", dropped, err)
	}
	mustExist(t, "the bare mailbox", telIngestPath("12", ""))
	// removeMailboxes forgets a uid's records along with its files.
	if err := appendMailbox("13", tx, "sms 103 0 0 KzE aGk=\n"); err != nil {
		t.Fatal(err)
	}
	if _, err := claimTelIngest("13"); err != nil {
		t.Fatal(err)
	}
	if err := removeMailboxes("13"); err != nil {
		t.Fatal(err)
	}
	if got := takeClaimedTag("13", "sms 103 0 0 KzE aGk="); got != "" {
		t.Fatalf("a removed uid's claim record survived: %q", got)
	}
}

// TestChooserEchoesTheBodySlotOnRestage: the tag survives a re-stage only because TelIngest.java rebuilds the row
// from f[0]..f[5] verbatim. Since NWP-20261019-27 the call loop sends the line restageLine(f, 6, ...) returns, and
// restageLine copies f[0]..f[base-1] ahead of the retry token (test-tel-restage-java.sh runs it under javac). If
// either stops echoing f[5], every re-staged call row loses its SIM and goes to the bare mailbox, which no unassign
// deletes.
func TestChooserEchoesTheBodySlotOnRestage(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "TelIngest.java"))
	if err != nil {
		t.Fatalf("TelIngest.java must be readable from core/agent: %v", err)
	}
	for _, p := range []struct{ what, code string }{
		{"the call loop no longer sends the line restageLine(f, 6, MAX_TEL_RETRIES) builds",
			`String line = restageLine(f, 6, MAX_TEL_RETRIES);` + "\n" +
				`                    if (line != null) {` + "\n" +
				`                        DaemonSocket.roundTrip("RESTAGE-TELINGEST\n" + line + "\n", 5_000);`},
		{"restageLine no longer copies f[0]..f[base-1] into the row it returns",
			`        StringBuilder row = new StringBuilder(f[0]);` + "\n" +
				`        for (int k = 1; k < base; k++) row.append(' ').append(f[k]);` + "\n" +
				`        return row.append(' ').append(retry + 1).toString();`},
	} {
		if strings.Count(string(b), p.code) != 1 {
			t.Fatalf("TelIngest.java no longer rebuilds a re-staged call row from f[0]..f[5] verbatim: %s", p.what)
		}
	}
}

// unassignFixture binds X to A and B and Y to A, and plants records on both SIMs, sealed and in mailboxes.
func unassignFixture(t *testing.T) (refA, refB string) {
	t.Helper()
	asGate(t) // DELETE-BINDING is an owner-mode verb: only the user-0 gate may call it (NWP-20260930-01)
	useTempInbox(t)
	useTempIngest(t)
	useTempBindings(t)
	va, _ := vaultWithTelKey(t)
	vb, _ := vaultWithTelKey(t)
	refA, refB = "refA", "refB"
	for _, b := range []struct {
		iccid, ref, pub string
	}{{iccidX, refA, va.TelPub}, {iccidX, refB, vb.TelPub}, {iccidY, refA, va.TelPub}} {
		if err := setBindingOwner(-1, b.iccid, "L", "open", b.ref, b.pub); err != nil {
			t.Fatal(err)
		}
	}
	tx, ty := simTag(iccidX), simTag(iccidY)
	for _, s := range []struct{ ref, pub, tag string }{
		{refA, va.TelPub, tx}, {refA, va.TelPub, tx}, {refA, va.TelPub, ty}, {refA, va.TelPub, ""}, {refB, vb.TelPub, tx},
	} {
		if err := sealItemToInbox(s.ref, s.pub, s.tag, testSMS); err != nil {
			t.Fatal(err)
		}
	}
	// A failed publish's leftover temp for X.
	if err := os.WriteFile(filepath.Join(telInboxDir(refA), "."+tx+".0123456789abcdef.seal"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, m := range []struct{ uid, tag string }{{"10", tx}, {"10", ty}, {"10", ""}, {"11", tx}} {
		if err := appendTelIngest(m.uid, m.tag, testSMS); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(telIngestPath("10", tx)+".tmp", []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return refA, refB
}

// recordCensus lists every file under both telephony bases, so a refusal can be shown to have touched nothing.
func recordCensus(t *testing.T) string {
	t.Helper()
	var out []string
	for _, base := range []string{telInboxBase, telIngestBase} {
		filepath.Walk(base, func(p string, fi os.FileInfo, err error) error {
			if err == nil && !fi.IsDir() {
				out = append(out, p)
			}
			return nil
		})
	}
	sort.Strings(out)
	b, _ := os.ReadFile(bindingsPath)
	return strings.Join(out, "\n") + "\n--\n" + string(b)
}

// TestUnbindDeletesThatSIMsRecordsOnly drives DELETE-BINDING end to end: every record that came in on X goes, for
// every owner and every session; Y's records, and the untagged ones, stay; Y stays bound.
func TestUnbindDeletesThatSIMsRecordsOnly(t *testing.T) {
	refA, refB := unassignFixture(t)
	tx, ty := simTag(iccidX), simTag(iccidY)
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); got != "OK "+lineToken("L") {
		t.Fatalf("reply %q, want OK", got)
	}
	left := map[string]int{}
	for _, p := range listSealed(refA) {
		left[blobTag(p)]++
	}
	if len(left) != 2 || left[ty] != 1 || left[""] != 1 {
		t.Fatalf("A's buffer after unbinding X holds %v; want only Y's blob and the untagged one", left)
	}
	ents, _ := os.ReadDir(telInboxDir(refA))
	for _, e := range ents {
		if strings.Contains(e.Name(), tx) {
			t.Fatalf("an X file survived in A's buffer: %s", e.Name())
		}
	}
	if _, err := os.Stat(telInboxDir(refB)); !os.IsNotExist(err) {
		t.Fatalf("B's buffer held only X's records and must be gone (err %v)", err)
	}
	for _, p := range []string{telIngestPath("10", tx), telIngestPath("11", tx), telIngestPath("10", tx) + ".tmp"} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s survived the unbind (err %v)", filepath.Base(p), err)
		}
	}
	mustExist(t, "Y's mailbox", telIngestPath("10", ty))
	mustExist(t, "the bare mailbox", telIngestPath("10", ""))
	bs := readBindings()
	if len(bs) != 1 || bs[0].ICCID != iccidY || len(bs[0].Owners) != 1 || bs[0].Owners[0].ProfileRef != refA {
		t.Fatalf("bindings after unbinding X = %+v; want only Y, owned by A", bs)
	}
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); got != "NOTFOUND" {
		t.Fatalf("a second unbind of X replied %q, want NOTFOUND", got)
	}
}

// TestUnbindRefusesWhatItCannotHonour: an empty ICCID, a per-owner unbind and a busy daemon change nothing; an
// unknown SIM says so; the padded spelling of a bound SIM works.
func TestUnbindRefusesWhatItCannotHonour(t *testing.T) {
	unassignFixture(t)
	before := recordCensus(t)
	for req, want := range map[string]string{
		"DELETE-BINDING\n\n\n":                     "ERR",
		"DELETE-BINDING\n \t\n\n":                  "ERR",
		"DELETE-BINDING\n" + iccidX + "\nrefA\n":   "ERR",
		"DELETE-BINDING\n89449999999999999999\n\n": "NOTFOUND",
	} {
		if got := driveLogin(t, t.TempDir(), req); got != want {
			t.Fatalf("%q replied %q, want %q", req, got, want)
		}
		if after := recordCensus(t); after != before {
			t.Fatalf("%q changed the records or bindings:\nbefore %s\nafter  %s", req, before, after)
		}
	}
	requireTryLocked(t) // else the next call deadlocks the package instead of failing
	sessionMu.Lock()
	got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n")
	sessionMu.Unlock()
	if got != "BUSY" {
		t.Fatalf("an unbind while sessionMu is held replied %q, want BUSY", got)
	}
	if after := recordCensus(t); after != before {
		t.Fatal("a BUSY unbind changed the records or bindings")
	}
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"F\n\n"); got != "OK "+lineToken("L") {
		t.Fatalf("the padded spelling of X replied %q, want OK", got)
	}
	if _, err := os.Stat(telIngestPath("11", simTag(iccidX))); !os.IsNotExist(err) {
		t.Fatalf("the padded unbind left X's records (err %v)", err)
	}
}

// TestUnbindKeepsTheBindingWhenARecordWillNotGo: records first, binding second, so a failure leaves the SIM bound
// and the owner can retry -- never a SIM unbound with its records left behind.
func TestUnbindKeepsTheBindingWhenARecordWillNotGo(t *testing.T) {
	unassignFixture(t)
	f := filepath.Join(t.TempDir(), "notadir")
	if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	telIngestBase = f // useTempIngest's cleanup restores it
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); got != "ERR" {
		t.Fatalf("reply %q, want ERR", got)
	}
	found := false
	for _, b := range readBindings() {
		if b.ICCID == iccidX {
			found = true
		}
	}
	if !found {
		t.Fatal("X was unbound although its records could not all be deleted")
	}
}

// TestDeleteBindingIsTryLocked pins the verb into the TryLock set by source, beside the behavioural BUSY above.
func TestDeleteBindingIsTryLocked(t *testing.T) { requireTryLocked(t) }

// requireTryLocked fails the test unless DELETE-BINDING is in handleLogin's TryLock set. The behavioural BUSY check
// calls it first: without the TryLock, handleLogin would block on the sessionMu the test holds, and hang every test.
func requireTryLocked(t *testing.T) {
	t.Helper()
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range stripComments(funcBody(t, string(b), "handleLogin")) {
		if strings.Contains(l, `name == "BACKUP" || name == "DELETE"`) {
			if !strings.Contains(l, `name == "DELETE-BINDING"`) {
				t.Fatal("DELETE-BINDING must answer BUSY rather than wait for sessionMu")
			}
			return
		}
	}
	t.Fatal("the TryLock set was not found -- this test is stale, not the code")
}

// TestStageErrorNamesNoSIM: a failed per-SIM hand-off is logged to login.log, which also travels in an issue report,
// and a file error names its path -- which for a per-SIM mailbox ends in the tag. The error must say how many SIMs
// failed, on one line, without the tag.
func TestStageErrorNamesNoSIM(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	v, dk := vaultWithTelKey(t)
	const ref, uid = "reftest", "12"
	tx, ty := simTag(iccidX), simTag(iccidY)
	for _, tag := range []string{tx, ty} {
		if err := sealItemToInbox(ref, v.TelPub, tag, testSMS); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(telIngestPath(uid, ty), "occupied"), 0o700); err != nil {
		t.Fatal(err)
	}
	for round := 1; round <= 2; round++ {
		n, err := stageTelInbox(v, dk, ref, uid)
		if n != 1 || err == nil {
			t.Fatalf("round %d: stage = %d, %v; want 1 staged and an error", round, n, err)
		}
		msg := err.Error()
		if strings.Contains(msg, ty) || strings.Contains(msg, tx) || strings.Contains(msg, "\n") || !strings.HasPrefix(msg, "1 of ") {
			t.Fatalf("round %d: error %q must count the failed SIMs on one line and name no tag", round, msg)
		}
		if !strings.Contains(msg, "telingest."+uid+".<sim>") {
			t.Fatalf("round %d: error %q lost the redacted path (control: the path was there to redact)", round, msg)
		}
		if err := sealItemToInbox(ref, v.TelPub, tx, testSMS); err != nil {
			t.Fatal(err)
		}
	}
}

// TestClaimServesOnlyWhatItTook: a mailbox file that will not go is left and NOT served, so the next claim serves
// its rows once. Serving and then failing to remove would deliver them twice, and SMS dedup is per run only.
func TestClaimServesOnlyWhatItTook(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores the read-only directory this test relies on")
	}
	dir := useTempIngest(t)
	if err := appendTelIngest("12", simTag(iccidX), testSMS); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	b, err := claimTelIngest("12")
	if err == nil || len(b) != 0 {
		t.Fatalf("claim of an unremovable file = %q, %v; want nothing served and the error", b, err)
	}
	os.Chmod(dir, 0o700)
	if b, err := claimTelIngest("12"); err != nil || strings.Count(string(b), "\n") != 1 {
		t.Fatalf("the next claim = %q, %v; want the row, once", b, err)
	}
}

// TestRemoveBindingOwnerTakesLegacyDuplicates: before NWP-20260924-07 a re-bind in the other ICCID spelling made a
// SECOND record for the same SIM. An unassign must remove both, or the SIM stays bound under the other spelling.
func TestRemoveBindingOwnerTakesLegacyDuplicates(t *testing.T) {
	useTempBindings(t)
	if err := writeBindings([]simBinding{
		{SubID: -1, ICCID: iccidX, Label: "L", Visibility: "open", Owners: []bindingOwner{{"refA", "pubA"}}},
		{SubID: 3, ICCID: iccidX + "F", Label: "L", Visibility: "open", Owners: []bindingOwner{{"refB", "pubB"}}},
		{SubID: 4, ICCID: iccidY, Label: "L", Visibility: "open", Owners: []bindingOwner{{"refC", "pubC"}}},
	}, nil); err != nil {
		t.Fatal(err)
	}
	if n, err := removeBindingOwner(iccidX, ""); n != 2 || err != nil {
		t.Fatalf("removeBindingOwner = %d, %v; want both spellings of X removed", n, err)
	}
	if bs := readBindings(); len(bs) != 1 || bs[0].ICCID != iccidY {
		t.Fatalf("bindings left = %+v; want only Y", bs)
	}
}

// lineToken is one label as a DELETE-BINDING OK reply carries it: "L" + base64(label), a bare "L" for a blank label.
func lineToken(label string) string { return "L" + base64.StdEncoding.EncodeToString([]byte(label)) }

// TestUnbindReplyNamesTheLineLabels: owner mode clears the unbound line's gate notices, which name the line only by
// label (NWP-20260924-08, Chester 2026-09-24: "unbind all should clear it"). The reply must name every label the SIM
// was stored under -- a blank one included, as a bare "L" -- and no other SIM's.
func TestUnbindReplyNamesTheLineLabels(t *testing.T) {
	asGate(t)
	useTempInbox(t)
	useTempIngest(t)
	useTempBindings(t)
	if err := writeBindings([]simBinding{
		{SubID: -1, ICCID: iccidX, Label: "Alex's line | work", Visibility: "open", Owners: []bindingOwner{{"refA", "pubA"}}},
		{SubID: 3, ICCID: iccidX + "F", Label: "", Visibility: "open", Owners: []bindingOwner{{"refB", "pubB"}}},
		{SubID: 4, ICCID: iccidY, Label: "Other", Visibility: "open", Owners: []bindingOwner{{"refC", "pubC"}}},
	}, nil); err != nil {
		t.Fatal(err)
	}
	got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n")
	f := strings.Split(got, " ")
	want := map[string]bool{lineToken("Alex's line | work"): true, "L": true}
	if len(f) != 3 || f[0] != "OK" || !want[f[1]] || !want[f[2]] || f[1] == f[2] {
		t.Fatalf("reply %q; want OK and exactly the tokens for X's two labels, the blank one as a bare L", got)
	}
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); got != "NOTFOUND" {
		t.Fatalf("a second unbind replied %q, want a bare NOTFOUND", got)
	}
}
