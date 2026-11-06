# Nowhere — OS OTA distribution channel (decouple from the user-data store)

Status: design · 2026-06-23 · pairs with the OTA work (P4.4 signed A/B payload via `update_engine`; P4.4b
content-addressed delivery) and data-portability.md.

The **device-side** OTA apply is done and proven: a signed A/B `update_engine` payload, delivered as
**content-addressed CDC chunks**, applies on a LOCKED device with no unlock and A/B-rolls-back both ways
(P4.4 / P4.4b). What this doc fixes is **where the payload comes from**: P4.4b reused the agent's store
client and shipped the OS payload through the **per-user data store**. That conflates two very different
things and should be split.

## Why the OS OTA must NOT ride the user-data store

| | User-data store | OS OTA payload |
|---|---|---|
| Scope | **Per identity** (one vault per `name+pass`) | **Device-wide** (one image per variant, all devices) |
| Secrecy | **Secret** → client-encrypted ciphertext (zero-knowledge) | **Public** → signed, anyone may read it |
| Who hosts | The user (managed tier, BYO-store, or cold archive) | **The vendor** (central release) |
| Trust | Confidentiality (only the key-holder decrypts) | **Integrity** (the device verifies the signature) |

Riding the user store breaks all four: every user's bucket would have to carry the OS payload (duplicated
N×); a user who **self-hosts or cold-archives** their store (a first-class feature — see
data-portability.md) would **stop receiving OS updates**; and the public OS image
would be sitting inside private vaults. The OS update belongs on its **own channel**.

## Design: a vendor OS channel, content-addressed + signed

- **Separate namespace, vendor-controlled.** A read-only OS distribution endpoint (a public S3-compatible
  bucket / object store / CDN), independent of any user store. Keyed by **`(variant, version)`** — e.g.
  `lineage_FP3` / `lynx`, version `0.3.0`.
- **Reuse the content-addressed model.** Keep the P4.4b CDC chunking + manifest, but in the OS namespace —
  so **delta download is free** (the device fetches only changed chunks) and the **device-side chunk cache**
  (the P4.4b follow-on) gives true delta OTAs.
- **Public is safe — integrity, not secrecy.** The payload is signed (`update_engine` payload key) and the
  device verifies it against its baked **OTA/AVB key** before applying. So the channel needs **no
  encryption and no read auth** — a hostile mirror cannot forge an update, only refuse to serve one. (This
  is the inverse of the user store, which is encrypted precisely because it is secret.)
- **Discovery: a small signed release manifest** per variant — `latest` version + the payload's chunk-
  manifest ref ~~(+ min-version / staged-rollout fields later)~~ *(superseded 2026-10-20: no min-version field is built, by decision (Q131, "sixteen recommendations accepted — Play's download cache does not roam; profile presets ..."); the device ring is retired and staged rollout is built when there is a production fleet, with the ring in its own conf (Q002, "twenty-eight recommendations accepted — the beta OTA ring retires ..."), both in `docs/product-decisions.md`)*. The device's OTA worker (`nowhere_otad`) polls
  *this* (not the user store) for "is there a newer OS for my variant?".

## Config split

- The **OS channel endpoint** is baked into `/system` (or a small separate provisioned config),
  **distinct from `/data/nowhere/nowhere.conf`** (the user-store config). A device with **no user store at
  all** (un-enrolled, or between profiles) still checks for and applies OS updates.
- This also cleanly separates the two trust roots: the user-store keys (the user's) vs. the OS-channel
  endpoint + the OTA signing key (the vendor's).

## Migration from the store-coupled OTA (P4.4b)

1. Stand up the OS channel (a `nowhere-os` read-only bucket / endpoint) and a **publish** step that pushes
   the signed payload + release manifest there (instead of `create-vault os-* / push` into a user store).
2. Point `nowhere_otad` at the OS channel + the baked endpoint, verifying the signed manifest.
3. The **device-side apply is unchanged** (`update_engine`, A/B, content-addressed chunks, chunk cache).

Net: the same proven apply path, fed by a public, vendor-controlled, signature-verified channel that is
independent of where (or whether) the user keeps their data.

## Endospore

Same channel model; the secure edition verifies the same signed payload through its (Pixel) verified-boot
key. The OS channel is edition-agnostic — only the `variant` key and the signing key differ.

## Open items

- ~~Staged rollout~~ **done** — a beta/canary ring gets the release first, promote-to-all is a marker-only
  copy (the payload is content-addressed, so no re-upload). Operator tooling: `e4-ota-publish.sh --beta` +
  `e4-ota-promote.sh`; see [ota-staged-rollout.md](ota-staged-rollout.md). ~~Remaining: the device-side ring
  selector so a canary device auto-reads its ring (a small `otaVersionRef()`/`nowhere_otad` change, tracked
  in that doc).~~ *(Superseded 2026-10-20, `NWP-20261020-47`: not built. Chester retired the device ring (Q002, the entry "twenty-eight recommendations accepted — the beta OTA ring retires ..." in `docs/product-decisions.md`); no phone reads a ring marker, and staged rollout is built when there is a production fleet, with the ring in its own conf; see ota-staged-rollout.md "Device follow-up".)*
- ~~Min-version gating in the release manifest.~~ *(Not built, by decision 2026-10-20 (Q131): no apply-time floor in the agent; update_engine refuses an older payload on the OTA path, and the downgrade guard is measured first on a relocked user build; see `docs/product-decisions.md`, "sixteen recommendations accepted — Play's download cache does not roam; profile presets ...".)*
- ~~Signing-key custody + rotation for the OS payload (separate from the per-device AVB root).~~ *(Decided 2026-10-20 (Q130): today's custody written down with Chester the named holder, two encrypted offline backups, and a rotation and compromise playbook in `release-runbook.md`; see `product-decisions.md`, "five recommendations accepted — the CRA basics are SPDX, a 90-day ...".)*
- Whether the release manifest is served from the same object store or a tiny HTTPS endpoint (the latter
  makes staged rollout + telemetry easier). *(Narrowed 2026-10-24, dn-1023 #6, `docs/product-decisions.md`, the entry "fourteen recommendations accepted — a key-only profile may keep a passphrase ...": an un-enrolled or self-hosting phone gets OS updates, by a public read of the per-release payload under `os/<dev>/` from a vendor endpoint baked into the image. Which of the two that endpoint is, is left to the OS payload layout design, done interactively before its slices are harvested (dn-1023 #7).)*
