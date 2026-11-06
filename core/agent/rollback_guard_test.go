package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261013-25: a rollback discards the session unsealed, so it must not leave roamd's keystore-push stash for the
// reap's cleanstorage to seal over #keys, and it must refuse while a seal is announced. test-rollback-guard.sh
// re-runs this file against copies of main.go with each guard removed.

type rbFixture struct {
	dest   string
	called int
}

func rbSetup(t *testing.T) *rbFixture {
	t.Helper()
	f := &rbFixture{dest: t.TempDir()}
	t.Setenv("NOWHERE_STATE", f.dest)
	if err := markRoamSession(f.dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.dest, ksLogoffCredsFile), []byte("alice\npw\n10\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ropReapReset(t)
	pendingReapMu.Lock()
	sealInFlight, sealRunKind = false, ""
	pendingReapMu.Unlock()
	old := rollbackHead
	rollbackHead = func(base, name, pass string, v uint64, se []byte) (uint64, error) {
		f.called++
		return 7, nil
	}
	t.Cleanup(func() {
		rollbackHead = old
		pendingReapMu.Lock()
		sealInFlight, sealRunKind = false, ""
		pendingReapMu.Unlock()
	})
	return f
}

func (f *rbFixture) roll() string {
	a, b := net.Pipe()
	defer a.Close()
	done := make(chan string)
	go func() {
		buf := make([]byte, 256)
		n, _ := b.Read(buf)
		done <- string(buf[:n])
	}()
	handleRollback(a, f.dest, "3")
	a.Close()
	return strings.TrimSpace(<-done)
}

func TestRollback_DropsTheKeystorePushStashAndQueuesTheReap(t *testing.T) {
	f := rbSetup(t)
	if got := f.roll(); got != "OK 7" {
		t.Fatalf("got %q, want OK 7", got)
	}
	if _, err := os.Stat(filepath.Join(f.dest, ksLogoffCredsFile)); !os.IsNotExist(err) {
		t.Errorf("the keystore-push stash survived a rollback (%v): the reap would seal the discarded session's keys over #keys", err)
	}
	pendingReapMu.Lock()
	sw, rp := pendingSwitchUID, pendingReapUID
	pendingReapMu.Unlock()
	if sw != "10" || rp != "10" {
		t.Errorf("switch/reap queued for (%q, %q), want 10", sw, rp)
	}
}

func TestRollback_WithNoStashStillSucceeds(t *testing.T) {
	f := rbSetup(t)
	os.Remove(filepath.Join(f.dest, ksLogoffCredsFile))
	if got := f.roll(); got != "OK 7" {
		t.Fatalf("got %q, want OK 7 -- an absent stash is not an error", got)
	}
}

func TestRollback_BusyWhileASealIsAnnounced(t *testing.T) {
	for name, set := range map[string]func(){
		"sealInFlight": func() { sealInFlight = true },
		"periodic run": func() { sealRunKind = "periodic" },
	} {
		f := rbSetup(t)
		pendingReapMu.Lock()
		set()
		pendingReapMu.Unlock()
		if got := f.roll(); got != "BUSY" {
			t.Errorf("%s: got %q, want BUSY", name, got)
		}
		if f.called != 0 {
			t.Errorf("%s: the head was rolled while a seal was announced", name)
		}
		if n, _, _ := readRoamSession(f.dest); n != "alice" {
			t.Errorf("%s: BUSY dropped .roamsession", name)
		}
		if _, err := os.Stat(filepath.Join(f.dest, ksLogoffCredsFile)); err != nil {
			t.Errorf("%s: BUSY removed the stash: %v", name, err)
		}
		pendingReapMu.Lock()
		sw, rp := pendingSwitchUID, pendingReapUID
		pendingReapMu.Unlock()
		if sw != "" || rp != "" {
			t.Errorf("%s: BUSY queued a teardown (%q, %q)", name, sw, rp)
		}
	}
}

func TestRollback_BusyWhileATeardownIsQueued(t *testing.T) {
	f := rbSetup(t)
	pendingReapMu.Lock()
	pendingReapUID = "10"
	pendingReapMu.Unlock()
	if got := f.roll(); got != "BUSY" || f.called != 0 {
		t.Errorf("got %q (head rolled %d times), want BUSY and no roll", got, f.called)
	}
}

// The chooser must have a BUSY arm for the ROLLBACK reply, not fall through to "check your connection". Since
// NWP-20261116-22 the reply is rendered by SnapshotCopy.rollbackReply, so this pins both halves: the ROLLBACK handler
// in ProfileActivity calls it, and its body holds an equals("BUSY") arm.
func TestRollback_ChooserHasABusyArm(t *testing.T) {
	b, err := os.ReadFile("../chooser/src/com/nowhere/chooser/ProfileActivity.java")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `sendDaemon("ROLLBACK\n"`)
	if i < 0 {
		t.Fatal("the ROLLBACK send moved")
	}
	end := strings.Index(src[i:], "showSnapshots();")
	if end < 0 {
		t.Fatal("the ROLLBACK handler's end moved")
	}
	if !strings.Contains(src[i:i+end], "SnapshotCopy.rollbackReply(r)") {
		t.Error("the ROLLBACK reply handler does not render through SnapshotCopy.rollbackReply")
	}
	b, err = os.ReadFile("../chooser/src/com/nowhere/chooser/SnapshotCopy.java")
	if err != nil {
		t.Fatal(err)
	}
	sc := string(b)
	j := strings.Index(sc, "static String rollbackReply(")
	if j < 0 {
		t.Fatal("SnapshotCopy.rollbackReply moved")
	}
	k := strings.Index(sc[j:], "\n    }\n")
	if k < 0 {
		t.Fatal("SnapshotCopy.rollbackReply's end moved")
	}
	if !strings.Contains(sc[j:j+k], `equals("BUSY")`) {
		t.Error("SnapshotCopy.rollbackReply has no BUSY arm")
	}
}
