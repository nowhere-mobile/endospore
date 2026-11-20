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
// (scopeReleaseOn) until an image carrying those checks has been published.
//
// #MEDIA VAULTS TOO (NWP-20261208-14). A #media head that is a vault releases the same way, with two additions. The
// media export pins one #media manifest outside the vault History (export_rekey.go), so that manifest and every chunk
// it names join the keep set (sealPruneMediaPin, read strictly). A #media manifest can name 100k chunks, so the compare
// stops above sealPruneMediaMaxKeys keys and releases nothing. ~~One later slice: the scope heads that are still bare
// manifests (a sealed manifest carries no release generation, so no other handset could learn that its cache names
// released chunks, and it would publish a head naming collected chunks).~~ *(superseded by NWP-20261208-15, below:
// built for bare-shaped #de, #sys, #keys and #apps heads; bare-shaped #media heads are still a later slice)*
//
// Every chunk a #media seal carries forward (the essential carry, the deferred carry, materializeCarried,
// newlyArrivedDeferred) comes from the head read at that seal (oldM in pushProfile), never from the restore receipt,
// so the new head, the kept History and the export pin name every manifest a #media seal can still need. RESIDUAL: a
// handset that still streams on demand a file another handset deleted, whose last naming snapshot was dropped, finds
// its chunks collected. The file is gone from every kept head.
//
// BARE-SHAPED SCOPE HEADS (NWP-20261208-15). A #de, #sys, #keys or #apps head that is still a bare manifest has no
// History and no release generation, so it cannot release at its own seal: no other handset could learn that its
// cache names a released chunk. Instead its seal RECORDS, once its head landed, the chunks it stopped naming (the old
// head's blobs less the new manifest's) in blobCachePath()+".scopedrop", a state-tmpfs file beside the cache and
// .relgen (release_gen.go's header: no threat-model row). Lines are `<relGenTag(scope head key)> blob/<hex>` and one
// `last <unix>`: content hashes and tags, never a name. The next bare-vault seal at least scopeDropMinGap after the
// last such release bumps the BARE vault's ReleaseGen (once, shared with a retention drop), and this step releases the
// records on the per-blob release proof under each scope key, less what the scope's CURRENT head names; a scope whose
// head became a vault since, or cannot be read, is skipped. After the attempt, whatever its result, the loaded records
// go and `last` is written: an unanswered release leaves those chunks on the lease schedule, never released wrongly.
// pushProfile checks the bare vault's generation at every bare-shaped scope push, so another handset drops its chunk
// cache before that scope seals; the gap bounds how often that happens, at most once a day. RESIDUAL: between another
// handset's bare push and its scope push in one round, its cache can still name a released chunk: the same accepted
// window as a vault head's CAS-less read. The record and the release ship behind scopeReleaseOn; the push check ships
// on.

