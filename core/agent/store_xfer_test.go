package main

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261203-10: storeXfer bounds a managed-store chunk transfer by the bytes in flight (store_xfer.go). These
// tests shrink its knobs: floor 200 ms, stall 100 ms, and a min rate of 80 KiB/s, so 64 KiB in flight is worth
// 800 ms and 1 KiB 12.5 ms. storeHTTP gets a Timeout equal to the floor, so a caller reverted to storeHTTP cuts a
// transfer the bound lets land. No test here runs in parallel: storeXferInflight is process-wide, so every check of
// it is a delta.

func storeXferTestKnobs(t *testing.T) {
	t.Helper()
	floor, rate, ceil, stall, client := storeXferFloor, storeXferMinRate, storeXferCeil, storeXferStall, storeHTTP
	t.Cleanup(func() {
		storeXferFloor, storeXferMinRate, storeXferCeil, storeXferStall, storeHTTP = floor, rate, ceil, stall, client
	})
	storeXferFloor = 200 * time.Millisecond
	storeXferStall = 100 * time.Millisecond
	storeXferMinRate = 80 << 10
	storeXferCeil = 5 * time.Second
	storeHTTP = &http.Client{Timeout: 200 * time.Millisecond}
}

// storeXferBlocking starts a server whose handler h may block on the returned channel. The channel closes before
// the server does (Cleanup runs last-in first-out), so srv.Close never waits on a held handler.
func storeXferBlocking(t *testing.T, h func(w http.ResponseWriter, r *http.Request, release <-chan struct{})) *httptest.Server {
	t.Helper()
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { h(w, r, release) }))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release) })
	return srv
}

func TestStoreXferGetSlowStreamLands(t *testing.T) {
	storeXferTestKnobs(t)
	resetCapReadCache(t)
	chunk := bytes.Repeat([]byte("g"), 1<<10)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f := w.(http.Flusher)
		for i := 0; i < 20; i++ { // 20 KiB over 400 ms: past storeHTTP's 200 ms, never 100 ms without a byte
			w.Write(chunk)
			f.Flush()
			time.Sleep(20 * time.Millisecond)
		}
	}))
	t.Cleanup(srv.Close)
	const key = "blob/xfer-slow-get"
	capReadMu.Lock()
	capReadCache[key] = capEntry{url: srv.URL + "/o", exp: time.Now().Add(time.Minute)}
	capReadMu.Unlock()
	var got []byte
	var ok bool
	var perr any
	func() {
		defer func() { perr = recover() }()
		got, ok = capGetMax(key, 64<<10)
	}()
	if perr != nil {
		t.Fatalf("a GET whose bytes flowed for 400 ms failed: %v -- capGetMaxOpt must read through storeXfer, and "+
			"every body Read must restart the stall timer", perr)
	}
	if !ok || !bytes.Equal(got, bytes.Repeat(chunk, 20)) {
		t.Fatalf("capGetMax returned ok=%v and %d bytes, want 20 KiB", ok, len(got))
	}
}

func TestStoreXferPutSlowAnswerLands(t *testing.T) {
	storeXferTestKnobs(t)
	data := bytes.Repeat([]byte("p"), 64<<10)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		time.Sleep(400 * time.Millisecond) // past storeHTTP's 200 ms, inside 64 KiB's 1000 ms
		sum := md5.Sum(b)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	if err := capPutErr("blob/xfer-slow-put", srv.URL+"/o", nil, data, nil); err != nil {
		t.Fatalf("a 64 KiB PUT answered after 400 ms failed: %v -- capPutErrGuarded must send through storeXfer, "+
			"whose deadline counts the bytes in flight", err)
	}
}

