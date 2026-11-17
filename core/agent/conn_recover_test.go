package main

// NWP-20261203-21: the shared transport pings HTTP/2, and a timed-out store read drops the pooled idle conns.
// No assertion here bounds wall time: a dead-conn conviction is by error class (the deadline, or not).

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
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

func TestSharedTransportPingsHTTP2(t *testing.T) {
	tr, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		t.Fatalf("http.DefaultTransport is %T, not *http.Transport", http.DefaultTransport)
	}
	if tr.HTTP2 == nil {
		t.Fatal("http.DefaultTransport.HTTP2 is nil: a pooled h2 conn on a dead path is never pinged and never closed")
	}
	if h2PingIdle <= 0 || tr.HTTP2.SendPingTimeout != h2PingIdle {
		t.Errorf("SendPingTimeout = %v, want h2PingIdle (%v) > 0", tr.HTTP2.SendPingTimeout, h2PingIdle)
	}
	if h2PingWait <= 0 || tr.HTTP2.PingTimeout != h2PingWait {
		t.Errorf("PingTimeout = %v, want h2PingWait (%v) > 0", tr.HTTP2.PingTimeout, h2PingWait)
	}
}

// blackholeRelay forwards each accepted TCP conn to target. blackhole() stops every EXISTING pair from copying
// (bytes read after it are discarded) but keeps both sockets open, as a dead path does. New accepts still forward.
type blackholeRelay struct {
	ln      net.Listener
	target  string
	accepts atomic.Int32
	mu      sync.Mutex
	dead    []*atomic.Bool
	conns   []net.Conn
	wg      sync.WaitGroup
}

func newBlackholeRelay(t *testing.T, target string) *blackholeRelay {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	r := &blackholeRelay{ln: ln, target: target}
	r.wg.Add(1)
	go r.serve()
	t.Cleanup(func() {
		ln.Close()
		r.mu.Lock()
		for _, c := range r.conns {
			c.Close()
		}
		r.mu.Unlock()
		r.wg.Wait()
	})
	return r
}

func (r *blackholeRelay) serve() {
	defer r.wg.Done()
	for {
		c, err := r.ln.Accept()
		if err != nil {
			return
		}
		r.accepts.Add(1)
		s, err := net.Dial("tcp", r.target)
		if err != nil {
			c.Close()
			continue
		}
		dead := new(atomic.Bool)
		r.mu.Lock()
		r.dead = append(r.dead, dead)
		r.conns = append(r.conns, c, s)
		r.mu.Unlock()
		r.wg.Add(2)
		go r.pipe(s, c, dead)
		go r.pipe(c, s, dead)
	}
}

