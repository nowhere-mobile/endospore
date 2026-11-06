package main

import (
	"bufio"
	"crypto/ed25519"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261104-13 (Q023): the catalog refresh asks CATALOG_URL and nothing else. A GATEWAY_URL with no CATALOG_URL
// must send no catalog request at all -- the gateway serves no such route, so each store open used to 404.

// countingCatalogServer counts EVERY request before the handler sees it.
func countingCatalogServer(t *testing.T, h http.HandlerFunc) (*httptest.Server, *int32) {
	t.Helper()
	hits := new(int32)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(hits, 1)
		h(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv, hits
}

// refreshCatalogReply drives handleRefreshCatalog over a pipe and returns its one reply line.
func refreshCatalogReply(t *testing.T) string {
	t.Helper()
	srvc, cli := net.Pipe()
	defer cli.Close()
	cli.SetDeadline(time.Now().Add(10 * time.Second))
	go func() {
		handleRefreshCatalog(srvc)
		srvc.Close()
	}()
	line, err := bufio.NewReader(cli).ReadString('\n')
	if err != nil {
		t.Fatalf("no reply from handleRefreshCatalog: %v", err)
	}
	return strings.TrimSuffix(line, "\n")
}

func useCatalogClient(t *testing.T, c *http.Client) {
	t.Helper()
	old := fetchAppHTTP
	fetchAppHTTP = c
	t.Cleanup(func() { fetchAppHTTP = old })
}

func notFound(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) }

func TestCatalogURL_unsetAsksNoGateway(t *testing.T) {
	_, _, data, restore := catalogRollbackFixture(t) // a baked key: without one the refresh is off before it resolves a URL
	defer restore()
	gw, gwHits := countingCatalogServer(t, notFound)
	useCatalogClient(t, gw.Client())
	t.Setenv("GATEWAY_URL", gw.URL)
	t.Setenv("CATALOG_URL", "")
	os.Unsetenv("CATALOG_URL")

	err := refreshCatalog()
	if err == nil || !strings.Contains(err.Error(), "no source") {
		t.Fatalf("refreshCatalog with CATALOG_URL unset = %v, want the no-source error", err)
	}
	if reply := refreshCatalogReply(t); reply != "NONE" {
		t.Fatalf("REFRESH-CATALOG with CATALOG_URL unset answered %q, want NONE", reply)
	}
	if n := atomic.LoadInt32(gwHits); n != 0 {
		t.Fatalf("GATEWAY_URL saw %d request(s): a store open sent a catalog request derived from GATEWAY_URL", n)
	}
	if _, err := os.Stat(data); err == nil {
		t.Fatalf("a catalog was installed at %s although no source was configured", data)
	}
}

func TestCatalogURL_setAsksOnlyCatalogURL(t *testing.T) {
	priv, _, data, restore := catalogRollbackFixture(t)
	defer restore()
	gw, gwHits := countingCatalogServer(t, notFound)
	t.Setenv("GATEWAY_URL", gw.URL)

	fresh := catalogWithGenerated(time.Now().Unix(), "org.catalogurl")
	sig := ed25519.Sign(priv, fresh)
	var mu sync.Mutex
	var paths []string
	cat, _ := countingCatalogServer(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		paths = append(paths, r.URL.Path)
		mu.Unlock()
		switch r.URL.Path {
		case "/catalog.json":
			w.Write(fresh)
		case "/catalog.json.sig":
			w.Write(sig)
		default:
			http.NotFound(w, r)
		}
	})
	useCatalogClient(t, cat.Client())
	t.Setenv("CATALOG_URL", cat.URL+"/catalog.json")

	if err := refreshCatalog(); err != nil {
		t.Fatalf("refreshCatalog with CATALOG_URL set: %v", err)
	}
	got, err := os.ReadFile(data)
	if err != nil || string(got) != string(fresh) {
		t.Fatalf("the signed catalog was not installed at %s (err=%v)", data, err)
	}
	mu.Lock()
	asked := strings.Join(paths, ",")
	mu.Unlock()
	if asked != "/catalog.json,/catalog.json.sig" {
		t.Fatalf("CATALOG_URL server was asked %q, want the catalog then its .sig", asked)
	}
	if reply := refreshCatalogReply(t); reply != "OK" {
		t.Fatalf("REFRESH-CATALOG with CATALOG_URL set answered %q, want OK", reply)
	}
	if n := atomic.LoadInt32(gwHits); n != 0 {
		t.Fatalf("GATEWAY_URL saw %d request(s) although CATALOG_URL was set", n)
	}
}
