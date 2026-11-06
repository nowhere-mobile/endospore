package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Slice D (telephony_owner.go): the device-owner telephony inbox -- an unbound SIM's arrivals sealed to the
// device-owner key and read behind the owner passphrase, kept in RAM until the owner clears them or a reboot.

// useTempOwnerInbox points the owner store at a fresh temp dir.
func useTempOwnerInbox(t *testing.T) string {
	t.Helper()
	old := ownerInboxBase
	ownerInboxBase = filepath.Join(t.TempDir(), "owner")
	t.Cleanup(func() { ownerInboxBase = old })
	return ownerInboxBase
}

// mintOwnerKey sets up a temp owner key + temp owner inbox as the user-0 gate, mints the key (OWNER-KEY-ENSURE), and
// returns the owner private half so a test can open what it sealed.
func mintOwnerKey(t *testing.T) []byte {
	t.Helper()
	useTempOwnerKey(t)
	useTempOwnerInbox(t)
	asGate(t)
	if got := ensure(t, nil, ownerTestPass); got != "CREATED" {
		t.Fatalf("mint owner key: OWNER-KEY-ENSURE replied %q, want CREATED", got)
	}
	f, st, err := readOwnerKey()
	if err != nil || st != ownerKeyValid {
		t.Fatalf("owner key not valid after mint: st=%v err=%v", st, err)
	}
	priv, _, ok := ownerKeyOpen(f, []byte(ownerTestPass), nil)
	if !ok {
		t.Fatal("owner key did not open under the test passphrase")
	}
	return priv
}

func decodeOwnerRow(t *testing.T, b64 string) ownerInboxRow {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("inbox row not base64: %v (%q)", err, b64)
	}
	var r ownerInboxRow
	if err := json.Unmarshal(raw, &r); err != nil {
		t.Fatalf("inbox row not JSON: %v", err)
	}
	return r
}

func decodeOwnerItem(t *testing.T, b64 string) telItem {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("item not base64: %v", err)
	}
	var it telItem
	if err := json.Unmarshal(raw, &it); err != nil {
		t.Fatalf("item not JSON: %v", err)
	}
	return it
}

func openOwnerItem(t *testing.T, priv []byte, path string) telItem {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read sealed owner item: %v", err)
	}
	it, err := openTelItem(priv, string(b))
	if err != nil {
		t.Fatalf("owner item did not open with the owner key: %v", err)
	}
	return it
}

// TestSealUnboundNoKeyKeepsNothing: with no device-owner key (a device not verified since the key landed), an
// unbound arrival is an accepted loss -- NONE, nothing stored -- exactly the pre-slice behaviour.
func TestSealUnboundNoKeyKeepsNothing(t *testing.T) {
	useTempOwnerKey(t) // temp path, NOT minted -> absent key
	useTempOwnerInbox(t)
	reply, verdict := sealUnboundToOwner(&arrivalReq{verb: "SEAL-TEL", it: testSMS})
	if reply != "NONE\n" || verdict != telVerdictUnbound {
		t.Fatalf("no-key unbound = %q / %q, want NONE / telVerdictUnbound", reply, verdict)
	}
	if n := len(listOwnerSealed()); n != 0 {
		t.Fatalf("an item was kept with no owner key: %d", n)
	}
}

