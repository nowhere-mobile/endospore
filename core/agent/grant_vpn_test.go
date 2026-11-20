package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261210-06 (backlog "A nearly empty profile takes about 85 s from submit to home; target under 60 s", cause
// (6)): the sign-in's first always-on VPN apply rides the grant op. handleRoamIn expects it, handleGrantPerms flags
// its grant (roam.req line 7 = "vpn") and posts roamd's answer, and retryVpnup takes an OK answer without any vpnup
// run of its own. Any other answer, or none in time, falls back to today's loop.

const gvStopLine = "is no longer this session's -- stopping"

type gvGrantCall struct{ op, uid, unit string }

// gvSetup seats a session marker for uid (profile name unique to the test), points the state dir at a temp dir, turns
// the day summary on for uid and replaces the seams. grantAnswer is what the fake grant op leaves in .grantvpn.<uid>
// when it is flagged ("" leaves no file). It returns the dest, the grant calls and the vpnup worker call count.
func gvSetup(t *testing.T, name, uid, grantAnswer string, vpnupReplies []string) (string, func() []gvGrantCall, func() int) {
	t.Helper()
	dest := dsSetup(t, name, uid, 0)
	dsvForgetInstant(t, uid)
	dsMarkerOn(t, uid)
	t.Cleanup(func() {
		grantVpn.mu.Lock()
		delete(grantVpn.m, uid)
		grantVpn.mu.Unlock()
	})
	var mu sync.Mutex
	var grants []gvGrantCall
	vcalls := 0
	oldG, oldW, oldS, oldN, oldWait := grantWorker, vpnupWorker, vpnupSleep, vpnupTries, vpnupGrantWait
	t.Cleanup(func() {
		grantWorker, vpnupWorker, vpnupSleep, vpnupTries, vpnupGrantWait = oldG, oldW, oldS, oldN, oldWait
	})
	grantWorker = func(dest, op, name, pass, uid, seSecret, kind, srcUnit, intent string, onProg func(string)) string {
		mu.Lock()
		grants = append(grants, gvGrantCall{op, uid, srcUnit})
		mu.Unlock()
		if srcUnit == "vpn" && grantAnswer != "" {
			if err := os.WriteFile(filepath.Join(loginStateDir(), grantVpnFile+uid), []byte(grantAnswer+"\n"), 0o600); err != nil {
				t.Error(err)
			}
		}
		return "OK"
	}
	vpnupWorker = func(dest, name, pass, uid string) string {
		mu.Lock()
		defer mu.Unlock()
		vcalls++
		if vcalls <= len(vpnupReplies) {
			return vpnupReplies[vcalls-1]
		}
		return vpnupReplies[len(vpnupReplies)-1]
	}
	vpnupSleep = func(time.Duration) { time.Sleep(2 * time.Millisecond) }
	vpnupTries = 5
	vpnupGrantWait = 5000 * 2 * time.Second // ~10 s of 2 ms steps: the grant always lands first
	return dest, func() []gvGrantCall {
			mu.Lock()
			defer mu.Unlock()
			return append([]gvGrantCall(nil), grants...)
		}, func() int {
			mu.Lock()
			defer mu.Unlock()
			return vcalls
		}
}

func TestGrantVpnFirstApplyRidesTheGrant(t *testing.T) {
	dest, grants, vcalls := gvSetup(t, "gvtest01", "71", "OK NONE", []string{"OK APPLIED"})
	grantVpn.expect("71")
	finish := gvRetry(t, dest, "gvtest01", "71")
	time.Sleep(20 * time.Millisecond) // retryVpnup is in its wait
	gvGrant(t, dest, "71")
	out := finish()
	if g := grants(); len(g) != 1 || g[0].op != "grant" || g[0].uid != "71" || g[0].unit != "vpn" {
		t.Fatalf("grant calls %+v, want one grant for 71 with unit vpn", g)
	}
	if n := vcalls(); n != 0 {
		t.Fatalf("vpnupWorker ran %d times, want 0: the grant's OK answer was the sign-in's apply; log %q", n, out)
	}
	if got := dsvLines(t, "71"); len(got) != 1 || !strings.Contains(got[0], " at=signin rc=none ") {
		t.Fatalf("vpn lines %q, want one at=signin rc=none", got)
	}
	if strings.Contains(out, "vpnup:") {
		t.Fatalf("an OK NONE answer logged a vpnup line: %q", out)
	}
	if _, err := os.Stat(filepath.Join(loginStateDir(), grantVpnFile+"71")); err == nil {
		t.Fatal("the .grantvpn file was not removed")
	}
}

func TestGrantVpnNotReadyFallsBackToTheLoop(t *testing.T) {
	dest, grants, vcalls := gvSetup(t, "gvtest02", "72", "NOTREADY", []string{"NOTREADY", "OK APPLIED"})
	grantVpn.expect("72")
	finish := gvRetry(t, dest, "gvtest02", "72")
	time.Sleep(20 * time.Millisecond)
	gvGrant(t, dest, "72")
	out := finish()
	if g := grants(); len(g) != 1 || g[0].unit != "vpn" {
		t.Fatalf("grant calls %+v, want one flagged grant", g)
	}
	if n := vcalls(); n != 2 {
		t.Fatalf("vpnupWorker ran %d times, want 2 (the loop until its OK); log %q", n, out)
	}
	if got := dsvLines(t, "72"); len(got) != 1 || !strings.Contains(got[0], " rc=applied ") {
		t.Fatalf("vpn lines %q, want one rc=applied", got)
	}
}

func TestGrantVpnTimesOut(t *testing.T) {
	dest, grants, vcalls := gvSetup(t, "gvtest03", "73", "OK APPLIED", []string{"OK APPLIED"})
	vpnupGrantWait = 3 * 2 * time.Second // three steps, then the loop
	grantVpn.expect("73")
	out := gvRetry(t, dest, "gvtest03", "73")()
	if n := vcalls(); n != 1 {
		t.Fatalf("vpnupWorker ran %d times, want 1 after the wait timed out; log %q", n, out)
	}
	gvGrant(t, dest, "73")
	if g := grants(); len(g) != 1 || g[0].unit != "" {
		t.Fatalf("grant calls %+v, want one grant with unit \"\" (the timed-out entry is gone)", g)
	}
}

func TestGrantVpnNotFlaggedWithoutExpect(t *testing.T) {
	dest, grants, _ := gvSetup(t, "gvtest04", "74", "OK APPLIED", []string{"OK APPLIED"})
	gvGrant(t, dest, "74")
	if g := grants(); len(g) != 1 || g[0].unit != "" {
		t.Fatalf("grant calls %+v, want one grant with unit \"\"", g)
	}
	if e := grantVpn.watch("74"); e != nil {
		t.Fatalf("a grant with no expect left an entry %+v", e)
	}
	if _, ok := grantVpn.wait("74", 0); ok {
		t.Fatal("a grant with no expect posted an answer")
	}
}

func TestGrantVpnSessionGoneAfterGrant(t *testing.T) {
	dest, grants, vcalls := gvSetup(t, "gvtest05", "75", "OK APPLIED", []string{"OK APPLIED"})
	grantVpn.expect("75")
	// The reap lands while the grant runs: the marker is gone before its answer is posted.
	inner := grantWorker
	grantWorker = func(d, op, name, pass, uid, se, kind, unit, intent string, p func(string)) string {
		r := inner(d, op, name, pass, uid, se, kind, unit, intent, p)
		os.Remove(filepath.Join(dest, roamSessionFile))
		return r
	}
	gvGrant(t, dest, "75")
	if g := grants(); len(g) != 1 || g[0].unit != "vpn" {
		t.Fatalf("grant calls %+v, want one flagged grant", g)
	}
	// The answer is waiting when retryVpnup starts, so only the re-check after the answer can see the reap.
	out := gvRetry(t, dest, "gvtest05", "75")()
	if n := vcalls(); n != 0 {
		t.Fatalf("vpnupWorker ran %d times for a session that is gone, want 0; log %q", n, out)
	}
	if strings.Count(out, gvStopLine) != 1 {
		t.Fatalf("want the stop line once, got %q", out)
	}
	if got := dsvLines(t, "75"); len(got) != 0 {
		t.Fatalf("vpn lines %q, want none for a stopped retry", got)
	}
}

func TestGrantVpnExpectedAtSignIn(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "\nfunc handleRoamIn(")
	if i < 0 {
		t.Fatal("handleRoamIn not found")
	}
	body := s[i:]
	if j := strings.Index(body[1:], "\nfunc "); j > 0 {
		body = body[:j+1]
	}
	ret := regexp.MustCompile(`(?s)if head == "" \{.*?\n\t\t\treturn\n\t\t\}`).FindStringIndex(body)
	exp := strings.Index(body, "\t\tgrantVpn.expect(uid)\n")
	gor := strings.Index(body, `goSafe("vpnup-retry"`)
	if ret == nil || exp < 0 || gor < 0 {
		t.Fatalf("anchors: head==\"\" return %v, expect %d, vpnup-retry %d", ret, exp, gor)
	}
	if !(ret[1] < exp && exp < gor) {
		t.Fatalf("want the head==\"\" return (%d) < grantVpn.expect(uid) (%d) < goSafe(\"vpnup-retry\" (%d)", ret[1], exp, gor)
	}
	if strings.Count(body, "grantVpn.expect(") != 1 {
		t.Fatal("want exactly one grantVpn.expect in handleRoamIn")
	}
}

