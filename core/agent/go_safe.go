package main

import (
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"sync/atomic"
	"time"
)

// NWP-20261014-66: a goroutine the daemon starts must not be able to take the daemon down.
//
// A store read that fails in transport PANICS (checkRead, storeReadErr) by design: the CLI verbs map it to
// exitStoreUnreachable in main's recover, and every daemon connection handler recovers it (handleLogin). A goroutine
// started from a handler has neither: its panic unwinds past every recover the handler holds, and Go then ends the
// PROCESS. Device-proven on lynx 2026101401 (userdebug), 2026-10-14: Wi-Fi was cut seconds after a sign-in, the
// background finish-tie read the profile's tie state (finishTieAtSignIn -> seSessionStatus -> headKey -> capGet ->
// checkRead), the read failed, and the login daemon died. init restarted it twice, it came back knowing no session,
// the chooser's Log off reached no daemon that knew one and fell back to a reboot, and the boot wipe removed the
// session WITHOUT sealing it. Losing the network right after a sign-in cost that session's changes.
//
// So every `go` statement in this package's daemon code goes through goSafe or goSafeLoop, and
// TestEveryGoroutineGoesThroughGoSafe holds that by an AST walk: a raw `go` statement -- or time.AfterFunc,
// context.AfterFunc or a .Go method, which start a goroutine too -- fails CI unless it is in the test's allow-list
// with its reason (today: goroutines that only ever run in a short-lived worker process, where a panic ending the
// process IS the contract).
//
// ⚠ A recover is not a rollback. Whatever the goroutine left half-done when it panicked stays half-done: a mutex it
// locked without a defer stays locked, a flag it set without a defer stays set. goSafe only turns "the daemon dies
// and its session is lost" into "this one background job ended early" -- and where the half-done state is worse than
// the crash, the state has to be released from a defer. This slice did that for the restart watchdog's give-back
// (end_unsaved.go), syncLoop's locks and seal-run announce, the logoff's verdict section, the gate-alarm relay,
// uploadBlobs' done and storedAppsCached's in-flight flag. A goroutine whose exit someone waits on must signal that
// exit from a defer, so the signal still fires on a panic.

// goSafeTag prefixes the recovered line: the login daemon's own "[logind]" unless runMediad stored "[mediad]". Atomic
// because main has already started the netlink watcher (installResolver) when runMediad stores it.
var goSafeTag atomic.Value

func goSafeTagNow() string {
	if t, ok := goSafeTag.Load().(string); ok {
		return t
	}
	return "[logind]"
}

// goSafe runs fn on a new goroutine; a panic out of fn is recovered and logged (goSafeLine), never re-panicked.
func goSafe(job string, fn func()) {
	if track := goSafeTrack.Load(); track != nil {
		if done := (*track)(job); done != nil {
			inner := fn
			fn = func() { defer done(); runSafe(job, inner) }
		}
	}
	go runSafe(job, fn)
}

// goSafeTrack is a test-only start hook, nil in production (NWP-20261024-13). goSafe calls it synchronously, before the
// go statement, so a job counts from the instant goSafe is called and not from when the scheduler first runs it. A
// non-nil done it returns runs when the job has ended, after an inner runSafe has recovered and logged its panic
// (NWP-20261128-14), so a test that waits for it may restore os.Stderr; the outer runSafe then sees no panic.
var goSafeTrack atomic.Pointer[func(job string) (done func())]

// goSafeLoop is goSafe for a loop that is meant to run for the life of the process (the periodic seal, the re-key
// job, mediad's pin and prefetch pollers, the netlink watcher). A panic out of fn is recovered and logged, and fn is
// started again, because a loop that silently stops is its own data loss -- a dead periodic seal on an amnesiac phone
// loses everything since the last one, exactly what NWP-20260901-35 recorded. A normal return of fn ends it.
//
// A panic that is deterministic comes back on every pass, so the restarts back off: goSafeLoopPause, doubling to
// goSafeLoopMaxPause. Only the first goSafeLoopStacks panics print their stack; the rest are one line each. A pass
// that ran longer than the cap before it failed is not the same fault spinning, so it starts both afresh: its own
// panic prints a stack, and the backoff begins again at goSafeLoopPause.
func goSafeLoop(job string, fn func()) {
	goSafe(job, func() {
		pause, panics := goSafeLoopPause, 0
		for {
			start := goSafeNow()
			healthy := func() bool { return goSafeNow().Sub(start) > goSafeLoopMaxPause }
			if runSafeStack(job, fn, func() bool { return panics < goSafeLoopStacks || healthy() }) {
				return
			}
			if healthy() {
				pause, panics = goSafeLoopPause, 0 // both budgets start again, this panic counted below
			}
			panics++
			goSafeSleep(pause)
			if pause *= 2; pause > goSafeLoopMaxPause {
				pause = goSafeLoopMaxPause
			}
		}
	})
}

// The restart backoff of goSafeLoop, how many of one loop's panics print a stack, and its clock. Variables so a
// test can shorten and observe them.
var (
	goSafeLoopPause    = 5 * time.Second
	goSafeLoopMaxPause = 5 * time.Minute
	goSafeLoopStacks   = 3
	goSafeSleep        = time.Sleep
	goSafeNow          = time.Now
)

// runSafe runs fn and reports whether it returned normally. A panic is recovered and logged by goSafeLine.
func runSafe(job string, fn func()) (returned bool) {
	return runSafeStack(job, fn, func() bool { return true })
}

// runSafeStack is runSafe with the stack of a bug's panic printed only when withStack, asked at the panic, says so.
func runSafeStack(job string, fn func(), withStack func() bool) (returned bool) {
	defer func() {
		if r := recover(); r != nil {
			stack := []byte("(stack omitted: this loop has panicked before)\n")
			if withStack() {
				stack = debug.Stack()
			}
			fmt.Fprint(os.Stderr, goSafeLine(job, r, stack))
			returned = false
		}
	}()
	fn()
	return true
}

// goSafeLine is the log line for a panic runSafe recovered from the goroutine named job (a fixed label, never a
// profile). The value is redacted the way every store error is (redactNameIn with no name): a store read's panic
// carries the transport error, and that can carry a presigned URL, whose query string is a live cap, or a
// ref/<64 hex>, which is a profile string. A deliberate panic in this package carries a scope suffix at most, never a
// profile name.
//
// A store read that could not reach the store is the expected case and gets exactly one line. Anything else is a
// bug: its stack follows, because the crash this replaces printed one and it is the only clue. A stack holds
// function names, files, lines and raw argument words -- never the bytes of a string.
func goSafeLine(job string, r any, stack []byte) string {
	text := fmt.Sprint(r)
	if e, ok := r.(error); ok {
		text = e.Error()
		if errors.Is(e, errStoreUnreachable) {
			return fmt.Sprintf("%s %s recovered: store unreachable: %s (NWP-20261014-66)\n", goSafeTagNow(), job, redactNameIn(text, ""))
		}
	}
	return fmt.Sprintf("%s %s recovered: %s (NWP-20261014-66)\n%s", goSafeTagNow(), job, redactNameIn(text, ""), stack)
}
