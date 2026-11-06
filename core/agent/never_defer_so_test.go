package main

import "testing"

// NWP-20260831-02. Native code can never be a stub: dlopen() of an overlay-served library does not fault
// it in, so a deferred .so kills its app at the first native call. The reported case: WhatsApp's superpack
// cache under CE files/decompressed/libs.spo/, deferred by the "/files/" app-dir rule, served through a
// fuse.nowheremedia overlay mounted inside the app's private data dir, crashing Application.onCreate on
// every launch after a roam (lynx, odtest35, 2026-08-30).
func TestSharedLibrariesAreNeverDeferrable(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "8388608")
	t.Setenv("NOWHERE_MEDIA_MIN_USER", "1048576")

	// ⚠ THE REPORTED CASE: a CE-tree rel (vault scope), over the app floor, inside a /files/ dir.
	wa := "com.whatsapp/files/decompressed/libs.spo/libwhatsapp.so"
	if classifyDeferred(wa, 13714608) {
		t.Error("a .so in CE app data must never be deferrable -- this is the WhatsApp crash, byte for byte")
	}
	// The same rule in the external #media tree: an .so is load-bearing whatever tree it sits in.
	ext := "Android/data/com.some.game/files/lib/arm64/libgame.so"
	if classifyDeferred(ext, 50<<20) {
		t.Error("a .so under external Android/data must never be deferrable either")
	}
	// And the return door: a previously-deferred .so must not be re-deferred by redeferTier.
	prev := map[string]deferredFile{wa: {Size: 13714608}}
	if _, ok := redeferTier(wa, 13714608, prev, nil, nil); ok {
		t.Error("redeferTier must refuse a .so even when a prior deferred record exists")
	}

	// Guard the guard: the deny must not over-reach. A genuinely bulk non-library file in the same dir
	// stays deferrable, so the fix cannot quietly disable CE/media deferral wholesale.
	bulk := "com.whatsapp/files/decompressed/libs.spo/assets.pack"
	if !classifyDeferred(bulk, 13714608) {
		t.Error("a non-.so bulk file on the same path must remain deferrable -- the deny is by suffix, not by dir")
	}
}
