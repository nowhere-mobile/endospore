# Tying a profile's scopes to the phone — design (NWP-20261006-16)
<!-- backlog: a tie does not protect a profile's scopes -->

Status: **DESIGN — DECIDED 2026-10-06** (§5; `docs/product-decisions.md`), **two further decisions 2026-10-07** (§7), **build plan §8**; slices 1 and 2 BUILT and device-proven (`NWP-20261007-11`, `-12`); **slice 3 planned in §9** (2026-10-08), with its two decisions; **slices 3a and 3b BUILT and device-proven on lynx 2026-10-08** (`NWP-20261008-03`, `-04`, `-05`), except the automatic finish at sign-in, which has no TIED PARTIAL profile to run on (its own row in `docs/backlog.md` §A). The backlog row this design answered is closed (§H, 2026-10-08). Backlog row: *“P1 SECURITY: a tie does not protect a
profile's scopes — `#de`, `#sys`, `#media`, `#apps`, `#keys` are keyed by the passphrase”*.

## 1. What is true today

A profile is several stored heads. The **vault** (the main app data, `name`) is opened through keyslots that wrap a
random data key (DK): a `pass` slot, a `recovery` slot, and — when tied (`NWP-20261006-09`) — a `se` slot for this
phone's chip instead of the `pass` slot. `#wallet` is sealed under the DK too (`scopeSealedUnderDK`).

Every other scope is keyed by the passphrase. For `name#de`, `name#sys`, `name#media`, `name#apps`, `name#keys`:

