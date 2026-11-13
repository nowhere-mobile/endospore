package main

// Incremental seal (#69, DIA-20260701-06): the legacy seal tars the WHOLE directory and CDC-chunks that one
// stream, so every save re-READS + re-HASHES the entire working set (the content cache skips re-SEALING
// unchanged chunks, but not the scan). For a multi-GB profile that's 45s warm / 2m+ cold on every logoff.
//
// This chunks FILE-ALIGNED: the CDC rolling hash resets at each large-file boundary, so a large file's chunks
// are self-contained. A per-profile scan cache (relpath -> mtime,size,mode,chunk-hashes) then lets an
// UNCHANGED large file be emitted from its cached hashes WITHOUT reading it -- the multi-GB read disappears.
// Small files (< threshold) are GROUPED and chunked normally (re-hashed each save, but their total is tiny),
// so a directory of thousands of small files doesn't explode into thousands of tiny chunks.
//
// The manifest is UNCHANGED (an ordered list of chunk hashes): restore just concatenates chunk plaintexts ->
// the same tar -> untar, regardless of how the seal split them. So restore needs no change, and correctness
// reduces to one invariant, covered by the round-trip tests: the emitted chunks concatenate to EXACTLY
// tarDirTo(src). The first save after this ships re-chunks file-aligned (hashes differ from the old
// whole-stream chunks) so it re-uploads once; after that, incremental.

import (
	"archive/tar"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"golang.org/x/sys/unix"
)

// sealWalkBlind classifies a filepath.Walk error. A path that VANISHED under the live user is expected and
// benign -- the tree churns while the session runs, and skipping it is exactly right. ANY OTHER error (EACCES
// on a directory we must descend, EIO) means the walk went BLIND over part of the source, and a manifest built
// from a blind walk is SHORT: sealing it replaces good data with a fraction of it.
//
// Not hypothetical. On lynx 2026-07-28 the #media scope failed to seal for a whole day: the login daemon runs
// in the `nowhere` SELinux domain, which has no dac_read_search and no media_rw_data_file access, so
// opendir("/data/media") returned EACCES on the very first call. The old code returned nil here, the walk
// ended immediately, and the seal offered a 2-chunk manifest for a 304-chunk tree. Only the shrink guard
// caught it -- and that guard needs a non-empty PRIOR head to compare against, so on a scope's FIRST seal the
// empty manifest would have become the authoritative head with nothing to notice.
// sealSpecialFromDirent answers "is this path a SPECIAL file (fifo/socket/device)?" WITHOUT stat'ing it.
//
// ⚠ WHY (NWP-20260825-09, Chester): signing into Tesla makes Realm create control files under its data dir --
// TrealmStorage.note (a named PIPE) and access_control.pick_writer.cv. The seal walk's lstat is then denied by
// SELinux ({ getattr } tclass=fifo_file, scontext endospore_priv), those paths count BLIND, and EVERY logoff is
// refused: "ERR-REFUSED PARTIAL:vault=refused -> staying signed in, NOT reaping". The user cannot sign out at
// all. Third app to hit this shape -- AliExpress needed the lnk_file grant above it.
//
// ⚠ THE SEPOLICY ROUTE DOES NOT WORK -- DO NOT RETRY IT. `allow nowhere app_data_file:fifo_file getattr;`
// reaches the compiler input (it IS in system_ext_sepolicy.conf) and is then SILENTLY DROPPED from the compiled
// CIL. Verified twice on lynx, including after nuking every sepolicy intermediate and forcing a full soong
// re-analysis. The build runs a tool called `sepolicy_filter_neverallow`, which STRIPS violating rules instead
// of failing the build, so nothing warns you -- and the adjacent lnk_file grant survives, which makes the
// broken state look convincing.
//
// So read the type from the DIRECTORY ENTRY instead. readdir needs only `read` on the parent dir, which the
// walker already holds, and d_type comes out of the dirent -- no per-file permission is involved, so SELinux
// cannot deny it. A fifo/socket/device has NO CONTENT TO SEAL, so skipping it is a policy decision, not a blind
// spot -- exactly how symlinks are already handled below. Realm recreates these on next launch.
//
// Returns (isSpecial, knowable). knowable=false means readdir itself failed, and the caller MUST keep treating
// the path as blind, because then we genuinely cannot see it.
func sealSpecialFromDirent(p string, cache map[string]map[string]fs.FileMode) (bool, bool) {
	dir := filepath.Dir(p)
	ents, ok := cache[dir]
	if !ok {
		des, err := os.ReadDir(dir)
		if err != nil {
			cache[dir] = nil // remember the failure; never re-readdir a dir we cannot read
			return false, false
		}
		ents = map[string]fs.FileMode{}
		for _, de := range des {
			ents[de.Name()] = de.Type()
		}
		cache[dir] = ents
	}
	if ents == nil {
		return false, false
	}
	mt, ok := ents[filepath.Base(p)]
	if !ok {
		return false, false
	}
	// Dirs and regular files are NOT special: a denied stat on those IS a real blind spot and must still refuse.
	return mt&(fs.ModeNamedPipe|fs.ModeSocket|fs.ModeDevice|fs.ModeCharDevice) != 0, true
}

func sealWalkBlind(err error) bool {
	return err != nil && !errors.Is(err, fs.ErrNotExist)
}

// sealBlindLog names the package (or, with none, the scope) of each path the walk could not read, the
// path's SELinux context and the error CODE -- never the path. The refusal line alone counts them, and that
// stranded a real user: ticket NW-b8b659735124 (frankel, 2026-08-20, user/release-keys) refused three
// logoffs with "44 path(s) -- fix the permissions" on the one build type where NOTHING can enumerate
// them (no adb, no shell, and this log is the only diagnostic channel). You cannot fix what you cannot
// name, so the line says WHICH APP and WHICH LABEL.
//
// Each line carries the package (pkg=<pkg>) or a fixed scope word (scope=media|ext|de|ce|other, from the
// path's root only), the walk error's code, and BEST-EFFORT the path's SELinux context via lgetxattr:
// the seal walker runs as root, and root being refused is an SELinux story (the live suspect is MCS
// categories on app-created files, the DIA-20260808-02 class), so the LABEL is the diagnosis. lgetxattr
// needs only the parent's search permission, so it often succeeds where open/readdir was denied; when it
// too is denied, the errno itself is evidence.
//
// WHY NO PATH (Q001 (e), docs/product-decisions.md, 2026-10-20, "eighteen recommendations accepted"): the
// old line printed the path with %q and the error with %v, and a *fs.PathError repeats the path UNQUOTED --
// past LOG_SCRUB_SED and report_issue.go's issueNameRules -- so a departed profile's app and photo file
// names stayed in roam.log on /data for the next profile's "Report an issue". The scrub stays as it is;
// the line changes. Package names already survive in roam.log (keystore/odrestore/held-on-demand lines),
// so nothing new outlives the session.
//
// Capped so a pathological tree cannot flood the log: the refusal line still carries the true total.
const sealBlindLogMax = 8

// sealBlindPkgs accumulates the PACKAGES whose data the walk could not read, so a refusal can NAME the app
// that is blocking sign-out instead of failing mutely.
//
// ⚠ WHY (NWP-20260825-13, Chester): when a seal is refused the user gets a TOAST -- "Couldn't save this
// session" -- with no app named and no action. That stranded him for the whole Tesla episode, and it is the
// THIRD app to do it (AliExpress lnk_file, Tesla fifo_file). sealBlindLog names every blind path's package or
// scope in the log, with its SELinux context; nothing machine-readable survived, so the UI could not say which app.
//
// Reset per push (resetSealBlindPkgs) so a refusal only ever reports the run that actually failed.
var (
	sealBlindPkgMu  sync.Mutex
	sealBlindPkgSet = map[string]bool{}
)

func resetSealBlindPkgs() {
	sealBlindPkgMu.Lock()
	sealBlindPkgSet = map[string]bool{}
	sealBlindPkgMu.Unlock()
}

// blindPkgOf pulls the package out of an unreadable path. App data lives at /data/user/<N>/<pkg>/... and
// /data/user_de/<N>/<pkg>/...; anything else (e.g. /data/media/<N>) has no package and returns "".
func blindPkgOf(p string) string {
	for _, pre := range []string{"/data/user/", "/data/user_de/"} {
		if !strings.HasPrefix(p, pre) {
			continue
		}
		rest := p[len(pre):]
		i := strings.IndexByte(rest, '/') // past <N>
		if i < 0 {
			return ""
		}
		rest = rest[i+1:]
		if j := strings.IndexByte(rest, '/'); j >= 0 {
			rest = rest[:j]
		}
		if rest == "" || strings.ContainsAny(rest, " \t") {
			return ""
		}
		return rest
	}
	return ""
}

