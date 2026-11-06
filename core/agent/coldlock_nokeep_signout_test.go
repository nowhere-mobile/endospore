package main

// #7 (docs/product-decisions.md, 2026-11-02; NWP-20261125-07): a cold lock's held corner whose in-place marker write
// failed signs the session out WITHOUT the keep-on-save-failure arm -- the keyguard may hold the untypable coldCredPIN,
// so a session kept when its save fails would run under a credential nobody can type. Backlog row: "`coldLockTeardown`
// writes the `.coldlock` marker in place at the point of no return and drops its error, so a marker that cannot be
// written leaves a stopped session nothing can resume". coldLockSignOutNoKeep marks the session's uid in
// logoutNoKeepUID; handleLogout reads and clears the mark once, at entry, and its failed-seal and media-sweep arms then
// end the session through logoutEndNoKeep instead of re-arming it. These tests drive the real handleLogout through
// cutoffWorker, with logoutNoKeepReap replaced by a recorder.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"sync"
	"testing"
	"time"
)

// nkReaps records logoutNoKeepReap.
type nkReaps struct {
	mu   sync.Mutex
	uids []string
	ch   chan struct{}
}

func (r *nkReaps) got() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.uids...)
}

// nkSetup seats a stored session for uid under its own profile name, stubs the sync and the inbox staging, and
// replaces logoutNoKeepReap with a recorder. The mark is cleared around the test.
func nkSetup(t *testing.T, uid, profile string) (string, *nkReaps) {
	t.Helper()
	dest := cutoffSession(t, uid)
	if err := markRoamSession(dest, profile, "correct horse", uid, ""); err != nil {
		t.Fatal(err)
	}
	rearmNoSync(t)
	t.Cleanup(resetMediaStuck)
	t.Cleanup(resetPushStuck)
	stage := logoffStageInbox
	logoffStageInbox = func(base, name, pass, uid string, se []byte) {}
	r := &nkReaps{ch: make(chan struct{}, 4)}
	reap := logoutNoKeepReap
	logoutNoKeepReap = func(u string) {
		r.mu.Lock()
		r.uids = append(r.uids, u)
		r.mu.Unlock()
		r.ch <- struct{}{}
	}
	clear := func() {
		pendingReapMu.Lock()
		logoutNoKeepUID = ""
		pendingReapMu.Unlock()
	}
	clear()
	t.Cleanup(func() { logoffStageInbox, logoutNoKeepReap = stage, reap; clear() })
	return dest, r
}

func nkMark(uid string) {
	pendingReapMu.Lock()
	logoutNoKeepUID = uid
	pendingReapMu.Unlock()
}

func nkMarkNow() string {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return logoutNoKeepUID
}

// nkLogout drives LOGOUT for dest and waits (hang guards only) for its logoff goroutine to end.
func nkLogout(t *testing.T, dest, uid string) {
	t.Helper()
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	logoffDone(t, uid, rearmHang)
}

// nkEnded checks a no-keep sign-out that ended its session: reaped once, the switch queued, nothing re-armed.
func nkEnded(t *testing.T, dest, uid string, r *nkReaps) {
	t.Helper()
	select {
	case <-r.ch:
	case <-time.After(10 * time.Second):
		t.Fatal("logoutNoKeepReap never ran: the no-keep sign-out kept the session")
	}
	if got := r.got(); len(got) != 1 || got[0] != uid {
		t.Errorf("logoutNoKeepReap calls = %q, want exactly one for %s", got, uid)
	}
	if got := nextReapAction(); got != "SWITCH "+uid {
		t.Errorf("nextReapAction = %q, want SWITCH %s", got, uid)
	}
	if name, _, _ := readRoamSession(dest); name != "" {
		t.Errorf(".roamsession was re-armed (%q): a no-keep sign-out keeps nothing", name)
	}
	if m := nkMarkNow(); m != "" {
		t.Errorf("logoutNoKeepUID = %q after the sign-out, want \"\"", m)
	}
	pendingReapMu.Lock()
	inFlight, failed := sealInFlight, sealFail
	pendingReapMu.Unlock()
	if inFlight || failed {
		t.Errorf("sealInFlight=%v sealFail=%v, want false and false: nothing says FAILED and hands the screen back", inFlight, failed)
	}
}

func nkHas(ops []string, op string) bool {
	for _, o := range ops {
		if o == op {
			return true
		}
	}
	return false
}

// N1. A failed seal ends a marked session: reaped, switched, not re-armed, no wake.
func TestColdLockNoKeep_AFailedSealEndsTheSession(t *testing.T) {
	const uid = "93"
	dest, r := nkSetup(t, uid, "nokeep1")
	ops := cutoffWorker(t, dest, rearmAnswers(map[string]string{"out": "ERR-PUSH 1"}), nil)
	nkMark(uid)
	nkLogout(t, dest, uid)
	nkEnded(t, dest, uid, r)
	if got := ops(); !nkHas(got, "out") || nkHas(got, "cutoffwake") {
		t.Errorf("ops = %v, want an out and no cutoffwake", got)
	}
}

