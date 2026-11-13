package main

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
)

// NWP-20261116-01 (h46 #1, docs/product-decisions.md 2026-10-28): the late sign-in job (late_work.go). autoPublish and
// enrollUnitAtLogin run after the ROAM-IN reply; LOGOUT, DELETE, the cold locks, BACKUP and syncLoop wait for the job
// up to lateWorkBound and then mark it abandoned; every write re-checks the mark and .roamsession. lateWorkCur and the
// seams are package globals: none of these tests may run in parallel.

// lateWorkHang is each test's own hang guard: a wait that never ends (mutant L6) fails here, not at go test's cap.
const lateWorkHang = 10 * time.Second

// lateWorkDrain waits out any late job in t.Cleanup, so no late goroutine outlives its test. Call it AFTER the store
// fixture: cleanups run last-in first-out, so the job ends before the fake store closes.
func lateWorkDrain(t *testing.T) {
	t.Helper()
	t.Cleanup(func() {
		lateWorkMu.Lock()
		lw := lateWorkCur
		lateWorkMu.Unlock()
		if lw == nil {
			return
		}
		select {
		case <-lw.done:
		case <-time.After(30 * time.Second):
			t.Errorf("a late sign-in job was still running 30 s after its test ended")
		}
		lateWorkMu.Lock()
		if lateWorkCur == lw {
			lateWorkCur = nil
		}
		lateWorkMu.Unlock()
	})
}

// lateWorkFresh starts a test with no job, finished or not, and drains whatever the test starts.
func lateWorkFresh(t *testing.T) {
	t.Helper()
	lateWorkMu.Lock()
	lw := lateWorkCur
	lateWorkMu.Unlock()
	if lw != nil {
		select {
		case <-lw.done:
		case <-time.After(lateWorkHang):
			t.Fatal("an earlier test's late job is still running")
		}
	}
	lateWorkMu.Lock()
	lateWorkCur = nil
	lateWorkMu.Unlock()
	lateWorkDrain(t)
}

// lateWorkShrink sets lateWorkBound for one test.
func lateWorkShrink(t *testing.T, d time.Duration) {
	t.Helper()
	old := lateWorkBound
	lateWorkBound = d
	t.Cleanup(func() { lateWorkBound = old })
}

// lateWorkMarker writes a complete .roamsession naming uid.
func lateWorkMarker(t *testing.T, dest, uid string) {
	t.Helper()
	writeMarker(t, dest, "lw-marker\nlw marker passphrase\n"+uid+"\n")
}

// lateWorkProbe is a started job whose one step blocks until release, then sends what lw.mayWrite() said.
type lateWorkProbe struct {
	lw      *lateWork
	release func()
	wrote   chan bool
}

// lateWorkBlockedJob starts a job for dest/uid whose step blocks. The release is registered in t.Cleanup after the
// drain, so it runs first and the drain never waits on a step that is still blocked.
func lateWorkBlockedJob(t *testing.T, dest, uid string) *lateWorkProbe {
	t.Helper()
	gate, ran := make(chan struct{}), make(chan struct{})
	var once sync.Once
	p := &lateWorkProbe{release: func() { once.Do(func() { close(gate) }) }, wrote: make(chan bool, 1)}
	startLateWork(dest, uid, func(lw *lateWork) {
		close(ran)
		<-gate
		p.wrote <- lw.mayWrite()
	})
	t.Cleanup(p.release)
	select {
	case <-ran:
	case <-time.After(lateWorkHang):
		t.Fatal("the late job's step never started")
	}
	lateWorkMu.Lock()
	p.lw = lateWorkCur
	lateWorkMu.Unlock()
	return p
}

// lateWrite releases the step and returns what its pre-write check said.
func (p *lateWorkProbe) lateWrite(t *testing.T) bool {
	t.Helper()
	p.release()
	select {
	case w := <-p.wrote:
		return w
	case <-time.After(lateWorkHang):
		t.Fatal("the released step never reached its write")
	}
	return true
}

// lateWorkReply drives h over a pipe and returns the whole reply and the daemon's log, failing after lateWorkHang.
func lateWorkReply(t *testing.T, h func(net.Conn)) (reply, log string) {
	t.Helper()
	log = captureStderr(t, func() {
		c := make(chan string, 1)
		go func() { c <- ropReply(t, h) }()
		select {
		case reply = <-c:
		case <-time.After(lateWorkHang):
			t.Fatalf("no reply within %v: the wait for the late job never ended", lateWorkHang)
		}
	})
	return reply, log
}

// lateWorkRecConn records every write on the conn into the shared ordered log.
type lateWorkRecConn struct {
	net.Conn
	add func(string)
}

func (c *lateWorkRecConn) Write(b []byte) (int, error) {
	c.add("write:" + string(b))
	return c.Conn.Write(b)
}

// lateWorkSeams stubs the start seam and the vpnup worker (a real OK sign-in starts the vpnup retry) for one test.
func lateWorkSeams(t *testing.T, started func()) {
	t.Helper()
	oldS, oldW, oldSl := lateWorkStarted, vpnupWorker, vpnupSleep
	t.Cleanup(func() { lateWorkStarted, vpnupWorker, vpnupSleep = oldS, oldW, oldSl })
	lateWorkStarted = started
	vpnupWorker = func(dest, name, pass, uid string) string { return "OK NONE" }
	vpnupSleep = func(time.Duration) {}
}

// The ROAM-IN reply is on the conn before the late job starts, and so is everything else the handler writes (the
// LASTSEAL line). Mutant L5 starts the job before the reply.
func TestLateWorkReplyBeforeTheMovedSteps(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
	lateWorkFresh(t)
	var mu sync.Mutex
	var log []string
	add := func(s string) { mu.Lock(); log = append(log, s); mu.Unlock() }
	lateWorkSeams(t, func() { add("late-start") })
	reply, _ := lateWorkReply(t, func(c net.Conn) {
		handleRoamIn(&lateWorkRecConn{Conn: c, add: add}, f.dest, walletFailName, walletFailPass, "21", "", "")
	})
	if !strings.HasPrefix(reply, "OK 21") && !strings.Contains(reply, "\nOK 21") {
		t.Fatalf("control failed: the sign-in replied %q, want OK 21", reply)
	}
	mu.Lock()
	defer mu.Unlock()
	start, okAt := -1, -1
	for i, e := range log {
		switch {
		case e == "late-start":
			start = i
		case strings.HasPrefix(e, "write:OK 21"):
			okAt = i
		}
	}
	if start < 0 {
		t.Fatalf("a stored profile's sign-in started no late job; log %q", log)
	}
	if okAt < 0 || okAt > start {
		t.Fatalf("the late job started before the OK reply was written (h46 #1); log %q", log)
	}
	for _, e := range log[start:] {
		if strings.HasPrefix(e, "write:") {
			t.Fatalf("the handler wrote %q after the late job started; log %q", e, log)
		}
	}
}

// A throwaway (no head in the store) returns before any late step: no job.
func TestLateWorkThrowawayStartsNoJob(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
	lateWorkFresh(t)
	var started atomic.Bool
	lateWorkSeams(t, func() { started.Store(true) })
	reply, _ := lateWorkReply(t, func(c net.Conn) {
		handleRoamIn(c, f.dest, "lw-throwaway", "a passphrase with no profile", "21", "", "")
	})
	if reply != "OK 21" {
		t.Fatalf("control failed: the throwaway sign-in replied %q, want OK 21", reply)
	}
	lateWorkMu.Lock()
	cur := lateWorkCur
	lateWorkMu.Unlock()
	if started.Load() || cur != nil {
		t.Fatal("a throwaway sign-in started a late job; it must return before any late step (h46 #1)")
	}
}

