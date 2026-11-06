package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// NWP-20261101-04 (Q087): while a roamed session is live (.roamsession stands), CREATE and CREATE-CODE answer
// ERR-LIVE before the store, the gateway or the enrollment bucket is touched, whatever was typed.

const clMarker = "liveprofile\nlive profile passphrase\n11\n\n"

// clSpy puts a request-counting proxy in front of createCodeEnv's gateway and returns the paths it saw.
func clSpy(t *testing.T) func() []string {
	t.Helper()
	target, err := url.Parse(os.Getenv("GATEWAY_URL"))
	if err != nil || target.Host == "" {
		t.Fatalf("no gateway to spy on: %v", err)
	}
	var mu sync.Mutex
	var seen []string
	rp := httputil.NewSingleHostReverseProxy(target)
	spy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.URL.Path)
		mu.Unlock()
		rp.ServeHTTP(w, r)
	}))
	t.Cleanup(spy.Close)
	t.Setenv("GATEWAY_URL", spy.URL)
	capReadCache = map[string]capEntry{}
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), seen...)
	}
}

func clMark(t *testing.T, dest string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte(clMarker), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCreateLive_BothVerbsRefuseAndTouchNothing(t *testing.T) {
	dest, wpath := createCodeEnv(t, "LIVECODELIVECODELIVECODE", 3)
	seen := clSpy(t)
	fundWallet(t, wpath, 4)
	walletBefore, _ := os.ReadFile(wpath)
	clMark(t, dest)
	t.Setenv("NOWHERE_ENROLL_MAX", "1") // one enrollment in the bucket: a refused create must not spend it
	blobCache, contentCache = nil, nil
	before := len(seen()) // fundWallet's own wallet traffic is setup, not the create
	const n, p = "livecreate-a", "a passphrase for the live-create case"

	for _, c := range []struct {
		verb string
		run  func(net.Conn)
	}{
		{"CREATE", func(c net.Conn) { handleCreate(c, dest, n, p) }},
		{"CREATE-CODE", func(c net.Conn) { handleCreateCode(c, dest, n, p, "LIVECODELIVECODELIVECODE") }},
	} {
		if got := verb(c.run); got != "ERR-LIVE" {
			t.Errorf("%s over a live session replied %q, want ERR-LIVE", c.verb, got)
		}
	}
	if got := seen()[before:]; len(got) != 0 {
		t.Errorf("a refused create reached the store/gateway: %v", got)
	}
	if b, err := os.ReadFile(filepath.Join(dest, roamSessionFile)); err != nil || string(b) != clMarker {
		t.Errorf("the live session's marker was disturbed: %q (err %v)", b, err)
	}
	if b, err := os.ReadFile(wpath); err != nil || string(b) != string(walletBefore) {
		t.Errorf("a refused create touched the wallet (err %v)", err)
	}
	if _, err := os.Stat(createStagingPath(n, p)); err == nil {
		t.Error("a refused CREATE-CODE staged a claim -- the code was drained")
	}
	if ok, _ := enrollAllow(); !ok {
		t.Error("a refused create spent the enrollment bucket")
	}
}

// With no marker the guard is inert: CREATE reaches its normal precheck answer.
func TestCreateLive_InertWithoutAMarker(t *testing.T) {
	dest, _ := createCodeEnv(t, "LIVECODELIVECODELIVECODE", 3)
	t.Setenv("GATEWAY_URL", "")
	blobCache, contentCache = nil, nil
	if got := verb(func(c net.Conn) { handleCreate(c, dest, "livecreate-b", "a passphrase for the inert case") }); got != "NOSTORE" {
		t.Errorf("CREATE with no marker and no store replied %q, want NOSTORE", got)
	}
}

// The reply consults nothing typed: two different pairs (and a blank one) get the same bytes.
func TestCreateLive_ReplyIsTheSameForEveryCredential(t *testing.T) {
	dest, _ := createCodeEnv(t, "LIVECODELIVECODELIVECODE", 3)
	clMark(t, dest)
	var first string
	for i, c := range [][2]string{{"livecreate-c", "first passphrase for the same-reply case"}, {"livecreate-d", "second passphrase, different"}, {"", ""}} {
		a := verb(func(x net.Conn) { handleCreate(x, dest, c[0], c[1]) })
		b := verb(func(x net.Conn) { handleCreateCode(x, dest, c[0], c[1], "LIVECODELIVECODELIVECODE") })
		if i == 0 {
			first = a
		}
		if a != "ERR-LIVE" || b != "ERR-LIVE" || a != first {
			t.Errorf("pair %d: CREATE %q, CREATE-CODE %q, want ERR-LIVE for both", i, a, b)
		}
	}
	if strings.Contains(first, "livecreate") {
		t.Errorf("the reply %q names a typed profile", first)
	}
}
