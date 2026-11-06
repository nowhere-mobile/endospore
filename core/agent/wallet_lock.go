package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// NWP-20261010-04: ONE WRITER OF THE WALLET FILE AT A TIME, ACROSS PROCESSES.
//
// The wallet is one file, $NOWHERE_STATE/wallet.json, in the boot-lifetime tmpfs, and every writer of it is a
// read-modify-write: load, change, save (temp+rename). Two of those overlapping lose one write. The writers
// that overlap in the field: payRent's leaseRefs (login daemon) loads, SPENDS, makes a gateway round trip and
// saves; the capFlush of every bracket whose wallet is its own does the same -- in the daemon (an export, a
// re-key batch, the durable wallet seal) and in the SEPARATE agent process nowhere_roamd.sh spawns for every
// periodic and logoff seal, which pays from this same file (it exports NOWHERE_STATE for exactly that); and the
// CLAIM verb records the plan and appends freshly minted tokens. (A credential change and a gate-side
// add-device run walletNotOurs: they neither spend from the file nor write it, and take no lock.) A lost spend
// record resurrects nonces the gateway holds spent (redemption is all-or-nothing, so a later purchase carrying
// one is refused 409 whole); a lost append loses bearer tokens the gateway cannot re-issue.
//
// So the lock is flock(2) on a SIDECAR file, not a sync.Mutex: a mutex cannot see the other process. flock
// also excludes two open()s inside one process (the lock belongs to the open file description, and every
// lockWallet opens its own), so goroutines in the daemon exclude each other through it too. Go opens with
// O_CLOEXEC, so an exec'd child never inherits a held lock.
//
// ⚠ NEVER DELETE THE .lock FILE. A waiter that opens it after an unlink creates a NEW inode and locks that,
// while the holder still holds the old one: both proceed, and nothing says so. It is a zero-byte file in a
// tmpfs that power-off clears. removeWallet and dropWalletIfUnchanged are the only ways the wallet leaves the
// state dir, and wipeSessionState goes through the first.
//
// ⚠ IT FAILS OPEN. If the lock file cannot be opened or locked (an SELinux denial, ENOLCK), lockWallet logs
// one line and returns a no-op: the caller proceeds UNLOCKED, which is exactly the behaviour before this slice.
// The alternative is worse: a lock that cannot be taken would refuse every seal on the device, and an
// amnesiac device's refused seal is its only copy of the session. No policy change was needed: `nowhere` and
// `endospore_priv` both hold create_file_perms on nowhere_data_file, which includes `lock`, and Diaspore's
// worker is su:s0. A lock that is merely BUSY past the wait is a different case: lockWallet proceeds unlocked
// after walletLockWait, but capFlush asks lockWalletWithin and gives up its wallet instead (see there).
//
// ⚠ LOCK ORDER: a cap bracket (capBracketMu) MAY be held when taking the wallet lock -- capFlush does exactly
// that -- NEVER the reverse. No holder of the wallet lock may call capBegin, capFlush, capWrite*,
// sealWalletDurable, triggerRoamWorker, or anything else that waits on another goroutine or process which
// itself takes the wallet lock. A violation deadlocks against ITSELF: flock on a second descriptor in the
// same process blocks like any other contender, and here it waits out the bound and then proceeds without
// the lock, defeating it. payRent releases before its sealWalletDurable for this reason. A holder MAY make a
// gateway or store round trip that takes no lock (leaseRefs leases, drainClaim mints, capFlush leases).
//
// Pure readers stay unlocked: saveWallet is temp+rename, so a reader sees the whole old file or the whole new.
//
// ⚠ THE GENERATION: WHOSE WALLET THE FILE IS. A sign-in, a create and the legacy wipes REPLACE the wallet --
// another profile's arrives -- and they cannot wait out a long holder: the chooser gives a sign-in 120 s and a
// create 90 s, and a create that runs past that has made the profile and lost its one-time recovery code. The
// realistic long holder is the DEPARTED session's payRent, which syncLoop runs after the seal and which can
// outlive the logoff by a full-footprint lease (leaseBudget, twice on a 409). So removeWallet bumps the
// generation in wallet.json.gen FIRST, waits at most walletSignInWait, and then removes the file with or without
// the lock. Every writer that can outlive its session -- leaseRefs, payRent's record, capFlush's saves --
// records the generation when it loads, under the lock, and checks it again under the lock immediately before
// it saves, with nothing slow in between. A changed generation means the file is somebody else's now: the
// writer does not save, and payRent publishes what it spent to ITS OWN profile's #wallet head instead, by value,
// under its own credentials -- so a spend is never lost from the departed profile's durable record, and never
// written into the arriving profile's file.
//
// The bound is airtight except for one holder: a removal that times out happened while the holder was still
// in its slow phase, BEFORE its check (the check-to-unlock stretch is a local write, microseconds, so a holder
// in it would have released within the wait). It therefore checks after the bump and refuses. The exception is
// a holder SUSPENDED for walletSignInWait between its check and its rename. The wipes in handleCreate and the
// legacy paths go through removeWallet too; drainClaim and claimTokens need no check, because CLAIM and
// CREATE-CODE take sessionMu, as ROAM-IN and CREATE do, so no claim spans a sign-in. And payRent is handed the
// generation its caller read BEFORE the session (maybePayRent), so one that starts after a sign-in is refused
// before it spends anything.