func TestStoreXferGetHungHeaders(t *testing.T) {
	storeXferTestKnobs(t)
	srv := storeXferBlocking(t, func(w http.ResponseWriter, r *http.Request, release <-chan struct{}) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/hung", nil)
	resp, err := storeXfer(req, 1<<10)
	if err == nil {
		resp.Body.Close()
		t.Fatal("a GET that never got headers returned no error")
	}
	if !errors.Is(err, errStoreXferStall) {
		t.Fatalf("a GET that never got headers ended with %v, want errStoreXferStall -- the stall timer must start "+
			"before Do, so it bounds the wait for headers", err)
	}
	if strings.Contains(err.Error(), srv.URL) {
		t.Fatalf("the cut names the URL: %v", err)
	}
}

func TestStoreXferDeadlineScales(t *testing.T) {
	if d := storeXferDeadline(0); d != 60*time.Second {
		t.Errorf("storeXferDeadline(0) = %v, want the 60 s floor", d)
	}
	if d := storeXferDeadline(cdcMax); d != 92*time.Second {
		t.Errorf("storeXferDeadline(one 4 MiB chunk) = %v, want 60 s + 32 s", d)
	}
	if one, two := storeXferDeadline(cdcMax), storeXferDeadline(2*cdcMax); two <= one {
		t.Errorf("storeXferDeadline(2 chunks) = %v is not over storeXferDeadline(1 chunk) = %v -- the deadline "+
			"must scale with the bytes in flight", two, one)
	}
}

func TestStoreXferDeadlineCeiling(t *testing.T) {
	if d := storeXferDeadline(24 * cdcMax); d != 10*time.Minute { // unclamped: 60 + 768 = 828 s
		t.Errorf("storeXferDeadline(24 chunks) = %v, want the 10 min ceiling", d)
	}
}

func TestStoreXferDeadlineRechecksInflight(t *testing.T) {
	storeXferTestKnobs(t)
	aIn, bIn, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var bWG sync.WaitGroup
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.ReadAll(r.Body)
		switch r.URL.Path {
		case "/a":
			close(aIn)
			time.Sleep(600 * time.Millisecond) // past A's own 212 ms, inside A + B's 1012 ms
			io.WriteString(w, "a")
		case "/b":
			close(bIn)
			select {
			case <-release:
			case <-r.Context().Done():
			}
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release); bWG.Wait() }) // runs first: B's handler returns, then B, then the server
	type res struct {
		resp *http.Response
		err  error
	}
	aRes := make(chan res, 1)
	go func() {
		req, _ := http.NewRequest(http.MethodPut, srv.URL+"/a", bytes.NewReader(make([]byte, 1<<10)))
		resp, err := storeXfer(req, 1<<10)
		aRes <- res{resp, err}
	}()
	<-aIn
	bWG.Add(1)
	go func() {
		defer bWG.Done()
		req, _ := http.NewRequest(http.MethodPut, srv.URL+"/b", bytes.NewReader(make([]byte, 64<<10)))
		if resp, err := storeXfer(req, 64<<10); err == nil {
			resp.Body.Close()
		}
	}()
	<-bIn
	a := <-aRes
	if a.err != nil {
		t.Fatalf("PUT A, answered after its own deadline but inside the deadline of A plus B in flight, failed: %v "+
			"-- the deadline must be rechecked against the bytes in flight when it fires", a.err)
	}
	b, err := io.ReadAll(a.resp.Body)
	a.resp.Body.Close()
	if err != nil || a.resp.StatusCode != http.StatusOK || string(b) != "a" {
		t.Fatalf("PUT A: status %d, body %q, read error %v", a.resp.StatusCode, b, err)
	}
}

func TestStoreXferContentLengthRearms(t *testing.T) {
	storeXferTestKnobs(t)
	piece := bytes.Repeat([]byte("c"), 4<<10)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(16*len(piece)))
		f := w.(http.Flusher)
		for i := 0; i < 16; i++ { // 64 KiB over 480 ms: past 1 KiB's 212 ms, inside 64 KiB's 1000 ms
			w.Write(piece)
			f.Flush()
			time.Sleep(30 * time.Millisecond)
		}
	}))
	t.Cleanup(srv.Close)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/cl", nil)
	resp, err := storeXfer(req, 1<<10)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("a 64 KiB body streamed past its 1 KiB estimate's deadline failed: %v -- the share must move to "+
			"the ContentLength once headers arrive", err)
	}
	if len(b) != 64<<10 {
		t.Fatalf("read %d bytes, want 64 KiB", len(b))
	}
}

func TestStoreXferReleasesInflight(t *testing.T) {
	storeXferTestKnobs(t)
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	t.Cleanup(ok.Close)
	notFound := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) }))
	t.Cleanup(notFound.Close)
	gone := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	goneURL := gone.URL
	gone.Close() // connection refused: a Do error
	hung := storeXferBlocking(t, func(w http.ResponseWriter, r *http.Request, release <-chan struct{}) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	for _, c := range []struct{ name, url string }{
		{"a 200 read and closed", ok.URL},
		{"a Do error", goneURL},
		{"a stall", hung.URL},
		{"a 404 closed", notFound.URL},
	} {
		before := atomic.LoadInt64(&storeXferInflight)
		req, _ := http.NewRequest(http.MethodGet, c.url+"/r", nil)
		resp, err := storeXfer(req, 8<<10)
		if err == nil {
			io.ReadAll(resp.Body)
			resp.Body.Close()
		}
		if d := atomic.LoadInt64(&storeXferInflight) - before; d != 0 {
			t.Errorf("%s left %d bytes in storeXferInflight (err %v) -- every exit must release its share", c.name, d, err)
		}
	}
}