// sealBlindPkgList returns the accumulated packages, sorted for a stable message.
func sealBlindPkgList() []string {
	sealBlindPkgMu.Lock()
	defer sealBlindPkgMu.Unlock()
	out := make([]string, 0, len(sealBlindPkgSet))
	for k := range sealBlindPkgSet {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// errCode is an error's text without any path: the inner error of a *fs.PathError / *os.LinkError /
// *os.SyscallError (e.g. "permission denied"), else the error's own text with any URL query and head key removed
// (logSafeErrText, NWP-20261117-26: a cap GET's *url.Error carries the whole presigned URL). Never the path.
func errCode(err error) string {
	if err == nil {
		return "none"
	}
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return errCode(pe.Err)
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		return errCode(le.Err)
	}
	var se *os.SyscallError
	if errors.As(err, &se) {
		return errCode(se.Err)
	}
	return logSafeErrText(err)
}

// blindScopeOf names the area of a package-less unreadable path by its ROOT only, as a fixed word.
func blindScopeOf(p string) string {
	switch {
	case p == "/data/media" || strings.HasPrefix(p, "/data/media/"):
		return "media"
	case strings.HasPrefix(p, "/storage/") || strings.HasPrefix(p, "/mnt/") || strings.HasPrefix(p, "/sdcard"):
		return "ext"
	case strings.HasPrefix(p, "/data/user_de/"):
		return "de"
	case strings.HasPrefix(p, "/data/user/"):
		return "ce"
	}
	return "other"
}

// sealUnreadableKeepLine is the [seal] line for a path whose stored record is kept. The quoted rel is
// scrubbed by LOG_SCRUB_SED; the error is its code, because a *fs.PathError repeats the path unquoted.
func sealUnreadableKeepLine(rel, kept string, err error) string {
	return fmt.Sprintf("[seal] %q unreadable -> keeping the stored %s: %s\n", rel, kept, errCode(err))
}

func sealBlindLog(nth int, p string, err error) {
	// Record the package BEFORE the log-elision cap: the log stops after sealBlindLogMax lines, but the
	// UI must still be able to name an app whose only blind path came in at number 51.
	pkg := blindPkgOf(p)
	if pkg != "" {
		sealBlindPkgMu.Lock()
		sealBlindPkgSet[pkg] = true
		sealBlindPkgMu.Unlock()
	}
	if nth > sealBlindLogMax {
		if nth == sealBlindLogMax+1 {
			fmt.Printf("push: [walk] ...further unreadable paths elided (the refusal line carries the total)\n")
		}
		return
	}
	ctx := "unknown"
	buf := make([]byte, 256)
	if sz, xerr := unix.Lgetxattr(p, "security.selinux", buf); xerr == nil && sz > 0 {
		ctx = strings.TrimRight(string(buf[:sz]), "\x00")
	} else if xerr != nil {
		ctx = "xattr-denied:" + errCode(xerr)
	}
	if pkg != "" {
		fmt.Printf("push: [walk] unreadable pkg=%s ctx=%s err=%s\n", pkg, ctx, errCode(err))
		return
	}
	fmt.Printf("push: [walk] unreadable scope=%s ctx=%s err=%s\n", blindScopeOf(p), ctx, errCode(err))
}

// incrementalSeal is on by default; NOWHERE_SEAL_FULL=1 forces the legacy whole-tar CDC (kill switch).
func incrementalSeal() bool { return os.Getenv("NOWHERE_SEAL_FULL") != "1" }

// sealFileThreshold: files >= this are chunked file-aligned + scan-cached (an unchanged one is skipped);
// smaller files are grouped + chunked normally. Default 1 MiB.
func sealFileThreshold() int64 {
	if n, err := strconv.ParseInt(os.Getenv("NOWHERE_SEAL_FILE_THRESHOLD"), 10, 64); err == nil && n > 0 {
		return n
	}
	return 1 << 20
}

// ondemandMedia (#84) gates the on-demand-media split: when set, classifyDeferred() large files are chunked
// into the manifest's Deferred index (served on-access by the media daemon, P3) instead of the login-gating
// essential tar. Off when unset, but roamd exports it ON for every seal (nowhere_roamd.sh, except #apps). It is
// the PROCESS-WIDE half only: since NWP-20260923-02 the push ANDs it with sealScopeDefers, so the CE vault and
// #de never defer by the heuristic whatever this says (media_heal.go).
func ondemandMedia() bool { return os.Getenv("NOWHERE_ONDEMAND_MEDIA") == "1" }

// loadDeferList (#204) reads NOWHERE_DEFER_LIST -- a file of tar-relative paths, one per line -- into a set the
// seal walk force-defers regardless of file size or the media heuristic. On-demand app APKs use it: their bytes
// ride the #apps seal (so a tap can materialise them) but are EXCLUDED from the login restore, exactly like a
// Tier-3 media file. Unset/empty/unreadable => nil (no forced defer), so a normal seal is byte-identical to
// before. Paths are slash-normalized to match walkChunks' filepath.ToSlash(rel) lookup.
// odHoldDirName is where hold_ondemand (nowhere_roamd.sh) parks a kept app's CE/DE data at login, under the
// chooser's own package dir so Android's app-data reconcile does not reap it. Kept here because the seal has
// to recognise that shape to drop a switched-off app's held bytes.
const odHoldDirName = ".nowhere-odhold"

// odFetchStageName (NWP-20261130-03) is fetch-oddata's stage beside the hold; see unfetched_fetch.go.
const odFetchStageName = ".nowhere-odfetch"

// loadDropList (DIA-20260804-04) reads NOWHERE_DROP_LIST -- a file of PACKAGE NAMES, one per line -- into a
// set of apps whose data the seal must NOT capture. Same env-var contract as NOWHERE_DEFER_LIST, and written
// by the same producer (the chooser, at logoff, from the keep-set it already computes).
//
// WHY THIS EXISTS. Turning an app Off in "Your apps" did not previously stop it being sealed. The keep-set
// gates only appcode_seal -- the APK CODE that rides name#apps -- while the data seal pushes /data/user/N,
// /data/user_de/N and /data/media/N WHOLESALE (nowhere_roamd.sh). So an app the user switched off kept its
// data sealed, billed and roamed forever, while the app itself was never reinstalled: permanent dead weight
// the user was charged for and could not see. It also made the screen copy false -- "Off means it's gone at
// logoff, like always" (showYourApps) was simply not true of the data.
//
// The list is PACKAGE NAMES, not paths, because the same package must be dropped from four different shapes
// across three scopes (see dropPkgForRel). Only USER-INSTALLED packages are ever listed: the producer prunes
// bundled/system apps, whose data is the profile itself (messages, browser, settings) and must always roam.
// An empty or absent list means "drop nothing", i.e. exactly the previous behaviour.
// fileDropList is the drop list AS THIS DEVICE WROTE IT -- the chooser's own per-session record, with no
// account tombstones folded in.
//
// Split out of loadDropList by NWP-20260906-18 for one load-bearing reason: a NEW tombstone is minted from
// this list -- only from its uninstall subset, goneDropList (NWP-20261023-07), since an Off never mints one --
// so minting from the unioned set would let every tombstone re-mint itself on every seal and
// refresh its own timestamp forever -- turning "when was this deleted" into "when did any device last seal",
// which is the field's only real content.
func fileDropList() map[string]bool {
	p := os.Getenv("NOWHERE_DROP_LIST")
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	m := map[string]bool{}
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		// Defensive: a path separator in a "package name" would mean the producer wrote paths, and matching it
		// as a basename could skip an unrelated subtree. Ignore anything that is not a plain package token.
		if ln == "" || strings.ContainsAny(ln, "/\\") {
			continue
		}
		m[ln] = true
	}
	return m
}

// loadDropList is the EFFECTIVE drop set for this seal: what this device recorded, PLUS what the ACCOUNT has
// deleted, MINUS anything the user currently keeps.
//
// NWP-20260906-18. The account tombstones are unioned here, and deliberately BEFORE the keep-set intersect,
// so every consumer -- the walk, the #204 deferred carry, the #91 essential carry and the presence guard --
// reads ONE set and cannot disagree about whether a package is deleted.
//
// ⚠ THE EARLY RETURN ON AN UNSET NOWHERE_DROP_LIST IS GONE, ON PURPOSE. An account tombstone has to apply on
// a handset whose OWN drop list is empty -- that is the entire case it exists for: the device that was
// already signed in when someone uninstalled the app elsewhere.
func loadDropList() map[string]bool {
	m := map[string]bool{}
	for pkg := range fileDropList() {
		m[pkg] = true
	}
	for pkg := range sealTombstones() {
		if pkg != "" && !strings.ContainsAny(pkg, "/\\") {
			m[pkg] = true
		}
	}
	// BELT AND BRACES: never drop a package that is CURRENTLY kept. The drop list is written at logoff but
	// lives in the chooser's CE dir, so it seals, roams and is restored -- roamd clears it at roam-in for
	// exactly that reason, but a reset that silently failed would otherwise let a PREVIOUS session's list
	// decide what this session drops, including an app the user has since switched back On. The keep-set is
	// the live truth and is right there next to it, so intersecting costs one file read and makes the
	// dangerous direction unreachable rather than merely unlikely.
	if kp := os.Getenv("NOWHERE_KEEP_LIST"); kp != "" {
		if kb, err := os.ReadFile(kp); err == nil {
			for pkg := range parseKeepModes(kb) {
				if m[pkg] {
					delete(m, pkg)
					// NWP-20260906-18: this is ALSO how an account TOMBSTONE is cleared, and why the tombstone needs no
					// expiry rule of its own -- reinstalling the app and keeping it is the escape hatch, expressed by the
					// user rather than inferred from a timestamp. A permanent record with no way back is how a tombstone
					// design goes wrong; this one cannot, because the machinery that undoes it already shipped.
					fmt.Printf("seal: NOT dropping %q -- it is in the keep-set (stale drop list, or a re-added app clearing its tombstone)\n", pkg)
				}
			}
		}
	}
	if len(m) == 0 {
		return nil
	}
	return m
}

