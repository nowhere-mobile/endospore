# Endospore E.3b — Secure-element key binding (StrongBox / Titan M2)

*(⚠ SUPERSEDED IN PART 2026-10-06 (`NWP-20261006-09`, `docs/product-decisions.md` "tying a profile to a phone's secure element is OPT-IN"): nothing hardens a profile automatically any more. The user ties it from the profile's settings (session verb `SE-TIE`) and can untie it (`SE-UNTIE`); the gate's `ENROLL-SE` and its calls at CREATE and RECOVER are gone. The mechanism below -- the `se` slot, `kekSE`, the dropped pass slot -- is unchanged.)*

Status: **DESIGN (2026-06-20).** The distinguishing security feature of the Endospore (GrapheneOS/Pixel)
edition over Diaspore (FP3): bind passphrase unlock to the **Titan M2** so the passphrase is **not
brute-forceable offline**. Pairs with endospore-spec.md (E.3) and builds on the vault
model in [recovery.md](recovery.md).

## Goal (Option A, chosen 2026-06-20)

The FP3 tops out at: a random **Data Key (DK)** encrypts the data; DK is wrapped in keyslots — a `pass`
slot (KEK = `Argon2id(passphrase, salt=name)`) and a `recovery` slot (KEK from the 12-word mnemonic). The
**weakness**: an attacker who captures the (zero-knowledge) store ciphertext can **brute-force the
passphrase offline** against the `pass` slot — there is no rate-limit, because the KEK must be derivable
from name+pass alone for blind-login to work on any device.

Endospore closes this on the **trusted device** using the Titan M2:
- **Trusted device:** the `pass` slot's KEK is gated by the secure element — unlock requires a hardware
  **Weaver**-throttled passphrase check that releases a **StrongBox**-bound device secret mixed into the
  KEK. Wrong guesses are rate-limited in hardware; the device secret never leaves the SE; so the passphrase
  is **not brute-forceable offline** (you need the specific Titan M2, and it throttles you).
- **Roaming to a new device:** falls back to the **12-word recovery mnemonic** (high entropy → not
  passphrase-guessable). The new device can then *enroll* (add its own SE-gated slot) so subsequent logins
  there are passphrase-only + throttled.
  ⚠ **This paragraph described the intent correctly and the implementation wrongly for three months.**
  It said "already built (`recover`/`recoverVault`)" — but `recoverVault` rebuilds the vault through
  `buildVault`, which REPLACES the slot list, so recovering on handset B **discarded handset A's `se`
  slot**. The two phones then alternated being locked out, each recovery undoing the last. The additive
  enrol this sentence always assumed is `enrollSEViaRecovery`, built in **E.3b.6** below
  (`NWP-20260915-09`); `recoverVault` is the passphrase-reset path and is **not** the multi-device path.

This is the Signal-SVR / iCloud-Keychain-HSM shape: a high-entropy master key (our DK) released by an
HSM/SE after a throttled low-entropy secret (the passphrase), with a high-entropy recovery path.

## Amnesiac vs. persistent SE enrollment — RESOLVED (no carve-out needed)

Initial worry: StrongBox/keystore2 state lives in `/data`, which an amnesiac device wipes on power-off, so
the enrollment would die each boot. **That misreads the model.** Endospore's amnesia comes from the roamed
identities being **`MAKE_USER_EPHEMERAL`** Android users (crypto-shredded on power-off) plus the tmpfs
working set — **NOT a wipe of user 0**. User 0 (the gate / device owner / OS-side state) **persists** across
power-off (proven on HW: the provisioning marker survives reboots). The chooser runs **at user 0**, so the
StrongBox key it creates lives in user 0's keystore and **persists naturally** with the device — no
special carve-out engineering required. (Confirmed by Chester 2026-06-20.)

