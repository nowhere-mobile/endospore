package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261028-02: the give-up window of a sign-in's restore processes and a DELETE. The tests share
// process-global state (storeGiveUp, s3RetryBase), so none runs in parallel.

func resetStoreGiveUpForTest() {
	storeGiveUp.mu.Lock()
	storeGiveUp.armed = 0
	storeGiveUp.armedAt = time.Time{}
	storeGiveUp.failingSince = time.Time{}
	storeGiveUp.answeredAt = time.Time{}
	storeGiveUp.logged = false
	storeGiveUp.mu.Unlock()
}

// setupStoreGiveUp zeroes the backoff, fakes the give-up clock and returns it for the test to advance.
func setupStoreGiveUp(t *testing.T) *time.Time {
	t.Helper()
	oldNow, oldBase := storeGiveUpNow, s3RetryBase
	s3RetryBase = 0
	now := time.Unix(1_000_000, 0)
	storeGiveUpNow = func() time.Time { return now }
	resetStoreGiveUpForTest()
	t.Cleanup(func() {
		storeGiveUpNow, s3RetryBase = oldNow, oldBase
		resetStoreGiveUpForTest()
	})
	return &now
}

// failOp is an op that counts its calls, spends 4 s of fake time and fails as a dead network does.
func failOp(clock *time.Time, calls *int) func() error {
	return func() error {
		*calls++
		*clock = clock.Add(4 * time.Second)
		return errors.New("dial tcp: i/o timeout")
	}
}

func TestStoreGiveUpUnarmedKeepsEveryAttempt(t *testing.T) {
	clock := setupStoreGiveUp(t)
	calls := 0
	err := retryStoreWithin("GET x", retryStoreUnbounded, failOp(clock, &calls))
	if calls != storeRetryAttempts {
		t.Errorf("unarmed made %d attempts, want %d", calls, storeRetryAttempts)
	}
	if err == nil || !strings.Contains(err.Error(), "i/o timeout") || errors.Is(err, errStoreGaveUp) {
		t.Errorf("unarmed error = %v, want the op's own", err)
	}
}

func TestStoreGiveUpArmedStopsAfterTheWindow(t *testing.T) {
	clock := setupStoreGiveUp(t)
	defer armStoreGiveUp("test")()
	calls := 0
	err := retryStoreWithin("GET x", retryStoreUnbounded, failOp(clock, &calls))
	if calls != 4 {
		t.Errorf("armed made %d attempts, want 4 (starts at 0/4/8/12 s, the 4th fails at 16 s)", calls)
	}
	if err == nil || !strings.Contains(err.Error(), "i/o timeout") {
		t.Errorf("first call error = %v, want the op's own", err)
	}
	calls = 0
	err = retryStoreWithin("GET y", retryStoreUnbounded, failOp(clock, &calls))
	if calls != 0 {
		t.Errorf("second call ran the op %d times, want 0", calls)
	}
	if !errors.Is(err, errStoreUnreachable) || errors.Is(err, errStorePermanent) {
		t.Errorf("second call error = %v, want unreachable and not permanent", err)
	}
	func() {
		defer func() {
			r := recover()
			if r == nil {
				t.Error("checkRead did not panic")
				return
			}
			if got := exitStatus(r); got != exitStoreUnreachable {
				t.Errorf("exitStatus = %d, want %d", got, exitStoreUnreachable)
			}
		}()
		checkRead(err)
	}()
}

func TestStoreGiveUpSuccessRestartsTheWindow(t *testing.T) {
	clock := setupStoreGiveUp(t)
	defer armStoreGiveUp("test")()
	fail := errors.New("dial tcp: i/o timeout")
	t0 := *clock
	noteStoreAttempt(fail)
	*clock = t0.Add(10 * time.Second)
	noteStoreAttempt(nil)
	noteStoreAttempt(fail)
	for _, c := range []struct {
		at   time.Duration
		want bool
	}{{16, false}, {24, false}, {25, true}} {
		*clock = t0.Add(c.at * time.Second)
		if got := storeGivenUp(); got != c.want {
			t.Errorf("at +%ds storeGivenUp = %v, want %v", c.at, got, c.want)
		}
	}
}

// A request that began before a response and fails after it must not backdate the outage past that response
// (RF-001): the outage counts from the response, so the window is 15 s from it, not from the failed start.
func TestStoreGiveUpLateFailureCannotBackdatePastAResponse(t *testing.T) {
	clock := setupStoreGiveUp(t)
	defer armStoreGiveUp("test")()
	t0 := *clock
	*clock = t0.Add(10 * time.Second)
	noteStoreAttempt(nil)
	*clock = t0.Add(16 * time.Second)
	noteStoreAttemptFrom(t0, errors.New("dial tcp: i/o timeout"))
	for _, c := range []struct {
		at   time.Duration
		want bool
	}{{16, false}, {24, false}, {25, true}} {
		*clock = t0.Add(c.at * time.Second)
		if got := storeGivenUp(); got != c.want {
			t.Errorf("at +%ds storeGivenUp = %v, want %v", c.at, got, c.want)
		}
	}
}

