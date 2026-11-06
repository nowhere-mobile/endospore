package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/crypto/hkdf"
)

// FIDO2 as a vault keyslot (#81, credential-tiers P3; docs/credential-tiers.md tier 2).
//
// FIDO2 here is NOT authentication -- there's nothing to authenticate against. It's a KEY-MATERIAL source:
// CTAP2's hmac-secret extension holds a per-credential HMAC key INSIDE the authenticator, and an assertion
// with a salt returns HMAC(key, salt) -- deterministic, high-entropy, never exported (the same primitive
// systemd-cryptenroll/LUKS use for FIDO2 disk unlock). That output derives the slot's KEK.
//
// The agent NEVER speaks CTAP2 (that's the gate's job, P4); it takes the assertion output as input --
// NOWHERE_FIDO2_HMAC (hex), exactly like NOWHERE_SE_SECRET feeds the `se` slot (mediad receives it staged as
// "@file:<path>", which adoptStagedSESecret resolves before the dispatch, NWP-20261112-29). This makes the whole
// vault side unit-testable with a fixed byte string standing in for a real key.
//
// MODE 2a (2FA, shipping first): KEK = HKDF(K_pass || hmac_output). Neither the passphrase nor the key alone
// unwraps DK, so enrollment DROPS the pass-only slot (like `se` hardening); the recovery mnemonic stays as
// the escape hatch. MODE 2b (key-primary, KEK = HKDF(hmac_output) with the key's own PIN gating the
// assertion) is a later slot flavor; P3 lands 2a.

const fido2HMACLen = 32 // CTAP2 hmac-secret output is HMAC-SHA-256 -> 32 bytes

// kekFido2 derives a fido2 slot's KEK. hmacOutput is the authenticator's hmac-secret assertion result;
// passKEK (2FA) is mixed in so neither factor alone opens the slot. hkdf-extract+expand over both, domain-
// separated. (2b would pass a nil/empty passKEK.)
func kekFido2(passKEK, hmacOutput []byte) []byte {
	ikm := make([]byte, 0, len(passKEK)+len(hmacOutput))
	ikm = append(ikm, passKEK...)
	ikm = append(ikm, hmacOutput...)
	r := hkdf.New(sha256.New, ikm, []byte("nowhere-fido2-kek-v1"), nil)
	out := make([]byte, 32)
	if _, err := io.ReadFull(r, out); err != nil {
		panic(err) // hkdf over a fixed reader never short-reads 32 bytes
	}
	return out
}

// sessionCred derives the credential the session user's keyguard/FBE binds to for a COLD lock (#81 resume
// gap, DIA-20260704-34). Without this, a 2FA profile's cold session was resumable with the passphrase ALONE
// -- the weakest door on the strongest profiles (gate login = pass+key, cold resume = pass). When the
// session holds a key hmac, the cold credential is HKDF(K_pass || hmac) truncated to 16 hex chars
// (Android's keyguard max length; 64 bits, Gatekeeper-throttled on-device), so recomputing it at resume
// needs the passphrase AND a fresh key assertion. Deterministic per (name, pass, key). A non-fido2 session
// returns the passphrase unchanged. NOTE the warm/cold split: the WARM keyguard (screen-off -> wake) stays
// the raw passphrase -- the user must be able to TYPE it -- only the cold-lock transitions to this derived
// credential (and resume clears it; the next screen-off re-arms the typable passphrase).
func sessionCred(name, pass string) string {
	h := fido2HMAC()
	if h == nil {
		return pass
	}
	ikm := make([]byte, 0, 32+len(h))
	ikm = append(ikm, deriveKey(name, pass)...)
	ikm = append(ikm, h...)
	r := hkdf.New(sha256.New, ikm, []byte("nowhere-session-cred-v1"), nil)
	out := make([]byte, 8)
	if _, err := io.ReadFull(r, out); err != nil {
		panic(err) // hkdf over a fixed reader never short-reads 8 bytes
	}
	return hex.EncodeToString(out)
}