// TestSealUnboundToOwnerKeepsAndOpens: an SMS and a call to an unbound SIM each seal to the owner key and open back
// (full number and body) with the owner private half -- and NOT with a wrong key.
func TestSealUnboundToOwnerKeepsAndOpens(t *testing.T) {
	priv := mintOwnerKey(t)
	items := []telItem{
		{Kind: "sms", SubID: 2, From: "+15551230000", When: 7, Body: "hi owner"},
		{Kind: "call", SubID: 2, From: "+15551230001", When: 8, CallType: 3},
	}
	for _, it := range items {
		if reply, verdict := sealUnboundToOwner(&arrivalReq{verb: "SEAL-TEL", it: it}); reply != "OWNER\n" || verdict != telVerdictOwner {
			t.Fatalf("%s: reply %q / %q, want OWNER / telVerdictOwner", it.Kind, reply, verdict)
		}
	}
	paths := listOwnerSealed()
	if len(paths) != 2 {
		t.Fatalf("owner store holds %d items, want 2", len(paths))
	}
	kinds := map[string]telItem{}
	for _, p := range paths {
		it := openOwnerItem(t, priv, p)
		kinds[it.Kind] = it
	}
	if sms, ok := kinds["sms"]; !ok || sms.Body != "hi owner" || sms.From != "+15551230000" {
		t.Fatalf("owner sms = %+v", kinds["sms"])
	}
	if call, ok := kinds["call"]; !ok || call.CallType != 3 || call.From != "+15551230001" {
		t.Fatalf("owner call = %+v", kinds["call"])
	}
}

// TestSealUnboundMmsStrippedOverSoft: an MMS whose media crosses the owner soft line is kept without its media
// (sender, subject, time and note=too-large), so the owner still learns it arrived.
func TestSealUnboundMmsStrippedOverSoft(t *testing.T) {
	priv := mintOwnerKey(t)
	oldS, oldH := telOwnerBudgetSoft, telOwnerBudgetHard
	telOwnerBudgetSoft, telOwnerBudgetHard = 1<<10, 1<<20 // soft 1 KiB, hard 1 MiB
	t.Cleanup(func() { telOwnerBudgetSoft, telOwnerBudgetHard = oldS, oldH })

	it := telItem{Kind: "mms", SubID: 2, From: "+15559990000", When: 42, Subject: "trip",
		Parts: []mmsPart{{ContentType: "image/jpeg", Data: make([]byte, 8<<10)}}}
	if reply, verdict := sealUnboundToOwner(&arrivalReq{verb: "SEAL-MMS", it: it}); reply != "OWNER\n" || verdict != telVerdictOwner {
		t.Fatalf("stripped MMS reply %q / %q, want OWNER", reply, verdict)
	}
	paths := listOwnerSealed()
	if len(paths) != 1 {
		t.Fatalf("want 1 owner item, got %d", len(paths))
	}
	got := openOwnerItem(t, priv, paths[0])
	if len(got.Parts) != 0 || got.Subject != "trip" || got.From != "+15559990000" || got.Note != "too-large" {
		t.Fatalf("stripped owner MMS = %+v (want no parts, subject/from kept, note=too-large)", got)
	}
}

// TestSealUnboundOverHardIsFull: an item that would cross the owner hard line is not kept, and the reply is FULL so
// the gate posts the loss notice.
func TestSealUnboundOverHardIsFull(t *testing.T) {
	mintOwnerKey(t)
	oldS, oldH := telOwnerBudgetSoft, telOwnerBudgetHard
	telOwnerBudgetSoft, telOwnerBudgetHard = 1<<10, 2<<10 // soft 1 KiB, hard 2 KiB
	t.Cleanup(func() { telOwnerBudgetSoft, telOwnerBudgetHard = oldS, oldH })

	it := telItem{Kind: "sms", SubID: 2, From: "+1", When: 1, Body: strings.Repeat("x", 4096)}
	if reply, verdict := sealUnboundToOwner(&arrivalReq{verb: "SEAL-TEL", it: it}); reply != "FULL\n" || verdict != telVerdictOwnerFull {
		t.Fatalf("over-hard reply %q / %q, want FULL / telVerdictOwnerFull", reply, verdict)
	}
	if n := len(listOwnerSealed()); n != 0 {
		t.Fatalf("an over-hard item was kept: %d", n)
	}
}

