# On-demand sandboxed Play — group materialize (design note, DIA-20260802)

**Status: IMPLEMENTED (DIA-20260802-09, chooser versionCode 30).** Goal: let the sandboxed-Play stack
(Play Store + Play Services) roam as an **on-demand** set, so its large code/data isn't sealed eagerly on
every logoff — yet one tap on Play Store brings the *working* stack (Store **and** Services) back.

## Implementation (as built)

Five files, no Go agent change (the manifest is opaque to the agent):
- **`ProfileActivity.java`** — `DEFAULT_GROUPS` bootstrap (`vending`/`gms`/`gsf` → `sandboxed-play`) +
  `defaultGroupFor`/`readAppGroups`/`groupFor`/`groupDeps` helpers. `captureAppCode` emits an optional trailing
  `group:<name>` token into `nowhere-appcode.list`. **Load-bearing fix:** `readAppModes` + `ondemandKeepSet`
  now split on *all* tabs (a first-tab-only parse read a 3-token `pkg⇥ondemand⇥group:…` line as INSTALLED and
  dropped gms from the on-demand set).
- **`nowhere_roamd.sh` `appcode_seal`** — carries the `group:` token through to `manifest.tsv` as a **trailing**
  field (keeps `col4=mode`/`col5=apk` byte-identical; `cut -f1/-f4` reap readers + the Go agent are unaffected).
- **`ChooserActivity.java` login** — reads the trailing group tag; a launcher-less group member (gms/gsf, zero
  sealed `act` lines) skips the placeholder cleanly (`hasLauncherMeta` check) and is recorded as a deferred group
  dep instead of logging a bogus "placeholder failed".
- **`UnarchiveService.java` tap** — `materializeAndInstall` iterates `groupDeps(this, entryPkg)` **deps-first**
  via a new `materializeMember()` (MATERIALIZE-APP + installApks + RESTORE-ODDATA per launcher-less member, no
  card/launch/arm), so Play Services is fully installed + data-restored + account-reloaded before Play Store
  launches. The group is resolved at tap from the roamed `nowhere-appkeep` (the sealed manifest is user-0-only
  and deleted post-login).
- **`nowhere_roamd.sh` account timing** — the `#sys` `acct_reload` is DEFERRED from the login `grant` op to the
  account member's tap-time `odrestore`, gated by a `/data/nowhere/acct-deferred-<uid>` marker so the **proven
  INSTALLED-gms path still reloads at `grant`, unchanged** (only the on-demand path moves to odrestore).

To use: set `com.android.vending` + `com.google.android.gms` to `ondemand` in the keep-set — `DEFAULT_GROUPS`
groups them (no hand-authored `group:` token needed). One tap on Play Store brings the whole stack back.

## E2E test (2026-08-02, odtest20→user11, flashed #532+#533): plumbing PROVEN, 3 blockers remain

- **#533 (dia-20260802-10)** extends `endospore-gmscompat-chooser-exempt.sh` so the on-demand **archived-placeholder**
  install of Play Store isn't gmscompat-blocked (`mInstallSource.mInstallerPackageName == com.nowhere.chooser` +
  `isArchivedInstallation()`). Needed because the archived-install path carries the sealed pkg's *original* installer
  as `initiatingPackageName`, so #531's initiator-only exemption missed it. ⚠ **Build lesson:** a change to a
  framework `patches/*.sh` only takes effect if the build **re-applies it to the graphene tree** — `stage-vendor`+`m`
  handles `core/` but NOT framework patches; #533's first build shipped stale until re-applied.
- **What worked:** deps-first materialize — `MATERIALIZE-APP(dep) gms` → installed → `RESTORE-ODDATA(dep)` →
  `group dep gms → true`, and the deferred account reload fired exactly as designed
  (`odrestore com.google.android.gms → deferred acct_reload fired`).
