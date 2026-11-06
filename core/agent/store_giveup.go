package main

import (
	"errors"
	"fmt"
	"os"
	"sync"
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
