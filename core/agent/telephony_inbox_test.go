package main

import (
	"crypto/rand"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// useTempInbox points telInboxBase at a temp dir for the duration of a test.
func useTempInbox(t *testing.T) {
	t.Helper()
	old := telInboxBase
	telInboxBase = t.TempDir()
	t.Cleanup(func() { telInboxBase = old })
}

// readTelInboxItems is readTelInbox without the opened paths, for tests that only care what was sealed.
func readTelInboxItems(v *vault, dk []byte, profileRef string) []telItem {
	items, _ := readTelInbox(v, dk, profileRef)
	return items
}

// vaultWithTelKey builds a bare vault with a fresh telephony keypair and returns it with its DK.
func vaultWithTelKey(t *testing.T) (*vault, []byte) {
	t.Helper()
	dk := make([]byte, 32)
	if _, err := rand.Read(dk); err != nil {
		t.Fatalf("rand: %v", err)
	}
	v := &vault{}
	ensureTelephonyKeypair(v, dk)
	if v.TelPub == "" || v.TelPriv == "" {
		t.Fatal("ensureTelephonyKeypair did not set the keypair")
	}
	return v, dk
}

func TestEnsureKeypairStableAndOpenable(t *testing.T) {
	v, dk := vaultWithTelKey(t)
	pub, priv := v.TelPub, v.TelPriv
	// Idempotent: a second ensure must NOT rotate the key (would orphan a published pubkey).
	ensureTelephonyKeypair(v, dk)
	if v.TelPub != pub || v.TelPriv != priv {
		t.Fatal("ensureTelephonyKeypair rotated an existing keypair")
	}
	if p := telephonyPriv(v, dk); len(p) != x25519KeyLen {
		t.Fatalf("telephonyPriv len = %d, want %d", len(p), x25519KeyLen)
	}
	// Wrong DK must not open the private key.
	other := make([]byte, 32)
	rand.Read(other)
	if telephonyPriv(v, other) != nil {
		t.Fatal("telephonyPriv opened with the wrong DK")
	}
}

func TestBufferAndListSealed(t *testing.T) {
	useTempInbox(t)
	const ref = "reftest"
	if got := listSealed(ref); got != nil {
		t.Fatalf("empty inbox should list nothing, got %v", got)
	}
	for i := 0; i < 3; i++ {
		if err := bufferSealed(ref, "", "blob"); err != nil {
			t.Fatalf("bufferSealed: %v", err)
		}
	}
	if got := listSealed(ref); len(got) != 3 {
		t.Fatalf("listSealed = %d, want 3", len(got))
	}
}

func TestListSealedIgnoresDotfilesAndOthers(t *testing.T) {
	useTempInbox(t)
	const ref = "reftest"
	dir := telInboxDir(ref)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, ".inflight.seal"), []byte("x"), 0o600) // dotfile temp
	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0o600)      // non-.seal
	os.WriteFile(filepath.Join(dir, "good.seal"), []byte("x"), 0o600)      // counts
	if got := listSealed(ref); len(got) != 1 {
		t.Fatalf("listSealed = %d, want 1 (only good.seal)", len(got))
	}
}