So the SE key is **device state, like the OS** — not user data. The **"amnesiac for your data" claim is
unchanged**: every roamed identity is still ephemeral; the device merely remembers *that it is a trusted
device* via an SE-gated unlock token that is inert without your passphrase + that physical Titan M2. A
brand-new / un-enrolled device holds nothing and roams via the mnemonic — full amnesia there. (The only
state that does NOT persist is intentional: a factory reset / unlock wipes user 0 too, which re-provisions
from scratch — the device then re-enrolls on first login, exactly as a new device would.)

## Crypto mechanism

Add a keyslot kind to the vault (`docs/recovery.md`): **`se`** (device-bound), living **in the roamed vault**
so the SE device can recover DK from the store. Enrolling a device adds its `se` slot **and DROPS the
pass-only slot** (the `Hardened` flag) — this is what closes the offline gap: a captured head then has only a
`recovery` (mnemonic) slot + per-device `se` slots, **none openable by passphrase alone**. The head ref stays
`profileRef(name,pass)` (findable by the legit user); only (passphrase + that device's `se_secret`) or the
mnemonic opens it. **Per-identity opt-in** (the `Hardened` flag): Endospore identities harden; Diaspore/FP3
identities keep the `pass` slot (portable, no SE). **Tradeoff:** a hardened identity can no longer be opened
by passphrase ALONE on a non-enrolled / non-SE device — those roam via the mnemonic, then re-enroll.
⚠ *“Roam via the mnemonic, then re-enroll”* means **`ADD-DEVICE` (E.3b.6), not `recoverVault`.** Using
the reset path here is what evicted the other handset for three months; see the Goal section above.
⚠⚠ **AND THIS COVERS THE BARE VAULT HEAD ONLY — the five scope heads are NOT secure-element bound.**
`name#de`, `#sys`, `#media`, `#apps` and `#keys` are bare manifests sealed under `deriveKey(name#scope,
pass)`, and a re-point gives them a single `pass` slot (`buildScopeVault`), so a passphrase alone opens the
app data, media and Keystore blobs on any device, hardened profile or not. Stated in
`profile-export-restore.md` §4; repeated here because `app_code.go` claimed the
opposite in a comment until `NWP-20260915-10`.
Implemented + unit-tested in `core/agent` (E.3b.2): `kekSE`, `enrollSE`, `resolveKeySE`, the `se` fallback in
`resolveKey`/`pushProfile`, and the `enroll-se` CLI.

- **SE-KEK** = `Argon2id( passphrase , salt = H(name ‖ se_secret) )` — a slow KDF, so it stays
  brute-force-resistant even if `se_secret` ever leaks; `se_secret` is a 32-byte random value sealed in the
  Titan M2 and released **only** after a successful **Weaver** check of the passphrase (hardware throttle:
  exponential backoff / lockout after N failures). The StrongBox-bound key is **non-exportable** and
  **auth-bound** (requires the Weaver/credential auth), so `se_secret` cannot be extracted off-device.
- **Enroll** (first login on a device, after a mnemonic recovery OR an already-unlocked session): generate
  `se_secret` in StrongBox + a Weaver slot for the passphrase; wrap DK under `SE-KEK`; persist the wrapped
  DK + handles in the device-local enrollment store (carved out from the wipe).
- **Unlock** (subsequent boots on the enrolled device): passphrase → Weaver check (throttled) → release
  `se_secret` → derive `SE-KEK` → unwrap DK → roam as usual. No store round-trip needed to *derive* the key
  (the store still holds the data; the `se` unlock just yields DK locally).
- **Roam to a new device:** mnemonic → `recovery` slot → DK → (optional) enroll on the new device.

## Integration (who does what)

StrongBox + Weaver are **Android Keystore / keystore2 APIs (Java/binder)** — the Go agent cannot call them
directly. So:
- **`core/chooser` (Java, platform-signed, device owner):** owns the SE operations — StrongBox key gen
  (`KeyGenParameterSpec.setIsStrongBoxBacked(true)` + `setUserAuthenticationRequired`), the Weaver/credential
  throttle, enroll, and unlock. On a successful unlock it hands the **unwrapped DK** to the daemon.
- **`core/agent` (Go daemon):** gains a way to accept a **caller-supplied DK** for a profile (a new
  `login-with-dk` path on the `diaspore_login` socket) instead of always deriving the pass-KEK itself; the
  rest of restore/seal is unchanged. Also a vault helper to add/read the `se` slot metadata.
- **Wipe carve-out (`core/vendor-common` + the amnesiac init):** the power-off wipe must preserve the SE
  enrollment store + the keystore2 entries for the StrongBox key / Weaver slot, while wiping everything
  else. This is the trickiest piece on GrapheneOS (FBE + the credential system) — its own slice.

## Threat model — what the SE buys / doesn't

- **Buys:** on the enrolled trusted device, the passphrase is **not offline-brute-forceable** (need the
  physical Titan M2 + it throttles); insider-/store-operator-resistant (the store still holds only
  ciphertext, and now the passphrase guard is hardware-throttled); a stolen powered-off device resists
  passphrase guessing (Weaver lockout).
- **Doesn't:** a brand-new device's security rests on the **mnemonic's** entropy (treat the 12 words as the
  real root secret — already true). The carve-out means an enrolled device is **not 100% amnesiac** w.r.t.
  the unlock token (acceptable per the decision above; the token is inert without the passphrase + that SE).
