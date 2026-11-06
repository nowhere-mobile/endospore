package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261028-05: SET-GATE-ALARM used to discard its write and remove errors, store any text as the time, and
// answer OK whatever happened, which defeated the logoff screen's "may not ring" warning. Each test drives the
// real dispatcher and asserts the reply, the gate.log line and the files.

func relayFutureMs() string {
	return strconv.FormatInt(time.Now().Add(time.Hour).UnixMilli(), 10)
}

func relayLog(t *testing.T, logPath string) string {
	t.Helper()
	b, _ := os.ReadFile(logPath)
	return string(b)
}

func relayHolds(t *testing.T, path, want string) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Errorf("%s: %v", filepath.Base(path), err)
		return
	}
	if string(b) != want {
		t.Errorf("%s = %q, want %q", filepath.Base(path), b, want)
	}
}

func TestGateAlarmRelay_StoresATimeAndItsOwner(t *testing.T) {
	logPath := gateLogTestFile(t)
	dest := t.TempDir()
	when := relayFutureMs()
	if got := evictConn(t, dest, "SET-GATE-ALARM\n"+when+"\t15\tcom.android.deskclock\n"); got != "OK" {
		t.Errorf("reply %q, want OK", got)
	}
	relayHolds(t, filepath.Join(dest, "gate-alarm"), when)
	relayHolds(t, filepath.Join(dest, "gate-alarm-src"), "15\tcom.android.deskclock")
	if l := relayLog(t, logPath); !strings.Contains(l, "relay-set-src") {
		t.Errorf("gate.log lacks relay-set-src: %q", l)
	}
}

func TestGateAlarmRelay_RefusesANonNumber(t *testing.T) {
	for _, bad := range []string{"abc", "-5", "12x"} {
		logPath := gateLogTestFile(t)
		dest := t.TempDir()
		if got := evictConn(t, dest, "SET-GATE-ALARM\n"+bad+"\n"); got != "ERR" {
			t.Errorf("%q: reply %q, want ERR", bad, got)
		}
		if _, err := os.Stat(filepath.Join(dest, "gate-alarm")); !os.IsNotExist(err) {
			t.Errorf("%q: a gate-alarm file was stored (%v)", bad, err)
		}
		if l := relayLog(t, logPath); !strings.Contains(l, "relay-err") {
			t.Errorf("%q: gate.log lacks relay-err: %q", bad, l)
		}
	}
}

func TestGateAlarmRelay_FailedTimeWriteIsERRAndDropsTheOwner(t *testing.T) {
	logPath := gateLogTestFile(t)
	dest := t.TempDir()
	if err := os.Mkdir(filepath.Join(dest, "gate-alarm"), 0o700); err != nil {
		t.Fatal(err)
	}
	ps := filepath.Join(dest, "gate-alarm-src")
	if err := os.WriteFile(ps, []byte("14\tcom.old.clock"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := evictConn(t, dest, "SET-GATE-ALARM\n"+relayFutureMs()+"\t15\tcom.android.deskclock\n"); got != "ERR" {
		t.Errorf("reply %q, want ERR", got)
	}
	if _, err := os.Stat(ps); !os.IsNotExist(err) {
		t.Errorf("an owner from an earlier relay survived a time that was not stored (%v)", err)
	}
	if l := relayLog(t, logPath); !strings.Contains(l, "relay-err") {
		t.Errorf("gate.log lacks relay-err: %q", l)
	}
}

func TestGateAlarmRelay_FailedOwnerWriteStaysOK(t *testing.T) {
	logPath := gateLogTestFile(t)
	dest := t.TempDir()
	if err := os.Mkdir(filepath.Join(dest, "gate-alarm-src"), 0o700); err != nil {
		t.Fatal(err)
	}
	when := relayFutureMs()
	if got := evictConn(t, dest, "SET-GATE-ALARM\n"+when+"\t15\tcom.android.deskclock\n"); got != "OK" {
		t.Errorf("reply %q, want OK (the time is stored, so the alarm rings)", got)
	}
	relayHolds(t, filepath.Join(dest, "gate-alarm"), when)
	l := relayLog(t, logPath)
	if !strings.Contains(l, "relay-src-err") {
		t.Errorf("gate.log lacks relay-src-err: %q", l)
	}
	if strings.Contains(l, "relay-set-src") {
		t.Errorf("gate.log claims relay-set-src for an owner that was not stored: %q", l)
	}
}

func TestGateAlarmRelay_ClearThatCannotRemoveIsERR(t *testing.T) {
	logPath := gateLogTestFile(t)
	dest := t.TempDir()
	p := filepath.Join(dest, "gate-alarm")
	if err := os.Mkdir(p, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p, "x"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := evictConn(t, dest, "SET-GATE-ALARM\n0\n"); got != "ERR" {
		t.Errorf("reply %q, want ERR", got)
	}
	if l := relayLog(t, logPath); !strings.Contains(l, "relay-err") {
		t.Errorf("gate.log lacks relay-err: %q", l)
	}
}

func TestGateAlarmRelay_ClearWithNothingThereIsOK(t *testing.T) {
	logPath := gateLogTestFile(t)
	dest := t.TempDir()
	if got := evictConn(t, dest, "SET-GATE-ALARM\n0\n"); got != "OK" {
		t.Errorf("reply %q, want OK", got)
	}
	l := relayLog(t, logPath)
	if !strings.Contains(l, "relay-clear") || strings.Contains(l, "relay-err") {
		t.Errorf("gate.log = %q, want relay-clear and no relay-err", l)
	}
}

func TestGateAlarmRelay_HeldClearIsOKAndTouchesNothing(t *testing.T) {
	logPath := gateLogTestFile(t)
	dest := t.TempDir()
	cutoffHoldMu.Lock()
	prev := cutoffHoldUID
	cutoffHoldUID = "15"
	cutoffHoldMu.Unlock()
	t.Cleanup(func() {
		cutoffHoldMu.Lock()
		cutoffHoldUID = prev
		cutoffHoldMu.Unlock()
	})
	if !cutoffHolding() {
		t.Fatal("cutoffHolding() is not true")
	}
	p, ps := filepath.Join(dest, "gate-alarm"), filepath.Join(dest, "gate-alarm-src")
	os.WriteFile(p, []byte("1760000000000"), 0o600)
	os.WriteFile(ps, []byte("15\tcom.android.deskclock"), 0o600)
	if got := evictConn(t, dest, "SET-GATE-ALARM\n0\n"); got != "OK" {
		t.Errorf("reply %q, want OK", got)
	}
	relayHolds(t, p, "1760000000000")
	relayHolds(t, ps, "15\tcom.android.deskclock")
	if l := relayLog(t, logPath); !strings.Contains(l, "relay-clear-held") {
		t.Errorf("gate.log lacks relay-clear-held: %q", l)
	}
}

func TestGateAlarmRelay_AGetNeverHandsBackARefusedValue(t *testing.T) {
	gateLogTestFile(t)
	gatePeer(t, 0)
	dest := t.TempDir()
	evictConn(t, dest, "SET-GATE-ALARM\nabc\n")
	if got := evictConn(t, dest, "GET-GATE-ALARM\n"); got != "0" {
		t.Errorf("GET-GATE-ALARM = %q, want 0", got)
	}
}
