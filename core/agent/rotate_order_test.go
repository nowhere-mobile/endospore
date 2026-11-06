package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// capStorePutHook, when non-nil, is called by mockCapStore for every object PUT, in arrival order, BEFORE
// the object is stored. Returning an error makes the store answer 500, which is how a test drives a
// transient store refusal partway through a flush. Reset by mockCapStore for every store it builds.
var capStorePutHook func(key string, body []byte) error

// rotateFixture stands up a funded cap-mode profile with one sealed scope. The sealed scope is the point:
// it puts re-pointed scope heads in the same pointer batch as the tombstones, which is the batch whose
// ordering is under test.
func rotateFixture(t *testing.T, srv string, name, pass string) {
	t.Helper()
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv, gwDefault).buyFaucet(200)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	for _, suf := range []string{"", "#de"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile("s3", name+suf, pass, d)
	}
	// ⚠ pushProfile SAMPLES the fence sequence (pushFenceSeq/pushFenceSampled) and never un-samples it. On
	// device that is harmless, because every push is its own short-lived `push` CLI process; in ONE test
	// binary it persists, so any later armSealFence bumps the sequence and sealFencePublishBlocked then
	// refuses EVERY publish, not the ref the test fenced. A fence test built on this fixture would still go
	// green and would be proving something else entirely. Un-sample it, as seal_fence_test.go does.
	pushFenceSeq, pushFenceSampled = 0, false
}

// TestCapFlushPublishesEveryPointerBeforeRetiringAny is the ordering invariant, stated as the failure it
// prevents: a store refusal partway through a rotation must never have already retired the old credential.
//
// capFlush's pointer phase used to be one `for k, v := range st.refs`, and Go randomises map iteration
// deliberately. put() is LOUD on failure -- fail() panics out of capWrite -- so whichever refs happened to
// go first were durably written and the rest were not, differently on every run. rotateVault is the only
// caller that buffers an EMPTY pointer, and an empty pointer is the one kind whose solo landing is fatal:
// it retires a credential. Landing every non-empty pointer first means the worst partial state is "both
// passphrases still open the profile", which is recoverable, instead of "neither does", which is not.
//
// ⚠ IT ROTATES FIVE SEPARATE PROFILES ON PURPOSE. Against the old map-range code this property is not
// always violated -- with n pointers of which k are tombstones it holds by chance with probability
// 1/C(n,k), a few percent here. One run would leave a mutant alive a few percent of the time, which is a
// flaky test pretending to be a passing one. Five independent rotations put that under 10^-7.
func TestCapFlushPublishesEveryPointerBeforeRetiringAny(t *testing.T) {
	srv, objs, omu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())

	for i := 0; i < 5; i++ {
		capReadCache = map[string]capEntry{}
		name := "ordrot" + strings.Repeat("x", i)
		const oldpass, newpass = "old horse battery staple", "new maple stone cloud lantern"
		rotateFixture(t, srv.URL, name, oldpass)

		// ⚠ A LEGACY HEAD AT THE NEW CREDENTIAL, so putHeadSingle's legacy tombstone actually fires.
		// That retirement used to go through delRef, which in cap mode mints its own write cap and PUTs
		// IMMEDIATELY -- landing before every buffered pointer in the same bracket, including the v2 head it
		// is meant to supersede. Planted directly into the store so the plant itself needs no bracket.
		omu.Lock()
		objs["ref/"+profileRefLegacy(name, newpass)] = []byte("a legacy head this rotation supersedes")
		omu.Unlock()

		var mu sync.Mutex
		var seq []string // the ref keys this rotation PUT, in arrival order, "" for a tombstone
		capStorePutHook = func(key string, body []byte) error {
			if !strings.HasPrefix(key, "ref/") {
				return nil // blobs go first by design (#45) and are not what this test is about
			}
			mu.Lock()
			defer mu.Unlock()
			if len(body) == 0 {
				seq = append(seq, "RETIRE "+key)
			} else {
				seq = append(seq, "PUBLISH "+key)
			}
			return nil
		}
		if _, err := rotateVault("s3", name, oldpass, newpass, nil, true); err != nil {
			t.Fatalf("run %d: rotateVault: %v", i, err)
		}
		capStorePutHook = nil

		retired := -1
		for n, step := range seq {
			if strings.HasPrefix(step, "RETIRE ") && retired < 0 {
				retired = n
			}
			if strings.HasPrefix(step, "PUBLISH ") && retired >= 0 {
				t.Fatalf("run %d: A POINTER WAS RETIRED BEFORE THE BATCH HAD FINISHED PUBLISHING. %q was "+
					"retired at step %d and %q was still published at step %d. A store failure in that gap "+
					"leaves the old credential dead and the new head unwritten -- the profile opens under "+
					"NEITHER passphrase. Full order: %v", i, seq[retired], retired, step, n, seq)
			}
		}
		if retired < 0 {
			t.Fatalf("run %d: the rotation retired nothing at all, so this test proved nothing. Order: %v", i, seq)
		}

		// ...and the SECOND ordering, which the two-pass split does not provide on its own: within the
		// publish pass a scope head must land before the bare vault that NAMES it. repointScopes calls that
		// ordering load-bearing in its own header, and for good reason -- if the vault published and a scope
		// head did not follow, the profile opens at the new credential and reads EMPTY. Insertion order is
		// what preserves it, and the map range threw that away on every cap-mode device.
		scopeRef, _ := headWriteRef(name+"#de", newpass)
		at := func(want string) int {
			for n, step := range seq {
				if step == "PUBLISH ref/"+want {
					return n
				}
			}
			return -1
		}
		scopeAt, headAt := at(scopeRef), at(profileRefV2(name, newpass))
		if scopeAt < 0 || headAt < 0 {
			t.Fatalf("run %d: expected both the #de head and the bare head in this batch; got %v", i, seq)
		}
		if scopeAt > headAt {
			t.Fatalf("run %d: THE BARE VAULT WAS PUBLISHED AT STEP %d, BEFORE THE #de SCOPE HEAD IT NAMES AT "+
				"STEP %d. A failure in that gap leaves a profile that opens at the new passphrase and is EMPTY: "+
				"its index names scope heads that were never written. Order: %v", i, headAt, scopeAt, seq)
		}
	}
}

