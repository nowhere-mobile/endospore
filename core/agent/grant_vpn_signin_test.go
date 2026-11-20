package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261210-06 (backlog "A nearly empty profile takes about 85 s from submit to home; target under 60 s", cause
// (6)): the end-to-end half of the grant-VPN handoff. These tests use ONLY identifiers origin/main already had
// (handleRoamIn, handleGrantPerms, retryVpnup and their seams), so this file builds against the base package alone
// and its assertions fail there by `--- FAIL`, not by a build error; grant_vpn_test.go holds the unit tests of the
// new handoff. The fake RW worker below reads roam.req the way roamd does and records each grant's line 7 (srcUnit).

type gvReq struct{ op, uid, unit string }

// gvReqWorker answers the RW lane like roamd: it reads and removes roam.req, records op / uid / line 7 and writes
// roam.res. A grant whose line 7 is "vpn" also leaves grantAnswer in <state>/.grantvpn.<uid>, as the grant arm does
// ("" leaves no file). Every other op answers "OK 21" ("in") or ERR-UNEXPECTED.
func gvReqWorker(t *testing.T, dest, grantAnswer string) func() []gvReq {
	t.Helper()
	var mu sync.Mutex
	var reqs []gvReq
	done, finished := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(finished)
		for {
			if b, err := os.ReadFile(filepath.Join(dest, laneRW.req)); err == nil && strings.Count(string(b), "\n") >= 7 {
				os.Remove(filepath.Join(dest, laneRW.req))
				l := strings.Split(string(b), "\n")
				mu.Lock()
				reqs = append(reqs, gvReq{l[0], l[3], l[6]})
				mu.Unlock()
				ans := "ERR-UNEXPECTED"
				switch l[0] {
				case "in":
					ans = "OK 21"
				case "grant":
					ans = "OK"
					if l[6] == "vpn" && grantAnswer != "" {
						os.WriteFile(filepath.Join(loginStateDir(), ".grantvpn."+l[3]), []byte(grantAnswer+"\n"), 0o600)
					}
				}
				os.WriteFile(filepath.Join(dest, laneRW.res), []byte(ans+"\n"), 0o600)
			}
			select {
			case <-done:
				return
			case <-time.After(5 * time.Millisecond):
			}
		}
	}()
	t.Cleanup(func() { close(done); <-finished })
	return func() []gvReq {
		mu.Lock()
		defer mu.Unlock()
		var g []gvReq
		for _, r := range reqs {
			if r.op == "grant" || r.op == "vpnup" {
				g = append(g, r)
			}
		}
		return g
	}
}

// gvSignIn drives a real stored-profile sign-in (user 21) behind gvReqWorker, then the chooser's GRANT-PERMS, and
// returns the grant/vpnup requests and the vpnupWorker run count once retryVpnup has had time to end. vpnupSleep is
// 50 ms, so retryVpnup's 2-second steps are short but the grant still lands inside its wait.
func gvSignIn(t *testing.T, grantAnswer string, vpnupReplies []string) ([]gvReq, int) {
	t.Helper()
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	reqs := gvReqWorker(t, f.dest, grantAnswer)
	lateWorkFresh(t)
	lateWorkSeams(t, func() {})
	var mu sync.Mutex
	vcalls := 0
	oldN := vpnupTries
	t.Cleanup(func() { vpnupTries = oldN })
	vpnupTries = 3
	vpnupWorker = func(dest, name, pass, uid string) string {
		mu.Lock()
		defer mu.Unlock()
		vcalls++
		if vcalls <= len(vpnupReplies) {
			return vpnupReplies[vcalls-1]
		}
		return vpnupReplies[len(vpnupReplies)-1]
	}
	vpnupSleep = func(time.Duration) { time.Sleep(50 * time.Millisecond) }
	// The marker goes at the end, so a retryVpnup still waiting stops (NWP-20261113-20) and outlives no test.
	t.Cleanup(func() { os.Remove(filepath.Join(f.dest, roamSessionFile)); time.Sleep(150 * time.Millisecond) })
	var reply string
	captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) {
			handleRoamIn(c, f.dest, walletFailName, walletFailPass, "21", "", "")
		})
	})
	if !strings.HasPrefix(reply, "OK 21") && !strings.Contains(reply, "\nOK 21") {
		t.Fatalf("control failed: the sign-in replied %q, want OK 21", reply)
	}
	lateWorkWait(t)
	gvGrant(t, f.dest, "21")
	time.Sleep(500 * time.Millisecond) // retryVpnup takes the answer (or runs its loop) and ends
	mu.Lock()
	defer mu.Unlock()
	return reqs(), vcalls
}

