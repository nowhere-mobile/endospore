package main

// NWP-20261210-05: the session's three claims in one worker run (session_claims.go). roamd's half -- that sessclaim runs
// the single arms' claim bodies once each, in order, and answers one line -- is
// core/vendor-common/bin/test-session-claims.sh; these pin the daemon's half: one sessclaim per sign-in, offline sign-in
// and resume and no single claim beside it, the parts this image supports, the single claims' log lines for a field that
// is not OK, and the drop under the RW slot once the session has ended.

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type scCall struct {
	why, uid, parts string
	live            string // the uid .roamsession named when the worker was asked
	coldlock        bool   // .coldlock existed then
}

type scRec struct {
	mu     sync.Mutex
	calls  []scCall
	single []string // single claim runs (locapply, mdapply, dtclaim): there must be none at a session start
	ch     chan scCall
}

// scSetup stands in for roamd's sessclaim (every run answers reply) on an image that supports the three claims, and
// records any single claim run beside it.
func scSetup(t *testing.T, reply string) *scRec {
	t.Helper()
	rec := &scRec{ch: make(chan scCall, 16)}
	prevW, prevL, prevM, prevD := sessionClaimsWorker, locGlobalsWorker, mobileDataWorker, devTogglesWorker
	prevLS, prevMS, prevDS := locGlobalsSupported, mobileDataSupported, devTogglesSupported
	locGlobalsSupported = func() bool { return true }
	mobileDataSupported = func() bool { return true }
	devTogglesSupported = func() bool { return true }
	sessionClaimsWorker = func(dest, why, uid, parts string) string {
		_, _, live := readRoamSession(dest)
		c := scCall{why: why, uid: uid, parts: parts, live: live, coldlock: clwExists(dest, ".coldlock")}
		rec.mu.Lock()
		rec.calls = append(rec.calls, c)
		rec.mu.Unlock()
		rec.ch <- c
		return reply
	}
	single := func(dest, op, why, uid string) string {
		rec.mu.Lock()
		rec.single = append(rec.single, op+"/"+why)
		rec.mu.Unlock()
		return "OK"
	}
	locGlobalsWorker, mobileDataWorker, devTogglesWorker = single, single, single
	t.Cleanup(func() {
		sessionClaimsWorker, locGlobalsWorker, mobileDataWorker, devTogglesWorker = prevW, prevL, prevM, prevD
		locGlobalsSupported, mobileDataSupported, devTogglesSupported = prevLS, prevMS, prevDS
	})
	return rec
}

func (r *scRec) wait(t *testing.T, what string) scCall {
	t.Helper()
	select {
	case c := <-r.ch:
		return c
	case <-time.After(3 * time.Second):
		t.Fatalf("%s: the daemon never asked roamd for sessclaim", what)
	}
	return scCall{}
}

func (r *scRec) none(t *testing.T, what string) {
	t.Helper()
	select {
	case c := <-r.ch:
		t.Errorf("%s: the daemon asked roamd for sessclaim %+v", what, c)
	case <-time.After(300 * time.Millisecond):
	}
}

// noMore waits out a second run and any single claim: one session start is ONE worker run.
func (r *scRec) noMore(t *testing.T, what string) {
	t.Helper()
	r.none(t, what+" (a second run)")
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.single) != 0 {
		t.Errorf("%s: single claim runs %v beside sessclaim -- want none", what, r.single)
	}
}

// scOffline drives an offline sign-in of user 12 and returns its reply.
func scOffline(t *testing.T, dest, name string) string {
	t.Helper()
	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, name, "correct horse battery", "12"); srv.Close() }()
	buf := make([]byte, 64)
	nr, _ := cli.Read(buf)
	cli.Close()
	return strings.TrimSpace(string(buf[:nr]))
}

