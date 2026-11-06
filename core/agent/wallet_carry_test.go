package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// fundedProfile creates a cap-mode profile, funds a local wallet, seals it durably to the store, and
// returns the recovery mnemonic plus the wallet head's content hash. The head hash is the thing most of
// these tests assert on: a carry is a POINTER MOVE, so the hash must survive a credential change byte for
// byte -- anything else means the wallet was re-serialised, merged, or replaced.
func fundedProfile(t *testing.T, srv, name, pass string, tokens int) (mnemonic, headHash, wpath string) {
	t.Helper()
	wpath = filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv, gwDefault).buyFaucet(tokens)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 50, PlanPeriods: 12}); err != nil {
		t.Fatal(err)
	}
	mnemonic = createVault("s3", name, pass)
	if mnemonic == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	dk, _, ok := resolveKey("s3", name, pass)
	if !ok {
		t.Fatal("the profile does not resolve after create")
	}
	// NWP-20261013-20: the fixture is a signed-in session whose restore landed, so its generation has its restore
	// proof -- without one every wallet publish is refused.
	markWalletRestoreLanded(wpath, walletGeneration(wpath))
	if _, err := sealWalletDurable("s3", name, pass, dk, wpath); err != nil {
		t.Fatalf("sealWalletDurable: %v", err)
	}
	headHash = getRef("s3", walletHeadKey("s3", name, pass))
	if headHash == "" {
		t.Fatal("precondition: the wallet was not published")
	}
	return mnemonic, headHash, wpath
}

// walletAt reads the wallet the store holds for (name, pass), the way a next login would.
func walletAt(t *testing.T, name, pass string) *Wallet {
	t.Helper()
	dk, _, ok := resolveKey("s3", name, pass)
	if !ok {
		return nil
	}
	return readStoredWallet("s3", name, pass, dk)
}

// TestARecoveryCarriesTheWalletToTheNewCredential is the headline: a user who recovers with their twelve
// words keeps the credit they paid for.
//
// The wallet head is keyed on the passphrase, so a recovery moves it -- and a recovery, by its own premise,
// cannot derive the old location, because the passphrase that would derive it is exactly what was lost. The
// scope index records that location verbatim, which is the reason #wallet is in the index at all; and
// repointScopes advances that record in the SAME call, so a recovery that does not carry loses the address
// permanently. payRent then stops re-leasing the orphan and the gateway GC takes it.
//
// ⚠ THE HASH MUST BE IDENTICAL. Blind tokens are bearer secrets the gateway cannot re-issue, so the carry
// moves the ciphertext rather than re-publishing a re-serialised wallet: an equal hash proves no field was
// dropped, no token set was recomputed, and no second copy was created.
func TestARecoveryCarriesTheWalletToTheNewCredential(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass, newpass = "walrec", "horse battery staple correct", "a brand new passphrase"
	mnemonic, oldHead, wpath := fundedProfile(t, srv.URL, name, pass, 40)

	// The gate has no session for this profile: that is what a recovery IS.
	if err := os.Remove(wpath); err != nil {
		t.Fatal(err)
	}
	if err := recoverVault("s3", name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}

	newHead := getRef("s3", walletHeadKey("s3", name, newpass))
	if newHead == "" {
		t.Fatal("THE RECOVERY LOST THE WALLET. Its head is keyed on the passphrase, so it moved; the only " +
			"record of where it used to be is the scope index, and repointScopes advances that record in " +
			"the same call. Nothing else in the tree can name the old location, payRent stops re-leasing " +
			"it, and the gateway GC eventually deletes it. Blind tokens cannot be re-issued.")
	}
	if newHead != oldHead {
		t.Fatalf("the wallet was REPUBLISHED (%s) rather than relocated (%s). A carry that re-serialises "+
			"drops any field this build does not know -- an older agent silently deleting a newer one's "+
			"wallet state -- and re-opens the token-merge question the design exists to avoid.",
			short(newHead), short(oldHead))
	}
	w := walletAt(t, name, newpass)
	if w == nil || len(w.Tokens) == 0 {
		t.Fatal("the carried wallet does not open at the new credential")
	}
	if w.PlanGB != 50 {
		t.Errorf("the carried wallet lost its plan record (PlanGB=%d, want 50)", w.PlanGB)
	}
}

