# Endospore

Endospore is the GrapheneOS edition of Nowhere, for Google Pixel phones. It is in beta.

Nowhere roams your user state, not the operating system. The OS is installed on the phone and is never fetched
from the network at boot. Your data, settings and files are encrypted on the phone, kept in a content-addressed
store, and restored when you sign in.

Nowhere's other edition, Diaspore, runs on LineageOS for the Fairphone 3 and is built from the same `core/`. Its
public repository is [github.com/nowhere-mobile/diaspore](https://github.com/nowhere-mobile/diaspore).

## What it does

- **Power off.** Power off and the device holds nothing readable of yours — ciphertext at most, unrecoverable
  without your passphrase. If you power off without logging off, your session can stay on the phone, as
  ciphertext, until the next boot erases it. Left on, your session stays on the phone, locked: it locks after 15
  minutes idle and is wiped 12 hours after that, by default.
- **Accountless.** No account. We can't tie any stored profile to a name or person.
- **Blind sign-in.** A wrong passphrase looks identical to an empty phone.
- **Roaming.** Sign in and your data, settings, and files re-materialize. Restore needs the network and a
  supported phone, so signing in takes a while; re-downloading apps on another device is not yet available.
- **Client-encrypted.** We cannot read your data — its keys are derived on your device from your passphrase and
  never sent to us. Choose a strong passphrase: a weak one can be guessed offline.
- **Verified boot.** Verified boot under a key you can check; the yellow warning means our key is in control.

Banking and other attestation-gated apps might not work.

[`docs/lock-model.md`](docs/lock-model.md) is the design of how a session is locked when the phone is left
unattended, and of what a power-off leaves.

## What is in this repository

- `core/` — everything both editions share:
  - `core/agent` — the roaming agent, a static Go binary: store I/O, AES-256-GCM, tar and the blind sign-in
    daemon. It also holds the client side of the managed store's billing (the wallet).
  - `core/chooser` — the gate: the sign-in screen the phone boots into, which is the device owner.
  - `core/napps` — nApps, the app store front end; it asks the chooser's `StoreService` to install.
    `core/pushd` — NowherePush, a UnifiedPush distributor.
  - `core/vendor-common` — the shared system side: the `su:s0` data worker and the other `bin/` scripts,
    init `.rc`, sepolicy, default permissions, the Soong `Android.bp`, media, and the default-app manifest.
- `editions/endospore/` — what GrapheneOS and the Pixels add: `endospore.mk`, the build glue and source patches
  in `build/`, the edition's system side in `vendor/` (its sepolicy, the Java helpers `nowhere_roamd.sh` runs, a
  framework overlay, the chooser's icon and the boot and shutdown animations), and one directory per phone under
  `devices/`, named by codename: `frankel` (Pixel 10), `stallion` (Pixel 10a), `tegu` (Pixel 9a), `husky`
  (Pixel 8 Pro) and `lynx` (Pixel 7a).
- `editions/diaspore/build/patches/` — only the seven source patches, written for Diaspore first, that
  `build-device.sh` also applies to the GrapheneOS tree (its `GOS_MANDATED_PATCHES`). The rest of the Diaspore
  edition is not in this repository.
- `docs/` — the specs and designs of the code in this tree.

The managed store's server is not in this repository and is not published.

## Building

Release images come from `editions/endospore/build/build-device.sh <device> <build-number>`, run on a Linux build
host against a GrapheneOS source tree you have synced and prepared as GrapheneOS's own build instructions
describe. `ENDOSPORE_TREE` names that tree and `ENDOSPORE_REPO` this repository; both default to paths on the
maintainers' build host. In order, the script cross-compiles the agent from `core/agent` (it needs Go), stages
`core/` and this edition into the tree's `vendor/endospore` (`build/stage-vendor.sh`), fetches the pinned default
apps from F-Droid (the staged copy of `core/vendor-common/prebuilts/fetch-default-apps.sh`), applies the source
patches (this edition's, and the seven in `editions/diaspore/build/patches/`), wires the product
(`build/inject-product.sh`) and runs `m`. It then checks the built image against `build/patch-markers.tsv`, the
literals the patches leave in it (`build/check-patch-markers.py`), and stops on a missing one. `--release` adds
GrapheneOS's signing step and the web-installer package, with signing keys of your own (`build/gen-keys.sh`). Each
patch script's header says what it changes.

The fetch checks every APK against its pinned SHA-256. The two rows of `default-apps.manifest` marked `manual`,
`AuroraServices` and `WireGuard`, are not on F-Droid at their pins, so they are never fetched, and the fetch exits
non-zero, which stops the script before it applies any patch, when either APK is missing from the tree's
`vendor/endospore/prebuilts/` or differs from its pin. `WireGuard` is committed in this repository
(`core/vendor-common/prebuilts/WireGuard.apk`) and `build/stage-vendor.sh` copies it in. `AuroraServices` is not:
put the AuroraOSS v1.1.1 APK that the manifest's comment above its row names in that directory yourself, as
`AuroraServices.apk`; a re-stage keeps it there.

By default the script stages the `beta-setup` ring (`core/vendor-common/etc/rings/beta-setup.conf`): first-run
setup runs in full, and choosing the managed store there enrols against the beta store. `NOWHERE_RING` names
another ring in that directory.

What is not here yet, plainly: the pinned base manifest (exactly which GrapheneOS source each release is built
on) and a clean-room recipe that builds an image from published inputs alone are not published, and nothing yet
checks that a build from this tree reproduces a release image.

## License

Apache-2.0: see [LICENSE](LICENSE). Third-party code in the tree keeps its own license, for example
`core/agent/third_party/go-fuse`, whose LICENSE sits beside it.

## About this repository

This repository is a per-release snapshot. Nowhere is developed in a private repository, which is the source of
truth; each Endospore release publishes the edition's public source here as one new commit, without the private
history. [CONTRIBUTING.md](CONTRIBUTING.md) says what that means for pull requests and where to report a problem.
