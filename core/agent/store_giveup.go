package main

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// NWP-20261028-02: a dead store is given up on after storeGiveUpWindow, not retried read by read (decision:
// docs/product-decisions.md 2026-10-19, item 5). Measured on lynx 2026-10-19, a sign-in over a hotspot with no
// upstream took about 2.5 minutes to go local and an offline DELETE outlasted the chooser's 90 s read, because
// every read spent its own five attempts and N reads cost N times that. Within one verb -- a sign-in's restore
// process or a DELETE -- retryStoreWithin now starts no attempt once the store has been unreachable continuously
// for 15 s with no response in between. The 1-2 s every lookup fails at a user switch (resolver.go) stays well
// inside the window.
//
// The outage clock is shared by everything in the process while armed: in the daemon a concurrent read in the same
// seconds sees the same dead store and gives up too, which is the decision's intent. Nothing is armed outside a
// sign-in's restore process and a DELETE, so seals, logoffs and background reads keep today's retries.
//
// Each restore process of one sign-in (base, #de, #media, #apps) is its own process and so has its own window: a
// store that dies between two scope restores can cost each later one 15 s.
//
// NWP-20261210-02 (backlog §B, "A large app's fetch fails on a slow link: one chunk with no data for 30 s ends the
// whole fetch, and each retry starts again from chunk 1"): a BODY BYTE is the store answering. A restore runs
// downloadWorkers (24) GETs at once over one link; at 2 Mbit/s each moves about 10 KB/s, so none FINISHES for longer
// than the window, and when one of them starves and is cut the clock above read 15 s of silence while the other 23
// were moving bytes the whole time. storeXferBody.Read now calls noteStoreBytes for every Read that returned bytes,
// which records an answer as a finished attempt does (at most once per storeBytesNoteEvery). The 2026-10-19 rule is
// unchanged for a dead store: no byte arrives on any connection, so nothing is noted and it still stops at 15 s.

// storeGiveUpWindow is the decided number: how long the store may stay silent before the verb stops retrying.
const storeGiveUpWindow = 15 * time.Second

// storeGiveUpNow is the clock, a variable so tests can move it.
var storeGiveUpNow = time.Now

var storeGiveUp struct {
	mu           sync.Mutex
	armed        int       // nested arms; the give-up applies only while this is above zero
	armedAt      time.Time // set when armed goes 0 -> 1: an outage before the arm is counted from the arm
	failingSince time.Time // zero = the last attempt was answered
	answeredAt   time.Time // when the store last answered; a failure that began earlier cannot backdate the outage
	logged       bool      // the stop line has been printed for this arm
}

// armStoreGiveUp turns the give-up on until the returned func is called. Arms are counted, so nested arms are
// safe; the func disarms once only. why is a fixed literal, never a profile name.
func armStoreGiveUp(why string) (disarm func()) {
	storeGiveUp.mu.Lock()
	if storeGiveUp.armed == 0 {
		storeGiveUp.armedAt = storeGiveUpNow()
		storeGiveUp.logged = false
	}
	storeGiveUp.armed++
	storeGiveUp.mu.Unlock()
	_ = why
	var once sync.Once
	return func() {
		once.Do(func() {
			storeGiveUp.mu.Lock()
			storeGiveUp.armed--
			storeGiveUp.mu.Unlock()
		})
	}
}

// noteStoreAttempt records the outcome of a store attempt that has just finished.
func noteStoreAttempt(err error) { noteStoreAttemptFrom(storeGiveUpNow(), err) }

