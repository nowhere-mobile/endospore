package main

import (
	"errors"
	"fmt"
	"os"
)

// REPOINTING THE SCOPES (NWP-20260915-02) -- what actually makes a recovered profile whole.
//
// A credential change moves every scope head, because both its LOCATION (profileRefV2(name#scope, pass)) and
// its KEY (deriveKey(name#scope, pass)) are pure functions of the passphrase. rotateVault can survive that by
// brute force, since it holds both passphrases. recoverVault cannot: the whole premise is that the old
// passphrase is gone, so the old heads are not merely undecryptable, they are unfindable.
//
// The scope index closes that: the vault records, sealed under the DK, WHERE each scope head lives and WHAT
// KEY opens it. repointScopes reads that index and re-publishes each head under the new credential.
//
// ⚠ THE DATA IS NEVER RE-ENCRYPTED. The new head is a small vault whose single `pass` slot wraps the
// PRESERVED original scope key under deriveKey(name#scope, NEWpass), and whose Manifest still points at the
// same sealed manifest blob. So a ~600 MB profile costs six small writes, not a re-seal -- the same trick
// that made the NWP-20260906-10 account-directory fix cheap.
//
// ⚠ AND THE NEW HEAD IS OPENED BY AN ORDINARY `pass` SLOT, DELIBERATELY. openVaultDK(v, name, pass) derives
// its candidate key from the name it is handed, and at every scope call site that name is already the SCOPED
// one. So resolveKeyHead, pushProfile, scopeFootprint and scopeManifest all keep working unchanged, from a
// cold `os/exec` agent process that has never seen the profile DK. A slot kind that needed the DK would work
// in recovery and fail silently in scopeFootprint, which leases only the head pointer when it cannot open the
// manifest -- un-leasing every chunk of every scope against the gateway GC.

// ErrScopeTombstoned is returned when a recorded scope ref resolves EMPTY but still EXISTS. An empty-but-
// present ref is a DELETE tombstone, not an unused scope, and the two must never be confused: skipping a
// tombstone silently would publish a profile that reports success while a scope quietly went missing -- the
// same silent-success shape docs/backlog.md records for a seal against a tombstoned head.
var ErrScopeTombstoned = errors.New("scope head is tombstoned")

// buildScopeVault mints the vault that REPLACES a bare scope head under a new credential.
//
// RecoveryRef is deliberately empty: a scope has no 12-word path of its own, and pushProfile already guards
// its recovery-ref write on RecoveryRef != "". Version starts at 0, which is safe because the head lands at a
// ref that has never had a rollback anchor -- readAnchor returns 0, so checkRollback's `ver < anchored` is
// false and it simply anchors at 0; the scope's next ordinary seal bumps it to 1 like any other vault.
//
// It is signed with the SCOPE key, not the profile DK, because that is what openVaultDK returns for this
// vault and therefore what verifyVault will check against.
func buildScopeVault(scopeKey []byte, scoped, newpass, manifestHash string) *vault {
	v := &vault{
		V:        1,
		Slots:    []keyslot{{Kind: "pass", Wrapped: wrap(deriveKey(scoped, newpass), scopeKey)}},
		Manifest: manifestHash,
	}
	signVault(v, scopeKey)
	return v
}

