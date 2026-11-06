package main

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261013-20, review passes 5 and 6: the six findings a third fix review confirmed, and the three code and test
// findings of the five a fourth confirmed (pass 6), as regression tests. Each test names the guard it convicts; every
// one fails (`--- FAIL`) with that guard reverted.

// storedNonces is the set of nonces the profile's stored wallet holds, read strictly.
func storedNonces(t *testing.T) map[string]bool {
	t.Helper()
	w := readBackStored(t)
	out := make(map[string]bool, len(w.Tokens))
	for _, tk := range w.Tokens {
		out[tk.Nonce] = true
	}
	return out
}

// assertKeepsEvery fails unless the stored wallet still holds every nonce in before (the invariant: no publish drops
// a token the store held) and want tokens in all.
func (f *walletFailFixture) assertKeepsEvery(t *testing.T, before map[string]bool, want int, what string) {
	t.Helper()
	got := readBackStored(t)
	have := map[string]bool{}
	for _, tk := range got.Tokens {
		have[tk.Nonce] = true
	}
	for n := range before {
		if !have[n] {
			t.Fatalf("%s: the stored wallet lost token %s (it holds %d token(s), want %d)", what, n, got.balance(), want)
		}
	}
	if got.balance() != want {
		t.Fatalf("%s: the stored wallet holds %d token(s), want %d", what, got.balance(), want)
	}
}

// fundSession is the never-restored session's own credit: n faucet tokens in its (otherwise empty) wallet file.
func (f *walletFailFixture) fundSession(t *testing.T, n int) {
	t.Helper()
	toks, err := newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).buyFaucet(n)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(f.wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	freeRenewedThrough = map[string]int64{}
	noWalletRenewed = map[string]*Wallet{}
}

// ---- (1) a by-value publish is judged by the proof that stood WITH ITS COPY ----

// (R1, the reviewers' direct probe) A copy of a never-restored session's wallet, taken before its retry landed: the
// retry then merges the stored wallet in and proves the generation, and the next sign-in moves the generation on, so
// nothing compares the copy with the file any more. Published, it would replace the stored 10 with the session's 2.
// Both arms of sealWalletValueDurable refuse it on the flag read with the copy (convicts its `!proven` refusal).
func TestAByValuePublishOfACopyTakenBeforeTheRetryIsRefused(t *testing.T) {
	t.Run("cap mode", func(t *testing.T) {
		f := walletFailSetup(t)
		before := storedNonces(t)
		f.failedRoamIn(t)
		genA := f.gen()
		f.appendTwo(t)
		data, _ := os.ReadFile(f.wpath)
		w, _ := loadWallet(f.wpath)
		proven := walletRestoreLanded(f.wpath, genA) // read with the copy
		if proven {
			t.Fatal("fixture: the never-restored generation is proven")
		}
		if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, genA); err != nil {
			t.Fatalf("fixture: the retry did not land: %v", err)
		}
		removeWallet(f.wpath) // sign-out, and the next sign-in moves the generation on
		if !walletRestoreLanded(f.wpath, genA) || f.gen() == genA {
			t.Fatal("fixture: genA should be proven now, and the wallet at another generation")
		}
		_, err := sealWalletValueDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath, w, data, genA, proven)
		if !errors.Is(err, errWalletNotRestored) {
			t.Fatalf("the pre-merge copy's publish = %v, want errWalletNotRestored", err)
		}
		f.assertKeepsEvery(t, before, f.stored, "a pre-merge copy published after the retry proved its generation")
	})
	t.Run("direct-store", func(t *testing.T) {
		base := newHTTPStore(t)
		t.Setenv("GATEWAY_URL", "")
		t.Setenv("S3_ACCESS_KEY", "k")
		wp := filepath.Join(t.TempDir(), "wallet.json")
		if err := appendTokens(wp, newBlindTokens()); err != nil {
			t.Fatal(err)
		}
		gen := walletGeneration(wp)
		data, _ := os.ReadFile(wp)
		w, _ := loadWallet(wp)
		proven := walletRestoreLanded(wp, gen)
		markWalletRestoreLanded(wp, gen) // the retry lands after the copy; this arm has no byte comparison at all
		dk := deriveKey(walletFailName, walletFailPass)
		_, err := sealWalletValueDurable(base, walletFailName, walletFailPass, dk, wp, w, data, gen, proven)
		if !errors.Is(err, errWalletNotRestored) {
			t.Fatalf("the direct-store publish of a pre-merge copy = %v, want errWalletNotRestored", err)
		}
		if h := getRef(base, walletHeadKey(base, walletFailName, walletFailPass)); h != "" {
			t.Fatalf("the pre-merge copy was published (head %s)", short(h))
		}
	})
}

