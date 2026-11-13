package main

// NWP-20261201-11: two phones sign in before a profile's #media scope has a head. Each holds the roster `none` and no
// restore receipt. Once the first seal creates the head, the second phone's seal may pass the no-receipt gate only when
// the carry folds the stored head in. Any other session without a receipt is refused, and before the walk where it can be.

import (
	"os"
	"path/filepath"
	"testing"
)

const noHeadReceiptPass = "no head receipt horse staple"

// noHeadReceiptPair is two handsets on one recording store, both signed in while the #media scope has no head, with A's
// first seal landed. It returns B's view of the head that seal made.
func noHeadReceiptPair(t *testing.T, name string) (rs *recordingStore, a, b *handset, head string) {
	t.Helper()
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	resetSealCaches()
	rs = newRecordingStore(t)
	createVault(rs.URL, name, noHeadReceiptPass)
	a, b = newHandset(t, rs.URL, name, noHeadReceiptPass), newHandset(t, rs.URL, name, noHeadReceiptPass)
	if !signInNoHead(a) || !signInNoHead(b) {
		t.Fatal("setup: a sign-in to a scope with no head recorded no roster")
	}
	a.put("DCIM/a.jpg", "the first photo")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup: A's first seal: %s", msg)
	}
	head = b.head("#media")
	if head == "" {
		t.Fatal("setup: A's first seal left no head")
	}
	return rs, a, b, head
}

// putLarge gives B a file of fresh random bytes, so a push that reaches the walk has something to upload.
func putLarge(t *testing.T, b *handset) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(b.work, "DCIM"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeRandom(t, b.work, "DCIM/big.bin", 2<<20)
}

func TestNoHeadReceipt_TheSecondPhoneSealsWhenTheCarryFoldsTheHeadIn(t *testing.T) {
	_, _, b, _ := noHeadReceiptPair(t, "nhr-pass")
	b.put("DCIM/from-b.jpg", "a photo from the second phone")
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s (why=%q)", msg, sealRefusedWhy)
	}
	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	for _, rel := range []string{"DCIM/a.jpg", "DCIM/from-b.jpg"} {
		if _, ok := m.Ess[rel]; !ok {
			t.Fatalf("the head does not index %s (head indexes %v)", rel, keysOfEss(m.Ess))
		}
	}
	b.put("DCIM/from-b-2.jpg", "a later photo")
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's second seal: %s (why=%q)", msg, sealRefusedWhy)
	}
}

func TestNoHeadReceipt_WithoutTheCarryTheSecondPhoneIsStillRefused(t *testing.T) {
	_, _, b, head := noHeadReceiptPair(t, "nhr-nocarry")
	b.put("DCIM/from-b.jpg", "a photo from the second phone")
	t.Setenv("NOWHERE_SEAL_FULL", "1") // a whole-tree seal has no per-file spans, so the carry declines
	sealRefusedWhy = ""
	if msg := b.seal("#media"); msg == "" || sealRefusedWhy != "no-receipt" {
		t.Fatalf("seal=%q why=%q, want refused as no-receipt", msg, sealRefusedWhy)
	}
	if got := b.head("#media"); got != head {
		t.Fatalf("the head moved from %s to %s: the refusal did not protect A's seal", head, got)
	}
}

func TestNoHeadReceipt_ARealRosterWithoutAReceiptIsRefusedBeforeTheWalk(t *testing.T) {
	rs, _, b, head := noHeadReceiptPair(t, "nhr-roster")
	ref := profileRefV2(b.name+"#media", b.pass)
	b.as(func() { writeLoginRoster(ref, head) }) // a restore that named this head and never completed
	putLarge(t, b)
	rs.mark()
	sealRefusedWhy = ""
	if msg := b.seal("#media"); msg == "" || sealRefusedWhy != "no-receipt" {
		t.Fatalf("seal=%q why=%q, want refused as no-receipt", msg, sealRefusedWhy)
	}
	rs.assertNothingSpent(t, "a real roster without a receipt")
}

func TestNoHeadReceipt_CarryOffRefusesBeforeTheWalk(t *testing.T) {
	rs, _, b, _ := noHeadReceiptPair(t, "nhr-carryoff")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "")
	putLarge(t, b)
	rs.mark()
	sealRefusedWhy = ""
	if msg := b.seal("#media"); msg == "" || sealRefusedWhy != "no-receipt" {
		t.Fatalf("seal=%q why=%q, want refused as no-receipt", msg, sealRefusedWhy)
	}
	rs.assertNothingSpent(t, "carry off")
}
