package main

// NWP-20261127-01: THE PER-PACKAGE SPAN INDEX of a bare vault or #de head (chunkManifest.PkgSpan, wire key "pspan").
//
// The 2026-10-26 decision's #2 (docs/product-decisions.md, "a sign-in waits only for what must be on the phone when
// the user lands ...") lets a sign-in skip the CE/DE data of an On-demand or Auto app until a tap, and requires the
// next seal to carry that app's stored data forward byte for byte. Pkg (bytes per package) cannot carry anything: a
// carry needs the chunks that hold one package's data and nothing else. This file builds that index from the walk's
// pkgAcct and reads it back.
//
// Why a span is exact: the essential stream is one logical tar. Each group starts its own cdcSplit and ends at a
// header boundary, and a file-aligned large file's region holds only its own header and data. So the chunks of one
// package's groups and large files, concatenated in order, are a valid tar stream of exactly that package's entries.
// groupUnit makes a held package (com.nowhere.chooser/.nowhere-odhold/<pkg>) its own unit, so held packages, the
// set the carry exists for, get spans too.
//
// ~~Nothing reads the index yet. The fetch slice carries an unfetched package by these spans;~~ (Superseded by
// NWP-20261129-03: the seal's carryUnfetched reads it, unfetched_carry.go.) A package the reader refuses is fetched at
// sign-in as today.

import (
	"sort"
	"strings"
)

// spanMixed is the owner a mixed group's chunks are claimed for. It is not a package name (a NUL never appears in
// one), so it never reaches the output; a package that meets it on a chunk is left out.
const spanMixed = "\x00mixed"

// spanPkgOfUnit is the package a group unit names: <pkg> at the scope root (a unit with a dot that is not the
// chooser), or the <pkg> of a hold unit com.nowhere.chooser/.nowhere-odhold/<pkg>. Every other unit ("", the chooser,
// Android, a dotless folder) names no package and its groups give no span.
func spanPkgOfUnit(unit string) string {
	if hp := chooserPkg + "/" + odHoldDirName + "/"; strings.HasPrefix(unit, hp) {
		p := unit[len(hp):]
		if p == "" || strings.IndexByte(p, '/') >= 0 {
			return ""
		}
		return p
	}
	if strings.IndexByte(unit, '/') >= 0 || unit == chooserPkg || !strings.Contains(unit, ".") {
		return ""
	}
	return unit
}

// pkgSpanNamed is every package the walk recorded data for: an owner of a single chunk, a package a group's weights
// name, or the package a group's unit names, mixed groups included. pushProfile logs len(named) - len(spans) as the
// count left out, so a package whose data sits only in a mixed group counts as left out.
func pkgSpanNamed(a *pkgAcct) map[string]bool {
	named := map[string]bool{}
	if a == nil {
		return named
	}
	for _, p := range a.single {
		if p != "" {
			named[p] = true
		}
	}
	for _, g := range a.groups {
		for p := range g.weights {
			if p != "" && p != chooserPkg { // the chooser is never a span package
				named[p] = true
			}
		}
		if p := spanPkgOfUnit(g.unit); p != "" {
			named[p] = true
		}
	}
	return named
}

