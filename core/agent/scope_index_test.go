package main

import (
	"strings"
	"testing"
)

// TestScopeIndexRoundTrips is the base property: what deriveScopeIndex produces, sealScopeIndex renders and
// openScopeIndex returns intact -- including the scope KEY, which is the half a recovery cannot re-derive.
func TestScopeIndexRoundTrips(t *testing.T) {
	dk := randBytes(32)
	const name, pass = "idxround", "horse battery staple correct"
	idx := deriveScopeIndex(name, pass, dk)

	// NWP-20260917-04: +1 for the RESERVED scopeBillKey entry, which is not a scope -- it records the
	// profile's own billing key so a recovery can name the plan it is moving off.
	if len(idx) != len(scopeIndexSuffixes)+1 {
		t.Fatalf("index has %d entries, want %d (one per scope, derived not observed, plus the billing record)",
			len(idx), len(scopeIndexSuffixes)+1)
	}
	got, ok := openScopeIndex(dk, sealScopeIndex(dk, idx))
	if !ok {
		t.Fatal("a sealed index does not re-open under the same DK")
	}
	for _, suf := range scopeIndexSuffixes {
		want := idx[suf]
		if got[suf].Ref != want.Ref {
			t.Errorf("%s: ref %q != %q", suf, got[suf].Ref, want.Ref)
		}
		// ⚠ A DK-SEALED HEAD RECORDS NO KEY, AND THIS LOOP USED TO DEMAND ONE. #wallet is not a
		// scope-keyed manifest: it is a blob sealed under the profile DK, so deriveKey(name#wallet, pass)
		// opens nothing there -- it is the ref-derivation secret, a second copy of the ADDRESS, recorded in
		// a field labelled "the key" (NWP-20260915-17).
		if scopeSealedUnderDK(suf) {
			if got[suf].Wrapped != "" {
				t.Errorf("%s: recorded a key (%q) for a head that is sealed under the profile DK -- the "+
					"field says \"the key that opens it\" and that value opens nothing", suf, got[suf].Wrapped)
			}
			continue
		}
		key, kok := unwrap(kekScopes(dk), got[suf].Wrapped)
		if !kok {
			t.Fatalf("%s: the scope key does not unwrap under kekScopes(dk)", suf)
		}
		// THE LOAD-BEARING ASSERTION: the recorded key must be the key the scope's data is actually sealed
		// under, or a re-pointed head would be openable and its manifest would still be gibberish.
		//
		// ⚠ IT IS WEAKER THAN IT READS, and the #wallet case is what exposed that: it compares the
		// recorded value against the SAME derivation the minter used, so it holds for whatever the minter
		// happens to write and can only catch a minter that wraps something else entirely. What it cannot
		// see is a suffix whose data is not sealed under a scope key at all -- which is why that case is
		// now asserted above rather than left to this comparison.
		if want := deriveKey(name+suf, pass); string(key) != string(want) {
			t.Errorf("%s: recorded key != deriveKey(name%s, pass)", suf, suf)
		}
	}
}

// TestScopeIndexRecordsTheWriteRefNotTheReadRef pins the choice that is easy to get wrong and silent when
// wrong. headKey returns the LEGACY ref while a legacy head exists; putHeadSingle tombstones legacy on the
// scope's next seal. An index built on headKey would therefore record, on a legacy profile, a ref that the
// same seal cycle kills -- and recovery would later read a tombstone.
func TestScopeIndexRecordsTheWriteRefNotTheReadRef(t *testing.T) {
	dk := randBytes(32)
	const name, pass = "idxwrite", "horse battery staple correct"
	idx := deriveScopeIndex(name, pass, dk)
	for _, suf := range scopeIndexSuffixes {
		want, _ := headWriteRef(name+suf, pass)
		if idx[suf].Ref != want {
			t.Errorf("%s: recorded %q, want headWriteRef %q", suf, idx[suf].Ref, want)
		}
	}
}

// TestScopeIndexIsSealedNotPlaintext: a vault head blob is plaintext JSON the store holds, so an unsealed
// index would hand a store operator a profile -> objects graph they cannot otherwise build. Neither the refs
// nor the keys may appear in the rendered field.
func TestScopeIndexIsSealedNotPlaintext(t *testing.T) {
	dk := randBytes(32)
	const name, pass = "idxseal", "horse battery staple correct"
	idx := deriveScopeIndex(name, pass, dk)
	sealed := sealScopeIndex(dk, idx)
	for _, suf := range scopeIndexSuffixes {
		if strings.Contains(sealed, idx[suf].Ref) {
			t.Errorf("%s: the scope ref appears VERBATIM in the sealed index -- it is not sealed", suf)
		}
		// ⚠ A DK-SEALED HEAD RECORDS NO KEY, and strings.Contains(x, "") is ALWAYS true -- so an empty
		// Wrapped would fail this loop for a reason that has nothing to do with sealing. Skipped, but only
		// where an absent key is the RULE, so a regression that empties it for a real scope still fails
		// here rather than being waved through (NWP-20260915-17).
		if scopeSealedUnderDK(suf) {
			if idx[suf].Wrapped != "" {
				t.Errorf("%s: recorded a key for a head that is sealed under the profile DK", suf)
			}
			continue
		}
		if strings.Contains(sealed, idx[suf].Wrapped) {
			t.Errorf("%s: the wrapped key appears verbatim in the sealed index", suf)
		}
	}
	// The sealed index is standard base64, whose alphabet is A-Z a-z 0-9 + / =. JSON's structure ({ } " :) and a
	// scope suffix's '#' are outside it, so any of them means plaintext leaked -- and none can appear by chance.
	// The probe used to be the substrings "ref" and "#de": "ref" is three base64 letters, which random ciphertext
	// of this length spells by chance about once in a few hundred runs, failing a correct seal.
	if strings.ContainsAny(sealed, "{}\":#") {
		t.Error("the sealed index leaks its own JSON structure -- it is not sealed")
	}
}

// TestScopeIndexWrongDKDoesNotOpen: the index must be inert to anyone without the profile DK, and must fail
// CLOSED rather than returning a half-parsed map.
func TestScopeIndexWrongDKDoesNotOpen(t *testing.T) {
	dk, other := randBytes(32), randBytes(32)
	sealed := sealScopeIndex(dk, deriveScopeIndex("idxwrong", "horse battery staple correct", dk))
	if _, ok := openScopeIndex(other, sealed); ok {
		t.Fatal("a foreign DK opened the scope index")
	}
	if _, ok := openScopeIndex(dk, ""); ok {
		t.Fatal("an ABSENT index reported ok -- a pre-fix vault must be distinguishable from an empty one")
	}
	if _, ok := openScopeIndex(dk, "not base64 at all"); ok {
		t.Fatal("a corrupt index reported ok")
	}
}

// TestScopeIndexCoversEveryDeletedScope ties the index's suffix list to the one the delete path already
// walks, so a scope can never be purgeable-but-unfindable (or the reverse). deleteScopeSuffixes carries ""
// for the bare vault, which the index deliberately does not -- the vault IS the thing the index lives in.
func TestScopeIndexCoversEveryDeletedScope(t *testing.T) {
	inIndex := map[string]bool{}
	for _, s := range scopeIndexSuffixes {
		inIndex[s] = true
	}
	for _, s := range deleteScopeSuffixes {
		if s == "" {
			continue // the bare vault: it carries the index, it is not an entry in it
		}
		if !inIndex[s] {
			t.Errorf("deleteScopeSuffixes has %q and the scope index does not -- a scope the delete path "+
				"knows about would be unfindable after a recovery", s)
		}
	}
}
