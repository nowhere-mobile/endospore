package main

// Storage breakdown (DIA-20260804-03): what is actually taking up space in THIS roamed session, per app,
// so the Storage screen can offer a way back under the plan.
//
// TWO NUMBERS PER APP, AND THEY ANSWER DIFFERENT QUESTIONS.
//
//   store (DIA-20260805-12) -- what this app COSTS THE PLAN: sealed, compressed, deduped bytes, read from
//                              the manifest's Pkg index (DIA-20260805-11) plus its Deferred entries
//   bytes (the local walk)  -- what you would FREE on this phone: raw on-disk, before compression
//
// The plan figure is the one users ask for ("how much of my plan is this app using"), and until
// DIA-20260805-11 it could not be computed at all: the essential region is one tar stream chunked by CDC,
// so chunkManifest carried a flat Chunks[]/Sizes[] with no per-file labels. The seal walk now records which
// chunks each package owns, which is the only place file boundaries are known.
//
// The user's own files carry the same two numbers per TOP-LEVEL FOLDER (NWP-20261123-14, h51 #4 A1): Folders has
// one row per directory at the media root (Download, DCIM, ...) and one, named "", for the files outside them. The
// phone figure is the walk's; the store figure is read from the #media head's per-file index (Ess) and its Deferred
// entries, by folder. Before it, the user's whole media folded into one MediaBytes and its plan cost sat inside
// StoreOther, so a store-heavy Download read as "backups".
//
// The two DO NOT reconcile, and the UI must not imply they do. Deleting 3 GB locally drops the billed
// figure by LESS (compression + dedup) and only at the next logoff seal. Nor do the plan rows sum to the
// billed total: refs is keyed by chunk hash, so a chunk shared between packages is billed once but shows in
// both rows, and retained snapshots (#58) are billed while belonging to no row -- which is what StoreOther
// exists to make visible instead of silently swallowing.
//
// WHERE THE BYTES ACTUALLY LIVE. Three non-obvious placements, each of which made an earlier version of
// this file report ~0 bytes for a user's biggest apps:
//
//  1. hold_ondemand (nowhere_roamd.sh) MOVES every kept app's restored CE+DE data out of the canonical
//     /data/user/N/<pkg> into <vol>/com.nowhere.chooser/.nowhere-odhold/<pkg> at login -- for on-demand
//     rows AND kept-installed rows. A never-tapped app keeps its data there for the whole session, and the
//     canonical dir is an empty installd skeleton. Skipping the chooser's dir wholesale therefore hid the
//     data of exactly the apps this screen exists to rank.
//  2. External app data is THREE prefixes, not one: Android/data, Android/media and Android/obb
//     (media_tier.go uses the same three). obb is game expansion data -- routinely the largest single item
//     on a phone that is over its plan.
//  3. The on-demand media FETCH caches (.nowhere-media, .nowhere-media-ext, also under the chooser's dir)
//     are what the "Free up space" button on this very screen reclaims (FREE-MEDIA-CACHE -> roamd
//     freemedia), reported separately -- all but their `.under` dir, which holds REAL files (see below).
//
// FUSE STUBS ARE NOT LOCAL BYTES. mediad mounts on-demand media overlays INSIDE the walked roots and
// answers getattr for never-downloaded files with their full MANIFEST size (mediafs.go). Counting those
// would offer "delete Organic Maps -- 8 GB" for 8 GB that are not on the device. The walk therefore does
// not cross a filesystem boundary (same rule as `du -x`), which excludes every FUSE overlay by
// construction rather than by pattern-matching paths.
//
// A SHORT WALK MUST NOT LOOK LIKE A SMALL NUMBER. nowhere.te records the lesson from the seal's own blind
// walk: a permission gap that silently produced a short manifest sealed nothing for a day. Unreadable
// subtrees are COUNTED (Blind) and reported, so the screen can say the figure is incomplete instead of
// quietly under-reporting and inviting the user to delete something that was not the problem.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// storageApp is one package's cost -- on this phone, and in the plan.
type storageApp struct {
	Pkg   string `json:"pkg"`
	Bytes int64  `json:"bytes"` // CE + DE + held data + external app-data, raw on-disk
	Mode  string `json:"mode"`  // "installed" | "ondemand" | "" (not kept -> not sealed, shown for context)
	// Store is this package's SEALED bytes -- what it costs the roaming plan (DIA-20260805-12), from the
	// manifest's Pkg index plus its own Deferred entries. Zero with StoreMeasured false means the profile has
	// not sealed since the index existed: "not measured yet", NOT "free".
	Store int64 `json:"store,omitempty"`
	// CodeSealed reports whether this package has bytes in #apps, i.e. whether its APK can actually be
	// restored (DIA-20260806-06). The keep-set says what the user WANTS kept; only #apps says what CAN come
	// back, and the two diverge the moment the roam-in reap removes an app whose code was lost. Without this
	// the row promised "comes back installed on your next phone" for an app that cannot -- device-proven on
	// lynx, where Play Services showed 161 MB of plan, no sealed code, and that promise.
	CodeSealed bool `json:"code,omitempty"`
}

// storageFolder is one top-level folder of the media root (NWP-20261123-14), or "" for the files outside every folder.
type storageFolder struct {
	Name  string `json:"name"`
	Bytes int64  `json:"bytes"`           // raw on-disk, this phone; the rows sum to MediaBytes exactly
	Store int64  `json:"store,omitempty"` // sealed bytes in the plan; meaningful only with FoldersMeasured
}

