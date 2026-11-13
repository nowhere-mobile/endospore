package main

// SEAL-DELTA (#145 S3, NWP-20260901-27): everything the "What's saved" screen needs that requires NO walk,
// in one length-prefixed JSON reply ("OK <len>\n<json>", the GET-STORAGE-BREAKDOWN frame, so the chooser's
// existing length-prefix reader consumes it).
//
//	Signal 1  -- when was this phone last saved, and did it land (the stamps + the recordSeal verdict)
//	Signal 2  -- WHICH apps live on this phone with no copy in the store: the chooser diffs StoredApps
//	             against its own live keep-set. This is the #124 answer -- the difference between "safe to
//	             power off" and "about to lose an app" -- and it is exact where bytes are structurally
//	             unmeasurable (#apps has no local tree until the seal stages one).
//	plus the live run kind, the deferral count (an invisible skipped cycle, made visible), and the
//	blind-walk package list so the screen can NAME what is blocking a save.
//
// StoredApps reads the #apps head via scopeManifest behind a single-flight TTL cache: one Argon2 (~105ms)
// plus a getRef+getBlob is too much for a poll loop, and design risk #3 says never on the first frame -- the
// screen paints Signal 1 immediately and fills apps when this lands. StoredMeasured=false means COULD NOT
// READ (offline, legacy head, no #apps yet): the chooser must render "unknown", never "none" -- an
// over-claiming delta tells someone it is safe to power off when it is not.

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// #145 S6 (NWP-20260901-30): what the last manual save actually stored. The seal streams per-scope byte
// frames ("<phase> <done> <total> [<scope>]") through the progress channel and DISCARDS them at the end --
// handleBackup's onProg sees every frame, so the composition is free to keep. The figure is PLAINTEXT BYTES
// CAPTURED (chunked), not bytes uploaded -- dedup and compression shrink the wire copy -- which is why the
// UI word is "captured", never "uploaded".
// sealDeltaBase is the store the two SEAL-DELTA verbs read heads from; a var only so a test can point it at an
// in-process store.
var sealDeltaBase = "s3"

var lastSaveBytes, lastSaveAreas atomic.Int64

// #55 (NWP-20261117-18): the line built on those two figures describes the last MANUAL save, and "Last saved <ago>"
// above it moves on every landed seal. sealLandedSeq counts the seals that landed this daemon lifetime (only
// recordSealLanded's OK arm moves it, and nothing resets it); lastSaveSeq is the count the manual save behind the
// figures produced, 0 for none. SEAL-DELTA sends the figures only while the two are equal.
var sealLandedSeq, lastSaveSeq atomic.Int64

// accumSaveScope folds one progress frame into the per-scope map: the LAST frame per scope wins, which is
// that scope's final done-byte figure. A 3-field frame (no scope) belongs to no area and is ignored.
func accumSaveScope(m map[string]int64, line string) {
	f := strings.Fields(line)
	if len(f) < 4 {
		return
	}
	done, err := strconv.ParseInt(f[1], 10, 64)
	if err != nil || done < 0 {
		return
	}
	m[f[3]] = done
}

// publishSaveSummary keeps a landed manual save's composition and the landed-seal sequence its verdict produced. The
// sequence is stored LAST, so a reader that sees it also sees that save's figures.
func publishSaveSummary(m map[string]int64, seq int64) {
	var sum int64
	for _, b := range m {
		sum += b
	}
	lastSaveBytes.Store(sum)
	lastSaveAreas.Store(int64(len(m)))
	lastSaveSeq.Store(seq)
}