// walletLockWait bounds a DAEMON-SIDE wait for the wallet lock that nobody is waiting on (payRent's lease and
// record, the CLI). It must outlast the LONGEST legitimate holder, because a waiter that gives up proceeds
// unlocked -- the race this lock exists to close. (capFlush waits capFlushWalletWait; anything a person is
// waiting on -- a sign-in, a create, a claim, a durable wallet seal's read -- walletSignInWait.)
//
// The longest holder is capFlush's window, from its loadWallet to its last wallet save. It makes up to THREE
// /lease calls (the free probe, the entitled lease, the token-less retry after a 409), each on leaseClient,
// whose deadline leaseBudget(len(refs)) is capped at gwLeaseMax: 3 x 5 min = 15 min. And up to THREE
// readStoredWallet calls (one per doFold), each FIVE store reads -- headKey's refProbe ladder (the unit head
// under multi-device, v2, legacy), then getRef, then getBlob. A read is a /caps round trip (gwDefault, 30 s)
// and an object GET (storeHTTP, 60 s), so one fully timed-out attempt costs 90 s: 15 x 90 s = 22.5 min.
//
//	3 x gwLeaseMax + 15 x (gwDefault + storeHTTP) = 15 min + 22.5 min = 37.5 min
//
// leaseRefs holds for at most two leases (10 min). drainClaim takes the lock per /issue batch but re-takes it at
// once, so a waiter polling every walletLockPoll sees the whole drain as one hold: about fifty round trips for
// the largest plan (a 1 TB annual claim, batches doubling to 256). Every other holder is a local file write.
//
// ⚠ NOT A HARD CEILING ON THE HOLDER: capGet retries a failing read up to five times, and an older gateway's
// /caps falls back to a second round trip, so a store that times out on every attempt can stretch a holder
// past this. A waiter then proceeds unlocked and logs it -- today's behaviour, in a case that also needs the
// store to be failing.
var walletLockWait = 3*gwLeaseMax + 15*(gwDefault+storeHTTP.Timeout)

// walletSignInWait bounds every wallet-lock wait a person is waiting on: removeWallet and the restore (a
// sign-in, a create, the legacy wipes), a claim before it mints, and sealWalletDurable's read. The chooser gives
// ROAM-IN 120 s and CREATE 90 s, and a login's own restore, vault and store round trips share that budget; a
// sign-in's removal and restore together stay under 20 s, which TestSignInWalletWaitsFitTheChoosersBudget holds.
// A wait that runs out is not an error: removal and restore proceed (THE GENERATION), a claim is refused before
// it mints (errWalletBusy), and the durable seal reads anyway (its head is still checked by putWalletHead).
var walletSignInWait = 10 * time.Second

