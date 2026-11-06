package main

// NWP-20261016-45: the daemon's half of the session-scoped location globals (locglobals.go). roamd's half -- what a
// claim and a release WRITE -- is core/vendor-common/bin/test-locglobals.sh; these pin WHEN the daemon asks for them:
// a claim at every start of a session in front, only for the session .roamsession names and only while its user exists
// (re-checked under the RW slot), and a release at every end -- the gate switch of a removal, the cold lock's own hold,
// and the clearing of an abandoned sign-in's marker.

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type locCall struct {
	op, why, uid string
	live         string // the uid .roamsession named when the worker was asked
	coldlock     bool   // .coldlock existed then
}

type locRec struct {
	mu    sync.Mutex
	calls []locCall
	ch    chan locCall
}

// locSetup stands in for roamd (every worker call answers reply) on an image that has the provider.
func locSetup(t *testing.T, reply string) *locRec {
	t.Helper()
	rec := &locRec{ch: make(chan locCall, 16)}
	prevW, prevS := locGlobalsWorker, locGlobalsSupported
	locGlobalsSupported = func() bool { return true }
	locGlobalsWorker = func(dest, op, why, uid string) string {
		_, _, live := readRoamSession(dest)
		c := locCall{op: op, why: why, uid: uid, live: live, coldlock: clwExists(dest, ".coldlock")}
		rec.mu.Lock()
		rec.calls = append(rec.calls, c)
		rec.mu.Unlock()
		rec.ch <- c
		return reply
	}
	t.Cleanup(func() { locGlobalsWorker, locGlobalsSupported = prevW, prevS })
	return rec
}

func (r *locRec) wait(t *testing.T, what string) locCall {
	t.Helper()
	select {
	case c := <-r.ch:
		return c
	case <-time.After(3 * time.Second):
		t.Fatalf("%s: the daemon never asked roamd for it", what)
	}
	return locCall{}
}

func (r *locRec) none(t *testing.T, what string) {
	t.Helper()
	select {
	case c := <-r.ch:
		t.Errorf("%s: the daemon asked roamd for %+v", what, c)
	case <-time.After(300 * time.Millisecond):
	}
}

func locPeer(t *testing.T, androidUID int) {
	t.Helper()
	prev := sessionPeerUID
	sessionPeerUID = func(net.Conn) int { return androidUID }
	t.Cleanup(func() { sessionPeerUID = prev })
}

// The live switch: the session's own chooser asks, roamd's verdict comes back, and the request names the live uid.
func TestApplyLocationAppliesTheLiveSessionsChoice(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	locPeer(t, 10*100000+10123)
	rec := locSetup(t, "OK APPLIED network_location=2 geocoder=0")
	// Held, to prove the verb runs free (concurrentSafeCmd): a materialise can hold sessionMu for minutes.
	sessionMu.Lock()
	done := make(chan string, 1)
	go func() { done <- driveLogin(t, dest, "APPLY-LOCATION\n") }()
	var got string
	select {
	case got = <-done:
		sessionMu.Unlock()
	case <-time.After(5 * time.Second):
		sessionMu.Unlock()
		<-done
		t.Fatal("APPLY-LOCATION waited on sessionMu -- a Location services tap would queue behind a materialise")
	}
	if got != "OK APPLIED network_location=2 geocoder=0" {
		t.Fatalf("APPLY-LOCATION replied %q", got)
	}
	if c := rec.wait(t, "the live switch"); c.op != "locapply" || c.why != "live" || c.uid != "10" {
		t.Errorf("worker asked %+v, want locapply/live for user 10", c)
	}
}

