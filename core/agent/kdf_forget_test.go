package main

import (
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// dn-1106 #1 (NWP-20261107-04): the login daemon forgets its KDF cache at every session end, once that session's last
// seal and wallet publish are done. Each test has its own profile name and resets the cache when it ends.

// kdfForgetSeed puts one entry in the cache and returns its key; the cache is emptied again when the test ends.
func kdfForgetSeed(t *testing.T, name string) string {
	t.Helper()
	k := name + "\x00kdf-forget-pass"
	deriveKeyMu.Lock()
	deriveKeyCache = map[string][]byte{k: make([]byte, 32)}
	deriveKeyMu.Unlock()
	t.Cleanup(func() {
		deriveKeyMu.Lock()
		deriveKeyCache = map[string][]byte{}
		deriveKeyMu.Unlock()
	})
	return k
}

func kdfForgetHas(k string) bool {
	deriveKeyMu.Lock()
	defer deriveKeyMu.Unlock()
	_, ok := deriveKeyCache[k]
	return ok
}

func kdfForgetLen() int {
	deriveKeyMu.Lock()
	defer deriveKeyMu.Unlock()
	return len(deriveKeyCache)
}

// kdfForgetWaitEmpty polls, bounded, for the cache to empty.
func kdfForgetWaitEmpty(t *testing.T, d time.Duration) {
	t.Helper()
	for end := time.Now().Add(d); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if kdfForgetLen() == 0 {
			return
		}
	}
	if n := kdfForgetLen(); n != 0 {
		t.Errorf("the KDF cache still holds %d entr(ies) %v after the session ended", n, d)
	}
}

// K1: the gate's CLEAN-STORAGE for a roamed user forgets; one for a uid below 10 does not.
func TestKDFForget_CleanStorageForgetsAReapedSession(t *testing.T) {
	for _, c := range []struct {
		name, uid string
		forgets   bool
	}{{"kdfforget-a", "11", true}, {"kdfforget-a5", "5", false}} {
		t.Run("uid "+c.uid, func(t *testing.T) {
			k := kdfForgetSeed(t, c.name)
			gatePeer(t, 10123)
			f, _, _ := gateOnlyFixture(t, "CLEAN-STORAGE", []abPlan{{lane: laneRW, text: "OK"}})
			defer waitGateOnly(t)
			reply, _, answered := gateOnlyDrive(t, f.dest, "CLEAN-STORAGE", c.uid+"\n", 10*time.Second)
			if !answered || reply != "OK" {
				t.Fatalf("CLEAN-STORAGE %s answered %q (answered=%v), want OK", c.uid, reply, answered)
			}
			if got := kdfForgetHas(k); got == c.forgets {
				t.Errorf("after CLEAN-STORAGE %s the seeded key is present=%v, want %v", c.uid, got, !c.forgets)
			}
		})
	}
}

// K2: a landed sign-out forgets after its wallet publish, never before: the step still sees the key.
func TestKDFForget_ALandedSignOutForgetsAfterItsWalletPublish(t *testing.T) {
	dest := cutoffSession(t, "11")
	if err := bumpWalletGeneration(walletPathFor(dest)); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	called, sawKey := false, false
	k := kdfForgetSeed(t, "kdfforget-b")
	old := logoutWalletStep
	logoutWalletStep = func(d, name, pass string, se []byte, gen, u string) (bool, error) {
		mu.Lock()
		called, sawKey = true, kdfForgetHas(k)
		mu.Unlock()
		return false, nil
	}
	t.Cleanup(func() { logoutWalletStep = old })
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": "OK", "cutoffwake": "WAKE OK 0"}, nil)
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	for end := time.Now().Add(15 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		mu.Lock()
		c := called
		mu.Unlock()
		if c {
			break
		}
		if time.Now().After(end) {
			t.Fatal("the wallet step never ran after a landed sign-out")
		}
	}
	ackReapAction("SWITCH", "11")
	ackReapAction("REAP", "11")
	kdfForgetWaitEmpty(t, 5*time.Second)
	mu.Lock()
	defer mu.Unlock()
	if !sawKey {
		t.Error("the wallet step ran with the key already forgotten: the publish is the key's last user")
	}
}

