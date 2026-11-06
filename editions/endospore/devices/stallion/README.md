# stallion — Google Pixel 10a

`stallion` is the device-tree **codename** for the Pixel 10a (Google's name; used by GrapheneOS + the build:
`lunch stallion-cur-user`, `vendor/google_devices/stallion`, `os-stallion`, `build-device.sh stallion <BN>`).
This dir is the **device tier** (see AGENTS.md "Repository layout") under the Endospore (GrapheneOS)
edition — only the bits hardcoded to *this* device:

- `vendor/etc/os-ref` — `os-stallion`, the per-device OTA payload ref.
- `vendor/etc/default-home` — the page-2 home seed: `nowhere_roamd.sh` `seed_home()` injects these apps into
  a fresh roamed profile's `launcher.db`, because GrapheneOS Launcher3 imports only the dock from the
  overlay (AGENTS.md "Home parity (E.5d)").
- `vendor/overlay/packages/apps/Launcher3/res/xml/default_workspace_5x5.xml` — the home layout for the 5×5
  grid (empty landing page + 5-app dock).
- `vendor/overlay/packages/apps/Settings/res/drawable-nodpi/endospore_boot_brand.png` — the boot-brand
  image the `FallbackHome` window paints.
- `vendor/overlay/packages/apps/Settings/res/layout/fallback_home_finishing_boot.xml` — strips the
  "Starting Android" scrim and spinner, so the brand stays visible during the boot hold.
- `vendor/overlay/packages/apps/Settings/res/values/themes.xml` — redefines `@style/FallbackHome` as an
  opaque window with the boot-brand background and the wallpaper off.
- `patches/launcher3-grid.sh` — forces the 5×5 grid + icon size (a source patch of the shared Launcher3
  `device_profiles.xml`; it can't be an RRO — see the script header).
- `patches/launcher3-qsb-firstscreen.sh` — flips `QSB_ON_FIRST_SCREEN` to true so the empty landing page
  survives.
- `patches/launcher3-media-progress-ring.sh` — ports the #129 offline-media prefetch progress ring into
  Launcher3.
- `patches/launcher3-media-ring-smooth.sh` — smooths that ring's animation (#128 / #172 issue 4).

`build-device.sh` applies every `patches/*.sh` here to the GrapheneOS tree; `stage-vendor.sh` overlays
`vendor/` onto the staged `vendor/endospore`.

## Provenance / parity with lynx
stallion's device tier was copied from lynx (Pixel 7a) in `e1aec89c` (2026-07-22). The four patches and
`default-home` carry the **same code** as `devices/lynx`'s and are applied unchanged; the Launcher3 and
Settings overlays are the same files too. Only `os-ref` differs. The launcher patches edit the **shared**
GrapheneOS Launcher3 source, so nothing in them is specific to this device's hardware. The line-2 header
comments of `launcher3-grid.sh`, `launcher3-qsb-firstscreen.sh` and `launcher3-media-ring-smooth.sh` still
name the Pixel 7a (lynx), and the grid patch's rationale describes lynx's display options. The header
comment of `default_workspace_5x5.xml` names lynx as well.

⚠ **Not checked on a Pixel 10a:** whether stallion's display makes stock Launcher3 pick the same grid
candidates as lynx's, so that the patch produces a 5×5 home here. Nothing in `worklog.md` or
`docs/backlog.md` records stallion's home as checked; a fresh profile on stallion showing page 2 is still a
NEEDS-DEVICE row in `docs/backlog.md`. If the grid differs on the 10a's display, adjust `launcher3-grid.sh`
here.

What the record does hold for stallion: web install and custom-AVB-key relock proven on 2026-07-19
(`docs/device-onboarding.md`), and stallion images in the fleet releases, most recently 0.5.45 (build
2026101201, `NWP-20261012-01` in `worklog.md`).

A second Pixel adds a sibling `devices/<codename>/`; nothing here belongs at the edition (OS) level.
