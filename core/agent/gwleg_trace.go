package main

// gwleg_trace.go -- NWP-20261203-14, backlog row "After a slow-network spell the session's offline-media prefetch
// never recovers: every attempt times out on its cap request until the session ends".
//
// The only line a stuck prefetch left was `Post "<gateway>": context deadline exceeded (Client.Timeout exceeded
// while awaiting headers)`. net/http prints that text whenever http.Client.Timeout fires before the response
// headers, whatever the request was doing: waiting for a pool slot (init() caps MaxConnsPerHost), resolving,
// dialing, the TLS handshake, or waiting on a dead pooled connection. The text cannot tell those stages apart, so
// the next slow-link run could not either. gwLegTrace records the phases of the gateway leg's requests with
// net/http/httptrace, and line() names the stage the last request stopped in.
//
// The line holds fixed words and integers ONLY. It never holds err.Error(), the URL, the host, an address, the
// key or the ref: a *url.Error's text carries the URL, and a cap URL carries the ref.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptrace"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// gwLegFailStreak counts the gateway legs that failed in a row in this process. Only (*gwLegTrace).line touches it.
var gwLegFailStreak atomic.Int64

// gwLegTrace holds the phases of the LAST request made through wrap(). gen names the RoundTrip that owns p, so a
// hook of an earlier request (a dial that ends after its request gave up) cannot write into the next one's phases.
type gwLegTrace struct {
	mu  sync.Mutex
	gen uint64
	p   gwLegPhases
}

// gwLegPhases is cleared as a whole per RoundTrip. It sits outside the mutex, so the clear never copies a lock.
type gwLegPhases struct {
	getConn, dnsStart, dnsDone, connStart, connDone, tlsStart, tlsDone, gotConn, wrote, firstByte time.Time

	// active is the connection phase ("dns", "dial" or "tls") that started last and has not succeeded since. The
	// timestamps alone cannot order the phases: boundDialContext dials tcp4 and, when that fails, resolves again
	// for its family-agnostic dial, so a refused tcp4 connect can sit "started, not done" beside a stalled second
	// lookup.
	active string

	reused, wasIdle bool
	idle            time.Duration
	proto           string
}

// start marks a connection phase as begun now. A repeated start (the fallback dial's second lookup and connect)
// restarts the phase, so its time and the line describe the latest attempt.
func (p *gwLegPhases) start(phase string, start, done *time.Time) {
	*start, *done = time.Now(), time.Time{}
	p.active = phase
}

// done marks a connection phase as finished. Only a success records its time and clears active, so a failed phase
// reads "started, not done" until a later phase starts.
func (p *gwLegPhases) done(phase string, err error, done *time.Time) {
	if err != nil {
		return
	}
	*done = time.Now()
	if p.active == phase {
		p.active = ""
	}
}

// record runs f on the phases under mu, only while gen still owns them.
func (t *gwLegTrace) record(gen uint64, f func(p *gwLegPhases)) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.gen == gen {
		f(&t.p)
	}
}

// clientTrace records one RoundTrip's phases. A done hook records its time only when its phase succeeded, so a
// failed phase reads "started, not done" and line() names it. GetConn keeps the FIRST call of the request; a DNS,
// connect or TLS start keeps the LATEST attempt of its phase (see start).
func (t *gwLegTrace) clientTrace(gen uint64) *httptrace.ClientTrace {
	return &httptrace.ClientTrace{
		GetConn: func(string) {
			t.record(gen, func(p *gwLegPhases) {
				if p.getConn.IsZero() {
					p.getConn = time.Now()
				}
			})
		},
		DNSStart: func(httptrace.DNSStartInfo) {
			t.record(gen, func(p *gwLegPhases) { p.start("dns", &p.dnsStart, &p.dnsDone) })
		},
		DNSDone: func(info httptrace.DNSDoneInfo) {
			t.record(gen, func(p *gwLegPhases) { p.done("dns", info.Err, &p.dnsDone) })
		},
		ConnectStart: func(string, string) {
			t.record(gen, func(p *gwLegPhases) { p.start("dial", &p.connStart, &p.connDone) })
		},
		ConnectDone: func(_, _ string, err error) {
			t.record(gen, func(p *gwLegPhases) { p.done("dial", err, &p.connDone) })
		},
		TLSHandshakeStart: func() {
			t.record(gen, func(p *gwLegPhases) { p.start("tls", &p.tlsStart, &p.tlsDone) })
		},
		TLSHandshakeDone: func(_ tls.ConnectionState, err error) {
			t.record(gen, func(p *gwLegPhases) { p.done("tls", err, &p.tlsDone) })
		},
		GotConn: func(info httptrace.GotConnInfo) {
			t.record(gen, func(p *gwLegPhases) {
				p.gotConn = time.Now()
				p.reused = info.Reused
				p.wasIdle = info.WasIdle
				p.idle = info.IdleTime
				p.proto = "http/1.1"
				if tc, ok := info.Conn.(*tls.Conn); ok && tc.ConnectionState().NegotiatedProtocol == "h2" {
					p.proto = "h2"
				}
			})
		},
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			t.record(gen, func(p *gwLegPhases) {
				if info.Err == nil {
					p.wrote = time.Now()
				}
			})
		},
		GotFirstResponseByte: func() {
			t.record(gen, func(p *gwLegPhases) {
				p.firstByte = time.Now()
			})
		},
	}
}

