package main

// NWP-20261114-05: the daemon's calls of roamd's bootwake op (boot_wake.go). No test here reaches a real worker: each
// one replaces bootWakeOp and seedHomeOp, and restores them and clears bootWakeGate in t.Cleanup, so no later test
// that drives handleRestoreOdData finds the gate armed.

import (
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
)

type bootWakeCall struct{ op, dest, uid, pkg string }

// bootWakeFakes replaces the two worker hooks with recorders and sets grantTailDelay to 0. It returns a reader of
// the calls made so far.
func bootWakeFakes(t *testing.T) func() []bootWakeCall {
	t.Helper()
	var mu sync.Mutex
	var calls []bootWakeCall
	oldBoot, oldSeed, oldDelay := bootWakeOp, seedHomeOp, grantTailDelay
	bootWakeGate.clear()
	t.Cleanup(func() {
		bootWakeOp, seedHomeOp, grantTailDelay = oldBoot, oldSeed, oldDelay
		bootWakeGate.clear()
	})
	bootWakeOp = func(dest, uid, pkg string) string {
		mu.Lock()
		defer mu.Unlock()
		calls = append(calls, bootWakeCall{"bootwake", dest, uid, pkg})
		return "BOOTWAKE 2 3\n"
	}
	seedHomeOp = func(dest, uid string) string {
		mu.Lock()
		defer mu.Unlock()
		calls = append(calls, bootWakeCall{"seed-home", dest, uid, ""})
		return "OK\n"
	}
	grantTailDelay = 0
	return func() []bootWakeCall {
		mu.Lock()
		defer mu.Unlock()
		return append([]bootWakeCall(nil), calls...)
	}
}

func TestGrantTail_SeedHomeThenBootWake(t *testing.T) {
	got := bootWakeFakes(t)
	grantTail("D", "10")
	want := []bootWakeCall{{"seed-home", "D", "10", ""}, {"bootwake", "D", "10", ""}}
	if c := got(); !reflect.DeepEqual(c, want) {
		t.Fatalf("grantTail made %v, want seed-home then bootwake for every package, once each: %v", c, want)
	}
}

func TestBootWakeGate_ArmedOnlyAfterGrantUntilTheNextLogin(t *testing.T) {
	bootWakeFakes(t)
	if bootWakeGate.armed("10") {
		t.Fatal("a fresh gate is armed")
	}
	bootWakeGate.arm("10")
	if !bootWakeGate.armed("10") {
		t.Error("the gate is not armed for the uid GRANT-PERMS armed it for")
	}
	if bootWakeGate.armed("11") {
		t.Error("the gate is armed for a different uid")
	}
	if bootWakeGate.armed("") {
		t.Error("the gate is armed for an empty uid")
	}
	bootWakeGate.clear()
	if bootWakeGate.armed("10") {
		t.Error("the gate stays armed after ROAM-IN cleared it")
	}
	bootWakeGate.arm("11")
	if bootWakeGate.armed("10") {
		t.Error("the gate is armed for the previous login's uid after a new login armed it for another")
	}
}

func TestRestoreOdData_BootWakeOnlyForARestoredPackageAfterGrant(t *testing.T) {
	bootWakeFakes(t)
	if bootWakeAfterRestore("OK org.x", "org.x", "10") {
		t.Error("a restore before GRANT-PERMS (gate unarmed) sends the boot broadcasts")
	}
	bootWakeGate.arm("10")
	for _, c := range []struct {
		reply, pkg, uid string
		want            bool
	}{
		{"OK org.x", "org.x", "10", true},
		{"OK NOSRC", "org.x", "10", false},
		{"OK LOCAL", "org.x", "10", false},
		{"ERR-NOTREADY", "org.x", "10", false},
		{"OK org.y", "org.x", "10", false},
		{"OK org.x", "org.x", "11", false},
		{"OK org.x extra", "org.x", "10", false},
	} {
		if got := bootWakeAfterRestore(c.reply, c.pkg, c.uid); got != c.want {
			t.Errorf("bootWakeAfterRestore(%q, %q, %q) = %v, want %v", c.reply, c.pkg, c.uid, got, c.want)
		}
	}
}

func TestRestoreOdData_BootWakePackageSendsThatPackage(t *testing.T) {
	got := bootWakeFakes(t)
	bootWakePackage("D", "10", "org.x")
	want := []bootWakeCall{{"bootwake", "D", "10", "org.x"}}
	if c := got(); !reflect.DeepEqual(c, want) {
		t.Fatalf("bootWakePackage made %v, want %v", c, want)
	}
}

// bootWakeFuncBody returns the source of func <name> in file: from its header to the next top-level func.
func bootWakeFuncBody(t *testing.T, file, name string) string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "\nfunc "+name+"(")
	if i < 0 {
		t.Fatalf("func %s not found in %s", name, file)
	}
	s = s[i+1:]
	if j := strings.Index(s, "\nfunc "); j >= 0 {
		s = s[:j]
	}
	return s
}

// bootWakeInOrder reports whether every piece occurs in src, each after the one before it.
func bootWakeInOrder(src string, pieces ...string) bool {
	at := 0
	for _, p := range pieces {
		i := strings.Index(src[at:], p)
		if i < 0 {
			return false
		}
		at += i + len(p)
	}
	return true
}

func TestBootWakeGate_SourcePins(t *testing.T) {
	bootWakeFakes(t)
	grant := bootWakeFuncBody(t, "main.go", "handleGrantPerms")
	if !bootWakeInOrder(grant, "bootWakeGate.arm(uid)", `goSafe("seed-home", func() { grantTail(dest, uid) })`) {
		t.Error("handleGrantPerms does not arm the gate and then run grantTail under goSafe")
	}
	if strings.Contains(grant, `triggerRoamWorker(dest, "seed-home"`) || strings.Contains(grant, "time.Sleep(") {
		t.Error("handleGrantPerms still runs its own seed-home op or sleep beside grantTail")
	}
	roamIn := bootWakeFuncBody(t, "main.go", "handleRoamIn")
	if !bootWakeInOrder(roamIn, "bootWakeGate.clear()", `armLoginWindow("roam-in", uid, false)`, "triggerRoamWorkerKind(") {
		t.Error("handleRoamIn does not clear the gate beside armLoginWindow, before its roam-in op")
	}
	restore := bootWakeFuncBody(t, "app_code.go", "restoreOdOne")
	if !bootWakeInOrder(restore, `fmt.Fprintf(conn, "%s\n", reply)`, "if bootWakeAfterRestore(reply, pkg, uid) {",
		`goSafe("bootwake-pkg", func() { bootWakePackage(dest, uid, pkg) })`) {
		t.Error("restoreOdOne does not write its reply and then start the gated one-package bootwake")
	}
}
