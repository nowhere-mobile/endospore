package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// TestSerializeMmsIngest (#150 P4): an MMS telItem serializes as "mms <when> <telItem_json_b64>" and the
// whole item (subject + text + binary image part) round-trips through the base64 JSON token -- what the
// roamed TelIngest.deliver decodes to do the multi-table content://mms insert.
func TestSerializeMmsIngest(t *testing.T) {
	it := telItem{Kind: "mms", SubID: 2, From: "+15551112222", When: 1720000000000, Subject: "hi 📷",
		Parts: []mmsPart{
			{ContentType: "text/plain", Name: "t.txt", Data: []byte("look at this")},
			{ContentType: "image/jpeg", Name: "p.jpg", Data: []byte{0xFF, 0xD8, 0xFF, 0x00, 0x11}},
		}}
	line := strings.TrimRight(serializeTelIngest([]telItem{it}, ""), "\n")
	f := strings.SplitN(line, " ", 3)
	if len(f) != 3 || f[0] != "mms" || f[1] != "1720000000000" {
		t.Fatalf("mms line = %q, want 'mms <when> <b64>'", line)
	}
	if strings.ContainsAny(f[2], " \n") {
		t.Fatalf("mms b64 token must have no spaces/newlines (line-safe): %q", f[2])
	}
	jb, err := base64.StdEncoding.DecodeString(f[2])
	if err != nil {
		t.Fatalf("b64 decode: %v", err)
	}
	var got telItem
	if err := json.Unmarshal(jb, &got); err != nil {
		t.Fatalf("json unmarshal: %v", err)
	}
	if !reflect.DeepEqual(got, it) {
		t.Fatalf("mms ingest round-trip:\n got %+v\nwant %+v", got, it)
	}
}

// parseIngestLine mimics the READER (TelIngest.java): a plain space split + per-token base64 decode with
// the "-" empty sentinel. It deliberately uses Split (NOT SplitN) with a strict ==6 check, plus a
// TrimSpace on the line, to prove no row DEPENDS on an empty trailing token surviving -- Java's
// String.split(" ") drops trailing empties and DaemonSocket trims the reply line, which is exactly how
// the pre-sentinel format silently lost every call row (empty body -> 5 tokens -> rejected). Like deliver(), it
// reads the body slot only for an SMS: a call row's slot is "-" or "-<simTag>" (NWP-20260924-07), never a body.
func parseIngestLine(t *testing.T, line string) telItem {
	t.Helper()
	f := strings.Split(strings.TrimSpace(line), " ")
	// NWP-20261130-01: an SMS row may carry its SIM's slot after the six fixed fields.
	if len(f) == 7 && f[0] != "call" && strings.HasPrefix(f[6], simSlotPrefix) && isSimTag(f[6][len(simSlotPrefix):]) {
		f = f[:6]
	}
	if len(f) != 6 {
		t.Fatalf("line has %d fields, want 6: %q", len(f), line)
	}
	when, _ := strconv.ParseInt(f[1], 10, 64)
	ctype, _ := strconv.Atoi(f[2])
	dur, _ := strconv.Atoi(f[3])
	body := ""
	if f[0] == "call" {
		if f[5] != "-" && !(strings.HasPrefix(f[5], "-") && isSimTag(f[5][1:])) {
			t.Fatalf("a call row's body slot must be - or -<simTag>, got %q", f[5])
		}
	} else {
		body = decTok(t, f[5])
	}
	return telItem{Kind: f[0], When: when, CallType: ctype, DurSec: dur,
		From: decTok(t, f[4]), Body: body}
}

// decTok decodes a wire token the way TelIngest.java does: "-" -> empty, else standard base64.
func decTok(t *testing.T, tok string) string {
	t.Helper()
	if tok == "-" {
		return ""
	}
	b, err := base64.StdEncoding.DecodeString(tok)
	if err != nil {
		t.Fatalf("token b64: %v", err)
	}
	return string(b)
}

func TestSerializeTelIngestRoundTrip(t *testing.T) {
	want := []telItem{
		{Kind: "sms", From: "+1 555 0100", When: 1720000000000, Body: "hi there\nsecond line | with a pipe & \"quotes\""},
		{Kind: "call", From: "+15550101", When: 1720000009999, CallType: 3, DurSec: 42}, // empty body -> "-" sentinel
		{Kind: "call", From: "", When: 1720000010001, CallType: 1, DurSec: 7},           // withheld number: BOTH sentinels
	}
	for _, tag := range []string{"", simTag("89440000000000000066")} {
		s := serializeTelIngest(want, tag)
		lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
		if len(lines) != len(want) {
			t.Fatalf("got %d lines, want %d", len(lines), len(want))
		}
		for i, ln := range lines {
			got := parseIngestLine(t, ln)
			if !reflect.DeepEqual(got, want[i]) {
				t.Fatalf("tag %q line %d round-trip mismatch:\n got  %+v\n want %+v", tag, i, got, want[i])
			}
		}
	}
}

