package main

// Q119 as bounded 2026-10-21 (docs/product-decisions.md, dn-1104 #3): a verified profile delete hands the vault's
// blobs to the gateway's next collection. The delete presents a per-blob release proof derived from the profile's
// DK (blobReleaseProof) and the gateway releases only a blob whose commitment matches, never on the profile
// string alone.
//
// ~~This slice covers the bare vault only: the current manifest and every History entry. The scope heads (#de,
// #media, #sys, #apps, #keys, #wallet) are sealed under their own keys and keep their lease schedule.~~
// *(Superseded by NWP-20261117-13: the scope heads go too, each under the key its own seal leased with: #de, #media,
// #sys, #apps and #keys under the scope key (the index entry's Wrapped, then its Prev, then deriveKey: the first that
// opens the head), #wallet under the DK. deleteProfileSE reads the heads before its purge tombstones them. A blob
// leased under another key (a wallet blob a scope flush bought into, an import, a re-key's older blobs) keeps its
// schedule, as does a vault-shaped head's own JSON blob, which no set names. A tied scope is mostly such a blob: the
// tie and the re-key job re-seal the scope inside capWrite with the profile DK, so its chunks, manifests and History
// are leased under the DK, and only what a later seal of that scope uploaded goes. A scope no key opens, or whose set
// cannot be read whole, is left out on its own; the others still go.)* A blob leased
// before its commitment column existed, or under another key, is refused by the gateway and keeps its schedule too.
// The plan grant is untouched: POST /release names blobs only.
//
// ~~A tied (secure-element) profile with no security key, deleted through the login daemon, releases nothing. It has
// no pass-only slot and the daemon has no NOWHERE_SE_SECRET, so openVaultDK returns nil inside deleteProfile and the
// release takes the "did not open to its data key" skip: those blobs keep their lease schedule. A profile with a
// security key (FIDO2), tied or not, has no pass-only slot either and opens through its fido2 slot only while the
// daemon's environment holds the key's cached hmac (NOWHERE_FIDO2_HMAC). loadFido2HmacEnv adopts it at sign-in and at
// a mid-session enrol, and maybePayRent and several verbs re-adopt it after a daemon restart, but handleDelete does
// not, so a delete that runs after a restart, before anything has re-adopted it, releases nothing for one either.
// The follow-up is for handleDelete to pass the session's SE secret into the delete, as handleDeleteSnapshot does
// with readRoamSessionSE, and to call loadFido2HmacEnv first, as handlePinStatus does.~~ *(Superseded by
// NWP-20261114-17: the delete opens such a vault with the session's chip secret, which handleDelete passes to
// deleteProfileSE only when the typed name and passphrase are the session's own (deleteSessionSE), or with the key
// hmac that loadFido2HmacEnv adopts into the environment first. The hmac is tried for whatever is typed, but the
// fido2 KEK mixes the passphrase KEK, so it opens only that key's own vault.)*
//
// The order is releaseDeletedSnapshot's: strict set, evict, proofs, release, one counts-only line. ~~A History entry
// that is not a CDC manifest (the creation state) makes the whole set fail, so nothing is released: the safe
// direction.~~ *(Superseded by NWP-20261113-14: an entry that decrypts under the DK and is not a CDC manifest -- the
// creation state, createVault's empty tar -- names only its own blob, which manifestBlobsStrict adds to the set. Any
// other entry that cannot be read still fails the whole set.)*
//
// The release's cost to the delete is bounded. Each POST /release batch of up to releaseBatchMax keys goes out on
// leaseClient(n), whose deadline is leaseBudget(n) = gwDefault + gwLeasePerRef per key (about 71 s for 4096), and
// the batches run one after another, so a slow gateway could add minutes to a DELETE that already takes 60-90 s on a
// slow network (NWP-20261011-37) and that the chooser reads for 90 s. So the set, the eviction and the proofs run
// inline (a dead store is bounded by armStoreGiveUp), the release runs through goSafe, and the delete waits for it at
// most deleteReleaseWait (gwUI, 10 s): that is the release's worst-case cost. Past it one keyless line is written and
// the delete returns with its verdict unchanged; the release carries on in the background (the delete-profile CLI
// verb exits and drops it, and so does a reboot handleDelete falls back to: the no-uid arm's, deleteNoUidReboot, or
// deleteReapFallback's when the reap's SWITCH is not consumed in 8 s), and whatever it does not release keeps its
// lease schedule.