- **BLOCKER 1 — Play Store real-APK install fails over its placeholder:**
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE: com.android.vending signatures do not match newer version` (chooser
  `unarchive install ... status=5`). Play Store stays archived and never returns. The placeholder's recorded
  signature (from `captureArchivedMeta`'s sealed `_meta` cert) ≠ the materialized real-APK signature. Investigate the
  placeholder cert capture (or a gmscompat signature quirk for vending). This is the direct cause of the icon revert.
- **BLOCKER 2 — account purged:** `Accounts: 0`, `accounts_ce.db` empty. The deferred `acct_reload` fired ~2s after
  gms installed, *before* gms's `GoogleAccountAuthenticatorService` registered, so `validateAccountsInternal` deleted
  the account (the authenticator-lag race, now on the on-demand path). Fix: `acct_reload` must **wait/poll for gms's
  authenticator** before reloading (the login-`grant` path avoided this only because grant runs after a natural delay).
- **BLOCKER 3 (UX, cosmetic) — framework unarchive window vs slow fetch:** the framework grants a **120s**
  foreground-service allowlist on the unarchive tap, but fetching gms first took ~2.5 min, so the framework's
  *own* unarchive progress UI abandoned its session and the icon reverted to the archived (cloud) look. The
  materialize itself keeps running in **our** `UnarchiveService` foreground service past that window (the E2E logs
  show gms fetched + installed + `acct_reload` fired *after* the revert), so this is **not** a functional failure —
  it's a missing "downloading" progress cue during the fetch. Once BLOCKER 1 lands, vending's real APK installs and
  the icon resolves to the real Play Store at the end; the icon stayed archived *permanently* in the failed run only
  because BLOCKER 1 killed the real install. No code change for the E2E fix — noted as a progress-indicator polish.

## Fixes (DIA-20260802-11, chooser versionCode 31)

- **BLOCKER 1 fixed — `captureArchivedMeta` records the CURRENT signer only.** `ProfileActivity.captureArchivedMeta`
  used `si.hasMultipleSigners() ? getApkContentsSigners() : getSigningCertificateHistory()` — for a key-rotated
  single-signer app (Play Store / gms carry a v3 signing lineage) the *history* is `[oldCert, currentCert]`, and
  `installArchivedPlaceholder` rebuilt that as a **multi-signer** `SigningInfo {old,current}` with null
  past-signing-certs. The real APK presents a single current signer **plus** a rotation lineage, so PMS's
  `compareSignatures` saw multi-signer{old,current} ≠ single-signer{current} → `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
  Non-rotated apps (the P2 test set) have a history of length 1, which is why they materialized fine. Fix: capture
  `si.getApkContentsSigners()` unconditionally (the current signer(s) in both single- and multi-signer cases); these
  match the real APK directly via `compareSignatures`, and the ephemeral placeholder — replaced by the real APK on
  tap — needs no lineage of its own. **Seal-side:** takes effect on the next logoff/re-seal after flashing.
- **BLOCKER 2 fixed — `acct_reload` waits for gms's authenticator on the on-demand path.** New
  `wait_acct_authenticator()` in `nowhere_roamd.sh` polls (bounded, ~30s, returns immediately once present) the
  per-user `registered_services/android.accounts.AccountAuthenticator.xml` for a `type="com.google"` entry before
  the deferred `acct_reload` runs in the `odrestore` op. That file is a plain read (not a `cmd`/dumpsys binder fd, so
  it dodges the su:s0 fd-capture denial) and gaining the entry is a lower bound on "authenticator registered", so
  `validateAccountsInternal` no longer purges the account. The login `grant` path is untouched (proven; runs after a
  natural delay). Falls through after the timeout so a never-registered authenticator is no worse than before.
- **Retest:** re-seal a clean profile with vending+gms `ondemand`, roam, tap Play Store → vending real APK installs
  over the (now single-signer) placeholder, gms materializes deps-first, and the account survives the reload.

## E2E PROVEN on flashed #534 (2026-08-02, fresh profile odtest22 → user 11)

One tap on the on-demand Play Store brought the whole sandboxed-Play stack back, working + signed in:
- **BLOCKER 1 fixed** — restored placeholder had exactly **1** `cert` line (was 2); `NowhereChooser: unarchive install
  com.android.vending status=0` (was `status=5`); vending `installed=true`, auto-launched, real Play Store icon.
