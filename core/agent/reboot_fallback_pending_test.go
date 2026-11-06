package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261017-07 -- the daemon's reboot fallbacks retry once (or hold, bounded) while telephony records are pending,
// and a reboot that still happens with records pending logs how many it cost. The reboot is stubbed through
// rebootHook; the waits through the package vars. A case that consumes the queue (or clears the records) during a wait
// does it from reapWaitHook at a named wait, never from a timer, so load cannot move it past the re-check that follows
// the wait (NWP-20261112-19); it also asserts the exact sequence of waits it saw. Every case plants a profile name and a ref in the fixture and
// asserts that no log line this change writes carries either. A case asserts the waits it saw and lower bounds on wall
// time only, never an upper bound, which one throttled CPU-quota period (up to 100 ms) exceeds (NWP-20261115-09).

const (
	rfpName = "Planted Profile Name"
	rfpRef  = "0123456789abcdef0123456789abcdef"
	rfpWait = 40 * time.Millisecond
	rfpHang = 10 * time.Second // a hang guard for rfpWithin, never a bound on how long a fallback may take
)

type rfpEnv struct {
	t       *testing.T
	root    string
	mu      sync.Mutex
	reasons []string
	phases  []string          // every wait reapWaitHook saw, in order; guarded by mu
	actions map[string]func() // one-shot actions, keyed by the wait they run at; guarded by mu
	logf    *os.File
}

func newRfpEnv(t *testing.T) *rfpEnv {
	t.Helper()
	e := &rfpEnv{t: t, root: t.TempDir(), actions: map[string]func(){}}
	oldInbox, oldOwner, oldIngest := telInboxBase, ownerInboxBase, telIngestBase
	telInboxBase = filepath.Join(e.root, "inbox")
	ownerInboxBase = filepath.Join(e.root, "owner")
	telIngestBase = e.root
	oldW := [5]time.Duration{reapSwitchWait, reapRemoveWait, deleteNoUidWait, deleteNoUidHoldStep, deleteNoUidHoldCap}
	reapSwitchWait, reapRemoveWait, deleteNoUidWait, deleteNoUidHoldStep, deleteNoUidHoldCap = rfpWait, rfpWait, rfpWait, rfpWait, 5*rfpWait
	rebootHook = func(reason string) bool {
		e.mu.Lock()
		e.reasons = append(e.reasons, reason)
		e.mu.Unlock()
		return true
	}
	oldHook := reapWaitHook
	reapWaitHook = func(phase string) {
		e.mu.Lock()
		e.phases = append(e.phases, phase)
		act := e.actions[phase]
		delete(e.actions, phase)
		e.mu.Unlock()
		if act != nil {
			act()
		}
	}
	f, err := os.Create(filepath.Join(t.TempDir(), "stderr"))
	if err != nil {
		t.Fatal(err)
	}
	e.logf = f
	oldErr := os.Stderr
	os.Stderr = f
	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID = "", ""
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		os.Stderr = oldErr
		f.Close()
		rebootHook = nil
		reapWaitHook = oldHook
		telInboxBase, ownerInboxBase, telIngestBase = oldInbox, oldOwner, oldIngest
		reapSwitchWait, reapRemoveWait, deleteNoUidWait, deleteNoUidHoldStep, deleteNoUidHoldCap = oldW[0], oldW[1], oldW[2], oldW[3], oldW[4]
		pendingReapMu.Lock()
		pendingSwitchUID, pendingReapUID = "", ""
		pendingReapMu.Unlock()
	})
	return e
}

func (e *rfpEnv) plantSealed() {
	e.t.Helper()
	dir := filepath.Join(telInboxBase, rfpRef)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "0123456789abcdef.fedcba9876543210.seal"), []byte("sealed "+rfpName), 0o600); err != nil {
		e.t.Fatal(err)
	}
}

func (e *rfpEnv) queue(switchUID, reapUID string) {
	pendingReapMu.Lock()
	pendingSwitchUID, pendingReapUID = switchUID, reapUID
	pendingReapMu.Unlock()
}

// on registers fn to run once, at the start of the first wait named phase (before its sleep, so before its re-check).
func (e *rfpEnv) on(phase string, fn func()) {
	e.mu.Lock()
	e.actions[phase] = fn
	e.mu.Unlock()
}

// wantPhases fails unless the waits reapWaitHook saw are exactly want, in order.
func (e *rfpEnv) wantPhases(want ...string) {
	e.t.Helper()
	e.mu.Lock()
	got := append([]string(nil), e.phases...)
	e.mu.Unlock()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		e.t.Errorf("waits = %q, want %q", got, want)
	}
}

