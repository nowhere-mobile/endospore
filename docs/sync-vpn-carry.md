# Account sync and always-on VPN carry (NWP-20261010-15)

Two per-user settings now follow a profile across a sign-out, as decided on 2026-10-10 (`docs/product-decisions.md`):

- **Account sync.** This is master auto-sync plus every per-account, per-authority switch.
- **The always-on VPN.** This is the always-on app plus its "Block connections without VPN" choice.

Neither setting can simply be carried, because every sign-in mints a new Android user.

- **Sync** lives in the device-global `/data/system/sync/accounts.xml`, which no Nowhere scope carries.
- **VPN** lives in Secure settings, which a fresh user starts without.

So both work the same way. The **capture** runs at each seal, and the **apply** runs at the next sign-in. The record is a roamd-owned sibling file in the chooser's CE dir, so it seals into the vault and nothing else reads it.

The code is in `core/vendor-common/bin/nowhere_roamd.sh` (`vpn_*`, `sync_*`) and in the Endospore helpers under `editions/endospore/vendor/helpers` (`np.SyncRoam`, `np.VpnAlwaysOn`). The tests are `test-sync-vpn-roam.sh` and `test-roam-helpers-java.sh`. Diaspore ships no helper, so on Diaspore neither setting is carried. `roam.log` says so for sync at every sign-in, and for the VPN at every sign-in where there is a VPN to apply (`OK NOHELPER`); the Profile screen's picker says so instead of offering a pick.

## The records

| File (chooser CE dir) | Written by | Shape |
| --- | --- | --- |
| `nowhere-vpn` | `vpn_seal_capture` | `app=<pkg>` and `lockdown=<0\|1>`. A block that is pending until the tunnel's first connection counts as 1. |
| `nowhere-vpn-pick` | the Profile screen's VPN picker | Same shape. It is a one-shot request for the next sign-in, and it outranks the capture. |
| `nowhere-sync` | `np.SyncRoam capture` | `nowhere-sync 1`, then `master <0\|1>`, then one `sync <0\|1> <type> <authority> <account name>` line per switch (sorted, percent-escaped), then `end <n>`. |
| `nowhere-sync-pending` | the apply and the capture | `pend 1 <type> <authority> <account name>` lines, one per carried 1 that cannot be set yet. It lasts for one session only. |
| `nowhere-sync-retry` | a sign-in apply that failed | `fix <carried> <live after the failure> <type> <authority> <account name>` lines, plus `fixmaster <carried> <live>` if master failed: what the retry may still write. It holds account names, lives in the CE dir, and is sealed like the rest, but is dropped at the next sign-in, so it lasts for one session only. |

⚠ `nowhere-sync`, the pend lines and `nowhere-sync-retry` hold account names. They never go through a shell variable, never into `roam.log`, and never into `$STATE`. Every log line is counts, a uid, a package name, or a helper answer that has passed a shape check (`sync_answer`).

## The helper runs as the system uid

On GrapheneOS, `ContentService.get/setSyncAutomaticallyAsUser` silently refuse a caller whose uid has no package. Root has none, so as root every per-account switch reads 0 and every write is dropped. `np.SyncRoam` is started as root, then:

1. It drops to the system uid (1000), calling `setgid` before `setuid`.
2. It checks that the drop happened.
3. It relaunches itself as a fresh app_process. The binder driver keeps the credentials of whoever opened `/dev/binder`, and the first app_process opened it as root before `main()` ran.

The child is waited for with a 12 s bound. That is strictly inside roamd's own 20 s `timeout`, so roamd never kills the parent and orphans the child.

## Pend lines: switches that cannot be set yet

