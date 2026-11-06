package main

import (
	"context"
	"net"
	"net/http"
	"syscall"
	"time"

	"github.com/minio/minio-go/v7"
)

// dialControl is the Control of every bound dial -- bindControl in production. A variable only so a test can swap
// in a recorder and prove the hook runs (store_transport_test.go). boundDialer reads it at DIAL time, so the swap
// reaches http.DefaultTransport (whose DialContext is set once in init()) as well as every storeTransport.
var dialControl = bindControl

// boundDialer is the one dialer behind both http.DefaultTransport and every minio client. Timeouts are those of
// the http.DefaultTransport init() it was factored out of (NWP-20261011-20).
var boundDialer = &net.Dialer{
	Timeout:   30 * time.Second,
	KeepAlive: 30 * time.Second,
	Control: func(network, address string, c syscall.RawConn) error {
		return dialControl(network, address, c)
	},
}

// boundDialContext prefers IPv4 for store/gateway dials. On a multi-network device (two SIMs + Wi-Fi) the agent's
// v6 path is unreliable -- competing v6 default routes give ENETUNREACH on connect AND mid-transfer resets
// ("software caused connection abort") that abort a login restore -- while v4 to R2/the gateway is solid. Dial
// tcp4 first and fall back to the family-agnostic dial only if v4 fails (a genuinely v6-only host).
func boundDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	if network == "tcp" {
		if c, err := boundDialer.DialContext(ctx, "tcp4", addr); err == nil {
			return c, nil
		}
	}
	return boundDialer.DialContext(ctx, network, addr)
}

// storeTransport is the transport every minio client is built with (NWP-20261011-20, docs/backlog.md "Direct-S3
// (minio) dials are still unbound -- the two-SIM false-offline class"). A nil minio.Options.Transport does NOT
// fall back to http.DefaultTransport: minio builds its OWN default, whose dialer has no Control, so those sockets
// went out unbound. This starts from that same minio default and replaces only its DialContext with the bound,
// tcp4-first dialer the gateway and OTA dials already use; minio's pooling, timeouts, proxy, TLS floor and
// DisableCompression stay as minio set them. An error is the caller's to handle -- never fall back to an unbound
// transport.
func storeTransport(secure bool) (http.RoundTripper, error) {
	tr, err := minio.DefaultTransport(secure)
	if err != nil {
		return nil, err
	}
	tr.DialContext = boundDialContext
	return tr, nil
}
