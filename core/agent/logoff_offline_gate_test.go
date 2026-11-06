package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261017-04: the two logoff gates (handleLogout, handleRoamOut) test localOnlySession like every other
// seal gate. An offline sign-in carries .localsession AND .offlinesession; if the first is lost, the logoff must
// still take the throwaway branch, not seal an EMPTY offline session over the real stored head (#72).

func TestLogoutOfflineOnlyMarkerSealsNothingAndReaps(t *testing.T) {
	dest := cutoffSession(t, "11")
	if err := os.WriteFile(filepath.Join(dest, ".offlinesession"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	ops := cutoffWorker(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": "OK"}, nil)
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	pendingReapMu.Lock()
	inFlight, kind, reap := sealInFlight, sealRunKind, pendingReapUID
	pendingReapMu.Unlock()
	if inFlight || kind != "" {
		t.Fatalf("an offline-only session started a seal (inFlight=%v kind=%q)", inFlight, kind)
	}
	if reap != "11" {
		t.Fatalf("pendingReapUID = %q, want 11", reap)
	}
	for _, m := range []string{".offlinesession", ".localsession", ".roamsession"} {
		if _, err := os.Stat(filepath.Join(dest, m)); err == nil {
			t.Errorf("%s survived the logoff", m)
		}
	}
	time.Sleep(200 * time.Millisecond)
	if got := ops(); len(got) != 0 {
		t.Fatalf("the worker was handed %v for a throwaway logoff", got)
	}
}

func TestLogoutControlWithNoMarkerSeals(t *testing.T) {
	dest := cutoffSession(t, "11")
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": "OK"},
		map[string]time.Duration{"cutoff": 2 * time.Second})
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	pendingReapMu.Lock()
	inFlight := sealInFlight
	pendingReapMu.Unlock()
	if !inFlight {
		t.Fatal("a stored session's logoff started no seal -- the control is vacuous")
	}
	// NWP-20261019-04: let the sign-out finish before the test returns. Left running, it outlives its temp dir, its
	// worker calls fail, and it reaches whatever logoffStageInbox stub the NEXT test has installed (seen as a second
	// staging call for uid 11 in TestLogoffRearmInbox_AFailedSealStagesTheInbox).
	deadline := time.Now().Add(15 * time.Second)
	for {
		pendingReapMu.Lock()
		reap := pendingReapUID
		pendingReapMu.Unlock()
		if reap == "11" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the control's sign-out never queued its reap")
		}
		time.Sleep(50 * time.Millisecond)
	}
	ackReapAction("SWITCH", "11")
	ackReapAction("REAP", "11")
}

// handleRoamOut ends in rebootNow (a real setprop), which cannot be stubbed, so its gate is pinned at the source.
func TestRoamOutGateHonoursBothMarkers(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"handleRoamOut", "handleLogout"} {
		body := stripComments(funcBody(t, string(src), fn))
		first := ""
		for _, l := range body {
			if strings.Contains(l, "LocalSession(dest)") || strings.Contains(l, "localOnlySession(dest)") {
				first = strings.TrimSpace(l)
				break
			}
		}
		if !strings.HasPrefix(first, "if localOnlySession(dest) {") {
			t.Errorf("%s: first marker test is %q, want `if localOnlySession(dest) {`", fn, first)
		}
		j := strings.Join(body, "\n")
		if !strings.Contains(j, "clearOfflineSession(dest)") {
			t.Errorf("%s never clears .offlinesession", fn)
		}
	}
}