A switch cannot be set this session when its account is not visible (the authenticator app is absent) or when no sync-adapter package serves its authority (an on-demand app that hasn't been tapped).

- **Only a 1 is ever pending.** A carried 0 is dropped at the apply. A new authority row starts disabled, so any 1 found there later is the user's own newer choice. The clearest case is opening an on-demand Gmail and tapping "Turn on", and a pending 0 would overwrite that.
- **A pend 1 is landed by the capture.** This happens the first time the capture finds the switch placeable, and only while the live value is still 0. If the live value is already 1, nothing is written. Once landed, the capture records what the framework reads back.
- **A pend 1 whose write does not stick** stays pending and is recorded as the carried 1. The capture counts it on a `stat landed=N unstuck=M` line, and roamd logs that line.

**Trade-offs, accepted:**
- An app that is absent at sign-in and turns its own sync on at first run beats a carried explicit 0.
- A carried 1 lands over a user who turned the switch on and back off between the app's install and the next capture.

Nothing on the device tells an app's own write apart from the user's.

## The gates

| Gate | What it does |
| --- | --- |
| **Apply marker** `$STATE/.syncapplied.<uid>` / `.vpnapplied.<uid>` | No capture runs until this session's apply has landed. Otherwise the fresh user's empty state would overwrite the record. The `in` op clears it. |
| **Apply retry** `$STATE/.syncretry.<uid>` | A sign-in sync apply that failed (a read-back mismatch, a timeout) is retried at the next seals, 5 times in all, then given up with one log line. The record is kept either way. The retry touches only what did not land: the failed apply hands those switches back (`fix` lines, kept in `nowhere-sync-retry`, plus master only if master itself failed), each with its live value read just after the failure. The retry writes a switch's carried value, 0 or 1, only while it still reads that value, which is taken to mean nobody has changed it since. If it reads anything else, the user or the app changed it, and their value stands. If the switch cannot be read during the retry, it is handed back unchanged and the retry does not count as done. ⚠ Residual (ABA): a switch changed and changed back within one seal interval reads as untouched, so the retry overwrites the user's final value, the same limit as the VPN row's set-then-clear. The **conservative rule** applies wherever there is no value-at-failure to compare against: it writes a 1 only over a live 0, never writes a 0, and never touches master. That covers a single switch whose value right after the failure could not be read, and the whole record when the failed apply handed nothing usable back. "Nothing usable" means it timed out, crashed, answered `ERR <Exception>`, or left a malformed hand-back, which roamd drops. ⚠ Residual: there, a user who turned a carried-1 switch off before the retry sees it turned back on. The next capture then records that 1, so their off is lost from the record too, until they turn it off again. On the sandboxed-Play path, where the account reload waits for gms to be tapped, the sync apply runs in odrestore right after that reload: correctness over latency, because applying it a seal later would overwrite a switch the user turned on in the meantime, or one belonging to an account the same reload placed. The cost sits on the materialise the user is waiting on: one helper run, typically 1-2 s, bounded at the 20 s helper timeout. That apply waits only for gms's account authenticator (`wait_acct_authenticator`), not for its sync adapters, which register a little later. So a carried 0 for a gms authority can be beaten by gms switching that authority on at its first run, which widens the trade-off in "Pend lines" above. ⚠ Trade-off: that apply also sets master auto-sync, overwriting a master toggle made earlier in the session, before the tap. That is accepted, because before the tap no account is placed and the master switch has nothing to sync, and telling a toggle from the untouched default would need the platform's build-config default. ⚠ If gms stays held for the whole session, no sync apply and so no sync capture runs: that session's changes to master sync and any account added in it are not carried, and the previous record stands. |
| **Deferred VPN** `$STATE/.vpndeferred.<uid>` / `.vpnretry.<uid>` | If the VPN app is on-demand and not yet opened, vpnup answers `OK DEFERRED` and keeps the choice it made (package, block, source). Each seal retries that exact choice, never a pick made since; a pick made this session stays for the next sign-in. If the user has set a different always-on VPN in Settings meanwhile, the user's choice wins: the deferral is dropped (with the pick it came from, if any) and the seal captures it. ⚠ Residual: a VPN the user sets and then clears again within one seal interval reads as "nothing set", exactly like untouched, so the carry is applied. A seal where the app is still held costs no JVM. Once the app has materialised, the retry runs 5 times in all, then gives up. It is not run from odrestore, which the user is waiting on. The `bootwake` op's per-package step, which runs after the app's restore, also runs this retry for that package (`NWP-20261130-04`), so the Auto sweep's held seals do not hold the VPN back. |
| **Fingerprint** `$STATE/.syncfp.<uid>` | A capture runs only if one of these changed: `accounts.xml`, the user's `accounts_ce.db` (and its `-wal`), or the user's two RegisteredServicesCache files (`users/<uid>/registered_services/android.content.SyncAdapter.xml` and `android.accounts.AccountAuthenticator.xml`, which are rewritten only when the adapter or authenticator set changes). `packages.list` is deliberately left out, because PackageManager rewrites it on every settings write. The fingerprint is stored only after a capture that worked. It is mtime and size of each file; one that exists but cannot be stat'ed fails closed (no fingerprint, so the capture runs). |
| **Backoff** `$STATE/.syncbo.<uid>` | While switches are pending and nothing has changed, the capture still retries after 1, 2, 4 … 32 seals, as a backstop. Each retry is logged. |

`$STATE` is `/data/nowhere/state`, a RAM tmpfs (`core/vendor-common/etc/nowhere.rc`), so these markers, including the deferred VPN package name, are gone at power-off.

## The VPN choice

`vpn_choice` picks the first well-formed source from this list:

1. The pick.
2. The capture.
3. The pre-slice `vpn=`/`vpnlockdown=` pref, with the block defaulting to on.

A carried ON is applied through the VPN app's consent (`np.VpnAlwaysOn … defer`). On Endospore, `vpn-lockdown-on-first-connect.sh` then arms the block at the tunnel's first connection, so a fresh session is never cut off before its tunnel is up. A carried OFF is an explicit `setAlwaysOnVpnPackage` with lockdown 0, which clears any deferred block. Every apply is read back from the settings before vpnup answers OK.
