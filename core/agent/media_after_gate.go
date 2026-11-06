package main

// NWP-20261123-07: WHICH PART OF AN ESSENTIAL #media RESTORE CAN WAIT UNTIL AFTER THE GATE (Q106, slice S1).
//
// The backlog row "A 179-second login, 95% of it bulk media restored INLINE before the gate opens" is a sign-in
// that streams every small photo, song and download through the login untar before the gate opens. Q106
// (docs/product-decisions.md, 2026-10-20) decided that user media restores after the gate; the mechanism is
// docs/media-after-gate.md, its six questions DECIDED 2026-11-02. This file holds that design's slices S1 and S2:
// the pure split of a head into what still restores before the gate and what can land afterwards (bgSplit, S1), and
// the one place the #media restore decides to stream only the pre-gate part (mediaRestorePlan, S2,
// NWP-20261125-03).
//
// mediaRestorePlan is bgSplit's one caller, from the #media restore in main.go, behind NOWHERE_MEDIA_AFTER_GATE.
// No daemon exports that flag, so no device restores anything differently.
//
// NWP-20261128-03 (slice S3, §5): the seal's side of a split. aftergateActive reads the marker, loadLandedRoster
// reads what the lander placed (pushProfile reads it once, before its walk), and unlandedBackground names the background rels the seal must carry by span and
// leave to the lander. isMediaTempName is the one test the three walks use to skip a lander or seed temp. ⚠ S4a-S5
// must land before any daemon exports the flag: without the lander no background file ever lands.

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

// mediaAfterGateOn is NOWHERE_MEDIA_AFTER_GATE, on only when it is exactly "1". "true", "0" and unset are all
// off. ⚠ The flag is not in nowhere.conf.example: S5 exports it, and TestEveryDocumentedConfFlagIsExportedByADaemon
// refuses a documented flag that no daemon exports.
func mediaAfterGateOn() bool { return os.Getenv("NOWHERE_MEDIA_AFTER_GATE") == "1" }

// aftergateFile maps a store ref to the AFTER-GATE MARKER (docs/media-after-gate.md §5 item 1): the head a #media
// restore split, so the background files of that head had not all landed when the gate opened. It has the login
// roster's shape and lifetime (loginRosterFile): the restore-receipts directory in RAM state, parked by roamd at
// every sign-in, gone at power-off. "" when receipts are off or ref is empty.
func aftergateFile(ref string) string {
	d := restoreReceiptDir()
	if d == "" || ref == "" {
		return ""
	}
	return filepath.Join(d, "aftergate."+ref)
}

// aftergateActive is the seal's reading of the marker (NWP-20261128-03, §5 item 3 and its fail-direction table):
// true when aftergate.<ref> names rosterHead, the head this session's roster says it restored, and true when the
// marker exists but cannot be read. A marker read as absent would send every unlanded background rel to the
// carry's roster arm, which drops it as a user deletion; so only "absent" (fs.ErrNotExist) reads as absent.
//
// False when rosterHead is "" (no roster: aftergateMarkerPresent covers that case), when receipts are off, when the
// marker is absent, and when it is readable and names another head (an earlier sign-in's split, not this one).
func aftergateActive(ref, rosterHead string) bool {
	f := aftergateFile(ref)
	if rosterHead == "" || f == "" {
		return false
	}
	b, err := os.ReadFile(f)
	if errors.Is(err, fs.ErrNotExist) {
		return false
	}
	if err != nil {
		return true // the marker exists and cannot be read: read as present (§5), never as absent
	}
	return strings.TrimSpace(string(b)) == rosterHead
}

// aftergateMarkerPresent is true when aftergate.<ref> exists in any form: a file, a directory, or a path whose
// stat fails for any reason except "absent". It does not read the content. False when receipts are off.
//
// The seal asks it only when the login roster is missing. finishRestore writes the #72 receipt before the roster,
// so a failed roster write after a split leaves a marker and no roster; the carry then declines on its rh == ""
// arm, and a seal from the walk alone would drop every background file not landed yet. A marker with no roster
// is therefore a split, and the seal refuses rather than publish.
func aftergateMarkerPresent(ref string) bool {
	f := aftergateFile(ref)
	if f == "" {
		return false
	}
	_, err := os.Lstat(f)
	return !errors.Is(err, fs.ErrNotExist)
}

// landedRosterFile maps a store ref to the LANDED ROSTER (§5 item 2): a keyed digest per background rel the lander
// has placed, in the walked roster's shape (walkedDigest, one per line), never a name. Its writer is the lander
// (slice S4a); this slice only reads it. "" when receipts are off or ref is empty.
func landedRosterFile(ref string) string {
	d := restoreReceiptDir()
	if d == "" || ref == "" {
		return ""
	}
	return filepath.Join(d, "landed."+ref)
}

