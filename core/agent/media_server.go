package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// #84 P3 -- nowhere_mediad's store-backed media server (the crypto/store half; the go-fuse glue rides on top).
//
// P2 split large media out of the login-gating manifest into chunkManifest.Deferred (rel -> chunk region +
// metadata); those files are NOT restored at login. This serves them on-access: the first open of a
// not-yet-cached deferred file fetches its chunks from the store (the same getChunk/unseal/unpackChunk path a
// restore uses), reassembles the WHOLE file into a CE-local cache, and serves reads from there. Fetching the
// whole file on first open -- not per read() -- is deliberate: a map DB does random reads, and paying one
// store round-trip per read() would ANR the app (design doc, "Risks"). This keeps login latency independent
// of GBs of maps/photos: they materialize only when actually opened.
//
// This file is store-and-crypto only (no kernel mount), so it unit-tests against the same in-process store
// harness the P1/P2 seal tests use. docs/on-demand-media.md is the design.

// mediaCacheDirName is the LEAF name of the media daemon's per-user local cache dir. The seal walkers skip
// any dir with this name WHEREVER it appears (walkChunks + tarDirTo, by basename): it is DERIVED state,
// reconstructible from the store, and its .under entries are BIND MOUNTS onto live app dirs -- sealing it
// would double the profile and follow the binds into the real data. (#84 P3d)
const mediaCacheDirName = ".nowhere-media"

// mediaCacheRel is the cache dir's path RELATIVE to the roamed user root (/data/user/<uid>). It lives INSIDE
// the chooser's package data dir -- NOT at the user root -- because Android's app-data reconcile (on the CE
// unlock at cold-lock RESUME) reaps any TOP-LEVEL dir under /data/user/<uid> that isn't an installed package:
// it renamed /data/user/<uid>/.nowhere-media to "<uuid>==deleted==" and async rm -rf'd it, walking THROUGH
// the live .under BIND and deleting the REAL app dir's contents (#92, proven on FP3 2026-07-03 -- destroyed
// an essential restored map + a freshly-migrated one). Inside a known package dir the reconcile leaves it
// alone; it's still the roamed user's CE storage so cached plaintext media stays FBE-protected and dies with
// the ephemeral user. The chooser is install-existing'd for every roamed user, so its dir always exists.
// MUST stay byte-identical to the CACHE= path nowhere_mediad.sh passes the daemon (media_seal.go derives the
// .under path from it; runMediad binds under the passed cacheDir -- the two must agree).
const mediaCacheRel = "com.nowhere.chooser/files/" + mediaCacheDirName

// appCodeStageDirName / appCodeStageRel: the chooser's TRANSIENT APK-install staging. UnarchiveService
// materialises an on-demand app by having the su:s0 worker restore its APK set into
// getFilesDir()/.appcode/<pkg>, installs from there, and ALWAYS deletes the cleartext bytes afterward -- so
// the dir exists only for the seconds-to-minutes of a materialise. (NWP-20260901-17)
const appCodeStageDirName = ".appcode"
const appCodeStageRel = "com.nowhere.chooser/files/" + appCodeStageDirName

// isAppCodeStagePath reports whether rel lives inside that staging. NWP-20260901-17: a periodic seal that
// runs DURING a materialise walks the staged APK set -- a couple of hundred MB of big files under a
// "/files/" segment, so the media split DEFERRED them; the staging is deleted minutes later; the rels then
// never exist again anywhere, and the present-not-deleted carry kept them in the head forever. Rendered on
// the Offline-media screen as held by "Profile" (pinnedApp of a chooser-segment rel is the chooser, whose
// app label is Profile), undeletable from the device, billed. The EXACT bug shape NWP-20260831-08 fixed for
// /.nowhere-odhold/, one directory over. The seal walkers now SKIP the staging (its real life is the #apps
// scope -- sealing it here double-stored bytes the store already holds), and pushProfile drops any stale
// deferred entry under it so existing heads self-heal on their next seal. Safe as a drop predicate for the
// same reason as isMediaCachePath: no legit user-data rel is ever inside the install staging.
func isAppCodeStagePath(rel string) bool {
	rel = strings.TrimPrefix(rel, "/")
	return rel == appCodeStageRel || strings.HasPrefix(rel, appCodeStageRel+"/")
}

// playDownloadRel is Play Store's own download cache: in-progress or leftover APK/split downloads, not the
// user's data. Q076 (docs/product-decisions.md, 2026-10-20, "sixteen recommendations accepted -- Play's download
// cache does not roam; ..."): it is never sealed -- excluded at the seal walk like the media daemon's cache --
// so it is neither restored nor billed (odtest57 carried ~703 MB of it and every sign-in restored it).
// This is the ONE by-name exclusion of another app's directory; it is not a list to grow. If Google renames
// the directory the exclusion goes silent and the bytes simply roam again: the cost is bytes, never data.
// NOT a carry or heal drop predicate (unlike isAppCodeStagePath / isMediaCachePath): an old head's deferred
// entry here is fetched at sign-in and leaves the head through the carry's healHandled arm, never unfetched.
const playDownloadRel = "com.android.vending/files/phonesky-download-service"

// isPlayDownloadPath reports whether rel (relative to a CE or DE scope root) is that directory or inside it.
func isPlayDownloadPath(rel string) bool {
	rel = strings.TrimPrefix(rel, "/")
	return rel == playDownloadRel || strings.HasPrefix(rel, playDownloadRel+"/")
}

// mediaProviderPkgs and mediaProviderDBNames name MediaProvider's own index databases. docs/product-decisions.md,
// 2026-11-10, "DECIDED: MediaProvider's databases leave the seal and the restore; nothing in a sign-in writes
// MediaProvider's database, and media not yet downloaded is announced through MediaStore": the new user's
// MediaProvider is already running when the restore lands, and it holds no file lock on its database, so every
// outside write lands under the live provider (lynx 2026111001: the CE restore truncated external.db and its
// -wal/-shm in place -> SQLITE_IOERR_FSTAT and a corrupt index). MediaProvider builds its index by scanning, as for
// a new user. Like playDownloadRel this is a by-name exclusion of another app's files, not a list to grow: a
// rename of the module or the files makes the skip silent and the files roam again.
var (
	mediaProviderPkgs = map[string]bool{
		"com.android.providers.media.module":        true,
		"com.google.android.providers.media.module": true,
	}
	mediaProviderDBNames = map[string]bool{
		"external.db": true, "external.db-wal": true, "external.db-shm": true, "external.db-journal": true,
		"internal.db": true, "internal.db-wal": true, "internal.db-shm": true, "internal.db-journal": true,
	}
)

// isMediaProviderDBRel reports whether rel (slash form, relative to a CE or #de scope root) is exactly
// <pkg>/databases/<db><sfx> for a MediaProvider module, external.db or internal.db, and "", -wal, -shm or
// -journal. Nothing else: not the databases dir, not another file in it, and not the same names deeper (so the
// #media scope, whose rels start at Android/ or a user folder, never matches). NWP-20261202-02: every seal walker
// skips these files (priced for the shrink guard, as Play's cache) and untarFrom never writes them.
func isMediaProviderDBRel(rel string) bool {
	parts := strings.Split(strings.TrimPrefix(rel, "/"), "/")
	return len(parts) == 3 && mediaProviderPkgs[parts[0]] && parts[1] == "databases" && mediaProviderDBNames[parts[2]]
}

// isMediaCachePath reports whether rel lives inside a media-daemon DERIVED cache -- ANY path segment that starts
// with mediaCacheDirName, i.e. `.nowhere-media` (CE) OR `.nowhere-media-ext` (external #media). Such a rel is
// never legit user data: real media seals under a CLEAN app rel, and the caches are reconstructible from the
// store. A DEFERRED entry keyed by a cache path is a #400 bug artifact (the ext cache was sealed before
// walkChunks skipped it) whose torn Size blocks re-materialize forever -- pushProfile drops those so a profile
// sealed before the fix self-heals. Safe as a drop predicate precisely because no legit rel is ever a cache path.
func isMediaCachePath(rel string) bool {
	for _, seg := range strings.Split(rel, "/") {
		if strings.HasPrefix(seg, mediaCacheDirName) {
			return true
		}
	}
	return false
}

// mediaUndersFile (DIA-20260816-13) is the leaf name, under NOWHERE_STATE, where mediad publishes the
// AUTHORITATIVE overlay map: one "<mountpoint>\t<hidden real dir>" line per live media overlay, appended as
// each is mounted and removed at teardown.
//
// WHY THIS EXISTS. The seal walk has to know what lies UNDER each FUSE overlay, and it used to reconstruct
// that by re-deriving the mangled cache path from `src`. That derivation is only correct when src IS the user
// dir (the CE scope). For the EXTERNAL scope the binds live under a different root AND a different cache dir,
// so the derived path never existed, walkChunks SkipDir'd the whole subtree, and the manifest collapsed --
// measured on lynx 2026081603 as "walk saw 0 path(s)", a 2-chunk manifest against a stored 86, and 24+
// consecutive refusals in one session (docs/seal-refusal-investigation.md). mediad already HOLDS both paths
// at mount time (mediaMount{target, hidden}); publishing them removes the guess entirely rather than making
// it cleverer -- the same guess has now produced two separate incidents (#135 and this one).
const mediaUndersFile = "media-unders"

// mediaProgressFile is the leaf name (under NOWHERE_STATE, the RAM tmpfs) where mediad publishes on-access
// fetch progress (#90) and the login daemon reads it for GET-MEDIA-STATUS. Both processes resolve it against
// the same $NOWHERE_STATE, so the string must agree.
const mediaProgressFile = "media.progress"

