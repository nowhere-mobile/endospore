package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// h46 #1 (docs/product-decisions.md, 2026-10-28, "ten recommendations accepted -- the late sign-in steps run in the
// background ..."; it supersedes the 2026-10-26 entry's #6): the best-effort sign-in steps run AFTER the ROAM-IN
// reply, in one goroutine, as the session's late work. Below the reply inside handleRoamIn they saved nothing: the
// handler still held sessionMu, and the gate's GET-APPS and GRANT-PERMS before the user switch waited for it, so each
// store round trip held the user at the gate. Part 1 (NWP-20261116-01) moves autoPublish and enrollUnitAtLogin.
// Part 2 (NWP-20261116-03) moves roamInWallet and telHandoffRoamIn ahead of them, in that order: the wallet landing
// asks mayWrite under the wallet lock, the telephony staging asks it under telMu (stageTelInboxGuarded), and the
// session's delivery claim releases the held bring-up only once the hand-off is done (telHandoffPending).
//
// LOGOUT, DELETE, both cold locks and every seal entry (BACKUP, syncLoop) call waitLateWork before any teardown, seal,
// publish or purge. The wait is bounded by lateWorkBound. At the bound the caller goes ahead and the job is marked
// abandoned: removing data is never deferred past the bound. A running step is never cancelled (a cancel cannot
// recall a PUT in flight); instead every step checks lw.mayWrite() before it starts and again before each store write
// begins, so an abandoned step, or one whose session is gone, starts no new write. "Each store write" is literal: the
// check is repeated after every request that can block, inside the writers themselves -- between the directory's blob
// upload and its ref PUT (writeAccountDirGuarded), after the discovery seal's argon2 (publishDiscoveryGuarded), and in
// cap mode before capFlush's quote, its lease and each PUT (capSetSessionMayWrite). It is also asked before every
// RETRY of a PUT: retryStoreWithinGuarded asks it before each attempt (capPutErrGuarded, s3PutGuarded), and
// lateWriteHook before each of minio's own retries inside one attempt (s3PutGuarded, discoPutGuarded). A PUT that
// fails after the job was abandoned therefore starts no second request.
//
// ⚠ NO STEP MAY TAKE sessionMu. handleLogin holds it while LOGOUT, DELETE and BACKUP wait here, coldLockSignOut holds
// it while it waits, and a new sign-in's startLateWork waits out the older job with it held too. A step that took
// sessionMu would deadlock against every one of those waits until the bound, every time. Nor may a step take any
// other lock a waiter holds while it waits; today the waits hold only sessionMu.

// lateWork is one sign-in's late job.
type lateWork struct {
	dest, uid string
	done      chan struct{} // closed from a defer when the steps end, also when a step panics
	abandoned atomic.Bool   // set once, by the first wait that reached lateWorkBound
}

var (
	lateWorkMu  sync.Mutex // guards lateWorkCur only; never held while a wait blocks
	lateWorkCur *lateWork  // the newest job; nil before the first sign-in
)

// lateWorkBound is how long a teardown or seal waits for the late job. It is derived from the moved steps' own
// store deadlines, read from the code:
//   - autoPublish makes one discovery PUT (publishDiscovery -> putRef -> discoPut). discoTimeout (15 s) bounds only
//     the discovery GETs; discoPut uses context.Background(), so its only bound is the transport's 30 s dial
//     timeout (store_transport.go). The PUT has no deadline of its own: the bound, not the step, ends the wait.
//   - enrollUnitAtLogin reads the head and the directory (resolveDK, loadAccountDir: capGet, retried for
//     capGetRetryWindow = 15 s, the same as storeGiveUpWindow) and writes through capWrite, whose gateway calls are
//     bounded by gwDefault (30 s).
//   - roamInWallet (Part 2) resolves the key (resolveDK, cached for the steps after it) and makes one strict wallet
//     read (getRef/getBlob, retried inside the store-retry window, 15 s), then waits at most walletSignInWait (10 s)
//     for the wallet lock. telHandoffRoamIn reads the head blob (the same window) and stages under telMu, with no
//     network wait.
//
// With Part 2 the four steps together can take longer than 45 s on a slow store that still answers. The bound is
// kept: it must stay under loginConnDeadline, and a step the bound overtakes is harmless -- mayWrite refuses its
// later writes, the wallet generation keeps no restore proof (every publisher refuses), and the hand-off stages
// nothing.
//
// One retry window (15 s) plus one gateway request (30 s) is 45 s: that covers a slow store that still answers. A
// dead store can cost more than that (one capGet attempt alone can), so there the bound ends the wait and mayWrite
// makes the late write harmless. The give-up clock (armStoreGiveUp) is NOT armed for the late job: it is process-wide,
// and arming it would cut a concurrent seal's retries.
//
// It must stay under loginConnDeadline (TestLateWorkBoundUnderLoginDeadline): BACKUP and the cold-lock sign-out send
// no WAIT lines, so their reply must still land inside the deadline handleLogin set. A var so tests shrink it.
var lateWorkBound = 45 * time.Second

// lateWorkStarted is a test seam, a no-op in production: startLateWork calls it synchronously, before the goroutine
// starts, so a test can order the job's start against the reply's writes.
var lateWorkStarted = func() {}

