package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// Q116 (docs/product-decisions.md, 2026-10-20; the wait line 2026-10-21): a sign-out always wins, and the screen
// shows progress while it waits. LOGOUT is serialized, so behind a materialise, a store install or the Auto sweep it
// queued on sessionMu under handleLogin's 60 s deadline: the wait ended between 60 and 90 s with the OK write failing
// on the expired deadline (the screen read EOF and rebooted over the seal), or ran past 90 s and the screen's read
// timed out first. lockSessionForLogout is the decision's "progress line before it takes the session lock": while it
// waits it re-arms the deadline and, once the wait has lasted logoutWaitFirst, writes `WAIT <seconds>`. The reader is
// LogoutAck (NOWHERE-882, NWP-20261106-01): it skips WAIT lines, for at most 600 s. LOGOUT only -- every other
// reader takes the first line as its answer.
//
// NWP-20261109-12 (Q116): the holder of sessionMu is never interrupted by this code, it is ASKED. When TryLock fails,
// lockSessionForLogout raises the sign-out signal before it starts waiting -- $STATE/od-cancel, which the materialise
// worker checks between chunks (odCancelRequested, NWP-20261109-11), and the signOutWaiting() channel FETCH-APP reads
// (NOWHERE-972) -- and lowers both once it holds the lock. A free lock raises nothing. No verb, no reply change. A
// sign-out stopping the Auto sweep and FETCH-APP's cancel are later slices.
//
// loginConnDeadline is handleLogin's entry deadline; the other two pace the WAIT lines. Vars so tests shrink them.
var loginConnDeadline = 60 * time.Second
var logoutWaitFirst = 20 * time.Second
var logoutWaitEvery = 20 * time.Second

// logoutWaitTicker and logoutWaitNow are lockSessionForLogout's tick source and the clock behind its `waited`, hoisted
// (as logoffStallTicker, NWP-20261110-08) so a test can step both by hand instead of racing real time on a loaded
// runner. Production never assigns them. conn.SetDeadline stays on time.Now(): a deadline is real time.
var logoutWaitTicker = func(d time.Duration) (<-chan time.Time, func()) {
	t := time.NewTicker(d)
	return t.C, t.Stop
}
var logoutWaitNow = time.Now

// odCancelFile is the sign-out marker under dest, the dir roamd calls $STATE.
const odCancelFile = "od-cancel"

var signOutMu sync.Mutex           // guards signOutC and signOutRaised
var signOutC = make(chan struct{}) // closed while a LOGOUT waits for sessionMu
var signOutRaised bool             // signOutC is closed
var signOutRaises atomic.Int64     // how many times signOutRaise ran (tests)

// signOutRaise asks the holder of sessionMu to stop at its next safe point: it closes signOutC (once) and writes
// dest/od-cancel. A failed write is logged, never fatal: the wait and its WAIT lines go on regardless.
func signOutRaise(dest string) {
	signOutRaises.Add(1)
	func() {
		signOutMu.Lock()
		defer signOutMu.Unlock() // a panic here must not leave every later raise, lower and reader blocked
		if !signOutRaised {
			close(signOutC)
			signOutRaised = true
		}
	}()
	if err := os.WriteFile(filepath.Join(dest, odCancelFile), []byte("1\n"), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] sign-out marker: %v\n", err)
	}
}

// signOutLower drops the marker, then installs a fresh open signOutC: a reader that sees an open channel never
// finds a stale marker.
func signOutLower(dest string) {
	if err := os.Remove(filepath.Join(dest, odCancelFile)); err != nil && !errors.Is(err, os.ErrNotExist) {
		fmt.Fprintf(os.Stderr, "[logind] sign-out marker: %v\n", err)
	}
	signOutMu.Lock()
	signOutC = make(chan struct{})
	signOutRaised = false
	signOutMu.Unlock()
}

// signOutWaiting returns the current sign-out channel: closed while a LOGOUT waits for sessionMu.
func signOutWaiting() <-chan struct{} {
	signOutMu.Lock()
	defer signOutMu.Unlock()
	return signOutC
}

// lockSessionForLogout returns holding sessionMu, as sessionMu.Lock() would.
func lockSessionForLogout(conn net.Conn, dest string) {
	if sessionMu.TryLock() {
		return
	}
	signOutRaise(dest)
	defer signOutLower(dest) // runs after the lock is held, on every return below
	got := make(chan struct{})
	// Go lets the caller's deferred sessionMu.Unlock() release a mutex another goroutine locked.
	goSafe("logout-session-wait", func() {
		sessionMu.Lock()
		close(got)
	})
	start := logoutWaitNow()
	tc, stop := logoutWaitTicker(logoutWaitEvery)
	defer stop()
	for {
		select {
		case <-tc:
			conn.SetDeadline(time.Now().Add(loginConnDeadline))
			if waited := logoutWaitNow().Sub(start); waited >= logoutWaitFirst {
				// A failed write is ignored and the wait goes on: returning without the lock would leave the
				// goroutine above holding sessionMu for ever.
				fmt.Fprintf(conn, "WAIT %d\n", int(waited/time.Second))
			}
		case <-got:
			conn.SetDeadline(time.Now().Add(loginConnDeadline))
			if waited := logoutWaitNow().Sub(start); waited >= logoutWaitFirst {
				fmt.Fprintf(os.Stderr, "[logind] LOGOUT waited %ds for the session lock\n", int(waited/time.Second))
			}
			return
		}
	}
}