// The moved steps are gone from before the reply, every step the decision keeps there is still there, and the job
// runs discovery, then the enrolment.
func TestLateWorkSourceOrder(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\nfunc handleRoamIn(")
	j := strings.Index(src, "\nfunc handleRoamInOffline(")
	if i < 0 || j < i {
		t.Fatal("control failed: handleRoamIn not found")
	}
	body := src[i:j]
	for _, re := range []string{`[^.\w]autoPublish\(`, `[^.\w]enrollUnitAtLogin\(`, `[^.\w]roamInWallet\(`, `[^.\w]telHandoffRoamIn\(`} {
		if regexp.MustCompile(re).MatchString(body) {
			t.Errorf("handleRoamIn still calls %s directly; it runs in the late job (h46 #1)", re)
		}
	}
	reply := strings.Index(body, `fmt.Fprintf(conn, "%s RECOVERY %s\n", out, recovery)`)
	late := strings.Index(body, "startLateWork(dest, uid,")
	throwaway := strings.Index(body, "if head == \"\" {\n\t\t\tmarkLocalSession(dest)")
	if reply < 0 || late < 0 || throwaway < 0 {
		t.Fatalf("control failed: reply %d, startLateWork %d, throwaway branch %d", reply, late, throwaway)
	}
	if late < reply {
		t.Error("startLateWork comes before the reply")
	}
	for _, stay := range []string{"markRoamSession(dest,", "removeWallet(walletPathFor(dest))", "vaultLocked(headVault,",
		"stashRoamInPIN(dest,", "migrateVault(\"s3\"", "getHeadBlob(\"s3\", head)", "beginTelHandoff(uid)",
		"holdTelStagingUntilClaim(uid)"} {
		k := strings.Index(body, stay)
		if k < 0 || k > reply {
			t.Errorf("%s is no longer before the reply (at %d, reply at %d)", stay, k, reply)
		}
	}
	// NWP-20261116-03: the hand-off is pending before the hold, after the throwaway return.
	if b, h := strings.Index(body, "beginTelHandoff(uid)"), strings.Index(body, "holdTelStagingUntilClaim(uid)"); b < throwaway || b > h {
		t.Errorf("beginTelHandoff(uid) must come after the throwaway return and before the hold (at %d, hold %d, throwaway %d)", b, h, throwaway)
	}
	if throwaway > late {
		t.Error("the throwaway branch no longer returns before the late job")
	}
	wal := strings.Index(body[late:], "roamInWalletGuarded(\"s3\", lateName, latePass, lateSE, lateWallet, lw.mayWrite)")
	tel := strings.Index(body[late:], "telHandoffRoamInGuarded(lateName, latePass, lateHead, lateSE, lateUID, lateStale, lw.mayWrite)")
	pub := strings.Index(body[late:], "autoPublishGuarded(lateName, latePass, lw.mayWrite)")
	enr := strings.Index(body[late:], "enrollUnitAtLoginGuarded(\"s3\", lateName, latePass, lateSE, lw.mayWrite)")
	if wal < 0 || tel < 0 || pub < 0 || enr < 0 || wal > tel || tel > pub || pub > enr {
		t.Errorf("the late job must run roamInWalletGuarded, telHandoffRoamInGuarded, autoPublishGuarded, then "+
			"enrollUnitAtLoginGuarded (at %d, %d, %d, %d)", wal, tel, pub, enr)
	}
}

// Each of the six entries waits, once, before anything else it does.
func TestLateWorkEveryTeardownWaits(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, c := range []struct{ head, call, before string }{
		{"\nfunc handleLogout(", `waitLateWorkConn(conn, loginConnDeadline, true, "logout")`, "restartPending()"},
		{"\nfunc handleDelete(", `waitLateWorkConn(conn, 120*time.Second, false, "delete")`, "armStoreGiveUp(\"delete\")"},
		{"\nfunc handleColdLock(", `waitLateWork("cold lock")`, "coldLockTeardown(dest, name, pass, uid, b)"},
		{"\nvar coldLockSignOut = func(", `waitLateWork("cold-lock sign-out")`, "handleLogout(server, dest)"},
		{"\nfunc handleBackup(", `waitLateWork("backup")`, "readRoamSession(dest)"},
		{"\nfunc syncLoop(", `waitLateWork("periodic seal")`, "readRoamSession(dest)"},
	} {
		i := strings.Index(src, c.head)
		if i < 0 {
			t.Fatalf("control failed: %s not found", c.head)
		}
		body := src[i : i+1+strings.Index(src[i+1:], "\n}\n")]
		w, x := strings.Index(body, c.call), strings.Index(body, c.before)
		if strings.Count(body, c.call) != 1 || x < 0 || w > x {
			t.Errorf("%s: want one %s before %s (wait at %d, %d)", strings.TrimSpace(c.head), c.call, c.before, w, x)
		}
	}
}

// LOGOUT waits for a blocked job, then goes ahead at the bound with the job abandoned; the step's write afterwards
// writes nothing. Mutant L1 (no wait) answers at once with the job still live; L6 (no bound) hangs.
func TestLateWorkLogoutWaitsThenAbandons(t *testing.T) {
	lateWorkFresh(t)
	ropReapReset(t)
	lateWorkShrink(t, 300*time.Millisecond)
	dest := t.TempDir()
	lateWorkMarker(t, dest, "31")
	markLocalSession(dest) // a throwaway: LOGOUT answers OK with no seal
	p := lateWorkBlockedJob(t, dest, "31")
	t0 := time.Now()
	reply, log := lateWorkReply(t, func(c net.Conn) { handleLogout(c, dest) })
	if reply != "OK" {
		t.Fatalf("LOGOUT replied %q, want OK", reply)
	}
	if !p.lw.abandoned.Load() {
		t.Fatal("LOGOUT answered with the late job neither ended nor abandoned: it did not wait (h46 #1)")
	}
	if waited := time.Since(t0); waited < lateWorkBound {
		t.Fatalf("LOGOUT answered after %v, before the bound %v", waited, lateWorkBound)
	}
	if !strings.Contains(log, "[logind] late sign-in work abandoned after 0s for logout (h46 #1)") {
		t.Fatalf("no abandon line in the log:\n%s", log)
	}
	if p.lateWrite(t) {
		t.Fatal("the abandoned step's pre-write check said it may still write")
	}
}

// DELETE waits the same way, and only then reaches its store work; it writes no WAIT line (its reader takes one line).
// Mutant L2 reaches the delete with the job still live.
func TestLateWorkDeleteWaitsThenAbandons(t *testing.T) {
	lateWorkFresh(t)
	lateWorkShrink(t, 300*time.Millisecond)
	logoutWaitVars(t, loginConnDeadline, 50*time.Millisecond, 50*time.Millisecond)
	dest := t.TempDir()
	lateWorkMarker(t, dest, "32")
	p := lateWorkBlockedJob(t, dest, "32")
	var reached, abandonedThen atomic.Bool
	old := deleteForSessionFn
	t.Cleanup(func() { deleteForSessionFn = old })
	deleteForSessionFn = func(base, name, pass, ln, lp string, se []byte) string {
		reached.Store(true)
		abandonedThen.Store(p.lw.abandoned.Load())
		return "wrongpass" // nothing deleted, no reap: the marker stays
	}
	reply, log := lateWorkReply(t, func(c net.Conn) { handleDelete(c, dest, "lw-delete", "lw delete passphrase", -1) })
	if reply != "NOTFOUND" {
		t.Fatalf("DELETE replied %q, want exactly NOTFOUND (no WAIT line)", reply)
	}
	if !reached.Load() || !abandonedThen.Load() {
		t.Fatalf("DELETE reached its store work (%v) with the late job not yet abandoned: it did not wait (h46 #1)", reached.Load())
	}
	if !strings.Contains(log, "late sign-in work abandoned after 0s for delete (h46 #1)") {
		t.Fatalf("no abandon line in the log:\n%s", log)
	}
	// The marker still names user 32, so only the abandoned mark stops the write (mutant L3).
	if p.lateWrite(t) {
		t.Fatal("the abandoned step's pre-write check said it may still write")
	}
}

// The marker rules (retryVpnup's): absent or another uid stops a step; a damaged marker with an empty uid does not.
func TestLateWorkMarkerRules(t *testing.T) {
	for _, c := range []struct {
		name, marker string
		want         bool
	}{
		{"a delete issued first: no marker", "", false},
		{"a marker naming another uid", "lw-marker\nlw marker passphrase\n44\n", false},
		{"a damaged marker with an empty uid", "lw-marker\nlw marker passphrase\n", true},
		{"a complete marker for this uid", "lw-marker\nlw marker passphrase\n33\n", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			dest := t.TempDir()
			if c.marker != "" {
				writeMarker(t, dest, c.marker)
			}
			lw := &lateWork{dest: dest, uid: "33", done: make(chan struct{})}
			if got := lw.mayWrite(); got != c.want {
				t.Fatalf("mayWrite = %v, want %v", got, c.want)
			}
			lw.abandoned.Store(true)
			if lw.mayWrite() {
				t.Fatal("an abandoned job may still write")
			}
		})
	}
}

