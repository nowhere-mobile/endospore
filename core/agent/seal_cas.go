package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
)

// Stale-publish guard (NWP-20260906-04) -- refuse to overwrite a head this seal did not read.
//
// THE GAP IS THE ONE #144's FENCE ALREADY DOCUMENTS, from the other side. Its header draws it exactly:
//
//	pushProfile samples the head        (main.go, `head := getRef(base, ref)`)
//	    ... walk + chunk + upload, MINUTES ...
//	capFlush "PUT the pointers LAST"    (main.go, the deferred flush)
//
//	Nothing between those two points re-reads the head.
//
// The fence closes that window for one writer: a DELETE on this device. Nothing closed it for the other
// writer, which is a SECOND DEVICE signed into the same profile. Both handsets resolve byte-identical refs
// (profileRefV2 is a pure function of name+pass with no device component), putRef is an unconditional PUT,
// and the periodic seal runs every syncIntervalDefault seconds. So each device replaces the other's whole
// scope, both print a normal success line, and the loser's session is gone. The bare vault keeps a rollback
// snapshot (pushSnapshot, #58); a SCOPE head is a bare manifest and structurally cannot -- so #de, #media,
// #sys, #apps and #keys losses are unrecoverable.
//
// WHAT THIS IS, AND WHAT IT IS NOT. It records what the seal READ and re-checks it at the instant of the
// PUT, which narrows the window from the whole seal -- minutes -- to about one round trip. It is NOT a
// compare-and-swap: two devices can still both re-read, both see the same value, and both PUT. Closing that
// needs a conditional write, and the store cannot express one through a presigned URL today. The point is
// that the common case -- one device's periodic seal landing while the other is mid-seal -- stops being
// silent whole-scope destruction and becomes a refusal with the stored copy intact and the user told.
// Anyone building on this must not read it as atomicity.
//
// ⚠ IN-PROCESS, DELIBERATELY, AND THAT IS THE DIFFERENCE FROM THE FENCE. The fence is file-backed because
// its two parties are two PROCESSES on one device and no mutex can order them. Here the expectation is
// simply what THIS process read a moment ago, and the other writer is another HANDSET whose write is
// visible in the store. So there is no durable state to leave behind, and no way for a stale marker to
// outlive the run and wedge a later seal -- which is the failure mode a persisted expectation would have
// (a receipt left ahead of the store refuses every subsequent seal, forever).
var (
	sealExpectMu sync.Mutex
	sealExpect   = map[string]string{}

	// sealStaleHit records that a publish was actually refused, so `push` exits exitSealRefused after the
	// defers run -- the same shape as sealFenceHit, and folded in at the same place. It must be a flag
	// rather than an immediate failure because the refusal happens inside the DEFERRED capFlush, after
	// every entry guard has already passed.
	//
	// ⚠ BRACKET-INTERNAL, like sealFenceHit (NWP-20261009-07): outside `push`, a caller reads its capWrite's
	// capVerdict.StaleHit.
	sealStaleHit bool
)

// expectRef records the value this seal READ at ref, so the publish can tell whether anyone advanced it
// since. Called once per scope, at the sample.
func expectRef(ref, val string) {
	if ref == "" {
		return
	}
	sealExpectMu.Lock()
	sealExpect["ref/"+strings.TrimPrefix(ref, "ref/")] = val
	sealExpectMu.Unlock()
}

// disarmExpect retires the reading for ONE ref once the bracket that relied on it has flushed. The login daemon is a
// single process for the whole boot and never runs pushProfile, the only thing that resets the set, so a reading
// left armed would judge a later, unrelated publish of the same ref against a dead value and refuse it
// (NWP-20261008-03: the background re-key reads the vault ref every batch).
func disarmExpect(ref string) {
	if ref == "" {
		return
	}
	sealExpectMu.Lock()
	delete(sealExpect, "ref/"+strings.TrimPrefix(ref, "ref/"))
	sealExpectMu.Unlock()
}

// clearSealExpectations drops the set at the start of a push, so one process serving many seals (the login
// daemon runs handleExport inline) never checks a key against a previous run's reading.
// clearStaleHit drops the VERDICT without dropping the READINGS. capWrite calls it so a bracket cannot
// inherit a refusal from some earlier operation in the same process -- the login daemon is one process
// for a whole boot, and sealStaleHit is otherwise cleared only inside pushProfile, which the daemon
// never runs (NWP-20260915-14).
//
// ⚠ NOT clearSealExpectations, and the difference matters: wiping sealExpect too would DISARM the
// stale guard for every reading its caller took before opening the bracket, turning a reset meant to
// stop a false refusal into a cause of a missed one.
func clearStaleHit() {
	sealExpectMu.Lock()
	sealStaleHit = false
	sealExpectMu.Unlock()
}

func clearSealExpectations() {
	sealExpectMu.Lock()
	sealExpect = map[string]string{}
	sealStaleHit = false
	sealExpectMu.Unlock()
}

// endSealExpectations retires the set once the publish phase is over, WITHOUT touching sealStaleHit --
// which main reads after pushProfile returns, to decide exitSealRefused.
//
// It has to exist. An expectation is a reading of one instant, and it is spent the moment that push
// publishes; leaving it armed judges every LATER write to the same ref in this process against a dead
// value. That is not hypothetical -- it broke four existing tests on the first run: a rollback repointing
// a head (snapshot_history_test), and two delete tests whose earlier push was refused so the ref was
// never created and the delete then found "notfound" instead of a tombstone. The daemon is long-lived and
// serves many seals, so this is a production shape, not a test artifact.
//
// ⚠ It must run AFTER capFlush, so it is deferred BEFORE the `defer capFlush()` (defers run LIFO). In cap
// mode putRef only BUFFERS, so retiring the set any earlier would disarm the one check that matters.
func endSealExpectations() {
	sealExpectMu.Lock()
	sealExpect = map[string]string{}
	sealExpectMu.Unlock()
}

