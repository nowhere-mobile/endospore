package main

// index_verbs_exec_test.go -- SEARCH-APPS, REFRESH-INDEX and REFRESH-CATALOG executed through their handlers over a
// pipe (NWP-20261127-17). Before this file no test sent SEARCH-APPS or REFRESH-INDEX: TestSearchSanitize copied the
// handler's strip and called searchIndex, so a broken handler passed. The cases pin the rune-boundary query cut, the
// "entries":[] reply for a no-match query, the reply's byte count, and refresh-off classified by errRefreshOff, never
// by an error's text (a failed fetch from a URL whose path holds "disabled" or "no source" answered NONE).
// test-index-verbs-exec.sh --mutate breaks each fix in turn and requires these tests to convict it.

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

// searchAppsReply drives handleSearchApps over a pipe and returns its header line and every byte after it.
func searchAppsReply(t *testing.T, query string) (string, []byte) {
	t.Helper()
	srv, cli := net.Pipe()
	defer cli.Close()
	cli.SetDeadline(time.Now().Add(10 * time.Second)) // hang guard only, never a timing assertion
	go func() {
		handleSearchApps(srv, query)
		srv.Close()
	}()
	br := bufio.NewReader(cli)
	header, err := br.ReadString('\n')
	if err != nil {
		t.Fatalf("no reply header from handleSearchApps: %v", err)
	}
	body, err := io.ReadAll(br)
	if err != nil {
		t.Fatalf("reading the handleSearchApps reply body: %v", err)
	}
	return strings.TrimSuffix(header, "\n"), body
}

var searchHeaderRe = regexp.MustCompile(`^OK ([0-9]+)$`)

// decodeSearch checks the "OK <n>" header, that n is the JSON's byte count, and decodes the JSON.
func decodeSearch(t *testing.T, header string, body []byte) searchReply {
	t.Helper()
	m := searchHeaderRe.FindStringSubmatch(header)
	if m == nil {
		t.Fatalf("SEARCH-APPS header = %q, want \"OK <n>\"", header)
	}
	if n, _ := strconv.Atoi(m[1]); n != len(body) {
		t.Fatalf("SEARCH-APPS header says %d bytes, the JSON is %d bytes", n, len(body))
	}
	var rep searchReply
	if err := json.Unmarshal(body, &rep); err != nil {
		t.Fatalf("SEARCH-APPS reply is not JSON: %v (%q)", err, body)
	}
	return rep
}

// withSearchCatalogData points catalogDataPath into a test dir, so no host file adds curated entries; withIndexKey
// redirects catalogSystemPath only.
func withSearchCatalogData(t *testing.T) {
	t.Helper()
	old := catalogDataPath
	catalogDataPath = filepath.Join(t.TempDir(), "catalog-data.json")
	t.Cleanup(func() { catalogDataPath = old })
}

// refreshIndexReply drives handleRefreshIndex over a pipe and returns its one reply line.
func refreshIndexReply(t *testing.T) string {
	t.Helper()
	srv, cli := net.Pipe()
	defer cli.Close()
	cli.SetDeadline(time.Now().Add(10 * time.Second)) // hang guard only
	go func() {
		handleRefreshIndex(srv)
		srv.Close()
	}()
	line, err := bufio.NewReader(cli).ReadString('\n')
	if err != nil {
		t.Fatalf("no reply from handleRefreshIndex: %v", err)
	}
	return strings.TrimSuffix(line, "\n")
}

func TestIndexVerbs_SearchCutKeepsWholeRunes(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	withSearchCatalogData(t)
	r := "検" // 3 bytes: 34 of them are 102 bytes, and a 100-byte cut ends in a partial rune
	want := strings.Repeat(r, 33)
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 1, Entries: []catalogEntry{idxEntry("org.runecut", want, 1)}})

	header, body := searchAppsReply(t, strings.Repeat(r, 34))
	rep := decodeSearch(t, header, body)
	if !utf8.ValidString(rep.Query) {
		t.Fatalf("the reply's query is not valid UTF-8: %q", rep.Query)
	}
	if n := utf8.RuneCountInString(rep.Query); n != 33 || rep.Query != want {
		t.Fatalf("the reply's query has %d runes (%q), want the 33 whole runes", n, rep.Query)
	}
	if len(rep.Query) > searchMaxQuery {
		t.Fatalf("the reply's query is %d bytes, want at most %d", len(rep.Query), searchMaxQuery)
	}
	found := false
	for _, e := range rep.Entries {
		found = found || e.Pkg == "org.runecut"
	}
	if !found {
		t.Fatalf("the entry labelled with the 33 runes was not found: %+v", rep.Entries)
	}
}

func TestIndexVerbs_SearchNoMatchIsEmptyArray(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	withSearchCatalogData(t)
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: 1, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})

	header, body := searchAppsReply(t, "zzqqnomatch")
	rep := decodeSearch(t, header, body)
	if !bytes.Contains(body, []byte(`"entries":[]`)) || bytes.Contains(body, []byte(`"entries":null`)) {
		t.Fatalf("a no-match query must answer \"entries\":[], got %s", body)
	}
	if len(rep.Entries) != 0 {
		t.Fatalf("a no-match query returned %d entries", len(rep.Entries))
	}
}

func TestIndexVerbs_RefreshIndexNoKeyIsNONE(t *testing.T) {
	_, _, restore := withIndexKey(t)
	defer restore()
	indexPubKey = "" // restore puts the key back
	srv, hits := countingCatalogServer(t, notFound)
	useCatalogClient(t, srv.Client())
	t.Setenv("INDEX_URL", srv.URL+"/index.json")
	t.Setenv("GATEWAY_URL", "")
	if reply := refreshIndexReply(t); reply != "NONE" {
		t.Fatalf("REFRESH-INDEX with no index key answered %q, want NONE", reply)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("REFRESH-INDEX with no index key sent %d request(s)", n)
	}
}

