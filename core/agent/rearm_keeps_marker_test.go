package main

// NWP-20261020-02: a logoff's re-arm continues the session only when nothing newer armed it. The backlog row
// "A PASSPHRASE CHANGE MADE IN A LIVE SESSION LEAVES THAT SESSION SEALING NOTHING, AND REPORTING SUCCESS" names
// handleLogout's late re-arm as a writer that captured the marker at LOGOUT and wrote it back unconditionally,
// over a rotation's newer one. These tests drive the real functions in a temp dest.

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	rkOldPass = "old-passphrase-zz"
	rkNewPass = "new-passphrase-qq"
	rkSE      = "se-secret-material"
)

func rkRead(t *testing.T, dest string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dest, roamSessionFile))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func rkNoSecrets(t *testing.T, log string) {
	t.Helper()
	for _, s := range []string{tName, rkOldPass, rkNewPass, rkSE} {
		if strings.Contains(log, s) {
			t.Fatalf("log leaked a marker value %q: %q", s, log)
		}
	}
}

func TestRearmKeepsNewerCompleteMarker(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, tName, rkNewPass, "11", rkSE); err != nil {
		t.Fatal(err)
	}
	before := rkRead(t, dest)
	log := captureStderr(t, func() {
		rearmRoamSession(dest, tName, rkOldPass, "11", rkSE, "late logout verdict after unstick, re-arm")
	})
	if string(rkRead(t, dest)) != string(before) {
		t.Fatalf("a re-arm replaced a complete marker: %q", rkRead(t, dest))
	}
	if !strings.Contains(log, "was re-written after this teardown captured it") || !strings.Contains(log, "keeping it, user 11") ||
		!strings.Contains(log, "late logout verdict after unstick, re-arm") {
		t.Fatalf("keep line missing: %q", log)
	}
	rkNoSecrets(t, log)
}

func TestRearmIdenticalMarkerIsSilent(t *testing.T) {
	dest := t.TempDir()
	if err := markRoamSession(dest, tName, rkOldPass, "11", rkSE); err != nil {
		t.Fatal(err)
	}
	before := rkRead(t, dest)
	log := captureStderr(t, func() { rearmRoamSession(dest, tName, rkOldPass, "11", rkSE, "watchdog unstick, re-arm") })
	if log != "" || string(rkRead(t, dest)) != string(before) {
		t.Fatalf("identical re-arm must be silent and change nothing: %q", log)
	}
}

func TestRearmDifferentSessionIsNotOverwritten(t *testing.T) {
	for _, tc := range []struct{ name, uid string }{{tName, "12"}, {"someone-else", "11"}} {
		dest := t.TempDir()
		if err := markRoamSession(dest, tc.name, rkNewPass, tc.uid, rkSE); err != nil {
			t.Fatal(err)
		}
		before := rkRead(t, dest)
		log := captureStderr(t, func() { rearmRoamSession(dest, tName, rkOldPass, "11", rkSE, "failed-seal arm") })
		if string(rkRead(t, dest)) != string(before) {
			t.Fatalf("%+v: a re-arm replaced another session's marker", tc)
		}
		if !strings.Contains(log, ".roamsession names another session -- not overwritten") || strings.Contains(log, "keeping it") {
			t.Fatalf("%+v: want the not-overwritten line only: %q", tc, log)
		}
		rkNoSecrets(t, log)
	}
}

func TestRearmWritesWhenAbsentOrDamaged(t *testing.T) {
	dest := t.TempDir()
	rearmRoamSession(dest, tName, rkOldPass, "11", rkSE, "absent")
	if f, st := readRoamSessionFields(dest); st != roamSessionComplete || f != [4]string{tName, rkOldPass, "11", rkSE} {
		t.Fatalf("absent marker not written: %v %v", f, st)
	}
	dest = t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte(tName+"\n"+rkNewPass+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rearmRoamSession(dest, tName, rkOldPass, "11", rkSE, "damaged")
	if f, st := readRoamSessionFields(dest); st != roamSessionComplete || f != [4]string{tName, rkOldPass, "11", rkSE} {
		t.Fatalf("damaged marker not overwritten: %v %v", f, st)
	}
}

// A rotation's markRoamSession landing while a re-arm is mid-write on a damaged marker must survive it: the
// re-arm's read-decide-write and mark are one critical section.
func TestRearmAndMarkAreSerialised(t *testing.T) {
	orig := roamSessionWriteFile
	defer func() { roamSessionWriteFile = orig }()
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	entered := make(chan struct{})
	release := make(chan struct{})
	first := true
	roamSessionWriteFile = func(name string, data []byte, perm os.FileMode) error {
		if first {
			first = false
			close(entered)
			<-release
		}
		return os.WriteFile(name, data, perm)
	}
	var once sync.Once
	releaseOnce := func() { once.Do(func() { close(release) }) }
	defer releaseOnce() // a failing assertion must not leave the re-arm blocked on the seam
	done := make(chan struct{}, 2)
	go func() { rearmRoamSession(dest, tName, rkOldPass, "11", rkSE, "interleave"); done <- struct{}{} }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("the re-arm of a damaged marker never reached the write")
	}
	go func() {
		if err := markRoamSession(dest, tName, rkNewPass, "11", rkSE); err != nil {
			t.Error(err)
		}
		done <- struct{}{}
	}()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if f, st := readRoamSessionFields(dest); st == roamSessionComplete && f[1] == rkNewPass {
			t.Fatal("markRoamSession landed while the re-arm was mid-write: the two are not serialised")
		}
		time.Sleep(10 * time.Millisecond)
	}
	releaseOnce()
	<-done
	<-done
	if f, st := readRoamSessionFields(dest); st != roamSessionComplete || f[1] != rkNewPass {
		t.Fatalf("the rotation's marker did not survive the re-arm: %v %v", f, st)
	}
}