// storageBreakdown is the whole reply.
type storageBreakdown struct {
	Apps       []storageApp `json:"apps"`
	MediaBytes int64        `json:"media_bytes"` // the user's own files: /data/media/<uid> outside Android/, overlaid too
	CacheBytes int64        `json:"cache_bytes"` // fetch caches minus `.under`, a `.part` by its disk: "Free up space"
	TotalBytes int64        `json:"total_bytes"` // apps + media + cache; LOCAL, not the billed footprint
	Blind      int          `json:"blind"`       // paths the walk could not read; >0 means this is an undercount
	// Folders splits MediaBytes by top-level folder (NWP-20261123-14): Bytes desc, then Name; "" is the files outside
	// every folder. MediaBytes stays, so a chooser that does not read Folders still draws its one row.
	Folders []storageFolder `json:"folders,omitempty"`
	// --- the PLAN side (DIA-20260805-12): filled in by the DAEMON, not the walk. The worker has no store
	// access and no passphrase; the daemon holds both, exactly as it does for GET-USAGE. ---
	StoreTotal int64 `json:"store_total,omitempty"` // the billed footprint -- the same number GET-USAGE reports
	// StoreOther is what the plan holds that belongs to NO app row: chunks shared between packages (billed
	// once, so handing them to one app would over-claim), retained snapshots (#58 rollback history), and the
	// profile's own non-app data. It exists so the rows PLUS this line reconcile with StoreTotal instead of
	// silently under-summing it -- a per-app column performs that arithmetic implicitly on every row, and
	// hiding the difference is what would make each row read as "free this much".
	StoreOther int64 `json:"store_other,omitempty"`
	// StoreMeasured separates "measured, and this app costs about nothing" from "never measured". False when
	// no sealed head carries a Pkg index yet: a pre-DIA-20260805-11 profile, or one whose last seal was a
	// full-tar NOWHERE_SEAL_FULL=1 run, which has no file boundaries to attribute.
	StoreMeasured bool `json:"store_measured,omitempty"`
	// AppsMeasured says the #apps scope ITSELF resolved (DIA-20260806-13). StoreMeasured is true as soon as any
	// scope carries a Pkg index, so it cannot distinguish "this app has no sealed code" from "we never read the
	// scope that would say". Gating the UI's missing-code claim on StoreMeasured meant a profile with a sealed
	// vault and no #apps head yet accused EVERY kept app of being unrecoverable.
	AppsMeasured bool `json:"apps_measured,omitempty"`
	// FoldersMeasured is true when the #media head carried its per-file index (EssIdx), so each Folders[].Store is
	// that folder's plan cost. False: the folders' store figures are not measured, and their bytes stay in StoreOther.
	FoldersMeasured bool `json:"folders_measured,omitempty"`
}

// walkState carries the cross-cutting concerns of one breakdown: which device the walk started on (so it
// never descends into a mediad FUSE overlay), which inodes have been counted (so a hard-linked file is not
// counted twice), and how many paths could not be read.
type walkState struct {
	dev   uint64
	seen  map[uint64]bool // inode numbers of multiply-linked files already counted
	blind int
}

// storageWalkFiles counts the files the walk has handed to visit, across the whole of one collectStorageBreakdownAt
// call (NWP-20261118-06). The walk runs in the RO lane, whose stall watchdog (runWorkerHeld, roamStallTicks: 150 s)
// abandons an op whose progress line does not change. The walk wrote none, so a full phone's count was abandoned
// and its finished work thrown away. A plain int: the walk runs in one goroutine of the short-lived worker.
var storageWalkFiles int

// storageWalkBeatEvery is how many files the walk counts between two progress beats.
const storageWalkBeatEvery = 2000

// storageWalkBeat publishes "counting <n>" at $NOWHERE_PROGRESS by temp + rename, as writeProg does, so the watchdog
// sees a new line. It is a no-op when NOWHERE_PROGRESS is unset. The line holds a count only: no name, no path.
func storageWalkBeat(n int) {
	f := os.Getenv("NOWHERE_PROGRESS")
	if f == "" {
		return
	}
	writeAtomic(f+".tmp", f, []byte(fmt.Sprintf("counting %d\n", n)))
}

// dirBytes sums the apparent size of every regular file under dir, staying on dir's own filesystem.
//
// Errors are counted rather than swallowed: an unreadable subtree contributes 0 AND increments blind, so
// the caller can tell the user the number is incomplete. A partial estimate is still better than an error
// dialog on a screen offered to a human -- but silently partial is not.
//
// Symlinks are never followed (WalkDir's DirEntry is lstat-derived and a symlink is not IsRegular), so a
// link into /data/media cannot double-count.
func dirBytes(dir string, st *walkState) int64 {
	var total int64
	walkBytes(dir, st, func(_ string, fi os.FileInfo) { total += fi.Size() })
	return total
}

// walkBytes is dirBytes with a per-file sink: visit gets the path and lstat info of every file dirBytes would
// count, under exactly the same rules, so a caller can attribute a tree file by file (the `.under` binds, below)
// or size a file by the disk it occupies (a sparse `.part`, cacheFileBytes).
func walkBytes(dir string, st *walkState, visit func(p string, fi os.FileInfo)) {
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			if !os.IsNotExist(err) {
				st.blind++ // EACCES/EIO: real bytes we cannot see
			}
			return nil
		}
		fi, e := d.Info()
		if e != nil {
			st.blind++
			return nil
		}
		sys, _ := fi.Sys().(*syscall.Stat_t)
		if d.IsDir() {
			// Do not cross a filesystem boundary: a mediad FUSE overlay mounted inside this tree reports
			// full manifest sizes for files that were never downloaded.
			if sys != nil && p != dir && uint64(sys.Dev) != st.dev {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		if sys != nil {
			if uint64(sys.Dev) != st.dev {
				return nil
			}
			if sys.Nlink > 1 { // hard link: count the bytes once
				if st.seen[uint64(sys.Ino)] {
					return nil
				}
				st.seen[uint64(sys.Ino)] = true
			}
		}
		storageWalkFiles++
		if storageWalkFiles%storageWalkBeatEvery == 0 {
			storageWalkBeat(storageWalkFiles)
		}
		visit(p, fi)
		return nil
	})
}

// newWalkState anchors a walk to root's filesystem. A root we cannot even stat is itself blind.
func newWalkState(root string) *walkState {
	st := &walkState{seen: map[uint64]bool{}}
	fi, err := os.Lstat(root)
	if err != nil {
		st.blind++
		return st
	}
	if sys, ok := fi.Sys().(*syscall.Stat_t); ok {
		st.dev = uint64(sys.Dev)
	}
	return st
}