// loadLandedRoster returns a predicate over the landed roster. An absent or unreadable file answers false for every
// rel: nothing landed, so every background rel is carried by its span. That is the keep direction (§5): a landed
// file the user deleted comes back once, and nothing is lost.
func loadLandedRoster(ref string, dk []byte) func(rel string) bool {
	set := readWalkedDigests(landedRosterFile(ref))
	return func(rel string) bool { return set[walkedDigest(dk, rel)] }
}

// unlandedBackground is the set of bgSplit(restoredM)'s background rels that landed does not hold. A nil landed
// reads as nothing landed. These rels are not on the phone because the lander has not placed them yet, not because
// the user deleted them: the seal takes them out of the carry's restored set, so they fall to its default arm and
// are carried by span, and out of the post-seal sync's list, because the lander owns them.
func unlandedBackground(restoredM chunkManifest, landed func(rel string) bool) map[string]bool {
	bg, _ := bgSplit(restoredM)
	out := map[string]bool{}
	for _, rel := range bg {
		if landed == nil || !landed(rel) {
			out[rel] = true
		}
	}
	return out
}

// essWithout returns a fresh copy of ess without every rel in drop. It never aliases ess.
func essWithout(ess map[string]essRegion, drop map[string]bool) map[string]essRegion {
	out := make(map[string]essRegion, len(ess))
	for rel, r := range ess {
		if !drop[rel] {
			out[rel] = r
		}
	}
	return out
}

// relsWithout returns a fresh slice of rels without every rel in drop, in the same order. It never aliases rels.
func relsWithout(rels []string, drop map[string]bool) []string {
	out := make([]string, 0, len(rels))
	for _, rel := range rels {
		if !drop[rel] {
			out = append(out, rel)
		}
	}
	return out
}

// isMediaTempName is true for the base name of a temp a media writer renames into place: ".nwsync-*"
// (media_span.go, writeMaterialized, which the lander shares) and ".nwseed-*" (mediafs.go). The three seal walks
// skip such a regular file and do not price it: a temp is not user data, and sealed it would restore as a stray
// file beside the real one (§5's last row).
func isMediaTempName(name string) bool {
	return strings.HasPrefix(name, ".nwsync-") || strings.HasPrefix(name, ".nwseed-")
}

// mediaRestorePlan is the manifest the login restore streams: the one place the Q106 split is decided.
//
// It returns m UNCHANGED (the same value: nothing written, nothing printed) unless NOWHERE_MEDIA_AFTER_GATE is on
// AND the scope is #media. Under the flag it returns a copy of m whose Chunks is bgSplit's pre-gate list, every
// other field unchanged. The caller keeps the FULL m for everything after the restore: the receipt and the roster
// name the head, and the pre-gate pass's skipped count is what earns them.
//
// ⚠ THE SPLIT IS NEVER ON WITHOUT ITS MARKER (§5 item 1). aftergate.<ref> is published BEFORE this returns, so
// before cdcRestore streams a chunk and before finishRestore writes the roster. A marker that cannot be written
// (receipts off included) returns m unchanged, and the whole set restores inline, as today.
func mediaRestorePlan(profile, pass, restoredHead string, m chunkManifest) chunkManifest {
	if !mediaAfterGateOn() || !isSharedMediaScope(profile) {
		return m
	}
	f := aftergateFile(profileRefV2(profile, pass)) // the roster's key (finishRestore)
	// Drop a marker an earlier sign-in of this boot left. The error is ignored on purpose: on the split arm the
	// publish below replaces the file by rename, and on the empty-split arm a marker that survives names either an
	// older head (S3 compares it with the roster head, so it does not match) or this head, whose split is also
	// empty. Neither drops a file.
	if f != "" {
		_ = os.Remove(f)
	}
	bg, pre := bgSplit(m)
	if len(bg) == 0 {
		return m // no per-file index, or nothing in Q106's list: the share line already says which
	}
	if f == "" || publishReceiptFile(f, []byte(restoredHead)) != nil {
		fmt.Println("restore: #media split -- the after-gate marker could not be written, so the whole set restores inline (NWP-20261125-03)")
		return m
	}
	var size int64
	for _, rel := range bg {
		size += m.Ess[rel].Size
	}
	// Counts only: no profile name, no path, no rel.
	fmt.Printf("restore: #media split -- pre-gate %d chunks / background %d files, %d bytes (NWP-20261125-03)\n",
		len(pre), len(bg), size)
	out := m
	out.Chunks = pre // a fresh slice from bgSplit: never aliases m.Chunks
	return out
}

