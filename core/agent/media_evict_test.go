package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// #84 P5: mediaCacheCap is an OPTIONAL hard cap, default 0 (no cap -- free-space eviction governs); the env
// sets an explicit byte cap. mediaCacheFreeFloor is the free-space floor, default 2 GiB, env-overridable.
func TestMediaCacheCap(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "")
	if got := mediaCacheCap(); got != 0 {
		t.Fatalf("default cap = %d; want 0 (no hard cap)", got)
	}
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "1048576")
	if got := mediaCacheCap(); got != 1<<20 {
		t.Fatalf("env cap = %d; want %d", got, 1<<20)
	}
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "not-a-number")
	if got := mediaCacheCap(); got != 0 {
		t.Fatalf("garbage env should fall back to default (0), got %d", got)
	}

	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", "")
	if got := mediaCacheFreeFloor(); got != 2<<30 {
		t.Fatalf("default free floor = %d; want %d", got, 2<<30)
	}
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", "1048576")
	if got := mediaCacheFreeFloor(); got != 1<<20 {
		t.Fatalf("env free floor = %d; want %d", got, 1<<20)
	}
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", "0")
	if got := mediaCacheFreeFloor(); got != 0 {
		t.Fatalf("free floor 0 (disabled) = %d; want 0", got)
	}
}

// #84 P5: with an explicit hard cap, evictCache deletes the OLDEST COMPLETE entries first, while never
// touching a `.part`/`.have` pair (mid-fetch) or the `.under/` seal-bind subdir, and it self-throttles so a
// burst of post-fetch calls only scans once per window. (Free-space eviction disabled here so the test is
// deterministic regardless of the host fs's free space.)
func TestEvictCache(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_CACHE_MIN_FREE", "0") // isolate the hard-cap path from free-space pressure
	dir := t.TempDir()
	// Complete cache entries (dotless names = a cacheKey), 100 bytes each, staggered oldest->newest.
	plant := func(name string, n int, age time.Duration) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, make([]byte, n), 0o644); err != nil {
			t.Fatal(err)
		}
		mt := time.Now().Add(-age)
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
		return p
	}
	oldest := plant("aaaaaaaa", 100, 3*time.Hour)
	mid := plant("bbbbbbbb", 100, 2*time.Hour)
	newest := plant("cccccccc", 100, 1*time.Hour)
	// A range fetch in flight: a `.part`/`.have` pair. Must NOT be evicted (deleting it mid-write corrupts).
	part := plant("dddddddd.part", 100, 4*time.Hour) // older than everything -> would be first to go if eligible
	have := plant("dddddddd.have", 8, 4*time.Hour)
	// The seal-bind subdir with a file -- deleting through it would follow the bind into live app data (#92).
	under := filepath.Join(dir, ".under")
	if err := os.MkdirAll(under, 0o755); err != nil {
		t.Fatal(err)
	}
	underFile := filepath.Join(under, "bind-marker")
	if err := os.WriteFile(underFile, make([]byte, 100), 0o644); err != nil {
		t.Fatal(err)
	}

	// Cap = 250 bytes. Complete entries total 300 -> must evict the single oldest (aaaa, 100) to land at 200.
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "250")
	s := &mediaServer{cacheDir: dir}
	s.evictCache("")

	must := func(p string, want bool, msg string) {
		_, err := os.Stat(p)
		if (err == nil) != want {
			t.Fatalf("%s: exists=%v want=%v", msg, err == nil, want)
		}
	}
	must(oldest, false, "oldest complete entry should be evicted")
	must(mid, true, "mid entry should survive (under cap after one eviction)")
	must(newest, true, "newest entry should survive")
	must(part, true, ".part must never be evicted (mid-fetch)")
	must(have, true, ".have must never be evicted (mid-fetch)")
	must(underFile, true, ".under bind file must never be touched")

	// Throttle: a second immediate call must be a no-op even though we now push back over the cap.
	over := plant("eeeeeeee", 200, 30*time.Minute) // total complete now 400 > 250, but call is throttled
	s.evictCache("")
	must(over, true, "throttled call must not evict")
	must(mid, true, "throttled call must not evict mid")

	// Clear the throttle -> the next scan evicts oldest-first down to the cap again.
	s.lastEvict = time.Time{}
	s.evictCache("")
	// Remaining by age: mid(2h), newest(1h), over(30m). mid+newest+over = 400; evict mid=300, evict newest=200<=250.
	must(mid, false, "post-throttle: oldest remaining evicted")
	must(newest, false, "post-throttle: next-oldest evicted to reach cap")
	must(over, true, "post-throttle: newest (largest, freshest) survives")

	// No hard cap (0) + free-space disabled -> eviction is fully off: replant a big set, nothing is deleted.
	t.Setenv("NOWHERE_MEDIA_CACHE_MAX", "0")
	keep := plant("ffffffff", 5000, time.Hour)
	s.lastEvict = time.Time{}
	s.evictCache("")
	must(keep, true, "no cap + no free-floor must never evict")
}
