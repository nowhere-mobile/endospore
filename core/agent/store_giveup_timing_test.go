package main

// NWP-20261112-17 (backlog §C, "On a dead network a sign-in takes minutes to go local and an offline delete outlasts
// the screen's wait: the store is retried read by read"). store_giveup_test.go drives retryStoreWithin on a fake
// clock; these four tests time the real thing in cap mode, on the real clock and the real 200 ms backoff: the
// `restore` verb re-executed through main() with NOWHERE_STORE_GIVEUP=1, and handleDelete running the real
// deleteForSession, each against a front whose every request stalls and then loses its connection. Against a store
// that never answers both stop within storeGiveUpWindow plus one read and print the stop line; against one that comes
// back inside the window both succeed.
//
// The stop line, not only the elapsed time, is what proves the give-up fired: capGetRetryWindow is also 15 s, so a
// single fatal cap read ends at about the same moment armed or unarmed, with the retry loop's own "retry window is
// spent" line instead. The tests share process-global state (storeGiveUp, capReadCache, os.Stderr), so none runs in
// parallel. test-store-giveup-timing.sh --mutate re-runs them against broken copies of main.go and store_giveup.go.

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// giveUpStopLine is the part of logStoreGiveUpOnce's line every case looks for.
const giveUpStopLine = "has not answered for 15s"

// slowDeadFront stands in front of the WHOLE mockCapStore (/caps, /cap and /obj). A request arriving before until is
// held for hold and then its connection is closed with no response, as a dead uplink does after its timeout; from
// until on, requests are proxied to inner. The reverse proxy keeps the incoming Host, so the presigned URLs the mock
// mints point back at the front and the object leg is held or proxied too. The counter is the number of requests
// dropped: a case that wants an outage spanning retries checks it, so a read that never reached the front cannot
// pass vacuously.
func slowDeadFront(t *testing.T, inner *httptest.Server, until time.Time, hold time.Duration) (string, *atomic.Int64) {
	t.Helper()
	u, err := url.Parse(inner.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(u)
	stop := make(chan struct{})
	var dropped atomic.Int64
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !time.Now().Before(until) {
			proxy.ServeHTTP(w, r)
			return
		}
		dropped.Add(1)
		select {
		case <-time.After(hold):
		case <-stop:
		}
		if hj, ok := w.(http.Hijacker); ok {
			if c, _, err := hj.Hijack(); err == nil {
				c.Close()
			}
		}
	}))
	// Cleanups run last-registered first: release the held handlers, then close the front (Close waits for them).
	t.Cleanup(front.Close)
	t.Cleanup(func() { close(stop) })
	return front.URL, &dropped
}

// giveUpTimingReset clears the give-up state and the cap cache now and when the test ends.
func giveUpTimingReset(t *testing.T) {
	t.Helper()
	resetStoreGiveUpForTest()
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() {
		resetStoreGiveUpForTest()
		capReadCache = map[string]capEntry{}
	})
}

// giveUpTimingVault points this process at inner in cap mode with a funded wallet and fresh local state, and creates
// name/pass there, as TestCapModeCreateVault does. The cap cache is emptied afterwards, so no cached cap targets
// inner directly when the front takes over.
func giveUpTimingVault(t *testing.T, inner *httptest.Server, name, pass string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", inner.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(inner.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	capReadCache = map[string]capEntry{}
	createVault("s3", name, pass)
	if getRef("s3", profileRefV2(name, pass)) == "" {
		t.Fatal("createVault in cap mode did not publish the head pointer")
	}
	capReadCache = map[string]capEntry{}
}

// TestGiveUpTimingRestoreHelper is not a test: it is the agent, re-executed from the test binary by the restore
// cases below, running the real `restore` verb through main() so the arm, the exit code and the log are the ones
// roamd's sign-in sees.
func TestGiveUpTimingRestoreHelper(t *testing.T) {
	a := os.Getenv("NOWHERE_GIVEUP_TIMING_HELPER")
	if a == "" {
		return
	}
	os.Args = append([]string{"nowhere_agent", "restore"}, strings.Split(a, "\n")...)
	main()
	os.Exit(0)
}