func (r *blackholeRelay) pipe(dst, src net.Conn, dead *atomic.Bool) {
	defer r.wg.Done()
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 && !dead.Load() {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func (r *blackholeRelay) blackhole() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, d := range r.dead {
		d.Store(true)
	}
}

func TestH2HealthClosesADeadConn(t *testing.T) {
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, "ok")
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	t.Cleanup(srv.Close)
	relay := newBlackholeRelay(t, srv.Listener.Addr().String())

	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	var d net.Dialer
	tr := &http.Transport{
		ForceAttemptHTTP2: true,
		TLSClientConfig:   &tls.Config{RootCAs: pool},
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return d.DialContext(ctx, network, relay.ln.Addr().String())
		},
	}
	applyH2Health(tr, 300*time.Millisecond, 300*time.Millisecond)
	t.Cleanup(tr.CloseIdleConnections)
	cl := &http.Client{Transport: tr}

	get := func(ctx context.Context) (*http.Response, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL, nil)
		if err != nil {
			t.Fatal(err)
		}
		return cl.Do(req)
	}
	resp, err := get(context.Background())
	if err != nil {
		t.Fatalf("first GET: %v", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.ProtoMajor != 2 {
		t.Fatalf("first GET: status %d over HTTP/%d, want 200 over HTTP/2 (this test would not test h2)", resp.StatusCode, resp.ProtoMajor)
	}

	relay.blackhole()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	resp, err = get(ctx)
	cancel()
	if err == nil {
		resp.Body.Close()
		t.Fatal("GET over the blackholed conn succeeded: the relay did not blackhole it")
	}
	if errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("GET over the blackholed conn ended on the caller's deadline (%v): no h2 ping closed the dead conn", err)
	}

	ctx, cancel = context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	resp, err = get(ctx)
	if err != nil {
		t.Fatalf("GET after the dead conn closed: %v (want a fresh conn)", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET after the dead conn closed: status %d, want 200", resp.StatusCode)
	}
	if n := relay.accepts.Load(); n != 2 {
		t.Fatalf("relay accepts = %d, want 2 (the GET after the dead conn must dial a new one)", n)
	}
}

func TestTimeoutDropsPooledConns(t *testing.T) {
	var drops atomic.Int32
	orig := dropPooledConns
	dropPooledConns = func() { drops.Add(1) }
	pooledDropAt.Store(0)
	t.Cleanup(func() {
		dropPooledConns = orig
		pooledDropAt.Store(0)
	})

	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-block:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(block) }) // runs before srv.Close (LIFO), so Close does not wait on the handler
	_, terr := (&http.Client{Timeout: 50 * time.Millisecond}).Get(srv.URL)
	if terr == nil || !isTimeoutErr(terr) {
		t.Fatalf("the blocking GET gave %v, want a timeout error", terr)
	}

	if !dropPooledConnsAfterTimeout(terr) || drops.Load() != 1 {
		t.Fatalf("a timeout: drops = %d, want 1", drops.Load())
	}
	if dropPooledConnsAfterTimeout(terr) || drops.Load() != 1 {
		t.Fatalf("a second timeout within dropPooledEvery: drops = %d, want still 1 (the throttle)", drops.Load())
	}

	pooledDropAt.Store(0)
	for _, e := range []error{errors.New("x"), fmt.Errorf("cap GET k -> status %d", 404), nil} {
		if dropPooledConnsAfterTimeout(e) {
			t.Errorf("dropPooledConnsAfterTimeout(%v) = true, want false (not a timeout)", e)
		}
	}
	if drops.Load() != 1 {
		t.Fatalf("non-timeout errors: drops = %d, want still 1", drops.Load())
	}

	pooledDropAt.Store(0)
	if !dropPooledConnsAfterTimeout(fmt.Errorf("readCap: %w", context.DeadlineExceeded)) || drops.Load() != 2 {
		t.Fatalf("a wrapped context.DeadlineExceeded: drops = %d, want 2", drops.Load())
	}
}

func TestStoreReadErrorPathsDropOnTimeout(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, c := range []struct{ fn, call string }{
		{"capReadURL", "dropPooledConnsAfterTimeout(err)"},
		{"capGetMaxOpt", "dropPooledConnsAfterTimeout(gerr)"},
	} {
		if !strings.Contains(strings.Join(stripComments(funcBody(t, src, c.fn)), "\n"), c.call) {
			t.Errorf("%s does not call %s on its store-read error path", c.fn, c.call)
		}
	}

	// main.go has more than one func init(): take the one that sizes the shared transport's pool.
	lines := strings.Split(src, "\n")
	var block []string
	for i := 0; i < len(lines) && block == nil; i++ {
		if lines[i] != "func init() {" {
			continue
		}
		for j := i + 1; j < len(lines); j++ {
			if lines[j] == "}" {
				if blk := lines[i : j+1]; strings.Contains(strings.Join(blk, "\n"), "MaxConnsPerHost") {
					block = blk
				}
				break
			}
		}
	}
	if block == nil {
		t.Fatal("no func init() in main.go sets MaxConnsPerHost -- this test is stale, not the code")
	}
	if !strings.Contains(strings.Join(stripComments(block), "\n"), "applyH2Health(t, h2PingIdle, h2PingWait)") {
		t.Error("the shared transport's init() does not call applyH2Health(t, h2PingIdle, h2PingWait)")
	}
}