// (R2, the reviewers' payRentGen probe) payRent spends from a never-restored session's wallet and saves its record,
// then publishes that copy by value after releasing the lock. While the publish is on its way -- its own lease, the
// second one naming the wallet head -- the user signs out: the retry lands (merging the stored 10 in, proving the
// generation) and the next sign-in moves the generation on. Pass 4 then published the pre-merge copy over the stored
// wallet (10 -> 1). It must be refused by the proof read with the copy at payRent's phase-2 save; and nothing is lost
// by the refusal -- the file at that generation keeps the spend, and the merge carries it to the fold (convicts the
// non-departed capture in payRentGen).
func TestPayRentsByValuePublishOfAPreMergeCopyIsRefused(t *testing.T) {
	f := walletFailSetup(t)
	before := storedNonces(t)
	f.failedRoamIn(t)
	genA := f.gen()
	f.fundSession(t, 2)
	wref, _ := headWriteRef(walletFailName+"#wallet", walletFailPass)
	prof := profileRefV2(walletFailName, walletFailPass)
	var mu sync.Mutex
	naming, presented := 0, 0
	fired := false
	var retryErr error
	capStoreLeaseSeen = func(req leaseReq) {
		mu.Lock()
		defer mu.Unlock()
		if req.Profile != prof {
			return
		}
		if _, ok := req.Refs["ref/"+wref]; !ok {
			return
		}
		naming++
		if naming == 1 {
			presented = len(req.Tokens) + len(req.BlindTokens)
			return
		}
		if naming == 2 && !fired {
			fired = true
			retryErr = retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, genA)
			removeWallet(f.wpath)
		}
	}
	t.Cleanup(func() { capStoreLeaseSeen = nil })
	var err error
	out := captureStderr(t, func() {
		_, _, err = payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", walletFailName,
			walletFailPass, f.wpath, nil, genA)
	})
	capStoreLeaseSeen = nil // the sign-out below leases too, and must not trip the in-flight hook
	mu.Lock()
	didFire, firstPresented, rerr := fired, presented, retryErr
	mu.Unlock()
	if firstPresented == 0 {
		t.Fatalf("fixture: payRent's own lease presented no tokens, so it spent nothing; stderr:\n%s", out)
	}
	if didFire {
		// The by-value publish reached its lease: the scenario ran in flight, as on a device.
		if rerr != nil {
			t.Fatalf("fixture: the in-flight retry did not land: %v", rerr)
		}
	} else {
		// Refused before its lease. Play the same sign-out now: the retry lands, the sign-out's fold publishes the
		// merged wallet (the spend included), and the next sign-in moves the generation on.
		if !errors.Is(err, errWalletNotRestored) {
			t.Fatalf("payRent's publish of a copy taken while its generation was unproven = %v, want errWalletNotRestored", err)
		}
		if rerr := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, genA); rerr != nil {
			t.Fatalf("the sign-out's retry: %v", rerr)
		}
		foldingSeal(t, walletFailName, walletFailPass, f.dk)
		removeWallet(f.wpath)
	}
	// 10 stored + the session's 2, of which payRent's lease spent one.
	f.assertKeepsEvery(t, before, f.stored+1, "payRent's by-value publish against a retry in flight")
}

// (R1, the phase-1/phase-2 variant) the same, through the instant between leaseRefsGen's save and payRent's record
// (payRentLeaseDone): the retry lands there and the generation moves on, so payRent takes the departed branch and
// publishes leaseRefsGen's copy -- loaded before the merge. Judged by the proof leaseRefsGen read with its load
// (convicts that capture).
func TestPayRentsDepartedPublishOfALoadBeforeTheRetryIsRefused(t *testing.T) {
	f := walletFailSetup(t)
	before := storedNonces(t)
	f.failedRoamIn(t)
	genA := f.gen()
	f.fundSession(t, 2)
	var retryErr error
	payRentLeaseDone = func() {
		retryErr = retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, genA)
		removeWallet(f.wpath)
	}
	t.Cleanup(func() { payRentLeaseDone = nil })
	_, paid, err := payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", walletFailName,
		walletFailPass, f.wpath, nil, genA)
	if retryErr != nil {
		t.Fatalf("fixture: the retry did not land: %v", retryErr)
	}
	if !paid || !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("payRent's departed publish of a pre-merge load = (paid %v, %v), want paid and errWalletNotRestored", paid, err)
	}
	f.assertKeepsEvery(t, before, f.stored, "payRent's departed publish of a load taken before the retry")
}

