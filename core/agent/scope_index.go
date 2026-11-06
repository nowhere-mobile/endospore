package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"sort"
	"strings"
)

// THE SCOPE INDEX (NWP-20260915-02) -- how a recovered profile finds the five-sixths of itself that is not
// the vault.
//
// THE BUG IT EXISTS FOR. A profile is SIX heads: the bare vault plus `#de`, `#sys`, `#media`, `#apps` and
// `#keys` (`#wallet` too, though it is deliberately outside profileFootprint). Only the bare vault is a
// `vault` struct with keyslots; the other heads are BARE heads, whose LOCATION is
// profileRefV2(name#scope, pass) and whose KEY is deriveKey(name#scope, pass) -- both pure functions of the
// passphrase, and neither recorded anywhere. So after a recovery, which by definition happens because the
// passphrase is gone, those heads are not merely undecryptable: they are UNFINDABLE. Proven by
// TestRecoveryReachesEveryScope and, in its blast-radius form, by TestRecoveryFootprintIsSuperset, which
// measured a recovery dropping 10 of 15 objects on a profile carrying only two scopes.
//
// THE FIX. The DK is the one secret that survives both rotation and recovery -- recoverVault rebuilds the
// vault with the "same DK + entropy, new pass slot". So the vault carries, sealed under a DK-derived KEK, a
// record of WHERE each scope head lives and WHAT KEY opens it. Recovery reaches the vault through the
// recovery ref (which is keyed on name+entropy, not the passphrase), opens the index with the DK, and can
// then re-point every scope under the new credential.
//
// ⚠ DERIVED, NOT OBSERVED. The index is minted for ALL suffixes unconditionally, from (name, pass), and
// never by looking at which scopes happen to exist. That is not tidiness: the bare scope is sealed FIRST in
// every cycle (nowhere_roamd.sh pushes the vault before #de/#media, and #keys is not sealed in that chain at
// all -- it runs at the reap), so an index built by observation would record nothing on a profile's first
// session. That is precisely the "wrote down my 12 words, then lost the phone" case, so an observed index
// would miss the user it exists for.
//
// ⚠ THE WRITE REF, NOT THE READ REF. Ref is headWriteRef(name#scope, pass), never headKey. headKey returns
// the LEGACY ref when one exists, and putHeadSingle tombstones legacy on the scope's very next seal -- so an
// index keyed on headKey would record, on a legacy profile, a ref that the same cycle then kills. A recorded
// ref that later reads empty-but-existing is a TOMBSTONE and must be a loud error, never a silent skip.
//
// ⚠ SEALED, NOT PLAINTEXT. A vault head blob is plaintext JSON that the store holds; an unsealed index would
// hand a store operator a profile -> objects graph they cannot otherwise build. It is wrapped under
// kekScopes(dk) for the same reason vault.TelPriv and vault.Pin are.

// scopeIndexSuffixes is every scope a profile seals under. `#wallet` is included DELIBERATELY even though
// profileFootprint excludes it: the index answers "where does this profile's state live", and a wallet whose
// head is unfindable after a recovery is a lost wallet. Excluding it from the LEASE set is a separate and
// correct decision (see docs/profile-snapshot.md) and this does not change it.
var scopeIndexSuffixes = []string{"#de", "#sys", "#media", "#apps", "#keys", "#wallet"}

// scopeBillKey is a RESERVED index key that is not a scope at all (NWP-20260917-04). It records the
// profile's own BILLING key -- profileRefV2(name, pass), the value the gateway keys entitlement grants
// on -- so a RECOVERY can name the plan it is moving off.
//
// ⚠ WHY IT HAS TO LIVE HERE. A rotation can derive the old billing key itself: it holds the old
// passphrase. A recovery cannot, by premise -- the passphrase is exactly what was lost -- and the vault
// records no bare profile ref anywhere else. The scope index is the one structure a recovery CAN read,
// because it is sealed under the DK and the 12-word code unwraps the DK. Without this the gateway half
// of plan continuity works for a rotation and silently fails for the case that matters most.
//
// ⚠ IT DECLARES NO KEY AND SEALS NOTHING. The entry carries a Ref and nothing else: there is no
// head at that address, no scope key to wrap, and nothing to observe.
const scopeBillKey = "!bill"