// TestACredentialChangeNeverPublishesAWalletItCannotAttribute is the money-destruction case, and it is the
// one the filed row did not describe.
//
// capWalletPath() is ONE file in a boot-lifetime tmpfs shared by every login, and nothing removes it at
// sign-out -- only at roam-in. A recovery runs at the gate with no session, so whatever that file holds is
// either nothing or the wallet of a profile that signed off earlier in this boot. The fold had no guard:
// it sealed those bearer tokens under the RECOVERING profile's DK and published them at its head.
//
// ⚠ AND IT SPENT THEM. capFlush's wallet funds the lease ladder, not just the publish: planPending() steers
// past the free probe and planPurchase presents whatever is in the file. The gateway's spent set is keyed on
// the nonce alone, with no profile column, so the departed profile's tokens are then dead everywhere and it
// has no record of the spend -- it re-presents them at its next login and is refused, permanently.
func TestACredentialChangeNeverPublishesAWalletItCannotAttribute(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const victim, vpass, vnew = "walvictim", "horse battery staple correct", "a brand new passphrase"
	mnemonic, victimHead, _ := fundedProfile(t, srv.URL, victim, vpass, 10)

	// A DIFFERENT profile signed in and out earlier in this boot, leaving its wallet in the shared state dir.
	stranger := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", stranger)
	strangerToks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(25)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(stranger, &Wallet{Tokens: strangerToks}); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(stranger)
	if err != nil {
		t.Fatal(err)
	}

	if err := recoverVault("s3", victim, mnemonic, vnew); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}

	if got := getRef("s3", walletHeadKey("s3", victim, vnew)); got != victimHead {
		t.Fatalf("THE RECOVERY PUBLISHED A WALLET THAT IS NOT THIS PROFILE'S at its own head (%s, want the "+
			"carried %s). Those are another profile's bearer tokens, now sealed under this profile's DK and "+
			"live in two accounts at once: whichever presents second is refused forever, and the gateway "+
			"cannot re-issue either side.", short(got), short(victimHead))
	}
	after, err := os.ReadFile(stranger)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Error("THE CREDENTIAL CHANGE SPENT OR REWROTE A WALLET THAT IS NOT ITS OWN. capFlush's wallet " +
			"funds the lease ladder, so an unattributable file is not merely published, it is presented to " +
			"the gateway -- and the departed profile keeps no record of the spend.")
	}
}

// TestAnAbsentWalletIsNeverPublishedOverALiveOne: loadWallet answers a MISSING file with an empty wallet
// rather than an error, so every consumer reads {} as "this profile has no credit" instead of "there is
// nothing here to publish".
//
// Both of the other wallet publishers guard on exactly this -- sealWallet on IsNotExist, sealWalletDurable
// on os.Stat, "nothing minted yet: nothing to lose". The fold, the only publisher the fleet runs, did not:
// it wrote {} at the profile's live head, durably, zeroing the balance AND the plan record. The next login
// then restores a perfectly valid empty wallet and reports a zero balance with no error anywhere.
func TestAnAbsentWalletIsNeverPublishedOverALiveOne(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass = "walabsent", "horse battery staple correct"
	_, head, wpath := fundedProfile(t, srv.URL, name, pass, 15)
	if err := os.Remove(wpath); err != nil {
		t.Fatal(err)
	}

	// The DK before the operation: enrollSE HARDENS the vault, dropping the pass slot, so resolveKey
	// cannot open it afterwards. The wallet is sealed under the DK, which hardening does not change.
	dk, _, ok := resolveKey("s3", name, pass)
	if !ok {
		t.Fatal("precondition: the profile does not resolve")
	}

	// An ordinary same-credential bracket with no local wallet. add-device is the fielded shape -- a GATE
	// verb with no session check at all, unlike SET-PIN and ENROLL-FIDO2, which both refuse without one.
	if err := enrollSE("s3", name, pass, []byte("handset-A-secret")); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}

	if got := getRef("s3", walletHeadKey("s3", name, pass)); got != head {
		t.Fatalf("A BRACKET WITH NO LOCAL WALLET OVERWROTE THE PROFILE'S LIVE WALLET HEAD (%s, want %s). "+
			"An absent file means there is nothing to publish, never that the balance is zero -- and this "+
			"head is the live one, not an orphan, so the credit is simply gone.", short(got), short(head))
	}
	var carried Wallet
	if err := json.Unmarshal(unseal(dk, getBlob("s3", getRef("s3", walletHeadKey("s3", name, pass)))), &carried); err != nil {
		t.Fatalf("the wallet at the profile's head no longer decodes: %v", err)
	}
	if len(carried.Tokens) == 0 {
		t.Error("the profile's wallet no longer holds any tokens")
	}
}

