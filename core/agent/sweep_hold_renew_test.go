package main

import (
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261204-05: with "until setup finishes" (sealHoldValue "run") an Auto sweep holds the periodic seal for as
// long as one of its steps is in flight, however long that step takes. A materialise's fetch and a RESTORE-ODDATA's
// odrestore renew the sweep's lease while their worker op runs (renewOdWhileSweep); a store Get does not, a reset
// session's late tick does not, a lapsed sweep is not revived, and a capped choice still lets one seal through.

// swhState is odState with the "run" choice and autoSweepLease restored after.
func swhState(t *testing.T) {
	t.Helper()
	odState(t)
	sl := autoSweepLease
	t.Cleanup(func() { autoSweepLease = sl })
	swhSetChoice("run")
}

func swhSetChoice(v string) {
	pendingReapMu.Lock()
	sealHoldValue = v
	pendingReapMu.Unlock()
}

// swhRestore runs RESTORE-ODDATA for pkg through the real dispatch in the background. The returned func waits for
// the handler and gives its reply.
func swhRestore(dest, pkg string) func() string {
	cli, srv := net.Pipe()
	go cli.Write([]byte("RESTORE-ODDATA\n" + pkg + "\n"))
	got := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		got <- strings.TrimSpace(string(b))
	}()
	done := make(chan struct{})
	go func() {
		handleLogin(srv, dest) // closes srv itself
		close(done)
	}()
	return func() string { <-done; s := <-got; cli.Close(); return s }
}

// swhSweepLive is what GET-SWEEP answers right now (a lock-free verb: it answers while a handler holds sessionMu).
func swhSweepLive(t *testing.T) bool {
	t.Helper()
	return strings.HasPrefix(evictConn(t, t.TempDir(), "GET-SWEEP\n"), "LIVE")
}

func swhSweepUntil() time.Time {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return autoSweepUntil
}

func swhStartSweep(t *testing.T) {
	t.Helper()
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 1 replied %q", got)
	}
}

// The field case: an app's data restore outlives both leases. Each renewal of the odrestore keeps the sweep and the
// package's lease live, so no periodic seal starts in the middle of the sweep. On main the restore was armed once and
// renewed nothing: both leases lapsed while it ran.
func TestSweepHoldOutlivesALongDataRestore(t *testing.T) {
	swhState(t)
	autoSweepLease, odInstallLease = 200*time.Millisecond, 200*time.Millisecond
	dest := odSession(t)
	startOdWorker(t, dest, 900*time.Millisecond, func(string) string { return "OK com.swh.a" })
	swhStartSweep(t)
	e := beginOdMaterialise("com.swh.a", time.Now())
	settleOdMaterialise("com.swh.a", e, odInstalling, time.Now())
	wait := swhRestore(dest, "com.swh.a")
	time.Sleep(600 * time.Millisecond)
	if r := periodicAt(time.Now()); r == "" {
		t.Error("a periodic seal may start in the middle of a 900ms data restore: no hold is live at 600ms")
	}
	if !swhSweepLive(t) {
		t.Error("the Auto sweep's lease lapsed while one of its data restores was still in flight")
	}
	if got := wait(); got != "OK com.swh.a" {
		t.Errorf("RESTORE-ODDATA replied %q", got)
	}
}

// A fetch longer than the sweep's lease: on main the sweep was renewed only at the MATERIALIZE-APP's start.
func TestSweepHoldOutlivesALongFetch(t *testing.T) {
	swhState(t)
	autoSweepLease = 200 * time.Millisecond
	dest := odSession(t)
	startOdWorker(t, dest, 900*time.Millisecond, func(string) string { return "ERR-FETCH" })
	swhStartSweep(t)
	wait := odMaterialize(dest, "com.swh.fetch", true)
	time.Sleep(600 * time.Millisecond)
	if !swhSweepLive(t) {
		t.Error("the Auto sweep's lease lapsed while one of its fetches was still in flight")
	}
	wait()
}