// bgSplit splits a #media head into the rels the background restore lands after the gate (bg, sorted) and the
// chunk list the login restore still streams before it (preGate, in head order).
//
// THE RULE is docs/media-after-gate.md §2. A rel of m.Ess goes to bg only when ALL of these hold:
//   - isUserMediaRel(rel): Q106's list, the same classifier the share line uses (media_user_share.go);
//   - !mediaDeferForbidden(rel): a .db, .so, keystore, /databases/ or /il2cpp/ file in a user folder still
//     restores first;
//   - its basename is not ".nomedia": MediaProvider scans the volume when the user starts, and a folder whose
//     .nomedia had not landed would be indexed into every gallery;
//   - its region is valid against the head, 0 <= S < E <= len(m.Chunks) (the carry's own bad-span test,
//     media_carry.go);
//   - its region shares no chunk index with any other valid region (below).
//
// Everything else stays pre-gate: every directory (directories ride the grouped chunks no region covers),
// app-private data, folders outside Q106's list, deny-listed files, .nomedia, and the tar trailer.
//
// THE SPLIT IS BY INDEX, NOT BY HASH (§3). Two files with equal bytes have equal chunk hashes at different
// indices, and only one of them may be in bg; removing by hash would cut the other out of the pre-gate tar.
// Under the Ess flags every region is a self-contained tar fragment (TestEssSpan_IsASelfContainedTarFragment),
// so m.Chunks with whole bg regions removed is still one valid tar of the remaining entries, and cdcRestore can
// stream it unchanged.
//
// ⚠ THE SPLIT IS COMPUTED AT RESTORE TIME AND NEVER STORED. It is a function of the head and the rule, so a
// head written before this code, or by a handset without it, splits the same way; nothing new goes in the seal.
//
// ⚠ m.Deferred IS NOT READ AND NOT CHANGED. Q106 moves what is restored inline; the deferred tier (files at or
// above the size floor) stays on-demand or prefetched by its Offline media tier, served by mediad as today.
//
// A head with no index (!m.EssIdx, or an empty m.Ess) gives an empty bg and a copy of m.Chunks: there are no
// per-file spans to split, so the whole set restores inline, as today. That includes an old head that holds a
// non-empty Ess without EssIdx; the conservative side, and the next seal writes EssIdx.
//
// The overlap arm is defence only. Two bg regions that share an index, or a bg region that shares one with a
// region that stays pre-gate, would corrupt the pre-gate tar: removing the shared chunk cuts bytes out of the
// other region's entry. Such a rel stays pre-gate. A bad span counts as a pre-gate region over every in-head index
// between its ends, as its ownership is unknown. The walk writes one region per file at threshold 0, so a real head
// never takes this arm.
//
// Pure: it never fetches, never logs and never aliases m.Chunks.
func bgSplit(m chunkManifest) (bg []string, preGate []string) {
	if !m.EssIdx || len(m.Ess) == 0 {
		return nil, slices.Clone(m.Chunks)
	}
	n := len(m.Chunks)
	valid := func(r essRegion) bool { return r.S >= 0 && r.S < r.E && r.E <= n }

	// cover[i] counts the regions that may hold chunk i, of every rel, bg-shaped or not. A bad span stays pre-gate,
	// but which chunks it owns is unknown, so it counts over every in-head index between its ends: a bg region next
	// to [1,4) in a three-chunk head must not give up chunk 1 or 2 (RF-001).
	cover := make([]int, n)
	for _, r := range m.Ess {
		lo, hi := max(min(r.S, r.E), 0), min(max(r.S, r.E), n)
		for i := lo; i < hi; i++ {
			cover[i]++
		}
	}

	drop := make([]bool, n)
	for rel, r := range m.Ess {
		if !isUserMediaRel(rel) || mediaDeferForbidden(rel) || path.Base(rel) == ".nomedia" || !valid(r) {
			continue
		}
		exclusive := true
		for i := r.S; i < r.E; i++ {
			if cover[i] != 1 {
				exclusive = false // defence only: an overlapping region stays pre-gate (see above)
				break
			}
		}
		if !exclusive {
			continue
		}
		bg = append(bg, rel)
		for i := r.S; i < r.E; i++ {
			drop[i] = true
		}
	}
	slices.Sort(bg)

	preGate = make([]string, 0, n)
	for i, h := range m.Chunks {
		if !drop[i] {
			preGate = append(preGate, h)
		}
	}
	return bg, preGate
}
