package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261201-07: a Back up now tap during a running save joins it, and a stamped tap during a save from before the
// reconnect queues exactly one more.

// bjLimit is every liveness bound in this file. A healthy run needs milliseconds.
const bjLimit = 30 * time.Second

type bjFix struct {
	tr    *goSafeTracker
	dest  string
	after int64
	hook  *bjHook
}

// bjHook stands in for queuedSaveStart. It answers from replies in order, then OK for ever, and counts its calls.
type bjHook struct {
	mu      sync.Mutex
	calls   int
	replies []string
}

func (h *bjHook) start(string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls++
	if len(h.replies) > 0 {
		r := h.replies[0]
		h.replies = h.replies[1:]
		return r
	}
	return "OK"
}

func (h *bjHook) count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.calls
}

// bjFixture gives a test its own session and a fast waiter. The cleanups run last-in first-out: the waiter is joined
// before any global it reads is restored.
func bjFixture(t *testing.T, profile string) *bjFix {
	t.Helper()
	tr := trackGoSafe(t)
	_, _, _ = ropStore(t)
	ropReapReset(t)

	pendingReapMu.Lock()
	oldKind, oldAt, oldFlight, oldLogin, oldArmed := sealRunKind, sealRunAt, sealInFlight, loginSettleUntil, queuedSaveArmed
	sealRunKind, sealRunAt, sealInFlight, loginSettleUntil, queuedSaveArmed = "", time.Time{}, false, time.Time{}, false
	pendingReapMu.Unlock()
	oldPoll, oldDeadline, oldStart, oldWait := queuedSavePoll, queuedSaveDeadline, queuedSaveStart, backupAfterWait
	oldLanded, oldWaiting := lastLandedSealStartedAt.Load(), userOpWaiting.Load()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealRunKind, sealRunAt, sealInFlight, loginSettleUntil, queuedSaveArmed = oldKind, oldAt, oldFlight, oldLogin, oldArmed
		pendingReapMu.Unlock()
		queuedSavePoll, queuedSaveDeadline, queuedSaveStart, backupAfterWait = oldPoll, oldDeadline, oldStart, oldWait
		lastLandedSealStartedAt.Store(oldLanded)
		userOpWaiting.Store(oldWaiting)
	})
	t.Cleanup(func() { tr.wait(t, bjLimit) })

	f := &bjFix{tr: tr, dest: t.TempDir(), after: time.Now().Unix(), hook: &bjHook{}}
	queuedSavePoll, queuedSaveDeadline, queuedSaveStart = 5*time.Millisecond, 10*time.Second, f.hook.start
	lastLandedSealStartedAt.Store(0)
	userOpWaiting.Store(0)
	if err := markRoamSession(f.dest, profile, ropPass, "12", ""); err != nil {
		t.Fatal(err)
	}
	return f
}

func bjSetRun(kind string, at time.Time) {
	pendingReapMu.Lock()
	sealRunKind, sealRunAt = kind, at
	pendingReapMu.Unlock()
}

func bjArmed() bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return queuedSaveArmed
}

// bjTap is one stamped tap, as the notice sends it.
func (f *bjFix) bjTap(t *testing.T) string {
	t.Helper()
	return ropReply(t, func(c net.Conn) { handleBackup(c, f.dest, f.after) })
}

// bjWaiterEnds fails the test if the armed waiter is still running after the liveness bound.
func (f *bjFix) bjWaiterEnds(t *testing.T) {
	t.Helper()
	for end := time.Now().Add(bjLimit); f.tr.count("queued-backup") != 0; time.Sleep(time.Millisecond) {
		if time.Now().After(end) {
			t.Fatalf("the waiter was still running after %s", bjLimit)
		}
	}
}

// bjSessionFree returns once no other job holds sessionMu, so a leftover of an earlier test cannot read as a BUSY here.
func bjSessionFree(t *testing.T) {
	t.Helper()
	for end := time.Now().Add(bjLimit); !sessionMu.TryLock(); time.Sleep(time.Millisecond) {
		if time.Now().After(end) {
			t.Fatalf("sessionMu stayed held for %s", bjLimit)
		}
	}
	sessionMu.Unlock()
}

