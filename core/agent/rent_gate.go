package main

import "sync"

// The rent gate (NWP-20261026-12). maybePayRent spends tokens and rewrites wallet.json outside the RW slot, after a
// periodic seal has released its announce, so it could land between END-UNSAVED's or RESTART-UNSAVED's durable wallet
// save and the end of the session: the saved wallet then lists tokens the gateway has already spent.
// The gate guarantees: no spend starts after an unsaved exit has begun its wallet save, and no exit saves the wallet
// while a spend is running. Both sides try and never wait: a refused spend is skipped (the next cycle renews), a
// refused exit answers BUSY.
var (
	rentMu       sync.Mutex
	rentInFlight int  // maybePayRent calls between beginRent and endRent
	rentExitHold bool // an unsaved exit is between holdRentForExit and releaseRent
)

// beginRent admits one spend. restartPending is asked FIRST and outside rentMu: it takes restartMu, which is never
// nested under rentMu.
func beginRent() bool {
	if restartPending() {
		return false
	}
	rentMu.Lock()
	defer rentMu.Unlock()
	if rentExitHold {
		return false
	}
	rentInFlight++
	return true
}

// endRent closes a spend beginRent admitted.
func endRent() {
	rentMu.Lock()
	if rentInFlight > 0 {
		rentInFlight--
	}
	rentMu.Unlock()
}

// holdRentForExit claims the gate for an unsaved exit; false while a spend is running.
func holdRentForExit() bool {
	rentMu.Lock()
	defer rentMu.Unlock()
	if rentInFlight > 0 {
		return false
	}
	rentExitHold = true
	return true
}

// releaseRent gives the gate back, on every return of the exit that held it.
func releaseRent() {
	rentMu.Lock()
	rentExitHold = false
	rentMu.Unlock()
}
