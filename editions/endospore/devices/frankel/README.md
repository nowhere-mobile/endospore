# frankel — Google Pixel 10

`frankel` is the device-tree **codename** for the Pixel 10 (Google's name; used by GrapheneOS + the build:
`lunch frankel-cur-user`, `vendor/google_devices/frankel`, `os-frankel`, `generate-release.sh frankel`).
It is on the `laguna` platform, alongside `blazer` and `mustang`. This dir is the **device tier** (see
AGENTS.md "Repository layout") under the Endospore (GrapheneOS) edition — only the bits hardcoded to *this*
device:

- `vendor/etc/os-ref` — `os-frankel`, the per-device OTA payload ref.
- `vendor/etc/default-home` — the page-2 home seed. **Required**: endospore.mk copies it to
  `/system/etc/nowhere/default-home`, so a device without this file fails the build with
  "missing and no known rule to make it" — which is exactly how the first frankel build broke
  (DIA-20260805-04).
- `vendor/overlay/...` — Launcher3 default workspace + the Settings boot-brand overlay.
- `patches/` — the Launcher3 source patches applied to the tree per build.

Identical to stallion's delta apart from `os-ref`; the two devices share a grid and app set.

## Bring-up (what a NEW device needs beyond this dir)

1. `vendor/adevtool/bin/run generate-all -d <device>` — generates `vendor/google_devices/<device>`, without
   which there is no product to lunch. Needs Node 24.
2. ~~`script/generate-keys <device>` then `script/encrypt-keys keys/<device>`.~~ *(superseded 2026-11-05,
   `NWP-20261105-19`: a device's keys are made in the keys home, not in a tree: `editions/endospore/build/gen-keys.sh
   <device>` makes them there on a host that has one, then `script/encrypt-keys` on the keys home's `<device>`;
   `docs/release-runbook.md` §1b)*
3. This directory.
4. A catalog entry + `Available: true` in `nowhere-cloud/internal/installer` (and `DisplayOrder`).
