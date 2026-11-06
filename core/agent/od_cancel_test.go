package main

import (
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// NWP-20261109-11 (Q116): a sign-out cancels MATERIALIZE-APP's download at its next safe point, between chunks.
// roamd names the marker in NOWHERE_OD_CANCEL; these tests plant it themselves.

// odCancelFresh gives the test a store whose blobs no earlier test believed present: the fixture fixes the profile
// name, and the blob and content caches are keyed by its DK.
func odCancelFresh(t *testing.T) odFetchFixture {
	t.Helper()
	blobCache, contentCache = nil, nil
	return odFetchSetup(t, newHTTPStore(t))
}

// C1: the marker lands during the 2nd fetch of a one-worker window, so the writer stops at the next chunk.
func TestOdCancelStopsBetweenChunks(t *testing.T) {
	f := odCancelFresh(t)
	t.Setenv("NOWHERE_DOWNLOAD_WORKERS", "1")
	marker := filepath.Join(t.TempDir(), "od-cancel")
	t.Setenv("NOWHERE_OD_CANCEL", marker)
	var fetched int32
	swapFetch(t, func(old func(string, []byte, int, string) ([]byte, error), base string, key []byte, v int, h string) ([]byte, error) {
		if atomic.AddInt32(&fetched, 1) == 2 {
			if err := os.WriteFile(marker, nil, 0o600); err != nil {
				t.Errorf("planting the marker: %v", err)
			}
		}
		return old(base, key, v, h)
	})
	_, err := restoreAppCode(f.base, f.name+"#apps", f.pass, "com.big", t.TempDir())
	if !errors.Is(err, errMaterializeCancelled) {
		t.Fatalf("restoreAppCode = %v, want an error wrapping errMaterializeCancelled", err)
	}
	if n := int(atomic.LoadInt32(&fetched)); n > 3 || n >= len(f.chunks) {
		t.Fatalf("%d chunks fetched after the marker appeared during the 2nd of %d; the cut must fall between chunks (at most 3)", n, len(f.chunks))
	}
}

// C2: a marker already present fetches nothing, not even the read caps.
func TestOdCancelBeforeTheFirstFetch(t *testing.T) {
	f := odCancelFresh(t)
	marker := filepath.Join(t.TempDir(), "od-cancel")
	if err := os.WriteFile(marker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_OD_CANCEL", marker)
	var fetched int32
	swapFetch(t, func(old func(string, []byte, int, string) ([]byte, error), base string, key []byte, v int, h string) ([]byte, error) {
		atomic.AddInt32(&fetched, 1)
		return old(base, key, v, h)
	})
	_, err := restoreAppCode(f.base, f.name+"#apps", f.pass, "com.big", t.TempDir())
	if !errors.Is(err, errMaterializeCancelled) {
		t.Fatalf("restoreAppCode = %v, want an error wrapping errMaterializeCancelled", err)
	}
	if n := atomic.LoadInt32(&fetched); n != 0 {
		t.Fatalf("%d chunks fetched with the marker already present, want 0", n)
	}
}

// C3: the env var names a path that does not exist -- no sign-out, the set restores whole.
func TestOdCancelMarkerAbsentRestoresWhole(t *testing.T) {
	f := odCancelFresh(t)
	t.Setenv("NOWHERE_OD_CANCEL", filepath.Join(t.TempDir(), "od-cancel"))
	dest := t.TempDir()
	n, err := restoreAppCode(f.base, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
}

// C4: the env var unset -- the CLI run by anything but roamd -- restores whole.
func TestOdCancelUnsetRestoresWhole(t *testing.T) {
	f := odCancelFresh(t)
	t.Setenv("NOWHERE_OD_CANCEL", "")
	os.Unsetenv("NOWHERE_OD_CANCEL")
	dest := t.TempDir()
	n, err := restoreAppCode(f.base, f.name+"#apps", f.pass, "com.big", dest)
	f.check(t, dest, n, err)
}