// giveUpTimingRestore runs `restore s3 name pass <dest>` in cap mode against gateway, armed as roamd's `in` op arms
// it, and returns the exit code, the combined output and the wall time.
func giveUpTimingRestore(t *testing.T, gateway, name, pass string) (int, string, time.Duration) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestGiveUpTimingRestoreHelper$", "-test.count=1")
	env := []string{
		"NOWHERE_GIVEUP_TIMING_HELPER=" + strings.Join([]string{"s3", name, pass, t.TempDir()}, "\n"),
		"GATEWAY_URL=" + gateway,
		"S3_ACCESS_KEY=",
		"NOWHERE_STORE_GIVEUP=1",
	}
	for _, kv := range os.Environ() {
		k := kv[:strings.IndexByte(kv+"=", '=')]
		switch k {
		case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS",
			"NOWHERE_STORE_GIVEUP", "NOWHERE_WALLET":
			continue // cap mode on gateway alone, no cache, no session state
		}
		env = append(env, kv)
	}
	cmd.Env = env
	start := time.Now()
	out, err := cmd.CombinedOutput()
	elapsed := time.Since(start)
	if err == nil {
		return 0, string(out), elapsed
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		t.Fatalf("running the agent: %v", err)
	}
	return ee.ExitCode(), string(out), elapsed
}

// giveUpTimingBounds is the window a never-answering store must be given up in: no earlier than the window (less a
// second of slack for the attempt that started it), no later than the window plus the one read in flight and two
// seconds for the passphrase derivation and the process around it.
func giveUpTimingBounds(hold time.Duration) (lo, hi time.Duration) {
	return storeGiveUpWindow - time.Second, storeGiveUpWindow + hold + 2*time.Second
}

// giveUpTimingDelete runs a real cap-mode DELETE of name/pass through handleDelete against gateway and returns the
// reply, the session dir, what the run wrote to stderr and the wall time. durRun's dur-alice marker only frames the
// session; the delete itself is deleteForSession on the test's own profile. The log is read from the file durRun
// points os.Stderr at (newRfpEnv's), named from inside the delete: a captureStderr around durRun would see nothing,
// and newRfpEnv's cleanup would then restore os.Stderr to that capture's closed pipe for every later test; one around
// the delete loses what it captured, because a dead store's read panics out of it (handleDelete turns the panic
// into ERR-STORE).
func giveUpTimingDelete(t *testing.T, gateway, wantReboot, name, pass string) (reply, dest, log string, elapsed time.Duration) {
	t.Helper()
	t.Setenv("GATEWAY_URL", gateway)
	t.Setenv("S3_ACCESS_KEY", "")
	if os.Getenv("NOWHERE_STATE") == "" {
		t.Setenv("NOWHERE_STATE", t.TempDir())
	}
	if os.Getenv("NOWHERE_WALLET") == "" {
		wpath := filepath.Join(t.TempDir(), "wallet.json")
		t.Setenv("NOWHERE_WALLET", wpath)
		if err := saveWallet(wpath, &Wallet{}); err != nil {
			t.Fatal(err)
		}
	}
	useTempBindings(t)
	capReadCache = map[string]capEntry{}
	start := time.Now()
	logPath := ""
	reply, dest = durRun(t, wantReboot, func(string, string, string, string, string, []byte) string {
		logPath = os.Stderr.Name()
		return deleteForSession("s3", name, pass, name, pass, nil)
	})
	elapsed = time.Since(start)
	if logPath == "" || logPath == "/dev/stderr" {
		t.Fatalf("the delete ran with os.Stderr = %q, not durRun's log file", logPath)
	}
	b, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	return reply, dest, string(b), elapsed
}

// R1: a sign-in's restore against a store that never answers stops at the window plus one read, prints the stop
// line and exits exitStoreUnreachable (roamd's BLANK NET, the local fallback).
func TestStoreGiveUpTiming_RestoreNeverAnswered(t *testing.T) {
	giveUpTimingReset(t)
	inner, _, _ := mockCapStore(t)
	const hold = 6 * time.Second
	front, dropped := slowDeadFront(t, inner, time.Now().Add(time.Hour), hold)
	code, out, elapsed := giveUpTimingRestore(t, front, "giveuptimingr1", "giveup timing restore one staple")
	t.Logf("restore against a dead store: exit %d after %v, %d request(s) dropped", code, elapsed, dropped.Load())
	if code != exitStoreUnreachable {
		t.Errorf("restore exited %d, want exitStoreUnreachable (%d)\n%s", code, exitStoreUnreachable, out)
	}
	if !strings.Contains(out, giveUpStopLine) {
		t.Errorf("the restore never printed the stop line (%q): the give-up did not fire\n%s", giveUpStopLine, out)
	}
	if lo, hi := giveUpTimingBounds(hold); elapsed < lo || elapsed > hi {
		t.Errorf("restore answered after %v, want within [%v, %v]\n%s", elapsed, lo, hi, out)
	}
}

