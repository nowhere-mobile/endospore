package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// NWP-20261129-07: the state tmpfs lives for the BOOT and a marker's name is the same in every session of its profile, so
// a marker a seal did not use (the walk-explained arm, a scope that did not shrink) was still armed in the next session
// on that boot, where a deliberate one allows any drastic shrink outright. A new recorded sign-in forgets them all.

// sfgRefs is the four scope refs markProfileShrinkIntent marks.
func sfgRefs(name, pass string) []string {
	var refs []string
	for _, scope := range []string{name, name + "#de", name + "#media", name + "#apps"} {
		refs = append(refs, profileRefV2(scope, pass))
	}
	return refs
}

// sfgArm arms what a Stop keeping tap and an inferred drop leave: three deliberate markers and an inferred #apps one.
func sfgArm(t *testing.T, name, pass string) []string {
	t.Helper()
	if err := markProfileShrinkIntent(name, pass); err != nil {
		t.Fatal(err)
	}
	refs := sfgRefs(name, pass)
	if err := markShrinkIntentInferred(refs[3], []string{"com.example.dropped"}); err != nil {
		t.Fatal(err)
	}
	sfgRequireArmed(t, refs, "control: after arming")
	return refs
}

func sfgRequireArmed(t *testing.T, refs []string, what string) {
	t.Helper()
	for i, r := range refs {
		if !haveShrinkIntent(r) {
			t.Errorf("%s: marker %d of %d is not armed", what, i+1, len(refs))
		}
	}
}

func sfgRequireNoneArmed(t *testing.T, refs []string, what string) {
	t.Helper()
	for i, r := range refs {
		if haveShrinkIntent(r) {
			t.Errorf("%s: marker %d of %d still has authority", what, i+1, len(refs))
		}
	}
}

// sfgExists reports whether a path is there, and fails on anything but "absent".
func sfgExists(t *testing.T, p string) bool {
	t.Helper()
	_, err := os.Lstat(p)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return err == nil
}

func TestShrinkForget_EveryKindGoes(t *testing.T) {
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	refs := sfgArm(t, "sfalice", "sfalice passphrase")
	var n int
	captureStderr(t, func() { n = forgetShrinkIntents(dest) })
	if n != 4 {
		t.Errorf("forgot %d markers, want 4", n)
	}
	// Before any reader: lockShrinkDir creates the lock file, so a reader would hide a forget that removed it.
	if !sfgExists(t, filepath.Join(dest, "shrink-intent", shrinkLockName)) {
		t.Errorf("the forget removed %s: a process waiting on the old file and one on a new file would both hold the lock", shrinkLockName)
	}
	sfgRequireNoneArmed(t, refs, "after the forget")

	empty := t.TempDir()
	if n := forgetShrinkIntents(empty); n != 0 {
		t.Errorf("forgot %d markers with no directory, want 0", n)
	}
	if sfgExists(t, filepath.Join(empty, "shrink-intent")) {
		t.Error("the forget created the directory")
	}
}

