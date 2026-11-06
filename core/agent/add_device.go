package main

import (
	"errors"
	"fmt"

	"github.com/tyler-smith/go-bip39"
)

// ADDING A SECOND HANDSET TO A HARDENED PROFILE (NWP-20260915-09).
//
// THE PROBLEM. E.3b hardening adds this device's `se` keyslot and DROPS the `pass` slot -- dropping it is the
// whole point, since a captured store ciphertext then has nothing a passphrase alone can open. But kekSE is
// salted with a secret sealed in ONE handset's Titan M2, so a second handset cannot open the vault at all:
// openVaultDK tries pass (gone), then se (the other device's), then fido2, and returns nil. The login shows a
// blank, which blind login makes indistinguishable from a wrong passphrase.
//
// Until now the only way back was recoverVault -- and that made it WORSE, not better. recoverVault rebuilds
// the vault through buildVault, which REPLACES the slot list, so handset B's recovery discards handset A's
// `se` slot and locks A out in turn. Two handsets alternate being locked out indefinitely, each recovery
// evicting the other. That was measured, not reasoned.
//
// THE FIX IS ADDITIVE. The destruction never came from hardening; it came from REBUILDING the vault. So this
// opens the existing vault through its `recovery` slot -- which every vault keeps, hardened or not -- and
// APPENDS this device's slot to the slot list that is already there. No passphrase change, no rebuild, no
// eviction. Handset A keeps working; handset B starts working; a third handset is the same operation again.
//
// ⚠ IT GRANTS NOTHING THE 12 WORDS DID NOT ALREADY GRANT. Anyone holding the mnemonic can already run
// recoverVault and take the profile outright. This is a strictly gentler use of the same secret.
//
// ⚠ AND IT NEEDS THE CURRENT PASSPHRASE TOO, for two reasons that are easy to miss: kekSE is passphrase-bound
// (Argon2id(passphrase, salt=H(name|se_secret))), so the slot cannot be minted without it; and the head is
// published at profileRefV2(name, pass), so a wrong passphrase would write a head where nobody looks. The
// passphrase is verified against the vault before anything is written -- see the ref cross-check below.