// chooserPkg is our own package: it is not user data the user can act on, and it is also where roamd parks
// other apps' held data and the media caches -- both of which ARE attributed, below.
const chooserPkg = "com.nowhere.chooser"

// collectStorageBreakdown measures the roamed user's on-disk cost per package.
//
// keep is the chooser's keep-set (pkg -> mode) so the UI can say whether an app is even being sealed; a
// package with data but no keep-set row costs nothing at logoff and must not be presented as a saving.
// Packages are discovered from the DATA DIRS rather than PackageManager: an on-demand app holds data while
// it has no APK installed, and that data is exactly what a user might want to clear.
func collectStorageBreakdown(uid string, keep map[string]string) storageBreakdown {
	return collectStorageBreakdownAt("/", uid, keep)
}

// collectStorageBreakdownAt is the walk with every absolute path it reads placed under root ("/" on the device),
// so a test can lay the device's tree out in a temp dir and run THIS code, not a copy of it.
func collectStorageBreakdownAt(root, uid string, keep map[string]string) storageBreakdown {
	storageWalkFiles = 0 // NWP-20261118-06: the beat counts this walk's files only
	out := storageBreakdown{Apps: []storageApp{}}
	if uid == "" {
		return out
	}
	storageWalkBeat(0)
	perPkg := map[string]int64{}
	folders := map[string]int64{} // top-level media folder -> its bytes; "" = files outside every folder
	userRoot := filepath.Join(root, "data", "user", uid)

	// CE and DE, plus the hold each one carries. The hold is keyed by package, so held bytes land on the
	// app that owns them rather than on the chooser.
	for _, vol := range []string{userRoot, filepath.Join(root, "data", "user_de", uid)} {
		st := newWalkState(vol)
		addPkgDirs(perPkg, vol, st, true)
		addPkgDirs(perPkg, filepath.Join(vol, chooserPkg, ".nowhere-odhold"), st, false)
		out.Blind += st.blind
	}

	// The APP ITSELF (DIA-20260804-07). Without this the screen measured app DATA only and never the code,
	// which on a phone is usually the bigger half: proven on odtest4, where Ring showed "5 MB" and YouTube
	// "18 MB" while both had a ~100-200 MB APK sitting in /data/app. Three things were wrong because of it --
	// the ranking (an app with a small data dir and a huge APK sorted near the bottom of a list whose entire
	// job is ranking), the gap against the billed figure (the #apps scope carries exactly these bytes, so a
	// large slice of what the user pays for was invisible here), and the apparent pointlessness of switching
	// an app off ("Ring, 5 MB" reads as not worth doing, when switching it off stops carrying its whole
	// install).
	//
	// /data/app is not per-user, but on an amnesiac phone it is effectively the roamed session's: bundled
	// apps live in /system, and anything installed in a session is wiped with it. Layout is
	// /data/app/~~<rand>/<pkg>-<rand>/base.apk, so the owning package is the entry name up to the FIRST '-'
	// -- unambiguous because an Android package name is dot-separated Java identifiers and can never contain
	// a hyphen, while the random suffix routinely does.
	appRoot := filepath.Join(root, "data", "app")
	appEnts, appErr := os.ReadDir(appRoot)
	if appErr != nil && !os.IsNotExist(appErr) {
		// Unreadable /data/app means EVERY app's code is missing from the total, which is the single largest
		// omission this walk can have. Counting it keeps the promise the rest of the function makes: a short
		// walk is reported as short, never as a complete small number. Without this the screen would state a
		// confident total that silently excluded every APK -- exactly the failure mode the Blind counter and
		// the seal's own sealBlind rule exist to prevent.
		out.Blind++
	}
	if len(appEnts) > 0 {
		ents := appEnts
		ast := newWalkState(appRoot)
		for _, outer := range ents {
			if !outer.IsDir() {
				continue
			}
			inner, err := os.ReadDir(filepath.Join(appRoot, outer.Name()))
			if err != nil {
				if !os.IsNotExist(err) {
					ast.blind++
				}
				continue
			}
			for _, e := range inner {
				if !e.IsDir() {
					continue
				}
				pkg := e.Name()
				if i := strings.IndexByte(pkg, '-'); i > 0 {
					pkg = pkg[:i]
				}
				if pkg == "" || pkg == chooserPkg {
					continue
				}
				perPkg[pkg] += dirBytes(filepath.Join(appRoot, outer.Name(), e.Name()), ast)
			}
		}
		out.Blind += ast.blind
	}

	// External app data: all three prefixes, not just Android/data.
	mediaRoot := filepath.Join(root, "data", "media", uid)
	mst := newWalkState(mediaRoot)
	for _, pfx := range []string{"data", "media", "obb"} {
		// DIA-20260816-19: data/obb now carry an EXTERNAL hold under the chooser's own dir (roamd's
		// hold_ondemand parks each on-demand app's external app-data there at login, so the login-time
		// `pm uninstall` cannot delete it). Skip the chooser on those two and add the hold explicitly, exactly
		// as the CE/DE loop above does -- otherwise every held byte bills to com.nowhere.chooser, which for an
		// on-demand app is most of the profile (88 MB for one game) and would put the biggest row on the wrong
		// app. Android/media has no hold and no chooser dir, so it keeps counting everything.
		skipChooser := pfx == "data" || pfx == "obb"
		addPkgDirs(perPkg, filepath.Join(mediaRoot, "Android", pfx), mst, skipChooser)
		if skipChooser {
			addPkgDirs(perPkg, filepath.Join(mediaRoot, "Android", pfx, chooserPkg, odHoldDirName), mst, false)
		}
	}

	// The user's own files: everything at the media root except Android/ (already attributed above).
	// Top-level FILES count too -- a stray 4 GB video sitting in the root is exactly what someone over
	// their plan needs to see. A directory is a folder row by its own name; anything else goes to the
	// files-outside-folders row ("").
	if ents, err := os.ReadDir(mediaRoot); err == nil {
		for _, e := range ents {
			if e.Name() == "Android" {
				continue
			}
			name := ""
			if e.IsDir() {
				name = e.Name()
			}
			addFolderBytes(folders, &out.MediaBytes, name, dirBytes(filepath.Join(mediaRoot, e.Name()), mst))
		}
	} else if !os.IsNotExist(err) {
		mst.blind++
	}

	// The on-demand media fetch caches -- reported separately because the "Free up space" button reclaims
	// these, so the user can see that button's effect reflected here.
	//
	// EXCEPT `.under` (NWP-20261016-49). mediad binds every dir it overlays to <cache>/.under/<underLeaf(rel)>
	// and mounts its FUSE overlay over the real path (serveMediaScope), so what sits under `.under` is the
	// user's REAL files in those dirs: pinned and prefetched media, app write-backs, the real contents of an
	// overlaid Download or DCIM. A bind keeps /data's st_dev, so the walk descends into it, and it is the ONLY
	// place the walk sees those files -- at the real path the overlay is another filesystem, which every walk
	// above skips. Summed into CacheBytes they were offered as "re-downloads when you open it again" under a
	// Clear that never frees them. So each is counted where its real path belongs (underOwner): the app's row,
	// or MediaBytes and its folder (underFolder). The same files are counted once each, so TotalBytes is
	// unchanged. And a partly fetched `.part` counts by the disk it holds, not the whole file its holes stand for
	// (cacheFileBytes).
	for _, c := range []struct {
		dir      string
		external bool // the #media scope's cache (rels under /data/media/<uid>); else the CE vault's (/data/user/<uid>)
	}{
		{filepath.Join(userRoot, chooserPkg, "files", ".nowhere-media"), false},
		{filepath.Join(userRoot, chooserPkg, "files", ".nowhere-media-ext"), true},
	} {
		out.CacheBytes += cacheBytesExceptUnder(c.dir, mst)
		addUnderBytes(perPkg, folders, &out.MediaBytes, filepath.Join(c.dir, ".under"), c.external, mst)
	}
	out.Blind += mst.blind

	for pkg, b := range perPkg {
		out.Apps = append(out.Apps, storageApp{Pkg: pkg, Bytes: b, Mode: keep[pkg]})
		out.TotalBytes += b
	}
	// Largest first (ties by name so a refresh does not reshuffle the many 0-byte rows that hold_ondemand
	// leaves behind as empty installd skeletons): the screen exists to answer "what do I delete", which is
	// a ranking question.
	sort.Slice(out.Apps, func(i, j int) bool {
		if out.Apps[i].Bytes != out.Apps[j].Bytes {
			return out.Apps[i].Bytes > out.Apps[j].Bytes
		}
		return out.Apps[i].Pkg < out.Apps[j].Pkg
	})
	out.TotalBytes += out.MediaBytes + out.CacheBytes
	out.Folders = foldersFromMap(folders)
	return out
}