// R2: a store that comes back inside the window still restores the profile.
func TestStoreGiveUpTiming_RestoreBackInsideTheWindow(t *testing.T) {
	giveUpTimingReset(t)
	inner, _, _ := mockCapStore(t)
	const name, pass = "giveuptimingr2", "giveup timing restore two staple"
	giveUpTimingVault(t, inner, name, pass)
	start := time.Now()
	front, dropped := slowDeadFront(t, inner, start.Add(10*time.Second), 3*time.Second)
	code, out, elapsed := giveUpTimingRestore(t, front, name, pass)
	t.Logf("restore against a store back at 10s: exit %d after %v, %d request(s) dropped", code, elapsed, dropped.Load())
	if code != 0 {
		t.Errorf("restore exited %d, want 0: a store back inside the window was given up\n%s", code, out)
	}
	if n := dropped.Load(); n < 2 {
		t.Errorf("the front dropped %d request(s), want at least 2: the outage never spanned a retry\n%s", n, out)
	}
}

// D1: a DELETE against a store that never answers stops at the window plus one read, prints the stop line, answers
// ERR-STORE and keeps the session.
func TestStoreGiveUpTiming_DeleteNeverAnswered(t *testing.T) {
	giveUpTimingReset(t)
	inner, _, _ := mockCapStore(t)
	const hold = 6 * time.Second
	front, dropped := slowDeadFront(t, inner, time.Now().Add(time.Hour), hold)
	reply, dest, log, elapsed := giveUpTimingDelete(t, front, "", "giveuptimingd1", "giveup timing delete one staple")
	t.Logf("delete against a dead store: %q after %v, %d request(s) dropped", reply, elapsed, dropped.Load())
	if reply != "ERR-STORE" {
		t.Errorf("reply %q, want ERR-STORE\n%s", reply, log)
	}
	durWantKept(t, dest)
	if !strings.Contains(log, giveUpStopLine) {
		t.Errorf("the delete never printed the stop line (%q): the give-up did not fire\n%s", giveUpStopLine, log)
	}
	if lo, hi := giveUpTimingBounds(hold); elapsed < lo || elapsed > hi {
		t.Errorf("delete answered after %v, want within [%v, %v]\n%s", elapsed, lo, hi, log)
	}
}

// D2: a DELETE against a store that comes back inside the window still deletes, and queues the session's reap as the
// "deleted" verdict of TestDeleteUnreachable_OtherVerdictsUnchanged does.
func TestStoreGiveUpTiming_DeleteBackInsideTheWindow(t *testing.T) {
	giveUpTimingReset(t)
	inner, _, _ := mockCapStore(t)
	const name, pass = "giveuptimingd2", "giveup timing delete two staple"
	giveUpTimingVault(t, inner, name, pass)
	start := time.Now()
	front, dropped := slowDeadFront(t, inner, start.Add(10*time.Second), 3*time.Second)
	reply, _, log, elapsed := giveUpTimingDelete(t, front, "delete reap NOT consumed", name, pass)
	t.Logf("delete against a store back at 10s: %q after %v, %d request(s) dropped", reply, elapsed, dropped.Load())
	if reply != "OK" {
		t.Errorf("reply %q, want OK: a store back inside the window was given up\n%s", reply, log)
	}
	if sw, rp := mbQueue(); sw != mbUID || rp != mbUID {
		t.Errorf("reap queue = (%q, %q), want both %q", sw, rp, mbUID)
	}
	if n := dropped.Load(); n < 2 {
		t.Errorf("the front dropped %d request(s), want at least 2: the outage never spanned a retry\n%s", n, log)
	}
}
