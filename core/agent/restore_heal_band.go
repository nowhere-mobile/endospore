package main

import (
	"math/bits"
	"strings"
	"sync/atomic"
)

// NWP-20261208-29 ("Sign-in's restore labels come back: "Restoring app data" restarts from 0%, ..."): the bare
// vault and #de restore in two steps under ONE phase word, the essential restore (cdcRestoreProg) and then the
// heal (healDeferredLate). Each used to report its own done/total, so the bar went 100% -> 0% -> 100%. The heal
// band joins them: the restore verb sets the heal's estimate before the essential restore, cdcRestoreProg reports
// out of its bytes plus that estimate and records where it stopped (the base), and the heal fills the rest.
// Process state, as progPhase is: the restore verb is one agent process per scope. Est 0 (no band) changes nothing.
var healBandEst, healBandBase atomic.Int64

// setHealBand opens a band of est bytes for the next essential restore and heal. The base is unknown until
// cdcRestoreProg runs.
func setHealBand(est int64) {
	healBandEst.Store(est)
	healBandBase.Store(0)
}

// clearHealBand closes the band, so every later writer reports its own frame again.
func clearHealBand() {
	healBandEst.Store(0)
	healBandBase.Store(0)
}

// healProgEstimate is the bytes the heal could fetch for this head: the deferred files that pass
// healDeferredLate's static checks. 0 for a scope that defers (the heal never runs there). Late, present and held
// files are not known before the restore; healBandFrame ends the heal at 100% whatever it fetches.
func healProgEstimate(profile string, m chunkManifest) int64 {
	if scopeDefersMedia(profile) {
		return 0
	}
	var est int64
	for rel, d := range m.Deferred {
		if d.Size <= 0 || len(d.Chunks) == 0 || isMediaCachePath(rel) || isAppCodeStagePath(rel) ||
			strings.Contains(rel, "/"+odHoldDirName+"/") {
			continue
		}
		est += d.Size
	}
	return est
}

// healBandFrame maps the heal's own progress h of H onto the band: from base (where the essential restore
// stopped) to base+est. No band (est or base not positive) passes h and H through. H <= 0 (nothing left to
// fetch) is the full frame, so the bar still ends at 100%. h*est/H is computed on a 128-bit product: a
// multi-GiB heal overflows int64 at h*est, and the bar would go negative and never reach 100%.
func healBandFrame(base, est, h, H int64) (done, total int64) {
	if est <= 0 || base <= 0 {
		return h, H
	}
	total = base + est
	if H <= 0 {
		return total, total
	}
	if h < 0 {
		h = 0
	}
	if h > H {
		h = H
	}
	hi, lo := bits.Mul64(uint64(h), uint64(est))
	q, _ := bits.Div64(hi, lo, uint64(H)) // 0 <= h <= H, so hi < H and q <= est
	return base + int64(q), total
}

// healProg is the heal's writeProg: its frame goes through the band.
func healProg(h, H int64) {
	done, total := healBandFrame(healBandBase.Load(), healBandEst.Load(), h, H)
	writeProg(int(done), int(total))
}
