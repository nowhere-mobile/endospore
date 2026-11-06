package main

import (
	"strings"
	"testing"
)

// NWP-20261123-13 (h53 #5): an installable package file in an app's private storage is never deferred. The rule
// is by shape: a .apk/.apks/.xapk/.apkm under Android/data/<pkg>/ (the #media scope) or in a CE <pkg>/ tree.
// The user's own folders and Android/media are unchanged, so a package file in Download still defers.

const apkEagerBig = int64(512 << 20) // above every floor (app 8 MiB, user 1 MiB)

// apkEagerRels must stay in the login restore.
var apkEagerRels = []string{
	"Android/data/com.example.inst/files/update.apk",
	"Android/data/com.example.inst/files/update.apks",
	"Android/data/com.example.inst/files/update.xapk",
	"Android/data/com.example.inst/files/update.apkm",
	"Android/data/com.example.inst/files/UPDATE.APK",
	"com.example.inst/files/update.apk",          // CE vault shape
	"com.example.inst/files/update.xapk",         // CE vault shape
	"com.example.inst/files/Download/update.apk", // a user-folder segment INSIDE an app-private tree
}

// apkEagerControls must still defer: the user's own folders, Android/media, and a non-package file.
var apkEagerControls = []string{
	"Download/app.apk",
	"Download/com.example.x/files/app.apk",
	"Android/media/com.example.x/app.apk",
	"Android/data/com.example.inst/files/map.bin",
}

func TestMediaApkEagerClassifyDeferred(t *testing.T) {
	for _, rel := range apkEagerRels {
		if classifyDeferred(rel, apkEagerBig) {
			t.Errorf("classifyDeferred(%q) = true, want false: a package file in app-private storage is never deferred", rel)
		}
	}
	for _, rel := range apkEagerControls {
		if !classifyDeferred(rel, apkEagerBig) {
			t.Errorf("classifyDeferred(%q) = false, want true: the control must still defer", rel)
		}
	}
}

func TestMediaApkEagerClassifyTier(t *testing.T) {
	override := map[string]mediaTier{"com.example.inst": tierPrefetch}
	for _, rel := range apkEagerRels {
		if got := classifyTier(rel, apkEagerBig, nil, nil); got != tierEssential {
			t.Errorf("classifyTier(%q) = %v, want tierEssential", rel, got)
		}
		if got := classifyTier(rel, apkEagerBig, override, nil); got != tierEssential {
			t.Errorf("classifyTier(%q) with a prefetch override = %v, want tierEssential (the rule beats an override)", rel, got)
		}
	}
	for _, rel := range apkEagerControls {
		if got := classifyTier(rel, apkEagerBig, nil, nil); got == tierEssential {
			t.Errorf("classifyTier(%q) = tierEssential, want a deferred tier: the control must still defer", rel)
		}
	}
}

// The return door refuses too: an already-deferred package file in app-private storage folds essential.
func TestMediaApkEagerRedeferRefused(t *testing.T) {
	for _, rel := range apkEagerRels {
		prev := map[string]deferredFile{rel: {Size: apkEagerBig}}
		if tier, ok := redeferTier(rel, apkEagerBig, prev, nil, nil); ok {
			t.Errorf("redeferTier(%q) = (%v, true), want false", rel, tier)
		}
	}
	rel := "Download/app.apk"
	if _, ok := redeferTier(rel, apkEagerBig, map[string]deferredFile{rel: {Size: apkEagerBig}}, nil, nil); !ok {
		t.Errorf("redeferTier(%q) = false, want true: a package file in Download may go back to deferred", rel)
	}
}

// The CE shape treats a first segment with a '.' as a package directory. That excludes the user's folders only
// while no mediaUserDirs / mediaUserRootPrefixes entry has a '.' in its first segment.
func TestMediaApkEagerUserFoldersHaveNoDot(t *testing.T) {
	for _, dir := range append(append([]string{}, mediaUserDirs...), mediaUserRootPrefixes...) {
		first := strings.SplitN(strings.TrimPrefix(dir, "/"), "/", 2)[0]
		if strings.Contains(first, ".") {
			t.Errorf("user media entry %q has a '.' in its first segment: the CE package-file shape would treat it as app-private", dir)
		}
	}
}