func TestIndexVerbs_RefreshIndexNoSourceIsNONE(t *testing.T) {
	_, _, restore := withIndexKey(t)
	defer restore()
	t.Setenv("INDEX_URL", "")
	t.Setenv("GATEWAY_URL", "")
	if reply := refreshIndexReply(t); reply != "NONE" {
		t.Fatalf("REFRESH-INDEX with no INDEX_URL or GATEWAY_URL answered %q, want NONE", reply)
	}
}

func TestIndexVerbs_RefreshIndexFetchFailIsERR(t *testing.T) {
	_, _, restore := withIndexKey(t)
	defer restore()
	srv, _ := countingCatalogServer(t, func(w http.ResponseWriter, r *http.Request) { http.Error(w, "boom", 500) })
	useCatalogClient(t, srv.Client())
	t.Setenv("INDEX_URL", srv.URL+"/index.json")
	t.Setenv("GATEWAY_URL", "")
	if reply := refreshIndexReply(t); reply != "ERR" {
		t.Fatalf("REFRESH-INDEX against a server answering 500 answered %q, want ERR", reply)
	}
}

func TestIndexVerbs_RefreshIndexNewerSignedIsOK(t *testing.T) {
	priv, _, restore := withIndexKey(t)
	defer restore()
	now := time.Now().Unix()
	writeSignedIndex(t, indexSystemPath, priv, catalog{Schema: 1, Generated: now - 3600, Entries: []catalogEntry{idxEntry("a.b", "A", 1)}})
	body, _ := json.Marshal(catalog{Schema: 1, Generated: now, Entries: []catalogEntry{idxEntry("a.b", "A", 2)}})
	sig := ed25519.Sign(priv, body)
	srv, _ := countingCatalogServer(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".sig") {
			w.Write(sig)
		} else {
			w.Write(body)
		}
	})
	useCatalogClient(t, srv.Client())
	t.Setenv("INDEX_URL", srv.URL+"/index.json")
	t.Setenv("GATEWAY_URL", "")
	if reply := refreshIndexReply(t); reply != "OK" {
		t.Fatalf("REFRESH-INDEX against a newer signed index answered %q, want OK", reply)
	}
	resetIndexCaches()
	if g := indexGeneratedOf(loadIndexBytes()); g != now {
		t.Fatalf("REFRESH-INDEX answered OK but the served index has generated=%d, want the fetched %d", g, now)
	}
}

func TestIndexVerbs_RefreshIndexURLWordIsERR(t *testing.T) {
	_, _, restore := withIndexKey(t)
	defer restore()
	srv, hits := countingCatalogServer(t, notFound)
	useCatalogClient(t, srv.Client())
	t.Setenv("INDEX_URL", srv.URL+"/disabled/index.json")
	t.Setenv("GATEWAY_URL", "")
	if reply := refreshIndexReply(t); reply != "ERR" {
		t.Fatalf("REFRESH-INDEX against a 404 from a URL holding \"disabled\" answered %q, want ERR: the URL's word decided the reply", reply)
	}
	if n := atomic.LoadInt32(hits); n == 0 {
		t.Fatal("REFRESH-INDEX sent no request to INDEX_URL")
	}
}

func TestIndexVerbs_RefreshCatalogFetchFailIsERR(t *testing.T) {
	_, _, _, restore := catalogRollbackFixture(t)
	defer restore()
	srv, _ := countingCatalogServer(t, func(w http.ResponseWriter, r *http.Request) { http.Error(w, "boom", 500) })
	useCatalogClient(t, srv.Client())
	t.Setenv("CATALOG_URL", srv.URL+"/catalog.json")
	if reply := refreshCatalogReply(t); reply != "ERR" {
		t.Fatalf("REFRESH-CATALOG against a server answering 500 answered %q, want ERR", reply)
	}
}

func TestIndexVerbs_RefreshCatalogURLWordIsERR(t *testing.T) {
	_, _, _, restore := catalogRollbackFixture(t)
	defer restore()
	srv, hits := countingCatalogServer(t, notFound)
	useCatalogClient(t, srv.Client())
	// A literal space: the client escapes it to %20 on the wire, the error text keeps "no source". Writing %20 here
	// would make the test pass on the old substring classification.
	t.Setenv("CATALOG_URL", srv.URL+"/no source/catalog.json")
	if reply := refreshCatalogReply(t); reply != "ERR" {
		t.Fatalf("REFRESH-CATALOG against a 404 from a URL holding \"no source\" answered %q, want ERR: the URL's word decided the reply", reply)
	}
	if n := atomic.LoadInt32(hits); n == 0 {
		t.Fatal("REFRESH-CATALOG sent no request to CATALOG_URL")
	}
}

// No other test drives handleRefreshCatalog with no baked key; without this case an unwrapped "disabled" return
// (test-index-verbs-exec.sh M7) would answer ERR unseen.
func TestIndexVerbs_RefreshCatalogNoKeyIsNONE(t *testing.T) {
	_, _, _, restore := catalogRollbackFixture(t)
	defer restore()
	catalogPubKey = "" // restore puts the key back
	srv, hits := countingCatalogServer(t, notFound)
	useCatalogClient(t, srv.Client())
	t.Setenv("CATALOG_URL", srv.URL+"/catalog.json")
	if reply := refreshCatalogReply(t); reply != "NONE" {
		t.Fatalf("REFRESH-CATALOG with no signing key answered %q, want NONE", reply)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("REFRESH-CATALOG with no signing key sent %d request(s)", n)
	}
}
