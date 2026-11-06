package main

import (
	"bytes"
	"testing"
)

// #108 P3: the offline-media budget splits a pinned app's large media between essential (kept offline, up to
// the budget, in stable walk order) and deferred (the over-budget excess, which streams on-demand). budget<=0
// means no cap. Un-pinned media is always deferred, regardless of budget.
func TestWalkChunksBudget(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_BLOBCACHE", "")
	blobCacheMu.Lock()
	blobCache = map[string]bool{}
	blobCacheMu.Unlock()

	dir := t.TempDir()
	blob := bytes.Repeat([]byte("M"), 8192) // 8 KiB each: >= MEDIA_MIN and >= threshold -> its own large-file region
	iwrite(t, dir, "app.maps/files/a.bin", blob)
	iwrite(t, dir, "app.maps/files/b.bin", blob)
	iwrite(t, dir, "app.maps/files/c.bin", blob)

	run := func(pins map[string]bool, budget int64) (essential, deferred int) {
		sc := newFileScanCache(make([]byte, 32))
		emit := func([]byte) int { return 0 }
		ranges, _, def, _, _, _, _, _ := walkChunks(dir, sc, 4096, true, ondemandMedia(), nil, nil, pins, nil, budget, emit, func(string) int { return 0 }, func(int64) {}, nil)
		return len(ranges), len(def)
	}
	pins := map[string]bool{"app.maps": true}

	cases := []struct {
		name         string
		pins         map[string]bool
		budget       int64
		wantE, wantD int
	}{
		{"no-pin -> all deferred", nil, 0, 0, 3},
		{"pinned, no cap -> all essential", pins, 0, 3, 0},
		{"pinned, 12KiB -> 1 kept, 2 stream", pins, 12 * 1024, 1, 2},
		{"pinned, 20KiB -> 2 kept, 1 streams", pins, 20 * 1024, 2, 1},
		{"pinned, huge -> all essential", pins, 1 << 30, 3, 0},
	}
	for _, c := range cases {
		if e, d := run(c.pins, c.budget); e != c.wantE || d != c.wantD {
			t.Errorf("%s: want %d essential/%d deferred, got %d/%d", c.name, c.wantE, c.wantD, e, d)
		}
	}
}