// The real guarded steps against a fake store: a check that says no at the start derives no key and writes nothing; one
// that says no just before the write writes nothing; nil writes (the control).
func TestLateWorkGuardedStepsWriteNothingAfterAbandon(t *testing.T) {
	never := func() bool { return false }
	once := func() func() bool { // yes at the start, no before the write
		var n atomic.Int32
		return func() bool { return n.Add(1) == 1 }
	}
	t.Run("enrollUnitAtLogin", func(t *testing.T) {
		base := newHTTPStore(t)
		const name, pass = "lw-enrol", "lw enrol passphrase"
		old := unitIDPath
		t.Cleanup(func() { unitIDPath = old })
		unitIDPath = filepath.Join(t.TempDir(), "unit-id")
		blobCache, contentCache = nil, nil
		createVault(base, name, pass)
		t.Setenv("NOWHERE_MULTIDEVICE", "1")
		dk := resolveDK(base, name, pass, nil)

		deriveKeyForget()
		enrollUnitAtLoginGuarded(base, name, pass, nil, never)
		deriveKeyMu.Lock()
		keys := len(deriveKeyCache)
		deriveKeyMu.Unlock()
		if keys != 0 {
			t.Fatalf("a step refused at its start derived %d key(s) (dn-1106 #1)", keys)
		}
		if _, ok := loadAccountDir(base, name, pass, dk); ok {
			t.Fatal("a step refused at its start wrote the account directory")
		}
		enrollUnitAtLoginGuarded(base, name, pass, nil, once())
		if _, ok := loadAccountDir(base, name, pass, dk); ok {
			t.Fatal("a step refused just before its write wrote the account directory")
		}
		enrollUnitAtLoginGuarded(base, name, pass, nil, nil)
		if d, ok := loadAccountDir(base, name, pass, dk); !ok || len(d.Units) != 1 {
			t.Fatal("control failed: an unguarded enrolment wrote no directory")
		}
	})
	t.Run("autoPublish", func(t *testing.T) {
		base := newHTTPStore(t)
		const name, pass = "lw-publish", "lw publish passphrase"
		for k, v := range map[string]string{"DISCO_ENDPOINT": "https://disco.test", "DISCO_BUCKET": "d", "DISCO_ACCESS_KEY": "dak",
			"DISCO_SECRET_KEY": "dsk", "S3_ENDPOINT": "https://s3.test", "S3_BUCKET": "b", "S3_ACCESS_KEY": "ak",
			"S3_SECRET_KEY": "sk", "GATEWAY_URL": ""} {
			t.Setenv(k, v)
		}
		if !discoConfigured() || !storeConfigured() {
			t.Fatal("control failed: discovery or the store is not configured")
		}
		autoPublishTo(base, name, pass, never)
		if _, ok := discoverConfig(base, name, pass); ok {
			t.Fatal("a step refused at its start published discovery")
		}
		autoPublishTo(base, name, pass, once())
		if _, ok := discoverConfig(base, name, pass); ok {
			t.Fatal("a step refused just before its write published discovery")
		}
		autoPublishTo(base, name, pass, nil)
		if _, ok := discoverConfig(base, name, pass); !ok {
			t.Fatal("control failed: an unguarded publish wrote nothing")
		}
	})
}

// BACKUP and a syncLoop cycle wait for a blocked job and go ahead at the bound; a finished job costs no wait.
func TestLateWorkBackupAndSyncLoopWait(t *testing.T) {
	t.Run("BACKUP", func(t *testing.T) {
		lateWorkFresh(t)
		lateWorkShrink(t, 300*time.Millisecond)
		dest := t.TempDir()
		p := lateWorkBlockedJob(t, dest, "34")
		reply, log := lateWorkReply(t, func(c net.Conn) { handleBackup(c, dest) })
		if reply != "NONE" {
			t.Fatalf("BACKUP with no session replied %q, want NONE", reply)
		}
		if !p.lw.abandoned.Load() || !strings.Contains(log, "for backup (h46 #1)") {
			t.Fatalf("BACKUP did not wait for the late job (abandoned %v):\n%s", p.lw.abandoned.Load(), log)
		}
	})
	t.Run("a syncLoop cycle", func(t *testing.T) {
		lateWorkFresh(t)
		resetSealSignals() // NWP-20261202-10: no landed save, so the change test answers nobase and runs no probe
		lateWorkShrink(t, 300*time.Millisecond)
		dest := t.TempDir()
		p := lateWorkBlockedJob(t, dest, "35")
		old := syncLoopSleep
		t.Cleanup(func() { syncLoopSleep = old })
		var sleeps atomic.Int32
		var abandonedAtNext atomic.Bool
		syncLoopSleep = func(time.Duration) {
			if sleeps.Add(1) > 1 {
				abandonedAtNext.Store(p.lw.abandoned.Load())
				runtime.Goexit()
			}
		}
		log := captureStderr(t, func() {
			done := make(chan struct{})
			go func() { defer close(done); syncLoop(dest) }()
			select {
			case <-done:
			case <-time.After(lateWorkHang):
				t.Fatalf("one syncLoop cycle did not end within %v", lateWorkHang)
			}
		})
		if !abandonedAtNext.Load() || !strings.Contains(log, "for periodic seal (h46 #1)") {
			t.Fatalf("the syncLoop cycle did not wait for the late job:\n%s", log)
		}
	})
	t.Run("a finished job costs no wait", func(t *testing.T) {
		lateWorkFresh(t)
		lateWorkShrink(t, time.Hour) // a wait that did not return at once would trip the hang guard
		dest := t.TempDir()
		startLateWork(dest, "36")
		lateWorkMu.Lock()
		lw := lateWorkCur
		lateWorkMu.Unlock()
		select {
		case <-lw.done:
		case <-time.After(lateWorkHang):
			t.Fatal("an empty late job never finished")
		}
		reply, log := lateWorkReply(t, func(c net.Conn) { handleBackup(c, dest) })
		if reply != "NONE" || lw.abandoned.Load() || strings.Contains(log, "abandoned") {
			t.Fatalf("a finished job: reply %q, abandoned %v, log:\n%s", reply, lw.abandoned.Load(), log)
		}
	})
}

// With the entry deadline and the WAIT pacing shrunk below the bound, a LOGOUT behind a blocked job still answers OK,
// with WAIT lines before it (Q116). Mutant L8 (no re-arm, no WAIT line) lets the deadline expire and loses the OK.
func TestLateWorkLogoutSaysWaitUnderShrunkDeadlines(t *testing.T) {
	lateWorkFresh(t)
	ropReapReset(t)
	logoutWaitVars(t, 300*time.Millisecond, 100*time.Millisecond, 100*time.Millisecond)
	lateWorkShrink(t, time.Second)
	dest := t.TempDir()
	lateWorkBlockedJob(t, dest, "37")
	var got string
	captureStderr(t, func() {
		select {
		case got = <-driveLoginAsync(t, dest, "LOGOUT\n"):
		case <-time.After(lateWorkHang):
			t.Fatalf("LOGOUT gave no reply within %v", lateWorkHang)
		}
	})
	lines := strings.Split(got, "\n")
	if lines[len(lines)-1] != "OK" {
		t.Fatalf("LOGOUT behind a blocked late job answered %q, want WAIT lines then OK", got)
	}
	waits := lines[:len(lines)-1]
	if len(waits) < 1 {
		t.Fatalf("LOGOUT waited past logoutWaitFirst and wrote no WAIT line: %q", got)
	}
	re := regexp.MustCompile(`^WAIT [0-9]+$`)
	for _, l := range waits {
		if !re.MatchString(l) {
			t.Fatalf("line %q is not `WAIT <seconds>` in %q", l, got)
		}
	}
}

// The bound stays under handleLogin's entry deadline, so BACKUP's and the cold-lock sign-out's replies still land.
func TestLateWorkBoundUnderLoginDeadline(t *testing.T) {
	if !(lateWorkBound < loginConnDeadline) {
		t.Fatalf("lateWorkBound %v is not under loginConnDeadline %v", lateWorkBound, loginConnDeadline)
	}
}

// A panic in a step ends the job, and done is still closed. NWP-20261128-14: done closes mid-unwind, before runSafe
// prints the recovered line, so the closure also waits for the tracked job before captureStderr restores os.Stderr.
func TestLateWorkPanicClosesDone(t *testing.T) {
	tr := trackGoSafe(t)
	lateWorkFresh(t)
	var later atomic.Bool
	var lw *lateWork
	captureStderr(t, func() {
		startLateWork(t.TempDir(), "38",
			func(*lateWork) { panic("lw: a step that panics") },
			func(*lateWork) { later.Store(true) },
		)
		lateWorkMu.Lock()
		lw = lateWorkCur
		lateWorkMu.Unlock()
		select {
		case <-lw.done:
		case <-time.After(lateWorkHang):
			t.Fatal("a step's panic left done open")
		}
		tr.wait(t, lateWorkHang)
	})
	if later.Load() {
		t.Fatal("a step after the panic still ran")
	}
}

// A new sign-in's job first waits out the older one the same way.
func TestLateWorkNewSignInWaitsOutTheOlderJob(t *testing.T) {
	lateWorkFresh(t)
	lateWorkShrink(t, 300*time.Millisecond)
	dest := t.TempDir()
	lateWorkMarker(t, dest, "39")
	p := lateWorkBlockedJob(t, dest, "39")
	captureStderr(t, func() {
		started := make(chan struct{})
		go func() { defer close(started); startLateWork(dest, "40") }()
		select {
		case <-started:
		case <-time.After(lateWorkHang):
			t.Fatalf("a new sign-in's job did not start within %v: its wait for the older job never ended", lateWorkHang)
		}
	})
	if !p.lw.abandoned.Load() {
		t.Fatal("a new sign-in started its job with the older one neither ended nor abandoned")
	}
}

