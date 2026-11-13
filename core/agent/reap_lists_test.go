package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261129-19 (h59 #11): CLEAN-STORAGE with no session live or parked removes a departed session's plaintext
// file-name lists from the state tmpfs, and (NWP-20261201-35, h60 #8) its content and group caches, sealcount and
// mnochange. Every test drives the real verb unless its comment says otherwise.

var reapListsGone = []string{
	"scancache.ab12", "scancache.ab12.tmp", "heal-handled-0123456789abcdef", "heal-handled-0123456789abcdef.tmp",
	"sealdelta.idx", "sealdelta.idx.tmp", "sealdelta.listed", "sealdelta.listed.tmp", "media-bg.list.handoff",
}

var reapListsStay = []string{
	"blobcache.x", "signin-summary.11", "xscancache.1", "xheal-handled-1", "xcontentcache.1", "xsealcount.1",
}

var reapCachesGone = []string{
	"contentcache.ab12", "groupcache.ab12", "groupcache.ab12.tmp", "sealcount.ab12", "mnochange.ab12", "mnochange.ab12.tmp",
}

const (
	reapListsKeptLine  = "[logind] reap: kept the session file lists and caches -- a session is live or parked (h59 #11, h60 #8)"
	reapListsDoneLine  = "[logind] reap: removed 9 session file list(s) from the state tmpfs (h59 #11)"
	reapCachesDoneLine = "[logind] reap: removed 6 session cache file(s) from the state tmpfs (h60 #8)"
)

// reapListsPlant writes every listed name into dest, plus the two shapes that must never be removed: an EMPTY
// directory with a matching name (os.Remove would take it) and a symlink with a matching name.
func reapListsPlant(t *testing.T, dest string) (symlinkTarget string) {
	t.Helper()
	for _, set := range [][]string{reapListsGone, reapCachesGone, reapListsStay} {
		for _, n := range set {
			plantFile(t, dest, n)
		}
	}
	for _, d := range []string{"scancache.d", "groupcache.d"} {
		if err := os.Mkdir(filepath.Join(dest, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	symlinkTarget = plantFile(t, t.TempDir(), "target")
	for _, l := range []string{"heal-handled-link", "mnochange.link"} {
		if err := os.Symlink(symlinkTarget, filepath.Join(dest, l)); err != nil {
			t.Fatal(err)
		}
	}
	return symlinkTarget
}

func reapListsExists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// reapListsCheckRemoved says the lists and the caches are gone and that everything else is still there.
func reapListsCheckRemoved(t *testing.T, dest, target string) {
	t.Helper()
	for _, set := range [][]string{reapListsGone, reapCachesGone} {
		for _, n := range set {
			if reapListsExists(filepath.Join(dest, n)) {
				t.Errorf("%s is still on the state tmpfs after the reap", n)
			}
		}
	}
	reapListsCheckOthers(t, dest, target)
}

func reapListsCheckOthers(t *testing.T, dest, target string) {
	t.Helper()
	for _, n := range reapListsStay {
		if !reapListsExists(filepath.Join(dest, n)) {
			t.Errorf("the reap removed %s, which is not a session file list or cache", n)
		}
	}
	for _, d := range []string{"scancache.d", "groupcache.d"} {
		if fi, err := os.Lstat(filepath.Join(dest, d)); err != nil || !fi.IsDir() {
			t.Errorf("the reap removed the directory %s (%v)", d, err)
		}
	}
	for _, l := range []string{"heal-handled-link", "mnochange.link"} {
		if fi, err := os.Lstat(filepath.Join(dest, l)); err != nil || fi.Mode()&os.ModeSymlink == 0 {
			t.Errorf("the reap removed the symlink %s (%v)", l, err)
		}
	}
	if !reapListsExists(target) {
		t.Errorf("the reap removed the target of the symlinks")
	}
}

// reapListsCheckAllKept says the reap removed nothing at all.
func reapListsCheckAllKept(t *testing.T, dest, target string) {
	t.Helper()
	for _, set := range [][]string{reapListsGone, reapCachesGone} {
		for _, n := range set {
			if !reapListsExists(filepath.Join(dest, n)) {
				t.Errorf("the reap removed %s although it must keep every list and cache", n)
			}
		}
	}
	reapListsCheckOthers(t, dest, target)
}

// reapListsDrive sends CLEAN-STORAGE <uid> and returns the [logind] reap: lines it logged. setup runs after the
// fixture, because the fixture points androidUsersDir at an empty directory, where every user reads as gone.
func reapListsDrive(t *testing.T, uid string, setup func(dest string)) (dest, target string, lines []string) {
	t.Helper()
	gatePeer(t, 10123)
	f, _, _ := gateOnlyFixture(t, "CLEAN-STORAGE", []abPlan{{lane: laneRW, text: "OK"}})
	target = reapListsPlant(t, f.dest)
	if setup != nil {
		setup(f.dest)
	}
	stop := memoCapture(t)
	reply, _, answered := gateOnlyDrive(t, f.dest, "CLEAN-STORAGE", uid+"\n", 10*time.Second)
	waitGateOnly(t)
	logged := stop()
	if !answered || reply != "OK" {
		t.Fatalf("CLEAN-STORAGE %s answered %q (answered=%v), want OK", uid, reply, answered)
	}
	for _, l := range strings.Split(logged, "\n") {
		if strings.HasPrefix(l, "[logind] reap: ") {
			lines = append(lines, l)
		}
	}
	return f.dest, target, lines
}

// reapListsSeedIdxCache says the walk has written its index, and restores the cache when the test ends.
func reapListsSeedIdxCache(t *testing.T) {
	t.Helper()
	x := &sealDeltaIdxCache
	x.mu.Lock()
	oldName, oldAt, oldOK := x.name, x.at, x.ok
	x.name, x.at, x.ok = "reaplists-idx", time.Now(), true
	x.mu.Unlock()
	t.Cleanup(func() {
		x.mu.Lock()
		x.name, x.at, x.ok = oldName, oldAt, oldOK
		x.mu.Unlock()
	})
}

func reapListsIdxCacheOK() bool {
	x := &sealDeltaIdxCache
	x.mu.Lock()
	defer x.mu.Unlock()
	return x.ok
}

// L1: no session. The lists and the caches go; blobcache.*, the unrelated files, a directory and a symlink stay.
func TestReapLists_L1_NoSessionRemovesTheLists(t *testing.T) {
	dest, target, _ := reapListsDrive(t, "11", nil)
	reapListsCheckRemoved(t, dest, target)
}

// L1b: the usual reap: the marker still names the gone user. The lists go too, so the call must follow
// clearMarkerOfGoneUser.
func TestReapLists_L1b_MarkerOfTheGoneUserIsClearedFirst(t *testing.T) {
	dest, target, _ := reapListsDrive(t, "11", func(dest string) {
		writeMarker(t, dest, "reaplists-l1b\npass\n11\n")
	})
	if reapListsExists(filepath.Join(dest, roamSessionFile)) {
		t.Errorf("the marker of gone user 11 is still there")
	}
	reapListsCheckRemoved(t, dest, target)
}

// L2: a marker in any state but absent is a session that still uses the lists.
func TestReapLists_L2_MarkerKeepsTheLists(t *testing.T) {
	for _, c := range []struct{ label, marker string }{
		{"complete marker of a live user", "reaplists-l2\npass\n11\n"},
		{"damaged marker", "reaplists-l2\n"},
	} {
		t.Run(c.label, func(t *testing.T) {
			reapListsSeedIdxCache(t)
			dest, target, lines := reapListsDrive(t, "12", func(dest string) {
				usersWith(t, "11")
				writeMarker(t, dest, c.marker)
			})
			reapListsCheckAllKept(t, dest, target)
			if len(lines) != 1 || lines[0] != reapListsKeptLine {
				t.Errorf("logged %q, want only %q", lines, reapListsKeptLine)
			}
			if !reapListsIdxCacheOK() {
				t.Errorf("a kept reap reset the walk's index cache: the live session's next walk does needless work")
			}
		})
	}
}

// L3: a parked cold lock still uses the lists, with no marker at all.
func TestReapLists_L3_ColdLockKeepsTheLists(t *testing.T) {
	dest, target, lines := reapListsDrive(t, "12", func(dest string) {
		plantFile(t, dest, ".coldlock")
	})
	reapListsCheckAllKept(t, dest, target)
	if len(lines) != 1 || lines[0] != reapListsKeptLine {
		t.Errorf("logged %q, want only %q", lines, reapListsKeptLine)
	}
}

// L4: uid 5 is not a roamed user: the n >= 10 guard leaves everything alone and says nothing.
func TestReapLists_L4_LowUidTouchesNothing(t *testing.T) {
	reapListsSeedIdxCache(t)
	dest, target, lines := reapListsDrive(t, "5", nil)
	reapListsCheckAllKept(t, dest, target)
	if len(lines) != 0 {
		t.Errorf("logged %q, want no reap line", lines)
	}
	if !reapListsIdxCacheOK() {
		t.Errorf("CLEAN-STORAGE 5 reset the walk's index cache")
	}
}

// L5: the walk's cache must not go on saying the removed index is written.
func TestReapLists_L5_ResetsTheWalkIndexCache(t *testing.T) {
	reapListsSeedIdxCache(t)
	reapListsDrive(t, "11", nil)
	if reapListsIdxCacheOK() {
		t.Errorf("sealDeltaIdxCache.ok is still true: the next walk skips the index the reap removed")
	}
}

// L6: each line is its fixed text. It holds counts only and names no file.
func TestReapLists_L6_LinesNameNoFile(t *testing.T) {
	_, _, removed := reapListsDrive(t, "11", nil)
	_, _, kept := reapListsDrive(t, "12", func(dest string) { plantFile(t, dest, ".coldlock") })
	if len(removed) != 2 || removed[0] != reapListsDoneLine || removed[1] != reapCachesDoneLine {
		t.Errorf("the reap logged %q, want only %q then %q", removed, reapListsDoneLine, reapCachesDoneLine)
	}
	if len(kept) != 1 || kept[0] != reapListsKeptLine {
		t.Errorf("the kept reap logged %q, want only %q", kept, reapListsKeptLine)
	}
	for _, l := range append(removed, kept...) {
		for _, n := range []string{"scancache", "heal-handled", "sealdelta", "contentcache", "groupcache", "sealcount", "mnochange", "ab12"} {
			if strings.Contains(l, n) {
				t.Errorf("the line %q names %s", l, n)
			}
		}
	}
}

// L7: a removal that fails is counted, and the line still names no file. This calls the function directly, because the
// read-only dest would also stop the fake worker. Root ignores the mode, so this skips under root.
func TestReapLists_L7_FailedRemovalIsCountedNeverNamed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores the directory mode")
	}
	dest := t.TempDir()
	plantFile(t, dest, "scancache.ab12")
	if err := os.Chmod(dest, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dest, 0o700) })
	stop := memoCapture(t)
	removed, kept := reapSessionLists(dest)
	logged := strings.TrimSpace(stop())
	if removed != 0 || kept {
		t.Errorf("removed=%d kept=%v, want 0 and false", removed, kept)
	}
	if want := "[logind] reap: removed 0 session file list(s) from the state tmpfs, 1 failed (h59 #11)\n" +
		"[logind] reap: removed 0 session cache file(s) from the state tmpfs (h60 #8)"; logged != want {
		t.Errorf("logged %q, want %q", logged, want)
	}
}

