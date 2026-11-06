package main

import (
	"os"
	"testing"
	"time"
)

// A restarted login daemon has an empty NOWHERE_FIDO2_HMAC; only dest/.fido2hmac (RAM tmpfs) survives. The
// backlog row "handleColdLock downgrades a 2FA session to passphrase-only when the hmac stash is missing" named
// that as the trigger for a `nokey` marker. handleColdLock re-adopts the stash (loadFido2HmacEnv) before it
// chooses the cold credential, so the trigger does not downgrade. These tests pin the committed marker's key
// flag, which no test asserted (coldlock_wait_order_test.go only plants the stash and checks the forward rekey).

// clrCommit runs a cold lock that commits (nobody holds the RW slot) and returns the recorded worker calls.
func clrCommit(t *testing.T, dest string, rec *clwRecorder) []clwCall {
	t.Helper()
	clwLock(t, dest, 0)
	if !clwWaitFor(2*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the teardown never finished")
	}
	if !clwExists(dest, ".coldlock") {
		t.Fatal("the lock did not commit -- no marker to read")
	}
	return rec.snapshot()
}

func TestColdLockOfARestartedDaemonKeepsTheKeyRequirement(t *testing.T) {
	dest, rec, _ := clwSetup(t)
	clwFido2(t, dest)
	os.Unsetenv("NOWHERE_FIDO2_HMAC") // the restarted daemon: stash on disk, env empty
	calls := clrCommit(t, dest, rec)
	if len(calls) == 0 || calls[0].op != "rekey" {
		t.Fatalf("ops = %v, want the first op to be the forward rekey to the key-bound credential", rec.ops())
	}
	if calls[0].seSecret == calls[0].pass {
		t.Error("the rekey's new credential equals the unlock secret -- the keyguard was armed passphrase-only")
	}
	if _, _, _, needKey, _, _ := readColdLock(dest); !needKey {
		t.Error("the committed marker says nokey: a restarted daemon downgraded a key-enrolled session")
	}
}

func TestColdLockWithoutAStashIsPassphraseOnly(t *testing.T) {
	dest, rec, _ := clwSetup(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	calls := clrCommit(t, dest, rec)
	if len(calls) == 0 || calls[0].op != "armcred" {
		t.Fatalf("ops = %v, want the first op to be armcred", rec.ops())
	}
	if _, _, _, needKey, _, _ := readColdLock(dest); needKey {
		t.Error("the marker demands a key for a session that has none")
	}
}