// RF-001: abandonment that lands WHILE a store request of the directory write blocks. The guard must be asked again
// when that request returns, before the next write begins: in direct mode between the blob upload and the ref PUT, in
// cap mode before the lease and before each PUT. The fake store abandons the job from inside the request.
func TestLateWorkDirectoryWriteStopsAfterAbandonMidRequest(t *testing.T) {
	enrolSetup := func(t *testing.T) (lw *lateWork) {
		t.Helper()
		old := unitIDPath
		t.Cleanup(func() { unitIDPath = old })
		unitIDPath = filepath.Join(t.TempDir(), "unit-id")
		dest := t.TempDir()
		lateWorkMarker(t, dest, "61")
		return &lateWork{dest: dest, uid: "61", done: make(chan struct{})}
	}
	t.Run("direct: abandoned during the blob upload", func(t *testing.T) {
		inner := newHTTPStore(t)
		const name, pass = "lw-mid-direct", "lw mid direct passphrase"
		blobCache, contentCache = nil, nil
		createVault(inner, name, pass)
		t.Setenv("NOWHERE_MULTIDEVICE", "1")
		lw := enrolSetup(t)
		target, err := url.Parse(inner)
		if err != nil {
			t.Fatal(err)
		}
		proxy := httputil.NewSingleHostReverseProxy(target)
		var armed, uploaded atomic.Bool
		var refsAfter atomic.Int32
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if armed.Load() && r.Method == "POST" && r.URL.Path == "/blob" {
				lw.abandoned.Store(true) // LOGOUT reached the bound while this upload ran
				uploaded.Store(true)
			}
			if uploaded.Load() && r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/") {
				refsAfter.Add(1)
			}
			proxy.ServeHTTP(w, r)
		}))
		t.Cleanup(srv.Close)
		base := srv.URL
		dk := resolveDK(base, name, pass, nil)
		armed.Store(true)
		enrollUnitAtLoginGuarded(base, name, pass, nil, lw.mayWrite)
		if !uploaded.Load() {
			t.Fatal("precondition: the directory blob was never uploaded, so this test checks nothing")
		}
		if n := refsAfter.Load(); n != 0 {
			t.Fatalf("the directory published %d ref PUT(s) after abandonment during the blob upload", n)
		}
		if _, ok := loadAccountDir(base, name, pass, dk); ok {
			t.Fatal("the account directory was written after the job was abandoned")
		}
	})
	capCase := func(t *testing.T, name string, arm func(abandon func())) (puts []string) {
		t.Helper()
		capLockEnv(t)
		const pass = "lw mid cap passphrase"
		createVault("s3", name, pass)
		t.Setenv("NOWHERE_MULTIDEVICE", "1")
		lw := enrolSetup(t)
		var mu sync.Mutex
		var abandonedAt atomic.Bool
		capStorePutHook = func(k string, _ []byte) error {
			if abandonedAt.Load() {
				mu.Lock()
				puts = append(puts, k)
				mu.Unlock()
			}
			return nil
		}
		arm(func() {
			if !abandonedAt.Load() {
				lw.abandoned.Store(true)
				abandonedAt.Store(true)
			}
		})
		enrollUnitAtLoginGuarded("s3", name, pass, nil, lw.mayWrite)
		if !abandonedAt.Load() {
			t.Fatal("precondition: the store request that abandons the job never ran, so this test checks nothing")
		}
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), puts...)
	}
	t.Run("cap: abandoned during the lease", func(t *testing.T) {
		puts := capCase(t, "lw-mid-lease", func(abandon func()) {
			capStoreLeaseSeen = func(leaseReq) { abandon() }
		})
		if len(puts) != 0 {
			t.Fatalf("the flush made %d PUT(s) after abandonment during the lease: %v", len(puts), puts)
		}
	})
	t.Run("cap: abandoned during the quote", func(t *testing.T) {
		var leased atomic.Bool
		puts := capCase(t, "lw-mid-quote", func(abandon func()) {
			capStoreQuote = func(http.Header, *quoteInfo) { abandon() }
			capStoreLeaseSeen = func(leaseReq) { leased.Store(true) }
		})
		if leased.Load() || len(puts) != 0 {
			t.Fatalf("the flush leased (%v) or made %d PUT(s) after abandonment during the quote", leased.Load(), len(puts))
		}
	})
	t.Run("cap: abandoned during the blob PUT", func(t *testing.T) {
		var during atomic.Bool
		puts := capCase(t, "lw-mid-put", func(abandon func()) {
			prev := capStorePutHook
			capStorePutHook = func(k string, b []byte) error {
				err := prev(k, b) // records only the PUTs after abandonment
				if strings.HasPrefix(k, "blob/") && !during.Load() {
					during.Store(true)
					abandon() // this PUT is in flight: it lands, nothing after it may begin
				}
				return err
			}
		})
		for _, k := range puts {
			if strings.HasPrefix(k, "ref/") {
				t.Fatalf("the flush PUT a pointer after abandonment during the blob upload: %v", puts)
			}
		}
	})
	// RF-001 (review of cc550c0dd): the ref PUT that was running when the job was abandoned FAILS, and capPutErr's
	// retry loop must not start a second request -- a retry landing after DELETE's purge would recreate the ref.
	t.Run("cap: abandoned during a failed ref PUT, before its retry", func(t *testing.T) {
		orb := s3RetryBase
		s3RetryBase = time.Millisecond
		t.Cleanup(func() { s3RetryBase = orb })
		var failed atomic.Bool
		puts := capCase(t, "lw-mid-ref-fail", func(abandon func()) {
			prev := capStorePutHook
			capStorePutHook = func(k string, b []byte) error {
				err := prev(k, b) // records only the PUTs after abandonment
				if strings.HasPrefix(k, "ref/") && !failed.Load() {
					failed.Store(true)
					abandon()                  // this PUT is in flight when LOGOUT or DELETE abandons the job ...
					return io.ErrUnexpectedEOF // ... and then it fails, so capPutErr would retry it
				}
				return err
			}
		})
		if !failed.Load() {
			t.Fatal("precondition: the flush never PUT a pointer, so this test checks nothing")
		}
		if len(puts) != 0 {
			t.Fatalf("the flush started %d PUT(s) after abandonment during a failed ref PUT (a retry): %v", len(puts), puts)
		}
	})
}