// dropPkgForRel reports whether a tar-relative DIRECTORY path is an app-data dir belonging to a dropped
// package. Matching is anchored, never a substring: a user folder that merely happens to share a package's
// name at some other depth is not touched.
//
// The four shapes, one per place a package's data lives across the three sealed scopes:
//
//	<pkg>                                        CE   (/data/user/N)  and DE (/data/user_de/N)
//	Android/{data,obb}/<pkg>                     external app-PRIVATE data in the #media scope
//	com.nowhere.chooser/.nowhere-odhold/<pkg>    CE/DE data hold_ondemand parked at login (roamd)
//	Android/{data,obb}/com.nowhere.chooser/.nowhere-odhold/<pkg>
//	                                             EXTERNAL data hold_ondemand parked at login (DIA-20260816-19)
//
// Android/media/<pkg> is deliberately NOT dropped, even though it is named after the package. That tree is
// app-created but USER-FACING: it is MediaStore-indexed shared content -- the photos and videos a user sees
// in their gallery and reasonably considers theirs, not the app's (WhatsApp's Media tree is the canonical
// example). Switching an app off says "stop carrying the app", not "delete my photos", so those bytes keep
// roaming in the #media scope. The cost is that some dead weight survives for that one shape; the
// alternative is silently destroying content the user never associated with the app they switched off.
//
// The hold matters: at login roamd MOVES every kept app's CE+DE data under the chooser's dir, so an app the
// user switches off DURING a session still has its real bytes sitting there. Missing this shape would seal
// the very data we just decided to stop carrying.
// dropPkgForFileRel is dropPkgForRel for a FILE path: it reports whether rel lives UNDER a dropped
// package's app-data dir, rather than being that dir itself.
//
// Needed because SkipDir only stops the WALK. The manifest's Deferred index is carried forward separately,
// by the "present-not-deleted" rule -- a deferred file the walk did not positively see is assumed merely
// unmaterialised (mediad down, cache evicted) and its record is kept. A dropped package's files are never
// seen by construction, so without this they would be carried forward verbatim: the seal would still list
// the switched-off app's on-demand media and APK bytes, keeping them referenced and BILLED, and the drop
// would silently do nothing for exactly the apps most likely to be large.
func dropPkgForFileRel(rel string, drop map[string]bool) bool {
	if len(drop) == 0 {
		return false
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	switch {
	case len(parts) >= 2 && parts[0] != "Android" && parts[0] != chooserPkg:
		return drop[parts[0]] // <pkg>/... at a scope root (CE / DE)
	// DIA-20260816-19: the EXTERNAL hold shape FIRST. The generic Android case below would otherwise match it
	// with parts[2] == chooserPkg and answer drop["com.nowhere.chooser"], which is always false -- silently
	// carrying a dropped app's held external data forever.
	case len(parts) >= 6 && parts[0] == "Android" && (parts[1] == "data" || parts[1] == "obb") &&
		parts[2] == chooserPkg && parts[3] == odHoldDirName:
		return drop[parts[4]]
	case len(parts) >= 4 && parts[0] == "Android" && (parts[1] == "data" || parts[1] == "obb"):
		return drop[parts[2]]
	case len(parts) >= 4 && parts[0] == chooserPkg && parts[1] == odHoldDirName:
		return drop[parts[2]]
	}
	return false
}

// attrPkgForRel maps a tar-relative path to the package whose PLAN COST it is, or "" for bytes no app owns
// (DIA-20260805-11). This is the attribution side of dropPkgForRel, and it deliberately differs twice:
//
//   - Android/media/<pkg> IS attributed here. Those bytes are carried and billed, so they are part of what
//     that app costs the plan -- even though a drop deliberately spares them (they are the user's gallery
//     content; see dropPkgForRel). The screen must say what is being paid for; the drop decides what
//     switching off removes. Conflating the two is what would make a row promise savings it cannot deliver.
//   - a first path component counts as a package only if it LOOKS like one (contains a dot). pinnedApp's
//     fallback does not check, so in the #media scope (src /data/media/<uid>) it invents pseudo-packages out
//     of the user's own folders -- a 4K video under DCIM/Camera/ becomes an app called "DCIM", which already
//     shows up in the Offline-media screen. A money-shaped number must not inherit that.
//
// The hold shape matters most in practice: at login roamd MOVES every kept app's CE+DE data under
// com.nowhere.chooser/.nowhere-odhold/<pkg>, and a never-tapped app leaves it there all session -- so
// without that case most apps' data would file under the chooser itself.
func attrPkgForRel(rel string) string {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	switch {
	case len(parts) >= 4 && parts[0] == chooserPkg && parts[1] == odHoldDirName:
		return parts[2]
	// DIA-20260816-19: EXTERNAL hold before the generic Android case, which would bill every held byte to the
	// chooser. On an on-demand app this is the bulk of the profile (88 MB for one game), so getting it wrong
	// puts the biggest row on the wrong app in a screen whose whole job is telling the user what costs what.
	case len(parts) >= 5 && parts[0] == "Android" && (parts[1] == "data" || parts[1] == "obb") &&
		parts[2] == chooserPkg && parts[3] == odHoldDirName:
		return parts[4]
	case len(parts) >= 4 && parts[0] == "Android" &&
		(parts[1] == "data" || parts[1] == "obb" || parts[1] == "media"):
		return parts[2]
	case len(parts) >= 2 && parts[0] != "Android" && parts[0] != chooserPkg &&
		strings.Contains(parts[0], "."):
		return parts[0] // <pkg>/... at a scope root: CE, DE, and the #apps stage
	}
	return ""
}

// pkgAcct accumulates, during the seal walk, WHICH CHUNKS BELONG TO WHICH PACKAGE -- the index the manifest
// has never carried, since chunkManifest.Chunks is a flat list over one concatenated tar with no labels. It
// records chunk INDICES, not bytes: a chunk's sealed size is only known in the caller (walkChunks' emitSeal
// returns an index; the caller records sizeOf[h] separately), so the byte math happens there.
//
// Two shapes, matching how the walk emits:
//
//   - single: a file >= threshold is file-aligned (flushGroup runs first), so every chunk of its region is
//     wholly that file's -- exact attribution at zero extra I/O.
//   - groups: small files share chunks by construction, so one flushGroup's chunks are split PRO RATA by the
//     plaintext bytes each package contributed. Approximate, and only for the small-file tail.
//     NWP-20261127-01: every group is recorded, weights or not, with the unit that bounded it, so the span
//     index (pkg_span.go) sees every chunk range of the grouped tail.
//
// A nil *pkgAcct disables accounting entirely, so the walk behaves exactly as before.
type pkgAcct struct {
	single map[int]string // chunk index -> the one package that owns it
	groups []groupSpan    // [start,end) spans emitted by one flushGroup, with per-package weights
}

type groupSpan struct {
	start, end int
	weights    map[string]int64 // package -> plaintext bytes it contributed to this group
	unit       string           // NWP-20261127-01: the groupUnit that bounded the group ("" for loose root entries only)
	mixed      bool             // NWP-20261127-01: the group held entries of more than one unit (a loose root entry counts)
}

func newPkgAcct() *pkgAcct { return &pkgAcct{single: map[int]string{}} }

// own records that chunk i is wholly pkg's. Nil-safe and ""-safe so callers need no guards.
func (a *pkgAcct) own(i int, pkg string) {
	if a == nil || pkg == "" {
		return
	}
	a.single[i] = pkg
}

// attributePkgBytes converts chunk ownership into per-package SEALED bytes.
//
// essIdx translates the accumulator's EMIT indices into indices of sizes[] (which parallels the essential
// chunks, skipping deferred ones); -1 means the chunk deferred and is priced from Deferred[rel].Sz instead.
//
// Grouped chunks are split pro rata by plaintext weight and rounded DOWN per package, so the parts can only
// under-sum their span, never over-sum it. That direction is deliberate: the leftover lands in the caller's
// unattributed remainder, where it is shown honestly, rather than inflating an app's row.
//
// Returns nil when nothing was attributed, so the manifest field stays absent (omitempty) and a reader can
// tell "not measured" from "measured as zero".
func attributePkgBytes(a *pkgAcct, essIdx []int, sizes []int64) map[string]int64 {
	if a == nil {
		return nil
	}
	at := func(emit int) int64 {
		if emit < 0 || emit >= len(essIdx) {
			return 0
		}
		k := essIdx[emit]
		if k < 0 || k >= len(sizes) {
			return 0
		}
		return sizes[k]
	}
	out := map[string]int64{}
	for i, pkg := range a.single {
		if b := at(i); b > 0 {
			out[pkg] += b
		}
	}
	for _, g := range a.groups {
		var span, wsum int64
		for i := g.start; i < g.end; i++ {
			span += at(i)
		}
		for _, w := range g.weights {
			wsum += w
		}
		if span <= 0 || wsum <= 0 {
			continue
		}
		for pkg, w := range g.weights {
			if b := span * w / wsum; b > 0 { // integer division: rounds DOWN, so parts never exceed the span
				out[pkg] += b
			}
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// subtreeBytes sums the apparent size of the regular files under dir, stat-only (nothing is read or
// chunked). Used to price a dropped app-data dir for the shrink guard. Best-effort: an unreadable corner
// contributes 0, which UNDER-states the drop and so can only make the guard stricter -- the safe direction.
func subtreeBytes(dir string) int64 {
	var n int64
	filepath.Walk(dir, func(_ string, fi os.FileInfo, err error) error {
		if err == nil && fi.Mode().IsRegular() {
			n += fi.Size()
		}
		return nil
	})
	return n
}

func dropPkgForRel(rel string, drop map[string]bool) bool {
	if len(drop) == 0 {
		return false
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	switch {
	case len(parts) == 1:
		return drop[parts[0]]
	case len(parts) == 3 && parts[0] == "Android":
		switch parts[1] {
		case "data", "obb": // app-private only -- NOT Android/media, see the note above
			return drop[parts[2]]
		}
	case len(parts) == 3 && parts[0] == chooserPkg && parts[1] == odHoldDirName:
		return drop[parts[2]]
	// DIA-20260816-19: the EXTERNAL hold, Android/{data,obb}/<chooser>/.nowhere-odhold/<pkg>. Same reason the
	// CE/DE hold shape exists: at login roamd MOVES the app's external data here, so an app switched off
	// during the session still has its real bytes sitting under the chooser -- and without this shape the drop
	// would walk straight past the largest thing it was asked to stop carrying.
	case len(parts) == 5 && parts[0] == "Android" && (parts[1] == "data" || parts[1] == "obb") &&
		parts[2] == chooserPkg && parts[3] == odHoldDirName:
		return drop[parts[4]]
	}
	return false
}

func loadDeferList() map[string]bool {
	p := os.Getenv("NOWHERE_DEFER_LIST")
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	m := map[string]bool{}
	for _, ln := range strings.Split(string(b), "\n") {
		if ln = strings.TrimSpace(ln); ln != "" {
			m[filepath.ToSlash(ln)] = true
		}
	}
	if len(m) == 0 {
		return nil
	}
	return m
}

// sealFullEvery forces a full re-hash (ignore the scan cache) every Nth seal per profile, so a content change
// that somehow kept an identical mtime+size (which the cache would miss) self-corrects within N saves. The
// counter is a tiny per-tag file next to the caches. Default 20; 0 disables the periodic full re-hash.
func sealFullEvery() int {
	if n, err := strconv.Atoi(os.Getenv("NOWHERE_SEAL_FULL_EVERY")); err == nil && n >= 0 {
		return n
	}
	return 20
}

type scanEntry struct {
	Mtime  int64    `json:"m"`
	Size   int64    `json:"s"`
	Mode   uint32   `json:"o"`
	Fmt    int      `json:"f,omitempty"` // tarEntryFormat these chunks were sealed under; 0 = pre-versioning
	Chunks []string `json:"c"`
}
type scanRec struct {
	R string    `json:"r"`
	E scanEntry `json:"e"`
}

// fileScanCache maps a profile's large files to their sealed chunk hashes, keyed by the same DK tag as the
// content cache (so it's per-identity + per-store, and unreadable across profiles). Persisted as one JSON
// record per line under NOWHERE_BLOBCACHE.
//
// NWP-20261119-01 (h49 #4): it also maps each small-file GROUP's key (groupCacheKey) to the chunk hashes that
// group sealed to, persisted beside it as groupcache.<tag>. The key covers everything the group's tar bytes
// depend on, so an unchanged group is reused by hash and none of its files is opened. That file holds keys and
// chunk hashes only, never a rel.
type fileScanCache struct {
	mu  sync.Mutex
	tag string
	m   map[string]scanEntry

	groups   map[string][]string // group key -> chunk hashes, loaded from groupcache.<tag>
	gPending []groupPending      // groups THIS walk chunked from a clean read; sealCacheRefresh stores them
	gUsed    map[string]bool     // keys this walk reused or chunked clean; saveGroups keeps only these
	gHits    int                 // groups this walk reused by hash
	gTotal   int                 // groups this walk flushed
	gSkipped int                 // small regular files a reused group did not read

	writer sealWriterTally // NWP-20261201-12: what this walk found changed, for the push log line
}

// groupRec is one line of groupcache.<tag>.
type groupRec struct {
	K string   `json:"k"`
	C []string `json:"c"`
}

// groupPending is a group THIS walk chunked from a clean read: its key and its [start,end) manifest indices.
type groupPending struct {
	key        string
	start, end int
}

func scanCachePath(tag string) string {
	dir := os.Getenv("NOWHERE_BLOBCACHE")
	if dir == "" || tag == "" {
		return ""
	}
	return filepath.Join(dir, "scancache."+tag)
}

func groupCachePath(tag string) string {
	dir := os.Getenv("NOWHERE_BLOBCACHE")
	if dir == "" || tag == "" {
		return ""
	}
	return filepath.Join(dir, "groupcache."+tag)
}

func newFileScanCache(dk []byte) *fileScanCache {
	sc := &fileScanCache{tag: contentCacheTagFor(dk), m: map[string]scanEntry{}, groups: map[string][]string{}}
	if p := groupCachePath(sc.tag); p != "" {
		// NWP-20261201-12: sealCacheRefresh rewrites this file once a head commits, so its time is the last seal's.
		if fi, err := os.Stat(p); err == nil {
			sc.writer.since = fi.ModTime()
		}
		if b, err := os.ReadFile(p); err == nil {
			for _, line := range strings.Split(string(b), "\n") {
				if line == "" {
					continue
				}
				var rec groupRec
				if json.Unmarshal([]byte(line), &rec) == nil && rec.K != "" && len(rec.C) > 0 {
					sc.groups[rec.K] = rec.C
				}
			}
		}
	}
	if p := scanCachePath(sc.tag); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			for _, line := range strings.Split(string(b), "\n") {
				if line == "" {
					continue
				}
				var rec scanRec
				if json.Unmarshal([]byte(line), &rec) == nil && rec.R != "" {
					sc.m[rec.R] = rec.E
				}
			}
		}
	}
	return sc
}

// get returns the cached chunk hashes for rel IFF (mtime,size,mode) match AND every chunk is still
// known-present in the store. A GC'd chunk (not known-present) forces a re-chunk -- reusing it would point the
// head at a missing blob. Returns nil to mean "re-chunk", which is always safe.
func (sc *fileScanCache) get(rel string, mtime, size int64, mode uint32) []string {
	sc.mu.Lock()
	e, ok := sc.m[rel]
	sc.mu.Unlock()
	if !ok || e.Mtime != mtime || e.Size != size || e.Mode != mode || len(e.Chunks) == 0 {
		return nil
	}
	if e.Fmt != tarEntryFormat {
		// NWP-20260908-02: sealed under a different writeTarEntry shape. The stat matches but the BYTES would
		// not, so reusing these hashes would keep the old shape alive for every unchanged file -- i.e. make a
		// header change inert exactly where it matters most. Re-chunk once; the entry is replaced on put.
		return nil
	}
	for _, h := range e.Chunks {
		if !blobCacheKnown(h) {
			return nil
		}
	}
	return e.Chunks
}

func (sc *fileScanCache) put(rel string, mtime, size int64, mode uint32, chunks []string) {
	sc.mu.Lock()
	sc.m[rel] = scanEntry{Mtime: mtime, Size: size, Mode: mode, Fmt: tarEntryFormat, Chunks: append([]string(nil), chunks...)}
	sc.mu.Unlock()
}

// save rewrites the cache atomically, keeping only the rels seen in THIS seal so a deleted file's entry can't
// linger and pin its (now unreferenced) chunks in the cache forever. Best-effort.
func (sc *fileScanCache) save(keep map[string]bool) {
	p := scanCachePath(sc.tag)
	if p == "" {
		return
	}
	sc.mu.Lock()
	defer sc.mu.Unlock()
	tmp := p + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return
	}
	for rel, e := range sc.m {
		if keep != nil && !keep[rel] {
			continue
		}
		if b, err := json.Marshal(scanRec{R: rel, E: e}); err == nil {
			f.Write(b)
			f.Write([]byte("\n"))
		}
	}
	f.Close()
	os.Rename(tmp, p)
}

// beginWalk resets the per-walk group state. walkChunks calls it first.
func (sc *fileScanCache) beginWalk() {
	sc.mu.Lock()
	sc.gPending, sc.gUsed = nil, map[string]bool{}
	sc.gHits, sc.gTotal, sc.gSkipped = 0, 0, 0
	sc.writer.reset()
	sc.mu.Unlock()
}

// getGroup returns the cached chunk hashes of the group with this key IFF every chunk is still known-present in
// the store -- get's rule: a GC'd chunk forces a re-read, never a reference to a missing blob. nil = re-read.
func (sc *fileScanCache) getGroup(key string) []string {
	sc.mu.Lock()
	cs := sc.groups[key]
	sc.mu.Unlock()
	if len(cs) == 0 {
		return nil
	}
	for _, h := range cs {
		if !blobCacheKnown(h) {
			return nil
		}
	}
	return cs
}

// getGroupIf is getGroup gated on `use` (false => always a miss, for a forced full re-hash).
func (sc *fileScanCache) getGroupIf(use bool, key string) []string {
	if !use {
		return nil
	}
	return sc.getGroup(key)
}

// noteGroup counts a flushed group. A hit keeps its key for saveGroups; a clean miss also queues [start,end) for
// sealCacheRefresh. A torn miss (a member changed, vanished or failed while it was read) is neither kept nor
// queued, so its old entry drops at the next save and the next walk reads it again.
func (sc *fileScanCache) noteGroup(key string, start, end int, hit, clean bool, files int) {
	sc.mu.Lock()
	defer sc.mu.Unlock()
	if sc.gUsed == nil {
		sc.gUsed = map[string]bool{}
	}
	sc.gTotal++
	switch {
	case hit:
		sc.gUsed[key] = true
		sc.gHits++
		sc.gSkipped += files
	case clean && start >= 0:
		sc.gUsed[key] = true
		sc.gPending = append(sc.gPending, groupPending{key, start, end})
	}
}

func (sc *fileScanCache) putGroup(key string, chunks []string) {
	sc.mu.Lock()
	if sc.groups == nil {
		sc.groups = map[string][]string{}
	}
	sc.groups[key] = append([]string(nil), chunks...)
	sc.mu.Unlock()
}

// groupStats reports this walk's counts for the push log line.
func (sc *fileScanCache) groupStats() (hits, total, skipped int) {
	sc.mu.Lock()
	defer sc.mu.Unlock()
	return sc.gHits, sc.gTotal, sc.gSkipped
}

// saveGroups rewrites groupcache.<tag> atomically, keeping only the keys THIS walk reused or chunked clean, so a
// changed or deleted group cannot pin its old chunks forever. Best-effort, as save.
func (sc *fileScanCache) saveGroups() {
	p := groupCachePath(sc.tag)
	if p == "" {
		return
	}
	sc.mu.Lock()
	defer sc.mu.Unlock()
	tmp := p + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return
	}
	for k, cs := range sc.groups {
		if !sc.gUsed[k] || len(cs) == 0 {
			continue
		}
		if b, err := json.Marshal(groupRec{K: k, C: cs}); err == nil {
			f.Write(b)
			f.Write([]byte("\n"))
		}
	}
	f.Close()
	os.Rename(tmp, p)
}

// sealCacheRefresh runs once the head is committed (pushProfile, #69): it stores the freshly chunked large files
// and the groups this walk chunked from a clean read (their hashes are now referenced by the new head), then saves
// both caches. A group with a hash missing from results is skipped. nil sc is a no-op.
func sealCacheRefresh(sc *fileScanCache, ranges []scanRange, seen map[string]bool, results map[int]string) {
	if sc == nil {
		return
	}
	for _, r := range ranges {
		hs := make([]string, 0, r.end-r.start)
		for i := r.start; i < r.end; i++ {
			hs = append(hs, results[i])
		}
		sc.put(r.rel, r.mtime, r.size, r.mode, hs)
	}
	sc.save(seen)
	sc.mu.Lock()
	pend := append([]groupPending(nil), sc.gPending...)
	sc.mu.Unlock()
next:
	for _, g := range pend {
		hs := make([]string, 0, g.end-g.start)
		for i := g.start; i < g.end; i++ {
			h := results[i]
			if h == "" {
				continue next
			}
			hs = append(hs, h)
		}
		sc.putGroup(g.key, hs)
	}
	sc.saveGroups()
}

// groupCacheKey is the hex SHA-256 of what a group's tar bytes depend on (NWP-20261119-01): tarEntryFormat, then
// per member in walk order its rel and mode, plus size and mtime for a regular file, mtime for a directory or other
// non-symlink entry (its header carries it), and nothing more for a symlink (writeTarEntryChecked skips it). Owner
// fields are zeroed (normalizeTarOwnership) and the CDC parameters are constants, so equal keys mean equal bytes.
func groupCacheKey(g []walkEnt) string {
	h := sha256.New()
	var b [8]byte
	u32 := func(v uint32) { binary.BigEndian.PutUint32(b[:4], v); h.Write(b[:4]) }
	i64 := func(v int64) { binary.BigEndian.PutUint64(b[:], uint64(v)); h.Write(b[:]) }
	u32(tarEntryFormat)
	for _, e := range g {
		rel := filepath.ToSlash(e.rel)
		u32(uint32(len(rel)))
		h.Write([]byte(rel))
		u32(uint32(e.info.Mode()))
		switch {
		case e.info.Mode().IsRegular():
			i64(e.info.Size())
			i64(e.info.ModTime().UnixNano())
		case e.info.Mode()&os.ModeSymlink != 0:
		default:
			i64(e.info.ModTime().UnixNano())
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}

// groupUnit is the top-level rel component a small entry's group is bounded by (NWP-20261119-01). A root-level
// non-directory entry has unit "": it opens no boundary and joins whatever group is open.
//
// NWP-20261127-01: a held package is its own unit. A rel under the On-demand hold,
// com.nowhere.chooser/.nowhere-odhold/<pkg> itself or anything below it, has unit
// com.nowhere.chooser/.nowhere-odhold/<pkg>, so each held package's small files form their own groups and its
// chunks hold only its data (the span index, pkg_span.go). The hold dir itself keeps unit com.nowhere.chooser.
//
// ONE-OFF COST, as NWP-20261119-01's: the first seal on this build re-chunks the hold's grouped tail once. The tar
// stream is byte-identical; only the chunk boundaries move. The held packages' Pkg figures change once, because
// they stop sharing the chooser's group pro rata and become exact.
func groupUnit(rel string, info os.FileInfo) string {
	r := filepath.ToSlash(rel)
	if hp := chooserPkg + "/" + odHoldDirName + "/"; strings.HasPrefix(r, hp) && len(r) > len(hp) {
		rest := r[len(hp):]
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			rest = rest[:i]
		}
		return hp + rest
	}
	if i := strings.IndexByte(r, '/'); i >= 0 {
		return r[:i]
	}
	if info.IsDir() {
		return r
	}
	return ""
}

// writeSealProg writes one seal progress frame for pushProfile's ticker. total is the stored denominator: 0 until
// walkChunks returns (the incremental arm has no pre-walk, NWP-20261119-01), then st.bytes. With a total the frame
// is writeProg's own "<phase> <done> <total>". Without one the seal does not know its size yet, so it writes no
// total that a reader can take for the whole: it writes "sizes 0 <beat>", the unit-less phase (lease_progress.go
// says why "sizes"), so every gate reader draws the bar at 0 with no byte text. beat counts the ticker's frames, so
// each line differs from the one before it and the daemon's stall watchdog (runWorkerHeld: it resets only on a
// CHANGED line) stays fed through a long walk; the first seal on this build re-chunks every group. writeProg
// writes nothing at total 0, so the walk would otherwise be silent. This writes the line itself, with the phase as
// an argument, and does not touch progPhase: the ticker is a second goroutine, and a swap of the shared phase
// there could be read back as the "prevPhase" that pushProfile's sizes block restores.
func writeSealProg(done, total, beat int64) {
	if total > 0 {
		writeProg(int(done), int(total))
		return
	}
	file := os.Getenv("NOWHERE_PROGRESS")
	if file == "" || beat <= 0 {
		return
	}
	line := fmt.Sprintf("sizes 0 %d", beat)
	if sc, _ := progScope.Load().(string); sc != "" {
		line += " " + sc // #113: trailing scope keyword, as writeProg
	}
	tmp := file + ".tmp"
	if os.WriteFile(tmp, []byte(line+"\n"), 0o600) == nil {
		os.Rename(tmp, file)
	}
}

// sealProgTotalHook is for tests only: pushProfile hands it its stored progress total once, before the walk. nil
// in production.
var sealProgTotalHook func(total *atomic.Int64)

// sealCounterNext reads+increments a tiny per-tag seal counter and reports whether THIS seal should be a full
// re-hash (every sealFullEvery()th). Best-effort: a missing/unwritable counter just never forces a full.
func sealCounterNext(tag string) bool {
	every := sealFullEvery()
	if every <= 0 || tag == "" {
		return false
	}
	dir := os.Getenv("NOWHERE_BLOBCACHE")
	if dir == "" {
		return false
	}
	p := filepath.Join(dir, "sealcount."+tag)
	n := 0
	if b, err := os.ReadFile(p); err == nil {
		n, _ = strconv.Atoi(strings.TrimSpace(string(b)))
	}
	n++
	os.WriteFile(p, []byte(strconv.Itoa(n)), 0o600)
	return n%every == 0
}

type scanRange struct {
	rel         string
	mtime, size int64
	mode        uint32
	start, end  int // [start,end) indices into the manifest for this freshly-chunked file
	tier        int // #129: mediaTier of a DEFERRED file (0=on-demand, 2=prefetch); 0 + unused for essential ranges
}

type walkEnt struct {
	path, rel string
	info      os.FileInfo
}

// walkChunks walks src in the SAME order as tarDirTo, driving the seal. An unchanged large file (scan-cache
// hit) reuses its stored chunk hashes via emitCached (no read), and so does an unchanged group of small files
// (a group-cache hit, NWP-20261119-01); every other byte is chunked -- small files grouped (one group per
// top-level directory at most), large files each in their own file-aligned region -- and sent to emitSeal. emitSeal/emitCached
// return the manifest index they assigned. `bump` advances the progress counter by the bytes a skipped file
// contributed (sealed bytes are counted by the caller as they finish). Returns the index ranges of freshly
// chunked large files (to refresh the scan cache after the seal lands) and the set of large-file rels seen
// (to prune deleted files). When forceFull is set, the scan cache is ignored (every large file is re-chunked).
//
// prevDef is the CURRENT head's Deferred index (#84 P3d): a deferred file whose stat matches its manifest
// record is CARRIED FORWARD into `carried` without being read. This is the seal guard that makes the periodic
// sync safe while the media daemon's overlays are LIVE -- the overlay serves getattr from the manifest (so
// the stat always matches), but a READ would lazily fetch the whole file from the store just to re-seal
// bytes the store already holds. forceFull deliberately does NOT bypass the carry: under the read-only
// overlay the file cannot have changed, and forcing a read through the mount is exactly the failure mode.
//
// unders (#84, no-teardown seal -- see media_seal.go) maps each live media-overlay mountpoint under src to
// its bind-hidden .under dir. The walk never descends into a mounted overlay: it walks the .under dir in its
// place (same rels), so stubs stay absent (carried forward via prevDef by the caller), real files seal
// normally, and no byte is read through FUSE -- the overlays stay mounted across seals, which is what keeps
// running apps' mount namespaces valid (the per-seal unmount churn blinded them; proven on FP3 2026-07-03).
// walkStats (DIA-20260816-17) counts what the walk actually TOUCHED. It exists because `seen` does not, and
// cannot: `seen` is the deferred-carry membership test (see the present-not-deleted rule in pushProfile) and
// the scan cache's key set, so it holds ONLY files at or above the threshold. Widening it would silently
// change which deferred entries carry forward and what sc.save persists -- a data-safety change to answer a
// logging question.
//
// So the diagnosis got its own counters. `walk saw 0 path(s)` printed len(seen) and read as "the walk found
// NOTHING", when it meant "no file >= 1 MiB" -- a completely ordinary state. That one label sent the #719
// investigation and three follow-ups after a phantom empty walk, and each wrong theory ("the restore returned
// nothing", "CE was evicted at seal time") cost a build-and-flash round to disprove. On lynx 2026081604 the
// scope held 35 files and the line still said 0.
//
// entries vs files vs large is the distinction that ends that class of mistake: a scope with entries>0 and
// large==0 is holding small files and is FINE; entries==0 is a genuinely empty walk and is not.
type walkStats struct {
	entries int    // every entry visit() handled -- regular files of any size, dirs, symlinks
	files   int    // regular files only
	large   int    // regular files >= threshold (or force-deferred): the ones that enter `seen`
	bytes   int64  // total regular-file bytes offered to the walk, before dedup/carry
	under   int    // entries read through a .under substitution rather than the live overlay (#84)
	digest  string // NWP-20261123-04: hex SHA-256 of the walk's policy and every entry it handled (media_nochange.go)
}

func walkChunks(src string, sc *fileScanCache, threshold int64, forceFull bool, od bool, prevDef map[string]deferredFile,
	unders map[string]string, pins map[string]bool, tiers map[string]mediaTier, budget int64, emitSeal func([]byte) int, emitCached func(string) int, bump func(int64), acct *pkgAcct) (ranges []scanRange, seen map[string]bool, deferred []scanRange, carried map[string]deferredFile, blind int, dropped int64, st walkStats, discard []scanRange) {
	return walkChunksExcl(src, sc, threshold, forceFull, od, prevDef, unders, pins, tiers, budget, emitSeal, emitCached, bump, acct, nil)
}

// walkChunksExcl is walkChunks with excl: the packages this scope's sign-in left unfetched (NWP-20261130-03,
// sealUnfetchedList). Their directories -- <pkg> and its on-demand hold -- are skipped like a dropped package's, but
// NOT priced into dropped: the carry re-emits their stored span, so the head does not shrink by them. tarDirToExcl
// applies the same test; the two seal paths must agree.
func walkChunksExcl(src string, sc *fileScanCache, threshold int64, forceFull bool, od bool, prevDef map[string]deferredFile,
	unders map[string]string, pins map[string]bool, tiers map[string]mediaTier, budget int64, emitSeal func([]byte) int, emitCached func(string) int, bump func(int64), acct *pkgAcct, excl map[string]bool) (ranges []scanRange, seen map[string]bool, deferred []scanRange, carried map[string]deferredFile, blind int, dropped int64, st walkStats, discard []scanRange) {
	seen = map[string]bool{}
	carried = map[string]deferredFile{}
	// od is the on-demand media split for THIS scope: the caller ANDs the process-wide switch with
	// scopeDefersMedia (NWP-20260923-02), so the vault and #de walks never defer by the heuristic. forceDef
	// below is NOT gated by it -- #apps defers on-demand APKs through the list with od off.
	forceDef := loadDeferList() // #204: rels (on-demand app APKs) the seal must defer regardless of size/heuristic
	dropPkgs := loadDropList()  // DIA-20260804-04: packages switched Off -> their data is not carried
	var essBytes int64          // #108 P3 / #129: bytes of bulk media kept essential (login) so far, against the Tier-1 budget
	// NWP-20261123-04: the walk digest a no-change #media push compares (media_nochange.go).
	dg := newWalkDigest(threshold, od, budget, pins, tiers, forceDef, dropPkgs)
	if sc != nil {
		sc.beginWalk()
	}
	var group []walkEnt
	var groupTop string // the top-level rel component of the open group ("" until a member names one)
	var groupMixed bool // NWP-20261127-01: the open group holds entries of more than one unit (a loose root entry counts)
	flushGroup := func() {
		if len(group) == 0 {
			return
		}
		g := group
		unit, mixed := groupTop, groupMixed // captured before the reset: the span index needs both
		group, groupTop = nil, ""
		groupMixed = false
		// DIA-20260805-11: a group's chunks span several files by construction, so record the span plus each
		// package's plaintext weight and let the caller split the sealed bytes pro rata. Weights come from the
		// entries themselves (no extra stat). NWP-20261127-01: every group is recorded, weights or not, so the span
		// index (pkg_span.go) sees every chunk range; attributePkgBytes skips a zero-weight group.
		gs := groupSpan{start: -1, unit: unit, mixed: mixed, weights: map[string]int64{}}
		var regBytes int64
		regFiles := 0
		for _, e := range g {
			if e.info != nil && e.info.Mode().IsRegular() {
				regBytes += e.info.Size()
				regFiles++
				if acct != nil {
					if p := attrPkgForRel(e.rel); p != "" {
						gs.weights[p] += e.info.Size()
					}
				}
			}
		}
		// NWP-20261119-01 (h49 #4): an unchanged group (same key, every chunk still known-present) is reused by
		// hash -- no file opened, no pipe, no goroutine -- exactly as the large-file arm reuses a scan-cache hit.
		// The key covers every input of the group's tar bytes and the group starts its own cdcSplit, so its
		// chunks are the ones a clean read would produce. forceFull bypasses it as it bypasses the file cache.
		var key string
		if sc != nil {
			key = groupCacheKey(g)
			if cached := sc.getGroupIf(!forceFull, key); cached != nil {
				for _, h := range cached {
					i := emitCached(h)
					if gs.start < 0 {
						gs.start = i
					}
					gs.end = i + 1
				}
				bump(regBytes) // skipped the read -> credit its bytes to progress at once
				sc.noteGroup(key, gs.start, gs.end, true, true, regFiles)
				if acct != nil && gs.start >= 0 {
					acct.groups = append(acct.groups, gs)
				}
				return
			}
		}
		// NWP-20261201-12: a group the cache did not serve. A group whose chunk is no longer known present misses too:
		// the safe direction. A forced walk misses every group, so it counts none.
		if !forceFull {
			sc.noteWriterGroupMiss(g)
		}
		// clean is written before CloseWithError, which is what ends cdcSplit's read, so reading it after the
		// split returns is ordered behind that write (the tarErr argument in pushProfile's legacy arm).
		clean := false
		pr, pw := io.Pipe()
		go func() {
			c, err := writeEntriesTarChecked(pw, g)
			clean = c
			pw.CloseWithError(err)
		}()
		cdcSplit(pr, func(c []byte) {
			i := emitSeal(c)
			if gs.start < 0 {
				gs.start = i
			}
			gs.end = i + 1
		})
		if sc != nil {
			sc.noteGroup(key, gs.start, gs.end, false, clean, regFiles)
		}
		if acct != nil && gs.start >= 0 {
			acct.groups = append(acct.groups, gs)
		}
	}
	// visit handles one walk entry: large files chunk file-aligned (deferred split / scan-cache reuse), and
	// everything else (small files, dirs, symlinks) joins the grouped tar. Shared by the main walk and the
	// .under substitution walk so both emit identically -- only the path they READ from differs.
	var visit func(p, rel string, info os.FileInfo)
	visit = func(p, rel string, info os.FileInfo) {
		// DIA-20260816-17: count BEFORE any classification, so the totals describe the walk itself and not the
		// subset that happened to survive a threshold, a tier or a budget.
		st.entries++
		if info.Mode().IsRegular() {
			st.files++
			st.bytes += info.Size()
		}
		// NWP-20261123-04: fold every entry into the walk digest, before any classification, in walk order.
		dg.add(rel, info)
		fd := forceDef[filepath.ToSlash(rel)] // #204: explicit on-demand defer -> file-aligned deferred region, any size
		if info.Mode().IsRegular() && (info.Size() >= threshold || fd) {
			st.large++
			sc.noteWriterFile(rel, info) // NWP-20261201-12
			seen[rel] = true
			mt, sz, md := info.ModTime().UnixNano(), info.Size(), uint32(info.Mode())
			// #129: decide this file's offline-media tier. classifyTier layers #108 pin > per-profile override >
			// curated default on top of classifyDeferred, so only bulk media is ever non-essential and a
			// login/state-critical file can never be demoted out of the login restore. od off -> everything
			// essential (today's pre-#84 behavior). isMedia gates the Tier-1 budget below.
			tier := tierEssential
			if fd {
				// #204: an on-demand app's APK -- deferred UNCONDITIONALLY (no media heuristic, no budget). Its
				// bytes ride the #apps seal so a tap can materialise them, but stay out of the login restore.
				tier = tierOnDemand
			} else {
				isMedia := classifyDeferred(rel, sz)
				if od && isMedia {
					tier = classifyTier(rel, sz, tiers, pins)
				} else if od {
					// NWP-20260829-29 -- THE RETURN DOOR. This is the exact site where a now-LOCAL file's fate is
					// decided, and until now it was a one-way ratchet: a file mediad had materialized (a #108 pin or
					// a #129 prefetch writes the real bytes into the passthrough dir and tombstones the stub) is a
					// real file by the next walk, so it arrives here -- and if classifyDeferred says no, which it
					// always does for a path `mediaDirs` does not list, it falls through with tier == tierEssential
					// (line 762) and rides the login tar from then on, forever, with nothing able to send it back.
					//
					// redeferTier lets it RETURN to Deferred, and only return: it requires the file to be in prevDef
					// already, so this can never demote something that has always been restored at login.
					//
					// ⚠ DO NOT set isMedia in this branch. The Tier-1 budget block below only fires when
					// tier == tierEssential, which this arm never leaves it as -- setting it would be dead code that
					// reads like a policy.
					if t, ok := redeferTier(rel, sz, prevDef, tiers, pins); ok {
						tier = t
					}
				}
				// #108 P3 budget (Tier-1): bulk media kept at login -- via a pin OR an essential-tier config -- is
				// essential only until the user's byte budget fills, in stable walk order; the excess FALLS BACK to
				// on-demand. budget<=0 = no cap. Non-media essential files never count and are always essential.
				if tier == tierEssential && isMedia {
					if budget > 0 && essBytes+sz > budget {
						tier = tierOnDemand // over budget -> stream on-access (best-effort keep-at-login, matches #108)
					} else {
						essBytes += sz
					}
				}
			}
			if tier != tierEssential {
				// Deferred: EXCLUDED from the login tar; served on-access (Tier-3) or background-prefetched
				// (Tier-2) by the media daemon. Stamp the tier on the record so mediad + the next seal agree.
				// #84 P3d: an UNCHANGED deferred file (stat == its record in the current head, every chunk still
				// known-present) is carried forward by hash -- NO read. Critical under a live media overlay: getattr
				// is served from this same manifest record (always matches), while a read would fetch the whole
				// file from the store. A re-tiering re-stamps the carried record's Tier without re-reading bytes.
				// ⚠ deferredMTimeNanos, not a raw compare (NWP-20260829-29). deferredFile.MTime is UnixNano when
				// the seal wrote it and UNIX SECONDS when the web importer did. materialize restores the file's
				// mtime from deferredMTimeNanos(d.MTime), so an imported file on disk reads seconds*1e9 while its
				// record still says seconds -- the raw comparison CANNOT match, and every re-defer would miss this
				// carry and re-chunk the whole file. That is not just slow: the importer chunked at FIXED 1 MiB
				// boundaries while the seal uses CDC, so the new hashes match nothing in the store and the entire
				// media set re-uploads on the logoff critical path. Inert for seal-written records, which are
				// already nanos and pass through unchanged.
				if prev, ok := prevDef[rel]; ok && prev.Size == sz && deferredMTimeNanos(prev.MTime) == mt && deferredChunksKnown(prev) {
					prev.Tier = int(tier)
					carried[rel] = prev
					bump(sz)
					return
				}
				// Chunk the RAW file bytes (NO tar wrapper -> the media daemon concatenates chunks to reconstruct
				// the file) into a SEPARATE deferred region. No scan-cache reuse for deferred files: a cached hash
				// could be tar-wrapped from a pre-flag seal, and mixing shapes would corrupt; the content cache
				// still skips the crypto for an unchanged chunk, so the cost is the re-read only.
				start, end := -1, -1
				// nb = the EXACT plaintext bytes fed to the chunker -> the record's Size. It MUST be the count of
				// bytes actually chunked, not the walk-time stat `sz`: mediad's fetch integrity check compares the
				// manifest Size to the sum of the chunk bytes (media_server.go), and a file being written between
				// the walk stat (line 233) and this read outgrows `sz` -> Size < chunk bytes -> mediad refuses the
				// file forever. (Organic Maps appending to *.mwm.ready.downloading; root-caused on-device 2026-07-14.)
				var nb int64
				torn := false
				f, oerr := os.Open(p)
				if oerr != nil {
					// NWP-20260829-29. This used to be `if f, err := os.Open(p); err == nil { ... }` with NO else:
					// on a failed open nothing was appended, start stayed -1, torn stayed false, and seen[rel] was
					// already TRUE (set at the top of visit) -- so the caller's present-not-deleted rule saw the file
					// as handled and DROPPED its stored deferred record. Losing the record loses the file, since the
					// bytes were only ever in the store. Mirror the torn branch: keep what the head already has.
					fmt.Fprint(os.Stderr, sealUnreadableKeepLine(rel, "deferred record", oerr))
					seen[rel] = false
					return
				}
				{
					cdcSplit(f, func(c []byte) {
						nb += int64(len(c))
						i := emitSeal(c)
						if start < 0 {
							start = i
						}
						end = i
					})
					sealAfterDeferredRead(p)
					// Belt-and-suspenders: if the file changed WHILE we read it (an app actively writing it), we
					// captured a torn snapshot -- a post-read fstat that differs from the walk-time stat is the tell.
					//
					// COMPARE AGAINST THE WALK-TIME SIZE `sz`, not only against `nb`. When a writer appends while we
					// are still reading, the reader picks the new bytes up, so nb ends up EQUAL to the final size and
					// that clause cannot fire -- detection then rests entirely on the mtime differing. mtime has finite
					// granularity, so two writes landing in the same tick share one and the tear goes unseen. Comparing
					// fi.Size() to sz catches growth directly and needs no clock at all.
					//
					// Keep all three: sz vs fi.Size() catches growth, nb vs fi.Size() catches a SHRINK or a read that
					// stopped early, and mtime catches an in-place rewrite that changed no length.
					if fi, ferr := f.Stat(); ferr == nil &&
						(fi.Size() != nb || fi.Size() != sz || fi.ModTime().UnixNano() != mt) {
						torn = true
					}
					f.Close()
				}
				if torn {
					// Don't persist an in-progress write. CLEAR seen[rel] so the caller's present-not-deleted rule
					// CARRIES the prior stable deferred record forward -- leaving seen=true would make it treat this
					// as a reclassification and DROP the good prior version. A brand-new mid-write file (no prior
					// record) is simply omitted and captured on the next, stable seal. The chunks already emitted
					// for the torn read sit in the emit order, where the caller would count anything not in a
					// deferred range as ESSENTIAL tar bytes -- raw file bytes between tar entries, which a restore
					// reads as a bad header (or, behind a zero prefix, as the end of the archive). `discard` names
					// them so the caller excludes them from every manifest; their blobs are still uploaded (and,
					// in cap mode, leased once by capFlush), and store GC reclaims them.
					fmt.Fprintf(os.Stderr, "[seal] %q changed while it was read -> not sealed this time; the stored record is kept\n", rel)
					if start >= 0 {
						discard = append(discard, scanRange{rel: rel, start: start, end: end + 1})
					}
					seen[rel] = false
					return
				}
				if start >= 0 {
					deferred = append(deferred, scanRange{rel: rel, mtime: mt, size: nb, mode: md, start: start, end: end + 1, tier: int(tier)})
				}
				return // do NOT writeEntryTar / add to the essential ranges
			}
			// DIA-20260805-11: a file >= threshold is file-aligned, so each of its chunks is wholly its own --
			// exact attribution. BOTH branches must record it: on an incremental seal most large files are
			// UNCHANGED and take the cached branch, so attributing only freshly-read files would leave nearly
			// everything unowned and every row would read far too small.
			flushGroup()
			// NWP-20260903-22: the group flush belongs HERE, on the ESSENTIAL path, not at the top of the
			// large-file branch where it used to sit (three lines above the tier decision).
			//
			// WHY IT IS NEEDED AT ALL: an essential large file is written file-aligned, so its region must start
			// on a chunk boundary -- both sub-branches below (the scan-cache hit and the writeEntryTar read)
			// depend on that, and the tail flush after the walk closes the last group.
			//
			// WHY IT MUST NOT FIRE EARLIER: a DEFERRED file emits no tar bytes whatsoever -- the carry-by-hash
			// arm returns without reading, and the freshly-chunked arm chunks RAW file bytes into their own
			// region and returns explicitly without writeEntryTar. Flushing for one of those cut the grouped
			// essential tar in half for nothing. On a scope whose essential stream is ONE ~1.95 GB tar of ~11.5k
			// sub-1MiB images, every newly materialized >=1 MiB file inserted a PERMANENT structural split:
			// flushGroup starts a fresh cdcSplit, so the segment before ended in a truncated chunk and the one
			// after restarted misaligned until the CDC re-synchronised. Measured on lynx (odimport9, 2026-08-29):
			// 65 chunks / 68.53 MiB uploaded by a logoff that should have carried almost everything by hash.
			//
			// MOVING IT IS BYTE-IDENTICAL TO THE TAR STREAM, which is what makes this safe rather than merely
			// cheaper: writeEntriesTar ends with tw.Flush(), NOT tw.Close(), so a group contributes no trailer
			// and the essential stream is one logical tar closed once by writeTarFooter. Merging two groups
			// therefore produces exactly the same bytes in exactly the same order -- only the chunk boundary
			// moves. And the manifest is order-filtered (main.go builds `chunks` as emit order minus
			// deferredIdx), so a deferred file's chunks landing before the group's changes no essential index.
			apkg := attrPkgForRel(rel)
			// NWP-20260906-16: this arm records its range TOO. It used to record none, and the consequence was
			// invisible because nothing read `ranges` except the scan cache -- but the #91 slice-5c essential
			// index is built from it, and in STEADY STATE almost every file takes this branch. The index would
			// have been empty on every seal after the first.
			//
			// ⚠ AND #apps ESCAPED THAT ONLY BY ACCIDENT OF A `cp` FLAG: roamd rebuilds its stage from scratch
			// every seal with a plain `cp` (no `-p`), so every staged APK has a fresh mtime and this cache never
			// hits. Adding `cp -p` as an optimisation -- an obvious thing for someone to do -- would have made
			// the whole carry silently inert. Recording it in both arms removes that coupling entirely.
			if cached := sc.getIf(!forceFull, rel, mt, sz, md); cached != nil {
				start, end := -1, -1
				for _, h := range cached {
					i := emitCached(h)
					acct.own(i, apkg)
					if start < 0 {
						start = i
					}
					end = i
				}
				if start >= 0 {
					ranges = append(ranges, scanRange{rel, mt, sz, md, start, end + 1, 0})
				}
				bump(sz) // skipped the read -> credit its bytes to progress at once
			} else {
				// NWP-20261024-03: ONE closure holds the pipe goroutine so a re-read is a second call, not a second
				// `go` statement (goStmtAllowed pins walkChunks). The goroutine closes the pipe with the WRITE error
				// only: a tear is not an error to the reader -- cdcSplit panics on a non-nil one and the whole seal
				// would be refused.
				read := func(inf os.FileInfo) (start, end int, torn bool, err error) {
					start, end = -1, -1
					pr, pw := io.Pipe()
					type readRes struct {
						torn bool
						err  error
					}
					done := make(chan readRes, 1)
					go func() {
						tn, e := writeEntryTarChecked(pw, p, inf, rel)
						pw.CloseWithError(e)
						done <- readRes{tn, e}
					}()
					cdcSplit(pr, func(c []byte) {
						i := emitSeal(c)
						acct.own(i, apkg)
						if start < 0 {
							start = i
						}
						end = i
					})
					r := <-done
					return start, end, r.torn, r.err
				}
				start, end, torn, werr := read(info)
				recMt, recSz, recMd := mt, sz, md
				if werr == nil && start >= 0 && torn {
					// The file changed between the walk stat and the copy, so the entry just emitted is the header
					// of one version around the bytes of another (zero-padded if it shrank, cut if it grew).
					// `discard` names its chunks so pushProfile keeps them out of every manifest, and the file is
					// read ONCE more from a fresh stat. The re-read's chunks follow the discarded ones at once --
					// the group was flushed before the first read and the walk has not moved on -- so once the
					// discard is removed the essential stream is still in walk order. The fresh stat is also what
					// the scan cache records, so the next seal hits it only while the file is still that version.
					discard = append(discard, scanRange{rel: rel, start: start, end: end + 1})
					fmt.Fprintf(os.Stderr, "[seal] %q changed while it was read -> reading it again\n", rel)
					if fi, lerr := os.Lstat(p); lerr != nil {
						start, werr = -1, lerr
					} else if !fi.Mode().IsRegular() {
						start, werr = -1, errors.New("no longer a regular file when it was read again")
					} else {
						start, end, torn, werr = read(fi)
						recMt, recSz, recMd = fi.ModTime().UnixNano(), fi.Size(), uint32(fi.Mode())
						if werr == nil && start >= 0 && torn {
							// Never a third read: keep what was read, as before this slice.
							fmt.Fprintf(os.Stderr, "[seal] %q changed again while it was re-read -> sealed as read\n", rel)
						}
					}
				}
				if werr != nil || start < 0 {
					// NWP-20261011-17 (docs/backlog.md, "An unreadable ESSENTIAL file keeps seen[rel] = true"): the
					// essential twin of the deferred arm's failed-open clear above (NWP-20260829-29). writeTarEntry
					// SKIPS a regular file it cannot open -- no header, nil error -- so werr cannot name that case;
					// start < 0 does. A regular file that was opened always yields its 512-byte header, hence at
					// least one chunk, so start < 0 here means we have no bytes for it. seen[rel] was already set TRUE
					// at the top of visit, and leaving it there made carryMediaEssentialRels (and the #apps carry)
					// count the file as walked and DROP its stored span -- losing a file whose bytes were only in the
					// store, labelled as the healthy answer. Clearing it keeps what the head already has, exactly as
					// the deferred arm does; no range is recorded, nothing is counted blind.
					//
					// ⚠ Residual, pre-existing, NOT fixed here: (1) a genuine I/O error mid-copy, after the header,
					// reaches cdcSplit through the pipe and panics it via check(), refusing the whole seal -- loud,
					// unchanged, which is why werr != nil is belt-and-suspenders (recorded in the unreadable-ESSENTIAL backlog row).
					// A TORN read here is handled above (NWP-20261024-03); a torn GROUPED small file was not
					// *(superseded by NWP-20261027-06: the grouped path reads each small file whole and re-reads it once)*.
					why := "no bytes read -- the open failed or the file vanished after the walk stat"
					if werr != nil {
						why = errCode(werr)
					}
					fmt.Fprintf(os.Stderr, "[seal] %q unreadable -> keeping the stored essential span: %s\n", rel, why)
					seen[rel] = false
				} else {
					ranges = append(ranges, scanRange{rel, recMt, recSz, recMd, start, end + 1, 0})
				}
			}
		} else {
			// NWP-20261119-01 (h49 #4): a group also ends where the walk leaves a top-level directory -- in the
			// vault, a package. Before this a group ended only at an essential large file's flush, so one changed
			// small file changed a group that could span many packages, and no group key was stable from seal to
			// seal. Byte-identical to the tar stream for the reason in the NWP-20260903-22 block above: only the
			// chunk boundary moves.
			//
			// A root-level non-directory entry has unit "" and opens no boundary: it joins the open group, as
			// before. The vault has no root-level files; the rule keeps a scope's loose root files (and the
			// deferred-split fixture in group_flush_test.go) in one group.
			//
			// ONE-OFF COST: the first seal on this build re-chunks the grouped essential tar of every scope that
			// has small files, once: new boundaries, new chunk hashes, uploaded once. After that an unchanged
			// package's group is reused by hash and none of its files is read.
			//
			// NWP-20261127-01: a group that holds entries of more than one unit is mixed, and the span index
			// gives none of its chunks to a package. A loose root entry (unit "") counts as another unit.
			if u := groupUnit(rel, info); u != "" {
				if groupTop != "" && u != groupTop {
					flushGroup()
				}
				if groupTop == "" {
					if len(group) > 0 {
						groupMixed = true // loose root entries opened this group before u
					}
					groupTop = u
				}
			} else if groupTop != "" {
				groupMixed = true // a loose root entry joins u's group
			}
			sc.noteWriterFile(rel, info) // NWP-20261201-12: this arm also takes directories and symlinks; it counts regular files only
			group = append(group, walkEnt{p, rel, info})
		}
	}
	direntCache := map[string]map[string]fs.FileMode{} // NWP-20260825-09
	filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			if sealWalkBlind(err) {
				// NWP-20260825-09: a special file we cannot stat is not a blind spot -- it has no content.
				if sp, known := sealSpecialFromDirent(p, direntCache); known && sp {
					fmt.Fprintf(os.Stderr, "[seal] skip special file %q (fifo/socket/device; nothing to seal -- NWP-20260825-09)\n", p)
					return nil
				}
				blind++ // unreadable, NOT vanished -> the caller refuses to publish a manifest built half-blind
				sealBlindLog(blind, p, err)
			}
			return nil // a path vanished under the live user -> skip, matches tarDirTo
		}
		rel, _ := filepath.Rel(src, p)
		if rel == "." {
			return nil
		}
		if info.IsDir() {
			if dropPkgForRel(rel, dropPkgs) {
				// DIA-20260804-04: the user switched this app Off -> stop carrying its data. Measure what we
				// are skipping (stat-only, no reads) so the shrink guard can tell whether the drop actually
				// ACCOUNTS for the shrink, instead of treating any drop at all as a blanket excuse.
				dropped += subtreeBytes(p)
				return filepath.SkipDir
			}
			if info.IsDir() && dropPkgForRel(rel, excl) {
				return filepath.SkipDir // NWP-20261130-03: unfetched in this scope -- the carry re-emits its stored span, never the phone's copy
			}
			if isOdFetchStagePath(rel) {
				return filepath.SkipDir // NWP-20261130-03: a killed fetch's stage -- never sealed (unfetched_fetch.go)
			}
			if info.IsDir() && isAppCodeStagePath(rel) {
				// NWP-20260901-17: the chooser's transient APK-install staging -- never sealed. Its real
				// life is the #apps scope; sealing a mid-materialise snapshot here is how ~215MB of gms
				// APKs became permanent "Profile" ghosts. See isAppCodeStagePath.
				dropped += subtreeBytes(p)
				return filepath.SkipDir
			}
			if isPlayDownloadPath(rel) {
				// NWP-20261102-01 (Q076): Play's download cache is never sealed. Priced for the shrink guard so
				// the first seal's drop of what an old head held essential is explained, not refused.
				dropped += subtreeBytes(p)
				return filepath.SkipDir
			}
			if strings.HasPrefix(info.Name(), mediaCacheDirName) {
				// #84 P3d: the media daemon's local cache (fetched deferred files + the .under binds). It is DERIVED
				// state -- every byte is reconstructible from the store -- so sealing it would double the profile
				// (and re-upload GBs), and its .under BINDS would be followed into the real app dirs. Skipped by
				// BASENAME so it's caught wherever it lives (#92 moved it under com.nowhere.chooser/files). Same
				// skip in tarDirTo so both seal paths agree.
				return filepath.SkipDir
			}
			if under, ok := unders[p]; ok && under != p {
				// #84 no-teardown seal: p is a LIVE media-overlay mountpoint. Read its bind-hidden real dir in
				// its place: the dir entry itself (mode/owner for the restore) then every real file inside, at
				// the same rels. Stubs aren't in .under -> absent -> the caller's present-not-deleted carry keeps
				// them. A self-mapped mountpoint (bind missing, mid-sweep race) falls through to the plain walk.
				if ui, uerr := os.Stat(under); uerr == nil {
					visit(under, rel, ui)
				} else {
					visit(p, rel, info)
				}
				filepath.Walk(under, func(up string, uinfo os.FileInfo, uerr error) error {
					if uerr != nil {
						if sealWalkBlind(uerr) {
							blind++ // same rule under a live media overlay: unreadable != vanished
							sealBlindLog(blind, up, uerr)
						}
						return nil
					}
					urel, _ := filepath.Rel(under, up)
					if urel == "." {
						return nil
					}
					if uinfo.Mode().IsRegular() && isMediaTempName(uinfo.Name()) {
						// NWP-20261128-03: the lander and mediafs.go write their temps into an overlay's hidden
						// real dir, which only this nested walk reads. Not user data, so not priced.
						return nil
					}
					// DIA-20260816-17: attribute this entry to the .under substitution. An overlay whose .under is
					// EMPTY is the single most likely explanation for "the data is on screen but the seal saw
					// none of it" -- under==0 while the mountpoint exists says the bind is there and hiding an
					// empty dir, which no other counter distinguishes from a scope that simply has no media.
					st.under++
					visit(up, filepath.Join(rel, urel), uinfo)
					return nil
				})
				return filepath.SkipDir
			}
		}
		if info.Mode().IsRegular() && isMediaTempName(info.Name()) {
			// NWP-20261128-03 (docs/media-after-gate.md §5, last row): a .nwsync-*/.nwseed-* temp a media writer
			// renames into place is never sealed as a user file. Not user data, so not priced.
			return nil
		}
		visit(p, rel, info)
		return nil
	})
	flushGroup()
	// the tar footer (two zero blocks) -- matches tarDirTo's tw.Close(); constant bytes -> one deduped chunk.
	pr, pw := io.Pipe()
	go func() { pw.CloseWithError(writeTarFooter(pw)) }()
	cdcSplit(pr, func(c []byte) { emitSeal(c) })
	st.digest = dg.sum()
	return ranges, seen, deferred, carried, blind, dropped, st, discard
}

