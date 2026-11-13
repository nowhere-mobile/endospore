package main

import (
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"os"
	"sync/atomic"
	"time"
)

// The deferred drain of the wallet's pending claim codes (NWP-20261202-01; h53 #6 slice 2, the drain half, decided
// 2026-11-02 in docs/product-decisions.md: the claim code waits in the profile's wallet, sealed with it, and any later
// session on any phone drains it at a randomised moment and clears the entry in the same publish that adds the tokens).
// A sign-in's late work arms it (armPendingClaimDrain, handleRoamIn's fifth step); the arm sends no request and takes
// no lock. One goroutine then waits a random 10-40 minutes of wall-clock time and fires: the random boundary is what
// separates the identified purchase from the first profile-tagged lease. The drain's own publish is still a
// profile-tagged write shortly after its /issue, as h53 #6 decides.
//
// THE FIRE'S CHECKS, in order; any refusal logs one fixed reason, sends nothing and leaves the code for a later session:
// the arm is still the newest; sessionMu is free (TryLock, never Lock) and no sign-out waits for it; the session is the
// armed profile's and the wallet generation is the armed one (the generation is read FIRST, then the session, as
// handleClaimMode and maybePayRent do, NWP-20261010-04); the generation's restore landed (else every publisher refuses
// and the minted tokens would live only on this device); the session is not local and not cold-locked (mint nothing a
// cold lock may not seal); GATEWAY_URL is set; and the rent gate admits it (it refuses while a restart or an unsaved
// exit runs).
//
// ⚠ THE FIRE HOLDS sessionMu FROM ITS CHECKS TO ITS PUBLISH, as CLAIM does. Every path that ends or swaps a session
// takes sessionMu, so with it held no sign-out of this profile and no sign-in of another can land between the drain's
// /issue and its wallet publish: one profile's tokens can never land in, or be published with, another's wallet. TryLock
// keeps the fire from queueing behind a session operation and then running on a stale name and generation, and a
// waiting LOGOUT (signOutWaiting) wins before a drain starts. Late work's "no step may take sessionMu" still holds: the
// step is the arm; the fire is its own goroutine, minutes later, and never waits on the lock.
//
// h55 #1's webhook-lag edge (an empty answer with nothing landed is kept once) is drainPendingClaims's clear rule.

const (
	pendingDrainMin = 10 * time.Minute // the earliest moment after the arm
	pendingDrainMax = 40 * time.Minute // the latest moment after the arm
)

var (
	// pendingDrainSleep is the wait before the fire; tests replace it.
	pendingDrainSleep = sleepUntilWall
	// pendingDrainDone is a test seam, nil in production: called when the armed goroutine ends.
	pendingDrainDone func()
	// pendingDrainSeq numbers the arms that started a goroutine; a fire whose number is not the newest exits unsent.
	pendingDrainSeq atomic.Uint64
)

// pendingDrainDelay draws the wait uniformly in [pendingDrainMin, pendingDrainMax] from crypto/rand. A failed read
// returns pendingDrainMax: the late end, never an earlier moment.
func pendingDrainDelay() time.Duration {
	n, err := rand.Int(rand.Reader, big.NewInt(int64(pendingDrainMax-pendingDrainMin)+1))
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent] pending claim drain: no random draw -- waiting the longest delay (NWP-20261202-01)\n")
		return pendingDrainMax
	}
	return pendingDrainMin + time.Duration(n.Int64())
}

// armPendingClaimDrain arms the deferred drain for the session (dest, name) when its wallet holds pending claim codes.
// It sends no request and takes no lock; the delay is never logged (with the gateway's timing it would date the drain).
func armPendingClaimDrain(dest, name, pass string) {
	wp := walletPathFor(dest)
	w, err := loadWallet(wp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent] pending claim drain for %q: not armed -- the wallet could not be read (NWP-20261202-01)\n", name)
		return
	}
	codes := 0
	for _, c := range w.PendingClaims {
		if c != "" {
			codes++
		}
	}
	if codes == 0 {
		return
	}
	gen := walletGeneration(wp)
	seq := pendingDrainSeq.Add(1)
	goSafe("pending-claim-drain", func() {
		if pendingDrainDone != nil {
			defer pendingDrainDone()
		}
		pendingDrainSleep(pendingDrainDelay())
		firePendingClaimDrain(dest, name, pass, gen, seq)
	})
	fmt.Fprintf(os.Stderr, "[agent] pending claim drain armed for %q: %d code(s) (NWP-20261202-01)\n", name, codes)
}

