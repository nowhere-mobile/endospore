package main

import (
	"archive/zip"
	"bufio"
	"crypto/ed25519"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// iconReply drives handleFetchIcon over a net.Pipe and returns the status line and any body bytes that followed.
func iconReply(t *testing.T, arg string) (string, []byte) {
	t.Helper()
	srvc, cli := net.Pipe()
	go func() {
		handleFetchIcon(srvc, arg)
		srvc.Close()
	}()
	r := bufio.NewReader(cli)
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatalf("no status line for %q: %v", arg, err)
	}
	body, _ := io.ReadAll(r)
	cli.Close()
	return strings.TrimSuffix(line, "\n"), body
}

// iconFixture signs a one-entry catalog whose iconRef is <server>/icon.png and points the package at it.
func iconFixture(t *testing.T, handler func(w http.ResponseWriter, r *http.Request)) (srvURL, iconURL, dir string, hits *int32) {
	t.Helper()
	priv, restore := withCatalogKey(t)
	t.Cleanup(restore)
	hits = new(int32)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(hits, 1)
		handler(w, r)
	}))
	t.Cleanup(srv.Close)
	saved := fetchAppHTTP
	fetchAppHTTP = srv.Client()
	t.Cleanup(func() { fetchAppHTTP = saved })

	dir = t.TempDir()
	iconURL = srv.URL + "/icon.png"
	manifest := []byte(fmt.Sprintf(`{"schema":1,"entries":[{"pkg":"com.example.app","iconRef":%q}]}`, iconURL))
	catalogSystemPath = filepath.Join(dir, "catalog.json")
	catalogDataPath = filepath.Join(dir, "catalog-data.json")
	os.WriteFile(catalogSystemPath, manifest, 0o600)
	os.WriteFile(catalogSystemPath+".sig", ed25519.Sign(priv, manifest), 0o600)
	return srv.URL, iconURL, dir, hits
}

func TestFetchIconAllowList(t *testing.T) {
	body := []byte("\x89PNGicon-bytes")
	srvURL, iconURL, _, hits := iconFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/icon.png" && r.URL.RawQuery == "" {
			w.Write(body)
			return
		}
		w.Write([]byte("attacker-reachable"))
	})

	st, got := iconReply(t, iconURL)
	if st != fmt.Sprintf("OK %d", len(body)) || string(got) != string(body) {
		t.Fatalf("catalog icon: got %q %q", st, got)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("expected 1 request for the allowed URL, got %d", n)
	}

	atomic.StoreInt32(hits, 0)
	for _, u := range []string{srvURL + "/other.png", iconURL + "?x=1", iconURL + "/", "http://127.0.0.1:1/x", strings.Replace(iconURL, "http://", "https://", 1)} {
		if st, got := iconReply(t, u); st != "NONE" || len(got) != 0 {
			t.Fatalf("%q must be NONE, got %q %q", u, st, got)
		}
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("server saw %d requests for non-catalog URLs", n)
	}
}

func TestFetchIconUnsignedOverrideIgnored(t *testing.T) {
	srvURL, _, _, hits := iconFixture(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("x")) })
	evil := srvURL + "/evil.png"
	os.WriteFile(catalogDataPath, []byte(fmt.Sprintf(`{"schema":1,"entries":[{"pkg":"evil","iconRef":%q}]}`, evil)), 0o600)
	if st, _ := iconReply(t, evil); st != "NONE" {
		t.Fatalf("unsigned override honored: %q", st)
	}
	// a data catalog with a wrong signature is no better
	os.WriteFile(catalogDataPath+".sig", []byte("bogus"), 0o600)
	if st, _ := iconReply(t, evil); st != "NONE" {
		t.Fatalf("badly signed override honored: %q", st)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("server saw %d requests", n)
	}
}

func TestFetchIconUpstreamErrorAndCap(t *testing.T) {
	const iconCap = 1 << 20
	size := 0
	status := http.StatusOK
	_, iconURL, _, _ := iconFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		w.Write(make([]byte, size))
	})

	status = http.StatusNotFound
	if st, got := iconReply(t, iconURL); st != "ERR" || len(got) != 0 {
		t.Fatalf("404: got %q %q", st, got)
	}
	status = http.StatusOK

	size = iconCap
	if st, got := iconReply(t, iconURL); st != "OK 1048576" || len(got) != iconCap {
		t.Fatalf("exactly 1 MiB: got %q, %d bytes", st, len(got))
	}
	size = iconCap + 1
	if st, got := iconReply(t, iconURL); st != "ERR" || len(got) != 0 {
		t.Fatalf("1 MiB + 1: got %q, %d bytes", st, len(got))
	}
}

func TestFetchIconPackPath(t *testing.T) {
	_, _, _, hits := iconFixture(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("net")) })
	sp := iconPackPath
	iconPackPath = filepath.Join(t.TempDir(), "icons.pack")
	resetIndexCaches()
	t.Cleanup(func() { iconPackPath = sp; resetIndexCaches() })

	f, err := os.Create(iconPackPath)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	for pkg, data := range map[string]string{"com.foo.bar": "icon-bar", "httpx.app": "icon-httpx"} {
		w, _ := zw.Create(pkg)
		w.Write([]byte(data))
	}
	zw.Close()
	f.Close()

	for pkg, data := range map[string]string{"com.foo.bar": "icon-bar", "httpx.app": "icon-httpx"} {
		if st, got := iconReply(t, pkg); st != fmt.Sprintf("OK %d", len(data)) || string(got) != data {
			t.Fatalf("pack icon %s: got %q %q", pkg, st, got)
		}
	}
	if st, _ := iconReply(t, "not.in.pack"); st != "NONE" {
		t.Fatalf("missing pkg: %q", st)
	}
	if st, _ := iconReply(t, ""); st != "NONE" {
		t.Fatalf("empty arg: %q", st)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("pack path made %d network requests", n)
	}
}
