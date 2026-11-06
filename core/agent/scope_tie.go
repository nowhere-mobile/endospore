package main

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
)

// TYING A PROFILE'S SCOPES TO THE PHONE (docs/tie-scope-keys.md §7-§8; groundwork NWP-20261007-11).
//
// A tie protects the vault and the wallet. Every other scope is sealed under deriveKey(name#scope, pass), so
// whoever guesses the passphrase derives the key himself, and wrapping that key under the chip changes nothing.
// Protecting a scope means a NEW RANDOM key and the content re-sealed under it -- here, from the store: the
// #keys dump and the #sys stage exist only at the end of a session, so nothing on the phone can be re-pushed at
// tie time (§4 step 2, superseded).
//
// Callers: se_tie.go (the tie and the untie), add_device.go (the 12-word path), scope_repoint.go's
// repointScopes (credential change and recovery: scopeTiedHere, scopeKeyFor) and scope_rekey_job.go's
// largeScopeRekeyStep (the re-key job's tie check: scopeTiedHere, scopeVersion).
// The order the caller must keep, crash-safe at every step:
//   1. prepare every scope (prepareScopeRekey): re-sealed blobs, manifests and the new head blob UPLOADED,
//      nothing published. A crash here references nothing.
//   2. publish the vault with rekeyedIndex(...): each scope recorded {Wrapped: K', Prev: K, Minted}. A crash here
//      leaves the scope heads old; the tied phone opens them with K, and recovery finds Prev (scopeKeyFor).
//   3. publishScopeRekeys: each scope head switched, refused if it moved since step 1. A crash between scopes
//      leaves each one either old (Prev verifies) or new (Wrapped verifies).
// All three inside one capWrite bracket (one lease, the profile's own tokens) with the worker slot and the
// session lock held, so no seal interleaves.

// tieSmallScopes are the scopes a tie re-keys at tie time (§5 Q1(b)); #media and #apps follow in the background.
var tieSmallScopes = []string{"#keys", "#sys", "#de"}

// scopeRekey is one prepared re-key: everything uploaded, nothing published.
type scopeRekey struct {
	Suf      string
	WriteRef string // where putHead publishes this scope (headWriteRef)
	WriteOld string // what WriteRef held when prepared; the publish refuses if it moved
	NewHead  string // the re-keyed vault's blob, or "" when this phone already holds the scope tied (nothing to do)
	OldKey   []byte // the key the scope was sealed under; nil for a scope that did not exist
	NewKey   []byte
}

// scopeTiedHere returns the key of a scope vault that this phone's chip opens and no passphrase slot does -- a scope
// that is already protected here -- or nil.
func scopeTiedHere(v *vault, scoped, pass string, se []byte) []byte {
	if v == nil || len(se) == 0 {
		return nil
	}
	for _, s := range v.Slots {
		if s.Kind == "pass" {
			return nil
		}
	}
	return unwrapDK(v, "se", kekSE(scoped, pass, se))
}

// scopeVersion is the version a re-published scope head must carry: above both its own and this phone's rollback
// anchor for the scope, so checkRollback never reads the new head as a replay.
func scopeVersion(scoped, pass string, cur uint64) uint64 {
	if a := readAnchor(profileRefV2(scoped, pass)); a > cur {
		cur = a
	}
	return cur + 1
}