// TestARefusedPublishRetiresNothing is the half of the ordering fix that ordering alone does not buy, and
// the half the filed row missed.
//
// capFlush's two publish guards CONTINUE; they do not panic. So merely putting the tombstones last still
// allows: head refused by the publish fence -> loop walks on -> tombstones land -> old credential retired,
// new head never written. Same lockout, correct order. The retire pass has to be GATED on the publish pass
// finishing clean, not just sequenced after it.
//
// The fence is armed here on the ref the rotation is about to publish, which is exactly what an in-flight
// delete of the NEW credential would do.
func TestARefusedPublishRetiresNothing(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())

	// ⚠ TWO WINDOWS, AND THEY ARE CAUGHT BY DIFFERENT CODE. Arming the fence BEFORE the rotation is
	// refused by putRef, which never buffers the ref at all -- rotateVault sees the flag and does not even
	// queue its tombstones. Arming it DURING the flush is the case capFlush exists for: the bracket
	// buffered everything minutes ago and every check it made has gone stale, so only the per-key re-check
	// at the moment of the PUT can see it. A test that only arms up front leaves that second gate
	// unmeasured -- which is what a pair of surviving mutants showed.
	for _, tc := range []struct {
		label string
		name  string
		early bool
	}{
		{"armed before the bracket", "refusedearly", true},
		{"armed during the flush", "refusedlate", false},
	} {
		t.Run(tc.label, func(t *testing.T) {
			capReadCache = map[string]capEntry{}
			const oldpass, newpass = "old horse battery staple", "new maple stone cloud lantern"
			rotateFixture(t, srv.URL, tc.name, oldpass)
			head := profileRefV2(tc.name, newpass)
			t.Cleanup(func() {
				liftSealFence([]string{head})
				sealFenceHit = false
				clearSealExpectations()
			})
			if tc.early && !armSealFence([]string{head}) {
				t.Fatal("precondition: could not arm the publish fence")
			}

			var mu sync.Mutex
			var retired []string
			armed := tc.early
			capStorePutHook = func(key string, body []byte) error {
				mu.Lock()
				defer mu.Unlock()
				if !armed && strings.HasPrefix(key, "ref/") {
					// The first pointer of the flush is a re-pointed SCOPE head, so the bare head is still to
					// come: this is a delete landing in the middle of the pointer phase, which is precisely the
					// gap capFlush re-checks for.
					armed = true
					armSealFence([]string{head})
				}
				if strings.HasPrefix(key, "ref/") && len(body) == 0 {
					retired = append(retired, key)
				}
				return nil
			}
			_, err := rotateVault("s3", tc.name, oldpass, newpass, nil, true)
			capStorePutHook = nil

			if err == nil {
				t.Fatal("rotateVault reported SUCCESS while the publish fence refused its new head. The user " +
					"would be told their passphrase had changed to one that resolves to nothing.")
			}
			if len(retired) > 0 {
				t.Fatalf("THE ROTATION RETIRED %d POINTER(S) AFTER ITS OWN PUBLISH WAS REFUSED: %v. The new "+
					"head was never written, so the profile now opens under neither passphrase -- and the copy "+
					"the chooser shows tells the user their passphrase has not changed.", len(retired), retired)
			}
			if _, _, ok := resolveKey("s3", tc.name, oldpass); !ok {
				t.Fatal("after a refused rotation the OLD passphrase no longer opens the profile. Nothing was " +
					"retired, so it must still work -- that is the whole point of publishing before retiring.")
			}
		})
	}
}