// scopeBillPrevKey records the billing key a credential change just moved OFF, so the carry can be
// RETRIED (NWP-20260917-07). Without it a failed carry is permanent: the old passphrase is gone by
// premise on the recovery path, and repointScopes has already advanced !bill to the new credential, so
// nothing in the tree can name the old plan afterwards. One attempt, forever, was the single largest
// residual of NWP-20260915-23.
//
// ⚠ IT RECORDS NOTHING AN ATTACKER DOES NOT ALREADY HAVE. The value is
// profileRefV2(name, oldpass), which anyone who knew the old passphrase can recompute offline forever
// -- that is the property the whole {old,new} authorisation rests on -- and it sits inside the DK seal
// like the rest of the index.
const scopeBillPrevKey = "!bill-prev"

// scopeBillRetagKey records the billing keys this profile's STORE ROWS may still be tagged with, so every
// later lease can name them as `prior` until the gateway has re-tagged them (NWP-20261009-02,
// docs/store-write-authorization.md §4).
//
// ⚠ WHY A RECORD AND NOT A DERIVATION. The gateway moves a ledger row from one profile key to another only
// when a lease names the old key in `prior` -- that is the whole authority, and it is deliberately the same
// as POST /rebind's. A credential change sends the key it moved off in its own lease, but that lease names
// only the heads the bracket wrote: the chunks are sealed under the unchanged DK, elided by the blob cache,
// and never re-published, so their rows stay tagged with the OLD key until a lease that names them carries
// the old key as prior. The one lease that names them all is payRent's full-footprint renewal, and it may
// not run for days. So the key is written down here, sealed under the DK like the rest of the index, sent
// by every bare seal and by payRent, and cleared once a full-footprint lease has answered 200.
//
// ⚠ IT RECORDS NOTHING AN ATTACKER DOES NOT ALREADY HAVE, for the reason !bill-prev states: each value is
// profileRefV2(name, somepass), recomputable offline by anyone who knew that passphrase.
//
// The value is a LIST -- a profile can change its credential twice before a full-footprint lease lands --
// rendered as the p2: prefix followed by the keys comma-joined, oldest first, at most billRetagMax of them.
// Same unresolvable shape as the other two reserved keys, so an older walker's getRef misses it.
const scopeBillRetagKey = "!bill-retag"

// billRetagMax bounds the list: the gateway accepts at most 8 prior keys per lease (§4), and a ninth change
// before any full-footprint lease has settled means the oldest row set is the one least likely to still
// exist. The oldest key is dropped first.
const billRetagMax = 8

// scopeBillMidKey records the INTERMEDIATE keys of a chained credential change (NWP-20261103-01, Q147).
//
// ⚠ WHY. Plan on A. A->B moves the plan at the gateway but the reply is lost, so the record stays A
// (!bill-prev). B->C before any sign-in is then refused by the gateway's 7-epoch per-grant cooldown
// (200 {"moved":0}), and every later retry asks A->C: A holds nothing, and nothing names B, where the plan
// actually sits. This list names B (and any further intermediate key), so the retry asks each of them too.
//
// ⚠ IT RECORDS NOTHING AN ATTACKER DOES NOT ALREADY HAVE, for the reason !bill-prev states: each value is
// profileRefV2(name, somepass), recomputable offline by anyone who knew that passphrase, and it sits inside
// the DK seal like the rest of the index.
//
// The value is the !bill-retag encoding: billRefPrefix, then the keys comma-joined, oldest first, at most
// billRetagMax of them. It exists only beside an outstanding !bill-prev, and dropBillPrev clears both.
const scopeBillMidKey = "!bill-mid"

// billRefPrefix makes the recorded ref UNRESOLVABLE, and that is the entire backward-compatibility
// argument rather than a decoration.
//
// ⚠⚠ BOTH INDEX WALKERS ITERATE BY MAP KEY, NOT BY scopeIndexSuffixes. scopeIndexSuffixesSorted
// ranges over whatever the index holds, so an older build -- one carrying the index from NWP-20260915-02
// but not this slice -- WILL see this entry and treat it as a scope. With the prefix, getRef misses, the
// entry never becomes Observed, and repointScopes takes its never-sealed arm: it publishes nothing and
// tombstones nothing. WITHOUT the prefix the recorded value is the live bare vault head's real address,
// so that build would RESOLVE it, fail to open "name#!bill" with a key derived for a different name, and
// fail the whole rotation -- or answer BLANK to a correct twelve-word phrase.
const billRefPrefix = "p2:"