// A sign-in's grant carries "vpn" on roam.req line 7, and its OK answer is the sign-in's first VPN apply: no vpnup
// run at all. On origin/main the grant's line 7 is empty and retryVpnup runs vpnup at once.
func TestGrantVpnSignInGrantCarriesTheApply(t *testing.T) {
	reqs, vcalls := gvSignIn(t, "OK NONE", []string{"OK NONE"})
	if len(reqs) != 1 || reqs[0].op != "grant" || reqs[0].uid != "21" || reqs[0].unit != "vpn" {
		t.Errorf("grant/vpnup requests %+v, want exactly one grant for user 21 with roam.req line 7 \"vpn\"", reqs)
	}
	if vcalls != 0 {
		t.Errorf("vpnupWorker ran %d times, want 0: the grant's OK answer was the sign-in's first apply", vcalls)
	}
}

// A grant that answers NOTREADY hands back to the 2-second loop, which runs until its OK (a control on origin/main:
// there the loop runs at once).
func TestGrantVpnSignInNotReadyRunsTheLoop(t *testing.T) {
	reqs, vcalls := gvSignIn(t, "NOTREADY", []string{"NOTREADY", "OK APPLIED"})
	if len(reqs) != 1 || reqs[0].op != "grant" {
		t.Errorf("grant/vpnup requests %+v, want exactly one grant", reqs)
	}
	if vcalls != 2 {
		t.Errorf("vpnupWorker ran %d times, want 2 (NOTREADY, then OK)", vcalls)
	}
}

// A grant with no sign-in before it is not flagged, and its reply stays OK (a control on origin/main).
func TestGrantVpnGrantWithoutSignInIsNotFlagged(t *testing.T) {
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	resetAbandoned(t, nil)
	reqs := gvReqWorker(t, dest, "OK NONE")
	gvGrant(t, dest, "22")
	if g := reqs(); len(g) != 1 || g[0].op != "grant" || g[0].unit != "" {
		t.Errorf("grant/vpnup requests %+v, want one grant with roam.req line 7 empty", g)
	}
	if _, err := os.Stat(filepath.Join(dest, ".grantvpn.22")); err == nil {
		t.Error("an unflagged grant left a .grantvpn file")
	}
}

// gvGrant drives GRANT-PERMS for uid and waits for its tail (seed-home, bootwake), as grantPermsRequest does.
func gvGrant(t *testing.T, dest, uid string) {
	t.Helper()
	calls := bootWakeFakes(t)
	old := tieFinishDelay
	tieFinishDelay = 0
	t.Cleanup(func() { tieFinishDelay = old })
	if err := os.WriteFile(filepath.Join(dest, ".localsession"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := ropReply(t, func(c net.Conn) { handleGrantPerms(c, dest, uid) }); got != "OK" {
		t.Fatalf("GRANT-PERMS replied %q, want OK", got)
	}
	deadline := time.Now().Add(5 * time.Second)
	for len(calls()) < 2 {
		if time.Now().After(deadline) {
			t.Fatalf("the grant tail did not run: %v", calls())
		}
		time.Sleep(5 * time.Millisecond)
	}
	os.Remove(filepath.Join(dest, ".localsession"))
}

// gvRetry starts retryVpnup and returns a func that waits for it and returns its log.
func gvRetry(t *testing.T, dest, name, uid string) func() string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = w
	done := make(chan struct{})
	go func() {
		defer close(done)
		retryVpnup(dest, name, "pw-"+name, uid)
	}()
	return func() string {
		select {
		case <-done:
		case <-time.After(20 * time.Second):
			t.Fatal("retryVpnup did not return")
		}
		os.Stderr = old
		w.Close()
		b, _ := readAllClose(r)
		return string(b)
	}
}

func readAllClose(r *os.File) ([]byte, error) {
	defer r.Close()
	var b []byte
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		b = append(b, buf[:n]...)
		if err != nil {
			return b, nil
		}
	}
}