// lateWorkFakeS3 is a path-style S3 endpoint that counts object PUTs. onPut runs for each PUT, in arrival order, and
// returns the status to answer: a 503 is one minio and retryStore both retry.
func lateWorkFakeS3(t *testing.T, onPut func(n int32) int) (host string, puts *atomic.Int32) {
	t.Helper()
	puts = new(atomic.Int32)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		if r.Method != http.MethodPut {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		st := onPut(puts.Add(1))
		if st != http.StatusOK {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(st)
			io.WriteString(w, `<?xml version="1.0" encoding="UTF-8"?><Error><Code>SlowDown</Code><Message>slow down</Message></Error>`)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	return u.Host, puts
}

// RF-001, the direct paths: the S3 PUT (retryStore around minio, which also retries on its own) and the discovery PUT
// (minio's own retries only). The PUT that is running when the job is abandoned fails with a 503, and no request may
// begin after it. The unguarded control proves the fake store's 503 is retried at all.
func TestLateWorkDirectPutsStopRetryingAfterAbandon(t *testing.T) {
	orb, omr := s3RetryBase, minio.MaxRetry
	t.Cleanup(func() { s3RetryBase, minio.MaxRetry = orb, omr })
	s3RetryBase = time.Millisecond
	direct := func(t *testing.T, host string) {
		t.Helper()
		oc := s3client
		t.Cleanup(func() { s3client = oc })
		s3client = nil
		t.Setenv("S3_ENDPOINT", "http://"+host)
		t.Setenv("S3_REGION", "us-east-1")
		t.Setenv("S3_BUCKET", "lwbucket")
		t.Setenv("S3_ACCESS_KEY", "lw-ak")
		t.Setenv("S3_SECRET_KEY", "lw-sk")
	}
	disco := func(t *testing.T, host string) {
		t.Helper()
		oc := discoClient
		t.Cleanup(func() { discoClient = oc })
		discoClient = nil
		t.Setenv("DISCO_ENDPOINT", "http://"+host)
		t.Setenv("DISCO_REGION", "us-east-1")
		t.Setenv("DISCO_BUCKET", "lwdisco")
		t.Setenv("DISCO_ACCESS_KEY", "lw-dak")
		t.Setenv("DISCO_SECRET_KEY", "lw-dsk")
	}
	cases := []struct {
		name     string
		maxRetry int // minio's own attempts per PutObject: 1 leaves only retryStore's retries
		setup    func(*testing.T, string)
		put      func(mayWrite func() bool) error
	}{
		{"s3: retryStore's retry", 1, direct, func(mw func() bool) error { return s3PutGuarded("ref/lw-direct", []byte("v"), mw) }},
		{"s3: minio's own retry", 4, direct, func(mw func() bool) error { return s3PutGuarded("ref/lw-direct", []byte("v"), mw) }},
		{"disco: minio's own retry", 4, disco, func(mw func() bool) error { return discoPutGuarded("ref/lw-disco", []byte("v"), mw) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			minio.MaxRetry = c.maxRetry
			t.Run("unguarded control", func(t *testing.T) {
				host, puts := lateWorkFakeS3(t, func(n int32) int {
					if n == 1 {
						return http.StatusServiceUnavailable
					}
					return http.StatusOK
				})
				c.setup(t, host)
				if err := c.put(nil); err != nil {
					t.Fatalf("precondition: the unguarded PUT did not recover from one 503: %v", err)
				}
				if n := puts.Load(); n != 2 {
					t.Fatalf("precondition: the unguarded PUT made %d request(s), want 2 (one retry)", n)
				}
			})
			t.Run("abandoned during the failed PUT", func(t *testing.T) {
				var abandoned atomic.Bool
				host, puts := lateWorkFakeS3(t, func(n int32) int {
					abandoned.Store(true) // LOGOUT or DELETE reached the bound while this PUT ran
					return http.StatusServiceUnavailable
				})
				c.setup(t, host)
				err := c.put(func() bool { return !abandoned.Load() })
				if n := puts.Load(); n != 1 {
					t.Fatalf("the PUT made %d request(s) after abandonment during the first, want only that one", n-1)
				}
				if err == nil || !strings.Contains(err.Error(), "h46 #1") {
					t.Fatalf("the refused retry returned %v, want errLateWriteDenied", err)
				}
			})
			t.Run("denied before the first request", func(t *testing.T) {
				host, puts := lateWorkFakeS3(t, func(int32) int { return http.StatusOK })
				c.setup(t, host)
				c.put(func() bool { return false })
				if n := puts.Load(); n != 0 {
					t.Fatalf("a PUT denied before it began still sent %d request(s)", n)
				}
			})
		})
	}
}

// ---- NWP-20261116-03 (h46 #1, Part 2): roamInWallet and telHandoffRoamIn run in the late job ----

// lateWalletGate proxies f's store and, on every GET of (name, pass)'s #wallet head, calls onRead and then, when
// block is set, waits for the returned release. Call it BEFORE lateWorkFresh and register the release with t.Cleanup
// AFTER it: the cleanups then release the read, drain the job, and only then close the proxy.
func lateWalletGate(t *testing.T, f *walletFailFixture, name, pass string, block bool, onRead func()) (release func()) {
	t.Helper()
	whk := walletHeadKey("s3", name, pass)
	target, _ := url.Parse(f.srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	gate := make(chan struct{})
	var once sync.Once
	release = func() { once.Do(func() { close(gate) }) }
	if !block {
		release()
	}
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" && strings.Contains(r.URL.Query().Get("k"), whk) {
			onRead()
			<-gate
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() { release(); px.Close() })
	return release
}

// lateWorkWait blocks until the current late job ends.
func lateWorkWait(t *testing.T) {
	t.Helper()
	lateWorkMu.Lock()
	lw := lateWorkCur
	lateWorkMu.Unlock()
	if lw == nil {
		t.Fatal("no late job was started")
	}
	select {
	case <-lw.done:
	case <-time.After(lateWorkHang):
		t.Fatal("the late job did not end")
	}
}

// lateSignal is a non-blocking send on a one-slot channel.
func lateSignal(c chan struct{}) func() {
	return func() {
		select {
		case c <- struct{}{}:
		default:
		}
	}
}

// lateAwait fails the test when c is not signalled within lateWorkHang.
func lateAwait(t *testing.T, c chan struct{}, what string) {
	t.Helper()
	select {
	case <-c:
	case <-time.After(lateWorkHang):
		t.Fatalf("%s never happened", what)
	}
}

// lateGuard answers answers[i] at its i-th call and the last answer after that, and counts its calls.
func lateGuard(answers ...bool) (func() bool, *atomic.Int32) {
	var n atomic.Int32
	return func() bool {
		i := int(n.Add(1)) - 1
		if i >= len(answers) {
			i = len(answers) - 1
		}
		return answers[i]
	}, &n
}

// lateSignIn drives a stored profile's ROAM-IN to OK 21 over a recording conn; f's store already carries the gate.
func lateSignIn(t *testing.T, f *walletFailFixture, add func(string)) {
	t.Helper()
	reply, _ := lateWorkReply(t, func(c net.Conn) {
		handleRoamIn(&lateWorkRecConn{Conn: c, add: add}, f.dest, walletFailName, walletFailPass, "21", "", "")
	})
	if !strings.HasPrefix(reply, "OK 21") && !strings.Contains(reply, "\nOK 21") {
		t.Fatalf("control failed: the sign-in replied %q, want OK 21", reply)
	}
}

// lateOrderLog is a test's shared ordered log.
type lateOrderLog struct {
	mu sync.Mutex
	l  []string
}

func (o *lateOrderLog) add(s string) { o.mu.Lock(); o.l = append(o.l, s); o.mu.Unlock() }

// at is the index of the first entry with prefix p, or -1.
func (o *lateOrderLog) at(p string) int {
	o.mu.Lock()
	defer o.mu.Unlock()
	for i, e := range o.l {
		if strings.HasPrefix(e, p) {
			return i
		}
	}
	return -1
}

// The ROAM-IN reply is written before roamInWallet's first store read. Mutant L15 puts roamInWallet back before the
// reply.
func TestLateWorkReplyBeforeTheWalletRead(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
	var o lateOrderLog
	lateWalletGate(t, f, walletFailName, walletFailPass, false, func() { o.add("wallet-read") })
	lateWorkFresh(t)
	lateWorkSeams(t, func() {})
	lateSignIn(t, f, o.add)
	lateWorkWait(t)
	okAt, readAt := o.at("write:OK 21"), o.at("wallet-read")
	if okAt < 0 || readAt < 0 || readAt < okAt {
		t.Fatalf("the wallet read (at %d) must come after the OK reply (at %d) (h46 #1); log %q", readAt, okAt, o.l)
	}
	if walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("the late wallet restore did not land")
	}
	if w, err := loadWallet(f.wpath); err != nil || w.balance() != f.stored {
		t.Fatalf("the late restore left %v tokens (err %v), want %d", w, err, f.stored)
	}
}

// A BACKUP issued while roamInWallet blocks waits for the landing; at the bound it goes ahead, the job is abandoned,
// and the landing then writes nothing: the generation stays without a proof, so nothing publishes a wallet.
// Mutant L16 removes the landing's mayWrite check.
func TestLateWorkBackupWaitsForTheWalletLanding(t *testing.T) {
	setup := func(t *testing.T, bound time.Duration) (*walletFailFixture, *lateOrderLog, func(), chan struct{}) {
		f := walletFailSetup(t)
		loginWindowState(t)
		resetAbandoned(t, nil)
		rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
		o := &lateOrderLog{}
		read := make(chan struct{}, 1)
		release := lateWalletGate(t, f, walletFailName, walletFailPass, true, lateSignal(read))
		lateWorkFresh(t)
		t.Cleanup(release)
		lateWorkShrink(t, bound)
		lateWorkSeams(t, func() {})
		old := walletRestoreFileLanded
		walletRestoreFileLanded = func(string) { o.add("landed") }
		t.Cleanup(func() { walletRestoreFileLanded = old })
		lateSignIn(t, f, o.add)
		lateAwait(t, read, "the late wallet read")
		return f, o, release, read
	}
	backup := func(t *testing.T, f *walletFailFixture, o *lateOrderLog) chan string {
		c := make(chan string, 1)
		go func() {
			c <- ropReply(t, func(conn net.Conn) { handleBackup(&lateWorkRecConn{Conn: conn, add: o.add}, f.dest) })
		}()
		return c
	}
	t.Run("waits, then seals only after the landing", func(t *testing.T) {
		f, o, release, _ := setup(t, time.Hour)
		gen := f.gen()
		c := backup(t, f, o)
		select {
		case r := <-c:
			t.Fatalf("BACKUP replied %q while the late wallet restore was still reading (h46 #1)", r)
		case <-time.After(200 * time.Millisecond):
		}
		release()
		select {
		case <-c:
		case <-time.After(lateWorkHang):
			t.Fatal("BACKUP never replied after the landing")
		}
		lateWorkWait(t)
		landed := o.at("landed")
		o.mu.Lock()
		reply := -1
		for i, e := range o.l {
			if i > o.at2("write:OK 21") && strings.HasPrefix(e, "write:") {
				reply = i
				break
			}
		}
		o.mu.Unlock()
		if landed < 0 || reply < 0 || reply < landed {
			t.Fatalf("BACKUP answered (at %d) before the wallet landed (at %d); log %q", reply, landed, o.l)
		}
		if walletNotRestored(f.wpath, gen) {
			t.Fatal("the late wallet restore did not prove its generation")
		}
		if w, err := loadWallet(f.wpath); err != nil || w.balance() != f.stored {
			t.Fatalf("the landing left %v (err %v), want %d tokens", w, err, f.stored)
		}
	})
	t.Run("after the bound the landing is a no-op", func(t *testing.T) {
		f, o, release, _ := setup(t, 300*time.Millisecond)
		gen := f.gen()
		var log string
		log = captureStderr(t, func() {
			c := backup(t, f, o)
			select {
			case <-c:
			case <-time.After(lateWorkHang):
				t.Fatal("BACKUP never went ahead at the bound")
			}
			release()
			lateWorkWait(t)
		})
		if !strings.Contains(log, "for backup (h46 #1)") {
			t.Fatalf("BACKUP did not wait for the late job to its bound:\n%s", log)
		}
		if _, err := os.Stat(f.wpath); !os.IsNotExist(err) {
			t.Fatalf("an abandoned late landing wrote a wallet file (stat err %v)", err)
		}
		if !walletNotRestored(f.wpath, gen) || !walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("an abandoned late landing wrote a restore proof: a publisher could now replace the stored wallet")
		}
		if !strings.Contains(log, "the late wallet restore was not written") {
			t.Fatalf("no refusal line for the abandoned landing:\n%s", log)
		}
		f.assertStored(t, f.stored, "after an abandoned late landing")
	})
}

