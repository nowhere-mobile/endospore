package main

// NWP-20261129-49: the mid-session media sync refuses a ".." SEGMENT, not a ".." inside a file name.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSyncRelOK(t *testing.T) {
	for rel, want := range map[string]bool{
		"DCIM/IMG..jpg": true,
		"a..b/c":        true,
		"..hidden/x":    true,
		"DCIM/x..":      true,
		"":              false,
		"/abs":          false,
		"..":            false,
		"../x":          false,
		"a/../b":        false,
		"a/..":          false,
	} {
		if got := syncRelOK(rel); got != want {
			t.Errorf("syncRelOK(%q) = %v, want %v", rel, got, want)
		}
	}
}

// As TestMediaSync_AnotherHandsetsPhotoLandsWithoutALogin, with two dots in the photo's name.
func TestMediaSync_AnEssentialNameHoldingTwoDotsLands(t *testing.T) {
	essentialMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	syncOut := filepath.Join(state, "mediasync.list")
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", syncOut)

	a, b := twoWriters(t, "syncnamesess", "correct horse battery staple")
	ref := profileRefV2("syncnamesess#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, a.head("#media")) })

	const photo = "DCIM/Holiday..jpg"
	const body = "a small photo, under the deferral floor, so it rides the essential tar"
	a.put(photo, body)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}

	target := filepath.Join(b.work, filepath.FromSlash(photo))
	if _, err := os.Lstat(target); err == nil {
		t.Fatal("the photo is already on B before any sync -- this fixture proves nothing")
	}
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("A's photo did not land on B (%v): a name holding two dots is not a traversal", err)
	}
	if string(got) != body {
		t.Errorf("the photo landed with the wrong bytes: %q", string(got))
	}
	list, err := os.ReadFile(syncOut)
	if err != nil || !strings.Contains(string(list), target) {
		t.Errorf("the sync list does not name the file that landed (err=%v, list=%q)", err, string(list))
	}
}

// As TestMediaSync_ADeferredPhotoFromAnotherHandsetLands, with two dots in the photo's name.
func TestMediaSync_ADeferredNameHoldingTwoDotsLands(t *testing.T) {
	deferredMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", filepath.Join(state, "mediasync.list"))

	a, b := twoWriters(t, "syncnamesdef", "correct horse battery staple")
	ref := profileRefV2("syncnamesdef#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, a.head("#media")) })

	const photo = "DCIM/Camera/IMG..x.jpg"
	body := strings.Repeat("photo bytes, comfortably over the lowered floor. ", 40)
	a.put(photo, body)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}
	requireDeferred(t, a, photo)

	target := filepath.Join(b.work, filepath.FromSlash(photo))
	if _, err := os.Lstat(target); err == nil {
		t.Fatal("the photo is already on B before any sync -- this fixture proves nothing")
	}
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("A's DEFERRED photo did not land on B (%v): a name holding two dots is not a traversal", err)
	}
	if string(got) != body {
		t.Errorf("the photo landed with the wrong bytes (%d of %d)", len(got), len(body))
	}
}
