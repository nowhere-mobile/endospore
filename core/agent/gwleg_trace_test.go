package main

// NWP-20261203-14: the gateway leg of a store read names the stage a failed request stopped in, with fixed words and
// integers only. Each test uses its own listener and a fresh cloned transport, so no pool state is shared.

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// gwLegClient is a 300 ms client over a fresh transport, traced by lt.
func gwLegClient(t *testing.T, lt *gwLegTrace, tune func(tr *http.Transport)) *http.Client {
	t.Helper()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	if tune != nil {
		tune(tr)
	}
	t.Cleanup(tr.CloseIdleConnections)
	return &http.Client{Timeout: 300 * time.Millisecond, Transport: lt.wrap(tr)}
}

// gwLegServer serves h until the test ends. A blocking handler waits on the returned channel, which closes before
// the server does (Cleanup runs last-in first-out).
func gwLegServer(t *testing.T, h func(n int64, w http.ResponseWriter, r *http.Request, release <-chan struct{})) *httptest.Server {
	t.Helper()
	release := make(chan struct{})
	var n atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h(n.Add(1), w, r, release)
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release) })
	return srv
}

func gwLegBlock(r *http.Request, release <-chan struct{}) {
	select {
	case <-release:
	case <-r.Context().Done():
	}
}

// gwLegSilentListener accepts connections and never writes to them.
func gwLegSilentListener(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var conns []net.Conn
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, c)
			mu.Unlock()
		}
	}()
	t.Cleanup(func() {
		ln.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, c := range conns {
			c.Close()
		}
	})
	return ln
}

// gwLegFailedLine makes one GET that must fail and returns the trace's line for it.
func gwLegFailedLine(t *testing.T, lt *gwLegTrace, c *http.Client, url string) (string, error) {
	t.Helper()
	t0 := time.Now()
	resp, err := c.Get(url)
	if err == nil {
		resp.Body.Close()
		t.Fatalf("the request succeeded; the test needs it to fail")
	}
	return lt.line(err, time.Since(t0)), err
}

func gwLegWant(t *testing.T, l string, parts ...string) {
	t.Helper()
	for _, p := range parts {
		if !strings.Contains(l, p) {
			t.Errorf("line %q does not hold %q", l, p)
		}
	}
}

func TestGwLegResponseWait(t *testing.T) {
	srv := gwLegServer(t, func(_ int64, _ http.ResponseWriter, r *http.Request, release <-chan struct{}) {
		gwLegBlock(r, release)
	})
	lt := &gwLegTrace{}
	l, _ := gwLegFailedLine(t, lt, gwLegClient(t, lt, nil), srv.URL+"/caps")
	if !strings.HasPrefix(l, "  cap gateway leg failed after ") {
		t.Errorf("line %q does not start with the fixed prefix", l)
	}
	gwLegWant(t, l, "stage=response-wait ", "conn=new ", "proto=http/1.1 ", "class=timeout ")
}

func TestGwLegReused(t *testing.T) {
	srv := gwLegServer(t, func(n int64, w http.ResponseWriter, r *http.Request, release <-chan struct{}) {
		if n == 1 {
			w.WriteHeader(http.StatusOK)
			io.WriteString(w, "ok")
			return
		}
		gwLegBlock(r, release)
	})
	lt := &gwLegTrace{}
	c := gwLegClient(t, lt, nil)
	resp, err := c.Get(srv.URL + "/caps")
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	l, _ := gwLegFailedLine(t, lt, c, srv.URL+"/caps")
	gwLegWant(t, l, "stage=response-wait ", "conn=reused ", "class=timeout ")
}

func TestGwLegTLS(t *testing.T) {
	ln := gwLegSilentListener(t)
	lt := &gwLegTrace{}
	l, _ := gwLegFailedLine(t, lt, gwLegClient(t, lt, nil), "https://"+ln.Addr().String()+"/caps")
	gwLegWant(t, l, "stage=tls ", "conn=none ", "proto=none ", "class=timeout ")
}

func TestGwLegRefused(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	lt := &gwLegTrace{}
	l, _ := gwLegFailedLine(t, lt, gwLegClient(t, lt, nil), "http://"+addr+"/caps")
	gwLegWant(t, l, "stage=dial ", "conn=none ", "class=refused ")
}

