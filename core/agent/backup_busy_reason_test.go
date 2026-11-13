package main

import (
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261015-36: a refused "Back up now" leaves one login.log line naming its cause.

// NWP-20261015-36: a refused "Back up now" leaves one login.log line naming its cause.
func TestBackupBusyReason(t *testing.T) {
	now := time.Now()
	live, old := now.Add(-time.Minute), now.Add(-sealRunExpiry-time.Minute)
	cases := []struct {
		name     string
		sealBusy bool
		login    time.Time
		waiting  int32
		kind     string
		at       time.Time
		want     string
	}{
		{"seal in flight", true, time.Time{}, 0, "", time.Time{}, "seal-in-flight"},
		{"login window", false, now.Add(time.Minute), 0, "", time.Time{}, "login"},
		{"user op waiting", false, time.Time{}, 1, "", time.Time{}, "user-op-waiting"},
		{"live periodic", false, time.Time{}, 0, "periodic", live, "seal-run:periodic"},
		{"live logoff", false, time.Time{}, 0, "logoff", live, "seal-run:logoff"},
		{"live manual", false, time.Time{}, 0, "manual", live, "seal-run:manual"},
		{"unstamped run is live", false, time.Time{}, 0, "periodic", time.Time{}, "seal-run:periodic"},
		{"expired periodic", false, time.Time{}, 0, "periodic", old, ""},
		{"expired logoff", false, time.Time{}, 0, "logoff", old, ""},
		{"expired manual", false, time.Time{}, 0, "manual", old, ""},
		{"nothing", false, time.Time{}, 0, "", time.Time{}, ""},
		{"seal in flight beats a run", true, now.Add(time.Minute), 1, "periodic", live, "seal-in-flight"},
		{"login beats a run", false, now.Add(time.Minute), 1, "periodic", live, "login"},
		{"user op beats a run", false, time.Time{}, 1, "periodic", live, "user-op-waiting"},
	}
	for _, c := range cases {
		if got := backupBusyReason(now, c.sealBusy, c.login, c.waiting, c.kind, c.at); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestHandleBackupLogsItsRefusal(t *testing.T) {
	_, _, _ = ropStore(t)
	ropReapReset(t)
	save := func() func() {
		pendingReapMu.Lock()
		k, a, f := sealRunKind, sealRunAt, sealInFlight
		pendingReapMu.Unlock()
		return func() {
			pendingReapMu.Lock()
			sealRunKind, sealRunAt, sealInFlight = k, a, f
			pendingReapMu.Unlock()
		}
	}()
	t.Cleanup(save)

	dest := t.TempDir()
	if err := markRoamSession(dest, ropName, ropPass, "12", ""); err != nil {
		t.Fatal(err)
	}

	pendingReapMu.Lock()
	sealRunKind, sealRunAt, sealInFlight = "periodic", time.Now(), false
	pendingReapMu.Unlock()
	var got string
	logged := captureStderr(t, func() {
		got = ropReply(t, func(c net.Conn) { handleBackup(c, dest) })
	})
	if got != "BUSY seal-run:periodic" {
		t.Fatalf("reply %q, want exactly BUSY seal-run:periodic", got)
	}
	if !strings.Contains(logged, "manual backup joined the running save: seal-run:periodic, follow-up not needed") {
		t.Errorf("the join left no cause in the log; stderr was %q", logged)
	}
	if strings.Contains(logged, "refused BUSY") {
		t.Errorf("a tap during a running save was logged as refused; stderr was %q", logged)
	}

	t.Run("a sign-in in progress is still refused", func(t *testing.T) {
		pendingReapMu.Lock()
		oldLogin := loginSettleUntil
		sealRunKind, sealRunAt, sealInFlight = "", time.Time{}, false
		loginSettleUntil = time.Now().Add(time.Minute)
		pendingReapMu.Unlock()
		t.Cleanup(func() {
			pendingReapMu.Lock()
			loginSettleUntil = oldLogin
			pendingReapMu.Unlock()
		})
		var got string
		logged := captureStderr(t, func() {
			got = ropReply(t, func(c net.Conn) { handleBackup(c, dest) })
		})
		if got != "BUSY login" {
			t.Fatalf("reply %q, want exactly BUSY login", got)
		}
		if !strings.Contains(logged, "manual backup refused BUSY: login") || strings.Contains(logged, "joined") {
			t.Errorf("a sign-in is a refusal, not a join; stderr was %q", logged)
		}
	})

	t.Run("nothing running is not refused", func(t *testing.T) {
		pendingReapMu.Lock()
		sealRunKind, sealRunAt, sealInFlight = "", time.Time{}, false
		pendingReapMu.Unlock()
		stop := ropWorker(t, dest)
		var got string
		logged := captureStderr(t, func() {
			got = ropReply(t, func(c net.Conn) { handleBackup(c, dest) })
		})
		if strings.HasPrefix(got, "BUSY") || strings.Contains(logged, "refused BUSY") {
			t.Errorf("an idle daemon refused: reply %q, stderr %q", got, logged)
		}
		for i := 0; i < 300; i++ { // let the manual seal goroutine finish before globals are restored
			pendingReapMu.Lock()
			f := sealInFlight
			pendingReapMu.Unlock()
			if !f {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		stop()
	})
}