// Only the session's own chooser may ask; with no session, or on an image without the provider, roamd is never asked.
func TestApplyLocationRefusesWhatItCannotApply(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	rec := locSetup(t, "OK APPLIED network_location=2 geocoder=2")

	locPeer(t, 10123) // the gate (user 0)
	if got := driveLogin(t, dest, "APPLY-LOCATION\n"); got != "NONE" {
		t.Errorf("a gate caller got %q, want NONE", got)
	}
	locPeer(t, 11*100000+10123) // an app of another user
	if got := driveLogin(t, dest, "APPLY-LOCATION\n"); got != "NONE" {
		t.Errorf("another user's caller got %q, want NONE", got)
	}
	locPeer(t, 10*100000+10123)
	if got := driveLogin(t, t.TempDir(), "APPLY-LOCATION\n"); got != "NONE" {
		t.Errorf("with no session the reply was %q, want NONE", got)
	}
	rec.none(t, "refused callers")

	locGlobalsSupported = func() bool { return false } // Diaspore
	if got := driveLogin(t, dest, "APPLY-LOCATION\n"); got != "OK UNAVAILABLE" {
		t.Errorf("without the provider the reply was %q, want OK UNAVAILABLE", got)
	}
	rec.none(t, "an image without the provider")
}

// A worker reply reaches the chooser as one line of roamd's vocabulary, whatever the worker printed.
func TestApplyLocationReplyIsOneSafeLine(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	locPeer(t, 10*100000+10123)
	locSetup(t, "ERR-LOC network_location=null,geocoder=?\nsecond line\x00")
	if got := driveLogin(t, dest, "APPLY-LOCATION\n"); got != "ERR-LOC network_location=null,geocoder=?" {
		t.Errorf("reply %q", got)
	}
}

// The guard under the slot: a claim runs only for the uid .roamsession names, and never for a session that is
// cold-locked or queued to be switched out; a release is never held back by it.
func TestLocClaimIsDroppedUnderTheSlotOnceItsSessionEnded(t *testing.T) {
	ropReapReset(t)
	t.Cleanup(func() { pendingReapMu.Lock(); pendingLockUID = ""; pendingReapMu.Unlock() })
	run := func(dest, op string) (string, []string) {
		stop := ropWorker(t, dest)
		out := runWorkerHeld(laneRW, dest, op, "live", "", "10", "", "", "", "", nil)
		return out, stop()
	}
	dest := t.TempDir()
	if out, ops := run(dest, "locapply"); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("no session: %q, worker saw %v -- want SKIP-ENDED and nothing written", out, ops)
	}
	if err := markRoamSession(dest, "bob", "pw", "11", ""); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest, "locapply"); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("another user is live: %q, %v", out, ops)
	}
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest, "locapply"); out != "ERR-PIN-TEST" || len(ops) != 1 || ops[0] != "locapply" {
		t.Fatalf("the live session's claim: %q, %v -- want it handed to the worker", out, ops)
	}
	for _, flag := range []*string{&pendingSwitchUID, &pendingReapUID, &pendingLockUID} {
		pendingReapMu.Lock()
		*flag = "10"
		pendingReapMu.Unlock()
		if out, ops := run(dest, "locapply"); out != "SKIP-ENDED" || len(ops) != 0 {
			t.Errorf("a session queued to be switched out: %q, %v", out, ops)
		}
		pendingReapMu.Lock()
		*flag = ""
		pendingReapMu.Unlock()
	}
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("alice\n10\n\nnokey\nnopin\nx\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, ops := run(dest, "locapply"); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("a cold-locked session: %q, %v", out, ops)
	}
	empty := t.TempDir()
	if out, ops := run(empty, "locrelease"); out != "ERR-PIN-TEST" || len(ops) != 1 {
		t.Errorf("a release with no session: %q, %v -- a release must always reach roamd", out, ops)
	}
}

