package main

// Scope-head repoint -- the recovery half of backlog "Scope heads still write a bare putHead with no
// History and no Version".
//
// THE GAP. pushProfile has two head-write branches (main.go). The VAULT branch retains the outgoing head
// (pushSnapshot -> v.History), bumps v.Version, re-signs, and advances the rollback anchor -- so a bad
// vault head can be rolled back to a retained snapshot. The SCOPE branch is a bare
// `putHead(base, profile, pass, manifestHash)`. No snapshot, no version, no anchor. History is a field on
// the vault struct, so a scope head has no history STRUCTURALLY, not by omission.
//
// The consequence is not theoretical: when a scope head (#media / #apps / #de / #keys) is repointed at a
// manifest that is wrong -- a truncated seal, a bad guard verdict -- the previous manifest hash is simply
// gone from the ref. The blobs usually survive, because they are content-addressed and shared, but nothing
// records WHICH hash was the good one. Recovery means reading the store's object listing to guess, before
// the gateway's GC collects the unreferenced manifest.
//
// This is the CHEAP half: point a scope head back at a manifest hash the operator supplies. The expensive
// half -- retaining scope history the way the vault does -- is still open, and this does not pretend to be
// it. What this buys is a supported, checked way to use a hash you already have.
//
// ⚠ A RE-POINTED SCOPE HEAD IS A VAULT (NWP-20261116-26). Every credential change (rotateVault,
// recoverVault) re-points each scope through repointScopes, and the new head is buildScopeVault's small
// vault: its `pass` slot wraps the PRESERVED original scope key under deriveKey(<scoped name>, newpass), and
// its Manifest names the manifest blob, still sealed under that original key. On such a head
// deriveKey(<scoped name>, pass) is the KEK that opens the slot, not the scope key. So this verb opens the
// vault with openVaultDKSE, validates the target under the key the slot holds, and publishes a NEW scope
// vault: the same slots, the replaced manifest in History, Version one above, re-signed with the scope key.
// Writing the target bare there would replace the vault with a head every reader opens with the wrong key.
// A bare or absent head keeps the bare write, with the key derived from the passphrase.
//
// ⚠ WHY VALIDATION IS ALSO AUTHORIZATION. A scope head seals under the scope key -- deriveKey(<scoped
// name>, pass) while the head is bare, the key its vault slot holds once a credential change re-pointed it --
// so a manifest blob only unseals if it was sealed by THIS profile under THIS profile's scope key. Requiring
// the target to decrypt is therefore not merely a typo guard -- it is what stops this verb pointing one
// profile's head at another profile's data, and what stops it fabricating a head for a name that never
// existed. No separate ownership check is needed, and none should be added in place of this one.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
)

var (
	errRepointNotScope  = errors.New("repoint: not a scope head")
	errRepointBadHash   = errors.New("repoint: target is not a content hash")
	errRepointNoSuchRef = errors.New("repoint: target does not exist in the store")
	errRepointForeign   = errors.New("repoint: target does not decrypt for this profile+passphrase")
	errRepointNotMan    = errors.New("repoint: target decrypts but is not a chunk manifest")
	errRepointSame      = errors.New("repoint: head already points there")
	errRepointLocked    = errors.New("repoint: the scope head is a vault no slot opens with this passphrase")
)

// validateRepointTarget proves the target is a manifest belonging to this profile, and says WHICH check
// failed. loadCDCManifest cannot be reused here: it collapses every failure -- missing blob, wrong key,
// malformed JSON -- into an empty chunkManifest, which is also what a legitimately EMPTY scope returns.
// A recovery tool that cannot tell "your passphrase is wrong" from "that scope is empty" is a trap.
func validateRepointTarget(base string, dk []byte, target string) (m chunkManifest, err error) {
	var blob []byte
	if err = recovered(func() { blob = getBlob(base, target) }); err != nil {
		return m, errRepointNoSuchRef
	}
	var pt []byte
	if err = recovered(func() { pt = unseal(dk, blob) }); err != nil {
		return m, errRepointForeign
	}
	if !bytes.HasPrefix(pt, cdcMagic) {
		return m, errRepointNotMan
	}
	if json.Unmarshal(pt[len(cdcMagic):], &m) != nil {
		return chunkManifest{}, errRepointNotMan
	}
	return m, nil
}