// capFlushWalletWait bounds capFlush's wait for the wallet lock, and it is short ON PURPOSE. In the seal
// WORKER that wait sits in the stretch with no progress -- writeProg(0, total) before the quote, nothing again
// until the first PUT -- and runWorkerHeld reports ERR-TIMEOUT after roamStallBudget (150 s) without a CHANGE in
// roam.progress. A worker that waited out a payRent lease there (leaseBudget, up to 5 min, twice on a 409)
// failed a healthy logoff, and its late reply could be read as the NEXT op's answer.
// TestSealGatewayLegFitsTheStallBudget counts it beside the quote and the lease: (2 x gwDefault + 5 s) x 2 =
// 130 s against 150 s. ⚠ That test's model is the one it already had -- one quote and one lease, each at
// gwDefault. A lease budget above gwDefault, the 402-then-entitled second lease and the folds' store reads were
// outside it before this slice and still are; this wait is kept small so it eats as little of the margin as it
// can, not because the stretch is proven to fit.
//
// When it runs out the flush does NOT proceed unlocked: it treats the wallet as not its own for this flush --
// the walletNotOurs path that already exists -- so it spends nothing, folds nothing, saves nothing, and its
// data still lands on the free tier, a live grant, or grace. The writer holding the lock is changing the wallet
// and has its own publish; a purchase waiting to start is activated by the next flush or by payRent.
var capFlushWalletWait = 5 * time.Second

// capFlushHeadWait is putWalletHead's wait for the lock: none. It sits in capFlush's SECOND silent stretch --
// after the last blob's progress write, through the fold blob, every pointer PUT and this -- and a holder busy
// there is checked for without the lock instead (putWalletHead). TestSealGatewayLegFitsTheStallBudget counts it.
const capFlushHeadWait = time.Duration(0)

// walletGeneration is the wallet's current generation token, "" before the first removal of this boot.
//
// NWP-20261013-20: a .gen that exists but cannot be read (a directory in its place, an I/O error) is
// walletGenUnreadable, never "": "" is a real generation, and an unreadable one read as "" would pass for a session
// that has its restore proof. No proof is ever written for walletGenUnreadable, so every publish judged by it is
// refused (walletRestoreLanded).
func walletGeneration(walletPath string) string {
	g, _ := walletGenerationErr(walletPath)
	return g
}

// walletGenUnreadable is walletGeneration's answer for a .gen it cannot read. Not a value bumpWalletGeneration can
// write (that is hex), so it never equals a real generation.
const walletGenUnreadable = "!unreadable"

// walletGenerationErr is walletGeneration with the read error: ("", nil) when there is no .gen file,
// (walletGenUnreadable, err) when there is one that cannot be read.
func walletGenerationErr(walletPath string) (string, error) {
	b, err := os.ReadFile(walletPath + ".gen")
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", nil
		}
		return walletGenUnreadable, err
	}
	return string(b), nil
}