func TestSealItemToInboxThenIngest(t *testing.T) {
	useTempInbox(t)
	v, dk := vaultWithTelKey(t)
	const ref = "reftest"
	want := []telItem{
		{Kind: "sms", SubID: 1, From: "+15551110001", When: 1000, Body: "one"},
		{Kind: "call", SubID: 1, From: "+15551110002", When: 2000, CallType: 1, DurSec: 5},
		{Kind: "sms", SubID: 2, From: "+15551110003", When: 3000, Body: "three"},
	}
	for _, it := range want {
		if err := sealItemToInbox(ref, v.TelPub, "", it); err != nil {
			t.Fatalf("sealItemToInbox: %v", err)
		}
	}
	got, opened := readTelInbox(v, dk, ref)
	if len(got) != len(want) || len(opened) != len(want) {
		t.Fatalf("read returned %d items / %d opened, want %d", len(got), len(opened), len(want))
	}
	// Filenames are random, so compare as a set keyed by When.
	byWhen := map[int64]telItem{}
	for _, it := range got {
		byWhen[it.When] = it
	}
	for _, w := range want {
		if !reflect.DeepEqual(byWhen[w.When], w) {
			t.Fatalf("missing/mismatched item for When=%d: got %+v", w.When, byWhen[w.When])
		}
	}
	// NWP-20260924-04: reading removes NOTHING -- a sealed record goes only once its hand-off is written.
	if l := listSealed(ref); len(l) != len(want) {
		t.Fatalf("readTelInbox removed sealed blobs before any hand-off: %d left, want %d", len(l), len(want))
	}
	dropSealed(opened)
	if l := listSealed(ref); l != nil {
		t.Fatalf("dropSealed left %v", l)
	}
}

// TestIngestSkipsCorruptBlob: a corrupt blob is skipped and LEFT (NWP-20260924-04) -- it can never be
// delivered, so nothing may claim to have handed it off; it is ciphertext on the tmpfs and the reboot takes it.
func TestIngestSkipsCorruptBlob(t *testing.T) {
	useTempInbox(t)
	v, dk := vaultWithTelKey(t)
	const ref = "reftest"
	if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: 42, Body: "ok"}); err != nil {
		t.Fatal(err)
	}
	// Drop a garbage .seal alongside the valid one.
	os.WriteFile(filepath.Join(telInboxDir(ref), "garbage.seal"), []byte("!!!not-a-sealed-box!!!"), 0o600)
	got, opened := readTelInbox(v, dk, ref)
	if len(got) != 1 || got[0].When != 42 || len(opened) != 1 {
		t.Fatalf("read should recover exactly the 1 valid item, got %+v (opened %v)", got, opened)
	}
	dropSealed(opened)
	l := listSealed(ref)
	if len(l) != 1 || filepath.Base(l[0]) != "garbage.seal" {
		t.Fatalf("after dropping the delivered blob, only the corrupt one must remain, got %v", l)
	}
}

// TestIngestWrongKeyRecoversNothingAndKeeps: a blob sealed to another key opens nothing and stays
// (NWP-20260924-04; it used to be cleared "amnesia-first", before anything had been delivered).
func TestIngestWrongKeyRecoversNothingAndKeeps(t *testing.T) {
	useTempInbox(t)
	sender, _ := vaultWithTelKey(t)   // sealed to THIS profile's pubkey
	reader, rdk := vaultWithTelKey(t) // a DIFFERENT profile tries to ingest
	const ref = "reftest"
	if err := sealItemToInbox(ref, sender.TelPub, "", telItem{Kind: "sms", When: 7, Body: "secret"}); err != nil {
		t.Fatal(err)
	}
	got, opened := readTelInbox(reader, rdk, ref)
	if len(got) != 0 || len(opened) != 0 {
		t.Fatalf("wrong key must recover nothing, got %+v (opened %v)", got, opened)
	}
	if l := listSealed(ref); len(l) != 1 {
		t.Fatalf("a blob that could not be opened must be left, got %v", l)
	}
}

func TestIngestNoKeypairIsNoop(t *testing.T) {
	useTempInbox(t)
	const ref = "reftest"
	// Buffer something, then ingest with a vault that has NO telephony key.
	bufferSealed(ref, "", "blob")
	got, opened := readTelInbox(&vault{}, make([]byte, 32), ref)
	if got != nil || opened != nil {
		t.Fatalf("no-keypair read should return nil, got %+v (opened %v)", got, opened)
	}
	// It must NOT clear (no key to deliver -> leave for a key-bearing login / reboot).
	if l := listSealed(ref); len(l) != 1 {
		t.Fatalf("no-keypair ingest should not clear the buffer, got %v", l)
	}
}
