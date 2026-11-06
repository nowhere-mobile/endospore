package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261026-02: a resume arms the 180s login window and, unlike a sign-in, never sends GRANT-PERMS, so nothing
// closed it early: Back up now answered BUSY: login and the periodic seal deferred for ~2 min after every resume
// (lynx 0.5.48, 2026-10-19). The resume now closes the window to the tail at its OK reply.

// rlwSaveWindow restores the window's three globals when the test ends. Register it BEFORE crLock: cleanups run
// last-in first, so crReset's zeroing runs first and this restore last.
func rlwSaveWindow(t *testing.T) {
	t.Helper()
	pendingReapMu.Lock()
	until, at, deferred := loginSettleUntil, loginWindowAt, loginDeferred
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		loginSettleUntil, loginWindowAt, loginDeferred = until, at, deferred
		pendingReapMu.Unlock()
	})
}

func rlwWindow() time.Time {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return loginSettleUntil
}

func TestResumeLoginWindowClosesToTheTailAtTheReply(t *testing.T) {
	rlwSaveWindow(t)
	l := crLock(t, crKinds[0])
	rec := locSetup(t, "OK APPLIED network_location=2 geocoder=0")
	crStartFake(t, l.dest, &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1})
	if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
		t.Fatalf("the resume was refused (%q)", got)
	}
	rec.wait(t, "a resume")
	w := rlwWindow()
	if w.IsZero() {
		t.Fatal("the window is zero after a resume: it must stay open for the tail")
	}
	if limit := time.Now().Add(loginWindowTail + time.Second); w.After(limit) {
		t.Errorf("the window runs %v past now after the resume, want at most the %v tail", time.Until(w), loginWindowTail)
	}
	if why := backupBusyReason(time.Now().Add(loginWindowTail+time.Second), false, w, 0, "", time.Time{}); why != "" {
		t.Errorf("Back up now is still refused (%q) once the tail has passed", why)
	}
}

func TestResumeLoginWindowARefusedResumeLeavesItAsItWas(t *testing.T) {
	rlwSaveWindow(t)
	l := crLock(t, crKinds[0])
	rec := locSetup(t, "OK APPLIED network_location=2 geocoder=0")
	crStartFake(t, l.dest, &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1})
	before := time.Now().Add(loginWindowCap)
	pendingReapMu.Lock()
	loginSettleUntil = before
	pendingReapMu.Unlock()
	if got := crResume(t, l.dest, "not-the-passphrase"); got == "OK 10" {
		t.Fatal("control failed: a wrong entry resumed")
	}
	rec.none(t, "a refused resume")
	if w := rlwWindow(); !w.Equal(before) {
		t.Errorf("a refused resume moved the window: %v, was %v", w, before)
	}
}

func TestCloseLoginWindowOnlyClosesAnOpenWindow(t *testing.T) {
	rlwSaveWindow(t)
	pendingReapMu.Lock()
	loginSettleUntil = time.Time{}
	pendingReapMu.Unlock()
	if out := captureStderr(t, func() { closeLoginWindow("10") }); out != "" {
		t.Errorf("a closed window printed %q", out)
	}
	if w := rlwWindow(); !w.IsZero() {
		t.Errorf("a stray close opened a window: %v", w)
	}

	pendingReapMu.Lock()
	loginSettleUntil, loginWindowAt = time.Now().Add(loginWindowCap), time.Now()
	pendingReapMu.Unlock()
	out := captureStderr(t, func() { closeLoginWindow("10") })
	w := rlwWindow()
	if w.IsZero() || w.After(time.Now().Add(loginWindowTail+time.Second)) {
		t.Errorf("an open window closed to %v, want the %v tail", time.Until(w), loginWindowTail)
	}
	for _, want := range []string{"login window cleared user 10 after ", "periodic seal(s) deferred, tail 15s (NWP-20260821-19)"} {
		if !strings.Contains(out, want) {
			t.Errorf("cleared line lacks %q: %q", want, out)
		}
	}
}

func TestResumeLoginWindowSourcePins(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	body := func(name string) string {
		t.Helper()
		i := strings.Index(src, "func "+name+"(")
		if i < 0 {
			t.Fatalf("func %s not found", name)
		}
		rest := src[i:]
		if j := strings.Index(rest[1:], "\nfunc "); j >= 0 {
			rest = rest[:j+1]
		}
		return rest
	}
	grant := body("handleGrantPerms")
	if !strings.Contains(grant, "closeLoginWindow(uid)") {
		t.Error("handleGrantPerms no longer closes the login window through closeLoginWindow")
	}
	if strings.Contains(grant, "loginSettleUntil = time.Now().Add(loginWindowTail)") {
		t.Error("handleGrantPerms sets the window inline again")
	}
	resume := body("handleResume")
	ok := strings.Index(resume, `fmt.Fprintf(conn, "OK %s\n", uid)`)
	if ok < 0 {
		t.Fatal("handleResume's OK reply not found")
	}
	if n := strings.Count(resume, "closeLoginWindow(uid)"); n != 1 {
		t.Fatalf("handleResume calls closeLoginWindow(uid) %d times, want exactly 1", n)
	}
	if strings.Index(resume, "closeLoginWindow(uid)") < ok {
		t.Error("handleResume closes the window before its OK reply")
	}
}
