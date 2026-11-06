package main

import (
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"sync/atomic"
)

// NWP-20261106-08: handleLogin ended in a bare recover(), so a panic in a daemon verb -- a store read that failed
// after its retries (storeReadErr), a tampered head (resolveKeyHeadSE), a rollback (checkRollback) -- ended with no
// reply and no line, and goSafe("connection") never saw it. recoverConnPanic is deferred directly in handleLogin
// (recover only works there), logs one line and returns: it never re-panics, so the connection still closes and the
// daemon lives on. It mirrors goSafeLine (NWP-20261014-66) and bestEffortPanic (NWP-20261027-16).
//
// The text is %q-quoted after redactNameIn, so log_scrub's and applyIssueNameRules' quoted-token rule replaces it
// whole (a panic can carry a session's file path); the stack, which holds function names and lines and never string
// bytes, is what stays readable in a report. Never printed: the request's first line (a legacy LOGIN's is a profile
// name), the verb, the peer.
//
// Two budgets, because a polled verb failing on a dead store would otherwise spend the only one and silence the
// tampered-head or rollback line this exists to keep.
var (
	connPanicStoreMax = 50
	connPanicBugMax   = 50
	connPanicStacks   = 3
	connPanicStoreN   atomic.Int64
	connPanicBugN     atomic.Int64
)

func recoverConnPanic() {
	if r := recover(); r != nil {
		fmt.Fprint(os.Stderr, connPanicLine(r))
	}
}

// connPanicLine is the line for a recovered panic, "" once its budget is spent.
func connPanicLine(r any) string {
	text := fmt.Sprint(r)
	e, isErr := r.(error)
	if isErr {
		text = e.Error()
	}
	text = redactNameIn(text, "")
	if isErr && errors.Is(e, errStoreUnreachable) {
		switch n := connPanicStoreN.Add(1); {
		case n <= int64(connPanicStoreMax):
			return fmt.Sprintf("[logind] connection recovered: store unreachable %q (NWP-20261106-08)\n", text)
		case n == int64(connPanicStoreMax)+1:
			return "[logind] connection recovered: further store-unreachable panics are not logged (NWP-20261106-08)\n"
		}
		return ""
	}
	switch n := connPanicBugN.Add(1); {
	case n <= int64(connPanicBugMax):
		stack := []byte("(stack omitted)\n")
		if n <= int64(connPanicStacks) {
			stack = debug.Stack()
		}
		return fmt.Sprintf("[logind] connection recovered: panic %q (NWP-20261106-08)\n%s", text, stack)
	case n == int64(connPanicBugMax)+1:
		return "[logind] connection recovered: further panics are not logged (NWP-20261106-08)\n"
	}
	return ""
}