// mediaAppProgFile (#129 P5) is the per-app materialize progress (leaf under NOWHERE_STATE): Sigma chunk bytes
// done/total for each app being Tier-2 prefetched, one line "app done total FETCHING|DONE". The login daemon
// relays it (GET-MEDIA-APP-PROGRESS); the chooser feeds it to the Launcher3 icon ring (P6). Distinct from the
// single dominant-fetch media.progress (#90) -- that's one notification, this is N per-app rows.
const mediaAppProgFile = "media.appprog"

// mediaRestoreOKFile (NWP-20260822-05) is the leaf, under NOWHERE_STATE, where a #media RESTORE records that
// it finished CLEANLY. It exists to disambiguate the one thing mediad provably cannot judge for itself.
//
// THE AMBIGUITY: markIncomplete fires when a deferred dir has to be recreated at serve time, and that has TWO
// causes with opposite severities -- a benign #92 scar (only the dir ENTRY was lost; the bytes are intact in
// the store) and a genuinely SHORT #media come-down (the app's essential runtime files really are missing, so
// it dies at launch with "not enough storage"). markIncomplete's own comment records that mediad "can't
// locally tell the benign scar from a real short restore without a store round-trip", which #84 removed from
// the login path -- so it has always surfaced BOTH, and an unknown fraction of the user-visible "Some data
// didn't finish loading" reports (#80) therefore have no network cause at all.
//
// But the RESTORE knows. It already computes exactly this: it withholds the #72 completion receipt when any
// entry could not be written, and a network-short restore dies via fail() and never reaches the end at all.
// Carrying that one bit across costs no round trip -- it is the fact the restore already had and threw away.
//
// FAIL-DIRECTION, deliberately: absent, unreadable, or anything other than the exact marker means "assume a
// real short restore" -- i.e. today's behaviour. This file can only ever REMOVE a false alarm, never suppress
// a true one. Written fresh per restore (cleared at the start), and roamd also clears it at roam-in, because
// NOWHERE_STATE is tmpfs that survives a LOGOFF and a stale "ok" from the previous session would be exactly
// the kind of inherited-receipt bug NWP-20260821-15 had to design around.
const mediaRestoreOKFile = "media.restore-ok"

// mediaRestoreWasClean reports whether the #media restore for THIS session finished with everything written.
// Any doubt answers false, which preserves the pre-NWP-20260822-05 behaviour exactly.
func mediaRestoreWasClean(stateDir string) bool {
	if stateDir == "" {
		return false
	}
	b, err := os.ReadFile(filepath.Join(stateDir, mediaRestoreOKFile))
	// EXACT match, not a prefix. A prefix test accepted "okish-but-not" (caught by the test), and a reader
	// that is loose about what counts as proof-of-completion is the wrong kind of loose here -- every false
	// "clean" silently downgrades a real short restore to a benign scar.
	return err == nil && strings.TrimSpace(string(b)) == "ok"
}

// clearMediaRestoreReceipt drops this session's "#media restore was clean" receipt before a #media restore
// begins, so every abnormal exit (a fail() on a short network, a panic, a kill) leaves it ABSENT -- which
// mediad reads as "assume a real short restore". Other phases never own the file and leave it untouched.
// NWP-20261014-26 (moved out of main()'s restore case so it is testable; NWP-20260822-05 is the design).
func clearMediaRestoreReceipt() {
	if os.Getenv("NOWHERE_PHASE") == "media" {
		if st := os.Getenv("NOWHERE_STATE"); st != "" {
			os.Remove(filepath.Join(st, mediaRestoreOKFile))
		}
	}
}

// finishRestore is the restore case's completion block, lifted out of main() so the fail direction is
// testable: an INCOMPLETE restore (skipped > 0) writes NO #72 receipt, NO login roster and NO media
// clean-receipt. NWP-20261014-26.
func finishRestore(profile, pass, restoredHead string, skipped int) {
	if skipped > 0 {
		fmt.Printf("restore: profile %s INCOMPLETE -- %d entr%s could not be written (see [restore] skip lines above). NOT recording a restore receipt: the next seal will be refused so this session cannot overwrite the stored profile.\n",
			logProfile(profile), skipped, map[bool]string{true: "y", false: "ies"}[skipped == 1])
	} else {
		// NWP-20260820-28: the head we ACTUALLY restored, already in hand. This used to re-run the whole
		// ladder (headKey probe + getRef) after the restore had finished, for a diagnostics-only label.
		writeRestoreReceipt(profileRefV2(profile, pass), restoredHead)
		// NWP-20260908-13: and the LOGIN ROSTER, which a seal must never advance. Same value today, but the
		// receipt answers "do I hold the current head" and moves with every seal, while the carry needs
		// "what was I given" and must not. Only a COMPLETE restore reaches here -- the skipped>0 arm above
		// returns without either -- so the roster can never read a short restore as the user deleting what
		// it failed to fetch.
		writeLoginRoster(profileRefV2(profile, pass), restoredHead)
		// NWP-20260822-05: and tell mediad this #media restore was CLEAN, so a deferred dir it later has to
		// recreate is judged a benign #92 scar rather than a short come-down. Reached only with skipped==0
		// and no earlier fail(), which is precisely the definition of "everything the manifest named was
		// written". Best-effort: a write failure just leaves mediad on its previous, more cautious answer.
		if os.Getenv("NOWHERE_PHASE") == "media" {
			if st := os.Getenv("NOWHERE_STATE"); st != "" {
				if err := os.WriteFile(filepath.Join(st, mediaRestoreOKFile), []byte("ok\n"), 0o600); err != nil {
					fmt.Fprintf(os.Stderr, "[restore] media clean-receipt write failed: %v\n", errCode(err))
				} else {
					// NWP-20260822-07: say that we wrote it. Silence here cost a whole flash cycle: roamd's
					// clear was mis-placed AFTER this restore, so the receipt was written and then deleted
					// every login, mediaRestoreWasClean always answered false, and the cause-separation ran
					// INERT while everything reported success. With this line, "wrote it" followed by an
					// absent file is a visible contradiction instead of an invisible one.
					fmt.Fprintf(os.Stderr, "[restore] media clean-receipt written (NWP-20260822-05)\n")
				}
			}
		}
	}
}

type mediaServer struct {
	base     string                  // the store the agent reads (cap/managed or S3), as any getChunk caller passes
	dk       []byte                  // the profile data key (resolveDK) -- unseals the chunks
	version  int                     // manifest version, for unpackChunk
	deferred map[string]deferredFile // rel -> its deferred record (chunk hashes + size/mode/mtime)
	cacheDir string                  // CE-per-user local cache of fetched files (content-addressed names)

	mu          sync.Mutex              // guards locks + offsets + prefetching + damaged
	locks       map[string]*sync.Mutex  // per-cache-key: coalesce concurrent opens of the same file onto one fetch
	offsets     map[string][]int64      // per-cache-key plaintext chunk start offsets (Pz prefix sums, #84 P4)
	prefetching map[string]bool         // per-cache-key: a background whole-file prefetch is already running (#84 P4b)
	lastEvict   time.Time               // #84 P5: throttle the cache-size scan (guarded by mu)
	damaged     map[string]map[int]bool // #109: per-cache-key set of chunks PROVEN corrupt in the store (sticky)
	deleted     map[string]bool         // #84: rel -> the app UNLINKED this deferred file (tombstoned; dropped at next seal)
	tombMu      sync.Mutex              // NWP-20261127-06: one .deleted append at a time (the torn-line repair reads, then writes)
	landMu      sync.Mutex              // NWP-20261202-17: the late heal's landing and a stub Unlink, one at a time

	progMu      sync.Mutex           // #90: guards active + dmg + the progress file
	scarLogged  map[string]bool      // NWP-20260822-05: apps whose recreated dir was judged a benign #92 scar (log once)
	progPath    string               // $NOWHERE_STATE/media.progress ("" disables publishing, e.g. unit tests)
	appProgPath string               // #129 P5: $NOWHERE_STATE/media.appprog per-app progress ("" disables)
	active      map[string]fetchProg // #90: cache-key -> a big (whole-file / prefetch) fetch in flight
	dmg         map[string]string    // #110: cache-key -> basename of a file with corrupt chunks (published DAMAGED)
	incomplete  map[string]bool      // DIA-20260730: app whose deferred dir had to be RECREATED (short restore) -> published INCOMPLETE
	lastAppProg time.Time            // #128: throttle publishAppProg from per-chunk progSet (guarded by progMu)
	restoring   struct {             // NWP-20261201-14: the #media lander's numbers, published RESTORING (guarded by progMu)
		done, total int64
		left        int
	}
}

// errDamagedChunk marks a fetch failure as PERMANENT store corruption (verified-hash mismatch after retries,
// GCM auth failure, or a plaintext/manifest length mismatch) -- as opposed to a transient network error.
// #109: a read that hits a damaged chunk fails FAST on later attempts (no store round-trip), and the
// background prefetch SKIPS damaged chunks instead of stopping, so the rest of the file still warms. Without
// this, every search over the file re-downloaded + re-failed the same corrupt blob (the nfctest "every NY
// search slow" loop, 2026-07-05).
var errDamagedChunk = errors.New("chunk is corrupt in the store")

// isCorruptErr classifies a fetch failure: true = the STORE CONTENT is provably bad (retry is useless),
// false = transient (network/offline -- retry may succeed). The matched strings are the panic/fail messages
// of getChunk (content-hash mismatch after 3 verified refetches, #207), unseal (GCM auth / truncated blob).
func isCorruptErr(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "corrupt chunk in store") ||
		strings.Contains(msg, "message authentication failed") ||
		strings.Contains(msg, "blob too short") ||
		strings.Contains(msg, "!= Pz") || // fetchChunkAt: plaintext length disagrees with the manifest
		strings.Contains(msg, "unpack chunk") // decompression failed on successfully-unsealed content
}