func TestParseBackupAfter(t *testing.T) {
	cases := []struct {
		line string
		want int64
	}{
		{"AFTER 1700000000", 1700000000},
		{"AFTER 1700000000\r\n", 1700000000},
		{"  AFTER 7\n", 7},
		{"AFTER " + strings.Repeat("9", 18), 999999999999999999},
		{"", 0},
		{"AFTER", 0},
		{"AFTER ", 0},
		{"AFTER -5", 0},
		{"AFTER 12x", 0},
		{"AFTER " + strings.Repeat("9", 19), 0},
		{"XAFTER 5", 0},
		{"1700000000", 0},
	}
	for _, c := range cases {
		if got := parseBackupAfter(c.line); got != c.want {
			t.Errorf("parseBackupAfter(%q) = %d, want %d", c.line, got, c.want)
		}
	}
}

func TestReadBackupAfter(t *testing.T) {
	old := backupAfterWait
	backupAfterWait = 20 * time.Millisecond
	t.Cleanup(func() { backupAfterWait = old })

	read := func(t *testing.T, srv net.Conn, r *bufio.Reader) int64 {
		t.Helper()
		got := make(chan int64, 1)
		go func() { got <- readBackupAfter(srv, r) }()
		select {
		case v := <-got:
			return v
		case <-time.After(10 * time.Second):
			t.Fatal("readBackupAfter did not return in 10 s: nothing bounds the read")
		}
		return 0
	}

	t.Run("bare BACKUP", func(t *testing.T) {
		cli, srv := net.Pipe()
		t.Cleanup(func() { cli.Close(); srv.Close() })
		if got := read(t, srv, bufio.NewReader(srv)); got != 0 {
			t.Fatalf("a bare BACKUP read %d, want 0", got)
		}
		// The connection still carries the reply and a later read: the read deadline must not outlive the wait.
		time.Sleep(40 * time.Millisecond)
		go srv.Write([]byte("OK\n"))
		line, err := bufio.NewReader(cli).ReadString('\n')
		if err != nil || line != "OK\n" {
			t.Fatalf("the reply after the wait: %q, %v", line, err)
		}
		go cli.Write([]byte("x\n"))
		if line, err := bufio.NewReader(srv).ReadString('\n'); err != nil || line != "x\n" {
			t.Fatalf("a read after the wait: %q, %v", line, err)
		}
	})

	t.Run("the stamp in one write with the verb", func(t *testing.T) {
		cli, srv := net.Pipe()
		t.Cleanup(func() { cli.Close(); srv.Close() })
		go cli.Write([]byte("BACKUP\nAFTER 42\n"))
		r := bufio.NewReader(srv)
		if verb, err := r.ReadString('\n'); err != nil || verb != "BACKUP\n" {
			t.Fatalf("the verb: %q, %v", verb, err)
		}
		if got := read(t, srv, r); got != 42 {
			t.Fatalf("the stamp read %d, want 42", got)
		}
	})
}

