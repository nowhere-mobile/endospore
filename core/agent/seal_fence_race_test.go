package main

import (
	"sync"
	"testing"
)

// NWP-20261011-79: direct writers can report a fence refusal without owning a
// bracket. Its verdict and resets must still synchronize with those writers.
// This deliberately does not assert whose refusal a bracket observes: routing
// the remaining direct writers through brackets is separate work (backlog §D).
func TestSealFenceRefusalConcurrentVerdict(t *testing.T) {
	t.Setenv("GATEWAY_URL", "") // capWrite's direct-mode arm; no network I/O
	sealExpectMu.Lock()
	oldFence, oldStale := sealFenceHit, sealStaleHit
	sealExpectMu.Unlock()
	t.Cleanup(func() {
		sealExpectMu.Lock()
		sealFenceHit, sealStaleHit = oldFence, oldStale
		sealExpectMu.Unlock()
	})

	const iterations = 64
	start := make(chan struct{})
	var writers sync.WaitGroup
	for i := 0; i < 4; i++ {
		writers.Add(1)
		go func() {
			defer writers.Done()
			<-start
			for j := 0; j < iterations; j++ {
				noteSealFenceRefusal("race-test", "ref/synthetic")
			}
		}()
	}
	close(start)
	for i := 0; i < iterations; i++ {
		capWrite("", "", nil, func() {}) // reset and capVerdictNow under a real bracket
	}
	writers.Wait()

	v := capWrite("", "", nil, func() {
		noteSealFenceRefusal("race-test", "ref/synthetic")
	})
	if !v.FenceHit || !v.Refused() {
		t.Fatalf("fence refusal missing from verdict: %+v", v)
	}
	if v := capWrite("", "", nil, func() {}); v.FenceHit {
		t.Fatal("next bracket inherited the fence refusal")
	}
}