// TestALiveSessionsWalletIsNotOverwrittenByTheStoredOne is the other direction, and it is why the carry is
// conditional rather than unconditional.
//
// capFlush says it in its own words: "The DISK wallet is authoritative; the folded (roamed) snapshot is the
// pre-settle state." settlePayment returns the tokens the gateway did not charge to the DISK, AFTER the last
// fold -- so between flushes the stored head is persistently BEHIND the local copy. When a session provably
// owns that copy, relocating the stored head over it would republish tokens the session has already spent:
// the gateway's spent set is keyed on the nonce alone, so they are refused on sight and, because redemption
// is all-or-nothing, they take every other token in the same request down with them.
func TestALiveSessionsWalletIsNotOverwrittenByTheStoredOne(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass, newpass = "wallive", "horse battery staple correct", "a brand new passphrase"
	_, stored, wpath := fundedProfile(t, srv.URL, name, pass, 30)

	// The session has since spent some of them; the disk copy is the newer one.
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if len(w.Tokens) < 4 {
		t.Fatalf("precondition: only %d tokens", len(w.Tokens))
	}
	w.Tokens = w.Tokens[2:]
	spent := len(w.Tokens)
	if err := saveWallet(wpath, w); err != nil {
		t.Fatal(err)
	}

	// walletOurs = true: this profile is signed in at `pass`, so the file is provably its own.
	// Record every object the flush writes, so the absence of a carry is observable rather than merely
	// argued: a relocation re-posts the stored blob, and nothing else in this flush would.
	var putMu sync.Mutex
	var order []string
	capStorePutHook = func(key string, body []byte) error {
		putMu.Lock()
		order = append(order, key)
		putMu.Unlock()
		return nil
	}
	if _, err := rotateVault("s3", name, pass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	capStorePutHook = nil
	// ⚠ THE FOLD MUST BE THE SOLE AUTHOR HERE, and the publish ORDER is what shows it. A carry writes
	// the wallet pointer through putRef, which records the key in refOrder, so it lands at the carry's
	// buffered position -- ahead of the vault head written after it. The fold assigns st.refs directly
	// and never enters refOrder, so when IT is the only author the wallet ref falls into capRefOrder's
	// sorted tail, after the head. (Watching for a re-POST of the stored blob does not work: postBlob
	// dedups on blobCacheKnown, so a redundant carry writes no blob at all and looks like no carry.)
	wref, _ := headWriteRef(name+"#wallet", newpass)
	at := func(k string) int {
		for i, got := range order {
			if got == k {
				return i
			}
		}
		return -1
	}
	walletAtStep, headAtStep := at("ref/"+wref), at("ref/"+profileRefV2(name, newpass))
	if walletAtStep < 0 || headAtStep < 0 {
		t.Fatalf("expected both the wallet ref and the vault head in this flush; got %v", order)
	}
	if walletAtStep < headAtStep {
		t.Errorf("THE ROTATION CARRIED THE STORED WALLET WHILE A SESSION OWNED THE LOCAL ONE (wallet at "+
			"step %d, head at %d -- a buffered carry, not the fold). The disk copy is the newer one: "+
			"settlePayment returns the uncharged tokens to it AFTER the last fold, so republishing the "+
			"stored blob resurrects tokens this session has already presented.", walletAtStep, headAtStep)
	}

	got := walletAt(t, name, newpass)
	if got == nil {
		t.Fatal("the rotation left no readable wallet at the new credential")
	}
	if len(got.Tokens) != spent {
		t.Fatalf("THE ROTATION PUBLISHED %d TOKENS WHERE THE LIVE SESSION HELD %d. It relocated the stored "+
			"head over a newer local copy, resurrecting tokens this session already presented. Redemption "+
			"is all-or-nothing, so one dead nonce rejects every token in the request and the purchase can "+
			"never activate.", len(got.Tokens), spent)
	}
	if newHead := getRef("s3", walletHeadKey("s3", name, newpass)); newHead == stored {
		t.Error("the new head is the STORED blob, so the session's post-spend state was discarded")
	}
}

// TestTheFoldMergesAgainstTheStoreNotTheProfileName pins a one-word bug with a three-week-old field report
// behind it.
//
// readStoredWallet's first parameter is the STORE BASE -- it feeds getRef(base, ...) and getBlob(base, ...).
// doFold passed sess.base, which capSessionT documents two fields up as the PROFILE ("alice"). Both are
// strings, so it compiled: getRef("alice", ...) matches neither store branch, falls through to an HTTP GET
// of "alice/ref/...", panics, and is swallowed by readStoredWallet's own recover(), which returns nil. So
// walletForPublish was handed nil every single time and returned the local wallet unchanged.
//
// ⚠ WHICH MEANS NWP-20260907-12 HAS NEVER RUN ON THE ONLY PUBLISHER THE FLEET EXERCISES. It was written
// because a handset erased an account's 50 GB plan on 2026-09-07 -- the exact failure below.
func TestTheFoldMergesAgainstTheStoreNotTheProfileName(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass = "walmerge", "horse battery staple correct"
	_, _, wpath := fundedProfile(t, srv.URL, name, pass, 20)

	// Another handset bought a bigger plan and sealed it. This one never saw it.
	stored := walletAt(t, name, pass)
	if stored == nil {
		t.Fatal("precondition: no stored wallet")
	}
	stored.PlanGB = 250
	dk, _, _ := resolveKey("s3", name, pass)
	if err := saveWallet(wpath, stored); err != nil {
		t.Fatal(err)
	}
	if _, err := sealWalletDurable("s3", name, pass, dk, wpath); err != nil {
		t.Fatal(err)
	}
	local, _ := loadWallet(wpath)
	local.PlanGB = 10 // this handset's stale memory of a smaller top-up
	if err := saveWallet(wpath, local); err != nil {
		t.Fatal(err)
	}

	// An ordinary seal: the fold republishes the wallet and must not erase what it did not know about.
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, pass, d)

	if got := walletAt(t, name, pass); got == nil || got.PlanGB != 250 {
		gb := -1
		if got != nil {
			gb = got.PlanGB
		}
		t.Fatalf("THE FOLD ERASED THE ACCOUNT'S PLAN (PlanGB=%d, want 250). It merges against the wallet "+
			"the store holds precisely so a handset that never saw a purchase cannot publish over it -- and "+
			"it was reading the profile name as a store base, so the merge was nil every time.", gb)
	}
}