// One worker run per session start, with every supported part, and no single claim beside it. The offline sign-in and
// the resume are driven; the sign-in needs a store, so its site is pinned in the source, as each handler's is: one
// claimSessionGlobalsAsync and no single claim call or op.
func TestSessionClaimOneRunPerSignIn(t *testing.T) {
	dest := t.TempDir()
	stop := ropWorker(t, dest) // answers the btwipe at once
	defer stop()
	rec := scSetup(t, "OK APPLIED;OK APPLIED mobile_data=1 data_roaming=0;OK CLAIMED 4")
	if got := scOffline(t, dest, "scone"); got != "OK 12" {
		t.Fatalf("offline sign-in replied %q", got)
	}
	c := rec.wait(t, "an offline sign-in")
	if c.why != "offline" || c.uid != "12" || c.parts != "loc,md,dt" || c.live != "12" {
		t.Errorf("offline sign-in asked %+v, want offline for user 12, parts loc,md,dt, .roamsession naming it", c)
	}
	rec.noMore(t, "an offline sign-in")

	l := crLock(t, crKinds[0])
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
		t.Fatalf("the resume was refused (%q)", got)
	}
	c = rec.wait(t, "a resume")
	if c.why != "resume" || c.uid != "10" || c.parts != "loc,md,dt" || c.live != "10" || c.coldlock {
		t.Errorf("resume asked %+v, want resume for user 10, parts loc,md,dt, recorded and no longer cold-locked", c)
	}
	rec.noMore(t, "a resume")

	for fn, why := range map[string]string{"handleRoamIn": "signin", "handleRoamInOffline": "offline", "handleResume": "resume"} {
		body := fileFuncBody(t, "main.go", fn)
		if n := strings.Count(body, "claimSessionGlobals"); n != 1 {
			t.Errorf("%s calls claimSessionGlobals %d times, want 1", fn, n)
		}
		if want := fmt.Sprintf("claimSessionGlobalsAsync(dest, uid, %q)", why); !strings.Contains(body, want) {
			t.Errorf("%s does not call %s", fn, want)
		}
		for _, single := range []string{"claimLocGlobals(", "claimMobileData(", "claimDevToggles(",
			`"locapply"`, `"mdapply"`, `"dtclaim"`} {
			if strings.Contains(body, single) {
				t.Errorf("%s still makes a single claim (%s): one session start is one worker run", fn, single)
			}
		}
	}
}

// The parts are the claims this image supports, in the order loc, md, dt; with none, nothing reaches roamd.
func TestSessionClaimPartsFollowSupport(t *testing.T) {
	rec := scSetup(t, "OK;OK;OK")
	for i := 0; i < 8; i++ {
		l, m, d := i&4 != 0, i&2 != 0, i&1 != 0
		locGlobalsSupported = func() bool { return l }
		mobileDataSupported = func() bool { return m }
		devTogglesSupported = func() bool { return d }
		var want []string
		if l {
			want = append(want, "loc")
		}
		if m {
			want = append(want, "md")
		}
		if d {
			want = append(want, "dt")
		}
		w := strings.Join(want, ",")
		if got := sessionClaimParts(); got != w {
			t.Errorf("support loc=%v md=%v dt=%v: parts %q, want %q", l, m, d, got, w)
		}
		claimSessionGlobals(t.TempDir(), "10", "signin")
		if w == "" {
			rec.none(t, "an image that supports no claim")
			continue
		}
		if c := rec.wait(t, "parts "+w); c.parts != w || c.why != "signin" || c.uid != "10" {
			t.Errorf("support loc=%v md=%v dt=%v: worker asked %+v, want parts %q", l, m, d, c, w)
		}
	}
	locGlobalsSupported = func() bool { return false }
	mobileDataSupported = func() bool { return false }
	devTogglesSupported = func() bool { return false }
	claimSessionGlobalsAsync(t.TempDir(), "10", "signin")
	rec.none(t, "claimSessionGlobalsAsync on an image that supports no claim")
	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.single) != 0 {
		t.Errorf("single claim runs %v", rec.single)
	}
}