// consumeSwitch and consumeReap retire one queue slot each, as ACK-REAP SWITCH and REAP do.
func (e *rfpEnv) consumeSwitch() {
	pendingReapMu.Lock()
	pendingSwitchUID = ""
	pendingReapMu.Unlock()
}

func (e *rfpEnv) consumeReap() {
	pendingReapMu.Lock()
	pendingReapUID = ""
	pendingReapMu.Unlock()
}

func (e *rfpEnv) rebooted() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]string(nil), e.reasons...)
}

func (e *rfpEnv) log() string {
	b, _ := os.ReadFile(e.logf.Name())
	s := string(b)
	for _, bad := range []string{rfpName, rfpRef, "0123456789abcdef.fedcba9876543210"} {
		if strings.Contains(s, bad) {
			e.t.Errorf("a log line carries %q:\n%s", bad, s)
		}
	}
	return s
}

// rfpWithin runs fn and fails the test if it has not returned by d.
func rfpWithin(t *testing.T, d time.Duration, fn func()) time.Duration {
	t.Helper()
	start := time.Now()
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("did not return within %v", d)
	}
	return time.Since(start)
}

func TestRebootFallback_NothingPending_RebootsAfterOneWindow(t *testing.T) {
	e := newRfpEnv(t)
	e.queue("7", "7")
	rfpWithin(t, rfpHang, func() { reapOrReboot("7") })
	if got := e.rebooted(); len(got) != 1 || !strings.Contains(got[0], "logoff switch NOT consumed") {
		t.Fatalf("reboots = %q", got)
	}
	// Nothing pending: it reboots after the switch window alone, with no re-queue window.
	e.wantPhases("switch")
	if strings.Contains(e.log(), "re-queued") || strings.Contains(e.log(), "will be lost") {
		t.Errorf("nothing pending, yet the log speaks of a re-queue or a loss:\n%s", e.log())
	}
}

func TestRebootFallback_Phase1_ConsumedDuringRequeue_NoReboot(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	e.queue("7", "7")
	e.on("switch-requeue", func() { e.queue("", "") })
	rfpWithin(t, rfpHang, func() { reapOrReboot("7") })
	if got := e.rebooted(); len(got) != 0 {
		t.Fatalf("rebooted %q although the watcher consumed the switch in the re-queue window", got)
	}
	if !strings.Contains(e.log(), "switch not consumed in 0s with 1 telephony record(s) pending -> re-queued once before the reboot fallback") {
		t.Errorf("no re-queue line:\n%s", e.log())
	}
	// Consumed in the re-queue, so phase 2 runs its window and finds the reap slot clear.
	e.wantPhases("switch", "switch-requeue", "remove")
}

func TestRebootFallback_Phase1_StillStuck_RebootsAndLogsCount(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	e.queue("7", "7")
	took := rfpWithin(t, rfpHang, func() { reapOrReboot("7") })
	if got := e.rebooted(); len(got) != 1 {
		t.Fatalf("reboots = %q", got)
	}
	if took < 2*rfpWait {
		t.Errorf("rebooted after %v: the re-queue window was skipped", took)
	}
	l := e.log()
	if !strings.Contains(l, "re-queued once before the reboot fallback") || !strings.Contains(l, "1 pending telephony record(s) will be lost") {
		t.Errorf("log lacks the re-queue or the cost:\n%s", l)
	}
}

func TestRebootFallback_Phase2_NothingPending(t *testing.T) {
	e := newRfpEnv(t)
	e.queue("", "7")
	rfpWithin(t, rfpHang, func() { reapOrReboot("7") })
	if got := e.rebooted(); len(got) != 1 || !strings.Contains(got[0], "logoff remove NOT consumed") {
		t.Fatalf("reboots = %q", got)
	}
	// Nothing pending: phase 2 reboots after its one window, with no re-queue window.
	e.wantPhases("switch", "remove")
}

func TestRebootFallback_Phase2_ConsumedDuringRequeue_NoReboot(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	e.queue("", "7")
	e.on("remove-requeue", func() { e.queue("", "") })
	rfpWithin(t, rfpHang, func() { reapOrReboot("7") })
	if got := e.rebooted(); len(got) != 0 {
		t.Fatalf("rebooted %q although the remove was consumed in the re-queue window", got)
	}
	if !strings.Contains(e.log(), "remove not consumed in 0s with 1 telephony record(s) pending -> re-queued once") {
		t.Errorf("no re-queue line:\n%s", e.log())
	}
	e.wantPhases("switch", "remove", "remove-requeue")
}

