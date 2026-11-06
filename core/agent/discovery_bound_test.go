package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// NWP-20261109-16: the sign-in discovery lookup runs holding sessionMu (handleRoamIn -> tryDiscover), so it must
// be bounded in time and size, and its stderr must not carry the passphrase-derived ref.

// discoBoundFixture points the DISCO_* env at srv, shortens discoTimeout, and restores the package state.
func discoBoundFixture(t *testing.T, srv *httptest.Server, keyed bool) {
	t.Helper()
	oldTimeout, oldClient, oldBucket := discoTimeout, discoClient, discoBucket
	t.Cleanup(func() { discoTimeout, discoClient, discoBucket = oldTimeout, oldClient, oldBucket })
	discoTimeout = 300 * time.Millisecond
	discoClient = nil
	t.Setenv("DISCO_ENDPOINT", srv.URL)
	t.Setenv("DISCO_BUCKET", "disco-bucket")
	t.Setenv("DISCO_REGION", "")
	if keyed {
		t.Setenv("DISCO_ACCESS_KEY", "AKTEST")
		t.Setenv("DISCO_SECRET_KEY", "SKTEST")
	} else {
		t.Setenv("DISCO_ACCESS_KEY", "")
		t.Setenv("DISCO_SECRET_KEY", "")
	}
}

// stallingServer accepts and never answers until the test releases it. The release is registered AFTER the
// server's Close would run (Cleanup is LIFO), so it runs BEFORE srv.Close, which would otherwise wait on it.
func stallingServer(t *testing.T) *httptest.Server {
	t.Helper()
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release) })
	return srv
}

// lookupWithin runs the discovery lookup and fails the test if it has not returned within 5 s.
func lookupWithin(t *testing.T, name, pass string) (cfg string, ok bool, err error) {
	t.Helper()
	type res struct {
		cfg string
		ok  bool
		err error
	}
	ch := make(chan res, 1)
	go func() { // test-only goroutine; not daemon code
		var r res
		r.err = recovered(func() { r.cfg, r.ok = discoverConfig("disco", name, pass) })
		ch <- r
	}()
	select {
	case r := <-ch:
		return r.cfg, r.ok, r.err
	case <-time.After(5 * time.Second):
		t.Fatal("the discovery lookup did not return within 5 s: it is unbounded and would hold sessionMu forever")
	}
	return "", false, nil
}

func TestDiscoBoundAnonStallIsAMiss(t *testing.T) {
	srv := stallingServer(t)
	discoBoundFixture(t, srv, false)
	if cfg, ok, _ := lookupWithin(t, "discbound-a", "pass-a"); ok || cfg != "" {
		t.Fatalf("a stalled endpoint must be a miss, got %q ok=%v", cfg, ok)
	}
}

func TestDiscoBound403LogsNoRef(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	t.Cleanup(srv.Close)
	discoBoundFixture(t, srv, false)
	name, pass := "discbound-b", "pass-b"
	var ok bool
	out := captureStderr(t, func() { _, ok, _ = lookupWithin(t, name, pass) })
	if ok {
		t.Fatal("a 403 must be a miss")
	}
	ref := bootstrapRef(name, pass)
	if !strings.Contains(out, "403") {
		t.Fatalf("the 403 hint is gone: %q", out)
	}
	if strings.Contains(out, ref) || strings.Contains(out, ref[:12]) {
		t.Fatalf("stderr carries the passphrase-derived ref: %q", out)
	}
}

func TestDiscoBoundOversizeAnswerIsAMiss(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(strings.Repeat("x", int(discoMaxBody)+1)))
	}))
	t.Cleanup(srv.Close)
	discoBoundFixture(t, srv, false)
	if cfg, ok, _ := lookupWithin(t, "discbound-c", "pass-c"); ok || cfg != "" {
		t.Fatalf("an answer over discoMaxBody must be a miss, got %d bytes ok=%v", len(cfg), ok)
	}
}

// An endless answer must stop at the cap, not be read until the timeout: with the cap the lookup returns at
// once; without it the read runs the whole (here 2 s) discoTimeout.
func TestDiscoBoundEndlessAnswerStopsAtTheCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		chunk := []byte(strings.Repeat("x", 512))
		for end := time.Now().Add(5 * time.Second); time.Now().Before(end) && r.Context().Err() == nil; {
			if _, err := w.Write(chunk); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(time.Millisecond)
		}
	}))
	t.Cleanup(srv.Close)
	discoBoundFixture(t, srv, false)
	oldMax := discoMaxBody
	t.Cleanup(func() { discoMaxBody = oldMax })
	discoMaxBody = 1024
	discoTimeout = 2 * time.Second
	start := time.Now()
	if _, ok, _ := lookupWithin(t, "discbound-e", "pass-e"); ok {
		t.Fatal("an endless answer must be a miss")
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("the lookup read an endless answer for %v instead of stopping at discoMaxBody", d)
	}
}

func TestDiscoBoundKeyedStallReturns(t *testing.T) {
	srv := stallingServer(t)
	discoBoundFixture(t, srv, true)
	if cfg, ok, _ := lookupWithin(t, "discbound-d", "pass-d"); ok || cfg != "" {
		t.Fatalf("a stalled endpoint must be a miss, got %q ok=%v", cfg, ok)
	}
}