// TestARotationWithNoSessionCarriesTheWallet: a rotation is not always driven by the signed-in profile.
// handleRotate calls rotateVault whether or not a session is live -- `live` gates only the keyguard re-key
// and whether refusals are named or blind -- and the CLI verb has no session at all. In those cases the
// state dir's wallet is not this profile's, so the fold is suppressed and the wallet must be carried from
// the store instead, or the credential change silently strands it.
func TestARotationWithNoSessionCarriesTheWallet(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass, newpass = "walrot", "horse battery staple correct", "a brand new passphrase"
	_, oldHead, wpath := fundedProfile(t, srv.URL, name, pass, 20)
	if err := os.Remove(wpath); err != nil {
		t.Fatal(err)
	}

	// walletOurs = false: no login established that file as this profile's.
	if _, err := rotateVault("s3", name, pass, newpass, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	got := getRef("s3", walletHeadKey("s3", name, newpass))
	if got != oldHead {
		t.Fatalf("the rotation left the wallet at %q, want the carried %s. The head is keyed on the "+
			"passphrase, so it moved; nothing re-leases the old location once payRent keys on the new "+
			"credential, and the gateway GC eventually deletes it.", short(got), short(oldHead))
	}
}

// TestTheIndexRecordsNoKeyForTheWalletAfterACredentialChange: both minters have to agree, or the false
// record comes back on the first rotation.
//
// ⚠ deriveScopeIndex is not the only one. repointScopes re-mints every entry it writes, so emptying the
// field at the create-time minter alone would leave a rotation quietly restoring a key that opens nothing
// -- recorded in a field documented as "the key that opens it", for a head sealed under the profile DK.
func TestTheIndexRecordsNoKeyForTheWalletAfterACredentialChange(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass, newpass = "walidx", "horse battery staple correct", "a brand new passphrase"
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if _, err := rotateVault(base, name, pass, newpass, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	dk, _, ok := resolveKey(base, name, newpass)
	if !ok {
		t.Fatal("the profile does not resolve after the rotation")
	}
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, newpass))))
	if !isV {
		t.Fatal("the head is not a vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the rotated vault carries no scope index")
	}
	if w := idx["#wallet"].Wrapped; w != "" {
		t.Errorf("the re-point recorded a key (%q) for the wallet head. It is sealed under the profile "+
			"DK, so that value opens nothing -- it is the ref-derivation secret, i.e. a second copy of the "+
			"ADDRESS, filed under a field labelled \"the key\".", w)
	}
	if want, _ := headWriteRef(name+"#wallet", newpass); idx["#wallet"].Ref != want {
		t.Errorf("the index names %s for the wallet, want %s", short(idx["#wallet"].Ref), short(want))
	}
}

// capStoreTokensPresented counts the tokens the mock gateway was asked to redeem, across the whole
// test. Reset by mockCapStore.
var capStoreTokensPresented int