- **BLOCKER 2 held** — `accounts_ce.db` user 11 kept `<account> / com.google`, `dumpsys account → Accounts: 1`.
- gms materialized deps-first (`materializeapp gms` → `odrestore gms` → `deferred acct_reload fired`), then vending.

Three residuals surfaced — none block the result, all fold into ONE next build:

1. **`wait_acct_authenticator` detector is a no-op** — the per-user `AccountAuthenticator.xml` is **ABX (binary XML)**,
   so `grep 'type="com.google"'` never matches → the poll ran its full 30 s and fell through (`NOT seen … reloading
   anyway`). The account survived only because 30 s was enough for the authenticator to actually register. ~~Fix:
   binary-safe substring — `grep -qa 'com.google'` (root-verified it matches).~~ *(Superseded 2026-11-21,
   NWP-20261121-03: a substring also matched Gmail's `com.google.android.gm.*` authenticator types, so the wait could
   end before GMS registered. `acct_type_registered` now matches the whole type: `type="<type>"` in text XML, or the
   2-byte length-prefixed string in ABX.)* The file is labeled
   `system_data_file`; roamd runs `endospore_priv` (permissive here, so reads it) — add a read allow if this must
   hold under enforcing.
2. **UX gap (blocker 4) — gms can't be set on-demand from the UI.** The "Your apps" toggle lists only launcher apps,
   and `groupDeps` only pulls keep-set members, so gms must be in `nowhere-appkeep` as `ondemand` — but nothing in the
   UI puts it there (for this test it was injected by hand via root). Fix: when a group **entry point** (vending) is
   set on-demand, cascade its installed launcher-less group members (gms, gsf) into the keep-set as on-demand, so the
   single visible Play Store toggle is enough. This is the "Play Store → depends on → Play Services" direction.
3. **Fresh-gms checkin lag → Play "try again".** A materialized gms has **no `android_id`** (checkin state doesn't
   roam), so Play loops on "Reauthenticating account … on retry" until a checkin lands. Manually resolved by
   `am broadcast android.server.checkin.CHECKIN` (android_id → `4265737865666688254`) **then force-stopping Play+gms**
   so they re-init with the identity (a stale pre-checkin Finsky kept failing). Fix: fire the checkin automatically at
   group-materialize completion (after gms `odrestore`) — and consider bouncing Finsky — so the user never sees it.

## Residual fixes (DIA-20260802-12, chooser versionCode 32)

All three residuals above are addressed so the feature works from the **visible Play Store toggle alone**, with no
hand-injected keep-set line and no manual checkin:

1. **Detector (a)** — ~~`wait_acct_authenticator` now matches the account-type as a **binary-safe substring**
   (`grep -qa "$type"`) instead of a text `type="…"` pattern, because `AccountAuthenticator.xml` is ABX.~~
   *(Superseded 2026-11-21, NWP-20261121-03: a substring also matched Gmail's `com.google.android.gm.*` authenticator
   types, so the wait could end before GMS registered. `acct_type_registered` now matches the whole type:
   `type="<type>"` in text XML, or the 2-byte length-prefixed string in ABX.)* The poll now
   returns the instant the authenticator registers rather than always running to timeout. (`nowhere_roamd.sh`.)
2. **Cascade (b)** — `ProfileActivity.setAppMode` mirrors an entry point's mode onto its **installed launcher-less
   group members** (`launcherlessGroupMembers`): setting Play Store on-demand now writes `com.google.android.gms`
   (and GSF if present) into `nowhere-appkeep` as on-demand automatically, and dropping / installing Play Store
   follows suit. This is the "Play Store → depends on → Play Services" dependency, made real. (`ProfileActivity.java`.)
3. **Auto-checkin (c)** — the gms `odrestore` op now fires `am broadcast android.server.checkin.CHECKIN` for the
   roamed user **before** vending materializes and auto-launches Finsky (~60 s later), so Play starts with `android_id`
   already established and never enters the "try again" loop. Fire-and-forget over the network. (`nowhere_roamd.sh`.)

