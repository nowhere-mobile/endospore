# Nowhere — staged OTA rollout (#83)

Status: shipped (publish/promote tooling) · 2026-07-23 · closes the "staged rollout" open item in
[ota-channel.md](ota-channel.md). Pairs with the OTA channel + apply path (that doc) and the publish script
`editions/endospore/build/e4-ota-publish.sh`.

## Goal

Don't ship a monthly OS release to the whole fleet at once. Stage it to a small **canary ring** first, watch
it, and **promote to everyone only after it's proven** — with a one-command rollback path if it isn't.

## The mechanic (why this is marker-only, not a second upload)

An OS release is delivered as **content-addressed CDC chunks** under a per-edition payload ref (`os-lynx`),
plus a tiny **version marker** ref that says "the latest published version is X". `nowhere_otad` reads the
marker (cheap), and only if it's newer than the running `/system` stamp does it CDC-restore the payload and
apply it. See [ota-channel.md](ota-channel.md).

Two facts make staged rollout almost free:

1. **The payload is device-wide and content-addressed.** Staging to a canary ring pushes the payload once;
   promoting to the whole fleet re-uploads **nothing** — the bytes are already in the store.
2. **A "ring" is just which version marker a device reads.** So the whole rollout state lives in two small
   marker refs:

   | Ring | Marker ref | Who reads it |
   |---|---|---|
   | `stable` (general) | `ota/<dev>/version` | every device, by default |
   | `beta` (canary) | `ota/<dev>/version-beta` | only devices opted into the `beta` ring |

Staging = write `version-beta`. Promote = copy that value into `version`. Rollback = point `version` back at
the older build (`--force`). None of these move a byte of payload.

> **Superseded (NWP-20261026-15, 2026-10-26): "None of these move a byte of payload" is false for staging.** A
> publish to ANY ring, `--beta` included, replaces `os-<dev>` (`"$AGENT" push s3 "$OSREF" "$OSPASS" "$STAGE"` in
> `e4-ota-publish.sh`), the one payload head every phone of that device restores; only promote is marker-only.
> `nowhere_otad.sh` step 2 (`restore s3 "$OSREF"`, then step 3 `set_res "APPLYING ${ver:-?}"`) restores and applies whatever `os-<dev>` holds and never compares it with `$ver`, the version `ota-check` offered; see the row *The OS payload ref `os-<dev>` is one head for every ring and every release* in `docs/backlog.md` §E.

## The flow

All three steps run on the build host with the native agent (`/tmp/agent_host`) and the store creds — the
same setup `e4-ota-publish.sh` already needs. No device or agent build is involved.

```bash
# 1. Stage the signed release to the canary ring. Pushes the payload (os-lynx) AND marks ota/lynx/version-beta.
#    The general fleet (ota/lynx/version) is untouched -- nobody on stable sees it yet.
#    [SUPERSEDED 2026-10-26, NWP-20261026-15: the stable MARKER is untouched, but the payload is not -- a stable
#    phone behind the stable marker that checks during the soak downloads and installs THIS beta build; the
#    payload restored in nowhere_otad.sh step 2 is never compared with $ver. Row in docs/backlog.md section E.]
editions/endospore/build/e4-ota-publish.sh --device lynx --beta \
    releases/<BN>/release-lynx-<BN>/lynx-ota_update-<BN>.zip 0.5.0 store.conf

# 2. Verify on a canary (see "Canary verification" below). Watch it apply, boot, roam, seal.

# 3. Promote to the whole fleet -- copies the beta marker into the general marker. Marker-only, instant.
editions/endospore/build/e4-ota-promote.sh store.conf --from beta --to stable --device lynx
#    (prompts for confirmation; add --yes for CI. Refuses a no-op/backward promote unless --force.)
```

> **Superseded (NWP-20261026-15, 2026-10-26): step 1's "nobody on stable sees it yet" holds for the marker only.**
> A stable phone behind the stable marker that runs a check during the soak is offered the stable version, restores
> `os-<dev>` (now the beta build) and installs it. `nowhere_otad.sh` step 2 (`restore s3 "$OSREF"`, then step 3 `set_res "APPLYING ${ver:-?}"`) restores and applies whatever `os-<dev>` holds and never compares it with `$ver`, the version `ota-check` offered; see the row *The OS payload ref `os-<dev>` is one head for every ring and every release* in `docs/backlog.md` §E.

After step 3, every `stable` device sees `0.5.0` on its next `ota-check` and updates through the normal,
already-proven `update_engine` A/B path. The `beta` marker still points at `0.5.0`, so canary devices stay
put — promoting advances **only** the target ring.

### Rollback

If a promoted release misbehaves, re-point the general ring at the previous build. Because the older
payload is still content-addressed in the store, devices that haven't rebooted yet simply never see the bad
version; devices already on it get the older marker (an A/B slot already carries the prior slot, and a
`--force` re-mark lets a not-yet-updated device stay/return on the good one):

