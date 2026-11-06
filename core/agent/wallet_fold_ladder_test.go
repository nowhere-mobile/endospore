package main

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260906-12. capFlush's wallet fold hand-rolled the head choice as profileRefV2(name+"#wallet", pass)
// instead of making the one putHead makes. #wallet is per-unit (isPerUnitRef), so with #91 on the two
// disagreed, and headRef probes the unit head FIRST -- so from the first durable wallet seal onward the fold
// wrote a ref nothing reads.
//
// In cap mode that is the only routine wallet publisher (sealWallet returns immediately there and the on-disk
// wallet is tmpfs), so post-spend state never became durable and the next login restored a pre-spend wallet:
// spent tokens resurrected, then refused by the gateway as spent nonces.
//
// The flag-off fold ref is covered by TestCapModeFoldWallet, which asserts v2 verbatim -- the fleet's
// behaviour must stay byte-identical, and that test failing would be the tell.

// foldingSeal runs one cap-mode seal that carries a data head, so capFlush folds the current wallet.
func foldingSeal(t *testing.T, name, pass string, dk []byte) {
	t.Helper()
	bn := capBegin()
	capSetSession(name, pass, dk)
	putRef("s3", profileRefV2(name, pass), postBlob("s3", bytes.Repeat([]byte("d"), 2000)))
	capFlush(bn)
}

// foldedBalance is the balance the next login restores, read STRICTLY (readStoredWalletStrict): a stored wallet that
// is damaged, does not open or does not parse fails the test rather than reading as an empty wallet, so an assertion
// that the stored wallet still holds its tokens cannot pass on a head that points at nothing usable. No wallet head at
// all is a balance of 0.
func foldedBalance(t *testing.T, name, pass string, dk []byte) int {
	t.Helper()
	w, _, err := readStoredWalletStrict("s3", name, pass, dk)
	if err != nil {
		t.Fatalf("readStoredWalletStrict: %v", err)
	}
	if w == nil {
		return 0
	}
	return w.balance()
}

// TestHeadWriteRefIsWherePutHeadActuallyWrites pins the two together BY OBSERVATION -- putHead is driven and
// the value is looked for at headWriteRef's ref -- so the fold's copy of the decision cannot drift again.
func TestHeadWriteRefIsWherePutHeadActuallyWrites(t *testing.T) {
	for _, tc := range []struct {
		flag        string
		scope       string
		wantPerUnit bool
	}{
		{"", "", false},        // the fleet: single account head
		{"", "#wallet", false}, //
		{"1", "#wallet", true}, // #91 on: per-unit
		{"1", "", true},        //
		{"1", "#apps", false},  // account-SHARED even with the flag on -- a kept app must roam to a new phone
		{"1", "#media", false}, //
	} {
		t.Run(tc.flag+tc.scope, func(t *testing.T) {
			base := newHTTPStore(t)
			orig := unitIDPath
			defer func() { unitIDPath = orig }()
			t.Setenv("NOWHERE_MULTIDEVICE", tc.flag)
			unitIDPath = filepath.Join(t.TempDir(), "unit-id")

			name, pass := "hwr"+tc.scope, "correct horse battery staple"
			ref, perUnit := headWriteRef(name+tc.scope, pass)
			if perUnit != tc.wantPerUnit {
				t.Fatalf("perUnit=%v, want %v", perUnit, tc.wantPerUnit)
			}
			putHead(base, name+tc.scope, pass, "deadbeef")
			if got := getRef(base, ref); got != "deadbeef" {
				t.Fatalf("putHead did not write at headWriteRef's ref (got %q) -- the two have drifted, which "+
					"is exactly how the wallet fold came to publish where nothing reads", got)
			}
		})
	}
}

// TestFoldedWalletIsWhatTheNextLoginRestores is the money assertion, end to end: seal the wallet durably (as a
// credit claim does), spend, then let a data seal fold the post-spend wallet -- and the next login must see
// the POST-spend balance. Before this fix the durable seal minted the unit head, the fold kept writing v2, and
// the restore resolved the unit head: the spend vanished and the tokens came back.
func TestFoldedWalletIsWhatTheNextLoginRestores(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	capReadCache = map[string]capEntry{}

	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	name, pass := "foldladder", "fold the wallet free"
	dk := deriveKey(name, pass)

	// A credit claim: sealWalletDurable -> putHead -> this unit's head. This is what makes the fold's ref
	// matter; with no unit head yet, headRef still falls through to v2 and the bug is invisible.
	if _, err := sealWalletDurable("s3", name, pass, dk, wpath); err != nil {
		t.Fatalf("sealWalletDurable: %v", err)
	}
	if got := foldedBalance(t, name, pass, dk); got != 10 {
		t.Fatalf("fixture: durably sealed wallet restores as %d, want 10", got)
	}

	// Spend, then let an ordinary data seal fold the post-spend wallet.
	if err := saveWallet(wpath, &Wallet{Tokens: toks[:4]}); err != nil {
		t.Fatal(err)
	}
	foldingSeal(t, name, pass, dk)

	if got := foldedBalance(t, name, pass, dk); got != 4 {
		t.Fatalf("the next login restores a balance of %d, want 4 -- the fold published to a ref the wallet "+
			"reader does not resolve, so the spend never became durable and %d spent tokens came back", got, got-4)
	}
}

