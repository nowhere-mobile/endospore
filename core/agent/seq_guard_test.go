package main

// NWP-20260907-13: the SEQUENTIAL two-handset overwrite -- the shape expectRef structurally cannot see.
//
// expectRef samples the head at the START of a push and compares at the PUT, so it catches a head that
// moved DURING a seal: a window of about one round trip. The common two-handset failure is sequential --
// B restored an hour ago, A has sealed since, and B now publishes content derived from a base that is no
// longer current. Nothing moves during B's push, so got == want and it goes straight over A.
//
// The restore receipt already holds the head this session last knew (restored at login, or written by its
// own last seal), so comparing it to the head just read names exactly that divergence.

import (
	"os"
	"path/filepath"
	"testing"
)

// withReceipts points the receipt dir at a temp state dir. Receipts are inert without NOWHERE_STATE, which
// is why the whole mechanism is a no-op for the host CLI and for every other test in this package.
func withReceipts(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
}

func TestSeqGuard_ReceiptHeadRoundTrips(t *testing.T) {
	withReceipts(t)
	const ref = "abc123"
	if got := restoreReceiptHead(ref); got != "" {
		t.Fatalf("a ref with no receipt returned %q, want empty", got)
	}
	writeRestoreReceipt(ref, "deadbeef")
	if got := restoreReceiptHead(ref); got != "deadbeef" {
		t.Fatalf("receipt head = %q, want deadbeef -- the comparison has nothing to compare", got)
	}
}

// THE FAILURE MODE THE WHOLE MECHANISM MUST NOT HAVE. If a head write could MINT a receipt, a session
// whose restore FAILED would acquire the very certificate #72 exists to withhold, and the guard that stops
// a 46%-complete restore from destroying 2.8 GB would be silently disarmed. Update only.
func TestSeqGuard_AHeadWriteNeverMintsAReceipt(t *testing.T) {
	withReceipts(t)
	const name, pass = "mintcheck", "correct horse battery staple"
	ref := profileRefV2(name, pass)

	reanchorReceipt(name, pass, "somehead")
	if haveRestoreReceipt(ref) {
		t.Fatal("a head write MINTED a restore receipt. A session whose restore failed would now pass the " +
			"#72 existence gate, and a partial restore could overwrite good data -- the exact data loss " +
			"that guard was built for.")
	}
}

// ...but it must UPDATE one, or a local head write (enrol, revoke, rotate, PIN, repoint -- fifteen sites)
// would leave the receipt stale and the guard would refuse this device's own next seal, forever.
func TestSeqGuard_AHeadWriteReanchorsAnExistingReceipt(t *testing.T) {
	withReceipts(t)
	const name, pass = "reanchor", "correct horse battery staple"
	ref := profileRefV2(name, pass)

	writeRestoreReceipt(ref, "head-at-login")
	reanchorReceipt(name, pass, "head-after-a-keyslot-change")

	if got := restoreReceiptHead(ref); got != "head-after-a-keyslot-change" {
		t.Fatalf("receipt still reads %q after this device wrote a new head. Every later seal would be "+
			"refused against a head this device itself established -- a permanently wedged session, which "+
			"is worse than the overwrite this guard exists to stop.", got)
	}
}

// An empty head must not clobber a good receipt: putHead is called on paths that can carry "" and losing
// the anchor would either wedge the session or silently disable the check.
func TestSeqGuard_AnEmptyHeadDoesNotClobberTheAnchor(t *testing.T) {
	withReceipts(t)
	const name, pass = "emptyhead", "correct horse battery staple"
	ref := profileRefV2(name, pass)

	writeRestoreReceipt(ref, "good-head")
	reanchorReceipt(name, pass, "")
	if got := restoreReceiptHead(ref); got != "good-head" {
		t.Fatalf("an empty head overwrote the anchor (now %q)", got)
	}
}

// The refusal is OFF by default. Detection always runs and always logs; only the refusal is gated, because
// choosing WHICH handset loses its session is a product decision and multi-device has never been one.
func TestSeqGuard_TheRefusalIsOffByDefault(t *testing.T) {
	if seqGuardEnabled() {
		t.Fatal("NOWHERE_SEQ_GUARD defaulted ON. Turning it on decides that the diverged handset loses its " +
			"unsealed session, which is almost certainly right and is still not mine to decide.")
	}
	t.Setenv("NOWHERE_SEQ_GUARD", "1")
	if !seqGuardEnabled() {
		t.Fatal("NOWHERE_SEQ_GUARD=1 did not enable the refusal, so the flag cannot be exercised on device")
	}
}

// Receipts are per-BOOT RAM state. Off-device there is no state dir, so the whole mechanism -- existence
// gate, head comparison and re-anchor alike -- must stay inert, or every host CLI use and every other test
// in this package changes behaviour.
func TestSeqGuard_InertWithoutAStateDir(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "")
	if restoreReceiptDir() != "" {
		t.Fatal("receipts are active with no NOWHERE_STATE")
	}
	if got := restoreReceiptHead("anyref"); got != "" {
		t.Fatalf("restoreReceiptHead returned %q off-device, want empty", got)
	}
	reanchorReceipt("n", "p", "h") // must not panic or write anything
}

// A receipt written before this field existed reads as empty, and an empty anchor must SKIP the comparison
// rather than refuse -- otherwise the first seal after an upgrade would be refused on every device.
func TestSeqGuard_AnOlderReceiptWithNoHeadIsNotTreatedAsStale(t *testing.T) {
	withReceipts(t)
	const ref = "oldstyle"
	d := restoreReceiptDir()
	if err := os.MkdirAll(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, ref), []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := restoreReceiptHead(ref); got != "" {
		t.Fatalf("a headless receipt read as %q; the caller must see empty and skip the comparison", got)
	}
	if !haveRestoreReceipt(ref) {
		t.Fatal("a headless receipt must still satisfy the #72 existence gate")
	}
}
