package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261011-01: the materialise window is a lease per package, covers the whole tap, ends on every exit path,
// is bounded against one anchor shared with the auto sweep, and holds only the periodic seal (od_window.go).

// odState zeroes the window, its leases, the shared anchor and everything the periodic decision reads, and
// restores them after. The leases are shrunk so a handler test runs in about a second.
func odState(t *testing.T) {
	t.Helper()
	sweepState(t) // autoSweep*, odMaterializeUntil, odLeases, sealsHeldSince, loginSettleUntil, lastSealStartedAt
	pendingReapMu.Lock()
	pe := odWindowEpoch
	pendingReapMu.Unlock()
	fl, re, il, hk := odFetchLease, odRenewEvery, odInstallLease, odRenewHook
	odFetchLease, odRenewEvery, odInstallLease = 300*time.Millisecond, 50*time.Millisecond, 5*time.Second
	t.Cleanup(func() {
		pendingReapMu.Lock()
		odWindowEpoch = pe
		pendingReapMu.Unlock()
		odFetchLease, odRenewEvery, odInstallLease, odRenewHook = fl, re, il, hk
	})
}

// odLive reports whether the periodic seal sees a live materialise window right now.
func odLive() bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return !odWindowNow(time.Now()).IsZero()
}

func odUntil() time.Time {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return odMaterializeUntil
}

func odLease(pkg string) time.Time {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return odLeases[pkg]
}

func odAnchor() time.Time {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return sealsHeldSince
}

func odEpoch() uint64 {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return odWindowEpoch
}

// periodicAt is periodicSealDeferReason at an arbitrary instant (prunes lapsed leases first, as any lease
// operation would).
func periodicAt(now time.Time) string {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	odPruneLocked(now)
	return periodicSealDeferReason(now, false)
}

func setSweep(began, until time.Time, runs int) {
	pendingReapMu.Lock()
	autoSweepBegan, autoSweepUntil, autoSweepRuns = began, until, runs
	pendingReapMu.Unlock()
}

// odFakeWorker answers the RW lane in dest: each request is held for `hold` while a progress line is written
// every 100ms, then answered with reply(op). It records the ops it saw.
type odFakeWorker struct {
	mu  sync.Mutex
	ops []string
}

func startOdWorker(t *testing.T, dest string, hold time.Duration, reply func(op string) string) *odFakeWorker {
	t.Helper()
	w := &odFakeWorker{}
	stop, done := make(chan struct{}), make(chan struct{})
	req := filepath.Join(dest, laneRW.req)
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			b, err := os.ReadFile(req)
			if err != nil || len(b) == 0 {
				time.Sleep(5 * time.Millisecond)
				continue
			}
			os.Remove(req)
			op := strings.SplitN(string(b), "\n", 2)[0]
			w.mu.Lock()
			w.ops = append(w.ops, op)
			w.mu.Unlock()
			for el := time.Duration(0); el < hold; el += 100 * time.Millisecond {
				os.WriteFile(filepath.Join(dest, laneRW.prog), []byte("apps "+el.String()+" 1000\n"), 0o600)
				time.Sleep(100 * time.Millisecond)
			}
			os.WriteFile(filepath.Join(dest, laneRW.res), []byte(reply(op)+"\n"), 0o600)
		}
	}()
	t.Cleanup(func() { close(stop); <-done })
	return w
}

// odSessionAs seats a stored (non-throwaway) session for uid in a fresh dest.
func odSessionAs(t *testing.T, uid string) string {
	t.Helper()
	dest := t.TempDir()
	if err := markRoamSession(dest, "odwin", "window horse battery staple", uid, ""); err != nil {
		t.Fatal(err)
	}
	return dest
}

func odSession(t *testing.T) string { return odSessionAs(t, "12") }

// odMaterialize runs MATERIALIZE-APP for pkg in the background. read=false closes the client end at once, the
// way a chooser that timed out or died leaves it. The returned func waits for the handler and gives its reply.
func odMaterialize(dest, pkg string, read bool) func() string {
	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() {
		handleMaterializeApp(srv, dest, pkg, false)
		srv.Close()
		close(done)
	}()
	if !read {
		cli.Close()
		return func() string { <-done; return "" }
	}
	got := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		got <- strings.TrimSpace(string(b))
	}()
	return func() string { <-done; return <-got }
}

