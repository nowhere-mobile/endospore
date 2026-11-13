package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"sync"
)

// NWP-20261017-02: A SIGN-OUT THAT LANDED TAKES THE WALLET OUT OF THE STATE TMPFS.
//
// wallet.json holds bearer blind tokens the gateway cannot re-issue. Before this, nothing removed it on a sign-out
// that did not reboot: it sat in /data/nowhere/state until the next sign-in or power-off. After the seal landed and
// the switch+reap was queued, sealLogoutWalletAndDrop publishes the departed session's wallet and then drops the file.
//
// ⚠ BY VALUE, NOT publishWalletBeforeDiscard. That one is safe for END-UNSAVED, which runs under sessionMu. A
// sign-out's goroutine holds no sessionMu and the reap is already queued, so a sign-in can replace the wallet while
// it runs; sealWalletDurable re-reads the file under the lock and judges the proof of WHATEVER generation it finds,
// publishing the ARRIVING profile's tokens to the DEPARTED profile's #wallet head. So the wallet is copied under the
// wallet lock at gen, together with gen's restore proof, and published with sealWalletValueDurable, which refuses a
// copy whose proof did not stand when it was taken and whose head write is the departed session's last word once the
// generation has moved on (putWalletHead).
//
// A generation with no restore proof KEEPS the file (errWalletNotRestored): the sign-out already went ahead without a
// wallet publish (logoffWalletRetry, whose notice is decided and unchanged), and the file is the only copy of what
// the session held. Every failure keeps it too. So does a generation whose stored wallet handleLogout could not read
// before its switch (NWP-20261201-22): nothing is published over a copy that could not be read.

// logoutWalletStep is what handleLogout runs once its seal has landed. A seam for the tests.
var logoutWalletStep = sealLogoutWalletAndDrop

// logoutWalletCaptured, when set (tests only), runs after the capture and before the publish.
var logoutWalletCaptured func()

// logoutWalletPublished, when set (tests only), runs after the publish and before the drop.
var logoutWalletPublished func()

// errLogoutWalletUnreadable refuses the publish of a generation whose stored wallet handleLogout could not read
// before its switch (NWP-20261201-22).
var errLogoutWalletUnreadable = errors.New("the stored wallet could not be read before the switch")

// logoutWalletUnreadableGens holds the generations whose stored wallet could not be read before the switch. Per
// generation, because the publish runs on a goroutine of its own and can outlast the next session's sign-out.
var (
	logoutWalletUnreadableMu   sync.Mutex
	logoutWalletUnreadableGens = map[string]bool{}
)

// setLogoutWalletUnreadable notes generation gen (v true) or clears its note.
func setLogoutWalletUnreadable(gen string, v bool) {
	logoutWalletUnreadableMu.Lock()
	defer logoutWalletUnreadableMu.Unlock()
	if v {
		logoutWalletUnreadableGens[gen] = true
	} else {
		delete(logoutWalletUnreadableGens, gen)
	}
}

// logoutWalletUnreadable reports whether generation gen carries the note.
func logoutWalletUnreadable(gen string) bool {
	logoutWalletUnreadableMu.Lock()
	defer logoutWalletUnreadableMu.Unlock()
	return logoutWalletUnreadableGens[gen]
}

// sealLogoutWalletAndDrop publishes the wallet of the session at dest that has just signed out, by value, and drops
// wallet.json while it still holds those bytes at gen. gen is the generation handleLogout read BEFORE the session;
// uid is for the log line only. dropped is false with a nil err when there was nothing to drop or the file was kept
// because it had changed (logged).
func sealLogoutWalletAndDrop(dest, name, pass string, se []byte, gen, uid string) (dropped bool, err error) {
	wp := walletPathFor(dest)
	defer func() {
		if r := recover(); r != nil {
			dropped, err = false, fmt.Errorf("panic: %s", logSafeStoreErr("wallet", panicAsErr(r)))
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "[logind] logout wallet user %s: NOT published, kept (%s)\n", uid, redactNameIn(logSafeErrText(err), name))
		}
	}()
	if _, serr := os.Stat(wp); serr != nil {
		if errors.Is(serr, fs.ErrNotExist) {
			return false, nil
		}
		return false, serr
	}
	if logoutWalletUnreadable(gen) {
		return false, errLogoutWalletUnreadable
	}
	basis, proven, err := captureLogoutWallet(wp, gen)
	if err != nil {
		return false, err
	}
	if !proven {
		return false, errWalletNotRestored
	}
	if logoutWalletCaptured != nil {
		logoutWalletCaptured()
	}
	var w Wallet
	if err := json.Unmarshal(basis, &w); err != nil {
		return false, errors.New("the wallet file could not be parsed")
	}
	dk, err := logoutWalletDK(name, pass, se)
	if err != nil {
		return false, err
	}
	if _, err := sealWalletValueDurable("s3", name, pass, dk, wp, &w, basis, gen, proven); err != nil {
		return false, fmt.Errorf("%s", logSafeStoreErr("wallet", err))
	}
	if logoutWalletPublished != nil {
		logoutWalletPublished()
	}
	dropped, why := dropWalletIfUnchanged(wp, gen, basis)
	if dropped {
		fmt.Fprintf(os.Stderr, "[logind] logout wallet user %s: published and dropped\n", uid)
	} else {
		fmt.Fprintf(os.Stderr, "[logind] logout wallet user %s: published, kept (%s)\n", uid, redactNameIn(why, name))
	}
	return dropped, nil
}

// captureLogoutWallet copies the wallet file at gen under the wallet lock, with whether gen's restore proof stood
// when the copy was taken, and releases the lock before it returns: no holder of the wallet lock may call a durable
// seal. Anything but a held lock refuses (the lock fails open, and a copy taken without it can be half another
// writer's).
func captureLogoutWallet(wp, gen string) (basis []byte, proven bool, err error) {
	unlock, state := lockWalletWithin(wp, walletLogoffRetryWait)
	defer unlock()
	if state != walletLocked {
		return nil, false, errors.New("the wallet lock could not be taken")
	}
	if !walletAtGeneration(wp, gen) {
		return nil, false, errors.New("the wallet changed hands before it could be read")
	}
	basis, err = os.ReadFile(wp)
	if err != nil {
		return nil, false, err
	}
	return basis, walletRestoreLanded(wp, gen), nil
}

// logoutWalletDK resolves the profile's data key (a store read), turning a panic or a nil key into an error.
func logoutWalletDK(name, pass string, se []byte) (dk []byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			dk, err = nil, fmt.Errorf("the key read failed: %s", logSafeStoreErr("wallet", panicAsErr(r)))
		}
	}()
	dk = resolveDK("s3", name, pass, se)
	if dk == nil {
		return nil, errors.New("no keyslot opens this profile's vault")
	}
	return dk, nil
}