// hardenVaultTo appends seSecret's `se` slot to a vault the caller has ALREADY OPENED with dk (v is that read),
// drops every `pass` slot, and publishes.
//
// Shared by both enrol paths so the cap bracket and the refusal check cannot drift apart between them.
//
// ⚠ THE BRACKET IS THE HISTORY HERE, and it moved into this function from enrollSE, so the account of why it
// exists moves with it. In cap mode postBlob's buffered path calls fail() outside a bracket, fail panics,
// daemonVaultOp turns that into an "ERR" reply -- and the chooser DISCARDED that reply. So E.3b hardening
// NEVER HAPPENED on a managed device, which is the entire fielded fleet: every Endospore profile kept its
// `pass` slot with Hardened=false and nothing anywhere said so, falsifying docs/threat-model.md's edition
// claim ("the passphrase is *not* offline-brute-forceable") for the whole fleet rather than merely for
// recovered profiles. That was NWP-20260915-06, and it is the FOURTH member of the family after rotateVault
// (DIA-20260704-35d), recoverVault (NWP-20260915-03) and migrateVault. Pinned by TestCapModeEnrollSE and,
// for the path added here, TestCapModeEnrollSEViaRecovery.
//
// Identity is unchanged by a keyslot edit, so the bracket is under the SAME pass -- the shape of setStoredPIN's capWrite (pin.go),
// not rotation's.
//
// NWP-20261009-07: THE EDIT IS MADE ON THE HEAD READ INSIDE THE BRACKET (capReadVaultForEdit), never on the vault
// the caller read. Made on that one, it put the vault back over anything published while phone B sat in Argon2 --
// phone A's 120 s seal, a PIN change, a revoked security key -- at Version+1, with nothing armed: the head named
// the old Manifest again and a revoked slot came back (NWP-20261111-10). Read under the lock, a seal, PIN or key
// change made between the caller's read and the bracket is kept; a publish another process or device makes after
// that read is refused at the flush and answered "hardening refused at publish". kekSE is Argon2, so it runs once,
// BEFORE the bracket, never under capBracketMu.
//
// Idempotent: if this device's slot already opens the vault there is nothing to add and nothing to drop, so
// it returns without writing. That matters because a re-run would otherwise append a DUPLICATE `se` slot and
// bump Version every time (measured 2 slots -> 3), which turns any repeated call into unbounded growth plus a
// metered store write. The check on the caller's v is a fast path that opens no bracket; the one that decides is
// on the head read inside it, which another run may already have given this slot.
func hardenVaultTo(base, name, pass string, v *vault, dk []byte, seSecret []byte) error {
	kek := kekSE(name, pass, seSecret)
	if unwrapDK(v, "se", kek) != nil {
		return nil // this device already has a slot here
	}
	label := deviceLabel() // NWP-20261114-24: read before the bracket, so no file read or getprop exec runs under it
	// The bracket is under the SAME pass: this changes the keyslots, never the identity, so the head stays at
	// profileRefV2(name, pass) and capFlush meters under the credential the profile already had.
	//
	// ⚠ BUT capWriteNoLogin, BECAUSE ADD-DEVICE IS A GATE VERB WITH NO SESSION. Its dispatch reads
	// name/pass/mnemonic straight off the socket and calls the handler -- unlike SET-PIN and ENROLL-FIDO2,
	// which both refuse with ERR-NOSESSION. So capWalletPath() here is whatever the boot-lifetime tmpfs
	// holds: nothing, or the wallet of a profile that signed off earlier in this boot. Running at the
	// CURRENT credential is what makes that dangerous rather than harmless -- the fold would write it at
	// this profile's LIVE wallet head, not at an orphan, and the ladder would SPEND from it. Nothing is
	// carried here: the credential is not moving, so the right answer is to leave the wallet alone
	// entirely (NWP-20260915-17).
	var perr error
	vd := capWriteNoLogin(name, pass, dk, func() {
		cur, err := capReadVaultForEdit(base, "add-device", name, pass, dk, v.Sig != "")
		if err != nil {
			perr = err
			capAbort()
			return
		}
		if unwrapDK(cur, "se", kek) != nil {
			capAbort() // the head read here already has this device's slot: nothing to write
			return
		}
		cur.Slots = append(cur.Slots, keyslot{Kind: "se", Wrapped: wrap(kek, dk), LabelSealed: sealSlotLabel(dk, label)})
		kept := make([]keyslot, 0, len(cur.Slots)) // harden: drop every pass-only slot
		for _, s := range cur.Slots {
			if s.Kind != "pass" {
				kept = append(kept, s)
			}
		}
		cur.Slots = kept
		cur.Hardened = true
		cur.Version++
		signVault(cur, dk)
		vh := postBlob(base, serializeVault(cur))
		putHeadSingle(base, name, pass, vh) // NWP-20260906-02: the ACCOUNT head, never this unit's
		putRef(base, cur.RecoveryRef, vh)
	})
	if perr != nil {
		return perr
	}
	if vd.Refused() {
		return errors.New("hardening refused at publish: the store did not accept the new head")
	}
	return nil
}

// The refusals the ADD-DEVICE handler has to tell apart, because each sends the user to a DIFFERENT field and
// a single "couldn't add this phone" leaves someone holding a correct recovery code with nowhere to go.
//
// ⚠ NONE OF THEM WEAKENS BLIND LOGIN, and the reasoning is worth keeping because the gate's convention is the
// opposite (buildRecoverScreen says "check the name and recovery code" precisely so it cannot say which):
//   - ErrAddDeviceBadPhrase is decided CLIENT-SIDE, from the words alone. It says nothing about any profile.
//   - ErrAddDeviceNoProfile is the JOINT failure of name AND phrase. It cannot separate "no such name" from
//     "wrong words", so it is not a name oracle.
//   - ErrAddDeviceWrongPass is reachable ONLY by someone who already holds the matching 12 words -- and they
//     can take the profile outright with RECOVER. It tells them nothing they could not already learn.
var (
	ErrAddDeviceBadPhrase = errors.New("invalid recovery phrase")
	ErrAddDeviceNoProfile = errors.New("no profile for that name + phrase")
	ErrAddDeviceWrongPass = errors.New("that passphrase does not match this profile")
)