// stashFido2Hmac (#81) writes the asserted hmac to the login hook's stash location (dest/.fido2hmac, RAM
// tmpfs, 0600) so the CURRENT session's seals can open the vault. The login hook (roamd "in") stashes via
// shell; this is the Go-side twin for MID-SESSION ENROLLMENT (DIA-20260704-32): the enroll ceremony just
// flipped the vault to pass+key, and without the stash the running session's very next seal -- periodic
// sync or the logoff itself -- finds no slot it can open ("couldn't save your data", proven on `c`).
func stashFido2Hmac(dest string, h []byte) error {
	return os.WriteFile(filepath.Join(dest, ".fido2hmac"), []byte(hex.EncodeToString(h)), 0o600)
}

// loadFido2HmacEnv (#81) adopts the login-cached hmac stash (roamd "in" wrote $STATE/.fido2hmac after the
// key assertion) into the LONG-LIVED daemon's process env, so its in-process seals -- the ~1-min periodic
// sync and the logoff app/prefs capture -- can open a 2FA vault WITHOUT re-touching the key each time (the
// hmac is deterministic per (credId,salt), so this is exactly reusing what the key would return). Called at
// roam-in: sets the env for a fido2 profile, UNSETS it otherwise so a later non-fido2 session can't inherit
// a stale hmac. Also called after a mid-session ENROLL-FIDO2 (the enroll stashes, the daemon adopts). The
// stash is RAM tmpfs (gone on power-off/reap), same as the passphrase in .roamsession.
func loadFido2HmacEnv(dest string) {
	b, err := os.ReadFile(filepath.Join(dest, ".fido2hmac"))
	if err != nil || len(strings.TrimSpace(string(b))) == 0 {
		os.Unsetenv("NOWHERE_FIDO2_HMAC")
		return
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", strings.TrimSpace(string(b)))
}

// fido2HMAC reads the authenticator assertion output the gate supplied (NOWHERE_FIDO2_HMAC, hex). Empty /
// malformed -> nil, so callers fall back to the pass/recovery paths transparently (mirrors seDK).
func fido2HMAC() []byte {
	s := strings.TrimSpace(os.Getenv("NOWHERE_FIDO2_HMAC"))
	if s == "" {
		return nil
	}
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != fido2HMACLen {
		return nil
	}
	return b
}

// fido2DK tries to open DK from a vault's fido2 slots using the assertion output this login supplied. 2FA:
// the KEK mixes the passphrase KEK, so it needs BOTH (name,pass) -> passKEK AND the right key. nil when no
// hmac is set or no fido2 slot opens -> resolveKey falls through to pass/se/recovery.
func fido2DK(v *vault, passKEK []byte) []byte {
	return fido2DKWith(v, passKEK, fido2HMAC())
}

// fido2DKWith is the fido2 rung with the hmac passed in instead of read from the env (NWP-20261111-03): the
// stranded phone's adopt must prove a freshly asserted hmac opens a fido2 slot of the CURRENT head without
// putting it in the process env, where openVaultDK's other rungs could answer for it. nil hmac -> nil.
func fido2DKWith(v *vault, passKEK, h []byte) []byte {
	if h == nil {
		return nil
	}
	for _, s := range v.Slots {
		if s.Kind == "fido2" {
			if dk, ok := unwrap(kekFido2(passKEK, h), s.Wrapped); ok {
				return dk
			}
		}
	}
	return nil
}

// fido2SlotInfo is the public-safe metadata the gate needs to run the CTAP2 assertion for a slot, plus the
// per-key identity (#81 multi-key) the Profile app shows in the "remove which key?" list.
type fido2SlotInfo struct {
	CredID    string // base64
	Salt      string // base64
	UV        bool
	Added     int64  // unix enrollment time (0 for a pre-multi-key slot)
	Label     string // optional nickname ("" -> the UI shows "Security key")
	Transport string // "usb" | "nfc" | "" (unknown/legacy) -> the UI shows "USB-C key" / "NFC key"
}

// listFido2Slots returns the assertion parameters for every fido2 slot in a resolved vault, so the gate can
// challenge each enrolled key. Public-safe (credId+salt+uv are LUKS-header-grade), but gated behind a head
// that only (name,pass) resolves, so it reveals nothing to someone who doesn't already know the passphrase.
func listFido2Slots(v *vault) []fido2SlotInfo {
	var out []fido2SlotInfo
	for _, s := range v.Slots {
		if s.Kind == "fido2" {
			out = append(out, fido2SlotInfo{CredID: s.CredID, Salt: s.Salt, UV: s.UV, Added: s.Added, Label: s.Label, Transport: s.Transport})
		}
	}
	return out
}

// --- cold-resume slot cache (NWP-20260823-09, #81 resume) --------------------------------------------
//
// THE PROBLEM THESE SOLVE: every assert path resolved its slots from the vault HEAD, which only
// (name,PASSPHRASE) opens -- but a PIN cold-resume never types the passphrase, and the passphrase it would
// need is itself sealed under coldWrapKey(name, unlockSecret, HMAC), i.e. under the very hmac the assert
// exists to obtain. Circular: a PIN+FIDO2 session could not be resumed on EITHER transport (device-proven
// on lynx 2026-08-23: "fido2-hmac: no profile", the key never touched). So the NON-SECRET assertion
// parameters are cached at LOGIN (where the vault is already open, no store round-trip, no failure mode)
// and carried into the cold-lock marker, which is what resume asserts from.
//
// WHY THIS IS SAFE TO CACHE: credId+salt+uv are LUKS-header-grade -- credId is what an ordinary WebAuthn
// server stores in the clear, and the salt is an assertion INPUT, not a secret. They yield nothing without
// the physical key. The cache is 0600 on tmpfs, dies with the session, and reveals no more than the
// "Welcome back <name>" the gate already shows. It is NOT vault material: no DK, no hmac, no passphrase.

// fido2KeyAssertFn is the assertion assertAnySlot runs; a test stubs it.
var fido2KeyAssertFn = fido2KeyAssert

// assertAnySlot challenges each enrolled key in turn over USB (multi-key: any ONE opens the vault) and
// returns the first hmac obtained. Shared by the login assert and the cold-resume re-assert so both treat
// a multi-key profile identically. Each slot is asserted with the uv it was enrolled with. A dead USB link or no key
// on the port ends the whole attempt; any other failure moves on to the next slot (NWP-20261113-09).
func assertAnySlot(slots []fido2SlotInfo) ([]byte, error) {
	var lastErr error
	for _, s := range slots {
		credID, e1 := base64.StdEncoding.DecodeString(s.CredID)
		salt, e2 := base64.StdEncoding.DecodeString(s.Salt)
		if e1 != nil || e2 != nil {
			continue
		}
		h, err := fido2KeyAssertFn(credID, salt, s.UV) // the slot's own uv: a UV slot asserts with a fresh token
		if err != nil {
			// ⚠ A DEAD LINK OR A MISSING KEY ENDS THE WHOLE ATTEMPT. Both are a property of the USB port, not of this
			// credential: the next slot runs findFidoHidraw and openCTAPHID again and fails the same way, after its own
			// ~8 s scan or its own read wait, so it cannot succeed. Same rule as fido2AssertOverNFC's nfcLinkError
			// (NWP-20260825-01). Any other error -- a CTAP-level rejection such as "that credential is not on this
			// key" -- goes on to the next slot, which is the multi-key semantic this loop exists for (NWP-20261113-09).
			var le *hidLinkError
			if errors.As(err, &le) || errors.Is(err, errNoFidoHidraw) {
				return nil, err
			}
			lastErr = err
			continue
		}
		return h, nil
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, errors.New("no enrolled key responded")
}

// encodeSlotSpec renders slots as "<b64credId>:<b64salt>:<uv>,..." -- std base64 contains no ':' or ','.
func encodeSlotSpec(slots []fido2SlotInfo) string {
	var parts []string
	for _, s := range slots {
		uv := "0"
		if s.UV {
			uv = "1"
		}
		parts = append(parts, s.CredID+":"+s.Salt+":"+uv)
	}
	return strings.Join(parts, ",")
}

// parseSlotSpec is encodeSlotSpec's inverse; a malformed field is skipped, never fatal (a resume that ends
// up with zero slots simply falls back to the old head-resolved path).
func parseSlotSpec(spec string) []fido2SlotInfo {
	var out []fido2SlotInfo
	for _, part := range strings.Split(spec, ",") {
		f := strings.Split(strings.TrimSpace(part), ":")
		if len(f) < 2 || f[0] == "" || f[1] == "" {
			continue
		}
		out = append(out, fido2SlotInfo{CredID: f[0], Salt: f[1], UV: len(f) > 2 && f[2] == "1"})
	}
	return out
}

// stashFido2Slots caches the slot spec for this session's cold-resume. Best-effort: a failure here costs a
// PIN resume, not the login, so it must never break the caller.
func stashFido2Slots(dest string, slots []fido2SlotInfo) {
	if dest == "" || len(slots) == 0 {
		return
	}
	os.WriteFile(filepath.Join(dest, ".fido2slots"), []byte(encodeSlotSpec(slots)), 0o600)
}

// syncFido2SlotsStash makes the cold-resume cache equal to the enrolled set an enroll or a removal just
// COMMITTED (NWP-20260823-10, remade by NWP-20261017-03). The slots come from the vault the bracket published,
// not from a second store read: the old refresh re-read the head after the commit and, on a store hiccup,
// LEFT THE STASH ALONE -- a stale or empty line 7 -- which was harmless while a resume could fall back to
// resolving the head with the typed entry, and strands the owner now that it cannot (a keyed resume takes its
// slot spec from the marker only). A local file write cannot fail the way a store read does -- but it can
// still fail (ENOSPC, a read-only state dir), and that must not pass silently either: the file is replaced
// atomically (a torn write is never read as a short spec) and a failure is RETURNED, so the enroll or removal
// answers ERR instead of OK over a stale line 7. The bracket has already committed, and the retry heals: an
// enroll finds its key present and a removal that finds its key gone both re-sync the stash from the head they
// read. An empty set (the last key removed) removes the stash, so a later cold-lock cannot bake a credential
// this vault no longer has.
func syncFido2SlotsStash(dest string, slots []fido2SlotInfo) error {
	if dest == "" {
		return nil
	}
	p := filepath.Join(dest, ".fido2slots")
	if len(slots) == 0 {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("cold-resume slot spec not cleared: %w", err)
		}
		return nil
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(encodeSlotSpec(slots)), 0o600); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("cold-resume slot spec not saved: %w", err)
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("cold-resume slot spec not saved: %w", err)
	}
	return nil
}

