package main

import (
	"fmt"
	"sync"
)

// NWP-20261204-21 (Q039, docs/product-decisions.md 2026-10-20): "the reap's longer hold on the next sign-in is measured
// first". The decision is accepted if the usual added time is near zero and 20 s shows only for a removal that is truly
// stuck; if it is often long, the reap's 20 s wait is shortened rather than the sign-out held longer.
//
// What the hold is made of: roamd's cleanstorage waits up to 80 polls (20 s) for the user's record to go, then up to
// 12 polls (3 s) past its last removal from users/<uid>, and 13 more polls, once, for a re-creation whose rm is refused.
// So one reap holds the RW lane for 20 s to about 30 s at worst. ge20s is the bucket the decision's acceptance reads.
//
// Why a histogram and not the log lines: triggerRoamWorkerKind writes "HELD the slot" only over 2 s, and both it and
// the "waited" line go to login.log, which a gate report excludes on purpose; the reap's own loop= field rides
// roam.log, which a gate report lacks too. Yet a reap runs at sign-out, so the report most likely to follow it is a
// gate one. These two values reach every report, the gate's included (buildIssueReportWith).
//
// The counts are since the DAEMON started, not since boot: read them against boot_id and uptime_s in the same report.
// Device-level integers only (no uid, no profile, no time), so they are safe at the gate, like roam_lost_starts. Not
// telemetry: a report leaves the phone only when the user sends it.

// holdHistogram is a bucketed count of millisecond durations under one mutex. Use it through its pointer methods only.
type holdHistogram struct {
	mu                                   sync.Mutex
	n, lt1s, s1to5, s5to20, ge20s, maxMs int64
}

// add counts one duration. A value equal to a boundary (1000, 5000, 20000 ms) goes UP. A negative value (a wall clock
// stepped back) is not a real hold, so it counts as 0.
func (h *holdHistogram) add(ms int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if ms < 0 {
		ms = 0
	}
	h.n++
	switch {
	case ms >= 20000:
		h.ge20s++
	case ms >= 5000:
		h.s5to20++
	case ms >= 1000:
		h.s1to5++
	default:
		h.lt1s++
	}
	if ms > h.maxMs {
		h.maxMs = ms
	}
}

// value is the report form: every key, always, in a fixed order.
func (h *holdHistogram) value() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return fmt.Sprintf("n=%d lt1s=%d 1to5s=%d 5to20s=%d ge20s=%d max_ms=%d", h.n, h.lt1s, h.s1to5, h.s5to20, h.ge20s, h.maxMs)
}

// reset zeroes every count (the tests use it).
func (h *holdHistogram) reset() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.n, h.lt1s, h.s1to5, h.s5to20, h.ge20s, h.maxMs = 0, 0, 0, 0, 0, 0
}

var (
	reapHold             holdHistogram // every cleanstorage op's RW-lane hold, ALL of them, not only the >2 s ones logged
	signinWaitBehindReap holdHistogram // the slot wait of each `in` op that, when it began to queue, found cleanstorage holding the RW lane
)