// A claim for a user that no longer exists is dropped under the slot: the chooser abandoned that sign-in and removed the
// user, and nothing would ever release it.
func TestLocClaimForAGoneUserIsDroppedUnderTheSlot(t *testing.T) {
	ropReapReset(t)
	users := useTempUsersDir(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	run := func(op string) (string, []string) {
		stop := ropWorker(t, dest)
		out := runWorkerHeld(laneRW, dest, op, "signin", "", "10", "", "", "", "", nil)
		return out, stop()
	}
	if out, ops := run("locapply"); out != "SKIP-ENDED" || len(ops) != 0 {
		t.Errorf("a claim for user 10, which no longer exists: %q, worker saw %v -- want SKIP-ENDED and nothing written", out, ops)
	}
	if out, ops := run("locrelease"); out != "ERR-PIN-TEST" || len(ops) != 1 {
		t.Errorf("a release for a gone user: %q, %v -- a release must always reach roamd", out, ops)
	}
	if err := os.MkdirAll(filepath.Join(users, "10"), 0o700); err != nil {
		t.Fatal(err)
	}
	if out, ops := run("locapply"); out != "ERR-PIN-TEST" || len(ops) != 1 || ops[0] != "locapply" {
		t.Errorf("control: user 10 exists, but its claim got %q, %v", out, ops)
	}
}

// An abandoned sign-in whose claim had already landed: the chooser removed the user with a bare removeUser (no SWITCH,
// no REAP, no CLEAN-STORAGE), so the only thing that notices is clearing the gone user's marker -- and that gives the
// location globals back, once. roamd leaves them alone if another session owns them by then (test-locglobals.sh).
func TestClearingAGoneUsersMarkerReleasesLocGlobals(t *testing.T) {
	users := useTempUsersDir(t)
	if err := os.MkdirAll(filepath.Join(users, "10"), 0o700); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	rec := locSetup(t, "OK APPLIED network_location=2 geocoder=2")
	if got := claimLocGlobals(dest, "10", "signin"); got != "OK APPLIED network_location=2 geocoder=2" {
		t.Fatalf("the sign-in claim answered %q", got)
	}
	if c := rec.wait(t, "the sign-in claim"); c.op != "locapply" || c.uid != "10" {
		t.Fatalf("worker asked %+v, want locapply for user 10", c)
	}
	if got := clearMarkerOfGoneUser(dest); got != "" {
		t.Fatalf("control: user 10 exists, but clearMarkerOfGoneUser cleared %q", got)
	}
	rec.none(t, "a marker whose user still exists")
	if err := os.RemoveAll(filepath.Join(users, "10")); err != nil { // the chooser's stopRoamUser
		t.Fatal(err)
	}
	if got := clearMarkerOfGoneUser(dest); got != "10" {
		t.Fatalf("clearMarkerOfGoneUser = %q, want 10", got)
	}
	if c := rec.wait(t, "a release once the gone user's marker is cleared"); c.op != "locrelease" || c.why != "gone" || c.uid != "10" {
		t.Errorf("worker asked %+v, want locrelease/gone for user 10", c)
	}
	if got := clearMarkerOfGoneUser(dest); got != "" {
		t.Errorf("a second pass cleared %q -- the marker is already gone", got)
	}
	rec.none(t, "a second pass over a marker that is already gone")
}

// The gate switch of a session being REMOVED releases, once; a cold lock's switch and a stale or REAP ack do not.
func TestAckReapOfARemovalSwitchReleasesLocGlobals(t *testing.T) {
	gatePeer(t, 10123)
	ropReapReset(t)
	t.Cleanup(func() { pendingReapMu.Lock(); pendingLockUID = ""; pendingReapMu.Unlock() })
	rec := locSetup(t, "OK BASELINE")
	dest := t.TempDir()
	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID = "10", "10"
	pendingReapMu.Unlock()
	if got := driveLogin(t, dest, "ACK-REAP\nSWITCH\n10\n"); got != "OK" {
		t.Fatalf("ACK-REAP replied %q", got)
	}
	if c := rec.wait(t, "a logoff's gate switch"); c.op != "locrelease" || c.why != "signout" || c.uid != "10" {
		t.Errorf("worker asked %+v, want locrelease/signout for user 10", c)
	}
	driveLogin(t, dest, "ACK-REAP\nSWITCH\n10\n") // a redelivered ack: the switch is already retired
	driveLogin(t, dest, "ACK-REAP\nREAP\n10\n")
	rec.none(t, "a repeated SWITCH ack and the REAP ack")

	pendingReapMu.Lock()
	pendingSwitchUID, pendingLockUID = "11", "11" // a cold lock: switch + LOCK, no REAP
	pendingReapMu.Unlock()
	driveLogin(t, dest, "ACK-REAP\nSWITCH\n11\n")
	rec.none(t, "a cold lock's switch (it releases inside its own teardown)")

	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID = "12", "12"
	pendingReapMu.Unlock()
	driveLogin(t, dest, "ACK-REAP\nSWITCH\n13\n")
	rec.none(t, "a stale ack for another uid")

	locGlobalsSupported = func() bool { return false }
	driveLogin(t, dest, "ACK-REAP\nSWITCH\n12\n")
	rec.none(t, "an image without the provider")
}

// The cold lock releases INSIDE its RW hold, past the point of no return, after btpark and before the switch.
func TestColdLockReleasesLocGlobalsInsideItsHold(t *testing.T) {
	dest, rec, _ := clwSetup(t)
	prev := locGlobalsSupported
	locGlobalsSupported = func() bool { return true }
	t.Cleanup(func() { locGlobalsSupported = prev })
	clwLock(t, dest, 0)
	if !clwWaitFor(3*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the cold lock never completed")
	}
	calls := rec.snapshot()
	lr, bp, n := -1, -1, 0
	for i, c := range calls {
		switch c.op {
		case "locrelease":
			lr, n = i, n+1
		case "btpark":
			bp = i
		}
	}
	if n != 1 {
		t.Fatalf("ops = %v, want exactly one locrelease", rec.ops())
	}
	c := calls[lr]
	if !c.rwHeld || c.slotLen != 1 {
		t.Errorf("locrelease ran outside the teardown's hold (rwHeld=%v slot=%d)", c.rwHeld, c.slotLen)
	}
	if !c.coldlock || c.roamsession {
		t.Errorf("locrelease ran before the point of no return (coldlock=%v roamsession=%v) -- a revoked lock would lose its choice", c.coldlock, c.roamsession)
	}
	if bp < 0 || lr < bp {
		t.Errorf("ops = %v, want locrelease after btpark", rec.ops())
	}
	if c.switchUID != "" {
		t.Errorf("the switch was published BEFORE the release -- the gate shows with the session's location on")
	}
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags = %q/%q, want 10/10", sw, lk)
	}
}

