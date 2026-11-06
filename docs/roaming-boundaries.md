# Diaspore — Roaming Boundaries (what roams, what can't)

Status: design note · 2026-06-11 · the Authenticators / passkeys row superseded in place 2026-10-04 (`NWP-20261003-02`) · layer 3 (a session that is ordinary app data) and the sign-out differential added 2026-10-12 (`NWP-20261011-73`) · telephony sealed delivery added 2026-10-12 (`NWP-20261011-49`) · the Banking / payments row, the layer-2 Keystore bullet, the Most app data row's Keystore caveat and the Authenticators / passkeys row's answer for another phone superseded in place 2026-10-16 (`NWP-20261016-46`)

Diaspore's promise is "your data roams; the device holds nothing at rest." This note draws the line
precisely: **Diaspore roams data; it cannot roam hardware-rooted trust.** That boundary isn't a bug to
fix — it's two security models colliding — so it's written down once, clearly, instead of rediscovered
every time someone asks "but does *my* app work?" A third class sits on the *roams* side of that line
and is the one that surprises people: a sign-in held in the app's own data, which roams because it is
data, whether or not anyone meant it to (layer 3).

## The three layers

### 1. Roamable — "your stuff" (the ~90%)
Anything that is just *data on the device* roams cleanly: sealed into the content-addressed store on
sync, restored on login, wiped on power-off.
- Messages (SMS/MMS), call log, contacts — they live in system content providers
  (`com.android.providers.telephony` → `mmssms.db`; `com.android.providers.contacts` →
  `calllog.db`, `contacts2.db`). A call, SMS or MMS that arrives while you are NOT signed in roams too, by
  sealed delivery: on a SIM bound to your profile the gate seals it to your profile's public telephony key and
  your next login inserts it into those same providers (`core/agent/telephony_inbox.go:14-19`,
  `core/chooser/src/com/nowhere/chooser/TelIngest.java:10-12`); the sealed copy waits in RAM, so a reboot first
  loses it.
- Files, photos, downloads, notes, and an app's OWN in-app settings (they live in its app data).
  ⚠ NOT the OS's settings ABOUT an app — `Settings > Apps > <app>` (GrapheneOS exploit-protection
  compatibility mode, Storage Scopes, Contact Scopes, Sensors). Those are per-user framework state,
  ~~are in no sealed scope, and are reset every login~~ *(superseded 2026-10-21 for the hardening flags on
  Endospore: Slice A, `NWP-20260821-17`, captures them at logoff and re-applies them at login,
  `core/chooser/src/com/nowhere/chooser/GosState.java`, and every Endospore build applies
  `editions/endospore/build/patches/gos-chooser-grant.sh`. It has never been observed working on a handset, so
  treat them as still reset every login until it is. Storage Scopes cannot roam as built (blocked by design),
  Contact Scopes are blocked, Sensors stays as written)*. See the per-app-settings rows in `backlog.md`.
- Most app data under `/data/data/<pkg>` and `/data/user/N`.

The clean mechanism for full fidelity is the **per-user model** (see the session-lifecycle item in
backlog.md): make each identity an Android user and roam its entire `/data/user/N`, which already
contains the providers and every app's data — Android does the per-user isolation and the provider/app
lifecycle for us; Diaspore just seals/restores the per-user blob.

### 2. NOT roamable — device-bound trust (the ~10%)
A whole class of apps *deliberately* anchor themselves to the physical device, for security. These do
not roam, by design:
- ~~**Android Keystore keys** — hardware-backed, sealed in the TEE/StrongBox; built to never leave the chip. A roamed copy of an app is missing the one key that makes its secrets valid.~~
  **Superseded 2026-10-16 (`NWP-20261016-46`).** That was written before the Keystore carry. Since `NWP-20260830-03` an app's Keystore keys roam with its data, unconditionally: the key stays wrapped by the TEE, and its wrapped blob is carried, so on the SAME phone the app's keys come back at the next sign-in, except keys bound to the screen lock or a fingerprint, which the carry refuses (`framework-patches.md`, `keystore-roam.sh`). On ANOTHER handset they do not come back: the import refuses a bundle stamped for another device, whose TEE-wrapped keys this one cannot unwrap (`keystore-roam.sh`); no restore onto different hardware has been tried (`profile-snapshot.md` §1).