// deferredChunksKnown reports whether every chunk of a deferred record is still known-present in the store --
// the same gate the scan cache applies (a GC'd chunk must force a re-chunk, never be re-referenced).
func deferredChunksKnown(d deferredFile) bool {
	if len(d.Chunks) == 0 {
		return false
	}
	for _, h := range d.Chunks {
		if !blobCacheKnown(h) {
			return false
		}
	}
	return true
}

// getIf is get() gated on `use` (false => always a miss, for a forced full re-hash).
func (sc *fileScanCache) getIf(use bool, rel string, mtime, size int64, mode uint32) []string {
	if !use {
		return nil
	}
	return sc.get(rel, mtime, size, mode)
}

// --- tar-region writers. writeTarEntryChecked (writeTarEntry is its wrapper) is the SINGLE source of per-entry tar
// bytes, shared with tarDirTo, so the incremental and legacy paths can never drift. Each region is Flush()ed (pads the entry) but NOT Closed
// (no footer); the footer is one final region, so the regions concatenate to exactly tarDirTo's output. ---

// sealOpenFile is the open writeTarEntry uses for a regular file's bytes. A package variable, not a call, so a
// test can make ONE path's open fail (NWP-20261011-17): chmod 000 does not stop root, which is what the CI runner
// is. Only writeTarEntry reads it.
var sealOpenFile = os.Open

