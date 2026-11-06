# #129 — 3-Tier Offline Media

Split roamed bulk media into three per-app tiers so login stays fast, valuable media arrives on its own in
the background, and the rest streams on demand. Builds on #84 (on-demand media / mediad) and #108 (pin +
budget). Supersedes #128 (the icon-ring nicety, now folded in as P6). Relates to #126/#127.

## The three tiers

| Tier | When fetched | Blocks login? | Mechanism |
|---|---|---|---|
| **1 Essential** | pre-login, inside the CDC restore tar | **yes** | `untarFrom` — today's essential set |
| **2 Prefetch** *(new)* | post-login, **async**, only on **Wi-Fi + (idle or charging)** | no | `materializePins` generalized, own budget, → promoted to essential on next seal |
| **3 On-demand** | first app open | no | mediad FUSE (`fetchFile`/`ensureRange`) — today's deferred set |

**Key framing:** Tier-2 is not a new subsystem — it's the existing #108 pin-materialize (`materializePins`)
generalized into one of three fetch policies. `classifyDeferred` stays the single gate for "is this bulk
media at all"; `classifyTier` layers the tier on top, so a login/state-critical file can *never* be demoted
out of the login restore.

## Classification model (`classifyTier`, `core/agent/media_tier.go`)

Per file, highest priority first:

1. `!classifyDeferred(rel,size)` → **essential** (small / non-media / deny-listed — never demoted).
2. `#108` pin on the app → **essential** (a pin is a force-into-login override; #108/#125 unchanged).
3. per-profile override for the app → that tier.
4. curated default → built-in `curatedTiers` table (maps → prefetch; everything else → on-demand).

The app unit is `pinnedApp(rel)` (the first data-dir segment, e.g. `app.organicmaps`), same as #108.

## Config (all **roams per-profile** — Chester's decision)

Tier prefs travel with the profile like #108 pins, not as device policy. All live next to the #108 files
under `com.nowhere.chooser/files/` so they ride the seal and restore at login:

| File | Meaning |
|---|---|
| `nowhere-media-tiers` | per-app overrides, one `app.segment tier` per line (`tier` = `essential`\|`prefetch`\|`ondemand`); `#` comments + malformed lines ignored |
| `nowhere-tier2-budget` | Tier-2 async-prefetch byte budget; absent → `defaultTier2Budget` (2 GiB); explicit `0` → unlimited |
| `nowhere-prefetch-metered` | `1` = allow Tier-2 prefetch on a **metered** network (cellular / metered hotspot); absent/`0` = **Wi-Fi-only (default)**. Read by the user-0 gate via the `GET-PREFETCH-METERED` daemon verb (per-profile → can't read cross-user directly). |
| `nowhere-media-budget` *(existing #108)* | Tier-1 essential/pin budget — **unchanged**; governs Tier-1 alone |

Tier-1 and Tier-2 budgets are **independent caps, not a shared pool**. There is no device `NOWHERE_TIER1_BUDGET`
(decided: keep the #108 per-profile budget only).

**Curated defaults** (Chester's decision — feature "on" for known heavy apps out of the box): a built-in
table in `media_tier.go` (`curatedTiers`) is the curation point. Ships with `app.organicmaps → prefetch`;
extend as needed. Any app absent from the profile override *and* the curated table → on-demand, so an
unconfigured app behaves exactly like today.

## Manifest (`deferredFile.Tier`, `core/agent/main.go`)

One new field, `Tier int json:"tr,omitempty"`. `0`/absent = on-demand (Tier-3), `2` = prefetch (Tier-2).
Essential files are not deferred (they ride the tar), so they never appear here. Because on-demand is the
zero value and the field is `omitempty`, **every pre-#129 sealed manifest stays byte-identical and
signature-valid**, and a #129 build with no config behaves exactly like today.

## Tier-2 prefetch engine (mediad + chooser gate)

- **Runs in mediad** (the Go daemon), not a new scheduler: `materializePins` already does a filtered, sorted,
  budget-capped background fetch that writes real bytes to `.under`, tombstones the stub, and publishes #90
  progress. Refactor it into a shared `materialize(sel, budget, …)` and call it twice: pins (eager) and
  Tier-2 (gated, `Tier==2`, `NOWHERE_TIER2_PREFETCH_BUDGET`). Reuses the proven no-teardown-seal / tombstone /
  write-back-safety machinery.
- **The gate lives in the chooser** (Wi-Fi/idle/charging are known to the app layer, not the daemon): the
  existing `nowhere-backup-watcher` thread evaluates Wi-Fi(unmetered) + (`isDeviceIdleMode` or charging) and
  sends `PREFETCH-ARM` / `PREFETCH-DISARM` verbs. mediad polls a `prefetch.armed` tmpfs flag between files and
  parks on disarm (finishes the current chunk first → a Wi-Fi drop / unplug can never corrupt a `.part`).
- **Cache safety:** writes go through the same `.under` + materialize-then-tombstone path as `materializePins`;
  `kickMediad` already refuses to start during `sealInFlight`/reap/switch; a Tier-2-materialized file is seen
  by the next seal as a real `.under` file → promoted to essential. A Tier-2 file whose prefetch never
  completes stays a valid deferred stub → mediad serves it on-demand (graceful degradation to Tier-3).

## Progress (Σ chunk bytes → launcher)

Per app: `total(a) = Σ deferredFile.Size` over that app's Tier-2/pin files (free from the manifest, reuses the
`LIST-MEDIA-APPS` grouping); `done(a)` = bytes already in cache. mediad publishes a new per-app file
`media.appprog` (separate from the single-line #90 `media.progress`); a new `GET-MEDIA-APP-PROGRESS` daemon
verb relays it; the chooser watcher parses per-app lines and writes a launcher-readable per-user progress file
(`createContextAsUser`, crossing to the roamed user).

## Launcher icon ring (out-of-repo Trebuchet patch)

Trebuchet/Launcher3 has no badge/progress consumption today, and an overlay can't add Java logic, so the ring
is a source patch `editions/diaspore/build/patches/trebuchet-media-progress-ring.sh` (same pattern as
`trebuchet-leading-landing-page.sh`, run before `m`). The patched icon view paints a partial arc (0–360°·pct),
driven by the P5 per-user progress file via a `FileObserver`. Hidden at idle / after DONE clears.

## Reconciliation / no-regressions

- **#84 mediad** — Tier-3 serving untouched; Tier-2 reuses the same cache + fetch primitives; a file is Tier-2
  or Tier-3, never both. No-teardown-seal, tombstone, damaged-chunk (#109), range-serving (P4) invariants hold.
- **#108/#125** — pins remain a Tier-1 forcing override evaluated before the tier map; `keepOffline` + the
  per-profile pin budget are byte-for-byte unchanged; a never-completed Tier-2 file still serves on-demand.
- **#127** — the carry-forward guard becomes tier-aware in P4 (un-materialized Tier-2 stub carried deferred,
  materialized carried essential) — the belt-and-suspenders #127 asks for, generalized to 3 tiers.
- **#126** — untouched; Tier-2's separate budget avoids entangling it. Its re-defer-on-tighten analog is a
  later Pn, explicitly out of P1–P6 scope.

## Slice plan (smallest-first; each merges behind `NOWHERE_ONDEMAND_MEDIA` + `default=ondemand`, no regression)

| Slice | What | Status |
|---|---|---|
| **P1** | manifest `Tier` field + `mediaTier`/`classifyTier` + curated table + `loadTiers`/`loadTier2Budget` + tests | **done** (agent unit-tested; no behavior change) |
| **P2** | seal three-way split in `walkChunks` (essential/prefetch/on-demand); stamp `deferredFile.Tier` | **done** (real-seal unit test `TestSealTiersMedia`; #108 pin/budget preserved) |
| **P3** | Tier-2 prefetch engine in mediad (refactor `materializePins` → shared `materialize` + gated `prefetchTier2` + own budget) | **done** (unit-tested; gated on `prefetchArmed()` → inert until P4 arms it, so merge-safe) |
| **P4a** | daemon `PREFETCH-ARM/DISARM` verbs (create/remove `prefetch.armed` + re-kick) + mediad mid-run pause (`materialize` `stillOK`) | **done** (agent unit-tested; verbs inert until the chooser calls them → merge-safe) |
| **P4b** | chooser Wi-Fi + idle/charging gate → the verbs; mediad **polls** `prefetch.armed` (the gate arms after mediad starts, so a one-shot check always missed it); + #127 tier-aware carry (re-tier walk-unseen deferred files) | **done + PROVEN on FP3** — c's OrganicMaps maps re-tiered to Tier-2, gate armed on Wi-Fi+charging, poller materialized them (China_Anhui/Chongqing/Fujian/Gansu…, cache 92→172 MB, #90 progress notice live) |
| **P5** | per-app progress **data pipeline**: mediad publishes `media.appprog` (Σ Tier-2 chunk bytes done/total per app) + `GET-MEDIA-APP-PROGRESS` daemon verb | **done + PROVEN on FP3** (unit-tested `TestPublishAppProg`; drives the P6 ring live) |
| **P6** | Launcher3 icon ring via the Trebuchet patch `trebuchet-media-progress-ring.sh`, fed by a chooser **cross-user broadcast** (`app.nowhere.MEDIA_PROGRESS`, NOT a file — sidesteps the CE/SELinux read) carrying `GET-MEDIA-APP-PROGRESS`. Ring drawn in `BubbleTextView` **and** `DoubleShadowBubbleTextView` (workspace/hotseat icons take a double-shadow `onDraw` path that never calls `super.onDraw`, so they must invoke the ring themselves). | **done + PROVEN on FP3** (2026-07-09): a ~39% blue arc on the OM icon during prefetch, updates live, clears at 100%. Supersedes #128 |

**Shipped alongside P6** (same PR, all proven on FP3): (a) the Profile **Offline media** screen's per-app control became a **3-way segmented picker** (Essential / Auto Wi-Fi / On-demand) — Essential = the #108 pin, Auto/On-demand = `nowhere-media-tiers` entries; `LIST-MEDIA-APPS` now returns `app bytes tier` so the picker shows the right default without duplicating `curatedTiers` in Java; (b) a **"Download over mobile data"** switch writing `nowhere-prefetch-metered`; (c) the #90 download notification gained a **heads-up advisory** ("Some apps may take longer to open or respond") since a T3 open blocks on the FUSE chunk and a big T2 prefetch adds I/O contention.

## Open questions (resolved / remaining)

Resolved by Chester (2026-07-08): tier config **roams per-profile**; **curated defaults** (maps→prefetch);
**Tier-1 uses the #108 budget only** (no separate device cap).

Remaining, decided-with-a-default (verify on FP3, don't block):
- **App-segment → launcher package mapping** for the ring (P6): config keys by data-dir segment, the launcher
  by package name. Assumed equal for roamed apps; add a mapping table if FP3 proves otherwise.
- **Launcher progress channel:** file + `FileObserver` (reuses the tmpfs-publish pattern) vs a cross-user
  broadcast Intent. Going with the file; revisit if FileObserver-across-CE proves flaky on FP3.