- **Attestation** (proving the device is genuine Endospore) is a *separate* feature (Option C) — out of
  scope here; note that key attestation reveals our custom AVB key (see endospore-spec.md risks).

## Implementation slices

1. **E.3b.1 — this design + carve-out decision. DONE** (carve-out confirmed 2026-06-20; design corrected: `se` slot in the roamed vault + drop the pass slot, not a device-local blob).
2. **E.3b.2 — agent: DONE.** `Hardened` vault flag + per-device `se` keyslot; `kekSE`/`enrollSE`/`resolveKeySE`; `se` fallback in `resolveKey`+`pushProfile`; `enroll-se` CLI; unit-tested (`se_test.go`, full suite green).
3. **E.3b.3 — chooser + plumbing: DONE (pending on-device verify).** Chooser `seSecretHex(name)` derives a
   stable per-identity secret from a **StrongBox HMAC key** (non-exportable, Titan M2; `""` if no SE → FP3
   stays portable). It hardens on CREATE (`ENROLL-SE`) *(⚠ superseded 2026-10-06: opt-in from settings, `SE-TIE`; `ENROLL-SE` removed)* and sends `se_secret` on every `ROAM-IN`. Daemon:
   `ENROLL-SE` verb + `se_secret` threaded through `ROAM-IN` → `.roamsession` → `roam.req` line 5 → `roamd`
   exports `DIASPORE_SE_SECRET` for restore **and** the periodic/logout seal. Agent vet+test green; chooser
   builds in the image (verified on-device at `.5`).
4. ~~**E.3b.4 — wipe carve-out**~~ **— DROPPED (moot).** User 0 persists across the amnesiac power-off (only
   `MAKE_USER_EPHEMERAL` roamed users + tmpfs are wiped), so the user-0 StrongBox key persists naturally —
   no carve-out needed. See the amnesiac section above.
5. **E.3b.5 — on-device: DONE + PROVEN on a Pixel 7a (2026-06-20).** `lynx-cur-userdebug` flashed; created
   `setest` at the gate → confirmed: (1) `feature:android.hardware.strongbox_keystore` present on lynx; (2)
   the chooser derived a 32-byte `se_secret` (`.roamsession` line 4 = 64 hex, no StrongBox errors) and the
   plumbing carried it create→`ENROLL-SE`→`.roamsession`→`roamd`→agent; (3) **the identity is hardened** —
   agent `restore` with the passphrase **alone** returns `empty -> nothing` (no pass slot → offline brute
   force closed), while `restore` with the StrongBox `se_secret` opens it (`(1 chunks) -> …`). Recovery slot
   preserved (mnemonic roam path; unit-tested in `se_test.go`). **The offline-brute-force fix works on real
   hardware.** Then **E.3a relock** as the finalization (signed factory image staged — but it predates the
   E.3b code, so re-sign the E.3b user build first).
   *(Deferred refinement: bind the StrongBox key to a device-credential = passphrase for a hardware throttle
   on on-device guessing — not needed for the offline-brute-force fix, which non-extractability already gives.)*