- the scope key is `K = deriveKey(name#scope, passphrase)` (Argon2id), and its head is a bare head sealed under `K`
  (`resolveKeyHead`'s legacy branch);
- every chunk is sealed **directly** with `K`: `seal(K, chunk)` (`main.go`), with a nonce that is an HMAC under `K`
  so unchanged data dedups;
- the scope index in the vault (`deriveScopeIndex`, sealed under `kekScopes(DK)`) only *records* `K`, so a recovery
  can find the scopes after a passphrase change.

So whoever guesses the passphrase derives `K` for every scope directly. A tie protects the main app data and the
wallet, and nothing else — photos and files, installed apps, the Keystore keys that keep apps signed in, settings
and device-encrypted data stay offline-guessable, tied or not. (Found by the cross-phone test on 2026-10-06; the tie
screen and `threat-model.md` were corrected the same day, `NWP-20261006-10`.)

## 2. Why this cannot be a rewrap

Wrapping `K` under the chip changes nothing while `K` is still `deriveKey(name#scope, passphrase)`: the attacker does
not need the wrapper, he derives `K` himself. Protecting a scope means giving it a **new random key** and
**re-sealing its content** under it. With convergent sealing every chunk's ciphertext changes, so the scope is
**uploaded again** — and stored again until the old copy's leases lapse.

## 3. What already exists and helps

- ~~**Reading needs no new path.**~~ *(Superseded 2026-10-07, `NWP-20261007-10`: false for `#keys`. It is sealed during the end-of-session cleanup, whose stashed credentials carry no secure-element secret, so a push of an se-only `#keys` head fails with “no slot opens” and the dump is then destroyed — every app signed out after every session. The fix is in §8.)* Scope readers go through `resolveKeyHead(base, name#scope, pass)`, which already
  accepts a scope head that is a *vault*, and `openVaultDK` already tries an `se` slot keyed on the scope name
  (`kekSE(name#scope, pass, se)`) with the chip secret roamd exports. A scope whose head is a vault with only an `se`
  slot (and the DK-held index entry for recovery) is read by today's code.
- **Credential changes already re-point scopes to vault heads** ("a vault wrapping the PRESERVED original key",
  rotateVault). The machinery to publish a vault head for a scope exists; what does not exist is a scope with a
  random key.
- **Seals keep the keyslots they read** ("keep the keyslots; just repoint"), so once a scope's head is a vault, later
  seals preserve its slots.

## 4. The shape

**Tie** (per scope, after the vault's own tie):

1. Mint a random `K'` for the scope.
2. Re-seal the scope's content under `K'`: ~~for the small scopes, read and re-push in the session (they are on the
   phone)~~ *(superseded 2026-10-07, `NWP-20261007-10`: the `#keys` dump exists only at the end-of-session cleanup and `#sys` is staged only at logoff, so neither is on the phone at tie time; every scope is re-encrypted FROM THE STORE instead, §8)*; for `#media` and `#apps`, see §5 Q1.
3. Publish the scope head as a vault: the content under `K'`, slots = this phone's `se` slot over `K'`; record `K'`
   in the scope index (under `kekScopes(DK)`), so the 12 words still recover it.
4. Only after the new head is published, stop leasing the old content (it ages out like any superseded data).

**Untie:** no re-upload. Add a `pass` slot over `K'` to each scope head and drop the `se` slots — `K'` stays random,
so nothing is re-sealed; the scope is passphrase-openable again, which is what untie means.

**Add this phone:** add this phone's `se` slot to each scope head too (it holds the DK via the recovery code, and the
index gives it every `K'`). *(2026-10-07: required in the FIRST slice, not later — without it a phone added to a tied profile opens the vault but not its scopes, so its restore reads them blank and its seals of them fail. §8.)*

**Recovery:** unchanged in principle — the index under the DK names every scope's key. A recovery that sets a new
passphrase re-adds `pass` slots.

**Untied profiles are not touched.** Their scopes stay `deriveKey(name#scope, passphrase)`; nothing is re-uploaded
for anyone who does not tie.

## 5. Decisions needed

**Q1 — Which scopes does a tie protect, given the re-upload?**
`#keys`, `#sys` and `#de` are small (kilobytes to a few MB). `#media` (photos, files) and `#apps` (installed app code)
can be gigabytes: re-sealing them means re-uploading them all, at the profile's own storage cost and data use, and it
cannot finish while the phone is offline.
- (a) **All five, at tie time** — the tie takes as long as a full upload of the profile, and the screen says so with
  the size.
- (b) **The small three at tie time; `#media` and `#apps` in the background** after the tie, resumable across
  sessions, with the settings screen showing "photos and files: protecting… 40%". The claim stays partial until it
  finishes.
- (c) **The small three only; `#media` and `#apps` stay passphrase-keyed**, and the screen says so permanently.

My recommendation is (b): the keys that keep apps signed in and settings are protected immediately, and nothing
promises photos are covered until they are. **DECIDED: (b)** (Chester, 2026-10-06).

**Q2 — What does the tie cost, and who pays?** Re-uploaded content is new storage until the old copy's leases lapse
(billing: the old chunks keep their lease until expiry). Either the profile's own tokens pay for the overlap, or the
gateway does not charge for a re-key. This touches the token economics (`docs/billing-model.md`), so it is yours. **DECIDED: the profile's own tokens
pay**, billed like any seal, and the tie screen states the estimated size (Chester, 2026-10-06).

**Q3 — Existing tied profiles** (tied today by `NWP-20261006-09` or before): re-key their scopes at their next
sign-in on the tied phone (the same flow as a tie), or only when the user re-ties? **DECIDED: at their next sign-in on
the tied phone**, once, automatically (Chester, 2026-10-06).

## 6. Not decided here

The exact on-store format of a scope vault (it should be today's `vault` struct with `Manifest` naming the scope's
manifest), the per-scope progress record for Q1(b), and the order of publishes for crash safety. Those follow the
answers above and are the slice's own design work.

## 7. Two further decisions (2026-10-07)

Raised by the build plan (§8), answered by Chester on 2026-10-07; recorded in `docs/product-decisions.md`.

- **A tie re-encrypts the scopes' saved history too.** A scope head that is a vault carries its retained snapshots
  (`History`), sealed under the old key `K`. The tie re-seals every retained snapshot's manifest and chunks under
  `K'` as well, so “Restore a snapshot” still reaches versions from before the tie, and a passphrase guess opens
  none of them. Cost: the retained versions are uploaded and paid for again (chunks shared with the live version
  are re-sealed once — the nonce is an HMAC of the plaintext under `K'`, so identical plaintext gives an identical
  blob). Options not taken: drop the history at tie, or leave it passphrase-keyed until it ages out.
- **The chip secret joins the passphrase in the end-of-session `#keys` stash.** `#keys` is pushed during the
  cleanup that runs after the user stops, from credentials roamd stashed at logoff (`KS_CREDS`, a root-only tmpfs
  file consumed at use). On a tied profile that push needs the secure-element secret too, so it is stashed beside
  the passphrase, with the same lifetime: deleted at use, gone at power-off.

## 8. Build plan (2026-10-07, `NWP-20261007-10`)

**Mechanism: re-encrypt from the store.** Re-pushing from the device cannot work (§4 step 2, superseded), and
publishing a vault head before its content is re-sealed leaves the scope readable by nothing in the gap. So, per
scope: resolve the current head (a bare head under `K = deriveKey(name#scope, pass)`, or a vault opened with the
session's `se`); take `K'` (random, or the pending one on a resume, so re-uploads dedup); fetch every chunk named by
the live manifest, its `Deferred` regions and every retained snapshot, `unseal(K)`, `seal(K')`, upload; rewrite the
manifests (sizes are unchanged — same overhead); publish the scope as a vault `{slots: se over K', Manifest,
History re-sealed, Version+1}` signed with `K'`. A scope that does not exist yet gets a placeholder vault (an empty
manifest under `K'`) so its first seal does not create a passphrase-keyed head. An unreadable scope is reported
and left as it is.

**The index carries both keys while a re-key is in flight.** `scopeRec` gains `Prev` (the previous key, wrapped
under the DK) and `Minted` (the key is random, not passphrase-derived). A reader picks whichever of `Wrapped`/`Prev`
verifies against what is actually at the ref, and refuses loudly if neither does.

**Publish order — crash-safe at every step**, inside one `capWrite` bracket (one lease, paid from the profile's own
tokens) while the worker slot and the session lock are held:
1. Upload every re-sealed blob and manifest for the scopes. *A crash here references nothing; the old state stands.*
2. Publish the vault with its tie slots and an index whose scopes read `{Wrapped: K', Prev: K, Minted}`.
   *A crash here leaves the scope heads old; the tied phone opens them with `K`, recovery finds `Prev`.*
3. Publish each scope head, refusing if the head moved since step 1. *A crash between scopes leaves each one
   either old (`Prev` verifies) or new (`Wrapped` verifies).*

Old chunks stay leased while the footprint names the old heads (until step 3) and lapse after.

**Untie** adds a pass slot over `K'` to each scope head and drops its `se` slots — no re-upload, the index is
unchanged — then unties the vault. A crash between the two leaves the vault tied, so Untie can run again.

**Other paths a tie must survive, built in the same slices:**
- **Passphrase change** (`repointScopes`): today it would re-wrap `K'` under a pass slot and silently undo the tie.
  It takes the session's `se` and, where a scope head had an `se` slot, republishes it `se`-only under the new
  passphrase. Recovery has no `se` and gets a pass slot, which matches “recovery comes back untied”.
- **Add this phone** (`enrollSEViaRecovery`): adds the new phone's `se` slot to each protected scope head.
- **The `#keys` push at cleanup:** the stash carries the `se` secret (§7) and the cleanup exports it.
- **Status:** `SE-STATUS` answers `TIED PARTIAL` while any small scope is not yet protected; Tie on a
  partly-tied profile runs only the scope re-key. The settings screen shows that state.

**Slices:** (1) the agent groundwork — index fields, the re-key and history re-seal, the scope untie, the
passphrase-change and add-phone paths — with no caller, so nothing changes on a device; (2) the wiring — Tie,
Untie and status, the `#keys` stash, the settings screen; (3) `#media`/`#apps` in the background, and the re-key at
sign-in for profiles tied before this shipped (§5 Q3).

## 9. Slice 3 — `#media` and `#apps` in the background, and the re-key at sign-in (2026-10-08, `NWP-20261008-02`)

**Decided** (Chester, 2026-10-08; `docs/product-decisions.md`): the job follows the profile's “download over mobile
data” switch (off, the default, means unmetered networks only), and pauses while the battery is under 20% and not
charging.

**Why the small-scope mechanism cannot be reused as it is.** `prepareScopeRekey` re-seals a whole scope inside one
`capWrite` bracket, and in cap mode `postBlob` buffers every blob until the flush — the whole scope in memory.
Chester's main profile names ~500 MB of on-demand files in `#media` and ~690 MB in `#apps`; deferred chunks are not
on the phone, so each must be downloaded, re-sealed and uploaded. One bracket would run the phone out of memory (the
`#45` failure), and nothing would survive a sign-out halfway through.

**Why the in-flight state must be in the store and in the footprint.** The gateway keeps what the footprint names
(`profileFootprintRec`: every chunk reachable from a scope head); an upload is leased only by the bracket that paid
for it. Chunks re-sealed across several sessions are named by no head until the switch, so without more they lapse
and the GC reaps them before the switch — and the switched head would then name chunks that are gone.

**Mechanism: a session-bound daemon job, per large scope, in batches.**
- **State, in the scope's index entry** (sealed under `kekScopes(DK)` like the rest of the index): `Next`, the new
  key `K'` wrapped under the DK, and `Progress`, the hash of a progress record sealed under `K'` — the head being
  re-keyed and the map of old chunk hash → re-sealed chunk hash. `Wrapped` keeps the current key until the switch,
  so no existing reader, seal, passphrase change or recovery sees anything new while a job is in flight.
- **Footprint:** `profileFootprintRec` also leases the progress record and every re-sealed chunk in its map, so the
  work survives between sessions until the switch, and lapses after an abandoned job is cleared.
- **A batch** holds the worker slot (the seal lane, so it never interleaves with a seal), re-seals up to a bounded
  size of not-yet-mapped chunks of the current head, its deferred regions and its retained snapshots, flushes them in
  its own `capWrite` bracket (the profile's tokens, as decided), and publishes the vault with `Progress` extended.
  A crash loses at most that batch; its blobs dedup on the next pass (the nonce is an HMAC under `K'`).
- **Gating, checked before every batch:** a tied session is up on a phone whose chip opens the vault; the network is
  unmetered unless the profile's mobile-data switch is on; the battery is at 20% or more, or charging; the plan has
  credit. Otherwise the job waits; it stops at sign-out and resumes at the next sign-in from `Progress`. Where the
  battery state is read from under enforcing sepolicy (the daemon itself, or the chooser telling it) is settled by
  the slice on the device.
- **Seals in between are unchanged.** A seal of `#media` keeps writing heads under the current key. Each batch works
  from the head current at that moment, skipping mapped chunks, so new content is picked up as it arrives.
- **The switch** — when every chunk of the current head and its history is mapped: build the manifests under `K'`
  from the map, then the same crash-safe order as the small scopes: publish the vault with `{Wrapped: K', Prev: K,
  Minted}` ~~(`Next`/`Progress` cleared)~~, then the scope head as an `se`-only vault, refused if the head moved since the
  manifests were built (then one more batch and switch). *(Corrected while building 3a, `NWP-20261008-03`: `Next` and
  `Progress` stay in the switch's vault and are cleared by the next step, once it sees the head tied. A refused
  pointer skips only itself — the rest of the flush is written — so a head that moved lets the vault land while the
  head does not, and a job cleared in that vault would start over under a fresh key and pay for every upload again.)*
- **Untie mid-flight** clears `Next`/`Progress`; nothing was switched, and the uploaded blobs lapse. Untie after the
  switch is the small scopes' untie (a pass slot over the same key, no re-upload).
- **Another tied phone** (one added with “Add this phone”) can resume the same job from the store. Two phones running
  it at once must not lose each other's progress: each batch's vault publish is refused if the vault moved since the
  batch read it, and the batch is retried from the newer `Progress` (a requirement on slice 3a, with its own test).

**As built (3a, `NWP-20261008-03`).** `largeScopeRekeyStep` (`core/agent/scope_rekey_job.go`) is one step — a
batch or the switch — run by `rekeyLoop` in the login daemon every 20 s, one unit of work per tick, only while the
gate's `REKEY-ARM` names this session and nothing that must not wait is in flight (a sign-out, reap or switch, a
seal, a cold lock); the worker slot is only *tried*, so a seal holding it wins. The gate's watcher sends
`REKEY-ARM`/`REKEY-DISARM` on a change, from the prefetch network rule and the battery (20% or more, or plugged in,
from the sticky battery broadcast — so the sepolicy question above did not arise). A batch is bounded at 16 MB of
re-sealed bytes. Each reading of the vault and scope head ref is disarmed once its bracket has flushed
(`disarmExpect`): the daemon is one process for the boot, and a reading left armed would refuse a later, unrelated
publish of the same ref.

**Progress on the Tie screen.** `SE-STATUS` adds a line per large scope in flight, `MEDIA <done> <total>` and
`APPS <done> <total>` in bytes, and the screen shows “Photos and files: protecting… 40% (1.1 of 2.6 GB)”, why it is
waiting when it is (Wi-Fi, battery, storage plan), and nothing once a scope is done. `OK TIED` keeps its meaning (the
small scopes); the screen stops saying photos, files and installed apps are passphrase-only once each one switches.

**As built (3b, `NWP-20261008-04`).** `SE-PROGRESS` (the session's own chooser, the same caller check as
`SE-STATUS`) answers `OK NONE` for an untied profile, else `OK` and `MEDIA|APPS <state> <done> <total>` per scope:
`done`, `running`, `wifi`, `net`, `battery` (the gate's reason, sent as `REKEY-WAIT-WIFI`/`-NET`/`-BATTERY` in place
of a bare disarm and kept per session in `rekey.wait`), `credit`, or `waiting`. The Tie screen polls it every 5 s
while it is showing and drops a scope once it is done; once both are, one line says the photos, files and apps are
protected by the chip too. The tied and untied texts no longer call them passphrase-only outright: the untied text
says they follow in the background and on what terms, and until each is done the screen says the passphrase still
opens it. The sign-in finish is `finishTieAtSignIn`, started from `handleGrantPerms` beside mediad.

**The re-key at sign-in (§5 Q3).** After a tied profile's login lands, if its small scopes are not all tied on this
phone (`TIED PARTIAL` — every profile tied before `NWP-20261007-12`), the daemon runs the small-scope re-key once,
in the background under the worker slot (`sessionTie`'s scope half), then starts the large-scope job. A failure leaves
`TIED PARTIAL` and the manual “Finish tying” on the Tie screen.

**Slices.** (3a) the agent job for `#media`/`#apps` — the index fields, batching, progress record, footprint, gating
and the switch — tested in a cap-mode store with a scope larger than one batch, a crash between batches, a seal
between batches, a head that moved at the switch, an untie mid-flight and a resume from the store; (3b) the progress
on the Tie screen and the re-key at sign-in.
