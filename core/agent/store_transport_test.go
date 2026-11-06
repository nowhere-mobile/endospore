package main

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
)

// NWP-20261011-20: storeTransport is minio's own default transport with ONLY the dialer swapped -- every other
// setting (pooling, timeouts, compression, TLS floor) must still be minio's.
func TestStoreTransportIsMinioDefaultWithBoundDial(t *testing.T) {
	for _, secure := range []bool{true, false} {
		rt, err := storeTransport(secure)
		if err != nil {
			t.Fatalf("storeTransport(%v): %v", secure, err)
		}
		got, ok := rt.(*http.Transport)
		if !ok {
			t.Fatalf("storeTransport(%v) is %T, want *http.Transport", secure, rt)
		}
		if got.DialContext == nil {
			t.Fatalf("storeTransport(%v): DialContext is nil -- minio would dial unbound", secure)
		}
		want, err := minio.DefaultTransport(secure)
		if err != nil {
			t.Fatalf("minio.DefaultTransport(%v): %v", secure, err)
		}
		if got.DisableCompression != want.DisableCompression ||
			got.MaxIdleConns != want.MaxIdleConns ||
			got.MaxIdleConnsPerHost != want.MaxIdleConnsPerHost ||
			got.MaxConnsPerHost != want.MaxConnsPerHost ||
			got.ResponseHeaderTimeout != want.ResponseHeaderTimeout ||
			got.IdleConnTimeout != want.IdleConnTimeout ||
			got.TLSHandshakeTimeout != want.TLSHandshakeTimeout ||
			got.ExpectContinueTimeout != want.ExpectContinueTimeout {
			t.Errorf("storeTransport(%v) differs from minio's default beyond the dialer:\n got %+v\nwant %+v", secure, got, want)
		}
		if (got.TLSClientConfig == nil) != (want.TLSClientConfig == nil) {
			t.Errorf("storeTransport(%v): TLSClientConfig nil=%v, minio's nil=%v", secure, got.TLSClientConfig == nil, want.TLSClientConfig == nil)
		}
		if secure && (got.TLSClientConfig == nil || got.TLSClientConfig.MinVersion != tls.VersionTLS12) {
			t.Errorf("storeTransport(true): TLS floor is not minio's TLS 1.2: %+v", got.TLSClientConfig)
		}
	}
}

// Every minio client must be built with a storeTransport: a minio.New whose Options carry no Transport dials
// unbound (minio's own default, not http.DefaultTransport) -- the two-SIM false-offline class. Text scan of every
// non-test source file: within the 10 lines before each minio.New, a `<v>, err := storeTransport(` assignment;
// within the 10 lines after it (the Options literal), `Transport: <v>,`.
func TestEveryMinioClientUsesStoreTransport(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	assign := regexp.MustCompile(`^\s*(\w+)\s*,\s*\w+\s*:?=\s*storeTransport\(`)
	sites := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(string(b), "\n")
		for i, l := range lines {
			if !strings.Contains(l, "minio.New(") {
				continue
			}
			sites++
			tv := ""
			for j := i - 1; j >= 0 && j >= i-10; j-- {
				if m := assign.FindStringSubmatch(lines[j]); m != nil {
					tv = m[1]
					break
				}
			}
			if tv == "" {
				t.Errorf("%s:%d: minio.New with no storeTransport( assignment in the 10 lines before it", name, i+1)
				continue
			}
			field := regexp.MustCompile(`^\s*Transport:\s*` + regexp.QuoteMeta(tv) + `\s*,`)
			found := false
			for j := i + 1; j < len(lines) && j <= i+10; j++ {
				if field.MatchString(lines[j]) {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("%s:%d: minio.Options literal does not pass Transport: %s (from storeTransport)", name, i+1, tv)
			}
		}
	}
	if sites < 3 {
		t.Fatalf("found %d minio.New call sites, want at least the 3 known (data store, discovery, test-connection)", sites)
	}
}

// The bound dialer's Control hook runs for a minio transport AND for http.DefaultTransport -- one definition,
// shared at runtime -- and the dial goes out tcp4 first.
func TestBoundDialRunsControlHook(t *testing.T) {
	var mu sync.Mutex
	var seen []string
	dialControl = func(network, address string, _ syscall.RawConn) error {
		mu.Lock()
		seen = append(seen, network+" "+address)
		mu.Unlock()
		return nil
	}
	t.Cleanup(func() { dialControl = bindControl })

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	defer srv.Close()
	want := "tcp4 " + strings.TrimPrefix(srv.URL, "http://")
	saw := func() bool {
		mu.Lock()
		defer mu.Unlock()
		for _, s := range seen {
			if s == want {
				return true
			}
		}
		return false
	}
	get := func(rt http.RoundTripper) {
		t.Helper()
		resp, err := (&http.Client{Transport: rt, Timeout: 5 * time.Second}).Get(srv.URL)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
	}

	rt, err := storeTransport(false)
	if err != nil {
		t.Fatal(err)
	}
	get(rt)
	if !saw() {
		t.Fatalf("storeTransport dial did not run the Control hook as %q; saw %v", want, seen)
	}

	mu.Lock()
	seen = nil
	mu.Unlock()
	dt := http.DefaultTransport.(*http.Transport).Clone()
	dt.DisableKeepAlives = true
	get(dt)
	if !saw() {
		t.Fatalf("http.DefaultTransport dial did not run the shared Control hook as %q; saw %v", want, seen)
	}
}
