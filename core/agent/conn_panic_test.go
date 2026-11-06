package main

import (
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261106-08: a panic in a daemon verb leaves one scrubbable line in login.log (conn_panic.go). Not parallel:
// the hooks and counters are package-global.

// connPanicFixture makes the DELETE arm panic with *v, lowers nothing, and restores every hook on cleanup.
func connPanicFixture(t *testing.T, v *any) {
	t.Helper()
	oldFn, oldStore, oldBug, oldStacks := handleDeleteFn, connPanicStoreMax, connPanicBugMax, connPanicStacks
	reset := func() {
		connPanicStoreN.Store(0)
		connPanicBugN.Store(0)
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealRunAt, deleteInFlight = false, "", time.Time{}, false
		pendingReapMu.Unlock()
	}
	handleDeleteFn = func(net.Conn, string, string, string, int) { panic(*v) }
	reset()
	t.Cleanup(func() {
		handleDeleteFn, connPanicStoreMax, connPanicBugMax, connPanicStacks = oldFn, oldStore, oldBug, oldStacks
		reset()
	})
}

func connPanicSend(t *testing.T) string {
	t.Helper()
	return captureStderr(t, func() { evictConn(t, t.TempDir(), "DELETE\nalice\npw\n") })
}

func connPanicCount(out, sub string) int { return strings.Count(out, sub) }

func TestConnPanicStoreReadIsOneLine(t *testing.T) {
	hex := strings.Repeat("ab", 32)
	var v any = storeReadErr{errors.New("Get \"https://store.example/ref/" + hex + "?X-Amz-Signature=abc\": EOF")}
	connPanicFixture(t, &v)
	out := connPanicSend(t)
	if n := connPanicCount(out, "connection recovered: store unreachable"); n != 1 {
		t.Fatalf("want one store-unreachable line, got %d:\n%s", n, out)
	}
	if strings.Contains(out, "X-Amz-Signature") || strings.Contains(out, "ref/"+hex) {
		t.Fatalf("the line leaks the presigned query or the head key:\n%s", out)
	}
	if strings.Contains(out, "goroutine ") {
		t.Fatalf("a store-unreachable line carries no stack:\n%s", out)
	}
	if !sessionMu.TryLock() {
		t.Fatal("sessionMu stayed held after the recovered panic")
	}
	sessionMu.Unlock()
	pendingReapMu.Lock()
	held := deleteInFlight
	pendingReapMu.Unlock()
	if held {
		t.Fatal("deleteInFlight stayed set after the recovered panic")
	}
}

func TestConnPanicTamperedHeadHasAStack(t *testing.T) {
	var v any = errors.New("head signature invalid -- the store served a tampered head")
	connPanicFixture(t, &v)
	lines := strings.Split(connPanicSend(t), "\n")
	if len(lines) < 2 || !strings.Contains(lines[0], `connection recovered: panic "head signature invalid -- the store served a tampered head"`) {
		t.Fatalf("no panic line first: %q", lines)
	}
	if !strings.HasPrefix(lines[1], "goroutine ") {
		t.Fatalf("no stack after the panic line: %q", lines)
	}
}

func TestConnPanicTextIsScrubbable(t *testing.T) {
	var v any = errors.New("open /data/media/10/DCIM/IMG trip one.jpg: permission denied")
	connPanicFixture(t, &v)
	var line string
	for _, l := range strings.Split(connPanicSend(t), "\n") {
		if strings.Contains(l, "connection recovered: panic") {
			line = l
		}
	}
	if line == "" {
		t.Fatal("no panic line")
	}
	got := applyIssueNameRules(line)
	if strings.Contains(got, "IMG trip") || strings.Contains(got, "DCIM") || !strings.Contains(got, "connection recovered") {
		t.Fatalf("the line is not scrubbed whole: %q", got)
	}
}

func TestConnPanicBudgetsAreSeparate(t *testing.T) {
	var v any = storeReadErr{errors.New("EOF")}
	connPanicFixture(t, &v)
	connPanicStoreMax = 3
	var all string
	for i := 0; i < 5; i++ {
		all += connPanicSend(t)
	}
	if n := connPanicCount(all, "connection recovered: store unreachable"); n != 3 {
		t.Fatalf("want 3 store lines, got %d:\n%s", n, all)
	}
	if n := connPanicCount(all, "further store-unreachable panics are not logged"); n != 1 {
		t.Fatalf("want one store 'further' line, got %d:\n%s", n, all)
	}
	v = errors.New("rollback detected for head")
	out := connPanicSend(t)
	if !strings.Contains(out, "connection recovered: panic") || !strings.Contains(out, "goroutine ") {
		t.Fatalf("a tampered-head panic after the store budget is silenced:\n%s", out)
	}
	connPanicBugMax = 2
	later := connPanicSend(t) + connPanicSend(t)
	if connPanicCount(later, "connection recovered: panic") != 1 || connPanicCount(later, "further panics are not logged") != 1 {
		t.Fatalf("the bug budget is not bounded at 2:\n%s", later)
	}
	more := connPanicSend(t)
	v = storeReadErr{errors.New("EOF")}
	more += connPanicSend(t)
	if more != "" {
		t.Fatalf("a spent budget still logs:\n%s", more)
	}
}