// billKeyRec renders the index entry for (name, pass).
//
// ⚠ profileRefV2, NOT headWriteRef. They coincide in every shipped build because multi-device is
// off, but headWriteRef returns the per-UNIT ref under #91 while the gateway keys grants on
// profileRefV2 -- which is what capFlush labels every lease with. Recording the wrong one would name a
// key the ledger has never heard of, and the failure would be a silent no-op at the far end.
func billKeyRec(name, pass string) scopeRec {
	return scopeRec{Ref: billRefPrefix + profileRefV2(name, pass)}
}

// billKeyOf returns the recorded billing key, or "" when the index predates this slice or holds
// something unexpected. "" is an ordinary answer meaning "we cannot name the old plan", and every
// caller must treat it as "do nothing" rather than as an error.
func billKeyOf(idx map[string]scopeRec) string { return billRefOf(idx, scopeBillKey) }

// billPrevOf returns the billing key a credential change moved off and has not yet confirmed carrying,
// or "" when there is no outstanding carry.
func billPrevOf(idx map[string]scopeRec) string { return billRefOf(idx, scopeBillPrevKey) }

func billRefOf(idx map[string]scopeRec, key string) string {
	r := idx[key].Ref
	if !strings.HasPrefix(r, billRefPrefix) {
		return ""
	}
	return strings.TrimPrefix(r, billRefPrefix)
}

// billRetagOf returns the billing keys the profile's rows may still be tagged with, oldest first, or nil when
// nothing is outstanding. Only 64-hex entries are kept: the gateway refuses any other shape in `prior`, so a
// damaged entry must drop out here rather than fail every lease that carries the record (NWP-20261009-02).
func billRetagOf(idx map[string]scopeRec) []string { return billKeyListOf(idx, scopeBillRetagKey) }

// billMidOf returns the intermediate billing keys of an unsettled chained change, oldest first, or nil.
func billMidOf(idx map[string]scopeRec) []string { return billKeyListOf(idx, scopeBillMidKey) }

func billKeyListOf(idx map[string]scopeRec, key string) []string {
	raw := billRefOf(idx, key)
	if raw == "" {
		return nil
	}
	var out []string
	for _, k := range strings.Split(raw, ",") {
		if isContentHash(k) {
			out = append(out, k)
		}
	}
	return out
}

// billRetagPush records that this profile's rows may be tagged with key: it appends key to the outstanding
// list (newest last, no duplicates, the oldest dropped past billRetagMax) and returns the index. current is
// the profile's billing key from here on, and it is dropped from the whole list, not only refused as key
// (NWP-20261009-02): a credential change back to an earlier passphrase (A->B->A) would otherwise leave the
// record naming the profile's own key, which the gateway refuses on every lease as 400 `bad prior`. An empty
// list removes the entry. An empty key, or one that is not a billing key, adds nothing -- "" is billKeyOf's
// ordinary answer for an index that predates NWP-20260917-04, and recording it would make every later lease
// carry a prior the gateway rejects.
func billRetagPush(idx map[string]scopeRec, key, current string) map[string]scopeRec {
	keys := make([]string, 0, billRetagMax+1)
	for _, k := range billRetagOf(idx) {
		if k != key && k != current {
			keys = append(keys, k)
		}
	}
	if isContentHash(key) && key != current {
		keys = append(keys, key)
	}
	if len(keys) > billRetagMax {
		keys = keys[len(keys)-billRetagMax:]
	}
	if len(keys) == 0 {
		delete(idx, scopeBillRetagKey)
		return idx
	}
	idx[scopeBillRetagKey] = billRetagRec(keys)
	return idx
}

// billRetagRec renders the !bill-retag entry for keys (oldest first). It declares no key and seals nothing,
// like the other two reserved entries.
func billRetagRec(keys []string) scopeRec {
	return scopeRec{Ref: billRefPrefix + strings.Join(keys, ",")}
}

// billMidRec renders the !bill-mid entry for keys (oldest first), in the same unresolvable shape.
func billMidRec(keys []string) scopeRec { return billRetagRec(keys) }