// firstDir is the optional trailing stashDir argument of enrollFido2 and removeFido2Key ("" = no cold-lock
// session to keep in step: the raw CLI and the tests).
func firstDir(d []string) string {
	if len(d) == 0 {
		return ""
	}
	return d[0]
}

// stashFido2SlotsPre caches the spec for a login that has NOT COMMITTED YET (NWP-20260823-11).
//
// ⚠ WHY A .pre FILE AND NOT THE LIVE STASH. The login assert runs BEFORE the NEEDKEY guard decides whether
// this login commits, so writing the live stash there has two failure modes, and NWP-20260823-10 hit both
// while trying to fix one of them:
//   - a REFUSED login (the straggler case this file documents for .fido2hmac at the "STASH DISCIPLINE" note)
//     would overwrite the LIVE session's spec with the refused attempt's;
//   - and the per-login reset that stops a keyless profile inheriting a stale spec has to live in the commit
//     arm, which runs AFTER the assert -- so it deleted the very spec the same login had just written, and
//     every keyed login ended up with an EMPTY marker line 7. The feature was inert.
//
// Promotion at commit resolves both: the assert writes .pre, and the commit arm moves it into place or, for a
// keyless login, removes both. Exactly the shape .fido2hmac.pre already uses.
//
// ⚠ A COMMITTING KEYED LOGIN MUST STAGE ITS SPEC (NWP-20261112-15). The cold lock bakes the promoted spec into
// marker line 7, and since NWP-20261017-03 a keyed resume takes its slots from that line only: a session that
// committed with no spec, or a torn one, is refused at every resume until the wipe, right passphrase and right
// key included. So the write is temp + rename, as syncFido2SlotsStash's is (a reader never sees a half-written
// spec), and a failure is RETURNED: the caller stops the login (or the adopt) instead of committing it.
func stashFido2SlotsPre(dest string, slots []fido2SlotInfo) error {
	if dest == "" || len(slots) == 0 {
		return nil
	}
	p := filepath.Join(dest, ".fido2slots.pre")
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(encodeSlotSpec(slots)), 0o600); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("slot spec not staged: %w", err)
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("slot spec not staged: %w", err)
	}
	return nil
}

