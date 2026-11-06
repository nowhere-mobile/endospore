package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261030-03 (decided 2026-10-20, "a cold-lock wipe removes the wiped session's wallet at once"): the gate's
// cold-lock wipe removes the session's wallet.json through removeWallet, unpublished, after the credit-lost note.
// Both wipe arms reach CLAIM-COLDLOCK only through ChooserActivity.coldWipe (called by ColdWipeReceiver.onReceive,
// the 12-hour alarm, and by evictRecheck's WIPE arm; test-coldwipe-gate-java.sh pins its single claim), so this verb
// is the whole surface. Nothing here is parallel: ownerPeerUID, walletSignInWait and the env are package-global.

func cwwShortWait(t *testing.T) {
	t.Helper()
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
}

func cwwPark(t *testing.T, f *walletFailFixture) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.dest, ".coldlock"), []byte(walletFailName+"\n15\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func cwwClaim(t *testing.T, f *walletFailFixture, uid string) string {
	t.Helper()
	return evictConn(t, f.dest, "CLAIM-COLDLOCK\n"+uid+"\n")
}

func cwwGone(t *testing.T, f *walletFailFixture) {
	t.Helper()
	for _, p := range []string{f.wpath, f.wpath + ".tmp", walletPrevPath(f.wpath)} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s survived the wipe (stat err %v)", filepath.Base(p), err)
		}
	}
}

// cwwPlant leaves a .tmp and a .prev beside the wallet, as an interrupted save would.
func cwwPlant(t *testing.T, f *walletFailFixture) {
	t.Helper()
	for _, p := range []string{f.wpath + ".tmp", walletPrevPath(f.wpath)} {
		if err := os.WriteFile(p, []byte("leftover"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func cwwRead(t *testing.T, f *walletFailFixture) []byte {
	t.Helper()
	b, err := os.ReadFile(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestColdLockWipeWallet_StoredRestoredSession(t *testing.T) {
	gatePeer(t, 10123)
	cwwShortWait(t)
	f := walletFailSetup(t)
	f.signIn(t)
	f.appendTwo(t)
	cwwPlant(t, f)
	gen0 := f.gen()
	cwwPark(t, f)
	n, back := f.countStoreRequests(t)
	got := cwwClaim(t, f, "15")
	reqs := n()
	back()
	if got != "OK" {
		t.Fatalf("CLAIM-COLDLOCK = %q, want OK", got)
	}
	cwwGone(t, f)
	if f.gen() == gen0 {
		t.Error("the generation did not move: the removal did not go through removeWallet")
	}
	if r := creditLostReply(f.dest); r != "NONE" {
		t.Errorf("a restored session's wipe recorded %q, want NONE", r)
	}
	if reqs != 0 {
		t.Errorf("the wipe made %d store request(s); it publishes nothing", reqs)
	}
}

func TestColdLockWipeWallet_NeverRestoredKeepsTheNotice(t *testing.T) {
	gatePeer(t, 10123)
	cwwShortWait(t)
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	cwwPark(t, f)
	if got := cwwClaim(t, f, "15"); got != "OK" {
		t.Fatalf("CLAIM-COLDLOCK = %q, want OK", got)
	}
	if r := creditLostReply(f.dest); !strings.HasPrefix(r, "NOTICE ") {
		t.Errorf("the wipe recorded %q, want a notice (it must be noted before the wallet is removed)", r)
	}
	cwwGone(t, f)
}

func TestColdLockWipeWallet_Throwaway(t *testing.T) {
	gatePeer(t, 10123)
	cwwShortWait(t)
	f := walletFailSetup(t)
	f.failedRoamIn(t)
	f.appendTwo(t)
	markLocalSession(f.dest)
	cwwPark(t, f)
	if got := cwwClaim(t, f, "15"); got != "OK" {
		t.Fatalf("CLAIM-COLDLOCK = %q, want OK", got)
	}
	cwwGone(t, f)
	if r := creditLostReply(f.dest); r != "NONE" {
		t.Errorf("a throwaway's wipe recorded %q, want NONE", r)
	}
}

func TestColdLockWipeWallet_GoneTouchesNothing(t *testing.T) {
	gatePeer(t, 10123)
	cwwShortWait(t)
	t.Run("another uid", func(t *testing.T) {
		f := walletFailSetup(t)
		f.signIn(t)
		f.appendTwo(t)
		cwwPark(t, f)
		before, gen := cwwRead(t, f), f.gen()
		if got := cwwClaim(t, f, "16"); got != "GONE" {
			t.Fatalf("CLAIM-COLDLOCK for another uid = %q, want GONE", got)
		}
		if !bytes.Equal(before, cwwRead(t, f)) || f.gen() != gen {
			t.Error("a GONE claim touched the wallet")
		}
	})
	t.Run("a second claim", func(t *testing.T) {
		f := walletFailSetup(t)
		f.signIn(t)
		f.appendTwo(t)
		cwwPark(t, f)
		if got := cwwClaim(t, f, "15"); got != "OK" {
			t.Fatalf("first claim = %q, want OK", got)
		}
		f.appendTwo(t) // the next session's wallet
		before, gen := cwwRead(t, f), f.gen()
		if got := cwwClaim(t, f, "15"); got != "GONE" {
			t.Fatalf("second claim = %q, want GONE", got)
		}
		if !bytes.Equal(before, cwwRead(t, f)) || f.gen() != gen {
			t.Error("a GONE claim touched the next session's wallet")
		}
	})
}

func TestColdLockWipeWallet_LeasedWriterCannotSaveBack(t *testing.T) {
	gatePeer(t, 10123)
	cwwShortWait(t)
	f := walletFailSetup(t)
	f.signIn(t)
	f.appendTwo(t)
	oldGen := f.gen()
	cwwPark(t, f)
	if got := cwwClaim(t, f, "15"); got != "OK" {
		t.Fatalf("CLAIM-COLDLOCK = %q, want OK", got)
	}
	if walletAtGeneration(f.wpath, oldGen) {
		t.Error("a writer that loaded before the claim still passes its save check")
	}
}

func TestColdLockWipeWallet_RoamedCallerRefused(t *testing.T) {
	gatePeer(t, gateRoamedA)
	cwwShortWait(t)
	f := walletFailSetup(t)
	f.signIn(t)
	f.appendTwo(t)
	cwwPark(t, f)
	before, gen := cwwRead(t, f), f.gen()
	if got := cwwClaim(t, f, "15"); got != "DENIED" {
		t.Fatalf("a roamed caller's CLAIM-COLDLOCK = %q, want DENIED", got)
	}
	if !bytes.Equal(before, cwwRead(t, f)) || f.gen() != gen {
		t.Error("a refused claim touched the wallet")
	}
	if _, err := os.Stat(filepath.Join(f.dest, ".coldlock")); err != nil {
		t.Error("a refused claim dropped the marker")
	}
}