func TestRebootFallback_Phase2_StillStuck_RebootsAndLogsCount(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	e.queue("", "7")
	took := rfpWithin(t, rfpHang, func() { reapOrReboot("7") })
	if got := e.rebooted(); len(got) != 1 || !strings.Contains(got[0], "logoff remove NOT consumed") {
		t.Fatalf("reboots = %q", got)
	}
	if took < 3*rfpWait {
		t.Errorf("rebooted after %v: phase 2's re-queue window was skipped", took)
	}
	if !strings.Contains(e.log(), "1 pending telephony record(s) will be lost") {
		t.Errorf("no cost line:\n%s", e.log())
	}
}

func TestRebootFallback_DeleteSwitch_RequeuesOnce(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	e.queue("7", "7")
	e.on("switch-requeue", func() { e.queue("", "") })
	rfpWithin(t, rfpHang, func() { deleteReapFallback("7") })
	if got := e.rebooted(); len(got) != 0 {
		t.Fatalf("rebooted %q although the switch was consumed in the re-queue window", got)
	}
	e.wantPhases("switch", "switch-requeue", "remove")
	e.queue("7", "7")
	took := rfpWithin(t, rfpHang, func() { deleteReapFallback("7") })
	if got := e.rebooted(); len(got) != 1 || !strings.Contains(got[0], "delete reap NOT consumed") || took < 2*rfpWait {
		t.Fatalf("reboots = %q after %v", got, took)
	}
	e.wantPhases("switch", "switch-requeue", "remove", "switch", "switch-requeue")
	if !strings.Contains(e.log(), "1 pending telephony record(s) will be lost") {
		t.Errorf("no cost line:\n%s", e.log())
	}
}

func TestRebootFallback_DeleteSwitch_NothingPending_Immediate(t *testing.T) {
	e := newRfpEnv(t)
	e.queue("7", "7")
	rfpWithin(t, rfpHang, func() { deleteReapFallback("7") })
	if got := e.rebooted(); len(got) != 1 {
		t.Fatalf("reboots = %q, want one", got)
	}
	// Nothing pending: it reboots after the switch window alone, with no re-queue window.
	e.wantPhases("switch")
}

func (e *rfpEnv) reapSlot() string {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return pendingReapUID
}

// dn-1104 #6 (NWP-20261107-06): once the gate has taken a delete's switch, the fallback also waits for the removal.
func TestRebootFallback_DeleteRemove_ConsumedNoReboot(t *testing.T) {
	e := newRfpEnv(t)
	e.queue("7", "7")
	e.on("switch", e.consumeSwitch)
	e.on("remove", e.consumeReap)
	rfpWithin(t, rfpHang, func() { deleteReapFallback("7") })
	if got := e.rebooted(); len(got) != 0 {
		t.Fatalf("rebooted %q although the switch and the removal were both consumed", got)
	}
	l := e.log()
	if !strings.Contains(l, "delete fallback check uid=7: switch consumed=true remove consumed=true") || strings.Contains(l, "re-queued") {
		t.Errorf("log:\n%s", l)
	}
	e.wantPhases("switch", "remove")
}

func TestRebootFallback_DeleteRemove_StillStuck_Reboots(t *testing.T) {
	e := newRfpEnv(t)
	e.queue("7", "7")
	e.on("switch", e.consumeSwitch)
	took := rfpWithin(t, rfpHang, func() { deleteReapFallback("7") })
	got := e.rebooted()
	if len(got) != 1 || got[0] != "delete remove NOT consumed 12s after switch uid=7" {
		t.Fatalf("reboots = %q", got)
	}
	if took < 2*rfpWait {
		t.Errorf("rebooted after %v: want at least the switch window plus one remove window (%v each)", took, rfpWait)
	}
	if !strings.Contains(e.log(), "switch consumed=true remove consumed=false") {
		t.Errorf("log lacks both outcomes:\n%s", e.log())
	}
	if s := e.reapSlot(); s != "" {
		t.Errorf("reap slot still %q after the reboot", s)
	}
	e.wantPhases("switch", "remove")
}

