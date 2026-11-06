package main

import "testing"

// NWP-20260901-17: the chooser's transient APK-install staging (.appcode) must never be sealed, never be
// carried, and never render on the Offline-media screen. This pins the predicate all three rely on.
//
// The bug it closes is the NWP-20260831-08 shape one directory over: a periodic seal that ran DURING a
// materialise walked ~215MB of staged gms APKs under com.nowhere.chooser/files/.appcode/, the media split
// deferred them (big files under a "/files/" segment), the staging was deleted minutes later, and the
// present-not-deleted carry kept the rels in the head forever -- rendered as held by "Profile", undeletable.
func TestIsAppCodeStagePath(t *testing.T) {
	yes := []string{
		"com.nowhere.chooser/files/.appcode",
		"com.nowhere.chooser/files/.appcode/com.google.android.gms/base.apk",
		"com.nowhere.chooser/files/.appcode/com.android.vending/split_config.arm64_v8a.apk",
		"/com.nowhere.chooser/files/.appcode/x", // tolerate a leading slash, like the other rel predicates
	}
	for _, rel := range yes {
		if !isAppCodeStagePath(rel) {
			t.Errorf("isAppCodeStagePath(%q) = false, want true", rel)
		}
	}
	no := []string{
		// The dir that MUST keep sealing: the on-demand hold is app STATE in parked form (-08 seals it
		// essential); dropping it here would destroy a parked app's data.
		"com.nowhere.chooser/.nowhere-odhold/com.android.vending/files/x",
		// The chooser's real files (pins, keep-lists) -- tiny, but they are legit vault content.
		"com.nowhere.chooser/files/nowhere-pins",
		// A sibling dir that merely shares the prefix must not match.
		"com.nowhere.chooser/files/.appcode-x/f",
		"com.nowhere.chooser/files/.appcodes/f",
		// Another app that happens to have a files/.appcode dir is NOT the chooser's staging.
		"org.example.other/files/.appcode/f",
		// An app's ordinary data.
		"com.android.vending/files/phonesky-download-service/1/blob",
		"Android/data/app.organicmaps/files/maps/x.mwm",
	}
	for _, rel := range no {
		if isAppCodeStagePath(rel) {
			t.Errorf("isAppCodeStagePath(%q) = true, want false", rel)
		}
	}
}