- **Device attestation (Play Integrity / SafetyNet)** — proves "genuine, unmodified device"; banking
  and payments gate on it. A roamed identity changes the attestation — and this build (LineageOS +
  unlocked bootloader) **already FAILS Play Integrity**, so those apps are limited here regardless of
  roaming.
- **Server-side device registration** — apps that bind your account to one device (WhatsApp, Signal):
  moving the data to a new device triggers re-verification (an SMS code), and rapid device-hopping
  trips anti-fraud.
- **DRM** — Widevine L1 keys are per-device; roamed media licenses won't validate.

### 3. Roams whether you want it to or not — a session that is ordinary app data
A login or session token that an app keeps in its own CE app data — cookies, WebView IndexedDB /
leveldb, localStorage, SharedPreferences, a token file — is pure data. It is sealed and restored with
the rest of the app's data, so the app comes back **signed in**. It is neither device-bound (layer 2:
nothing ties it to the chip, so it survives a new Android user) nor optional: there is no per-app
"sign me out" control, because no predicate can tell from outside which bytes are the session (the
2026-08-20 entry in `product-decisions.md`, decided 2026-08-30 as "drop the switch, always carry").
The only ways not to carry it are to sign out inside the app before logging off, or to set the app's
roaming mode to Off, which drops ALL of its data (`loadDropList` → `dropPkgForRel`,
`core/agent/incremental_seal.go`) — settings and content along with the session.

⚠ **A string scan cannot prove such a session absent.** WebView IndexedDB is a leveldb, and leveldb
compresses its tables, so `grep`/`strings` over the app's files reads nothing in them. A sweep that
finds no token is evidence of nothing; see *How to answer "does app X stay signed in across a roam"*
below.

**Worked example — Coach USA (`com.orbit_user_app`), frankel, build 2026082001, 2026-08-20**
(`NWP-20260820-02`): a React Native + WebView app, Play-installed. It roamed and came back signed in
(the restored Cookies / localStorage / sessionStorage / AsyncStorage were md5-identical to what was
sealed). A sweep of all 72 non-cache files of its data found no credential anywhere a string scan can
see: cookies were consent/analytics only, localStorage empty, sessionStorage analytics only,
AsyncStorage just `fcmToken`/`isFirstTime`, the 8 `shared_prefs` files all Firebase/GMS plumbing, no
EncryptedSharedPreferences, and no Keystore entry — while the app was signed in the whole time. A
sign-out differential placed the session in the WebView **IndexedDB** for `https_www.coachusa.com`:
signing out in-app made that leveldb's `LOG` record its own manual compaction (1374 B → 28 keys /
658 B), while Cookies and AsyncStorage stayed byte-identical. ⚠ That attribution is
**correlational**, not subtractive: the store that changed at sign-out was IndexedDB, but no run
deleted IndexedDB alone and watched the session go.