type sealDeltaReply struct {
	V       int    `json:"v"`
	Session string `json:"session"` // "stored" | "local"
	Verdict string `json:"verdict"` // recordSeal's vocabulary: "" (none yet) | ok | fail | nocredit | refused
	Parts   string `json:"parts,omitempty"`
	// Reason is the gateway's own refusal text behind a "nocredit" verdict (NWP-20260904-09), already bounded
	// by gatewayReason. Omitted when there is none, so an older chooser sees nothing new.
	Reason string `json:"reason,omitempty"`
	// Scopes is the last verdict's per-scope detail as GET-LOGOFF-REFUSAL's SCOPE lines, "\n"-joined:
	// `SCOPE <scope> <cause>[:<guard>] 0` (recordSeal's sealScopes; <saved> is always 0 here, per-scope save times
	// stay GET-LOGOFF-REFUSAL's). NWP-20261113-08, backlog row "Your data's save copy says the wrong thing in four
	// cases", case (2): with only Verdict and Parts the chooser could not tell a shrink-guard refusal of the vault
	// from a concurrent change. Scope and guard tokens only; omitted when empty, so an older chooser sees nothing new.
	Scopes string `json:"scopes,omitempty"`
	// LastStart / LastOK: #145 Signal 1.
	LastStart   int64            `json:"lastStart"`          // unix sec; 0 = no seal dispatched this daemon lifetime
	LastOK      int64            `json:"lastOK"`             // unix sec; 0 = none LANDED this daemon lifetime
	Run         string           `json:"run,omitempty"`      // a seal live right now ("periodic"|"logoff"|"manual"|"promote")
	RunStart    int64            `json:"runStart,omitempty"` // unix sec: the live run's own announce (sealRunAt); omitted with no run
	RunProg     string           `json:"runProg,omitempty"`  // the live run's frame "<phase> <done> <total>[ <scope>]": SEAL-STATUS line 1 less "SEALING "
	Deferrals   int64            `json:"deferrals"`
	BlindPkgs   []string         `json:"blind,omitempty"`
	StoredApps  map[string]int64 `json:"storedApps,omitempty"` // pkg -> sealed bytes in the #apps head
	StoredKnown bool             `json:"storedMeasured"`       // false = could not read -- "unknown", NEVER "none"
	LastSaveB   int64            `json:"lastSaveB,omitempty"`  // #145 S6: plaintext bytes the last manual save captured, while it is the last seal to land (#55)
	LastSaveN   int64            `json:"lastSaveN,omitempty"`  // ... across how many areas (scopes)
}

// storedAppsFromManifest maps a #apps manifest to pkg -> sealed bytes. The essential half comes from the
// Pkg index (exact, seal-computed); the deferred half (an on-demand app's carried APK set) is summed per
// package from each entry's sealed chunk sizes. First segments that are not dotted package names are
// DROPPED rather than mislabelled (design risk #2 -- Android requires a dot, and a stray staging rel must
// not become an app row; the -17 "Download is not an app" lesson). Returns nil -- distinct from empty --
// when the manifest carries neither index: nil is "not measured", and a reader must never render it as
// "nothing stored".
func storedAppsFromManifest(m chunkManifest) map[string]int64 {
	if len(m.Pkg) == 0 && len(m.Deferred) == 0 {
		return nil
	}
	out := map[string]int64{}
	for pkg, b := range m.Pkg {
		if strings.Contains(pkg, ".") {
			out[pkg] += b
		}
	}
	for rel, d := range m.Deferred {
		seg := strings.TrimPrefix(rel, "/")
		if i := strings.IndexByte(seg, '/'); i >= 0 {
			seg = seg[:i]
		}
		if !strings.Contains(seg, ".") {
			continue
		}
		for _, z := range d.Sz {
			out[seg] += z
		}
	}
	if len(out) == 0 {
		// Everything was dropped by the dotted filter: measured, and nothing attributable.
		return map[string]int64{}
	}
	return out
}

// appsHeadAbsent answers whether the store DEFINITELY holds no #apps head for (name, pass) (NWP-20261027-09): every
// rung of the head ladder (per-unit, v2, legacy) walked with the strict probe answered a definite not-found, or the
// head is a delete tombstone. scopeManifest cannot say this: its headKey resolves the ladder with the non-strict
// refProbe and its getRef reads a cap-mode 403 as absence, so "no head" and "could not read" come back as one answer.
// A transport error, a 5xx or a 403 must never read as "nothing stored" (NWP-20260903-01), so refProbeStrict panics
// on them and a panic answers false. Not one key that headKey resolved: a rung whose loose probe failed would be
// skipped, and a definite 404 on the next rung would then read as absent. The wallet asks the same question the
// same way (readStoredWalletStrict).
func appsHeadAbsent(base, name, pass string) (absent bool) {
	defer func() {
		if recover() != nil {
			absent = false
		}
	}()
	_, head, _ := headRefWith(base, name+"#apps", pass, refProbeStrict)
	return head == ""
}

// The single-flight TTL cache for the #apps head read (design risk #3: ~105ms Argon2 + two store round
// trips must not run per poll). Keyed by profile name within a session (one session, one identity);
// resetSealSignals empties it at every new sign-in, because a profile is name plus passphrase.
var sealDeltaCache struct {
	mu       sync.Mutex
	name     string
	apps     map[string]int64
	known    bool
	at       time.Time
	inFlight bool
	gen      uint64 // bumped by resetSealDeltaCaches: a refresh kicked before it publishes nothing
}

