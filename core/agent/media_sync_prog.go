package main

// NWP-20261204-19: THE POST-SEAL MEDIA SYNC REPORTS PROGRESS, one frame per chunk it fetches.
//
// Backlog row: "The post-seal media sync writes no progress frame, so a periodic #media seal whose sync outlasts the
// 150 s stall budget is answered ERR-TIMEOUT while it runs on". pushProfile stops its progress ticker (stopProg)
// after the chunk loop. The sync that follows the head put (materializeCarried, then materializeDeferredArrivals)
// fetches up to deferredSyncBudget per tier and wrote nothing. runWorkerHeld answers ERR-TIMEOUT after
// roamStallBudget with no CHANGED frame in roam.progress, and stopOnGiveUp does not stop an `out` op, so the RW lane
// answered busy until the push ended.
//
// WHY PER CHUNK, NOT PER FILE. One file of the 64 MiB budget on a slow link takes longer than 150 s alone. A chunk is
// at most cdcMax (4 MiB), and the store's per-chunk GET deadlines bound the time one chunk takes, so a frame per
// chunk keeps the gap between two changed frames inside the stall budget.
//
// WHY "sizes". The numbers are chunk counts, not bytes. "sizes" is the unit-less phase: every gate reader draws it
// from the fraction alone, without byte text (lease_progress.go, "WHY sizes"). A count under "save" would be drawn
// as bytes.
//
// COUNTS ONLY. A frame is `sizes <chunks fetched> <chunks planned>` plus the scope writeProg appends. It holds no
// rel and no file name: a rel under Android/data names a package.
//
// NOTHING FETCHED, NOTHING WRITTEN. plan and chunk run only around a real fetch, after every skip check, so a cycle
// with no arrivals leaves roam.progress exactly as it was.
//
// WHY THIS LIVES OUTSIDE main.go. core/vendor-common/bin/test-progress-units.sh reads main.go's FIRST
// `setProgPhase("sizes")`. A literal in the sync block would come before pushProfile's sizes block and become the
// line that suite checks. main.go only makes a mediaSyncProg and passes it down.
//
// The sync runs in one goroutine after stopProg, and no other progPhase writer runs then, so the save and restore of
// the phase need no lock (as leaseProg.before).

// mediaSyncProg is one sync's chunk count across both tiers. A nil *mediaSyncProg writes nothing.
type mediaSyncProg struct {
	done, total int // done: chunks fetched; total: chunks planned so far, never below done
}

// mediaSyncProgWrite is the frame writer. Tests replace it; production never assigns it.
var mediaSyncProgWrite = writeProg

// plan adds n chunks that the next fetch will get.
func (p *mediaSyncProg) plan(n int) {
	if p == nil {
		return
	}
	p.total += n
}

// chunk counts one fetched chunk and writes one "sizes <done> <total>" frame, then restores the phase.
func (p *mediaSyncProg) chunk() {
	if p == nil {
		return
	}
	p.done++
	if p.total < p.done {
		p.total = p.done
	}
	prev, _ := progPhase.Load().(string)
	setProgPhase("sizes")
	mediaSyncProgWrite(p.done, p.total)
	setProgPhase(prev)
}