import (
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"time"
)

// releaseDeletedProfileFn is a var so deleteProfile's tests can record the call.
var releaseDeletedProfileFn = releaseDeletedProfile

// deleteReleaseWait bounds how long a delete waits for its POST /release (see the header); a var so
// TestDeleteReleaseWaitIsBounded can shorten it.
var deleteReleaseWait = gwUI

// deleteReleaseSet is every blob the vault's current manifest and each kept History manifest name. Nothing is
// subtracted: the whole profile is going. Any manifest that cannot be read returns (nil, err), so a partial set is
// never released.
func deleteReleaseSet(base string, dk []byte, v *vault) (map[string]bool, error) {
	set := map[string]bool{}
	if v.Manifest != "" {
		if err := manifestBlobsStrict(base, dk, v.Manifest, set); err != nil {
			return nil, err
		}
	}
	for _, h := range v.History {
		if h.Manifest == "" {
			continue
		}
		if err := manifestBlobsStrict(base, dk, h.Manifest, set); err != nil {
			return nil, err
		}
	}
	return set, nil
}

// deletedScopeHead is one scope head a delete read before its purge: the suffix, the head value and
// deriveKey(name+suf, pass). It lives in RAM for one delete and is never logged.
type deletedScopeHead struct {
	suf     string
	head    string
	derived []byte
}

// deleteScopeHeads reads each scope head of (name, pass) as a restore does, before the delete's purge tombstones
// it. An error or an empty head leaves that scope out. It reads nothing else of a scope: the blobs stay in the store
// after the purge, the refs do not. In cap mode on S3 the probe carries the value, so a scope costs one ref read
// when its v2 head exists and two otherwise; getRef runs only where the probe carried no value. It prints nothing.
func deleteScopeHeads(base, name, pass string) []deletedScopeHead {
	var heads []deletedScopeHead
	for _, suf := range scopeIndexSuffixes {
		var head string
		err := recovered(func() {
			ref, val, have := headRef(base, name+suf, pass)
			head = val
			if !have && !(isS3(base) && capMode()) {
				head = getRef(base, ref)
			}
		})
		if err == nil && head != "" {
			heads = append(heads, deletedScopeHead{suf: suf, head: head, derived: deriveKey(name+suf, pass)})
		}
		writeProg(2, 20) // #734: the gate's socket read sees progress across these reads
	}
	return heads
}

// deletedScopeKey is the key the scope head h was sealed under: the DK for a scope sealed under it (#wallet);
// otherwise the index entry's Wrapped, then its Prev, then the derived key -- the first that opens the head. nil
// when none does.
func deletedScopeKey(base string, dk []byte, idx map[string]scopeRec, h deletedScopeHead) []byte {
	if scopeSealedUnderDK(h.suf) {
		if scopeKeyOpens(base, h.head, dk) {
			return dk
		}
		return nil
	}
	kek := kekScopes(dk)
	var cands [][]byte
	if rec, ok := idx[h.suf]; ok {
		for _, w := range []string{rec.Wrapped, rec.Prev} {
			if w == "" {
				continue
			}
			if k, ok := unwrap(kek, w); ok {
				cands = append(cands, k)
			}
		}
	}
	cands = append(cands, h.derived)
	for _, k := range cands {
		if len(k) > 0 && scopeKeyOpens(base, h.head, k) {
			return k
		}
	}
	return nil
}

// scopeReleaseSet is every blob the scope head names under key: a scope vault's current manifest and kept History
// (deleteReleaseSet), or a bare head's manifest and chunks. Strict, as deleteReleaseSet is: any error returns
// (nil, err). A vault-shaped head's own JSON blob is in no set.
func scopeReleaseSet(base string, key []byte, head string) (map[string]bool, error) {
	var blob []byte
	if err := recovered(func() { blob = getHeadBlob(base, head) }); err != nil {
		return nil, err
	}
	if sv, isV := parseVault(blob); isV {
		return deleteReleaseSet(base, key, sv)
	}
	set := map[string]bool{}
	if err := manifestBlobsStrict(base, key, head, set); err != nil {
		return nil, err
	}
	return set, nil
}