// sealAfterDeferredRead runs in walkChunks' deferred arm once the file's bytes are chunked and before the post-read
// stat that detects a tear. Production never replaces it; only tests do, to grow the file at exactly that point,
// because pushProfile's emitter cannot be injected (NWP-20261024-01).
var sealAfterDeferredRead = func(path string) {}

// writeTarEntry is writeTarEntryChecked without the tear report: the legacy tarDirTo cannot discard an entry once it
// is emitted, so it takes the zero-pad-or-cut behaviour. Grouped entries no longer do (writeGroupedEntry, NWP-20261027-06);
// writeEntriesTar reaches this only for symlinks, non-regular entries and files over groupedReadMax.
func writeTarEntry(tw *tar.Writer, p string, info os.FileInfo, rel string) error {
	_, err := writeTarEntryChecked(tw, p, info, rel)
	return err
}

// sealAfterEssentialCopy runs in writeTarEntryChecked once a regular file's header is written and before its bytes
// are copied. Production never replaces it; only tests do, to change the file at exactly that point
// (NWP-20261024-03). It fires for grouped and legacy entries too, so a hook must filter by path.
var sealAfterEssentialCopy = func(path string) {}

// writeTarEntryChecked is the single source of per-entry tar bytes. torn reports that the file changed between the
// walk stat the header was built from and this copy (see below); the bytes written are the same either way.
func writeTarEntryChecked(tw *tar.Writer, p string, info os.FileInfo, rel string) (torn bool, err error) {
	// NWP-20260821-06 (ticket NW-b8b659735124, root-caused on lynx): SYMLINKS are SKIPPED, not carried.
	// AliExpress's bundled U4 WebView plants absolute hash->hash symlinks in its v8_cache -- the first app
	// data we carry that symlinks inside itself -- and before the lnk_file sepolicy grant the seal walk's
	// lstat was denied { getattr }, counted BLIND, and refused every logoff (35 blind paths). The grant
	// makes the link visible; this skips it.
	//
	// WHY SKIP rather than carry-and-relativize: recreating a symlink at RESTORE time (as root, from the
	// untrusted store) is a tar-slip ROOT-WRITE ESCAPE -- a lexical containment check cannot stop it, because
	// a self/shallow link planted earlier in the same stream makes the linkname resolve inside the root
	// lexically while physically escaping it (an intermediate symlink component is followed; O_NOFOLLOW only
	// guards the leaf). Reachable by any unprivileged roamed app, which controls links in its own package
	// dir. The safe design is to create no symlinks on restore at all -- so we emit none here. What is lost
	// is REGENERABLE: v8_cache is V8 bytecode cache (rebuilt from JS on next run); WebView sign-in state
	// lives in app_webview/ cookies+IndexedDB, which are real files that roam normally. If an app is ever
	// found to need a specific link carried, the correct mechanism is openat2 RESOLVE_IN_ROOT extraction,
	// tracked as its own slice -- NOT a lexical check.
	//
	// NOT counted blind: a skip is a policy decision, blind refuses the whole seal. That distinction is the
	// entire point of the ticket.
	if info.Mode()&os.ModeSymlink != 0 {
		fmt.Fprintf(os.Stderr, "[seal] skip symlink %q (regenerable; symlinks are not roamed -- NWP-20260821-06)\n", rel)
		return false, nil
	}
	hdr, err := tar.FileInfoHeader(info, "")
	if err != nil {
		return false, nil // matches tarDirTo: a bad header skips the entry rather than aborting the seal
	}
	hdr.Name = rel
	normalizeTarOwnership(hdr)
	if !info.Mode().IsRegular() {
		return false, tw.WriteHeader(hdr)
	}
	f, err := sealOpenFile(p)
	if err != nil {
		return false, nil // vanished after the walk -> skip entirely (no header), matches tarDirTo
	}
	defer f.Close()
	if err := tw.WriteHeader(hdr); err != nil {
		return false, err
	}
	sealAfterEssentialCopy(p)
	n, err := io.CopyN(tw, f, hdr.Size)
	if err != nil && err != io.EOF {
		return false, err
	}
	// NWP-20261024-03: report a TORN read -- the file changed between the walk stat the header was built from and
	// this copy. A short copy is one; a post-copy fstat that disagrees with the header's size (growth: the copy was
	// cut at it) or the walk-time mtime (a same-length rewrite) is the other. A same-length rewrite inside one mtime
	// tick shows in neither. The bytes written are unchanged either way; only the file-aligned essential arm acts on
	// it (it can discard its own chunks, a group cannot).
	torn = n < hdr.Size
	if fi, ferr := f.Stat(); ferr == nil && (fi.Size() != hdr.Size || !fi.ModTime().Equal(info.ModTime())) {
		torn = true
	}
	if n < hdr.Size { // shrank mid-seal: zero-pad to the declared size so the tar stays consistent
		_, err = io.CopyN(tw, zeroReader{}, hdr.Size-n)
		return torn, err
	}
	return torn, nil
}