// prepareScopeRekey re-seals one scope under newKey and uploads the result, publishing nothing.
//
// Every chunk the scope names is re-sealed: the live manifest's chunks, its deferred (on-demand) regions, and every
// retained snapshot's (Chester, 2026-10-07: "re-encrypt it too", so a restore can still reach versions from before
// the tie and a passphrase guess opens none of them). seal's nonce is an HMAC of the plaintext under the key, so
// a chunk shared between versions re-seals to one blob and uploads once. A scope that does not exist gets a
// placeholder (an empty archive under newKey), or its first seal would create a passphrase-keyed head. A delete
// tombstone is refused: re-creating a scope the profile deleted is not a tie's to decide.
//
// Must run inside the caller's capWrite bracket in cap mode (postBlob buffers there).
func prepareScopeRekey(base, name, pass, suf string, se, newKey []byte) (rk *scopeRekey, err error) {
	scoped := name + suf
	writeRef, _ := headWriteRef(scoped, pass)
	rk = &scopeRekey{Suf: suf, WriteRef: writeRef, NewKey: newKey}
	err = recovered(func() {
		rk.WriteOld = getRef(base, writeRef)
		_, head, have := headRef(base, scoped, pass)
		if !have {
			head = getRef(base, writeRef)
		}
		var manifest string
		var history []headSnap
		var cur uint64
		if head == "" {
			if refExists(base, writeRef) {
				panic(fmt.Errorf("%s: its ref is a delete tombstone", suf))
			}
			var buf bytes.Buffer
			tw := tar.NewWriter(&buf)
			tw.Close()
			manifest = postBlob(base, seal(newKey, buf.Bytes()))
		} else {
			if ov, isV := parseVault(getHeadBlob(base, head)); isV {
				if k := scopeTiedHere(ov, scoped, pass, se); k != nil {
					rk.NewKey, rk.NewHead = k, "" // already protected on this phone: nothing to re-seal
					return
				}
				rk.OldKey = openVaultDKSE(ov, scoped, pass, se)
				if rk.OldKey == nil {
					panic(fmt.Errorf("%s: no slot opens its head", suf))
				}
				if ov.Sig != "" && !verifyVault(ov, rk.OldKey) {
					panic(fmt.Errorf("%s: its head does not verify", suf))
				}
				manifest, history, cur = ov.Manifest, ov.History, ov.Version
			} else {
				rk.OldKey = deriveKey(scoped, pass) // a bare head IS the manifest, sealed under the passphrase key
				manifest = head
			}
			done := map[string]string{}
			manifest = resealManifest(base, rk.OldKey, newKey, manifest, done)
			resealed := make([]headSnap, len(history))
			for i, sn := range history {
				sn.Manifest = resealManifest(base, rk.OldKey, newKey, sn.Manifest, done)
				resealed[i] = sn
			}
			history = resealed
		}
		nv := &vault{
			V:        1,
			Slots:    []keyslot{{Kind: "se", Wrapped: wrap(kekSE(scoped, pass, se), newKey)}},
			Manifest: manifest,
			History:  history,
			Version:  scopeVersion(scoped, pass, cur),
			Hardened: true,
		}
		signVault(nv, newKey)
		rk.NewHead = postBlob(base, serializeVault(nv))
	})
	if err != nil {
		return nil, err
	}
	return rk, nil
}

// resealManifest re-seals one manifest and every chunk it names under newKey, returning the new manifest's hash.
// done maps an old chunk hash to its re-sealed hash across the whole scope, so a chunk is fetched once. A legacy
// pre-CDC head (the blob is the archive itself) is re-sealed whole. getChunk verifies every fetch against its hash.
func resealManifest(base string, oldKey, newKey []byte, manifestHash string, done map[string]string) string {
	if manifestHash == "" {
		return ""
	}
	pt := unseal(oldKey, getBlob(base, manifestHash))
	if !bytes.HasPrefix(pt, cdcMagic) {
		return postBlob(base, seal(newKey, pt))
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		panic(fmt.Errorf("a manifest decrypts but will not parse: %v", err))
	}
	chunk := func(h string) string {
		if nh, ok := done[h]; ok {
			return nh
		}
		nh := postBlob(base, seal(newKey, unseal(oldKey, getChunk(base, h))))
		done[h] = nh
		return nh
	}
	for i, h := range m.Chunks {
		m.Chunks[i] = chunk(h)
	}
	for rel, d := range m.Deferred {
		cs := make([]string, len(d.Chunks))
		for i, h := range d.Chunks {
			cs[i] = chunk(h)
		}
		d.Chunks = cs
		m.Deferred[rel] = d
	}
	js, err := json.Marshal(m)
	check(err)
	out := make([]byte, 0, len(cdcMagic)+len(js))
	out = append(append(out, cdcMagic...), js...)
	return postBlob(base, seal(newKey, out))
}