// An offline sign-in claims (the baseline, from its empty prefs) once the session is recorded.
func TestOfflineSignInClaimsLocGlobalsAfterTheMarker(t *testing.T) {
	dest := t.TempDir()
	stop := ropWorker(t, dest) // answers the btwipe at once
	defer stop()
	rec := locSetup(t, "OK APPLIED network_location=0 geocoder=0")
	cli, srv := net.Pipe()
	go func() { handleRoamInOffline(srv, dest, "alice", "correct horse battery", "12"); srv.Close() }()
	buf := make([]byte, 64)
	nr, _ := cli.Read(buf)
	cli.Close()
	if got := strings.TrimSpace(string(buf[:nr])); got != "OK 12" {
		t.Fatalf("offline sign-in replied %q", got)
	}
	c := rec.wait(t, "an offline sign-in")
	if c.op != "locapply" || c.why != "offline" || c.uid != "12" || c.live != "12" {
		t.Errorf("worker asked %+v, want locapply/offline for user 12 with .roamsession naming it", c)
	}
}

// A resumed session claims again, after its marker is written and the cold-lock marker is gone.
func TestResumeClaimsLocGlobalsAgain(t *testing.T) {
	l := crLock(t, crKinds[0])
	rec := locSetup(t, "OK APPLIED network_location=2 geocoder=0")
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
		t.Fatalf("the resume was refused (%q)", got)
	}
	c := rec.wait(t, "a resume")
	if c.op != "locapply" || c.why != "resume" || c.uid != "10" || c.live != "10" || c.coldlock {
		t.Errorf("worker asked %+v, want locapply/resume for user 10, recorded and no longer cold-locked", c)
	}
}

// A refused resume claims nothing.
func TestRefusedResumeClaimsNothing(t *testing.T) {
	l := crLock(t, crKinds[0])
	rec := locSetup(t, "OK APPLIED network_location=2 geocoder=0")
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	if got := crResume(t, l.dest, "not-the-passphrase"); got == "OK 10" {
		t.Fatal("control failed: a wrong entry resumed")
	}
	rec.none(t, "a refused resume")
}