6. **S1 — on-device guessing throttle (the deferred refinement above). PLANNED 2026-06-22.** Bind the
   StrongBox `se_secret` key with `setUserAuthenticationRequired(true)` to the **lock-screen device
   credential** (see [lock-model.md](lock-model.md) "Implementation plan", L1+L2) so releasing `se_secret`
   requires a fresh credential auth → on-device passphrase/PIN guessing is hardware-throttled (Weaver
   backoff / lockout). This is the *complement* to the already-closed offline path: offline brute-force is
   shut by non-extractability (E.3b.5), S1 shuts on-device brute-force. **Depends on the lock-screen
   credential existing** — that credential is the throttle anchor, which is why S1 sequences after L1+L2.
   Confirm **Weaver is reachable on lynx**; otherwise fall back to the coarser Keymint
   `setUserAuthenticationValidityDuration` (see Open decisions). Tracked as task S1.

7. **E.3b.6 — ADDING A SECOND HANDSET: BUILT 2026-09-15 (`NWP-20260915-09`). NEEDS-DEVICE.**
   Hardening drops the `pass` slot, and `kekSE` is salted with a secret sealed in ONE handset's Titan M2 —
   so a second handset finds the vault and cannot open it. `openVaultDK` tries pass (gone), then `se` (the
   other device's), then `fido2`, and returns nil; the gate renders a blank, which blind login makes
   **indistinguishable from a wrong passphrase**. The user has a correct passphrase and no way to learn it.

   ⚠ **The destruction never came from hardening — it came from REBUILDING the vault.** So the fix is
   additive: `enrollSEViaRecovery` opens the existing vault through its `recovery` slot (which every vault
   keeps, hardened or not) and **APPENDS** this device's `se` slot to the slot list that is already there.
   No passphrase change, no rebuild, no eviction. Handset A keeps working, B starts working, a third is the
   same operation again — pinned by a test that adds three and asserts each still opens exactly one slot.

   ⚠ **It grants nothing the 12 words did not already grant.** Anyone holding the mnemonic can run
   `recoverVault` and take the profile outright; this is a strictly gentler use of the same secret.

   ⚠ **It needs the CURRENT PASSPHRASE as well, and that is not belt-and-braces.** `kekSE` is
   `Argon2id(passphrase, salt=H(name‖se_secret))`, so the slot cannot be minted without it; and the head
   publishes at `profileRefV2(name, pass)`, so a wrong passphrase would write a head **at a ref nobody
   reads** while the real profile sat untouched and the user was told it worked. A ref cross-check refuses
   before anything is written.

   Wire: `ADD-DEVICE\n<name>\n<pass>\n<12 words>\n<se_secret_hex>\n` →
   `OK | BLANK | NOSTORE | ERR-BADSECRET | ERR-BADPHRASE | ERR-NOPROFILE | ERR-BADPASS | ERR`.
   ⚠ **The refusals name WHICH credential was wrong**, unlike the gate's reset screen, which deliberately
   will not. That is a considered exception: `ERR-BADPHRASE` is decided from the typed words alone;
   `ERR-NOPROFILE` is the JOINT failure of name AND phrase, so it cannot separate an unknown name from
   wrong words; and `ERR-BADPASS` is reachable only by someone already holding this profile's 12 words.
   None is a profile-existence oracle. Collapsing them has a concrete cost — someone who typed their
   recovery code correctly and their passphrase wrongly would be sent back to check the recovery code.

   Chooser: the gate reveals **"Passphrase works on your other phone?"** only after a failed sign-in —
   after EVERY failed sign-in, never conditioned on anything the store said, so its appearance says
   nothing about whether a profile exists.

   Also fixed here: `hardenVaultTo` is now shared by both enrol paths, so the cap bracket and the
   refused-publish check cannot drift apart between them — the bug class that produced
   `NWP-20260915-03` and `-06`, and that this repo has now shipped **four** times.

8. **E.3b.7 — A PASSPHRASE CHANGE SURVIVES HARDENING: FIXED 2026-09-15 (`NWP-20260915-10`). NEEDS-DEVICE.**
   `kekSE` is `Argon2id(passphrase, salt=H(name‖se_secret))`, so every `se` slot dies the instant the
   passphrase moves — exactly like a `fido2` slot, for exactly the same reason. `rotateVault` already solved
   that for keys (present key follows, absent key dropped, refuse if every key would be dropped) and the
   `se` slots were simply never given the same treatment: the loop was GATED on `fido2HMAC() != nil ||
   len(listFido2Slots(v)) > 0`, so on a hardened non-2FA vault it never ran at all.

   **The rotation contract is now one policy for both kinds:** the present device's slot FOLLOWS the
   rotation, an absent device's slot is RETIRED (and counted, so the screen can say how many), and if
   nothing this device holds would survive, the rotation **REFUSES and writes nothing**. That third clause
   is what makes *"this phone keeps working"* unconditionally true, which is why the screen can now promise
   it before the user commits.

   ⚠ **The secret is passed as an ARGUMENT, never read from the environment.** `seDK` reads
   `NOWHERE_SE_SECRET`, which the login daemon does not have and cannot get; the ROTATE handler reads the
   live session's own secret from `.roamsession` line 4 (`readRoamSessionSE`) and hands it in — the
   `enrollSE` / `hardenVaultTo` shape. ⚠ **That blindness affected far more than rotation** — fixed
   for the two P0 legs by `NWP-20260915-12`, the same day. ⚠ **And the mechanism as stated here was
   wrong:** the lease does NOT lapse. `capFlush` re-leases every ref it writes and `putRef` buffers head
   pointers unconditionally, so the heads stay leased forever; what lapses is the COLD CHUNK SET, because
   `postBlob` short-circuits on a `blobCacheKnown` hit and `maybePayRent` is the only full-footprint
   re-lease in the system. With the head still live the GC deletes those chunks INDIVIDUALLY beneath it.
   See `docs/cap-bootstrap.md` for the corrected account and the 120-day clock.

   **Two pre-existing defects were fixed with it, because without them the fix's own success message is
   false.** Neither is specific to hardening; both have applied to every successful rotation, Diaspore
   included. (i) The roamed user's **keyguard** was never re-keyed — `armCredentialOnScreenOff` captures
   the passphrase typed at the gate as a `final String` and is one-shot — so the screen lock still wanted
   the old passphrase; the handler now re-keys through the `su:s0` worker FIRST and rolls back if the
   rotation then refuses, which is `handlePromote2`'s rule. (ii) The session's **restore receipts** stayed
   filed under the old credential, so the next seal — and above all the logoff capture — was REFUSED for
   want of a receipt at the new ref; they are migrated now (moved, never minted).

   Wire: `ROTATE` → `OK <n>` / `ERR-SECRET` / `ERR-STRAND` / `ERR-MULTI` / `ERR-REKEY` / `ERR-SESSION` /
   `ERR-STORE` / `ERR` / `BLANK`. ⚠ Every named refusal is **gated on the live session** — emitted only when
   the request is the signed-in session's own `(name, oldpass)` — so the socket's answer to a stranger is
   byte-identical to before and blind login is untouched.

9. **E.3b.8 — HARDENED *AND* KEY-ENROLLED IS A SUPPORTED COMBINATION NOW: FIXED 2026-09-15
   (`NWP-20260915-13`). NEEDS-DEVICE.** It was not reachable before, and not by design — all three
   FIDO2 entry points were blind on a hardened vault, for the same reason everything else was: the `pass`
   slot is gone, and the ladder fell through to an environment the login daemon never carries. USB enrol
   handed the `su:s0` worker an EMPTY `se_secret` (`roamd` exports line 5 only when it is non-empty);
   NFC enrol and remove run in the daemon. So **a hardened profile could neither add nor remove a
   security key**, and the 2FA tier did not work on the edition it was built for.

   ⚠ **And removing the last key used to UN-HARDEN the vault, silently.** `removeFido2Key` re-adds a
   `pass` slot when the last key goes, so the user is not stranded — but its premise, *"the vault
   would have neither a pass nor a fido2 slot"*, is false when `se` slots exist: this handset's secure
   element still opens it, and so do the 12 words. Re-adding a passphrase slot there handed back exactly
   the offline brute-force surface that dropping it bought, and nothing wrote `Hardened` — so the
   vault went on REPORTING hardened while no longer being it, which would have falsified
   [`threat-model.md`](threat-model.md)'s edition claim for that profile with nothing to say so. The
   re-add now asks about every slot kind, not just `fido2`.

   **Order of operations, for whoever reads this next:** harden first, then enrol. `enrollFido2`'s
   first-enrol branch drops every `pass` slot, and `enrollSE` needs one to open by — so enrolling a
   key BEFORE hardening still leaves the profile unable to harden, and the way in is `ADD-DEVICE` with
   the 12 words (E.3b.6). That asymmetry is not fixed here.

## Open decisions
- ~~The carve-out (amnesiac-for-data + persistent-SE-unlock)~~ — **CONFIRMED by Chester 2026-06-20** (per-identity `Hardened` opt-in; FP3 unaffected).
- **Throttle primitive:** Weaver (preferred — true hardware throttle) vs. a Keymint auth-bound StrongBox key
  with `setUserAuthenticationValidityDuration` (simpler but coarser). Confirm Weaver is reachable on lynx.
- **Multi-device — PARTLY CLOSED 2026-09-15 (`NWP-20260915-09`, E.3b.6).** *How a second handset enrols*
  is answered: `ADD-DEVICE`, additive, unlimited slots, each handset one slot, proven for three. **What is
  still open is REVOCATION** — there is no way to remove a lost handset's `se` slot. Today the only lever
  is `recoverVault`, which replaces the whole slot list: it does revoke the lost device, and it revokes
  every other one at the same time, so each surviving handset must be re-added. That is a usable answer
  for one-phone owners and a poor one for anyone who added a second on purpose. **Filed as
  `NWP-20260915-11`.** *(Answered 2026-10-20, `NWP-20261020-47` (Q011, the entry "twenty-eight recommendations accepted — the beta OTA ring retires ..." in `docs/product-decisions.md`, `NWP-20261020-47`): a lost phone is revoked by **changing the passphrase**, which retires every other phone's slot and moves every store ref, each phone kept then being added again with the 12 words; nothing new is built now. The lever named above is corrected: by the 2026-09-15 decision recovery answers a forgotten passphrase, never a compromised one, so it is not the revocation path. A per-phone slot removal is built only if tied multi-phone profiles become common; a full re-key is not funded.)*
- ✅ **A passphrase change used to lock out every handset — FIXED 2026-09-15 (`NWP-20260915-10`, E.3b.7
  in the slice list above).** ⚠ **AND THE SYMPTOM AS FIRST RECORDED HERE WAS WRONG IN A WAY WORTH KEEPING.** This bullet said
  the daemon answered `OK`. That is what the *probe* did, because the probe put `NOWHERE_SE_SECRET` in its
  own process environment. The login daemon never has it — the sole exporter in the tree is
  `nowhere_roamd.sh`, inside the `su:s0` **worker**, and `nowhere_login.sh` exports a closed list that does
  not include it. So on a real handset the rotation *refused*: `"pass slot won't unwrap"` → `BLANK` →
  *"couldn't change — check your current passphrase"*, **a false accusation against a correct passphrase**,
  with nothing written. Both are bugs and they needed different fixes; the lesson is that a probe which sets
  an environment variable the real process cannot have is measuring a different program.