// rekeyedIndex returns idx with every prepared scope recorded under its new key and, while the re-key is in flight,
// the key it replaces: {Ref, Wrapped: K', Prev: K, Minted, Observed}. A scope already tied here keeps its key with
// no Prev. idx itself is not modified.
func rekeyedIndex(idx map[string]scopeRec, dk []byte, rks []*scopeRekey) map[string]scopeRec {
	kek := kekScopes(dk)
	next := make(map[string]scopeRec, len(idx)+len(rks))
	for k, v := range idx {
		next[k] = v
	}
	for _, rk := range rks {
		rec := next[rk.Suf]
		rec.Ref = rk.WriteRef
		rec.Wrapped = wrap(kek, rk.NewKey)
		rec.Prev = ""
		if rk.NewHead != "" && rk.OldKey != nil {
			rec.Prev = wrap(kek, rk.OldKey)
		}
		rec.Minted = true
		rec.Observed = true
		next[rk.Suf] = rec
	}
	return next
}

// publishScopeRekeys switches each prepared scope head to its re-keyed vault. Step 3: only after the vault carrying
// rekeyedIndex is published. A head that moved since it was prepared is refused at the flush (expectRef).
func publishScopeRekeys(base, name, pass string, rks []*scopeRekey) {
	for _, rk := range rks {
		if rk.NewHead == "" {
			continue
		}
		capExpect("tie", rk.WriteRef, rk.WriteOld) // disarmed as the tie's bracket ends (NWP-20261009-07)
		putHead(base, name+rk.Suf, pass, rk.NewHead)
		fmt.Fprintf(os.Stderr, "[agent] tie: scope %s re-keyed (NWP-20261007-11)\n", rk.Suf)
	}
}

// untieScopeHeads is the scope half of an untie: each scope this phone holds tied gets a passphrase slot over the
// SAME key and loses its `se` slots. Nothing is re-sealed or re-uploaded -- the key stays random, the index is
// unchanged -- and the scope opens by passphrase again, which is what untie means. Run before the vault's own
// untie, so a crash between the two leaves the vault tied and Untie can simply run again.
func untieScopeHeads(base, name, pass string, se []byte, sufs []string) error {
	return recovered(func() {
		for _, suf := range sufs {
			scoped := name + suf
			writeRef, _ := headWriteRef(scoped, pass)
			writeOld := getRef(base, writeRef) // what the head holds as this edit starts: the value the arm below uses
			_, head, have := headRef(base, scoped, pass)
			if !have {
				head = writeOld
			}
			if head == "" {
				continue
			}
			ov, isV := parseVault(getHeadBlob(base, head))
			if !isV {
				continue
			}
			k := unwrapDK(ov, "se", kekSE(scoped, pass, se))
			if k == nil {
				continue // not tied on this phone: nothing this phone can untie
			}
			kept := make([]keyslot, 0, len(ov.Slots)+1)
			hasPass := false
			for _, s := range ov.Slots {
				if s.Kind == "se" {
					continue
				}
				hasPass = hasPass || s.Kind == "pass"
				kept = append(kept, s)
			}
			if !hasPass {
				kept = append(kept, keyslot{Kind: "pass", Wrapped: wrap(deriveKey(scoped, pass), k)})
			}
			nv := *ov
			nv.Slots, nv.Hardened, nv.Sig = kept, false, ""
			nv.Version = scopeVersion(scoped, pass, ov.Version)
			signVault(&nv, k)
			// Armed at the value the edit started from, as prepareScopeRekey does, so a publish that landed after that
			// read refuses this one (NWP-20261009-07) instead of being overwritten by it (NWP-20261111-15).
			capExpect("untie", writeRef, writeOld)
			putHead(base, scoped, pass, postBlob(base, serializeVault(&nv)))
		}
	})
}

