# Store installs any F-Droid app — build plan (DIA-20260731)

**Goal.** The Nowhere store ("Get apps") lets a user **search and install any F-Droid app**, on-device, through
the privileged store install path — not just the ~12 curated/featured entries. F-Droid itself stays **browse-only**
(it can't install on this OS: device policy `no_install_unknown_sources` + GrapheneOS
`persist.allow_unknown_system_app_updates`). The store is the one privileged installer.

This plan is the output of a 4-facet design pass + a 2-lens adversarial review (both reviewers: *sound with
fixes*). Every fix below is folded in.

## Architecture (decided)

- **On-device search + install.** Our servers never learn *what* a user installs — search and install run on the
  device against a local index.
- **Trimmed, Nowhere-signed F-Droid index** (~5–10 MB). It reuses the **existing `catalog`/`catalogEntry`/
  `catalogAPK` structs** (`catalog.go:53-73`) — one APK per entry, `source:"fdroid"` — so `verifyCatalogSig`,
  `fetchAndVerify`, `findCatalogEntry`, and the roamd `stageapp` install path all work unchanged. Two deltas vs
  `catalog.json`: serialize **compact** (indent=2 over ~4000 apps blows past 10 MB), and it's a **distinct file**
  (`index.json`) so the cheap ~12-entry storefront landing never pays the 10 MB parse.