// releaseDeletedProfile releases the vault's blobs and those of the scope heads the delete read before its purge
// (heads, nil = none), in one request. It never returns an error and never panics, and cannot change the delete's
// verdict: whatever it cannot do leaves the blobs on the lease schedule. No line carries a profile name, suffix, ref,
// key, preimage or commitment.
func releaseDeletedProfile(base string, dk []byte, v *vault, heads []deletedScopeHead) {
	skip := func(format string, a ...any) {
		fmt.Fprintf(os.Stderr, "[agent] delete: nothing released early -- "+format+"\n", a...)
	}
	if !capMode() {
		skip("this store has no gateway")
		return
	}
	if multiDeviceEnabled() {
		skip("per-unit heads of other devices are not read")
		return
	}
	if v == nil {
		skip("no vault was read")
		return
	}
	if dk == nil {
		skip("the vault did not open to its data key")
		return
	}
	set, err := deleteReleaseSet(base, dk, v)
	if err != nil {
		skip("a version could not be read (%v)", err)
		return
	}
	if len(set) == 0 {
		skip("the vault names no object")
		return
	}
	// Each scope's set is strict on its own: a scope no key opens, or whose set cannot be read whole, is left out
	// and the others still go.
	type scopeSet struct {
		key []byte
		set map[string]bool
	}
	var scopes []scopeSet
	idx, _ := openScopeIndex(dk, v.Scopes)
	for _, h := range heads {
		key := deletedScopeKey(base, dk, idx, h)
		if key == nil {
			continue
		}
		sset, err := scopeReleaseSet(base, key, h.head)
		if err != nil || len(sset) == 0 {
			continue
		}
		scopes = append(scopes, scopeSet{key, sset})
	}
	if left := len(heads) - len(scopes); left > 0 {
		fmt.Fprintf(os.Stderr, "[agent] delete: %d scope head(s) left on their lease schedule -- no key opened them or an object could not be read\n", left)
	}
	union := make(map[string]bool, len(set))
	for k := range set {
		union[k] = true
	}
	for _, s := range scopes {
		for k := range s.set {
			union[k] = true
		}
	}
	// An eviction error does not hold the release back: the profile's heads are tombstoned and fenced, so no seal of
	// this phone names these blobs again, and a re-create gets a new DK and so new blob addresses.
	evicted, eerr := blobCacheEvict(workerBlobCachePath(), union)
	if eerr != nil {
		fmt.Fprint(os.Stderr, "[agent] delete: could not evict the profile's objects from this phone's blob cache -- releasing anyway\n")
	}
	proofs := make(map[string]string, len(union))
	for k := range set {
		proofs[k] = hex.EncodeToString(blobReleaseProof(dk, k))
	}
	// A key already present keeps its first proof.
	for _, s := range scopes {
		for k := range s.set {
			if _, ok := proofs[k]; !ok {
				proofs[k] = hex.EncodeToString(blobReleaseProof(s.key, k))
			}
		}
	}
	// The job captures the proofs and the gateway URL, never a key.
	type releaseResult struct {
		released []string
		status   int
		err      error
	}
	done := make(chan releaseResult, 1)
	gw := os.Getenv("GATEWAY_URL")
	goSafe("delete-release", func() {
		var r releaseResult
		defer func() {
			if p := recover(); p != nil {
				r = releaseResult{err: recoveredErr("release", p)}
			}
			done <- r
		}()
		r.released, r.status, r.err = newGatewayClient(gw, gwDefault).releaseBlobs(proofs)
	})
	var released []string
	var status int
	select {
	case r := <-done:
		released, status, err = r.released, r.status, r.err
	case <-time.After(deleteReleaseWait):
		fmt.Fprint(os.Stderr, "[agent] delete: the gateway is still taking the release -- not waiting\n")
		return
	}
	switch {
	case status == http.StatusNotFound || status == http.StatusMethodNotAllowed:
		skip("the gateway does not release early")
	case err != nil:
		skip("the gateway did not take the request (status %d)", status)
	default:
		fmt.Fprintf(os.Stderr, "[agent] delete: %d of %d object(s) of the profile's vault released for the next collection, %d scope head(s) sent with it (%d evicted from this phone's cache)\n",
			len(released), len(proofs), len(scopes), evicted)
	}
}