func TestShrinkForget_SweepsTheLeftovers(t *testing.T) {
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	refs := sfgRefs("sfleft", "sfleft passphrase")
	if err := markShrinkIntent(refs[0]); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(dest, "shrink-intent")
	leftovers := []string{refs[0] + shrinkOldSuffix, refs[0] + ".new", refs[0] + shrinkOldSuffix + ".new", shrinkTxnName, shrinkTxnName + ".new"}
	for _, l := range leftovers {
		if err := os.WriteFile(filepath.Join(dir, l), []byte("left"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var n int
	captureStderr(t, func() { n = forgetShrinkIntents(dest) })
	if n != 1 {
		t.Errorf("forgot %d markers, want 1", n)
	}
	for i, l := range leftovers {
		if sfgExists(t, filepath.Join(dir, l)) {
			t.Errorf("leftover %d of %d is still there", i+1, len(leftovers))
		}
	}
	if !sfgExists(t, filepath.Join(dir, shrinkLockName)) {
		t.Errorf("the forget removed %s", shrinkLockName)
	}
}

func TestShrinkForget_AMarkerThatCannotBeRemovedIsTombstoned(t *testing.T) {
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	refs := sfgArm(t, "sfdave", "sfdave passphrase")
	orig := shrinkRemove
	shrinkRemove = func(string) error { return syscall.EIO }
	t.Cleanup(func() { shrinkRemove = orig })
	var n int
	captureStderr(t, func() { n = forgetShrinkIntents(dest) })
	if n != 4 {
		t.Errorf("forgot %d markers, want 4", n)
	}
	for i, r := range refs {
		b, err := os.ReadFile(filepath.Join(dest, "shrink-intent", r))
		if err != nil || string(b) != consumedMarker {
			t.Errorf("marker %d of %d is not the tombstone: %q, %v", i+1, len(refs), b, err)
		}
	}
	sfgRequireNoneArmed(t, refs, "after the tombstones")
}

func TestShrinkForget_AMarkerThatCannotBeNeutralisedKeepsTheFlag(t *testing.T) {
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	ref := sfgRefs("sfstuck", "sfstuck passphrase")[0]
	if err := markShrinkIntent(ref); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(dest, "shrink-intent")
	for _, l := range []string{shrinkTxnName, ref + shrinkOldSuffix} {
		if err := os.WriteFile(filepath.Join(dir, l), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	origRm, origRw := shrinkRemove, shrinkRewrite
	shrinkRemove = func(string) error { return syscall.EIO }
	shrinkRewrite = func(string, []byte, os.FileMode) error { return syscall.EIO }
	t.Cleanup(func() { shrinkRemove, shrinkRewrite = origRm, origRw })
	var n int
	log := captureStderr(t, func() { n = forgetShrinkIntents(dest) })
	if n != 0 {
		t.Errorf("counted %d markers as forgotten, want 0", n)
	}
	if !strings.Contains(log, "1 marker(s) an earlier session left could NOT be neutralised") {
		t.Errorf("the log does not say so: %q", log)
	}
	for _, l := range []string{shrinkTxnName, ref + shrinkOldSuffix} {
		if !sfgExists(t, filepath.Join(dir, l)) {
			t.Error("the forget removed the flag or the record of a marker it could not neutralise, which would hand it its authority back")
		}
	}
	if haveShrinkIntent(ref) {
		t.Error("a marker that is pending under the flag has authority")
	}
}

func TestShrinkForget_ALockItCannotGetIsSaid(t *testing.T) {
	t.Run("unavailable", func(t *testing.T) {
		dest := t.TempDir()
		if err := os.WriteFile(filepath.Join(dest, "shrink-intent"), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		var n int
		log := captureStderr(t, func() { n = forgetShrinkIntents(dest) })
		if n != 0 || !strings.Contains(log, "NOT forgotten (directory unavailable)") {
			t.Errorf("forgot %d, log %q", n, log)
		}
	})
	t.Run("busy", func(t *testing.T) {
		dest := t.TempDir()
		t.Setenv("NOWHERE_STATE", dest)
		refs := sfgArm(t, "sfbusy", "sfbusy passphrase")
		orig := shrinkLockWait
		shrinkLockWait = 20 * time.Millisecond
		t.Cleanup(func() { shrinkLockWait = orig })
		unlock, err := lockShrinkDir(filepath.Join(dest, "shrink-intent"), false)
		if err != nil {
			t.Fatal(err)
		}
		var n int
		log := captureStderr(t, func() { n = forgetShrinkIntents(dest) })
		unlock()
		if n != 0 || !strings.Contains(log, "NOT forgotten (directory busy)") {
			t.Errorf("forgot %d, log %q", n, log)
		}
		sfgRequireArmed(t, refs, "after a forget that had no lock")
	})
}

func TestShrinkForget_OfflineSignIn(t *testing.T) {
	const pw = "sfbob passphrase"
	f := walletFailSetup(t)
	rwWorker(t, f.dest, map[string]string{"btwipe": "OK"})
	refs := sfgArm(t, "sfbob", pw)
	var reply string
	captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) { handleRoamInOffline(c, f.dest, "", pw, "21") })
	})
	if reply != "BLANK" {
		t.Fatalf("control: a sign-in with no name replied %q, want BLANK", reply)
	}
	sfgRequireArmed(t, refs, "after an offline sign-in refused before its marker")
	captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) { handleRoamInOffline(c, f.dest, "sfbob", pw, "21") })
	})
	if reply != "OK 21" {
		t.Fatalf("offline sign-in replied %q, want OK 21", reply)
	}
	sfgRequireNoneArmed(t, refs, "after an offline sign-in")
}

func TestShrinkForget_OnlineSignIn(t *testing.T) {
	const pw = "sfcarol passphrase"
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	rwWorker(t, f.dest, map[string]string{"in": "OK 21"})
	lateWorkDrain(t)
	refs := sfgArm(t, "sfcarol", pw)
	var reply string
	captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) { handleRoamIn(c, f.dest, "sfcarol", pw, "21", "", "") })
	})
	if !strings.HasPrefix(reply, "OK") {
		t.Fatalf("online sign-in replied %q, want OK", reply)
	}
	sfgRequireNoneArmed(t, refs, "after an online sign-in")
}

// The cold-lock fixture names its profile "alice" and crLock does not set NOWHERE_STATE: without it the markers are inert.
func TestShrinkForget_AResumeKeepsItsOwn(t *testing.T) {
	l := crLock(t, crKinds[0])
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	t.Setenv("NOWHERE_STATE", l.dest)
	refs := sfgArm(t, "alice", crPass)
	if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
		t.Fatalf("control: RESUME replied %q, want OK 10", got)
	}
	sfgRequireArmed(t, refs, "after a cold-lock RESUME")
}

func TestShrinkForget_CallSites(t *testing.T) {
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
	const call = "forgetShrinkIntents(dest)"
	in := fn("func handleRoamIn(", "func handleRoamInOffline(")
	after, forget, claim := at(in, "handleRoamIn", "recordAnrSeen(dest)"), at(in, "handleRoamIn", call), at(in, "handleRoamIn", `claimLocGlobalsAsync(dest, uid, "signin")`)
	if !(after < forget && forget < claim) {
		t.Errorf("sign-in order: recordAnrSeen %d, forget %d, claim %d", after, forget, claim)
	}
	off := fn("func handleRoamInOffline(", "func handleRelogin(")
	after, forget, claim = at(off, "handleRoamInOffline", "resetSealSignals()"), at(off, "handleRoamInOffline", call), at(off, "handleRoamInOffline", `claimLocGlobalsAsync(dest, uid, "offline")`)
	if !(after < forget && forget < claim) {
		t.Errorf("offline order: resetSealSignals %d, forget %d, claim %d", after, forget, claim)
	}
	for _, fnName := range []string{"handleResume", "handleRotate", "handlePromote2"} {
		if strings.Contains(fileFuncBody(t, "main.go", fnName), "forgetShrinkIntents(") {
			t.Errorf("%s continues a session and must keep its markers", fnName)
		}
	}
	if strings.Contains(fileFuncBody(t, "roamsession_marker.go", "markRoamSession"), "forgetShrinkIntents(") {
		t.Error("markRoamSession runs for RESUME and the rotations too, which continue one session")
	}
}
