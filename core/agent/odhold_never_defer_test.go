package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260831-08. The on-demand hold is parked app STATE: it must seal (that is how a never-materialised
// app's data roams) but always ESSENTIAL -- a deferred hold entry becomes permanent dead weight, because the
// hold's rels never exist again anywhere once the app materialises. The reported case: ~215MB of vending's
// phonesky download cache, deferred out of the hold by the "/files/" rule, carried forever, rendered on the
// Offline-media screen as held by "Profile" (the hold lives under the chooser's package segment), and
// undeletable from any device.
func TestHoldPathsAreNeverDeferrable(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "8388608")
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "1048576")

	// The reported case: a parked Play Store download, CE shape.
	ce := "com.nowhere.chooser/.nowhere-odhold/com.android.vending/files/phonesky-download-service/1/blob"
	if classifyDeferred(ce, 100<<20) {
		t.Error("a file parked in the CE hold must never be deferrable, however large")
	}
	// The external hold shape (ext_hold_shape_test's layout).
	ext := "Android/data/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast/files/asset.ab"
	if classifyDeferred(ext, 100<<20) {
		t.Error("a file parked in the EXTERNAL hold must never be deferrable either")
	}
	// The return door refuses hold paths too.
	prev := map[string]deferredFile{ce: {Size: 100 << 20}}
	if _, ok := redeferTier(ce, 100<<20, prev, nil, nil); ok {
		t.Error("redeferTier must refuse a hold path even with a prior deferred record")
	}
	// Guard the guard: the same file at the app's OWN rel (post-materialise life) stays deferrable.
	live := "com.android.vending/files/phonesky-download-service/1/blob"
	if !classifyDeferred(live, 100<<20) {
		t.Error("the same file under the app's own rel must remain deferrable -- the deny is the hold, not the app")
	}
}

// The self-heal: a stale hold-deferred entry in an existing head must be DROPPED by the next seal's carry,
// not carried forever. Seeded via NOWHERE_DEFER_LIST (force-defer bypasses the heuristic, exactly how a
// pre-fix head acquired these entries).
func TestStaleHoldDeferredEntriesAreDroppedNotCarried(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "holdheal", "hold healing horse battery staple"
	createVault(base, name, pass)

	rel := "com.nowhere.chooser/.nowhere-odhold/com.android.vending/files/phonesky-download-service/1/blob"
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Dir(filepath.Join(src, filepath.FromSlash(rel))), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, filepath.FromSlash(rel)), make([]byte, 8192), 0o644); err != nil {
		t.Fatal(err)
	}
	dl := filepath.Join(t.TempDir(), "defer.list")
	if err := os.WriteFile(dl, []byte(rel+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", dl)
	pushProfile(base, name, pass, src)
	if _, ok := redeferManifest(t, base, name, pass).Deferred[rel]; !ok {
		t.Fatal("seed failed: the force-defer list did not put the hold rel into the head's Deferred index")
	}

	// The healing seal: no defer list, the hold path gone from disk (the app materialised; the stash emptied).
	t.Setenv("NOWHERE_DEFER_LIST", "")
	srcB := t.TempDir()
	if err := os.WriteFile(filepath.Join(srcB, "anchor.txt"), []byte("keep the walk non-empty"), 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, srcB)
	if _, ok := redeferManifest(t, base, name, pass).Deferred[rel]; ok {
		t.Fatal("a stale hold-deferred entry was CARRIED -- the 215MB \"held by Profile\" dead weight, not healed")
	}
}
