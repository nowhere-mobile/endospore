package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/hkdf"
)

// Remembered session PIN (#81 item 3; docs/credential-tiers.md "remembered PIN"). The PIN is a LOCAL
// convenience credential, NOT the roaming secret:
//
//	WARM glance-unlock (screen off -> wake, within the idle window): the PIN ALONE, armed as the Android
//	keyguard credential -> hardware-throttled by Gatekeeper/Weaver, the standard phone-unlock model. Low
//	entropy is fine because it's throttled, not offline-attackable.
//	COLD resume (idle 15min+ / manual lock, same device): PIN + security key -- coldCredPIN below.
//	FRESH gate login (new device / after power-off / 12h wipe): passphrase (+ key) -- the roaming secret is
//	IRREDUCIBLE; a low-entropy PIN can never guard a world-readable store.
//
// So the PIN is never a DK-unwrapping keyslot (that would make DK offline-brute-forceable from a store
// dump). Instead it's stored SEALED under the vault DK (v.Pin): only someone who ALREADY opened the vault
// (passphrase [+ key]) can read it, so it roams safely and reveals nothing to a store dump. It's set once
// and decrypted + armed after each pass(+key) login. Sub-slice 1 is the storage + derivation primitives;
// the login-stash / keyguard-arm / cold-lock wiring lands in later sub-slices.

const pinMinLen, pinMaxLen = 4, 16 // >=4 for the OS keyguard credential; <=16 for its max length