// markDamaged records chunk i of key as proven-corrupt (sticky for this mediad's lifetime -- a re-login
// retries once, in case the store was repaired) and publishes the DAMAGED status for the chooser (#110).
func (s *mediaServer) markDamaged(key, rel string, i int) {
	s.mu.Lock()
	if s.damaged == nil {
		s.damaged = map[string]map[int]bool{}
	}
	if s.damaged[key] == nil {
		s.damaged[key] = map[int]bool{}
	}
	first := len(s.damaged[key]) == 0
	s.damaged[key][i] = true
	s.mu.Unlock()
	if first {
		if i < 0 {
			dlog("mediad: %q is CORRUPT in the store -- marking damaged, no more retries (restore a snapshot to repair)", rel)
		} else {
			dlog("mediad: %q chunk %d is CORRUPT in the store -- marking damaged, no more retries (restore a snapshot to repair)", rel, i+1)
		}
	}
	s.progMu.Lock()
	defer s.progMu.Unlock()
	if s.progPath == "" {
		return
	}
	if s.dmg == nil {
		s.dmg = map[string]string{}
	}
	s.dmg[key] = path.Base(rel)
	s.writeProg()
}

// setRestoring publishes the lander's progress (NWP-20261201-14): numbers only, and left 0 ends the line.
func (s *mediaServer) setRestoring(done, total int64, left int) {
	s.progMu.Lock()
	defer s.progMu.Unlock()
	if s.progPath == "" {
		return
	}
	s.restoring.done, s.restoring.total, s.restoring.left = done, total, left
	s.writeProg()
}

// markBgDamaged publishes a corrupt rel the lander met as the DAMAGED line (§6). Its dmg key is never a cache key, and
// it logs nothing: markDamaged's log line names the rel.
func (s *mediaServer) markBgDamaged(rel string) {
	s.progMu.Lock()
	defer s.progMu.Unlock()
	if s.progPath == "" {
		return
	}
	if s.dmg == nil {
		s.dmg = map[string]string{}
	}
	s.dmg["bg:"+rel] = path.Base(rel)
	s.writeProg()
}

// markIncomplete records that a deferred dir had to be RECREATED because it was absent on disk at serve time.
// Unlike a #92 scar (only the dir ENTRY was lost; the data is intact in the store), a genuinely SHORT #media
// come-down can leave the app's ESSENTIAL runtime files (e.g. Unity il2cpp global-metadata.dat) missing -> the
// app fails at launch with a cryptic "not enough storage to install required resources" (DIA-20260730). mediad
// can't locally tell the benign scar from a real short restore without a store round-trip (which would reintroduce
// the login latency #84 removed), so it keeps serving -- but it must NOT do so SILENTLY. Surface it on the SAME
// progress channel the chooser polls (GET-MEDIA-STATUS), so a partial restore is VISIBLE. Sticky for the session;
// a rare false-positive on a true #92 scar is benign (the data is still fetchable and the app still works).
func (s *mediaServer) markIncomplete(app string) {
	if app == "" {
		app = "?"
	}
	s.progMu.Lock()
	defer s.progMu.Unlock()
	if s.incomplete == nil {
		s.incomplete = map[string]bool{}
	}
	// NWP-20260822-05: if THIS session's #media restore finished cleanly, a recreated dir cannot be a short
	// come-down -- everything the manifest named was written. It is the benign #92 scar, so log it and do NOT
	// raise the user-facing INCOMPLETE. Without this split, #80 ("Some data didn't finish loading") mixes two
	// causes with opposite severities and cannot be measured against any network change.
	if mediaRestoreWasClean(os.Getenv("NOWHERE_STATE")) {
		if !s.scarLogged[app] {
			dlog("mediad: deferred dir recreated for %q, but this session's #media restore completed cleanly "+
				"-- treating as a #92 dir-entry scar, NOT a short restore (NWP-20260822-05)", app)
			if s.scarLogged == nil {
				s.scarLogged = map[string]bool{}
			}
			s.scarLogged[app] = true
		}
		return
	}
	if !s.incomplete[app] {
		dlog("mediad: restore INCOMPLETE for %q -- deferred dir recreated; app-essential files may be missing (reconnect to finish loading)", app)
	}
	s.incomplete[app] = true
	if s.progPath != "" {
		s.writeProg()
	}
}

// isDamaged reports whether chunk i of key was already proven corrupt (-> fail fast, no refetch).
func (s *mediaServer) isDamaged(key string, i int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.damaged[key][i]
}

// hasDamaged reports whether key has any proven-corrupt chunk (-> don't restart its prefetch).
func (s *mediaServer) hasDamaged(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.damaged[key]) > 0
}

// ---- #90: on-access fetch progress, surfaced to the user as an ongoing notification ----
//
// A legacy whole-file fetch or a background prefetch of a multi-GB map can run for minutes with zero UI (on
// the FP3, OrganicMaps showed a blank map for ~20min during the first-open storm). mediad publishes the
// current big-fetch's progress to a one-line file in the RAM state tmpfs ($NOWHERE_STATE/media.progress); the
// login daemon relays it over GET-MEDIA-STATUS and the chooser posts a cross-user progress notification into
// the roamed session, auto-dismissed when the file goes idle (removed). ONLY the two big-fetch paths tick --
// a lone foreground range read is ~1 chunk and finishes before a poll, and surfacing it would flash a
// misleading "1MB / 2.9GB". Concurrent fetches are tracked together; the published line names the one with the
// most bytes still to go (the dominant download) and counts the rest.
type fetchProg struct {
	name        string
	app         string // #128: owning app package (pinnedApp(rel)) -> the icon ring's LIVE in-flight bytes
	done, total int64
}

// progSet records/updates key's in-flight progress and republishes the status file. No-op when progPath is
// unset (unit tests, or a mediad launched without NOWHERE_STATE).
func (s *mediaServer) progSet(key, rel string, done, total int64) {
	s.progMu.Lock()
	if s.progPath == "" {
		s.progMu.Unlock()
		return
	}
	if s.active == nil {
		s.active = map[string]fetchProg{}
	}
	s.active[key] = fetchProg{name: path.Base(rel), app: pinnedApp(rel), done: done, total: total}
	s.writeProg()
	// #128 smoothness: advance the app icon ring per chunk (the fetch's LIVE bytes on the fixed materialize
	// base). Throttled to ~700ms -- the chooser only relays it ~1s, so a per-chunk progSet need not rescan the
	// deferred set every chunk. publishAppProg is called AFTER releasing progMu (it takes progMu itself).
	pub := time.Since(s.lastAppProg) > 700*time.Millisecond
	if pub {
		s.lastAppProg = time.Now()
	}
	s.progMu.Unlock()
	if pub {
		s.publishAppProg()
	}
}

// progDone drops key from the in-flight set and republishes (removing the file when nothing is left).
func (s *mediaServer) progDone(key string) {
	s.progMu.Lock()
	defer s.progMu.Unlock()
	if s.progPath == "" {
		return
	}
	delete(s.active, key)
	s.writeProg()
}

// publishAppProg (#129 P5) republishes per-app Tier-2 materialize progress: for every prefetch (Tier-2)
// deferred file, sum its plaintext Size into the app's total, and into done once it's materialized
// (tombstoned). One line per app "app done total FETCHING|DONE"; the file is removed when nothing is Tier-2.
// The TOTAL is the app's whole Tier-2 set -- known up front -> the ring is MONOTONIC (it never jumps backward).
// #128: on top of that fixed base it adds the IN-FLIGHT fetch's LIVE bytes to done, so the ring advances per
// CHUNK within a file, not just per file-land. STATELESS (recomputed from s.deferred + tombstones + s.active
// each call) so repeat passes don't double-count. No-op when appProgPath is unset (unit tests / no NOWHERE_STATE).
func (s *mediaServer) publishAppProg() {
	if s.appProgPath == "" {
		return
	}
	type ap struct{ done, total int64 }
	agg := map[string]*ap{}
	for rel, d := range s.deferred {
		if d.Tier != int(tierPrefetch) {
			continue
		}
		a := pinnedApp(rel)
		if agg[a] == nil {
			agg[a] = &ap{}
		}
		agg[a].total += d.Size
		if s.isDeleted(rel) {
			agg[a].done += d.Size
		}
	}
	// #128 smoothness: add each in-flight fetch's LIVE partial to its app's done (the fetching file is already
	// counted in the base total, so add only the partial; cap at total). Monotonic: when the file lands it moves
	// from a live partial to a materialized full via the base above. progMu is taken alone here -- isDeleted
	// above already released s.mu -- so there is no lock inversion. progDone deliberately does NOT publish, so
	// the brief progDone->markDeleted window never broadcasts a dip (media.appprog keeps its last good value).
	s.progMu.Lock()
	for _, p := range s.active {
		if a := agg[p.app]; a != nil {
			a.done += p.done
			if a.done > a.total {
				a.done = a.total
			}
		}
	}
	s.progMu.Unlock()
	if len(agg) == 0 {
		os.Remove(s.appProgPath)
		return
	}
	// NWP-20260902-02: report only what is STILL IN FLIGHT. A settled app was written out forever as
	// "<app> <done> <total> DONE", and the file was removed only when there were NO tier-2 entries at all --
	// which never happens while anything is pinned for offline use. Both readers take a non-empty, non-"IDLE"
	// reply as "a prefetch is running", so the "Downloading offline media" notice -- setOngoing(true), and so
	// NOT swipe-dismissable -- stayed up from the first prefetch until logoff, with Launcher3's icon ring
	// stuck at 100% beside it. (Chester, NW-56d64ab6cab3: "why the 'downloading offline media' doesn't go
	// away?" -- mediad.log had logged "prefetch materialize complete -- 22 file(s) now local" an hour before.)
	//
	// FIXED IN THE PRODUCER, DELIBERATELY, NOT IN THE TWO READERS. The status token existed and said DONE;
	// both consumers ignore it -- ChooserActivity tests `!ap.equals("IDLE")`, and the Launcher3 ring patch
	// parses fields 0-2 and never looks at field 3. Teaching each reader the token separately leaves the next
	// reader to relearn it: the same shape as NWP-20260901-20, where update_engine's real status strings were
	// UPDATE_STATUS_*-prefixed and the parser matched none of them. Whether work is in progress is the
	// producer's fact to state, so a finished app simply leaves the list.
	//
	// The WIRE FORMAT IS UNCHANGED (4 space-separated fields): the Launcher3 ring patch splits on it and is
	// applied out of repo. Only which ROWS appear changes, and an app leaving the payload is already how that
	// ring clears -- so the patch needs no update.
	out := ""
	for a, p := range agg {
		if p.done >= p.total {
			continue // settled -- not progress, and saying so forever is the bug
		}
		out += fmt.Sprintf("%s %d %d %s\n", a, p.done, p.total, "FETCHING")
	}
	if out == "" {
		os.Remove(s.appProgPath) // nothing in flight -> the verb answers IDLE and every reader clears
		return
	}
	tmp := s.appProgPath + ".tmp"
	if os.WriteFile(tmp, []byte(out), 0o600) == nil {
		os.Rename(tmp, s.appProgPath)
	}
}

