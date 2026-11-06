package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// NWP-20261025-02: A DEFERRED #MEDIA FILE THIS SESSION CREATED, SEALED AND DELETED MUST NOT BE FETCHED BACK.
//
// The deferred tier's twin of NWP-20261025-01. A photo taken this session and sealed by a periodic seal is in
// the stored head and not in the login roster, so once deleted newlyArrivedDeferred read it as another
// handset's arrival and the next seal downloaded it and wrote it back into DCIM. The walked roster is the
// second half of "ours" here too.

func TestMediaArrival_ADeferredPhotoTakenSealedAndDeletedIsNotFetchedBack(t *testing.T) {
	deferredMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", filepath.Join(state, "mediasync.list"))
	a, _ := twoWriters(t, "arrwalk", "correct horse battery staple")
	ref := profileRefV2("arrwalk#media", "correct horse battery staple")
	const photo = "DCIM/Camera/IMG_taken_here.jpg"

	a.put("Documents/shared.txt", "tiny")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	a.as(func() { loginArrived(ref, a.head("#media")) })

	a.put(photo, strings.Repeat("a blurry photo, over the lowered floor. ", 100))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("seal that publishes the photo: %s", msg)
	}
	requireDeferred(t, a, photo)

	a.rm(photo)
	out := captureStdout(t, func() {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("seal after the delete: %s", msg)
		}
	})
	if _, err := os.Lstat(filepath.Join(a.work, filepath.FromSlash(photo))); err == nil {
		t.Error("the deleted photo was fetched back onto the phone by the next seal")
	}
	if strings.Contains(out, "arrived from another handset") {
		t.Errorf("the seal reports the session's own photo as an arrival:\n%s", out)
	}
}

func TestMediaArrival_PredicateSkipsOnlyTheRelItNames(t *testing.T) {
	d := deferredFile{Size: 10, Chunks: []string{"c0"}}
	stored := map[string]deferredFile{"DCIM/a.jpg": d, "DCIM/b.jpg": d}
	dest := t.TempDir()

	got := newlyArrivedDeferred(stored, nil, dest, func(rel string) bool { return rel == "DCIM/a.jpg" })
	if want := []string{"DCIM/b.jpg"}; !reflect.DeepEqual(got, want) {
		t.Errorf("with a predicate naming a.jpg got %v, want %v", got, want)
	}
	got = newlyArrivedDeferred(stored, nil, dest, nil)
	if want := []string{"DCIM/a.jpg", "DCIM/b.jpg"}; !reflect.DeepEqual(got, want) {
		t.Errorf("with a nil predicate got %v, want %v", got, want)
	}
}