Retest: fresh profile, sign in, set **only Play Store → on-demand** (gms should now join the keep-set automatically),
roam, tap Play Store → whole stack materializes, account survives, and Play Store opens signed-in with no manual steps.

## Generalized Play-Services dependency + download progress (DIA-20260802-13, chooser versionCode 33)

Two extensions, chooser-only (no roamd change — the tap materialize already runs each dep through
`MATERIALIZE-APP` → `odrestore`, which fires the account reload + checkin for gms):

- **Any app that uses Play Services now depends on gms** (not just the sandboxed-play group). `setAppMode` records a
  Play-Services client (detected by the `com.google.android.gms.version` manifest meta-data, read while the app is
  installed) into a roamed `nowhere-playdeps` list, and `reconcilePlayProviders` keeps the launcher-less providers
  in sync with demand:
  - **gms** is kept iff any sandboxed-play group member *or* any recorded Play-Services client is kept; **gsf** only
    for group members (a generic client's tap materializes gms alone — pulling gsf for it would seal dead weight).
  - **INSTALLED dominates on-demand:** an installed dependent launches at sign-in with no tap to materialize the
    provider, so the provider is installed whenever *any* dependent is installed, and on-demand only when *every*
    dependent is on-demand.
  - Demand is computed from **archive-safe recorded facts** (group membership + `nowhere-playdeps`), never a live
    manifest read — which throws for an already-archived client and would undercount demand.

  `appDeps()` = `groupDeps()` ∪ gms (for a recorded client, when gms is a sealed on-demand member), and
  `UnarchiveService` materializes `appDeps` deps-first. So **YouTube → on-demand** pulls Play Services along and
  tapping YouTube materializes gms first — same as Play Store — and it generalizes to any Play-Services app (games,
  etc.). Clients are recorded whenever **kept** (installed or on-demand), so an installed Play-Services app also
  keeps gms installed. The providers stay **invisible + untoggleable** in "Your apps" (a keep-set enumeration filter),
  since a ghost row would inflate the count and toggling gms off would strand every client.

  *(Two adversarial pre-PR review rounds hardened this: installed-dominance, gsf-group-only, archive-safe demand,
  refcount-correct removal, installed-client coverage, writing a provider mode without requiring it be live-installed
  on the roamed user, and keeping the providers out of the user-visible app list.)*
- **Download progress indicator.** `UnarchiveService`'s foreground-service notification now shows a step-wise
  progress bar — `Downloading <app> (n of m)` across the whole materialize set — instead of a bare spinner. The
  framework's own unarchive ring on the launcher icon times out during the ~2.5 min fetch, so this notification is
  the durable progress surface (the icon still reverts to archived mid-fetch, then resolves to the real app on
  completion — a framework limitation we route around rather than fight).

## Whole-stack dependency: a client pulls Play Store too (DIA-20260803-01, chooser versionCode 34)

DIA-20260802-13 made a client pull **gms**; on-device that wasn't enough — YouTube reported **"device not
compatible"** because Google apps check for the **Play Store app itself** (`com.android.vending`), via
`GooglePlayServicesUtil` ("requires the Google Play Store, but it is missing"), not just Services. (Aurora Store
can't stand in — it's `com.aurora.store`, not the `com.android.vending` package the check wants.) So a Play-Services
client now depends on the **whole sandboxed-Play stack** {vending, gms, gsf}:

- `appDeps(client)` = `groupDeps()` ∪ the stack members that are sealed on-demand (`[gms, gsf, vending]`), so tapping
  YouTube materializes Play Services **and** Play Store deps-first, then YouTube. `isStackMember` short-circuits a
  stack member's own tap to plain `groupDeps` (unchanged).
- `reconcilePlayStack` (was `reconcilePlayProviders`) computes one `need` across kept clients (playdeps + installed-
  live), then: **gms/gsf** — reconcile owns their mode; **vending** — split by whether the user chose its mode. A
  **user-kept** vending keeps the user's mode untouched (its own mode feeds `need`, so overwriting it would self-
  latch to installed forever). An **auto-pulled** vending (not in playdeps, so not a demand source) has its mode
  owned by reconcile at `need`, so it stays consistent with gms/gsf. A `preKept` snapshot lets a just-toggled-off
  but still-demanded vending be re-added from its sealed bytes. Play Store stays a **visible, user-toggleable** row
  (only gms/gsf are hidden); turning it off while a client is kept re-adds it (dependency enforcement).