// writeProg atomically publishes the dominant active fetch (+ any damaged verdict, #110), or removes the file
// when there is nothing to say. Caller holds progMu.
func (s *mediaServer) writeProg() {
	if len(s.active) == 0 && len(s.dmg) == 0 && len(s.incomplete) == 0 && s.restoring.left == 0 {
		os.Remove(s.progPath)
		return
	}
	var lines string
	if len(s.active) > 0 {
		// Dominant = the fetch with the most bytes still to go (the big map, not a small file that snuck in).
		var dom fetchProg
		best := int64(-1)
		for _, p := range s.active {
			if r := p.total - p.done; r > best {
				best, dom = r, p
			}
		}
		// One line: "LOADING <done> <total> <nfiles> <name>". name is last so a reader splits the first 4 fields
		// and keeps the remainder (a media basename may contain spaces).
		lines = fmt.Sprintf("LOADING %d %d %d %s\n", dom.done, dom.total, len(s.active), dom.name)
	}
	if len(s.dmg) > 0 {
		// #110: "DAMAGED <nfiles> <name>" -- a file with store-corrupt chunks (deterministic; #109 stopped
		// retrying it). Sticky for the session; the chooser surfaces it once with the snapshot-restore remedy.
		// Name = the lexicographically-first damaged file, so the published line is deterministic.
		first := ""
		for _, n := range s.dmg {
			if first == "" || n < first {
				first = n
			}
		}
		lines += fmt.Sprintf("DAMAGED %d %s\n", len(s.dmg), first)
	}
	if len(s.incomplete) > 0 {
		// DIA-20260730: "INCOMPLETE <napps> <app>" -- a fresh #media restore came down SHORT (a deferred dir had
		// to be recreated), so an app's essential deferred files may be missing. Sticky for the session; the
		// chooser surfaces it with a "reconnect and reload your data" remedy. App = lexicographically-first, so
		// the published line is deterministic (same convention as DAMAGED).
		first := ""
		for a := range s.incomplete {
			if first == "" || a < first {
				first = a
			}
		}
		lines += fmt.Sprintf("INCOMPLETE %d %s\n", len(s.incomplete), first)
	}
	if s.restoring.left > 0 {
		// NWP-20261201-14: "RESTORING <done B> <total B> <files left>" -- the #media lander. Numbers only (§6).
		lines += fmt.Sprintf("RESTORING %d %d %d\n", s.restoring.done, s.restoring.total, s.restoring.left)
	}
	tmp := s.progPath + ".tmp"
	if os.WriteFile(tmp, []byte(lines), 0o600) == nil {
		os.Rename(tmp, s.progPath) // atomic on the tmpfs -> a concurrent reader never sees a partial line
	}
}

// prefetchTriggerChunks: once a range-served file's foreground reads have faulted in this many chunks, a
// background goroutine fetches the REST of the file. Rationale: OrganicMaps opens every registered map at
// startup for a tiny header read (~1 chunk) -- that must NOT trigger a download -- but a real search scans
// the map's index across many chunks, and each cold section is a store round-trip, so the first search felt
// far slower than the old whole-file-on-open (which paid once, up front). Prefetching the rest as soon as a
// file is genuinely in use converges it to whole-file-local speed: the in-flight search increasingly hits
// already-fetched chunks, and every later search is instant. Set at 2 so a header read alone never prefetches
// (the quota-decoupling promise -- don't download maps the user never opens -- is preserved), but any real
// content access does.
const prefetchTriggerChunks = 2

func newMediaServer(base string, dk []byte, m chunkManifest, cacheDir string) *mediaServer {
	s := &mediaServer{
		base:     base,
		dk:       append([]byte(nil), dk...),
		version:  m.Version,
		deferred: m.Deferred,
		cacheDir: cacheDir,
		locks:    map[string]*sync.Mutex{},
	}
	// #84: reload any tombstones (deferred files the app unlinked). They persist to <cacheDir>/.deleted so a
	// mediad restart WITHIN the session keeps the file deleted, and the seal reads the SAME file to drop the
	// entry. Cleared implicitly on power-off/reap (tmpfs-adjacent).
	//
	// NWP-20260917-23: this used to read "kickMediad re-execs after every periodic seal", and that has been
	// FALSE since NWP-20260829-27 -- kickMediad's ctl.start is a no-op against a RUNNING service, so it
	// re-execs nothing. A mid-session restart happens only when the daemon is stopped first (cold-lock,
	// logoff) or exited on its own (nothing to serve). The tombstone reload still matters for exactly those
	// cases; only the stated reason was wrong. It is corrected here because that sentence is one of two that
	// led a reader to conclude mediad is periodically re-credentialled, which is what NWP-20260917-11 was
	// filed on.
	s.deleted = loadTombstones(cacheDir)
	return s
}

// loadTombstones reads <cacheDir>/.deleted (one rel per line) into a set. Missing/empty -> empty set.
func loadTombstones(cacheDir string) map[string]bool {
	out := map[string]bool{}
	b, err := os.ReadFile(filepath.Join(cacheDir, ".deleted"))
	if err != nil {
		return out
	}
	for _, ln := range strings.Split(string(b), "\n") {
		// NWP-20261129-46: keep the line as written. appendTombstone writes rel+"\n" exactly, and a file name may
		// begin or end in whitespace, so a trimmed key can name another file: the restart lists the deleted stub
		// again and hides that file's stub. Same defect class as NWP-20261016-43.
		if ln != "" {
			out[ln] = true
		}
	}
	return out
}

// isDeleted reports whether the app unlinked this deferred file (so it must not be served or listed).
func (s *mediaServer) isDeleted(rel string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.deleted[rel]
}

// markDeleted records an app UNLINK of a deferred file: (1) tombstone it in RAM + append to <cacheDir>/.deleted
// so the next seal drops the entry from Deferred (the store bytes GC once no head references them) and a mediad
// re-exec remembers it; (2) delete its local cache (the whole-file copy + the range .part/.have sidecar) to
// free space. The store blobs are left for GC -- another profile/head may still reference the same content.
// NWP-20261127-06: the append is checked, and its error returned. The seal and a re-exec'd mediad read ONLY the
// file, so a dropped append (ENOSPC on a full phone) hid the stub this session while the seal kept it, and the
// next sign-in served the "deleted" file again. The RAM tombstone is set FIRST and kept on failure: the write-back
// callers (Create, rename, Setattr, open for write, materialize) need the stub to yield to the real file this
// session either way; Unlink, the one caller that can refuse, takes it back (unmarkDeleted). A last line cut short
// (no '\n') gets its newline before the new rel, or the two would join into one bogus line and both be lost. The
// cache is evicted only once the append landed. The error is a bare errno (no path in its text; go-fuse's
// ToErrno maps it as is). A rel already tombstoned in RAM returns nil at once.
func (s *mediaServer) markDeleted(rel string) error {
	s.mu.Lock()
	if s.deleted == nil {
		s.deleted = map[string]bool{}
	}
	first := !s.deleted[rel]
	s.deleted[rel] = true
	s.mu.Unlock()
	if !first {
		return nil
	}
	if err := s.appendTombstone(rel); err != nil {
		var en syscall.Errno
		if errors.As(err, &en) && en != 0 {
			return en
		}
		return syscall.EIO
	}
	if d, ok := s.attr(rel); ok {
		key := cacheKey(d)
		for _, suf := range []string{"", ".part", ".have"} {
			os.Remove(filepath.Join(s.cacheDir, key+suf))
		}
	}
	return nil
}

