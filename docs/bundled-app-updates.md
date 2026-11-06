# Bundled-App Update Control

How Diaspore governs the versions of the apps **we bundle** (Fennec, Organic Maps, the messaging/dialer
set, etc.) so an upstream update can't silently regress a roamed session. Motivated by a concrete failure
(below). Relates to distribution-strategy, commercialize,
[app-model](app-model.md), and the E.7 release pipeline in roadmap.

## ⚠ Endospore (GrapheneOS): no store can update a bundled app — DECIDED 2026-09-24

Everything below was written for Diaspore (LineageOS), where F-Droid could and did update bundled apps. On
Endospore it cannot: GrapheneOS lets only its first-party app source (`app.grapheneos.apps`) or the shell update a
SYSTEM package (`PackageInstallerSession.java:4713-4728` in `grapheneos-2026061600`), and every bundled app is a
system app in `/product`. Found through ticket `NW-0aa83bebd87d` (logcat, `PackageInstallerSession`: *“System app
updates from unknown sources are blocked”*). Decided by Chester the same day, verbatim: *“yeah a and in the future b sounds the right approach”* — (a) on
Endospore a bundled app moves only with the OS image, so the pins in `default-apps.manifest` are what users get and
each release is where they move; (b) later, our own store becomes an allowed updater. Engineering consequences,
ours and not his decision (`product-decisions.md` 2026-09-24): (b) needs a framework patch accepting a second
installer, not the one-installer overlay first offered; and the process gate below applies to every pin bump.

## The problem (why this doc exists)

Bundled apps ship as system apps at a known-good version, but F-Droid then **auto-updates them from
fdroid.org** with no gate of ours. On 2026-07-09 that bit us:

- F-Droid updated the bundled **Fennec 151.0.3 → 152.0.4**.
- 152.0.4 **crashes on launch for every roamed user**: `java.lang.UnsupportedOperationException` at
  `org.mozilla.fenix.HomeActivity.onCreate` — but only on the normal launcher intent
  (`action=MAIN + category=LAUNCHER`); a bare-component launch opens fine. The app, profile, and roamed data
  are all healthy.
- Root cause: that line is early `onCreate` theme/window setup that isn't supported for a **secondary
  (non-primary) Android user** — and **every Diaspore roamed session is a secondary user** (the gate is
  user 0 / primary; a roamed profile like `c` is user 11 / secondary). So it works on user 0 and crashes on
  the roamed user, and only after the 152 bump (151 was fine).

**Key framing:** "works on the primary user" ≠ "works roamed." Any bundled-app update can regress on
secondary users, and we currently find out only when a user reports a broken app. We need (a) a gate before
an update reaches devices, and (b) a way to make our approved version *stick*.

## The constraint: how F-Droid actually chooses a version

Three facts drive everything here (all verified):

1. F-Droid offers an update whenever **any enabled repository** advertises a **higher `versionCode`** than
   what's installed.
2. **Repository priority is only a tiebreaker** — it decides *which repo* to use when two repos carry the
   **same** version. It does **not** cap the version: the **highest `versionCode` across all enabled repos
   always wins**. So a high-priority Diaspore repo pinning an *older* version does **not** stop fdroid.org's
   newer one.
3. An in-place update requires a **matching signing certificate**. Android (and F-Droid) refuse a
   signature-mismatched update; F-Droid won't even offer one. A repo can also lock the accepted signer via
   `AllowedAPKSigningKeys`.

Consequence: you cannot pin a version by "preferring" our repo. You pin it either by removing the repo that
offers the higher version, or by making the app **ours by signature** so no one else *can* update it.

## The two levers — "our app store" vs "the signature"

These are the two things the choice is really between, and they solve **different halves** of the problem:

- **Distribution / curation — "our app store."** A Diaspore F-Droid repo that we run, which advertises only
  **approved versions** of the bundled apps. This is *where* blessed builds live and how we publish them; it
  also becomes the natural home for the managed store (curation, later billing/subscriptions). **On its own
  it does not enforce a version** — because of constraint #2, if fdroid.org is also enabled it still wins on
  a higher `versionCode`. A store caps versions only if fdroid.org is **disabled**, which is leaky (see
  Option 1).

