package main

import (
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261013-24: DELETE's BUSY guard was only the sessionMu TryLock, which a periodic seal never holds. The delete
// started mid-seal and the seal re-published the refs it had just tombstoned. DELETE now answers BUSY while any seal
// is running (anySealRunning), and the periodic loop starts no seal while a delete is in flight.

// deleteSealFixture installs a recording handleDelete, resets the announce state, and restores both on cleanup.
func deleteSealFixture(t *testing.T) *int {
	t.Helper()
	calls := new(int)
	oldFn := handleDeleteFn
	handleDeleteFn = func(conn net.Conn, dest, name, pass string, peer int) {
		*calls++
		pendingReapMu.Lock()
		held := deleteInFlight
		pendingReapMu.Unlock()
		if !held {
			t.Error("handleDelete ran without deleteInFlight set: the periodic loop would not be held off")
		}
		_, _ = conn.Write([]byte("OK\n"))
	}
	reset := func() {
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealRunAt, deleteInFlight = false, "", time.Time{}, false
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(func() { handleDeleteFn = oldFn; reset() })
	return calls
}

const deleteReq = "DELETE\nalice\npw-alice\n"

func TestDeleteAnswersBusyDuringAnnouncedPeriodicSeal(t *testing.T) {
	calls := deleteSealFixture(t)
	setSealRun("periodic")
	if got := driveLogin(t, t.TempDir(), deleteReq); got != "BUSY" {
		t.Fatalf("DELETE during an announced periodic seal replied %q, want BUSY", got)
	}
	if *calls != 0 {
		t.Fatal("handleDelete ran during an announced periodic seal")
	}
	if deleteInFlight {
		t.Fatal("a refused DELETE left deleteInFlight set")
	}
	clearSealRun()
	if got := driveLogin(t, t.TempDir(), deleteReq); got != "OK" || *calls != 1 {
		t.Fatalf("control: DELETE with no seal replied %q after %d calls, want OK after 1", got, *calls)
	}
	if deleteInFlight {
		t.Fatal("deleteInFlight stayed set after the delete returned")
	}
}

func TestDeleteAnswersBusyDuringSealInFlight(t *testing.T) {
	calls := deleteSealFixture(t)
	pendingReapMu.Lock()
	sealInFlight = true
	pendingReapMu.Unlock()
	if got := driveLogin(t, t.TempDir(), deleteReq); got != "BUSY" || *calls != 0 {
		t.Fatalf("DELETE during a manual/logoff seal replied %q (%d calls), want BUSY (0)", got, *calls)
	}
}

func TestDeleteIgnoresAnExpiredAnnounce(t *testing.T) {
	calls := deleteSealFixture(t)
	pendingReapMu.Lock()
	sealRunKind, sealRunAt = "periodic", time.Now().Add(-sealRunExpiry-time.Minute)
	pendingReapMu.Unlock()
	if got := driveLogin(t, t.TempDir(), deleteReq); got != "OK" || *calls != 1 {
		t.Fatalf("DELETE past the announce expiry replied %q (%d calls), want OK (1)", got, *calls)
	}
}

func TestPeriodicLoopDefersWhileDeleteInFlight(t *testing.T) {
	deleteSealFixture(t)
	pendingReapMu.Lock()
	clear := deleteDeferLocked("")
	held := deleteDeferLocked("login")
	deleteInFlight = true
	got := deleteDeferLocked("")
	kept := deleteDeferLocked("login")
	pendingReapMu.Unlock()
	if clear != "" || held != "login" || kept != "login" {
		t.Fatalf("without a delete the reason must pass through; got %q, %q, %q", clear, held, kept)
	}
	if got != "delete-in-flight" {
		t.Fatalf("defer reason with a delete in flight = %q, want delete-in-flight", got)
	}
	if announcePeriodicSeal() {
		t.Fatal("announcePeriodicSeal announced during a delete")
	}
	if k := func() string { pendingReapMu.Lock(); defer pendingReapMu.Unlock(); return sealRunKind }(); k != "" {
		t.Fatalf("a refused announce left sealRunKind=%q", k)
	}
	endDelete()
	if !announcePeriodicSeal() {
		t.Fatal("announcePeriodicSeal refused with no delete in flight")
	}
}

func TestAnySealRunningMatchesTheBackupGuard(t *testing.T) {
	deleteSealFixture(t)
	now := time.Now()
	set := func(inFl bool, kind string, at time.Time) {
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealRunAt = inFl, kind, at
		pendingReapMu.Unlock()
	}
	for _, c := range []struct {
		name string
		inFl bool
		kind string
		at   time.Time
		want bool
	}{
		{"idle", false, "", time.Time{}, false},
		{"fresh periodic", false, "periodic", now, true},
		{"zero-stamp announce", false, "periodic", time.Time{}, true},
		{"expired announce", false, "periodic", now.Add(-sealRunExpiry - time.Second), false},
		{"sealInFlight", true, "", time.Time{}, true},
	} {
		set(c.inFl, c.kind, c.at)
		if got := anySealRunning(now); got != c.want {
			t.Errorf("%s: anySealRunning = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestSyncLoopUsesTheDeleteAwareGuards pins syncLoop's two call sites as source: the loop itself sleeps for an
// interval and reads a live session, so it cannot be driven here.
func TestSyncLoopUsesTheDeleteAwareGuards(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{"reason = deleteDeferLocked(reason)", "if !announcePeriodicSeal() {"} {
		if !strings.Contains(src, want) {
			t.Errorf("syncLoop no longer contains %q", want)
		}
	}
	if strings.Contains(src, "setSealRun(\"periodic\")\n\t\tout := triggerRoamWorkerKind") {
		t.Error("syncLoop announces the periodic seal without the delete check")
	}
}
