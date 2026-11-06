package main

// NWP-20261113-27: the daemon's build-warning cache. refreshBuildWarning holds what the fetch returned (any error
// clears it), buildWarningAffects answers from memory with the expiry honoured, and refreshOtaCache refreshes it after
// every completed OTA check, whatever the offer.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// bwCacheTest gives the test its own floor path and an empty cache, and resets both when it ends.
func bwCacheTest(t *testing.T) int64 {
	t.Helper()
	old := buildWarningSeqPath
	buildWarningSeqPath = filepath.Join(t.TempDir(), "build-warning-seq")
	bwMu.Lock()
	bwCurrent = nil
	bwMu.Unlock()
	t.Cleanup(func() {
		buildWarningSeqPath = old
		bwMu.Lock()
		bwCurrent = nil
		bwMu.Unlock()
	})
	return int64(1_800_000_000)
}

func bwCacheWarning(now, expires int64) *buildWarning {
	return &buildWarning{Schema: 1, Seq: 1, Issued: now - 60, Expires: expires, Versions: []string{"0.5.45"}}
}

func TestBuildWarningCacheSetsAndClears(t *testing.T) {
	now := bwCacheTest(t)
	w := bwCacheWarning(now, now+3600)
	refreshBuildWarning(now, func() (*buildWarning, error) { return w, nil })
	if !buildWarningAffects("0.5.45", now) {
		t.Fatal("a cached warning for 0.5.45 does not affect 0.5.45")
	}
	if buildWarningAffects("0.5.46", now) {
		t.Fatal("a cached warning for 0.5.45 affects 0.5.46")
	}
	refreshBuildWarning(now, func() (*buildWarning, error) { return nil, errBuildWarningStore })
	if buildWarningAffects("0.5.45", now) {
		t.Fatal("a fetch error kept the previous warning: any error must mean no notice")
	}
	refreshBuildWarning(now, func() (*buildWarning, error) { return w, nil })
	refreshBuildWarning(now, func() (*buildWarning, error) { return nil, nil })
	if buildWarningAffects("0.5.45", now) {
		t.Fatal("nothing published kept the previous warning")
	}
}

func TestBuildWarningCacheHonoursExpiry(t *testing.T) {
	now := bwCacheTest(t)
	w := bwCacheWarning(now, now+10)
	refreshBuildWarning(now, func() (*buildWarning, error) { return w, nil })
	if !buildWarningAffects("0.5.45", now) || !buildWarningAffects("0.5.45", now+9) {
		t.Fatal("a warning before its expiry does not affect its version")
	}
	if buildWarningAffects("0.5.45", now+10) {
		t.Fatal("a warning at its expiry still affects its version")
	}
	refreshBuildWarning(now+10, func() (*buildWarning, error) { return w, nil })
	if buildWarningAffects("0.5.45", now) {
		t.Fatal("a warning already expired at the refresh was kept")
	}
}

func TestBuildWarningCacheNoStoreCall(t *testing.T) {
	now := bwCacheTest(t)
	n := 0
	refreshBuildWarning(now, func() (*buildWarning, error) { n++; return bwCacheWarning(now, now+3600), nil })
	for i := int64(0); i < 50; i++ {
		buildWarningAffects("0.5.45", now+i)
		buildWarningAffects("0.5.46", now+i*100)
	}
	if n != 1 {
		t.Fatalf("buildWarningAffects called the fetch: %d fetches after one refresh", n)
	}
}

func TestRefreshOtaCacheRefreshesBuildWarning(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	main := string(src)
	i := strings.Index(main, "func refreshOtaCache() {")
	if i < 0 {
		t.Fatal("refreshOtaCache is gone")
	}
	body := main[i:]
	body = body[:strings.Index(body, "\n}\n")]
	call := "\n\trefreshBuildWarning(time.Now().Unix(), func() (*buildWarning, error) { return fetchBuildWarning(\"s3\", time.Now().Unix()) })\n"
	gone := "fmt.Fprintln(os.Stderr, \"[ota] refresh: the store could not be reached; the last answer is kept\")"
	gate := "if latest != \"\" && avail {"
	for _, s := range []string{call, gone, gate} {
		if c := strings.Count(body, s); c != 1 {
			t.Fatalf("refreshOtaCache holds %q %d times, want once", strings.TrimSpace(s), c)
		}
	}
	if strings.Index(body, call) < strings.Index(body, gone) {
		t.Error("refreshOtaCache refreshes the build warning before the unreachable-store return")
	}
	if strings.Index(body, call) > strings.Index(body, gate) {
		t.Error("refreshOtaCache refreshes the build warning only when an update is offered")
	}
}
