package main

import "os"

// NWP-20261124-06: the unfetched-package seal guard. The 2026-10-26 decision (docs/product-decisions.md, #2) lets
// a sign-in skip the CE/DE data of an On-demand or Auto app until its first tap. One of its guards is that "the
// seal carries every unfetched package's sealed data forward, never drops it and never seals an empty copy over
// it". This file is the "never seals an empty copy over it" half.
//
// ~~The carry half is NOT here, because the vault and #de heads cannot express it today: chunkManifest.Ess is
// written only under NOWHERE_CARRY_ESSENTIAL=1, which roamd pins to 0 on every non-#apps push, and the small-file
// tail is grouped across packages, so no per-package chunk span exists to carry.~~ (Superseded by NWP-20261127-01,
// the span index, and NWP-20261129-03, the carry: unfetched_carry.go. This guard still refuses what that carry leaves
// out.) What those heads DO carry is Pkg, the sealed bytes per package (built through attrPkgForRel, which files the
// on-demand hold under the held package). Pkg cannot carry bytes, but it can see a package's data vanish -- the same use the #apps presence
// guard makes of it. ~~The carry, with the span index it needs, belongs to the fetch slice.~~ (Superseded as above.)
//
// ~~Nothing writes the list yet, so the guard is inert until the fetch slice does.~~ (Superseded by NWP-20261130-03:
// the sign-in's vault restore writes unfetched.ce and its #de restore unfetched.de, and each push names its own scope's
// file, unfetched_fetch.go.)

// loadUnfetchedList reads NOWHERE_UNFETCHED_LIST: the packages whose data this session has not fetched, one per
// line. Blank lines and '#' lines are ignored, and a name that fails validPkgName is ignored.
//
// It returns (nil, true) when the variable is unset or empty: there is no list, the guard is off, and the seal
// behaves as before. It returns (nil, false) when the file cannot be read: the caller cannot tell which packages
// are unfetched, which is never the same as "none".
func loadUnfetchedList() (map[string]bool, bool) {
	p := os.Getenv("NOWHERE_UNFETCHED_LIST")
	if p == "" {
		return nil, true
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, false
	}
	return parseUnfetched(b), true // NWP-20261130-03: the line rule is shared with the fetch's list writer
}

// unfetchedDropped counts the listed packages that the stored head carries and this seal does not. A package is
// carried when its Pkg entry is > 0 or a deferred rel files under it. A package the drop list removes is not
// counted: a deliberate Off is a deletion, not an absence.
//
// The deferred rels go through attrPkgForRel, never pkgPresenceSet: pkgPresenceSet takes the first path segment,
// so it files com.nowhere.chooser/.nowhere-odhold/<pkg>/... under the chooser, and a held package would never be
// seen as carried.
func unfetchedDropped(oldPkg map[string]int64, oldDeferred []string, newPkg map[string]int64, newDeferred []string, unfetched, drop map[string]bool) int {
	wasDef, nowDef := unfetchedDeferredPkgs(oldDeferred), unfetchedDeferredPkgs(newDeferred)
	n := 0
	for p, listed := range unfetched {
		if !listed || dropPkgForFileRel(p+"/x", drop) {
			continue
		}
		was := oldPkg[p] > 0 || wasDef[p]
		have := newPkg[p] > 0 || nowDef[p]
		if was && !have {
			n++
		}
	}
	return n
}

func unfetchedDeferredPkgs(rels []string) map[string]bool {
	m := map[string]bool{}
	for _, rel := range rels {
		if p := attrPkgForRel(rel); p != "" {
			m[p] = true
		}
	}
	return m
}

// unfetchedNotCarried (NWP-20261130-03) counts the listed packages that the stored head carries (Pkg > 0) and this seal
// does not carry BY THEIR STORED SPAN (carried, the carry's ranges). unfetchedDropped admits any copy of a package; this
// one does not: while a package is listed its data has not come back, so any other copy of it -- the walk's, of files an
// app wrote on fresh data before its fetch -- would replace the stored data, however small it is. A package the drop
// list removes is not counted.
func unfetchedNotCarried(oldPkg map[string]int64, carried map[string][][2]int, unfetched, drop map[string]bool) int {
	n := 0
	for p, listed := range unfetched {
		if !listed || dropPkgForFileRel(p+"/x", drop) {
			continue
		}
		if _, ok := carried[p]; oldPkg[p] > 0 && !ok {
			n++
		}
	}
	return n
}