// TestSealUnboundOversizeMmsKeptStripped: an MMS over the per-item cap, arriving on the owner line with the store
// near-empty (under the soft line), is kept STRIPPED — not dropped whole — so the owner still learns it came. Guards
// the review's P2: before the strip-first, such an item hit sealTelItem's over-cap error and returned FULL.
func TestSealUnboundOversizeMmsKeptStripped(t *testing.T) {
	priv := mintOwnerKey(t)
	it := telItem{Kind: "mms", SubID: 2, From: "+15557778888", When: 9, Subject: "big",
		Parts: []mmsPart{{ContentType: "image/jpeg", Data: make([]byte, maxTelItemBytes+1)}}}
	if reply, verdict := sealUnboundToOwner(&arrivalReq{verb: "SEAL-MMS", it: it}); reply != "OWNER\n" || verdict != telVerdictOwner {
		t.Fatalf("oversize owner MMS reply %q / %q, want OWNER (kept stripped)", reply, verdict)
	}
	paths := listOwnerSealed()
	if len(paths) != 1 {
		t.Fatalf("want 1 owner item, got %d", len(paths))
	}
	got := openOwnerItem(t, priv, paths[0])
	if len(got.Parts) != 0 || got.Subject != "big" || got.From != "+15557778888" || got.Note != "too-large" {
		t.Fatalf("oversize owner MMS = %+v (want stripped, subject/from kept, note=too-large)", got)
	}
}

// TestBoundInboxHardBudget: a bound seal whose buffer would cross the bound hard line is refused (errTelBoundFull),
// so a flood on a bound SIM whose owner is offline can never fill the shared state tmpfs.
func TestBoundInboxHardBudget(t *testing.T) {
	useTempInbox(t)
	old := telBoundBudgetHard
	telBoundBudgetHard = 256
	t.Cleanup(func() { telBoundBudgetHard = old })
	big := strings.Repeat("A", 512)
	if err := bufferSealed("refX", "", big); err != errTelBoundFull {
		t.Fatalf("over-budget bound buffer err = %v, want errTelBoundFull", err)
	}
	if n := len(listSealed("refX")); n != 0 {
		t.Fatalf("an over-budget bound item was written: %d", n)
	}
	// Under budget it writes as before.
	if err := bufferSealed("refX", "", "small"); err != nil {
		t.Fatalf("under-budget bound buffer err = %v, want nil", err)
	}
	if n := len(listSealed("refX")); n != 1 {
		t.Fatalf("under-budget bound item count = %d, want 1", n)
	}
}