- **Baked snapshot in `/system`** (offline baseline, amnesia-proof, instant first search — the index is fetched
  **lazily on search, never at login**) + a **lazy signed `/data` refresh** (fresh URLs so aged-out apps don't 404).
  **No hard WiFi gate** (would lock out mobile-only roaming users); ~~soft pref + one-time metered heads-up instead.~~ *(Superseded 2026-10-20 (Q079): the refresh follows the profile's existing "Download over mobile data" switch, with a conditional GET; no separate pref and no heads-up; see `docs/product-decisions.md`, "sixteen recommendations accepted — Play's download cache does not roam; profile presets ...".)*

## Trust model (corrected by review — these are load-bearing)

1. **Pin F-Droid's repo cert — MANDATORY.** `curate-catalog.py` currently fetches `index-v2.json` over bare TLS
   with no repo-signature check (`curate-catalog.py:21-30`). Tolerable for 12 hand-checked apps; **unacceptable**
   once an automated job mirrors ~4000. The trim job must fetch `entry.jar`, verify its JAR signature against
   F-Droid's **pinned repo signing-cert SHA-256** (`jarsigner -verify -strict`), and only then trust the index it
   points at. **Gate the whole feature on this** — do not ship TLS-only. *(Pin value must be sourced from
   `fdroidserver`/the F-Droid client, not asserted from memory.)*
2. **Separate index-signing key** (`indexPubKey`), NOT the catalog key. Domain separation: the online index key is
   used by an automated job (larger blast radius); a leak must **not** be able to forge a `/system` catalog
   override. Add `indexPubKey` + `verifyIndexSig` in `catalog.go`; `catalogPubKey`/`verifyCatalogSig` stay
   catalog-only. Chester holds both private keys.
3. **SSRF allow-list.** `fetchAndVerify` (`catalog.go:173-184`) and `handleFetchIcon` (`catalog.go:312-336`) GET
   arbitrary URLs. Enforce `https://` + an `f-droid.org`/configured-mirror **host allow-list** at **both** trim time
   (reject any entry whose url/iconRef leaves the pinned base) and daemon fetch time.
4. **Per-app sha256 + REQUIRED signer.** `signingCert` is `omitempty` and `installStagedApk` **skips** the signer
   gate when empty (`ProfileActivity.java:4686-4691`). In `--all` trim mode, **skip (fail-closed) any entry lacking
   a 64-hex `signingCert`**; add a test asserting every emitted entry carries one.
5. **Honest guarantee.** We guarantee **integrity + provenance** (right bytes, claimed signer) — **not app safety,
   not in-session data protection.** A malicious installed app runs in the roamed user *with the restored real
   profile* (contacts, tokens). The doc + UI must say so, and label index apps **"not curated by Nowhere"** vs the
   vetted featured set.

## Components

### Daemon (`core/agent`, Go)
- **`index.json` / `index.json.sig`** artifact; `indexSystemPath=/system/etc/nowhere/index.json` (baked, verified
  boot) + `indexDataPath=/data/nowhere/index.json` (refreshed, signed; durable by design: the same public file for every device, verified on every read and refused when stale). Baked seed ships in
  `core/vendor-common/etc/`.
- **`loadIndexBytes`** — mirror of `loadCatalogBytes` (`catalog.go:100-121`) but verified with `verifyIndexSig`
  against `indexPubKey`, and **prefer `/data` only when its `generated` ≥ the baked `generated`** (anti-rollback;
  read only the leading `generated` via a streaming decoder, don't full-parse to choose).
- **In-memory parsed cache** (`getIndex()`): parse once, keyed by served-file `mtime:size`, RWMutex-guarded, busted
  on refresh. **This is the answer to "parse 10 MB per keystroke"** — every SEARCH is a cheap in-memory scan.
  Precompute the iconRef set so FETCH-ICON's allow-list check is O(1).
- **`SEARCH-APPS <query>`** verb — scan the cache, rank (exact→prefix→word→substring), **cap 50 server-side**, reply
  length-prefixed (`OK <n>\n<json>` | `NONE`), entries in `catalogEntry` shape with `apks` omitted (via a projection
  struct — note `apks` has no `omitempty`, so a naive strip serializes `"apks":null`) but **`signingCert` kept**
  (the client signer-pin needs it). Merge curated first (so `play`/`nowhere` apps surface), dedupe by pkg, curated
  wins. Empty query → featured set. Sanitize query (trim/tolower/cap ~100/strip control chars). Reply carries
  `generated` + `truncated` so the UI shows "catalog from <date>" and "showing top N".
- **`REFRESH-INDEX`** verb — mirror `REFRESH-CATALOG`; dedicated **`indexHTTPGet` with a ~32 MiB cap** (the current
  8 MiB `catalogHTTPGet` cap at `catalog.go:379` would silently truncate → sig fail → silent fallback). Verify sig
  **after** download (a hostile huge blob still fail-closes). Write-guard: install only if `fetched.generated >
  served.generated`, clamp `generated` (reject ≤0, > now+skew, or missing). Atomic write of **both** file+sig or
  neither. Lazy: SEARCH never blocks on refresh; the client fires REFRESH-INDEX in the background.
- **`FETCH-APP` fallback** — `findIndexEntry` resolves an arbitrary pkg from the index (latest version). Treat a
  requested `vc` as **advisory**: pin it if still present, else fall back to latest before `ERR-NOENTRY`. Don't have
  the client hard-pin the *search-time* signer (a mid-session refresh can change it) — `handleFetchApp` returns the
  resolved signer, or the gate uses the freshly-resolved entry.
- **Compatibility** — carry `minSdkVersion` + `nativecode`/ABI in trimmed entries; filter (or label) incompatible
  apps so a Get doesn't fail with a generic signer-mismatch error. Map PackageInstaller incompatibility → "not
  compatible with this device."
- **Update discovery for long-tail** — a verb that cross-references the roamed user's installed packages against the
  cached index and returns available updates, surfaced in "Your apps" (otherwise managed updates only reach the ~12
  featured apps).

### Chooser (`ProfileActivity.showAppStore`, Java)
- Search box: **debounced (~280 ms, min 2 chars)** → `SEARCH-APPS` → render via existing `renderCatalog`
  (`ProfileActivity.java:4808`), same `catalogEntry` shape. Empty query → curated featured (GET-CATALOG).
- Get → existing `onGetApp`/`getAppInMode`/`installStagedApk` for a non-catalog pkg (thread its fields).
- **Icons** — cap concurrency (bounded pool), fetch **on-screen rows only**, LRU/size-bound `ICON_CACHE`
  (`ProfileActivity.java:4573` currently spawns a thread + f-droid.org GET per not-installed row → thundering herd
  at 50 results/keystroke). Browse-leak tradeoff is a **product decision** (below).
- **Metered detection is client-side** (`ConnectivityManager`, the pattern already in `ChooserActivity`) — the
  daemon *cannot* detect live metered state (no `dumpsys connectivity`; `GET-PREFETCH-METERED` only reads a stored
  pref). ~~Soft "WiFi-only" pref + one-time metered heads-up.~~ *(Superseded 2026-10-20 (Q079): nApps reads the profile's existing mobile-data switch; see `docs/product-decisions.md`, "sixteen recommendations accepted — Play's download cache does not roam; profile presets ...".)*
- Staleness hint ("catalog from <date>"), compatibility label, "not curated by Nowhere" badge for index apps.

### Trim pipeline + build (server-side + build)
- **`trim-fdroid-index.py`** — fetch `index-v2.json` + `entry.jar`, **verify the JAR sig vs the pinned repo cert**,
  run `curate-catalog.py`'s `entry_for` over **all** apps (`--all` mode) + carry minSdk/ABI + require a 64-hex
  signer, emit compact `trimmed-index.json` (schema-1 `catalog` shape), **sign with the index key**, push it to R2
  (`publish-fdroid-index.sh R2_DEST=r2:nowhere/fdroid`). **Gateway-served** (not a public bucket): each gateway
  pulls the signed set from R2 and serves `GET /fdroid/index.json(.sig)`, so `INDEX_URL` points at the gateway
  (`https://api.nowhere.mobile/fdroid/index.json`); R2 stays private and `ServeContent` gives ETag/304 for free.
  Runbook: nowhere-cloud `deploy/fdroid-index-deploy.md`. Cadence: every few hours (VM cron). Server-side
  monitoring/alert if the cert-verify aborts or publish fails (else the index silently goes stale and devices 404).
- **Baked snapshot** — build step drops `index.json` + `.sig` into `vendor/<edition>/etc` → `.mk`
  `PRODUCT_COPY_FILES` to `/system/etc/nowhere/`, exactly like `catalog.json`. **Hash-pin** the fetched snapshot
  (sha256 + generated in a committed lockfile / `.mk` stamp; CI fails if the fetched object doesn't match) so the
  `/system` image stays **reproducible** for the GPL full-source release. Refresh the baked baseline each OS release.
- **Config** — ✅ `nowhere_login.sh` now exports **both** `INDEX_URL` and `CATALOG_URL` (was a dead bug: it exported
  only `S3_*`/`GATEWAY_URL`, so a conf-set URL silently did nothing). ✅ Both documented in `nowhere.conf.example`
  (commented template — real values provisioned out-of-band). ✅ The chooser fires `REFRESH-INDEX` on an independent
  thread when the store opens (`showAppStore` → `refreshIndex()`), so `/data` freshens lazily without blocking search. *(Stale by 2026-10-20: `showAppStore` is gone and nothing calls `REFRESH-INDEX`; the 2026-10-20 decision (Q079) re-wires it in nApps; see `docs/product-decisions.md`, "sixteen recommendations accepted — Play's download cache does not roam; profile presets ...".)*
  ✅ Gateway route + pull tooling landed in nowhere-cloud (`GET /fdroid/{name}` #112 + `deploy/nowhere-fdroid-sync.*`
  + `deploy/fdroid-index-deploy.md` #113). Operational remainder (infra, Chester): configure the rclone R2 remote,
  add the build-VM publish cron, and enable the gateway `nowhere-fdroid-sync.timer`. If `index.json(.sig)` is ever
  committed, add `*.sig -text` to `.gitattributes` (a raw 64-byte sig can contain a CRLF pair `eol=lf` would corrupt).

## Amnesia interaction
- Baked baseline on read-only `/system` → **cold-boot, offline search works**.
- Refresh cache on `/data` → wiped per power-off → re-refreshed per warm session (small pull). **No persistent
  rollback high-water mark** — mitigate by clamping `generated` + rejecting a missing `generated` (freshness is
  load-bearing); document the residual honestly.
- **Metered pref / one-time consent persistence** — `/data` wipe means it re-prompts every boot as designed. Either
  seed a default via roamd (like the Aurora/F-Droid seeds) or accept the re-prompt. ~~**Decide during build.**~~ *(Moot 2026-10-20 (Q079): the switch is the per-profile `nowhere-prefetch-metered` file, which roams with the profile, so there is no device-side pref to persist; see `docs/product-decisions.md`, "sixteen recommendations accepted — Play's download cache does not roam; profile presets ...".)*

## Failure modes
Offline → baked snapshot. Refresh sig-fail / oversized → keep baked (fail-closed) + surface "catalog may be out of
date." Dead baked URL (404) → refresh fixes it; a stale install fails gracefully with a clear message.
Incompatible (minSdk/ABI) → "not compatible with this device." Empty/mismatched signer → refused.

## Product decisions (DECIDED, Chester 2026-07-31)
1. **Curation = everything, with badges.** Ship **all** ~4000 F-Droid apps. Carry F-Droid's anti-feature flags
   (Tracking / NonFreeNet / UpstreamNonFree / Ads / KnownVuln / …) in the trimmed entry and surface them in the UI,
   plus a **"not curated by Nowhere"** badge on every index (non-featured) app. No allow-list gate — the badge +
   the existing `showSideloadWarning` route inform the user; they choose. True to "install any F-Droid app."
2. **Icons = baked icon pack.** Bundle app icons **inside the signed `/system` artifact** so browsing reveals
   **nothing** to f-droid.org — the privacy win. Implications to design for:
   - **Size:** ~15–20 MB of icons on top of the ~10 MB index → **~25–30 MB baked into read-only `/system`.** Confirm
     the partition budget. Downscale icons hard (e.g. 96×96 webp/png) and dedupe to keep it down.
   - **Format:** icon bytes travel with the signed index (a companion signed `icons.pack` covered by the same
     signature, or per-entry embedded — decide at build; a separate signed pack keeps the JSON parse cheap). The
     daemon serves icons from the baked pack via FETCH-ICON (no network), so the chooser icon path is unchanged.
   - **Refresh gap:** the baked pack covers apps **as of build time**. A brand-new app surfaced only by a `/data`
     refresh has **no baked icon** → fall back to a generic placeholder (NOT a live fetch — that would reintroduce
     the leak). Its icon arrives with the next OS release's baked pack. Accept the placeholder for the rare
     brand-new-app case.

*(Also engineering, noted: multi-APK/split-APK apps — `entry_for` emits a single base.apk; split-required apps
would install incompletely. ~~Filter them at trim time or flag "not installable here."~~)* *(Decided 2026-10-20 (Q079): after a check of the live index the split row closes as not applicable, and `trim_entry` refuses any entry whose version record is not a single APK file; see `docs/product-decisions.md`, "sixteen recommendations accepted — Play's download cache does not roam; profile presets ...".)* *(Built NWP-20261102-14: the live index was checked 2026-10-20 -- 4766 packages, none multi-file, so the row is not applicable; `trim-fdroid-index.py` `single_apk` / skip reason `notsingleapk` fail-closes against a future format change.)*

## Phased build
- **A. Trust + pipeline:** `trim-fdroid-index.py` with the F-Droid cert pin + index signing key + `--all` +
  signer-required + host allow-list; baked snapshot + hash-pin; `nowhere_login.sh` export fix.
  - ✅ **`nowhere_login.sh` export fix** (PR #515) — `CATALOG_URL` + `INDEX_URL` now exported.
  - ✅ **`trim-fdroid-index.py` built + tested on the VM.** Verifies `entry.jar`'s JAR sig + pins F-Droid's repo
    cert (fingerprint `43238d51…9c9ccab`, **empirically confirmed** against the live `entry.jar` — not asserted),
    then confirms `index-v2.json`'s sha256 against the signed `entry.json`. Trims all apps to the schema-1 `catalog`
    shape (+ `minSdk` / `nativecode` / `antiFeatures`), requires a 64-hex signer per entry (**fail-closed**), and
    host-allow-lists every url/iconRef. Result: **4112 apps, 2.7 MB compact** (1 skipped: no signer), 0 invariant
    violations. Output is unsigned pending the index key.
  - ✅ **`build-icon-pack.py` built + tested on the VM.** Fetches each app's F-Droid icon (host-allow-listed),
    downscales to a 96×96 palette PNG (ImageMagick `convert -thumbnail -colors 256`), and packs them into
    `icons.pack` — a **ZIP keyed by package name** (the Phase B daemon reads entry `<pkg>` for FETCH-ICON, serving
    icons **locally** → zero browse leak). Result: **3703/3705 icons, 9.9 MB** (2 failed to fetch → on-device
    placeholder). With the index that's **~12.6 MB baked**, under budget. A new app surfaced only by a `/data`
    refresh has no baked icon → generic placeholder (never a live fetch).
  - ✅ **Index-signing key deployed + artifacts signed.** Separate ed25519 index key (`indexPubKey =
    jq+90FnJ…9rllM=`, distinct from `catalogPubKey`) lives ON the build VM (`/mnt/build/keys/index-signing.key`,
    600) — an **online/automation** key (it signs each periodic refresh; smaller blast radius than the offline
    catalog key). `index.json` + `icons.pack` signed + verified against the pubkey.
  - ✅ **`publish-fdroid-index.sh`** — the one-command pipeline (cron-able on the signing host): trim → icon-pack →
    sign both → write `fdroid-index.lock` (sha256 pin of all four files for a reproducible `/system` bake) →
    optional R2 upload for the device's lazy `REFRESH-INDEX`. Signed set persisted at `/mnt/build/fdroid-index/`
    (index.json 2.7 MB + icons.pack 9.9 MB + two .sig + lock).
  - ⏳ Remaining (folds into **Phase B**, since a baked signed index is only useful once the daemon verifies it):
    bake the four files into `/system/etc/nowhere/` (`.mk` + a build step that hash-checks against the committed
    lock) (NWP-20261029-15: the Endospore stage checks the set against the lock written beside it in FDROID_INDEX_DIR, and the lock's index-pubkey against indexPubKey; no lock is committed to the repo, so a committed-lock pin for a reproducible bake is not built.) + wire `INDEX_URL` → R2 for dynamic refresh. Then the Phase B daemon (`indexPubKey` + `verifyIndexSig` +
    `loadIndexBytes` + `SEARCH-APPS` + `REFRESH-INDEX` + `FETCH-APP` fallback) reads them.
- **B. Daemon — ✅ built + tested** (`core/agent/index.go`): `indexPubKey` (separate key) + `verifyIndexSig`
  (shared `verifyEd25519`); `loadIndexBytes` with a newer-than-baked rollback guard; an in-memory parsed cache
  (`getIndex`) so search is an in-memory scan; `SEARCH-APPS` (rank + cap 50 + merge curated, index icons routed to
  the local pack via iconRef=pkg); `REFRESH-INDEX` (32 MiB cap + generated write-guard); `FETCH-APP` `findAppEntry`
  fallback (catalog → index, vc advisory); `servePackIcon` from the baked `icons.pack`. `catalogEntry` gained
  `minSdk`/`nativecode`/`antiFeatures`. Baking wired (`endospore.mk`/`diaspore.mk` + `stage-vendor.sh`). `go vet`
  clean, unit tests pass, proven against the real **4112-app index + 9.9 MB pack**. Remaining B: flash + on-device
  E2E; a build hash-pin check vs `fdroid-index.lock`. (NWP-20261029-15: the Endospore stage checks the set against the lock written beside it in FDROID_INDEX_DIR, and the lock's index-pubkey against indexPubKey; no lock is committed to the repo, so a committed-lock pin for a reproducible bake is not built.)
- **`INDEX_URL` → R2 lazy refresh — ✅ device-side wired** (DIA-20260801-38): `nowhere_login.sh` export fix +
  `nowhere.conf.example` docs + the chooser's `refreshIndex()` on-store-open trigger. Operational remainder is
  Chester's: cron `publish-fdroid-index.sh` with `R2_DEST` + provision `INDEX_URL`. Until then devices serve the
  baked `/system` snapshot (feature works, just frozen at each OS release rather than self-updating).
- **C. Chooser:** search UX + bounded/on-screen icons + client-side metered + staleness/compat/"not curated" labels.
- **D. Long-tail update discovery** verb + "Your apps" surface.

## Test coverage (new, security-focused)
Signed-index rollback (older/future/missing `generated`); oversized-index truncation → fail-closed fallback;
url/iconRef host-pin rejection; empty-signer entry refused; `--all` emits a 64-hex signer for every entry; minSdk/ABI
incompatible → clear message; `INDEX_URL`/`CATALOG_URL` export assertion; SEARCH-APPS query sanitization + result cap.

## Unresolved (track, decide before/at build)
Index-key **rotation/revocation** (a baked `indexPubKey` rotates only via OTA; a leaked online key can push poisoned
overrides until every device OTAs — amnesia limits each device to one power cycle of exposure, but state it) *(decided 2026-11-02, `docs/product-decisions.md`, the entry *"twenty-four answers to the open-decisions list ..."*, #8: a rollover or revocation object signed by the release key, as Q098's bad-build object is, built before the prod store opens)*;
  **The object: verifier built (NWP-20261124-25), not fetched yet** (`core/agent/index_key.go`). The envelope is
  `nowhere-index-key 1`, a newline, the base64url signature, a newline, then the body. The release key
  (`releasePubKey`) signs `nowhere-index-key-v1\0` plus the body, so a release manifest or a build warning cannot pass
  as this object. The phone checks the signature before it parses the body, and refuses a body over 4 KiB. The body is
  JSON `{schema: 1, seq, issued, key?, revoked?: [...]}`. `seq` and `issued` must be present and above 0. `seq` must be
  above the phone's floor (a replay guard). `issued` must be at most one day ahead of the phone's clock. The body must
  name a `key`, revoke at least one key, or both. Every key is standard base64 of a 32-byte ed25519 key (the spelling of
  `indexPubKey`). `revoked` holds at most 16 keys and no duplicate. The new key must not be revoked. All key compares use
  the decoded bytes. The object has no expiry: a rollover stands until an object with a higher seq replaces it. An
  expiry would put every phone back on the leaked key. A rollover's key checks the `/data` refresh. A revoked baked key
  with no new key means the phone accepts no `/data` refresh. The baked `/system` copy keeps the baked key. Left for the
  next slice: the fetch, the durable seq floor, the operator's put command, and the call in `index.go`;
curation policy (above); icon strategy (above); ~~metered-pref persistence under amnesia; multi-APK/split handling;~~ *(both decided 2026-10-20, Q079)*
`/system` size budget for the baked index (~10 MB into read-only).