// stripScopeIndex re-publishes name's bare head with vault.Scopes cleared and re-signed -- which is what an
// OLDER build does to a profile that has one, since Scopes is an ordinary JSON field and parseVault ignores
// what it does not know. Used to build the two states rotation must survive.
func stripScopeIndex(t *testing.T, base, name, pass string) {
	t.Helper()
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("stripScopeIndex: the profile does not resolve")
	}
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("stripScopeIndex: the head is not a vault")
	}
	v.Scopes = ""
	signVault(v, dk)
	putHead(base, name, pass, postBlob(base, serializeVault(v)))
}

// TestRotationRepointsScopesWithNoIndex: a passphrase change must move the whole profile, not the one head
// that happens to carry keyslots.
//
// rotateVault used to re-point scopes only `if idx, ok := openScopeIndex(...); ok`, with no else -- the
// exact reading scope_index.go forbids in its own words ("never as 'this profile has no scopes'"). It then
// published the rotated vault and reported OK with five of six heads left at the old credential: orphaned,
// still leased and billed, named by nothing, and not even reachable by a later delete.
//
// ⚠ AND THIS IS THE COMMON CASE, NOT A LEGACY TAIL. The index shipped in NWP-20260915-02, which is in no
// published image, so every fielded profile has Scopes == "" until its next bare seal.
func TestRotationRepointsScopesWithNoIndex(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldpass, newpass = "noidx", "horse battery staple correct", "a brand new passphrase"
	sealScopeFixture(t, base, name, oldpass)

	originalKey, _, ok := resolveKey(base, name+"#de", oldpass)
	if !ok {
		t.Fatal("precondition: #de does not resolve before the rotation")
	}
	stripScopeIndex(t, base, name, oldpass)

	if _, err := rotateVault(base, name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}

	got, _, ok := resolveKey(base, name+"#de", newpass)
	if !ok {
		t.Fatal("#de DOES NOT RESOLVE AFTER THE ROTATION. Its head is still at a ref derived from the old " +
			"passphrase, so everything in that scope is orphaned: still in the store, still leased, named " +
			"by nothing, and invisible to a later delete of this profile.")
	}
	if !bytes.Equal(got, originalKey) {
		t.Fatal("#de resolves after the rotation but under a DIFFERENT key, so its manifest will not open. " +
			"The re-point must carry the preserved scope key, never mint a new one.")
	}
}

