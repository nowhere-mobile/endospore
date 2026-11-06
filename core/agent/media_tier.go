package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// On-demand media tiering (#84, P1). A roamed profile's bulk media (offline maps, ML models, downloads,
// photos) is LARGE and NOT needed to bring up a usable session, yet today it rides the login-gating CE
// restore -- so login blocks on GBs of it (profile c: 891 MB of OrganicMaps .mwm maps under
// app.organicmaps/files/). classifyDeferred decides, per file, whether it is "deferred media" -- excluded
// from the login-critical restore and served on-access from the store instead (P2/P3). This file is JUST the
// policy + the manifest shape; nothing consumes it yet (no login/seal behavior change in P1).
//
// The rule is deliberately CONSERVATIVE: a file is deferred ONLY if it is (a) big enough to matter, (b) in a
// known bulk-media subtree, and (c) NOT on the deny list of login/state-critical files. Anything unrecognized
// stays essential (restored at login), so a misclassification can only make login SLOWER, never break it.

// mediaMinBytes is the size floor for deferral (NOWHERE_MEDIA_MIN, default 8 MiB). Below this, deferring buys
// nothing (the round-trip savings don't beat just restoring it) and risks deferring small state files.
func mediaMinBytes() int64 {
	if v := os.Getenv("NOWHERE_MEDIA_MIN"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return 8 << 20
}

// mediaUserMinBytes is the floor for the USER'S media trees (NOWHERE_MEDIA_MIN_USER), defaulting to
// sealFileThreshold() -- 1 MiB.
//
// Three reasons it is not the 8 MiB app floor. In these trees a 2-6 MB file is a photo, never app state. It is
// the web importer's own boundary, which is what finally makes the two sides agree about what "deferrable"
// means. And sealFileThreshold() is the LOWEST floor that can have any effect at all: classifyDeferred is only
// ever reached from inside the walk gate `info.Size() >= threshold || fd`, so anything below it is inert by
// construction -- a fact that cost NWP-20260828-17 a wrong root cause once already.
//
// Defaulting to the function rather than a 1<<20 literal keeps the two tracking each other forever.
func mediaUserMinBytes() int64 {
	if v := os.Getenv("NOWHERE_MEDIA_MIN_USER"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return sealFileThreshold()
}

// mediaFloorFor returns the size floor for whichever media tree `lower` (an already-lowercased "/"+rel) falls
// in, and false when it is in none of them.
//
// ⚠ THE ORDER IS LOAD-BEARING. mediaAppDirs is tested FIRST and wins, so an app-private tree that happens to
// contain a "Pictures/" or "Download/" folder of its own keeps the conservative floor instead of inheriting
// the permissive user-media one. Reversing these two lines would quietly lower the floor on app-private data.
func mediaFloorFor(lower string) (int64, bool) {
	for _, dir := range mediaAppDirs {
		if strings.Contains(lower, dir) {
			return mediaMinBytes(), true
		}
	}
	for _, dir := range mediaUserDirs {
		if strings.Contains(lower, dir) {
			return mediaUserMinBytes(), true
		}
	}
	for _, pfx := range mediaUserRootPrefixes {
		if strings.HasPrefix(lower, pfx) {
			return mediaUserMinBytes(), true
		}
	}
	return 0, false
}

// The media trees, split by SIZE FLOOR (NWP-20260829-30). rel paths are tar-relative with forward slashes
// (e.g. "app.organicmaps/files/260527/China_Hebei.mwm", "media/0/DCIM/x.jpg").
//
// ⚠ WHY THIS IS THREE LISTS AND NOT ONE. A single list forced ONE floor on trees with very different
// contents. `/files/` is app-private and holds small state next to bulk downloads, so it wants a conservative
// floor. The user's own buckets hold photos and video, where a 2-6 MB file is a picture and never app state.
// Fusing them meant the conservative floor governed everything, and a typical camera photo -- most of a camera
// roll -- could never be deferred at all.

// mediaAppDirs: APP-PRIVATE bulk. Keeps the conservative mediaMinBytes floor, because small state files live
// here too.
var mediaAppDirs = []string{
	"/files/", // app private files: offline maps, ML models, downloaded content
}

// mediaUserDirs: the user's own shared buckets, matched as a path SEGMENT anywhere in the rel, exactly as the
// single list always did.
var mediaUserDirs = []string{
	"/download/",                        // user downloads
	"/dcim/",                            // camera
	"/movies/", "/music/", "/pictures/", // shared media buckets
}

// mediaUserRootPrefixes: scoped-storage app media that is nonetheless the USER'S content -- MediaStore-indexed
// shared files such as WhatsApp's "Android/media/com.whatsapp/WhatsApp/Media/...". Matched with a PREFIX on the
// lowercased "/"+rel, so it must sit at the SCOPE ROOT rather than merely appear somewhere in the path.
//
// ⚠ THIS IS NOT A NEW JUDGEMENT. The repo already draws exactly this line: dropPkgForRel treats Android/data
// and Android/obb as app-private while Android/media is the user's (incremental_seal.go, and the cases in
// drop_list_test.go). Adding it here makes the media predicate agree with a call the tree had already made.
//
// ⚠ DELIBERATELY ABSENT: "/android/data/" and "/android/obb/". Those are app-private state and
// launch-critical expansion assets. Their genuinely bulk subtree, Android/data/<pkg>/files/, is already
// covered by mediaAppDirs at the conservative floor.
var mediaUserRootPrefixes = []string{"/android/media/"}

// mediaDenyDirs / mediaDenyExts: NEVER defer these even if large + in a media dir -- either they are login- or
// state-critical (an app that can't open its DB at start crash-loops; a missing keystore breaks auth), or
// deferring them mounts an overlay that a system writer has to write THROUGH and cannot (see "/logs/" below).
// NWP-20260831-08: "/.nowhere-odhold/" is the ON-DEMAND HOLD -- an app's parked CE/DE/ext data awaiting
// odrestore, stashed under the chooser's own package dir. It MUST keep sealing (that is how a
// never-materialised app's data roams) but it must seal ESSENTIAL: it is app STATE in parked form, and a
// parked tree contains the same "/files/" segments as a live one, so without this entry the media split
// deferred big files OUT of the hold. Device-proven on lynx (odtest35, 2026-08-31): seals that ran while
// vending was parked deferred ~200MB of its phonesky download cache under the hold's rel, the paths then
// never existed again on any device, the deferred carry kept them forever ("not deleted, just
// unmaterialised"), and the Offline-media screen showed them as 215MB held by "Profile" -- the chooser's
// own app label, since the hold lives under its package segment. Undeletable from the device, billed.
//
// NWP-20260923-01: "/logs/" is here because A DEFERRED FILE MOUNTS AN OVERLAY ROAMD CANNOT WRITE THROUGH.
// Field-proven on frankel (ticket NW-aa348ffb98fd, build 2026092203): WhatsApp keeps its own logs in
// files/Logs, they cleared the app floor under the mediaAppDirs "/files/" rule, the seal deferred them,
// and mediad mounted a fuse.nowheremedia overlay over com.whatsapp/files/Logs to serve the stubs. roamd
// runs as endospore_priv, which holds READ-ONLY on the fuse type (endospore.te's `allow endospore_priv fuse:dir r_dir_perms` and `fuse:file` rules), so odrestore's
// `cp -a` create and reown's chown both returned EACCES -- 12 errors, every one of them under files/Logs.
// Each failed CE hand-back kept the hold. Two of the three were answered ERR-NOTREADY and retried; the third
// was answered OK, because WhatsApp's Android/data volume succeeded in the same op and odrestore's success
// counter spans all four volumes -- a masked failure, filed as its own row. Nothing was lost; it never settled.
//
// ⚠ BY DIR, NOT BY SUFFIX, and each of the tempting alternatives is wrong in a specific way:
//   - the mount is per DIRECTORY (media_server.go collapses the deferred set to maximal ancestor dirs), so
//     it is the dir that must never hold a stub, whatever else lands in it;
//   - ".log" would not even cover the rotated files: the ext test is HasSuffix on the WHOLE lowercased path,
//     so it misses "whatsapp-2026-09-23.1.log.gz" (the same reason .db-wal/.db-shm are separate entries);
//   - a bare ".gz" would reach far past this bug: these lists run BEFORE the floor test, so it would forbid
//     deferring every .gz in the user's own buckets (Download, at the 1 MiB user floor) -- the exact bulk
//     the on-demand tier exists to keep out of the login restore.
//
// Segment-anchored like every entry here: the subject is lowercased, so it matches WhatsApp's "Logs", but
// not "crashlogs/" and not a FILE named "logs.bin".
//
// ⚠⚠ THIS IS NOT THE STRUCTURAL FIX, and it must not be mistaken for one. ANY large file deferred inside an
// app's private files/ tree still mounts an overlay odrestore cannot write through; logs are merely the
// sixth shape of it to reach a device. The open decision is recorded in docs/backlog.md, and closing it one
// name at a time is the pattern that row already warns against. mediaPackageExts below (NWP-20261123-13,
// h53 #5) is NOT that pattern: it is a rule by shape, a class of file in every app's private storage, and not
// one app's folder. Q076's one by-name exclusion stays the only one.
//
// ⚠ AND IT IS FORWARD-ONLY -- exactly as the ".so" entry below is. It stops NEW deferrals. A never-
// materialised stub is not in .under, so the walk never sees it, and the carry re-emits it unchanged; mediad
// remounts over the dir at every login. What clears an existing stub is a MATERIALISE, not this list: the
// #108 pin pass and the tier-2 prefetch both write the real bytes into the live .under and tombstone the stub,
// after which the next seal folds the file to essential through this deny. An unpinned, on-demand stub has
// no such path and lasts until the app rotates the file away. See the backlog row before assuming it healed.
var mediaDenyDirs = []string{"/databases/", "/shared_prefs/", "/no_backup/", "/.nowhere-odhold/", "/logs/"}

// NWP-20260831-02: ".so" is here because NATIVE CODE CAN NEVER BE A STUB. A deferred file is served
// through the FUSE overlay until materialised, and dlopen() of an overlay-served library does not fault
// it in -- the process dies at its first native call with UnsatisfiedLinkError. Device-proven on lynx
// 2026-08-30 (odtest35, build 2026083006): WhatsApp packs its real libraries inside a superpack archive
// and extracts them to files/decompressed/libs.spo/*.so in its CE data; the vault seal deferred the two
// >=8MiB ones (the mediaAppDirs "/files/" rule at the app floor), the next login mounted a
// fuse.nowheremedia overlay INSIDE the app's private data dir to serve them, and WhatsApp then crashed at
// Application.onCreate on EVERY launch -- deterministic, and unreadable from the crash alone. Same class
// as /il2cpp/ below (mediaKeepEagerDirs, Toon Blast, DIA-20260730), but extension-shaped: an .so is
// load-bearing wherever it sits and whatever tree it is in, so the deny is by suffix, not by dir.
// ⚠ FORWARD-ONLY, like "/logs/" above -- NWP-20260923-01 corrected this sentence, which used to call it
// "largely self-healing" because the app would re-extract its libs. The record says otherwise: with the stub
// served, WhatsApp crashed on EVERY launch and never reached the re-extract, and the device proof of this fix
// ran only "after one residue purge" (docs/backlog.md, the .so row). A carried .so stub is invisible to the
// walk and re-emitted by the carry, the same as any other; it clears only by a materialise.
var mediaDenyExts = []string{".db", ".db-wal", ".db-shm", ".keystore", ".jks", ".p12", ".pem", ".so"}

// mediaPackageExts: NWP-20261123-13 (h53 #5, docs/product-decisions.md 2026-11-02, "seven answers to harvest
// 53"). An INSTALLABLE PACKAGE in an app's private storage is never deferred, for the ".so" reason: installable
// code can never be a stub. An installer app that keeps Android/data/<pkg>/files/update.apk above the app floor
// had it sealed deferred; mediad then served it through its overlay, and the installer's PackageInstaller
// session read a file that was not there until fetched.
//
// ⚠ NOT IN mediaDenyExts, ON PURPOSE. That list applies in every tree, so it would stop deferral for a package
// file in the user's own folders too (Download/app.apk), and each one would download at every sign-in. This
// list applies ONLY in app-private storage (mediaPackagePrivate): Android/data/<pkg>/ in the #media scope, or a
// CE <pkg>/ tree, for a residual stub an older head still carries. Download, DCIM and Android/media still defer.
//
// ⚠ A CLASS, NOT A NAME: it matches by suffix and shape in every app, so it is not the by-name pattern the
// "/logs/" warning above forbids. Q076's one by-name exclusion stays the only one.
//
// ⚠ FORWARD-ONLY, like ".so" and "/logs/". It stops NEW deferrals. A package file an older head already carries
// deferred stays a stub until something materialises it (a #108 pin or a tier-2 prefetch); the next seal then
// keeps it essential through this rule.
var mediaPackageExts = []string{".apk", ".apks", ".xapk", ".apkm"}

// mediaPackagePrivate reports whether `lower` (an already-lowercased "/"+rel) is in an app's private storage, the
// only place mediaPackageExts applies. Two shapes, kept as two tests:
//   - #media: "/android/data/<pkg>/..." with a non-empty <pkg> segment;
//   - CE vault: the FIRST segment is a package directory. A package name always holds a '.', and no
//     mediaUserDirs / mediaUserRootPrefixes first segment does, so a rel rooted at Download, DCIM or Android is
//     never this shape. It is a first-segment test and not a Contains test of the user dirs ON PURPOSE: an app's
//     own files/Download/ folder is still app-private (the mediaFloorFor order says the same).
func mediaPackagePrivate(lower string) bool {
	if rest, ok := strings.CutPrefix(lower, "/android/data/"); ok {
		if i := strings.IndexByte(rest, '/'); i > 0 {
			return true
		}
	}
	if first, _, ok := strings.Cut(strings.TrimPrefix(lower, "/"), "/"); ok && strings.Contains(first, ".") {
		return true
	}
	return false
}

// mediaKeepEagerDirs: app CODE/METADATA subtrees the app needs PRESENT to LAUNCH -- never defer them even when
// large and under a media dir (files/). Unity's IL2CPP runtime keeps its global metadata + version blobs here
// (files/il2cpp/Metadata/global-metadata.dat, files/il2cpp/unity.ver); if a restore is incomplete they aren't on
// disk and the game crash-loops at start with a misleading "not enough storage to install required resources"
// (proven, Toon Blast, DIA-20260730). Bulk downloadable assets (files/ContentDownload/*.ab) are deliberately NOT
// here -- deferring those is fine. Matched as a path SEGMENT (leading+trailing slash), like mediaDenyDirs.
var mediaKeepEagerDirs = []string{"/il2cpp/"}

// classifyDeferred reports whether a regular file (tar-relative rel, byte size) is deferred media. Pure +
// side-effect-free so P2's seal walk and P3's media daemon share ONE definition of the split.
// mediaDeferForbidden answers ONE question: is it unsafe to leave this file out of the login restore?
// Extracted from classifyDeferred in NWP-20260829-29 without changing a byte of its logic (all three loops
// return false, so their order relative to each other never mattered).
//
// WHY IT HAD TO COME OUT: classifyDeferred fused this with a SECOND, unrelated question -- "does this look
// like bulk media?" (the size floor + the mediaDirs whitelist). A caller that already knows a file is out of
// the tar, and only needs to know whether it is SAFE to keep it out, had no way to ask. That is precisely why
// nothing in the tree could re-defer a file the web importer deferred on a path mediaDirs does not list: the
// only available predicate also demanded the file look like bulk media, which it never will.
//
// NWP-20261123-13: it also forbids a package file (mediaPackageExts) in an app's private storage
// (mediaPackagePrivate). Every check here returns true only, so the order still does not matter.
func mediaDeferForbidden(rel string) bool {
	lower := "/" + strings.ToLower(strings.TrimPrefix(rel, "/")) // leading slash so "/seg/" matches a first segment
	for _, ext := range mediaDenyExts {
		if strings.HasSuffix(lower, ext) {
			return true
		}
	}
	for _, ext := range mediaPackageExts {
		if strings.HasSuffix(lower, ext) && mediaPackagePrivate(lower) {
			return true // installable code in an app's private storage is never a stub (h53 #5)
		}
	}
	for _, deny := range mediaDenyDirs {
		if strings.Contains(lower, deny) {
			return true
		}
	}
	for _, keep := range mediaKeepEagerDirs {
		if strings.Contains(lower, keep) {
			return true // app-essential code/metadata (e.g. il2cpp) -> stay eager/resident, never defer
		}
	}
	return false
}

func classifyDeferred(rel string, size int64) bool {
	// ⚠ THE DENY LISTS RUN FIRST AND UNCONDITIONALLY. That ordering is the STRUCTURAL guarantee that widening
	// the media trees (NWP-20260829-30) can never make a .db / .keystore / il2cpp file deferrable, whatever the
	// web importer did with it -- no tree entry can reach past this.
	if mediaDeferForbidden(rel) {
		return false
	}
	lower := "/" + strings.ToLower(strings.TrimPrefix(rel, "/"))
	floor, ok := mediaFloorFor(lower)
	if !ok {
		return false // unrecognized large file -> essential (conservative: never break login, only slow it)
	}
	// The size test moved from first to last, because the floor now depends on WHICH tree the file is in. That
	// is affordable: this function's call count is bounded by the files the walk sees at or above
	// sealFileThreshold() plus the records on the carry loop -- thousands, not every walked entry.
	return size >= floor
}

// --- #108 per-app "keep offline" pins ---
//
// A user can PIN an app so its bulk media is restored at LOGIN (essential) instead of streamed on-access:
// instant, offline-ready, at the cost of a slower login + more device/plan footprint. The pin set is a small
// file inside the profile (pinFileRel), so it rides the seal as ordinary data -> it ROAMS with the profile and
// is restored at login. The seal gates classifyDeferred on it (a pinned app's large files skip deferral), so a
// pinned app's media seals into the login-critical set exactly like a small file would.

// pinFileRel: where the pin set lives inside the roamed profile. One app-data-dir SEGMENT per line (e.g.
// "app.organicmaps"). Under the chooser's files dir -- always present (the chooser is install-existing'd for
// every roamed user) and NOT the media cache dir (mediaCacheDirName, which the seal skips), so it's captured.
const pinFileRel = "com.nowhere.chooser/files/nowhere-pins"

// pinnedApp returns the app-data-dir segment a rel belongs to -- the unit of #108 pinning / #129 tiering.
// For the CE scope (/data/user/N) a rel is "<pkg>/files/x.mwm" -> "<pkg>" (the first component). For the
// EXTERNAL-media scope (/data/media/N, ref name#media) app-specific storage lives under
// "Android/{data,media,obb}/<pkg>/..." -- so the app is the component AFTER that prefix, NOT the literal
// "Android". Without this, an external map keyed to "Android" got curatedTier("Android")=on-demand instead of
// app.organicmaps's tierPrefetch (and a #108 pin of the app was silently ignored), so the Tier-2 prefetch that
// re-materializes the maps at login never ran (#129 external-media serve gap).
func pinnedApp(rel string) string {
	rel = strings.TrimPrefix(rel, "/")
	for _, pfx := range []string{"Android/data/", "Android/media/", "Android/obb/"} {
		if strings.HasPrefix(rel, pfx) {
			rest := rel[len(pfx):]
			if i := strings.IndexByte(rest, '/'); i >= 0 {
				return rest[:i]
			}
			return rest
		}
	}
	if i := strings.IndexByte(rel, '/'); i >= 0 {
		return rel[:i]
	}
	return rel
}

// mediaCfgRoot maps a scope's data root to the CE dir that actually holds the per-app media config
// (pins/tiers/budget). The chooser writes that config into the ROAMED USER'S CE dir
// (/data/user/<N>/com.nowhere.chooser/files/, via getFilesDir), so the CE-scope seal (src=/data/user/<N>)
// already reads it correctly. But the EXTERNAL-media scope (ref name#media) seals AND serves with
// src=/data/media/<N>, whose com.nowhere.chooser/files/ never exists -- so a user's tier/pin/budget choice was
// silently ignored for external-media apps (offline maps), and the Tier-2 prefetch that fills them never keyed
// off the override. Rewrite /data/media/<N> -> /data/user/<N> so BOTH scopes resolve the one CE config. Any
// other path (CE scope, VM/test tmp dirs) passes through unchanged.
func mediaCfgRoot(src string) string {
	const mediaPfx = "/data/media/"
	if strings.HasPrefix(src, mediaPfx) {
		return "/data/user/" + strings.TrimPrefix(src, mediaPfx)
	}
	return src
}

// loadPins reads the profile's pin set (pinFileRel under the CE config root) into a set of app segments.
// Missing/empty -> nil (nothing pinned -> today's on-demand behavior for every app). The seal calls this once
// per push.
func loadPins(src string) map[string]bool {
	b, err := os.ReadFile(filepath.Join(mediaCfgRoot(src), filepath.FromSlash(pinFileRel)))
	if err != nil {
		return nil
	}
	out := map[string]bool{}
	for _, ln := range strings.Split(string(b), "\n") {
		if ln = strings.TrimSpace(ln); ln != "" {
			out[ln] = true
		}
	}
	return out
}

// budgetFileRel: the user-set offline-media budget (BYTES) for #108 P3, next to pinFileRel so it roams with
// the profile. 0/absent/unparseable -> no cap (every pinned app is fully kept offline, the P2 behavior).
// When set, the seal keeps a pinned app's media essential only up to this many bytes (in stable walk order)
// and lets the excess fall back to on-demand -- a best-effort pin that never fails.
const budgetFileRel = "com.nowhere.chooser/files/nowhere-media-budget"

// loadBudget reads the offline-media budget (bytes) from src. 0 -> unlimited (no cap).
func loadBudget(src string) int64 {
	b, err := os.ReadFile(filepath.Join(mediaCfgRoot(src), filepath.FromSlash(budgetFileRel)))
	if err != nil {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// --- #129: per-app 3-tier offline media (pre-login / async prefetch / on-demand) ---
//
// #84 split media into a BINARY essential-vs-deferred; #129 makes the DEFERRED set a TRI-STATE per app:
//
//	Tier-1 essential  -- restored at login (in the tar), like any non-media file. Blocks login.
//	Tier-2 prefetch   -- deferred at login (fast login) but fetched ASYNC in the background afterwards
//	                     (Wi-Fi + idle/charging, own budget). It stays Tier-2 across seals: the walk
//	                     re-runs classifyTier, which returns prefetch again. (It is NOT promoted to
//	                     essential -- this line said so until NWP-20260828-17.)
//	Tier-3 on-demand  -- deferred; served on-access by mediad only (today's deferred behavior).
//
// classifyDeferred stays the SINGLE gate for "is this bulk media at all"; classifyTier layers the tier on
// top, so login/state-critical files can NEVER be demoted out of the login restore. This file is JUST the
// policy + the loaders; nothing consumes classifyTier yet (the seal wiring is P2 -- no behavior change here).

type mediaTier int

const (
	// tierOnDemand is the ZERO value on purpose: deferredFile.Tier is `omitempty`, so an on-demand file
	// stamps Tier=0/absent and a pre-#129 manifest (no Tier at all) reads back as on-demand -- byte-identical
	// + signature-valid. Do NOT renumber these.
	tierOnDemand  mediaTier = 0 // Tier-3: served on-access by mediad
	tierEssential mediaTier = 1 // Tier-1: restored at login (rides the tar; never stored in Deferred)
	tierPrefetch  mediaTier = 2 // Tier-2: async background prefetch after login (manifest Tier=2)
)

// curatedTiers: the built-in DEFAULT tier per app-data-dir segment, applied when the profile carries no
// explicit override for that app. The curation point -- known offline-first apps whose bulk media is worth
// having ready without the user asking. Anything absent falls to on-demand (curatedTier), so a #129 build
// with no config behaves exactly like today for every unrecognized app.
var curatedTiers = map[string]mediaTier{
	"app.organicmaps": tierPrefetch, // offline maps: large but valuable offline -> prefetch on Wi-Fi
}

func curatedTier(app string) mediaTier {
	if t, ok := curatedTiers[app]; ok {
		return t
	}
	return tierOnDemand
}

// tierFileRel: the per-profile tier OVERRIDE map -- one "app.segment tier" per line (tier =
// essential|prefetch|ondemand), next to the #108 pin/budget files so it ROAMS with the profile (Chester's
// #129 decision: tier prefs travel with the profile like pins, not device policy) and is restored at login.
// A blank line, a '#' comment, or a malformed/unknown-tier line is ignored. Absent -> curated defaults apply.
const tierFileRel = "com.nowhere.chooser/files/nowhere-media-tiers"

// cfgFileRel is the profile's Configuration screen (NWP-20260825-15): "key=value" lines, roaming next to
// the tier map. Only media.default matters here; the app defaults are the chooser's business.
const cfgFileRel = "com.nowhere.chooser/files/nowhere-config"

// mediaDefaultKey carries the profile-configured default INSIDE the tier map, so nothing on the hot path
// needs a new parameter -- walkChunks, classifyTier and their callers are untouched. "*" is safe as a
// sentinel because the keys are app-data-dir SEGMENTS (package-shaped: pinnedApp(rel)), which can never be
// "*"; a tier line naming "*" was already meaningless and is now simply the same thing spelled by hand.
const mediaDefaultKey = "*"

func parseTier(s string) (mediaTier, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "essential", "1":
		return tierEssential, true
	case "prefetch", "2":
		return tierPrefetch, true
	case "ondemand", "on-demand", "3":
		return tierOnDemand, true
	}
	return 0, false
}

// loadTiers reads the profile's per-app tier overrides into app-segment -> tier. Missing/empty -> nil (the
// curated defaults apply to every app). Called once per seal, like loadPins.
// loadConfiguredMediaDefault reads media.default from the Configuration file. ok=false when the profile has
// never set one -- and that distinction is load-bearing: absent means the CURATED per-app defaults still
// apply, while a set value is the user overriding our curation deliberately from a settings screen.
func loadConfiguredMediaDefault(src string) (mediaTier, bool) {
	b, err := os.ReadFile(filepath.Join(mediaCfgRoot(src), filepath.FromSlash(cfgFileRel)))
	if err != nil {
		return 0, false
	}
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		eq := strings.IndexByte(ln, '=')
		if eq <= 0 || strings.TrimSpace(ln[:eq]) != "media.default" {
			continue
		}
		if t, ok := parseTier(ln[eq+1:]); ok {
			return t, true
		}
	}
	return 0, false
}

func loadTiers(src string) map[string]mediaTier {
	out := map[string]mediaTier{}
	// NWP-20260825-15: the Configuration default, if the profile set one. Read FIRST and unconditionally --
	// a profile can configure a default without ever touching a single app, in which case the tier file does
	// not exist and the old early-return would have thrown the default away with it.
	if d, ok := loadConfiguredMediaDefault(src); ok {
		out[mediaDefaultKey] = d
	}
	b, err := os.ReadFile(filepath.Join(mediaCfgRoot(src), filepath.FromSlash(tierFileRel)))
	if err != nil {
		if len(out) == 0 {
			return nil // nothing configured at all -- curated defaults apply, exactly as before
		}
		return out
	}
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		f := strings.Fields(ln)
		if len(f) != 2 {
			continue
		}
		if t, ok := parseTier(f[1]); ok {
			out[f[0]] = t
		}
	}
	return out
}

// classifyTier decides a file's tier. Non-media / small / state-critical -> tierEssential (can never be
// demoted out of the login restore). Otherwise, highest priority first: a #108 pin forces essential; else
// the per-profile roaming override; else the curated default. Pure + O(1) (the maps are built once per seal
// and passed in), so the hot seal walk can call it per file.
func classifyTier(rel string, size int64, tiers map[string]mediaTier, pins map[string]bool) mediaTier {
	if !classifyDeferred(rel, size) {
		return tierEssential
	}
	app := pinnedApp(rel)
	if pins[app] {
		return tierEssential // #108 pin: force into the login restore (unchanged from #108)
	}
	return tierForApp(app, tiers)
}

// tierForApp is the PREFERENCE half of classifyTier: per-profile override, else a configured profile-wide
// default, else our curation. Extracted in NWP-20260829-29.
//
// ⚠ THIS IS NOT the `configuredTier(rel, tiers, pins)` that was designed and REFUTED on 2026-08-29. That one
// took a REL and folded the pin check in, which made it look like a safety verdict and invited callers to use
// it as one -- and a caller that did would stamp Tier=2 on a #204 force-deferred APK, because curatedTier
// needs no config file to fire. This takes an APP SEGMENT and carries no safety judgement whatsoever: every
// caller must answer "is it safe to keep this out of the login tar?" for itself, first.
func tierForApp(app string, tiers map[string]mediaTier) mediaTier {
	if t, ok := tiers[app]; ok {
		return t // per-profile roaming override
	}
	if d, ok := tiers[mediaDefaultKey]; ok {
		// NWP-20260825-15: the profile CONFIGURED a default, so it beats our curation -- someone opened a
		// settings screen and chose. Absent (the normal case) leaves curatedTier exactly as it was.
		return d
	}
	return curatedTier(app)
}

// redeferTier is THE RETURN DOOR (NWP-20260829-29). It answers: may this now-LOCAL file go back into Deferred
// instead of falling through to essential and riding the login tar forever?
//
// ⚠ WHY THIS EXISTS. Materialization was a ONE-WAY DOOR. mediad's #108 pin and #129 prefetch write real bytes
// into the passthrough dir and tombstone the stub; the next seal then walks a real file, asks classifyDeferred,
// and for anything the web importer deferred on a path `mediaDirs` does not list the answer is NO at any size
// -- so the file lands ESSENTIAL and is restored inline at every login from then on, and nothing in the tree
// can send it back. That ratchet is why the obvious fix to NWP-20260828-17 (stamp the configured tier on the
// carry path) was refused by three independent reviews: it routes the whole imported corpus into the
// login-blocking tar one seal later, which is the very trap that row already forbids.
//
// ⚠ IT IS DELIBERATELY A RETURN, NEVER A DEMOTION. Condition (1) is the whole safety argument: the file must
// ALREADY be Deferred in the head we are sealing against. So this can only put back something that was
// already out of the tar -- it can never take a file that has always been restored at login and stop
// restoring it. That is what keeps constraint "must not grow, or silently shrink, the login set" true in both
// directions, and it is why this is safe where a size/path-agnostic tier lookup was not.
//
// ⚠ THE DENY LIST STILL RULES, and asymmetrically ON PURPOSE. "Already deferred" is NOT evidence a file is
// bulk media: the importer applies no deny list at all, so a .db / .db-wal / .keystore can sit in its band.
// Such a file folds essential here and never comes back -- a one-way door in the SAFE direction.
func redeferTier(rel string, size int64, prevDef map[string]deferredFile, tiers map[string]mediaTier, pins map[string]bool) (mediaTier, bool) {
	if _, ok := prevDef[rel]; !ok {
		return 0, false // never deferred before -> this would be a NEW demotion, which is not ours to make
	}
	if mediaDeferForbidden(rel) {
		return 0, false // state-critical / app-essential -> belongs in the login restore, whatever the importer did
	}
	if size < mediaMinBytes() {
		return 0, false // below the floor the rest of the system treats as "worth deferring"
	}
	app := pinnedApp(rel)
	if pins[app] {
		return 0, false // #108 pin: the user asked for it at login. Still wins, exactly as before.
	}
	t := tierForApp(app, tiers)
	if t == tierEssential {
		return 0, false // an essential-tier config is the user asking for the tar
	}
	return t, true // tierPrefetch or tierOnDemand only
}

// tier2BudgetFileRel: the Tier-2 async-prefetch byte budget, roaming with the profile next to the #108
// files. It is SEPARATE from the #108 essential/pin budget (loadBudget) -- Tier-1 keep-at-login and Tier-2
// background-prefetch are independent caps, not a shared pool (Chester's #129 decision). Absent ->
// defaultTier2Budget; explicit 0 -> unlimited (matching loadBudget's convention); negative -> the default.
const tier2BudgetFileRel = "com.nowhere.chooser/files/nowhere-tier2-budget"

const defaultTier2Budget int64 = 2 << 30 // 2 GiB: a sane bound on background prefetch when the user set none

func loadTier2Budget(src string) int64 {
	b, err := os.ReadFile(filepath.Join(mediaCfgRoot(src), filepath.FromSlash(tier2BudgetFileRel)))
	if err != nil {
		return defaultTier2Budget
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil || n < 0 {
		return defaultTier2Budget
	}
	return n
}

// prefetchMeteredOut: the #129 metered-prefetch policy for the LIVE session, in the RAM state dir. The policy itself
// is per-profile and roams: the chooser keeps it in its own files dir in the roamed user
// (com.nowhere.chooser/files/nowhere-prefetch-metered, "1" = allow Tier-2 background prefetch on a METERED network;
// absent = Wi-Fi-only, the DEFAULT -- Chester's call: never spend cellular data on prefetch unless the user opts in).
//
// NWP-20261005-08: the daemon must NOT read that file in place. /data/user/<N> is created by vold at user N's MLS
// level (system_data_file:s0:c<512+N>,c768), and searching a system_data_file dir needs the subject to dominate it
// (system/sepolicy private/mls), which the `nowhere` domain does not. Every read was refused -- an avc every 30 s,
// the gate's poll cadence -- and the refusal read as "off", so the opt-in never took effect on an enforcing build.
// Instead the worker surfaces the profile's value here at roam-in (like apps.out / prefs.out), and the profile
// screen's SET-PREFETCH-METERED keeps it current mid-session.
//
// The file holds "<uid> <0|1>". The uid ties it to ONE session: every login mints a new user, so a value left by an
// earlier session (a login path that never reached the worker's surface step, say) can never be answered for this
// one -- it falls back to the Wi-Fi-only default instead.
const prefetchMeteredOut = "prefetch-metered.out"

// prefetchMeteredFor reports whether session user <uid> has opted into metered prefetch, from the state dir.
func prefetchMeteredFor(dest, uid string) bool {
	if uid == "" {
		return false
	}
	b, err := os.ReadFile(filepath.Join(dest, prefetchMeteredOut))
	if err != nil {
		return false
	}
	f := strings.Fields(string(b))
	return len(f) == 2 && f[0] == uid && f[1] == "1"
}

// setPrefetchMetered records session user <uid>'s choice in the state dir (the SET-PREFETCH-METERED verb), by temp +
// rename, so a lock-free GET-PREFETCH-METERED never reads a truncated file (NWP-20261117-23).
func setPrefetchMetered(dest, uid string, on bool) error {
	v := "0"
	if on {
		v = "1"
	}
	p := filepath.Join(dest, prefetchMeteredOut)
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(uid+" "+v+"\n"), 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
