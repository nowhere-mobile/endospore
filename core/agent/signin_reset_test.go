package main

// NWP-20261108-03: a new sign-in's Your data carries nothing of the last session. resetSealSignals also clears the
// last manual save's figures, the deferral count and both SEAL-DELTA caches; a stored-apps refresh kicked before the
// reset publishes nothing. test-signin-reset.sh breaks each part in turn.

import (
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// siresetEnv points the store at an in-process one (a kicked refresh ends at once) and restores every global the
// tests touch.
func siresetEnv(t *testing.T) {
	t.Helper()
	base := sealDeltaBase
	started, ok := lastSealStartedAt.Load(), lastSealOKAt.Load()
	bytes, areas, defers := lastSaveBytes.Load(), lastSaveAreas.Load(), sealDeferCount.Load()
	hook := sealDeltaRefreshHook
	sealDeltaBase = newHTTPStore(t)
	sdseResetCaches(nil)
	t.Cleanup(func() {
		sealDeltaBase, sealDeltaRefreshHook = base, hook
		lastSealStartedAt.Store(started)
		lastSealOKAt.Store(ok)
		lastSaveBytes.Store(bytes)
		lastSaveAreas.Store(areas)
		sealDeferCount.Store(defers)
		sdseResetCaches(nil)
	})
}

// siresetJoin registers the join of every kicked refresh after siresetEnv's cleanup, so it runs BEFORE it (cleanups
// run last-in first): a Fatal before a test's own wait still leaves no refresh running against the restored globals.
func siresetJoin(t *testing.T, tr *goSafeTracker) {
	t.Helper()
	t.Cleanup(func() { tr.wait(t, 5*time.Second) })
}

func TestSigninResetClearsTheLastSaveAndDeferrals(t *testing.T) {
	siresetEnv(t)
	lastSaveBytes.Store(2 << 30)
	lastSaveAreas.Store(5)
	sealDeferCount.Store(7)
	resetSealSignals()
	if b, n, d := lastSaveBytes.Load(), lastSaveAreas.Load(), sealDeferCount.Load(); b != 0 || n != 0 || d != 0 {
		t.Fatalf("after a sign-in reset: lastSaveBytes=%d lastSaveAreas=%d sealDeferCount=%d, want all 0", b, n, d)
	}
}

func TestSigninResetASameNamedProfileIsNotServedTheLastRows(t *testing.T) {
	tr := trackGoSafe(t)
	siresetEnv(t)
	siresetJoin(t, tr)
	sealDeltaCache.mu.Lock()
	sealDeltaCache.name, sealDeltaCache.apps, sealDeltaCache.known = "sireset-sam", map[string]int64{"com.example.app": 1}, true
	sealDeltaCache.at = time.Now().Add(-2 * time.Minute)
	sealDeltaCache.mu.Unlock()
	resetSealSignals()
	apps, known := storedAppsCached("sireset-sam", "pw-two", nil)
	if apps != nil || known {
		t.Fatalf("a second sign-in under the same name was served %v (known=%v) from the first", apps, known)
	}
	tr.wait(t, 5*time.Second)
}

func TestSigninResetARefreshFromBeforeTheResetPublishesNothing(t *testing.T) {
	tr := trackGoSafe(t)
	siresetEnv(t)
	siresetJoin(t, tr)
	var fired atomic.Bool
	sealDeltaRefreshHook = func() {
		if !fired.CompareAndSwap(false, true) {
			return
		}
		resetSealSignals()
		sealDeltaCache.mu.Lock()
		sealDeltaCache.inFlight = true // the new identity's own kick
		sealDeltaCache.mu.Unlock()
	}
	storedAppsCached("sireset-before", "pw", nil)
	tr.wait(t, 5*time.Second)
	if !fired.Load() {
		t.Fatal("the refresh hook never ran")
	}
	sealDeltaCache.mu.Lock()
	name, apps, known, inFlight := sealDeltaCache.name, sealDeltaCache.apps, sealDeltaCache.known, sealDeltaCache.inFlight
	sealDeltaCache.mu.Unlock()
	if name != "" || apps != nil || known {
		t.Fatalf("a refresh begun before the reset published name=%q apps=%v known=%v", name, apps, known)
	}
	if !inFlight {
		t.Fatal("a refresh begun before the reset cleared the new identity's inFlight")
	}
}

func TestSigninResetEmptiesTheWalkIndexCache(t *testing.T) {
	siresetEnv(t)
	sealDeltaIdxCache.mu.Lock()
	sealDeltaIdxCache.name, sealDeltaIdxCache.ok, sealDeltaIdxCache.at = "sireset-sam", true, time.Now()
	sealDeltaIdxCache.mu.Unlock()
	resetSealSignals()
	sealDeltaIdxCache.mu.Lock()
	name, ok, at := sealDeltaIdxCache.name, sealDeltaIdxCache.ok, sealDeltaIdxCache.at
	sealDeltaIdxCache.mu.Unlock()
	if name != "" || ok || !at.IsZero() {
		t.Fatalf("walk index cache after a sign-in: name=%q ok=%v at=%v, want empty", name, ok, at)
	}
}

func TestSigninResetSealDeltaCarriesNothingOfTheLastSession(t *testing.T) {
	tr := trackGoSafe(t)
	siresetEnv(t)
	siresetJoin(t, tr)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	dest := t.TempDir()
	lastSaveBytes.Store(2 << 30)
	lastSaveAreas.Store(5)
	sealDeferCount.Store(3)
	if err := markRoamSession(dest, "sireset-b", "pw-b", "21", ""); err != nil {
		t.Fatal(err)
	}
	resetSealSignals()
	now := time.Now().Unix()
	lastSealStartedAt.Store(now)
	lastSealOKAt.Store(now)
	reply := ropReply(t, func(c net.Conn) { handleSealDelta(c, dest) })
	nl := strings.IndexByte(reply, '\n')
	if nl < 0 || !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("SEAL-DELTA reply %q", reply)
	}
	body := reply[nl+1:]
	if want := fmt.Sprintf("OK %d", len(body)); reply[:nl] != want {
		t.Fatalf("frame %q for a %d-byte body", reply[:nl], len(body))
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		t.Fatal(err)
	}
	if m["lastOK"] != float64(now) {
		t.Fatalf("lastOK = %v, want the new session's %d", m["lastOK"], now)
	}
	for _, k := range []string{"lastSaveB", "lastSaveN"} {
		if v, has := m[k]; has {
			t.Fatalf("%s = %v on the new session's Your data", k, v)
		}
	}
	if m["deferrals"] != float64(0) {
		t.Fatalf("deferrals = %v, want 0", m["deferrals"])
	}
	tr.wait(t, 5*time.Second)
}