// at2 is at for a caller that already holds o.mu.
func (o *lateOrderLog) at2(p string) int {
	for i, e := range o.l {
		if strings.HasPrefix(e, p) {
			return i
		}
	}
	return -1
}

// An abandoned job's (or a deleted session's) wallet step writes nothing, and its telephony step stages nothing.
// Mutant L17 removes the staging's check under telMu.
func TestLateWorkWalletAndTelNoOpWhenAbandonedOrDeleted(t *testing.T) {
	t.Run("wallet: refused at the start reads nothing", func(t *testing.T) {
		f := walletFailSetup(t)
		var reads atomic.Int32
		lateWalletGate(t, f, walletFailName, walletFailPass, false, func() { reads.Add(1) })
		never, _ := lateGuard(false)
		roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, never)
		if reads.Load() != 0 {
			t.Fatalf("a refused wallet step read the store %d time(s)", reads.Load())
		}
		if _, err := os.Stat(f.wpath); !os.IsNotExist(err) || !walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("a refused wallet step wrote a file or a proof")
		}
	})
	t.Run("wallet: refused at the landing writes nothing", func(t *testing.T) {
		f := walletFailSetup(t)
		once, n := lateGuard(true, false)
		roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, once)
		if _, err := os.Stat(f.wpath); !os.IsNotExist(err) || !walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("a wallet landing refused under the lock wrote a file or a proof")
		}
		if n.Load() != 2 {
			t.Fatalf("the guard was asked %d times, want 2 (start, landing)", n.Load())
		}
		roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, nil) // control
		if walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("control failed: an unguarded landing did not land")
		}
	})
	t.Run("wallet: a DELETE first leaves the job a no-op", func(t *testing.T) {
		f := walletFailSetup(t)
		loginWindowState(t)
		resetAbandoned(t, nil)
		rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
		read := make(chan struct{}, 1)
		release := lateWalletGate(t, f, walletFailName, walletFailPass, true, lateSignal(read))
		lateWorkFresh(t)
		t.Cleanup(release)
		lateWorkSeams(t, func() {})
		lateSignIn(t, f, func(string) {})
		lateAwait(t, read, "the late wallet read")
		os.Remove(filepath.Join(f.dest, roamSessionFile)) // what DELETE does to the marker before the reap
		release()
		lateWorkWait(t)
		if _, err := os.Stat(f.wpath); !os.IsNotExist(err) || !walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("a late landing after the session was deleted wrote a file or a proof")
		}
	})
	t.Run("telephony: refused under telMu stages nothing", func(t *testing.T) {
		_, head, _, ref := thSetup(t)
		resetStaging(t)
		t.Cleanup(func() { underTelMu(func() { delete(telHandoffPending, "11") }) })
		beginTelHandoff("11")
		once, n := lateGuard(true, false)
		out := captureStderr(t, func() { telHandoffRoamInGuarded(thName, thPass, head, nil, "11", nil, once) })
		var b []byte
		underTelMu(func() { b, _ = claimTelIngest("11") })
		if len(b) != 0 || thInboxCount(t, ref) != 1 {
			t.Fatalf("a refused hand-off staged %q (inbox %d, want the sealed item kept)", b, thInboxCount(t, ref))
		}
		if n.Load() != 2 || !strings.Contains(out, "telephony hand-off skipped, kept sealed: the sign-in's late work") {
			t.Fatalf("guard calls %d, want 2; log:\n%s", n.Load(), out)
		}
		underTelMu(func() {
			if telHandoffPending["11"] {
				t.Error("a refused hand-off left its pending mark: the claim would hold arrivals to the cap")
			}
		})
		telHandoffRoamInGuarded(thName, thPass, head, nil, "11", nil, nil) // control
		underTelMu(func() { b, _ = claimTelIngest("11") })
		if len(b) == 0 { // its sealed copy stays pending until ACK-TELROWS (telephony_pending.go)
			t.Fatal("control failed: an unguarded hand-off staged nothing")
		}
	})
}

// A claim the session makes before the late landing is merged in, not overwritten; a locked retry that landed first
// makes the landing a no-op, whatever the lock and the guard say. Mutants L23 (4a) and L25 (4b).
func TestLateWorkWalletLandingMergesAClaim(t *testing.T) {
	t.Run("merge", func(t *testing.T) {
		f := walletFailSetup(t)
		read := make(chan struct{}, 1)
		release := lateWalletGate(t, f, walletFailName, walletFailPass, true, lateSignal(read))
		done := make(chan struct{})
		go func() {
			defer close(done)
			roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, func() bool { return true })
		}()
		lateAwait(t, read, "the late wallet read")
		f.appendTwo(t) // the session's claim, at its generation
		release()
		lateAwait(t, done, "the late landing")
		if w, err := loadWallet(f.wpath); err != nil || w.balance() != f.stored+2 {
			t.Fatalf("the late landing left %v (err %v), want the stored %d plus the claimed 2", w, err, f.stored)
		}
		if walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("the merged landing did not prove its generation")
		}
	})
	retryFirst := func(t *testing.T) (*walletFailFixture, []byte, *atomic.Int32) {
		f := walletFailSetup(t)
		f.appendTwo(t)
		if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, f.gen()); err != nil {
			t.Fatalf("control failed: the retry did not land: %v", err)
		}
		snap, err := os.ReadFile(f.wpath)
		if err != nil {
			t.Fatal(err)
		}
		old := roamInPlanCarry
		var carries atomic.Int32
		roamInPlanCarry = func(base, name, pass string, dk []byte, walletPath string, _ func() bool) { carries.Add(1) }
		t.Cleanup(func() { roamInPlanCarry = old })
		return f, snap, &carries
	}
	const lockRefusal, notWritten, readFailed = "the wallet lock was not taken", "the late wallet restore was not written", "wallet read FAILED"
	const carrySkipped = "the plan carry was not run"
	unchanged := func(t *testing.T, f *walletFailFixture, snap []byte) {
		t.Helper()
		if b, _ := os.ReadFile(f.wpath); string(b) != string(snap) {
			t.Fatal("the late landing rewrote a file a retry had already landed")
		}
		if walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("the retry's proof is gone")
		}
	}
	t.Run("4a", func(t *testing.T) { // the lock held: a standing proof returns nil before the lock refusal
		f, snap, carries := retryFirst(t)
		oldWait := walletSignInWait
		walletSignInWait = 100 * time.Millisecond
		t.Cleanup(func() { walletSignInWait = oldWait })
		unlock, state := lockWalletWithin(f.wpath, time.Second)
		defer unlock()
		if state != walletLocked {
			t.Fatalf("control failed: the test could not take the wallet lock (%v)", state)
		}
		always := func() bool { return true }
		if err := pullWalletStrictGuarded("s3", walletFailName, walletFailPass, f.dk, f.wpath, always); err != nil {
			t.Fatalf("a late landing over a standing proof answered %v, want nil", err)
		}
		out := captureStderr(t, func() { roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, always) })
		for _, bad := range []string{lockRefusal, notWritten, readFailed, carrySkipped} {
			if strings.Contains(out, bad) {
				t.Fatalf("a landing over a standing proof logged %q:\n%s", bad, out)
			}
		}
		if carries.Load() != 1 {
			t.Fatalf("the plan carry ran %d times, want 1", carries.Load())
		}
		unchanged(t, f, snap)
	})
	t.Run("4b", func(t *testing.T) { // the guard says no at the landing: a standing proof still returns nil
		f, snap, carries := retryFirst(t)
		guard, n := lateGuard(true, false)
		out := captureStderr(t, func() { roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, guard) })
		if !strings.Contains(out, carrySkipped) {
			t.Fatalf("no carry-skipped line:\n%s", out)
		}
		for _, bad := range []string{lockRefusal, notWritten, readFailed} {
			if strings.Contains(out, bad) {
				t.Fatalf("a landing over a standing proof logged %q:\n%s", bad, out)
			}
		}
		if carries.Load() != 0 || n.Load() != 2 {
			t.Fatalf("carries %d (want 0), guard calls %d (want 2: start, before the carry)", carries.Load(), n.Load())
		}
		unchanged(t, f, snap)
	})
}

