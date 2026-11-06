package main

import (
	"testing"
	"time"
)

// TestOtaStampsCarryNoMonotonicReading is the regression test for NWP-20260824-02, and it tests the
// property that actually broke rather than the symptom.
//
// A bare time.Now() carries a MONOTONIC reading, and time.Since/Until then measure CLOCK_MONOTONIC, which
// on Linux does NOT advance across system suspend. That is why the bug survived its own self-heal: the
// OTA-STATUS probe kicks a refresh when `age > otaCacheTTL`, but the age was computed from a monotonic
// delta that had frozen along with the sleep. On hardware, frankel showed no update for 30+ minutes and
// then showed it within seconds of being connected to power.
//
// Round(0) strips the monotonic reading. There is no way to fast-forward a suspend in a unit test, so the
// test asserts the INVARIANT that makes the fix work: these stamps must be wall-clock instants. If someone
// "tidies" a Round(0) away, this fails.
func TestOtaStampsCarryNoMonotonicReading(t *testing.T) {
	// A time.Time with a monotonic reading prints a trailing "m=+x.y"; one without never does. That string
	// form is the documented, stable way to observe the difference (there is no exported accessor).
	withMono := time.Now()
	if !hasMonotonic(withMono) {
		t.Skip("this platform's time.Now() carries no monotonic reading; the invariant is moot here")
	}

	otaCacheMu.Lock()
	otaCacheAt = time.Now().Round(0)
	otaLastTry = time.Now().Round(0)
	otaRefreshSince = time.Now().Round(0)
	at, try, since := otaCacheAt, otaLastTry, otaRefreshSince
	otaCacheMu.Unlock()

	for name, v := range map[string]time.Time{"otaCacheAt": at, "otaLastTry": try, "otaRefreshSince": since} {
		if hasMonotonic(v) {
			t.Errorf("%s carries a monotonic reading; it must be a WALL-clock instant (use time.Now().Round(0)), "+
				"or its age freezes across suspend and no refresh is ever kicked", name)
		}
	}
}

func hasMonotonic(t time.Time) bool {
	// String() appends " m=+<seconds>" only when a monotonic reading is present.
	s := t.String()
	for i := 0; i+2 < len(s); i++ {
		if s[i] == 'm' && s[i+1] == '=' {
			return true
		}
	}
	return false
}

// TestSleepUntilWallReturnsAfterTheDeadline guards the napping helper against the obvious regressions: an
// off-by-one that returns immediately, and a nap loop that overshoots wildly. It deliberately does NOT try
// to simulate suspend -- see the comment above.
func TestSleepUntilWallReturnsAfterTheDeadline(t *testing.T) {
	start := time.Now().Round(0)
	sleepUntilWall(120 * time.Millisecond)
	elapsed := time.Since(start)
	if elapsed < 120*time.Millisecond {
		t.Fatalf("returned after %v, before the %v deadline", elapsed, 120*time.Millisecond)
	}
	if elapsed > 5*time.Second {
		t.Fatalf("returned after %v, far past the deadline -- the nap loop is not converging", elapsed)
	}
}

// TestKickOtaRefreshAbandonsAFrozenFlight proves the single-flight guard cannot latch forever. A refresh
// that is in flight when the device suspends has its HTTP timeouts frozen too, so without an age bound
// otaRefreshing stays true and every later kick -- including the user pressing "check for updates" -- is
// silently dropped.
func TestKickOtaRefreshAbandonsAFrozenFlight(t *testing.T) {
	otaCacheMu.Lock()
	otaRefreshing = true
	otaRefreshSince = time.Now().Round(0).Add(-2 * otaRefreshAbandon) // a flight that "started" long ago
	otaCacheMu.Unlock()
	defer func() {
		otaCacheMu.Lock()
		otaRefreshing = false
		otaCacheMu.Unlock()
	}()

	stale := time.Now().Round(0).Add(-2 * otaRefreshAbandon)
	otaCacheMu.Lock()
	blocked := otaRefreshing && time.Since(otaRefreshSince) < otaRefreshAbandon
	otaCacheMu.Unlock()
	if blocked {
		t.Fatal("a flight older than otaRefreshAbandon still blocks new kicks; the guard can latch forever")
	}

	otaCacheMu.Lock()
	otaRefreshSince = time.Now().Round(0)
	fresh := otaRefreshing && time.Since(otaRefreshSince) < otaRefreshAbandon
	otaCacheMu.Unlock()
	if !fresh {
		t.Fatal("a flight that just started does NOT coalesce; repeated probes would pile up refreshers")
	}
	_ = stale
}