// sealDeltaRefreshHook runs at the end of the stored-apps refresh, before its publish; nil in production. A test
// sets it to begin a new identity's session while a refresh is in flight.
var sealDeltaRefreshHook func()

const sealDeltaCacheTTL = 60 * time.Second

// storedAppsCached serves the cache and refreshes it OFF the request path, single-flighted -- the reply
// never blocks on the store. First call for a profile returns (nil,false) and kicks the fetch; the poll a
// moment later is served. Mirrors kickOtaRefresh's shape. se is the session's secure-element secret: it opens a
// tied profile's re-keyed #apps head. The cache stays keyed by profile name.
func storedAppsCached(name, pass string, se []byte) (map[string]int64, bool) {
	c := &sealDeltaCache
	c.mu.Lock()
	fresh := c.name == name && time.Since(c.at) < sealDeltaCacheTTL
	apps, known := c.apps, c.known
	if c.name != name {
		apps, known = nil, false // never serve another profile's rows
	}
	kick := !fresh && !c.inFlight
	var gen uint64
	if kick {
		c.inFlight = true
		gen = c.gen
	}
	c.mu.Unlock()
	if kick {
		goSafe("seal-delta apps", func() {
			var a map[string]int64
			var ok bool
			// NWP-20261014-66: published from a defer, so a panic below still releases inFlight (as unknown) instead
			// of leaving every later call to wait on a refresh that will never land.
			defer func() {
				c.mu.Lock()
				defer c.mu.Unlock()
				if c.gen != gen {
					return // a sign-in reset the cache after this refresh began: its rows and its inFlight are not ours
				}
				c.name = name
				c.apps = a
				c.known = ok && a != nil
				c.at = time.Now()
				c.inFlight = false
			}()
			var m chunkManifest
			// This runs in the login daemon, whose environment never carries NOWHERE_SE_SECRET (NWP-20260915-12): the session's secret is passed in.
			m, ok = scopeManifest(sealDeltaBase, name+"#apps", pass, se)
			if ok {
				a = storedAppsFromManifest(m) // a panic here leaves a nil, which publishes as unknown
			} else if appsHeadAbsent(sealDeltaBase, name, pass) {
				// NWP-20261027-09: no #apps head at all (a profile before its first #apps seal) is measured, and nothing
				// is stored; every other !ok -- a failed read, a head that does not open -- stays unknown.
				a, ok = map[string]int64{}, true
			}
			if h := sealDeltaRefreshHook; h != nil {
				h()
			}
		})
	}
	return apps, known
}

func handleSealDelta(conn net.Conn, dest string) {
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	se := seFromSession(dest)
	r := sealDeltaReply{V: 1, Session: "stored"}
	if isLocalSession(dest) {
		// A throwaway is never sealed; every store-side field would be a lie of one kind or another.
		r.Session = "local"
	}
	sealMu.Lock()
	r.Verdict = sealStatus
	r.Parts = sealParts
	r.Reason = sealReason
	r.Scopes = sealScopes // NWP-20261113-08: the row's case (2), the guard behind each refused scope
	sealMu.Unlock()
	r.LastStart = lastSealStartedAt.Load()
	r.LastOK = lastSealOKAt.Load()
	pendingReapMu.Lock()
	r.Run = sealRunKind
	if sealRunKind != "" && !sealRunAt.IsZero() {
		r.RunStart = sealRunAt.Unix() // the live run's OWN start, read with its kind under one lock (not lastStart)
	}
	pendingReapMu.Unlock()
	// composeSealStatus takes pendingReapMu itself: never call it under the lock above.
	if r.Run != "" {
		if l := composeSealStatus(dest); len(l) > 0 && strings.HasPrefix(l[0], "SEALING ") {
			r.RunProg = strings.TrimSpace(strings.TrimPrefix(l[0], "SEALING "))
		}
	}
	r.Deferrals = sealDeferCount.Load()
	// #55 (NWP-20261117-18): the line describes the last MANUAL save, so it is sent only while that save is still the
	// last seal to land; a later landed seal (periodic, sign-out, promote) hides it. Sequence first, figures after:
	// publishSaveSummary stores the sequence last.
	if seq := lastSaveSeq.Load(); seq != 0 && seq == sealLandedSeq.Load() {
		r.LastSaveB = lastSaveBytes.Load()
		r.LastSaveN = lastSaveAreas.Load()
	}
	if b, err := os.ReadFile(sealBlindPkgPath()); err == nil {
		for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
			if l = strings.TrimSpace(l); l != "" {
				r.BlindPkgs = append(r.BlindPkgs, l)
			}
		}
	}
	if r.Session == "stored" {
		r.StoredApps, r.StoredKnown = storedAppsCached(name, pass, se)
	}
	out, err := json.Marshal(r)
	if err != nil {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprintf(conn, "OK %d\n", len(out))
	conn.Write(out)
}