// repointScopes re-publishes every scope named by idx under newpass, and returns the index that describes the
// result -- which the caller must store in the vault it is about to publish.
//
// oldpass is the credential the scopes are moving OFF, or "" when the caller does not have it. Only
// rotateVault can supply it; recovery exists precisely because that passphrase is gone. When it is
// present the scope key is OBSERVED from the head in front of us rather than taken from idx.Wrapped --
// see THE KEY below, which is the whole of NWP-20260915-14 part (ii).
//
// ORDERING, and it is load-bearing. Every new head is written (b, c) and READ BACK (d) before the caller
// publishes the bare vault (e). Because recoverVault writes the recovery ref last, a failure anywhere before
// (e) leaves the OLD vault and its OLD index authoritative, and a re-run is idempotent: the old scope heads
// were never touched.
//
// ⚠ IT NEVER RETIRES AN OLD SCOPE REF, and that is a deliberate divergence from the first draft of this plan,
// which ended with a tombstone loop mirroring rotateVault's. A crash between tombstoning the old ref and
// publishing the new one would leave that scope named by nothing under EITHER passphrase -- unrecoverable,
// for a saving of one small object. The superseded refs simply stop being named by profileFootprint and age
// out; the manifest blobs they pointed at stay leased by the new heads, because they are content-addressed.
// se is this phone's secure-element secret, or nil (recovery). NWP-20261007-11: a scope a tie re-keyed carries an
// `se` slot and no pass slot; with se the old head opens through it, and the new head is published `se`-only under
// newpass with its history kept, so a passphrase change does not silently untie it. Without se (recovery) the key
// comes from the index and the head gets a pass slot -- a recovered profile comes back untied (2026-10-06).
func repointScopes(base, name string, idx map[string]scopeRec, newpass string, dk []byte, oldpass string, se []byte) (map[string]scopeRec, []string, error) {
	kek := kekScopes(dk)
	next := make(map[string]scopeRec, len(idx))
	written := map[string]string{} // new ref -> the blob hash we published, for the read-back in (d)
	// superseded collects the OLD ref of every scope whose head this call actually MOVED -- never a
	// scope that was absent, and never one whose address did not change. The caller retires these
	// AFTER its publish lands (NWP-20260916-04); see THE RETIREMENT below for why they cannot simply
	// be tombstoned here.
	var superseded []string

	for _, suf := range scopeIndexSuffixesSorted(idx) {
		// NWP-20260917-04: the billing record is not a scope. RE-DERIVE it for the new credential and move
		// on -- nothing is read, nothing is published, and nothing joins `superseded`. Doing it here rather
		// than at the two callers means BOTH credential changes advance the record in one place, so a
		// recovery that follows a rotation names the post-rotation key and not a stale one.
		if !isScopeSuffix(suf) {
			continue // the reserved keys (billing and SSAID records) are set below, from the PRE-change index
		}
		scoped := name + suf
		newRef, _ := headWriteRef(scoped, newpass)
		rec := idx[suf]

		// A scope that was never sealed has nothing to move. Record a fresh entry so the index stays complete
		// for the NEXT credential change, and move on.
		fresh := scopeRec{Ref: newRef, Wrapped: wrap(kek, deriveKey(scoped, newpass))}
		if scopeSealedUnderDK(suf) {
			fresh.Wrapped = "" // see scopeRec: a DK-sealed head has no scope key to record
		}
		if rec.Ref == "" {
			next[suf] = fresh
			continue
		}

		// ⚠ #wallet IS IN THE INDEX BUT MUST NOT BE RE-POINTED AS A SCOPE, and the reason is a shape
		// mismatch rather than a policy. Every other scope head is a manifest sealed under a SCOPE key, which
		// is what buildScopeVault wraps. The wallet head is a blob sealed under the PROFILE DK (doFold and
		// sealWalletDurable both use it) and every reader -- readStoredWallet, readStoredWalletStrict -- does a plain
		// unseal with that DK. Publishing a scope vault there produces an object they answer nil to, silently,
		// and the balance reads as zero. In cap mode doFold happened to overwrite it in the same flush, so the
		// damage only ever showed on the direct path; relying on that is not a design. Recording the new
		// LOCATION and publishing nothing is right: the fold writes the real wallet at exactly this ref.
		// Carrying the wallet across a credential change is its own problem -- docs/backlog.md NWP-20260915-17.
		if scopeSealedUnderDK(suf) {
			next[suf] = fresh
			continue
		}

		// (a) read and classify the old head.
		oldHead := getRef(base, rec.Ref)
		if oldHead == "" {
			// THE TOMBSTONE TEST: an empty-but-present ref is a DELETE TOMBSTONE, and it is only evidence of a
			// loss if somebody actually SAW a scope at that address. Otherwise it is ordinary history --
			// deleteProfile tombstones all seven suffixes and nothing ever clears them, so every re-created
			// profile in the field sits on them forever.
			//
			// ⚠ IT USED TO TEST `rec.Wrapped != ""`, AS A PROXY FOR "SOMEBODY WROTE THIS DOWN", AND THAT PROXY
			// WAS WRONG IN BOTH DIRECTIONS (NWP-20260915-18). deriveScopeIndex records Wrapped for every
			// suffix whether or not the scope exists, and createVault mints exactly that index over refs its
			// own purge has just tombstoned -- so a re-created profile refused here on ROTATION and on
			// RECOVERY, and recovery answers only OK or BLANK, which told a user holding a CORRECT twelve-word
			// phrase that it was wrong, after they had already lost a handset. repointScopes then wrote
			// `fresh` for a never-sealed scope WITH Wrapped, so a profile acquired the same false evidence
			// about itself at every credential change.
			//
			// So the test is now the fact it always meant to be: did anyone OBSERVE a head here. Set by
			// deriveScopeIndex when the head resolved at mint time, and below when this very call read one.
			// Absent means derived, which is what every index already in the field is.
			//
			// ⚠ THIS IS NARROWER THAN THE OLD TEST AND THAT IS DELIBERATE, NOT A SIDE EFFECT. A scope lost
			// before the profile ever recorded an observation of it now passes silently. That case and a
			// re-created profile are INDISTINGUISHABLE at the ref level -- both are empty-but-present at a
			// derived address -- so one of them has to give, and refusing was the wrong choice: it turned a
			// rare true positive into a systematic false one that bricked the recovery path for every profile
			// that had ever been deleted and re-created. The guard still fires, loudly, for the case it was
			// written for. (#wallet never reaches here at all: scopeSealedUnderDK returns above.)
			if rec.Observed && refExists(base, rec.Ref) {
				return nil, nil, fmt.Errorf("%w: %s (ref %s) -- refusing to publish a profile whose scope was "+
					"deleted out from under it", ErrScopeTombstoned, suf, short(rec.Ref))
			}
			next[suf] = fresh // absent, or a tombstone at a ref we merely derived: nothing to move either way
			continue
		}
		// A scope head is a BARE head, so the head value IS the sealed manifest. Unless this profile has been
		// re-pointed before, in which case it is already a vault and its Manifest is what we carry forward.
		manifest := oldHead
		ov, isVault := parseVault(getHeadBlob(base, oldHead))
		if isVault {
			manifest = ov.Manifest
		}

		// THE KEY -- OBSERVED WHEN WE CAN, RECORDED WHEN WE CANNOT (NWP-20260915-14).
		//
		// The index is a RECOVERY artifact. Its header says why the ref is written down verbatim: recovery
		// has no old passphrase, so a scope head is "not merely undecryptable: UNFINDABLE". None of that
		// reasoning reaches a ROTATION, which is handed both passphrases -- and the head itself answers the
		// same question more reliably than the record does, because the two shapes are distinguishable:
		//   bare head  -> the key IS deriveKey(scoped, oldpass); that is what sealed it, and the ref we
		//                 found it at is itself derived from oldpass, so no other passphrase can be right.
		//   vault head -> already re-pointed once; buildScopeVault wraps the PRESERVED key under an
		//                 ordinary pass slot, so openVaultDK returns it, and nil says plainly that it did
		//                 not -- an authenticated check the recorded path does not get.
		//
		// ⚠ WHY THIS IS NOT MERELY TIDIER. main.go's MINT-IF-ABSENT note warns that deriving a scope key
		// blind is correct ONLY while the head is still bare: once re-pointed, deriveKey(scoped, pass) is the
		// KEK that opens the wrapper, NOT the key inside it. An absent index looks like a safe proxy for
		// "never re-pointed" and is not one -- vault carries Scopes as an ordinary JSON field, parseVault
		// ignores unknown fields, and an OLDER build therefore strips the index on its next bare seal and
		// re-signs a vault that verifies. On a staged rollout two handsets share one profile across that
		// gap. Looking at the head is right in both states; deriving blind would publish a head wrapping a
		// KEK where the key belongs, and the damage would surface one credential change later.
		var scopeKey []byte
		tiedHere := false
		if oldpass != "" {
			if isVault {
				scopeKey = openVaultDKSE(ov, scoped, oldpass, se)
				tiedHere = scopeTiedHere(ov, scoped, oldpass, se) != nil
			} else {
				scopeKey = deriveKey(scoped, oldpass)
			}
		}
		if scopeKey == nil {
			// No oldpass (recovery), or a vault head that oldpass did not open. Fall back to the record, which
			// is the only path recovery ever had -- and refuse loudly if that fails too, rather than publishing
			// a head nobody can open.
			// NWP-20261007-11: Wrapped, or Prev while a tie's re-key is in flight -- whichever verifies against the
			// head actually in front of us (scopeKeyFor), never a record taken on trust.
			k, ok := scopeKeyFor(base, rec, kek)
			if !ok {
				return nil, nil, fmt.Errorf("scope %s: no key opens its head -- neither the passphrase it was sealed "+
					"under nor the profile-DK record, so re-pointing would publish a head nobody can open", suf)
			}
			scopeKey = k
		}

		// (b) publish the new head blob, then (c) point the new ref at it. Old ref untouched.
		nv := buildScopeVault(scopeKey, scoped, newpass, manifest)
		if tiedHere {
			// Still tied: this phone's slot under the new passphrase, no pass slot, and the history a tie paid to
			// re-seal carried with it.
			nv = &vault{V: 1, Slots: []keyslot{{Kind: "se", Wrapped: wrap(kekSE(scoped, newpass, se), scopeKey)}},
				Manifest: manifest, History: ov.History, Version: ov.Version + 1, Hardened: true}
			signVault(nv, scopeKey)
		}
		vh := postBlob(base, serializeVault(nv))
		putRef(base, newRef, vh)
		written[newRef] = vh
		// Observed: this arm ran because getRef returned a head and we opened it. That is the observation
		// the tombstone test above is looking for, and it is the only place one is made during a
		// credential change -- `fresh` above stays derived, deliberately, because a scope that was never
		// sealed is exactly what nobody has seen (NWP-20260915-18).
		next[suf] = scopeRec{Ref: newRef, Wrapped: wrap(kek, scopeKey), Observed: true, Minted: rec.Minted} // the PRESERVED key, never re-derived
		// ⚠ ONLY HERE, and only when the address really moved. This arm is the one that published a
		// new head from a head it actually read, so rec.Ref names a live object that is now superseded.
		// The `newRef == rec.Ref` guard is not theoretical bookkeeping: retiring a ref we had just
		// written to would delete the head this call exists to create.
		if rec.Ref != "" && rec.Ref != newRef {
			superseded = append(superseded, rec.Ref)
		}
		fmt.Fprintf(os.Stderr, "[agent] repoint %s: %s -> %s\n", suf, short(rec.Ref), short(newRef))
	}

	// (d) read every new ref back before the caller commits the vault that points at them. A head that did
	// not land must fail the whole operation LOUDLY: the alternative is a recovery that reports success and
	// leaves a scope unreachable, which is the exact failure this slice exists to remove.
	//
	// ⚠ DIRECT MODE ONLY, AND NOT AS AN OPTIMISATION. In cap mode these writes are still BUFFERED -- refs sit
	// in RAM and blobs in a spill file until capFlush (capBufferPut), and no read path consults either -- so
	// reading them back inside the bracket would report every single one as missing and turn a correct
	// recovery into a hard failure. Cap mode has its own, stronger check at the moment the bytes actually
	// land: capPut sends Content-MD5 and compares the store's returned ETag against it, failing with "the
	// store wrote CORRUPT bytes (torn PUT)". Its failures are loud (fail -> panic out of capWrite), and the
	// caller additionally refuses on sealFenceHit/sealStaleHit.
	if !capMode() {
		for ref, want := range written {
			if got := getRef(base, ref); got != want {
				return nil, nil, fmt.Errorf("re-pointed scope head did not land: ref %s reads %q, wrote %q",
					short(ref), short(got), short(want))
			}
		}
	}
	// NWP-20261008-03: a background re-key in flight carries across a credential change. Its K' is wrapped under the
	// DK, which a credential change does not touch, and the job re-reads the scope head every batch, so the work done
	// so far stays valid; dropping it here would only make the job start again and pay for its uploads twice.
	for suf, rec := range idx {
		if rec.Next == "" || !isScopeSuffix(suf) {
			continue
		}
		if n, ok := next[suf]; ok {
			n.Next, n.Progress = rec.Next, rec.Progress
			next[suf] = n
		}
	}
	// NWP-20260917-04/-07: the billing record advances to the new credential, and the key it moved OFF is
	// kept as !bill-prev so a failed carry can be RETRIED at a later login. Set from `idx` (the PRE-change
	// index) rather than derived, so a rotation that follows a failed rotation does not overwrite the key
	// that still holds the plan with one that never did.
	//
	// ⚠ ONLY WHEN THERE IS SOMETHING TO CARRY. An index with no !bill entry yet (a profile that has
	// not sealed under a build carrying -04) gets no !bill-prev either: recording an empty previous key
	// would make every later login attempt a carry it can never name.
	next[scopeBillKey] = billKeyRec(name, newpass)
	// ⚠⚠ NWP-20260917-16: AN OUTSTANDING RECORD WINS OVER THE CURRENT KEY, AND THE COMMENT
	// ABOVE ASSERTED THIS BEFORE THE CODE DID IT. The previous line read `billKeyOf(idx)`, which is
	// idx[!bill] -- the key of the change that just happened -- not idx[!bill-prev], which is where a
	// key whose carry has NOT settled actually lives. `next` is a fresh map, so the old record was
	// dropped rather than kept.
	//
	// Cost of that, exactly: plan on key A. Change A->B with the gateway down -- the carry fails and
	// the record correctly says A. Change B->C before any login can retry -- the record became B,
	// which never held the plan, and **A is now named by nothing in the tree**. The grant is stranded
	// at a key nobody can produce, which is the precise loss NWP-20260917-07 was written to prevent.
	// Real money, and silent.
	//
	// ⚠ The two keys are NOT interchangeable and the order matters: carry A first, because only
	// A can still hold a live grant. ~~B is discarded deliberately~~ -- SUPERSEDED by NWP-20261103-01
	// (Q147): B is kept in !bill-mid. A->B whose reply was lost leaves the plan at B while the record
	// says A, and B->C inside the gateway's cooldown is refused, so a chain does NOT leave only one key
	// that can hold a grant. The retry asks A and every mid key; the cost is one /rebind per outstanding
	// key per sign-in until settled. Every key is the profile's own, recomputable by anyone who knew
	// that passphrase, sealed under the DK.
	newBill := profileRefV2(name, newpass)
	if prev := billPrevOf(idx); prev != "" {
		// NWP-20261103-05 (Q147): an outstanding record keeps its OWN time -- the move it names started then.
		next[scopeBillPrevKey] = scopeRec{Ref: billRefPrefix + prev, At: idx[scopeBillPrevKey].At} // still unsettled: keep naming it
		// The existing mid list is carried explicitly (`next` is fresh), plus the key this change moves off.
		var mid []string
		add := func(k string) {
			if !isContentHash(k) || k == prev || k == newBill {
				return
			}
			for _, m := range mid {
				if m == k {
					return
				}
			}
			mid = append(mid, k)
		}
		for _, k := range billMidOf(idx) {
			add(k)
		}
		add(billKeyOf(idx))
		if len(mid) > billRetagMax {
			mid = mid[len(mid)-billRetagMax:]
		}
		if len(mid) > 0 {
			next[scopeBillMidKey] = billMidRec(mid)
		}
	} else if prev := billKeyOf(idx); prev != "" {
		next[scopeBillPrevKey] = scopeRec{Ref: billRefPrefix + prev, At: planMovingNow()} // NWP-20261103-05: stamped when recorded
	}
	// NWP-20261009-02: an OUTSTANDING re-tag list survives the change too -- `next` is a fresh map, so
	// without this a second credential change before any full-footprint lease would drop the key the
	// first one recorded, and rows still tagged with it could never be re-tagged. The key this change
	// moves off is NOT added here: only the caller knows it (a rotation derives it, a recovery reads it
	// from !bill), and it pushes it with billRetagPush.
	//
	// ⚠ MINUS THE KEY THE PROFILE IS MOVING TO. A change back to an earlier passphrase (A->B->A) finds A
	// still outstanding; carried as is, the record would name the profile's own key, and the gateway
	// refuses every lease that does as 400 `bad prior` -- every seal, every renewal, every delete, with no
	// renewal ever landing to clear it.
	var carry []string
	for _, k := range billRetagOf(idx) {
		if k != newBill {
			carry = append(carry, k)
		}
	}
	if len(carry) > 0 {
		next[scopeBillRetagKey] = billRetagRec(carry)
	}
	// NWP-20261122-12 (Q026): the SSAID userkey record is CARRIED VERBATIM from the pre-change index, never
	// re-derived: it exists to outlive the passphrase that derived it, and `next` is a fresh map, so without
	// this line every rotation and every recovery would drop it.
	if uk := ssaidOf(idx); uk != "" {
		next[scopeSsaidKey] = ssaidRec(uk)
	}
	return next, superseded, nil
}