// enrollSEViaRecovery adds THIS device's secure-element slot to a profile it cannot otherwise open, using the
// 12-word recovery code as the opener instead of the passphrase.
//
// This is the path that makes hardening compatible with "one profile across devices" (product-decisions.md,
// 2026-09-08). It deliberately does NOT call recoverVault: that mints a new passphrase and rebuilds the slot
// list, which is what evicts every other handset.
func enrollSEViaRecovery(base, name, mnemonic, pass string, seSecret []byte) error {
	if len(seSecret) == 0 {
		return errors.New("empty se_secret")
	}
	entropy, err := bip39.EntropyFromMnemonic(mnemonic)
	if err != nil {
		return ErrAddDeviceBadPhrase
	}
	rref := recoveryRef(name, entropy)
	head := getRef(base, rref)
	if head == "" {
		return ErrAddDeviceNoProfile
	}
	// ⚠ THE PASSPHRASE MUST BE THE ONE THIS VAULT IS PUBLISHED UNDER, and this is the check that proves it.
	// The recovery code alone cannot tell us: it resolves the head through ref/<RecoveryRef>, which is keyed
	// on name+entropy and says nothing about the passphrase. Without this cross-check a wrong (but plausible)
	// passphrase would mint a slot under the wrong KEK and publish the head at profileRefV2(name, WRONGpass)
	// -- a ref nobody reads -- leaving the real head untouched and the user staring at a success message.
	if getRef(base, headKey(base, name, pass)) != head {
		return ErrAddDeviceWrongPass
	}
	v, isV := parseVault(getHeadBlob(base, head))
	if !isV {
		return errors.New("profile is not a vault (migrate first)")
	}
	dk := unwrapDK(v, "recovery", kekRecovery(name, entropy))
	if dk == nil {
		return errors.New("recovery slot won't unwrap")
	}
	if err := hardenVaultTo(base, name, pass, v, dk, seSecret); err != nil {
		return err
	}
	return addScopeSlotsAfterEnrol(base, name, pass, v, dk, seSecret)
}

// addScopeSlotsAfterEnrol gives the phone just added a slot on every scope a tie re-keyed (NWP-20261007-11). Without
// it the phone opens the vault but not #de/#sys/#keys: its restore reads them blank and its seals of them fail. A
// profile with no re-keyed scope -- every profile until a tie re-keys one -- costs one index read and nothing else.
func addScopeSlotsAfterEnrol(base, name, pass string, v *vault, dk, seSecret []byte) error {
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		return nil
	}
	minted := false
	for _, rec := range idx {
		minted = minted || rec.Minted
	}
	if !minted {
		return nil
	}
	var err error
	// ADD-DEVICE is a gate verb with no session, so this bracket is no-login exactly as hardenVaultTo's is (its
	// capWriteNoLogin comment, NWP-20260915-17): capWrite folded and spent a departed profile's wallet (NWP-20261114-03).
	vd := capWriteNoLogin(name, pass, dk, func() {
		if err = addScopeSESlots(base, name, pass, seSecret, dk, idx); err != nil {
			capAbort() // a bare return would still flush what was buffered
		}
	})
	if err != nil {
		return fmt.Errorf("this phone opens the profile, but not its protected data: %w", err)
	}
	if vd.Refused() {
		return errors.New("refused at publish: the store did not accept the scopes' new slots")
	}
	return nil
}