// The other direction: a retry that lands between leaseRefsGen and payRent's record, with the generation unchanged,
// leaves a merged file; the record is saved over it and that copy IS taken with the proof standing, so it publishes
// -- the stored 10 plus the session's remaining token. Judging it by leaseRefsGen's earlier load would refuse a
// complete wallet (convicts the phase-2 capture from the other side).
func TestPayRentPublishesACopyTakenAfterTheRetryProvedIt(t *testing.T) {
	f := walletFailSetup(t)
	before := storedNonces(t)
	f.failedRoamIn(t)
	genA := f.gen()
	f.fundSession(t, 2)
	var retryErr error
	payRentLeaseDone = func() {
		retryErr = retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, genA)
	}
	t.Cleanup(func() { payRentLeaseDone = nil })
	_, paid, err := payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", walletFailName,
		walletFailPass, f.wpath, nil, genA)
	if retryErr != nil {
		t.Fatalf("fixture: the retry did not land: %v", retryErr)
	}
	if !paid || err != nil {
		t.Fatalf("payRent after a landed retry = (paid %v, %v), want paid and published", paid, err)
	}
	f.assertKeepsEvery(t, before, f.stored+1, "payRent's publish of a copy taken after the retry")
}

// sealWalletDurable reads its copy under the lock, and the proof with it: a generation that moved while it waited for
// the lock -- to one whose proof appears only while the head is on its way -- is refused, not published as this
// profile's wallet (convicts the under-lock capture and refusal in sealWalletDurable).
func TestSealWalletDurableJudgesTheProofReadWithItsCopy(t *testing.T) {
	f := walletFailSetup(t)
	before := storedNonces(t)
	f.signIn(t)
	f.appendTwo(t)
	unlock, st := lockWalletWithin(f.wpath, time.Second)
	if st != walletLocked {
		t.Fatal("fixture: could not take the wallet lock")
	}
	var mu sync.Mutex
	genB := ""
	var once sync.Once
	walletLockTrace = func(ev string) {
		if ev != "wait" {
			return
		}
		once.Do(func() { // the wallet changes hands while the seal waits
			bumpWalletGeneration(f.wpath)
			saveWallet(f.wpath, &Wallet{})
			mu.Lock()
			genB = f.gen()
			mu.Unlock()
			unlock()
		})
	}
	capStoreLeaseSeen = func(leaseReq) { // the arriving generation's own restore proves it while the head is on its way
		mu.Lock()
		g := genB
		mu.Unlock()
		if g != "" {
			markWalletRestoreLanded(f.wpath, g)
		}
	}
	t.Cleanup(func() { walletLockTrace = nil; capStoreLeaseSeen = nil; unlock() })
	_, err := sealWalletDurable("s3", walletFailName, walletFailPass, f.dk, f.wpath)
	if genB == "" {
		t.Fatal("fixture: the seal never waited for the lock, so the generation never moved under it")
	}
	if !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("sealWalletDurable over a generation that moved while it waited = %v, want errWalletNotRestored", err)
	}
	f.assertKeepsEvery(t, before, f.stored, "a durable seal of a copy taken at an unproven generation")
}

// A create's staged claim is published by value with the proof read under the lock with its copy: a staged claim
// whose generation has no proof is refused and STAYS STAGED -- it is the only other copy of the claim (convicts the
// capture in finishStagedClaim; with the flag forced true the publish is refused silently at the head and the staged
// file removed).
func TestAStagedClaimWhoseProofDidNotStandStaysStaged(t *testing.T) {
	f := walletFailSetup(t)
	before := storedNonces(t)
	staged := createStagingPath(walletFailName, walletFailPass)
	if err := appendTokens(staged, newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	if walletRestoreLanded(staged, walletGeneration(staged)) {
		t.Fatal("fixture: the staged claim's generation is proven")
	}
	out := captureStderr(t, func() { finishStagedClaim(walletFailName, walletFailPass, staged) })
	if w, err := loadWallet(staged); err != nil || w.balance() != 2 {
		t.Fatalf("the unproven staged claim did not stay (%v, %v); stderr:\n%s", w, err, out)
	}
	f.assertKeepsEvery(t, before, f.stored, "an unproven staged claim")
}

// ---- (2) a landing allocates nothing after the file lands ----

// blockNewFile stands in for a disk that refuses a NEW file at p: a directory there makes a write of p fail. A path
// that already holds a file is left alone -- a disk that is full refuses new pages, not renames of files it holds --
// so a REWRITE of a file staged before the block (a temp proof written again after the landing) is beyond it; that
// would cost a spurious forfeit, undone by a rename.
func blockNewFile(t *testing.T, p string) {
	t.Helper()
	if err := os.Mkdir(p, 0o700); err == nil {
		t.Cleanup(func() { os.Remove(p) })
	}
}

// refuseNewFilesOnceLanded makes the disk refuse every new file the moment a landing's file write has landed
// (walletRestoreFileLanded): the proof's temp file, the kept copy and the wallet's temp file. It reports whether the
// moment came, so a test cannot pass without reaching it.
func refuseNewFilesOnceLanded(t *testing.T, gen string) (fired func() bool) {
	t.Helper()
	var hit atomic.Bool
	walletRestoreFileLanded = func(wp string) {
		hit.Store(true)
		blockNewFile(t, walletRestoreLandedPath(wp, gen)+".tmp")
		blockNewFile(t, walletPrevPath(wp))
		blockNewFile(t, wp+".tmp")
	}
	t.Cleanup(func() { walletRestoreFileLanded = nil })
	return hit.Load
}

// After the merge is saved the disk refuses every new file: the proof's temp file, the kept copy and the wallet's.
// The retry still lands, because both were staged before the merge and only a rename is left (convicts staging the
// proof's temp file and the kept copy BEFORE the merge -- the hook fires right after the merge's save, so one written
// after it is refused -- and dropping the kept copy on success).
func TestARetryLandsWhenTheDiskRefusesNewFilesAfterItsMerge(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	gen := f.gen()
	fired := refuseNewFilesOnceLanded(t, gen)
	err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, gen)
	if !fired() {
		t.Fatalf("fixture: the merge never landed, so the disk never refused anything (retry = %v)", err)
	}
	if err != nil {
		t.Fatalf("a retry whose disk refuses new files after the merge = %v: something after the merge allocated", err)
	}
	if !walletRestoreLanded(f.wpath, gen) {
		t.Fatal("the landed retry wrote no proof")
	}
	if w, _ := loadWallet(f.wpath); w.balance() != f.stored+2 {
		t.Fatalf("the merged wallet holds %d, want %d", w.balance(), f.stored+2)
	}
	if _, err := os.Stat(walletPrevPath(f.wpath)); !os.IsNotExist(err) {
		t.Fatalf("a landed retry left its kept copy behind (stat err %v): it holds tokens nothing reads", err)
	}
}

