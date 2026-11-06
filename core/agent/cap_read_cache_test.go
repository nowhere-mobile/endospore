package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// resetCapReadCache empties capReadCache and its sweep state now and when the test ends.
func resetCapReadCache(t *testing.T) {
	t.Helper()
	reset := func() {
		capReadMu.Lock()
		capReadCache = map[string]capEntry{}
		capReadSweptAt = time.Time{}
		capReadMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

func capReadHas(key string) bool {
	capReadMu.Lock()
	defer capReadMu.Unlock()
	_, ok := capReadCache[key]
	return ok
}

func capReadLen() int {
	capReadMu.Lock()
	defer capReadMu.Unlock()
	return len(capReadCache)
}

// capReadGateway answers POST /caps with a cap for every ref asked and a 60 s ttl.
func capReadGateway(t *testing.T) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/caps" {
			http.NotFound(w, r)
			return
		}
		var req struct {
			Refs []string `json:"refs"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		caps := map[string]string{}
		for _, ref := range req.Refs {
			caps[ref] = "https://store.invalid/" + ref
		}
		json.NewEncoder(w).Encode(capsResp{Caps: caps, TTLSeconds: 60})
	}))
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
}

func TestCapReadCache_SweepDropsExpired(t *testing.T) {
	resetCapReadCache(t)
	now := time.Now()
	capReadMu.Lock()
	for i := 0; i < 1000; i++ {
		capReadCache[fmt.Sprintf("old-%d", i)] = capEntry{url: "u", exp: now.Add(-time.Second)}
	}
	for i := 0; i < 10; i++ {
		capReadCache[fmt.Sprintf("live-%d", i)] = capEntry{url: "u", exp: now.Add(time.Minute)}
	}
	capReadPutLocked("new", capEntry{url: "n", exp: now.Add(time.Minute)}, now)
	capReadMu.Unlock()
	if got := capReadLen(); got != 11 {
		t.Fatalf("cache holds %d entries after the sweep, want 11 (10 live + the new one)", got)
	}
	for i := 0; i < 10; i++ {
		if !capReadHas(fmt.Sprintf("live-%d", i)) {
			t.Fatalf("live-%d was swept", i)
		}
	}
	if !capReadHas("new") {
		t.Fatal("the new key was not stored")
	}
}

func TestCapReadCache_SweepKeepsLive(t *testing.T) {
	resetCapReadCache(t)
	now := time.Now()
	capReadMu.Lock()
	capReadCache["edge-live"] = capEntry{url: "u", exp: now.Add(time.Nanosecond)}
	capReadCache["edge-dead"] = capEntry{url: "u", exp: now}
	capReadPutLocked("new", capEntry{url: "n", exp: now.Add(time.Minute)}, now)
	capReadMu.Unlock()
	if !capReadHas("edge-live") {
		t.Fatal("an entry expiring 1 ns after now was swept")
	}
	if capReadHas("edge-dead") {
		t.Fatal("an entry expiring exactly at now survived the sweep")
	}
}

func TestCapReadCache_Throttled(t *testing.T) {
	resetCapReadCache(t)
	now := time.Now()
	live := now.Add(time.Hour)
	capReadMu.Lock()
	capReadPutLocked("first", capEntry{url: "1", exp: live}, now)
	capReadCache["stale"] = capEntry{url: "s", exp: now.Add(time.Second)}
	// stale is expired by the second put's clock, but that put is inside the interval: no sweep.
	capReadPutLocked("second", capEntry{url: "2", exp: live}, now.Add(capReadSweepEvery-time.Nanosecond))
	capReadMu.Unlock()
	if !capReadHas("stale") {
		t.Fatal("a put inside capReadSweepEvery swept")
	}
	capReadMu.Lock()
	capReadPutLocked("third", capEntry{url: "3", exp: live}, now.Add(capReadSweepEvery+time.Nanosecond))
	capReadMu.Unlock()
	if capReadHas("stale") {
		t.Fatal("a put past capReadSweepEvery did not sweep")
	}
}

func TestCapReadCache_PrefetchSweeps(t *testing.T) {
	resetCapReadCache(t)
	capReadGateway(t)
	capReadMu.Lock()
	capReadCache["gone"] = capEntry{url: "u", exp: time.Now().Add(-time.Minute)}
	capReadMu.Unlock()
	prefetchReadCaps([]string{"k1", "k2"})
	if capReadHas("gone") {
		t.Fatal("an expired entry survived prefetchReadCaps")
	}
	if !capReadHas("k1") || !capReadHas("k2") {
		t.Fatal("prefetchReadCaps did not cache both keys")
	}
}

func TestCapReadCache_ReadURLSweeps(t *testing.T) {
	resetCapReadCache(t)
	capReadGateway(t)
	capReadMu.Lock()
	capReadCache["gone"] = capEntry{url: "u", exp: time.Now().Add(-time.Minute)}
	capReadMu.Unlock()
	u, err := capReadURL("k1")
	if err != nil || u == "" {
		t.Fatalf("capReadURL: %q, %v", u, err)
	}
	if capReadHas("gone") {
		t.Fatal("an expired entry survived a capReadURL miss")
	}
	if !capReadHas("k1") {
		t.Fatal("capReadURL did not cache the key")
	}
}
