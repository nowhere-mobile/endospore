package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// logoutWaitVars shrinks the three pacing vars for one test (NWP-20261106-04).
func logoutWaitVars(t *testing.T, deadline, first, every time.Duration) {
	t.Helper()
	d, f, e := loginConnDeadline, logoutWaitFirst, logoutWaitEvery
	t.Cleanup(func() { loginConnDeadline, logoutWaitFirst, logoutWaitEvery = d, f, e })
	loginConnDeadline, logoutWaitFirst, logoutWaitEvery = deadline, first, every
}

// logoutWaitReply sends req while the test holds sessionMu for hold, and returns the whole reply. The lock is
// released on every exit path, as replyWhileHeld does.
func logoutWaitReply(t *testing.T, dest, req string, hold time.Duration) string {
	t.Helper()
	sessionMu.Lock()
	held := true
	defer func() {
		if held {
			sessionMu.Unlock()
		}
	}()
	c := driveLoginAsync(t, dest, req)
	time.Sleep(hold)
	sessionMu.Unlock()
	held = false
	select {
	case got := <-c:
		return got
	case <-time.After(5 * time.Second):
		t.Fatal("no reply 5 s after sessionMu was released")
	}
	return ""
}

// logoutWaitHang is the hang guard of the stepped cases: it fires only when the code under test never reaches the
// event, so no load can reach it on correct code.
const logoutWaitHang = 30 * time.Second

// logoutWaitSteps replaces lockSessionForLogout's tick source and clock with hand-stepped ones.
//
// A send on ticks returns when the loop has TAKEN the tick, not when the tick arm has finished. The arm reads the clock
// after that, so a test that moved the clock straight after a send could change the value the arm reads. reads closes
// that gap: the fake clock takes its value, then reports one read. step waits for that report before it returns, and
// the next step moves the clock only after that.
type logoutWaitSteps struct {
	ticks   chan time.Time
	reads   chan struct{}
	waited  atomic.Int64 // the fake time since the wait began, in ns
	every   atomic.Int64 // the interval the loop asked the tick source for
	stopped atomic.Int64 // how many times the loop stopped the tick source
}

func logoutWaitStepped(t *testing.T) *logoutWaitSteps {
	t.Helper()
	h := &logoutWaitSteps{ticks: make(chan time.Time), reads: make(chan struct{}, 64)}
	tk, now := logoutWaitTicker, logoutWaitNow
	t.Cleanup(func() { logoutWaitTicker, logoutWaitNow = tk, now })
	logoutWaitTicker = func(d time.Duration) (<-chan time.Time, func()) {
		h.every.Store(int64(d))
		return h.ticks, func() { h.stopped.Add(1) }
	}
	base := time.Unix(1_000_000, 0) // far from real time: a deadline taken from this clock would be long past
	logoutWaitNow = func() time.Time {
		v := base.Add(time.Duration(h.waited.Load()))
		h.reads <- struct{}{}
		return v
	}
	return h
}

// began waits until the loop has read its start time, so the clock can move.
func (h *logoutWaitSteps) began(t *testing.T) {
	t.Helper()
	select {
	case <-h.reads:
	case <-time.After(logoutWaitHang):
		t.Fatal("the wait never read its start time: LOGOUT is not in lockSessionForLogout's loop")
	}
}

// step sets the fake wait, hands the loop one tick and returns once the tick arm has read the clock.
func (h *logoutWaitSteps) step(t *testing.T, waited time.Duration) {
	t.Helper()
	h.waited.Store(int64(waited))
	select {
	case h.ticks <- time.Now():
	case <-time.After(logoutWaitHang):
		t.Fatal("the wait loop took no tick")
	}
	select {
	case <-h.reads:
	case <-time.After(logoutWaitHang):
		t.Fatal("the tick arm never read the clock")
	}
}

// logoutWaitConn records, in order, each SetDeadline ("deadline") and each Write (its text) on one end of a pipe; a
// goroutine drains the other end.
type logoutWaitConn struct {
	net.Conn
	mu        sync.Mutex
	events    []string
	deadlines []time.Time
}

func (c *logoutWaitConn) SetDeadline(d time.Time) error {
	c.mu.Lock()
	c.events = append(c.events, "deadline")
	c.deadlines = append(c.deadlines, d)
	c.mu.Unlock()
	return c.Conn.SetDeadline(d)
}

func (c *logoutWaitConn) Write(b []byte) (int, error) {
	c.mu.Lock()
	c.events = append(c.events, string(b))
	c.mu.Unlock()
	return c.Conn.Write(b)
}

// logoutWaitHeld runs lockSessionForLogout against a recording conn while the test holds sessionMu, drives ticks, and
// returns what the conn saw once the call has returned. The cleanup leaves sessionMu free on every exit path, and runs
// before the seams and the pacing vars are restored.
func logoutWaitHeld(t *testing.T, h *logoutWaitSteps, ticks ...time.Duration) *logoutWaitConn {
	t.Helper()
	cli, srv := net.Pipe()
	go io.Copy(io.Discard, cli)
	rec := &logoutWaitConn{Conn: srv}
	sessionMu.Lock()
	released := false
	release := func() {
		if !released {
			released = true
			sessionMu.Unlock()
		}
	}
	dest := t.TempDir()
	done := make(chan struct{})
	go func() {
		defer close(done)
		lockSessionForLogout(rec, dest)
	}()
	t.Cleanup(func() {
		release()
		select {
		case <-done:
			sessionMu.Unlock() // the call returned holding it
		case <-time.After(logoutWaitHang):
			t.Error("lockSessionForLogout never returned after sessionMu was released")
		}
		cli.Close()
		srv.Close()
	})
	h.began(t)
	for _, w := range ticks {
		h.step(t, w)
	}
	release()
	select {
	case <-done:
	case <-time.After(logoutWaitHang):
		t.Fatal("lockSessionForLogout never returned after sessionMu was released")
	}
	if sessionMu.TryLock() { // the cleanup unlocks what this took
		t.Fatal("lockSessionForLogout returned without holding sessionMu")
	}
	return rec
}