// The bound: after the last step the sweep lapses on its own (a dead chooser sends no AUTO-SWEEP 0), the restored
// package's lease ends at once, and a later step does not revive the lapsed sweep.
func TestSweepHoldLapsesAfterTheLastStep(t *testing.T) {
	swhState(t)
	autoSweepLease, odInstallLease = 200*time.Millisecond, 200*time.Millisecond
	dest := odSession(t)
	startOdWorker(t, dest, 300*time.Millisecond, func(string) string { return "OK" })
	swhStartSweep(t)
	e := beginOdMaterialise("com.swh.last", time.Now())
	settleOdMaterialise("com.swh.last", e, odInstalling, time.Now())
	if got := swhRestore(dest, "com.swh.last")(); got != "OK" {
		t.Fatalf("RESTORE-ODDATA replied %q", got)
	}
	if l := odLease("com.swh.last"); !l.IsZero() {
		t.Errorf("the restored package's lease is still live until %v", l)
	}
	deadline := time.Now().Add(autoSweepLease + odRenewEvery + 150*time.Millisecond)
	for swhSweepLive(t) {
		if time.Now().After(deadline) {
			t.Fatal("the sweep is still live past autoSweepLease plus one tick after its last step")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// The sweep has lapsed. A later step renews its own package's lease, never the sweep's.
	wait := swhRestore(dest, "com.swh.later")
	time.Sleep(200 * time.Millisecond)
	if swhSweepLive(t) {
		t.Error("a RESTORE-ODDATA revived a lapsed sweep")
	}
	wait()
}

// A renewal tick in flight when the odrestore returns cannot re-open the lease the restore ends: the renewal has
// EXITED before endOdLease. The hook holds every renewal between its tick and its extension.
func TestOdRestoreNoStrayRenewal(t *testing.T) {
	swhState(t)
	odRenewEvery = time.Millisecond
	odFetchLease = 5 * time.Second
	odRenewHook = func() { time.Sleep(40 * time.Millisecond) }
	dest := odSession(t)
	startOdWorker(t, dest, 100*time.Millisecond, func(string) string { return "OK com.swh.stray" })
	hits := 0
	for i := 0; i < 5; i++ {
		if got := evictConn(t, dest, "RESTORE-ODDATA\ncom.swh.stray\n"); got != "OK com.swh.stray" {
			t.Fatalf("RESTORE-ODDATA replied %q", got)
		}
		time.Sleep(80 * time.Millisecond) // past any renewal that was still in flight
		if !odLease("com.swh.stray").IsZero() {
			hits++
			endOdLease("com.swh.stray", time.Now())
		}
	}
	if hits != 0 {
		t.Errorf("a renewal re-opened a restored package's lease after the restore ended it, %d of 5 times", hits)
	}
}

// A store Get (FETCH-APP) is not a sweep app: its renewals keep its own lease, never the sweep's.
func TestStoreGetDoesNotRenewTheSweep(t *testing.T) {
	c := fahSetup(t, "swh-storeget", "org.example.swhget", "/held.apk", "OK")
	sl := autoSweepLease
	t.Cleanup(func() { autoSweepLease = sl })
	odRenewEvery, autoSweepLease = 20*time.Millisecond, 200*time.Millisecond // fahSetup's hour would never tick
	swhSetChoice("run")
	swhStartSweep(t)
	wait := c.run(true)
	fahWaitStarted(t, c.srv)
	time.Sleep(600 * time.Millisecond)
	if swhSweepLive(t) {
		t.Error("a store Get held past autoSweepLease kept the Auto sweep's lease live")
	}
	c.srv.releaseAll()
	wait()
}

// A renewal from the session before a reset must not extend the next session's sweep.
func TestSweepHoldStaleEpochDoesNotRenew(t *testing.T) {
	swhState(t)
	autoSweepLease, odRenewEvery = 200*time.Millisecond, 20*time.Millisecond
	e := odWindowEpochNow()
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		renewOdWhileSweep("com.swh.stale", e, stop)
	}()
	t.Cleanup(func() { close(stop); <-done })
	resetOdWindow()
	swhSetChoice("run")
	swhStartSweep(t)
	after := time.Now()
	time.Sleep(150 * time.Millisecond)
	if u := swhSweepUntil(); u.After(after.Add(autoSweepLease)) {
		t.Errorf("the old session's renewal extended the new sweep to %v, past its own start + autoSweepLease", u.Sub(after))
	}
}

// A capped choice keeps its cap: a renewal moves a lease's end, never the anchor, so a restore renewed past the
// maximum still lets one seal through.
func TestCappedChoiceStillLetsOneSealThrough(t *testing.T) {
	swhState(t)
	swhSetChoice("2")
	pendingReapMu.Lock()
	sealsHeldSince = time.Now().Add(-3 * time.Minute)
	pendingReapMu.Unlock()
	dest := odSession(t)
	startOdWorker(t, dest, 600*time.Millisecond, func(string) string { return "OK com.swh.cap" })
	wait := swhRestore(dest, "com.swh.cap")
	time.Sleep(300 * time.Millisecond)
	if r := periodicAt(time.Now()); r != "" {
		t.Errorf("a renewed restore held a seal past the 2-minute maximum: %q", r)
	}
	wait()
}