// TestOwnerInboxListReadDeleteClear drives the four verbs over handleLogin: list returns a row per sealed item with
// an MMS's media replaced by a part count; read returns the full item; a wrong passphrase is NONE; delete and clear
// remove.
func TestOwnerInboxListReadDeleteClear(t *testing.T) {
	mintOwnerKey(t) // asGate, temp key + temp owner inbox, key minted
	sealUnboundToOwner(&arrivalReq{verb: "SEAL-TEL", it: telItem{Kind: "sms", SubID: 2, From: "+15551112222", When: 100, Body: "first"}})
	sealUnboundToOwner(&arrivalReq{verb: "SEAL-MMS", it: telItem{Kind: "mms", SubID: 2, From: "+15553334444", When: 200, Subject: "pics",
		Parts: []mmsPart{{ContentType: "text/plain", Data: []byte("hello")}, {ContentType: "image/jpeg", Data: []byte{1, 2, 3, 4}}}}})

	// LIST, correct passphrase.
	reply := driveLogin(t, t.TempDir(), ownerReq("GET-OWNER-INBOX", nil, ownerTestPass))
	lines := strings.Split(reply, "\n")
	if lines[0] != "OK" {
		t.Fatalf("LIST head = %q (full %q)", lines[0], reply)
	}
	var mmsID, smsID string
	nrows := 0
	for _, l := range lines[1:] {
		if l == "" {
			continue
		}
		nrows++
		r := decodeOwnerRow(t, l)
		switch r.Kind {
		case "mms":
			if r.NParts != 2 || r.Subject != "pics" || r.From != "+15553334444" {
				t.Fatalf("mms row = %+v", r)
			}
			mmsID = r.ID
		case "sms":
			if r.Body != "first" || r.From != "+15551112222" {
				t.Fatalf("sms row = %+v", r)
			}
			smsID = r.ID
		}
	}
	if nrows != 2 || mmsID == "" || smsID == "" {
		t.Fatalf("LIST rows=%d mmsID=%q smsID=%q", nrows, mmsID, smsID)
	}

	// READ the MMS -> the full item, media included.
	rreply := driveLogin(t, t.TempDir(), ownerReq("READ-OWNER-ITEM", nil, ownerTestPass)+mmsID+"\n")
	rlines := strings.Split(rreply, "\n")
	if rlines[0] != "OK" || len(rlines) < 2 {
		t.Fatalf("READ reply = %q", rreply)
	}
	full := decodeOwnerItem(t, rlines[1])
	if full.Kind != "mms" || len(full.Parts) != 2 || string(full.Parts[1].Data) != string([]byte{1, 2, 3, 4}) {
		t.Fatalf("READ item = %+v", full)
	}

	// Wrong passphrase: NONE, indistinguishable from an empty inbox.
	if got := driveLogin(t, t.TempDir(), ownerReq("GET-OWNER-INBOX", nil, "wrong-passphrase")); strings.TrimSpace(got) != "NONE" {
		t.Fatalf("LIST with wrong pass = %q, want NONE", got)
	}

	// DELETE the MMS.
	if got := driveLogin(t, t.TempDir(), "DELETE-OWNER-ITEM\n"+mmsID+"\n"); strings.TrimSpace(got) != "OK" {
		t.Fatalf("DELETE = %q, want OK", got)
	}
	if n := len(listOwnerSealed()); n != 1 {
		t.Fatalf("after delete, %d items, want 1", n)
	}

	// CLEAR the rest.
	if got := driveLogin(t, t.TempDir(), "CLEAR-OWNER-INBOX\n"); strings.TrimSpace(got) != "OK" {
		t.Fatalf("CLEAR = %q, want OK", got)
	}
	if n := len(listOwnerSealed()); n != 0 {
		t.Fatalf("after clear, %d items, want 0", n)
	}
}

