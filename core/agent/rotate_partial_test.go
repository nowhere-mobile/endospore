package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// capStoreLeasePresent is injected into every lease reply mockCapStore sends, so a test can make the
// gateway claim it already holds a key. Reset for every store mockCapStore builds.
var capStoreLeasePresent []string

var errTestStoreRefused = errors.New("the store refused this write")

// TestAPartialRetireKeepsTheNewKeyguardAndSaysSo: once capFlush has begun retiring, the rotation has
// COMMITTED -- the new head is published and its ETag verified -- and everything the failure path used
// to do is wrong in the same direction.
//
// It rolled the keyguard back to the old passphrase, aiming the lockscreen at a credential the store has
// retired. It left .roamsession naming that same dead credential, so the periodic sync and the logoff
// capture publish to a ref that no longer resolves. And every reply code it could reach renders in the
// chooser as some form of "your passphrase has not changed", so the user is told to keep using a
// passphrase that opens nothing -- and the next thing that copy tells them to do is sign out, which is
// exactly when the capture runs.
func TestAPartialRetireKeepsTheNewKeyguardAndSaysSo(t *testing.T) {
	rb := s3RetryBase
	s3RetryBase = time.Millisecond // the failing PUT exhausts the retry ladder; do not sleep through it
	t.Cleanup(func() { s3RetryBase = rb })

	dest := capRotateFixture(t)
	calls := stubRekey(t, "OK")
	const name, oldp, newp = "partialrot", "horse battery staple correct", "a completely different passphrase"
	if createVault("s3", name, oldp) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	// A sealed session, so there is a restore RECEIPT to carry. Without one there is nothing to migrate
	// and the assertion below would pass on any implementation -- migrateRestoreReceipts MOVES a receipt
	// and never mints one, which is load-bearing elsewhere (#72).
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, oldp, d)
	if !haveRestoreReceipt(profileRefV2(name, oldp)) {
		t.Fatal("precondition: the seal left no restore receipt to migrate")
	}
	liveMarker(t, dest, name, oldp, "10", "")

	// Take every publish, then refuse the FIRST retirement: the exact shape the two-pass flush creates.
	// Pick the first retirement as the victim and refuse THAT KEY every time. Failing it once is not
	// enough: capPut runs the write through retryStore, so a single 500 is retried and succeeds, and the
	// rotation completes normally -- which is what a first draft of this test measured.
	victim := ""
	capStorePutHook = func(key string, body []byte) error {
		if victim == "" && strings.HasPrefix(key, "ref/") && len(body) == 0 {
			victim = key
		}
		if key == victim {
			return errTestStoreRefused
		}
		return nil
	}
	got := rotateVerb(t, dest, name, oldp, newp)
	capStorePutHook = nil
	if victim == "" {
		t.Fatal("precondition: no retirement was ever attempted, so this test proved nothing")
	}

	if got != "ERR-SESSION" {
		t.Errorf("a partially-committed rotation replied %q. Every other code the chooser renders here "+
			"claims the passphrase did not change, and it did -- the new head is published and the old "+
			"credential is being retired. ERR-SESSION is the one that tells the truth.", got)
	}
	if len(*calls) != 1 {
		t.Errorf("the keyguard was re-keyed %d times, want 1. A rollback here points the lockscreen at "+
			"the passphrase the store just retired: %v", len(*calls), *calls)
	}
	marker, err := os.ReadFile(filepath.Join(dest, ".roamsession"))
	if err != nil {
		t.Fatalf("reading the session marker: %v", err)
	}
	if lines := strings.Split(string(marker), "\n"); len(lines) < 2 || lines[1] != newp {
		t.Errorf("the session marker still carries %q, want the NEW passphrase. Its seals -- the periodic "+
			"sync and the logoff capture above all -- would publish to a ref the store has retired.", lines[1])
	}
	if _, _, ok := resolveKey("s3", name, newp); !ok {
		t.Error("the new passphrase does not open the profile, so ERR-SESSION's advice would strand the user")
	}
	// ⚠ AND THE RECEIPT HAS TO FOLLOW TOO. The migration normally runs after the bracket, which a
	// store failure in the retire pass PANICS straight past. Without it this session holds a receipt filed
	// under the retired credential, so its next seal -- the logoff capture, which is precisely what
	// ERR-SESSION tells the user to go and do -- is refused for want of one at the new ref.
	if !haveRestoreReceipt(profileRefV2(name, newp)) {
		t.Error("the session's restore receipt did not follow the rotation. Its next seal will be refused " +
			"for want of a receipt at the new ref, and the seal it will be refused on is the logoff capture.")
	}
}