// TestAppendTelIngestBatchWritesTheRow: the batch writer every staging uses since NWP-20260927-09 (the atomic
// fresh write it replaced for a roam-in is gone) lays down one newline-terminated row per item.
func TestAppendTelIngestBatchWritesTheRow(t *testing.T) {
	old := telIngestBase
	telIngestBase = t.TempDir()
	t.Cleanup(func() { telIngestBase = old })

	if err := appendTelIngestBatch("11", "", []telItem{{Kind: "sms", From: "+1", When: 5, Body: "x"}}); err != nil {
		t.Fatalf("appendTelIngestBatch: %v", err)
	}
	b, err := os.ReadFile(telIngestPath("11", ""))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	// "sms 5 0 0 <b64(+1)> <b64(x)>\n"
	if !strings.HasPrefix(string(b), "sms 5 0 0 ") || !strings.HasSuffix(string(b), "\n") || strings.Count(string(b), "\n") != 1 {
		t.Fatalf("unexpected content: %q", b)
	}
}

// TestAppendTelIngestRawRoundTrip (#135 Part 3): a RESTAGE-re-staged raw row -- including its trailing retry
// token -- is appended verbatim onto the mailbox (with or without a newline) and read back whole by the next
// claim, so a later delivery kick retries it with the retry count intact.
func TestAppendTelIngestRawRoundTrip(t *testing.T) {
	old := telIngestBase
	telIngestBase = t.TempDir()
	t.Cleanup(func() { telIngestBase = old })

	if err := appendTelIngestRaw("11", "call 5 3 0 KzE - 1"); err != nil { // 7th token = retry count, no newline
		t.Fatal(err)
	}
	if err := appendTelIngestRaw("11", "call 6 3 0 KzI - 2\n"); err != nil { // already newline-terminated
		t.Fatal(err)
	}
	b, err := claimTelIngest("11")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) != 2 || lines[0] != "call 5 3 0 KzE - 1" || lines[1] != "call 6 3 0 KzI - 2" {
		t.Fatalf("claim = %q, want the two re-staged rows with retry tokens intact", b)
	}
	if _, err := os.Stat(telIngestPath("11", "")); !os.IsNotExist(err) {
		t.Fatal("mailbox not emptied by the claim")
	}
}

// TestClaimTelIngestAtomicTake (#149): a claim TAKES all staged rows and empties the mailbox, and a row
// appended AFTER a claim is not lost; it lands in a fresh mailbox the next claim takes. The old read-whole GET +
// remove-whole ACK dropped exactly such an append. (Claim and append never interleave: both run under
// telMu (telephony_lock.go), which is what lets claimTelIngest read and then remove without the old rename-aside.)
func TestClaimTelIngestAtomicTake(t *testing.T) {
	old := telIngestBase
	telIngestBase = t.TempDir()
	t.Cleanup(func() { telIngestBase = old })

	if err := appendTelIngest("11", "", telItem{Kind: "sms", From: "+1", When: 1, Body: "a"}); err != nil {
		t.Fatal(err)
	}
	if err := appendTelIngest("11", "", telItem{Kind: "sms", From: "+2", When: 2, Body: "b"}); err != nil {
		t.Fatal(err)
	}

	b, err := claimTelIngest("11")
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n"); len(lines) != 2 {
		t.Fatalf("claim = %q, want both staged rows", b)
	}
	// the mailbox is now empty -- a second claim gets nothing (no double-take).
	if b2, err := claimTelIngest("11"); err != nil || len(b2) != 0 {
		t.Fatalf("second claim = %q (err %v), want empty", b2, err)
	}
	// an append AFTER the claim is NOT lost.
	if err := appendTelIngest("11", "", telItem{Kind: "sms", From: "+3", When: 3, Body: "c"}); err != nil {
		t.Fatal(err)
	}
	b3, err := claimTelIngest("11")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(b3), "sms 3 0 0 ") {
		t.Fatalf("append after claim was lost: %q", b3)
	}
}
