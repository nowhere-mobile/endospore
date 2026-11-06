# Managed app updates — the store as version authority (DIA-20260731)

**Goal.** Make the Nowhere app store the authority for which *version* of an app a user runs, so a broken
upstream update can never silently reach devices. This is the direct answer to the class of incident where
F-Droid pushed Fennec 152 and it crashed on our secondary/roamed users (see `bundled-app-version-pinning`): we
pin a version we've *tested on our OS*, and the store is what installs and updates it.

The catalog already pins versions: every `catalogEntry` carries a `versionCode` + `url` + `sha256`, `FETCH-APP`
installs exactly that, and Phase 4c signed publishing (`REFRESH-CATALOG`) can push a new pinned catalog to devices
**without an OTA**. So the *publish* side of version authority exists. Managed updates add the *consume* side.

## Slice 1 — update surfacing + apply (DONE)

Chooser-only; the daemon `FETCH-APP` already fetches the catalog's pinned version.

- `paintStoreAction` compares the **installed** `versionCode` (`installedVc`) against the catalog's pinned
  `versionCode`. When the catalog is **newer**, the row's chip becomes **"Update"** (accent) instead of
  **"Added"**.
- Tapping **Update** runs the same `fetchApp` → `installStagedApk` path as a fresh install: it fetches the
  catalog-pinned APK, verifies its **signer** against the entry's `signingCert` (an update from a different key is
  refused), and `PackageInstaller` upgrades it in place — keeping the app's data and its keep-mode. The toast says
  "updated." At the next seal the newer version rides into `#apps` and roams.
- Only fires for **vetted, version-pinned** sources (`fdroid` / `nowhere`). `play` apps carry no pinned version
  (they're Aurora-managed), so they never show "Update" from our catalog.

This gives full version authority for any app whose only update channel is our store.

## Slice 2 — suppress uncontrolled upstream updates (FUTURE)

Slice 1 lets us *offer* the tested version; it does not yet *stop* another channel from installing an untested one.
Two leaks to close so the pin holds:

1. **The bundled F-Droid client / Aurora auto-updating** a store-managed app to a newer upstream build. Store-
   managed apps need a "hands-off upstream" marker those clients respect (or are configured to ignore).
2. **The roam seal capturing whatever is currently installed** — so an in-session upstream update would propagate
   to the user's other phones via `#apps`. The seal (or the keep-set) must prefer the catalog-pinned version for a
   store-managed app rather than blindly sealing the on-device one.

## Slice 3 — bundled vs store-managed (DECISION)

The Fennec incident was a **bundled** app (`/product`, updated via OTA + an F-Droid overlay), not a store-installed
one. Bundled apps update on the OTA track; the store's authority covers **store-installed** apps. Open choice:
move some bundled apps to store-managed so the same authority covers them, or keep them bundled and just block the
F-Droid overlay.

⚠ **DECIDED for Endospore, 2026-09-24 (`NWP-20260924-05`, `product-decisions.md`):** keep them bundled. On Endospore
they move only with the OS image, and GrapheneOS already blocks the F-Droid overlay (it refuses every system-app
update not from its first-party app source); our store becoming an allowed updater of bundled apps is the later
step (b). On Diaspore the overlay is not blocked and this choice stays open.

## The commitment

Being the version authority is an operational commitment, not just a feature: if we pin versions and (Slice 2)
suppress upstream, then **we** own shipping updates promptly — **including security updates**. A pinned-but-stale
app is a liability. Same cadence discipline as the OTA policy: someone curates + tests + republishes on a schedule.