// stalePublish reports whether the ref about to be overwritten has MOVED since this seal sampled it.
// storeKey may be a bare ref or the "ref/<hash>" form, matching sealFencePublishBlocked's contract.
//
// A ref with no expectation armed is NEVER stale: only the scope heads this seal actually read are guarded,
// so recovery refs, anchors, tombstones and every other pointer publish are untouched.
//
// The re-read is one store round trip per SCOPE HEAD -- a handful per seal, not one per chunk -- and in cap
// mode reads are free and unauthenticated. capGet asserts no write bracket, so this is safe to call from
// inside capFlush, which is the only place it can catch the worst case.
func stalePublish(base, storeKey, about string) bool {
	key := "ref/" + strings.TrimPrefix(storeKey, "ref/")
	sealExpectMu.Lock()
	want, armed := sealExpect[key]
	sealExpectMu.Unlock()
	if !armed {
		return false
	}
	// A read failure is NOT a move. Treating it as one would turn a transient store blip into a refused
	// logoff, which on an amnesiac device costs the session -- the exact trade the gateway's own grace arm
	// exists to avoid. Silence means "no evidence anyone moved it", so the publish proceeds as before.
	var got string
	if err := recovered(func() { got = getRef(base, strings.TrimPrefix(key, "ref/")) }); err != nil {
		return false
	}
	if got == want {
		return false
	}
	if op := capRefusalOp(key); op != "" { // a reading a session operation armed, not a seal's
		noteOpRefused(op, key, want, got, false)
		return true
	}
	noteStalePublish(about, key, want, got)
	return true
}

// noteOpRefused records a refused publish made by a session operation -- SET-PIN, a key enrol, a rollback, a
// rotation, a tie -- in that operation's own words (NWP-20261009-07). noteStalePublish speaks of a seal in
// flight and of THIS session's changes not being saved, which is wrong for these and is the line support
// tickets quote. Like it, this names no cause it cannot know.
//
// early is a refusal before the operation buffered anything (capHoldHead): nothing at all was written, and the
// ref named is the head the operation READ, which it may never write itself (a rotation's old head). Otherwise
// it is the flush withholding this one pointer, and the others in the same batch may have landed.
func noteOpRefused(op, storeKey, want, got string, early bool) {
	sealExpectMu.Lock()
	sealStaleHit = true
	sealExpectMu.Unlock()
	ref, was, now := short(strings.TrimPrefix(storeKey, "ref/")), refValue(want), refValue(got)
	if early {
		fmt.Fprintf(os.Stderr, "[agent] %s: refused before anything was written -- the head it read (ref %s) moved "+
			"from %s to %s after it read it, so going on would have discarded that change. It can be tried again.\n",
			op, ref, was, now)
		return
	}
	fmt.Fprintf(os.Stderr, "[agent] %s: the store did not take ref %s -- it moved from %s to %s after the %s read "+
		"it, so writing it would have discarded that change. This pointer was withheld; other pointers in the "+
		"same batch may have landed.\n", op, ref, was, now, op)
}

// refValue renders a ref's value for a refusal line: short, and "(absent)" for none.
func refValue(v string) string {
	if v == "" {
		return "(absent)"
	}
	return short(v)
}

// noteStalePublish records the refusal and explains it in the vocabulary the other seal guards use
// (#111: a refusal is never reported as success).
func noteStalePublish(what, storeKey, want, got string) {
	sealExpectMu.Lock()
	sealStaleHit = true
	sealExpectMu.Unlock()
	// NWP-20260907-11: THIS LINE MAY NOT NAME A CAUSE AS FACT, AND MAY NOT GIVE THE READER AN ERRAND.
	// It read "That is another device signed into this profile ... Sign out of the other device, then
	// sign in again here." Both halves were wrong, and this was the FIFTH copy of them -- the other four
	// were chooser strings fixed by NWP-20260907-07, and this one was missed because it is a LOG line.
	// It is also the worst place to have had it: it asserted the cause outright rather than
	// conditionally, and it is the text that lands in every support ticket.
	//
	// ⚠ PROVEN WRONG BY THE VERY EVENT IT DESCRIBED, on lynx 2026-09-07: the head that moved had been
	// advanced by a security key REVOKED ON THE OTHER HANDSET -- a keyslot change, not a competing seal
	// -- and the line still told the reader to go and sign out of a device. Minutes earlier the same
	// refusal had fired from an ENROLMENT on the handset the user was holding.
	//
	// Naming the candidate causes IS right here, unlike in the UI: this is a diagnostic line and the
	// person reading it in a ticket needs the list. What is forbidden is picking one and calling it the
	// answer, and telling anyone to do anything about it.
	fmt.Printf("%s: PUBLISH REFUSED for ref %s -- this head moved from %s to %s while the seal was in "+
		"flight, so writing it would DISCARD whatever advanced it. The stored copy is intact and untouched, "+
		"and THIS session's changes were not saved. What moved it is not knowable from here: another "+
		"signed-in device, or a keyslot change on this one (a security key enrolled or revoked, a PIN set, "+
		"a passphrase rotated). The next seal re-reads the head and normally succeeds.\n",
		what, short(strings.TrimPrefix(storeKey, "ref/")), short(want), short(got))
}
