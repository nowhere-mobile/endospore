package main

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// "Back up now" during the background re-key (NWP-20261027-17). The re-key sets nothing backupBusyReason reads and
// only TRIES the worker slot, so a backup tapped during a batch is accepted and the re-key yields after the batch
// already running. These pin that; they pass on main.

// rekeyFixture is tieFixture + tiedWithMedia under its OWN profile name and uid (tieFixture hardcodes one name and
// uid 12), so no two tests share a vault key, a blob cache entry or the re-key job's per-uid state. It also restores
// the re-key job's state when the test ends.
func rekeyFixture(t *testing.T, name, uid string) (dest, pass string) {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	pass = "horse battery staple correct"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	dest = t.TempDir()
	if err := markRoamSession(dest, name, pass, uid, hex.EncodeToString(seA)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, rekeyArmedFile), []byte(uid+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	sealMediaInSession(t, name, pass, "photos v1")
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	old := rekeyBatchBytes
	rekeyBatchBytes = 1
	rekeyStateMu.Lock()
	oldState, oldUID, oldErr := rekeyState, rekeyStateUID, rekeyLastErr
	rekeyState, rekeyStateUID, rekeyLastErr = map[string]rekeyStep{}, "", nil
	rekeyStateMu.Unlock()
	t.Cleanup(func() {
		rekeyBatchBytes = old
		rekeyStateMu.Lock()
		rekeyState, rekeyStateUID, rekeyLastErr = oldState, oldUID, oldErr
		rekeyStateMu.Unlock()
	})
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	return dest, pass
}

// busyNow is backupBusyReason over the live inputs, read under the lock that guards them.
func busyNow() string {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return backupBusyReason(time.Now(), sealInFlight, loginSettleUntil, userOpWaiting.Load(), sealRunKind, sealRunAt)
}

// clearBusyInputs zeroes every input backupBusyReason reads and restores them when the test ends, so a test sees only
// what it sets itself, whatever an earlier test left behind.
func clearBusyInputs(t *testing.T) {
	t.Helper()
	pendingReapMu.Lock()
	oldIn, oldKind, oldAt, oldWin := sealInFlight, sealRunKind, sealRunAt, loginSettleUntil
	sealInFlight, sealRunKind, sealRunAt, loginSettleUntil = false, "", time.Time{}, time.Time{}
	pendingReapMu.Unlock()
	oldWait := userOpWaiting.Swap(0)
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealRunAt, loginSettleUntil = oldIn, oldKind, oldAt, oldWin
		pendingReapMu.Unlock()
		userOpWaiting.Store(oldWait)
	})
}

func TestRekeyOnceStandsDownWhileAManualBackupHoldsTheSealChannel(t *testing.T) {
	name := "rekeybk-standdown"
	dest, pass := rekeyFixture(t, name, "31")
	clearBusyInputs(t)
	pendingReapMu.Lock()
	sealInFlight, sealRunKind, sealRunAt = true, "manual", time.Now()
	pendingReapMu.Unlock()
	rekeyOnce(dest)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress != "" {
		t.Fatal("a re-key batch started while a manual backup was in flight")
	}
	pendingReapMu.Lock()
	sealInFlight, sealRunKind, sealRunAt = false, "", time.Time{}
	pendingReapMu.Unlock()
	rekeyOnce(dest)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress == "" {
		t.Fatal("precondition: no batch ran once the backup was gone")
	}
}

func TestARekeyBatchLeavesNoReasonForBackupToRefuse(t *testing.T) {
	name := "rekeybk-batch"
	dest, pass := rekeyFixture(t, name, "32")
	clearBusyInputs(t)
	rekeyOnce(dest)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress == "" {
		t.Fatal("precondition: no batch ran")
	}
	if why := busyNow(); why != "" {
		t.Errorf("after a re-key batch, Back up now would answer BUSY %s", why)
	}
	select {
	case laneRW.slot <- struct{}{}:
		<-laneRW.slot
	default:
		t.Error("the re-key batch left the worker slot held")
	}
}

func TestHoldingTheWorkerSlotIsNotABusyReason(t *testing.T) {
	clearBusyInputs(t)
	laneRW.slot <- struct{}{} // as a batch does
	held := true
	release := func() {
		if held {
			held = false
			<-laneRW.slot
		}
	}
	t.Cleanup(release)
	if why := busyNow(); why != "" {
		t.Errorf("a held worker slot alone made Back up now answer BUSY %s", why)
	}
	userOpWaiting.Add(1) // as a queued odrestore does
	t.Cleanup(func() { userOpWaiting.Add(-1) })
	if why := busyNow(); why != "user-op-waiting" {
		t.Errorf("a user op queued behind the held slot: BUSY reason %q, want user-op-waiting", why)
	}
}

func TestRekeyOnceDoesNotWaitForAHeldSlot(t *testing.T) {
	name := "rekeybk-nowait"
	dest, pass := rekeyFixture(t, name, "33")
	clearBusyInputs(t)
	laneRW.slot <- struct{}{}
	held := true
	release := func() {
		if held {
			held = false
			<-laneRW.slot
		}
	}
	t.Cleanup(release)
	done := make(chan struct{})
	go func() { rekeyOnce(dest); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("rekeyOnce waited for a held worker slot instead of trying it")
	}
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress != "" {
		t.Fatal("a re-key batch ran without the worker slot")
	}
}