// The roam-in's restore, the same way (pass 6): once the restored file is written the disk refuses every new file,
// and the restore still lands, because its proof was staged before the write (convicts staging BEFORE
// writeRestoredWallet's putWalletBytes).
func TestARoamInRestoreLandsWhenTheDiskRefusesNewFilesAfterItsWrite(t *testing.T) {
	f := walletFailSetup(t)
	gen := f.gen()
	fired := refuseNewFilesOnceLanded(t, gen)
	err := pullWalletStrict("s3", walletFailName, walletFailPass, f.dk, f.wpath)
	if !fired() {
		t.Fatalf("fixture: the restore never wrote the file, so the disk never refused anything (restore = %v)", err)
	}
	if err != nil {
		t.Fatalf("a restore whose disk refuses new files after its write = %v: something after the write allocated", err)
	}
	if !walletRestoreLanded(f.wpath, gen) {
		t.Fatal("the landed restore wrote no proof")
	}
	if w, _ := loadWallet(f.wpath); w.balance() != f.stored {
		t.Fatalf("the restored wallet holds %d, want the stored %d", w.balance(), f.stored)
	}
}

// The proof's rename fails (a directory at the proof's path), and the disk refuses every new file once the merge has
// landed: the undo is a rename of the copy kept before the merge, so the file goes back to the session's own tokens
// and nothing is proven -- never a merged file with no proof, whose next retry would bring a spent nonce back
// (convicts the undo by rename).
func TestARefusedProofIsUndoneByARenameWhenTheDiskRefusesNewFiles(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	gen := f.gen()
	before, _ := os.ReadFile(f.wpath)
	if err := os.Mkdir(walletRestoreLandedPath(f.wpath, gen), 0o700); err != nil {
		t.Fatal(err)
	}
	fired := refuseNewFilesOnceLanded(t, gen)
	var err error
	out := captureStderr(t, func() {
		err = retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, gen)
	})
	if !fired() {
		t.Fatalf("fixture: the merge never landed, so the disk never refused anything; stderr:\n%s", out)
	}
	if !errors.Is(err, errWalletNotRestored) || walletRestoreLanded(f.wpath, gen) {
		t.Fatalf("a retry whose proof could not be renamed = %v (proven %v), want errWalletNotRestored and no proof",
			err, walletRestoreLanded(f.wpath, gen))
	}
	if after, _ := os.ReadFile(f.wpath); string(after) != string(before) {
		t.Fatalf("the merge was not undone: the file holds %s, want %s; stderr:\n%s", after, before, out)
	}
	for _, p := range []string{walletPrevPath(f.wpath), walletRestoreLandedPath(f.wpath, gen) + ".tmp"} {
		if _, serr := os.Stat(p); !os.IsNotExist(serr) {
			t.Fatalf("the undone retry left %s behind (stat err %v)", filepath.Base(p), serr)
		}
	}
}

