package main

// NWP-20261108-09: refreshOtaCache and otaCheck EXECUTED. The older OTA tests only scan their source. A store the
// refresh could not reach must be RECORDED (otaLastTry moves, lasterr "unreachable", the cached answer is kept); a
// marker that is definitely absent is a COMPLETED check that answers NONE; a fresh-cap 403 on the marker is a
// failed read, never "nothing published".

import (
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const otaRefreshRef = "ota/nwptest/version"

// otaRefreshState saves every global a refresh can touch, restores them on cleanup, and starts the test from zero.
func otaRefreshState(t *testing.T) {
	t.Helper()
	otaCacheMu.Lock()
	cl, ca, cat, rf, rs, lt, le := otaCacheLatest, otaCacheAvail, otaCacheAt, otaRefreshing, otaRefreshSince, otaLastTry, otaLastErr
	otaCacheLatest, otaCacheAvail, otaCacheAt, otaRefreshing, otaRefreshSince, otaLastTry, otaLastErr = "", false, time.Time{}, false, time.Time{}, time.Time{}, ""
	otaCacheMu.Unlock()
	otaNotesMu.Lock()
	no, nc, nm, na := otaNotesOffered, otaNotesChain, otaNotesMore, otaNotesAt
	otaNotesOffered, otaNotesChain, otaNotesMore, otaNotesAt = "", nil, false, time.Time{}
	otaNotesMu.Unlock()
	otaMandMu.Lock()
	mo, mb, mr := otaMandOffered, otaMandBest, otaMandRetryAt
	otaMandOffered, otaMandBest, otaMandRetryAt = "", nil, time.Time{}
	otaMandMu.Unlock()
	rb := s3RetryBase
	s3RetryBase = time.Millisecond
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() {
		otaCacheMu.Lock()
		otaCacheLatest, otaCacheAvail, otaCacheAt, otaRefreshing, otaRefreshSince, otaLastTry, otaLastErr = cl, ca, cat, rf, rs, lt, le
		otaCacheMu.Unlock()
		otaNotesMu.Lock()
		otaNotesOffered, otaNotesChain, otaNotesMore, otaNotesAt = no, nc, nm, na
		otaNotesMu.Unlock()
		otaMandMu.Lock()
		otaMandOffered, otaMandBest, otaMandRetryAt = mo, mb, mr
		otaMandMu.Unlock()
		s3RetryBase = rb
		capReadCache = map[string]capEntry{}
	})
}

func otaRefreshEnv(t *testing.T, gateway string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", gateway)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("S3_SECRET_KEY", "")
	t.Setenv("S3_ENDPOINT", "")
	t.Setenv("NOWHERE_OTA_VERSION_REF", otaRefreshRef)
	t.Setenv("NOWHERE_STATE", t.TempDir())
}

// otaRefreshRun is refreshOtaCache where a panic is a failed test, never a dead test binary.
func otaRefreshRun(t *testing.T) {
	t.Helper()
	if err := recovered(refreshOtaCache); err != nil {
		t.Errorf("refreshOtaCache panicked instead of recording the outcome: %v", err)
	}
}

// otaRefreshRefuse puts a proxy in front of srv that answers GETs of the OTA marker with status and passes
// everything else through, and points the gateway at it.
func otaRefreshRefuse(t *testing.T, srv *httptest.Server, status int) {
	t.Helper()
	target, _ := url.Parse(srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" && strings.Contains(r.URL.Query().Get("k"), otaRefreshRef) {
			w.WriteHeader(status)
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
}

// otaRefreshQuiesce waits for a refresh a probe kicked in the background, so it cannot write after the cleanup.
func otaRefreshQuiesce(t *testing.T) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(5 * time.Millisecond) {
		otaCacheMu.Lock()
		busy := otaRefreshing
		otaCacheMu.Unlock()
		if !busy {
			return
		}
	}
	t.Fatal("a background OTA refresh did not finish")
}

func otaRefreshTriedMs(t *testing.T) int64 {
	t.Helper()
	f := strings.Fields(otaVersionsLine("0.0.0"))
	for i, w := range f {
		if w == "tried_ms" && i+1 < len(f) {
			n, err := strconv.ParseInt(f[i+1], 10, 64)
			if err != nil {
				t.Fatalf("tried_ms %q is not a number", f[i+1])
			}
			return n
		}
	}
	t.Fatalf("OTA-VERSIONS has no tried_ms: %q", otaVersionsLine("0.0.0"))
	return -1
}

func TestOtaRefreshDeadStoreIsRecorded(t *testing.T) {
	otaRefreshState(t)
	otaRefreshEnv(t, deadStore(t))
	seeded := time.Now().Add(-time.Minute).Round(0)
	otaCacheMu.Lock()
	otaCacheLatest, otaCacheAvail, otaCacheAt = "1.2.3", true, seeded
	otaCacheMu.Unlock()
	before := time.Now().Add(-time.Second)
	otaRefreshRun(t)
	otaCacheMu.Lock()
	lastErr, tried, latest, avail, at := otaLastErr, otaLastTry, otaCacheLatest, otaCacheAvail, otaCacheAt
	otaCacheMu.Unlock()
	if lastErr != "unreachable" {
		t.Errorf("otaLastErr = %q, want unreachable", lastErr)
	}
	if tried.IsZero() || tried.Before(before) {
		t.Errorf("otaLastTry = %v, want a stamp from this attempt", tried)
	}
	if latest != "1.2.3" || !avail || !at.Equal(seeded) {
		t.Errorf("the cached answer changed: %q %v %v", latest, avail, at)
	}
	if ms := otaRefreshTriedMs(t); ms < 0 {
		t.Errorf("OTA-VERSIONS tried_ms = %d, want >= 0", ms)
	}
}