// TestGwLegFallbackDNS replays the hooks of boundDialContext's fallback: the tcp4 lookup succeeds, the tcp4
// connect is refused, and the family-agnostic dial's second lookup stalls. The line must name the pending lookup,
// not the refused connect. No socket: the round tripper fires the trace hooks itself.
func TestGwLegFallbackDNS(t *testing.T) {
	lt := &gwLegTrace{}
	rt := lt.wrap(gwLegRoundTripper(func(req *http.Request) (*http.Response, error) {
		ct := httptrace.ContextClientTrace(req.Context())
		ct.GetConn("gw:443")
		ct.DNSStart(httptrace.DNSStartInfo{Host: "gw"})
		ct.DNSDone(httptrace.DNSDoneInfo{})
		ct.ConnectStart("tcp4", "192.0.2.1:443")
		ct.ConnectDone("tcp4", "192.0.2.1:443", syscall.ECONNREFUSED)
		ct.DNSStart(httptrace.DNSStartInfo{Host: "gw"})
		return nil, context.DeadlineExceeded
	}))
	req, err := http.NewRequest(http.MethodPost, "https://gw/caps", nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = rt.RoundTrip(req)
	l := lt.line(err, time.Second)
	gwLegWant(t, l, "stage=dns ", "conn=none ", "class=timeout ")
}

func TestGwLegAnswered(t *testing.T) {
	srv := gwLegServer(t, func(_ int64, w http.ResponseWriter, _ *http.Request, _ <-chan struct{}) {
		w.WriteHeader(http.StatusOK)
	})
	lt := &gwLegTrace{}
	resp, err := gwLegClient(t, lt, nil).Get(srv.URL + "/caps")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	l := lt.line(errors.New("gwleg test"), time.Millisecond)
	gwLegWant(t, l, "stage=answered ", "conn=new ", "class=other ")
}

func TestGwLegStreak(t *testing.T) {
	gwLegFailStreak.Store(0)
	t.Cleanup(func() { gwLegFailStreak.Store(0) })
	lt := &gwLegTrace{}
	fail := errors.New("gwleg test")
	want := []string{"streak=1", "streak=2", "", "streak=1"}
	for i, err := range []error{fail, fail, nil, fail} {
		l := lt.line(err, time.Millisecond)
		switch {
		case want[i] == "" && l != "":
			t.Errorf("call %d: a success gave %q, want an empty line", i+1, l)
		case want[i] != "" && !strings.HasSuffix(l, " "+want[i]):
			t.Errorf("call %d: line %q does not end with %q", i+1, l, want[i])
		}
	}
}

func TestGwLegClearPerRoundTrip(t *testing.T) {
	srv := gwLegServer(t, func(n int64, w http.ResponseWriter, r *http.Request, release <-chan struct{}) {
		if n == 1 {
			http.NotFound(w, r)
			return
		}
		gwLegBlock(r, release)
	})
	lt := &gwLegTrace{}
	c := gwLegClient(t, lt, nil)
	resp, err := c.Post(srv.URL+"/caps", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("first request: status %d, want 404", resp.StatusCode)
	}
	l, _ := gwLegFailedLine(t, lt, c, srv.URL+"/cap")
	gwLegWant(t, l, "stage=response-wait ")
	if strings.Contains(l, "stage=answered") {
		t.Errorf("line %q describes the first request, not the last", l)
	}
}

func TestGwLegPrivacy(t *testing.T) {
	const host = "gwsentinel.invalid"
	const hex = "5e4f0c1d2b3a49586776859483a2b1c0d9e8f7061524334251607f8e9dacbfe1"
	ln := gwLegSilentListener(t)
	lt := &gwLegTrace{}
	c := gwLegClient(t, lt, func(tr *http.Transport) {
		tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, ln.Addr().String())
		}
	})
	l, err := gwLegFailedLine(t, lt, c, "https://"+host+"/"+hex)
	if !strings.Contains(err.Error(), host) || !strings.Contains(err.Error(), hex) {
		t.Fatalf("the error text does not hold the host and the hex, so this test proves nothing: %v", err)
	}
	if strings.Contains(l, host) || strings.Contains(l, hex) {
		t.Errorf("line %q leaks the host or the path", l)
	}
	gwLegWant(t, l, "stage=tls ", "class=timeout ")
}

func TestGwLegWiredIntoCapReadURL(t *testing.T) {
	body := strings.Join(stripComments(funcBody(t, agentSources(t)["main.go"], "capReadURL")), "\n")
	for _, want := range []string{".wrap(http.DefaultTransport)", ".line(err,"} {
		if !strings.Contains(body, want) {
			t.Errorf("capReadURL does not hold %q: its gateway leg is not traced or not logged", want)
		}
	}
}