// appendTombstone appends rel+"\n" to <cacheDir>/.deleted, first ending a torn last line. O_RDWR, not O_WRONLY:
// the repair reads the last byte through the same handle. Returns the first error (write before close).
func (s *mediaServer) appendTombstone(rel string) error {
	s.tombMu.Lock()
	defer s.tombMu.Unlock()
	f, err := os.OpenFile(filepath.Join(s.cacheDir, ".deleted"), os.O_APPEND|os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	line := rel + "\n"
	st, err := f.Stat()
	if err == nil && st.Size() > 0 {
		var b [1]byte
		if _, err = f.ReadAt(b[:], st.Size()-1); err == nil && b[0] != '\n' {
			line = "\n" + line
		}
	}
	if err == nil {
		var n int
		if n, err = f.Write([]byte(line)); err == nil && n != len(line) {
			err = syscall.EIO
		}
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// unmarkDeleted takes back a RAM tombstone whose append failed. Only Unlink calls it: the stub stays listed and
// served, and the app sees its unlink fail.
func (s *mediaServer) unmarkDeleted(rel string) {
	s.mu.Lock()
	delete(s.deleted, rel)
	s.mu.Unlock()
}

// attr returns a deferred file's presented size/mode/mtime straight from the manifest record, so the file
// appears to the app with its real length and DAC bits WITHOUT the bytes being local yet. getattr must never
// trigger a fetch (only open/read does), so this is a pure map lookup. The FUSE layer adds the owning uid.
func (s *mediaServer) attr(rel string) (deferredFile, bool) {
	d, ok := s.deferred[rel]
	return d, ok
}

// cacheKey is a deferred file's content address: its chunks are content-addressed, so the ordered hash list
// identifies the exact bytes. Naming the cache entry by it makes fetch idempotent across re-derivation, dedups
// identical files (two apps shipping the same map blob share one entry), and lets P5 eviction delete-by-key.
func cacheKey(d deferredFile) string {
	sum := sha256.Sum256([]byte(strings.Join(d.Chunks, "\n")))
	return hex.EncodeToString(sum[:])
}

// mediaCacheCap is an OPTIONAL hard byte cap on the fetch cache. DEFAULT 0 (no hard cap): eviction is normally
// driven by FREE SPACE, not a fixed size (mediaCacheFreeFloor) -- #84's whole point is a big store on a small
// phone, so media stays cached as long as /data has room. A FIXED 2 GiB cap (the original #84 P5) threw away
// maps on a phone with tens of GB free, so a re-searched map re-fetched from the store => 30s searches
// (nfctest 2026-07-05). $NOWHERE_MEDIA_CACHE_MAX (bytes) sets an explicit cap for a constrained device / tests.
func mediaCacheCap() int64 {
	if v := strings.TrimSpace(os.Getenv("NOWHERE_MEDIA_CACHE_MAX")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return 0 // no hard cap by default -- the free-space floor governs
}

// mediaCacheFreeFloor is how much FREE space to keep on the cache filesystem. evictCache trims the oldest
// cached media only when free space would fall below this -- so on a phone with room to spare NOTHING is
// evicted and hot maps stay fast. Default 2 GiB; $NOWHERE_MEDIA_CACHE_MIN_FREE (bytes) overrides, 0 disables
// the free-space trigger (then only an explicit NOWHERE_MEDIA_CACHE_MAX cap, if any, evicts).
func mediaCacheFreeFloor() int64 {
	if v := strings.TrimSpace(os.Getenv("NOWHERE_MEDIA_CACHE_MIN_FREE")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return 2 << 30 // keep 2 GiB free on /data
}

// evictCache trims the fetch cache ONLY under storage pressure: it deletes the OLDEST complete cache entries
// (approx-LRU by mtime; a re-fetch gets a fresh mtime so hot files self-protect) until free space on the cache
// fs is back above mediaCacheFreeFloor AND (if an explicit NOWHERE_MEDIA_CACHE_MAX is set) the cache is under
// that hard cap. On a phone with room to spare it does NOTHING -- media stays cached, searches stay fast. Only
// TOP-LEVEL complete entries are touched -- never the `.under/` seal binds, an in-flight `.fetch-*` temp, or a
// `.part`/`.have` pair being filled (deleting a `.part` mid-fetch would strand a chunk write against an
// unlinked inode). Deleting a file an app is mid-read on is SAFE (the open fd holds the inode; next access
// re-fetches). Throttled to one scan / 15s, so it is cheap to call after every fetch. Best-effort.
//
// keep is the cache path the caller has just landed and is about to return ("" = none): it still COUNTS toward
// the cap and the free-space measure (it occupies that disk) but is never deleted, so a caller never hands back
// a path this call removed. Under a cap smaller than keep, or a floor no deletion can reach, every OTHER
// complete entry goes and keep stays. A caller passes the path it is about to return.
func (s *mediaServer) evictCache(keep string) {
	capBytes := mediaCacheCap()    // optional hard cap (0 = none)
	floor := mediaCacheFreeFloor() // keep this much free (0 = disabled)
	if capBytes <= 0 && floor <= 0 {
		return // eviction fully disabled
	}
	s.mu.Lock()
	if !s.lastEvict.IsZero() && time.Since(s.lastEvict) < 15*time.Second {
		s.mu.Unlock()
		return
	}
	s.lastEvict = time.Now()
	s.mu.Unlock()

	freeBytes := int64(-1)
	var st syscall.Statfs_t
	if syscall.Statfs(s.cacheDir, &st) == nil {
		freeBytes = int64(st.Bavail) * int64(st.Bsize)
	}
	ents, err := os.ReadDir(s.cacheDir)
	if err != nil {
		return
	}
	type ce struct {
		path  string
		size  int64
		mtime int64
	}
	var files []ce
	var total int64
	for _, e := range ents {
		// Only COMPLETE cache entries (name == a 64-hex cacheKey, no dot). Skip the `.under` bind subdir, an
		// in-flight `.fetch-*` temp, and a range `.part`/`.have` pair being actively filled.
		if e.IsDir() || strings.Contains(e.Name(), ".") {
			continue
		}
		fi, ierr := e.Info()
		if ierr != nil {
			continue
		}
		p := filepath.Join(s.cacheDir, e.Name())
		total += fi.Size()
		if p == keep {
			continue // the entry the caller just landed: counted above, never a candidate
		}
		files = append(files, ce{p, fi.Size(), fi.ModTime().UnixNano()})
	}
	overCap := func() bool { return capBytes > 0 && total > capBytes }
	lowFree := func() bool { return floor > 0 && freeBytes >= 0 && freeBytes < floor }
	if !overCap() && !lowFree() {
		return // room to spare -> keep everything cached (the common case on a spacious phone)
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mtime < files[j].mtime }) // oldest first
	for _, f := range files {
		if !overCap() && !lowFree() {
			break
		}
		if os.Remove(f.path) == nil {
			total -= f.size
			if freeBytes >= 0 {
				freeBytes += f.size
			}
			// a cache file name is a derived key (cacheKey), not the user's file name
			dlog("mediad: evicted %s (%d bytes) under storage pressure -- free=%d floor=%d cap=%d total=%d", filepath.Base(f.path), f.size, freeBytes, floor, capBytes, total)
		}
	}
}

// fetchFile makes sure rel's bytes are in the local cache and returns the cache path. Idempotent: a full cache
// hit (the file present at its recorded size) skips the network entirely. Concurrent opens of the same file
// coalesce onto ONE fetch (per-key lock), so two threads -- or the app re-opening a map -- never double-fetch.
func (s *mediaServer) fetchFile(rel string) (string, error) {
	d, ok := s.deferred[rel]
	if !ok {
		return "", fmt.Errorf("mediad: %q is not a deferred file", rel)
	}
	cp := filepath.Join(s.cacheDir, cacheKey(d))
	if fi, err := os.Stat(cp); err == nil && fi.Size() == d.Size {
		return cp, nil // already fully cached
	}
	lk := s.lockFor(cacheKey(d))
	lk.Lock()
	defer lk.Unlock()
	if fi, err := os.Stat(cp); err == nil && fi.Size() == d.Size {
		return cp, nil // another caller fetched it while we waited on the lock
	}
	// #109: a pre-Pz entry has no per-chunk skipping -- one corrupt chunk means the WHOLE file can never
	// materialize. Fail fast on later opens (chunk -1 = the file-level damaged mark) instead of re-downloading
	// gigabytes just to hit the same bad blob.
	if s.isDamaged(cacheKey(d), -1) {
		return "", fmt.Errorf("mediad: %q: %w (not retrying)", rel, errDamagedChunk)
	}
	dlogv("mediad: WHOLE-FILE fetch %q (%d bytes) -- pre-Pz entry, no range map, fetching entire file", rel, d.Size) // #84 search trace (NOWHERE_MEDIA_DEBUG)
	if err := s.fetchToCache(rel, d, cp); err != nil {
		if isCorruptErr(err) {
			s.markDamaged(cacheKey(d), rel, -1)
			return "", fmt.Errorf("mediad: %q: %w: %v", rel, errDamagedChunk, err)
		}
		return "", err
	}
	s.evictCache(cp) // #84 P5: bound the cache after adding a whole file (throttled; keeps cp, the file it returns)
	return cp, nil
}

// materializePins (#108, immediate materialize) makes a PINNED app's deferred media LOCAL: for each pinned
// app's deferred file it fetches the file to the cache, writes the real bytes into the passthrough dir (.under),
// then tombstones the stub -- exactly the #84 write-back materialize, driven in bulk. The next seal walks the
// now-real files and (P1) keeps them essential (pinned), so they stop being deferred and restore at login.
// undersByDir maps each live overlay's rel dir -> its .under (hidden) real path. Best-effort + SAFE per file: a
// fetch/write failure leaves that file deferred (never lost), and the tombstone is written ONLY after the real
// file has fully landed, so an interrupted materialize can never drop a stub without its replacement. Runs in a
// background goroutine (serving stays live); fetchFile already publishes #90 progress ("Loading your media").
// materialize fetches a SELECTED subset of the deferred set into their real .under locations -- up to budget,
// in STABLE sorted order (so it matches the files the seal keeps essential) -- tombstoning each stub only
// AFTER its real bytes land, so the next seal keeps them essential. Shared by #108 pin-materialize (sel =
// pinned app) and #129 Tier-2 prefetch (sel = Tier==prefetch). Best-effort + SAFE per file: a fetch/write
// failure leaves that file deferred (never lost), and the tombstone is written ONLY after the real file has
// fully landed, so an interrupted run can never drop a stub without its replacement. Runs in a background
// goroutine (serving stays live); fetchFile already publishes #90 progress. budget<=0 means no cap. label
// is for logs.
func (s *mediaServer) materialize(label string, sel func(rel string, d deferredFile) bool, budget int64, undersByDir map[string]string, stillOK func() bool) {
	rels := make([]string, 0, len(s.deferred))
	for rel := range s.deferred {
		if sel(rel, s.deferred[rel]) && !s.isDeleted(rel) {
			rels = append(rels, rel)
		}
	}
	if len(rels) == 0 {
		return
	}
	sort.Strings(rels)
	s.publishAppProg() // #129 P5: publish per-app totals up front (done=0) so the ring shows immediately
	var did int
	var matBytes int64
	for _, rel := range rels {
		if stillOK != nil && !stillOK() {
			// #129 P4: the Wi-Fi + idle/charging gate dropped mid-run -> PARK at this file boundary. The
			// previous file's fetch already finished atomically (temp+rename), so nothing partial is left; the
			// un-materialized rest stays deferred and mediad serves it on-demand until re-armed. (nil = never
			// pause -- pins always materialize.)
			dlog("mediad: %s materialize paused after %d file(s) (gate closed)", label, did)
			break
		}
		d := s.deferred[rel]
		if budget > 0 && matBytes+d.Size > budget {
			continue // over budget -> leave deferred (streams on-demand)
		}
		hidden, ok := undersByDir[path.Dir(rel)]
		if !ok {
			continue // no live overlay for this dir -> can't write the real file safely; skip
		}
		cp, err := s.fetchFile(rel)
		if err != nil {
			dlog("mediad: %s materialize %q: fetch failed, left deferred: %v", label, rel, errCode(err))
			continue
		}
		dst := filepath.Join(hidden, path.Base(rel))
		if err := copyFile(cp, dst, os.FileMode(d.Mode)&os.ModePerm); err != nil {
			dlog("mediad: %s materialize %q: write failed, left deferred: %v", label, rel, errCode(err))
			continue
		}
		// NWP-20260829-26: charge the budget only once the bytes ACTUALLY landed. Counting at the top of
		// the loop also charged every file that then skipped (no live overlay for its dir), failed to
		// fetch, or failed to write -- so a run could stop "over budget" against bytes nothing ever wrote
		// and keep fewer files offline than the user's #108 / #129 budget allows. Silent both ways: the
		// skip logs nothing, and the budget check that later fires looks legitimate.
		matBytes += d.Size // matches the seal: every KEPT file counts
		// NWP-20260828-15: restore the RECORDED mtime. copyFile stamps the FETCH time, and that costs twice.
		// (1) The next seal's byte-carry fast path is `prev.Size == sz && prev.MTime == mt`, so a moved mtime
		// misses it and identical bytes are re-read, re-chunked and re-UPLOADED -- every login, for every
		// pinned/prefetched file. (2) A file that lands essential carries the fetch time into its ustar
		// header, changing that chunk's plaintext and defeating dedup across the whole surrounding CDC chunk.
		// Restoring the true value is also the CORRECT direction for the user: photo dates and sort order
		// survive materialization instead of collapsing to "now". Best-effort -- a failure costs a re-upload,
		// never data, so it logs and proceeds rather than leaving the file deferred.
		if mt := deferredMTimeNanos(d.MTime); mt > 0 {
			t := time.Unix(0, mt)
			if err := os.Chtimes(dst, t, t); err != nil {
				dlog("mediad: %s materialize %q: chtimes failed (re-upload next seal): %v", label, rel, errCode(err))
			}
		}
		if err := s.markDeleted(rel); err != nil { // tombstone AFTER the real file lands -> seal keeps it essential; safe order
			dlog("mediad: %s materialize %q: tombstone not persisted (RAM tombstone this session; the seal keeps the stub): %v", label, rel, errCode(err))
		}
		did++
		dlog("mediad: MATERIALIZED %s %q -> local (kept offline; restored at login)", label, rel)
		s.publishAppProg() // #129 P5: per-app progress ticks up as each file lands
	}
	if did > 0 {
		dlog("mediad: %s materialize complete -- %d file(s) now local (sealed essential at next save)", label, did)
	}
}

// materializePins (#108): keep a PINNED app's deferred media offline, up to the user's #108 byte budget.
// NWP-20260829-27: stillOK is no longer nil. A pin pass used to be UNINTERRUPTIBLE -- only killing mediad
// could stop it -- so an unpin could not call off a fetch it had just started, and on a large app that is
// gigabytes of traffic the user already asked to cancel. The caller passes a check on the pin set itself.
func (s *mediaServer) materializePins(pins map[string]bool, budget int64, undersByDir map[string]string, stillOK func() bool) {
	if len(pins) == 0 {
		return
	}
	s.materialize("pinned", func(rel string, d deferredFile) bool { return pins[pinnedApp(rel)] }, budget, undersByDir, stillOK)
}

// prefetchTier2 (#129 P3): background-prefetch Tier-2 media after login, up to the SEPARATE Tier-2 budget --
// same fetch -> .under -> tombstone path as a pin. A never-completed one stays a valid deferred stub (mediad
// still serves it on-demand). stillOK is polled between files so the P4 gate (prefetchArmed) can PAUSE it
// mid-run when Wi-Fi/charging drops.
//
// ⚠ NWP-20260829-29 corrects what NWP-20260828-17 wrote here. The old note said the next walk "re-runs
// classifyTier ... so the file is RE-DEFERRED". That is true ONLY for a file classifyDeferred accepts. For a
// path `mediaDirs` does not list -- every scoped-storage app's media, Android/media/<pkg>/... -- the walk
// answers NO at any size, the file lands ESSENTIAL, and it rides the login tar forever. Re-deferral now holds
// for those paths too, but because of the RETURN DOOR in the seal walk (redeferTier), not because classifyTier
// says so. ⚠ THE TWO MUST SHIP TOGETHER: this selector without that door is exactly the refuted design --
// it materializes the imported band and the next seal folds all of it into the login-blocking tar.
func (s *mediaServer) prefetchTier2(budget int64, undersByDir map[string]string, tiers map[string]mediaTier, pins map[string]bool, stillOK func() bool) {
	s.materialize("prefetch", func(rel string, d deferredFile) bool { return s.wantPrefetch(rel, d, tiers, pins) }, budget, undersByDir, stillOK)
}

// wantPrefetch decides whether Tier-2 should fetch this deferred file (NWP-20260829-29).
//
// The stored Tier is honoured first, exactly as before. The second clause is what makes the user's setting
// mean something for an imported profile: a record the seal could never re-tier (Tier stuck at 0 because
// classifyTier returns essential for its path, and the carry only accepts prefetch/on-demand) is still
// prefetchable if the LIVE config says so and redeferTier agrees it may return to Deferred afterwards.
//
// ⚠ THIS READS CONFIG, IT NEVER WRITES A MANIFEST. That is the whole reason it is safe where the refuted
// carry-path stamp was not: nothing here can put Tier=2 on a #204 APK or on a deny-listed file, because no
// Tier is persisted at all. The staging-dir guard is belt-and-braces -- mediad serves only the CE and
// name#media scopes, never name#apps -- but it costs nothing and states the intent.
func (s *mediaServer) wantPrefetch(rel string, d deferredFile, tiers map[string]mediaTier, pins map[string]bool) bool {
	if d.Tier == int(tierPrefetch) {
		return true
	}
	if isAppCodeStagingDir(path.Dir(rel)) {
		return false
	}
	// (a) RECOGNISED media trees, decided from the LIVE config. NWP-20260829-30 widened the predicate to cover
	// the user's scoped-storage media, so this is the clause that reaches a 2-6 MB photo. It is safe by
	// construction: classifyTier returning tierPrefetch IMPLIES classifyDeferred is true, so mediad can only
	// ever materialize a file the next walk will re-defer -- no ratchet.
	//
	// ⚠ NWP-20260829-31 -- THIS CLAUSE WAS MISSING and the omission was user-visible. Without it the only
	// route for an imported record was (b) below, whose floor is the 8 MiB APP floor, so a 2 MB photo in a
	// prefetch-configured app was not selected at all: the user set Auto, nothing happened, and it stayed that
	// way until a logoff seal stamped Tier=2 and a further login prefetched it. Two transitions to do what the
	// switch says it does now.
	if classifyTier(rel, d.Size, tiers, pins) == tierPrefetch {
		return true
	}
	// (b) UNRECOGNISED trees -- Android/data and friends, which -30 deliberately did not widen. Here the seal's
	// return door is the right question: would it let this file back out of the tar after we make it local?
	// s.deferred IS the prevDef of the next seal, so redeferTier's "already deferred" precondition holds
	// exactly when we want it to.
	t, ok := redeferTier(rel, d.Size, s.deferred, tiers, pins)
	return ok && t == tierPrefetch
}

// prefetchArmedFile is the leaf name (under NOWHERE_STATE, the RAM tmpfs) of the Tier-2 prefetch ARM flag. The
// login daemon creates/removes it on the chooser's PREFETCH-ARM/DISARM (P4); mediad reads it here.
const prefetchArmedFile = "prefetch.armed"

// prefetchArmed reports whether Tier-2 background prefetch is currently allowed (#129). The chooser ARMS it --
// the daemon creates $NOWHERE_STATE/prefetch.armed -- only on Wi-Fi + (idle or charging) (P4); mediad just
// honors it. Absent -> not armed (the default): a #129 build therefore never prefetches on cellular / at
// capacity. Polled both before starting the Tier-2 pass and between files (mid-run pause).
func prefetchArmed() bool {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(st, prefetchArmedFile))
	return err == nil
}

func (s *mediaServer) lockFor(key string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	lk := s.locks[key]
	if lk == nil {
		lk = &sync.Mutex{}
		s.locks[key] = lk
	}
	return lk
}

// fetchToCache pulls every chunk of d, unseals + unpacks it, concatenates in manifest order, and atomically
// installs the result at cp. getChunk/unseal PANIC on a corrupt blob or a bad key (a restore recovers the same
// way -- see cdcRestore); in a long-lived daemon that must NOT crash the process, so we recover it into an
// error and the caller turns it into an EIO the app can handle (design doc, "Offline reads"). Written to a
// temp file + rename, so a partial fetch (the link drops mid-map) never appears complete in the cache.
func (s *mediaServer) fetchToCache(rel string, d deferredFile, cp string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = recoveredErr(fmt.Sprintf("mediad: fetch %q failed", rel), r) // keeps the chain (NWP-20261013-05)
		}
	}()
	if e := os.MkdirAll(s.cacheDir, 0o700); e != nil {
		return e
	}
	tmp, e := os.CreateTemp(s.cacheDir, ".fetch-*")
	if e != nil {
		return e
	}
	tmpName := tmp.Name()
	defer func() { tmp.Close(); os.Remove(tmpName) }() // Remove is a harmless no-op after a successful rename
	key := cacheKey(d)
	s.progSet(key, rel, 0, d.Size) // #90: surface this whole-file fetch as a "Loading your media" notification
	defer s.progDone(key)
	var written int64
	for i, h := range d.Chunks {
		raw, ue := unpackChunk(unseal(s.dk, getChunk(s.base, h)), s.version)
		if ue != nil {
			return fmt.Errorf("mediad: unpack chunk %d/%d of %q: %w", i+1, len(d.Chunks), rel, ue)
		}
		n, we := tmp.Write(raw)
		if we != nil {
			return we
		}
		written += int64(n)
		s.progSet(key, rel, written, d.Size) // #90: advance the bar per chunk
	}
	if written != d.Size {
		return fmt.Errorf("mediad: %q size mismatch: fetched %d, manifest says %d", rel, written, d.Size)
	}
	if ce := tmp.Close(); ce != nil {
		return ce
	}
	os.Chmod(tmpName, os.FileMode(d.Mode)&os.ModePerm) // mirror the original DAC bits onto the served file
	return os.Rename(tmpName, cp)
}

// deferredDirs groups the deferred files by parent directory: dir -> its sorted basenames. The daemon mounts
// the media FUSE over each of these dirs (context= is one label per mount, so it's one mount per deferred dir)
// and the overlay presents exactly these basenames as that dir's on-demand entries (rel = dir + "/" + name).
// Sorted for stable mount ordering and deterministic tests.
func (s *mediaServer) deferredDirs() map[string][]string {
	dirs := map[string][]string{}
	for rel := range s.deferred {
		d := path.Dir(rel)
		dirs[d] = append(dirs[d], path.Base(rel))
	}
	for _, names := range dirs {
		sort.Strings(names)
	}
	return dirs
}

// mediaMountRoots returns the MAXIMAL dirs of a deferred-dir set: every dir that has no path-component
// ancestor also in the set. It is what serveMediaScope mounts, and it exists because NESTING WEDGES LOGOFF
// (NWP-20260829-04).
//
// deferredDirs() keys by path.Dir(rel), so a profile with WhatsApp yields BOTH ".../Media/WhatsApp Images"
// and ".../Media/WhatsApp Images/Sent". Mounting an overlay on each is broken in both orders, and the order
// was a coin flip because serveMediaScope ranged over the map:
//
//   - ANCESTOR FIRST -> the child's bind source lies inside a live overlay, so the bind inherits the
//     overlay's context=nowhere_media_file (mediaMountOptions) and the MS_PRIVATE that follows needs
//     `dir mounton` on that type, which no sepolicy grants. It fails EACCES ("make-private ... permission
//     denied"), mediad skips the dir, and the mount is left behind.
//   - CHILD FIRST -> the ancestor's overlay covers the child MOUNTPOINT. Mounts are keyed
//     (parent-mount, dentry), so once the ancestor is mounted every lookup of the child name resolves
//     inside the overlay filesystem and never meets the child mount at all.
//
// SO A NESTED CHILD OVERLAY HAS NEVER SERVED A BYTE, IN EITHER ORDER -- which is why collapsing the set is
// safe: it removes nothing that ever worked. What it removes is the leftover mount, which after mediad is
// SIGKILLed at logoff becomes a DEAD FUSE mount the sweep cannot clear; the seal walk then gets ENOTCONN,
// the #media guard correctly refuses a short manifest, and the profile can never log off again (three
// consecutive refusals on lynx 2026-08-29; the only escape was a reboot that discarded the session).
//
// ⚠ THE ANCESTOR STILL DOES NOT INJECT STUBS FOR THE NESTED DIRS -- it serves them as plain passthrough,
// exactly as today. Making one overlay serve a whole subtree is a separate, larger change
// (NWP-20260829-07); this function only stops the wedge.
//
// ⚠ CALL IT ON A SET THAT HAS ALREADY HAD .appcode DROPPED. Collapse must never let an ancestor inherit the
// chooser's APK staging dir -- overlaying that is the NWP-20260825-10 destruction.
//
// Component-safe: "a/SentX" is NOT swallowed by "a/Sent". Never synthesizes an ancestor that holds no
// deferred files of its own -- that would widen the passthrough surface for free.
func mediaMountRoots(dirs map[string][]string) []string {
	keys := make([]string, 0, len(dirs))
	for d := range dirs {
		keys = append(keys, d)
	}
	sort.Strings(keys) // ancestors sort before their descendants ("a" < "a/b"), so one pass suffices
	roots := make([]string, 0, len(keys))
	for _, d := range keys {
		covered := false
		for _, r := range roots {
			if d == r || strings.HasPrefix(d, r+"/") {
				covered = true
				break
			}
		}
		if !covered {
			roots = append(roots, d)
		}
	}
	return roots
}

// ---- #84 P4: range-granular serving ----
//
// Whole-file-on-open was the P3 design ("a map DB does random reads; a store round-trip per read() would ANR
// the app"), but OrganicMaps OPENS every registered map at startup -- on the FP3 that turned one app launch
// into a full ~2.9GB re-download of the entire deferred set, every fresh session (the cache dies with the
// ephemeral user). Range serving keeps the on-access promise at CHUNK granularity instead: a read at byte
// offset O fetches only the chunk(s) covering it (Pz prefix sums), written into a SPARSE ".part" cache file
// with a ".have" per-chunk presence sidecar. Reads of present ranges are pure local pread -- the app pays one
// ~1MiB chunk fetch per new region it actually touches, and a startup header scan costs KBs, not GBs. When
// the last chunk lands, the part is PROMOTED (renamed) to the plain content-addressed cache entry, converging
// with the whole-file path. Entries without Pz (sealed before P4, carried forward since) can't be mapped --
// zstd-then-seal means Sz can't derive plaintext offsets -- so they keep whole-file-on-open.

// rangeable reports whether d carries a usable range map: Pz parallel to Chunks, all positive, summing to
// exactly Size. Anything else -> whole-file-on-open (never a corrupt range map).
func (d deferredFile) rangeable() bool {
	if len(d.Chunks) == 0 || len(d.Pz) != len(d.Chunks) {
		return false
	}
	var sum int64
	for _, n := range d.Pz {
		if n <= 0 {
			return false
		}
		sum += n
	}
	return sum == d.Size
}

// chunkOffsets returns the plaintext start offset of each chunk (prefix sums of Pz), cached per content key.
func (s *mediaServer) chunkOffsets(key string, d deferredFile) []int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.offsets == nil {
		s.offsets = map[string][]int64{}
	}
	if o, ok := s.offsets[key]; ok {
		return o
	}
	o := make([]int64, len(d.Pz))
	var off int64
	for i, n := range d.Pz {
		o[i] = off
		off += n
	}
	s.offsets[key] = o
	return o
}

