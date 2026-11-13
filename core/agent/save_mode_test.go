package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261201-03: the profile's save mode (save_mode.go). Package-global state, so nothing here is parallel.

// saveModeState clears the mode and the gate's network report for one test and puts them back after it.
func saveModeState(t *testing.T) {
	t.Helper()
	pendingReapMu.Lock()
	pv, pu, pa := saveModeValue, saveNetUnmetered, saveNetAt
	saveModeValue, saveNetUnmetered, saveNetAt = "", false, time.Time{}
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		saveModeValue, saveNetUnmetered, saveNetAt = pv, pu, pa
		pendingReapMu.Unlock()
	})
}

// saveModeSession records a session for uid under a profile name no other test uses, and returns its dest.
func saveModeSession(t *testing.T, name, uid string) string {
	t.Helper()
	dest := t.TempDir()
	if err := markRoamSession(dest, name, "pw-"+name, uid, ""); err != nil {
		t.Fatal(err)
	}
	return dest
}

func saveModePlant(t *testing.T, dest, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, saveModeOut), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func saveModeMem(t *testing.T) string {
	t.Helper()
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return saveModeValue
}

// The one decision: three modes against every state of the gate's report. Times are injected.
func TestSaveModeDecisionTable(t *testing.T) {
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	nets := []struct {
		name      string
		unmetered bool
		at        time.Time
		wifi      string // the reason Only on Wi-Fi gives on this network
	}{
		{"fresh unmetered", true, now.Add(-30 * time.Second), ""},
		{"exactly 3 minutes old", true, now.Add(-saveNetFresh), ""},
		{"stale unmetered", true, now.Add(-saveNetFresh - time.Second), saveHoldWifi},
		{"never reported", true, time.Time{}, saveHoldWifi},
		{"fresh metered", false, now.Add(-30 * time.Second), saveHoldWifi},
		{"from the future (a clock moved back)", true, now.Add(time.Second), saveHoldWifi},
	}
	for _, n := range nets {
		for _, m := range []struct{ mode, want string }{
			{saveModeAlways, ""},
			{"", ""},
			{saveModeOff, saveHoldOff},
			{saveModeWifi, n.wifi},
		} {
			if got := saveModeDeferReason(m.mode, n.unmetered, n.at, now); got != m.want {
				t.Errorf("mode %q on %s: reason %q, want %q", m.mode, n.name, got, m.want)
			}
		}
	}
}

// The mode reaches the periodic decision, after the shared guards and before the sweep hold.
func TestSaveModePeriodicDeferReason(t *testing.T) {
	sweepState(t)
	saveModeState(t)
	now := time.Now()
	set := func(mode string, unmetered bool, at time.Time) string {
		pendingReapMu.Lock()
		defer pendingReapMu.Unlock()
		saveModeValue, saveNetUnmetered, saveNetAt = mode, unmetered, at
		return periodicSealDeferReason(now, false)
	}
	if got := set(saveModeOff, true, now); got != saveHoldOff {
		t.Errorf("Off: reason %q, want %q", got, saveHoldOff)
	}
	if got := set(saveModeWifi, false, now); got != saveHoldWifi {
		t.Errorf("Only on Wi-Fi on a metered network: reason %q, want %q", got, saveHoldWifi)
	}
	if got := set(saveModeWifi, true, now); got != "" {
		t.Errorf("Only on Wi-Fi on an unmetered network: reason %q, want none", got)
	}
	if got := set(saveModeAlways, false, time.Time{}); got != "" {
		t.Errorf("Always: reason %q, want none", got)
	}
	if got := set("", false, time.Time{}); got != "" {
		t.Errorf("an unknown mode: reason %q, want none", got)
	}
	pendingReapMu.Lock()
	saveModeValue = saveModeOff
	got := periodicSealDeferReason(now, true)
	autoSweepUntil, autoSweepBegan = now.Add(time.Hour), now
	sweep := periodicSealDeferReason(now, false)
	pendingReapMu.Unlock()
	if got != "seal-in-flight" {
		t.Errorf("a seal in flight in Off mode: reason %q, want the guard first", got)
	}
	if sweep != saveHoldOff {
		t.Errorf("a live sweep in Off mode: reason %q, want the mode before the sweep hold", sweep)
	}
}

// Without the chooser half there is no save-mode.out: the mode is Always and the periodic saves run as before.
func TestSaveModeNoFileIsAlways(t *testing.T) {
	sweepState(t)
	saveModeState(t)
	dest := saveModeSession(t, "savemodenofile", "12")
	if got := saveModeFor(dest, "12"); got != saveModeAlways {
		t.Fatalf("no file: saveModeFor answered %q, want always", got)
	}
	refreshSaveMode(dest, "12")
	pendingReapMu.Lock()
	got := periodicSealDeferReason(time.Now(), false)
	pendingReapMu.Unlock()
	if got != "" {
		t.Errorf("no file: periodic reason %q, want none", got)
	}
}