// The handoff itself: claim once, an empty answer is delivered, a replaced entry is not removed by an older waiter.
func TestGrantVpnHandoffRules(t *testing.T) {
	g := &grantVpnHandoff{m: map[string]*grantVpnEntry{}}
	if g.claim("9") {
		t.Fatal("claim with no expect")
	}
	g.expect("9")
	if !g.claim("9") || g.claim("9") {
		t.Fatal("claim must be true exactly once")
	}
	g.post("9", "")
	if a, ok := g.wait("9", time.Second); !ok || a != "" {
		t.Fatalf("an empty answer: got %q %v, want \"\" true", a, ok)
	}
	if g.watch("9") != nil {
		t.Fatal("wait left the entry")
	}
	g.post("9", "OK APPLIED") // a late post never re-creates an entry
	if g.watch("9") != nil {
		t.Fatal("a post with no entry created one")
	}
	g.expect("9")
	old := g.watch("9")
	g.expect("9")
	g.finish("9", old)
	if g.watch("9") == nil {
		t.Fatal("an older waiter removed the replacement entry")
	}
	if _, ok := g.wait("9", time.Millisecond); ok {
		t.Fatal("an undelivered wait said ok")
	}
}

func TestGrantVpnReadFile(t *testing.T) {
	d := t.TempDir()
	if got := readGrantVpn(d, "5"); got != "" {
		t.Fatalf("absent file read %q", got)
	}
	p := filepath.Join(d, grantVpnFile+"5")
	os.WriteFile(p, []byte("OK APPLIED\nsecond line\n"), 0o600)
	if got := readGrantVpn(d, "5"); got != "OK APPLIED" {
		t.Fatalf("read %q, want OK APPLIED", got)
	}
	if _, err := os.Stat(p); err == nil {
		t.Fatal("the file was not removed")
	}
	if got := readGrantVpn(d, "../5"); got != "" {
		t.Fatalf("a non-digit uid read %q", got)
	}
}