// rescueScopeIndex builds the index a rotation needs for a vault that carries none.
//
// ⚠ IT RECORDS LOCATIONS ONLY, AND THAT IS THE POINT. Wrapped is left empty, so repointScopes takes
// every key by observation from the head it fetches anyway (see THE KEY above). Minting real Wrapped
// values here would mean deriving them blind from oldpass, which is exactly the KEK-for-key hazard
// main.go's MINT-IF-ABSENT note describes -- and it would be pure guesswork, since the whole reason
// we are here is that nothing recorded what those keys are.
//
// headRef, not headWriteRef: it resolves the per-unit and legacy fallbacks that a write-ref cannot see,
// and in cap mode it returns the value from the same probe. A suffix that resolves nowhere yields the
// write ref with no value, which repointScopes reads as "never sealed" and records fresh -- and a ref
// that exists but reads EMPTY is a delete tombstone, which it still refuses loudly (ErrScopeTombstoned).
//
// Cost: six Argon2id passes at oldpass plus six ref probes, ~0.5s against the 75s ROTATE deadline.
func rescueScopeIndex(base, name, oldpass string, dk []byte) map[string]scopeRec {
	idx := make(map[string]scopeRec, len(scopeIndexSuffixes))
	for _, suf := range scopeIndexSuffixes {
		ref, _, _ := headRef(base, name+suf, oldpass)
		idx[suf] = scopeRec{Ref: ref}
	}
	// A rescue still leaves the NEXT recovery a billing record (NWP-20260917-04). oldpass is right here:
	// this is the index as it stands BEFORE the re-point, and repointScopes advances it to newpass.
	idx[scopeBillKey] = billKeyRec(name, oldpass)
	return idx
}