// pinFloor accepts a plausible local PIN: 4-16 DIGITS. The entropy FLOOR against the world-readable store is
// the roaming passphrase's job (#79); this local, hardware-throttled factor only needs to be a real PIN.
func pinFloor(pin string) bool {
	if len(pin) < pinMinLen || len(pin) > pinMaxLen {
		return false
	}
	for _, r := range pin {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// setPinOnVault seals the PIN under dk into v.Pin (in memory; the caller writes the head, cap-bracketed).
// An empty pin CLEARS it. A non-empty pin must pass the floor.
func setPinOnVault(v *vault, dk []byte, pin string) error {
	if pin == "" {
		v.Pin = ""
		return nil
	}
	if !pinFloor(pin) {
		return errors.New("PIN must be 4-16 digits")
	}
	v.Pin = base64.StdEncoding.EncodeToString(seal(dk, []byte(pin)))
	return nil
}

// vaultPIN decrypts the stored PIN with dk. "" if none set or it doesn't decrypt (defensive: a tampered /
// wrong-key blob reads as no-PIN rather than crashing).
func vaultPIN(v *vault, dk []byte) string {
	if v.Pin == "" {
		return ""
	}
	blob, err := base64.StdEncoding.DecodeString(v.Pin)
	if err != nil {
		return ""
	}
	var pt []byte
	func() {
		defer func() { recover() }() // unseal fail()s on a bad blob -> treat as no-PIN
		pt = unseal(dk, blob)
	}()
	return string(pt)
}

// coldCredPIN derives the COLD-lock keyguard/FBE credential for the PIN model: HKDF(Argon2(name,PIN) || hmac)
// truncated to 16 hex chars (Android keyguard max length; 64 bits, Gatekeeper-throttled on-device). The key
// hmac dominates the entropy (the PIN is the throttled second factor), and cold-lock PURGES the hmac, so the
// credential is uncomputable without the physical key at resume. Same shape/domain as sessionCred (so a
// non-2FA PIN profile with no hmac degrades to Argon2(name,PIN)) -- just the PIN in place of the passphrase.
// The WARM keyguard credential is the RAW PIN (the user types it, Gatekeeper verifies) -- NOT this.
func coldCredPIN(name, pin string, hmacOut []byte) string {
	return coldCredFromKey(deriveKey(name, pin), hmacOut)
}

// coldCredFromKey is coldCredPIN over an ALREADY-derived K = Argon2(name, secret). A resume derives K once,
// uncached, and needs both the credential and the wrap key from it (NWP-20260924-01), so the derivation is
// split out rather than paid twice. Byte-identical to coldCredPIN for the same K.
func coldCredFromKey(k, hmacOut []byte) string {
	ikm := make([]byte, 0, len(k)+len(hmacOut))
	ikm = append(ikm, k...)
	ikm = append(ikm, hmacOut...)
	r := hkdf.New(sha256.New, ikm, []byte("nowhere-session-cred-v1"), nil)
	out := make([]byte, 8)
	if _, err := io.ReadFull(r, out); err != nil {
		panic(err) // hkdf over a fixed reader never short-reads
	}
	return hex.EncodeToString(out)
}

// coldWrapKey derives the 32-byte key that seals the PASSPHRASE for cold-lock recovery (#81 item 3/4). At
// cold-lock the roaming passphrase (needed to SEAL after resume) isn't something the user re-types when they
// unlock with a PIN -- so it's cached locally, sealed under this key = HKDF(Argon2(name,unlockSecret) ||
// hmac). A PIN(+key) resume recomputes the key from the typed PIN (+ re-asserted hmac) and recovers the
// passphrase. Same factors as coldCredPIN (so a wrong PIN / wrong key can't decrypt it), a distinct info
// string, full 32 bytes for AES-256. NWP-20260924-01: used for EVERY session now, not only PIN ones -- the
// sealed passphrase is also the resume PROOF (coldResumeProof), and a no-PIN session needs one too.
func coldWrapKey(name, unlockSecret string, hmacOut []byte) []byte {
	return coldWrapKeyFromKey(deriveKey(name, unlockSecret), hmacOut)
}

// coldWrapKeyFromKey is coldWrapKey over an already-derived K; see coldCredFromKey.
func coldWrapKeyFromKey(k, hmacOut []byte) []byte {
	ikm := make([]byte, 0, len(k)+len(hmacOut))
	ikm = append(ikm, k...)
	ikm = append(ikm, hmacOut...)
	r := hkdf.New(sha256.New, ikm, []byte("nowhere-cold-passwrap-v1"), nil)
	out := make([]byte, 32)
	if _, err := io.ReadFull(r, out); err != nil {
		panic(err)
	}
	return out
}

// coldResumeProof checks a resume entry against the marker's line 6, INDEPENDENTLY of the CE (NWP-20260924-01).
//
// ⚠⚠ WHY THIS EXISTS: roamd's verify op used `ls /data/user/N/android` as its ground truth, and ANY entry passes
// that while the CE is still readable -- the window before eviction, and indefinitely under EVICT-INCOMPLETE. The
// wrong entry then became the session's passphrase, and the next seal published the owner's data as a NEW
// profile at (name, entry): readable by whoever typed it, on any Nowhere device. Line 6 is
// AES-GCM(coldWrapKey(name, unlockSecret, hmac), passphrase) for every session, and the GCM tag authenticates:
// only the right unlock secret (and, keyed, the right hmac) opens it. For a PIN session the plaintext is the
// passphrase the resume needs; for a no-PIN session the unlock secret IS the passphrase, so it must also equal
// the entry. It returns the passphrase and true, or "" and false -- NEVER the entry on a failure: the old
// fallback that took the entry as the passphrase was the other half of the same hole.
func coldResumeProof(k, hmacOut []byte, entry string, hasPin bool, wrap string) (string, bool) {
	blob, err := base64.StdEncoding.DecodeString(wrap)
	if err != nil || len(blob) == 0 {
		return "", false
	}
	var pt []byte
	func() {
		defer func() {
			if recover() != nil { // unseal panics on a bad tag: that IS the wrong-entry answer
				pt = nil
			}
		}()
		pt = unseal(coldWrapKeyFromKey(k, hmacOut), blob)
	}()
	if len(pt) == 0 {
		return "", false
	}
	if !hasPin && subtle.ConstantTimeCompare(pt, []byte(entry)) != 1 {
		return "", false
	}
	return string(pt), true
}

// resumeDecoyCred is what an UNPROVEN resume entry sends to the keyguard in its place: 16 random decimal
// digits, which Gatekeeper accepts as the shape of either a PIN or a password and rejects as a value. Sending
// it keeps every attempt costing exactly one hardware-throttled evaluation, so the proof above never becomes an
// unthrottled offline guessing oracle -- and a wrong entry itself never rides `cmd`'s argv. "" if the random
// source fails, which the caller refuses on.
func resumeDecoyCred() string {
	out := make([]byte, 0, 16)
	buf := make([]byte, 32)
	for len(out) < 16 {
		if _, err := rand.Read(buf); err != nil {
			return ""
		}
		for _, b := range buf {
			if b < 250 && len(out) < 16 { // rejection sampling: 250 = 25*10, so every digit is equally likely
				out = append(out, '0'+b%10)
			}
		}
	}
	return string(out)
}

// setStoredPIN opens the profile's vault (passphrase [+ the session's cached key hmac] via the full ladder),
// seals the PIN under DK, and writes the head -- cap-bracketed in managed mode (every store write must ride
// capBegin/capFlush; DIA-20260704-35d). An empty pin removes it. The DK is unchanged, so the PIN survives a
// passphrase rotation and key add/remove for free (all keep the same DK). Returns "no such profile / wrong
// passphrase" style errors for a bad open.
func setStoredPIN(base, name, pass, pin string, se []byte) error {
	if pin != "" && !pinFloor(pin) {
		return errors.New("PIN must be 4-16 digits")
	}
	hd, v, isV := readVaultHead(base, name, pass) // to open the DK: the edit itself re-reads inside the bracket
	if hd.val == "" {
		return errors.New("wrong passphrase / no profile")
	}
	if !isV {
		return errors.New("profile is not a vault (migrate first)")
	}
	dk := openVaultDKSE(v, name, pass, se) // pass -> secure element -> fido2 (#81)
	if dk == nil {
		return errors.New("no slot opens (sign in with your passphrase + key first)")
	}
	// NWP-20261009-07: THE EDIT IS MADE ON THE HEAD READ INSIDE THE BRACKET. Made on the one read above, it put
	// that vault back over anything published while SET-PIN waited for the lock -- a background re-key batch
	// is the usual one -- and the result was never consulted, so it answered OK over a write the store had
	// refused. Re-read under the lock there is nothing in this process to conflict with; a refusal that is left
	// (another process or device) answers ERR, the handler's existing failure reply.
	var perr error
	if capWrite(name, pass, dk, func() { // paid write in managed mode; identity unchanged (pass stays the pass)
		cur, err := capReadVaultForEdit(base, "PIN change", name, pass, dk, v.Sig != "")
		if err == nil {
			err = setPinOnVault(cur, dk, pin)
		}
		if err != nil {
			perr = err
			capAbort()
			return
		}
		cur.Version++
		signVault(cur, dk)
		vh := postBlob(base, serializeVault(cur))
		putHead(base, name, pass, vh)
		if cur.RecoveryRef != "" {
			putRef(base, cur.RecoveryRef, vh)
		}
		syncAccountKeyslots(base, name, pass, dk, cur) // NWP-20260906-10: the PIN is identity, so it travels
	}).Refused() {
		return errors.New("refused at publish: the store did not accept the new head")
	}
	return perr
}

// stashSessionPIN mirrors the fido2 hmac stash (DIA-20260704-29): the decrypted PIN is cached in the RAM
// tmpfs (dest/.sessionpin, 0600, gone on power-off/reap) at login / set-PIN, so the keyguard armer and the
// cold-lock derive from it WITHOUT a store round-trip. An empty pin removes the stash.
func stashSessionPIN(dest, pin string) {
	p := filepath.Join(dest, ".sessionpin")
	if pin == "" {
		os.Remove(p)
		return
	}
	// NWP-20261005-10: write-then-rename. GET-SESSION-PIN and ARM-PIN now run outside sessionMu, so a reader can
	// land mid-write; a truncated-then-written file would read as "no PIN" and arm the passphrase.
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(pin), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] session PIN stash failed: %v\n", err)
		os.Remove(tmp)
		return
	}
	if err := os.Rename(tmp, p); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] session PIN stash failed: %v\n", err)
		os.Remove(tmp)
	}
}