// TestAnAttributableBracketStillRefusesAnAbsentWallet separates two guards that an earlier version of
// this file could not tell apart: it removed the wallet AND used a no-login bracket, so either guard
// alone satisfied it and a mutant deleting one survived.
//
// This is the ATTRIBUTABLE case -- an ordinary seal at the profile's own credential -- with no local
// wallet. It is the login-path shape: the login removes wallet.json, a bracket runs, and the restore
// reads the head back only afterwards. loadWallet answers a missing file with an EMPTY wallet, so
// without a guard the fold publishes {} over the live head in that gap.
func TestAnAttributableBracketStillRefusesAnAbsentWallet(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass = "walseal", "horse battery staple correct"
	_, head, wpath := fundedProfile(t, srv.URL, name, pass, 15)
	if err := os.Remove(wpath); err != nil {
		t.Fatal(err)
	}

	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, pass, d) // this profile's OWN credential: attributable, but no file exists

	if got := getRef("s3", walletHeadKey("s3", name, pass)); got != head {
		t.Fatalf("AN ORDINARY SEAL WITH NO LOCAL WALLET OVERWROTE THE LIVE HEAD (%s, want %s). An absent "+
			"file means there is nothing to publish, never that the balance is zero -- and both of the other "+
			"wallet publishers already guard on exactly this.", short(got), short(head))
	}
}

// TestAddDeviceNeverPublishesAStrangersWallet is the other half: a no-login bracket whose wallet file
// is PRESENT and belongs to somebody else.
//
// ⚠ ADD-DEVICE IS A GATE VERB WITH NO SESSION CHECK -- its dispatch reads name/pass/mnemonic straight
// off the socket, unlike SET-PIN and ENROLL-FIDO2, which both refuse with ERR-NOSESSION. And it runs at
// the profile's CURRENT credential, which makes it worse than a credential change rather than better:
// the fold writes at this profile's LIVE wallet head, not at an orphan.
func TestAddDeviceNeverPublishesAStrangersWallet(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass = "waladd", "horse battery staple correct"
	_, head, _ := fundedProfile(t, srv.URL, name, pass, 15)

	// A profile that signed off earlier in this boot left its wallet in the shared state dir.
	stranger := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", stranger)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(25)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(stranger, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	if err := enrollSE("s3", name, pass, []byte("handset-A-secret")); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	if got := getRef("s3", walletHeadKey("s3", name, pass)); got != head {
		t.Fatalf("A GATE-SIDE ADD-DEVICE PUBLISHED A STRANGER%sS WALLET AT THIS PROFILE%sS LIVE HEAD "+
			"(%s, want %s). Those bearer tokens now exist in two accounts, and the spent set is keyed on the "+
			"nonce alone -- whoever presents second is refused permanently.", "'", "'", short(got), short(head))
	}
}

// TestACredentialChangeSpendsNothing: suppressing the PUBLISH is not enough, because capFlush's wallet
// also FUNDS the lease ladder. planPending() steers past the free probe and planPurchase presents
// whatever the file holds -- so an unattributable wallet is not merely republished, it is redeemed.
//
// ⚠ AND THAT HARM IS INVISIBLE ON THE DEVICE, which is why this asserts on what was PRESENTED. The
// spent set has no profile column, so the nonces are burned for every profile at once; the profile
// that paid for them keeps no record of the spend, re-presents them at its next login, and is refused
// permanently -- with credit the gateway cannot re-issue.
func TestACredentialChangeSpendsNothing(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}

	const name, pass, newpass = "walspend", "horse battery staple correct", "a brand new passphrase"
	mnemonic, _, _ := fundedProfile(t, srv.URL, name, pass, 10)

	// A stranger's wallet with a plan WAITING TO ACTIVATE: planPending() is true, so the flush skips the
	// free probe and takes the entitled path, which is the one that presents tokens.
	stranger := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", stranger)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(8)
	if err != nil {
		t.Fatal(err)
	}
	w := &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}
	if !w.planPending() {
		t.Fatal("precondition: the stranger wallet is not plan-pending, so the free probe would cover the flush")
	}
	if err := saveWallet(stranger, w); err != nil {
		t.Fatal(err)
	}

	capStoreTokensPresented = 0
	if err := recoverVault("s3", name, mnemonic, newpass); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}
	if capStoreTokensPresented != 0 {
		t.Fatalf("THE CREDENTIAL CHANGE PRESENTED %d TOKEN(S) FROM A WALLET THAT IS NOT ITS OWN. They are "+
			"burned for every profile at once, and the profile that paid for them keeps no record of the "+
			"spend: it re-presents them at its next login and is refused forever.", capStoreTokensPresented)
	}
}