func TestOdWindowFor(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	live := now.Add(time.Minute)
	none := time.Time{}
	cases := []struct {
		name          string
		until, since  time.Time
		lastSealStart int64
		live          bool
	}{
		{"no window", none, none, 0, false},
		{"lapsed", now.Add(-time.Second), now.Add(-time.Minute), 0, false},
		{"ends exactly now", now, now.Add(-time.Minute), 0, false},
		{"live, held recently, no seal this session", live, now.Add(-time.Minute), 0, true},
		{"live, held a full gap, no seal since", live, now.Add(-autoSweepMaxSealGap), 0, false},
		{"live, held long, a seal ran recently", live, now.Add(-2 * time.Hour), now.Add(-time.Minute).Unix(), true},
		{"live, the last seal started a full gap ago", live, now.Add(-2 * time.Hour), now.Add(-autoSweepMaxSealGap).Unix(), false},
		{"live, a long seal before this hold -> the gap counts from the hold", live, now.Add(-time.Minute), now.Add(-35 * time.Minute).Unix(), true},
	}
	for _, c := range cases {
		got := odWindowFor(now, c.until, c.since, c.lastSealStart, autoSweepMaxSealGap)
		if !got.IsZero() != c.live {
			t.Errorf("%s: odWindowFor = %v, want live=%v", c.name, got, c.live)
		}
		if c.live && !got.Equal(c.until) {
			t.Errorf("%s: a live window reads %v, want its own end %v", c.name, got, c.until)
		}
	}
}

// The maximum reaches the PERIODIC decision, and the capped-seal log line names the actual reason.
func TestOdWindowMaximumLetsOneSealThrough(t *testing.T) {
	odState(t)
	now := time.Now()
	pendingReapMu.Lock()
	odMaterializeUntil, sealsHeldSince = now.Add(time.Hour), now.Add(-autoSweepMaxSealGap-time.Second)
	note := odCapNote(now)
	pendingReapMu.Unlock()
	if r := periodicNow(t); r != "" {
		t.Fatalf("a window that has held seals back for %s still defers (%q) -- the maximum is not applied", autoSweepMaxSealGap, r)
	}
	if !strings.Contains(note, "have kept seals back since") {
		t.Errorf("the capped-seal log line reads %q; it must say the holds kept seals back", note)
	}
	lastSealStartedAt.Store(now.Add(-time.Minute).Unix()) // one seal just ran: the window holds again
	if r := periodicNow(t); r != "materialise" {
		t.Fatalf("after a seal ran, a live window reads %q, want materialise", r)
	}
	pendingReapMu.Lock()
	note = odCapNote(now)
	pendingReapMu.Unlock()
	if note != "" {
		t.Errorf("a window that still holds produced a cap note %q", note)
	}
	lastSealStartedAt.Store(now.Add(-autoSweepMaxSealGap - time.Minute).Unix())
	pendingReapMu.Lock()
	sealsHeldSince = now.Add(-2 * autoSweepMaxSealGap)
	note = odCapNote(now)
	pendingReapMu.Unlock()
	if !strings.Contains(note, "the last seal started") {
		t.Errorf("capped by the seal gap, the log line reads %q; it must name the last seal", note)
	}
}

// Round-2 probes C and D: a fresh tap after a long seal gets its full window, even when the session had an earlier
// tap long before -- because a seal started after that earlier hold.
func TestOdWindowFreshTapAfterALongSealHolds(t *testing.T) {
	odState(t)
	lastSealStartedAt.Store(time.Now().Add(-35 * time.Minute).Unix())
	beginOdMaterialise("com.c", time.Now())
	if !odLive() {
		t.Fatal("PROBE C: a fresh tap's window is void from its first instant")
	}
	resetOdWindow()
	e := beginOdMaterialise("com.early", time.Now().Add(-2*time.Hour))
	settleOdMaterialise("com.early", e, odFailed, time.Now().Add(-2*time.Hour))
	beginOdMaterialise("com.d", time.Now())
	if !odLive() {
		t.Fatal("PROBE D: an earlier tap two hours ago voided a fresh tap's window -- a seal ran since, so a new hold")
	}
}

// Round-3 item 2 and 4: the anchor moves only when a hold begins after a seal started. A pause of any length with
// no seal keeps the count; a pause of a few minutes in which a seal started begins a new one.
func TestOdWindowAnchorMovesOnlyAfterASeal(t *testing.T) {
	odState(t)
	t0 := time.Now().Add(-3 * time.Hour)
	e := beginOdMaterialise("com.a", t0)
	settleOdMaterialise("com.a", e, odFailed, t0.Add(10*time.Minute))
	beginOdMaterialise("com.b", t0.Add(2*time.Hour)) // two hours, and no seal started
	if a := odAnchor(); !a.Equal(t0) {
		t.Fatalf("a hold after a pause with NO seal restarted the count at %v, want %v -- a pause could then keep "+
			"seals off without bound", a, t0)
	}
	resetOdWindow()
	odFetchLease = 90 * time.Second // com.b below must still be live 70 s after it opens
	e = beginOdMaterialise("com.a", t0)
	settleOdMaterialise("com.a", e, odFailed, t0.Add(10*time.Minute))
	lastSealStartedAt.Store(t0.Add(11 * time.Minute).Unix()) // a seal starts in the pause
	later := t0.Add(13 * time.Minute)                        // a few minutes after it
	beginOdMaterialise("com.b", later)
	if a := odAnchor(); !a.Equal(later) {
		t.Fatalf("a hold beginning after a seal started kept the old anchor %v, want %v", a, later)
	}
	// A lease opening while another is live never moves it, even after a let-through seal.
	lastSealStartedAt.Store(later.Add(time.Minute).Unix())
	beginOdMaterialise("com.c", later.Add(70*time.Second))
	if a := odAnchor(); !a.Equal(later) {
		t.Errorf("a lease opening inside a live hold moved the anchor to %v", a)
	}
	// Both leases END explicitly AFTER that seal; a hold right after continues the episode: the seal came first.
	endOdLease("com.b", later.Add(2*time.Minute))
	endOdLease("com.c", later.Add(2*time.Minute))
	beginOdMaterialise("com.d", later.Add(3*time.Minute))
	if a := odAnchor(); !a.Equal(later) {
		t.Errorf("a hold after leases that ended AFTER the last seal began a new episode at %v, want %v", a, later)
	}
}

