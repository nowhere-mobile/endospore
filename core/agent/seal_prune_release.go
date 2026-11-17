package main

// NWP-20261204-06: A BARE-VAULT SEAL RELEASES THE CHUNKS ITS RETENTION DROPPED.
//
// pushSnapshot puts the outgoing head into History and pruneSnapshots then drops whatever the two-class retention
// no longer keeps. Before this file a dropped snapshot was simply forgotten: its chunks kept their leases until
// the term ended, and the gateway's free sum counted them as live (docs/backlog.md section D, the row 'The gateway
// refuses a free profile's renewal as "free quota exceeded" ...'). The decisions are docs/product-decisions.md
// '2026-11-12 -- DECIDED: four answers to harvest 64 ...', answer 2, option C, and '2026-10-20 -- DECIDED: a
// deleted snapshot's blobs are released on proof of a per-blob release secret ...', #1 (b).
//
// The step copies releaseDeletedSnapshot (snapshot_delete.go): the set, strictly; evict it from this phone's blob
// cache; record the release generation; read the head back; present the proofs on POST /release. pushProfile bumps
// vault.ReleaseGen before it signs the head, so another handset drops its chunk cache (release_gen.go), and runs
// the step only after capFlush published that head. The step never changes the seal's verdict.
//
// THE BARE VAULT AND THE FOUR SCOPE VAULTS (NWP-20261207-03). A #de, #sys, #keys or #apps head that is a vault (a
// credential change re-pointed it, or a tie did) releases at its seal exactly as the bare vault does: rk is that scope
// head's key, the proofs and the keep set use the scope key, and RecoveryRef is "" on a scope vault, so the read-back
// checks the scope head alone. pushProfile and the restore arm check the scope vault's release generation under that
// scope head's key (release_gen.go), so another handset drops its chunk cache. The scope release ships OFF
// (scopeReleaseOn) until an image carrying those checks has been published. Two later slices: #media (the export
// pins a manifest, and its kept manifests can name 100k chunks each, so the re-read needs a bound) and the scope heads
// that are still bare manifests (a sealed manifest carries no release generation, so no other handset could learn
// that its cache names released chunks, and it would publish a head naming collected chunks).

