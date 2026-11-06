package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// NWP-20260901-35. syncLoop double-locked pendingReapMu and deadlocked the daemon for the life of the boot.
//
// WHY A SOURCE TEST AND NOT A BEHAVIOURAL ONE. The defect is a permanent deadlock in an infinite loop: a test
// that exercised it would hang rather than fail, and hanging the suite is worse than not catching it. The
// mutex is also plain package state with no seam to inject, so there is nothing to assert against at runtime
// that would not itself have to take the lock. Checking the lock DISCIPLINE in the source is the honest
// version of this test -- it catches the exact shape that shipped, deterministically, in milliseconds.
//
// HOW IT SHIPPED, because the class matters more than the instance. NWP-20260901-26 was applied ON TOP OF the
// pre-existing `pendingReapMu.Lock()` instead of replacing it, leaving two Lock() calls with only comments
// between them. sync.Mutex is not reentrant, so the second call blocked forever WHILE THE GOROUTINE STILL
// HELD THE MUTEX. Nothing caught it: the unit tests cover syncDeferReason (the pure function), not the lock
// around it; `go vet` does not model mutex reentrancy; and the release-time artifact checks verify that
// symbols are PRESENT, not that they work. The only visible scar was indentation -- the inserted block sat at
// one tab inside a two-tab block -- which reads as cosmetic and was skimmed past twice.
//
// The blast radius is why this is worth a permanent guard: pendingReapMu also guards the manual backup,
// logoff, POLL/ACK-REAP, SEAL-STATUS and the on-demand materialise window. On an amnesiac device whose /data
// is wiped at power-off, a permanently dead periodic seal is silent data loss.

var lockLine = regexp.MustCompile(`\bpendingReapMu\.(Lock|Unlock)\(\)`)

// funcBody returns the body of a top-level func, from its opening line to the closing brace in column 0.
func funcBody(t *testing.T, src, name string) []string {
	t.Helper()
	lines := strings.Split(src, "\n")
	start := -1
	for i, l := range lines {
		if strings.HasPrefix(l, "func "+name+"(") {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatalf("func %s not found -- this test is stale, not the code", name)
	}
	for i := start + 1; i < len(lines); i++ {
		if lines[i] == "}" {
			return lines[start : i+1]
		}
	}
	t.Fatalf("no closing brace for %s", name)
	return nil
}

// stripComments drops // lines so a mutex named in prose (this file's own history, for instance) is not
// mistaken for a call. Deliberately line-based: the patterns matched are whole statements.
func stripComments(lines []string) []string {
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		if s := strings.TrimSpace(l); strings.HasPrefix(s, "//") {
			continue
		}
		out = append(out, l)
	}
	return out
}

func TestSyncLoopPendingReapMuBalanced(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"syncLoop"} {
		body := stripComments(funcBody(t, string(b), fn))
		depth, locks, unlocks := 0, 0, 0
		for i, l := range body {
			for _, m := range lockLine.FindAllStringSubmatch(l, -1) {
				if m[1] == "Lock" {
					depth++
					locks++
					// The whole bug: a second Lock with no Unlock between. sync.Mutex is not reentrant,
					// so this does not merely nest -- it blocks forever, holding the mutex.
					if depth > 1 {
						t.Fatalf("%s: pendingReapMu.Lock() at body line %d while ALREADY HELD -- "+
							"sync.Mutex is not reentrant, this deadlocks the daemon forever (NWP-20260901-35).\n  %s",
							fn, i+1, strings.TrimSpace(l))
					}
				} else {
					depth--
					unlocks++
					if depth < 0 {
						t.Fatalf("%s: pendingReapMu.Unlock() at body line %d with the mutex not held", fn, i+1)
					}
				}
			}
		}
		if depth != 0 {
			t.Errorf("%s: pendingReapMu left held on exit (depth %d)", fn, depth)
		}
		if locks != unlocks {
			t.Errorf("%s: %d Lock() vs %d Unlock()", fn, locks, unlocks)
		}
		if locks == 0 {
			t.Errorf("%s: no pendingReapMu use found -- the test is looking at the wrong function", fn)
		}
	}
}