// Round-3 probe: holds separated by pauses, the periodic loop ticking every 15 minutes or every 120 s. No pause may
// restart the count while nothing seals, so a seal runs at least every autoSweepMaxSealGap plus one tick.
func TestOdWindowPausesDoNotResetTheBound(t *testing.T) {
	for _, c := range []struct{ tick, hold, pause time.Duration }{
		{15 * time.Minute, 25 * time.Minute, 3 * time.Minute},
		{120 * time.Second, 26*time.Minute + 50*time.Second, 100 * time.Second},
	} {
		odState(t)
		odFetchLease = 90 * time.Second
		t0 := time.Now().Add(-5 * time.Hour)
		cycle := c.hold + c.pause
		var last time.Duration
		worst := time.Duration(0)
		for m, next := time.Duration(0), c.tick; m < 120*time.Minute; m += 10 * time.Second {
			now := t0.Add(m)
			if off := m % cycle; off < c.hold-90*time.Second+time.Second && off%(80*time.Second) == 0 {
				beginOdMaterialise("com.e"+m.String(), now)
			}
			if m >= next {
				next += c.tick
				if periodicAt(now) == "" {
					if m-last > worst {
						worst = m - last
					}
					last = m
					lastSealStartedAt.Store(now.Unix())
				}
			}
		}
		if tail := 120*time.Minute - last; tail > worst {
			worst = tail // the stretch after the last seal counts too
		}
		if limit := autoSweepMaxSealGap + c.tick; worst > limit {
			t.Errorf("tick %s, holds of %s, pauses of %s: %s without a seal (bound %s)", c.tick, c.hold, c.pause, worst, limit)
		}
	}
}

// Round-3 probe B: a materialise hold first, an auto sweep starting 20 minutes in. ONE count between them.
func TestOdWindowThenSweepShareOneCount(t *testing.T) {
	odState(t)
	odFetchLease = 90 * time.Second
	t0 := time.Now().Add(-2 * time.Hour)
	first := time.Duration(-1)
	for m := time.Duration(0); m < 60*time.Minute; m += 20 * time.Second {
		now := t0.Add(m)
		if m%(80*time.Second) == 0 {
			beginOdMaterialise("com.p"+m.String(), now)
		}
		if m == 20*time.Minute {
			setSweep(now, now.Add(time.Hour), 1)
		}
		if periodicAt(now) == "" {
			first = m
			break
		}
	}
	if first < 0 || first > autoSweepMaxSealGap {
		t.Errorf("PROBE B: the first seal was allowed at +%s after the first tap, want by +%s", first, autoSweepMaxSealGap)
	}
}

// Round-3 probe A: an auto sweep first, taps chaining through it and past its end. ONE count between them.
func TestOdWindowSweepThenTapsShareOneCount(t *testing.T) {
	odState(t)
	odFetchLease = 90 * time.Second
	t0 := time.Now().Add(-2 * time.Hour)
	setSweep(t0, t0.Add(time.Hour), 1)
	e := beginOdMaterialise("com.a", t0)
	settleOdMaterialise("com.a", e, odFailed, t0.Add(18*time.Minute))
	first := time.Duration(-1)
	for m := 20 * time.Minute; m < 90*time.Minute; m += 20 * time.Second {
		now := t0.Add(m)
		if (m-20*time.Minute)%(80*time.Second) == 0 {
			beginOdMaterialise("com.t"+m.String(), now)
		}
		if m == 25*time.Minute {
			setSweep(time.Time{}, time.Time{}, 0)
		}
		if periodicAt(now) == "" {
			first = m
			break
		}
	}
	if first < 0 || first > autoSweepMaxSealGap {
		t.Errorf("PROBE A: no seal until +%s after the sweep began, want by +%s", first, autoSweepMaxSealGap)
	}
}

// A sweep that starts through the real verb while a materialise hold is live continues that hold's count -- even
// after a seal the maximum let through: the hold never ended, so no new episode begins.
func TestOdWindowSweepVerbContinuesALiveHold(t *testing.T) {
	odState(t)
	odFetchLease = time.Minute
	t0 := time.Now().Add(-10 * time.Second)
	beginOdMaterialise("com.a", t0)
	lastSealStartedAt.Store(t0.Add(time.Second).Unix()) // a let-through seal inside the live hold
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 1 replied %q", got)
	}
	if a := odAnchor(); !a.Equal(t0) {
		t.Errorf("a sweep starting inside a live hold moved the anchor from %v to %v", t0, a)
	}
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n0\n")
}