// ensureRange makes the bytes [off, off+n) of rel readable locally and returns the path to pread from --
// the complete cache entry when it exists, else the sparse part file after fetching just the chunks covering
// the range. Falls back to the whole-file fetch for entries without a range map. Concurrent calls for the
// same file serialize on the per-key lock (same lock the whole-file path takes, so the two paths can never
// interleave on one entry).
func (s *mediaServer) ensureRange(rel string, off, n int64) (string, error) {
	d, ok := s.deferred[rel]
	if !ok {
		return "", fmt.Errorf("mediad: %q is not a deferred file", rel)
	}
	key := cacheKey(d)
	cp := filepath.Join(s.cacheDir, key)
	if fi, err := os.Stat(cp); err == nil && fi.Size() == d.Size {
		return cp, nil // fully cached (fetched whole, or promoted below)
	}
	if !d.rangeable() {
		return s.fetchFile(rel) // legacy pre-Pz entry -> whole-file-on-open, as before
	}
	// Clamp to the file; a read at/past EOF still needs the part file to pread 0 bytes from.
	if off < 0 {
		off = 0
	}
	end := off + n
	if end > d.Size {
		end = d.Size
	}
	lk := s.lockFor(key)
	lk.Lock()
	defer lk.Unlock()
	if fi, err := os.Stat(cp); err == nil && fi.Size() == d.Size {
		return cp, nil // promoted while we waited on the lock
	}
	pp, hp := cp+".part", cp+".have"
	if err := s.initPart(pp, hp, d); err != nil {
		return "", err
	}
	have, err := os.ReadFile(hp)
	if err != nil || len(have) != len(d.Chunks) {
		// Sidecar missing/corrupt (interrupted init, bit-rot): treat every chunk as absent -- refetching a
		// present chunk is only wasted bytes, never wrong bytes (content-addressed, verified on unseal).
		have = make([]byte, len(d.Chunks))
	}
	offs := s.chunkOffsets(key, d)
	lo := sort.Search(len(offs), func(i int) bool { return offs[i]+d.Pz[i] > off })
	for i := lo; i < len(offs) && offs[i] < end; i++ {
		if have[i] == 1 {
			continue
		}
		// #109: a chunk already proven corrupt fails FAST -- no store round-trip. Retrying is useless (the
		// store content is bad, verified after refetches) and the retry loop made every search over the file
		// slow. A fresh corrupt discovery marks it sticky + publishes DAMAGED for the chooser (#110).
		if s.isDamaged(key, i) {
			return "", fmt.Errorf("mediad: %q chunk %d/%d: %w (not retrying)", rel, i+1, len(d.Chunks), errDamagedChunk)
		}
		if err := s.fetchChunkAt(pp, d, offs, i); err != nil {
			if isCorruptErr(err) {
				s.markDamaged(key, rel, i)
				return "", fmt.Errorf("mediad: %q chunk %d/%d: %w: %v", rel, i+1, len(d.Chunks), errDamagedChunk, err)
			}
			return "", err
		}
		have[i] = 1
		markHave(hp, i)
	}
	nHave := countOnes(have)
	if nHave == len(have) {
		// Every chunk present -> promote to the plain cache entry; the whole-file path's "present at recorded
		// size" check now hits, and any fd already open on the part keeps reading the same inode.
		os.Chmod(pp, os.FileMode(d.Mode)&os.ModePerm)
		if err := os.Rename(pp, cp); err == nil {
			os.Remove(hp)
			s.evictCache(cp) // #84 P5: a whole file just completed -> bound the cache (keeps cp, the entry it returns)
			return cp, nil
		}
	} else if nHave >= prefetchTriggerChunks {
		// The file is genuinely in use (a search, a viewport pan) -> fetch the rest in the background so it
		// becomes fully local. Non-blocking: this read already has its bytes. maybePrefetch de-dups.
		s.maybePrefetch(rel, key)
	}
	return pp, nil
}

