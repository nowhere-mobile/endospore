package main

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"strconv"
)

// The unusable-claim notice (NWP-20261208-03; decided 2026-11-03, h55 #1 in docs/product-decisions.md): "When the
// deferred drain finds the code unknown or spent, it clears the pending entry in the same wallet publish, and Profile
// says that the code could not be used, that the profile is on the free plan, and that a code can be entered under Add
// credits". drainPendingClaims (pending_claim.go) leaves the notice in Wallet.UnusableClaims; this file is the free-plan
// test it uses and the two Profile verbs that serve it:
//
//	GET-CLAIM-NOTICE\n         -> NOTICE <n>\n (n >= 1: notices Profile has not shown yet) | NONE\n
//	CLAIM-NOTICE-SHOWN\n<n>\n  -> OK\n (the first n cleared) | BUSY\n (wallet lock held) | NONE\n (no live stored session
//	                              or wallet) | ERR-ARGS\n (n not a positive integer) | ERR\n
//
// Neither verb names a code or a hash: the answers are counts.

// claimNoticeFree reports whether w is on the free plan, for h55 #1's notice: no credit, no waiting or queued purchase,
// and no plan ever recorded. The words of the notice say the profile is on the free plan, so a wallet that is not
// gets none. That also keeps the notice true for a code keepPendingClaim staged (h60 #15): such a code can land tokens
// in one session and clear on the miss path in a later one, and it WAS used.
//
// NOT PaidThrough: a free lease advances it (the free lease's through, billing.go), so a free profile can be paid
// through a date in the future. PlanGB survives activation and AccountPlanGB is only raised (the gateway's answer), so
// either one set means a plan was recorded.
func claimNoticeFree(w *Wallet) bool {
	return w.balance() == 0 && !w.planPending() && len(w.PlanQueue) == 0 && w.PlanGB == 0 && w.AccountPlanGB == 0
}

// claimNoticeSession reports whether dest holds a live stored session: a .roamsession that names a profile, and not a
// throwaway or an offline one (their wallets never publish, so they hold no notice).
func claimNoticeSession(dest string) bool {
	name, _, _ := readRoamSession(dest)
	return name != "" && !localOnlySession(dest)
}

// handleGetClaimNotice answers GET-CLAIM-NOTICE from the LOCAL wallet only (no passphrase, no gateway), as GET-BILLING
// does. It is lock-free for GET-BILLING's reason: saveWallet writes temp+rename, so a reader sees the old file or the
// new one.
func handleGetClaimNotice(conn net.Conn, dest string) {
	if !claimNoticeSession(dest) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	w, err := loadWallet(capWalletPath())
	if err != nil || len(w.UnusableClaims) == 0 {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(conn, "NOTICE %d\n", len(w.UnusableClaims))
}

// handleClaimNoticeShown answers CLAIM-NOTICE-SHOWN: Profile showed the notice for n codes, so the first n entries
// (oldest first) are dropped. n above the count drops them all.
//
// It saves the whole wallet, so it runs only under the held lock (drainPendingClaims's rule): a busy lock answers BUSY
// and an unavailable one ERR, and neither saves. The acknowledgement reaches the store with the session's next wallet
// publish; saveWallet's seen-set note (noteWalletSeen) already holds each dropped entry, and that is what keeps
// walletForPublish from bringing it back from the stored copy.
func handleClaimNoticeShown(conn net.Conn, dest, arg string) {
	n, err := strconv.Atoi(arg)
	if err != nil || n < 1 {
		fmt.Fprint(conn, "ERR-ARGS\n")
		return
	}
	if !claimNoticeSession(dest) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	wp := capWalletPath()
	unlock, state := lockWalletWithin(wp, walletSignInWait)
	defer unlock()
	switch state {
	case walletLockBusy:
		fmt.Fprint(conn, "BUSY\n")
		return
	case walletLocked:
	default:
		fmt.Fprint(os.Stderr, "[agent] claim notice shown: the wallet lock is unavailable -- nothing cleared (NWP-20261208-03)\n")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	if _, serr := os.Stat(wp); errors.Is(serr, fs.ErrNotExist) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	w, err := loadWallet(wp)
	if err != nil {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	if n > len(w.UnusableClaims) {
		n = len(w.UnusableClaims)
	}
	if n > 0 {
		var rest []string
		rest = append(rest, w.UnusableClaims[n:]...)
		w.UnusableClaims = rest
		if serr := saveWallet(wp, w); serr != nil {
			fmt.Fprint(os.Stderr, "[agent] claim notice shown: the wallet save failed -- nothing cleared (NWP-20261208-03)\n")
			fmt.Fprint(conn, "ERR\n")
			return
		}
	}
	// Counts only: never a notice's hash.
	fmt.Fprintf(os.Stderr, "[agent] claim notice shown: %d cleared, %d left (NWP-20261208-03)\n", n, len(w.UnusableClaims))
	fmt.Fprint(conn, "OK\n")
}
