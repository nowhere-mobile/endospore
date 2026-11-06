# lynx — Google Pixel 7a

`lynx` is the device-tree **codename** for the Pixel 7a (Google's name; used by GrapheneOS + the build:
`lunch lynx-cur-user`, `vendor/google_devices/lynx`, `os-lynx`, `generate-release.sh lynx`). This dir is
the **device tier** (see AGENTS.md "Repository layout") under the Endospore (GrapheneOS) edition — only the
bits hardcoded to *this* device:

- `vendor/etc/os-ref` — `os-lynx`, the per-device OTA payload ref.
- `vendor/etc/default-home` — the page-2 home seed: `nowhere_roamd.sh` `seed_home()` injects these apps into
  a fresh roamed profile's `launcher.db`, because GrapheneOS Launcher3 imports only the dock from the
  overlay (AGENTS.md "Home parity (E.5d)").
- `vendor/overlay/.../default_workspace_5x5.xml` — the home layout for lynx's 5×5 grid (dock-only).
- `vendor/overlay/packages/apps/Settings/res/drawable-nodpi/endospore_boot_brand.png` — the boot-brand
  image the `FallbackHome` window paints.
- `vendor/overlay/packages/apps/Settings/res/layout/fallback_home_finishing_boot.xml` — strips the
  "Starting Android" scrim and spinner, so the brand stays visible during the boot hold.
- `vendor/overlay/packages/apps/Settings/res/values/themes.xml` — redefines `@style/FallbackHome` as an
  opaque window with the boot-brand background and the wallpaper off.
- `patches/launcher3-grid.sh` — forces the 5×5 grid + icon size for lynx's screen.
- `patches/launcher3-qsb-firstscreen.sh` — flips `QSB_ON_FIRST_SCREEN` to true so the empty landing page
  survives.
- `patches/launcher3-media-progress-ring.sh` — ports the #129 offline-media prefetch progress ring into
  Launcher3.
- `patches/launcher3-media-ring-smooth.sh` — smooths that ring's animation (#128 / #172 issue 4).

A second Pixel adds a sibling `devices/<codename>/`; nothing here belongs at the edition (OS) level.