func TestRebootFallback_DeleteRemove_RequeuesOnce(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	e.queue("7", "7")
	e.on("switch", e.consumeSwitch)
	e.on("remove-requeue", e.consumeReap)
	rfpWithin(t, rfpHang, func() { deleteReapFallback("7") })
	if got := e.rebooted(); len(got) != 0 {
		t.Fatalf("rebooted %q although the removal was consumed in the re-queue window", got)
	}
	if !strings.Contains(e.log(), "remove not consumed in 0s with 1 telephony record(s) pending -> re-queued once") {
		t.Errorf("no re-queue line:\n%s", e.log())
	}
	e.wantPhases("switch", "remove", "remove-requeue")
	e.queue("7", "7")
	e.on("switch", e.consumeSwitch)
	took := rfpWithin(t, rfpHang, func() { deleteReapFallback("7") })
	got := e.rebooted()
	if len(got) != 1 || !strings.Contains(got[0], "delete remove NOT consumed") || took < 3*rfpWait {
		t.Fatalf("reboots = %q after %v", got, took)
	}
	e.wantPhases("switch", "remove", "remove-requeue", "switch", "remove", "remove-requeue")
	if !strings.Contains(e.log(), "1 pending telephony record(s) will be lost") {
		t.Errorf("no cost line:\n%s", e.log())
	}
}

func TestRebootFallback_NoUid_HoldsToTheCapThenReboots(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	took := rfpWithin(t, rfpHang, deleteNoUidReboot)
	if got := e.rebooted(); len(got) != 1 || got[0] != "delete with no session uid" {
		t.Fatalf("reboots = %q", got)
	}
	if took < deleteNoUidWait+deleteNoUidHoldCap {
		t.Errorf("held only %v, want at least %v", took, deleteNoUidWait+deleteNoUidHoldCap)
	}
	if !strings.Contains(e.log(), "holding the reboot") || !strings.Contains(e.log(), "1 pending telephony record(s) will be lost") {
		t.Errorf("log lacks the hold or the cost:\n%s", e.log())
	}
}

func TestRebootFallback_NoUid_ReleasedWhenRecordsClear(t *testing.T) {
	e := newRfpEnv(t)
	e.plantSealed()
	e.on("nouid-hold", func() { os.RemoveAll(telInboxBase) })
	rfpWithin(t, rfpHang, deleteNoUidReboot)
	if got := e.rebooted(); len(got) != 1 {
		t.Fatalf("reboots = %q, want one after the hold ends", got)
	}
	// The hold ends at its first step once nothing is pending.
	e.wantPhases("nouid-grace", "nouid-hold")
}

func TestRebootFallback_NoUid_NothingPending_ThreeSecondsAsToday(t *testing.T) {
	e := newRfpEnv(t)
	rfpWithin(t, rfpHang, deleteNoUidReboot)
	if got := e.rebooted(); len(got) != 1 {
		t.Fatalf("reboots = %q, want one", got)
	}
	// Nothing pending: it reboots after the grace window alone, with no hold.
	e.wantPhases("nouid-grace")
	if strings.Contains(e.log(), "holding") {
		t.Errorf("held with nothing pending:\n%s", e.log())
	}
}

func TestRebootFallback_CountError_IsPending(t *testing.T) {
	e := newRfpEnv(t)
	if err := os.WriteFile(telInboxBase, []byte("x"), 0o600); err != nil { // a FILE where the dir should be: ENOTDIR
		t.Fatal(err)
	}
	e.queue("7", "7")
	took := rfpWithin(t, rfpHang, func() { reapOrReboot("7") })
	if got := e.rebooted(); len(got) != 1 || took < 2*rfpWait {
		t.Fatalf("reboots = %q after %v: an unreadable count must be treated as pending", got, took)
	}
	if !strings.Contains(e.log(), "an unknown number of pending telephony record(s) will be lost") {
		t.Errorf("no unknown-count line:\n%s", e.log())
	}
}

