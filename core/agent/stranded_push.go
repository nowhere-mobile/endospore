package main

import (
	"sort"
	"strconv"
	"strings"
)

// strandedReason names why no slot of the stored head opens for this session, or "" when it cannot tell
// (NWP-20261111-01; Q016 in docs/product-decisions.md, 2026-10-20).
//
// stored is the vault at the stored head; known is the vault at the head this session last KNEW -- the one its
// restore receipt names (restoreReceiptHead), which is the head it opened at login or last published itself.
// known is nil when there is no receipt, receipts are off, or that head cannot be read as a vault, and then the
// answer is "": nothing here may turn an unknown into a verdict.
//
//	locks-changed      the stored head's keyslots are not the ones this session opened: the sign-in was changed
//	                   after this phone signed in, so no slot this phone holds opens it
//	unlock-lost        the keyslots are the ones this session opened and still none opens: this phone lost its own
//	                   unlock material
//	...-key            either, when the stored head carries at least one security-key slot (a key can open it)
//
// The slots compare as a multiset of (Kind, Wrapped, CredID, Salt, UV). Wrapped is in the tuple because a rotation
// or a recovery rebuilds the vault with the SAME kinds and new wrapped keys, and that is a lock change. Added, Label
// and Transport are not: a relabelled key is the same lock. Wrapped is compared for equality only, and nothing here
// prints or returns a slot.
func strandedReason(stored, known *vault) string {
	if known == nil {
		return ""
	}
	why := "unlock-lost"
	if !sameSlotMultiset(stored.Slots, known.Slots) {
		why = "locks-changed"
	}
	if len(listFido2Slots(stored)) > 0 {
		why += "-key"
	}
	return why
}

// sameSlotMultiset reports whether a and b hold the same locks, in any order (see strandedReason).
func sameSlotMultiset(a, b []keyslot) bool {
	if len(a) != len(b) {
		return false
	}
	key := func(s keyslot) string {
		return strings.Join([]string{s.Kind, s.Wrapped, s.CredID, s.Salt, strconv.FormatBool(s.UV)}, "\x00")
	}
	ka, kb := make([]string, len(a)), make([]string, len(b))
	for i := range a {
		ka[i] = key(a[i])
	}
	for i := range b {
		kb[i] = key(b[i])
	}
	sort.Strings(ka)
	sort.Strings(kb)
	for i := range ka {
		if ka[i] != kb[i] {
			return false
		}
	}
	return true
}
