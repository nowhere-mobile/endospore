package main

import (
	"bufio"
	"io"
	"net"
	"strings"
	"testing"
)

// adoptRun feeds handleWifiAdopt the four field lines over a real unix socket (so it has a peer uid) and returns
// the reply and what reached stderr. handleLogin has already consumed the "WIFI-ADOPT" verb line before the arm, so
// the handler's reader starts at <pass>; the request the gate sends is "WIFI-ADOPT\n" + these lines.
func adoptRun(t *testing.T, fields string) (reply, logged string) {
	t.Helper()
	logged = captureStderr(t, func() {
		reply = unixRoundTrip(t, func(c net.Conn) {
			handleWifiAdopt(c, bufio.NewReader(strings.NewReader(fields)))
		})
	})
	return
}

// NWP-20261020-31: one adopt pass leaves one content-free count line in login.log.
func TestWifiAdoptLogsCounts(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"1\n2\n0\n1\n", "[logind] wifi-adopt pass 1: 2 added, 0 already saved, 1 FAILED\n"},
		{"0\n0\n0\n0\n", "[logind] wifi-adopt pass 0: 0 added, 0 already saved, 0 FAILED\n"},
		{"2\n32\n32\n32\n", "[logind] wifi-adopt pass 2: 32 added, 32 already saved, 32 FAILED\n"}, // the bounds are inclusive
		{"1\r\n2\r\n0\r\n1\r\n", "[logind] wifi-adopt pass 1: 2 added, 0 already saved, 1 FAILED\n"},
	} {
		reply, logged := adoptRun(t, c.in)
		if reply != "OK\n" {
			t.Errorf("%q: reply %q, want OK", c.in, reply)
		}
		if logged != c.want {
			t.Errorf("%q: logged %q, want %q", c.in, logged, c.want)
		}
	}
}

// A peer with no credentials (net.Pipe) is refused, as GET-WIFI-MIRROR refuses it, and nothing is logged.
func TestWifiAdoptRefusesWithoutPeerCreds(t *testing.T) {
	var reply string
	logged := captureStderr(t, func() {
		srv, cli := net.Pipe()
		done := make(chan struct{})
		go func() {
			defer close(done)
			handleWifiAdopt(srv, bufio.NewReader(strings.NewReader("1\n2\n0\n1\n")))
			srv.Close()
		}()
		b, _ := io.ReadAll(cli)
		<-done
		cli.Close()
		reply = string(b)
	})
	if reply != "ERR\n" {
		t.Errorf("reply %q, want ERR", reply)
	}
	if logged != "" {
		t.Errorf("logged %q, want nothing", logged)
	}
}

// Anything but four bounded plain decimal integers is ERR, and nothing reaches login.log.
func TestWifiAdoptRefusesMalformed(t *testing.T) {
	for name, in := range map[string]string{
		"non-integer":       "x\n2\n0\n1\n",
		"negative":          "1\n-1\n0\n1\n",
		"pass 3":            "3\n0\n0\n0\n",
		"count 33":          "0\n33\n0\n0\n",
		"last count 33":     "0\n0\n0\n33\n",
		"missing line":      "1\n2\n0\n",
		"truncated, no \\n": "1\n2\n0\n1",
		"plus sign":         "+1\n0\n0\n0\n",
		"leading space":     " 1\n0\n0\n0\n",
		"empty line":        "1\n\n0\n0\n",
		"three digits":      "0\n100\n0\n0\n",
		"ssid-like text":    "0\nHomeNet\n0\n0\n",
		"unicode digit":     "0\n٣\n0\n0\n",
		"nothing":           "",
	} {
		reply, logged := adoptRun(t, in)
		if reply != "ERR\n" {
			t.Errorf("%s: reply %q, want ERR", name, reply)
		}
		if logged != "" {
			t.Errorf("%s: logged %q, want nothing", name, logged)
		}
	}
}

// The record is sent right after a sign-out, while CLEAN-STORAGE may hold sessionMu (the GATE-TIMING case).
func TestWifiAdoptIsConcurrentSafe(t *testing.T) {
	if !concurrentSafeCmd("WIFI-ADOPT") {
		t.Error("WIFI-ADOPT must run outside sessionMu")
	}
}
