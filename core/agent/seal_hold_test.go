package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261011-01: the profile's seal-hold choice (seal_hold.go) sets the one maximum the materialise window and
// the auto sweep are both read against.

func TestSealHoldGap(t *testing.T) {
	for _, c := range []struct {
		v    string
		want time.Duration
	}{
		{"2", 2 * time.Minute}, {"10", 10 * time.Minute}, {"30", 30 * time.Minute}, {"run", 0},
		{"", 30 * time.Minute}, {"45", 30 * time.Minute}, {"RUN", 30 * time.Minute}, {"2 10", 30 * time.Minute},
		{" 10\n", 10 * time.Minute},
	} {
		if got := sealHoldGap(c.v); got != c.want {
			t.Errorf("sealHoldGap(%q) = %s, want %s", c.v, got, c.want)
		}
	}
}

// odHoldAt opens a lease for pkg at now with the shared anchor `held` ago and no seal since, under choice v.
func odHoldAt(t *testing.T, v string, held time.Duration) time.Time {
	t.Helper()
	now := time.Now()
	pendingReapMu.Lock()
	applySealHoldLocked(v)
	pendingReapMu.Unlock()
	beginOdMaterialise("com.hold", now)
	pendingReapMu.Lock()
	sealsHeldSince = now.Add(-held)
	pendingReapMu.Unlock()
	return now
}

// Each option bounds a materialise hold at its own maximum; "run" has none, and ends only when the leases end.
func TestSealHoldBoundsTheWindowPerOption(t *testing.T) {
	for _, c := range []struct {
		v   string
		gap time.Duration
	}{{"2", 2 * time.Minute}, {"10", 10 * time.Minute}, {"30", 30 * time.Minute}, {"", 30 * time.Minute}} {
		odState(t)
		odFetchLease = time.Hour
		odHoldAt(t, c.v, c.gap-5*time.Second)
		if r := periodicNow(t); r != "materialise" {
			t.Errorf("choice %q: %s into a hold the seal reads %q, want materialise", c.v, c.gap-5*time.Second, r)
		}
		resetOdWindow()
		odHoldAt(t, c.v, c.gap+5*time.Second)
		if r := periodicNow(t); r != "" {
			t.Errorf("choice %q: %s into a hold the seal still defers (%q), want it let through", c.v, c.gap+5*time.Second, r)
		}
	}
	odState(t)
	odFetchLease = time.Hour
	odHoldAt(t, "run", 10*time.Hour)
	if r := periodicNow(t); r != "materialise" {
		t.Fatalf(`choice "run": ten hours into a hold the seal reads %q, want materialise -- no time cap`, r)
	}
	endOdLease("com.hold", time.Now())
	if r := periodicNow(t); r != "" {
		t.Fatalf(`choice "run": with no lease live the seal still defers (%q) -- the hold must end with the leases`, r)
	}
}

// The same choice governs the auto sweep: both are materialisation.
func TestSealHoldBoundsTheSweepPerOption(t *testing.T) {
	for _, c := range []struct {
		v   string
		gap time.Duration
	}{{"2", 2 * time.Minute}, {"10", 10 * time.Minute}, {"30", 30 * time.Minute}, {"", 30 * time.Minute}} {
		odState(t)
		pendingReapMu.Lock()
		applySealHoldLocked(c.v)
		pendingReapMu.Unlock()
		now := time.Now()
		setSweep(now.Add(-c.gap+5*time.Second), now.Add(time.Hour), 1)
		if r := periodicNow(t); r != "auto-sweep" {
			t.Errorf("choice %q: a sweep %s old reads %q, want auto-sweep", c.v, c.gap-5*time.Second, r)
		}
		setSweep(now.Add(-c.gap-5*time.Second), now.Add(time.Hour), 1)
		if r := periodicNow(t); r != "" {
			t.Errorf("choice %q: a sweep %s old still defers (%q)", c.v, c.gap+5*time.Second, r)
		}
	}
	odState(t)
	pendingReapMu.Lock()
	applySealHoldLocked("run")
	pendingReapMu.Unlock()
	now := time.Now()
	setSweep(now.Add(-10*time.Hour), now.Add(time.Minute), 1)
	if r := periodicNow(t); r != "auto-sweep" {
		t.Fatalf(`choice "run": a ten-hour sweep reads %q, want auto-sweep`, r)
	}
	setSweep(now.Add(-10*time.Hour), now.Add(-time.Second), 1) // its lease lapsed
	if r := periodicNow(t); r != "" {
		t.Fatalf(`choice "run": a lapsed sweep still defers (%q)`, r)
	}
}