func TestTelPendingCount(t *testing.T) {
	e := newRfpEnv(t)
	if n, err := telPendingCount(); n != 0 || err != nil {
		t.Fatalf("missing bases: n=%d err=%v, want 0 nil", n, err)
	}
	dir := filepath.Join(telInboxBase, rfpRef)
	os.MkdirAll(dir, 0o700)
	os.MkdirAll(ownerInboxBase, 0o700)
	w := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	w(filepath.Join(dir, "0123456789abcdef.fedcba9876543210.seal"), "a")
	w(filepath.Join(dir, "0123456789abcdef.fedcba9876543211.7.0123456789abcdef.pend"), "b")
	w(filepath.Join(dir, ".tmp-leftover"), "c") // not a record
	w(filepath.Join(ownerInboxBase, "0123456789abcdef.seal"), "d")
	w(filepath.Join(ownerInboxBase, ".hidden"), "e") // not a record
	w(filepath.Join(e.root, "telingest.7"), "sms 1 x\nsms 2 y\n")
	w(filepath.Join(e.root, "telingest.7.tmp"), "sms 1 x\n") // not a mailbox
	n, err := telPendingCount()
	if err != nil || n != 5 {
		t.Fatalf("n=%d err=%v, want 5 nil (2 blobs, 1 owner item, 2 rows)", n, err)
	}
	// an unreadable dir is an error, not zero
	os.RemoveAll(telInboxBase)
	w(telInboxBase, "x")
	if _, err := telPendingCount(); err == nil {
		t.Error("an unreadable inbox base counted as zero with no error")
	}
	os.Remove(telInboxBase)
	os.RemoveAll(ownerInboxBase)
	w(ownerInboxBase, "x")
	if _, err := telPendingCount(); err == nil {
		t.Error("an unreadable owner base counted as zero with no error")
	}
	os.Remove(ownerInboxBase)
	telIngestBase = filepath.Join(e.root, "telingest.7") // a file, so ReadDir fails with ENOTDIR
	if _, err := telPendingCount(); err == nil {
		t.Error("an unreadable ingest base counted as zero with no error")
	}
	telIngestBase = filepath.Join(e.root, "absent")
	if n, err := telPendingCount(); n != 0 || err != nil {
		t.Errorf("missing ingest base: n=%d err=%v, want 0 nil", n, err)
	}
}

// NWP-20261026-28: a record handed to a session sits in its mailbox AND as a .pend copy; it is one record.
func rfpPairWrite(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

func rfpPend(e *rfpEnv, uid, key string) string {
	return filepath.Join(telInboxBase, rfpRef, "0123456789abcdef.fedcba9876543210."+uid+"."+rowKeyHash(uid, key)+".pend")
}

func TestTelPendingCount_PairCountsOnce(t *testing.T) {
	e := newRfpEnv(t)
	rfpPairWrite(t, filepath.Join(e.root, "telingest.7.0123456789abcdef"), "sms 1700000000000 x\n")
	rfpPairWrite(t, rfpPend(e, "7", "sms 1700000000000"), "p")
	if n, err := telPendingCount(); err != nil || n != 1 {
		t.Fatalf("n=%d err=%v, want 1 nil (a row and its pending copy are one record)", n, err)
	}
}

func TestTelPendingCount_PairPlusUnpairedAndClaimed(t *testing.T) {
	e := newRfpEnv(t)
	rfpPairWrite(t, filepath.Join(e.root, "telingest.7.0123456789abcdef"), "sms 1700000000000 x\nsms 1700000000001 y\n")
	rfpPairWrite(t, rfpPend(e, "7", "sms 1700000000000"), "p")
	rfpPairWrite(t, rfpPend(e, "8", "sms 1700000000009"), "q") // claimed, not acknowledged: in no mailbox
	if n, err := telPendingCount(); err != nil || n != 3 {
		t.Fatalf("n=%d err=%v, want 3 nil (pair, unpaired row, claimed copy)", n, err)
	}
}

func TestTelPendingCount_SameKeyOtherSessionCountsBoth(t *testing.T) {
	e := newRfpEnv(t)
	rfpPairWrite(t, filepath.Join(e.root, "telingest.7"), "sms 1700000000000 x\n")
	rfpPairWrite(t, rfpPend(e, "8", "sms 1700000000000"), "p")
	if n, err := telPendingCount(); err != nil || n != 2 {
		t.Fatalf("n=%d err=%v, want 2 nil (the copy is session 8's, the row session 7's)", n, err)
	}
}

func TestTelPendingCount_ShortAndPartialRows(t *testing.T) {
	e := newRfpEnv(t)
	rfpPairWrite(t, filepath.Join(e.root, "telingest.7"), "lonely\n")
	if n, err := telPendingCount(); err != nil || n != 1 {
		t.Fatalf("one-field row: n=%d err=%v, want 1 nil", n, err)
	}
	rfpPairWrite(t, filepath.Join(e.root, "telingest.7"), "sms 1700000000000 x")
	if n, err := telPendingCount(); err != nil || n != 0 {
		t.Fatalf("no trailing newline: n=%d err=%v, want 0 nil", n, err)
	}
}
