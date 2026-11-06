package main

// NWP-20261120-05: the OTA check's attempt is bounded (ota_check_bound.go). A refresh with no store answer within
// otaCheckInterimBound records "unreachable" (tried_ms moves, re-marked at each bound) and OTA-STATUS answers
// "UNKNOWN unreachable" for it; a refresh that has not reached its bound, or a check that never ran, still answers
// "UNKNOWN checking"; a quick refresh leaves no mark; a stale marker writes nothing.

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// otaInterimState is otaRefreshState plus the three generation counters and the bound, which it sets to 50 ms.
func otaInterimState(t *testing.T) {
	t.Helper()
	otaRefreshState(t)
	otaCacheMu.Lock()
	g, o, i := otaRefreshGen, otaRefreshOpen, otaInterimGen
	otaRefreshGen, otaRefreshOpen, otaInterimGen = 0, 0, 0
	otaCacheMu.Unlock()
	b := otaCheckInterimBound
	otaCheckInterimBound = 50 * time.Millisecond
	t.Cleanup(func() {
		otaCacheMu.Lock()
		otaRefreshGen, otaRefreshOpen, otaInterimGen = g, o, i
		otaCacheMu.Unlock()
		otaCheckInterimBound = b
	})
}

// otaInterimPoll waits for cond, with a generous ceiling: never a tight upper bound.
func otaInterimPoll(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(5 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatalf("%s: not within 5 s (OTA-VERSIONS %q)", what, strings.TrimSpace(otaVersionsLine("0.0.0")))
}

func otaInterimHas(field string) bool {
	return strings.Contains(" "+strings.TrimSpace(otaVersionsLine("0.0.0"))+" ", " "+field+" ")
}

func otaInterimCounters() (open, interim uint64) {
	otaCacheMu.Lock()
	defer otaCacheMu.Unlock()
	return otaRefreshOpen, otaInterimGen
}

// (a) A gateway that does not answer: the refresh reads unreachable at its bound, re-marked at the next; its late
// failure closes the generation; a refresh kicked after it answers "checking" again.
func TestOtaInterimStuckRefreshReadsUnreachable(t *testing.T) {
	tr := trackGoSafe(t)
	otaInterimState(t)
	release := make(chan struct{})
	var once sync.Once
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(front.Close)
	// Runs before front.Close (cleanups are LIFO): release the handlers, then let the refresh end before the state
	// is restored, also when an assertion below stopped the test early.
	t.Cleanup(func() {
		once.Do(func() { close(release) })
		for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(5 * time.Millisecond) {
			otaCacheMu.Lock()
			busy := otaRefreshing
			otaCacheMu.Unlock()
			if !busy {
				return
			}
		}
	})
	otaRefreshEnv(t, front.URL)

	kickOtaRefresh()
	otaInterimPoll(t, "a stuck refresh records unreachable while it runs", func() bool {
		return otaInterimHas("lasterr unreachable") && !otaInterimHas("tried_ms -1") && otaInterimHas("refreshing 1")
	})
	if got := driveLogin(t, t.TempDir(), "OTA-STATUS\n"); got != "UNKNOWN unreachable" {
		t.Errorf("OTA-STATUS = %q for a refresh past its bound, want UNKNOWN unreachable", got)
	}
	first := otaRefreshTriedMs(t)
	otaInterimPoll(t, "tried_ms moves again at a later bound", func() bool {
		return otaRefreshTriedMs(t) > first && otaInterimHas("refreshing 1")
	})

	once.Do(func() { close(release) })
	otaRefreshQuiesce(t)
	if !otaInterimHas("lasterr unreachable") {
		t.Errorf("OTA-VERSIONS = %q after the late failure, want lasterr unreachable", strings.TrimSpace(otaVersionsLine("0.0.0")))
	}
	if open, interim := otaInterimCounters(); open != 0 || interim != 0 {
		t.Errorf("after the outcome otaRefreshOpen = %d, otaInterimGen = %d, want 0 and 0", open, interim)
	}
	tr.wait(t, 5*time.Second)

	// A refresh kicked right after the late one ended has not reached its bound: "checking". Set by hand, so the
	// probe's kick coalesces and no store is asked.
	otaCacheMu.Lock()
	otaRefreshing, otaRefreshSince = true, time.Now().Round(0)
	otaCacheMu.Unlock()
	if got := driveLogin(t, t.TempDir(), "OTA-STATUS\n"); got != "UNKNOWN checking" {
		t.Errorf("OTA-STATUS = %q for a just-kicked refresh after a late one, want UNKNOWN checking", got)
	}
	otaCacheMu.Lock()
	otaRefreshing = false
	otaCacheMu.Unlock()
}

// (b) No refresh has run yet (every counter 0) and one is in flight: "checking", never "unreachable".
func TestOtaInterimNeverRunAnswersChecking(t *testing.T) {
	otaInterimState(t)
	otaRefreshEnv(t, deadStore(t))
	otaCacheMu.Lock()
	otaRefreshing, otaRefreshSince = true, time.Now().Round(0)
	otaCacheMu.Unlock()
	if got := driveLogin(t, t.TempDir(), "OTA-STATUS\n"); got != "UNKNOWN checking" {
		t.Errorf("OTA-STATUS = %q for a just-kicked first refresh, want UNKNOWN checking", got)
	}
	otaCacheMu.Lock()
	otaRefreshing = false
	otaCacheMu.Unlock()
}

// (c) A marker whose generation is not open returns at its first bound and writes nothing.
func TestOtaInterimStaleMarkerWritesNothing(t *testing.T) {
	otaInterimState(t)
	done := make(chan struct{})
	t.Cleanup(func() { close(done) }) // only so a broken marker cannot outlive the test; never closed before the check
	ended := make(chan struct{})
	go func() { otaInterimMark(7, done); close(ended) }()
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		t.Fatal("a marker for a generation that is not open did not return")
	}
	otaCacheMu.Lock()
	tried, lastErr, interim := otaLastTry, otaLastErr, otaInterimGen
	otaCacheMu.Unlock()
	if !tried.IsZero() || lastErr != "" || interim != 0 {
		t.Errorf("a stale marker wrote otaLastTry %v, otaLastErr %q, otaInterimGen %d; want nothing", tried, lastErr, interim)
	}
}

