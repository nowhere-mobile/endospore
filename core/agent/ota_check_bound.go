package main

// NWP-20261120-05: bound the OTA check's ATTEMPT, not only its retries. capGetRetryWindow bounds when a retry may
// START; one attempt can still cost 2 x 30 s on the gateway plus 60 s on the object store (the budget comment above
// capGetRetryWindow). refreshOtaCache recorded otaLastTry / otaLastErr only when otaCheck returned, so with no network
// a refresh ran far past the chooser's waits: OTA-VERSIONS' tried_ms never moved and OTA-STATUS answered "checking".
// Both screens then said "The update service is slow to answer", never "Couldn't check for updates".
//
// The interim marker records "unreachable" while a refresh has had no store answer for otaCheckInterimBound, and
// OTA-STATUS answers "UNKNOWN unreachable" for a refresh past its bound. The refresh itself is not stopped: its late
// answer still lands through refreshOtaCache's outcome writes, unchanged.

import (
	"fmt"
	"os"
	"time"
)

// otaCheckInterimBound is how long a refresh may run with no store answer before it reads as unreachable.
//
// 10 s, because the open path (ChooserActivity doCheck) settles in about 15 s (6 re-polls of 2.5 s), so the mark
// lands before its last read and the screen says "Couldn't check for updates".
// The tap path still answers at its 30 s cap: OtaCheckWait waits for refreshing 0 or the cap, and the chooser is not
// changed. The re-marks move tried_ms, so at the cap it reads a failed check, not TIMEOUT.
// A slow but working store reads "couldn't check" from the bound until its answer lands; that answer then replaces it.
// time.After is monotonic, which is right here: this is an awake screen's wait, not a wait across a suspend
// (compare sleepUntilWall).
var otaCheckInterimBound = 10 * time.Second

// All under otaCacheMu.
var (
	otaRefreshGen  uint64 // bumped by each refresh that has a store to ask, so the first is 1
	otaRefreshOpen uint64 // the generation whose outcome is not recorded yet (0 = none)
	otaInterimGen  uint64 // the generation the marker last marked (0 = none)
)

// otaInterimMark marks refresh gen as unreachable at each otaCheckInterimBound until done is closed or the
// generation's outcome is recorded. It re-marks at every bound, so a tap that joins a stuck refresh still sees
// tried_ms move. A stale marker (its generation no longer open) writes nothing and returns.
func otaInterimMark(gen uint64, done <-chan struct{}) {
	for {
		bound := otaCheckInterimBound
		select {
		case <-done:
			return
		case <-time.After(bound):
		}
		otaCacheMu.Lock()
		if otaRefreshOpen != gen {
			otaCacheMu.Unlock()
			return
		}
		otaLastTry, otaLastErr = time.Now().Round(0), "unreachable" // Round(0): the rule above otaCacheTTL
		first := otaInterimGen != gen
		otaInterimGen = gen
		otaCacheMu.Unlock()
		if first {
			// No URL and no error text: the attempt has not failed, it has only not answered.
			fmt.Fprintf(os.Stderr, "[ota] refresh: no store answer within %s; recorded unreachable while it keeps trying\n", bound)
		}
	}
}