// pendingDrainSkip logs one refusal of the fire: a fixed reason, the profile name only as %q.
func pendingDrainSkip(name, reason string) {
	fmt.Fprintf(os.Stderr, "[agent] pending claim drain for %q: skipped -- %s (NWP-20261202-01)\n", name, reason)
}

// firePendingClaimDrain is the armed drain at its moment: the checks in this file's top comment, then
// drainPendingClaims and, when tokens landed or an entry was cleared or marked, one wallet publish
// (sealClaimedWallet) that carries the tokens, the clear and the mark together.
func firePendingClaimDrain(dest, name, pass, gen string, seq uint64) {
	if pendingDrainSeq.Load() != seq {
		pendingDrainSkip(name, "a newer arm superseded it")
		return
	}
	if !sessionMu.TryLock() {
		pendingDrainSkip(name, "a session operation is in progress")
		return
	}
	defer sessionMu.Unlock() // the whole fire: no sign-out or sign-in until it ends
	select {
	case <-signOutWaiting():
		pendingDrainSkip(name, "a sign-out is waiting")
		return
	default:
	}
	wp := walletPathFor(dest)
	wgen := walletGeneration(wp) // FIRST, then the session (handleClaimMode's order)
	n, _, _ := readRoamSession(dest)
	if n != name {
		pendingDrainSkip(name, "the session ended")
		return
	}
	if wgen != gen {
		pendingDrainSkip(name, "a new sign-in")
		return
	}
	if !walletRestoreLanded(wp, wgen) {
		pendingDrainSkip(name, "the wallet was not restored")
		return
	}
	if localOnlySession(dest) {
		pendingDrainSkip(name, "a local session")
		return
	}
	if coldLockedUID(dest) != "" {
		pendingDrainSkip(name, "cold-locked")
		return
	}
	gw := os.Getenv("GATEWAY_URL")
	if gw == "" {
		pendingDrainSkip(name, "no gateway")
		return
	}
	if !beginRent() {
		pendingDrainSkip(name, "an unsaved exit or restart is in progress")
		return
	}
	defer endRent()
	defer func() { bestEffortPanic("pending-claim-drain", name, recover()) }() // billing never crashes the daemon
	before := pendingClaimState(wp)
	got, err := drainPendingClaims(newGatewayClient(gw, gwDefault), wp)
	publish := "nothing to publish"
	if got > 0 || pendingClaimState(wp) != before {
		publish = "NOT published"
		if sealClaimedWallet(dest, name, pass, got, wgen) {
			publish = "published"
		}
	}
	outcome := "ok"
	switch {
	case err == nil:
	case errors.Is(err, errWalletBusy):
		outcome = "busy"
	case errors.Is(err, errPendingClaimLockUnavailable):
		outcome = "lock unavailable"
	default:
		outcome = "error"
	}
	// Counts and a fixed outcome only: never a code, never err's text.
	fmt.Fprintf(os.Stderr, "[agent] pending claim drain for %q: %d token(s) added, %s (%s) (NWP-20261202-01)\n",
		name, got, publish, outcome)
}

// pendingClaimState is the wallet's pending codes and miss hashes as one comparable string, "" when it cannot be read.
// It holds codes: it is compared, never logged.
func pendingClaimState(walletPath string) string {
	w, err := loadWallet(walletPath)
	if err != nil {
		return ""
	}
	s := ""
	for _, c := range w.PendingClaims {
		s += c + "\n"
	}
	s += "\x00"
	for _, k := range w.PendingClaimMisses {
		s += k + "\n"
	}
	return s
}