// L7b: a cache whose removal fails is counted in its own line, and no line names it. Root ignores the mode, as in L7.
func TestReapLists_L7b_FailedCacheRemovalIsCountedApart(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores the directory mode")
	}
	dest := t.TempDir()
	plantFile(t, dest, "contentcache.ab12")
	if err := os.Chmod(dest, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dest, 0o700) })
	stop := memoCapture(t)
	removed, kept := reapSessionLists(dest)
	logged := strings.TrimSpace(stop())
	if removed != 0 || kept {
		t.Errorf("removed=%d kept=%v, want 0 and false", removed, kept)
	}
	if want := "[logind] reap: removed 0 session file list(s) from the state tmpfs (h59 #11)\n" +
		"[logind] reap: removed 0 session cache file(s) from the state tmpfs, 1 failed (h60 #8)"; logged != want {
		t.Errorf("logged %q, want %q", logged, want)
	}
}

// L8: a reap beside a live or parked session keeps every cache (the residual decided in h62 #7), and says so.
func TestReapLists_L8_KeptReapKeepsEveryCache(t *testing.T) {
	for _, c := range []struct {
		label string
		setup func(t *testing.T, dest string)
	}{
		{"marker of a live user", func(t *testing.T, dest string) {
			usersWith(t, "11")
			writeMarker(t, dest, "reaplists-l8\npass\n11\n")
		}},
		{"parked cold lock", func(t *testing.T, dest string) { plantFile(t, dest, ".coldlock") }},
	} {
		t.Run(c.label, func(t *testing.T) {
			dest, _, lines := reapListsDrive(t, "12", func(dest string) { c.setup(t, dest) })
			for _, n := range reapCachesGone {
				if !reapListsExists(filepath.Join(dest, n)) {
					t.Errorf("a kept reap removed %s", n)
				}
			}
			if len(lines) != 1 || lines[0] != reapListsKeptLine {
				t.Errorf("logged %q, want only %q", lines, reapListsKeptLine)
			}
		})
	}
}

