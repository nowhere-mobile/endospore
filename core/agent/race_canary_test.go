//go:build racecanary

package main

import (
	"sync"
	"testing"
)

// raceCanaryShared is written and read with no synchronisation, on purpose.
var raceCanaryShared int

// TestRaceCanary exists only to prove -race is live: test-race.sh runs it as a CONTROL and requires the detector to
// report this race. It never builds without the racecanary tag, so `go test ./...` and `go vet ./...` never see it.
func TestRaceCanary(t *testing.T) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			raceCanaryShared = i
		}
	}()
	go func() {
		defer wg.Done()
		seen := 0
		for i := 0; i < 1000; i++ {
			seen += raceCanaryShared
		}
		t.Log("canary read total", seen)
	}()
	wg.Wait()
}
