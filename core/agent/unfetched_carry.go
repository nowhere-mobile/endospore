package main

// NWP-20261129-03: THE UNFETCHED-PACKAGE CARRY. The 2026-10-26 decision's #2 (docs/product-decisions.md, "a sign-in
// waits only for what must be on the phone when the user lands ...") lets a sign-in skip the CE/DE data of an On-demand
// or Auto app until a tap, and one of its guards is that "the seal carries every unfetched package's sealed data forward
// and never seals an empty copy over it". unfetched_guard.go is the "never an empty copy" half. This file is the carry:
// it re-emits a listed package's stored chunks, by hash, into the bare vault or #de head this seal writes. A span is a
// valid tar fragment (pkg_span.go), so the carried chunks restore as they did before.
//
// Nothing is fetched, decrypted or uploaded. The chunks stay leased by the footprint renewal, which leases every hash a
// head names.
//
// This carry and the #apps / #media carries in pushProfile never run in one seal, because their scopes are disjoint:
// this one runs only for the bare vault and #de, mediaEssentialCarryOn is true only for #media, and carryEssential is
// on only for #apps (roamd pins NOWHERE_CARRY_ESSENTIAL=0 on every other push, conf_flags_scoped_test.go).
//
// Nothing writes the list yet, so the carry is inert until the fetch slice does.

import (
	"fmt"
	"sort"
	"strings"
)

// carryUnfetched re-emits, before the tar footer, each listed package that is not dropped, that the walk recorded no
// data for, and whose stored span pkgSpanChunks trusts. It returns the new chunk list, the carried packages' ranges in
// that list, their stored Pkg figures, and the count of chunks carried. A package the reader refuses is left out, and
// the guard then refuses the seal.
//
// A package gets ONE range, because its chunks go in contiguously and pkgSpanChunks refuses two touching ranges of one
// package: a package stored with two ranges, re-recorded range by range, would be refused at the next seal.
//
// A package with no Pkg figure gets no pkgB entry: attributePkgBytes writes no zero entry either.
func carryUnfetched(oldM chunkManifest, chunks []string, walked map[string]bool, unf, drop map[string]bool) (out []string, spans map[string][][2]int, pkgB map[string]int64, n int) {
	names := make([]string, 0, len(unf))
	for p, listed := range unf {
		if !listed {
			continue
		}
		if dropPkgForFileRel(p+"/x", drop) {
			continue // a deliberate Off is a deletion, not an absence
		}
		if walked[p] {
			continue // the walk's copy wins
		}
		names = append(names, p)
	}
	sort.Strings(names) // deterministic span numbering, so two seals of one state produce one manifest
	out = chunks
	footer := chunks[len(chunks)-1]
	for _, p := range names {
		c, _, ok := pkgSpanChunks(oldM, p)
		if !ok {
			continue
		}
		if spans == nil {
			spans, pkgB = map[string][][2]int{}, map[string]int64{}
			out = chunks[:len(chunks)-1] // a region past the footer is never restored (see the carry in pushProfile)
		}
		start := len(out)
		out = append(out, c...)
		spans[p] = [][2]int{{start, len(out)}}
		if b := oldM.Pkg[p]; b > 0 {
			pkgB[p] = b
		}
		n += len(c)
	}
	if spans != nil {
		out = append(out, footer)
	}
	return out, spans, pkgB, n
}

// sealCarryUnfetched is pushProfile's call: the gate and the log line around carryUnfetched. The gate is the guard's
// scope, a seal with per-file boundaries (under NOWHERE_SEAL_FULL the footer shares a chunk with file bytes and the walk
// records nothing), and a readable, non-empty list. An unreadable list carries nothing: the guard refuses that seal
// as unfetched-unknown.
func sealCarryUnfetched(profile string, oldM chunkManifest, chunks []string, acct *pkgAcct, deferredMap map[string]deferredFile) ([]string, map[string][][2]int, map[string]int64, int) {
	if strings.IndexByte(profile, '#') >= 0 && !strings.HasSuffix(profile, "#de") {
		return chunks, nil, nil, 0
	}
	if !incrementalSeal() || len(chunks) == 0 {
		return chunks, nil, nil, 0
	}
	unf, ok := loadUnfetchedList()
	if !ok || len(unf) == 0 {
		return chunks, nil, nil, 0
	}
	walked := pkgSpanNamed(acct)
	for rel := range deferredMap {
		if p := attrPkgForRel(rel); p != "" {
			walked[p] = true
		}
	}
	out, spans, pkgB, n := carryUnfetched(oldM, chunks, walked, unf, loadDropList())
	fmt.Printf("push: profile %s unfetched carry: %d package(s) carried by span, %d left to the guard (NWP-20261129-03)\n",
		logProfile(profile), len(spans), len(unf)-len(spans))
	return out, spans, pkgB, n
}

// mergeCarried adds src to dst. dst can be nil: a walk that found no package builds no index.
func mergeCarried[V any](dst, src map[string]V) map[string]V {
	if len(src) == 0 {
		return dst
	}
	if dst == nil {
		dst = map[string]V{}
	}
	for k, v := range src {
		dst[k] = v
	}
	return dst
}