// (d) A store that answers at once: no mark, then or later.
func TestOtaInterimQuickRefreshLeavesNoMark(t *testing.T) {
	tr := trackGoSafe(t)
	otaInterimState(t)
	srv, _, _ := mockCapStore(t)
	otaRefreshEnv(t, srv.URL)
	otaRefreshRun(t)
	tried := otaRefreshTriedMs(t)
	time.Sleep(20 * otaCheckInterimBound)
	if !otaInterimHas("lasterr none") {
		t.Errorf("OTA-VERSIONS = %q after a quick refresh, want lasterr none", strings.TrimSpace(otaVersionsLine("0.0.0")))
	}
	if got := otaRefreshTriedMs(t); got != tried {
		t.Errorf("tried_ms moved from %d to %d after a quick refresh ended", tried, got)
	}
	tr.wait(t, 5*time.Second)
}

// (e) refreshOtaCache starts the marker once and always ends it.
func TestOtaInterimIsWired(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	main := string(src)
	i := strings.Index(main, "func refreshOtaCache() {")
	if i < 0 {
		t.Fatal("refreshOtaCache is gone")
	}
	body := main[i:]
	body = body[:strings.Index(body, "\n}\n")]
	for _, s := range []string{"defer close(done)", `goSafe("ota-interim"`} {
		if c := strings.Count(body, s); c != 1 {
			t.Errorf("refreshOtaCache holds %q %d times, want once", s, c)
		}
	}
}