// readFido2SlotsStash reads what stashFido2Slots wrote (empty if absent).
func readFido2SlotsStash(dest string) string {
	b, err := os.ReadFile(filepath.Join(dest, ".fido2slots"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// enrollFido2 adds a 2FA fido2 slot to an existing vault. FIRST enroll (pass slot still present): drops the
// pass-only slots, so login now needs passphrase + key. ADDING a key to an already-enrolled vault
// (DIA-20260704-35 multi-key): DK opens via the ALREADY-enrolled key's cached hmac (openVaultDK -- a live
// 2FA session holds it, so key #2 enrolls without key #1 in the single USB-C port) and the new slot is
// simply appended -- ANY enrolled key + passphrase then opens the vault (unwrapDK/fido2DK iterate slots).
// credIDb64/saltb64 are the CTAP2 credential id + the 32-byte hmac-secret salt (both base64); hmacHex is
// the assertion output for THAT (credId,salt,uv) captured at enrollment; uv fixes the slot's PIN/UV policy
// (login must match or the key returns a different secret). The recovery slot is left intact as the
// lose-the-keys escape hatch. Mirrors enrollSE.
// ⚠ se: NWP-20260915-13. Without it a HARDENED vault could not enrol a key at all -- the `pass` slot is
// gone by design, so the ladder fell through to an env the login daemon never carries and the USB path
// handed the worker an empty secret. The 2FA tier was therefore dead on Endospore, the edition it was
// built for, in every one of its three entry points: USB enrol, NFC enrol and remove.
// stashDir (NWP-20261017-03): the live session's state dir. When given, the cold-resume slot spec there is
// rewritten from the vault this call committed (syncFido2SlotsStash), so it cannot lag the enrolled set.
func enrollFido2(base, name, pass, credIDb64, saltb64, hmacHex string, uv bool, transport string, se []byte, stashDir ...string) error {
	h, err := hex.DecodeString(strings.TrimSpace(hmacHex))
	if err != nil || len(h) != fido2HMACLen {
		return errors.New("hmac must be 32-byte hex")
	}
	if _, err := base64.StdEncoding.DecodeString(credIDb64); err != nil || credIDb64 == "" {
		return errors.New("cred_id must be base64")
	}
	salt, err := base64.StdEncoding.DecodeString(saltb64)
	if err != nil || len(salt) != 32 {
		return errors.New("salt must be base64 32 bytes")
	}
	hd, v, isV := readVaultHead(base, name, pass) // to open the DK: the edit itself re-reads inside the bracket
	if hd.val == "" {
		return errors.New("wrong passphrase / no profile")
	}
	if !isV {
		return errors.New("profile is not a vault (migrate first)")
	}
	passKEK := deriveKey(name, pass)
	dk := unwrapDK(v, "pass", passKEK)
	if dk == nil {
		// Already 2FA: the pass slot is gone by design. Open via the ENROLLED key's cached hmac (env,
		// exported by roamd from the login stash) or the SE slot, so a second key can be added
		// mid-session with only the NEW key in the single USB-C port. The new key's ceremony returns its
		// values without touching the env, so fido2DK still tries the enrolled key's hmac.
		dk = openVaultDKSE(v, name, pass, se)
		if dk == nil {
			return errors.New("no slot opens (sign in with an enrolled key first, or recover)")
		}
	}
	slot := keyslot{
		Kind: "fido2", CredID: credIDb64, Salt: saltb64, UV: uv,
		Added:     time.Now().Unix(), // #81 multi-key: so the remove list can show "added <date>"
		Transport: transport,         // "usb" | "nfc" | "" -> the remove list can show "USB-C key" / "NFC key"
		Wrapped:   wrap(kekFido2(passKEK, h), dk),
	}
	return publishKeyslotVault(base, "security-key enrol", name, pass, dk, v.Sig != "", firstDir(stashDir), func(cur *vault) (bool, error) {
		for _, s := range listFido2Slots(cur) {
			if s.CredID == credIDb64 {
				return false, nil // already enrolled on this head: the slot is there, and adding it again would double it
			}
		}
		// A first enrol is one a `pass` slot opens -- asked of the head read in the bracket, which is the one
		// this edit lands on. A hardened vault never takes this branch: it has no pass slot. Nothing here can
		// un-harden anything: it only ever DROPS slots.
		firstEnroll := unwrapDK(cur, "pass", passKEK) != nil
		cur.Slots = append(cur.Slots, slot)
		if firstEnroll {
			kept := make([]keyslot, 0, len(cur.Slots)) // 2FA: drop every pass-only slot -> a key becomes required
			for _, s := range cur.Slots {
				if s.Kind != "pass" {
					kept = append(kept, s)
				}
			}
			cur.Slots = kept
		}
		return true, nil
	})
}

// publishKeyslotVault applies edit to the profile's vault and publishes it: this unit's head, the recovery ref,
// and the account head's keyslots (syncAccountKeyslots, NWP-20260906-10: the revoked or added slot must reach
// the account head too, or a device with no unit head of its own still opens with the OLD slots). In managed
// mode the rewrite rides a capWrite bracket, like createVault.
//
// NWP-20261009-07: it was a bare bracket that published whatever had been read, whenever the lock let it, and
// reported success regardless. edit now runs on the head read INSIDE the bracket (capReadVaultForEdit), so an
// enrol or a removal that waited for a re-key batch lands on the batch's head instead of being refused -- and
// for an NFC enrol, instead of throwing the two-tap ceremony away: the DK and the credential's id, salt and
// hmac are the same whichever head they land on. A refusal that remains, from another process or device,
// answers ERR, which the chooser already shows as a failed enrol or remove.
//
// edit reports whether it changed anything: an enrol or a removal another device already made needs no
// publish, and is a success. signed: see capReadVaultForEdit.
func publishKeyslotVault(base, op, name, pass string, dk []byte, signed bool, stashDir string, edit func(cur *vault) (bool, error)) error {
	var perr error
	var final []fido2SlotInfo
	settled := false
	if capWrite(name, pass, dk, func() {
		cur, err := capReadVaultForEdit(base, op, name, pass, dk, signed)
		changed := false
		if err == nil {
			changed, err = edit(cur)
		}
		if err != nil || !changed {
			perr = err
			if err == nil {
				final, settled = listFido2Slots(cur), true // already so on this head: the stash should say so too
			}
			capAbort()
			return
		}
		cur.Version++
		signVault(cur, dk)
		vh := postBlob(base, serializeVault(cur))
		putHead(base, name, pass, vh)
		putRef(base, cur.RecoveryRef, vh)
		syncAccountKeyslots(base, name, pass, dk, cur)
		final, settled = listFido2Slots(cur), true
	}).Refused() {
		return errors.New("refused at publish: the store did not accept the new head")
	}
	if perr == nil && settled {
		// from the vault just committed -- no store read to fail (NWP-20261017-03); a write failure is an error
		if err := syncFido2SlotsStash(stashDir, final); err != nil {
			fmt.Fprintf(os.Stderr, "[logind] %s committed but %v\n", op, err)
			return err
		}
	}
	return perr
}

// errKeyTapMissing and errKeyTapWrong are removeFido2KeyTapped's two refusals (NWP-20261127-02): no tap came
// with the request, or the tapped key cannot confirm this removal. Nothing is removed on either.
var (
	errKeyTapMissing = errors.New("no key was tapped to confirm the removal")
	errKeyTapWrong   = errors.New("the tapped key cannot confirm this removal")
)

// permittedRemoveSlots returns the fido2 slots whose tap may confirm removing credIDb64 (h53 #3,
// docs/product-decisions.md 2026-11-02: "a tap of a remaining key, or of the key itself when it is the last
// one"). A named key with others beside it: every other key, never the named one. The named key alone: that
// key. A name this vault does not hold: every key (removeFido2Key then answers "no such security key").
// credIDb64 == "" (remove every key) with one key: that key.
// ⚠ credIDb64 == "" with two or more keys permits ANY ONE enrolled key. That is AN INFERENCE, NOT STATED BY
// CHESTER: the decision names only a remaining key and the last key, and when every key goes none remains, so
// the rule falls back to the sign-in rule -- any one enrolled key.
func permittedRemoveSlots(v *vault, credIDb64 string) []keyslot {
	var all, others []keyslot
	for _, s := range v.Slots {
		if s.Kind != "fido2" {
			continue
		}
		all = append(all, s)
		if s.CredID != credIDb64 {
			others = append(others, s)
		}
	}
	if credIDb64 == "" || len(others) == 0 {
		return all
	}
	return others
}

// removeFido2KeyTapped (NWP-20261127-02) is removeFido2Key behind a fresh tap: tap is the hmac a key returned
// for this request, and the removal goes ahead only when it opens a slot permittedRemoveSlots allows. The tap is
// its argument only: it never reads NOWHERE_FIDO2_HMAC or .fido2hmac, which hold the answer cached at sign-in
// (the decision's "Not chosen"). The tap also opens the DK for the edit, so no other rung answers for it. se is
// not read: a fido2 slot opens from (name, pass) and the key's hmac alone, on a hardened vault too.
func removeFido2KeyTapped(base, name, pass, credIDb64 string, tap []byte, se []byte, stashDir ...string) (bool, error) {
	if len(tap) == 0 {
		return false, errKeyTapMissing
	}
	hd, v, isV := readVaultHead(base, name, pass)
	if hd.val == "" {
		return false, errors.New("wrong passphrase / no profile")
	}
	if !isV {
		return false, errors.New("profile is not a vault")
	}
	permitted := permittedRemoveSlots(v, credIDb64)
	if len(permitted) == 0 {
		return false, errors.New("no security key enrolled")
	}
	only := *v // a shallow copy holding only the permitted slots; v itself is not changed
	only.Slots = permitted
	passKEK := deriveKey(name, pass)
	if fido2DKWith(&only, passKEK, tap) == nil {
		return false, errKeyTapWrong
	}
	return removeFido2KeyOpen(base, name, pass, credIDb64, func(v *vault) []byte { return fido2DKWith(v, passKEK, tap) }, stashDir...)
}

// removeFido2Key (DIA-20260704-35) removes ONE enrolled key by its credential id -- so losing a key means
// revoking JUST that one and keeping the others, not the blunt all-or-nothing. credIDb64=="" removes ALL
// keys (the "turn off security keys" affordance). Removing the LAST key re-adds a passphrase slot (the
// voluntary downgrade back to passphrase-only; the involuntary path stays the recovery mnemonic). It does not
// check for a tap: the daemon calls it only through removeFido2KeyTapped, which refuses unless a fresh tap of a
// remaining key (or of the last key itself) opens the vault (h53 #3, NWP-20261127-02). The DK then opens via
// the full ladder.
// The recovery slot is always untouched. Returns whether the vault is STILL key-protected after the removal
// (so the caller knows to keep vs purge the cold-credential key binding).
// ⚠ AND THE LAST-KEY BRANCH BELOW USED TO SILENTLY UN-HARDEN A HARDENED VAULT (NWP-20260915-13). Its
// premise -- "the vault would have neither a pass nor a fido2 slot" -- is simply false when `se` slots
// exist: the handset's own secure element still opens it. Re-adding a `pass` slot there was both
// unnecessary AND a security downgrade, and nothing wrote v.Hardened, so the vault went on REPORTING
// hardened while being offline brute-forceable by passphrase alone -- the exact property kekSE exists
// to provide and the exact claim docs/threat-model.md makes for the edition.
// stashDir: as enrollFido2 -- the cold-resume slot spec follows the committed set, and the last removal deletes it.
func removeFido2Key(base, name, pass, credIDb64 string, se []byte, stashDir ...string) (stillEnrolled bool, err error) {
	return removeFido2KeyOpen(base, name, pass, credIDb64, func(v *vault) []byte { return openVaultDKSE(v, name, pass, se) }, stashDir...)
}

// removeFido2KeyOpen is removeFido2Key's body with the DK open passed in (NWP-20261127-02): removeFido2Key opens
// through the full ladder, removeFido2KeyTapped through the tap alone.
func removeFido2KeyOpen(base, name, pass, credIDb64 string, open func(v *vault) []byte, stashDir ...string) (stillEnrolled bool, err error) {
	hd, v, isV := readVaultHead(base, name, pass) // to open the DK: the edit itself re-reads inside the bracket
	if hd.val == "" {
		return false, errors.New("wrong passphrase / no profile")
	}
	if !isV {
		return false, errors.New("profile is not a vault")
	}
	if len(listFido2Slots(v)) == 0 {
		return false, errors.New("no security key enrolled")
	}
	dk := open(v)
	if dk == nil {
		return false, errors.New("no slot opens (sign in with an enrolled key first, or recover)")
	}
	// A credential this vault never had is still an error, as it always was. One it had when this was asked,
	// and another device removed before the bracket opened, is a success: the user's intent is met, and the
	// handler answers "OK <still enrolled>" exactly as it would have (NWP-20261009-07).
	present := credIDb64 == ""
	for _, s := range listFido2Slots(v) {
		present = present || s.CredID == credIDb64
	}
	if !present {
		// Already gone: a retry after a failed stash write lands here, so heal the cold-resume spec from this head.
		if serr := syncFido2SlotsStash(firstDir(stashDir), listFido2Slots(v)); serr != nil {
			return true, serr
		}
		return true, errors.New("no such security key")
	}
	before := len(listFido2Slots(v)) > 0
	err = publishKeyslotVault(base, "security-key removal", name, pass, dk, v.Sig != "", firstDir(stashDir), func(cur *vault) (bool, error) {
		kept := make([]keyslot, 0, len(cur.Slots)+1)
		removed := 0
		for _, s := range cur.Slots {
			if s.Kind == "fido2" && (credIDb64 == "" || s.CredID == credIDb64) {
				removed++
				continue // drop this key
			}
			kept = append(kept, s)
		}
		if removed == 0 {
			stillEnrolled = len(listFido2Slots(cur)) > 0 // already gone from this head: nothing to publish
			return false, nil
		}
		// If that was the last key, the vault would have neither a pass nor a fido2 slot -> add a pass slot
		// back (downgrade to passphrase-only). If keys remain, we stay 2FA and add nothing.
		stillEnrolled = false
		for _, s := range kept {
			if s.Kind == "fido2" {
				stillEnrolled = true
			}
		}
		// ⚠ ...AND ONLY WHEN NOTHING ELSE OPENS IT. The re-add exists so the last key cannot strand the user,
		// but a hardened vault is not stranded: its `se` slot opens on this handset, and the 12 words open it
		// anywhere. Re-adding a passphrase slot there hands back exactly the offline brute-force surface that
		// dropping it bought -- silently, with Hardened left true. So ask about every slot kind, not just
		// fido2. A NON-hardened 2FA vault is unaffected: seSlotCount is 0 and it takes the branch as before.
		if !stillEnrolled && seSlotCount(cur) == 0 {
			kept = append(kept, keyslot{Kind: "pass", Wrapped: wrap(deriveKey(name, pass), dk)})
		}
		cur.Slots = kept
		return true, nil
	})
	if err != nil {
		// The handlers answer ERR and do not read stillEnrolled, so this is only the last state known. It is not
		// a claim about the store: an error from inside the bracket published nothing, but a refusal at the flush
		// (another process or device moved the head) refuses the head alone, and the recovery ref and the account
		// head's keyslots beside it may still have landed.
		return before, err
	}
	return stillEnrolled, nil
}