// A proof whose temp file cannot be written is refused BEFORE the merge: the wallet file is never replaced, so a
// disk that refuses a write never stands between a merge and its proof (convicts the staging order).
func TestARetryWhoseProofCannotBeStagedNeverTouchesTheFile(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	gen := f.gen()
	st0, err := os.Stat(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(walletRestoreLandedPath(f.wpath, gen)+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, gen); !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("a retry whose proof cannot be staged = %v, want errWalletNotRestored", err)
	}
	st1, err := os.Stat(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(st0, st1) {
		t.Fatal("the wallet file was replaced although the proof could not be staged: the merge ran first")
	}
	if walletRestoreLanded(f.wpath, gen) {
		t.Fatal("a retry whose proof could not be staged proved its generation")
	}
	if _, err := os.Stat(walletPrevPath(f.wpath)); !os.IsNotExist(err) {
		t.Fatalf("a refused staging left its kept copy behind (stat err %v)", err)
	}
}

// assertNothingStaged fails unless a refused landing for gen left no proof, no proof temp file and no kept copy.
func (f *walletFailFixture) assertNothingStaged(t *testing.T, gen, what string) {
	t.Helper()
	if walletRestoreLanded(f.wpath, gen) {
		t.Fatalf("%s proved its generation", what)
	}
	for _, p := range []string{walletPrevPath(f.wpath), walletRestoreLandedPath(f.wpath, gen) + ".tmp"} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s left %s behind (stat err %v)", what, filepath.Base(p), err)
		}
	}
}

// assertFileIs fails unless the wallet file still holds exactly before.
func (f *walletFailFixture) assertFileIs(t *testing.T, before []byte, what string) {
	t.Helper()
	if after, err := os.ReadFile(f.wpath); err != nil || string(after) != string(before) {
		t.Fatalf("%s changed the wallet file to %q (read err %v), want %q", what, after, err, before)
	}
}