// addFolderBytes adds n bytes of the user's own files to MediaBytes and to the top-level folder they sit in. It is the
// only writer of both, so the folder rows always sum to MediaBytes.
func addFolderBytes(folders map[string]int64, media *int64, name string, n int64) {
	*media += n
	folders[name] += n
}

// foldersFromMap turns the walk's folder map into the reply's rows, dropping an empty folder.
func foldersFromMap(folders map[string]int64) []storageFolder {
	var out []storageFolder
	for name, n := range folders {
		if n != 0 {
			out = append(out, storageFolder{Name: name, Bytes: n})
		}
	}
	sortFolders(out)
	return out
}

// sortFolders orders the folder rows as the app rows are ordered: largest on this phone first, then by name, so a
// refresh does not reshuffle them.
func sortFolders(fs []storageFolder) {
	sort.Slice(fs, func(i, j int) bool {
		if fs[i].Bytes != fs[j].Bytes {
			return fs[i].Bytes > fs[j].Bytes
		}
		return fs[i].Name < fs[j].Name
	})
}

// underFolder names the folder row of a user file reached through a `.under` bind: the first component of its rel
// when the cache is the external one (rels under /data/media/<uid>, the walk's own root), the leaf was readable and
// the rel has a '/'. Every other case is "": a CE-cache rel (not under the media root), a top-level file, a hashed
// leaf. An external rel under Android/ the user owns (the chooser's own data outside its holds) is "" too: the walk
// never makes an Android folder, and the store side leaves Android/ out of every folder.
func underFolder(external, ok bool, rel string) string {
	if !external || !ok || strings.HasPrefix(rel, "Android/") {
		return ""
	}
	if i := strings.IndexByte(rel, '/'); i > 0 {
		return rel[:i]
	}
	return ""
}

// addPkgDirs adds each package-named subdirectory of base into perPkg. skipChooser drops our own package
// (true for the CE/DE roots, where it is a real package dir; false for the hold and the external roots,
// whose entries are all other apps' packages).
func addPkgDirs(perPkg map[string]int64, base string, st *walkState, skipChooser bool) {
	ents, err := os.ReadDir(base)
	if err != nil {
		if !os.IsNotExist(err) {
			st.blind++ // the root itself is unreadable -> every app under it is missing from the total
		}
		return
	}
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		pkg := e.Name()
		if strings.HasPrefix(pkg, ".") || (skipChooser && pkg == chooserPkg) {
			continue
		}
		perPkg[pkg] += dirBytes(filepath.Join(base, pkg), st)
	}
}

// cacheBytesExceptUnder sums one media fetch cache dir by dirBytes' rules, leaving out its `.under` subdir: the
// complete entries "Free up space" deletes, plus what it keeps (the scope's `.deleted`, `.fetch-*` temps, and each
// partly fetched file's `.part`/`.have` pair), every file sized by cacheFileBytes.
func cacheBytesExceptUnder(dir string, st *walkState) int64 {
	ents, err := os.ReadDir(dir)
	if err != nil {
		if !os.IsNotExist(err) {
			st.blind++
		}
		return 0
	}
	var total int64
	for _, e := range ents {
		if e.Name() == ".under" {
			continue
		}
		walkBytes(filepath.Join(dir, e.Name()), st, func(_ string, fi os.FileInfo) { total += cacheFileBytes(fi) })
	}
	return total
}