// W1: Q116's window 1. One tick below logoutWaitFirst re-arms and writes nothing; two ticks at or past it re-arm and
// write `WAIT <seconds>` from the clock; taking the lock re-arms once more. Every deadline is real time.
func TestLogoutWait_W1_WaitLinesKeepTheReplyAlive(t *testing.T) {
	const first = 20 * time.Second
	logoutWaitVars(t, time.Hour, first, 7*time.Second)
	h := logoutWaitStepped(t)
	began := time.Now()
	rec := logoutWaitHeld(t, h, first-time.Nanosecond, first, 45*time.Second)
	got := strings.Join(rec.events, "|")
	if want := "deadline|deadline|WAIT 20\n|deadline|WAIT 45\n|deadline"; got != want {
		t.Fatalf("the conn saw %q, want %q (Q116)", got, want)
	}
	for _, d := range rec.deadlines {
		if !d.After(began) {
			t.Fatalf("deadline %v is not in real time (the wait began at %v)", d, began)
		}
	}
	if got := time.Duration(h.every.Load()); got != 7*time.Second {
		t.Fatalf("the tick source was asked for %v, want logoutWaitEvery", got)
	}
	if got := h.stopped.Load(); got != 1 {
		t.Fatalf("the tick source was stopped %d times, want 1", got)
	}
}

// W2: no WAIT line before logoutWaitFirst, however many ticks land.
func TestLogoutWait_W2_NoWaitLineBeforeFirst(t *testing.T) {
	const first = 20 * time.Second
	logoutWaitVars(t, time.Hour, first, 7*time.Second)
	h := logoutWaitStepped(t)
	rec := logoutWaitHeld(t, h, 0, first/2, first-time.Nanosecond)
	got := strings.Join(rec.events, "|")
	if want := "deadline|deadline|deadline|deadline"; got != want {
		t.Fatalf("the conn saw %q, want no write and one deadline per tick plus one (Q116)", got)
	}
}

// W3: a free lock answers at once.
func TestLogoutWait_W3_FreeLockAnswersAtOnce(t *testing.T) {
	logoutWaitVars(t, 2*time.Second, 400*time.Millisecond, 50*time.Millisecond)
	if got := driveLogin(t, t.TempDir(), "LOGOUT\n"); got != "OK" {
		t.Fatalf("LOGOUT with a free lock answered %q, want exactly OK", got)
	}
}

// W4: every other serialized verb takes its first line as the answer, so it never gets a WAIT line.
func TestLogoutWait_W4_OtherVerbsGetNoWaitLine(t *testing.T) {
	logoutWaitVars(t, 2*time.Second, 100*time.Millisecond, 100*time.Millisecond)
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, "apps.out"), []byte("com.example.app\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := logoutWaitReply(t, dest, "GET-APPS\n", 250*time.Millisecond); got != "com.example.app" {
		t.Fatalf("GET-APPS held 250 ms answered %q, want exactly com.example.app", got)
	}
}

// W5: end to end through handleLogin. A LOGOUT held past logoutWaitFirst answers its WAIT lines, then exactly OK.
func TestLogoutWait_W5_ThroughHandleLogin(t *testing.T) {
	const first = 20 * time.Second
	logoutWaitVars(t, time.Hour, first, 7*time.Second)
	h := logoutWaitStepped(t)
	sessionMu.Lock()
	released := false
	release := func() {
		if !released {
			released = true
			sessionMu.Unlock()
		}
	}
	c := driveLoginAsync(t, t.TempDir(), "LOGOUT\n")
	var got string
	replied := false
	t.Cleanup(func() {
		release()
		if !replied {
			select {
			case <-c:
			case <-time.After(logoutWaitHang):
				t.Error("no reply after sessionMu was released")
			}
		}
	})
	h.began(t)
	h.step(t, first)
	h.step(t, 45*time.Second)
	release()
	select {
	case got = <-c:
		replied = true
	case <-time.After(logoutWaitHang):
		t.Fatal("no reply after sessionMu was released")
	}
	if want := "WAIT 20\nWAIT 45\nOK"; got != want {
		t.Fatalf("LOGOUT answered %q, want %q (Q116)", got, want)
	}
}

// W6: outside a stepped test the seams are the real ticker and the real clock.
func TestLogoutWait_W6_SeamsDefaultToTheRealTickerAndClock(t *testing.T) {
	tc, stop := logoutWaitTicker(time.Millisecond)
	defer stop()
	select {
	case <-tc:
	case <-time.After(logoutWaitHang):
		t.Fatal("logoutWaitTicker's default never ticks")
	}
	before := time.Now()
	got := logoutWaitNow()
	if after := time.Now(); got.Before(before) || got.After(after) {
		t.Fatalf("logoutWaitNow's default read %v, outside the real clock's %v to %v", got, before, after)
	}
}