// A sweep starting with nothing live, after a seal, begins a new episode; a tap opening inside a live sweep after a
// let-through seal does not.
func TestOdWindowSweepStartAndTapsInsideIt(t *testing.T) {
	odState(t)
	t0 := time.Now().Add(-time.Hour)
	e := beginOdMaterialise("com.a", t0)
	settleOdMaterialise("com.a", e, odFailed, t0.Add(10*time.Minute))
	lastSealStartedAt.Store(t0.Add(20 * time.Minute).Unix())
	before := time.Now()
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 1 replied %q", got)
	}
	a := odAnchor()
	if a.Before(before) {
		t.Fatalf("a sweep starting after a seal kept the old episode's anchor %v", a)
	}
	lastSealStartedAt.Store(time.Now().Unix()) // a seal the maximum let through, inside the sweep
	beginOdMaterialise("com.b", time.Now().Add(2*time.Second))
	if b := odAnchor(); !b.Equal(a) {
		t.Errorf("a tap opening inside a live sweep moved the anchor from %v to %v", a, b)
	}
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n0\n")
}

// A sweep's end -- by AUTO-SWEEP 0, or by its lease lapsing -- is a hold end: a seal that started BEFORE it does
// not begin a new episode for the next tap.
func TestOdWindowSweepEndCountsAsAHoldEnd(t *testing.T) {
	odState(t)
	odFetchLease = time.Minute
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 1 replied %q", got)
	}
	anchor := time.Now().Add(-20 * time.Minute)
	pendingReapMu.Lock()
	sealsHeldSince = anchor
	pendingReapMu.Unlock()
	lastSealStartedAt.Store(time.Now().Add(-5 * time.Second).Unix()) // a let-through seal during the sweep
	evictConn(t, t.TempDir(), "AUTO-SWEEP\n0\n")
	beginOdMaterialise("com.a", time.Now())
	if a := odAnchor(); !a.Equal(anchor) {
		t.Errorf("after AUTO-SWEEP 0 a tap began a new episode at %v, want the sweep's %v (no seal since it ended)", a, anchor)
	}

	resetOdWindow()
	now := time.Now()
	setSweep(now.Add(-30*time.Minute), now.Add(-2*time.Minute), 1) // lapsed two minutes ago
	pendingReapMu.Lock()
	sealsHeldSince = now.Add(-30 * time.Minute)
	pendingReapMu.Unlock()
	lastSealStartedAt.Store(now.Add(-10 * time.Minute).Unix()) // started while it was live
	beginOdMaterialise("com.b", now)
	if a := odAnchor(); !a.Equal(now.Add(-30 * time.Minute)) {
		t.Errorf("after a sweep lapsed a tap began a new episode at %v -- the lapse must count as the hold's end", a)
	}
}

// Round-3 probe C: taps every 80 s for an hour. Seals still run at least every autoSweepMaxSealGap.
func TestOdWindowChainedTapsStillSeal(t *testing.T) {
	odState(t)
	odFetchLease = 90 * time.Second
	t0 := time.Now().Add(-3 * time.Hour)
	var seals []time.Duration
	for m := time.Duration(0); m < 65*time.Minute; m += 10 * time.Second {
		now := t0.Add(m)
		if m%(80*time.Second) == 0 {
			beginOdMaterialise("com.c"+m.String(), now)
		}
		if periodicAt(now) == "" {
			seals = append(seals, m)
			lastSealStartedAt.Store(now.Unix())
		}
	}
	if len(seals) < 2 {
		t.Errorf("only %d seals in 65 minutes of chained taps: %v", len(seals), seals)
	}
}

// Leases only move out, and an extension from an ended session does nothing.
func TestOdWindowLeasesExtendOnlyAndRespectTheEpoch(t *testing.T) {
	odState(t)
	t0 := time.Now()
	ep := beginOdMaterialise("com.a", t0)
	settleOdMaterialise("com.a", ep, odInstalling, t0)
	long := odLease("com.a")
	if !long.Equal(t0.Add(odInstallLease)) || !odUntil().Equal(long) {
		t.Fatalf("install lease %v / window %v, want both %v", long, odUntil(), t0.Add(odInstallLease))
	}
	extendOdLease("com.a", ep, t0, odFetchLease)
	if !odLease("com.a").Equal(long) {
		t.Errorf("a shorter extension moved the lease from %v to %v", long, odLease("com.a"))
	}
	resetOdWindow()
	if extendOdLease("com.a", ep, time.Now(), time.Hour) || !odUntil().IsZero() {
		t.Error("an extension from before the reset re-opened the window")
	}
}