// cacheFileBytes is what one fetch cache file takes on this phone. A range fetch's `<key>.part` is SPARSE: initPart
// truncates it to the whole file's size and ensureRange fills it chunk by chunk, so its apparent size is the whole
// file while the disk holds only the chunks fetched. A read of fewer than prefetchTriggerChunks chunks neither
// promotes nor prefetches the file -- OrganicMaps' startup header read of every map leaves one such `.part` per map
// -- mediad's eviction skips every `.part`, and Clear keeps them all. Sized by fi.Size(), those holes read as
// gigabytes "held on this phone" before Clear and again after it (NWP-20261016-49). So a `.part` counts by its
// allocated blocks, never more than its apparent size; every other file counts by its apparent size, as dirBytes
// does, so a complete entry reads the figure freemedia's `stat -c %s` reports when Clear deletes it.
func cacheFileBytes(fi os.FileInfo) int64 {
	n := fi.Size()
	if !strings.HasSuffix(fi.Name(), ".part") {
		return n
	}
	if sys, ok := fi.Sys().(*syscall.Stat_t); ok {
		if a := int64(sys.Blocks) * 512; a < n {
			return a
		}
	}
	return n
}

// addUnderBytes counts the real files under one media cache's `.under` dir where their real paths belong. Each
// entry is the bind of one overlaid dir, named underLeaf(rel); underRel reads the rel back, and each file goes to
// underOwner(external, <rel>/<its path inside the bind>). A leaf underRel cannot read (the hashed form, for a rel
// too long to escape) goes to MediaBytes: its owner is unknown, but its bytes are real and stay in the total. A file
// the user owns goes to MediaBytes and to its folder row (underFolder).
func addUnderBytes(perPkg, folders map[string]int64, media *int64, under string, external bool, st *walkState) {
	ents, err := os.ReadDir(under)
	if err != nil {
		if !os.IsNotExist(err) {
			st.blind++
		}
		return
	}
	for _, e := range ents {
		leafDir := filepath.Join(under, e.Name())
		rel, ok := underRel(e.Name())
		walkBytes(leafDir, st, func(p string, fi os.FileInfo) {
			n := fi.Size()
			owner := ""
			full := ""
			if in, err := filepath.Rel(leafDir, p); ok && err == nil {
				full = path.Join(rel, filepath.ToSlash(in))
				owner = underOwner(external, full)
			}
			if owner == "" {
				addFolderBytes(folders, media, underFolder(external, full != "", full), n)
				return
			}
			perPkg[owner] += n
		})
	}
}

// underOwner names who owns a real file reached through a `.under` bind, by the rule the walk above applies to
// the same file at its real path: an app's package, or "" for the user's own files (MediaBytes). rel is relative
// to the scope root -- /data/media/<uid> for the external (#media) cache, /data/user/<uid> for the CE vault's --
// and attrPkgForRel, the seal's own attribution, reads both layouts: Android/{data,media,obb}/<pkg>/..., the
// chooser's external and CE holds, and a CE <pkg>/.... Its CE rule is "a dotted first component", which on the
// media root is only a folder name ("Movies.2024"), so an external rel outside Android/ is always the user's.
//
// The chooser's own CE, Android/data and Android/obb data outside its holds gets no row, as at its real path,
// where the walk above skips those three chooser dirs (skipChooser) and adds only the holds. Its Android/media
// dir, which it does not write, counts whole on a chooser row, here as at its real path, where the walk counts
// Android/media whole. On the CE layout attrPkgForRel already names no package for the chooser (its CE rule
// excludes chooserPkg); on the external one its generic Android/<data|obb>/<pkg> rule names the chooser, so that
// answer is dropped here. Such a file, like a rel no rule names (a dot dir), counts as the user's, so it stays in
// the total.
func underOwner(external bool, rel string) string {
	if external && !strings.HasPrefix(rel, "Android/") {
		return ""
	}
	pkg := attrPkgForRel(rel)
	if pkg == chooserPkg && (strings.HasPrefix(rel, "Android/data/") || strings.HasPrefix(rel, "Android/obb/")) {
		return ""
	}
	if !strings.HasPrefix(pkg, ".") {
		return pkg
	}
	return ""
}

// handleGetStorageBreakdown backs the GET-STORAGE-BREAKDOWN verb. Reply is length-prefixed JSON
// ("OK <nbytes>\n<json>"), the same shape as GET-CATALOG, so the chooser reads it with the existing
// daemonLenReply helper rather than a new protocol.
//
// PURELY LOCAL: no store round-trip, no gateway, no passphrase. That is what makes it safe to run while a
// materialise holds the session lock -- see the concurrentSafeCmd entry.
//
// The walk itself runs in the roamd WORKER (endospore_priv), not here: this domain cannot read the roamed
// user's data dirs at all -- see the `storagebreakdown` CLI case in main.go for why, including the MCS
// category constraint that no type rule would have fixed. Doing it here would have produced a screenful of
// zeroes with no error, since dirBytes treats an unreadable tree as empty.
//
// The deadline is extended because the worker does a full recursive stat of the user's data, and the phone
// that asks is by definition the one with the most of it. Expiring mid-walk would turn a slow screen into
// a BLANK one. ⚠ The chooser's daemonLenReply uses a 30s socket timeout, SHORTER than this -- the Storage
// screen must raise its own timeout for this verb or it will give up before the daemon answers.
//
// NWP-20261118-06 (h48 #6): the count itself is the session's shared count (storage_count.go). This handler joins
// a running one or starts one, and waits for it. The count runs on its own goroutine, so a count this handler
// started still lands in the kept copy after the 120 s deadline has cut this connection. The reply is unchanged,
// byte for byte.
func handleGetStorageBreakdown(conn net.Conn, dest string) {
	name, _, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n") // nobody signed in
		return
	}
	conn.SetDeadline(time.Now().Add(120 * time.Second)) // full recursive stat of a large /data/user tree
	j, started := startStorageCount(dest)
	if !started && storageCountJoinedHook != nil {
		storageCountJoinedHook()
	}
	<-j.done
	out := j.out
	// The count's result is the merged JSON object; anything else is one of the worker's ERR-* tokens (or NONE).
	if !strings.HasPrefix(out, "{") {
		fmt.Fprintf(conn, "%s\n", out)
		return
	}
	fmt.Fprintf(conn, "OK %d\n", len(out))
	fmt.Fprint(conn, out)
}

