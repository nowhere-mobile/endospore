package main

import (
	"net"
	"os"
	"strings"
	"testing"
)

// NWP-20261117-32: every BUSY that END-UNSAVED and RESTART-UNSAVED write names its cause in one token -- seal,
// teardown, rent or slot -- so the Profile screen never says "A save is running" for a refusal that is not a save.
// Each arm is driven here and its exact reply asserted; a source check holds both handlers to no bare BUSY.

// ebArm is one BUSY arm: arrange sets the cause (and returns its undo), want is the exact reply.
type ebArm struct {
	name    string
	want    string
	arrange func(t *testing.T, f *euFixture) func()
}

// ebSeal announces a seal the way syncLoop does: a periodic run kind, or a seal in flight.
func ebSeal(kind string, inFlight bool) func(*testing.T, *euFixture) func() {
	return func(t *testing.T, f *euFixture) func() {
		pendingReapMu.Lock()
		sealRunKind, sealInFlight = kind, inFlight
		pendingReapMu.Unlock()
		return func() {}
	}
}

// ebTeardownQueued queues a teardown of this session (endUnsavedBlocked's first arm).
func ebTeardownQueued(t *testing.T, f *euFixture) func() {
	pendingReapMu.Lock()
	pendingLockUID = euUID
	pendingReapMu.Unlock()
	return func() {}
}

// ebColdLock runs a cold lock (endUnsavedBlocked's last arm).
func ebColdLock(t *testing.T, f *euFixture) func() {
	coldLockMu.Lock()
	coldLockRunning = true
	coldLockMu.Unlock()
	return func() {}
}

// ebRent runs a rent payment, so holdRentForExit refuses.
func ebRent(t *testing.T, f *euFixture) func() {
	t.Cleanup(rgReset)
	if !beginRent() {
		t.Fatal("beginRent refused on an idle gate")
	}
	return endRent
}

// ebSlot holds the RW worker slot for the whole request.
func ebSlot(t *testing.T, f *euFixture) func() {
	laneRW.slot <- struct{}{}
	return func() { <-laneRW.slot }
}

// ebUnderSlot changes state from the wallet step, so the top checks pass and the re-check under the slot refuses.
func ebUnderSlot(set func(t *testing.T, f *euFixture) func()) func(*testing.T, *euFixture) func() {
	return func(t *testing.T, f *euFixture) func() {
		endUnsavedWallet = func(dest, name, pass string, se []byte, gen string) error {
			f.wallets++
			set(t, f)
			return nil
		}
		return func() {}
	}
}

func ebRestart(f *euFixture) string {
	return ropReply(f.t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) })
}

func TestEndUnsavedBusy_EveryArm(t *testing.T) {
	for _, a := range []ebArm{
		{"a periodic seal is queued", "BUSY seal", ebSeal("periodic", false)},
		{"a seal is in flight", "BUSY seal", ebSeal("", true)},
		{"a teardown is queued", "BUSY teardown", ebTeardownQueued},
		{"a cold lock is running", "BUSY teardown", ebColdLock},
		{"a rent payment is running", "BUSY rent", ebRent},
		{"the worker slot stays held", "BUSY slot", ebSlot},
		{"a teardown queued while the wallet saved", "BUSY teardown", ebUnderSlot(ebTeardownQueued)},
	} {
		t.Run(a.name, func(t *testing.T) {
			f := euSetup(t)
			f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
			undo := a.arrange(t, f)
			got := f.end()
			undo()
			if got != a.want {
				t.Fatalf("got %q, want %q", got, a.want)
			}
			f.untouched(a.name)
			if f.sweeps != 0 {
				t.Errorf("the media sweep ran %d time(s) for a refused request", f.sweeps)
			}
			if currentLogoffRefusal() == nil {
				t.Error("a BUSY answer consumed the refusal")
			}
		})
	}
}

func TestRestartUnsavedBusy_EveryArm(t *testing.T) {
	for _, a := range []ebArm{
		{"a periodic seal is queued", "BUSY seal", ebSeal("periodic", false)},
		{"a seal is in flight", "BUSY seal", ebSeal("", true)},
		{"a teardown is queued", "BUSY teardown", ebTeardownQueued},
		{"a cold lock is running", "BUSY teardown", ebColdLock},
		{"a rent payment is running", "BUSY rent", ebRent},
		{"the worker slot stays held", "BUSY slot", ebSlot},
		{"a seal announced while the wallet saved", "BUSY seal", ebUnderSlot(ebSeal("periodic", false))},
		{"a teardown queued while the wallet saved", "BUSY teardown", ebUnderSlot(ebTeardownQueued)},
	} {
		t.Run(a.name, func(t *testing.T) {
			f := euSetup(t)
			logoffSweepFailed(f.name, euUID)
			logoffSweepFailed(f.name, euUID)
			close(f.watch) // a mutant that lets the restart through must reach its reply, not wait on the watchdog
			undo := a.arrange(t, f)
			got := ebRestart(f)
			undo()
			if got != a.want {
				t.Fatalf("got %q, want %q", got, a.want)
			}
			if len(f.rebootList()) != 0 || isLocalSession(f.dest) {
				t.Errorf("reboots %v, local %v after %s", f.rebootList(), isLocalSession(f.dest), got)
			}
		})
	}
}

// The handlers' sources: no bare BUSY reply, no bare BUSY handed to restartRefused, and every token present.
func TestEndUnsavedBusy_Source(t *testing.T) {
	b, err := os.ReadFile("end_unsaved.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"handleEndUnsaved", "handleRestartUnsaved"} {
		body := strings.Join(stripComments(funcBody(t, string(b), name)), "\n")
		for _, bad := range []string{`"BUSY\n"`, `restartRefused(conn, uid, "BUSY",`} {
			if strings.Contains(body, bad) {
				t.Errorf("%s writes a bare BUSY (%s): the Profile screen cannot say why", name, bad)
			}
		}
		for _, tok := range []string{`"BUSY seal`, `"BUSY teardown`, `"BUSY rent`, `"BUSY slot`} {
			if !strings.Contains(body, tok) {
				t.Errorf("%s no longer writes %s", name, tok)
			}
		}
	}
}
