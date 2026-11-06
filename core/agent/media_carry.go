package main

// #91 SLICE 5b, REBUILT: THE PER-REL ESSENTIAL CARRY FOR THE SHARED #media HEAD.
//
// The problem, device-proven on frankel + lynx (NWP-20260907-20) and reproduced off-device in
// media_shared_head_test.go: `#media` is ACCOUNT-shared under both settings of NOWHERE_MULTIDEVICE, so two
// signed-in handsets write one ref, and each republished its own head every cycle forever.
//
// The DEFERRED bulk was never the problem -- the #84 present-not-deleted carry already unions it, which is
// why the union-merge built for this in slice 5a was withdrawn (NWP-20260907-23: it changed nothing and
// resurrected tombstoned deletions). What diverges is the ESSENTIAL set: a whole-tree tar in
// chunkManifest.Chunks with no per-file labels, so no handset could adopt another's essential files without
// holding the bytes. Controlled experiment: two handsets whose essential sets match converge; give each ONE
// small file the other has not materialised and they never converge again.
//
// The fix is the machinery #apps already has (NWP-20260906-16/-17), keyed by REL instead of by package:
// chunkManifest.Ess maps a rel to its span of Chunks, and the seal re-emits a span BY HASH out of the
// manifest it already read -- nothing fetched, nothing decrypted from another lineage, nothing re-uploaded,
// and it stays alive because addCDCChunks leases every hash the head NAMES.
//
// ⚠ WHAT THIS DOES NOT DO: MAKE THE TWO HEADS EQUAL. Measured on the shipped #apps carry, two handsets that
// each hold something the other lacks settle into a permanent 2-CYCLE -- the same head from each, round
// after round, with no data loss. Three causes, and a rel-keyed carry addresses none of them: carried spans
// are appended rather than interleaved in rel order; DIRECTORY entries ride an un-indexed grouped chunk that
// no per-rel index can name; and until NWP-20260908-02 the tar header carried a per-login uid. This slice
// removes the LOSS, not the churn. Say so plainly rather than letting a later reader assume convergence.

import (
	"os"
	"sort"
	"strings"
)

// carryEssentialMedia gates this carry. SEPARATE from NOWHERE_CARRY_ESSENTIAL on purpose: that flag also
// turns on reconcileAppManifest -- which WRITES manifest.tsv into the directory push was handed -- plus the
// Apps index and the Gone tombstones, all keyed on package names. Under a #media seal `src` is
// /data/media/$uid, so reusing the #apps flag would create a user-visible manifest.tsv in the phone's storage
// root and mint an app-tombstone index out of path segments like "DCIM" and "Download".
//
// It shares the ONE-FLAG rule carryEssential documents: it implies threshold 0, because per-file spans are
// meaningless unless every file is chunked file-aligned. Threshold 0 also puts every regular file into the
// walk's `seen` set, which is what lets this carry tell "absent" from "never walked" at all.
func carryEssentialMedia() bool { return os.Getenv("NOWHERE_CARRY_ESSENTIAL_MEDIA") == "1" }

// isSharedMediaScope reports whether the scope being sealed is the account-shared media tree.
//
// ⚠ #apps IS ALSO ACCOUNT-SHARED AND IS DELIBERATELY NOT SERVED HERE. Its cross-lineage problem has its own
// machinery (the 5c index, carry and tombstones), where absence must be distinguished from a deliberate
// uninstall by the drop list and the Gone set. The two selections are not interchangeable.
func isSharedMediaScope(profile string) bool { return strings.HasSuffix(profile, "#media") }

// mediaEssentialCarryOn: the flag AND the scope. A flag alone is not a scope check -- NWP-20260908-01
// was exactly the cost of believing otherwise -- so the vault, #de, #sys and #keys seals are
// structurally unable to reach this carry even if the variable leaks into their environment.
func mediaEssentialCarryOn(profile string) bool {
	return carryEssentialMedia() && isSharedMediaScope(profile)
}

// essIndexOn: who writes chunkManifest.Ess and gets the threshold-0 per-file alignment it requires.
// Deliberately NARROWER than "either flag": the OTHER things carryEssential() gates are #apps semantics
// (the Gone tombstone set, reconcileAppManifest writing manifest.tsv into the tree push was handed, the
// Apps index) and must never fire on /data/media/$uid.
func essIndexOn(profile string) bool { return carryEssential() || mediaEssentialCarryOn(profile) }

