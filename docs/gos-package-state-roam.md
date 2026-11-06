# Roaming GrapheneOS per-app state (`GosPackageState`)

**Status: Slice A BUILT (`NWP-20260821-17`), pending a build + on-hardware proof. Slices B and C blocked.** Endospore-only.

**Architecture: A″** — chosen by the maintainer 2026-08-21. The framework patch grants the chooser same-user read/write and the chooser does both halves from inside the roamed user; there is no helper binary, no sepolicy change and no cross-user permission anywhere.
Supersedes the mechanism section of the `NWP-20260821-05` research row in `backlog.md`,
**two of whose load-bearing claims are wrong** — see [§2](#2-corrections-to-the-nwp-20260821-05-research).

Direction is settled in `product-decisions.md`: this class **must** roam. The
owner's risk call, not ours; banking apps are the canonical need and exploit-protection compatibility
mode is GrapheneOS's own recommendation for running them. The document-as-not-roamed door is closed.

Everything marked **DEVICE-PROVEN** was measured on lynx (Pixel 7a, build `2026082100`, userdebug) on
2026-08-21 at **uid 2000**, not root — see [§3](#3-device-proven-facts). Everything else is cited to
GrapheneOS source at `/mnt/build/graphene/grapheneos-2026061600` on the build host.

---

## 1. Verdict: this is three slices, not one, and two of them are blocked

| Part | Verdict |
| --- | --- |
| **A — the hardening flags, including `ENABLE_EXPLOIT_PROTECTION_COMPAT_MODE`** | **BUILDABLE.** Closes the stated need. |
| **B — Storage Scopes** (flag 0 + blob) | **BLOCKED BY DESIGN.** The blob embeds the **source user id** as a literal path. |
| **C — Contact Scopes** (flag 5 + blob) | **BLOCKED** pending id-stability proof — and the obvious test proves nothing. |

Shipping these together would have released B and C broken under cover of A working. They fail in the
project's signature way: **merged, inert, and self-reporting success.**

### Why B is blocked

A storage scope is a plain absolute path string — `StorageScope.java:40` `public final String path`,
serialized at `:100` `s.writeUTF(scope.path)`. It must resolve under a `StorageVolume` root, and the
primary emulated root is **user-scoped**: `VolumeInfo.java:379` returns
`new File(path, Integer.toString(userId))`, i.e. `/storage/emulated/<userId>`. Enforcement is a literal
`startsWith` match (`StorageScopesHooks.java:136-144`), not a canonicalisation, and the shell write path
applies whatever hex it is handed with **zero validation** (`GosPackageStatePmHooks.java:355-356` →
`HexEncoding.decode`; `validateScopePath` lives only in PermissionController and is bypassed).

So a scope set in user 10 as `/storage/emulated/10/Documents/Bank`, replayed into user 12, matches
**nothing, ever** — while the app carries `STORAGE_SCOPES_ENABLED` and a naive byte-level read-back
reports a perfect match, because the bytes did round-trip faithfully. The user's app silently has access
to no files. This is not a risk to test for; it is arithmetic.

Unblocking it needs a serializer-level path rewrite, not a patch: the payload is Java modified-UTF-8 with
a 2-byte length prefix (`StorageScope.java:82-107`), and changing the user id changes the string length,
so the array must be fully parsed and re-emitted.

### Why C is blocked, and why the obvious test would falsely clear it

`ContactScopesStorage.java:23` holds `long[][] idsByType` over four types
(`ContactScope.java:13-16`: `TYPE_GROUP`, `TYPE_CONTACT`, `TYPE_NUMBER`, `TYPE_EMAIL`) — **raw database
row ids**. The framework itself treats these as fragile: `GosPackageStatePmHooks.clearContactScopesStorage`
exists precisely to *"discard IDs that refer to entries in the contacts provider database"* and is fired
from `onClearApplicationUserData` for the contacts provider. **The roam path bypasses that guard.**

⚠ **The failure mode is not "scopes to nothing", it is "scopes to different people."** An app the user
confined to three contacts silently gets three *other* contacts. That is a privacy regression, and it is
strictly worse than not roaming.

⚠ **The obvious test is the wrong test.** The investigation traced each type to the column it is matched
against in `ScopedContactsProvider.java`: `TYPE_GROUP` → `groups._id`; `TYPE_CONTACT` → `contacts._id`,
the **aggregated** id; `TYPE_NUMBER`/`TYPE_EMAIL` → `data._id`. **`raw_contacts._id` is used nowhere.**
A test that dumps `raw_contacts` would come back green and prove nothing, while `contacts._id` — the
aggregate id ContactsProvider2 creates and destroys — is the least stable of the three and the one such a
test never touches.

---

## 2. Corrections to the `NWP-20260821-05` research

That row is otherwise sound and its file:line work stands. Two claims do not.

### 2.1 "No framework patch" — WRONG. A framework patch is unavoidable.

The row's headline reads *"no framework patch, no file-seeding, no cache trap"*. The no-cache-trap half is
right (see [K5](#kill-list)). The rest is not, because **there is no shell read**:

- `edit-gos-package-state` is the only Gos entry in `PackageManagerShellCommand.java` (`:230-231`).
- `GosPackageStatePmHooks.runShellCommand` (`:330-368`) has nine verbs — `add-flag`, `clear-flag`,
  `add-package-flag`, `clear-package-flag`, `set-storage-scopes`, `set-contact-scopes`,
  `set-kill-uid-after-apply`, `set-notify-uid-after-apply`, `update-permission-state` — **all writes, no
  printer**. `dumpsys package` exposes nothing.
- The only read is the binder API `IPackageManager.aidl:870 getGosPackageState(String, int)`.

**DEVICE-PROVEN:** `cmd package get-gos-package-state 0 <pkg>` → `Unknown command`, `rc=255`.

So capture — reading the state to seal it — has nothing to call from a shell. The row's capture design
does not exist. Either the platform gains a read verb, or a new principal gains the binder permission.
Either way it is a framework patch, and that is real scope the row does not budget for.

### 2.2 "`set()` returns false for a not-yet-installed package" — WRONG, and it was the design's spine

The row says to apply *"strictly per-package AFTER that package is installed"* and to *"treat false as a
SEQUENCING BUG, never a soft failure"*. That constraint drove the entire apply architecture. It is false.

**DEVICE-PROVEN.** `com.farmerbb.notepad` was installed for user 12 and **not** for user 0. Writing it
for user 0 returned `rc=0` and persisted:

```xml
<pkg name="com.farmerbb.notepad" inst="false" stopped="true" nl="true" first-install-time="0">
  <GrapheneOS-package-state flags-1="16777216" />
</pkg>
```

Then `pm install-existing --user 0 com.farmerbb.notepad` — **the pre-seeded flag survived the install**,
the entry simply gaining real inodes. State can be seeded *before* the app exists for that user.

The source agrees: per-user state is force-created for every `PackageSetting` at user creation
(`Settings.java:4936-4937`, comment *"This would force-create correct per-user state"*), so the binding
refusal is **`no packageSetting`** (PM has never heard of the package at all), not `no user state`.

⚠ The converse **is** true and constrains siting: **`pm uninstall --user N` destroys the state**
(DEVICE-PROVEN — the entry collapses to a self-closing tag with no child). Roam-in reaps with
`pm uninstall` USER_ALL before raising placeholders, so **apply must run after the reap.**

---

## 3. Device-proven facts

Measured on lynx at **uid 2000** (`adb unroot` → `uid=2000(shell) context=u:r:shell:s0`).

⚠ **Root results on this device are worthless for this question.** `GosPackageStatePermissions.java:89`
grants `SHELL_UID` full permission **unconditionally**; the ROOT grant at `:90-93` is inside
`if (Build.isDebuggable())`. A userdebug lynx therefore grants root too, and a production `user` build
does not. Run `adb unroot` and confirm `id -u` == 2000 before any test, or the result is void.

| # | Fact | Evidence |
| --- | --- | --- |
| 1 | The uid-2000 write door works | `pm edit-gos-package-state <pkg> 0 add-flag ENABLE_EXPLOIT_PROTECTION_COMPAT_MODE` → `rc=0` |
| 2 | There is no read verb | `get-gos-package-state` → `Unknown command`, `rc=255` |
| 3 | State can be pre-seeded before install, and **survives** the install | §2.2 |
| 4 | Per-user uninstall **destroys** the state | entry collapses to a self-closing `<pkg …/>` |
| 5 | Cross-user writes work, to a **stopped** user | write to user 12 while it was not running → `rc=0` |
| 6 | Flag names **and** numeric indices both parse | `add-flag 24` → `rc=0` |
| 7 | A retired or unknown index **throws** | `add-flag 25` and `add-flag 29` → `IllegalArgumentException`, `rc=255` |
| 8 | **The editor is ATOMIC** | `add-flag 24 add-flag 25` in one command → the *valid* bit 24 did **not** land |
| 9 | Writeback is async and the file lags | four `clear-flag`s returned `rc=0` while the decoded XML still showed the old value; converged after ~20 s |

**Fact 8 is the one that makes the carry mask safety-critical.** `ed.apply()` runs only at EOF
(`GosPackageStatePmHooks.java:337-341`), so **one stray bit silently loses the entire package's state —
compat mode included.** A mask containing retired bit 25 would have been fatal in exactly that way.

**Fact 9 kills file-based capture** independently of the async-write argument in the original research:
the setting the user just made is precisely the one a logoff-time file read would miss.

### The four refusal causes, all reported as `rc=1`

Exit code alone is **ambiguous**. Only logcat (tag `GosPackageStatePmHooks`) separates them:

| logcat line | Real meaning | Proven with |
| --- | --- | --- |
| `set: no packageSetting for <pkg>` | PM has no record of the package at all | a bogus package name |
| `set: appId of <pkg> == SYSTEM_UID` | package is in `android.uid.system` — **refused outright** | `com.android.DeviceAsWebcam` |
| `no write permission` | caller's appId is not in the grant table | not exercised |
| `no user state` | **the user id does not exist** — *not* "not installed for that user" | user 99 |

⚠ The `SYSTEM_UID` refusal is a normal, expected outcome for any `android.uid.system` package, not a bug.
Capture must skip them so they never reach the apply counters as false alarms. It also made the first
negative test misleading: a system-uid package refuses for that reason, *not* for the reason under test.

### On-disk shape

`/data/system/users/<id>/package-restrictions.xml` is **Android Binary XML** — decode with
`abx2xml <in> <out>` (it needs **both** arguments; one argument throws `ArrayIndexOutOfBoundsException`).
State serializes as `<GrapheneOS-package-state flags-1="<decimal long>"/>` nested inside `<pkg name=…>`.

---

## 4. The carry set

Full enumeration, `GosPackageStateFlag.java:12-38` — 25 constants over indices `{0,1,5,6..24,26,27,28}`.
Indices **2, 3, 4 and 25 are retired** ("do not reuse"), and by fact 7 any of them in a mask is fatal.

**Slice A mask = `0x1FFFFC2`** = bits `{1, 6..24}` — narrowed from the review's `0x19FFFFC2` when A″ was chosen.

⚠ **The narrowing is a consequence of the architecture, not a change of mind.** Under A″ the grant *is* the allowlist: `filterRead` masks every read to the caller's granted flags, so withholding a flag from the patch makes it **structurally unreadable** by the chooser rather than merely filtered in our own code. Granting exactly GrapheneOS's own
`settingsReadWriteFlags` array — rather than a copied list — therefore does three things at once: it makes bit 26 unreachable by construction, it keeps the grant minimal, and it makes the carry set **track upstream automatically** if GrapheneOS adds a hardening switch. Play Integrity bits 27/28 are deliberately deferred to a follow-on rather than widening the grant to reach them.

| Carried | Why |
| --- | --- |
| 1 `ALLOW_ACCESS_TO_OBB_DIRECTORY` | standalone user toggle, no blob dependency |
| 6,7,8 / 9,10,11 / 12,13,14 / 15,16 / 17,18 / 19,20 / 21,22,23 | the hardening tri-states, **each pair whole** |
| **24 `ENABLE_EXPLOIT_PROTECTION_COMPAT_MODE`** | the stated need |


| Deliberately NOT carried | Why |
| --- | --- |
| **26 `PLAY_INTEGRITY_API_USED_AT_LEAST_ONCE`** | derived usage bookkeeping, not a user setting — and under A″ not merely unmasked but **ungranted**, so unreadable |
| 27 `SUPPRESS_PLAY_INTEGRITY_API_NOTIF`, 28 `BLOCK_PLAY_INTEGRITY_API` | genuine user settings, but reaching them means widening the grant past `settingsReadWriteFlags`; deferred |
| 0 `STORAGE_SCOPES_ENABLED`, 5 `CONTACT_SCOPES_ENABLED` | meaningless without their blobs — slices B and C |

⚠ **Carry the masked flag word verbatim; never reconstruct it bit by bit.** Each hardening toggle is a
*pair* — `X` plus `X_NON_DEFAULT` ("the user explicitly set this") — and `AppSwitch.java:150-152` makes
the switch tri-state. A `_NON_DEFAULT` bit **without** its value bit reads as *explicitly disabled by the
user*, i.e. roaming would **turn a protection off that the user never turned off**. Verbatim masked
carriage makes splitting a pair structurally impossible.

⚠ Compat mode does **not** rescue a split pair in general: six `Asw*` classes short-circuit on bit 24, but
`AswRestrictWebViewDynCodeLoading` is **not** among them.

⚠ **The device proves why the mask must be an allowlist.** The only genuine in-the-wild state on lynx was
`net.peakgames.toonblast` carrying `flags-1="67108864"` — exactly `2^26`,
`PLAY_INTEGRITY_API_USED_AT_LEAST_ONCE`. A blanket `flags-1` copy would roam "this app has already used
the Play Integrity API" into every fresh session.

---

## 5. Slice A architecture

**DECIDED 2026-08-21: A″.** Both needed a framework patch (§2.1) either way. A″ was chosen over A′ because it introduces no new executable into the image, no sepolicy surface and no shell parsing, and because it sites capture and apply directly beside `capturePerms` — the mechanism it mirrors. A′ is retained below only so the trade-off is not re-litigated.

### A′ — patch a read *verb*; a uid-2000 privilege-drop helper; capture and apply in roamd

Adds `get-gos-package-state` to the existing shell surface, reachable only through the same
`getFiltered()` gate every other reader passes, so **it grants no new authority to anything**. A small
`cc_binary` (`nowhere_gos`, matching the shipped `nowhere_seed_home` / `nowhere_db_fix` precedent,
labelled `nowhere_exec`) is exec'd by root roamd and drops itself to uid 2000 — unconditionally, so a
userdebug lynx and a release build take the *same* code path, which defuses the
"userdebug cannot prove a user build" trap. Needs no new sepolicy `allow`, only a `file_contexts` line.

### A″ — patch the permission table to grant the chooser, same-user only; capture and apply in chooser Java

`GosPackageStatePermissions.init()` takes an additive `builder().readWriteFlags(…).apply(pkg, computer)`.
Granting **only** the Slice-A flags and **no** cross-user permission is sufficient, because the chooser
runs *inside* the roamed user and `checkCrossUserPermissions` short-circuits when
`targetUserId == callingUserId`. No helper binary, no sepolicy, no shell parsing, and capture/apply sit
directly beside the existing `capturePerms`/`nowhere-perms` mechanism they mirror.
Elegantly, `filterRead` then masks reads to exactly the granted flags — **the grant *is* the allowlist**,
enforced by the framework.

| | A′ | A″ |
| --- | --- | --- |
| New authority granted | **none** | a narrow same-user grant to an app that already holds device-owner, `INSTALL_PACKAGES`, `MANAGE_APP_OPS_MODES` |
| New artifacts | framework patch + `cc_binary` + `file_contexts` + roamd | framework patch + chooser Java |
| Framework↔package coupling | none | the patch names `com.nowhere.chooser`; `Builder.apply` **throws on debuggable builds** if it is absent or non-system |
| Cross-user reach | full (`createFull()`) | none, by construction |

⚠ Note the *cross-user* asymmetry: `ALLOW_CROSS_USER_PROFILE_*` would **not** help a user-0 caller, since
it requires `getProfileParentId(target) == caller` (`GosPackageStatePermission.java:196-204`) and Nowhere's
roamed users are independent secondaries, not work profiles. Only `createFull()` carries
`ALLOW_CROSS_ANY_USER_WRITES`.

### Apply siting (either design)

After the reap (§2.2), at the two sites that already exist for the analogous permission replay:
`grant` arm after `grant_perms_for "$uid"` (`nowhere_roamd.sh:2951`) covers restored-whole, bundled and
archived placeholders; `odrestore` arm (`:3101`) covers tap/auto materialise. `grant_perms_for` ends in a
bare `wait` (`:406`), so inserting after it is race-free.

⚠ **The install-shape gap:** a package installed mid-session by Play, Aurora, nApps or a sideload reaches
neither hook (`backlog.md` #137 and `NWP-20260820-10`) — and the canonical user's bank app comes from
Play. A per-package apply receipt bounds it: an unapplied package's row is **carried forward, not
dropped**, so its state lands at the *next* login instead of being lost. Degraded, not broken — but it
must be stated, not discovered.

⚠ `set()` fans the state to **every** package in a `sharedUserId` (`GosPackageStatePmHooks.java:122-137`),
each with its own `killUid`. Dedupe per sharedUserId at capture — for cost, not correctness.

---

## Kill list

Objections raised and **refuted**, recorded so they are not re-derived.

| # | Objection | Refuted by |
| --- | --- | --- |
| K1 | *Root can do this on a shipping build.* | `GosPackageStatePermissions.java:89-93` — the SHELL grant is unconditional, the ROOT grant is inside `if (Build.isDebuggable())`. |
| K2 | *Shell may lack cross-user write.* | `createFull()` = `new GosPackageStatePermission(-1,-1,-1,-1,-1)` (`GosPackageStatePermission.java:62-64`); `checkCrossUserPermissions` short-circuits at `:192-195`. DEVICE-PROVEN (fact 5). |
| K3 | *SELinux blocks the uid-2000 binder call — the domain follows the process.* | True premise, wrong conclusion: `setuid(2)` does not change a security context; only `execve` with a type_transition does. The child stays `endospore_priv`, where the rules already exist. |
| K4 | *`cmd` from this domain cannot capture stdout (the su:s0 fd doctrine).* | Stale for stdout — `endospore.te:96-99` grants `system_server endospore_priv:fifo_file write` for exactly this. ⚠ **stderr to a FILE remains fatal** (`nowhere_roamd.sh:1170-1176`). |
| K5 | *The #210 SSAID "cached at user creation" trap applies.* | It does not. Reads hit the live `PackageSetting`, and the app-side cache is invalidated synchronously on set. No staged seed, no mint-time hook. |
| K6 | *The binding refusal is "no user state".* | No — per-user state is force-created at user creation (`Settings.java:4936-4937`). DEVICE-PROVEN: `no user state` appears only for a **non-existent user id**. |
| K7 | *Archiving loses the state.* | `DeletePackageHelper.java:628-635` preserves it when `DELETE_KEEP_DATA|DELETE_ARCHIVE`, resets to DEFAULT otherwise. |
| K8 | *sharedUserId members clobber each other.* | Capture emits only non-default rows, so a default member never overwrites a non-default sibling. |
| K9 | *In-session changes are lost on an unclean power-off.* | `syncLoop` runs the same `out` op every 120 s (`main.go:8588`). |
| K10 | *Apply races `grant_perms_for`'s background jobs.* | `nowhere_roamd.sh:406` is a bare `wait`. |
| K11 | *Bit 24 alone is not enough.* | It is a genuine master override — six `Asw*` classes short-circuit on it. ⚠ `AswRestrictWebViewDynCodeLoading` is **not** one of them. |
| K12 | *Numeric `add-flag <n>` will not parse.* | DEVICE-PROVEN (fact 6). Which is also why retired index 25 throws (fact 7). |
| K13 | *Cross-profile inheritance through recycled user ids.* | `Settings.removeUserLPw` removes per-package user state and deletes the file. Residual exposure is disk forensics, not next-user adoption. |
| K14 | *A blind-login timing or observability leak.* | None — a blank login's apply is the same shape as `grant_perms_for`'s existing early return, and a blank login already differs by the entire restore. |

---

## Rebase watch

⚠ This mechanism's door is **upstream GrapheneOS policy**, and an upstream tightening breaks it silently.
On every GrapheneOS rebase, re-check:

1. `GosPackageStatePermissions.init()` — is `grantedPermissions.put(Process.SHELL_UID, full)` still
   unconditional? *(A′ only -- A″, the built design, uses neither the shell's grant nor a shell read verb; kept for the trade-off record, §5.)*
2. `GosPackageStateFlag.java` — new indices, and **newly retired** ones. A retired index inside the carry
   mask is fatal by fact 8. **Enforced** (`NWP-20261014-38`): `gos-chooser-grant.sh` asserts at every apply that
   each set bit of `GosState.MASK` is a live index of this enum and fails the build (exit 2) naming the bit
   otherwise; the build log carries `mask 0x… ⊆ live flag indices (<count> constants)`.
3. `GosPackageStatePmHooks.runShellCommand` — did a read verb appear upstream? If so, A′'s patch shrinks
   to nothing. *(A′ only -- A″, the built design, uses neither the shell's grant nor a shell read verb; kept for the trade-off record, §5.)*

---

## 6. As built (`NWP-20260821-17`)

| File | Role |
| --- | --- |
| `editions/endospore/build/patches/gos-chooser-grant.sh` | the framework patch — one additive `builder()…apply("com.nowhere.chooser", computer)` in `GosPackageStatePermissions.init()`, reusing the upstream `settingsReadWriteFlags` array, **no cross-user permission** |
| `core/chooser/src/com/nowhere/chooser/GosState.java` | capture, apply, the mask, and the receipt. **All reflection** — the chooser is ONE Soong module built from the same sources for both editions, so a direct `GosPackageState` reference would break the Diaspore build outright |
| `ProfileActivity.doLogoff` | `GosState.capture(this)` beside `capturePerms()` |
| `CredentialService` | a `gosstate` start → `GosState.apply(this)`, riding an EXISTING component because a new manifest component does not register over a pinned-fingerprint reflash without a data wipe (the B4 lesson) |
| `ChooserActivity.kickGosState` | fires the apply at switch-landing, **login only** — a resume reuses the same user, whose state was never destroyed |
| `nowhere_roamd.sh` | deletes the receipt at roam-in, beside its four siblings |

### The invariant the whole thing is built around

**A sealed row may only be DROPPED against a positive apply receipt.**

A denied read returns `NONE`, which is byte-identical to "this package has no state". So on an image where
the patch is missing, a naive capture would read nothing for everything, write an empty file, and **destroy
every per-app setting the user had** — silently, permanently, on the first logoff. The receipt is what makes
the distinction the read cannot: it lists packages whose write the framework *confirmed* this session.

- receipt confirms the package → a live read of 0 genuinely means "the user cleared it" → drop the row.
- receipt does not → carry the previous row forward unchanged.
- nothing confirmed at all, and rows exist → **touch nothing**, and log loudly.

An empty sealed set also counts as a live mechanism: there is no state to lose, so a fresh profile can still
capture the first setting the user ever makes. This is the same shape as `capturePerms`' #204 carry-forward
and as the `nowhere-appseen` receipt in `NWP-20260821-15`, deliberately.

The rule — the receipt text, its parse, the live test and the per-package carry/drop branch — is pinned by
`core/chooser/test-gos-carry.sh`, which runs it under javac with six mutants (`NWP-20261017-15`).

### What proves it on hardware

1. `logcat` at login shows `gos apply user=<N>: <n> applied, 0 failed`. Its absence, or
   `gos apply: ALL <n> writes failed`, means the image does not carry the patch.
2. Set *Exploit protection compatibility mode* on an app, log off, log back in, and read the toggle in
   Settings → Apps → that app. It must still be ON.
3. The regression that matters most: an app the user has **never** set a flag on must come back with the
   toggle still OFF, and an app whose flag the user CLEARS must come back OFF — the receipt is what makes the
   clear stick rather than being carried forward forever.
4. On a build **without** the patch, the sealed file must be byte-identical after a logoff. That is the
   destructive case, and it is the one worth testing deliberately rather than assuming.

⚠ Lands in `services.jar` → a full `m`, and a `system` reflash. Not a sepolicy-only or vendor-only change.
