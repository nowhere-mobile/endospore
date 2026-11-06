package main

// h47 #1 option A, part 1 (NWP-20261117-01; docs/product-decisions.md, 2026-10-28): A SEAL THAT ROAMD'S OUT OP RUNS
// CAN STOP AT ITS NEXT CHUNK BOUNDARY.
//
// The request is the file $NOWHERE_STATE/.sealstop. The push only stats it. The login daemon raises it and drops it
// (part 2, NWP-20261117-04): handleLogout raises it when the announce it replaces is "periodic" (a periodic seal
// queued for or holding the RW slot), so that the sign-out runs one seal instead of waiting out the periodic's whole
// seal and then running its own; runWorkerHeld drops it under the slot, immediately before an out op's request is
// written, and only for an out op that runs (requestSealStop and dropSealStop below). SUPERSEDED in part (h49 #13,
// NWP-20261119-03): handleLogout also raises it when the announce it replaces is "manual" (a running Back up now), and
// its out op then runs as "logoff-pinned"; a "promote" announce is still not asked (h49 #13 leaves it open). A Back up
// now whose announce a sign-out took while it waited for the slot answers SKIP-STOPPED there and leaves the request
// for the sign-out's own out op (manualStoppedAtSlot below, NWP-20261126-11).
//
// WHO MAY HONOUR IT. Only a `push` verb run with NOWHERE_SEAL_STOPPABLE=1, and only roamd's out op exports that
// (roamd runs one op per process, so the out op's _push, acct_seal and appcode_seal see it and nothing else does).
// ⚠ cleanstorage's keystore_push runs the SAME verb for the #keys scope, and its retry ladder ends with the reap
// destroying the keystore dump. A stoppable #keys push would stop on every rung while a .sealstop is present, and
// the dump would be lost. So sealStoppable defaults to false, and sealStopAsked is the only place that reads it.
//
// THE CHECK POINTS. In the walk: where sealChunk dispatches a chunk and where cachedChunk places a reused one. A yes
// there unwinds the walk by a sealStopSignal panic that pushProfile recovers. In the cap flush (capFlush): at its two
// flushMayWrite points (before the /quote, and before any /lease), before each blob PUT begins (uploadBlobs), and
// once more after the blob PUTs, before the fold blob. There is no check between lease batches.
//
// ⚠ ONCE THE POINTER PASS HAS BEGUN THE STOP IS IGNORED. A stop between two pointer PUTs would publish the head and
// leave the recovery ref stale: the partial head the decision forbids. The pointer pass therefore never asks.
//
// WHAT A STOP LEAVES.
//   - A walk-phase stop unwinds before the tail. It leaves no head, no restore-receipt re-anchor, no walked roster, no
//     scan-cache save, no anchor bump and no media-sync list. In cap mode it also leases and PUTs nothing (capAbort,
//     so the deferred capFlush finds its bracket closed and flushes nothing). In direct mode no putRef runs; chunks a
//     worker had already posted stay in the store, content-addressed and unreferenced.
//   - A flush-phase stop comes after the tail, exactly as a failed upload does today. The tail already ran putHead
//     (buffered in cap mode, so not published), writeRestoreReceipt, recordWalkedRoster, sc.save and the media carry,
//     so the receipt names the unpublished head. The next seal's stale-base check only logs that while
//     NOWHERE_SEQ_GUARD is 0, as on every ring, and sc.get re-verifies blobCacheKnown for every cached chunk, so a
//     scan-cache entry for a blob that never landed corrects itself. Blobs already PUT stay: they are leased and
//     content-addressed, and blobCacheAdd ran for each, so the next seal does not send them again.
//   - The tail and the deferred flush are NOT reordered: the flush is the payment path (one flush = one lease).

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync/atomic"
)

// sealStopFile is the request's file name in $NOWHERE_STATE.
const sealStopFile = ".sealstop"

var (
	sealStoppable         bool        // set only by `case "push":`, only when NOWHERE_SEAL_STOPPABLE=1
	sealStopped           atomic.Bool // this push's verdict; reset at the top of pushProfile, as sealRefused is
	sealChunkDispatchHook func()      // tests only: called once per chunk sealChunk dispatches
)

// sealStopSignal is the sentinel panic value of a walk-phase stop. pushProfile recovers it and re-panics any other.
type sealStopSignal struct{}

// sealStopAsked reports whether this process may stop and a stop is requested. It is a stat only.
func sealStopAsked() bool {
	if !sealStoppable {
		return false
	}
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(st, sealStopFile))
	return err == nil
}

// sealStopNow is the latch every check point calls: once it says yes, it says yes for the rest of this push, so a
// request removed mid-flush cannot resume a flush that has already skipped work. It logs once.
func sealStopNow() bool {
	if sealStopped.Load() {
		return true
	}
	if !sealStopAsked() {
		return false
	}
	if sealStopped.CompareAndSwap(false, true) {
		fmt.Fprintf(os.Stderr, "  seal-stop: a stop was requested -- this seal starts no further write (h47 #1)\n")
	}
	return true
}

// requestSealStop creates the stop request in dest ($NOWHERE_STATE): an empty file, mode 0600. handleLogout calls it,
// after it releases pendingReapMu, when the announce it replaced was "periodic" (or, since h49 #13,
// NWP-20261119-03, "manual").
func requestSealStop(dest string) error {
	return os.WriteFile(filepath.Join(dest, sealStopFile), nil, 0o600)
}

// dropSealStop removes the stop request in dest. runWorkerHeld calls it for an out op under the slot, after every
// guard and immediately before roam.req is written, so only an out op that really runs drops it. A request that was
// there is logged (the only trace of a raise the sign-out's own out op consumed); a removal error is logged and the
// op still runs.
func dropSealStop(dest string) {
	err := os.Remove(filepath.Join(dest, sealStopFile))
	switch {
	case err == nil:
		fmt.Fprintf(os.Stderr, "[logind] worker op=out: dropped the stop request a sign-out raised, before writing its own request (h47 #1)\n")
	case !errors.Is(err, fs.ErrNotExist):
		fmt.Fprintf(os.Stderr, "[logind] worker op=out: could not drop the stop request (h47 #1): %v\n", err)
	}
}

// manualStoppedAtSlot reports whether a Back up now that reaches the RW slot must not run (h49 #13, "saves once";
// NWP-20261126-11): its intent is "manual" and, read under pendingReapMu, the announce is "logoff", so a sign-out
// took the announce from this Back up now while it waited for the slot. runWorkerHeld then answers SKIP-STOPPED and
// LEAVES the stop request for the sign-out's own out op (intent "") to drop. A Back up now whose sign-out has already
// ended (announce "") runs as tapped: a sign-out that landed has queued the reap, so the clobber guard's SKIP-REAPING
// answers first; a sign-out that was refused kept the session, and its Back up now is still wanted.
func manualStoppedAtSlot(intent string) bool {
	if intent != "manual" {
		return false
	}
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return sealRunKind == "logoff"
}