*Three adversarial review rounds hardened this* — they caught and fixed, before any build: vending self-latching to
installed, an archived vending being un-re-addable after toggle-off, and an installed client leaving Play Store on-
demand while Services went installed. Final gate: clean for every on-demand toggle sequence.

### Known limitations (out of scope for the on-demand feature; tracked separately)

- **Installed sandboxed-Play stack is broken** at a deeper layer: `hold_ondemand` parks a launcher-less member's data
  even in *installed* mode (empty-mode keep-set line), and the login-side launcher-less deferral (DIA-20260802,
  #532) never fires `RESTORE-ODDATA` for an **installed** launcher-less gms — so an installed gms roams back with
  **no data + no account**. Because of this, keeping the stack *installed* doesn't work regardless of reconcile, and
  a *user-kept on-demand* Play Store beside an installed client stays on-demand (the no-latch rule). Both resolve
  together when the installed-launcher-less-restore path is fixed. The **on-demand** config (the feature's target)
  is unaffected.
- **PIN not surviving a roam** (separate bug): `set-pin` writes the PIN to the sealed vault, but a subsequent seal
  can push a vault snapshot without it, so the next login restores a PIN-less vault (`PIN-STATUS=NONE`) and warm-lock
  falls back to the passphrase. Not a lock-out. See warm-lock notes.

## Motivation

Sandboxed Play now roams as `MODE_INSTALLED` (see docs/sandboxed-play-roam.md): its APKs seal into
`name#apps` and its data + account roam on every logoff. That works, but `com.google.android.gms`
alone is 100s of MB of code + data — the single biggest thing in the roam footprint. The on-demand
tier exists precisely for this: keep an app as an **archived placeholder** (no APK, no bulk data
roam) until the user taps it, then materialize it from `name#apps`. Making sandboxed Play on-demand
would cut the roam footprint dramatically for users who only occasionally open the Store.

## Why the naive approach doesn't work

Setting **both** `com.android.vending` and `com.google.android.gms` to `ondemand` and tapping Play
Store does **not** bring Play Services back. Three reasons:

1. **Materialize is per-app and tap-driven.** A tap fires `ACTION_UNARCHIVE_PACKAGE` for *that one*
   package -> `UnarchiveService` -> `MATERIALIZE-APP <pkg>` -> `installStagedApk` -> `odrestore`.
   Nothing follows dependencies; Android's unarchive doesn't chase them, and gms isn't a static
   dependency of vending (they talk over IPC at runtime, as separate packages).
2. **Play Services can't be a tappable placeholder at all.** The archived placeholder is raised from
   the sealed `ArchivedPackageInfo` — essentially the launcher activities + their icons (what
   `captureArchivedMeta` seals). **gms has no launcher activity** (the same reason it's filtered out
   of "Your apps"). So an on-demand gms is an icon-less ghost: nothing to show, nothing to tap, no
   way to trigger its own materialize.
3. **Play Store is useless without Play Services.** Even a cleanly-materialized vending needs gms for
   auth/licensing/downloads; with gms still archived it just fails.

So "both on-demand, tap the Store" yields a materialized-but-broken Store plus an un-materializable
Services ghost.

## Design: group materialize

Treat the sandboxed-Play packages as one **materialize group**. Tapping the member that *has* a
launcher (Play Store) materializes the **whole group** — including the launcher-less members
(Play Services, and GSF if present).

### Group declaration

Add an optional group tag to the keep-set line (`files/nowhere-appkeep`) and carry it through the
sealed manifest (`.appcode/manifest.tsv`):

```
com.android.vending   ondemand   group:sandboxed-play
com.google.android.gms ondemand  group:sandboxed-play
```

`captureAppCode` already parses the mode column; extend it to a 3rd `group:<name>` token. A group is
just "these packages materialize together." Keep it data-driven (no hardcoded package list) so other
runtime bundles (e.g. a webview + its provider) can reuse it. As a bootstrap, a built-in default
group for the GMS set is fine.

### Seal / login (placeholder only the entry point)

- **Seal:** every group member's code (`name#apps`) + data (`.nowhere-odhold`, via `hold_ondemand`)
  seals exactly as an ordinary on-demand app does today — no change.
- **Login placeholder:** raise an archived placeholder **only for members that have a launcher
  activity** (the group's *entry points* — here, just Play Store). Launcher-less members (gms, gsf)
  are sealed + held but get **no** placeholder — they're never tapped directly. `installRoamedAppCode`
  already skips a placeholder when the sealed `ArchivedPackageInfo` has no launcher activities; make
  that explicit and record the member as a *deferred group dependency* rather than dropping it.

### Tap -> materialize the group

When `UnarchiveService` receives `ACTION_UNARCHIVE_PACKAGE` for a group entry point (vending), it
materializes the entry point **and then iterates the rest of its group**, running the same steps for
each launcher-less member:

```
onUnarchive(vending):
  materialize(vending)                       # existing: MATERIALIZE-APP + installStagedApk + odrestore
  for dep in group(vending) - {vending}:     # gms, (gsf)
      MATERIALIZE-APP dep                     # agent fetches dep's APK from name#apps -> .appcode
      installStagedApk(dep)                   # real APK install (gmscompat exemption already allows it)
      RESTORE-ODDATA dep                       # odrestore: held data back + reown + keystore_register + grant
```

The chooser resolves the group from the restored manifest. Order matters: install gms **before**
vending finishes wiring up so the Store finds Services on first launch (or install gms first, then
vending). Each `installStagedApk` benefits from the gmscompat install exemption; each `odrestore`
brings the member's held data + (for gms) the account, and `keystore_register`s it — so this composes
with the account roam (DIA-20260802-04..06) for free.

### UX

- The launcher shows **one** icon (Play Store). Tapping it shows the normal materialize/loading
  screen while the whole group installs. The account reload (grant-op `acct_reload`) still runs at
  login; if the account should only reload once gms materializes, move/duplicate that step into the
  group-materialize completion.

## Open questions

- **Group entry points:** what if a group has *no* launcher member? (Not the case for Play, but for
  generality — such a group can only be "installed" mode, or needs a synthetic tappable entry.)
- **Partial failure:** if a dependency's fetch fails mid-group, leave the entry point materialized and
  retry the deps on next launch, or roll the whole group back? (Lean: per-member best-effort + a
  "group incomplete" surface, like the store's INCOMPLETE handling.)
- **Account timing:** the `#sys` account reload currently fires in the grant op at login. For an
  on-demand gms, the account is meaningless until gms materializes — so the reload (and the
  keystore-key import, once built) should hang off the **group-materialize completion**, not login.
- **First-tap latency:** gms is large; the first tap downloads its APK over Wi-Fi. Acceptable for an
  opt-in on-demand tier, but worth a determinate progress bar for the group.

## Relation to existing work

- Builds directly on the on-demand tier (`hold_ondemand` / `odrestore` / `MATERIALIZE-APP` /
  `installArchivedPlaceholder`) and the sandboxed-Play roam chain (gmscompat exemption, `#526`/`#527`/
  `#528`, the `name#sys` account scope).
- The keystore-key roam (still to build) plugs into the same `odrestore`/`keystore_register` point, so
  a group-materialized gms would pick up its keys there too.

## ⚠ The gap process: a materialized app runs BEFORE its data and keys land (DIA-20260803-02)

Proven on odtest4 (flashed vc34, profile odtest27 → user 13) while retesting the whole-stack dependency
with **Ring** (`com.ringapp`, a third-party Play-Services client). The stack materialized correctly and
Ring opened — no "device not compatible" — but Ring came up **signed out**.

The tap sequence is not the whole story: **the app starts on its own, a minute before its state arrives.**

```
19:46:25.471  ActivityManager: Start proc 26071:com.ringapp for bound-service
                {com.ringapp/com.android.internal.gmscompat.client.GmsCompatClientService}
19:46:26      Ring mints _androidx_security_master_key_ into the still-EMPTY keystore ns 1310270
19:47:33      RESTORE-ODDATA moves Ring's held CE/DE data back (vault encrypted under the CARRIED key)
19:47:34      keystore_register stages the carried bundle at IMPORT_DIR/1310270.keys
19:47:35.386  keystore2: "nowhere: keystore imported 10 key(s) into ns 1310270 (#210)"
19:47:35.468  AndroidKeyStoreSpi: KeyStoreException System error
                database.rs:2086 "In with_rows_extract_one: Unexpected row."
19:47:35.48+  Ring regenerates 7 keys → LoginActivity
```

**Why it happens:** `gmscompat` binds a Play-Services client's `GmsCompatClientService` the instant
`installApks` completes. That process initializes as a **first run** against an empty profile and mints
its own keystore keys. `keyentry` has **no UNIQUE on `(domain, namespace, alias)`**, so when the carried
bundle then imports, it lands a *second* Live row for an alias the gap process already created — and
every later lookup dies in `with_rows_extract_one` (`SYSTEM_ERROR`). The app reads that as a corrupt
vault and rebuilds it, which is precisely the sign-out the carry exists to prevent.

**Why the LOGIN-roam path never hit this** (Amazon has been stable for weeks): a kept *installed* app is
not auto-launched at login — the user taps it minutes later, so nothing mints in between. The lazy
import had unbounded slack. The on-demand tap path removed that slack.

### The fix (three parts, all required)

1. **The carried key wins** — `nowhere_import_keys` unreferences any row holding the alias before
   inserting (alias/domain/namespace NULLed, state `Unreferenced`), exactly as the stock create path's
   `rebind_alias` does, and now propagates the row count into `.do_gc(need_gc)` so the displaced blob is
   actually reclaimed. No duplicate row, no `SYSTEM_ERROR`.
2. **Import before the lookup, not only on a miss** — on-miss alone never fires once the gap process has
   minted the very alias the app then looks up: the lookup *hits* its own fresh key, so the carried
   bundle is never consumed at all and the user is signed out with their real keys sitting unread on
   disk. `try_import` is one-shot, so this stays a stat in the steady state.
3. **Kill the gap process** — `odrestore` force-stops the package before copying its data back, so
   nothing holds stale in-memory keys or flushes a fresh vault over the restored one.

### Two traps this exposed (both fixed here, both would have wasted a build)

- **`am force-stop` leaves the package STOPPED**, and AMS adds `FLAG_EXCLUDE_STOPPED_PACKAGES` to every
  broadcast — so the `CHECKIN` kick fired later in the *same* `odrestore` op would have been silently
  dropped, regressing the proven DIA-20260802-12 android_id bootstrap (and the next line logs
  "checkin kicked" regardless). The kick now passes `--include-stopped-packages`, which also cold-starts
  gms — what the kick wants anyway — and clears the stopped flag before `acct_reload`.
- **`keystore-roam.sh` skipped whenever its marker was present**, so applying it to an already-patched
  tree would have shipped a build *without* this fix while reporting success. The marker is now
  version-aware: it refuses, prints the revert command, and a post-patch check enforces that the version
  string is actually stamped into `database.rs` so the gate can never self-brick.

⚠ **Build note:** the keystore2 half is a source patch, so a tree that already carries the older patch
must be reverted before rebuilding — `git -C <tree>/system/security/keystore2 checkout -- src/ && rm -f
<tree>/system/security/keystore2/src/nowhere_roam.rs` — then re-run the patch script. Part 3 is roamd
(`/system/bin`, hot-patchable); parts 1–2 are keystore2 and need the flash.