// startLateWork starts the session's late job: ONE goroutine that runs steps in order. A new sign-in first waits out
// an older job the same way a teardown does, so at most one job runs. A panic in a step ends the job (runSafe logs
// it) and done is still closed.
func startLateWork(dest, uid string, steps ...func(lw *lateWork)) {
	waitLateWork("new sign-in")
	lw := &lateWork{dest: dest, uid: uid, done: make(chan struct{})}
	lateWorkMu.Lock()
	lateWorkCur = lw
	lateWorkMu.Unlock()
	lateWorkStarted()
	goSafe("signin-late", func() {
		defer close(lw.done)             // registered first, so it runs on a panic too
		defer markTelHandoffDone(lw.uid) // h46 #1: a panic, an early end or a throwaway never holds arrivals to the cap
		for _, s := range steps {
			s(lw)
		}
	})
}

// waitLateWork blocks until the late job ends or lateWorkBound passes, whichever is first. With no job, a finished
// one or one already abandoned, it returns at once. why is a fixed literal at every call site.
func waitLateWork(why string) { waitLateWorkConn(nil, 0, false, why) }

// waitLateWorkConn is waitLateWork for a verb that answers a chooser read, in lockSessionForLogout's shape: every
// logoutWaitEvery it re-arms conn's deadline to window and, when sayWait is set and the wait has lasted
// logoutWaitFirst, writes `WAIT <seconds>`. Only LOGOUT sets sayWait: its reader (LogoutAck) skips WAIT lines, and
// every other reader takes the first line as its answer. On return the deadline is re-armed once more, so the reply
// gets a full window. A failed write is ignored and the wait goes on.
func waitLateWorkConn(conn net.Conn, window time.Duration, sayWait bool, why string) {
	lateWorkMu.Lock()
	lw := lateWorkCur
	lateWorkMu.Unlock()
	if lw == nil || lw.abandoned.Load() {
		return
	}
	select {
	case <-lw.done:
		return
	default:
	}
	if conn != nil {
		defer func() { conn.SetDeadline(time.Now().Add(window)) }() // the deadline counts from the return, not from here
	}
	start := time.Now()
	bound := time.NewTimer(lateWorkBound)
	defer bound.Stop()
	var tick <-chan time.Time
	if conn != nil {
		tk := time.NewTicker(logoutWaitEvery)
		defer tk.Stop()
		tick = tk.C
	}
	for {
		select {
		case <-lw.done:
			return
		case <-tick:
			conn.SetDeadline(time.Now().Add(window))
			if waited := time.Since(start); sayWait && waited >= logoutWaitFirst {
				fmt.Fprintf(conn, "WAIT %d\n", int(waited/time.Second))
			}
		case <-bound.C:
			lw.abandoned.Store(true)
			// An abandoned step may stay blocked in a store read for minutes; its staging is refused from now on
			// (mayWrite, asked under telMu), so releasing the claim here is never ahead of a staging that can still
			// happen. The waiter holds at most sessionMu, and sessionMu -> telMu is the allowed order.
			markTelHandoffDone(lw.uid)
			fmt.Fprintf(os.Stderr, "[logind] late sign-in work abandoned after %ds for %s (h46 #1)\n",
				int(time.Since(start)/time.Second), why)
			return
		}
	}
}

// mayWrite reports whether a step may still write: the job is not abandoned, and the marker still names this
// session. Every step calls it before it starts and again just before each write.
func (lw *lateWork) mayWrite() bool {
	if lw.abandoned.Load() {
		return false
	}
	// retryVpnup's rule (NWP-20261113-20): a damaged marker is still a live session and its uid line may be the part
	// that was lost, so an empty uid carries on (hence readRoamSessionState, never readRoamSession).
	_, _, mu, st := readRoamSessionState(lw.dest)
	return st != roamSessionAbsent && (mu == "" || mu == lw.uid)
}

// lateMayWrite runs a guarded step's check; nil means always (the direct callers outside the late job).
func lateMayWrite(f func() bool) bool { return f == nil || f() }

// errLateWriteDenied is what a store writer returns when its late-work guard said no before a request began (h46
// #1). It is NOT errStorePermanent: the store gave no answer, so it must not restart the give-up window
// (store_giveup.go). retryStoreWithinGuarded returns it at once, before it notes the attempt.
var errLateWriteDenied = errors.New("late sign-in work: the write was not started -- the job is abandoned or its session is gone (h46 #1)")

// lateWriteHook carries a late step's guard into one minio PutObject, whose client retries a failed request on its
// own (minio.MaxRetry), out of sight of retryStore. Passed as PutObjectOptions.Progress, minio wraps the body in a
// hook reader and seeks it, and so this hook, back to the start before EVERY attempt, the first included
// (executeMethod). A Seek here asks the guard and fails when it says no, which ends the PutObject before that
// attempt's request is built; a request already sent is never touched. Read only counts progress, so it accepts all.
type lateWriteHook struct {
	mayWrite func() bool
	denied   atomic.Bool
}

func (h *lateWriteHook) Read(b []byte) (int, error) { return len(b), nil }

func (h *lateWriteHook) Seek(offset int64, whence int) (int64, error) {
	if !h.mayWrite() {
		h.denied.Store(true)
		return 0, errLateWriteDenied
	}
	return offset, nil
}

// lateWriteProgress is the PutObjectOptions.Progress for a guarded write: nil (no hook, the request unchanged) when
// there is no guard.
func lateWriteProgress(mayWrite func() bool) (io.Reader, *lateWriteHook) {
	if mayWrite == nil {
		return nil, nil
	}
	h := &lateWriteHook{mayWrite: mayWrite}
	return h, h
}

// lateWriteErr maps a PutObject's error to errLateWriteDenied when the hook refused an attempt, whatever minio
// wrapped it in.
func lateWriteErr(h *lateWriteHook, err error) error {
	if err != nil && h != nil && h.denied.Load() {
		return errLateWriteDenied
	}
	return err
}