// The state file answers only its own session, and anything but the four choices reads as no choice (the default).
func TestSealHoldForIsKeyedAndDefaults(t *testing.T) {
	dest := t.TempDir()
	if v := sealHoldFor(dest, "12"); v != "" {
		t.Errorf("no file: %q, want none (the default)", v)
	}
	if err := setSealHold(dest, "12", "10"); err != nil {
		t.Fatal(err)
	}
	if v := sealHoldFor(dest, "12"); v != "10" {
		t.Errorf("own session: %q, want 10", v)
	}
	if v := sealHoldFor(dest, "13"); v != "" {
		t.Errorf("another session read %q -- a value must never cross sessions", v)
	}
	setSealHold(dest, "12", "45")
	if b, _ := os.ReadFile(filepath.Join(dest, sealHoldOut)); strings.TrimSpace(string(b)) != "12 30" {
		t.Errorf("an unknown value was stored as %q, want the default '12 30'", b)
	}
	os.WriteFile(filepath.Join(dest, sealHoldOut), []byte("12 forever\n"), 0o600)
	if v := sealHoldFor(dest, "12"); v != "" {
		t.Errorf("an unknown stored value read as %q, want none (the default)", v)
	}
}

// A change made on the Profile screen applies to the very next decision: SET-SEAL-HOLD records it and applies it.
func TestSealHoldLiveChangeAppliesAtOnce(t *testing.T) {
	odState(t)
	odFetchLease = time.Hour
	dest := odSession(t)
	odHoldAt(t, "", 15*time.Minute) // the default: 15 minutes in, still held
	if r := periodicNow(t); r != "materialise" {
		t.Fatalf("control: under the default a 15-minute hold reads %q", r)
	}
	if got := evictConn(t, dest, "SET-SEAL-HOLD\n10\n12\n"); got != "OK" {
		t.Fatalf("SET-SEAL-HOLD replied %q", got)
	}
	if r := periodicNow(t); r != "" {
		t.Fatalf("after choosing 10 minutes a 15-minute hold still defers (%q): the change did not apply", r)
	}
	if v := sealHoldFor(dest, "12"); v != "10" {
		t.Errorf("the choice was not recorded for the session: %q", v)
	}
	if got := evictConn(t, dest, "SET-SEAL-HOLD\nrun\n12\n"); got != "OK" {
		t.Fatalf("SET-SEAL-HOLD replied %q", got)
	}
	if r := periodicNow(t); r != "materialise" {
		t.Fatalf(`after choosing "run" the hold reads %q, want materialise`, r)
	}
	if got := evictConn(t, t.TempDir(), "SET-SEAL-HOLD\n2\n12\n"); got != "ERR" {
		t.Errorf("SET-SEAL-HOLD with no session replied %q, want ERR", got)
	}
}

// syncLoop re-reads the session's choice before every periodic decision -- that is how a value roamd surfaced at
// sign-in, or one a lost SET-SEAL-HOLD left only in the file, takes effect. Pinned as code (the loop sleeps for a
// whole interval before its first decision, so no test can drive it).
func TestSealHoldSyncLoopRereadsTheChoice(t *testing.T) {
	code := odCode(t, "main.go", "syncLoop")
	blk := "holdChanged, holdText := refreshSealHold(dest, uid)\nvar reason, odCap string\nfunc() {\npendingReapMu.Lock()\ndefer pendingReapMu.Unlock()\ninFlEff := sealInFlight"
	if !strings.Contains(code, blk) {
		t.Fatalf("syncLoop no longer re-reads the seal-hold choice right before its decision:\n%s", blk)
	}
	if i, j := strings.Index(code, blk), strings.Index(code, "reason = periodicSealDeferReason(time.Now(), inFlEff)"); j < i {
		t.Fatal("the choice is read after the decision it should govern")
	}
}