// A field that is not OK prints its single claim's line, byte for byte; an OK field and a part not asked for print
// nothing; a reply that is not three fields prints one sessclaim line.
func TestSessionClaimLogsEachNonOK(t *testing.T) {
	scSetup(t, "")
	reply := ""
	sessionClaimsWorker = func(dest, why, uid, parts string) string { return reply }
	logOf := func(r string) string {
		reply = r
		return captureStderr(t, func() { claimSessionGlobals(t.TempDir(), "10", "signin") })
	}
	devTogglesSupported = func() bool { return false } // parts loc,md
	if got, want := logOf("OK APPLIED;FAILED(x);-"),
		"[logind] mobiledata: signin claim for user 10 answered [FAILEDx] (NWP-20261026-06)\n"; got != want {
		t.Errorf("reply OK APPLIED;FAILED(x);- logged %q, want %q", got, want)
	}
	devTogglesSupported = func() bool { return true }
	if got, want := logOf("ERR-LOC network_location=?;OK APPLIED;ERR-DT x\n"),
		"[logind] locglobals: signin claim for user 10 answered [ERR-LOC network_location=?] (NWP-20261016-45)\n"+
			"[logind] devtoggles: signin claim for user 10 answered [ERR-DT x] (NWP-20261027-08)\n"; got != want {
		t.Errorf("two failed fields logged %q, want %q", got, want)
	}
	if got := logOf("OK APPLIED;OK APPLIED mobile_data=1 data_roaming=0;OK CLAIMED 4\n"); got != "" {
		t.Errorf("an all-OK reply logged %q", got)
	}
	devTogglesSupported = func() bool { return false }
	if got := logOf("OK;OK;-"); got != "" {
		t.Errorf("a part not asked for logged %q", got)
	}
	devTogglesSupported = func() bool { return true }
	for _, r := range []string{"SKIP-ENDED", "ERR-UID", "ERR-ARGS", "OK;OK", "OK;OK;OK;OK", "ERR-BUSY\nsecond"} {
		want := "[logind] sessclaim: signin claim for user 10 answered " + logVal(locReplyToken(r)) + " (NWP-20261210-05)\n"
		if got := logOf(r); got != want {
			t.Errorf("reply %q logged %q, want %q", r, got, want)
		}
	}
}

// The guard under the slot: a sessclaim runs only for the uid .roamsession names, and never for a session that is
// cold-locked or queued to be switched out (TestLocClaimIsDroppedUnderTheSlotOnceItsSessionEnded).
func TestSessionClaimDroppedUnderTheSlot(t *testing.T) {
	ropReapReset(t)
	t.Cleanup(func() { pendingReapMu.Lock(); pendingLockUID = ""; pendingReapMu.Unlock() })
	run := func(dest string) (string, []string) {
		stop := ropWorker(t, dest)
		out := runWorkerHeld(laneRW, dest, "sessclaim", "signin", "", "10", "", "", "loc,md,dt", "", nil)
		return out, stop()
	}
	dest := t.TempDir()
	if out, ops := run(dest); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("no session: %q, worker saw %v -- want SKIP-ENDED and nothing written", out, ops)
	}
	if err := markRoamSession(dest, "scbob", "pw", "11", ""); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("another user is live: %q, %v", out, ops)
	}
	if err := markRoamSession(dest, "scalice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest); out != "ERR-PIN-TEST" || len(ops) != 1 || ops[0] != "sessclaim" {
		t.Fatalf("the live session's sessclaim: %q, %v -- want it handed to the worker", out, ops)
	}
	for _, flag := range []*string{&pendingSwitchUID, &pendingReapUID, &pendingLockUID} {
		pendingReapMu.Lock()
		*flag = "10"
		pendingReapMu.Unlock()
		if out, ops := run(dest); out != "SKIP-ENDED" || len(ops) != 0 {
			t.Errorf("a session queued to be switched out: %q, %v", out, ops)
		}
		pendingReapMu.Lock()
		*flag = ""
		pendingReapMu.Unlock()
	}
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("scalice\n10\n\nnokey\nnopin\nx\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("a cold-locked session: %q, %v", out, ops)
	}
}