func writeEntryTar(w io.Writer, p string, info os.FileInfo, rel string) error {
	_, err := writeEntryTarChecked(w, p, info, rel)
	return err
}

// writeEntryTarChecked is writeEntryTar that also reports a torn read (NWP-20261024-03).
func writeEntryTarChecked(w io.Writer, p string, info os.FileInfo, rel string) (bool, error) {
	tw := tar.NewWriter(w)
	torn, err := writeTarEntryChecked(tw, p, info, rel)
	if err != nil {
		return torn, err
	}
	return torn, tw.Flush()
}

// sealAfterGroupedRead runs in writeGroupedEntry once a small file's bytes are read into memory and before the
// post-read fstat that detects a tear. Production never replaces it; only tests do, to change the file at exactly
// that point (NWP-20261027-06). It fires once per read, so a hook must filter by path.
var sealAfterGroupedRead = func(path string) {}

// groupedReadMax bounds the memory writeGroupedEntry holds for one file. Grouped files are under the seal threshold
// by construction, so this only matters for a file that grew past it since the walk, or an unusual threshold; such a
// file takes the unchanged writeTarEntry path (NWP-20261027-06).
const groupedReadMax = 8 << 20

func writeEntriesTar(w io.Writer, ents []walkEnt) error {
	_, err := writeEntriesTarChecked(w, ents)
	return err
}