// F4 (round 4): a cycle a hold deferred wakes when the maximum lets a seal through, not a whole interval later.
// Pinned as code -- the loop sleeps before its first decision -- with the arithmetic in holdWakeAfter tested below.
func TestSealHoldSyncLoopWakesAtTheMaximum(t *testing.T) {
	code := odCode(t, "main.go", "syncLoop")
	for _, blk := range []string{
		"var holdWake time.Duration\nfor {",
		"wait := time.Duration(syncIntervalGet()) * time.Second\nif holdWake > 0 && holdWake < wait {\nwait = holdWake\n}\nholdWake = 0\nsyncLoopSleep(wait)",
		"holdWake = holdWakeLocked(time.Now(), reason, time.Duration(syncIntervalGet())*time.Second)\n}()",
	} {
		if !strings.Contains(code, blk) {
			t.Errorf("syncLoop no longer holds the block\n%s", blk)
		}
	}
}

func TestSealHoldWakeAfter(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	iv := 10 * time.Minute
	for _, c := range []struct {
		name string
		ref  time.Time
		gap  time.Duration
		want time.Duration
	}{
		{"no maximum", now.Add(-time.Minute), 0, iv},
		{"no reference", time.Time{}, 2 * time.Minute, iv},
		{"the maximum ends before the interval", now.Add(-time.Minute), 2 * time.Minute, time.Minute + time.Second},
		{"the maximum ends after the interval", now, 30 * time.Minute, iv},
		{"already past the maximum", now.Add(-time.Hour), 2 * time.Minute, time.Second},
	} {
		if got := holdWakeAfter(now, c.ref, c.gap, iv); got != c.want {
			t.Errorf("%s: holdWakeAfter = %s, want %s", c.name, got, c.want)
		}
	}
}

// holdWakeLocked reads the maximum and the reference of the hold that deferred the cycle, and only those.
func TestSealHoldWakeFollowsTheDeferringHold(t *testing.T) {
	odState(t)
	iv := 10 * time.Minute
	now := time.Now()
	pendingReapMu.Lock()
	applySealHoldLocked("2")
	sealsHeldSince = now.Add(-time.Minute)
	autoSweepBegan, autoSweepUntil = now.Add(-time.Minute), now.Add(time.Hour)
	mat := holdWakeLocked(now, "materialise", iv)
	swp := holdWakeLocked(now, "auto-sweep", iv)
	other := holdWakeLocked(now, "login", iv)
	pendingReapMu.Unlock()
	if mat != time.Minute+time.Second || swp != time.Minute+time.Second {
		t.Errorf("a 2-minute hold one minute in wakes after %s (materialise) / %s (sweep), want 1m1s", mat, swp)
	}
	if other != iv {
		t.Errorf("a cycle deferred for another reason wakes after %s, want the interval", other)
	}
	// A tap anchored the hold two minutes ago; a sweep began 30 s ago and continues it. The sweep's wake counts
	// from the shared anchor, so the 2-minute maximum is already reached.
	pendingReapMu.Lock()
	sealsHeldSince = now.Add(-2 * time.Minute)
	autoSweepBegan = now.Add(-30 * time.Second)
	cont := holdWakeLocked(now, "auto-sweep", iv)
	pendingReapMu.Unlock()
	if cont != time.Second {
		t.Errorf("a sweep continuing a tap's 2-minute-old hold wakes after %s, want 1s (it counts from the sweep's own start?)", cont)
	}
}

