package main

import (
	"encoding/json"
	"testing"
	"time"
)

// NWP-20260901-27 (#145 S3): the stored-apps extraction. Signal 2 is the #124 answer -- which apps live on
// this phone with no copy in the store -- so the failure directions matter more than the happy path: "not
// measured" must never read as "nothing stored", and a non-package rel must never become an app row.
func TestStoredAppsFromManifest(t *testing.T) {
	// Essential half from the Pkg index; deferred half summed per package from sealed chunk sizes.
	m := chunkManifest{
		Pkg: map[string]int64{
			"com.whatsapp":        41 << 20,
			"com.android.vending": 30 << 20,
		},
		Deferred: map[string]deferredFile{
			"com.whatsapp/split_config.arm64.apk": {Sz: []int64{5 << 20, 3 << 20}},
			"com.example.game/base.apk":           {Sz: []int64{100 << 20}},
			// The -17 lesson: a first segment without a dot is NOT a package and must be dropped, not shown.
			"Download/leftover.apkm": {Sz: []int64{127 << 20}},
		},
	}
	got := storedAppsFromManifest(m)
	if got == nil {
		t.Fatal("measured manifest returned nil (= not measured)")
	}
	if got["com.whatsapp"] != 41<<20+8<<20 {
		t.Errorf("whatsapp = %d, want essential+deferred sum", got["com.whatsapp"])
	}
	if got["com.example.game"] != 100<<20 {
		t.Errorf("deferred-only app = %d, want 100MiB", got["com.example.game"])
	}
	if _, bad := got["Download"]; bad {
		t.Error("non-dotted first segment rendered as an app row")
	}
	if len(got) != 3 {
		t.Errorf("rows = %d (%v), want 3", len(got), got)
	}
}

// nil (not measured) is distinct from empty (measured, nothing attributable). Conflating them is the
// over-claiming delta the design forbids: it would tell someone it is safe to power off when it is not.
func TestStoredAppsNotMeasuredIsNil(t *testing.T) {
	if got := storedAppsFromManifest(chunkManifest{}); got != nil {
		t.Fatalf("legacy manifest (no Pkg, no Deferred) = %v, want nil", got)
	}
	// Measured but everything filtered: empty map, NOT nil.
	m := chunkManifest{Deferred: map[string]deferredFile{"Download/x": {Sz: []int64{1}}}}
	got := storedAppsFromManifest(m)
	if got == nil || len(got) != 0 {
		t.Fatalf("all-filtered manifest = %v, want empty non-nil map", got)
	}
}

// Signal 1: the OK stamp is promoted on an OK verdict ONLY. A failed seal updating "last saved" would be
// the restore-receipt mistake in a new coat (design risk #4).
func TestSealStampsPromoteOnOKOnly(t *testing.T) {
	lastSealStartedAt.Store(0)
	lastSealOKAt.Store(0)
	t.Cleanup(func() { lastSealStartedAt.Store(0); lastSealOKAt.Store(0); resetSealStatus() })

	markSealStarted()
	if lastSealStartedAt.Load() == 0 {
		t.Fatal("markSealStarted did not stamp")
	}
	recordSeal("ERR-NOCREDIT")
	if lastSealOKAt.Load() != 0 {
		t.Fatal("a FAILED verdict promoted the OK stamp")
	}
	recordSeal("OK")
	if lastSealOKAt.Load() == 0 {
		t.Fatal("an OK verdict did not promote the OK stamp")
	}
}

// The reply shape: a wire-visible contract, pinned so the chooser's reader and this stay in step.
func TestSealDeltaReplyShape(t *testing.T) {
	r := sealDeltaReply{V: 1, Session: "stored", Verdict: "ok", LastStart: 100, LastOK: 90,
		Run: "periodic", Deferrals: 2, StoredApps: map[string]int64{"com.a.b": 5}, StoredKnown: true}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"v", "session", "verdict", "lastStart", "lastOK", "run", "deferrals", "storedApps", "storedMeasured"} {
		if _, ok := m[k]; !ok {
			t.Errorf("reply missing %q", k)
		}
	}
}

// The cache must never serve another profile's rows across a re-login.
func TestStoredAppsCacheIsProfileKeyed(t *testing.T) {
	c := &sealDeltaCache
	c.mu.Lock()
	c.name, c.apps, c.known, c.at, c.inFlight = "alice", map[string]int64{"com.x.y": 1}, true, time.Now(), true
	c.mu.Unlock()
	t.Cleanup(func() {
		c.mu.Lock()
		c.name, c.apps, c.known, c.at, c.inFlight = "", nil, false, time.Time{}, false
		c.mu.Unlock()
	})
	// inFlight=true blocks the refresh kick, so this exercises ONLY the read path.
	apps, known := storedAppsCached("bob", "pw", nil)
	if apps != nil || known {
		t.Fatalf("cache served alice's rows to bob: (%v, %v)", apps, known)
	}
	apps, known = storedAppsCached("alice", "pw", nil)
	if !known || apps["com.x.y"] != 1 {
		t.Fatalf("cache failed to serve its own profile: (%v, %v)", apps, known)
	}
}
