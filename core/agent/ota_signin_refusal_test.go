package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261101-11 (Q062): while an OS update is staging or applying, ROAM-IN, ROAM-IN-OFFLINE, CREATE and
// CREATE-CODE answer ERR-OTA before any credential is read -- otad reboots after the apply and would end the
// new session with its work unsealed. A RESUME of a parked session is not refused.

func osrSeed(t *testing.T, res string) string {
	t.Helper()
	dest := t.TempDir()
	if res != "" {
		if err := os.WriteFile(filepath.Join(dest, "ota.res"), []byte(res+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dest
}

// osrStore points the daemon at a store that counts every request it receives.
func osrStore(t *testing.T) *int32 {
	t.Helper()
	var n int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&n, 1)
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("S3_ENDPOINT", srv.URL)
	t.Setenv("S3_BUCKET", "b")
	t.Setenv("S3_ACCESS_KEY", "k")
	t.Setenv("S3_SECRET_KEY", "s")
	return &n
}

// osrReply returns the handler's reply; a handler that never answers (it reached the worker) is reported as
// NO-REPLY after a bound, so a missing refusal fails the test instead of hanging it.
func osrReply(f func(net.Conn)) string {
	cli, srv := net.Pipe()
	go func() { f(srv); srv.Close() }()
	got := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		got <- dropCreateProgress(strings.TrimSpace(string(b)))
	}()
	select {
	case r := <-got:
		return r
	case <-time.After(5 * time.Second):
		cli.Close()
		return "NO-REPLY"
	}
}

// osrVerbs runs each of the four handlers with the given credentials.
func osrVerbs(dest, name, pass string) map[string]string {
	return map[string]string{
		"ROAM-IN":         osrReply(func(c net.Conn) { handleRoamIn(c, dest, name, pass, "12", "", "") }),
		"ROAM-IN-OFFLINE": osrReply(func(c net.Conn) { handleRoamInOffline(c, dest, name, pass, "12") }),
		"CREATE":          osrReply(func(c net.Conn) { handleCreate(c, dest, name, pass) }),
		"CREATE-CODE":     osrReply(func(c net.Conn) { handleCreateCode(c, dest, name, pass, "code") }),
	}
}

func TestOtaSigninRefusalInFlight(t *testing.T) {
	for _, res := range []string{"STAGING", "STAGING 0.6.0", "APPLYING 0.6.0", "OK 0.6.0"} {
		n := osrStore(t)
		dest := osrSeed(t, res) // mtime is now: otaWorkerDead's grace keeps it live without getprop
		// a blank name would be answered BLANK by every handler's own check, so ERR-OTA proves the call is first
		for _, cr := range [][2]string{{"alice-osr", "pw-one"}, {"bob-osr", "pw-two"}, {"", ""}} {
			for verb, got := range osrVerbs(dest, cr[0], cr[1]) {
				if got != "ERR-OTA" {
					t.Errorf("ota.res %q, %s: reply %q, want ERR-OTA", res, verb, got)
				}
			}
		}
		if c := atomic.LoadInt32(n); c != 0 {
			t.Errorf("ota.res %q: %d store request(s) made, want none", res, c)
		}
	}
}

func TestOtaSigninRefusalRepliesAreIdentical(t *testing.T) {
	dest := osrSeed(t, "STAGING")
	a := osrVerbs(dest, "carol-osr", "one")
	b := osrVerbs(dest, "dave-osr", "two")
	for verb := range a {
		if a[verb] != b[verb] {
			t.Errorf("%s: replies differ between credentials: %q vs %q", verb, a[verb], b[verb])
		}
	}
}

func TestOtaSigninRefusalNotInFlight(t *testing.T) {
	for _, res := range []string{"ERR-PAYLOAD", "ERR-APPLY", "UPTODATE", "NONE", ""} {
		dest := osrSeed(t, res)
		if otaInFlight(dest) {
			t.Errorf("ota.res %q reported in flight", res)
		}
		// an empty name is each handler's first own check: BLANK, not ERR-OTA
		for verb, got := range osrVerbs(dest, "", "") {
			if got != "BLANK" {
				t.Errorf("ota.res %q, %s: reply %q, want its normal BLANK", res, verb, got)
			}
		}
	}
}

func TestOtaSigninRefusalDoesNotTouchResume(t *testing.T) {
	dest := osrSeed(t, "APPLYING 0.6.0")
	if got := osrReply(func(c net.Conn) { handleResume(c, dest, "x") }); got == "ERR-OTA" {
		t.Errorf("RESUME answered ERR-OTA during an update; a parked session must still resume")
	}
}