// addScopeSESlots gives this phone's chip a slot on every scope a tie re-keyed (Minted in the index), so a phone
// added through the 12-word path opens the scopes as well as the vault. The key comes from the index, opened with
// the DK this path already holds, and is verified against the head before it is used. Run inside a capWrite.
func addScopeSESlots(base, name, pass string, se, dk []byte, idx map[string]scopeRec) error {
	kek := kekScopes(dk)
	return recovered(func() {
		for _, suf := range scopeIndexSuffixesSorted(idx) {
			rec := idx[suf]
			if !isScopeSuffix(suf) || !rec.Minted {
				continue
			}
			scoped := name + suf
			writeRef, _ := headWriteRef(scoped, pass)
			writeOld := getRef(base, writeRef) // what the head holds as this edit starts: the value the arm below uses
			_, head, have := headRef(base, scoped, pass)
			if !have {
				head = writeOld
			}
			if head == "" {
				continue
			}
			ov, isV := parseVault(getHeadBlob(base, head))
			if !isV {
				continue
			}
			k, ok := scopeKeyFor(base, scopeRec{Ref: writeRef, Wrapped: rec.Wrapped, Prev: rec.Prev}, kek)
			if !ok {
				panic(fmt.Errorf("%s: no recorded key opens its head", suf))
			}
			if unwrapDK(ov, "se", kekSE(scoped, pass, se)) != nil {
				continue // this phone already has its slot
			}
			nv := *ov
			nv.Slots = append(append([]keyslot{}, ov.Slots...), keyslot{Kind: "se", Wrapped: wrap(kekSE(scoped, pass, se), k)})
			nv.Sig = ""
			nv.Version = scopeVersion(scoped, pass, ov.Version)
			signVault(&nv, k)
			// Armed at the value the edit started from, as prepareScopeRekey does, so a publish that landed after that
			// read refuses this one (NWP-20261009-07) instead of being overwritten by it (NWP-20261111-15).
			capExpect("add-device", writeRef, writeOld)
			putHead(base, scoped, pass, postBlob(base, serializeVault(&nv)))
		}
	})
}

// scopeKeyFor returns the recorded key that actually opens the scope head at rec.Ref: Wrapped first, then Prev, the
// key a re-key in flight is replacing. Each is checked against the head itself -- a vault's signature, or a bare
// head's seal -- so a record that describes another state is never used to publish a head nobody can open.
func scopeKeyFor(base string, rec scopeRec, kek []byte) ([]byte, bool) {
	var head string
	if err := recovered(func() { head = getRef(base, rec.Ref) }); err != nil || head == "" {
		return nil, false
	}
	for _, w := range []string{rec.Wrapped, rec.Prev} {
		if w == "" {
			continue
		}
		k, ok := unwrap(kek, w)
		if !ok {
			continue
		}
		if scopeKeyOpens(base, head, k) {
			return k, true
		}
	}
	return nil, false
}

// scopeKeyOpens says whether k is the key of the scope head `head`.
func scopeKeyOpens(base, head string, k []byte) bool {
	opens := false
	_ = recovered(func() {
		blob := getHeadBlob(base, head)
		if ov, isV := parseVault(blob); isV {
			if ov.Sig != "" {
				opens = verifyVault(ov, k)
				return
			}
			_, ml := classifyManifestLoad(base, k, ov.Manifest)
			opens = ml == mlOK || ml == mlNotCDC
			return
		}
		unseal(k, blob)
		opens = true
	})
	return opens
}

// scopeTiedOnThisPhone says whether the scope's head is a vault this phone's chip opens and no passphrase slot does.
// A scope with no head is not tied: after a tie every small scope has one (a placeholder if it was empty).
func scopeTiedOnThisPhone(base, scoped, pass string, se []byte) bool {
	tied := false
	_ = recovered(func() {
		ref, head, have := headRef(base, scoped, pass)
		if !have {
			head = getRef(base, ref)
		}
		if head == "" {
			return
		}
		if ov, isV := parseVault(getHeadBlob(base, head)); isV {
			tied = scopeTiedHere(ov, scoped, pass, se) != nil
		}
	})
	return tied
}
