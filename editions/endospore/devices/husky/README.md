# husky — Google Pixel 8 Pro

`husky` is the device-tree **codename** for the Pixel 8 Pro (Google's name; used by GrapheneOS + the build:
`lunch husky-cur-userdebug`, `vendor/google_devices/husky`, `os-husky`, `generate-release.sh husky`). This
dir is the **device tier** (see AGENTS.md "Repository layout") under the Endospore (GrapheneOS) edition —
only the bits hardcoded to *this* device:

- `vendor/etc/os-ref` — `os-husky`, the per-device OTA payload ref.
- `vendor/etc/default-home` — the page-2 app list `seed_home()` injects into a fresh profile's `launcher.db`.
- `vendor/overlay/…/default_workspace_5x5.xml` — the home layout (dock-only; page 2 comes from the seed).
- `patches/launcher3-*.sh` — per-device Launcher3 source patches.

## ⚠ This tier was scaffolded by copying `lynx/`, and the copy has NOT been reviewed for this screen

Every file here was byte-identical to the `lynx` (Pixel 7a) tier as of 2026-09-08, including a README that
still described the Pixel 7a. That is fixed; the rest is not, and the display-dependent parts are
**unverified on a Pixel 8 Pro**:

- `patches/launcher3-grid.sh` reasons explicitly about *lynx's* dimensions — "lynx satisfies BOTH the 4x5
  'Pixel 2021' and the 5x5 'Large Phone' display-options … so FORCE the 5x5 grid" — and shrinks the home icon
  56 → 54 for that screen. Whether a Pixel 8 Pro wants the same forcing, or already picks a larger grid on
  its own, has never been checked. The patch is not obviously harmful — it removes a default *candidate*, it
  does not pin a grid — but "not obviously harmful" is not "right for this display".
- `default_workspace_5x5.xml` is dock-only, so it is the least screen-sensitive of the three; it is still a
  5×5 layout inherited from a smaller phone.

**Check the home on the first boot of a fresh profile** — grid columns, dock capacity, icon size, and that
page 2 renders from `default-home`. If the grid is wrong, that patch is where to look first, and the fix
belongs here rather than at the edition level.

## Why the device exists

`husky` was brought up as a **second adb-visible handset** (2026-09-08). `lynx` was the only userdebug
device, and diagnosing anything spanning two handsets — the `#media` two-writer convergence, the
mid-session sync — with one side visible produced a run of wrong calls that day. So build it `userdebug`
deliberately:

```
VARIANT=userdebug bash editions/endospore/build/build-device.sh husky <build-number>
```

⚠ It defaults to `user` like every device except lynx, so the variable is not optional.

⚠ **SUPERSEDED 2026-10-30** (`docs/product-decisions.md`, *"every release is proved on a canary first ..."*, `NWP-20261030-11`): husky is now the release canary on a **user** build. The userdebug second-handset role above is history; build it `VARIANT=user` with its own `OUT_DIR=out-husky-user` so the userdebug `out-husky` tree is not overwritten.

⚠ And `device/google/shusky` is **not** in the checkout — only `shusky-kernels` plus the adevtool-generated
`vendor/google_devices/husky`, which is complete and is what the build actually consumes. An older note
recorded husky as blocked on a missing device tree; it is not, and the first cold build ran from a clean
`PREP_ONLY` with inject-product reporting everything already wired.