// TestAScopeThatCannotBeRePointedPublishesNothing: rotateVault's re-point failure says it aborts the
// bracket, and until NWP-20260915-14 it did not.
//
// ⚠ capWrite is begin / defer abort / fn / FLUSH. A bare `return` out of the closure is a NORMAL
// return, so capFlush ran and published every scope head buffered before the failure, and the deferred
// capAbort was a no-op because capFlush had already nil-ed the bracket. The comment on that line said the
// opposite. It mattered little while the path was gated behind an index no fielded profile carries; this
// slice removes that gate, so the refusal is now reachable on any rotation.
func TestAScopeThatCannotBeRePointedPublishesNothing(t *testing.T) {
	dest := capRotateFixture(t)
	_ = dest
	const name, oldp, newp = "abortrot", "horse battery staple correct", "a completely different passphrase"
	if createVault("s3", name, oldp) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	// Two scopes that CAN be re-pointed, so there is something buffered to leak...
	for _, suf := range []string{"#de", "#media"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile("s3", name+suf, oldp, d)
	}
	// ...and one that cannot: #sys sorts AFTER both, and a tombstone there is the loud refusal.
	//
	// ⚠ #sys IS SEALED FIRST NOW, AND THAT IS A CORRECTION TO THIS FIXTURE (NWP-20260915-18). It used to
	// tombstone a scope that had NEVER been sealed, because that was the cheapest way to produce an
	// empty-but-present ref. But a tombstone on a scope nobody ever wrote is not a loss of anything -- it is
	// precisely the shape a deleted-and-re-created profile carries on all six suffixes, and refusing on it is
	// the bug -18 exists to remove. The refusal this test is about needs a scope that really HAD data, so the
	// fixture now gives #sys data and then takes it away. The ordering property being tested is untouched:
	// #sys still sorts after #de and #media.
	//
	// The extra bare push after it is the observation cycle -- see sealScopeFixture for why one is needed.
	sd := t.TempDir()
	if err := os.WriteFile(filepath.Join(sd, "f.txt"), []byte("payload#sys"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name+"#sys", oldp, sd)
	bd := t.TempDir()
	if err := os.WriteFile(filepath.Join(bd, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, oldp, bd)
	delRef("s3", profileRefV2(name+"#sys", oldp), "", nil)
	if !refExists("s3", profileRefV2(name+"#sys", oldp)) {
		t.Fatal("FIXTURE BROKE: the #sys scope is not present after it was tombstoned -- this backend keeps an empty ref present (newHTTPStore stores \"\"; delRef writes an empty object), so the fixture no longer reaches the state under test")
	}

	if _, err := rotateVault("s3", name, oldp, newp, nil, true); !errors.Is(err, ErrScopeTombstoned) {
		t.Fatalf("rotateVault returned %v, want ErrScopeTombstoned -- without the refusal this test "+
			"proves nothing", err)
	}
	for _, suf := range []string{"#de", "#media"} {
		ref, _ := headWriteRef(name+suf, newp)
		if getRef("s3", ref) != "" {
			t.Errorf("the refused rotation PUBLISHED %s at the new credential. The bracket was supposed to "+
				"be discarded, so a rotation that refuses leaves the store exactly as it found it; instead it "+
				"leaves paid, leased objects that nothing names and no delete of this profile will reach.", suf)
		}
	}
	if _, _, ok := resolveKey("s3", name, oldp); !ok {
		t.Error("after a refused rotation the old passphrase must still open the profile")
	}
}

// TestAPointerTheGatewayCallsPresentIsNeverSkipped: put() skips any key the lease reported as already
// present, justified by "the key IS the hash of these bytes". That is true of a blob and FALSE of a ref,
// whose key is an HMAC of the credential and whose value is mutable.
//
// ⚠ THE INVARIANT THAT SAVES IT LIVES IN THE OTHER REPO -- the gateway filters Present to blob/ only.
// NWP-20260915-14 makes the client depend on it twice: the retire pass runs precisely because the publish
// pass finished with no refusal, and a silently skipped head is neither a refusal nor a panic. It would
// retire the old credential behind a head that was never written, which is the failure this slice exists
// to remove, re-entered through an assumption about somebody else's code.
func TestAPointerTheGatewayCallsPresentIsNeverSkipped(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}
	const name, pass = "presentref", "horse battery staple correct"
	capStoreLeasePresent = []string{"ref/" + profileRefV2(name, pass)}

	err := recovered(func() { createVault("s3", name, pass) })
	if err == nil {
		t.Fatal("the flush accepted a gateway that listed a POINTER as already present. It skipped the " +
			"write and reported success, so the head was never stored -- and a rotation would go on to " +
			"retire the old credential behind it.")
	}
	if !strings.Contains(err.Error(), "present") {
		t.Errorf("the flush failed with %v, which does not name the cause. A refusal nobody can diagnose "+
			"is how a cross-repo assumption stays invisible.", err)
	}
}