func TestSaveModeForKeyedAndDefaulting(t *testing.T) {
	dest := t.TempDir()
	saveModePlant(t, dest, "12 off\n")
	if got := saveModeFor(dest, "12"); got != saveModeOff {
		t.Errorf("the session's own value: %q, want off", got)
	}
	if got := saveModeFor(dest, "13"); got != saveModeAlways {
		t.Errorf("another session's value was answered: %q", got)
	}
	if got := saveModeFor(dest, ""); got != saveModeAlways {
		t.Errorf("an empty uid: %q, want always", got)
	}
	for _, body := range []string{"12 junk\n", "12\n", "12 wifi off\n", ""} {
		saveModePlant(t, dest, body)
		if got := saveModeFor(dest, "12"); got != saveModeAlways {
			t.Errorf("%q: answered %q, want always", body, got)
		}
	}
}

// The manual path never sees the mode: syncDeferReason answers alike in every mode, and neither it nor the sign-out,
// Back up now or the cold lock names the mode in source.
func TestSaveModeManualPathNeverHeld(t *testing.T) {
	saveModeState(t)
	now := time.Now()
	for _, m := range []string{"", saveModeAlways, saveModeWifi, saveModeOff} {
		pendingReapMu.Lock()
		saveModeValue, saveNetUnmetered, saveNetAt = m, false, time.Time{}
		pendingReapMu.Unlock()
		if got := syncDeferReason(now, false, time.Time{}, time.Time{}, 0); got != "" {
			t.Errorf("mode %q: syncDeferReason answered %q, want none", m, got)
		}
		if got := syncDeferReason(now, true, time.Time{}, time.Time{}, 0); got != "seal-in-flight" {
			t.Errorf("mode %q: syncDeferReason answered %q, want seal-in-flight", m, got)
		}
	}
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, fn := range []string{"handleBackup", "backupBusyReason", "handleLogout", "handleLogoff", "handleColdLock", "syncDeferReason"} {
		body := strings.Join(stripComments(funcBody(t, src, fn)), "\n")
		for _, w := range []string{"saveModeDeferReason", "saveModeValue", "saveHoldOff", "saveHoldWifi"} {
			if strings.Contains(body, w) {
				t.Errorf("%s names %s: the save mode governs the periodic saves only", fn, w)
			}
		}
	}
}

func TestSaveModeSetRefusesAnotherSession(t *testing.T) {
	saveModeState(t)
	dest := saveModeSession(t, "savemoderefuse", "12")
	if got := evictConn(t, dest, "SET-SAVE-MODE\nwifi\n12\n"); got != "OK" {
		t.Fatalf("control: the session's own SET replied %q", got)
	}
	for _, req := range []string{"SET-SAVE-MODE\noff\n11\n", "SET-SAVE-MODE\noff\n\n"} {
		if got := evictConn(t, dest, req); got != "ERR" {
			t.Errorf("%q replied %q, want ERR", req, got)
		}
	}
	if m := saveModeMem(t); m != saveModeWifi || saveModeFor(dest, "12") != saveModeWifi {
		t.Errorf("a refused SET changed the mode: memory %q, file %q, want wifi", m, saveModeFor(dest, "12"))
	}
	if got := evictConn(t, t.TempDir(), "SET-SAVE-MODE\noff\n12\n"); got != "ERR" {
		t.Errorf("SET with no session replied %q, want ERR", got)
	}
}

// A change on the Profile screen applies at once, and an unknown value is recorded as Always.
func TestSaveModeUnknownValueIsAlways(t *testing.T) {
	saveModeState(t)
	dest := saveModeSession(t, "savemodeunknown", "12")
	if got := evictConn(t, dest, "SET-SAVE-MODE\noff\n12\n"); got != "OK" || saveModeMem(t) != saveModeOff {
		t.Fatalf("SET off replied %q, memory %q", got, saveModeMem(t))
	}
	if got := evictConn(t, dest, "SET-SAVE-MODE\nnever\n12\n"); got != "OK" {
		t.Fatalf("SET of an unknown value replied %q", got)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, saveModeOut)); string(b) != "12 always\n" {
		t.Errorf("the file reads %q, want always", b)
	}
	if m := saveModeMem(t); m != saveModeAlways {
		t.Errorf("memory reads %q, want always", m)
	}
}