// The claim sites, pinned in the source: an asynchronous claim's order against the marker write cannot be seen from
// its call (the goroutine may run after the marker either way), and driving handleRoamIn needs a store. Each claim
// comes after its session marker is written and a refusal to write it has returned; the sign-in's comes before the
// throwaway branch, so a throwaway claims too, and the resume's after the cold-lock marker is gone.
func TestEverySignInClaimsLocGlobalsAfterTheMarker(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	fn := func(from, to string) string {
		t.Helper()
		i, j := strings.Index(s, from), strings.Index(s, to)
		if i < 0 || j < i {
			t.Fatalf("%s not found", from)
		}
		return s[i:j]
	}
	at := func(body, name, needle string) int {
		t.Helper()
		if n := strings.Count(body, needle); n != 1 {
			t.Fatalf("%q appears %d times in %s, want 1", needle, n, name)
		}
		return strings.Index(body, needle)
	}
	in := fn("func handleRoamIn(", "func handleRoamInOffline(")
	mark := at(in, "handleRoamIn", "if err := markRoamSession(dest, name, pass, uid, seSecret); err != nil {")
	refused := at(in, "handleRoamIn", `fmt.Fprint(conn, "ERR-UNRECORDED\n")`)
	claim := at(in, "handleRoamIn", `claimLocGlobalsAsync(dest, uid, "signin")`)
	throwaway := at(in, "handleRoamIn", `if head == "" {`+"\n\t\t\tmarkLocalSession(dest)")
	if !(mark < refused && refused < claim && claim < throwaway) {
		t.Errorf("sign-in order: marker %d, refusal %d, claim %d, throwaway branch %d -- want the claim after the "+
			"refusal returned and before the throwaway branch", mark, refused, claim, throwaway)
	}
	off := fn("func handleRoamInOffline(", "func handleRelogin(")
	mark = at(off, "handleRoamInOffline", `if err := markRoamSession(dest, name, pass, uid, ""); err != nil {`)
	refused = at(off, "handleRoamInOffline", `fmt.Fprint(conn, "ERR-UNRECORDED\n")`)
	claim = at(off, "handleRoamInOffline", `claimLocGlobalsAsync(dest, uid, "offline")`)
	if !(mark < refused && refused < claim) {
		t.Errorf("offline order: marker %d, refusal %d, claim %d -- want the claim after the refusal returned",
			mark, refused, claim)
	}
	res := fn("func handleResume(", "func purgeLocalProfileState(")
	mark = at(res, "handleResume", "if err := markRoamSession(dest, name, pass, uid, se); err != nil {")
	gone := at(res, "handleResume", `os.Remove(filepath.Join(dest, ".coldlock"))`)
	claim = at(res, "handleResume", `claimLocGlobalsAsync(dest, uid, "resume")`)
	if !(mark < gone && gone < claim) {
		t.Errorf("resume order: marker %d, cold-lock marker removed %d, claim %d -- want the claim after both",
			mark, gone, claim)
	}
}

// Without the provider nothing reaches roamd from any of the helpers -- the Diaspore guarantee on the daemon side.
func TestLocGlobalsHelpersAreInertWithoutTheProvider(t *testing.T) {
	rec := locSetup(t, "OK")
	locGlobalsSupported = func() bool { return false }
	if got := claimLocGlobals(t.TempDir(), "10", "live"); got != "OK UNAVAILABLE" {
		t.Errorf("claimLocGlobals = %q", got)
	}
	claimLocGlobalsAsync(t.TempDir(), "10", "signin")
	releaseLocGlobalsAsync(t.TempDir(), "10", "signout")
	prevW := coldLockWorker
	asked := 0
	coldLockWorker = func(dest, op, name, pass, uid, se string, rwHeld bool) string { asked++; return "OK" }
	releaseLocAtLock(t.TempDir(), "10")
	coldLockWorker = prevW
	rec.none(t, "the helpers on an image without the provider")
	if asked != 0 {
		t.Errorf("releaseLocAtLock dispatched %d op(s)", asked)
	}
}

func TestLocReplyToken(t *testing.T) {
	for in, want := range map[string]string{
		"OK APPLIED network_location=2 geocoder=0":       "OK APPLIED network_location=2 geocoder=0",
		"ERR-LOC network_location=?,geocoder=null\nmore": "ERR-LOC network_location=?,geocoder=null",
		"OK \"alice\" /data/user/10":                     "OK alice datauser10",
		"":                                               "",
		strings.Repeat("A", 200):                         strings.Repeat("A", 80),
	} {
		if got := locReplyToken(in); got != want {
			t.Errorf("locReplyToken(%q) = %q, want %q", in, got, want)
		}
	}
}