func TestStoreGiveUpCountsFromTheArm(t *testing.T) {
	clock := setupStoreGiveUp(t)
	t0 := *clock
	noteStoreAttempt(errors.New("dial tcp: i/o timeout"))
	*clock = t0.Add(60 * time.Second)
	defer armStoreGiveUp("test")()
	for _, c := range []struct {
		at   time.Duration
		want bool
	}{{60, false}, {74, false}, {75, true}} {
		*clock = t0.Add(c.at * time.Second)
		if got := storeGivenUp(); got != c.want {
			t.Errorf("at +%ds storeGivenUp = %v, want %v", c.at, got, c.want)
		}
	}
}

func TestStoreGiveUpPermanentAndNilAreAnswers(t *testing.T) {
	clock := setupStoreGiveUp(t)
	defer armStoreGiveUp("test")()
	fail := errors.New("dial tcp: i/o timeout")
	perm := fmt.Errorf("x: %w", errStorePermanent)
	noteStoreAttempt(fail)
	*clock = clock.Add(10 * time.Second)
	noteStoreAttempt(perm)
	*clock = clock.Add(10 * time.Second)
	if storeGivenUp() {
		t.Error("a permanent refusal did not count as a response")
	}
	noteStoreAttempt(fail)
	*clock = clock.Add(10 * time.Second)
	noteStoreAttempt(nil)
	*clock = clock.Add(10 * time.Second)
	if storeGivenUp() {
		t.Error("a nil result did not count as a response")
	}
	calls := 0
	err := retryStoreWithin("GET x", retryStoreUnbounded, func() error {
		calls++
		*clock = clock.Add(20 * time.Second)
		return perm
	})
	if calls != 1 || !errors.Is(err, errStorePermanent) || storeGivenUp() {
		t.Errorf("permanent op: calls=%d err=%v givenUp=%v", calls, err, storeGivenUp())
	}
}

func TestStoreGiveUpDisarm(t *testing.T) {
	clock := setupStoreGiveUp(t)
	run := func() int {
		calls := 0
		retryStoreWithin("GET x", retryStoreUnbounded, failOp(clock, &calls))
		return calls
	}
	disarm := armStoreGiveUp("test")
	if got := run(); got != 4 {
		t.Errorf("armed: %d attempts, want 4", got)
	}
	disarm()
	disarm()
	if got := run(); got != storeRetryAttempts {
		t.Errorf("after disarm: %d attempts, want %d", got, storeRetryAttempts)
	}

	resetStoreGiveUpForTest()
	a := armStoreGiveUp("a")
	b := armStoreGiveUp("b")
	b()
	b()
	if got := run(); got != 4 {
		t.Errorf("one of two arms disarmed: %d attempts, want 4", got)
	}
	if got := run(); got != 0 {
		t.Errorf("still armed after give-up: %d attempts, want 0", got)
	}
	a()
	if got := run(); got != storeRetryAttempts {
		t.Errorf("both disarmed: %d attempts, want %d", got, storeRetryAttempts)
	}
}

func TestStoreGiveUpIsArmedWhereDecided(t *testing.T) {
	mainSrc, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(mainSrc)
	body := func(sig string) string {
		i := strings.Index(src, sig)
		if i < 0 {
			t.Fatalf("%s not found", sig)
		}
		rest := src[i:]
		if j := strings.Index(rest[1:], "\nfunc "); j >= 0 {
			rest = rest[:j+1]
		}
		return rest
	}
	m := body("\nfunc main() {")
	if !strings.Contains(m, `os.Getenv("NOWHERE_STORE_GIVEUP") == "1"`) || !strings.Contains(m, "armStoreGiveUp(") {
		t.Error("main() does not arm the give-up on NOWHERE_STORE_GIVEUP == \"1\"")
	}

	d := body("\nfunc handleDelete(conn net.Conn")
	blank := "fmt.Fprint(conn, \"BLANK\\n\")\n\t\treturn\n\t}\n"
	k := strings.Index(d, blank)
	if k < 0 {
		t.Fatal("handleDelete's BLANK check not found")
	}
	var stmts []string
	for _, ln := range strings.Split(d[k+len(blank):], "\n") {
		if s := strings.TrimSpace(ln); s != "" && !strings.HasPrefix(s, "//") {
			stmts = append(stmts, s)
			if len(stmts) == 2 {
				break
			}
		}
	}
	// NWP-20261116-01 (h46 #1, late_work.go): the late-work wait comes first, so its up-to-lateWorkBound wait is not
	// counted against the DELETE's give-up window; the arm is the statement right after it.
	if len(stmts) == 2 && strings.HasPrefix(stmts[0], `waitLateWorkConn(conn, `) {
		stmts = stmts[1:]
	}
	if len(stmts) == 0 || !strings.HasPrefix(stmts[0], `defer armStoreGiveUp("delete")()`) {
		t.Errorf("handleDelete's first statement after the BLANK check (and the late-work wait) is %q, want the deferred arm", stmts)
	}

	sh, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Fatal(err)
	}
	pin := regexp.MustCompile(`^\[ "\$op" = "in" \] && export NOWHERE_STORE_GIVEUP=1\b`)
	n := 0
	for _, ln := range strings.Split(string(sh), "\n") {
		if strings.HasPrefix(strings.TrimSpace(ln), "#") || !strings.Contains(ln, "export NOWHERE_STORE_GIVEUP=1") {
			continue
		}
		n++
		if !pin.MatchString(ln) {
			t.Errorf("the export is not guarded by the in op: %q", ln)
		}
	}
	if n != 1 {
		t.Errorf("nowhere_roamd.sh has %d exports of NOWHERE_STORE_GIVEUP, want exactly 1", n)
	}
}
