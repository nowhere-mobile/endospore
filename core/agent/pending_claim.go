package main

import (
	"errors"
	"fmt"
	"os"
	"slices"
)

// The pending claim codes (Wallet.PendingClaims, NWP-20261125-05; decided 2026-11-02, h53 #6 in
// docs/product-decisions.md): the claim code of a deferred drain waits in the profile's wallet, sealed with it, and any
// later session on any phone drains it. This file is the drain-and-clear step, which armPendingClaimDrain
// (pending_claim_drain.go, NWP-20261202-01) runs at a random moment in each later session, and the keep of a code whose
// Add-credits drain was cut short (NWP-20261201-21).
//
// ⚠ THE CLEAR RULE. drainClaim returns (total, nil) on a PARTIAL drain too -- an error, an unexpected status or a busy
// wallet after some batches landed: the code keeps the rest -- so tokens landing do NOT prove the code empty, and
// clearing on them drops the paid remainder. Only a call that returns (0, nil), the 402 at batch 1 with nothing minted
// in that call, proves the code holds nothing more (spent or unknown: the gateway answers 402 for both). So an entry is
// cleared only after such a call; any error keeps it for a later session, and tokens already landed stay landed.
//
// THE WEBHOOK-LAG EDGE (decided 2026-11-03, h55 #1; NWP-20261202-01). An unknown code and a spent one get the same 402,
// and a code whose payment webhook has not reached the gateway yet is unknown for that while. So a run whose proving
// (0, nil) came with NO tokens landed for that code in the run does not clear it the first time: it keeps the code and
// adds the code's hash (pendingClaimSeenKey, never the code) to Wallet.PendingClaimMisses. The next run that gets the
// same answer for a code whose hash is there clears the code and drops the hash. A run that landed tokens and then got
// the proving (0, nil) clears at once, as before. Clears and marks go up in one save under the held lock.

// maxPendingClaimCalls bounds the drainClaim calls per code per run. A full drain takes two (the tokens, then the
// proving 402); a code still answering tokens after this many is kept for the next run.
const maxPendingClaimCalls = 3

// errPendingClaimLockUnavailable is the clear's answer when the wallet lock cannot be opened or taken: the proven-empty
// entries are kept, because the clear never saves the wallet unlocked.
var errPendingClaimLockUnavailable = errors.New("the wallet lock is unavailable -- the pending claim codes were kept")

// pendingClaimBeforeClear is a test seam, nil in production: called just before the clear takes the wallet lock.
var pendingClaimBeforeClear func()

// drainPendingClaims drains every pending claim code of the wallet at walletPath into it and clears each code the
// gateway proved empty (or marks it for one retry, the webhook-lag edge above), in one save under the wallet lock. drained is the tokens added; err joins every failure (an
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
	missed := map[string]bool{}
	for _, k := range w.PendingClaimMisses {
		missed[k] = true
	}
	var errs []error
	cleared := map[string]bool{}
	marked := map[string]bool{}
	for i, code := range codes {
		codeLanded := 0 // the tokens this run landed for this code
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
			codeLanded += got
			if derr != nil {
				errs = append(errs, derr) // kept: a later session retries, and what landed stays landed
				break
			}
			if got == 0 {
				if codeLanded > 0 || missed[pendingClaimSeenKey(code)] {
					cleared[code] = true // the proving (0, nil) after tokens, or the second empty answer (h55 #1)
				} else {
					marked[code] = true // the first empty answer with nothing landed: kept once for the webhook's lag
				}
				break
			}
		}
	}
	if len(cleared) == 0 && len(marked) == 0 {
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
		fmt.Fprintf(os.Stderr, "[agent] pending claim: the wallet is busy -- %d proven-empty or marked code(s) kept for a later run (NWP-20261125-05)\n", len(cleared)+len(marked))
		return drained, errors.Join(append(errs, errWalletBusy)...)
	case walletLocked:
	default:
		fmt.Fprintf(os.Stderr, "[agent] pending claim: the wallet lock is unavailable -- %d proven-empty or marked code(s) kept for a later run (NWP-20261125-05)\n", len(cleared)+len(marked))
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
	// The misses: the held ones plus this run's marks, each only while its code is still kept (a cleared code's hash
	// goes with it). In code order, so the save is the same whatever order the map iterates in.
	var newMisses []string
	for _, c := range codes {
		if marked[c] {
			newMisses = append(newMisses, pendingClaimSeenKey(c))
		}
	}
	misses := pendingClaimMissesFor(kept, cur.PendingClaimMisses, newMisses)
	if len(kept) == len(cur.PendingClaims) && slices.Equal(misses, cur.PendingClaimMisses) {
		return drained, errors.Join(errs...) // another writer already took them out: nothing to save
	}
	gone := len(cur.PendingClaims) - len(kept)
	cur.PendingClaims = kept
	cur.PendingClaimMisses = misses
	if serr := saveWallet(walletPath, cur); serr != nil {
		return drained, errors.Join(append(errs, serr)...)
	}
	fmt.Fprintf(os.Stderr, "[agent] pending claim: %d code(s) cleared, %d marked for one retry, %d kept, %d tokens added (NWP-20261202-01)\n",
		gone, len(marked), len(kept), drained)
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

// pendingClaimMissesFor is the union of the miss hashes in sides, in order and deduplicated, keeping only the hash of a
// code in codes (NWP-20261202-01). drainPendingClaims, walletForPublish and mergeLateRestore all build
// Wallet.PendingClaimMisses with it, so a miss never outlives its code. It returns a new slice: it never appends into a
// caller's backing array.
func pendingClaimMissesFor(codes []string, sides ...[]string) []string {
	live := make(map[string]bool, len(codes))
	for _, c := range codes {
		live[pendingClaimSeenKey(c)] = true
	}
	var out []string
	have := map[string]bool{}
	for _, side := range sides {
		for _, k := range side {
			if live[k] && !have[k] {
				have[k] = true
				out = append(out, k)
			}
		}
	}
	return out
}