// sessionPIN reads the stashed session PIN ("" when none).
func sessionPIN(dest string) string {
	b, err := os.ReadFile(filepath.Join(dest, ".sessionpin"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// storedPIN returns the profile's stored PIN (decrypted under DK), or "" if none / can't open. The gate uses
// it after a pass(+key) login to arm the warm keyguard + derive the cold credential.
// ⚠ se: NWP-20260915-12. Without it this returned "" on every hardened profile, and stashSessionPIN
// then REMOVES the stash rather than leaving a stale one -- so the remembered-PIN tier was silently
// dead on the edition it was built for. Not a lockout: both the warm armer and the cold resume fall
// back to the full passphrase, and they agree about it, so nothing wedges.
// A failed store read PANICS, as it always has; storedPINErr is the form that returns it.
func storedPIN(base, name, pass string, se []byte) string {
	pin, err := storedPINErr(base, name, pass, se)
	if err != nil {
		panic(err)
	}
	return pin
}

// storedPINErr is storedPIN with the two "" answers told apart (NWP-20261011-25): ("", nil) is a profile with no
// head, a legacy (non-vault) head, a vault this caller cannot open, or no PIN set; ("", err) is a store read that
// FAILED. Before this the roam-in stash called storedPIN inside a bare recover(), so a store blip cost the
// session its remembered PIN with no log line, and nothing could tell that from a profile that never set one.
//
// ⚠ NO RETRY OF ITS OWN, deliberately. The reads below already retry: in cap and direct-S3 mode getRef goes
// through capGet/s3Get, which run retryStore (5 attempts) and panic via checkRead only after the last one, and
// getHeadBlob refetches a corrupt head 3 times over getBlob's own retried read. Wrapping this in retryStore
// would multiply that worst case by 5, inside the synchronous roam-in reply the gate is waiting on. The http
// dev store has no retry at all (a transport error panics at once); that is a test backend, not a field one.
// vaultPIN's own recover() is not a read: it guards only the local unseal of a blob already in memory.
func storedPINErr(base, name, pass string, se []byte) (pin string, err error) {
	defer func() {
		if r := recover(); r != nil {
			pin = ""
			if e, ok := r.(error); ok {
				err = e
			} else {
				err = fmt.Errorf("%v", r)
			}
		}
	}()
	head := getRef(base, headKey(base, name, pass))
	if head == "" {
		return "", nil
	}
	v, isV := parseVault(getHeadBlob(base, head))
	if !isV {
		return "", nil
	}
	dk := openVaultDKSE(v, name, pass, se)
	if dk == nil {
		return "", nil
	}
	return vaultPIN(v, dk), nil
}

// stashRoamInPIN is the roam-in's remembered-PIN stash (#81 item 3, DIA-20260704-40): decrypt the PIN sealed in
// the head and stash it, so the keyguard armer and the cold-lock use it without a store read. A profile with no
// PIN clears any stale stash, so a later session cannot inherit one (the fido2 hmac rule).
//
// ⚠ A FAILED READ CLEARS THE STASH TOO, and says so (NWP-20261011-25). Clearing is the fail-closed direction: the
// session arms the full passphrase, and a new session must never inherit a previous profile's PIN. What changed
// is that it is no longer silent, and that it now runs at all -- under the old bare recover() a panicking read
// unwound past stashSessionPIN, so the PREVIOUS stash survived. The line carries no name, no PIN and no store key
// (logSafeStoreErr); the stored PIN itself is untouched, so the next sign-in reads it again.
func stashRoamInPIN(dest, base, name, pass string, se []byte) {
	pin, err := storedPINErr(base, name, pass, se)
	if err != nil {
		stashSessionPIN(dest, "")
		fmt.Fprintf(os.Stderr, "[logind] roam-in: remembered-PIN read FAILED after retries (%s) -- this session arms "+
			"the passphrase; the stored PIN is untouched\n", logSafeStoreErr("session PIN", err))
		return
	}
	stashSessionPIN(dest, pin)
}
