package main

import (
	"errors"
	"fmt"
	"os"
)

// NWP-20261112-14: A LANDED SIGN-OUT RENEWS THE WHOLE FOOTPRINT (Q088's device half).
//
// The gateway's plan hold drops the least recently presented rows first once a profile is over its plan, and it
// stamps a row with the DAY it was last presented (Q088). payRentGen is the only full-footprint lease, and it runs
// from maybePayRent after a periodic or manual seal only when renewalDue -- so a customer who renewed on day N and
// kept working for weeks signs out with every cold in-use chunk still on day N, tied with the chunks the session's
// seals replaced, and the hold can drop one still in use. So the sign-out renews too, after the session's last seal,
// unless the footprint was already renewed in this epoch (signOutRenewalDue, billing.go: the once-per-epoch rule).
//
// maybePayRent cannot be reused: it skips once .roamsession no longer names the profile, which a landed sign-out has
// already cleared. This runs inside handleLogout's "logout-wallet" goroutine, BEFORE logoutWalletStep, so the wallet
// that is published and dropped is the one this renewal left; the wallet drop and forgetSessionKeys wait until it
// returns, bounded by the gateway client's timeouts. The reap does not: reapOrReboot runs outside that goroutine.
// It holds no worker lane and no sessionMu. A sign-in that took the wallet meanwhile moves the generation, and
// payRentGenRule's own generation checks refuse to spend from or publish another profile's file.
//
// NWP-20261127-03: THESE LINES NAME ONLY THE USER (docs/backlog.md, "The sign-out renewal's login.log line keeps the
// profile name in cleartext until the next reap or boot: it is written after the reap's log scrub"). handleLogout runs
// this goroutine beside reapOrReboot, so its lines, and payRentGenRule's lines under renewSignOut (payRentWho), land
// after the reap's log scrub and stay in login.log until the next reap or boot. So no line here carries the name: each
// prints the user id, its error text passes redactNameIn with the profile's name (billing's errors name it, as the
// free tier's 402 does), and the deferred recover is signOutRenewalPanic, not the shared bestEffortPanic, which
// prints the name.

// signOutRenewalEngaged, when set (tests only), runs inside renewAtSignOut's recover, before any store read.
var signOutRenewalEngaged func()

// logoutRenewStep is what handleLogout's landed arm runs before logoutWalletStep. A seam for the tests.
var logoutRenewStep = renewAtSignOut

// renewAtSignOut renews the whole footprint of the session at dest that has just signed out, from the wallet
// generation gen handleLogout read before the session. se is the session's secure-element secret; uid is for the
// log line only. A no-op when the device has no managed-store gateway.
func renewAtSignOut(dest, name, pass string, se []byte, gen, uid string) {
	gw := os.Getenv("GATEWAY_URL")
	if gw == "" {
		return // managed-store billing not configured on this device
	}
	if !beginRent() {
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s: skipped -- an unsaved sign-out or restart is in progress\n", uid)
		return
	}
	defer endRent()
	defer func() { signOutRenewalPanic(uid, name, recover()) }() // billing must never crash the sign-out
	if signOutRenewalEngaged != nil {
		signOutRenewalEngaged()
	}
	// A FIDO2-2FA vault does not open without the key hmac in the process env (maybePayRent's B3 note).
	loadFido2HmacEnv(dest)
	wpath := walletPathFor(dest)
	w, err := loadWallet(wpath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s: error (%s)\n", uid, redactNameIn(logSafeStoreErr("signout-renewal", err), name))
		return
	}
	// maybePayRent's never-engaged gate: outside cap mode a session with no balance and no recorded lease is not on
	// the managed store, so the sign-out leases no more than the periodic path would.
	if w.balance() == 0 && w.PaidThrough == 0 && !capMode() {
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s: skipped (never engaged the managed store)\n", uid)
		return
	}
	info, paid, err := payRentGenSignOut(newGatewayClient(gw, gwDefault), "s3", name, pass, wpath, se, gen)
	switch {
	case err != nil:
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s: error (%s)\n", uid, redactNameIn(logSafeStoreErr("signout-renewal", err), name))
	case !paid:
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s: skipped (already renewed this epoch, or nothing stored)\n", uid)
	case info.Spent > 0:
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s: paid through epoch %d (%d token(s) spent)\n", uid, info.ThroughEpoch, info.Spent)
	default:
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s: renewed\n", uid)
	}
}

// signOutRenewalPanic is bestEffortPanic for renewAtSignOut with no name in the line (NWP-20261127-03): the user id,
// the same store-unreachable split, and the store error's text through redactNameIn with the profile's name.
func signOutRenewalPanic(uid, name string, r any) {
	if r == nil {
		return
	}
	if e, ok := r.(error); ok && errors.Is(e, errStoreUnreachable) {
		fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s -> skipped: store read FAILED after retries (%s)\n", uid,
			redactNameIn(logSafeStoreErr("signout-renewal", e), name))
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] signout-renewal user %s -> skipped: unexpected failure (details withheld)\n", uid)
}