// writeEntriesTarChecked is writeEntriesTar that also reports whether every entry was written from the state the
// walk stat describes (NWP-20261119-01): clean is false when any member changed while it was read, vanished, or
// was skipped. Only a clean group may enter the group cache. The bytes written are the same either way.
func writeEntriesTarChecked(w io.Writer, ents []walkEnt) (clean bool, err error) {
	tw := tar.NewWriter(w)
	clean = true
	for _, e := range ents {
		c, err := writeGroupedEntryChecked(tw, e.path, e.info, e.rel)
		if err != nil {
			return false, err
		}
		clean = clean && c
	}
	return clean, tw.Flush()
}

// writeGroupedEntry writes one entry of a group. A group's chunks span several files, so an entry cannot be discarded
// once emitted; instead a small regular file is read whole into memory, fstat'ed after the read, and -- if it
// changed since the walk -- read once more, and the entry is written from what was last read with a header that
// matches those bytes: never zero-padded, never cut (NWP-20261027-06). An unchanged file produces exactly the bytes
// writeTarEntry does. Symlinks, non-regular entries and files over groupedReadMax take writeTarEntry unchanged.
func writeGroupedEntry(tw *tar.Writer, p string, info os.FileInfo, rel string) error {
	_, err := writeGroupedEntryChecked(tw, p, info, rel)
	return err
}

