# App persistence across roam — design (DIA-20260724-07)

## Problem

Apps a user installs *inside* a roamed session do not survive a logoff. Reported 2026-07-24: alice
installed **Thunderbird** (F-Droid) and **AliExpress** (sideloaded APK); both worked in-session and both were
gone after logoff → login. This breaks the core promise — *your whole profile roams with you* — for
user-installed apps, and leaves their restored app data orphaned.

## Current behaviour (what roams today)

The seal captures the user's **app data** (`/data/user/N`), **files/media**, and a **list of installed
package names** (`GET-APPS`). On login, `provisionRoamedApps`
([`core/chooser/.../ChooserActivity.java`](../core/chooser/src/com/nowhere/chooser/ChooserActivity.java),
`provisionRoamedApps` / `baseApps` / `installExistingFor`) installs, for the fresh ephemeral user:

1. every launchable **system** app on the device (dynamic `baseApps()`), and
2. the sealed **name list** — each via `PackageManager.installExistingPackageAsUser` (**install-existing**).

`install-existing` only *enables* a package whose **APK is already on the device**. So:

- **Bundled/system apps** (Camera, Gallery, the browser, and any app baked into the image) always come back —
  their APK is in `/system`/`/product` and never GC'd.
- **User-installed apps do not.** They install into `/data/app` for that user only. On logoff the ephemeral
  user is **reaped**; it was the sole installer, so PackageManager **garbage-collects the APK**. On the next
  login `install-existing` has no APK to enable → the app never appears, and the restored `/data/user/N` data
  for it is orphaned.

The code names this gap directly: *"device-local install-existing **for now** — the cross-device code fetch
from Aurora/F-Droid is the productionization."* It corresponds to backlog gaps **#29** (cross-device app-code
re-download) and **#157** (Aurora/F-Droid ecosystem).

**Confirmed on lynx (2026-07-24):** Thunderbird is not a bundled/system app on that build, so it behaved
exactly like the sideloaded AliExpress. **Source (F-Droid vs sideload) is irrelevant today** — there is no
re-download path; `install-existing` is device-local only. Whether any given app survives currently depends on
whether it happens to be **bundled** in that build — an inconsistency the user cannot see and shouldn't have
to reason about. The design must erase that distinction: *if I installed it, it comes back.*

## Goals

- A user-installed app — **any source, including sideloaded** — reappears, functional, after logoff→login,
  cold-lock→resume, **and** after roaming to a different device.
- Works **offline** — no dependency on the original source (F-Droid/Play) being reachable at login.
- Storage cost is **bounded, visible, and deduplicated** across profiles/devices.
- **Amnesia preserved**: no readable app code persists on the OS between sessions; the code rides the
  encrypted, content-addressed store like the rest of the profile.

## Non-goals

