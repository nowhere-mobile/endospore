package main

import (
	"errors"
	"fmt"
	"os"
)

// The pending claim codes (Wallet.PendingClaims, NWP-20261125-05; decided 2026-11-02, h53 #6 in
// docs/product-decisions.md): the claim code of a deferred drain waits in the profile's wallet, sealed with it, and any
// later session on any phone drains it. This file is the drain-and-clear step, which nothing calls yet (slice 2 wires the
// create and the randomised moment), and the keep of a code whose Add-credits drain was cut short (NWP-20261201-21).
//
// ⚠ THE CLEAR RULE. drainClaim returns (total, nil) on a PARTIAL drain too -- an error, an unexpected status or a busy
// wallet after some batches landed: the code keeps the rest -- so tokens landing do NOT prove the code empty, and
// clearing on them drops the paid remainder. Only a call that returns (0, nil), the 402 at batch 1 with nothing minted
// in that call, proves the code holds nothing more (spent or unknown: the gateway answers 402 for both). So an entry is
// cleared only after such a call; any error keeps it for a later session, and tokens already landed stay landed.

// maxPendingClaimCalls bounds the drainClaim calls per code per run. A full drain takes two (the tokens, then the
// proving 402); a code still answering tokens after this many is kept for the next run.
const maxPendingClaimCalls = 3

// errPendingClaimLockUnavailable is the clear's answer when the wallet lock cannot be opened or taken: the proven-empty
// entries are kept, because the clear never saves the wallet unlocked.
var errPendingClaimLockUnavailable = errors.New("the wallet lock is unavailable -- the pending claim codes were kept")

// pendingClaimBeforeClear is a test seam, nil in production: called just before the clear takes the wallet lock.
var pendingClaimBeforeClear func()

// drainPendingClaims drains every pending claim code of the wallet at walletPath into it and clears each code the
// gateway proved empty, in one save under the wallet lock. drained is the tokens added; err joins every failure (an
// entry whose drain failed is kept). The publish is the caller's (sealWalletDurable), so the tokens and the cleared
// entry reach the store in one publish.
//
// The wallet lock is NOT held across the drains: drainClaim takes it per batch, and a second flock in this process
// would wait on itself (LOCK ORDER, wallet_lock.go).
func drainPendingClaims(g *gatewayClient, walletPath string) (drained int, err error) {
	w, err := loadWallet(walletPath)
	if err != nil {
		return 0, err
	}
	var codes []string
	seen := map[string]bool{}
	for _, c := range w.PendingClaims {
		if c != "" && !seen[c] {
			seen[c] = true
			codes = append(codes, c)
		}
	}
	if len(codes) == 0 {
		return 0, nil
	}
	var errs []error
	cleared := map[string]bool{}
	for i, code := range codes {
		for call := 1; call <= maxPendingClaimCalls; call++ {
			got, derr := drainClaim(g, walletPath, code, false)
			outcome := "landed"
			switch {
			case errors.Is(derr, errWalletBusy):
				outcome = "busy"
			case derr != nil:
				outcome = "error"
			case got == 0:
				outcome = "empty"
			}
			// Counts and the outcome only: never the code, and never derr's text.
			fmt.Fprintf(os.Stderr, "[agent] pending claim %d/%d call %d/%d: %d tokens (%s) (NWP-20261125-05)\n",
				i+1, len(codes), call, maxPendingClaimCalls, got, outcome)
			drained += got
			if derr != nil {
				errs = append(errs, derr) // kept: a later session retries, and what landed stays landed
				break
			}
			if got == 0 {
				cleared[code] = true // the proving (0, nil): nothing is left on the code
				break
			}
		}
	}
	if len(cleared) == 0 {
		return drained, errors.Join(errs...)
	}
	if pendingClaimBeforeClear != nil {
		pendingClaimBeforeClear()
	}
	// The clear saves the whole wallet, so it runs only under the held lock. lockWalletWithin FAILS OPEN on an
	// unopenable or unlockable lock file (walletLockUnavailable); an unlocked save here could overwrite another
	// writer's tokens or codes, so that state keeps the entries exactly as a busy lock does.
	unlock, state := lockWalletWithin(walletPath, walletSignInWait)
	defer unlock()
	switch state {
	case walletLockBusy:
		fmt.Fprintf(os.Stderr, "[agent] pending claim: the wallet is busy -- %d proven-empty code(s) kept for a later run (NWP-20261125-05)\n", len(cleared))
		return drained, errors.Join(append(errs, errWalletBusy)...)
	case walletLocked:
	default:
		fmt.Fprintf(os.Stderr, "[agent] pending claim: the wallet lock is unavailable -- %d proven-empty code(s) kept for a later run (NWP-20261125-05)\n", len(cleared))
		return drained, errors.Join(append(errs, errPendingClaimLockUnavailable)...)
	}
	cur, lerr := loadWallet(walletPath)
	if lerr != nil {
		return drained, errors.Join(append(errs, lerr)...)
	}
	var kept []string
	for _, c := range cur.PendingClaims {
		if !cleared[c] {
			kept = append(kept, c)
		}
	}
	if len(kept) == len(cur.PendingClaims) {
		return drained, errors.Join(errs...) // another writer already took them out: nothing to save
	}
	gone := len(cur.PendingClaims) - len(kept)
	cur.PendingClaims = kept
	if serr := saveWallet(walletPath, cur); serr != nil {
		return drained, errors.Join(append(errs, serr)...)
	}
	fmt.Fprintf(os.Stderr, "[agent] pending claim: %d code(s) cleared, %d kept, %d tokens added (NWP-20261125-05)\n",
		gone, len(kept), drained)
	return drained, errors.Join(errs...)
}

// keepPendingClaim adds code to the wallet at walletPath's PendingClaims (oldest first, deduplicated), so a later drain
// finishes a code whose Add-credits drain was cut short (NWP-20261201-21; decided 2026-11-06, h60 #15). A code the
// wallet already holds is not saved again. The clear stays drainPendingClaims's, after its proving call.
//
// It saves the whole wallet, so it runs only under the held lock, by drainPendingClaims's rule: a busy lock returns
// errWalletBusy, an unavailable one errPendingClaimLockUnavailable, and neither saves. The code is a PAID BEARER CODE, so
// this function logs nothing and its caller logs counts and a fixed outcome only.
func keepPendingClaim(walletPath, code string) error {
	unlock, state := lockWalletWithin(walletPath, walletSignInWait)
	defer unlock()
	switch state {
	case walletLockBusy:
		return errWalletBusy
	case walletLocked:
	default:
		return errPendingClaimLockUnavailable
	}
	w, err := loadWallet(walletPath)
	if err != nil {
		return err
	}
	for _, c := range w.PendingClaims {
		if c == code {
			return nil
		}
	}
	w.PendingClaims = append(w.PendingClaims, code)
	return saveWallet(walletPath, w)
}
