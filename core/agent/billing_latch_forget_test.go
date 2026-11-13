package main

import (
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// h60 #18 (NWP-20261201-37): the login daemon forgets its two billing latches at every session end, after the sign-out
// renewal. The seeded keys have the shape of profileRefV2's output and derive from nothing.

var (
	billingLatchKeyA = strings.Repeat("a", 64)
	billingLatchKeyB = strings.Repeat("b", 64)
)

// billingLatchReset empties both latches for the test and restores them after.
func billingLatchReset(t *testing.T) {
	t.Helper()
	noWalletRenewedReset(t)
	freeRenewedMu.Lock()
	old := freeRenewedThrough
	freeRenewedThrough = map[string]int64{}
	freeRenewedMu.Unlock()
	t.Cleanup(func() {
		freeRenewedMu.Lock()
		freeRenewedThrough = old
		freeRenewedMu.Unlock()
	})
}

// billingLatchLens reads both latches' sizes under their mutexes.
func billingLatchLens() (free, noWallet int) {
	freeRenewedMu.Lock()
	free = len(freeRenewedThrough)
	freeRenewedMu.Unlock()
	noWalletRenewedMu.Lock()
	noWallet = len(noWalletRenewed)
	noWalletRenewedMu.Unlock()
	return free, noWallet
}

// billingLatchSeed sets both latches for one key.
func billingLatchSeed(key string) {
	latchFreeRenewed(key, 42)
	recordNoWalletRenewal(key, leaseInfo{}, false, 42)
}

func TestBillingLatchForget_ForgetSessionKeysEmptiesBoth(t *testing.T) {
	billingLatchReset(t)
	billingLatchSeed(billingLatchKeyA)
	billingLatchSeed(billingLatchKeyB)
	if free, noWallet := billingLatchLens(); free != 2 || noWallet != 2 {
		t.Fatalf("the seed left free=%d noWallet=%d, want 2 and 2", free, noWallet)
	}
	forgetSessionKeys("test")
	free, noWallet := billingLatchLens()
	if free != 0 {
		t.Errorf("freeRenewedThrough still holds %d key(s) after forgetSessionKeys", free)
	}
	if noWallet != 0 {
		t.Errorf("noWalletRenewed still holds %d key(s) after forgetSessionKeys", noWallet)
	}
}

// The real handleLogout, with no CLEAN-STORAGE sent: only the logout-wallet goroutine's forget can empty the maps.
func TestBillingLatchForget_ALandedSignOutForgetsAfterItsRenewal(t *testing.T) {
	billingLatchReset(t)
	dest := cutoffSession(t, "11")
	if err := markRoamSession(dest, "latchforget-a", "latchforget-pass", "11", ""); err != nil {
		t.Fatal(err)
	}
	if err := bumpWalletGeneration(walletPathFor(dest)); err != nil {
		t.Fatal(err)
	}
	billingLatchSeed(billingLatchKeyA) // another profile's latch: the whole map goes
	var mu sync.Mutex
	renewed, walletPublished := false, false
	oldR, oldW := logoutRenewStep, logoutWalletStep
	logoutRenewStep = func(d, name, pass string, se []byte, gen, u string) {
		billingLatchSeed(profileRefV2(name, pass))
		mu.Lock()
		renewed = true
		mu.Unlock()
	}
	logoutWalletStep = func(d, name, pass string, se []byte, gen, u string) (bool, error) {
		mu.Lock()
		walletPublished = true
		mu.Unlock()
		return false, nil
	}
	t.Cleanup(func() { logoutRenewStep, logoutWalletStep = oldR, oldW })
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": "OK", "cutoffwake": "WAKE OK 0"}, nil)
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	for end := time.Now().Add(15 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		mu.Lock()
		done := renewed && walletPublished
		mu.Unlock()
		if done {
			break
		}
		if time.Now().After(end) {
			t.Fatal("the renewal and wallet steps did not both run after a landed sign-out")
		}
	}
	ackReapAction("SWITCH", "11")
	ackReapAction("REAP", "11")
	var free, noWallet int
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if free, noWallet = billingLatchLens(); free == 0 && noWallet == 0 {
			return
		}
	}
	if free != 0 {
		t.Errorf("freeRenewedThrough still holds %d key(s) 5s after the landed sign-out", free)
	}
	if noWallet != 0 {
		t.Errorf("noWalletRenewed still holds %d key(s) 5s after the landed sign-out", noWallet)
	}
}

func TestBillingLatchForget_TheHelperTakesBothLocks(t *testing.T) {
	bb, err := os.ReadFile("billing.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(bb), "forgetBillingLatches")), "\n")
	for _, want := range []string{"freeRenewedMu.Lock()", "noWalletRenewedMu.Lock()"} {
		if !strings.Contains(body, want) {
			t.Errorf("forgetBillingLatches does not take %s", want)
		}
	}
	mb, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if body := strings.Join(stripComments(funcBody(t, string(mb), "forgetSessionKeys")), "\n"); !strings.Contains(body, "forgetBillingLatches()") {
		t.Error("forgetSessionKeys does not call forgetBillingLatches")
	}
}