// TestFoldDoesNotStrandTheWalletAtTheAccountRef. headRef falls through to v2 for a device with no unit head of
// its own, so the stranded copy was not merely dead -- a SECOND handset would restore this one's bearer
// tokens. headRef refuses that deliberately for #wallet in its "restore from another unit" override ("bearer
// tokens -> never restored from another device"); the fold was writing the ref that undid it.
func TestFoldDoesNotStrandTheWalletAtTheAccountRef(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	capReadCache = map[string]capEntry{}

	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	name, pass := "foldstrand", "fold the wallet free"
	dk := deriveKey(name, pass)
	foldingSeal(t, name, pass, dk)

	mu.Lock()
	defer mu.Unlock()
	if objs["ref/"+profileRefV2(name+"#wallet", pass)] != nil {
		t.Fatal("the fold published the wallet at the ACCOUNT ref with #91 on -- a second handset that has " +
			"not sealed yet falls through to it and restores this device's bearer tokens")
	}
	uref, perUnit := headWriteRef(name+"#wallet", pass)
	if !perUnit {
		t.Fatal("fixture: #wallet is not resolving per-unit")
	}
	ptr := objs["ref/"+uref]
	if ptr == nil {
		t.Fatal("the fold published no wallet pointer at this unit's head")
	}
	wblob := objs["blob/"+strings.TrimSpace(string(ptr))]
	if wblob == nil {
		t.Fatal("the folded wallet pointer resolves to no blob")
	}
	var rw Wallet
	if err := json.Unmarshal(unseal(dk, wblob), &rw); err != nil {
		t.Fatalf("the folded wallet did not unseal: %v", err)
	}
	if rw.balance() != 10 {
		t.Fatalf("folded wallet balance %d, want 10", rw.balance())
	}
}

// TestFoldFollowsTheWriteLadderNotTheReadLadder. The tempting fix is to point the fold at headKey -- where the
// wallet is READ. That is wrong in one real shape and this test is the shape: a pre-#91 profile already has a
// v2 wallet ref, so headRef's probe finds it and returns v2, while putHead (sealWalletDurable's path) writes
// the UNIT head regardless. A fold on the read ladder would keep feeding v2 until the first durable seal
// minted the unit head, and every fold after that would be stranded again -- this bug, recreated.
//
// The write ladder has no such ambiguity: it never probes, so the fold and the durable seal agree from the
// first byte.
func TestFoldFollowsTheWriteLadderNotTheReadLadder(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	orig := unitIDPath
	defer func() { unitIDPath = orig }()
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	capReadCache = map[string]capEntry{}

	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	name, pass := "foldlegacy", "fold the wallet free"
	dk := deriveKey(name, pass)
	v2 := "ref/" + profileRefV2(name+"#wallet", pass)
	// A real, readable wallet blob: NWP-20261107-02 (dn-1031 #1) makes the fold skip its head while the stored copy
	// cannot be read, and a ref to a blob that is not there is such a copy.
	wj, _ := json.Marshal(&Wallet{})
	plantedBlob := seal(dk, wj)
	planted := hashHex(plantedBlob)
	mu.Lock()
	objs["blob/"+planted] = plantedBlob
	objs[v2] = []byte(planted) // as a profile sealed before #91 was turned on already has
	mu.Unlock()

	foldingSeal(t, name, pass, dk)

	mu.Lock()
	defer mu.Unlock()
	uref, _ := headWriteRef(name+"#wallet", pass)
	if objs["ref/"+uref] == nil {
		t.Fatal("the fold did not write this unit's head -- it followed the READ ladder to the pre-existing v2 " +
			"ref, so the first durable seal will move the head and strand every fold after it")
	}
	if got := strings.TrimSpace(string(objs[v2])); got != planted {
		t.Fatalf("the fold overwrote the pre-#91 account wallet ref (%s), which putHead would never touch "+
			"with the flag on", short(got))
	}
}