// writeGroupedEntryChecked is writeGroupedEntry that also reports clean: false when the entry was not written from
// the state the walk stat describes -- it changed while it was read (!whole), its open failed, a fallback
// writeTarEntryChecked reported a tear, or its header could not be built (NWP-20261119-01). A symlink skip and a
// non-regular header are clean: both follow from the stat alone. The bytes written are unchanged.
func writeGroupedEntryChecked(tw *tar.Writer, p string, info os.FileInfo, rel string) (clean bool, err error) {
	fallback := func() (bool, error) {
		torn, err := writeTarEntryChecked(tw, p, info, rel)
		return !torn, err
	}
	if !info.Mode().IsRegular() {
		return fallback()
	}
	if info.Size() > groupedReadMax {
		// The fallback may skip a file it cannot open with no error and no tear; at the seal threshold such a
		// file never joins a group, so this arm is only reached under an unusual threshold.
		return fallback()
	}
	f, err := sealOpenFile(p)
	if err != nil {
		return false, nil // vanished after the walk -> skip entirely (no header), matches writeTarEntry
	}
	defer f.Close()
	sealAfterEssentialCopy(p)
	read := func() (buf []byte, fi os.FileInfo, ok bool, err error) {
		buf, err = io.ReadAll(io.LimitReader(f, groupedReadMax+1))
		if err != nil {
			return nil, nil, false, err
		}
		sealAfterGroupedRead(p)
		fi, err = f.Stat()
		return buf, fi, len(buf) <= groupedReadMax && err == nil, nil
	}
	buf, fi, ok, err := read()
	if err != nil {
		return false, err
	}
	if !ok {
		_, err := writeTarEntryChecked(tw, p, info, rel)
		return false, err
	}
	whole := int64(len(buf)) == info.Size() && fi.Size() == info.Size() && fi.ModTime().Equal(info.ModTime())
	hdrInfo := info
	if !whole {
		fmt.Fprintf(os.Stderr, "[seal] %q changed while it was read -> reading it once more\n", rel)
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			_, err := writeTarEntryChecked(tw, p, info, rel)
			return false, err
		}
		first := fi
		buf, fi, ok, err = read()
		if err != nil {
			return false, err
		}
		if !ok {
			_, err := writeTarEntryChecked(tw, p, info, rel)
			return false, err
		}
		if int64(len(buf)) != fi.Size() || !fi.ModTime().Equal(first.ModTime()) {
			fmt.Fprintf(os.Stderr, "[seal] %q changed while it was read twice -> sealed as last read\n", rel)
		}
		hdrInfo = fi
	}
	hdr, err := tar.FileInfoHeader(hdrInfo, "")
	if err != nil {
		return false, nil // matches writeTarEntry: a bad header skips the entry rather than aborting the seal
	}
	hdr.Name = rel
	normalizeTarOwnership(hdr)
	hdr.Size = int64(len(buf))
	if err := tw.WriteHeader(hdr); err != nil {
		return false, err
	}
	_, err = tw.Write(buf)
	return whole, err
}

// tarEntryFormat is the version of the BYTES writeTarEntry emits for a given file. Bump it whenever this
// function changes the header, so the per-file scan cache -- which keys on (mtime,size,mode) and would
// otherwise hand back chunks sealed under the OLD shape forever -- misses once and re-chunks. Without the
// bump a format change is INERT for every unchanged file, which is the quietest possible way to ship nothing.
//
//	1: ownership normalised out of the header (NWP-20260908-02).
const tarEntryFormat = 1

// normalizeTarOwnership zeroes the OWNER fields of a seal entry, because they are per-device, per-session,
// and never read back.
//
// WHAT THEY COST. tar.FileInfoHeader fills Uid/Gid/Uname/Gname from the local stat, and roamd chowns the
// #media essential tier to `uid*100000+appid` at every login (nowhere_roamd.sh, reown_ext_appdata) -- a value
// that differs between two handsets AND between two logins on one handset. So the same file, byte-identical
// on disk, sealed to DIFFERENT chunks depending on which phone and which session tarred it. That is 11 bytes
// of header deciding a content address.
//
// Two consequences, both live before this. docs/multi-device.md promises "dedup across lineages is automatic:
// identical bytes -> identical chunks -> billed once"; for everything under Android/data|obb that was false,
// and a second handset re-uploaded and re-paid for media it already had. And two handsets could never
// converge on a shared #media head however well the rest of the machinery worked, because they could not
// agree on the CHUNKS -- which is what made this a prerequisite for the essential index (#91) rather than an
// optimisation.
//
// SAFE BECAUSE NOTHING READS IT. untarFrom restores mode and mtime and never chowns (there is no os.Chown on
// the restore path at all); ownership is re-established afterwards by roamd, which computes it from THIS
// device’s user and package ids -- the only correct source, since the sealing device’s ids are meaningless
// here. Carrying them was always dead weight.
//
// It also removes a latent format switch: a uid above 2097151 (user 21 and up) does not fit a ustar octal
// field, so Go would have escalated those entries to PAX -- a different header shape for the same file, on
// the same device, decided by how many times someone had logged in.
//
// ONE-OFF COST: the first seal after this re-chunks the ESSENTIAL set of every scope once, because every
// header changes. Deferred media is untouched -- it is chunked from raw file bytes with no tar header at all.
func normalizeTarOwnership(hdr *tar.Header) {
	hdr.Uid, hdr.Gid = 0, 0
	hdr.Uname, hdr.Gname = "", ""
}

func writeTarFooter(w io.Writer) error {
	return tar.NewWriter(w).Close() // no entries -> just the two zero blocks
}