// buildPkgSpans turns the walk's chunk ownership into, per package, the sorted half-open [s,e) ranges of ESSENTIAL
// chunk indices (indices into Chunks, translated from emit indices by essIdx) that hold only that package's data:
// its single chunks plus every chunk of a non-mixed group its unit names.
//
// A package is LEFT OUT, never given a partial span, when any of its chunks is claimed by another package, when a
// mixed group holds any of its data (by the group's unit or its weights), when any of its emit indices is deferred (essIdx -1) or out of range, or when an essential index is
// outside [0,nChunks). A partial span would carry a package with a hole in it. Returns nil when no package is left.
func buildPkgSpans(a *pkgAcct, essIdx []int, nChunks int) map[string][][2]int {
	if a == nil {
		return nil
	}
	owner := map[int]string{}
	idx := map[string][]int{}
	bad := map[string]bool{}
	claim := func(emit int, pkg string) {
		if emit < 0 || emit >= len(essIdx) {
			bad[pkg] = true
			return
		}
		k := essIdx[emit]
		if k < 0 || k >= nChunks {
			bad[pkg] = true
			return
		}
		if o, ok := owner[k]; ok && o != pkg {
			bad[o], bad[pkg] = true, true
			return
		}
		if _, ok := owner[k]; !ok {
			owner[k] = pkg
			idx[pkg] = append(idx[pkg], k)
		}
	}
	for i, p := range a.single {
		if p != "" {
			claim(i, p)
		}
	}
	for _, g := range a.groups {
		p := spanPkgOfUnit(g.unit)
		switch {
		case g.mixed:
			// Every package the mixed group holds data of is left out WHOLE, not only this group's chunks: its other
			// groups and single chunks would otherwise give it an accepted span with this group missing. The group
			// holds at most one unit (a new unit flushes it), so its unit and its weights name every such package;
			// the unit covers a group whose package entries are directories only.
			if up := spanPkgOfUnit(g.unit); up != "" {
				bad[up] = true
			}
			for w := range g.weights {
				bad[w] = true
			}
			p = spanMixed
		case p == "":
			continue
		}
		for w := range g.weights {
			if p != spanMixed && w != p {
				bad[p] = true // a named group weighed for another package: not this package's data alone
			}
		}
		for i := g.start; i < g.end; i++ {
			claim(i, p)
		}
	}
	spans := map[string][][2]int{}
	for p, ks := range idx {
		if p == spanMixed || bad[p] {
			continue
		}
		sort.Ints(ks)
		var rs [][2]int
		for _, k := range ks {
			if n := len(rs); n > 0 && rs[n-1][1] == k {
				rs[n-1][1] = k + 1
				continue
			}
			rs = append(rs, [2]int{k, k + 1})
		}
		spans[p] = rs
	}
	if len(spans) == 0 {
		return nil
	}
	return spans
}

// pkgSpanChunks is the reader: the chunk hashes (and their sealed sizes, when the head has Sizes) of pkg's span, in
// order. ok is true only for a span the carry can trust:
//
//   - m.PkgSpan names pkg with at least one range;
//   - every range has 0 <= s < e <= len(m.Chunks);
//   - the ranges are strictly ascending and neither touch nor overlap (the builder merges a touching pair, so a
//     touching pair is a span this agent did not write);
//   - no other package's range overlaps any of them;
//   - Sizes is empty or parallel to Chunks;
//   - no m.Deferred rel files under pkg: a deferred file's bytes are not in Chunks, so the span would not hold all
//     of the package.
//
// ~~No caller yet: the fetch slice carries an unfetched package by these spans.~~ (Superseded by NWP-20261129-03:
// carryUnfetched is the caller.) A package the reader refuses is fetched at sign-in as today.
func pkgSpanChunks(m chunkManifest, pkg string) (chunks []string, sizes []int64, ok bool) {
	rs := m.PkgSpan[pkg]
	if len(rs) == 0 {
		return nil, nil, false
	}
	for i, r := range rs {
		if r[0] < 0 || r[0] >= r[1] || r[1] > len(m.Chunks) {
			return nil, nil, false
		}
		if i > 0 && r[0] <= rs[i-1][1] {
			return nil, nil, false
		}
	}
	for other, ors := range m.PkgSpan {
		if other == pkg {
			continue
		}
		for _, o := range ors {
			for _, r := range rs {
				if o[0] < r[1] && r[0] < o[1] {
					return nil, nil, false
				}
			}
		}
	}
	if len(m.Sizes) != 0 && len(m.Sizes) != len(m.Chunks) {
		return nil, nil, false
	}
	for rel := range m.Deferred {
		if attrPkgForRel(rel) == pkg {
			return nil, nil, false
		}
	}
	for _, r := range rs {
		chunks = append(chunks, m.Chunks[r[0]:r[1]]...)
		if len(m.Sizes) != 0 {
			sizes = append(sizes, m.Sizes[r[0]:r[1]]...)
		}
	}
	return chunks, sizes, true
}