// TestOwnerInboxRejectsNonItemIDs: the item id the DELETE and READ verbs take is the only thing between a gate caller
// and an arbitrary "<id>.seal" path, so anything but 16 lowercase hex is refused (DELETE: ERR request, READ: NONE)
// and nothing outside the inbox is removed or opened. The sentinels are named with hex ("abcd") so a regex widened to
// admit "." and "/" would actually reach them, and the READ one is a real item sealed under the owner key so a READ
// that escaped the inbox would answer OK rather than NONE for want of a blob that opens.
func TestOwnerInboxRejectsNonItemIDs(t *testing.T) {
	mintOwnerKey(t)
	sealUnboundToOwner(&arrivalReq{verb: "SEAL-TEL", it: telItem{Kind: "sms", SubID: 2, From: "+15551112222", When: 100, Body: "inside"}})
	inside := listOwnerSealed()
	if len(inside) != 1 {
		t.Fatalf("sealed %d items, want 1", len(inside))
	}
	blob, err := os.ReadFile(inside[0])
	if err != nil {
		t.Fatal(err)
	}
	parent := filepath.Dir(ownerInboxBase)
	readSentinel := filepath.Join(parent, "abcd.seal")
	sibSentinel := filepath.Join(parent, "sib", "abcd.seal")
	if err := os.MkdirAll(filepath.Dir(sibSentinel), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{readSentinel, sibSentinel} {
		if err := os.WriteFile(p, blob, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	for _, id := range []string{"../abcd", "../sib/abcd", "..", "ABCDEF0123456789", "0123456789abcde", "0123456789abcdef0", ""} {
		if got := driveLogin(t, t.TempDir(), "DELETE-OWNER-ITEM\n"+id+"\n"); strings.TrimSpace(got) != "ERR request" {
			t.Fatalf("DELETE %q = %q, want ERR request", id, got)
		}
		if got := driveLogin(t, t.TempDir(), ownerReq("READ-OWNER-ITEM", nil, ownerTestPass)+id+"\n"); strings.TrimSpace(got) != "NONE" {
			t.Fatalf("READ %q = %q, want NONE", id, got)
		}
		for _, p := range []string{readSentinel, sibSentinel, inside[0]} {
			if _, err := os.Stat(p); err != nil {
				t.Fatalf("after id %q, %s is gone: %v", id, p, err)
			}
		}
	}
}

// TestOwnerInboxRefusesNonGate: every owner-inbox verb is DENIED to any caller but the user-0 gate, before the
// request is read, whether or not the inbox holds anything.
func TestOwnerInboxRefusesNonGate(t *testing.T) {
	mintOwnerKey(t)
	sealUnboundToOwner(&arrivalReq{verb: "SEAL-TEL", it: testSMS})
	asCaller(t, 10999, 10123) // a caller whose appId is not the pinned gate chooser's
	for _, req := range []string{
		ownerReq("GET-OWNER-INBOX", nil, ownerTestPass),
		ownerReq("READ-OWNER-ITEM", nil, ownerTestPass) + "0000000000000000\n",
		"DELETE-OWNER-ITEM\n0000000000000000\n",
		"CLEAR-OWNER-INBOX\n",
	} {
		if got := driveLogin(t, t.TempDir(), req); strings.TrimSpace(got) != "DENIED" {
			t.Fatalf("non-gate %q = %q, want DENIED", strings.SplitN(req, "\n", 2)[0], got)
		}
	}
	// And a non-gate caller did not remove anything.
	if n := len(listOwnerSealed()); n != 1 {
		t.Fatalf("non-gate caller changed the store: %d items, want 1", n)
	}
}

// TestV2UnboundSealsToOwner drives the whole v2 wire: an unbound-SIM arrival with an owner key present replies OWNER
// and seals one openable item, and a retry of the same arrival id replays OWNER without sealing a second copy.
func TestV2UnboundSealsToOwner(t *testing.T) {
	useTempInbox(t)
	useArrivalState(t) // an empty replay table, isolated from other tests'
	useTempBindings(t) // no bindings -> the SIM is unbound
	priv := mintOwnerKey(t)

	req := v2Tel(arrivalID(9001), "sms", 2, "89990000000000000000", "+15551239999", late, "secret body")
	if got := driveLogin(t, t.TempDir(), req); got != "OWNER" {
		t.Fatalf("unbound v2 arrival with an owner key = %q, want OWNER", got)
	}
	paths := listOwnerSealed()
	if len(paths) != 1 {
		t.Fatalf("owner store holds %d, want 1", len(paths))
	}
	if it := openOwnerItem(t, priv, paths[0]); it.Body != "secret body" || it.From != "+15551239999" || it.SubID != 2 {
		t.Fatalf("sealed owner item = %+v", it)
	}
	// A retry replays OWNER and does not double-seal.
	if got := driveLogin(t, t.TempDir(), req); got != "OWNER" {
		t.Fatalf("retry = %q, want OWNER (replayed)", got)
	}
	if n := len(listOwnerSealed()); n != 1 {
		t.Fatalf("retry double-sealed: %d items, want 1", n)
	}
}

func TestOwnerInboxCmdPredicate(t *testing.T) {
	for _, v := range []string{"GET-OWNER-INBOX", "READ-OWNER-ITEM", "DELETE-OWNER-ITEM", "CLEAR-OWNER-INBOX"} {
		if !ownerInboxCmd(v) {
			t.Fatalf("%q should be an owner-inbox verb", v)
		}
	}
	for _, v := range []string{"GET-BINDINGS", "OWNER-KEY-NEW", "SEAL-TEL", "LOGIN", ""} {
		if ownerInboxCmd(v) {
			t.Fatalf("%q should not be an owner-inbox verb", v)
		}
	}
}