// TestRotationObservesTheScopeKeyRatherThanDerivingItBlind is the reason the fix reads the head instead of
// deriving from the old passphrase, and it is the test that separates the two candidate designs.
//
// main.go's MINT-IF-ABSENT note states the hazard: deriving a scope key blind is correct ONLY while the
// head is still a BARE head. After one credential change the head is a vault wrapping the PRESERVED key,
// and deriveKey(scoped, pass) is then the KEK that opens the wrapper -- NOT the key inside it. A missing
// index looks like a safe proxy for "never re-pointed" and is not one, because an older build strips the
// field and re-signs a vault that still verifies.
//
// So: rotate once WITH an index (the scope head becomes a vault), strip the index, rotate again. A fix that
// derives blind publishes a head wrapping a KEK where the key belongs, and the damage surfaces only at the
// next credential change -- on a user who has already been through one.
func TestRotationObservesTheScopeKeyRatherThanDerivingItBlind(t *testing.T) {
	base := newHTTPStore(t)
	const name, p1, p2, p3 = "obskey", "horse battery staple correct", "a brand new passphrase", "a third passphrase entirely"
	sealScopeFixture(t, base, name, p1)

	originalKey, _, ok := resolveKey(base, name+"#de", p1)
	if !ok {
		t.Fatal("precondition: #de does not resolve")
	}
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("first rotateVault: %v", err)
	}
	if _, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name+"#de", p2)))); !isV {
		t.Fatal("precondition: after one rotation #de's head should be a VAULT wrapping the preserved key; " +
			"without that shape this test cannot tell the two designs apart")
	}

	stripScopeIndex(t, base, name, p2)

	if _, err := rotateVault(base, name, p2, p3, nil, true); err != nil {
		t.Fatalf("second rotateVault: %v", err)
	}
	got, _, ok := resolveKey(base, name+"#de", p3)
	if !ok {
		t.Fatal("#de does not resolve after the second rotation")
	}
	if !bytes.Equal(got, originalKey) {
		t.Fatal("THE SECOND ROTATION PUBLISHED THE WRONG KEY FOR #de. It wrapped deriveKey(name#de, oldpass) " +
			"-- the KEK that opens the previous wrapper -- instead of the preserved scope key inside it. The " +
			"head resolves, so nothing complains; the manifest it names will not unseal.")
	}
}

// TestARefusalDoesNotOutliveTheOperationThatCausedIt: a rotation that fully succeeded must not be
// reported as a store failure because something EARLIER in the same boot was refused.
//
// sealFenceHit and sealStaleHit are process-wide, and the only code that clears them is the top of
// pushProfile -- whose sole non-test caller is the `push` CLI verb, a separate process spawned per
// seal. The login daemon, which is one process for the whole boot, never runs it. So the first
// refused publish of a boot latched both flags and every later rotation inherited the verdict.
//
// ⚠ AND IT INHERITS IT IN THE DANGEROUS DIRECTION. The rotation has by then published its new head
// AND retired the old credential; only the REPORT is wrong. The chooser renders ERR-STORE as
// "couldn't reach your storage -- your passphrase has not changed", so the user keeps using a
// passphrase that no longer opens anything. Same false claim as the unordered pointer phase, reached
// from the opposite side.
func TestARefusalDoesNotOutliveTheOperationThatCausedIt(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() { sealFenceHit = false; clearSealExpectations() })
	capReadCache = map[string]capEntry{}

	const name, pass1, doomed, pass2 = "latchrot", "old horse battery staple", "a doomed passphrase", "new maple stone cloud lantern"
	rotateFixture(t, srv.URL, name, pass1)

	// A first rotation whose new head the fence refuses. It publishes nothing durable and leaves both
	// flags set -- the ordinary shape of "a delete landed while this was in flight".
	if !armSealFence([]string{profileRefV2(name, doomed)}) {
		t.Fatal("precondition: could not arm the publish fence")
	}
	if _, err := rotateVault("s3", name, pass1, doomed, nil, true); err == nil {
		t.Fatal("precondition: the fenced rotation should have been refused")
	}
	if !sealFenceHit {
		t.Fatal("precondition: the refusal should have set the process-wide flag; without that this test " +
			"cannot observe the latch it exists for")
	}

	// A SECOND, entirely unrelated rotation to a different credential. Nothing fences it.
	if _, err := rotateVault("s3", name, pass1, pass2, nil, true); err != nil {
		t.Fatalf("THE SECOND ROTATION REPORTED %v, but nothing refused it. It inherited the first "+
			"rotation's verdict from a flag that is never cleared outside pushProfile. The user is told "+
			"their passphrase did not change -- and it did.", err)
	}
	if _, _, ok := resolveKey("s3", name, pass2); !ok {
		t.Fatal("the second rotation reported success but the new passphrase does not open the profile")
	}
	if _, _, ok := resolveKey("s3", name, pass1); ok {
		t.Fatal("the second rotation reported success but the OLD passphrase still opens the profile -- " +
			"it was not retired, so the report was wrong in the other direction")
	}
}

