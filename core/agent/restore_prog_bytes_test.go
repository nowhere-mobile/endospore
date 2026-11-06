package main

import "testing"

// NWP-20260901-19: cdcRestore reports BYTES, not chunk indices. The first 0.5.12 install rendered
// "10 B of 1 KB" for a 1.8 GB payload because the progress file carried chunk counts and the OTA screen
// byte-rendered them -- the NWP-20260828-07 defect class, inherited exactly as the #145 review warned.
// This pins the ladder the fix is built on.
func TestChunkByteProgress(t *testing.T) {
	m := chunkManifest{
		Chunks: []string{"a", "b", "c"},
		Sizes:  []int64{100, 250, 4096},
	}
	cum, sum := chunkByteProgress(m)
	if cum == nil || sum != 4446 {
		t.Fatalf("chunkByteProgress = (%v, %d), want ladder with sum 4446", cum, sum)
	}
	want := []int64{100, 350, 4446}
	for i, w := range want {
		if cum[i] != w {
			t.Errorf("cum[%d] = %d, want %d", i, cum[i], w)
		}
	}
	// The last rung MUST equal the total, or the bar never reaches 100%.
	if cum[len(cum)-1] != sum {
		t.Errorf("final rung %d != sum %d", cum[len(cum)-1], sum)
	}
}

// Every degenerate manifest falls back to (nil, 0) -- chunk counts -- rather than a wrong ladder. A wrong
// byte figure is worse than a count: the count is only ugly, the wrong bytes are a lie about progress.
func TestChunkByteProgressFallsBack(t *testing.T) {
	cases := []struct {
		name string
		m    chunkManifest
	}{
		{"legacy: no Sizes", chunkManifest{Chunks: []string{"a", "b"}}},
		{"length mismatch", chunkManifest{Chunks: []string{"a", "b"}, Sizes: []int64{10}}},
		{"negative size (corrupt)", chunkManifest{Chunks: []string{"a"}, Sizes: []int64{-5}}},
		{"all zero", chunkManifest{Chunks: []string{"a"}, Sizes: []int64{0}}},
		{"empty manifest", chunkManifest{}},
	}
	for _, c := range cases {
		if cum, sum := chunkByteProgress(c.m); cum != nil || sum != 0 {
			t.Errorf("%s: chunkByteProgress = (%v, %d), want (nil, 0)", c.name, cum, sum)
		}
	}
}