// scopeSsaidKey records the profile's SSAID userkey (#210), the key every app's ANDROID_ID derives from
// (NWP-20261122-12; Q026 in docs/product-decisions.md, 2026-10-20, with its offline answer of 2026-10-21).
//
// ⚠ WHY IT HAS TO LIVE HERE. ssaidUserKey derives the userkey from deriveKey(name, pass), a key of the
// PASSPHRASE, so a passphrase change or a 12-word recovery would change every app's id once and sign out
// every device-bound login (Amazon is the known case). The index is sealed under the DK, which survives
// both, so a key recorded here outlives the passphrase that derived it. SEED-SSAID reads it back
// (seedSsaidKey in main.go).
//
// ⚠ MINT IF ABSENT, CARRIED VERBATIM, NEVER RE-DERIVED. The first bare seal records the key of the
// passphrase in use then (pushProfile); a rotation whose index carries none records the key of the
// passphrase it moves off; repointScopes copies the record into every rotated and recovered index. Writing
// it again under a later passphrase would change every app's id, which is the bug.
//
// The p2: prefix keeps an older walker safe, for the reason billRefPrefix states: an older build sees this
// entry as a scope, its getRef misses, and repointScopes takes its never-sealed arm. That build's rotation
// rebuilds the index from the keys it knows and so drops the record; the next bare seal on a newer build
// records the key of the passphrase in use then.
//
// ⚠ THE VALUE IS SECRET-DERIVED (ssaidUserKey over the pass-KEK). It sits only inside the DK seal, so the
// store sees ciphertext, and it is never logged.
const scopeSsaidKey = "!ssaid"

// ssaidRec renders the !ssaid entry for the userkey uk, in the unresolvable p2: shape of the billing records.
func ssaidRec(uk string) scopeRec { return scopeRec{Ref: billRefPrefix + uk} }

// ssaidOf returns the recorded SSAID userkey, or "" when the index carries none or holds anything but 64
// upper-case hex characters (ssaidUserKey's format). "" means "seed the derived key".
func ssaidOf(idx map[string]scopeRec) string {
	uk := billRefOf(idx, scopeSsaidKey)
	if len(uk) != 64 {
		return ""
	}
	for i := 0; i < len(uk); i++ {
		if c := uk[i]; !(c >= '0' && c <= '9' || c >= 'A' && c <= 'F') {
			return ""
		}
	}
	return uk
}

// isScopeSuffix separates real scopes from the reserved keys. Every walker that does store I/O or
// re-points a head must consult it, or it will treat the billing records and the SSAID record as scopes.
func isScopeSuffix(k string) bool {
	return k != scopeBillKey && k != scopeBillPrevKey && k != scopeBillRetagKey && k != scopeBillMidKey &&
		k != scopeSsaidKey
}

// scopeRec is one scope's coordinates: where its head is published, and the key that opens it.
type scopeRec struct {
	Ref     string `json:"ref"`     // headWriteRef(name#scope, pass) -- recorded verbatim, so it survives the passphrase that derived it
	Wrapped string `json:"wrapped"` // deriveKey(name#scope, pass), wrapped under kekScopes(dk)
	// Observed says this entry describes a scope head somebody actually READ, rather than one derived
	// from (name, pass). It gates exactly one thing -- the tombstone refusal in repointScopes -- and
	// nothing else: Ref and Wrapped still locate and open the scope either way, so a derived entry is
	// no less useful to a recovery. See THE TOMBSTONE TEST in scope_repoint.go (NWP-20260915-18).
	//
	// ⚠ THE POLARITY IS THE MIGRATION. Absent (false) must mean DERIVED, because every index in the
	// field today was minted by deriveScopeIndex and none of them carry this key. Reading absent as
	// "observed" would leave every fielded profile on the broken behaviour, which is the whole bug.
	Observed bool `json:"observed,omitempty"`
	// Minted says Wrapped is a RANDOM key a tie gave this scope, not deriveKey(name#scope, pass) -- the scope
	// is protected and only its index entry (or a slot on its head) can open it (NWP-20261007-11).
	// Prev is the key a re-key in flight is replacing, wrapped like Wrapped. It covers the window between the
	// vault carrying this index and the scope head being switched: in that window the head is still under the
	// old key, so a reader picks whichever of Wrapped/Prev verifies against the head (scopeKeyFor). It wraps a
	// key the passphrase already derives, inside the DK seal, so leaving it exposes nothing new.
	// Both omitempty: an index without them serializes byte-identically, so no fielded signature changes.
	Minted bool   `json:"minted,omitempty"`
	Prev   string `json:"prev,omitempty"`
	// Next and Progress are a BACKGROUND re-key in flight (NWP-20261008-03, docs/tie-scope-keys.md §9): Next is the
	// new key K' wrapped like Wrapped, Progress the hash of a record sealed under K' naming every chunk already
	// re-sealed. Wrapped stays the CURRENT key until the switch, so nothing that reads this entry sees a change while
	// a job runs. Both omitempty, for the same byte-identity reason as Minted and Prev.
	Next     string `json:"next,omitempty"`
	Progress string `json:"progress,omitempty"`
	// At is the unix second of the credential change that recorded a !bill-prev (NWP-20261103-05, Q147): the
	// time the phone's own carry was left outstanding, from which GET-BILLING says the plan is still moving
	// while the gateway's rebind cooldown can still be refusing it. Set ONLY on !bill-prev; omitempty keeps
	// every index without it byte-identical.
	At int64 `json:"at,omitempty"`
}