```bash
# Roll the general ring back to a known-good version staged on a "prev" ring (or re-stage it as beta first).
editions/endospore/build/e4-ota-promote.sh store.conf --device lynx --from prev --to stable --force --yes
```

`--force` is required because it's a **non-forward** marker move (the tooling refuses to silently move a ring
backward otherwise).

> **Superseded (NWP-20261026-15, 2026-10-26): the Rollback paragraph's "the older payload is still content-addressed in
> the store, devices that haven't rebooted yet simply never see the bad version" is false.** The older chunks may still
> be in the bucket, but `os-<dev>` names only the newest manifest, and re-pointing the marker does not re-point it. A
> phone behind the rolled-back marker is offered the older version and installs the NEWER build, the one being rolled
> back. A real rollback today means re-publishing the older release's payload, and `update_engine`'s timestamp
> monotonicity refuses an older build on a phone already past it (`docs/release-runbook.md`, retention note).
> `nowhere_otad.sh` step 2 (`restore s3 "$OSREF"`, then step 3 `set_res "APPLYING ${ver:-?}"`) restores and applies whatever `os-<dev>` holds and never compares it with `$ver`, the version `ota-check` offered; see the row *The OS payload ref `os-<dev>` is one head for every ring and every release* in `docs/backlog.md` §E.

## Canary verification (today, no device build)

The publish step above pushes the real payload and marks the `beta` ref, so a canary is verified by pointing
a dev device's OTA check at that ref. Drive it from the build host over `adb` against the on-device agent:

```bash
# On the canary (dev build with adb). Confirm the beta marker resolves and reports an update:
adb shell "NOWHERE_OTA_VERSION_REF=ota/lynx/version-beta /system/bin/nowhere_agent ota-check s3"
#   -> ota-check: UPDATE -> 0.5.0     (exit 0 = the canary would take it)
```

For a full apply on the canary, restore+stage the `os-lynx` payload and let `update_engine` apply it exactly
as `nowhere_otad` does (`restore s3 os-lynx nowhere-os /data/ota_package` → `update_engine_client --update`),
or — simplest — hand the device the follow-up ring config below so it treats `beta` as its ring and its own
`nowhere_otad` pulls the canary release unattended. Either way the general fleet is unaffected.

> **Superseded (NWP-20261026-15, 2026-10-26): "Either way the general fleet is unaffected" is false.** The publish that
> staged this canary replaced `os-<dev>`, so a stable phone behind the stable marker that checks meanwhile restores and
> installs the canary build; `nowhere_otad.sh` step 2 (`restore s3 "$OSREF"`, then step 3 `set_res "APPLYING ${ver:-?}"`)
> never compares the payload with `$ver`. See the row *The OS payload ref `os-<dev>` is one head for every ring and every
> release* in `docs/backlog.md` §E.

## Device follow-up (batches into the next build) — automatic beta-ring devices

> **Superseded (NWP-20261020-47, 2026-10-20): this follow-up is not built.** Chester retired the device ring (Q002, the entry "twenty-eight recommendations accepted — the beta OTA ring retires ..." in `docs/product-decisions.md`, `NWP-20261020-47`): `OTA_RING` leaves both ring confs, the stale `version-beta` markers are levelled once, and no phone reads a ring marker. Staged rollout is built when there is a production fleet, with the ring in its own conf, not in `beta-setup`. A canary is still possible by hand on lynx with `NOWHERE_OTA_VERSION_REF`.

The tooling above is complete for the **operator** side (stage / promote / roll back). The one remaining
piece, so a canary device pulls its ring's release **on its own** (no per-check env override), is a small
device change that ships with the next `m systemimage`:

- **Ring selection in the agent.** `otaVersionRef()` (`core/agent/main.go`) currently derives
  `ota/<dev>/version`. Have it append `-<ring>` when a ring is configured, resolved (like the DNS/`os-ref`
  pattern) from, in order: `$NOWHERE_OTA_RING`, then a baked `/system/etc/nowhere/ota-ring`, else `stable`.
- **Export it from `nowhere_otad.sh`.** Add `NOWHERE_OTA_RING` (and/or read `OTA_RING=` from `nowhere.conf`)
  to the worker's `export` set, next to `GATEWAY_URL`, so the agent child inherits it. A device is then put
  on the canary ring by a one-line `nowhere.conf` edit (`OTA_RING=beta`, LF endings) — no reflash — and
  reverts to `stable` by removing it.
- **Optional gate affordance.** Surface the ring in gate → Software update ("Beta channel") so a tester can
  opt a device in/out without adb.

Until that lands, a canary is driven with the env override shown above — which is enough to prove a staged
release before promoting it.