// SET-SAVE-MODE never waits on sessionMu: a materialise holds that for minutes.
func TestSaveModeSetNeverWaitsOnTheSession(t *testing.T) {
	saveModeState(t)
	dest := saveModeSession(t, "savemodenowait", "12")
	sessionMu.Lock()
	defer sessionMu.Unlock()
	done := make(chan string, 1)
	go func() { done <- evictConn(t, dest, "SET-SAVE-MODE\noff\n12\n") }()
	select {
	case got := <-done:
		if got != "OK" {
			t.Fatalf("SET-SAVE-MODE replied %q", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("SET-SAVE-MODE waited on the session lock a materialise holds")
	}
}

// The two writers are ordered: a SET that lands between syncLoop's read and its apply is never reverted.
func TestSaveModeSetAndRereadAreOrdered(t *testing.T) {
	saveModeState(t)
	dest := saveModeSession(t, "savemodeorder", "12")
	old := saveModeRefreshHook
	saveModeRefreshHook = func() { time.Sleep(2 * time.Millisecond) } // widen the read->apply gap
	t.Cleanup(func() { saveModeRefreshHook = old })
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
				refreshSaveMode(dest, "12")
			}
		}
	}()
	vals := []string{saveModeWifi, saveModeOff, saveModeAlways}
	reverted := 0
	for i := 0; i < 40; i++ {
		v := vals[i%len(vals)]
		if r := handleSetSaveMode(dest, v, "12"); r != "OK" {
			t.Fatalf("SET %s replied %s", v, r)
		}
		for end := time.Now().Add(6 * time.Millisecond); time.Now().Before(end); {
			if saveModeMem(t) != v {
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
}

// SET-SAVE-MODE publishes by temp + rename, so a lock-free GET never reads a truncated file, and a failed publish
// leaves no temp file behind.
func TestSaveModeSetWritesByRename(t *testing.T) {
	dest := t.TempDir()
	if err := setSaveMode(dest, "12", saveModeWifi); err != nil {
		t.Fatal(err)
	}
	ents, err := os.ReadDir(dest)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 1 || ents[0].Name() != saveModeOut {
		t.Fatalf("the state dir holds %v, want only %s", ents, saveModeOut)
	}
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, saveModeOut), 0o700); err != nil { // the rename target is a directory: it fails
		t.Fatal(err)
	}
	if err := setSaveMode(dir, "12", saveModeWifi); err == nil {
		t.Fatal("a failed publish reported success")
	}
	if _, err := os.Stat(filepath.Join(dir, saveModeOut+".tmp")); err == nil {
		t.Error("a failed publish left its temp file")
	}
}

// A session boundary forgets the old profile's mode and the network report.
func TestSaveModeResetForgets(t *testing.T) {
	odState(t)
	saveModeState(t)
	pendingReapMu.Lock()
	saveModeValue, saveNetUnmetered, saveNetAt = saveModeOff, true, time.Now()
	pendingReapMu.Unlock()
	resetOdWindow()
	pendingReapMu.Lock()
	v, u, at := saveModeValue, saveNetUnmetered, saveNetAt
	pendingReapMu.Unlock()
	if v != "" || u || !at.IsZero() {
		t.Errorf("after a session boundary: mode %q, unmetered %v, at %v, want all cleared", v, u, at)
	}
}

// The report's age is wall time: a monotonic reading would stop during suspend and keep an old report fresh.
func TestSaveModeNetTimeIsWallClock(t *testing.T) {
	saveModeState(t)
	recordSaveNet(true)
	pendingReapMu.Lock()
	at := saveNetAt
	pendingReapMu.Unlock()
	if at.IsZero() || at != at.Round(0) {
		t.Errorf("saveNetAt is unset or carries a monotonic reading: %v", at)
	}
}

// The gate's verbs answer OK and set the report; METERED after UNMETERED clears it.
func TestSaveModeNetVerbs(t *testing.T) {
	gatePeer(t, 10123)
	saveModeState(t)
	dest := t.TempDir()
	for _, c := range []struct {
		req  string
		want bool
	}{{"SAVE-NET-UNMETERED\n", true}, {"SAVE-NET-METERED\n", false}} {
		if got := driveLogin(t, dest, c.req); got != "OK" {
			t.Fatalf("%q replied %q", c.req, got)
		}
		pendingReapMu.Lock()
		u, at := saveNetUnmetered, saveNetAt
		pendingReapMu.Unlock()
		if u != c.want || at.IsZero() {
			t.Errorf("%q: unmetered %v at %v, want %v", c.req, u, at, c.want)
		}
	}
}

func TestSaveModeHoldLogStep(t *testing.T) {
	const (
		heldOff  = "[logind] periodic saves held: save mode off (NWP-20261201-03)"
		heldWifi = "[logind] periodic saves held: save mode wifi (NWP-20261201-03)"
		resume   = "[logind] periodic saves resume: save mode (NWP-20261201-03)"
	)
	for _, c := range []struct{ prev, reason, next, line string }{
		{"", saveHoldOff, saveHoldOff, heldOff},
		{"", saveHoldWifi, saveHoldWifi, heldWifi},
		{saveHoldOff, saveHoldOff, saveHoldOff, ""},
		{saveHoldOff, saveHoldWifi, saveHoldWifi, heldWifi},
		{saveHoldWifi, "", "", resume},
		{"", "", "", ""},
		{saveHoldOff, "seal-in-flight", saveHoldOff, ""},
		{"", "seal-in-flight", "", ""},
	} {
		next, line := saveModeHoldStep(c.prev, c.reason)
		if next != c.next || line != c.line {
			t.Errorf("step(%q, %q) = (%q, %q), want (%q, %q)", c.prev, c.reason, next, line, c.next, c.line)
		}
	}
}

