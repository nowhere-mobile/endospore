package main

import (
	"fmt"
	"os"
	"time"
)

// NWP-20261120-01 (docs/backlog.md §B, "An odrestore the daemon gave up on keeps the roamd worker, ..."; decided
// 2026-11-01 in docs/product-decisions.md, "a worker op the login daemon has given up on is stopped ..."): when
// runWorkerHeld gave up on an odrestore, its roamd instance ran on, and every later op on the lane answered
// workerBusy until it ended (NWP-20261022-02's guard). On frankel one app's restore ran about 3.5 min: from the
// 150 s give-up on, every periodic seal and the sign-out's cutoff, sweepmedia and cutoffwake answered
// ERR-WORKER-BUSY, and the sign-out refused. Now the give-up sends ctl.stop for the lane and waits a bounded time
// for init to stop it. The abandoned record stays, so the next op still discards whatever the stopped instance
// left in $RES. A stop is safe for odrestore since NWP-20261119-09: roamd drops a volume's hold only after the
// copy, the reown and the relabel, so a kill at any point leaves the hold for the next tap or Auto sweep.

// workerStopSamples bounds stopAbandonedWorker's wait for init: this many workerState samples, one per workerTick
// (20 at 500 ms = 10 s). A package var so worker_stop_test.go can set it.
var workerStopSamples = 20

// stopOnGiveUp reports whether runWorkerHeld stops the instance of an op it gave up on. Only "odrestore": the
// 2026-11-01 decision names it, and a restore nobody waits for keeps its hold and is retried at the next tap or
// Auto sweep. A seal (`out`) or a sign-in (`in`) is never stopped here: whether any other op is stopped is h50 #2,
// still open with Chester, so those lanes answer busy until the instance ends, as before.
func stopOnGiveUp(op string) bool {
	return op == "odrestore"
}

// stopAbandonedWorker sends ctl.stop for lane's service and waits, at most workerStopSamples samples, for init to
// report it stopped. It reads the state as runWorkerHeld's busy guard does: anything but running, stopping or
// restarting (an empty value or a failed getprop included) is stopped. The caller holds lane.slot, so no request
// can be published while the instance stops. On an image without the ctl.stop$nowhere_roamd label init refuses the
// setprop, this logs that the op did not stop, and the lane answers busy until it ends, as before this slice.
func stopAbandonedWorker(lane workerLane, op string) {
	workerStop(lane.svc)
	for i := 0; i < workerStopSamples; i++ {
		time.Sleep(workerTick)
		switch workerState(lane.svc) {
		case "running", "stopping", "restarting":
			continue
		}
		fmt.Fprintf(os.Stderr, "[logind] worker lane %s: stopped the %s op this daemon gave up on (2026-11-01)\n", lane.svc, op)
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] worker lane %s: the %s op did not stop within %d samples -- the lane answers busy until it ends\n",
		lane.svc, op, workerStopSamples)
}