// maybePrefetch starts ONE background whole-file prefetch for key, if not already running. The goroutine
// drives every missing chunk through ensureRange (per-chunk, so foreground reads interleave between chunks
// instead of waiting behind a held lock); the last chunk it lands promotes the part to the complete entry.
// It stops on the first fetch error (offline / corrupt) -- a foreground read surfaces the real error. Bounded
// and self-terminating: it exits when the file is whole, and the session's mediad is SIGKILLed at logoff, so
// the cache (and any in-flight prefetch) dies with the ephemeral user.
func (s *mediaServer) maybePrefetch(rel, key string) {
	d, ok := s.deferred[rel]
	if !ok || !d.rangeable() {
		return
	}
	// #109: a file with a proven-corrupt chunk can never promote to complete, so every read would otherwise
	// restart this prefetch. Its first prefetch run already warmed every GOOD chunk (damaged ones are skipped
	// below); later cold reads still fetch on demand. Don't spin it again.
	if s.hasDamaged(key) {
		return
	}
	s.mu.Lock()
	if s.prefetching == nil {
		s.prefetching = map[string]bool{}
	}
	if s.prefetching[key] {
		s.mu.Unlock()
		return
	}
	s.prefetching[key] = true
	s.mu.Unlock()
	dlogv("mediad: PREFETCH start %q (%d chunks) -- warm the whole file in the background", rel, len(d.Chunks)) // #84 search trace (NOWHERE_MEDIA_DEBUG)
	goSafe("media-prefetch", func() {
		defer func() {
			s.mu.Lock()
			delete(s.prefetching, key)
			s.mu.Unlock()
		}()
		s.progSet(key, rel, 0, d.Size) // #90: surface the background prefetch (the multi-GB first-open storm)
		defer s.progDone(key)
		offs := s.chunkOffsets(key, d)
		skipped := 0
		for i := range d.Chunks {
			if _, err := s.ensureRange(rel, offs[i], d.Pz[i]); err != nil {
				// #109: a CORRUPT chunk is permanent -- skip it and keep warming the rest of the file, so
				// searches over the good parts stay fast. Only a TRANSIENT error (offline) stops the walk.
				if errors.Is(err, errDamagedChunk) {
					skipped++
					continue
				}
				dlog("mediad: PREFETCH %q STOPPED at chunk %d/%d: %v", rel, i, len(d.Chunks), errCode(err)) // #84 diag
				return
			}
			s.progSet(key, rel, offs[i]+d.Pz[i], d.Size) // cumulative plaintext bytes through chunk i
		}
		if skipped > 0 {
			dlog("mediad: PREFETCH %q finished with %d corrupt chunk(s) skipped -- file stays incomplete (restore a snapshot to repair)", rel, skipped)
			return
		}
		dlogv("mediad: PREFETCH %q COMPLETE -- fully local now", rel) // #84 search trace (NOWHERE_MEDIA_DEBUG)
	})
}