// Round 5: a SET is applied only to the session of the user that sent it. A late one from an ended session --
// or one with no user at all -- is refused, and the live choice and file are untouched.
func TestSealHoldSetRefusesAnotherSession(t *testing.T) {
	odState(t)
	dest := odSession(t) // user 12
	if got := evictConn(t, dest, "SET-SEAL-HOLD\n10\n12\n"); got != "OK" {
		t.Fatalf("control: the session's own SET replied %q", got)
	}
	for _, req := range []string{"SET-SEAL-HOLD\nrun\n11\n", "SET-SEAL-HOLD\nrun\n\n"} {
		if got := evictConn(t, dest, req); got != "ERR" {
			t.Errorf("%q replied %q, want ERR", req, got)
		}
	}
	pendingReapMu.Lock()
	mem := sealHoldValue
	pendingReapMu.Unlock()
	if mem != "10" || sealHoldFor(dest, "12") != "10" {
		t.Errorf("a refused SET changed the choice: memory %q, file %q, want 10", mem, sealHoldFor(dest, "12"))
	}
}

// Round 5: a session boundary forgets the old profile's choice, so nothing -- the sweep-start log included -- reports
// it for the next session; until the new session's is read, the default holds.
func TestSealHoldResetForgetsTheChoice(t *testing.T) {
	odState(t)
	pendingReapMu.Lock()
	applySealHoldLocked("2")
	pendingReapMu.Unlock()
	resetOdWindow()
	pendingReapMu.Lock()
	v, gap := sealHoldValue, holdCapLocked()
	pendingReapMu.Unlock()
	if v != "" || gap != 30*time.Minute {
		t.Errorf("after a session boundary the choice is %q (%s), want unset (30m)", v, gap)
	}
}

// F1 (round 4): SET-SEAL-HOLD never waits on sessionMu -- a materialise holds that for minutes.
func TestSealHoldSetNeverWaitsOnTheSession(t *testing.T) {
	odState(t)
	if !concurrentSafeCmd("SET-SEAL-HOLD") {
		t.Fatal("SET-SEAL-HOLD is serialised on sessionMu")
	}
	dest := odSession(t)
	sessionMu.Lock() // a materialise in progress
	defer sessionMu.Unlock()
	done := make(chan string, 1)
	go func() { done <- evictConn(t, dest, "SET-SEAL-HOLD\n10\n12\n") }()
	select {
	case got := <-done:
		if got != "OK" {
			t.Fatalf("SET-SEAL-HOLD replied %q", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("SET-SEAL-HOLD waited on the session lock a materialise holds")
	}
}

// F1/F7 (round 4): the two writers are ordered. A SET that lands while syncLoop's re-read is between its read and
// its apply is never reverted, and file and memory always end on the same, latest value.
func TestSealHoldSetAndRereadAreOrdered(t *testing.T) {
	odState(t)
	dest := odSession(t)
	old := sealHoldRefreshHook
	sealHoldRefreshHook = func() { time.Sleep(2 * time.Millisecond) } // widen the read->apply gap
	t.Cleanup(func() { sealHoldRefreshHook = old })
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
				refreshSealHold(dest, "12")
			}
		}
	}()
	vals := []string{"2", "10", "run", "30"}
	reverted := 0
	for i := 0; i < 40; i++ {
		v := vals[i%len(vals)]
		if r, _, _ := handleSetSealHold(dest, v, "12"); r != "OK" {
			t.Fatalf("SET %s replied %s", v, r)
		}
		// Watch memory for a while after the SET returned: a re-read that read the file BEFORE the SET and applies
		// AFTER it would flip it back, even if the next re-read then corrects it.
		for end := time.Now().Add(6 * time.Millisecond); time.Now().Before(end); {
			pendingReapMu.Lock()
			got := sealHoldValue
			pendingReapMu.Unlock()
			if got != v {
				reverted++
				break
			}
			time.Sleep(100 * time.Microsecond)
		}
	}
	close(stop)
	<-done
	if reverted != 0 {
		t.Errorf("a re-read reverted a SET %d of 40 times", reverted)
	}
	pendingReapMu.Lock()
	mem := sealHoldValue
	pendingReapMu.Unlock()
	if file := sealHoldFor(dest, "12"); file != mem {
		t.Errorf("file %q and memory %q disagree", file, mem)
	}
}