func TestSigninResetAResumeKeepsAll(t *testing.T) {
	siresetEnv(t)
	dest := t.TempDir()
	lastSaveBytes.Store(2 << 30)
	lastSaveAreas.Store(5)
	sealDeferCount.Store(3)
	now := time.Now()
	sealDeltaCache.mu.Lock()
	sealDeltaCache.name, sealDeltaCache.apps, sealDeltaCache.known = "sireset-keep", map[string]int64{"com.example.app": 1}, true
	sealDeltaCache.at, sealDeltaCache.inFlight = now, true // inFlight: no kick
	sealDeltaCache.mu.Unlock()
	sealDeltaIdxCache.mu.Lock()
	sealDeltaIdxCache.name, sealDeltaIdxCache.ok, sealDeltaIdxCache.at = "sireset-keep", true, now
	sealDeltaIdxCache.mu.Unlock()
	if err := markRoamSession(dest, "sireset-keep", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	if b, n, d := lastSaveBytes.Load(), lastSaveAreas.Load(), sealDeferCount.Load(); b != 2<<30 || n != 5 || d != 3 {
		t.Fatalf("a RESUME changed lastSaveBytes=%d lastSaveAreas=%d sealDeferCount=%d", b, n, d)
	}
	sealDeltaCache.mu.Lock()
	cn, ca, ck := sealDeltaCache.name, sealDeltaCache.apps, sealDeltaCache.known
	sealDeltaCache.mu.Unlock()
	sealDeltaIdxCache.mu.Lock()
	xn, xo := sealDeltaIdxCache.name, sealDeltaIdxCache.ok
	sealDeltaIdxCache.mu.Unlock()
	if cn != "sireset-keep" || len(ca) != 1 || !ck || xn != "sireset-keep" || !xo {
		t.Fatalf("a RESUME changed the caches: apps cache %q %v %v, index cache %q %v", cn, ca, ck, xn, xo)
	}
}