// ⚠ AN EMPTY Wrapped MEANS "NO KEY IS RECORDED HERE", and it now has two causes. One is temporary: a
// RESCUED entry, derived at rotation time by rescueScopeIndex, which records locations only and leaves the
// key to be observed from the head (NWP-20260915-14). The other is permanent and is #wallet
// (NWP-20260915-17): the wallet head is not a scope-keyed manifest but a blob sealed under the PROFILE DK,
// so there is no scope key to record -- and recording one was worse than useless, because
// deriveKey(name#wallet, pass) is the REF-DERIVATION secret, i.e. a second copy of the ADDRESS filed under
// a field labelled "the key". It is also unnecessary: every consumer of this index holds the DK before it
// can open the index at all, which is sealed under kekScopes(dk). For #wallet the halves split -- the
// LOCATION is the irreducible fact a recovery cannot derive, and the KEY is one it already has.
//
// ⚠⚠ AND THE OBVIOUS TIDY-UP IS A MONEY-GRADE TRAP. Do NOT "fix" this by making the wallet a real
// scope sealed under deriveKey(name#wallet, pass) so the field becomes true. repointScopes deliberately
// never retires an old scope ref, so that would hand anyone holding the OLD passphrase a directly
// DECRYPTABLE copy of the orphaned wallet at a ref nothing ever tombstones. Today an old passphrase is a
// working locator and not a working key, because the bare vault it would need for the DK is retired.
// Make the RECORD honest; never move the SEAL.
//
// scopeSealedUnderDK names that distinction once, so the two minters and the two consumers agree by
// construction rather than by a string comparison repeated in four places.
func scopeSealedUnderDK(suf string) bool { return suf == "#wallet" }

// kekScopes derives the KEK that wraps every scope key in the index. Keyed by the DK and nothing else, which
// is the whole point: the DK is what a recovery still holds. An HMAC rather than Argon2 because the input is
// already a 32-byte uniformly-random key, not a low-entropy secret -- the same reason wrap() takes a KEK
// directly. Domain-separated so this key can never collide with another DK-derived use.
func kekScopes(dk []byte) []byte {
	mac := hmac.New(sha256.New, dk)
	mac.Write([]byte("nowhere-scope-index-v1"))
	return mac.Sum(nil)
}

// observeScopes upgrades DERIVED entries to OBSERVED for scopes whose head resolves NOW, and reports
// whether it changed anything. It is the only way an index minted before a scope existed learns that the
// scope is real -- and createVault mints at a moment when, by construction, none of them are.
//
// ⚠ IT FLIPS ONE BIT AND TOUCHES NOTHING ELSE, which is what keeps it clear of MINT-IF-ABSENT, NEVER
// RE-DERIVE (see the bare-seal call site). Ref and Wrapped are left exactly as recorded, so the hazard that
// rule exists for -- re-deriving a scope key that a credential change has already turned into a KEK, and
// only finding out at the next recovery -- is unreachable from here. "Have I seen a head at this address"
// is a different question from "what opens it", and only the first is being answered.
//
// ⚠ A SCOPE IS RECORDED ONE CYCLE AFTER IT FIRST APPEARS, DELIBERATELY AND UNAVOIDABLY. roamd pushes
// the BARE vault first and the scopes after it (nowhere_roamd.sh: `_push vault`, then `_push de`,
// `_push media`, ...), so a scope sealed for the FIRST time is not yet on the store when this runs; the next
// cycle records it, 120s later. Only a brand-new scope lags -- one the profile already had is recorded on
// the very first seal after this build lands.
//
// The consequence is bounded and stated at the guard: a profile that has sealed exactly ONCE in its life
// and then loses a scope does not get the loud refusal. Every profile used for more than one cycle does.
// See TestATombstoneIsNotEvidenceUntilSomebodySawTheScope.
func observeScopes(base string, idx map[string]scopeRec) bool {
	changed := false
	for _, suf := range scopeIndexSuffixesSorted(idx) {
		if !isScopeSuffix(suf) {
			continue // the billing record names no head; probing for one is a pointless store round-trip
		}
		rec := idx[suf]
		if rec.Observed || rec.Ref == "" {
			continue
		}
		if getRef(base, rec.Ref) == "" {
			continue // absent, or a tombstone: either way nobody has seen a scope here
		}
		rec.Observed = true
		idx[suf] = rec
		changed = true
	}
	return changed
}