type gwLegRoundTripper func(*http.Request) (*http.Response, error)

func (f gwLegRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

// wrap traces every request that goes through rt. Each RoundTrip clears the recorded phases first: readCap can
// make a second request (the GET /cap fallback), and the line describes the last one. Pass http.DefaultTransport,
// so the leg keeps the one connection pool of the process.
func (t *gwLegTrace) wrap(rt http.RoundTripper) http.RoundTripper {
	return gwLegRoundTripper(func(req *http.Request) (*http.Response, error) {
		t.mu.Lock()
		t.gen++
		t.p = gwLegPhases{}
		gen := t.gen
		t.mu.Unlock()
		return rt.RoundTrip(req.WithContext(httptrace.WithClientTrace(req.Context(), t.clientTrace(gen))))
	})
}

// gwLegPhaseMs is a phase's length in ms: 0 when it never started, until now when it started and did not finish.
func gwLegPhaseMs(start, done, now time.Time) int64 {
	switch {
	case start.IsZero():
		return 0
	case done.IsZero():
		return now.Sub(start).Milliseconds()
	}
	return done.Sub(start).Milliseconds()
}

// gwLegClass names the error class from the error's types, never from its text.
func gwLegClass(err error) string {
	var ne net.Error
	var cve *tls.CertificateVerificationError
	var rhe tls.RecordHeaderError
	var ae tls.AlertError
	var uae x509.UnknownAuthorityError
	var he x509.HostnameError
	var cie x509.CertificateInvalidError
	switch {
	case errors.As(err, &ne) && ne.Timeout(), errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, syscall.ECONNRESET):
		return "reset"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "refused"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "unreachable"
	case errors.As(err, &cve), errors.As(err, &rhe), errors.As(err, &ae), errors.As(err, &uae),
		errors.As(err, &he), errors.As(err, &cie):
		return "tls"
	}
	return "other"
}

// line is the log line of one gateway leg: "" on success (the streak resets), else one line of fixed words and
// integers that names the stage the last request stopped in.
func (t *gwLegTrace) line(err error, elapsed time.Duration) string {
	if err == nil {
		gwLegFailStreak.Store(0)
		return ""
	}
	n := gwLegFailStreak.Add(1)
	t.mu.Lock()
	p := t.p
	t.mu.Unlock()
	now := time.Now()
	stage := "conn-wait"
	switch {
	case !p.firstByte.IsZero():
		stage = "answered"
	case !p.wrote.IsZero():
		stage = "response-wait"
	case !p.gotConn.IsZero():
		stage = "request-write"
	case p.active != "":
		stage = p.active
	}
	conn, proto := "none", "none"
	if !p.gotConn.IsZero() {
		conn, proto = "new", p.proto
		if p.reused {
			conn = "reused"
		}
	}
	var idle int64
	if p.wasIdle {
		idle = p.idle.Milliseconds()
	}
	return fmt.Sprintf("  cap gateway leg failed after %dms: stage=%s conn=%s idle_ms=%d proto=%s dns_ms=%d connect_ms=%d tls_ms=%d class=%s streak=%d",
		elapsed.Milliseconds(), stage, conn, idle, proto,
		gwLegPhaseMs(p.dnsStart, p.dnsDone, now), gwLegPhaseMs(p.connStart, p.connDone, now),
		gwLegPhaseMs(p.tlsStart, p.tlsDone, now), gwLegClass(err), n)
}
