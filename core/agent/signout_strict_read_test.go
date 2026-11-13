package main

import (
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261201-22 (h60 #16; the rule of 2026-10-22 #4): a landed sign-out reads the stored wallet strictly before its
// switch. Unreadable, it publishes no #wallet, keeps the file and records the notice before the switch.

func strictReadTry(t *testing.T, try func(name, pass string, dk []byte) bool) {
	t.Helper()
	old := endStoredWalletReadTry
	endStoredWalletReadTry = try
	t.Cleanup(func() { endStoredWalletReadTry = old })
}

var strictReadKey = func() []byte { return []byte("a fixed key") }

// strictReadStepDone wraps logoutWalletStep so the returned channel closes when the sign-out's wallet step has ended.
func strictReadStepDone(t *testing.T) <-chan struct{} {
	t.Helper()
	done := make(chan struct{})
	old := logoutWalletStep
	logoutWalletStep = func(d, name, pass string, se []byte, gen, u string) (bool, error) {
		defer close(done)
		return old(d, name, pass, se, gen, u)
	}
	t.Cleanup(func() { logoutWalletStep = old })
	return done
}

func strictReadWait(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("the wallet step never ended")
	}
}

// strictReadClearNote leaves no note of gen behind for a later test.
func strictReadClearNote(t *testing.T, gen string) {
	t.Helper()
	t.Cleanup(func() { setLogoutWalletUnreadable(gen, false) })
}

// R1: two tries, one bound.
func TestSignOutStrictRead_HelperTriesTwiceInOneBound(t *testing.T) {
	t.Run("two failures are unreadable", func(t *testing.T) {
		var tries atomic.Int32
		strictReadTry(t, func(string, string, []byte) bool { tries.Add(1); return false })
		if endStoredWalletRead("p", "q", strictReadKey) {
			t.Fatal("a read that failed twice was reported readable")
		}
		if got := tries.Load(); got != 2 {
			t.Fatalf("the read ran %d times, want 2", got)
		}
	})
	t.Run("one failure then a success is readable", func(t *testing.T) {
		var tries atomic.Int32
		strictReadTry(t, func(string, string, []byte) bool { return tries.Add(1) == 2 })
		if !endStoredWalletRead("p", "q", strictReadKey) {
			t.Fatal("the retry that succeeded was reported unreadable")
		}
	})
	t.Run("the bound passing is unreadable", func(t *testing.T) {
		old := endStoredWalletReadWait
		endStoredWalletReadWait = 50 * time.Millisecond
		t.Cleanup(func() { endStoredWalletReadWait = old })
		entered, release := make(chan struct{}), make(chan struct{})
		strictReadTry(t, func(string, string, []byte) bool {
			close(entered)
			select {
			case <-release:
			case <-time.After(2 * time.Second):
			}
			return true
		})
		got := endStoredWalletRead("p", "q", strictReadKey)
		close(release)
		<-entered // the late try has read the seam, so the cleanup can restore it
		if got {
			t.Fatal("a read still running when the bound passed was reported readable")
		}
	})
}

// R2: the store refuses the #wallet read. The notice is there when the sign-out queues its switch, nothing is
// published over the stored copy, and the file is kept.
func TestSignOutStrictRead_UnreadableKeepsTheStoredWallet(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	strictReadClearNote(t, f.gen())
	back := f.walletFailBreakWalletOnly(t)
	defer back()
	done := strictReadStepDone(t)
	out := f.signOut(t, "91")
	if got := creditLostReply(f.dest); !strings.HasPrefix(got, "NOTICE ") {
		t.Fatalf("the gate finds %q when the sign-out queues its switch, want a NOTICE; stderr:\n%s", got, out)
	}
	found := false
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "sign-out user 91: the stored wallet could not be read before the switch") {
			found = true
			if strings.Contains(l, walletFailName) {
				t.Fatalf("the line names the profile: %s", l)
			}
		}
	}
	if !found {
		t.Fatalf("no line says the read failed; stderr:\n%s", out)
	}
	strictReadWait(t, done)
	back()
	f.assertStored(t, f.stored, "a sign-out that could not read the stored wallet")
	if _, err := os.Stat(f.wpath); err != nil {
		t.Fatalf("the wallet file was not kept: %v", err)
	}
}

// R3: a working store publishes and drops as before, with no notice.
func TestSignOutStrictRead_ReadablePublishes(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	done := strictReadStepDone(t)
	out := f.signOut(t, "92")
	if got := creditLostReply(f.dest); got != "NONE" {
		t.Fatalf("the gate finds %q after a sign-out with a working store; stderr:\n%s", got, out)
	}
	strictReadWait(t, done)
	f.assertStored(t, f.stored+2, "a sign-out with a working store")
	assertGone(t, f.wpath)
}

// R4: the read runs after the seal and before the switch is queued.
func TestSignOutStrictRead_BeforeTheSwitch(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(src), "handleLogout")), "\n")
	last := -1
	for _, want := range []string{`triggerRoamWorkerKind(dest, "out"`, `endStoredWalletRead(`, `pendingSwitchUID = uid // seal landed`} {
		at := strings.Index(body, want)
		if at < 0 {
			t.Fatalf("handleLogout has no %q", want)
		}
		if at < last {
			t.Fatalf("%q is out of order in handleLogout", want)
		}
		last = at
	}
}

// R5: a readable read clears a note an earlier unreadable read of the same generation left, so that generation
// publishes.
func TestSignOutStrictRead_AReadableReadClearsTheNote(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen := f.gen()
	setLogoutWalletUnreadable(gen, true)
	strictReadClearNote(t, gen)
	done := strictReadStepDone(t)
	f.signOut(t, "93")
	strictReadWait(t, done)
	if logoutWalletUnreadable(gen) {
		t.Fatal("a readable read left the note set")
	}
	f.assertStored(t, f.stored+2, "the sign-out after a readable read")
}