// TestARescuedIndexTreatsALeftoverTombstoneAsAnUnusedScope: a profile that was deleted and re-created
// at the same credentials must still be able to change its passphrase.
//
// deleteProfile tombstones every suffix in deleteScopeSuffixes, and a tombstone is deliberately left as
// an empty object that EXISTS -- delRef says why, at length. createVault then re-publishes only the bare
// head and the recovery ref, so a re-created profile sits on six empty-but-present scope refs forever.
//
// ⚠ rescueScopeIndex resolves those refs with headRef, and refProbe reports a tombstone as EXISTS.
// Handed to repointScopes unqualified, every one of them reads as ErrScopeTombstoned -- "a scope was
// deleted out from under this profile" -- and the rotation refuses, permanently, with a message about a
// deletion the user performed themselves and that the re-create already dealt with. A RECORDED ref
// (Wrapped set) still refuses, because there it does mean a live profile lost a scope; a ref we merely
// derived proves nothing of the kind.
func TestARescuedIndexTreatsALeftoverTombstoneAsAnUnusedScope(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldpass, newpass = "recreated", "horse battery staple correct", "a brand new passphrase"
	sealScopeFixture(t, base, name, oldpass)
	if st := deleteProfile(base, name, oldpass); st != "deleted" {
		t.Fatalf("precondition: delete reported %q, want deleted", st)
	}
	if createVault(base, name, oldpass) == "" {
		t.Fatal("precondition: could not re-create the profile")
	}
	if !refExists(base, profileRefV2(name+"#de", oldpass)) {
		t.Fatal("FIXTURE BROKE: the #de scope is not present after it was tombstoned -- this backend keeps an empty ref present (newHTTPStore stores \"\"; delRef writes an empty object), so the fixture no longer reaches the state under test")
	}
	// The rescue path is the one under test, so put the profile in the shape that reaches it: no index.
	stripScopeIndex(t, base, name, oldpass)

	if _, err := rotateVault(base, name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("A RE-CREATED PROFILE CANNOT CHANGE ITS PASSPHRASE: %v. The scope refs its rescued index "+
			"names are tombstones left by the delete that preceded the re-create -- ordinary history, not a "+
			"scope taken away from a live profile. Refusing here is permanent: nothing ever clears them.", err)
	}
	if _, _, ok := resolveKey(base, name, newpass); !ok {
		t.Fatal("the rotation reported success but the new passphrase does not open the profile")
	}
}

// TestRotationDoesNotPublishAWalletShapeNothingCanRead: #wallet is in the scope index deliberately, but it
// is not a scope in the sense repointScopes means, and re-pointing it as one destroys it.
//
// Every other scope head is a manifest sealed under a SCOPE key, which is what buildScopeVault wraps in a
// pass slot. The wallet head is a blob sealed under the PROFILE DK -- doFold and sealWalletDurable both
// use it -- and readStoredWallet (and, before NWP-20261013-20, the login restore) do a plain unseal with that DK inside a recover(), so a
// vault published there does not fail loudly: they return nil and the balance reads as zero.
//
// ⚠ THE DIRECT PATH IS WHERE IT SHOWS. In cap mode the fold writes the same ref later in the same
// flush and overwrites the mistake, which is why this survived -- a correctness that depends on one
// caller happening to run second, in one of the two store modes, is not a design.
func TestRotationDoesNotPublishAWalletShapeNothingCanRead(t *testing.T) {
	base := newHTTPStore(t)
	const name, oldpass, newpass = "walletshape", "horse battery staple correct", "a brand new passphrase"
	sealScopeFixture(t, base, name, oldpass)
	dk, _, ok := resolveKey(base, name, oldpass)
	if !ok {
		t.Fatal("precondition: the profile does not resolve")
	}

	// A wallet head in the shape the real publishers write: a DK-sealed blob, not a vault.
	wref, _ := headWriteRef(name+"#wallet", oldpass)
	putRef(base, wref, postBlob(base, seal(dk, []byte(`{"tokens":[]}`))))

	if _, err := rotateVault(base, name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}

	newRef, _ := headWriteRef(name+"#wallet", newpass)
	if head := getRef(base, newRef); head != "" {
		if _, isVault := parseVault(getHeadBlob(base, head)); isVault {
			t.Fatal("THE ROTATION PUBLISHED A SCOPE VAULT AT THE WALLET HEAD. Every wallet reader unseals " +
				"that ref with the PROFILE DK inside a recover(), so it will not error -- it will return nil " +
				"and the balance will read as zero, with the tokens still paid for and unreachable.")
		}
	}
}