// withStoreBytes decorates the worker's JSON with per-package SEALED bytes, the billed total, and the
// unattributable remainder. Returns the input untouched on any error, so this can only add information.
// rowsForRowlessPackages appends a row for every store-attributed package that the LOCAL walk did not find.
//
// Kept separate from withStoreBytes so it is testable: withStoreBytes needs a real store to reach this point
// (storePkgBytes reports measured=false in a unit test), so the invariant would otherwise be asserted only
// against a copy of the logic rather than the logic.
func rowsForRowlessPackages(apps []storageApp, per map[string]int64, code map[string]bool) []storageApp {
	seen := make(map[string]bool, len(apps))
	for i := range apps {
		seen[apps[i].Pkg] = true
	}
	// Deterministic order: map iteration is randomised, and a screen whose rows reshuffle between reads reads
	// as instability to the user even when every number is identical.
	var add []string
	for pkg, v := range per {
		if v > 0 && !seen[pkg] {
			add = append(add, pkg)
		}
	}
	sort.Strings(add)
	for _, pkg := range add {
		apps = append(apps, storageApp{Pkg: pkg, Store: per[pkg], CodeSealed: code[pkg]})
	}
	return apps
}

func withStoreBytes(workerJSON, name, pass string, se []byte) (string, error) {
	if pass == "" {
		return workerJSON, fmt.Errorf("no session key")
	}
	var b storageBreakdown
	if err := json.Unmarshal([]byte(workerJSON), &b); err != nil {
		return workerJSON, err
	}
	per, code, measured, appsMeasured := storePkgBytesOf("s3", name, pass, se)
	// NWP-20261123-14: the folders are measured on their own, from the #media head's per-file index. A profile whose
	// heads carry no Pkg index (only the user's own files are sealed, so storePkgBytes leaves every key to a folder)
	// still gets its folder rows; only when NEITHER side is measured is the reply the pure local walk.
	fstore, foldersMeasured := storeFolderBytesOf("s3", name, pass, se)
	if !measured && !foldersMeasured {
		return workerJSON, nil // nothing sealed with an index yet: leave the reply as the pure local walk
	}
	b.AppsMeasured = appsMeasured
	var attributed int64
	for i := range b.Apps {
		if v, ok := per[b.Apps[i].Pkg]; ok {
			b.Apps[i].Store = v
		}
		b.Apps[i].CodeSealed = code[b.Apps[i].Pkg]
	}
	// NWP-20260826-02: give a package with NO LOCAL ROW a row of its own, instead of leaving its bytes
	// nowhere at all.
	//
	// b.Apps comes from the LOCAL walk, so the loop above can only attribute store bytes to packages that
	// still have data on this device. A package that is sealed but locally absent -- an #apps-only orphan
	// (its APK rides in #apps with no data dir), or an on-demand app whose hold was released -- appeared in
	// NEITHER place: it has no row, and because `attributed` below counts it, it is subtracted out of
	// StoreOther too. So the screen displayed
	//
	//     sum(rows) + StoreOther  ==  StoreTotal - (bytes of every package with no local row)
	//
	// and those bytes were simply missing from the accounting, on the one screen whose job is to explain
	// where the plan went. Worse, they were UNACTIONABLE: the chooser's "Stop carrying" chip is driven off a
	// row, so with no row there is nothing to press -- the same dead end Chester hit with tesla, reached by a
	// different route and with no visible number to even start from.
	//
	// Bytes stays 0 (there genuinely is nothing on this device) which is exactly what the UI's "0 B on this
	// phone" case already renders; Store carries the plan cost, which is the number the user is paying.
	b.Apps = rowsForRowlessPackages(b.Apps, per, code)
	// Every attributed package counts toward the remainder, including ones with no local row (an app whose
	// data is sealed but currently absent from this device still occupies the plan).
	for _, v := range per {
		attributed += v
	}
	// NWP-20261123-14: the user's own files by top-level folder, read from the #media head's per-file index. The
	// folder total counts toward `attributed` as the apps do, so StoreOther stays the remainder and the plan column
	// adds up: apps + folders + StoreOther == StoreTotal (before the clamp below). storePkgBytes leaves these bytes
	// off every app row, so none is counted twice. Not measured (no index): the folders get no store figure and
	// their bytes stay in StoreOther, as before.
	if foldersMeasured {
		b.Folders = withFolderStore(b.Folders, fstore)
		for _, v := range fstore {
			attributed += v
		}
		b.FoldersMeasured = true
	}
	// ⚠ StoreMeasured IS NOT THIS QUESTION, and conflating the two was a mistake I nearly shipped. Its
	// documented meaning is that a sealed head carries a Pkg INDEX -- about attribution -- and the
	// !measured early return above already keeps it honest. What was NOT honest is StoreTotal: on a
	// hardened vault the footprint could only see head refs, so "the plan cost, which is the number the
	// user is paying" came out as a few kilobytes.
	//
	// So take the same exit the function already takes when it cannot attribute: serve the pure local
	// walk. The screen then shows no store numbers rather than wrong ones, which is a shape it already
	// renders and the UI already handles.
	fp, fpMeasured := footprintOf("s3", name, pass, se)
	if !fpMeasured {
		return workerJSON, nil
	}
	// StoreMeasured keeps its meaning: a head carried a Pkg index. With the folders alone measured it stays false, so
	// the app rows still read "not measured yet" and the chooser draws no remainder row; StoreOther is then the plan
	// minus the folders, so the column still adds up.
	b.StoreMeasured = measured
	for _, sz := range fp {
		b.StoreTotal += sz
	}
	if b.StoreOther = b.StoreTotal - attributed; b.StoreOther < 0 {
		// Attribution can exceed the billed total legitimately: refs is keyed by chunk HASH, so a chunk shared
		// between two packages is billed once but shows in both rows. Clamp rather than render a negative
		// "other" -- the rows are then known to over-sum, which the UI says in words instead of arithmetic.
		b.StoreOther = 0
	}
	out, err := json.Marshal(b)
	if err != nil {
		return workerJSON, err
	}
	return string(out), nil
}