// reapListsSaveCaches empties the blob and content caches for the test and restores them when it ends.
func reapListsSaveCaches(t *testing.T) {
	t.Helper()
	oldBlob, oldContent, oldTag := blobCache, contentCache, contentCacheLoadedTag
	blobCache, contentCache, contentCacheLoadedTag = nil, nil, ""
	t.Cleanup(func() { blobCache, contentCache, contentCacheLoadedTag = oldBlob, oldContent, oldTag })
}

// L9: only a removal pass drops the in-memory content cache. A kept reap leaves it for the live session.
func TestReapLists_L9_RemovalResetsTheInMemoryContentCache(t *testing.T) {
	reapListsSaveCaches(t)
	const tag = "reaplists-l9"
	seed := func() { contentCache, contentCacheLoadedTag = map[string]string{"k": "v"}, tag }

	seed()
	reapSessionLists(t.TempDir())
	if contentCache != nil || contentCacheLoadedTag != "" {
		t.Errorf("after a removal pass contentCache=%v tag=%q, want nil and empty", contentCache, contentCacheLoadedTag)
	}

	seed()
	dest := t.TempDir()
	plantFile(t, dest, ".coldlock")
	reapSessionLists(dest)
	if contentCache["k"] != "v" || len(contentCache) != 1 || contentCacheLoadedTag != tag {
		t.Errorf("after a kept reap contentCache=%v tag=%q, want them unchanged", contentCache, contentCacheLoadedTag)
	}
}