// A late landing that does not take the wallet lock writes nothing and no proof; a later locked retry lands it. A
// nil-guard caller keeps today's unlocked landing. Mutant L21.
func TestLateWorkWalletLandingRefusesAHeldLock(t *testing.T) {
	f := walletFailSetup(t)
	oldWait := walletSignInWait
	walletSignInWait = 100 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = oldWait })
	gen := f.gen()
	unlock, state := lockWalletWithin(f.wpath, time.Second)
	if state != walletLocked {
		t.Fatalf("control failed: the test could not take the wallet lock (%v)", state)
	}
	out := captureStderr(t, func() {
		roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, func() bool { return true })
	})
	if _, err := os.Stat(f.wpath); !os.IsNotExist(err) {
		t.Fatalf("a late landing without the lock wrote the wallet file (stat err %v)", err)
	}
	if !walletNotRestored(f.wpath, gen) {
		t.Fatal("a late landing without the lock wrote a restore proof")
	}
	if _, err := os.Stat(walletPrevPath(f.wpath)); !os.IsNotExist(err) {
		t.Fatal("a late landing without the lock left a staged copy")
	}
	if _, err := os.Stat(walletRestoreLandedPath(f.wpath, gen) + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("a late landing without the lock left a staged proof")
	}
	for _, want := range []string{"the wallet lock was not taken within walletSignInWait -- nothing written",
		"a later locked retry (Add credits, the periodic seal, a sign-out) may land it"} {
		if !strings.Contains(out, want) {
			t.Fatalf("no %q in:\n%s", want, out)
		}
	}
	for _, bad := range []string{"wallet read FAILED", "wallet lock was held", "the next retry lands it"} {
		if strings.Contains(out, bad) {
			t.Fatalf("the lock refusal logged %q:\n%s", bad, out)
		}
	}
	unlock()
	if err := retryWalletRestore("s3", walletFailName, walletFailPass, f.dk, f.wpath, gen); err != nil {
		t.Fatalf("the locked retry after the refusal: %v", err)
	}
	if w, err := loadWallet(f.wpath); err != nil || w.balance() != f.stored || walletNotRestored(f.wpath, gen) {
		t.Fatalf("the locked retry left %v (err %v), want %d tokens and the proof", w, err, f.stored)
	}
	t.Run("a nil guard keeps the unlocked landing", func(t *testing.T) {
		f := walletFailSetup(t)
		unlock, state := lockWalletWithin(f.wpath, time.Second)
		defer unlock()
		if state != walletLocked {
			t.Fatalf("control failed: the test could not take the wallet lock (%v)", state)
		}
		roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, nil)
		if walletNotRestored(f.wpath, f.gen()) {
			t.Fatal("a nil-guard landing no longer lands past a busy lock")
		}
	})
}

// The plan carry is asked again after the landing: a job that ended meanwhile skips it. Mutant L22.
func TestLateWorkPlanCarrySkippedWhenTheLateWorkEnds(t *testing.T) {
	old := roamInPlanCarry
	var carries atomic.Int32
	roamInPlanCarry = func(base, name, pass string, dk []byte, walletPath string, _ func() bool) { carries.Add(1) }
	t.Cleanup(func() { roamInPlanCarry = old })
	f := walletFailSetup(t)
	guard, n := lateGuard(true, true, false)
	out := captureStderr(t, func() { roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, f.wpath, guard) })
	if walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("control failed: the landing did not land")
	}
	if carries.Load() != 0 || !strings.Contains(out, "the plan carry was not run") {
		t.Fatalf("the plan carry ran %d time(s) after the late work ended; log:\n%s", carries.Load(), out)
	}
	if n.Load() != 3 {
		t.Fatalf("the guard was asked %d times, want 3 (start, landing, carry)", n.Load())
	}
	g := walletFailSetup(t) // control
	roamInWalletGuarded("s3", walletFailName, walletFailPass, nil, g.wpath, nil)
	if carries.Load() != 1 {
		t.Fatalf("control failed: an unguarded landing ran the carry %d times, want 1", carries.Load())
	}
}

// A proven absence of a stored wallet: a standing proof returns nil before the guard is asked. Mutant L24.
func TestLateWorkNoWalletProofStandsBeforeTheGuard(t *testing.T) {
	f := walletFailSetup(t)
	const name, pass = "lw-nowallet", "a profile with no stored wallet"
	dk := deriveKey(name, pass)
	foldingSeal(t, name, pass, dk)
	never := func() bool { return false }
	if err := pullWalletStrictGuarded("s3", name, pass, dk, f.wpath, never); !errors.Is(err, errLateWriteDenied) {
		t.Fatalf("control: a refused proven absence answered %v, want errLateWriteDenied", err)
	}
	if !walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("a refused proven absence wrote a proof")
	}
	if err := markWalletRestoreLanded(f.wpath, f.gen()); err != nil {
		t.Fatal(err)
	}
	if err := pullWalletStrictGuarded("s3", name, pass, dk, f.wpath, never); err != nil {
		t.Fatalf("a proven absence over a standing proof answered %v, want nil", err)
	}
	if walletNotRestored(f.wpath, f.gen()) {
		t.Fatal("the standing proof is gone")
	}
}

// The chooser's claim releases the held bring-up only once the late hand-off is done; an abandoned or panicking job
// releases it at the next claim; the cap still ends it. Mutants L18 (claim before staging) and L20 (no job-end mark).
func TestLateWorkClaimHoldsUntilTheHandoffStaged(t *testing.T) {
	claim := func(uid int) {
		var w strings.Builder
		underTelMu(func() { serveGetTelIngest(&w, uid*100000+5) })
	}
	clean := func(t *testing.T, uids ...string) {
		t.Cleanup(func() {
			underTelMu(func() {
				for _, u := range uids {
					delete(telHandoffPending, u)
				}
			})
		})
	}
	hold := func(t *testing.T, uid string) {
		t.Helper()
		if err := beginTelStaging(uid, true); err != nil {
			t.Fatal(err)
		}
		beginTelHandoff(uid)
		if !holdTelStagingUntilClaim(uid) {
			t.Fatal("control failed: the bring-up did not hold")
		}
	}
	t.Run("before and after the staging", func(t *testing.T) {
		resetStaging(t)
		useTempIngest(t)
		clean(t, "40")
		hold(t, "40")
		claim(40)
		if !holds("40") {
			t.Fatal("a claim before the late hand-off staged released the hold (h46 #1)")
		}
		if _, skipped, err := stageTelInboxGuarded(&vault{}, nil, "", "40", func() bool { return false }); !skipped || err != nil {
			t.Fatalf("control failed: skipped %v, err %v", skipped, err)
		}
		claim(40)
		if holds("40") {
			t.Fatal("a claim after the hand-off was done did not release the hold")
		}
	})
	t.Run("abandoned", func(t *testing.T) {
		resetStaging(t)
		useTempIngest(t)
		lateWorkFresh(t)
		lateWorkShrink(t, 200*time.Millisecond)
		clean(t, "41")
		hold(t, "41")
		p := lateWorkBlockedJob(t, t.TempDir(), "41")
		waitLateWork("test")
		if !p.lw.abandoned.Load() {
			t.Fatal("control failed: the job was not abandoned")
		}
		claim(41)
		if holds("41") {
			t.Fatal("an abandoned job's hand-off still holds arrivals after the claim")
		}
	})
	t.Run("panic", func(t *testing.T) {
		tr := trackGoSafe(t) // NWP-20261128-14: the job's recovered line is written before captureStderr restores
		resetStaging(t)
		useTempIngest(t)
		lateWorkFresh(t)
		clean(t, "42")
		hold(t, "42")
		captureStderr(t, func() {
			startLateWork(t.TempDir(), "42", func(*lateWork) { panic("a late step panicked") })
			lateWorkWait(t)
			tr.wait(t, lateWorkHang)
		})
		claim(42)
		if holds("42") {
			t.Fatal("a panicking job's hand-off still holds arrivals after the claim")
		}
	})
	t.Run("the cap", func(t *testing.T) {
		resetStaging(t)
		useTempIngest(t)
		clean(t, "43")
		hold(t, "43")
		underTelMu(func() { telStagingUntil = time.Now().Add(-time.Second) })
		if holds("43") {
			t.Fatal("a pending hand-off held arrivals past the cap")
		}
	})
}

// Driven through the handler: a claim that comes while the late job is still in its wallet step keeps the hold, and
// one after the job ends releases it.
func TestLateWorkClaimDuringTheSignInKeepsTheHold(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	resetStaging(t)
	useTempIngest(t)
	rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
	read := make(chan struct{}, 1)
	release := lateWalletGate(t, f, walletFailName, walletFailPass, true, lateSignal(read))
	lateWorkFresh(t)
	t.Cleanup(release)
	lateWorkShrink(t, time.Hour)
	lateWorkSeams(t, func() {})
	lateSignIn(t, f, func(string) {})
	lateAwait(t, read, "the late wallet read")
	var w strings.Builder
	underTelMu(func() { serveGetTelIngest(&w, 21*100000+5) })
	if !holds("21") {
		t.Fatal("the session's claim released the hold before its late hand-off ran (h46 #1)")
	}
	release()
	lateWorkWait(t)
	underTelMu(func() { serveGetTelIngest(&w, 21*100000+5) })
	if holds("21") {
		t.Fatal("the claim after the late hand-off did not release the hold")
	}
}

// planCarryProxy fronts the test store: once armed, it lets skip GETs of a ref through, then the next one signals
// read and blocks until release. With only set, only a GET of that path counts. armOnBlob arms it when a blob upload
// answers. Every write request is counted while counting is set.
type planCarryProxy struct {
	url                        string
	armed, counting, armOnBlob atomic.Bool
	skip, writes               atomic.Int32
	only                       atomic.Value // string
	read, release              chan struct{}
	releaseOnce                sync.Once
}