// storePkgBytes reads per-package SEALED bytes out of the sealed heads: the Pkg index for the essential
// region (DIA-20260805-11) plus each scope's own Deferred entries, which have carried per-path sizes since
// #84 and cover on-demand APK code and bulk media.
//
// measured reports whether ANY scope carried a Pkg index. A profile that has not sealed since the index
// existed reports no per-app plan figures at all rather than a table of zeros.
//
// #keys is skipped deliberately: it stages <pkg>.keys blobs of a few kilobytes, so attributing them would
// add rows that round to nothing while implying keystore material is a storage cost worth acting on.
// appsMeasured (DIA-20260806-13) is returned SEPARATELY from measured, and the distinction is the whole point.
// `measured` goes true as soon as ANY scope carries a Pkg index -- the vault alone does it. `code` is only ever
// populated under #apps. So a profile that has sealed its vault/#de/#media but has no #apps head yet reports
// measured=true with an EMPTY code map, and every kept row then renders "its app files are missing -- it won't
// come back". That is not an edge case: the connected lynx is in exactly that state, and so is every profile in
// the window between its first data seal and its first code seal.
//
// Any "this app has no sealed code" claim must therefore be gated on appsMeasured, never on measured.
func storePkgBytes(base, profile, pass string, se []byte) (per map[string]int64, code map[string]bool, measured, appsMeasured bool) {
	per, code = map[string]int64{}, map[string]bool{}
	for _, scope := range []string{profile, profile + "#de", profile + "#media", profile + "#apps"} {
		m, ok := scopeManifest(base, scope, pass, se)
		if !ok {
			continue
		}
		if strings.HasSuffix(scope, "#apps") {
			// Recorded on RESOLUTION, before looking at contents: an #apps head that legitimately carries no
			// packages is still a measurement ("nothing has sealed code"), and that is a different fact from
			// "we could not read #apps at all". The old code collapsed the two into an identical answer.
			appsMeasured = true
		}
		// DIA-20260806-06: does this package have sealed CODE, i.e. bytes in #apps? That is the difference
		// between "comes back installed on your next phone" and a promise we cannot keep. The keep-set says
		// what the user WANTS kept; only #apps says what can actually be restored, and the two diverge the
		// moment the roam-in reap removes an app whose code was lost (device-proven on lynx: Play Services,
		// 161 MB of plan, no sealed code, and the screen still promised it would come back).
		isApps := strings.HasSuffix(scope, "#apps")
		// NWP-20261123-14: on #media a user folder is a folder row, never an app row. attrPkgForRel reads "a dotted
		// first component" as a CE package, so a folder named "Movies.2024" was billed to a bogus app
		// "Movies.2024", from its Pkg key and from every Deferred entry under it. withStoreBytes prices the
		// folders from this same head (mediaFolderStore), so both are skipped here.
		isMedia := strings.HasSuffix(scope, "#media")
		var folderKeys map[string]bool
		if isMedia {
			folderKeys = mediaFolderKeys(m)
		}
		for pkg, bytes := range m.Pkg {
			if folderKeys[pkg] {
				continue
			}
			if pkg != "" && bytes > 0 {
				per[pkg] += bytes
				measured = true
				if isApps {
					code[pkg] = true
				}
			}
		}
		for rel, d := range m.Deferred {
			if isMedia && isMediaFolderRel(rel) {
				continue
			}
			pkg := attrPkgForRel(rel)
			if pkg == "" {
				continue
			}
			for _, z := range d.Sz {
				per[pkg] += z
			}
			if isApps {
				code[pkg] = true // an on-demand app's APK rides #apps as a DEFERRED entry, not an essential one
			}
		}
	}
	return per, code, measured, appsMeasured
}

// mediaFolderOf names the folder row of a #media rel (relative to /data/media/<uid>, as the walk's folders are): its
// first component, or "" for a rel with no '/', a file outside every folder.
func mediaFolderOf(rel string) string {
	if i := strings.IndexByte(rel, '/'); i >= 0 {
		return rel[:i]
	}
	return ""
}

// isMediaFolderRel reports whether a #media rel is the user's own file, i.e. not under Android/, whose app data the
// app rows already price.
func isMediaFolderRel(rel string) bool {
	return !strings.HasPrefix(rel, "Android/")
}

// mediaFolderKeys is the set of named folders a #media manifest prices by folder: the first component of every
// non-Android Ess and Deferred rel ("" is not a package name and is left out). storePkgBytes skips a Pkg key in it.
func mediaFolderKeys(m chunkManifest) map[string]bool {
	keys := map[string]bool{}
	add := func(rel string) {
		if isMediaFolderRel(rel) {
			if f := mediaFolderOf(rel); f != "" {
				keys[f] = true
			}
		}
	}
	for rel := range m.Ess {
		add(rel)
	}
	for rel := range m.Deferred {
		add(rel)
	}
	return keys
}

// mediaFolderStore prices the user's files by top-level folder from a #media head alone: an essential file's sealed
// bytes are the Sizes of its span of Chunks (Ess, per-file aligned under the carry, so the spans are disjoint), and a
// deferred file's are its own Sz. It is measured only when the seal built the per-file index (EssIdx) and Sizes is
// parallel to Chunks. One span out of range makes the whole answer not measured, so a corrupt index is never
// half-read. An Android/ rel counts in no folder.
func mediaFolderStore(m chunkManifest) (map[string]int64, bool) {
	if !m.EssIdx || len(m.Sizes) != len(m.Chunks) {
		return nil, false
	}
	out := map[string]int64{}
	for rel, r := range m.Ess {
		if r.S < 0 || r.E > len(m.Chunks) || r.S > r.E {
			return nil, false
		}
		if !isMediaFolderRel(rel) {
			continue
		}
		f := mediaFolderOf(rel)
		for _, z := range m.Sizes[r.S:r.E] {
			out[f] += z
		}
	}
	for rel, d := range m.Deferred {
		if !isMediaFolderRel(rel) {
			continue
		}
		f := mediaFolderOf(rel)
		for _, z := range d.Sz {
			out[f] += z
		}
	}
	return out, true
}