// saveModeLoop runs two cycles of the real syncLoop for a session of the given name as user 12, with save-mode.out
// planted as "12 off" and no SET: a fixed reply is the worker's, so a cycle that was not held runs fast and shows.
func saveModeLoop(t *testing.T, name string) (*abInit, string) {
	t.Helper()
	lateWorkFresh(t)
	sweepState(t)
	saveModeState(t)
	sessionState(t)
	useTempUsersDir(t)
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "SKIP-REAPING"}, {lane: laneRW, text: "SKIP-REAPING"}})
	if err := os.MkdirAll(filepath.Join(androidUsersDir, "12"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := markRoamSession(f.dest, name, "pw-"+name, "12", ""); err != nil {
		t.Fatal(err)
	}
	saveModePlant(t, f.dest, "12 off\n")
	// With a gateway set and the rent gate closed, maybePayRent logs its one skip line and spends nothing.
	t.Setenv("GATEWAY_URL", "http://127.0.0.1:1")
	rentMu.Lock()
	rentExitHold = true
	rentMu.Unlock()
	t.Cleanup(rgReset)
	old := syncLoopSleep
	t.Cleanup(func() { syncLoopSleep = old })
	var sleeps atomic.Int32
	syncLoopSleep = func(time.Duration) {
		if sleeps.Add(1) > 2 {
			runtime.Goexit()
		}
	}
	log := captureStderr(t, func() {
		done := make(chan struct{})
		go func() { defer close(done); syncLoop(f.dest) }()
		select {
		case <-done:
		case <-time.After(60 * time.Second):
			t.Fatal("two syncLoop cycles did not end within 60 s")
		}
	})
	return f, log
}

const saveModeRentSkip = "pay-rent %q: skipped -- an unsaved sign-out"

// Two cycles held in Off: the refresh is wired, sealDeferCount does not move, the hold logs once, no worker starts,
// and the cycle's upkeep still runs -- the store lease, and the revival of a dead mediad.
func TestSaveModeSyncLoopHold(t *testing.T) {
	before := sealDeferCount.Load()
	f, log := saveModeLoop(t, "savemodeheld")
	if got := sealDeferCount.Load(); got != before {
		t.Errorf("sealDeferCount moved from %d to %d: a save-mode hold is not a fault", before, got)
	}
	if n := strings.Count(log, "[logind] periodic saves held: save mode off (NWP-20261201-03)"); n != 1 {
		t.Errorf("the hold line appears %d time(s), want 1:\n%s", n, log)
	}
	if strings.Contains(log, "periodic seal deferred") {
		t.Errorf("a save-mode hold was logged as a deferred seal:\n%s", log)
	}
	if starts := f.snapshot(); len(starts) != 0 {
		t.Errorf("a held cycle started a worker: %+v", starts)
	}
	skip := strings.Replace(saveModeRentSkip, "%q", `"savemodeheld"`, 1)
	if n := strings.Count(log, skip); n != 2 {
		t.Errorf("maybePayRent ran %d time(s) in two held cycles, want 2 (the lease must keep renewing):\n%s", n, log)
	}
	if _, err := os.Stat(filepath.Join(f.dest, "mediad.req")); err != nil {
		t.Errorf("a held cycle did not kick mediad: %v", err)
	}
}

// A DELETE or a rotation in flight has always deferred the upkeep; a hold must not bring it into that window.
func TestSaveModeSyncLoopHoldStandsAsideForADelete(t *testing.T) {
	pendingReapMu.Lock()
	deleteInFlight = true
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		deleteInFlight = false
		pendingReapMu.Unlock()
	})
	f, log := saveModeLoop(t, "savemodedelete")
	if !strings.Contains(log, "[logind] periodic saves held: save mode off (NWP-20261201-03)") {
		t.Fatalf("fixture: the cycle was not held:\n%s", log)
	}
	skip := strings.Replace(saveModeRentSkip, "%q", `"savemodedelete"`, 1)
	if strings.Contains(log, skip) {
		t.Errorf("a held cycle reached maybePayRent during a DELETE:\n%s", log)
	}
	if _, err := os.Stat(filepath.Join(f.dest, "mediad.req")); err == nil {
		t.Error("a held cycle kicked mediad during a DELETE")
	}
}