// noteStoreAttemptFrom records an attempt's outcome. A failure is stamped at the attempt's START: the store was
// unanswered from then, and stamping the end would let one slow attempt hide up to its own length from the window.
// That bounds the cost of a dead store to the window plus the one attempt in flight. It tracks while unarmed on
// purpose: an outage that began before the arm is clamped to armedAt by storeGivenUp. A nil result and a definitive
// refusal (errStorePermanent) are both responses, so the store is reachable and the window restarts.
func noteStoreAttemptFrom(started time.Time, err error) {
	storeGiveUp.mu.Lock()
	defer storeGiveUp.mu.Unlock()
	if err == nil || errors.Is(err, errStorePermanent) {
		storeGiveUp.failingSince = time.Time{} // the store answered
		storeGiveUp.answeredAt = storeGiveUpNow()
		return
	}
	if storeGiveUp.failingSince.IsZero() {
		// Requests overlap: one that began before the last response and fails after it must not reinstate an
		// outage older than that response, so the outage counts from the later of the two.
		storeGiveUp.failingSince = laterOf(started, storeGiveUp.answeredAt)
	}
}

// storeBytesNoteEvery throttles noteStoreBytes' answers: every body Read of every GET calls it, and the mutex is
// taken at most this often.
const storeBytesNoteEvery = 250 * time.Millisecond

// storeXferByteAt is storeGiveUpNow().UnixNano() of the last body byte any storeXfer GET received (0 = none since the
// last reset). retryStoreWithinGuarded reads it to tell a stall on a link that carries bytes from a dead link.
var storeXferByteAt atomic.Int64

// storeBytesNotedAt is storeGiveUpNow().UnixNano() of the last answer noteStoreBytes recorded: the throttle.
var storeBytesNotedAt atomic.Int64

// noteStoreBytes records that a store GET has just received body bytes (NWP-20261210-02). It always stamps
// storeXferByteAt; at most once per storeBytesNoteEvery it also records an answer exactly as noteStoreAttemptFrom does
// for a nil result. A clock that moved backwards (now before the last noted stamp) counts as due. The throttle is a
// compare-and-swap, so of many readers due at once only one takes the mutex.
func noteStoreBytes() {
	now := storeGiveUpNow()
	ns := now.UnixNano()
	storeXferByteAt.Store(ns)
	for {
		last := storeBytesNotedAt.Load()
		if ns >= last && ns-last < int64(storeBytesNoteEvery) {
			return // noted recently enough
		}
		if storeBytesNotedAt.CompareAndSwap(last, ns) {
			break
		}
	}
	storeGiveUp.mu.Lock()
	storeGiveUp.failingSince = time.Time{} // a body byte is the store answering
	storeGiveUp.answeredAt = now
	storeGiveUp.mu.Unlock()
}

// storeGivenUp reports whether the armed verb should stop retrying the store.
func storeGivenUp() bool {
	storeGiveUp.mu.Lock()
	defer storeGiveUp.mu.Unlock()
	return storeGiveUp.armed > 0 && !storeGiveUp.failingSince.IsZero() &&
		storeGiveUpNow().Sub(laterOf(storeGiveUp.failingSince, storeGiveUp.armedAt)) >= storeGiveUpWindow
}

func laterOf(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// storeGaveUpErr is what a retry loop returns once it has given up. It unwraps to errStoreUnreachable, so
// checkRead's panic still exits as exitStoreUnreachable (roamd's BLANK NET) and a DELETE still answers ERR-STORE,
// and NOT to errStorePermanent, which would read as a definitive answer from the store.
type storeGaveUpErr struct{}

func (storeGaveUpErr) Error() string {
	return "store gave up: no answer for 15s in this sign-in or delete"
}
func (storeGaveUpErr) Unwrap() error { return errStoreUnreachable }

var errStoreGaveUp error = storeGaveUpErr{}

// logStoreGiveUpOnce prints the stop line once per arm.
func logStoreGiveUpOnce(what string) {
	storeGiveUp.mu.Lock()
	first := !storeGiveUp.logged
	storeGiveUp.logged = true
	storeGiveUp.mu.Unlock()
	if first {
		fmt.Fprintf(os.Stderr, "  retry %s stopped: the store has not answered for 15s in this sign-in or delete (docs/product-decisions.md 2026-10-19)\n", logSafeWhat(what))
	}
}
