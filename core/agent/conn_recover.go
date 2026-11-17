package main

// Pooled-connection recovery for the shared transport (NWP-20261203-21), for the backlog row "After a slow-network
// spell the session's offline-media prefetch never recovers: every attempt times out on its cap request until the
// session ends". mediad is one long-lived process. Its gateway and store requests share http.DefaultTransport's
// pool. A pooled connection can outlive a dead path in two ways. An HTTP/2 connection has no health check by default
// (Transport.HTTP2 nil = no pings). And bindControl (resolver.go) binds a socket to an interface at dial time only.
// applyH2Health closes the first kind. dropPooledConnsAfterTimeout closes the idle rest after a timed-out read.

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

const (
	h2PingIdle = 15 * time.Second // ping an h2 conn that has read no frame for this long
	h2PingWait = 10 * time.Second // close it when the ping gets no answer in this long
)

// applyH2Health turns on the HTTP/2 health check of t. An h2 connection that has read no frame for idle gets a
// PING. When no answer comes within wait, the connection closes, its streams fail fast, and the next request
// dials fresh. Every other field of an existing t.HTTP2 config is kept.
func applyH2Health(t *http.Transport, idle, wait time.Duration) {
	if t.HTTP2 == nil {
		t.HTTP2 = &http.HTTP2Config{}
	}
	t.HTTP2.SendPingTimeout = idle
	t.HTTP2.PingTimeout = wait
}

// dropPooledEvery is the least time between two pool drops, so a burst of timeouts drops the pool once.
const dropPooledEvery = 10 * time.Second

// dropPooledConns drops the idle connections of the shared transport. A var so tests count the calls.
var dropPooledConns = func() {
	if t, ok := http.DefaultTransport.(*http.Transport); ok {
		t.CloseIdleConnections()
	}
}

var (
	pooledDropAt atomic.Int64 // UnixNano of the last drop; 0 = never
	pooledDrops  atomic.Int64 // drops this process, for the log line
)

// isTimeoutErr reports whether err is a timeout: a net.Error that says so, or a spent context deadline.
func isTimeoutErr(err error) bool {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return true
	}
	return errors.Is(err, context.DeadlineExceeded)
}

// dropPooledConnsAfterTimeout drops the pooled idle connections when err is a timeout and the last drop is at least
// dropPooledEvery old, and reports whether it dropped. CloseIdleConnections drops the idle h1 and h2 connections of
// every host. A re-dial re-resolves the host, and bindControl re-binds the new socket to the current egressFor
// interface. A busy h2 connection stays open: the h2 ping (applyH2Health) covers it. A status answer (403, 404,
// 5xx) is not a timeout, so its callers do not call this. The log line holds no URL, host, key or error text.
func dropPooledConnsAfterTimeout(err error) bool {
	if err == nil || !isTimeoutErr(err) {
		return false
	}
	now := time.Now().UnixNano()
	last := pooledDropAt.Load()
	if last != 0 && now-last < int64(dropPooledEvery) {
		return false
	}
	if !pooledDropAt.CompareAndSwap(last, now) {
		return false // a concurrent timeout dropped the pool first
	}
	dropPooledConns()
	n := pooledDrops.Add(1)
	fmt.Fprintf(os.Stderr, "  store: a request timed out; dropped the pooled idle connections so the next attempt dials fresh (%d drops this process)\n", n)
	return true
}
