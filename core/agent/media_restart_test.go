package main

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// NWP-20261202-20: MEDIA-RESTART, a health notice's Fix for a session MediaProvider that stopped answering. Every test
// drives the real handleLogin (dsSetup / dsVerb), has its own profile name, and restores every hook it replaces.

const mrUID = "13"

const mrPeer = 13*100000 + 10123

// mrCall is one call of the worker hook.
type mrCall struct{ dest, name, uid string }

// mrRec records the worker hook's calls.
type mrRec struct {
	mu    sync.Mutex
	calls []mrCall
}

func (r *mrRec) add(c mrCall) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, c)
}

func (r *mrRec) get() []mrCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]mrCall(nil), r.calls...)
}

// mrSetup gives the test a live session for uid and the peer, a recording worker, a no-op sleep and a clear pending
// flag; it restores all three hooks and the flag afterwards.
func mrSetup(t *testing.T, name, uid string, peer int) (string, *mrRec) {
	t.Helper()
	dest := dsSetup(t, name, uid, peer)
	prevWorker, prevSleep := mediaRestartWorker, mediaRestartSleep
	mediaRestartPending.Store(false)
	t.Cleanup(func() {
		mrWaitIdle(t)
		mediaRestartWorker, mediaRestartSleep = prevWorker, prevSleep
		mediaRestartPending.Store(false)
	})
	rec := &mrRec{}
	mediaRestartWorker = func(dest, name, uid string) string {
		rec.add(mrCall{dest, name, uid})
		return "OK\n"
	}
	mediaRestartSleep = func() {}
	if anySealRunning(time.Now()) {
		t.Fatal("a seal is marked running before the test starts; another test leaked it")
	}
	return dest, rec
}

// mrWaitIdle waits for a queued restart to finish. The bound is a hang guard, never a timing claim.
func mrWaitIdle(t *testing.T) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); mediaRestartPending.Load(); {
		if time.Now().After(end) {
			t.Fatal("the queued media restart did not finish within 5 s")
		}
		time.Sleep(time.Millisecond)
	}
}

// mrSetSeal sets sealInFlight under pendingReapMu and restores the earlier value when the test ends.
func mrSetSeal(t *testing.T, v bool) {
	t.Helper()
	pendingReapMu.Lock()
	prev := sealInFlight
	sealInFlight = v
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealInFlight = prev
		pendingReapMu.Unlock()
	})
}

func mrClearSeal() {
	pendingReapMu.Lock()
	sealInFlight = false
	pendingReapMu.Unlock()
}

// TestMediaRestartDeniesUser0AndOtherUsers: only the live session's own Android user may queue the restart.
func TestMediaRestartDeniesUser0AndOtherUsers(t *testing.T) {
	for _, c := range []struct {
		what string
		peer int
	}{{"user 0 (the gate)", 10123}, {"another user", 14*100000 + 10123}, {"root", 0}, {"no peer", -1}} {
		t.Run(c.what, func(t *testing.T) {
			dest, rec := mrSetup(t, "mr-denied", mrUID, c.peer)
			if got := dsVerb(t, dest, "MEDIA-RESTART", ""); got != "DENIED\n" {
				t.Fatalf("%s: reply %q, want DENIED", c.what, got)
			}
			if mediaRestartPending.Load() {
				t.Fatalf("%s: a refused caller set the pending flag", c.what)
			}
			if n := len(rec.get()); n != 0 {
				t.Fatalf("%s: the worker ran %d time(s) for a refused caller", c.what, n)
			}
		})
	}
}

// TestMediaRestartNoSession: without a live session the verb answers ERR-NOSESSION and queues nothing.
func TestMediaRestartNoSession(t *testing.T) {
	dest, rec := mrSetup(t, "mr-nosess", "", mrPeer)
	if got := dsVerb(t, dest, "MEDIA-RESTART", ""); got != "ERR-NOSESSION\n" {
		t.Fatalf("reply %q, want ERR-NOSESSION", got)
	}
	if mediaRestartPending.Load() || len(rec.get()) != 0 {
		t.Fatal("no session, but a restart was queued")
	}
}

// TestMediaRestartQueuedBeforeWorker: QUEUED reaches the caller while the worker has not returned, and the worker
// gets the session's name and uid.
func TestMediaRestartQueuedBeforeWorker(t *testing.T) {
	dest, rec := mrSetup(t, "mr-queued", mrUID, mrPeer)
	entered, release := make(chan struct{}), make(chan struct{})
	mediaRestartWorker = func(d, name, uid string) string {
		rec.add(mrCall{d, name, uid})
		close(entered)
		<-release
		return "OK\n"
	}
	if got := dsVerb(t, dest, "MEDIA-RESTART", ""); got != "QUEUED\n" {
		close(release)
		t.Fatalf("reply %q, want QUEUED before the worker returns", got)
	}
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("the worker was never called")
	}
	close(release)
	mrWaitIdle(t)
	calls := rec.get()
	if len(calls) != 1 || calls[0] != (mrCall{dest, "mr-queued", mrUID}) {
		t.Fatalf("worker calls %+v, want one with the session's dest, name and uid", calls)
	}
}