// PROBE A (round 2): tap A fetched OK and is installing; tap B's fetch fails. A's hold must survive.
func TestOdWindowSecondTapFailingKeepsTheFirstInstall(t *testing.T) {
	odState(t)
	now := time.Now()
	ea := beginOdMaterialise("com.a", now)
	settleOdMaterialise("com.a", ea, odInstalling, now)
	eb := beginOdMaterialise("com.b", time.Now())
	settleOdMaterialise("com.b", eb, odFailed, time.Now())
	if !odLive() {
		t.Fatal("PROBE A: B's failed fetch closed A's install hold")
	}
	if !odLease("com.b").IsZero() {
		t.Error("B's failed fetch left B a lease")
	}
}

// PROBE B (round 2): two taps installing; A's RESTORE-ODDATA ends A's lease only.
func TestOdWindowRestoreEndsOnlyItsOwnLease(t *testing.T) {
	odState(t)
	ea := beginOdMaterialise("com.a", time.Now())
	settleOdMaterialise("com.a", ea, odInstalling, time.Now())
	eb := beginOdMaterialise("com.b", time.Now())
	settleOdMaterialise("com.b", eb, odInstalling, time.Now())
	endOdLease("com.a", time.Now()) // A's RESTORE-ODDATA
	if !odLive() {
		t.Fatal("PROBE B: A's RESTORE-ODDATA closed B's install hold")
	}
	if !odLease("com.a").IsZero() {
		t.Error("A's RESTORE-ODDATA left A's lease")
	}
	endOdLease("com.b", time.Now())
	if !odUntil().IsZero() {
		t.Error("with both RESTORE-ODDATAs in, the window is still open")
	}
}