// deriveScopeIndex builds the index for (name, pass) BY DERIVATION. It performs no store I/O and does not
// care whether a given scope has ever been sealed: a suffix that was never used simply names a ref that
// resolves to nothing, which a consumer skips. See the DERIVED, NOT OBSERVED note above.
//
// ⚠ IT NEVER SETS Observed, AND THAT IS WHAT THE NAME MEANS (NWP-20260915-18). Everything here is
// computed from (name, pass, dk) without looking at the store, so every entry is a PREDICTION about where a
// scope would live -- equally true of a scope that exists, one that never has, and one whose ref is a delete
// tombstone. Recording that prediction as though somebody had confirmed it is exactly what bricked rotation
// and recovery for every re-created profile. Observations are made in two places only: observeScopes, and
// repointScopes when it reads a head itself.
//
// An earlier draft of -18 had this take `base` and look. It was DELETED rather than kept: a mutation run
// showed it changed no outcome the bare seal did not already reach in the same call, and two ways to become
// observed is one more than the rule needs.
func deriveScopeIndex(name, pass string, dk []byte) map[string]scopeRec {
	kek := kekScopes(dk)
	idx := make(map[string]scopeRec, len(scopeIndexSuffixes))
	for _, suf := range scopeIndexSuffixes {
		scoped := name + suf
		ref, _ := headWriteRef(scoped, pass)
		if scopeSealedUnderDK(suf) {
			idx[suf] = scopeRec{Ref: ref} // no key: the DK opens it, and every reader of this index holds the DK
			continue
		}
		idx[suf] = scopeRec{Ref: ref, Wrapped: wrap(kek, deriveKey(scoped, pass))}
	}
	// NWP-20260917-04: and the profile's own billing key, so a recovery can name the plan it moves off.
	// Derived like everything else here and just as cheap -- profileRefV2 reuses the memoised deriveKey.
	idx[scopeBillKey] = billKeyRec(name, pass)
	return idx
}

// sealScopeIndex renders the index for vault.Scopes: canonical JSON (map keys sorted by encoding/json, and
// the suffix list is fixed), wrapped under kekScopes(dk). Returns "" for an empty index so the field stays
// omitempty and a pre-fix vault's signature keeps verifying.
func sealScopeIndex(dk []byte, idx map[string]scopeRec) string {
	if len(idx) == 0 {
		return ""
	}
	b, err := json.Marshal(idx)
	check(err)
	return wrap(kekScopes(dk), b)
}

// openScopeIndex is sealScopeIndex's inverse. ok is false for an absent index (a pre-fix profile -- the
// caller must treat that as "this vault predates the index", never as "this profile has no scopes") and for
// one that will not unwrap or parse.
func openScopeIndex(dk []byte, sealed string) (map[string]scopeRec, bool) {
	if sealed == "" {
		return nil, false
	}
	b, ok := unwrap(kekScopes(dk), sealed)
	if !ok {
		return nil, false
	}
	var idx map[string]scopeRec
	if err := json.Unmarshal(b, &idx); err != nil || len(idx) == 0 {
		return nil, false
	}
	return idx, true
}

// scopeIndexSuffixesSorted is the index's suffixes in a stable order, so callers that iterate produce
// deterministic logs and deterministic store write order. A map range would not.
func scopeIndexSuffixesSorted(idx map[string]scopeRec) []string {
	out := make([]string, 0, len(idx))
	for k := range idx {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
