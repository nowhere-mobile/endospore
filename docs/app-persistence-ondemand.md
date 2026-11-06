# On-demand apps — an archived-app tier for app persistence (design, for sign-off)

<!-- backlog: A Play stack member the user never switched off is dropped from the seal at logoff -->
**Status:** design · 2026-07-25 · **BUILT and shipped** — the header read "**not built**" until
2026-09-03, three weeks after the tier shipped and while it was still being actively fixed
(`NWP-20260903-11` install-heal is on-demand work from the same day). Corrected when a new
`gen-active.py` check flagged this doc as declaring itself unbuilt with no backlog row. Residual
on-demand work is tracked in `docs/backlog.md` §B, not here — phased spec + the one open mechanism question to sign
off before code. Extends app persistence ([app-persistence.md](app-persistence.md), #199–#202) and is the
**app-tier analog of the 3-tier offline-media model** ([#129 — 3-tier offline media](129-media-tiers.md); on
the device, the `showOfflineMedia` tri-state in `core/chooser/.../ProfileActivity.java`).

## Problem

App persistence (#201) is **binary and eager**: an app is either *kept* — sealed to the account **and
re-installed in full at every sign-in** — or off. Two costs fall out of "eager":

1. **Login cost.** Every kept app's APK set is materialised from the store and `PackageInstaller`-installed
   during the sign-in provisioning window, before the session is usable. A user who keeps 15 apps but opens
   3 pays the full download+install for all 15 on every roam-in.
2. **Local storage.** Every kept app occupies `/data/app` for the whole session even if never opened —
   against the amnesiac model's "hold as little as possible locally" grain.

Meanwhile **media already has a third gear**: the offline-media screen (#129) lets each app's *maps & files*
be **Essential** (local at sign-in), **Auto** (prefetched in the background), or **On-demand** (streamed
through the mediad FUSE layer on first access). Apps have no equivalent — the APK is always eager.

This gap also surfaced as a **UX confusion** (2026-07-25, lynx): the offline-media screen shows
"AliExpress — On-demand", which reads as *the app* being on-demand, when it only means the app's **data**
streams on demand (the APK is fully installed). The missing app-tier concept is exactly what makes that
label ambiguous. (A related label fix, done by NWP-20261105-10 — see *Related UX* below.)

## Goal

A third app state — **On-demand** — that sits between *off* and *keep-installed*:

> The app is **sealed to the account** (its APK set rides `name#apps` like a kept app), but it is **not
> materialised locally at sign-in**. It appears as a **placeholder / archived icon**; the **first tap**
> fetches its APK set from the store, installs it, and launches — then it behaves like any installed app for
> the rest of the session.

So the "Your apps" control becomes a tri-state that mirrors media:

| App tier | Sealed to account? | At sign-in | On first tap |
|---|---|---|---|
| **Off** (default) | no | nothing | — (not present) |
| **On-demand** *(new)* | yes | placeholder icon only | fetch APK → install → launch |
| **Keep installed** (current #201) | yes | full install | launches immediately |

Wins: **faster sign-in** (materialise only what's opened), **less local storage**, and it extends the
roaming model's "materialise on demand" philosophy from files to apps. Best for users with many or large
kept apps (games, big shopping apps). Cost: a **first-tap download+install latency** and a **network
requirement at first open** (handled — see edge cases).

## Non-goals

- **Not** a replacement for keep-installed. Apps a user opens constantly should stay eager; on-demand is a
  per-app choice (and a candidate *default* — see sign-off).
- **Not** partial/streamed *execution* of an app (no app-level FUSE). The unit is the whole APK set: it's
  fetched and installed in full on first tap, just **lazily**. (Media streaming stays media's job.)
- **Not** DRM/attestation-app rescue — same best-effort caveat as #201.

## Mechanism — two options for the placeholder + tap

The sealing/capture side is **unchanged** from #201 (the APK bytes already ride `name#apps`, CDC-deduped).
The new machinery is (a) presenting a **placeholder** for an on-demand app, and (b) **materialising** it on
tap. Two ways to get the placeholder + tap-to-materialise:

### Option A — native Android app-archiving *(recommended, pending the routing check)*
Android 15+ (this build is Android 17) has **app archiving**: `PackageInstaller.requestArchive(pkg)` removes
the APK but keeps the app's data + a **launcher-rendered placeholder icon with a cloud/download badge**;
tapping it fires an **unarchive** flow (`ACTION_UNARCHIVE_PACKAGE` to the *installer of record*). If we are
the installer of record (we install via our own `PackageInstaller` session, #200), the unarchive
broadcast comes to **us** — and we service it by fetching the APK set from `name#apps` and completing the
install, instead of going to Play.

- **Restore:** an on-demand app is installed at sign-in **then immediately archived** (or, if the archive
  API accepts it, registered archived without a full install first — to verify). Net local footprint ≈ the
  icon + data stub, not the APK.
- **Tap:** the OS shows the archived-icon UX for free; the unarchive intent routes to our installer; we
  fetch + install + the OS launches.
- **Pros:** the placeholder + progress + tap affordance are **OS-native** — no Launcher3 fork, matches
  platform muscle memory. **Cons / must-verify before committing:** (1) that the unarchive intent reaches
  our device-owner installer in the **roamed secondary user** under enforcing `endospore_priv`
  (sepolicy + installer-of-record), (2) that archiving works for a **sideloaded** app (no store record),
  (3) the archive→unarchive round-trip preserves the signer so app data still verifies.

### Option B — custom Launcher3 placeholder *(fallback)*
Synthesise a launcher entry per on-demand app (icon from the sealed manifest); intercept its tap in
Launcher3 → call a chooser `MATERIALIZE-APP <pkg>` → fetch + `PackageInstaller` + launch, with our own
progress (reuse the #129 media-download ring). Full control, but a **Launcher3 fork** + we own the entire
placeholder/tap/progress UX.

**Recommendation: A**, gated on a spike proving the unarchive-in-roamed-user routing (P1 below). Fall back
to B if the intent can't be routed to our installer under the enforcing roamed-user model.

## Data model

- **Keep-set gains a per-app mode.** `files/nowhere-appkeep` today is one **pkg** per line (kept = installed).
  Extend to `pkg⇥mode`, `mode ∈ {installed, ondemand}`. **Back-compat:** a bare `pkg` line (no tab) reads as
  `installed` — existing keep-sets keep working unchanged.
- **Mode rides the sealed app-manifest**, not just the keep-set. `captureAppCode` already writes
  `nowhere-appcode.list` (`pkg⇥versionCode⇥sideloaded⇥apk…`); add a **`mode`** column so the sealed
  `name#apps` manifest carries it. Restore then branches on the manifest **without** needing the roamed
  keep-set readable at install time (it's mid-restore into the roamed user's CE).
- **Capture is otherwise unchanged:** both `installed` and `ondemand` apps are sealed identically (same
  bytes to `name#apps`, same footprint/billing) — the mode only changes **how they come back**.

## Phasing

- **P1 — mechanism spike + data model (no user-visible tier yet).** Prove Option A: from a device-owner
  `PackageInstaller` session in the **roamed user**, archive an installed 3rd-party app, confirm the
  placeholder renders, tap it, and confirm the **unarchive intent reaches our installer** so we can complete
  it from local bytes. In parallel, land the **back-compat keep-set mode** + the **manifest `mode` column**
  (capture writes it; restore reads it but still installs everything — no behaviour change yet). Deliverable:
  a go/no-go on A vs B, plus the data-model foundation. *Self-contained + review-ready: the data-model change
  is inert (mode defaults to `installed`) and the spike is throwaway.*
  **Spike done (lynx, 2026-07-25): GO on A.** `pm archive` / `pm request-unarchive` are shell-available;
  AliExpress + KeePassDX restored by #200 already show `installerPackageName=com.nowhere.chooser`; `pm archive`
  returns *"Installer does not support unarchival"* — so the only missing piece is the chooser **declaring the
  unarchive receiver** (decision 1), which becomes the P2 entry point. Also observed: #200 installs the APK in
  **user 0** (installer = chooser) and it persists there across logoff — an at-rest app-code caching question
  to weigh separately. Remaining P1: the back-compat keep-set `mode` + manifest `mode` column.
- **P2 — restore honours on-demand.** Restore installs `installed` apps (current) and, for `ondemand` apps,
  produces the **placeholder** (archive-after-install via A, or the synthetic entry via B) — nothing
  materialised beyond the stub. No tap handling yet; an on-demand app shows but isn't openable. *(Held with
  P3 — a placeholder you can't open is not shippable on its own.)*
- **P3 — materialise on tap.** Handle the unarchive/tap: fetch the app's APK set from `name#apps` via caps
  → `PackageInstaller` session → launch, with progress (reuse the #129 download-ring surface) and a clean
  **offline-tap** message. P2+P3 ship together as the first user-visible slice.
- **P4 — the tri-state UX.** "Your apps" row becomes **Off / On-demand / Keep installed** (the media
  `mediaAppRow` segmented control, re-skinned), with the sideloaded one-time warning preserved, the
  storage summary split into "installed vs on-demand," and copy that makes the three states legible.
- **P5 — eviction (reclaim).** Re-archive an on-demand app unused for N days (or under memory pressure) to
  return it to the placeholder state — the app-tier analog of on-demand-media eviction. Its bytes stay in
  `name#apps`, so re-tap re-materialises. Off by default; opt-in or automatic under a budget.

## Edge cases

- **Offline first tap:** no network → cannot materialise. Show a clear "connect to the internet to open
  <app>" message; never a silent failure or a crash. (Mirrors the media on-demand offline verdict.)
- **First-tap latency:** a large app (game) may take a while. Progress UX is mandatory (P3), not optional.
- **Sideloaded on-demand:** works — bytes are in `name#apps`. But verify Option A archives a sideloaded app;
  if not, sideloaded on-demand falls to Option B or is disallowed (documented, not silently dropped).
- **Update drift:** the sealed APK is the in-session snapshot; on-device auto-update (Aurora/F-Droid) may
  bump an installed app later. An on-demand app materialises at its **sealed** version; document that.
- **Signature:** archive→unarchive (A) or re-install (B) must preserve the original signer so restored app
  data still verifies — same requirement as #201 restore.
- **Amnesia:** an on-demand app's local bytes are wiped at logoff like everything else; the account copy in
  `name#apps` is the only persistence. No new at-rest exposure.

## Related UX — the "installed app shows On-demand" label (separate small fix)

The offline-media screen (`showOfflineMedia`) shows each app's **data** tier (Essential/Auto/On-demand); an
*installed* app there labelled "On-demand" reads as the app being on-demand. Independent of this feature,
that screen's per-row/label should make unmistakable that the tier governs the app's **maps & files**, not
the app binary — and once the app itself has an On-demand tier (P4), the two surfaces must clearly
distinguish "app: on-demand" from "app's data: on-demand." Tracked separately so it can ship before P4.
**Done (NWP-20261105-10, Q074, decided 2026-10-20):** each row's control is captioned "Maps & files" and the words
stay; the media tier is not renamed.

## Decisions required (sign-off)

1. **Mechanism → A (native archiving) or B (Launcher3 placeholder)? — RESOLVED → A** (P1 spike, lynx,
   2026-07-25). `pm archive` / `pm request-unarchive` are shell-available, and the #200-restored apps already
   carry `installerPackageName=com.nowhere.chooser`, so the unarchive intent routes to **us**. The one
   requirement A imposes: **the chooser (installer of record) must declare unarchival support** — until it
   registers the unarchive receiver, `pm archive` fails `Installer does not support unarchival`. No Launcher3
   fork. **B retired to fallback-only** (revisit only if the receiver can't be wired under the enforcing
   roamed user). That receiver is the entry point for P2.
2. **Default tier for a newly-kept app → `installed` or `ondemand`?** Recommendation: keep **`installed`**
   the default (least surprise; today's behaviour), with on-demand an explicit per-app choice — revisit once
   P4 measures real login-time savings.
3. **Eviction (P5) → automatic under a budget, or opt-in only?** Defer; decide after P3 ships and we see real
   on-demand footprints.
4. **Work id** for the build track.

## Tasks (proposed)

- **P1** — mechanism spike (A: archive/unarchive routing in the roamed user) + back-compat keep-set mode +
  manifest `mode` column (inert). Go/no-go on A vs B.
- **P2+P3** — restore produces the placeholder + materialise-on-tap (fetch `name#apps` → install → launch) +
  offline handling + progress. First user-visible slice; ships together.
- **P4** — "Your apps" Off / On-demand / Keep installed tri-state + storage accounting split + copy.
- **P5** — eviction / reclaim (re-archive unused on-demand apps).

Relates to #201 (this is its P4+), #129 (the media tri-state this mirrors), and #168 (cross-device app-code
re-download — the same `name#apps` fetch primitive P3 needs).
