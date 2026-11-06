package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261030-02: the gate signs in with ROAM-IN, which never ran the NWP-20260903-53 reset of lastSealStartedAt /
// lastSealOKAt, so profile B's Your data showed profile A's save time and B's export gate passed on A's seal. The
// reset belongs right after the sign-in's marker is written: not before it (a refused ROAM-IN must leave a parked
// cold-locked session's signals to its evict-recheck) and not inside markRoamSession (RESUME continues one session).

// rsrSeed sets both seal signals to an hour ago -- a departed session that sealed -- and zeroes them again on cleanup.
func rsrSeed(t *testing.T) int64 {
	t.Helper()
	v := time.Now().Add(-time.Hour).Unix()
	lastSealStartedAt.Store(v)
	lastSealOKAt.Store(v)
	t.Cleanup(func() { lastSealStartedAt.Store(0); lastSealOKAt.Store(0) })
	return v
}

// rsrRequire fails unless both signals hold want.
func rsrRequire(t *testing.T, want int64, what string) {
	t.Helper()
	if s, ok := lastSealStartedAt.Load(), lastSealOKAt.Load(); s != want || ok != want {
		t.Fatalf("%s: lastSealStartedAt=%d lastSealOKAt=%d, want both %d", what, s, ok, want)
	}
}

func TestRoamInSignalResetOffline(t *testing.T) {
	f := walletFailSetup(t)
	rwWorker(t, f.dest, map[string]string{"btwipe": "OK"})
	rsrSeed(t)
	var reply string
	captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) {
			handleRoamInOffline(c, f.dest, "rsr-offline", "rsr offline passphrase", "21")
		})
	})
	if reply != "OK 21" {
		t.Fatalf("offline sign-in replied %q, want OK 21", reply)
	}
	if _, err := os.Stat(filepath.Join(f.dest, ".roamsession")); err != nil {
		t.Fatalf("control failed: the sign-in wrote no marker: %v", err)
	}
	rsrRequire(t, 0, "after a ROAM-IN-OFFLINE that wrote its marker")
}

func TestRoamInSignalResetOnline(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
	lateWorkDrain(t) // h46 #1: no late sign-in job outlives the test
	rsrSeed(t)
	var reply string
	captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) {
			handleRoamIn(c, f.dest, "rsr-online", "rsr online passphrase", "21", "", "")
		})
	})
	if !strings.HasPrefix(reply, "OK") {
		t.Fatalf("online sign-in replied %q, want OK", reply)
	}
	if _, err := os.Stat(filepath.Join(f.dest, ".roamsession")); err != nil {
		t.Fatalf("control failed: the sign-in wrote no marker: %v", err)
	}
	rsrRequire(t, 0, "after a ROAM-IN that wrote its marker")
}

func TestRoamInSignalResetKeptOnEarlyRefusal(t *testing.T) {
	for _, k := range []string{"GATEWAY_URL", "S3_ENDPOINT", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY", "DISCO_ENDPOINT", "DISCO_BUCKET"} {
		t.Setenv(k, "")
	}
	dest := t.TempDir()
	loginWindowState(t)
	v := rsrSeed(t)
	reply := ropReply(t, func(c net.Conn) {
		handleRoamIn(c, dest, "rsr-nostore", "rsr nostore passphrase", "21", "", "")
	})
	if reply != "NOSTORE" {
		t.Fatalf("control failed: sign-in with no store replied %q, want NOSTORE", reply)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err == nil {
		t.Fatal("control failed: a refused sign-in wrote a marker")
	}
	rsrRequire(t, v, "after a ROAM-IN refused before its marker")
}

// The cold-lock fixture names its profile "alice"; a RESUME continues that same session, so it must keep the signals.
func TestRoamInSignalResetKeptOnResume(t *testing.T) {
	l := crLock(t, crKinds[0])
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	v := rsrSeed(t) // after crLock: the lock's teardown may stamp the signals
	if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
		t.Fatalf("control failed: RESUME replied %q, want OK 10", got)
	}
	rsrRequire(t, v, "after a cold-lock RESUME")
}