// repointScopeHead points one scope head at target. It returns the head it replaced, so the caller can
// print an exact undo. It never creates a head for a target that is not this profile's own.
//
// The name must carry a KNOWN scope suffix (profileBaseName), because a bare profile may be literally named
// "a#b"; and it must not be #wallet, whose head is a wallet blob sealed under the profile DK, never a manifest.
//
// A VAULT head (a scope a credential change re-pointed, see the header) is opened with openVaultDKSE. A vault
// no slot opens with this passphrase, or a signed vault that does not verify under the key its slot holds, is
// errRepointLocked, and nothing is written. Otherwise the target is validated under that key and a new scope
// vault is published with the target as its Manifest. For a vault head, old is the MANIFEST the vault named,
// not the vault blob's hash, so the undo the CLI prints re-points the head back at it. For a bare head, old is
// the raw head as before.
func repointScopeHead(base, name, pass, target string) (old string, m chunkManifest, err error) {
	if bn := profileBaseName(name); bn == name || scopeSealedUnderDK(name[len(bn):]) {
		return "", m, errRepointNotScope
	}
	if !isContentHash(target) {
		return "", m, errRepointBadHash
	}
	// headRef only carries the VALUE on cap backends (refProbe returns haveVal=false elsewhere), so the
	// getRef is not redundant -- reading `val` alone made every non-cap read look like an ABSENT head, which
	// the round-trip test caught immediately: the undo hash came back empty.
	href, hval, have := headRef(base, name, pass)
	if !have {
		if err = recovered(func() { hval = getRef(base, href) }); err != nil {
			return "", m, err
		}
	}
	old = hval
	key := deriveKey(name, pass) // a bare or absent head: the passphrase derives the scope key itself
	var ov *vault
	if old != "" {
		var isV bool
		if err = recovered(func() { ov, isV = parseVault(getHeadBlob(base, old)) }); err != nil {
			return old, m, err
		}
		if isV {
			// nil: the CLI reaches an `se` slot through NOWHERE_SE_SECRET, as every scope caller does.
			key = openVaultDKSE(ov, name, pass, nil)
			if key == nil || (ov.Sig != "" && !verifyVault(ov, key)) {
				return ov.Manifest, m, errRepointLocked
			}
		}
	}
	if ov != nil {
		old = ov.Manifest // a vault head: errRepointSame and the undo both mean the manifest it names
	}
	if m, err = validateRepointTarget(base, key, target); err != nil {
		return old, m, err
	}
	if old == target {
		return old, m, errRepointSame
	}
	if ov == nil {
		if err = recovered(func() { putHead(base, name, pass, target) }); err != nil {
			return old, m, err
		}
		return old, m, nil
	}
	// The vault write: every slot and the scope's own History stay; the replaced manifest joins History so
	// the undo has a record, and the bumped Version and the signature are what resolveKeyHead checks.
	nv := *ov
	if err = recovered(func() {
		pushSnapshot(&nv, target, nv.HeadKind)
		nv.Manifest = target
		nv.Version++
		signVault(&nv, key)
		vh := postBlob(base, serializeVault(&nv))
		putHead(base, name, pass, vh)
	}); err != nil {
		return old, m, err
	}
	return old, m, nil
}

// recovered runs f and turns the codebase's panic-based fail() into an error, so callers can branch on a
// failure instead of taking the process down. The agent's verbs are allowed to die; a recovery tool that
// dies mid-way through diagnosing is worse than one that reports.
func recovered(f func()) (err error) {
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(error); ok {
				err = e
				return
			}
			err = fmt.Errorf("%v", r)
		}
	}()
	f()
	return nil
}