func newPlanCarryProxy(t *testing.T, base string) *planCarryProxy {
	t.Helper()
	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	p := &planCarryProxy{read: make(chan struct{}, 1), release: make(chan struct{})}
	rp := httputil.NewSingleHostReverseProxy(u)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && p.counting.Load() {
			p.writes.Add(1)
		}
		if r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/blob") && p.armOnBlob.Load() {
			rp.ServeHTTP(w, r)
			p.armed.Store(true)
			return
		}
		only, _ := p.only.Load().(string)
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/ref/") && p.armed.Load() &&
			(only == "" || r.URL.Path == only) {
			if p.skip.Add(-1) < 0 && p.armed.CompareAndSwap(true, false) {
				lateSignal(p.read)()
				<-p.release
			}
		}
		rp.ServeHTTP(w, r)
	}))
	p.url = srv.URL
	t.Cleanup(func() { p.releaseOnce.Do(func() { close(p.release) }); srv.Close() })
	return p
}

// RF-001: the plan carry's head reads can block past the bound. An abandonment during either read starts no rebind,
// no marker write and no carry-record publish after it. Mutants L26 (the carry's re-check after its head read) and
// L27 (dropBillPrevGuarded's re-check inside its bracket).
func TestLateWorkPlanCarryStopsWhenAbandonedDuringItsHeadRead(t *testing.T) {
	setup := func(t *testing.T, name string) (base, wpath string, dk []byte, gw *rebindGateway) {
		base = newHTTPStore(t)
		gw = newRebindGateway(t)
		state := t.TempDir()
		t.Setenv("NOWHERE_STATE", state)
		wpath = filepath.Join(state, "wallet.json")
		t.Setenv("NOWHERE_WALLET", wpath)
		const p1, p2 = "horse battery staple correct", "a brand new passphrase"
		createVault(base, name, p1)
		t.Setenv("GATEWAY_URL", "")
		if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
			t.Fatalf("rotateVault: %v", err)
		}
		dk, _, _ = resolveKey(base, name, p2)
		if err := saveWallet(wpath, &Wallet{PaidThrough: 1 << 40, PlanGB: 10}); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(planMovingPath(wpath), []byte("1\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return base, wpath, dk, gw
	}
	const p2 = "a brand new passphrase"
	billPrev := func(t *testing.T, base, name string, dk []byte) string {
		t.Helper()
		v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, p2))))
		idx, ok := openScopeIndex(dk, v.Scopes)
		if !ok {
			t.Fatal("no index")
		}
		return billPrevOf(idx)
	}
	run := func(t *testing.T, name string, blockAfterRebind bool, skip int32) {
		base, wpath, dk, gw := setup(t, name)
		p := newPlanCarryProxy(t, base)
		p.skip.Store(skip)
		gwURL := gw.srv.URL
		if blockAfterRebind { // arm the store proxy when the rebind answers: the next ref GET is dropBillPrev's
			u, _ := url.Parse(gw.srv.URL)
			rp := httputil.NewSingleHostReverseProxy(u)
			gsrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				rp.ServeHTTP(w, r)
				p.armed.Store(true)
			}))
			t.Cleanup(gsrv.Close)
			gwURL = gsrv.URL
		} else {
			p.armed.Store(true)
		}
		t.Setenv("GATEWAY_URL", gwURL)
		var abandoned atomic.Bool
		done := make(chan struct{})
		go func() {
			defer close(done)
			retryPlanCarryGuarded(p.url, name, p2, dk, wpath, func() bool { return !abandoned.Load() })
		}()
		lateAwait(t, p.read, "the plan carry's head read")
		abandoned.Store(true)
		p.counting.Store(true)
		olds, _ := gw.calls()
		before := len(olds)
		p.releaseOnce.Do(func() { close(p.release) })
		lateAwait(t, done, "the plan carry")
		if olds, _ := gw.calls(); len(olds) != before {
			t.Errorf("the abandoned carry sent %d rebind(s) after the abandonment", len(olds)-before)
		}
		if n := p.writes.Load(); n != 0 {
			t.Errorf("the abandoned carry made %d store write(s) after the abandonment", n)
		}
		// After a confirmed rebind the marker is removed before the record edit starts, while the guard still says
		// yes; only an abandonment during the carry's own head read must leave it.
		if b, err := os.ReadFile(planMovingPath(wpath)); !blockAfterRebind && (err != nil || string(b) != "1\n") {
			t.Errorf("the abandoned carry rewrote the plan-moving marker (%q, %v)", b, err)
		}
		if billPrev(t, base, name, dk) == "" {
			t.Error("the abandoned carry cleared the carry record")
		}
	}
	t.Run("the carry's head read", func(t *testing.T) { run(t, "lwpcread", false, 0) })
	t.Run("the record edit's head read", func(t *testing.T) { run(t, "lwpcdrop", true, 0) })
	// dropBillPrevGuarded's look outside the bracket (openVaultHead) reads two refs on this store, the head probe and
	// the head itself; skipping both blocks the bracket's own read for the edit (capReadVaultForEdit).
	t.Run("the record edit's read inside its bracket", func(t *testing.T) { run(t, "lwpcedit", true, 2) })
	t.Run("control", func(t *testing.T) {
		const name = "lwpcctl"
		base, wpath, dk, gw := setup(t, name)
		t.Setenv("GATEWAY_URL", gw.srv.URL)
		retryPlanCarryGuarded(base, name, p2, dk, wpath, func() bool { return true })
		if olds, _ := gw.calls(); len(olds) != 1 || billPrev(t, base, name, dk) != "" {
			t.Fatalf("control failed: %d rebind(s), record %q -- a guard that says yes must carry and clear", len(olds),
				billPrev(t, base, name, dk))
		}
		if _, err := os.Stat(planMovingPath(wpath)); !os.IsNotExist(err) {
			t.Fatal("control failed: the carried plan left its marker")
		}
	})
}

// RF-001 (third review): the carry-record edit's head publication reads the store before its PUT -- the stale-publish
// check of the head the edit read, and the legacy ref's existence before its retirement. Either read can block until
// the job is abandoned; after it the head, the recovery ref and the legacy tombstone are not written. Mutants L29
// (the edit publishes its head through the unguarded putHead) and L30 (the legacy tombstone without the guard).
func TestLateWorkPlanCarryStopsWhenAbandonedDuringItsHeadPublication(t *testing.T) {
	const p1, p2 = "horse battery staple correct", "a brand new passphrase"
	setup := func(t *testing.T, name string) (base string, dk []byte, legacy string) {
		base = newHTTPStore(t)
		t.Setenv("NOWHERE_STATE", t.TempDir())
		t.Setenv("GATEWAY_URL", "")
		createVault(base, name, p1)
		if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
			t.Fatalf("rotateVault: %v", err)
		}
		dk, _, _ = resolveKey(base, name, p2)
		// A legacy ref beside the v2 head: putHeadSingle retires it after the head lands.
		legacy = profileRefLegacy(name, p2)
		putRef(base, legacy, "a-legacy-head")
		return base, dk, legacy
	}
	head := func(t *testing.T, base, name string) string {
		t.Helper()
		return getRef(base, headKey(base, name, p2))
	}
	run := func(t *testing.T, name string, blockLegacy bool) {
		base, dk, legacy := setup(t, name)
		before := head(t, base, name)
		p := newPlanCarryProxy(t, base)
		p.armOnBlob.Store(true) // the next ref GET after the vault blob lands is the head publication's
		if blockLegacy {
			p.only.Store("/ref/" + legacy)
		}
		var abandoned atomic.Bool
		done := make(chan struct{})
		go func() {
			defer close(done)
			dropBillPrevGuarded(p.url, name, p2, dk, func() bool { return !abandoned.Load() })
		}()
		lateAwait(t, p.read, "the head publication's store read")
		abandoned.Store(true)
		p.counting.Store(true)
		p.releaseOnce.Do(func() { close(p.release) })
		lateAwait(t, done, "the carry-record edit")
		if n := p.writes.Load(); n != 0 {
			t.Errorf("the abandoned edit made %d store write(s) after the abandonment", n)
		}
		if !blockLegacy && head(t, base, name) != before {
			t.Error("the abandoned edit published its head")
		}
		if got := getRef(base, legacy); got != "a-legacy-head" {
			t.Errorf("the abandoned edit retired the legacy ref (now %q)", got)
		}
	}
	t.Run("the stale-publish read of the head", func(t *testing.T) { run(t, "lwphhead", false) })
	t.Run("the legacy ref's existence read", func(t *testing.T) { run(t, "lwphlegacy", true) })
	t.Run("control", func(t *testing.T) {
		const name = "lwphctl"
		base, dk, legacy := setup(t, name)
		before := head(t, base, name)
		if !dropBillPrevGuarded(base, name, p2, dk, func() bool { return true }) {
			t.Fatal("control failed: a guard that says yes must clear the record")
		}
		if head(t, base, name) == before || getRef(base, legacy) != "" {
			t.Fatal("control failed: the edit must publish its head and retire the legacy ref")
		}
	})
}
