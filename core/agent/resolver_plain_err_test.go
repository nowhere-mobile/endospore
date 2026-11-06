package main

import (
	"context"
	"net"
	"strings"
	"testing"
)

// NWP-20261014-49: dialPlain reports EVERY server's failure (NWP-20260822-04). Keeping only the last error cost
// a day on #64 -- the capture named the final address of the fallback list and read as "IPv6 is the problem"
// when all servers had failed. An already-cancelled ctx makes each literal-address dial fail deterministically
// and offline.
func TestDialPlain_JoinsEveryServersError(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	first, second := "192.0.2.1:53", "[2001:db8::1]:53"
	_, err := dialPlain(ctx, "udp", []string{first, second}, &net.Dialer{})
	pe, ok := err.(*plainDialError)
	if !ok {
		t.Fatalf("want *plainDialError, got %T: %v", err, err)
	}
	msg := pe.Error()
	if !strings.HasPrefix(msg, "resolver: all 2 dns server(s) failed [") {
		t.Fatalf("Error() = %q, want the all-2 prefix", msg)
	}
	for _, a := range []string{first, second} {
		if !strings.Contains(msg, a) {
			t.Errorf("Error() = %q does not name %s", msg, a)
		}
	}
	i, j := strings.Index(msg, first), strings.Index(msg, second)
	if i < 0 || j < 0 || i >= j {
		t.Errorf("Error() = %q does not name the servers in order", msg)
	}
	if !strings.Contains(msg[i:j], "; ") {
		t.Errorf("Error() = %q does not separate the parts with \"; \"", msg)
	}
	if !strings.Contains(msg, "operation was canceled") {
		t.Errorf("Error() = %q lost the underlying dial error", msg)
	}
	kinds := pe.kinds()
	if len(kinds) != 2 {
		t.Fatalf("kinds() has %d entries, want 2: %q", len(kinds), kinds)
	}
	for _, k := range kinds {
		if strings.Contains(k, "192.0.2.1") || strings.Contains(k, "2001:db8") {
			t.Errorf("kinds() entry %q names a server address", k)
		}
	}
}

func TestDialPlain_NoServersConfigured(t *testing.T) {
	for _, addrs := range [][]string{nil, {}} {
		_, err := dialPlain(context.Background(), "udp", addrs, &net.Dialer{})
		if err == nil || !strings.Contains(err.Error(), "no dns servers configured") {
			t.Errorf("addrs=%v: err = %v, want no dns servers configured", addrs, err)
		}
	}
}

// NWP-20261015-22: a server string that does not parse makes DialContext fail with OpError{dial, *net.AddrError},
// whose text is "address <the string>: <why>". The plain diagnostic (Error()) keeps the address; the address-free
// view kinds() -- the one that reaches login.log -- must keep only the why.
func TestDialPlain_MalformedAddressIsNotNamed(t *testing.T) {
	first, second := "192.0.2.7", "[2001:db8::9"
	_, err := dialPlain(context.Background(), "udp", []string{first, second}, &net.Dialer{})
	pe, ok := err.(*plainDialError)
	if !ok {
		t.Fatalf("want *plainDialError, got %T: %v", err, err)
	}
	msg := pe.Error()
	for _, a := range []string{first, second} {
		if !strings.Contains(msg, a) {
			t.Errorf("Error() = %q does not name %s", msg, a)
		}
	}
	kinds := pe.kinds()
	if len(kinds) != 2 {
		t.Fatalf("kinds() has %d entries, want 2: %q", len(kinds), kinds)
	}
	for _, k := range kinds {
		if k == "" || strings.Contains(k, "192.0.2.7") || strings.Contains(k, "2001:db8") {
			t.Errorf("kinds() entry %q is empty or names a server string", k)
		}
	}
	if !strings.Contains(kinds[0], "missing port") {
		t.Errorf("kinds()[0] = %q lost the parse reason", kinds[0])
	}
}

func TestDescribeDialErr_AddrError(t *testing.T) {
	ae := &net.AddrError{Err: "missing port in address", Addr: "192.0.2.7"}
	for _, c := range []struct {
		name string
		err  error
		want string
	}{
		{"bare", ae, "missing port in address"},
		{"under OpError", &net.OpError{Op: "dial", Net: "udp", Err: ae}, "dial: missing port in address"},
	} {
		if got := describeDialErr(c.err); got != c.want {
			t.Errorf("%s: describeDialErr = %q, want %q", c.name, got, c.want)
		}
	}
}