// K3: END-UNSAVED forgets after its wallet drop, never before.
func TestKDFForget_EndUnsavedForgetsAfterItsWalletPublish(t *testing.T) {
	f := euSetup(t)
	k := kdfForgetSeed(t, "kdfforget-c")
	var mu sync.Mutex
	sawKey := false
	prev := endUnsavedWalletDrop
	endUnsavedWalletDrop = func(dest, name, pass string, se []byte, gen, uid string) (bool, error) {
		mu.Lock()
		sawKey = kdfForgetHas(k)
		mu.Unlock()
		return prev(dest, name, pass, se, gen, uid)
	}
	t.Cleanup(func() { endUnsavedWalletDrop = prev })
	if err := markRoamSession(f.dest, "alice", "pw", euUID, "a1b2c3d4e5f6"); err != nil {
		t.Fatal(err)
	}
	wp := walletPathFor(f.dest)
	if err := os.WriteFile(wp, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := bumpWalletGeneration(wp); err != nil {
		t.Fatal(err)
	}
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	if got := f.end(); got != "OK" {
		t.Fatalf("END-UNSAVED answered %q, want OK", got)
	}
	f.waitDrop(t, 5*time.Second)
	kdfForgetWaitEmpty(t, 5*time.Second)
	mu.Lock()
	defer mu.Unlock()
	if !sawKey {
		t.Error("the wallet drop ran with the key already forgotten: the publish is the key's last user")
	}
}

// K4: a sign-in that answers BLANK or BLANK NET forgets.
func TestKDFForget_ABlankSignInForgets(t *testing.T) {
	for _, c := range []struct{ answer, name string }{{"BLANK", "kdfforget-d"}, {"BLANK NET", "kdfforget-e"}} {
		t.Run(c.answer, func(t *testing.T) {
			kdfForgetSeed(t, c.name)
			reply, rec := failedSigninDrive(t, c.answer, c.name)
			if reply != c.answer {
				t.Fatalf("the reply is %q, want %q", reply, c.answer)
			}
			kdfForgetWaitEmpty(t, 3*time.Second)
			// A BLANK reply schedules roamd's log scrub (NWP-20261027-02) in the background. Wait for it to reach the
			// worker, as the scrub tests do: failedSigninDrive's cleanup waits only while the RW slot is held, so a
			// scrub that has not taken it yet outlives the test, writes into its removed TempDir and holds the slot
			// against the next sign-in.
			if !waitForOp(rec, "logscrub", 3*time.Second) {
				t.Errorf("no logscrub request reached the RW lane after a %s sign-in; ops seen: %v", c.answer, rec.ops)
			}
		})
	}
}

// K5: a busy lane or a timeout is no verdict on the credential, so nothing is forgotten.
func TestKDFForget_ABusyOrTimedOutSignInKeepsTheCache(t *testing.T) {
	for _, c := range []struct{ answer, name string }{{"ERR-TIMEOUT", "kdfforget-f"}, {"ERR-WORKER-BUSY", "kdfforget-g"}} {
		t.Run(c.answer, func(t *testing.T) {
			k := kdfForgetSeed(t, c.name)
			reply, _ := failedSigninDrive(t, c.answer, c.name)
			if reply != c.answer {
				t.Fatalf("the reply is %q, want %q", reply, c.answer)
			}
			time.Sleep(300 * time.Millisecond)
			if !kdfForgetHas(k) {
				t.Errorf("a %s sign-in forgot the KDF cache: no verdict ended that attempt", c.answer)
			}
		})
	}
}

// K6: handleRoamIn forgets in each BLANK branch, after the reply, and in no other.
func TestKDFForget_SourcePins(t *testing.T) {
	success, blankNet, other, blank := roamInBranches(t)
	for _, c := range []struct{ name, src string }{{"success", success}, {"busy/timeout", other}} {
		if strings.Contains(c.src, "forgetSessionKeys(") {
			t.Errorf("the %s part of handleRoamIn forgets the KDF cache: no verdict ended that attempt", c.name)
		}
	}
	for _, c := range []struct{ name, src string }{{"BLANK NET", blankNet}, {"BLANK", blank}} {
		reply := strings.Index(c.src, "fmt.Fprint(conn")
		call := strings.Index(c.src, "forgetSessionKeys(")
		if call < 0 || strings.Count(c.src, "forgetSessionKeys(") != 1 {
			t.Errorf("the %s branch does not forget the KDF cache exactly once", c.name)
		} else if reply < 0 || call < reply {
			t.Errorf("the %s branch forgets BEFORE it writes the reply", c.name)
		}
	}
}