// TestMediaRestartWaitsForASave: while a save runs the worker is not called; once it ends the worker runs once.
func TestMediaRestartWaitsForASave(t *testing.T) {
	dest, rec := mrSetup(t, "mr-seal", mrUID, mrPeer)
	mrSetSeal(t, true)
	sleeps := 0
	early := false
	mediaRestartSleep = func() {
		sleeps++
		if len(rec.get()) != 0 {
			early = true
		}
		if sleeps == 3 {
			mrClearSeal()
		}
	}
	if got := dsVerb(t, dest, "MEDIA-RESTART", ""); got != "QUEUED\n" {
		t.Fatalf("reply %q, want QUEUED", got)
	}
	mrWaitIdle(t)
	if early {
		t.Fatal("the worker ran while a save was still running")
	}
	if sleeps != 3 {
		t.Fatalf("slept %d time(s), want 3 (the save ended on the 3rd)", sleeps)
	}
	if n := len(rec.get()); n != 1 {
		t.Fatalf("the worker ran %d time(s) after the save, want 1", n)
	}
}

// TestMediaRestartTwoTapsOneDispatch: a tap while a restart is pending also answers QUEUED and starts nothing.
func TestMediaRestartTwoTapsOneDispatch(t *testing.T) {
	dest, rec := mrSetup(t, "mr-dedupe", mrUID, mrPeer)
	release := make(chan struct{})
	mediaRestartWorker = func(d, name, uid string) string {
		rec.add(mrCall{d, name, uid})
		<-release
		return "OK\n"
	}
	for i := 1; i <= 2; i++ {
		if got := dsVerb(t, dest, "MEDIA-RESTART", ""); got != "QUEUED\n" {
			close(release)
			t.Fatalf("tap %d: reply %q, want QUEUED", i, got)
		}
	}
	close(release)
	mrWaitIdle(t)
	if n := len(rec.get()); n != 1 {
		t.Fatalf("two taps dispatched %d restart(s), want 1", n)
	}
}

// TestMediaRestartSessionEndedDrops: a session that changed or ended while the restart waited gets no restart.
func TestMediaRestartSessionEndedDrops(t *testing.T) {
	for _, c := range []struct {
		what   string
		change func(t *testing.T, dest string)
	}{
		{"another session", func(t *testing.T, dest string) {
			if err := markRoamSession(dest, "mr-ended2", "pw-mr-ended2", "14", ""); err != nil {
				t.Error(err)
			}
		}},
		{"signed out", func(t *testing.T, dest string) {
			if err := os.Remove(filepath.Join(dest, roamSessionFile)); err != nil {
				t.Error(err)
			}
		}},
	} {
		t.Run(c.what, func(t *testing.T) {
			dest, rec := mrSetup(t, "mr-ended", mrUID, mrPeer)
			mrSetSeal(t, true)
			mediaRestartSleep = func() {
				c.change(t, dest)
				mrClearSeal()
			}
			if got := dsVerb(t, dest, "MEDIA-RESTART", ""); got != "QUEUED\n" {
				t.Fatalf("reply %q, want QUEUED", got)
			}
			mrWaitIdle(t)
			if n := len(rec.get()); n != 0 {
				t.Fatalf("%s: the worker ran %d time(s) for a session that is no longer live", c.what, n)
			}
		})
	}
}

// TestMediaRestartGivesUp: a save that never ends is waited out for a fixed count of intervals, then the restart is
// dropped and the flag cleared.
func TestMediaRestartGivesUp(t *testing.T) {
	if mediaRestartMaxWaits != 420 {
		t.Fatalf("mediaRestartMaxWaits = %d, want 420 ((65 min + 5 min) / 10 s)", mediaRestartMaxWaits)
	}
	dest, rec := mrSetup(t, "mr-giveup", mrUID, mrPeer)
	mrSetSeal(t, true)
	sleeps := 0
	mediaRestartSleep = func() { sleeps++ }
	if got := dsVerb(t, dest, "MEDIA-RESTART", ""); got != "QUEUED\n" {
		t.Fatalf("reply %q, want QUEUED", got)
	}
	mrWaitIdle(t)
	if sleeps != mediaRestartMaxWaits {
		t.Fatalf("slept %d time(s), want %d", sleeps, mediaRestartMaxWaits)
	}
	if n := len(rec.get()); n != 0 {
		t.Fatalf("the worker ran %d time(s) while the save never ended", n)
	}
}

// TestMediaRestartRidesTheReadWriteLane: the op takes the read-write lane with no slot cap, so a seal and the restart
// never overlap, and the verb itself does not wait on sessionMu.
func TestMediaRestartRidesTheReadWriteLane(t *testing.T) {
	if laneFor("mediarestart").svc != laneRW.svc {
		t.Errorf("laneFor(mediarestart) = %s, want the read-write lane %s", laneFor("mediarestart").svc, laneRW.svc)
	}
	if c := workerWaitCap("mediarestart"); c != 0 {
		t.Errorf("workerWaitCap(mediarestart) = %v, want 0 (never dropped behind a seal)", c)
	}
	if !concurrentSafeCmd("MEDIA-RESTART") {
		t.Error("MEDIA-RESTART waits on sessionMu; it only reads the marker and sets a flag")
	}
}
