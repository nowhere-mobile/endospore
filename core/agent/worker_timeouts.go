package main

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
)

// worker_timeouts.go (NWP-20261204-16) -- the evidence for Q182 (docs/product-decisions.md, 2026-10-20, option (b))
// and the backlog row "The #83 lost-start race fires ROUTINELY". roam_lost_starts says how many lost starts were
// re-fired; it cannot say whether any op was LOST, nor whether an expired op's request was ever read. These counts
// can, and an issue report carries them as status roam_worker_timeouts and roam_lost_starts_by_op.
//
// What each count means:
//   - n: the ERR-TIMEOUT expiries of runWorkerHeld, its stall exit and its hardCap exit both (timedOut).
//   - unconsumed: the expiries where the request file was still there at the expiry, so no worker read the request.
//     The residual the row names -- an instance that ignored the start and never exits, so the request is never
//     read -- is an expiry with unconsumed counted, and usually with after_lost_start=0, because the service never
//     read "stopped" and nothing was re-fired.
//   - after_lost_start: the expiries that followed a lost-start re-fire of the same op: a re-fired start that still
//     brought no answer.
//   - an expiry with the request consumed (n minus unconsumed) is a worker that read the request and then hung or died.
//   - ops / lostStartsByOp: the same expiries, and noteLostStart's re-fires, counted by op.
//
// The counts live for the DAEMON's lifetime, like roamLostStarts: they reset with the daemon, so a reader reads them
// against the report's boot_id and uptime_s. The values are fixed op words and integers -- an op that is not a fixed
// word (opTokenRe) is counted as "other" when it is recorded -- with no uid and no profile, so they are safe at gate
// scope and skip statusValue, like conf_ring_keys.

var (
	workerTimeoutsMu sync.Mutex
	workerTimeouts   struct {
		n, afterLostStart, unconsumed int64
		byOp                          map[string]int64
	}
	lostStartsByOp = map[string]int64{}
)

// opListCap bounds each by-op list; the keys past it are summed as one "+<k>" item.
const opListCap = 12

var opTokenRe = regexp.MustCompile(`^[a-z0-9-]{1,24}$`)

// opToken returns op when it is a fixed op word, else "other".
func opToken(op string) string {
	if opTokenRe.MatchString(op) {
		return op
	}
	return "other"
}

// noteWorkerTimeout records one ERR-TIMEOUT expiry of op: afterLostStart when this op was re-fired as a lost start,
// unconsumed when its request file was still there at the expiry.
func noteWorkerTimeout(op string, afterLostStart, unconsumed bool) {
	workerTimeoutsMu.Lock()
	defer workerTimeoutsMu.Unlock()
	workerTimeouts.n++
	if afterLostStart {
		workerTimeouts.afterLostStart++
	}
	if unconsumed {
		workerTimeouts.unconsumed++
	}
	if workerTimeouts.byOp == nil {
		workerTimeouts.byOp = map[string]int64{}
	}
	workerTimeouts.byOp[opToken(op)]++
}

// noteLostStartOp records one lost-start re-fire of op in the per-op count (called by noteLostStart).
func noteLostStartOp(op string) {
	workerTimeoutsMu.Lock()
	defer workerTimeoutsMu.Unlock()
	lostStartsByOp[opToken(op)]++
}

// workerTimeoutsValue is status roam_worker_timeouts: `n=<n> after_lost_start=<n> unconsumed=<n> ops=<op>:<n>,...`.
func workerTimeoutsValue() string {
	workerTimeoutsMu.Lock()
	defer workerTimeoutsMu.Unlock()
	return fmt.Sprintf("n=%d after_lost_start=%d unconsumed=%d ops=%s", workerTimeouts.n, workerTimeouts.afterLostStart,
		workerTimeouts.unconsumed, opCountList(workerTimeouts.byOp, ",", ":"))
}

// lostStartsByOpValue is status roam_lost_starts_by_op: `<op>=<n> ...`.
func lostStartsByOpValue() string {
	workerTimeoutsMu.Lock()
	defer workerTimeoutsMu.Unlock()
	return opCountList(lostStartsByOp, " ", "=")
}

// opCountList renders m as `<op><kv><n>` items joined by sep, ops sorted, at most opListCap items and then `+<k>` for
// the k ops left out; "none" when m is empty. The caller holds workerTimeoutsMu.
func opCountList(m map[string]int64, sep, kv string) string {
	if len(m) == 0 {
		return "none"
	}
	ops := make([]string, 0, len(m))
	for op := range m {
		ops = append(ops, op)
	}
	sort.Strings(ops)
	items := make([]string, 0, opListCap+1)
	for i, op := range ops {
		if i == opListCap {
			items = append(items, fmt.Sprintf("+%d", len(ops)-opListCap))
			break
		}
		items = append(items, fmt.Sprintf("%s%s%d", op, kv, m[op]))
	}
	return strings.Join(items, sep)
}