import (
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

// sealPruneSetWait bounds how long the step waits for the release set (one read per dropped and kept manifest), and
// sealPruneReleaseWait how long it waits for POST /release. The push runs at sign-out: a dead store must not hold
// it. Vars so a test can shorten them.
var sealPruneSetWait = 10 * time.Second
var sealPruneReleaseWait = 5 * time.Second

// sealPruneDropped is the manifests of oldHead and oldHist that are neither newHead nor in newHist: the snapshots
// this seal's retention dropped. "" is skipped; the result is deduplicated and sorted. Pure.
func sealPruneDropped(oldHead string, oldHist []headSnap, newHead string, newHist []headSnap) []string {
	kept := map[string]bool{newHead: true}
	for _, h := range newHist {
		kept[h.Manifest] = true
	}
	seen := map[string]bool{}
	var out []string
	consider := func(m string) {
		if m == "" || kept[m] || seen[m] {
			return
		}
		seen[m] = true
		out = append(out, m)
	}
	consider(oldHead)
	for _, h := range oldHist {
		consider(h.Manifest)
	}
	sort.Strings(out)
	return out
}

// sealPruneReleaseEligible: only the gateway has POST /release (cap mode); per-unit heads of other devices are not
// read, so their kept snapshots are unknown (multi-device); and only a head whose chunk cache is distrusted on a
// release generation change may release (relGenScope). pushProfile calls it only for a vault head, so a scope is
// admitted only as a scope vault, and only while scopeReleaseOn.
func sealPruneReleaseEligible(profile string) bool {
	return capMode() && !multiDeviceEnabled() && relGenScope(profile) && (strings.IndexByte(profile, '#') < 0 || scopeReleaseOn)
}

// relGenScope: the heads whose chunk cache a release generation distrusts (NWP-20261207-03), the bare vault and the
// #de, #sys, #keys and #apps scopes. Not #media (a later slice) and not #wallet or any other suffix. Pure.
func relGenScope(profile string) bool {
	i := strings.IndexByte(profile, '#')
	if i < 0 {
		return true
	}
	switch profile[i:] {
	case "#de", "#sys", "#keys", "#apps":
		return true
	}
	return false
}

// scopeReleaseOn turns the scope vaults' release on (MODERATOR RULING, harvest 68). It ships false. FLEET WINDOW: an
// image without the scope release generation checks (pushProfile, relGenAtScopeRestore) keeps a scope chunk cache
// across a sign-out, so a handset on such an image could re-publish a chunk this phone released. A one-line follow-up
// PR sets it true once an image carrying the checks has been published. Tests set it with t.Cleanup.
var scopeReleaseOn = false

// sealPruneReleaseSet is every blob a dropped manifest names that neither kept.Manifest nor any kept.History entry
// names. Any manifest that cannot be read returns (nil, err): nothing is released when anything is unknown.
func sealPruneReleaseSet(base string, dk []byte, dropped []string, kept *vault) (map[string]bool, error) {
	free := map[string]bool{}
	for _, m := range dropped {
		if err := manifestBlobsStrict(base, dk, m, free); err != nil {
			return nil, err
		}
	}
	keep, err := manifestKeepSet(base, dk, kept)
	if err != nil {
		return nil, err
	}
	for k := range keep {
		delete(free, k)
	}
	return free, nil
}

// sealPruneReleaseGate: the release is correct only when the new head, which no longer names the dropped
// snapshots, is in the store. A refused, stale, fenced or stopped flush published no head. Pure.
func sealPruneReleaseGate(landed, refused, stopped bool) bool {
	return landed && !refused && !stopped
}

// sealPrunePending is what pushProfile hands the deferred step. landed is set only by capAfterPublish on the head.
type sealPrunePending struct {
	base, profile, pass string
	dk                  []byte   // a copy
	dropped             []string // sealPruneDropped
	vh                  string   // the vault blob this seal published
	kept                *vault   // a copy of the published vault
	landed              bool
}

// sealPruneRelease runs after capFlush, in pushProfile's defer. It never panics out, never returns an error and never
// changes the seal's verdict: whatever it cannot do leaves the chunks on the lease schedule.
func sealPruneRelease(p *sealPrunePending) {
	lp := logProfile(p.profile)
	defer func() {
		if r := recover(); r != nil { // the panic value is dropped: it can name a blob
			fmt.Printf("push: profile %s: nothing released early -- the release step failed\n", lp)
		}
	}()
	rk := relGenHeadKey(p.base, p.profile, p.pass)
	cache := blobCachePath() // the file the next seal's distrustBlobCacheIfReleased reads
	skip := func(why string) {
		fmt.Printf("push: profile %s: nothing released early -- %s\n", lp, why)
	}
	// Nothing was released, so the cache is still true: record the new generation, or the next seal drops the whole
	// chunk cache and re-chunks the bare scope.
	skipRecord := func(why string) {
		skip(why)
		relGenRecord(cache, rk, p.kept.ReleaseGen)
	}

	// The set reads every kept manifest: on a goSafe job, waited at most sealPruneSetWait. done is buffered and the
	// job always sends one result, so it never blocks once the step has stopped waiting.
	type setResult struct {
		set map[string]bool
		err error
	}
	done := make(chan setResult, 1)
	base, dk, dropped, kept := p.base, append([]byte(nil), p.dk...), p.dropped, p.kept
	goSafe("seal-prune-set", func() {
		var r setResult
		defer func() {
			if q := recover(); q != nil {
				r = setResult{err: errManifestUnreadable}
			}
			done <- r
		}()
		r.set, r.err = sealPruneReleaseSet(base, dk, dropped, kept)
	})
	var set map[string]bool
	select {
	case r := <-done:
		if r.err != nil {
			skipRecord("a kept version could not be read")
			return
		}
		set = r.set
	case <-time.After(sealPruneSetWait):
		skipRecord("the kept versions were not read in time")
		return
	}
	if len(set) == 0 {
		skipRecord("every object is still named by the current state or a kept version")
		return
	}

	// Evict first: a cache that still believed a released chunk present would publish a manifest naming it. The
	// generation is recorded only when the eviction succeeded; otherwise the next seal finds the mismatch and drops
	// the whole cache, the safe direction.
	evicted, eerr := blobCacheEvict(cache, set)
	if eerr == nil {
		relGenRecord(cache, rk, p.kept.ReleaseGen)
	}

	// Read back both refs immediately before the request. The publish is not a compare-and-swap: another handset can
	// overwrite the head in the window, and a recovery ref that lags would open a vault naming the released chunks.
	read := func(ref string) (got string) {
		defer func() {
			if q := recover(); q != nil {
				got = ""
			}
		}()
		return getRef(p.base, ref)
	}
	if read(rk) != p.vh {
		skip("the head changed after the seal landed")
		return
	}
	if p.kept.RecoveryRef != "" && read(p.kept.RecoveryRef) != p.vh {
		skip("the recovery copy does not name this seal")
		return
	}

	proofs := make(map[string]string, len(set))
	for k := range set {
		proofs[k] = hex.EncodeToString(blobReleaseProof(p.dk, k))
	}
	// The job captures the proofs and the gateway URL, never dk.
	type releaseResult struct {
		released []string
		status   int
		err      error
	}
	rdone := make(chan releaseResult, 1)
	gw := os.Getenv("GATEWAY_URL")
	goSafe("seal-prune-release", func() {
		var r releaseResult
		defer func() {
			if q := recover(); q != nil {
				r = releaseResult{err: recoveredErr("release", q)}
			}
			rdone <- r
		}()
		r.released, r.status, r.err = newGatewayClient(gw, gwDefault).releaseBlobs(proofs)
	})
	var r releaseResult
	select {
	case r = <-rdone:
	case <-time.After(sealPruneReleaseWait):
		skip("the gateway is still taking the release -- not waiting")
		return
	}
	status, n, m := r.status, len(r.released), len(set)
	switch {
	case status == http.StatusNotFound || status == http.StatusMethodNotAllowed:
		skip("the gateway does not release early")
	case r.err != nil:
		fmt.Printf("push: profile %s: nothing released early -- the gateway did not take the request (status %d)\n", lp, status)
	default:
		fmt.Printf("push: profile %s: %d of %d unshared object(s) released for the next collection (%d evicted from this phone's cache)\n",
			lp, n, m, evicted)
	}
}