This layer does not depend on the Keystore carry (`NWP-20260830-03`, which supersedes layer 2's Keystore bullet):
an app whose session also needs a Keystore key depends on that carry as well (see the Authenticators /
passkeys row below); this app had no Keystore key at all, so its session came back on app data alone.

## Worked examples
| App / data | Roams? | Why |
|---|---|---|
| SMS / call log / contacts | **Yes** | Provider databases — pure data (per-user model). |
| Calls / SMS / MMS that arrive at the gate while you are signed out | **Yes, on a SIM bound to your profile** | Sealed to your profile's public telephony key at the gate, delivered into your providers at your next login (`core/agent/telephony_inbox.go:14-19`); held in RAM, so lost if the phone reboots first. On an unbound SIM they go to the device owner's inbox instead (`core/agent/telephony_owner.go:16-19`). |
| Files, photos, notes, an app's own in-app settings | **Yes** | Pure data, inside the app's own storage. |
| `Settings > Apps > <app>` OS toggles (exploit-protection compat mode, Storage/Contact Scopes) | **Not yet — DECIDED 2026-08-21 they must** (`product-decisions.md`: the owner’s risk call, not ours; banking apps need compat mode and it is GrapheneOS’s own recommendation) | Per-user framework state (`GosPackageState`-class), ~~in no sealed scope~~, and a fresh Android user is minted each login — ~~the mechanism is open work (`NWP-20260820-05`)~~. *(Superseded 2026-10-21 for the hardening flags on Endospore: Slice A, `NWP-20260821-17`, captures and re-applies them (`GosState.java`), and every Endospore build applies `gos-chooser-grant.sh`. It has never been observed on a handset (`backlog.md`, the Slice A row), so the verdict stays “Not yet” until it is. Storage Scopes cannot roam as built (blocked by design); Contact Scopes are blocked.)* ⚠ Network permission (INTERNET) is the ONE part that already roams (#127) — which makes the screen look like it all roams. |
| Most app data (games, readers…) | **Mostly** | `/data/data` — ~~unless it leans on Keystore.~~ **Superseded 2026-10-16 (`NWP-20261016-46`):** since `NWP-20260830-03` an app's Keystore keys roam with its data on the same phone, except keys bound to the screen lock or a fingerprint (layer 2). |
| WebView / web-session logins (e.g. Coach USA, `com.orbit_user_app`) | **Yes — whether you want it or not** | The session is ordinary app data (cookies, WebView IndexedDB/leveldb, localStorage), so it roams with the app (layer 3). Only an in-app sign-out before logoff, or roaming mode Off (which drops all the app's data), stops it. A `grep`/`strings` sweep cannot see it in a compressed leveldb; answer with the sign-out differential below. |
| WhatsApp / Signal | **Data yes, login no** | Chats roam (file-encrypted DB); registration is device-bound → re-verify per device. |
| Banking / payments | ~~**No**~~ **Superseded 2026-10-16 (`NWP-20261016-46`).** Runs: **on Endospore, five mainstream US banking apps are maintainer-reported working (2026-10-16; phone, build and compatibility-mode setting not recorded)** · **on Diaspore, not an app that checks Play Integrity** · stays signed in across a sign-out: **not measured for the five; the one app on record tested, an Intune-managed work app, does not (cause open)** | ~~Play Integrity + Keystore; also fails on this ROM's unlocked bootloader.~~ That was written for Diaspore, and before the Keystore carry. On Endospore the five run with sandboxed Google Play, which passes basic integrity only, so an app that demands strong attestation still refuses: hardware key attestation shows our own AVB key (`endospore-spec.md`, remote attestation; `product-decisions.md`, “the public claim on banking apps says they ‘might not work’, not that they won’t”; by Chester's direction the five are not recorded with this report anywhere, here or in nowhere-cloud `launch/claims-matrix.md`). On Diaspore there are no Google Play services and the bootloader stays unlocked, so Play Integrity fails. Since `NWP-20260830-03` an app's Keystore keys roam with its data, except keys bound to the screen lock or a fingerprint (`framework-patches.md`, `keystore-roam.sh`); a bank's own device binding may still see a new device at each sign-in (layer 2). That Intune-managed work app came back with no data although its app data and its Keystore key were restored; the cause is open (`backlog.md` §C, the row for ticket `NW-4f9eb634fde4`). |
| Netflix (HD), other DRM | **No** | Widevine L1 device keys. |
| Authenticators / passkeys | ~~**No**~~ **Superseded 2026-10-04 (`NWP-20261003-02`).** On the SAME phone: **yes, mostly** · on another phone: ~~**app keys unproven**~~ **app keys do not come back** (superseded 2026-10-16, `NWP-20261016-46`: the import refuses them; not tried on hardware) | ~~Device-bound credentials (that's the point of them).~~ That was written before the Keystore carry. Since `NWP-20260830-03` every app's Keystore keys roam with its data, unconditionally, so an app's keys come back at the next sign-in on the same phone. ⚠ Keys bound to the screen lock or a fingerprint are DELETED at a cold-lock resume (`NWP-20260917-30`, open), so a biometric unlock does not survive one. TOTP apps such as Aegis keep their seeds in app data and roam as app data (untested; `backlog.md`, the Aegis row). Synced passkeys: untested (`backlog.md`, the synced-passkey row). ~~On ANOTHER handset the carry is unproven: Keystore keys are TEE-backed and the import may refuse foreign hardware (`profile-snapshot.md` §1).~~ **Superseded 2026-10-16 (`NWP-20261016-46`):** on ANOTHER handset they do not come back: the import refuses a bundle stamped for another device (`keystore-roam.sh`, layer 2); no restore onto different hardware has been tried (`profile-snapshot.md` §1). |

## How to answer "does app X stay signed in across a roam"
Answer it by **measurement on a device, with a sign-out differential** — not by reading the app's
files for something that looks like a token.

1. Sign in to the app. As root, capture **every** store under the app's data dirs (`/data/user/<N>/<pkg>`
   and `/data/user_de/<N>/<pkg>`): `shared_prefs/`, `databases/`, `files/`, and the WebView tree
   (`app_webview/…`: Cookies, Local Storage, Session Storage, IndexedDB). Record a hash of each file and
   keep a copy.
2. Sign out **inside the app**, by its own control.
3. Capture the same stores again the same way.
4. Diff the two captures file by file. The files that changed at sign-out are where the session lives;
   files that stayed byte-identical are not carrying it.
5. For every leveldb (IndexedDB, Local Storage), read its `LOG` file: leveldb writes its own compactions
   there, and a compaction logged at the moment of sign-out names the store that dropped the session —
   in `com.orbit_user_app` it was the only store that moved.
6. Say how strong the answer is. A differential is correlational: it shows which store changed, not that
   the session lived only there. To make it subtractive, delete that one store on a signed-in copy and
   confirm the app comes up signed out.

Whether the app comes back signed in at all is then an ordinary roam (log off, log back in, open it). If
it does and step 4 points only at app data, the app is layer 3; if it does not, look at layer 2 (a
Keystore key, attestation, server-side device binding).

⚠ **`grep`/`strings` sweeps are blind to compressed stores.** A leveldb table is compressed, so a sweep
that finds no token there has not looked. This is the #39 lesson — *assert the value, not the marker*:
an instrument that looks authoritative and silently reads nothing proves nothing. The sweep of
`com.orbit_user_app`'s 72 files found no credential while the app was signed in.

## Design stance
- Diaspore **owns the data + privacy story**: messages, contacts, files, settings, most apps, and the
  amnesiac "nothing left at rest" — on power-off your SMS history *leaves the device*, a stronger
  property than any normal phone offers.
- Diaspore is **honest about the boundary**: device-anchored trust (banking, DRM, attestation, the
  WhatsApp/Signal login handshake) re-attests or re-registers per device. We don't pretend to defeat
  attestation — that's a different, adversarial problem.
- Diaspore is equally honest about the other side of it: a session an app keeps in its own data roams
  with that data (layer 3), and we do not offer a per-app sign-out we cannot deliver.
- Framing: **roamable data is your life; device-bound trust is the stuff someone deliberately nailed
  down.** Diaspore moves the first and is upfront about the second.

## Implications for the build
- The **per-user model** is the right home for full-fidelity data roaming (SMS/contacts/app data) and
  reconciles with the session-lifecycle (logoff/switch) design.
- **Volume**: app data is GBs, and today's roaming state is a **RAM-backed tmpfs** — right for a small
  working set, wrong for a full `/data`. Full roaming needs a disk-or-hybrid backing + chunk-level CDC.
- For device-bound apps the realistic UX is: the data is there, but the app re-registers/re-attests on
  first use per device. Set that expectation rather than promising seamlessness.