// bumpWalletGeneration gives the wallet a new generation (temp+rename, so a reader sees one or the other), and says
// when it could not.
func bumpWalletGeneration(walletPath string) error {
	var r [8]byte
	if _, err := rand.Read(r[:]); err != nil {
		binary.BigEndian.PutUint64(r[:], uint64(time.Now().UnixNano()))
	}
	tmp := walletPath + ".gen.tmp"
	if err := os.WriteFile(tmp, []byte(hex.EncodeToString(r[:])), 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, walletPath+".gen"); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// errNoWalletFile is a lease made with no wallet file (leaseRefsGen): it renewed, presented nothing, and nothing
// may be saved or published from it -- a missing file is not an empty wallet.
var errNoWalletFile = errors.New("no wallet file -- the lease renewed; nothing was saved or published")

// errWalletBusy is a claim refused BEFORE it minted, because another writer held the wallet for all of
// walletSignInWait: nothing was redeemed, so a retry finishes it (drainClaim).
var errWalletBusy = errors.New("the wallet is busy -- the claim was refused before anything was minted; try again")

// errWalletChangedHands is what a writer returns when the generation it loaded under is gone before it could
// save: the file is another profile's now, and nothing was written to it.
var errWalletChangedHands = errors.New("the wallet changed hands (a sign-in or a create replaced it) -- not saved")

// walletReplaced carries what leaseRefs SPENT when the wallet changed hands during its lease: the post-settle
// wallet, which payRent publishes to its own profile's #wallet head because the file is no longer its to save.
type walletReplaced struct{ w *Wallet }

func (e *walletReplaced) Error() string { return errWalletChangedHands.Error() }
func (e *walletReplaced) Unwrap() error { return errWalletChangedHands }

// walletLockPoll is how often a waiter retries. Polling LOCK_NB rather than blocking in LOCK_EX is what makes
// the wait bounded: a blocked flock cannot be given a deadline.
var walletLockPoll = 100 * time.Millisecond

// walletLockTrace, when set (tests only), is called with "wait" the first time a lockWallet finds the lock held
// by someone else, so a test can force an interleaving without sleeping.
var walletLockTrace func(event string)

// walletLockState says how a lockWalletWithin came out.
type walletLockState int

const (
	walletLocked          walletLockState = iota // held; release with the returned func
	walletLockUnavailable                        // could not open or lock the file: proceed unlocked (FAILS OPEN)
	walletLockBusy                               // someone else held it for the whole wait
)

// lockWallet takes the exclusive lock guarding the wallet file at path, waiting at most walletLockWait, and
// returns the function that releases it. The release is idempotent, so a caller can both release early and
// defer it for its panic paths. On any failure it logs and returns a no-op (see FAILS OPEN above).
func lockWallet(path string) (unlock func()) {
	unlock, state := lockWalletWithin(path, walletLockWait)
	if state == walletLockBusy {
		fmt.Fprintf(os.Stderr, "[agent] wallet lock: proceeding UNLOCKED (NWP-20261010-04)\n")
	}
	return unlock
}

// lockWalletWithin is lockWallet with the wait and the outcome in the caller's hands. Whatever the state, the
// returned unlock is safe to call (a no-op unless the state is walletLocked).
func lockWalletWithin(path string, wait time.Duration) (unlock func(), state walletLockState) {
	noop := func() {}
	lp := path + ".lock"
	f, err := os.OpenFile(lp, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent] wallet lock: cannot open %s: %v -- proceeding UNLOCKED (NWP-20261010-04)\n", lp, err)
		return noop, walletLockUnavailable
	}
	fd := int(f.Fd())
	start := time.Now()
	waited := false
	for {
		err = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			break
		}
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if !errors.Is(err, unix.EWOULDBLOCK) {
			f.Close()
			fmt.Fprintf(os.Stderr, "[agent] wallet lock: cannot lock %s: %v -- proceeding UNLOCKED (NWP-20261010-04)\n", lp, err)
			return noop, walletLockUnavailable
		}
		if !waited {
			waited = true
			if walletLockTrace != nil {
				walletLockTrace("wait")
			}
		}
		if time.Since(start) >= wait {
			f.Close()
			fmt.Fprintf(os.Stderr, "[agent] wallet lock: %s still held after %s (NWP-20261010-04)\n", lp, wait)
			return noop, walletLockBusy
		}
		time.Sleep(walletLockPoll)
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			_ = unix.Flock(fd, unix.LOCK_UN)
			f.Close() // closing alone would release it too; the explicit unlock says what this is for
		})
	}, walletLocked
}