- **Enforcement — "the signature."** Sign the bundled apps with the **Diaspore key**. Now the installed app
  is *ours*, and fdroid.org's differently-signed build is a signature mismatch it **cannot** install
  (constraint #3). This is OS-enforced and independent of which repos are enabled. It's what makes our store
  *authoritative* for our apps.

So it isn't really "store **vs** signature" — the **store is the distribution, the signature is the lock.**
A store without the signature protects our apps only as long as fdroid.org is absent; the signature is what
lets fdroid.org stay enabled (users keep the full catalog) while our bundled apps remain untouchable by
anyone but us.

## Options compared

| Option | What controls the bundled-app version | Can fdroid.org override our apps? | Users keep the fdroid.org catalog? | Effort | Who owns security updates for bundled apps |
|---|---|---|---|---|---|
| **0. Status quo** | fdroid.org (always latest) | Yes — this is the bug | Yes | None | Upstream — but breaks roamed with no warning |
| **1. Our repo only, apps stay F-Droid-signed** | Us, but *only because fdroid.org is disabled* | Yes, the moment a user re-adds fdroid.org (same cert) | No (off by default) | Low — just host F-Droid-signed APKs at chosen versions | Mostly upstream; we only choose which version to publish |
| **2. Our repo + bundled apps re-signed with our key** *(recommended)* | Us, hard — signature mismatch blocks everyone else | **No — OS-enforced**, even with fdroid.org enabled | **Yes** — fdroid.org is harmless for our apps, still serves everything else | Medium + ongoing | **Us** — we must rebuild/re-sign and republish promptly on upstream fixes |
| **3. Our own device-owner updater (skip F-Droid for bundled apps)** | Us, hard | N/A — F-Droid isn't the channel | Yes | High — build a privileged update path | Us |

Precedent: **CalyxOS** runs exactly Option 2 — its own F-Droid repo shipped with the OS alongside
fdroid.org, fed by a pipeline that re-hosts approved APKs, plus an on-device local repo for offline install.

## Recommendation

**Target Option 2; ship Option 1 as a fast interim.**

- **Interim (Option 1):** stand up the Diaspore repo, host the approved (F-Droid-signed) bundled APKs, and
  make it the only default repo. Buys us the version gate today with no re-signing. Accept that it leaks if
  a user re-adds fdroid.org.
- **Target (Option 2):** re-sign the bundled apps with the Diaspore key and serve them from the Diaspore
  repo. This makes the store authoritative and lets us **keep fdroid.org enabled** so users retain full app
  freedom for apps *they* choose, while our bundled set is locked to versions we've blessed.
- **Bundle the approved APKs as an on-device local repo** for offline / first-boot install — fits the
  amnesiac/roamed model (roamed users `install-existing`).

Since the chooser is **device owner**, Option 3 (deliver bundled-app updates through our own privileged
installer, like the OS OTA channel) is available if we ever want to drop the F-Droid dependency for bundled
apps entirely — more control, more to build. Option 2 reuses F-Droid's UX and the infra we already have.

## The process gate (independent of which option)

"Approved version" must mean *tested*, not just *newer*. Before an approved version is published to the
Diaspore repo, CI must **cold-launch it via the normal launcher intent on a secondary (roamed-equivalent)
user** and assert it reaches its home activity. That single check would have caught Fennec 152 before any
device saw it. This is the durable fix; the repo/signature machinery is what makes the approval *stick*.

## Cost / commitment (be honest)

Re-signing (Option 2) makes us the **vendor of record** for the bundled apps: we must track upstream,
rebuild/re-sign, and republish approved versions **promptly**, especially for security fixes — otherwise we
hold users on a stale, potentially vulnerable build. This is real ongoing work and the same commitment
CalyxOS / e/OS take on. It's a Phase-2 / commercialization item that lives naturally in the managed store
and the E.7 release pipeline.

## Immediate stopgap (done)

On the dev FP3, reverted Fennec to the bundled 151.0.3 with `pm uninstall-system-updates
org.mozilla.fennec_fdroid` (removes the /data/app 152 overlay, keeps user data). F-Droid will re-offer 152
until the repo/pin work lands, so this is a stopgap, not a fix.