func TestOtaRefreshForbiddenMarkerIsUnreachable(t *testing.T) {
	otaRefreshState(t)
	srv, objs, mu := mockCapStore(t)
	mu.Lock()
	objs["ref/"+otaRefreshRef] = []byte("9.9.9\n")
	mu.Unlock()
	otaRefreshEnv(t, srv.URL)
	otaRefreshRefuse(t, srv, http.StatusForbidden)
	otaRefreshRun(t)
	otaCacheMu.Lock()
	lastErr, fresh := otaLastErr, !otaCacheAt.IsZero()
	otaCacheMu.Unlock()
	if lastErr != "unreachable" {
		t.Errorf("a 403 on the marker left otaLastErr = %q, want unreachable", lastErr)
	}
	if fresh {
		t.Error("a 403 on the marker was recorded as a completed check")
	}
	got := driveLogin(t, t.TempDir(), "OTA-STATUS\n")
	otaRefreshQuiesce(t)
	if got == "NONE" {
		t.Errorf("OTA-STATUS = %q after a refused marker read, want an UNKNOWN", got)
	}
}

func TestOtaRefreshNoMarkerAnswersNone(t *testing.T) {
	otaRefreshState(t)
	srv, _, _ := mockCapStore(t)
	otaRefreshEnv(t, srv.URL)
	otaRefreshRun(t)
	otaCacheMu.Lock()
	lastErr, at, latest, avail := otaLastErr, otaCacheAt, otaCacheLatest, otaCacheAvail
	otaCacheMu.Unlock()
	if lastErr != "" {
		t.Errorf("a missing marker left otaLastErr = %q, want none", lastErr)
	}
	if at.IsZero() || latest != "" || avail {
		t.Errorf("a missing marker left the cache %q %v %v, want fresh and empty", latest, avail, at)
	}
	if got := driveLogin(t, t.TempDir(), "OTA-STATUS\n"); got != "NONE" {
		t.Errorf("OTA-STATUS = %q, want NONE", got)
	}
	otaRefreshQuiesce(t)
	if l := otaVersionsLine("0.0.0"); !strings.Contains(l, "lasterr none") {
		t.Errorf("OTA-VERSIONS = %q, want lasterr none", l)
	}
}

func TestOtaRefreshPublishedMarkerIsAvail(t *testing.T) {
	otaRefreshState(t)
	srv, objs, mu := mockCapStore(t)
	mu.Lock()
	objs["ref/"+otaRefreshRef] = []byte("999.0.0\n")
	mu.Unlock()
	otaRefreshEnv(t, srv.URL)
	otaRefreshRun(t)
	otaCacheMu.Lock()
	lastErr, latest, avail := otaLastErr, otaCacheLatest, otaCacheAvail
	otaCacheMu.Unlock()
	if lastErr != "" || latest != "999.0.0" || !avail {
		t.Errorf("refresh left %q %q %v, want none 999.0.0 true", lastErr, latest, avail)
	}
	if got := driveLogin(t, t.TempDir(), "OTA-STATUS\n"); !strings.HasPrefix(got, "AVAIL 999.0.0") {
		t.Errorf("OTA-STATUS = %q, want AVAIL 999.0.0", got)
	}
	otaRefreshQuiesce(t)
}

// TestOtaRefreshOtaCheckIsStrict: the ota-check CLI shares otaCheck. A refused marker read must not come back as
// "nothing published" (exit 3, which nowhere_otad.sh reports as NONE); it panics into exitStoreUnreachable.
func TestOtaRefreshOtaCheckIsStrict(t *testing.T) {
	otaRefreshState(t)
	runFile := filepath.Join(t.TempDir(), "running")
	if err := os.WriteFile(runFile, []byte("0.0.0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Run("403 on the marker", func(t *testing.T) {
		srv, objs, mu := mockCapStore(t)
		mu.Lock()
		objs["ref/"+otaRefreshRef] = []byte("9.9.9\n")
		mu.Unlock()
		otaRefreshEnv(t, srv.URL)
		otaRefreshRefuse(t, srv, http.StatusForbidden)
		r := panicOf(func() { otaCheck("s3", runFile) })
		if r == nil {
			t.Fatal("otaCheck read a refused marker as a result; want a panic")
		}
		if got := exitStatus(r); got != exitStoreUnreachable {
			t.Errorf("exit status %d, want %d (exitStoreUnreachable)", got, exitStoreUnreachable)
		}
	})
	t.Run("no marker", func(t *testing.T) {
		srv, _, _ := mockCapStore(t)
		otaRefreshEnv(t, srv.URL)
		var latest string
		var avail bool
		if err := recovered(func() { latest, avail = otaCheck("s3", runFile) }); err != nil {
			t.Fatalf("otaCheck panicked on an absent marker: %v", err)
		}
		if latest != "" || avail {
			t.Errorf("otaCheck = %q %v, want empty false", latest, avail)
		}
	})
}
