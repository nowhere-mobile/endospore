package main

import (
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
)

// NWP-20261129-33 (dn-1031 #1, decided 2026-10-21, option (b)): payRent's spend and a claim write no #wallet head while
// the stored copy cannot be read, so a store hiccup on this handset's read no longer publishes its local set over the
// tokens another handset published. The spend or the claim stays in the file and the next save that can read publishes
// the merge. A damaged or absent copy still publishes the local set, as the fold does. The state is
// signOutMergeStore's: this session spent X and the other handset published Y. Every assertion reads the STORE.

// strictPublishCopy takes the by-value copy as payRentGenRule takes it: under the wallet lock, which is released before
// the publish because its bracket's capFlush takes that lock.
func strictPublishCopy(t *testing.T, f *walletFailFixture) (w *Wallet, basis []byte, gen string) {
	t.Helper()
	unlock := lockWallet(f.wpath)
	defer unlock()
	w, err := loadWallet(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	gen = walletGeneration(f.wpath)
	if !walletRestoreLanded(f.wpath, gen) {
		t.Fatal("control: the session's generation has no restore proof")
	}
	basis, _ = json.Marshal(w)
	return w, basis, gen
}

func strictPublishValue(t *testing.T, f *walletFailFixture) error {
	t.Helper()
	w, basis, gen := strictPublishCopy(t, f)
	_, err := sealWalletValueDurableStrict("s3", walletFailName, walletFailPass, f.dk, f.wpath, w, basis, gen, true)
	return err
}

func strictPublishFile(t *testing.T, f *walletFailFixture) error {
	t.Helper()
	_, err := sealWalletDurableStrict("s3", walletFailName, walletFailPass, f.dk, f.wpath)
	return err
}

func strictPublishHead() string {
	_, head, _ := headRefWith("s3", walletFailName+"#wallet", walletFailPass, refProbeStrict)
	return head
}

// strictPublishUnchanged: the store holds exactly the wallet it held, with X and Y in it.
func strictPublishUnchanged(t *testing.T, x string, before map[string]bool, head, what string) {
	t.Helper()
	if got := strictPublishHead(); got != head {
		t.Errorf("%s moved the #wallet head", what)
	}
	got := signOutMergeStored(t)
	if !reflect.DeepEqual(got, before) {
		t.Errorf("%s changed the stored wallet: %d tokens, want %d", what, len(got), len(before))
	}
	if !got[x] || !got[blindSeenKey(signOutMergeY())] {
		t.Errorf("%s: the stored wallet lost X (%v) or Y (%v)", what, got[x], got[blindSeenKey(signOutMergeY())])
	}
}

// E1: an unreadable copy, then the same call with the fault lifted.
func TestStrictWalletPublish_E1_TheValueSiblingWritesNoHeadThenMerges(t *testing.T) {
	f := walletFailSetup(t)
	x, want := signOutMergeStore(t, f)
	before, head := signOutMergeStored(t), strictPublishHead()

	back := f.walletFailWalletReads(t, 500)
	err := strictPublishValue(t, f)
	back()
	if !errors.Is(err, errStoredWalletUnreadable) {
		t.Fatalf("sealWalletValueDurableStrict over an unreadable copy = %v, want errStoredWalletUnreadable", err)
	}
	strictPublishUnchanged(t, x, before, head, "the strict publish over an unreadable copy")

	if err := strictPublishValue(t, f); err != nil {
		t.Fatalf("sealWalletValueDurableStrict with the fault lifted: %v", err)
	}
	signOutMergeAssert(t, x, want)
}

// E2: payRent itself, with the fault arriving after its lease and before its publish. The spend stays in the file, and
// the next save that can read publishes the merge.
func TestStrictWalletPublish_E2_PayRentWritesNoHeadThenTheNextSaveMerges(t *testing.T) {
	f := walletFailSetup(t)
	x, _ := signOutMergeStore(t, f)
	before, head := signOutMergeStored(t), strictPublishHead()
	spendable, err := loadWallet(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	held := twoWriterNonces(spendable)
	freeRenewedThrough = map[string]int64{}
	noWalletRenewed = map[string]*Wallet{}

	var back func()
	payRentLeaseDone = func() { back = f.walletFailWalletReads(t, 500) }
	t.Cleanup(func() { payRentLeaseDone = nil })
	_, paid, err := payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", walletFailName,
		walletFailPass, f.wpath, nil, f.gen())
	if back == nil {
		t.Fatal("fixture: payRent never reached its publish: its lease did not run")
	}
	back()
	if !paid || !errors.Is(err, errStoredWalletUnreadable) {
		t.Fatalf("payRent over an unreadable copy = (paid %v, %v), want paid and errStoredWalletUnreadable", paid, err)
	}
	strictPublishUnchanged(t, x, before, head, "payRent over an unreadable copy")

	after, err := loadWallet(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	local := twoWriterNonces(after)
	var spent []string
	for k := range held {
		if !local[k] {
			spent = append(spent, k)
		}
	}
	if len(spent) == 0 {
		t.Fatal("fixture: payRent's lease spent no token")
	}

	if _, err := sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath); err != nil {
		t.Fatalf("the next save: %v", err)
	}
	got := signOutMergeStored(t)
	if !got[blindSeenKey(signOutMergeY())] {
		t.Error("the next save lost Y, the other handset's token")
	}
	if got[x] {
		t.Error("the next save resurrected X, a token this session spent before payRent")
	}
	for _, k := range spent {
		if got[k] {
			t.Errorf("the next save resurrected %s, a token payRent spent", k)
		}
	}
	for k := range local {
		if !got[k] {
			t.Errorf("the next save lost %s, a token in this session's file", k)
		}
	}
}

// E3: the claim. Its three attempts all meet the fault, so it answers not saved and writes nothing; with the fault
// lifted the same seal lands the merge.
func TestStrictWalletPublish_E3_TheClaimAnswersUnsavedThenMerges(t *testing.T) {
	f := walletFailSetup(t)
	if err := markRoamSession(f.dest, walletFailName, walletFailPass, "10", ""); err != nil {
		t.Fatal(err)
	}
	x, want := signOutMergeStore(t, f)
	before, head := signOutMergeStored(t), strictPublishHead()
	sleeps := 0
	old := claimSealSleep
	claimSealSleep = func(time.Duration) { sleeps++ }
	t.Cleanup(func() { claimSealSleep = old })

	back := f.walletFailWalletReads(t, 500)
	saved := sealClaimedWallet(f.dest, walletFailName, walletFailPass, 2, f.gen())
	back()
	if saved {
		t.Error("the claim's seal over an unreadable copy reported saved")
	}
	if sleeps != 2 {
		t.Errorf("the claim's seal slept %d times, want 2: all three attempts run", sleeps)
	}
	strictPublishUnchanged(t, x, before, head, "the claim's seal over an unreadable copy")

	if !sealClaimedWallet(f.dest, walletFailName, walletFailPass, 2, f.gen()) {
		t.Fatal("the claim's seal did not land with the fault lifted")
	}
	signOutMergeAssert(t, x, want)
}

// strictPublishDamage flips one byte of the blob the #wallet head names.
func strictPublishDamage(t *testing.T, f *walletFailFixture) {
	t.Helper()
	k := "blob/" + strictPublishHead()
	f.objsMu.Lock()
	defer f.objsMu.Unlock()
	b, ok := f.objs[k]
	if !ok || len(b) == 0 {
		t.Fatalf("fixture: the store has no blob at %s", k)
	}
	damaged := append([]byte(nil), b...)
	damaged[0] ^= 0xff
	f.objs[k] = damaged
}

// strictPublishRemove removes every rung of the #wallet head's ladder.
func strictPublishRemove(t *testing.T, f *walletFailFixture) {
	t.Helper()
	wn := walletFailName + "#wallet"
	f.objsMu.Lock()
	defer f.objsMu.Unlock()
	removed := 0
	for _, ref := range []string{unitHeadRef(wn, walletFailPass, deviceUnitID()), profileRefV2(wn, walletFailPass), profileRefLegacy(wn, walletFailPass)} {
		if _, ok := f.objs["ref/"+ref]; ok {
			delete(f.objs, "ref/"+ref)
			removed++
		}
	}
	if removed == 0 {
		t.Fatal("fixture: the store has no #wallet head to remove")
	}
}

// E4: a damaged and an absent copy are not "unreadable": both siblings publish the local set, without Y.
func TestStrictWalletPublish_E4_ADamagedOrAbsentCopyStillPublishes(t *testing.T) {
	for _, tc := range []struct {
		copyState string
		change    func(*testing.T, *walletFailFixture)
		control   func(*Wallet, error) bool
	}{
		{"damaged", strictPublishDamage, func(_ *Wallet, err error) bool { return walletDamage(err) }},
		{"absent", strictPublishRemove, func(w *Wallet, err error) bool { return w == nil && err == nil }},
	} {
		for _, sib := range []struct {
			name    string
			publish func(*testing.T, *walletFailFixture) error
		}{
			{"value", strictPublishValue},
			{"file", strictPublishFile},
		} {
			t.Run(tc.copyState+" "+sib.name, func(t *testing.T) {
				f := walletFailSetup(t)
				x, want := signOutMergeStore(t, f)
				head := strictPublishHead()
				tc.change(t, f)
				capReadCache = map[string]capEntry{}
				blobCache = nil
				contentCache = nil
				w, _, err := readStoredWalletStrict("s3", walletFailName, walletFailPass, f.dk)
				if !tc.control(w, err) {
					t.Fatalf("control: the strict read of a %s copy = (%v, %v)", tc.copyState, w, err)
				}

				if err := sib.publish(t, f); err != nil {
					t.Fatalf("the %s sibling over a %s copy: %v", sib.name, tc.copyState, err)
				}
				if got := strictPublishHead(); got == "" || got == head {
					t.Fatalf("the %s sibling over a %s copy did not move the #wallet head", sib.name, tc.copyState)
				}
				// want is the session's 11 keys and Y; the local set alone holds the 11.
				y := blindSeenKey(signOutMergeY())
				var local []string
				for _, k := range want {
					if k != y {
						local = append(local, k)
					}
				}
				signOutMergeAssert(t, x, local)
			})
		}
	}
}

// Direct-store mode: payRent's publish merges before the mode branch, so it writes no head there either. The file
// sibling delegates to sealWallet, as sealWalletDurable does: self-hosted stays fail-soft on the backlog row's left list.
func TestStrictWalletPublish_DirectStoreModes(t *testing.T) {
	directBracketEnv(t)
	base := newHTTPStore(t)
	const name, pass = "strictpubdirect", "pass of the direct store"
	wp := directBracketWallet(t)
	dk := deriveKey(name, pass)
	basis, err := os.ReadFile(wp)
	if err != nil {
		t.Fatal(err)
	}
	w, err := loadWallet(wp)
	if err != nil {
		t.Fatal(err)
	}
	foldUnreadableSeam(t, errFoldStoreRead)

	_, err = sealWalletValueDurableStrict(base, name, pass, dk, wp, w, basis, walletGeneration(wp), true)
	if !errors.Is(err, errStoredWalletUnreadable) {
		t.Fatalf("sealWalletValueDurableStrict = %v, want errStoredWalletUnreadable", err)
	}
	if h := getRef(base, profileRefV2(name+"#wallet", pass)); h != "" {
		t.Fatalf("sealWalletValueDurableStrict wrote the #wallet head over an unreadable copy (%s)", h)
	}

	if _, err := sealWalletDurableStrict(base, name, pass, dk, wp); err != nil {
		t.Fatalf("sealWalletDurableStrict in direct-store mode: %v", err)
	}
	if getRef(base, profileRefV2(name+"#wallet", pass)) == "" {
		t.Fatal("sealWalletDurableStrict in direct-store mode did not delegate to sealWallet")
	}
}