import (
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// sealPruneSetWait bounds how long the step waits for the release set (one read per dropped and kept manifest), and
// sealPruneReleaseWait how long it waits for POST /release. The push runs at sign-out: a dead store must not hold
// it. Vars so a test can shorten them.
var sealPruneSetWait = 10 * time.Second
var sealPruneReleaseWait = 5 * time.Second

// sealPruneMediaMaxKeys bounds the keys a #media release holds to compare: the dropped set plus the keep set. A #media
// vault keeps up to 7 automatic snapshots plus its head (Q141, pushProfile's vault arm), and one #media manifest can
// name about 100k chunks (the 100,139-chunk head of the backlog's HTTP 500 row), so an unbounded compare could hold
// millions of keys in memory at sign-out. Above the bound the step releases nothing; the chunks stay on the lease
// schedule. The bare vault and the other scopes have no bound. A var so a test can lower it.
var sealPruneMediaMaxKeys = 400000

// errSealPruneTooLarge is a #media release set whose compare passed sealPruneMediaMaxKeys.
var errSealPruneTooLarge = errors.New("too many objects to compare")

// sealPruneOverBound: n keys are too many to compare, for a #media head only. Pure.
func sealPruneOverBound(media bool, n int) bool {
	return media && n > sealPruneMediaMaxKeys
}

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
// #de, #sys, #keys and #apps scopes, and #media (NWP-20261208-14). Not #wallet or any other suffix. Pure.
func relGenScope(profile string) bool {
	i := strings.IndexByte(profile, '#')
	if i < 0 {
		return true
	}
	switch profile[i:] {
	case "#de", "#sys", "#keys", "#apps", "#media":
		return true
	}
	return false
}

// scopeReleaseOn turns the scope vaults' release on (MODERATOR RULING, harvest 68). It shipped false in 0.5.58, the
// first image carrying the scope release generation checks (pushProfile, relGenAtScopeRestore); NWP-20261116-56 turns it
// on after 0.5.58 was published (2026-11-17), so the release ships one published release behind the check
// (docs/product-decisions.md, 2026-11-17, "seven answers to harvest 69", item 7). FLEET WINDOW: a handset still on an
// image without the checks (0.5.57 or older) keeps a scope chunk cache across a sign-out and could re-publish a chunk
// this phone released; it closes as the fleet takes 0.5.58. Tests set it with t.Cleanup.
var scopeReleaseOn = true

// sealPruneReleaseSet is every blob a dropped manifest names that neither kept.Manifest nor any kept.History entry
// names, nor, for a #media head, the export's pinned manifest (sealPruneMediaPin). Any manifest or pin that cannot be
// read returns (nil, err): nothing is released when anything is unknown. For a #media head only, a compare above
// sealPruneMediaMaxKeys keys returns errSealPruneTooLarge, checked after each manifest read.
func sealPruneReleaseSet(base string, dk []byte, profile, pass string, dropped []string, kept *vault) (map[string]bool, error) {
	name, scope, scoped := strings.Cut(profile, "#")
	media := scoped && scope == "media"
	free := map[string]bool{}
	for _, m := range dropped {
		if err := manifestBlobsStrict(base, dk, m, free); err != nil {
			return nil, err
		}
		if sealPruneOverBound(media, len(free)) {
			return nil, errSealPruneTooLarge
		}
	}
	over := func(keep map[string]bool) error {
		if sealPruneOverBound(media, len(free)+len(keep)) {
			return errSealPruneTooLarge
		}
		return nil
	}
	keep, err := manifestKeepSetEach(base, dk, kept, over)
	if err != nil {
		return nil, err
	}
	if media {
		pin, err := sealPruneMediaPin(base, name, pass)
		if err != nil {
			return nil, err
		}
		for k := range pin {
			keep[k] = true
		}
		if err := over(keep); err != nil {
			return nil, err
		}
	}
	for k := range keep {
		delete(free, k)
	}
	return free, nil
}

// sealPruneMediaPin is every blob key the media export's pinned #media manifest names: the manifest's own blob and
// every chunk and deferred chunk. name is the bare profile. The export page streams that manifest's chunks, and the
// manifest is pinned outside the #media vault's History, so a #media release that ignored it would collect chunks the
// export still names. Both pointers are read strictly (getRefBytesStrict: capGetStrict in cap mode, the only mode the
// release runs in): a 404 is absence, any other failure is an error. An empty value is absence too: a purged export
// leaves its pointers empty until they expire (leaseEmptyExportRefs). The re-keyed pointer is read first and the
// legacy ref/export/<name>#media only when the re-keyed one is absent. Neither present: an empty set. A pointer that
// is not a content hash, a blob that cannot be read or opened, or any panic: (nil, err). The panic value is dropped: it can name
// a blob.
func sealPruneMediaPin(base, name, pass string) (pin map[string]bool, err error) {
	defer func() {
		if r := recover(); r != nil {
			pin, err = nil, errManifestUnreadable
		}
	}()
	read := func(ref string) string {
		b, _ := getRefBytesStrict(base, ref)
		return strings.TrimSpace(string(b))
	}
	h := read(exportMediaRef(deriveKey(name, pass)).name())
	if h == "" {
		h = read("export/" + name + "#media")
	}
	if h == "" {
		return map[string]bool{}, nil
	}
	if !isContentHash(h) {
		return nil, errors.New("the media export pointer is not a content hash")
	}
	_, pt, err := openMediaExportManifest(base, name, pass, getBlob(base, h))
	if err != nil {
		return nil, err
	}
	pin = map[string]bool{}
	if err := manifestPlainBlobs(h, pt, pin); err != nil {
		return nil, err
	}
	return pin, nil
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
	scopes              []*scopeDropSet // bare-shaped scope records released with this seal (NWP-20261208-15)
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
	if len(p.scopes) > 0 { // NWP-20261208-15: on every return, the loaded records go and `last` is written
		defer scopeDropDone(blobCachePath(), p.scopes)
	}
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
		set    map[string]bool
		err    error
		scopes []scopeDropResult // one per p.scopes entry
	}
	done := make(chan setResult, 1)
	base, dk, dropped, kept := p.base, append([]byte(nil), p.dk...), p.dropped, p.kept
	profile, pass := p.profile, p.pass
	scopes := scopeDropCopy(p.scopes)
	goSafe("seal-prune-set", func() {
		var r setResult
		defer func() {
			if q := recover(); q != nil {
				r = setResult{err: errManifestUnreadable}
			}
			done <- r
		}()
		if len(dropped) > 0 {
			r.set, r.err = sealPruneReleaseSet(base, dk, profile, pass, dropped, kept)
		} else {
			r.set = map[string]bool{} // a release of scope records alone: no kept manifest needs reading
		}
		r.scopes = scopeDropSets(base, scopes)
	})
	var set map[string]bool
	var sd []scopeDropResult
	select {
	case r := <-done:
		if errors.Is(r.err, errSealPruneTooLarge) {
			skipRecord("too many objects to compare")
			return
		}
		if r.err != nil {
			skipRecord("a kept version could not be read")
			return
		}
		set, sd = r.set, r.scopes
	case <-time.After(sealPruneSetWait):
		skipRecord("the kept versions were not read in time")
		return
	}
	// NWP-20261208-15: each skipped scope says why before anything else returns; scopeKeys is the union of the rest.
	scopeKeys := map[string]bool{}
	for i, s := range p.scopes {
		if i >= len(sd) || sd[i].why != "" {
			why := "from " + logProfile(s.profile) + " -- the scope head could not be read"
			if i < len(sd) {
				why = "from " + logProfile(s.profile) + " -- " + sd[i].why
			}
			fmt.Printf("push: profile %s: nothing released early %s\n", lp, why)
			continue
		}
		for k := range sd[i].set {
			scopeKeys[k] = true
		}
	}
	if len(set) == 0 && len(scopeKeys) == 0 {
		skipRecord("every object is still named by the current state or a kept version")
		return
	}

	// Evict first: a cache that still believed a released chunk present would publish a manifest naming it. The
	// generation is recorded only when the eviction succeeded; otherwise the next seal finds the mismatch and drops
	// the whole cache, the safe direction.
	evicted, eerr := blobCacheEvict(cache, set)
	if eerr == nil && len(scopeKeys) > 0 {
		var n int
		n, eerr = blobCacheEvict(cache, scopeKeys)
		evicted += n
	}
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

	proofs := make(map[string]string, len(set)+len(scopeKeys))
	for k := range set {
		proofs[k] = hex.EncodeToString(blobReleaseProof(p.dk, k))
	}
	// NWP-20261208-15: a scope head read back as anything but the head its set was computed against leaves the
	// request; the rest are proven under their own scope key.
	fromScopes := 0
	for i, s := range p.scopes {
		if i >= len(sd) || sd[i].why != "" || len(sd[i].set) == 0 {
			continue
		}
		if read(s.ref) != sd[i].head {
			why := "from " + logProfile(s.profile) + " -- the scope head changed"
			fmt.Printf("push: profile %s: nothing released early %s\n", lp, why)
			continue
		}
		for k := range sd[i].set {
			proofs[k] = hex.EncodeToString(blobReleaseProof(s.key, k))
			fromScopes++
		}
	}
	if len(proofs) == 0 {
		skip("every object is still named by the current state or a kept version")
		return
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
	status, n, m := r.status, len(r.released), len(proofs)
	switch {
	case status == http.StatusNotFound || status == http.StatusMethodNotAllowed:
		skip("the gateway does not release early")
	case r.err != nil:
		fmt.Printf("push: profile %s: nothing released early -- the gateway did not take the request (status %d)\n", lp, status)
	default:
		// TestSealPruneReleaseSourceNeverFormatsASecret admits only its listed names here, so the scope count is text.
		why := "(" + strconv.Itoa(fromScopes) + " from scope heads)"
		fmt.Printf("push: profile %s: %d of %d unshared object(s) released for the next collection (%d evicted from this phone's cache) %s\n",
			lp, n, m, evicted, why)
	}
}

// NWP-20261208-15: the bare-shaped scope records (the header's BARE-SHAPED SCOPE HEADS).

// scopeDropMinGap is the least time between two releases of scope records: each bumps the bare release generation,
// and each bump makes another handset drop its whole chunk cache. scopeDropMaxKeys bounds the records per scope head;
// what does not fit stays on the lease schedule. Vars so a test can change them.
var scopeDropMinGap = 24 * time.Hour
var scopeDropMaxKeys = 100000

// scopeDropScopes are the bare-shaped scope heads whose freed chunks are recorded. Not #media: its export pins a
// manifest, and that pin is a later slice.
var scopeDropScopes = []string{"#de", "#sys", "#keys", "#apps"}

// scopeDropSuffix: profile is <name><one of scopeDropScopes>, exactly (not "a#de#x"). Pure.
func scopeDropSuffix(profile string) bool {
	i := strings.IndexByte(profile, '#')
	if i <= 0 {
		return false
	}
	for _, s := range scopeDropScopes {
		if profile[i:] == s {
			return true
		}
	}
	return false
}

// scopeDropEligible: a bare-shaped seal of this scope records the chunks it stopped naming. The release goes through
// the gateway (cap mode), only one device seals this profile (not multi-device), and it ships behind scopeReleaseOn.
// Pure but for the env.
func scopeDropEligible(profile string) bool {
	return capMode() && !multiDeviceEnabled() && scopeReleaseOn && scopeDropSuffix(profile)
}

// scopeDropChecksBare: a bare-shaped push of this scope checks the BARE vault's release generation. #media too: the
// chunk cache is shared, so the bare generation covers it at no cost. Pure.
func scopeDropChecksBare(profile string) bool {
	i := strings.IndexByte(profile, '#')
	return i > 0 && (scopeDropSuffix(profile) || profile[i:] == "#media")
}

func scopeDropPath(cachePath string) string {
	if cachePath == "" {
		return ""
	}
	return cachePath + ".scopedrop"
}

// scopeDropFreed is every blob the old head names that the manifest this seal built does not: newManifest and each of
// its chunks and deferred chunks, taken from memory. Only the old head is read; any read error returns (nil, err)
// and nothing is recorded.
func scopeDropFreed(base string, dk []byte, oldHead, newManifest string, chunks []string, deferred map[string]deferredFile) (map[string]bool, error) {
	freed := map[string]bool{}
	if err := manifestBlobsStrict(base, dk, oldHead, freed); err != nil {
		return nil, err
	}
	delete(freed, "blob/"+newManifest)
	for _, c := range chunks {
		delete(freed, "blob/"+c)
	}
	for _, d := range deferred {
		for _, c := range d.Chunks {
			delete(freed, "blob/"+c)
		}
	}
	return freed, nil
}

// scopeDropLine parses one record line: `<16-hex tag> blob/<hex>` (rec) or `last <unix>`. Anything else is ignored.
func scopeDropLine(line string) (tag, key string, last int64, isLast, ok bool) {
	f := strings.Fields(line)
	if len(f) != 2 {
		return "", "", 0, false, false
	}
	if f[0] == "last" {
		n, err := strconv.ParseInt(f[1], 10, 64)
		return "", "", n, true, err == nil
	}
	h := strings.TrimPrefix(f[1], "blob/")
	if len(f[0]) != 16 || !isLowerHex(f[0]) || h == f[1] || h == "" || !isLowerHex(h) {
		return "", "", 0, false, false
	}
	return f[0], f[1], 0, false, true
}

func isLowerHex(s string) bool {
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// scopeDropLoad reads the records by tag and the last release time. A missing file is empty, not an error.
func scopeDropLoad(cachePath string) (byTag map[string]map[string]bool, last int64, haveLast bool, err error) {
	byTag = map[string]map[string]bool{}
	p := scopeDropPath(cachePath)
	if p == "" {
		return byTag, 0, false, nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return byTag, 0, false, nil
		}
		return nil, 0, false, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		tag, key, n, isLast, ok := scopeDropLine(line)
		switch {
		case !ok:
		case isLast:
			last, haveLast = n, true
		default:
			if byTag[tag] == nil {
				byTag[tag] = map[string]bool{}
			}
			byTag[tag][key] = true
		}
	}
	return byTag, last, haveLast, nil
}

// scopeDropWrite replaces the file with the records of byTag (sorted) and, when haveLast, one `last` line: a temp file
// in the same dir, 0600, renamed over it (relGenRecord's shape).
func scopeDropWrite(cachePath string, byTag map[string]map[string]bool, last int64, haveLast bool) error {
	p := scopeDropPath(cachePath)
	if p == "" {
		return nil
	}
	var lines []string
	for tag, keys := range byTag {
		for k := range keys {
			lines = append(lines, tag+" "+k)
		}
	}
	sort.Strings(lines)
	if haveLast {
		lines = append(lines, "last "+strconv.FormatInt(last, 10))
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), filepath.Base(p)+".tmp")
	if err != nil {
		return err
	}
	fail := func(err error) error {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		return fail(err)
	}
	if _, err := tmp.WriteString(strings.Join(lines, "\n") + "\n"); err != nil {
		return fail(err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), p); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// scopeDropRecord adds keys under relGenTag(headKey), until that tag holds scopeDropMaxKeys records.
func scopeDropRecord(cachePath, headKey string, keys map[string]bool) error {
	if scopeDropPath(cachePath) == "" || len(keys) == 0 {
		return nil
	}
	byTag, last, haveLast, err := scopeDropLoad(cachePath)
	if err != nil {
		return err
	}
	tag := relGenTag(headKey)
	have := byTag[tag]
	if have == nil {
		have = map[string]bool{}
		byTag[tag] = have
	}
	add := make([]string, 0, len(keys))
	for k := range keys {
		if _, _, _, _, ok := scopeDropLine(tag + " " + k); ok && !have[k] {
			add = append(add, k)
		}
	}
	sort.Strings(add)
	for _, k := range add {
		if len(have) >= scopeDropMaxKeys {
			break
		}
		have[k] = true
	}
	return scopeDropWrite(cachePath, byTag, last, haveLast)
}

// scopeDropFinish removes exactly the loaded (tag, key) records, so a record added after the load stays, and writes
// `last <now>`.
func scopeDropFinish(cachePath string, loaded map[string]map[string]bool, now time.Time) error {
	if scopeDropPath(cachePath) == "" {
		return nil
	}
	byTag, _, _, err := scopeDropLoad(cachePath)
	if err != nil {
		return err
	}
	for tag, keys := range loaded {
		for k := range keys {
			delete(byTag[tag], k)
		}
		if len(byTag[tag]) == 0 {
			delete(byTag, tag)
		}
	}
	return scopeDropWrite(cachePath, byTag, now.Unix(), true)
}

// scopeDropSet is one scope head's records, carried by sealPrunePending.
type scopeDropSet struct {
	profile  string          // name#sfx, for logProfile only
	ref      string          // relGenHeadKey(base, profile, pass)
	tag      string          // relGenTag(ref)
	key      []byte          // deriveKey(profile, pass), a copy
	recorded map[string]bool // the records the file held for tag
}

// scopeDropResult is the set job's answer for one scope: the head it read and what to release, or why not.
type scopeDropResult struct {
	head string
	set  map[string]bool
	why  string // a fixed text, never a hash
}

// scopeDropDue is the scope records a bare seal of profile releases now: none unless the profile is a bare vault
// eligible for the release, scopeReleaseOn, the file holds a record and the last release is at least scopeDropMinGap
// old. The file is read before any head key is probed. A read error or a panic means nothing is due, records kept.
func scopeDropDue(base, profile, pass string, now time.Time) (out []*scopeDropSet) {
	defer func() {
		if recover() != nil {
			out = nil
		}
	}()
	if strings.IndexByte(profile, '#') >= 0 || !scopeReleaseOn || !sealPruneReleaseEligible(profile) {
		return nil
	}
	byTag, last, haveLast, err := scopeDropLoad(blobCachePath())
	if err != nil || len(byTag) == 0 {
		return nil
	}
	if haveLast && now.Sub(time.Unix(last, 0)) < scopeDropMinGap {
		return nil
	}
	for _, sfx := range scopeDropScopes {
		scoped := profile + sfx
		ref := relGenHeadKey(base, scoped, pass)
		tag := relGenTag(ref)
		if len(byTag[tag]) == 0 {
			continue
		}
		out = append(out, &scopeDropSet{profile: scoped, ref: ref, tag: tag, key: deriveKey(scoped, pass), recorded: byTag[tag]})
	}
	return out
}

// scopeDropCopy copies the sets for the set job, which can outlive the step's wait.
func scopeDropCopy(in []*scopeDropSet) []scopeDropSet {
	out := make([]scopeDropSet, len(in))
	for i, s := range in {
		rec := make(map[string]bool, len(s.recorded))
		for k := range s.recorded {
			rec[k] = true
		}
		out[i] = scopeDropSet{profile: s.profile, ref: s.ref, tag: s.tag, key: append([]byte(nil), s.key...), recorded: rec}
	}
	return out
}

func scopeDropSets(base string, scopes []scopeDropSet) []scopeDropResult {
	out := make([]scopeDropResult, len(scopes))
	for i := range scopes {
		out[i] = scopeDropSetOf(base, &scopes[i])
	}
	return out
}

// scopeDropSetOf re-reads the scope's head: a vault (re-pointed since the records were made) or an unreadable head is
// skipped; else the set is the records less every blob the current head names.
func scopeDropSetOf(base string, s *scopeDropSet) (res scopeDropResult) {
	defer func() {
		if recover() != nil {
			res = scopeDropResult{why: "the scope head could not be read"}
		}
	}()
	head := getRef(base, s.ref)
	if head == "" {
		return scopeDropResult{why: "the scope head could not be read"}
	}
	if _, isV := parseVault(headBlobGet(base, head)); isV {
		return scopeDropResult{why: "the scope head is a vault now"}
	}
	keep := map[string]bool{}
	if err := manifestBlobsStrict(base, s.key, head, keep); err != nil {
		return scopeDropResult{why: "the scope head could not be read"}
	}
	set := map[string]bool{}
	for k := range s.recorded {
		if !keep[k] {
			set[k] = true
		}
	}
	return scopeDropResult{head: head, set: set}
}

// scopeDropDone runs after every release attempt that carried scope records: those records go, `last` is written.
func scopeDropDone(cachePath string, scopes []*scopeDropSet) {
	loaded := map[string]map[string]bool{}
	for _, s := range scopes {
		loaded[s.tag] = s.recorded
	}
	if err := scopeDropFinish(cachePath, loaded, time.Now()); err != nil {
		fmt.Println("push: the released scope records could not be removed -- the next due bare seal releases them again")
	}
}

// relGenAtBareShapedScope is pushProfile's check at a bare-shaped scope push: the BARE vault's release generation,
// read from bareHead (the bare head pushProfile's tombstone guard read), against the bare head's record. A
// scope-record release bumps only the bare generation, so without this another handset's scope seal could publish a
// head naming a chunk this phone released. A failed read drops the cache, the safe direction.
func relGenAtBareShapedScope(base, profile, pass, bareHead string) {
	i := strings.IndexByte(profile, '#')
	if i <= 0 {
		return
	}
	cache, lp := blobCachePath(), logProfile(profile)
	defer func() {
		if r := recover(); r != nil { // the panic value is dropped: it can name a blob
			blobCacheDrop(cache)
			fmt.Printf("push: profile %s: the bare release generation could not be read -- the chunk cache is dropped for this seal\n", lp)
		}
	}()
	var gen uint64 // an absent or legacy bare head is generation 0
	if bareHead != "" {
		if bv, isV := parseVault(headBlobGet(base, bareHead)); isV {
			gen = bv.ReleaseGen
		}
	}
	if distrustBlobCacheIfReleased(cache, relGenHeadKey(base, profile[:i], pass), gen) {
		fmt.Printf("push: profile %s: the bare release generation moved since this phone's chunk cache was filled -- the cache is dropped for this seal\n", lp)
	}
}