// A merge that fails after its staging because the local file does not parse leaves nothing staged behind: no temp
// proof, no kept copy (convicts the discard on loadWallet's error path).
func TestAFailedMergeLeavesNothingStaged(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	gen := f.gen()
	if err := os.WriteFile(f.wpath, []byte("not a wallet"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, gen); err == nil {
		t.Fatal("a retry over a local file that does not parse landed")
	}
	f.assertNothingStaged(t, gen, "a failed merge")
	f.assertFileIs(t, []byte("not a wallet"), "a failed merge")
}

// (pass 6) A merge whose save fails after its staging -- the disk refuses the wallet's temp file -- merges nothing
// and leaves nothing staged: no temp proof, no kept copy of the session's tokens (convicts the discard on the merge
// save's error path).
func TestARetryWhoseMergeCannotBeSavedLeavesNothingStaged(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	gen := f.gen()
	before, _ := os.ReadFile(f.wpath)
	if err := os.Mkdir(f.wpath+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, gen); err == nil {
		t.Fatal("a retry whose merge could not be saved landed")
	}
	f.assertFileIs(t, before, "a retry whose merge could not be saved")
	f.assertNothingStaged(t, gen, "a retry whose merge could not be saved")
}

// (pass 6) A retry whose kept copy cannot be written -- a directory at wallet.json.prev -- is refused before the
// merge and leaves neither its temp proof nor its copy behind (convicts the discard when the kept copy cannot be
// written: without it both the temp proof and the planted directory stay behind, and either assertion fails).
func TestARetryWhoseKeptCopyCannotBeWrittenLeavesNothingStaged(t *testing.T) {
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	gen := f.gen()
	before, _ := os.ReadFile(f.wpath)
	if err := os.Mkdir(walletPrevPath(f.wpath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, gen); !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("a retry whose kept copy cannot be written = %v, want errWalletNotRestored", err)
	}
	f.assertFileIs(t, before, "a retry whose kept copy cannot be written")
	f.assertNothingStaged(t, gen, "a retry whose kept copy cannot be written")
}

// (pass 6) The roam-in's restore whose file write fails after its staging -- the disk refuses the wallet's temp file
// -- leaves the file as it was and nothing staged: no temp proof, no kept copy (convicts the discard on
// writeRestoredWallet's putWalletBytes error path). A file stands at the generation, so the staging keeps a copy too.
func TestARoamInRestoreWhoseFileCannotBeWrittenLeavesNothingStaged(t *testing.T) {
	f := walletFailSetup(t)
	f.appendTwo(t)
	gen := f.gen()
	before, _ := os.ReadFile(f.wpath)
	if err := os.Mkdir(f.wpath+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := pullWalletStrict("s3", walletFailName, walletFailPass, f.dk, f.wpath); err == nil {
		t.Fatal("a restore whose file could not be written landed")
	}
	f.assertFileIs(t, before, "a restore whose file could not be written")
	f.assertNothingStaged(t, gen, "a restore whose file could not be written")
}

// noWalletName / noWalletPass is a profile that has never stored a wallet: a strict read of its #wallet head proves
// there is none.
const noWalletName, noWalletPass = "walletnone", "a profile that never stored a wallet"

// (pass 6, the fourth review's P1 probe) A retry that PROVES there is no stored wallet changes no file: the session's
// file holds only its own claimed tokens, and stays as it is. When the disk refuses that proof's rename (a directory
// at the proof's path) the proof is forfeited, nothing is left staged, and the file keeps its tokens -- so the
// sign-out still sees the credit it must warn about. Pass 5's undo took "no kept copy" for "there was no file" and
// removed it: the claimed credit was deleted, silently (convicts the undo leaving a file its landing did not change).
func TestARetryThatProvesNoStoredWalletKeepsTheFileWhenItsProofIsRefused(t *testing.T) {
	run := func(t *testing.T, refuse bool) (f *walletFailFixture, gen string, before []byte, err error) {
		t.Helper()
		f = walletFailSetup(t)
		gen = f.gen()
		if walletRestoreLanded(f.wpath, gen) {
			t.Fatal("fixture: the session's generation is proven")
		}
		f.appendTwo(t)
		before, _ = os.ReadFile(f.wpath)
		if refuse {
			if merr := os.Mkdir(walletRestoreLandedPath(f.wpath, gen), 0o700); merr != nil {
				t.Fatal(merr)
			}
		}
		err = retryWalletRestore("s3", noWalletName, noWalletPass, nil, f.wpath, gen)
		return f, gen, before, err
	}
	t.Run("control: the absence is proven and the file kept", func(t *testing.T) {
		f, gen, before, err := run(t, false)
		if err != nil || !walletRestoreLanded(f.wpath, gen) {
			t.Fatalf("a retry that proves no stored wallet = %v (proven %v), want nil and the proof",
				err, walletRestoreLanded(f.wpath, gen))
		}
		f.assertFileIs(t, before, "a retry that proved no stored wallet")
	})
	t.Run("the proof's rename is refused: forfeited, the file kept", func(t *testing.T) {
		f, gen, before, err := run(t, true)
		if !errors.Is(err, errWalletNotRestored) {
			t.Fatalf("a retry whose proof of absence could not be renamed = %v, want errWalletNotRestored", err)
		}
		f.assertFileIs(t, before, "a refused proof of absence")
		if w, lerr := loadWallet(f.wpath); lerr != nil || w.balance() != 2 || !walletHoldsCredit(f.wpath) {
			t.Fatalf("after a refused proof of absence the session holds %v (%v): its claimed credit is gone", w, lerr)
		}
		f.assertNothingStaged(t, gen, "a refused proof of absence")
	})
}

// A kept copy a daemon death left mid-landing goes with the wallet at the next sign-in: it holds the departed
// session's tokens.
func TestRemoveWalletRemovesAKeptCopy(t *testing.T) {
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := os.WriteFile(walletPrevPath(wp), []byte(`{"blind_tokens":[{"msg":"m","sig":"s"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	removeWallet(wp)
	if _, err := os.Stat(walletPrevPath(wp)); !os.IsNotExist(err) {
		t.Fatalf("removeWallet left the kept copy (stat err %v)", err)
	}
}

// ---- (3, 4) every retry entry point honours the generation its caller captured ----

// (FREV-E through retrySessionWallet's own hand-off) the generation moves WHILE resolveDK reads the bare vault head --
// the store read between the outer check and the inner retry. Handed the caller's generation, the inner retry refuses;
// one that re-read the generation after resolveDK would merge A's stored wallet into B's file and prove B's
// generation (mutant M26). The proxy fires on resolveDK's own read, matched by the head's key, never on "the first
// request", so a cache serving that read cannot move the trigger into the strict read.
func TestASessionRetryRefusesAGenerationThatMovesWhileItResolvesTheKey(t *testing.T) {
	run := func(t *testing.T, move bool) (f *walletFailFixture, genA, genB string, err error, fires int32) {
		t.Helper()
		f = walletFailSetup(t)
		f.failedRoamIn(t)
		genA = f.gen()
		hk := headKey("s3", walletFailName, walletFailPass)
		if hk == "" {
			t.Fatal("fixture: the profile has no data head")
		}
		target, _ := url.Parse(f.srv.URL)
		proxy := httputil.NewSingleHostReverseProxy(target)
		var n atomic.Int32
		var mu sync.Mutex
		px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodGet && r.URL.Path == "/obj" && strings.Contains(r.URL.Query().Get("k"), hk) &&
				n.Add(1) == 1 && move {
				removeWallet(f.wpath) // B signs in while A's retry resolves A's key
				saveWallet(f.wpath, &Wallet{})
				mu.Lock()
				genB = f.gen()
				mu.Unlock()
			}
			proxy.ServeHTTP(w, r)
		}))
		defer px.Close()
		prev := os.Getenv("GATEWAY_URL")
		t.Setenv("GATEWAY_URL", px.URL)
		capReadCache = map[string]capEntry{}
		err = retrySessionWallet(f.dest, walletFailName, walletFailPass, nil, genA, walletSignInWait)
		t.Setenv("GATEWAY_URL", prev)
		capReadCache = map[string]capEntry{}
		mu.Lock()
		defer mu.Unlock()
		return f, genA, genB, err, n.Load()
	}
	t.Run("the generation moves during resolveDK: refused", func(t *testing.T) {
		f, genA, genB, err, fires := run(t, true)
		if fires < 1 || genB == "" || genB == genA || f.gen() == genA {
			t.Fatalf("fixture: the move did not happen during resolveDK's read (fires %d, genB %q)", fires, genB)
		}
		if !errors.Is(err, errWalletNotRestored) {
			t.Fatalf("a retry whose generation moved during resolveDK = %v, want errWalletNotRestored", err)
		}
		if w, _ := loadWallet(f.wpath); w.balance() != 0 {
			t.Fatalf("B's wallet holds %d token(s): A's stored wallet was merged into it", w.balance())
		}
		if walletRestoreLanded(f.wpath, genB) || walletRestoreLanded(f.wpath, genA) {
			t.Fatal("A's retry proved a generation")
		}
	})
	t.Run("control: nothing moves, the retry lands", func(t *testing.T) {
		f, genA, _, err, fires := run(t, false)
		if fires < 1 {
			t.Fatal("fixture: resolveDK's read never reached the store")
		}
		if err != nil || !walletRestoreLanded(f.wpath, genA) {
			t.Fatalf("the control retry = %v (proven %v): the proxy broke the read", err, walletRestoreLanded(f.wpath, genA))
		}
		if w, _ := loadWallet(f.wpath); w.balance() != f.stored {
			t.Fatalf("the control retry left %d token(s), want the stored %d", w.balance(), f.stored)
		}
	})
}

// staleStepFixture is A's never-restored session that B has replaced: B's generation, B's (empty) wallet file.
func staleStepFixture(t *testing.T) (f *walletFailFixture, genA, genB string) {
	t.Helper()
	f = walletFailSetup(t)
	f.failedRoamIn(t)
	genA = f.gen()
	removeWallet(f.wpath)
	genB = f.gen()
	if err := saveWallet(f.wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	return f, genA, genB
}

// (M21) a sign-out's wallet step handed A's generation over B's wallet reads nothing, merges nothing, proves nothing
// and reports no lost credit (B's file holds none).
func TestASignOutsWalletStepForAGenerationTheWalletLeftDoesNothing(t *testing.T) {
	f, genA, genB := staleStepFixture(t)
	n, back := f.countStoreRequests(t)
	lost := logoffWalletRetry(f.dest, walletFailName, walletFailPass, nil, genA)
	reads := n()
	back()
	if reads != 0 {
		t.Fatalf("A's stale sign-out step made %d store request(s)", reads)
	}
	if w, _ := loadWallet(f.wpath); w.balance() != 0 {
		t.Fatalf("B's wallet holds %d token(s) after A's stale sign-out step: merged", w.balance())
	}
	if walletRestoreLanded(f.wpath, genA) || walletRestoreLanded(f.wpath, genB) {
		t.Fatal("A's stale sign-out step proved a generation")
	}
	if lost {
		t.Fatal("A's stale sign-out step reported credit lost from B's empty wallet")
	}
}

// (M24) END-UNSAVED's wallet step handed A's generation over B's wallet merges nothing, proves nothing and publishes
// nothing. It resolves the key first (one store read), so no request count is asserted.
func TestEndUnsavedsWalletStepForAGenerationTheWalletLeftPublishesNothing(t *testing.T) {
	f, genA, genB := staleStepFixture(t)
	before := storedNonces(t)
	err := publishWalletBeforeDiscard(f.dest, walletFailName, walletFailPass, nil, genA)
	if !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("END's wallet step for A's generation over B's wallet = %v, want errWalletNotRestored", err)
	}
	if w, _ := loadWallet(f.wpath); w.balance() != 0 {
		t.Fatalf("B's wallet holds %d token(s) after END's stale step: merged", w.balance())
	}
	if walletRestoreLanded(f.wpath, genA) || walletRestoreLanded(f.wpath, genB) {
		t.Fatal("END's stale step proved a generation")
	}
	f.assertKeepsEvery(t, before, f.stored, "END's stale step")
}

// ---- (6) a sign-in that supersedes a parked cold-locked session ----

// parkColdLocked leaves the fixture's session the way a cold lock does: the .coldlock marker names user 15.
func (f *walletFailFixture) parkColdLocked(t *testing.T) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.dest, ".coldlock"), []byte(walletFailName+"\n15\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// rwWorker stands in for roamd on the RW lane, answering each op with answers[op] ("ERR-UNEXPECTED" for any other).
func rwWorker(t *testing.T, dest string, answers map[string]string) {
	t.Helper()
	done, finished := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(finished)
		for {
			if b, err := os.ReadFile(filepath.Join(dest, laneRW.req)); err == nil && strings.Count(string(b), "\n") >= 7 {
				os.Remove(filepath.Join(dest, laneRW.req))
				ans, ok := answers[strings.SplitN(string(b), "\n", 2)[0]]
				if !ok {
					ans = "ERR-UNEXPECTED"
				}
				os.WriteFile(filepath.Join(dest, laneRW.res), []byte(ans+"\n"), 0o600)
			}
			select {
			case <-done:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	t.Cleanup(func() { close(done); <-finished })
}

// loginWindowState saves and restores the login-window globals a driven ROAM-IN arms, so a later syncLoop test is
// not deferred by this one's window.
func loginWindowState(t *testing.T) {
	t.Helper()
	pendingReapMu.Lock()
	u, a, d := loginSettleUntil, loginWindowAt, loginDeferred
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		loginSettleUntil, loginWindowAt, loginDeferred = u, a, d
		pendingReapMu.Unlock()
	})
}

// supersededLine is the start of the supersede's log line, whatever uid it names; the parked one is user 15.
const supersededLine = "the superseded cold-locked session (user "

// The #123 supersede, online (handleRoamIn, here a throwaway sign-in, which runs the same block before its head==""
// return) and offline (handleRoamInOffline): over a parked stored session that never read its stored wallet and
// holds credit it logs ONE content-free line naming the parked uid, and records no gate notice; over a parked
// throwaway, a parked session whose restore landed, or no parked session at all, it logs nothing.
func TestASignInThatSupersedesAParkedSessionLogsItsLostCredit(t *testing.T) {
	signIn := map[string]func(t *testing.T, f *walletFailFixture) (string, string){
		"online": func(t *testing.T, f *walletFailFixture) (string, string) {
			loginWindowState(t)
			rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
			lateWorkDrain(t) // h46 #1: no late sign-in job outlives the test
			var reply string
			out := captureStderr(t, func() {
				reply = ropReply(t, func(c net.Conn) {
					handleRoamIn(c, f.dest, "someone-new", "a passphrase with no profile", "21", "", "")
				})
			})
			return reply, out
		},
		"offline": func(t *testing.T, f *walletFailFixture) (string, string) {
			rwWorker(t, f.dest, map[string]string{"btwipe": "OK"})
			var reply string
			out := captureStderr(t, func() {
				reply = ropReply(t, func(c net.Conn) {
					handleRoamInOffline(c, f.dest, "someone-new", "a passphrase with no profile", "21")
				})
			})
			return reply, out
		},
	}
	cases := []struct {
		name  string
		setup func(t *testing.T, f *walletFailFixture)
		lines int
	}{
		{"a parked never-restored session holding credit: one line", func(t *testing.T, f *walletFailFixture) {
			f.failedRoamIn(t)
			f.appendTwo(t)
			f.parkColdLocked(t)
		}, 1},
		{"a parked throwaway: none", func(t *testing.T, f *walletFailFixture) {
			f.failedRoamIn(t)
			f.appendTwo(t)
			markLocalSession(f.dest)
			f.parkColdLocked(t)
		}, 0},
		{"a parked session whose restore landed: none", func(t *testing.T, f *walletFailFixture) {
			f.signIn(t)
			f.appendTwo(t)
			f.parkColdLocked(t)
		}, 0},
		{"an ordinary sign-in, nothing parked: none", func(t *testing.T, f *walletFailFixture) {
			f.failedRoamIn(t)
			f.appendTwo(t)
		}, 0},
		{"a marker naming the arriving uid: none", func(t *testing.T, f *walletFailFixture) {
			f.failedRoamIn(t)
			f.appendTwo(t)
			if err := os.WriteFile(filepath.Join(f.dest, ".coldlock"), []byte(walletFailName+"\n21\n\n\n\n\n\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}, 0},
	}
	for path, drive := range signIn {
		for _, c := range cases {
			t.Run(path+"/"+c.name, func(t *testing.T) {
				f := walletFailSetup(t)
				c.setup(t, f)
				reply, out := drive(t, f)
				if !strings.HasPrefix(reply, "OK") {
					t.Fatalf("the sign-in replied %q; stderr:\n%s", reply, out)
				}
				if got := strings.Count(out, supersededLine); got != c.lines {
					t.Fatalf("the superseded-credit line was logged %d time(s), want %d; stderr:\n%s", got, c.lines, out)
				}
				for _, ln := range strings.Split(out, "\n") {
					if !strings.Contains(ln, supersededLine) {
						continue
					}
					if !strings.Contains(ln, supersededLine+"15) never read its stored wallet and holds credit") {
						t.Fatalf("the superseded-credit line does not name the parked user 15: %q", ln)
					}
					if strings.Contains(ln, walletFailName) || strings.Contains(ln, walletFailPass) {
						t.Fatalf("the superseded-credit line names the profile: %q", ln)
					}
				}
				if got := creditLostReply(f.dest); got != "NONE" {
					t.Fatalf("the supersede recorded the gate's notice (%q): it would blame the arriving session", got)
				}
				if _, err := os.Stat(filepath.Join(f.dest, ".coldlock")); !os.IsNotExist(err) {
					t.Fatalf("fixture: the sign-in did not drop the parked marker (stat err %v)", err)
				}
			})
		}
	}
}