// initPart creates the sparse part file at its full size + a zeroed presence sidecar, once. A part already at its
// full size keeps its sidecar when that holds exactly one byte per chunk (the chunks it marks stay marked). A
// full-size part whose sidecar is missing, unreadable or of any other length (a write that failed on a full disk, a
// kill between the part and the sidecar, a torn write) gets a zeroed one, so marks for chunks fetched from then on
// are kept (markHave never creates the file). A repair that cannot be written changes nothing -- reads still refetch,
// as ensureRange does for a missing sidecar -- so it is logged, never returned. Every sidecar is written to
// hp+".tmp" and renamed over hp, so none is ever seen half-written.
func (s *mediaServer) initPart(pp, hp string, d deferredFile) error {
	zeroHave := func() error {
		tmp := hp + ".tmp"
		if err := os.WriteFile(tmp, make([]byte, len(d.Chunks)), 0o600); err != nil {
			os.Remove(tmp)
			return err
		}
		if err := os.Rename(tmp, hp); err != nil {
			os.Remove(tmp)
			return err
		}
		return nil
	}
	if fi, err := os.Stat(pp); err == nil && fi.Size() == d.Size {
		if have, herr := os.ReadFile(hp); herr == nil && len(have) == len(d.Chunks) {
			return nil
		}
		if err := zeroHave(); err != nil {
			// filepath.Base(pp) is a derived cacheKey name, not the user's file name
			dlog("mediad: .have repair for %q not written (%s) -- its reads refetch every chunk", filepath.Base(pp), errCode(err))
		}
		return nil
	}
	// filepath.Base(pp) is a derived cacheKey name, not the user's file name
	dlogv("mediad: fresh .part %s (%d chunks, size %d) -- cache was COLD/absent for this file", filepath.Base(pp), len(d.Chunks), d.Size) // #84 search trace (NOWHERE_MEDIA_DEBUG)
	if err := os.MkdirAll(s.cacheDir, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(pp, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := f.Truncate(d.Size); err != nil {
		return err
	}
	// (Re)zero the sidecar LAST: a part file that exists with a zeroed sidecar is always safe (chunks refetch).
	return zeroHave()
}

// fetchChunkAt fetches, unseals and unpacks chunk i and writes it at its plaintext offset in the part file.
// getChunk/unseal PANIC on a corrupt blob (same recovery contract as fetchToCache) -- recovered into an error
// so a long-lived daemon never dies on a bad chunk.
func (s *mediaServer) fetchChunkAt(pp string, d deferredFile, offs []int64, i int) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = recoveredErr(fmt.Sprintf("mediad: fetch chunk %d/%d", i+1, len(d.Chunks)), r) // keeps the chain (NWP-20261013-05)
		}
	}()
	raw, ue := unpackChunk(unseal(s.dk, getChunk(s.base, d.Chunks[i])), s.version)
	if ue != nil {
		return fmt.Errorf("mediad: unpack chunk %d/%d: %w", i+1, len(d.Chunks), ue)
	}
	if int64(len(raw)) != d.Pz[i] {
		return fmt.Errorf("mediad: chunk %d/%d length %d != Pz %d", i+1, len(d.Chunks), len(raw), d.Pz[i])
	}
	f, e := os.OpenFile(pp, os.O_WRONLY, 0o600)
	if e != nil {
		return e
	}
	defer f.Close()
	_, e = f.WriteAt(raw, offs[i])
	return e
}

// markHave flips one presence byte in the sidecar (best-effort: a lost mark only costs a refetch).
func markHave(hp string, i int) {
	f, err := os.OpenFile(hp, os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteAt([]byte{1}, int64(i))
}

func allOnes(b []byte) bool {
	return len(b) > 0 && countOnes(b) == len(b)
}

func countOnes(b []byte) int {
	n := 0
	for _, v := range b {
		if v == 1 {
			n++
		}
	}
	return n
}
