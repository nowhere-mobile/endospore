package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261011-25: the remembered-PIN read at roam-in must tell a FAILED read from a profile with no PIN, survive a
// transient store failure through the read path's own retry, and say so loudly when it does not.

const pinReadName, pinReadPass, pinReadPIN = "pinread", "correct horse battery staple", "246810"

// pinReadCapStore stands up a cap-mode gateway + object-store double in front of an http store that already holds
// the profile: /cap hands out a presigned URL, /obj serves the http store's object for it. The first dropFirst
// object GETs fail at the TRANSPORT level (the connection is cut mid-body, like a Wi-Fi drop), never with a 5xx.
// Returns a counter of object GETs seen. The profile is written through the http store because cap-mode writes
// need a lease; the keys are the same on both backends (ref/<ref>, blob/<hash>).
func pinReadCapStore(t *testing.T, base string, dropFirst int) *int {
	t.Helper()
	old := s3RetryBase
	s3RetryBase = time.Millisecond // shrink the backoff, as cap_test.go does
	t.Cleanup(func() { s3RetryBase = old })
	var mu sync.Mutex
	gets := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		ref := r.URL.Query().Get("ref")
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)})
	})
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gets++
		n := gets
		mu.Unlock()
		if n <= dropFirst {
			// Headers and part of the body, then the connection dies: the body read fails with an unexpected EOF.
			// Cut mid-body, not before the response, because net/http silently re-sends a GET whose reused
			// connection closes before any byte arrives -- so a pre-response drop is not one attempt of capGet's
			// retry, and a test built on it passes whether or not that retry exists.
			if hj, ok := w.(http.Hijacker); ok {
				if c, buf, err := hj.Hijack(); err == nil {
					buf.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\npartial")
					buf.Flush()
					c.Close()
				}
			}
			return
		}
		resp, err := http.Get(base + "/" + r.URL.Query().Get("k"))
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() { capReadCache = map[string]capEntry{} })
	if !capMode() {
		t.Fatal("capMode should be true with GATEWAY_URL set and no S3 creds")
	}
	return &gets
}

// pinReadProfile creates a vault profile in a fresh http store, with pin set when non-empty.
func pinReadProfile(t *testing.T, pin string) string {
	t.Helper()
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	createVault(base, pinReadName, pinReadPass)
	if pin != "" {
		if err := setStoredPIN(base, pinReadName, pinReadPass, pin, nil); err != nil {
			t.Fatalf("setStoredPIN: %v", err)
		}
	}
	return base
}

// (a) Two object GETs dropped mid-flight, then the store serves: the PIN comes back through capGet's own retry.
// Mutation: drop all five attempts and this fails.
func TestStoredPINErrSurvivesTransientCapFailure(t *testing.T) {
	base := pinReadProfile(t, pinReadPIN)
	gets := pinReadCapStore(t, base, 2)
	pin, err := storedPINErr("s3", pinReadName, pinReadPass, nil)
	if err != nil {
		t.Fatalf("a transient store failure must be retried, not surfaced: %v", err)
	}
	if pin != pinReadPIN {
		t.Fatalf("storedPINErr = %q, want the stored PIN", pin)
	}
	if *gets <= 2 {
		t.Fatalf("the double saw %d object GETs; the two drops were not exercised", *gets)
	}
}

// (b) A store that never answers: the read FAILS, distinguishably, and only after the retries ran.
func TestStoredPINErrPermanentFailureIsAnError(t *testing.T) {
	base := pinReadProfile(t, pinReadPIN)
	gets := pinReadCapStore(t, base, 1<<30)
	pin, err := storedPINErr("s3", pinReadName, pinReadPass, nil)
	if err == nil {
		t.Fatal("an unreachable store must return an error, not read as \"no PIN\"")
	}
	if pin != "" {
		t.Fatalf("a failed read returned pin %q", pin)
	}
	if *gets < 5 {
		t.Fatalf("the read gave up after %d GETs; capGet's retry should have made 5", *gets)
	}
	// The http dev store: a transport error panics at once (it has no retry), and still comes back as an error.
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()
	t.Setenv("GATEWAY_URL", "")
	if pin, err := storedPINErr(deadURL, pinReadName, pinReadPass, nil); err == nil || pin != "" {
		t.Fatalf("http dev store unreachable: storedPINErr = (%q, %v), want (\"\", error)", pin, err)
	}
}

// (c) No PIN, an unknown profile and a wrong passphrase are all ("", nil): absence, never an error, so blind
// login is unchanged.
func TestStoredPINErrAbsenceIsNotAnError(t *testing.T) {
	base := pinReadProfile(t, "")
	pinReadCapStore(t, base, 0)
	for _, c := range []struct{ what, name, pass string }{
		{"no PIN set", pinReadName, pinReadPass},
		{"unknown profile", "nobody-here", pinReadPass},
		{"wrong passphrase", pinReadName, "the wrong passphrase"},
	} {
		if pin, err := storedPINErr("s3", c.name, c.pass, nil); pin != "" || err != nil {
			t.Fatalf("%s: storedPINErr = (%q, %v), want (\"\", nil)", c.what, pin, err)
		}
	}
}

// The roam-in seam: a failed read REMOVES a previous profile's stash (fail-closed; it used to unwind past the
// stash and leave it) and prints one FAILED line carrying no name and no PIN. A good read stashes the PIN, silently.
func TestStashRoamInPINFailedReadClearsStashAndSaysSo(t *testing.T) {
	base := pinReadProfile(t, pinReadPIN)
	dest := t.TempDir()
	stash := filepath.Join(dest, ".sessionpin")

	pinReadCapStore(t, base, 1<<30)
	stashSessionPIN(dest, "13579") // the previous profile's
	out := captureStderr(t, func() { stashRoamInPIN(dest, "s3", pinReadName, pinReadPass, nil) })
	if _, err := os.Stat(stash); !os.IsNotExist(err) {
		t.Fatalf("a failed PIN read left a stash behind (stat err %v): a new session inherits it", err)
	}
	if !strings.Contains(out, "remembered-PIN read FAILED") {
		t.Fatalf("no FAILED line on a failed read; stderr:\n%s", out)
	}
	for _, leak := range []string{pinReadName, pinReadPIN, "13579", "X-Amz-"} {
		if strings.Contains(out, leak) {
			t.Fatalf("the FAILED line leaks %q:\n%s", leak, out)
		}
	}

	pinReadCapStore(t, base, 0)
	out = captureStderr(t, func() { stashRoamInPIN(dest, "s3", pinReadName, pinReadPass, nil) })
	if got := sessionPIN(dest); got != pinReadPIN {
		t.Fatalf("a good read stashed %q, want the stored PIN", got)
	}
	if strings.Contains(out, "FAILED") {
		t.Fatalf("a good read logged a failure:\n%s", out)
	}
}