// L10: the same profile signs in again after the reap in the same boot: its next save lands and the restore re-seeds
// the content cache. contentCache is NOT reset by hand before that save: the reap must have done it.
func TestReapLists_L10_NextSameProfileSignInStillSaves(t *testing.T) {
	reapListsSaveCaches(t)
	D := t.TempDir()
	t.Setenv("NOWHERE_BLOBCACHE", D)
	base := newHTTPStore(t)
	name, pass := "reaplists-l10", "reap lists horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	path := filepath.Join(src, "big.txt")
	big := bytes.Repeat([]byte("content-cache round trip 0123456789 abcdefghij\n"), 133861)
	if err := os.WriteFile(path, big, 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	m, _ := restoreManifest(t, base, name, pass)
	if len(m.Chunks) < 2 {
		t.Fatalf("expected several chunks, got %d", len(m.Chunks))
	}
	found, err := filepath.Glob(filepath.Join(D, "contentcache.*"))
	if err != nil || len(found) != 1 {
		t.Fatalf("the restore wrote content caches %q (%v), want exactly one", found, err)
	}
	tag := strings.TrimPrefix(filepath.Base(found[0]), "contentcache.")

	prefixes := []string{"contentcache.", "groupcache.", "sealcount.", "mnochange."}
	for _, prefix := range prefixes {
		if !reapListsExists(filepath.Join(D, prefix+tag)) {
			plantFile(t, D, prefix+tag)
		}
	}
	reapSessionLists(D)
	for _, prefix := range prefixes {
		if reapListsExists(filepath.Join(D, prefix+tag)) {
			t.Errorf("%s<tag> is still on the state tmpfs after the reap", prefix)
		}
	}

	// The leading chunks do not change, so only the reap's reset gets them written to the file again.
	big = append(big, []byte("one more line at the end of the file\n")...)
	if err := os.WriteFile(path, big, 0o600); err != nil {
		t.Fatal(err)
	}
	blobCache = nil
	pushProfile(base, name, pass, src)
	m2, dst := restoreManifest(t, base, name, pass)
	if got, err := os.ReadFile(filepath.Join(dst, "big.txt")); err != nil {
		t.Fatal(err)
	} else if !bytes.Equal(got, big) {
		t.Fatalf("the save after the reap did not land: restored %d B, want %d B", len(got), len(big))
	}
	b, err := os.ReadFile(filepath.Join(D, "contentcache."+tag))
	if err != nil {
		t.Fatalf("the restore did not write the content cache again: %v", err)
	}
	if n := bytes.Count(b, []byte("\n")); n < len(m2.Chunks) {
		t.Errorf("the content cache holds %d line(s), want at least %d: the restore did not re-seed it", n, len(m2.Chunks))
	}
}

// L11: the bound of the residual decided by h60 #7. Lists kept beside a live session go at the next reap with no
// session, and so does a list that session wrote after the kept reap. The second reap calls the function directly, as
// L7 does: the fixture answers one CLEAN-STORAGE.
func TestReapLists_L11_KeptListsGoAtTheNextReapWithNoSession(t *testing.T) {
	dest, target, lines := reapListsDrive(t, "12", func(dest string) {
		usersWith(t, "11")
		writeMarker(t, dest, "reaplists-l8\npass\n11\n")
	})
	reapListsCheckAllKept(t, dest, target)
	if len(lines) != 1 || lines[0] != reapListsKeptLine {
		t.Errorf("logged %q, want only %q", lines, reapListsKeptLine)
	}

	plantFile(t, dest, "scancache.l8")
	if err := os.Remove(filepath.Join(dest, roamSessionFile)); err != nil {
		t.Fatal(err)
	}
	removed, kept := reapSessionLists(dest)
	if want := len(reapListsGone) + 1; removed != want || kept {
		t.Errorf("removed=%d kept=%v, want %d and false", removed, kept, want)
	}
	if reapListsExists(filepath.Join(dest, "scancache.l8")) {
		t.Errorf("scancache.l8 is still on the state tmpfs after the reap with no session")
	}
	reapListsCheckRemoved(t, dest, target)
}