// The whole tap through the real handlers: the lease stays live through a fetch that outlasts it, is held for
// the install once OK reaches the chooser, and the package's RESTORE-ODDATA ends it.
func TestOdWindowHeldForTheWholeTap(t *testing.T) {
	odState(t)
	dest := odSession(t)
	w := startOdWorker(t, dest, 1200*time.Millisecond, func(op string) string { return "OK com.big" })
	wait := odMaterialize(dest, "com.big", true)
	time.Sleep(900 * time.Millisecond) // three fetch leases in
	if !odLive() {
		t.Fatalf("the window lapsed mid-fetch (lease %s) -- a periodic seal could take the slot", odFetchLease)
	}
	if got := wait(); got != "OK com.big" {
		t.Fatalf("MATERIALIZE-APP replied %q", got)
	}
	now := time.Now()
	until := odLease("com.big")
	if until.Before(now.Add(odInstallLease-time.Second)) || until.After(now.Add(odInstallLease)) {
		t.Fatalf("after OK the lease ends in %s, want the install lease %s", until.Sub(now), odInstallLease)
	}
	if got := evictConn(t, dest, "RESTORE-ODDATA\ncom.big\n"); got != "OK com.big" {
		t.Fatalf("RESTORE-ODDATA replied %q", got)
	}
	if odLive() {
		t.Fatal("RESTORE-ODDATA left the window open")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if strings.Join(w.ops, ",") != "materializeapp,odrestore" {
		t.Errorf("worker saw %v", w.ops)
	}
}

// Round-3 item 5: a renewal tick already in flight when the fetch returns cannot re-open the lease settling ends.
// The hook holds every renewal between its tick and its extension, so without the join the extension lands after
// the settle.
func TestOdWindowNoStrayRenewalAfterSettle(t *testing.T) {
	odState(t)
	odRenewEvery = time.Millisecond
	odFetchLease = 5 * time.Second
	odRenewHook = func() { time.Sleep(40 * time.Millisecond) }
	dest := odSession(t)
	startOdWorker(t, dest, 100*time.Millisecond, func(string) string { return "ERR-FETCH" })
	hits := 0
	for i := 0; i < 5; i++ {
		odMaterialize(dest, "com.f", true)()
		time.Sleep(80 * time.Millisecond) // past any renewal that was still in flight
		if !odLease("com.f").IsZero() {
			hits++
			endOdLease("com.f", time.Now())
		}
	}
	if hits != 0 {
		t.Errorf("a renewal re-opened a failed fetch's lease after settling ended it, %d of 5 times", hits)
	}
}

// RESTORE-ODDATA through the real handler ends its own package's lease, not another tap's.
func TestOdWindowRestoreHandlerEndsOnlyItsPackage(t *testing.T) {
	odState(t)
	dest := odSession(t)
	startOdWorker(t, dest, 100*time.Millisecond, func(string) string { return "OK com.a" })
	for _, p := range []string{"com.a", "com.b"} {
		e := beginOdMaterialise(p, time.Now())
		settleOdMaterialise(p, e, odInstalling, time.Now())
	}
	if got := evictConn(t, dest, "RESTORE-ODDATA\ncom.a\n"); got != "OK com.a" {
		t.Fatalf("RESTORE-ODDATA replied %q", got)
	}
	if !odLease("com.a").IsZero() {
		t.Error("com.a's RESTORE-ODDATA left com.a's lease")
	}
	if odLease("com.b").IsZero() || !odLive() {
		t.Error("com.a's RESTORE-ODDATA ended com.b's install hold")
	}
}

// A failed fetch ends that package's lease at once: nobody will install, and nothing else would end it.
func TestOdWindowClosesOnAFailedFetch(t *testing.T) {
	odState(t)
	dest := odSession(t)
	startOdWorker(t, dest, 200*time.Millisecond, func(string) string { return "ERR-FETCH" })
	if got := odMaterialize(dest, "com.big", true)(); got != "ERR-FETCH" {
		t.Fatalf("reply %q", got)
	}
	if !odUntil().IsZero() {
		t.Fatalf("a failed fetch left the window open until %v", odUntil())
	}
}

// A reply the chooser is no longer there to read (it timed out or died) ends the lease even on OK.
func TestOdWindowClosesWhenTheReplyIsNotRead(t *testing.T) {
	odState(t)
	dest := odSession(t)
	startOdWorker(t, dest, 200*time.Millisecond, func(string) string { return "OK com.big" })
	odMaterialize(dest, "com.big", false)()
	if !odUntil().IsZero() {
		t.Fatalf("an OK nobody read held the window open until %v (%s) for an install that will never happen",
			odUntil(), time.Until(odUntil()).Round(time.Millisecond))
	}
}

// odReapReset clears the reap queue around a test that queues one.
func odReapReset(t *testing.T) {
	t.Helper()
	reset := func() {
		pendingReapMu.Lock()
		pendingReapUID, pendingSwitchUID = "", ""
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

// A throwaway's logoff ends the session and the window, and nothing the ended session still has in flight
// re-opens it: not the renewal, not the install lease of an OK that lands after it.
func TestOdWindowLogoffEndsItForGood(t *testing.T) {
	odState(t)
	odReapReset(t)
	dest := odSession(t)
	startOdWorker(t, dest, 1000*time.Millisecond, func(string) string { return "OK com.big" })
	wait := odMaterialize(dest, "com.big", true)
	time.Sleep(200 * time.Millisecond)
	if !odLive() {
		t.Fatal("control: the window is not open during the fetch")
	}
	markLocalSession(dest) // the cheapest logout to drive: a throwaway's ends the session at once, without a seal
	cli, srv := net.Pipe()
	go func() { handleLogout(srv, dest); srv.Close() }()
	io.ReadAll(cli)
	if odLive() {
		t.Fatal("the logoff left the materialise window open")
	}
	time.Sleep(3 * odRenewEvery)
	if odLive() {
		t.Fatal("the ended session's renewal re-opened the window")
	}
	if got := wait(); got != "OK com.big" {
		t.Fatalf("reply %q", got)
	}
	if odLive() {
		t.Fatal("an OK landing after the logoff opened the install lease into whatever session comes next")
	}
}

// odLogout drives LOGOUT for a stored session whose worker answers `out` with outReply, and waits until done()
// reports the teardown reached the state under test.
func odLogout(t *testing.T, dest, outReply string, done func() bool) {
	t.Helper()
	startOdWorker(t, dest, 100*time.Millisecond, func(op string) string {
		if op == "out" {
			return outReply
		}
		return "OK"
	})
	cli, srv := net.Pipe()
	go func() { handleLogout(srv, dest); srv.Close() }()
	if b, _ := io.ReadAll(cli); strings.TrimSpace(string(b)) != "OK" {
		t.Fatalf("LOGOUT replied %q", b)
	}
	deadline := time.Now().Add(15 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatal("the logoff never reached the state under test")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// Round-3 item 7: a stored session's LOGOUT whose seal LANDS ends the session -- and its install holds.
func TestOdWindowLandedLogoffResetsIt(t *testing.T) {
	odState(t)
	resetSealState(t)
	odReapReset(t)
	odInstallLease = time.Minute
	dest := odSessionAs(t, "47")
	e := beginOdMaterialise("com.big", time.Now())
	settleOdMaterialise("com.big", e, odInstalling, time.Now())
	before := odEpoch()
	odLogout(t, dest, "OK", func() bool { return odEpoch() != before }) // fails here if the landed seal never resets
	pendingReapMu.Lock()
	queued := pendingSwitchUID == "47"
	pendingReapMu.Unlock()
	odReapReset(t) // ACK the switch and the reap ourselves, so the teardown's reboot fallback stands down
	if !queued {
		t.Fatal("control: the reset came before the logoff seal landed (no reap queued)")
	}
	if !odUntil().IsZero() {
		t.Fatal("a logoff whose seal landed left that session's install hold in place for the next session")
	}
}

// F10 (round 2): a LOGOUT whose seal fails re-arms the SAME session, and that session's install keeps its hold.
func TestOdWindowFailedLogoffKeepsTheLeases(t *testing.T) {
	odState(t)
	resetSealState(t)
	odInstallLease = time.Minute
	dest := odSession(t)
	e := beginOdMaterialise("com.big", time.Now())
	settleOdMaterialise("com.big", e, odInstalling, time.Now())
	odLogout(t, dest, "ERR-PUSH", func() bool {
		pendingReapMu.Lock()
		failed := sealFail
		pendingReapMu.Unlock()
		_, err := os.Stat(filepath.Join(dest, roamSessionFile))
		return err == nil && failed
	})
	if !odLive() || odLease("com.big").IsZero() {
		t.Fatal("a logoff that FAILED and left the session signed in dropped that session's install hold")
	}
}

// The cold-lock wipe's claim ends the parked session and its leases; a claim for another uid ends nothing.
func TestOdWindowColdLockClaimResetsIt(t *testing.T) {
	gatePeer(t, 10123)
	odState(t)
	dest := t.TempDir()
	os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("odwin\n15\n\n\n\n\n\n"), 0o600)
	e := beginOdMaterialise("com.big", time.Now())
	settleOdMaterialise("com.big", e, odInstalling, time.Now())
	if got := evictConn(t, dest, "CLAIM-COLDLOCK\n16\n"); got != "GONE" || odUntil().IsZero() {
		t.Fatalf("a GONE claim (%q) ended the parked session's hold", got)
	}
	if got := evictConn(t, dest, "CLAIM-COLDLOCK\n15\n"); got != "OK" {
		t.Fatalf("claim replied %q", got)
	}
	if !odUntil().IsZero() {
		t.Fatal("the cold-lock wipe's claim left the wiped session's install hold")
	}
}

// A session marker naming a user that is gone ends that session's leases with it; a live user's are kept.
func TestOdWindowGoneUserMarkerResetsIt(t *testing.T) {
	odState(t)
	old := androidUsersDir
	androidUsersDir = t.TempDir()
	t.Cleanup(func() { androidUsersDir = old })
	dest := odSessionAs(t, "47")
	e := beginOdMaterialise("com.big", time.Now())
	settleOdMaterialise("com.big", e, odInstalling, time.Now())
	os.Mkdir(filepath.Join(androidUsersDir, "47"), 0o700)
	if clearMarkerOfGoneUser(dest) != "" || odUntil().IsZero() {
		t.Fatal("a live user's marker was cleared, or its hold ended")
	}
	os.Remove(filepath.Join(androidUsersDir, "47"))
	if clearMarkerOfGoneUser(dest) != "47" {
		t.Fatal("control: the gone user's marker was not cleared")
	}
	if !odUntil().IsZero() {
		t.Fatal("clearing a gone user's marker left its install hold")
	}
}

// odCode is a function's body with comments and blank lines dropped and each line trimmed: the code a pin
// compares, so a comment cannot satisfy it and rewording a comment cannot break it.
func odCode(t *testing.T, file, fn string) string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\nfunc "+fn+"(")
	if i < 0 {
		t.Fatalf("control failed: no func %s in %s", fn, file)
	}
	j := strings.Index(src[i+1:], "\n}\n")
	var out []string
	cm := regexp.MustCompile(`\s+//.*$`)
	for _, l := range strings.Split(src[i+1:i+1+j], "\n") {
		l = strings.TrimSpace(cm.ReplaceAllString(l, ""))
		if l == "" || strings.HasPrefix(l, "//") {
			continue
		}
		out = append(out, l)
	}
	return strings.Join(out, "\n")
}

// The session-boundary resets no cheap behavioural test reaches, pinned as code blocks (never as a spelling a
// comment could satisfy), each with its exact count of live calls.
func TestOdWindowSessionBoundaryResetsArePinned(t *testing.T) {
	for _, c := range []struct {
		file, fn string
		calls    int
		blocks   []string
	}{
		{"main.go", "handleLogout", 2, []string{
			// the throwaway (either marker, NWP-20261017-04): the session ends at once
			"clearLocalSession(dest)\nclearOfflineSession(dest)\nforgetUiderrorsFloor(dest)\nresetOdWindow()\npendingReapMu.Lock()\npendingSwitchUID = uid",
			// the landed seal: the session ends here, never on a failed logoff -- the reap is queued in the verdict's
			// critical section (released from a defer, NWP-20261014-66), and both keep-signed-in arms return before this
			"pendingReapUID = uid\nreturn false, false, sealPartial\n}()",
			"return\n}\nforgetUiderrorsFloor(dest)\nresetOdWindow()\nif p := partial; p != \"\" {",
		}},
		{"main.go", "handleDelete", 1, []string{"})\nresetOdWindow()\nif uid != \"\" {"}},
		{"main.go", "handleRollback", 1, []string{"forgetUiderrorsFloor(dest)\nresetOdWindow()\npendingReapMu.Lock()\npendingSwitchUID = uid"}},
		{"main.go", "handleRoamIn", 1, []string{"if name == \"\" || uid == \"\" {\nfmt.Fprint(conn, \"BLANK\\n\")\nreturn\n}\nresetOdWindow()\nif !storeConfigured() {"}},
		{"main.go", "handleRoamInOffline", 1, []string{"if name == \"\" || uid == \"\" {\nfmt.Fprint(conn, \"BLANK\\n\")\nreturn\n}\nresetOdWindow()"}},
	} {
		code := odCode(t, c.file, c.fn)
		if n := strings.Count(code, "resetOdWindow()"); n != c.calls {
			t.Errorf("%s calls resetOdWindow %d times, want %d", c.fn, n, c.calls)
		}
		for _, blk := range c.blocks {
			if !strings.Contains(code, blk) {
				t.Errorf("%s no longer holds the block\n%s", c.fn, blk)
			}
		}
	}
}

// F1 (round 2): "Back up now" is never held by a materialise window -- the sweep record's rule. It used to
// answer BUSY, which the screen shows as a save already running.
func TestOdWindowDoesNotHoldBackUpNow(t *testing.T) {
	odState(t)
	resetSealState(t)
	dest := odSession(t)
	startOdWorker(t, dest, 100*time.Millisecond, func(string) string { return "OK" })
	e := beginOdMaterialise("com.big", time.Now())
	settleOdMaterialise("com.big", e, odInstalling, time.Now())
	if !odLive() {
		t.Fatal("control: no live window")
	}
	// Control: the predicate is consulted at all -- a live LOGIN window still answers BUSY.
	pendingReapMu.Lock()
	loginSettleUntil = time.Now().Add(time.Minute)
	pendingReapMu.Unlock()
	if got := evictConn(t, dest, "BACKUP\n"); got != "BUSY login" {
		t.Fatalf("control: BACKUP during a login window replied %q, want BUSY login", got)
	}
	pendingReapMu.Lock()
	loginSettleUntil = time.Time{}
	pendingReapMu.Unlock()
	if got := evictConn(t, dest, "BACKUP\n"); got != "OK" {
		t.Fatalf("BACKUP during an install hold replied %q, want OK -- the window must not hold Back up now", got)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		pendingReapMu.Lock()
		busy := sealInFlight
		pendingReapMu.Unlock()
		if !busy {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the manual backup never finished")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// The guards of RESTORE-ODDATA answer without arming a lease (they used to leave the window armed with nothing to
// close it).
func TestOdWindowRestoreOdDataGuardsDoNotArm(t *testing.T) {
	odState(t)
	for _, c := range []struct{ dest, pkg, want string }{
		{t.TempDir(), "a/b", "ERR-PKG"},
		{t.TempDir(), "com.big", "NONE"},
	} {
		if got := evictConn(t, c.dest, "RESTORE-ODDATA\n"+c.pkg+"\n"); got != c.want {
			t.Fatalf("RESTORE-ODDATA %q replied %q, want %q", c.pkg, got, c.want)
		}
		if !odUntil().IsZero() {
			t.Fatalf("RESTORE-ODDATA answering %s armed the window", c.want)
		}
	}
}

// F5 (round 4): a lease opening inside a live sweep that noted no anchor takes the sweep's start, or now.
func TestOdWindowLeaseInsideAnUnanchoredSweep(t *testing.T) {
	odState(t)
	now := time.Now()
	setSweep(now.Add(-5*time.Minute), now.Add(time.Hour), 1)
	beginOdMaterialise("com.a", now)
	if a := odAnchor(); !a.Equal(now.Add(-5 * time.Minute)) {
		t.Errorf("anchor %v, want the sweep's start %v", a, now.Add(-5*time.Minute))
	}
	resetOdWindow()
	setSweep(time.Time{}, now.Add(time.Hour), 1)
	beginOdMaterialise("com.b", now)
	if a := odAnchor(); !a.Equal(now) {
		t.Errorf("a sweep with no start: anchor %v, want now %v", a, now)
	}
}

// F5 (round 4): a session boundary ends the auto sweep's lease too -- it belongs to the old session's chooser.
func TestOdWindowResetEndsTheSweep(t *testing.T) {
	odState(t)
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n1\n"); got != "OK" {
		t.Fatalf("AUTO-SWEEP 1 replied %q", got)
	}
	resetOdWindow()
	if r := periodicNow(t); r != "" {
		t.Fatalf("after a session boundary the old session's sweep still holds the seal (%q)", r)
	}
	if got := evictConn(t, t.TempDir(), "GET-SWEEP\n"); got != "NONE" {
		t.Errorf("GET-SWEEP after a reset reads %q, want NONE", got)
	}
	if got := evictConn(t, t.TempDir(), "AUTO-SWEEP\n0\n"); got != "OK" {
		t.Errorf("a late AUTO-SWEEP 0 from the old chooser replied %q", got)
	}
}

// A new identity taking over the daemon does not inherit the old session's window.
func TestOdWindowResetWithTheSession(t *testing.T) {
	odState(t)
	ok := lastSealOKAt.Load()
	t.Cleanup(func() { lastSealOKAt.Store(ok) })
	ep := beginOdMaterialise("com.big", time.Now())
	settleOdMaterialise("com.big", ep, odInstalling, time.Now())
	resetSessionSignals()
	if !odUntil().IsZero() || !odAnchor().IsZero() {
		t.Fatal("resetSessionSignals left the previous session's materialise window or anchor")
	}
}