// N2. A media sweep that does not verify ends a marked session without a seal.
func TestColdLockNoKeep_AFailedMediaSweepEndsTheSession(t *testing.T) {
	const uid = "94"
	dest, r := nkSetup(t, uid, "nokeep2")
	ops := cutoffWorker(t, dest, rearmAnswers(map[string]string{"sweepmedia": "ERR-MEDIA-SWEEP 1"}), nil)
	nkMark(uid)
	nkLogout(t, dest, uid)
	nkEnded(t, dest, uid, r)
	if got := ops(); nkHas(got, "out") || nkHas(got, "cutoffwake") {
		t.Errorf("ops = %v, want no out and no cutoffwake", got)
	}
}

// N3. Control (#86 Fix A): with no mark the same failed seal keeps the session signed in and queues nothing.
func TestColdLockNoKeep_ControlKeepsTheSession(t *testing.T) {
	const uid = "95"
	dest, r := nkSetup(t, uid, "nokeep3")
	cutoffWorker(t, dest, rearmAnswers(map[string]string{"out": "ERR-PUSH 1"}), nil)
	nkLogout(t, dest, uid)
	if name, _, u := readRoamSession(dest); name != "nokeep3" || u != uid {
		t.Errorf(".roamsession = (%q, %q), want the session re-armed", name, u)
	}
	if got := r.got(); len(got) != 0 {
		t.Errorf("logoutNoKeepReap ran for %q without a mark", got)
	}
	if got := nextReapAction(); got != "NONE" {
		t.Errorf("nextReapAction = %q, want NONE", got)
	}
}

// N4. Through the real coldLockSignOut: coldLockSignOutNoKeep marks, the sign-out reads the mark at entry, and its
// failed seal ends the session after coldLockSignOutNoKeep has already cleared the mark.
func TestColdLockNoKeep_ThroughTheRealSignOut(t *testing.T) {
	const uid = "96"
	dest, r := nkSetup(t, uid, "nokeep4")
	cutoffWorker(t, dest, rearmAnswers(map[string]string{"out": "ERR-PUSH 1"}), nil)
	done := make(chan struct{})
	go func() { coldLockSignOutNoKeep(dest); close(done) }()
	select {
	case <-done:
	case <-time.After(rearmHang):
		t.Fatal("coldLockSignOutNoKeep did not return")
	}
	logoffDone(t, uid, rearmHang)
	nkEnded(t, dest, uid, r)
}

// N5. A mark for another uid does not reach this sign-out: the session is kept and the mark stays.
func TestColdLockNoKeep_AnotherUsersMarkIsNotTaken(t *testing.T) {
	const uid = "97"
	dest, r := nkSetup(t, uid, "nokeep5")
	cutoffWorker(t, dest, rearmAnswers(map[string]string{"out": "ERR-PUSH 1"}), nil)
	nkMark("98")
	nkLogout(t, dest, uid)
	if name, _, _ := readRoamSession(dest); name != "nokeep5" {
		t.Errorf(".roamsession = %q, want the session re-armed", name)
	}
	if got := r.got(); len(got) != 0 {
		t.Errorf("logoutNoKeepReap ran for %q under another user's mark", got)
	}
	if m := nkMarkNow(); m != "98" {
		t.Errorf("logoutNoKeepUID = %q, want 98 left alone", m)
	}
}

// N6. The capture is at entry, by construction. coldLockSignOutNoKeep clears the mark once its sign-out answers, and
// handleLogout answers before its goroutines run, so a goroutine that read the mark itself could find it cleared and
// keep the session under coldCredPIN. N4 cannot force that interleaving, so this pins the source: handleLogout's own
// body reads logoutNoKeepUID before its first goSafe, and no func literal inside handleLogout reads it.
func TestColdLockNoKeep_HandleLogoutCapturesTheMarkAtEntry(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var fn *ast.FuncDecl
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv == nil && fd.Name.Name == "handleLogout" {
			fn = fd
		}
	}
	if fn == nil {
		t.Fatal("handleLogout not found in main.go")
	}
	mentions := func(n ast.Node) bool {
		found := false
		ast.Inspect(n, func(m ast.Node) bool {
			if id, ok := m.(*ast.Ident); ok && id.Name == "logoutNoKeepUID" {
				found = true
			}
			return !found
		})
		return found
	}
	isGoSafe := func(s ast.Stmt) bool {
		es, ok := s.(*ast.ExprStmt)
		if !ok {
			return false
		}
		call, ok := es.X.(*ast.CallExpr)
		if !ok {
			return false
		}
		id, ok := call.Fun.(*ast.Ident)
		return ok && id.Name == "goSafe"
	}
	readAt, goSafeAt := -1, -1
	for i, s := range fn.Body.List {
		if readAt < 0 && mentions(s) {
			readAt = i
		}
		if goSafeAt < 0 && isGoSafe(s) {
			goSafeAt = i
		}
	}
	if readAt < 0 {
		t.Error("handleLogout's own body never reads logoutNoKeepUID: the no-keep mark is not captured at entry")
	}
	if goSafeAt >= 0 && readAt > goSafeAt {
		t.Errorf("handleLogout reads logoutNoKeepUID at statement %d, after its first goSafe at %d: capture it at entry", readAt, goSafeAt)
	}
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if lit, ok := n.(*ast.FuncLit); ok && mentions(lit) {
			t.Errorf("a func literal in handleLogout reads logoutNoKeepUID (%s): its goroutines must capture noKeep, never the global", fset.Position(lit.Pos()))
			return false
		}
		return true
	})
}