func TestQueueFollowUp(t *testing.T) {
	const after = int64(1_700_000_000)
	before, at, later := time.Unix(after-60, 0), time.Unix(after, 0), time.Unix(after+60, 0)
	cases := []struct {
		name  string
		after int64
		kind  string
		runAt time.Time
		armed bool
		want  bool
	}{
		{"started before the reconnect", after, "periodic", before, false, true},
		{"manual before the reconnect", after, "manual", before, false, true},
		{"unstamped run", after, "periodic", time.Time{}, false, true},
		{"started at the reconnect", after, "periodic", at, false, false},
		{"started after the reconnect", after, "periodic", later, false, false},
		{"no stamp on the tap", 0, "periodic", before, false, false},
		{"a sign-out", after, "logoff", before, false, false},
		{"a sign-out's suffixed kind", after, "logoff-cold", before, false, false},
		{"already armed", after, "periodic", before, true, false},
	}
	for _, c := range cases {
		if got := queueFollowUp(c.after, c.kind, c.runAt, c.armed); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestQueuedSaveStep(t *testing.T) {
	now := time.Now()
	after := now.Add(-time.Minute).Unix()
	older := time.Unix(after-300, 0)
	newer := time.Unix(after+10, 0)
	expired := now.Add(-sealRunExpiry - time.Minute)
	type in struct {
		live    string
		kind    string
		runAt   time.Time
		busy    bool
		login   time.Time
		waiting int32
		landed  int64
	}
	cases := []struct {
		name string
		in   in
		want int
	}{
		{"the session ended", in{live: "", kind: "periodic", runAt: older}, queuedDropSessionEnded},
		{"another session is live", in{live: "13"}, queuedDropSessionEnded},
		{"a sign-out runs", in{live: "12", kind: "logoff", runAt: older}, queuedDropSignOut},
		{"a sign-out from after the reconnect", in{live: "12", kind: "logoff", runAt: newer}, queuedDropSignOut},
		{"landed at the reconnect", in{live: "12", landed: after}, queuedDropLanded},
		{"landed after the reconnect", in{live: "12", landed: after + 5}, queuedDropLanded},
		{"a newer periodic, announced at the reconnect", in{live: "12", kind: "periodic", runAt: time.Unix(after, 0)}, queuedDropNewerSave},
		{"a newer periodic", in{live: "12", kind: "periodic", runAt: newer}, queuedDropNewerSave},
		{"a newer manual", in{live: "12", kind: "manual", runAt: newer}, queuedDropNewerSave},
		{"the older run is still live", in{live: "12", kind: "periodic", runAt: older}, queuedStepWait},
		{"an unstamped run", in{live: "12", kind: "periodic"}, queuedStepWait},
		{"seal in flight with no kind", in{live: "12", busy: true}, queuedStepWait},
		{"a sign-in in progress", in{live: "12", login: now.Add(time.Minute)}, queuedStepWait},
		{"a user op waiting", in{live: "12", waiting: 1}, queuedStepWait},
		{"landed before the reconnect, run still live", in{live: "12", kind: "periodic", runAt: older, landed: after - 1}, queuedStepWait},
		{"the older run expired", in{live: "12", kind: "periodic", runAt: expired}, queuedStepStart},
		{"idle", in{live: "12"}, queuedStepStart},
		{"idle, landed before the reconnect", in{live: "12", landed: after - 1}, queuedStepStart},
	}
	for _, c := range cases {
		if got := queuedSaveStep(now, "12", c.in.live, c.in.kind, c.in.runAt, c.in.busy, c.in.login, c.in.waiting, c.in.landed, after); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
}

// TestStartQueuedBackup drives the real start, which every waiter test replaces with its hook.
func TestStartQueuedBackup(t *testing.T) {
	f := bjFixture(t, "bj-start")
	queuedSaveStart = startQueuedBackup
	bjSessionFree(t)

	sessionMu.Lock()
	got := startQueuedBackup(f.dest)
	sessionMu.Unlock()
	if got != "BUSY" {
		t.Errorf("with sessionMu held: %q, want BUSY", got)
	}

	bjSetRun("periodic", time.Now())
	if got := startQueuedBackup(f.dest); got != "BUSY seal-run:periodic" {
		t.Errorf("with a live periodic: %q, want BUSY seal-run:periodic", got)
	}
	if !sessionMu.TryLock() {
		t.Fatal("startQueuedBackup left sessionMu held")
	}
	sessionMu.Unlock()

	bjSetRun("", time.Time{})
	if got := startQueuedBackup(t.TempDir()); got != "NONE" {
		t.Errorf("with no session: %q, want NONE", got)
	}
	if !sessionMu.TryLock() {
		t.Fatal("startQueuedBackup left sessionMu held")
	}
	sessionMu.Unlock()
}

// TestBackupJoinDispatcherPassesTheStamp sends the notice's bytes through handleLogin: the stamp queues one save.
func TestBackupJoinDispatcherPassesTheStamp(t *testing.T) {
	f := bjFixture(t, "bj-wire")
	bjSessionFree(t)
	bjSetRun("periodic", time.Unix(f.after-60, 0))
	req := "BACKUP\nAFTER " + strconv.FormatInt(f.after, 10) + "\n"
	var got string
	logged := captureStderr(t, func() {
		got = driveLogin(t, f.dest, req)
		bjSetRun("", time.Time{})
		f.bjWaiterEnds(t)
	})
	if got != "BUSY seal-run:periodic" {
		t.Fatalf("reply %q, want exactly BUSY seal-run:periodic", got)
	}
	if !strings.Contains(logged, "follow-up queued") || f.hook.count() != 1 {
		t.Errorf("the stamp did not reach the join: %d starts; stderr was %q", f.hook.count(), logged)
	}
}

func TestBackupJoinSixTapsOneFollowUp(t *testing.T) {
	f := bjFixture(t, "bj-six")
	bjSetRun("periodic", time.Unix(f.after-60, 0))
	logged := captureStderr(t, func() {
		for i := 0; i < 6; i++ {
			if got := f.bjTap(t); got != "BUSY seal-run:periodic" {
				t.Errorf("tap %d: reply %q, want exactly BUSY seal-run:periodic", i, got)
			}
		}
		time.Sleep(20 * time.Millisecond) // the waiter must not start the save while the running one is live
		if n := f.hook.count(); n != 0 {
			t.Errorf("the queued save started %d time(s) while the running save was live", n)
		}
		bjSetRun("", time.Time{})
		f.bjWaiterEnds(t)
	})
	if n := strings.Count(logged, "manual backup joined the running save: seal-run:periodic"); n != 6 {
		t.Errorf("%d joined lines, want 6; stderr was %q", n, logged)
	}
	if n := strings.Count(logged, "follow-up queued"); n != 1 {
		t.Errorf("%d queued lines, want 1; stderr was %q", n, logged)
	}
	if n := strings.Count(logged, "follow-up already queued"); n != 5 {
		t.Errorf("%d already-queued lines, want 5; stderr was %q", n, logged)
	}
	if strings.Contains(logged, "refused BUSY") {
		t.Errorf("a tap was refused; stderr was %q", logged)
	}
	if n := f.hook.count(); n != 1 {
		t.Errorf("queuedSaveStart called %d time(s), want exactly 1", n)
	}
	if n := strings.Count(logged, "queued save started"); n != 1 {
		t.Errorf("%d started lines, want 1; stderr was %q", n, logged)
	}
	if bjArmed() {
		t.Error("queuedSaveArmed stayed set after the waiter ended")
	}
}

// TestBackupJoinLogsTheFollowUp: the reasons that join, with what each says about a follow-up.
func TestBackupJoinLogsTheFollowUp(t *testing.T) {
	f := bjFixture(t, "bj-words")
	t.Run("seal in flight, no stamp", func(t *testing.T) {
		pendingReapMu.Lock()
		sealInFlight = true
		pendingReapMu.Unlock()
		t.Cleanup(func() {
			pendingReapMu.Lock()
			sealInFlight = false
			pendingReapMu.Unlock()
		})
		var got string
		logged := captureStderr(t, func() {
			got = ropReply(t, func(c net.Conn) { handleBackup(c, f.dest) })
		})
		if got != "BUSY seal-in-flight" {
			t.Fatalf("reply %q, want exactly BUSY seal-in-flight", got)
		}
		if !strings.Contains(logged, "joined the running save: seal-in-flight, follow-up not needed") {
			t.Errorf("stderr was %q", logged)
		}
	})
	t.Run("a sign-out, stamped", func(t *testing.T) {
		bjSetRun("logoff", time.Unix(f.after-60, 0))
		t.Cleanup(func() { bjSetRun("", time.Time{}) })
		var got string
		logged := captureStderr(t, func() { got = f.bjTap(t) })
		if got != "BUSY seal-run:logoff" {
			t.Fatalf("reply %q, want exactly BUSY seal-run:logoff", got)
		}
		if !strings.Contains(logged, "joined the running save: seal-run:logoff, follow-up none for a sign-out") {
			t.Errorf("stderr was %q", logged)
		}
		if n := f.tr.count("queued-backup"); n != 0 || bjArmed() {
			t.Errorf("a sign-out armed a waiter: %d live, armed %v", n, bjArmed())
		}
	})
}

func TestBackupJoinNewerRunQueuesNothing(t *testing.T) {
	f := bjFixture(t, "bj-newer")
	bjSetRun("periodic", time.Unix(f.after, 0))
	var got string
	logged := captureStderr(t, func() { got = f.bjTap(t) })
	if got != "BUSY seal-run:periodic" {
		t.Fatalf("reply %q, want exactly BUSY seal-run:periodic", got)
	}
	if !strings.Contains(logged, "follow-up not needed") {
		t.Errorf("stderr was %q", logged)
	}
	if n := f.tr.count("queued-backup"); n != 0 || bjArmed() {
		t.Errorf("a save from after the reconnect armed a waiter: %d live, armed %v", n, bjArmed())
	}
}

func TestQueuedSaveDropsOnSignOut(t *testing.T) {
	f := bjFixture(t, "bj-signout")
	bjSetRun("periodic", time.Unix(f.after-60, 0))
	logged := captureStderr(t, func() {
		f.bjTap(t)
		bjSetRun("logoff", time.Now())
		f.bjWaiterEnds(t)
	})
	if !strings.Contains(logged, "queued save dropped: sign-out") {
		t.Errorf("stderr was %q", logged)
	}
	bjSetRun("", time.Time{})
	time.Sleep(10 * queuedSavePoll)
	if n := f.hook.count(); n != 0 {
		t.Errorf("queuedSaveStart called %d time(s) after a sign-out", n)
	}
}

func TestQueuedSaveDropsWhenSessionEnds(t *testing.T) {
	f := bjFixture(t, "bj-ended")
	bjSetRun("periodic", time.Unix(f.after-60, 0))
	logged := captureStderr(t, func() {
		f.bjTap(t)
		if err := os.Remove(filepath.Join(f.dest, ".roamsession")); err != nil {
			t.Error(err)
		}
		f.bjWaiterEnds(t)
	})
	if !strings.Contains(logged, "queued save dropped: session-ended") {
		t.Errorf("stderr was %q", logged)
	}
	if n := f.hook.count(); n != 0 {
		t.Errorf("queuedSaveStart called %d time(s) for an ended session", n)
	}
}

func TestQueuedSaveDropsWhenTheStartFindsNoSession(t *testing.T) {
	f := bjFixture(t, "bj-none")
	f.hook.replies = []string{"NONE"}
	bjSetRun("periodic", time.Unix(f.after-60, 0))
	logged := captureStderr(t, func() {
		f.bjTap(t)
		bjSetRun("", time.Time{})
		f.bjWaiterEnds(t)
	})
	if !strings.Contains(logged, "queued save dropped: session-ended") || f.hook.count() != 1 {
		t.Errorf("%d starts; stderr was %q", f.hook.count(), logged)
	}
}

func TestQueuedSaveWaitsOnBusyStart(t *testing.T) {
	f := bjFixture(t, "bj-busy")
	f.hook.replies = []string{"BUSY seal-run:periodic"}
	bjSetRun("periodic", time.Unix(f.after-60, 0))
	logged := captureStderr(t, func() {
		f.bjTap(t)
		bjSetRun("", time.Time{})
		f.bjWaiterEnds(t)
	})
	if n := f.hook.count(); n != 2 {
		t.Errorf("queuedSaveStart called %d time(s), want 2", n)
	}
	if n := strings.Count(logged, "queued save started"); n != 1 {
		t.Errorf("%d started lines, want 1; stderr was %q", n, logged)
	}
}

func TestQueuedSaveExpires(t *testing.T) {
	f := bjFixture(t, "bj-expire")
	queuedSaveDeadline = 30 * time.Millisecond
	bjSetRun("periodic", time.Unix(f.after-60, 0))
	logged := captureStderr(t, func() {
		f.bjTap(t)
		f.bjWaiterEnds(t)
	})
	if !strings.Contains(logged, "queued save dropped: expired") || f.hook.count() != 0 {
		t.Errorf("%d starts; stderr was %q", f.hook.count(), logged)
	}
	if bjArmed() {
		t.Error("queuedSaveArmed stayed set after the waiter ended")
	}
}
