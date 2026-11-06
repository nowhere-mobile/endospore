package main

import "time"

// NWP-20261115-06: capFlush's GATEWAY LEG REPORTS PROGRESS, one line before each /lease request.
//
// capFlush writes `save 0 <total>` and then nothing until uploadBlobs' first PUT lands. Between them run the quote
// and the lease, which goes in batches of leaseBatchRefs refs (Q090): a 100k-chunk #media flush is 7 requests per
// arm, ~45 s each at the measured 2.6-2.83 ms/ref. runWorkerHeld answers ERR-TIMEOUT after roamStallBudget with no
// CHANGE in roam.progress, so a working seal was declared stalled and kept running unsupervised while the user's Log
// off was refused. Device-observed on lynx 2026102201: `save 0 60184949 media` held for ~5 min, then `HELD the slot
// 345407ms` and ERR-TIMEOUT; the large-profile sign-in row records the same pushes failing IN the lease
// (`cap-flush free lease: HTTP 500`, and `upload 4m55s` before `cap-flush entitled lease: HTTP 500`).
//
// WHY "sizes". It is the unit-less phase: every gate reader draws a "sizes" frame without byte text, as roamd's
// `_apps_stage_prog` uses it. ProfileActivity's sign-out screen draws it as "Preparing <scope>…" and Back up now as
// "Backing up <scope>…", both from the fraction alone, so neither shows byte text during the lease leg and both
// show it again from the first PUT. A count of requests under "save" would be drawn as bytes.
//
// WHY THIS LIVES OUTSIDE main.go. core/vendor-common/bin/test-progress-units.sh reads main.go's FIRST
// `setProgPhase("sizes")` and FIRST `setProgPhase(prevPhase)` (head -1). capFlush comes before pushProfile's sizes
// block, so a literal in capFlush would become the line that suite checks. main.go only calls newLeaseProg, add,
// before and during.
//
// THE HEARTBEAT (NWP-20261117-10). One full batch (leaseBatchRefs refs) has a deadline of leaseBudget(16384) =
// 193.84 s, above roamStallBudget, so a request that answers inside its own deadline could still starve the
// watchdog. during runs each /lease request with a heartbeat beside it: every leaseBeat the heartbeat writes the
// lease leg's line again as "sizes <d*m> <t*m>", m = 2, 3, ... The stall rule needs a CHANGED line, and the gate
// draws its bar from the FRACTION, so the beat scales both numbers: the line changes and the bar does not move.
// (d, t) is the line before wrote when ON; OFF, it is (1, 1), so a slow one-batch flush beats "sizes 2 2",
// "sizes 3 3", ... A request that answers within one leaseBeat writes nothing new. during stops the heartbeat and
// waits for it to exit before the caller goes on, so no beat follows the reply or lands among the upload's lines.
//
// THE RESIDUAL, PLAINLY: each request's start and every leaseBeat while it runs now write. What remains is a request
// that reaches its own deadline (leaseBudget, at most gwLeaseMax): it fails, and the seal reports it.

// leaseProg is one flush's lease-leg progress. It is ON only when the flush's refs need more than one /lease
// request; OFF, it writes nothing, so a flush that fits one batch writes exactly what it wrote before.
type leaseProg struct {
	on          bool
	done, total int // done: lease requests this flush has started; total: requests planned so far, never below done
}

// newLeaseProg decides ON once, from the flush's refs, before its first lease request (whichever arm sends it).
func newLeaseProg(refs map[string]int64) *leaseProg {
	return &leaseProg{on: len(leaseBatches(refs, leaseBatchRefs)) > 1}
}

// add plans n more lease requests.
func (p *leaseProg) add(n int) {
	if p.on {
		p.total += n
	}
}

// before writes one "sizes <done> <total>" line (writeProg appends the scope) just before a /lease request, then
// restores the phase, so the upload's lines stay "save" with their byte text. The lease leg runs in one goroutine
// and no other progPhase writer runs during it, so the save and restore need no lock.
func (p *leaseProg) before() {
	if !p.on {
		return
	}
	p.done++
	if p.total < p.done {
		p.total = p.done
	}
	prev, _ := progPhase.Load().(string)
	setProgPhase("sizes")
	writeProg(p.done, p.total)
	setProgPhase(prev)
}

// leaseBeat is how often a /lease request in flight writes its lease-leg line again. Tests shrink it.
var leaseBeat = 30 * time.Second

// leaseBeatTicker is the heartbeat's tick source, hoisted (as logoffStallTicker) so a test can step it by hand. It
// returns the tick channel and its stop. Production never assigns it.
var leaseBeatTicker = func(d time.Duration) (<-chan time.Time, func()) {
	t := time.NewTicker(d)
	return t.C, t.Stop
}

// during runs one /lease request with the heartbeat beside it. It stops the heartbeat and waits for it to exit
// before it returns, also when req panics. The request's own deadline (leaseBudget) bounds both.
func (p *leaseProg) during(req func()) {
	stop := p.heartbeat()
	defer stop()
	req()
}

// heartbeat starts the beat goroutine and returns its stop, which ends the goroutine and waits for its exit. Beat m
// (m = 2, 3, ...) writes "sizes <d*m> <t*m>" and restores the phase, as before does. While the request runs, the
// caller goroutine is blocked in it and writes no progress, so the save and restore need no lock.
func (p *leaseProg) heartbeat() func() {
	d, t := 1, 1
	if p.on {
		d, t = p.done, p.total
	}
	tick, stopTick := leaseBeatTicker(leaseBeat)
	quit, exited := make(chan struct{}), make(chan struct{})
	goSafe("lease heartbeat", func() {
		defer close(exited)
		defer stopTick()
		for m := 2; ; m++ {
			select {
			case <-quit:
				return
			case <-tick:
			}
			select { // a tick and the stop together: the stop wins, so no beat follows the reply
			case <-quit:
				return
			default:
			}
			prev, _ := progPhase.Load().(string)
			setProgPhase("sizes")
			writeProg(d*m, t*m)
			setProgPhase(prev)
		}
	})
	return func() { close(quit); <-exited }
}
