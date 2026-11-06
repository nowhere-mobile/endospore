package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261107-03: FETCH-APP's APK download is bounded by a stall timer, a budget and the entry's size, not by the
// store client's 60 s total timeout.

func fabSha(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// fabSetVars saves the download bounds and the client, and restores them when the test ends.
func fabSetVars(t *testing.T, stall time.Duration, maxBytes int64) {
	t.Helper()
	oc, ost, om := fetchAppHTTP, fetchAppStall, fetchAppMaxBytes
	t.Cleanup(func() { fetchAppHTTP, fetchAppStall, fetchAppMaxBytes = oc, ost, om })
	fetchAppStall = stall
	fetchAppMaxBytes = maxBytes
}

func fabNoFiles(t *testing.T, out string) {
	t.Helper()
	for _, p := range []string{out, out + ".part"} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("%s was left behind", p)
		}
	}
}

func TestFetchAppBudget_SlowButMoving(t *testing.T) {
	body := bytes.Repeat([]byte("a"), 32<<10)
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < len(body); i += 2048 {
			w.Write(body[i : i+2048])
			w.(http.Flusher).Flush()
			time.Sleep(40 * time.Millisecond)
		}
	}))
	t.Cleanup(srv.Close)
	fabSetVars(t, 300*time.Millisecond, fetchAppMaxBytes)
	fetchAppHTTP = &http.Client{Timeout: 200 * time.Millisecond, Transport: srv.Client().Transport}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out := filepath.Join(t.TempDir(), "app.apk")
	if err := fetchAndVerify(ctx, srv.URL+"/a.apk", fabSha(body), out, int64(len(body))); err != nil {
		t.Fatalf("a slow download that keeps moving must finish: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil || !bytes.Equal(got, body) {
		t.Fatalf("bytes differ (err=%v, len=%d)", err, len(got))
	}
}

func TestFetchAppBudget_Stall(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(make([]byte, 1024))
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release) }) // registered after srv.Close's, so it runs first
	fabSetVars(t, 200*time.Millisecond, fetchAppMaxBytes)
	out := filepath.Join(t.TempDir(), "app.apk")
	start := time.Now()
	err := fetchAndVerify(context.Background(), srv.URL+"/a.apk", strings.Repeat("0", 64), out, 0)
	if err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("a stalled download must fail fast: err=%v after %v", err, time.Since(start))
	}
	if !strings.Contains(err.Error(), "no data for") {
		t.Errorf("want a stall error, got %v", err)
	}
	fabNoFiles(t, out)
}

func TestFetchAppBudget_Budget(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for r.Context().Err() == nil {
			w.Write([]byte{1})
			w.(http.Flusher).Flush()
			time.Sleep(50 * time.Millisecond)
		}
	}))
	t.Cleanup(srv.Close)
	fabSetVars(t, 30*time.Second, fetchAppMaxBytes)
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out := filepath.Join(t.TempDir(), "app.apk")
	start := time.Now()
	err := fetchAndVerify(ctx, srv.URL+"/a.apk", strings.Repeat("0", 64), out, 0)
	if err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("a trickle must end at the budget: err=%v after %v", err, time.Since(start))
	}
	if !strings.Contains(err.Error(), "budget") {
		t.Errorf("want a budget error, got %v", err)
	}
	fabNoFiles(t, out)
}

func TestFetchAppBudget_OverCatalogSize(t *testing.T) {
	body := bytes.Repeat([]byte("b"), 5000)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(body) }))
	t.Cleanup(srv.Close)
	fabSetVars(t, 5*time.Second, fetchAppMaxBytes)
	out := filepath.Join(t.TempDir(), "app.apk")
	err := fetchAndVerify(context.Background(), srv.URL+"/a.apk", fabSha(body), out, 1000)
	if err == nil || !strings.Contains(err.Error(), "size mismatch") {
		t.Fatalf("a body past the entry's size must be refused as a size mismatch, got %v", err)
	}
	fabNoFiles(t, out)
}

func TestFetchAppBudget_NoStatedSize(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.URL.Query().Get("n"))
		w.Write(bytes.Repeat([]byte("c"), n))
	}))
	t.Cleanup(srv.Close)
	fabSetVars(t, 5*time.Second, 1000)
	for _, tc := range []struct {
		n  int
		ok bool
	}{{2000, false}, {1000, true}} {
		body := bytes.Repeat([]byte("c"), tc.n)
		out := filepath.Join(t.TempDir(), "app.apk")
		err := fetchAndVerify(context.Background(), srv.URL+"/a.apk?n="+strconv.Itoa(tc.n), fabSha(body), out, 0)
		if tc.ok && err != nil {
			t.Errorf("%d bytes (the bound) must be accepted: %v", tc.n, err)
		}
		if !tc.ok {
			if err == nil || !strings.Contains(err.Error(), "size mismatch") {
				t.Errorf("%d bytes must be refused as a size mismatch, got %v", tc.n, err)
			}
			fabNoFiles(t, out)
		}
	}
}

func TestFetchAppBudget_Numbers(t *testing.T) {
	java, err := os.ReadFile("../chooser/src/com/nowhere/chooser/StoreService.java")
	if err != nil {
		t.Fatalf("EXTRACTION FAILED: %v", err)
	}
	m := regexp.MustCompile(`FETCH_APP_CAP_MS = (\d+);`).FindSubmatch(java)
	if m == nil {
		t.Fatal("EXTRACTION FAILED: FETCH_APP_CAP_MS not found in StoreService.java")
	}
	capMs, _ := strconv.Atoi(string(m[1]))
	if need := fetchAppBudget + fetchAppStageAllowance + 60*time.Second; need > time.Duration(capMs)*time.Millisecond {
		t.Errorf("budget + allowance + plan-gate room = %v exceeds FETCH_APP_CAP_MS %dms", need, capMs)
	}
	src, err := os.ReadFile("catalog.go")
	if err != nil {
		t.Fatalf("EXTRACTION FAILED: %v", err)
	}
	s := string(src)
	i := strings.Index(s, "func handleFetchApp(")
	if i < 0 {
		t.Fatal("EXTRACTION FAILED: handleFetchApp not found")
	}
	fn := s[i:]
	if j := strings.Index(fn, "\nfunc "); j >= 0 {
		fn = fn[:j]
	}
	if strings.Contains(fn, "300 * time.Second") {
		t.Error("handleFetchApp's connection deadline is back to 300 s")
	}
	if !strings.Contains(fn, "fetchAppBudget + fetchAppStageAllowance") {
		t.Error("handleFetchApp's connection deadline is not the budget plus the stage allowance")
	}
}