- App **update** management / an app-store UX (separate: #157 Aurora, #169 bundled-app update gating).
- Making **DRM / hardware-attestation** apps (banking, some streaming) work across roam — best-effort
  re-install + re-auth; may refuse. Documented, not solved.
- Persisting **bundled/system** apps — already handled by `install-existing`.

## Options

| | Mechanism | Sideloaded APK (AliExpress) | Offline | Storage |
|---|---|---|---|---|
| **A. Seal the APK bytes** *(recommended)* | Capture the user's 3rd-party APKs into the content-addressed store; re-`pm install` on restore | ✅ | ✅ | APK bytes in footprint, but **CDC-deduped** (a popular app stored once fleet-wide) |
| **B. Record source + re-download** | Seal `(pkg, source, version)`; re-fetch from F-Droid/Aurora at login | ❌ no source for a sideload | ❌ needs network | tiny |
| **C. Hybrid** | Bytes for sideloads, re-download for store apps | ✅ | partial | medium |

**Recommendation: A.** It is the only option that handles sideloaded APKs, it works offline (matching the
roaming model — *everything* moves with the profile), the content-addressed store dedups popular APKs across
the whole fleet, and it reuses the existing seal/restore machinery. B is a strict subset that fails the
reported AliExpress case; C's complexity isn't justified once A's dedup neutralises the storage argument.

## Recommended design (A)

### Capture (at seal, before the reap)

- **Which apps:** the roamed user's installed packages that are **not system** and **not in the default base
  set** — i.e. genuinely user-installed 3rd-party apps. Exclude `baseApps()` and system/updated-system
  packages; key off installer + `ApplicationInfo` flags.
- **What bytes:** the full APK set from `/data/app/<pkg-dir>/*.apk` — **base + every split** (density / abi /
  language). Missing a split makes the re-install fail, so capture is **all-or-nothing per package**.
- **Who:** the **root worker** (roamd/agent) reads `/data/app` (the chooser can't read other packages' APK
  files; root can). Capture must run at the **exit verb, while the user is still alive**, before the reap GCs
  the APKs — same ordering constraint as the seal and the Wi-Fi-mirror capture.
- **Where it goes:** APK bytes → the content-addressed store (CDC chunks → dedup). A per-profile
  **app-manifest** records `[(pkg, versionCode, [apk-chunk-refs], installerPackage, sideloaded)]`. This adds to
  the **profile footprint** (billed).

### Restore (at the login provisioning window)

- After `provisionRoamedApps` (install-existing of the bundled set), the **chooser** (device owner) reads the
  app-manifest via a new `GET-APPS-CODE` verb, materialises each package's APK set from the store, and installs
  it with a **session-based `PackageInstaller`** (multi-APK / splits) as `--user <uid>`,
  `INSTALL_REASON_USER`.
- **Ordering:** alongside/after install-existing, **before** `GRANT-PERMS` (permissions need the app
  installed). Cold-lock resume uses the same path.
- **Failure is per-app non-fatal** — one bad/rejected APK must never blank the login (mirror the best-effort
  `untarFrom` pattern).

### Split of responsibility

| Step | Actor | Why |
|---|---|---|
| Resolve which packages + each one's APK + split paths | chooser (`ProfileActivity`, roamed user) | has live PackageManager visibility; the su:s0 worker **can't query `pm`** (the `cmd`→system_server fd denial), so it can't enumerate — it needs the paths handed to it (same reason `captureAppList`/`capturePerms` are chooser-side) |
| Read the APK bytes from `/data/app` + `push name#apps` | root worker (roamd) | can read `apk_data_file` + run `nowhere_agent push`; runs in the logoff `out` verb, before the reap GCs the APKs |
| Store (content-addressed) | agent `push` | existing dedup machinery |
| Re-install `pm install --user` | chooser (device owner) | `pm install` hits the device-owner wall for the worker |

## Decisions required (sign-off)

1. **Security posture — persisting executable code that auto-installs on every device the profile touches.**
   The verified-OS guarantee does **not** extend to user apps; a malicious APK in a profile would re-install
   (as device owner) on each roam-in. Options: (a) allow all — the user's own profile, own choice, same as any
   phone; (b) store-sourced only, block sideloads — safer but breaks AliExpress and re-introduces an
   inconsistency; (c) allow all but **explicit per-app opt-in** with a one-time warning for sideloaded APKs.
   **Recommendation: (c).** It doubles as the storage control and makes the persisted set intentional.
2. **Storage / billing.** Persisted APKs count toward the paid footprint. Options: automatic (all user apps) /
   per-app opt-in / a budget. **Recommendation: per-app opt-in** — a "keep on my account" toggle, reusing the
   offline-media pin UX (#108). Bounds cost and satisfies decision 1 in one control.
3. **Work ID** for the build track.

## Edge cases

- **Splits:** capture all; install as one `PackageInstaller` session.
- **Version drift:** the sealed APK is the in-session snapshot; on-device auto-update can bump it later.
- **Signature:** re-install preserves the original signer (same bytes → same key), so signed app data still
  verifies.
- **DRM/attestation apps:** best-effort; may re-auth or refuse (non-goal).
- **Large apps / games:** the opt-in/budget bounds the cost; dedup helps for common ones.

## Phasing

- **P1 — capture (built, DIA-20260724-07):** the chooser resolves each opted-in package's APK + split paths at
  logoff (`ProfileActivity.captureAppCode` → `files/nowhere-appcode.list`, one line `pkg⇥versionCode⇥sideloaded⇥apk…`);
  the su:s0 worker (`appcode_seal` in `nowhere_roamd.sh`, in the `out` verb) copies the bytes to a disk staging
  dir → `push s3 name#apps` — a sealed **sibling scope** exactly like `#media` (own head, CDC-deduped, kept off
  the login-critical vault + its #58 snapshots); `profileFootprint` fans out to `#apps` so the bytes are billed +
  never GC'd, and `isPerUnitRef` treats `#apps` as account-shared so a kept app roams to a *different* device.
  Gated by the `persist.nowhere.appcode` system property: `""` = keep nothing (**default — nothing persists**,
  per the T4 sign-off), `"all"` = every user-installed app (the measurement mode), else a package allowlist (the
  P3 per-app opt-in target). *Deliverable: measured real footprint of Thunderbird + AliExpress via a capture-all
  pass, to validate the storage model.*
- **P2 — restore (built, DIA-20260724-10):** the worker restores `name#apps` (sealed **all-essential** —
  `NOWHERE_ONDEMAND_MEDIA=0` on the push — so nothing comes back as a mediad stub) into the USER-0 chooser's
  `files/.appcode` staging (chown'd to the chooser). The device-owner chooser (`ChooserActivity.installRoamedAppCode`,
  run **before** the `GET-APPS` install-existing pass) installs each package via a **`PackageInstaller` session**
  (base + every split), then `installExistingPackageAsUser` enables it for the roamed user. Per-app **non-fatal**;
  the staging is deleted after (amnesia). Round-trip proven by `TestAppsScopeRestoresWhole`. *The two apps reappear
  + run — pending on-device validation on lynx.*
- **P3 — opt-in UX (built, DIA-20260724-11):** the real opt-in is a per-profile **keep-set** (`files/nowhere-appkeep`,
  one pkg/line, seals + roams); `captureAppCode` reads it, and the `persist.nowhere.appcode` property is demoted to
  a dev/measurement override. New Profile screen **Preferences → Your apps** (`ProfileActivity.showYourApps`) lists
  the user-installed apps (icon + label + ~size + "sideloaded") with a per-app **keep toggle**; turning on a
  *sideloaded* app shows a one-time warning (roamed ack marker). Accounting: a live total on that screen + a
  "Kept apps: N · ~X MB" line on the Storage screen.

## Sign-off (resolved 2026-07-25)

- **Decision 1 (security posture) → (c): allow all sources, per-app opt-in.** Any app — including
  sideloaded — may persist, but only the ones the user explicitly opts into ("keep this app on my account"),
  with a one-time warning the first time a *sideloaded* APK is kept. Nothing persists by default.
- **Decision 2 (storage/billing) → per-app opt-in.** The same "keep this app" toggle governs cost; it reuses
  the offline-media pin UX (#108). A budget-cap on top is deferred — revisit after P1 measures the real
  footprint of a couple of real apps.
- **One mechanism satisfies both**: a per-app *keep this app* toggle. It is the gate for capture (P1 stores
  only opted-in apps as a shipped default; a dev/measurement pass may capture-all to size the footprint) and
  the control the "your apps" surface (P3) exposes.
- Work ID: **DIA-20260724-07**.

## Tasks (raised — project tasks #199–#202)

- **T1 (P1) — #199:** capture user-installed APK sets at seal (roamd/agent) + write the app-manifest.
- **T2 (P2) — #200:** restore — worker restores `name#apps` → user-0 chooser `.appcode`; chooser `PackageInstaller` (splits) + `installExistingPackageAsUser`, non-fatal per app. **Built** (PR #471 — pending on-device validation).
- **T3 (P3) — #201:** per-profile keep-set (`nowhere-appkeep`) + "Your apps" toggle screen + one-time sideload warning + storage accounting. **Built** (compiles/validates at the chooser flash).
- **T4 — #202:** security sign-off — the persist-executable-code decision (decision 1 above).
- **Follow-on — on-demand app tier:** a third state (Off / On-demand / Keep installed) so a kept app can ride
  the account as a **placeholder** and materialise its APK on first tap — the app-tier analog of on-demand
  media (#129), for faster sign-in + less local storage. Design + phasing:
  [app-persistence-ondemand.md](app-persistence-ondemand.md).

Relates to #29 / #157 (the Aurora/F-Droid ecosystem is the online-refresh complement to A's offline-first
seal-the-bytes approach).