// ---- #145 S5 (NWP-20260901-29): the changed-since-last-save walk ----

// sealDeltaIdxCache: the three data heads' Deferred indexes, cached like storedApps -- ~three key
// derivations plus six store round trips is too much per tap, and the index only moves when a seal lands.
var sealDeltaIdxCache struct {
	mu   sync.Mutex
	name string
	at   time.Time
	ok   bool
}

// resetSealDeltaCaches empties both SEAL-DELTA caches for a new identity (NWP-20261108-03). They are keyed by the
// profile NAME, and a profile is name plus passphrase: a second "sam" was served the first one's #apps rows, and the
// walk skipped its index refresh. gen++ keeps a refresh kicked before the reset from publishing afterwards.
func resetSealDeltaCaches() {
	c := &sealDeltaCache
	c.mu.Lock()
	c.name, c.apps, c.known, c.at, c.inFlight = "", nil, false, time.Time{}, false
	c.gen++
	c.mu.Unlock()
	x := &sealDeltaIdxCache
	x.mu.Lock()
	x.name, x.at, x.ok = "", time.Time{}, false
	x.mu.Unlock()
}

// sealDeltaScopeDK opens a scope's data key the way scopeManifest does: a vault head through openVaultDKSE, a
// legacy bare head with the scope's own derived key. nil when the scope has no head or the key does not open.
func sealDeltaScopeDK(base, scope, pass string, se []byte) (dk []byte) {
	defer func() {
		if recover() != nil {
			dk = nil
		}
	}()
	head := getRef(base, headKey(base, scope, pass))
	if head == "" {
		return nil
	}
	if v, isV := parseVault(getHeadBlob(base, head)); isV {
		return openVaultDKSE(v, scope, pass, se)
	}
	return deriveKey(scope, pass)
}

// handleSealDeltaWalk: dump the Deferred indexes for the worker, trigger the RO-lane walk, pass the JSON
// through with the OK-length frame. The WORKER walks (only endospore_priv can read a roamed user's
// MCS-categorised data -- the storagebreakdown lesson); the DAEMON holds the passphrase, so the index is
// written here first.
//
// Rule B's baseline (NWP-20261108-05) is the announce stamp of the last seal that LANDED this daemon lifetime
// (lastLandedSealStartedAt, written by noteSealLanded from the periodic, manual and promote paths, each with its
// own stamp). A failed, refused or skipped seal never moves it, and a seal still running has not landed, so files
// it may hold still count: the safe direction. It used to be lastSealStartedAt, stamped at EVERY announce, so a
// periodic dispatch that failed after the user took photos said "No new changes since the last save."
// NOBASE when none has landed: with no baseline the mtime rule would count every restored file, and "your whole
// profile is unsaved" at first open is the lie this feature exists to prevent.
// handleLogout records nothing: a logoff that lands ends the session (the next
// sign-in's resetSealSignals zeroes the stamp). The logoff arms that record an OK but KEEP the session (the late
// verdict after the stall unstick, the two superseded returns) leave the baseline at the previous landed seal or
// at 0: that over-counts or answers NOBASE, both the safe direction.
func handleSealDeltaWalk(conn net.Conn, dest string) {
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "LOCAL\n")
		return
	}
	se := seFromSession(dest)
	since := lastLandedSealStartedAt.Load()
	if since == 0 {
		fmt.Fprint(conn, "NOBASE\n")
		return
	}
	// Refresh the index at most once per TTL; a stale index only mis-sorts a file between the exact rule
	// and the estimate rule, and the walk's own since-filter still bounds the answer.
	if err := refreshSealDeltaIdx(dest, name, pass, se, func(at time.Time) bool { return time.Since(at) < sealDeltaCacheTTL }); err != nil {
		fmt.Fprint(conn, "ERR-IDX\n")
		return
	}
	conn.SetDeadline(time.Now().Add(60 * time.Second))
	out := strings.TrimSpace(triggerRoamWorkerKind(dest, "sealdelta", name, "", uid, "", "", fmt.Sprint(since), "", nil))
	if !strings.HasPrefix(out, "{") {
		if out == "" {
			out = "ERR-WORKER"
		}
		fmt.Fprintf(conn, "%s\n", out)
		return
	}
	fmt.Fprintf(conn, "OK %d\n", len(out))
	fmt.Fprint(conn, out)
}