// storeFolderBytes is the per-folder sealed bytes of the profile's #media head (storeFolderBytesOf's default). It reads
// the #media head a second time after storePkgBytes, which this screen can afford.
func storeFolderBytes(base, profile, pass string, se []byte) (map[string]int64, bool) {
	m, ok := scopeManifest(base, profile+"#media", pass, se)
	if !ok {
		return nil, false
	}
	return mediaFolderStore(m)
}

// withFolderStore sets each folder row's plan cost and, as rowsForRowlessPackages does for apps, gives a folder the
// store holds and this phone does not a row of its own (Bytes 0), so its plan cost is never on no row at all.
func withFolderStore(fs []storageFolder, store map[string]int64) []storageFolder {
	seen := make(map[string]bool, len(fs))
	for i := range fs {
		fs[i].Store = store[fs[i].Name]
		seen[fs[i].Name] = true
	}
	for name, v := range store {
		if v > 0 && !seen[name] {
			fs = append(fs, storageFolder{Name: name, Store: v})
		}
	}
	out := fs[:0]
	for _, f := range fs {
		if f.Bytes != 0 || f.Store != 0 {
			out = append(out, f)
		}
	}
	sortFolders(out)
	return out
}

// scopeManifest opens one sealed scope's LIVE manifest, mirroring scopeFootprint's head -> vault -> DK path.
// Snapshot history is deliberately NOT read: those chunks are billed but belong to no app row, so they are
// part of the remainder rather than any package's cost.
// ⚠ se: NWP-20260915-15. This is scopeFootprint's twin and it was blind in the same way -- on a
// hardened vault it returned ok=false, so every per-app row on the Storage screen read as zero and
// the screen could not say which packages the plan was actually going on.
func scopeManifest(base, scope, pass string, se []byte) (m chunkManifest, ok bool) {
	defer func() {
		if recover() != nil {
			m, ok = chunkManifest{}, false
		}
	}()
	head := getRef(base, headKey(base, scope, pass))
	if head == "" {
		return chunkManifest{}, false
	}
	hblob := getHeadBlob(base, head)
	if v, isV := parseVault(hblob); isV {
		dk := openVaultDKSE(v, scope, pass, se)
		if dk == nil || v.Manifest == "" {
			return chunkManifest{}, false
		}
		// NWP-20261011-26 (#117, the read side): classify, do not collapse. loadCDCManifest answers an empty
		// manifest for a missing blob, a decrypt failure and corrupt JSON alike, so this returned ok=true with
		// no chunks and the Storage screen, the seal-delta cache and the per-app rows all under-reported as if
		// the scope were empty. Every caller already reads !ok as "not measured", which is the honest answer.
		lm, st := classifyManifestLoad(base, dk, v.Manifest)
		switch st {
		case mlOK:
			return lm, true
		case mlNotCDC:
			return chunkManifest{}, true // a legacy pre-CDC head: readable, it just carries no chunk list
		case mlUnreadable:
			fmt.Fprintf(os.Stderr, "[agent] storage: %s manifest exists but could not be read -- not measured (#117)\n", logProfile(scope))
		}
		return chunkManifest{}, false // mlUnreadable, and mlAbsent, which v.Manifest != "" above rules out
	}
	// LEGACY BARE HEAD: the head blob IS the sealed manifest (pre-vault shape), so unseal it with the
	// scope's own key -- the same fallback scopeFootprint has always had.
	//
	// DIA-20260806-03: bailing here was a silent, systematic UNDERCOUNT. createVault is called ONLY for the
	// bare profile name (main.go), so the base CE scope is the one and only vault -- #de, #media, #apps and
	// #keys are ALL legacy bare heads. Returning false for them meant the plan column read exactly one of
	// the four scopes it claims to price. Device-proven on lynx: Play Services showed "under 1 MB of your
	// plan" against 88 MB on the phone, because its data sits in the DE hold
	// (com.nowhere.chooser/.nowhere-odhold/<pkg>, where roamd parks every kept app's data at login) -- i.e.
	// in #de, which was never read. App CODE in #apps and offline media in #media were invisible for the
	// same reason. The walk-side attribution was correct all along; nothing downstream could see it.
	return parseBareHeadManifest(unseal(deriveKey(scope, pass), hblob))
}

// parseBareHeadManifest reads a legacy bare head's plaintext: cdcMagic followed by the manifest JSON. Split
// out from scopeManifest so the regression is testable without standing up a store.
func parseBareHeadManifest(pt []byte) (m chunkManifest, ok bool) {
	if !bytes.HasPrefix(pt, cdcMagic) {
		return chunkManifest{}, false
	}
	if json.Unmarshal(pt[len(cdcMagic):], &m) != nil {
		return chunkManifest{}, false
	}
	return m, true
}

// readKeepModes parses the chooser's keep-set (files/nowhere-appkeep) into pkg -> mode. The file is the
// single source of truth for what gets SEALED: "<pkg>" alone means installed, "<pkg>\tondemand" means the
// on-demand tier, and a package absent from it is not carried at all. Missing/unreadable file -> empty map,
// which renders every app as not-kept -- the conservative direction, since it never invites the user to
// drop something expecting a saving that would not materialise.
func readKeepModes(uid string) map[string]string {
	b, err := os.ReadFile("/data/user/" + uid + "/" + chooserPkg + "/files/nowhere-appkeep")
	if err != nil {
		return map[string]string{}
	}
	return parseKeepModes(b)
}

// parseKeepModes is the parsing half, split out so the test exercises THIS code rather than a copy of it
// (a test that re-implements the parser cannot catch a bug in the parser). The mode is field 1 specifically:
// a group row carries a third field (readAppGroups in ProfileActivity.java reads f[2] as "group:<name>"),
// so a reader that split once and took "the rest" would produce a mode of "ondemand\tgroup:..." -- matching
// neither mode, and rendering an on-demand app as though it were not kept at all.
func parseKeepModes(b []byte) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		mode := "installed"
		if len(f) > 1 && f[1] != "" {
			mode = f[1]
		}
		out[f[0]] = mode
	}
	return out
}
