package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261129-19 (h59 #11): CLEAN-STORAGE with no session live or parked removes a departed session's plaintext
// file-name lists from the state tmpfs. Every test drives the real verb unless its comment says otherwise.

var reapListsGone = []string{
	"scancache.ab12", "scancache.ab12.tmp", "heal-handled-0123456789abcdef", "heal-handled-0123456789abcdef.tmp",
	"sealdelta.idx", "sealdelta.idx.tmp", "sealdelta.listed", "sealdelta.listed.tmp",
}

var reapListsStay = []string{
	"blobcache.x", "contentcache.x", "groupcache.x", "signin-summary.11", "xscancache.1", "xheal-handled-1",
}

const (
	reapListsKeptLine = "[logind] reap: kept the session file lists -- a session is live or parked (h59 #11)"
	reapListsDoneLine = "[logind] reap: removed 8 session file list(s) from the state tmpfs (h59 #11)"
)

// reapListsPlant writes every listed name into dest, plus the two shapes that must never be removed: an EMPTY
// directory with a matching name (os.Remove would take it) and a symlink with a matching name.
func reapListsPlant(t *testing.T, dest string) (symlinkTarget string) {
	t.Helper()
	for _, set := range [][]string{reapListsGone, reapListsStay} {
		for _, n := range set {
			plantFile(t, dest, n)
		}
	}
	if err := os.Mkdir(filepath.Join(dest, "scancache.d"), 0o700); err != nil {
		t.Fatal(err)
	}
	symlinkTarget = plantFile(t, t.TempDir(), "target")
	if err := os.Symlink(symlinkTarget, filepath.Join(dest, "heal-handled-link")); err != nil {
		t.Fatal(err)
	}
	return symlinkTarget
}

func reapListsExists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// reapListsCheckRemoved says the lists are gone and that everything else is still there.
func reapListsCheckRemoved(t *testing.T, dest, target string) {
	t.Helper()
	for _, n := range reapListsGone {
		if reapListsExists(filepath.Join(dest, n)) {
			t.Errorf("%s is still on the state tmpfs after the reap", n)
		}
	}
	reapListsCheckOthers(t, dest, target)
}

func reapListsCheckOthers(t *testing.T, dest, target string) {
	t.Helper()
	for _, n := range reapListsStay {
		if !reapListsExists(filepath.Join(dest, n)) {
			t.Errorf("the reap removed %s, which is not a session file list", n)
		}
	}
	if fi, err := os.Lstat(filepath.Join(dest, "scancache.d")); err != nil || !fi.IsDir() {
		t.Errorf("the reap removed the directory scancache.d (%v)", err)
	}
	if fi, err := os.Lstat(filepath.Join(dest, "heal-handled-link")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the reap removed the symlink heal-handled-link (%v)", err)
	}
	if !reapListsExists(target) {
		t.Errorf("the reap removed the target of the symlink heal-handled-link")
	}
}

// reapListsCheckAllKept says the reap removed nothing at all.
func reapListsCheckAllKept(t *testing.T, dest, target string) {
	t.Helper()
	for _, n := range reapListsGone {
		if !reapListsExists(filepath.Join(dest, n)) {
			t.Errorf("the reap removed %s although it must keep every list", n)
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

// L1: no session. The lists go; the hash caches, the unrelated files, a directory and a symlink stay.
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
	if len(removed) != 1 || removed[0] != reapListsDoneLine {
		t.Errorf("the reap logged %q, want only %q", removed, reapListsDoneLine)
	}
	if len(kept) != 1 || kept[0] != reapListsKeptLine {
		t.Errorf("the kept reap logged %q, want only %q", kept, reapListsKeptLine)
	}
	for _, l := range append(removed, kept...) {
		for _, n := range []string{"scancache", "heal-handled", "sealdelta", "ab12"} {
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
	if want := "[logind] reap: removed 0 session file list(s) from the state tmpfs, 1 failed (h59 #11)"; logged != want {
		t.Errorf("logged %q, want %q", logged, want)
	}
}