// removeWallet hands the wallet over: it bumps the generation, then deletes the wallet file -- and a save's temp
// file, if a writer died between its write and its rename -- under the lock if it can be had within
// walletSignInWait, and without it otherwise (NWP-20261010-04). The bump comes FIRST, so a holder still in its
// slow phase finds it at its check and does not save; see THE GENERATION above. Never the .lock.
//
// NWP-20261013-20: and it bumps AGAIN once it has the lock (or has waited it out), before the removal. A writer that
// won the lock in the gap after the first bump loaded under that generation, so its save check would pass against
// it; the second bump makes that writer's check fail too, whenever it saves. Neither bump's generation has a restore
// proof (wallet_restore.go), so nothing loaded under either can publish a wallet. If NEITHER bump lands, the
// generation stays the departed session's, and so would its proof: that proof is forfeited, so the arriving session
// publishes nothing until its own restore lands and proves it again. And it removes the copy a staged restore keeps
// of the file it replaces (wallet.json.prev, stageWalletLanding), which a daemon that died mid-landing leaves behind:
// it holds the departed session's tokens.
func removeWallet(walletPath string) {
	old := walletGeneration(walletPath)
	err1 := bumpWalletGeneration(walletPath)
	unlock, state := lockWalletWithin(walletPath, walletSignInWait)
	defer unlock()
	if state == walletLockBusy {
		fmt.Fprintf(os.Stderr, "[agent] wallet lock: removing the wallet without it -- the holder is before its "+
			"generation check and will not save (NWP-20261010-04)\n")
	}
	if err2 := bumpWalletGeneration(walletPath); err2 != nil && err1 != nil {
		fmt.Fprintf(os.Stderr, "[agent] wallet: the generation could NOT be moved on (%v) -- the departed session's "+
			"restore proof is forfeited, so nothing publishes a wallet until a restore lands again (NWP-20261013-20)\n", err2)
		forfeitWalletRestoreLanded(walletPath, old)
	}
	os.Remove(walletPath)
	os.Remove(walletPath + ".tmp")
	os.Remove(walletPrevPath(walletPath))
	os.Remove(walletPath + ".seen")
	os.Remove(seenBadPath(walletPath))
	os.Remove(planMovingPath(walletPath)) // NWP-20261103-05: the plan-moving notice never outlives the session
}

// dropWalletIfUnchanged is a sign-out's removal of the wallet it has just published (NWP-20261017-02): wallet.json
// leaves the state dir only while it is still the departed session's file -- generation gen, holding exactly basis,
// the bytes that were published -- so a bearer token is never left in the tmpfs after its session, and never taken
// from one that has since been replaced or has moved on. It returns whether it dropped, and the reason when not.
//
// The lock is taken with lockWalletWithin and anything but walletLocked KEEPS the file: the lock fails open, and a
// drop that raced a writer is the loss this exists to prevent. Under it the generation is bumped before the
// removal, so a writer of the departed session that loaded the file under gen finds it gone at its own check.
// Removes the wallet, its temp file and the staged copy (walletPrevPath). NEVER the .lock, the .gen, a .landed-*
// proof (a departed session's late publisher still asks about its generation) or the .creditlost notice.
func dropWalletIfUnchanged(walletPath, gen string, basis []byte) (bool, string) {
	unlock, state := lockWalletWithin(walletPath, walletSignInWait)
	defer unlock()
	switch state {
	case walletLockBusy:
		return false, "lock busy"
	case walletLockUnavailable:
		return false, "lock unavailable"
	}
	if !walletAtGeneration(walletPath, gen) {
		return false, "the wallet changed hands"
	}
	cur, err := os.ReadFile(walletPath)
	if err != nil || !bytes.Equal(cur, basis) {
		return false, "the wallet changed since it was published"
	}
	if err := bumpWalletGeneration(walletPath); err != nil {
		return false, fmt.Sprintf("the generation could not be moved on: %v", err)
	}
	// A removal that fails (anything but already-gone) leaves bearer tokens in the tmpfs: say so, never "dropped".
	var left []string
	for _, p := range []string{walletPath, walletPath + ".tmp", walletPrevPath(walletPath), walletPath + ".seen", seenBadPath(walletPath)} {
		if err := walletRemoveFile(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
			left = append(left, filepath.Base(p))
		}
	}
	if len(left) > 0 {
		return false, "could not remove " + strings.Join(left, ", ")
	}
	return true, ""
}

// walletRemoveFile is os.Remove; a seam so a test can fail a removal.
var walletRemoveFile = os.Remove

// scopeProfileDK resolves the PROFILE's data key for a scope flush that is about to buy, or nil (NWP-20261010-04).
// The scope's own DK cannot seal the wallet (NWP-20260904-03), so this is what lets that flush publish the wallet
// it spent from. nil se is right in the seal worker, where openVaultDKSE's env rung (NOWHERE_SE_SECRET) still
// opens a hardened vault (resolveDK). A store failure is nil as well: the caller then buys nothing, which is safe.
func scopeProfileDK(base, pass string) (dk []byte) {
	defer func() {
		if recover() != nil {
			dk = nil
		}
	}()
	return resolveDK("s3", base, pass, nil)
}