// mediaCarryStats is what the seal prints. A carry that silently selects nothing looks exactly like a carry
// that is not wired up -- which is the failure this whole area keeps repeating -- so every decline is
// counted and named.
type mediaCarryStats struct {
	Indexed  int // rels the stored head names
	Restored int // rels the head THIS session restored named
	Walked   int // declined: the walk visited it
	Deferred int // declined: this seal already indexes it as deferred
	Deleted  int // declined: we held it and it is gone -> a real deletion
	Tomb     int // declined: an explicit mediad unlink
	Excluded int // declined: drop list / cache / staging / hold
	BadSpan  int // declined: the stored head cannot back the span
	Unread   int // carried (also in Carried): on this phone, the walk could not read it, the stored span is kept
	Carried  int
}

// carryMediaEssentialRels selects, in deterministic order, the rels this seal must re-emit by hash.
//
// THE RULE THAT MAKES IT SAFE IS THE RESTORE ROSTER, and it is the whole reason this is not the resurrection
// bug of 2026-09-07 wearing a new hat. For DEFERRED media, absence means "not materialised" and a deletion
// needs a mediad tombstone. For ESSENTIAL media the opposite holds: the login restore MATERIALISES every
// essential file, so a file this session restored and no longer has was DELETED by the user, and re-emitting
// it would make photos undeletable. The discriminator is which head each rel came from:
//
//	in the stored head and either restored at login or walked by an earlier seal of THIS session, absent now
//	-> WE HELD IT AND IT IS GONE -> a deletion.
//	in the stored head, in neither, absent now -> another lineage published it since -> CARRY.
//
// A rel the walk VISITED but could not read (walkChunks sets seen[rel] = false: the key is present, the value
// false) is still on this phone, so it is never a deletion whether or not this session restored it: it is
// carried by its stored span and counted in Unread. This relies on that walkChunks convention. A file that
// vanished between the walk's stat and its open keeps its stored span in the head for that one cycle too; the
// post-seal sync never writes such a rel back (carriedToLand), and absent from the next walk it falls to the
// roster arm.
//
// restoredEss must therefore come from a COMPLETE restore. It does: a restore that skipped anything withholds
// its receipt (main.go), and the caller does not run this carry without one -- so a short restore can never
// be read as the user deleting everything it failed to fetch.
func carryMediaEssentialRels(oldEss, restoredEss map[string]essRegion, seen map[string]bool,
	deferred map[string]deferredFile, tomb map[string]bool, drop map[string]bool, oldChunks int,
	walkedHere func(rel string) bool) ([]string, mediaCarryStats) {

	st := mediaCarryStats{Indexed: len(oldEss), Restored: len(restoredEss)}
	rels := make([]string, 0, len(oldEss))
	for rel := range oldEss {
		rels = append(rels, rel)
	}
	sort.Strings(rels) // deterministic span numbering: two seals of one state produce one manifest

	out := rels[:0:0]
	for _, rel := range rels {
		switch {
		case seen[rel]:
			// The walk positively visited it and decided its fate. This is also the duplicate guard: a
			// carried span lands AFTER every walked span, and untarFrom opens each entry O_TRUNC, so a rel in
			// both would restore the STALE copy over the fresh local one -- silently, with skipped==0 and a
			// completion receipt written over the loss.
			st.Walked++
		case hasDeferred(deferred, rel):
			// Already indexed as deferred by this seal. walkChunks clears seen[rel] on a torn or unreadable
			// read precisely so the deferred carry keeps the stored record; without this case that same rel
			// would ALSO get its essential span spliced in -- one file restored twice, billed twice, and
			// served as a mediad stub over bytes the login restore already wrote.
			st.Deferred++
		case tomb[rel]:
			st.Tomb++ // an explicit unlink through the media overlay
		case dropPkgForFileRel(rel, drop):
			st.Excluded++ // a switched-off app: a deliberate exclusion is a deletion, not an absence
		case isMediaCachePath(rel), isAppCodeStagePath(rel), strings.Contains(rel, "/.nowhere-odhold/"):
			// Derived caches, install staging, and the on-demand hold. The hold is NOT optional here the way
			// it reads for #apps: mediaDenyDirs forces hold contents ESSENTIAL, so under a #media Ess index
			// every parked byte of every on-demand app would become a carry candidate -- another handset's
			// parked data, spliced in, undeletable from this device and billed forever (NWP-20260831-08).
			st.Excluded++
		case unreadHere(seen, rel):
			// Visited but unreadable this seal (walkChunks: key present, value false). The file is still here, so
			// the roster below must never see it: a restored file that one seal cannot open is not a deletion.
			// Tombstone, drop and exclusion arms above keep precedence.
			r := oldEss[rel]
			if r.S < 0 || r.E > oldChunks || r.E <= r.S {
				st.BadSpan++ // never re-emit a span the stored head cannot back
				continue
			}
			out = append(out, rel)
			st.Carried++
			st.Unread++
		case (len(restoredEss) > 0 && hasEss(restoredEss, rel)) || (walkedHere != nil && walkedHere(rel)):
			// THE ROSTER, AND IT MUST BE THE LAST ARM. We restored it this session (or an earlier seal of this
			// session walked and published it: a file the user made here and deleted here is ours too) and it is not here now, and
			// every OTHER reason for a rel to be missing has been ruled out above -- so what is left is the user
			// deleting it. Read the arms above as the list of innocent absences (a file present but
			// unread this seal included): this one is sound only because nothing follows it.
			//
			// NWP-20260908-17: it used to sit AHEAD of the two exclusion arms. Both decline the carry either way,
			// so the defect never changed a byte and lived entirely in the COUNT -- which is the opposite of
			// harmless, because `deleted-here` is the number read off a handset to tell a working carry from a
			// broken one, and what it actually printed was "absent for a reason I have not checked yet".
			//
			// It takes a MID-SESSION change to forge one, which is why the shipped fleet has only ever printed 0:
			// the rel has to be in the head we RESTORED (so the exclusion did not apply at login) and excluded by
			// the time we seal. Two events do that, both routine. A tap on an on-demand app -- roamd's odrestore
			// copies the parked tree out of .nowhere-odhold/ and removes the source, so every held rel of every app
			// tapped this session is restored, absent from the walk, and was scored a deletion the user never made.
			// And switching an app Off, which puts it on the drop list the seal SkipDirs.
			//
			// The cache and staging rels in the arm above cannot reach here at all: the walk SkipDirs both, Ess is
			// built only from what the walk emitted, so they were never indexed and are in neither map. That arm
			// guards the OTHER handset's copies, which are absent from restoredEss by definition -- the ordering
			// never shadowed it for the case it exists to serve.
			//
			// Nothing mints from this arm today and this slice adds nothing that does. But the ordering is the
			// precondition for anything ever doing so, and it is not sufficient on its own: this arm is only as
			// good as the walk was COMPLETE, and the caller checks a complete RESTORE receipt, not a complete walk.
			st.Deleted++
		default:
			r := oldEss[rel]
			if r.S < 0 || r.E > oldChunks || r.E <= r.S {
				st.BadSpan++ // never re-emit a span the stored head cannot back
				continue
			}
			out = append(out, rel)
			st.Carried++
		}
	}
	return out, st
}

// unreadHere: the walk visited rel and could not read it (key present, value false).
func unreadHere(seen map[string]bool, rel string) bool { v, ok := seen[rel]; return ok && !v }

// carriedToLand: the carried rels the post-seal sync may write onto this phone -- those whose key is ABSENT from
// seen, that is, the walk never visited them (another handset's file this phone does not hold), in input order. A
// rel the walk visited and could not read (key present, value false) is on the phone or was deleted after the
// walk's stat; either way it is never written back. A nil seen keeps every rel.
func carriedToLand(carried []string, seen map[string]bool) []string {
	out := make([]string, 0, len(carried))
	for _, rel := range carried {
		if _, visited := seen[rel]; !visited {
			out = append(out, rel)
		}
	}
	return out
}

// hasDeferred / hasEss are map membership tests kept as helpers so the switch above reads as a list of
// reasons rather than a list of comma-ok idioms.
func hasDeferred(m map[string]deferredFile, rel string) bool { _, ok := m[rel]; return ok }
func hasEss(m map[string]essRegion, rel string) bool         { _, ok := m[rel]; return ok }