// sealDeltaIdxWriteMu serialises refreshSealDeltaIdx (NWP-20261202-10): the delta screen and the periodic change test
// write the same sealdelta.idx and sealdelta.listed files.
var sealDeltaIdxWriteMu sync.Mutex

// refreshSealDeltaIdx writes the walk's index files (the three data heads' Deferred indexes and the listed files) for
// the profile, unless the cached index is this profile's and reuse accepts the time it was written. Lifted out of
// handleSealDeltaWalk (NWP-20261202-10) so the periodic change test can write the index under its own rule; the
// handler keeps its TTL rule. Any error means the index files cannot be trusted.
func refreshSealDeltaIdx(dest, name, pass string, se []byte, reuse func(at time.Time) bool) error {
	sealDeltaIdxWriteMu.Lock()
	defer sealDeltaIdxWriteMu.Unlock()
	c := &sealDeltaIdxCache
	c.mu.Lock()
	fresh := c.name == name && c.ok && reuse(c.at)
	c.mu.Unlock()
	if fresh {
		return nil
	}
	scopes := map[string]map[string]deferredFile{}
	listed := map[string]map[string]int64{}
	for scope, suffix := range map[string]string{"vault": "", "de": "#de", "media": "#media"} {
		// This runs in the login daemon, whose environment never carries NOWHERE_SE_SECRET (NWP-20260915-12): the session's secret is passed in.
		if m, ok := scopeManifest(sealDeltaBase, name+suffix, pass, se); ok {
			if len(m.Deferred) > 0 {
				scopes[scope] = m.Deferred
			}
			if scope == "media" {
				// NWP-20261126-06: the #media head lists its Deferred AND its Ess rels whenever it opens. A head with
				// Ess and no Deferred is the normal head under the essential-media carry, and must still list its files.
				lm := map[string]int64{}
				for rel, d := range m.Deferred {
					lm[rel] = d.Size
				}
				for rel, r := range m.Ess {
					if r.Size > 0 {
						lm[rel] = r.Size
					}
				}
				listed["media"] = lm
			}
		}
	}
	// NWP-20261126-06: the vault and #de scan caches list the files of 1 MiB or more that the last seal saw. A
	// scope's cache is read ONLY when no seal was dispatched after the last landed one (before and after the
	// read), and the cache is not older than that landed seal: a cache from a seal that never landed is not
	// read. Otherwise the scope's deletions are unknown, and the file says so with a #nocache line.
	var noCache []string
	for scope, suffix := range map[string]string{"vault": "", "de": "#de"} {
		started, landed := lastSealStartedAt.Load(), lastLandedSealStartedAt.Load()
		var rels map[string]int64
		if started == landed {
			if dk := sealDeltaScopeDK(sealDeltaBase, name+suffix, pass, se); dk != nil {
				p := filepath.Join(dest, "scancache."+contentCacheTagFor(dk))
				if fi, err := os.Stat(p); err == nil && fi.ModTime().Unix() >= landed {
					if b, err := os.ReadFile(p); err == nil {
						rels = map[string]int64{}
						for _, line := range strings.Split(string(b), "\n") {
							var rec scanRec
							if line != "" && json.Unmarshal([]byte(line), &rec) == nil && rec.R != "" {
								rels[rec.R] = rec.E.Size
							}
						}
					}
				}
			}
		}
		if rels == nil || lastSealStartedAt.Load() != started {
			noCache = append(noCache, scope)
			continue
		}
		listed[scope] = rels
	}
	sort.Strings(noCache)
	if err := writeSealDeltaIdx(sealDeltaIdxPath(dest), scopes); err != nil {
		return err
	}
	if err := writeSealDeltaListed(sealDeltaListedPath(dest), listed, noCache); err != nil {
		return err
	}
	c.mu.Lock()
	c.name, c.at, c.ok = name, time.Now(), true
	c.mu.Unlock()
	return nil
}
