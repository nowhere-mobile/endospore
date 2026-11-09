#!/usr/bin/env bash
# build-device.sh <device> <build-number> [--release <verified-commit>] -- THE canonical per-device Endospore build.
#
# WHY THIS EXISTS
#
# Every per-device build so far has been an ad-hoc /mnt/build/<device>-build-<date>.sh, written by copying
# the newest one. That works until a copied line goes stale, and then the staleness propagates into every
# later script silently. Two live examples, both of which shipped:
#
#   1. `password=` on script/generate-release.sh. Correct while the signing keys were plaintext. Once the keys
#      gained a passphrase it became a HANG: script/decrypt-keys gates on the variable being DEFINED, so an
#      empty-but-defined password skips its own single prompt, drops to `openssl pkcs8 ... -nocrypt` with no
#      -passin, and openssl then asks per key on /dev/tty DIRECTLY (not stdin -- </dev/null does not help).
#      Detached, that hangs forever at load 0 with an empty log. Cost: 10.5 h on two devices.
#
#   2. BUILD_NUMBER never set for `m`. build/envsetup.sh resolves it as
#          ${BUILD_NUMBER:-$(cat $OUT_DIR/soong/build_number.txt || date -u +%Y%m%d00)}
#      -- reading the OUT_DIR's EXISTING number FIRST. So a warm out dir PINS the build number from the day it
#      was created. Seven consecutive releases (2026080400..2026081000) all shipped images identifying as
#      2026072800, because only a COLD out dir ever picks up today's date. A fielded device's reported build
#      could be any of the seven, which guts the issue reporter -- the only diagnostic on a locked user build.
#
# So: one script in the repo, reviewed, rather than N on the box. Both fixes below are one line each; the
# expensive part was not knowing.
#
# PARALLEL SAFETY: several devices may build CONCURRENTLY (each needs its own OUT_DIR, which this sets). That
# is only safe because os-ref is staged per device and selected by TARGET_PRODUCT (#627) -- it used to be one
# shared path, so the losing build baked another device's OTA channel. The rest of the staged tree is shared
# and identical across devices: of the 6 files in each device's vendor delta only etc/os-ref differs, and the
# per-device Launcher3 patches differ only in a comment. Prep still writes shared paths, so do NOT run two
# copies of this script's PREP at the same time -- use PREP=0 (below) for every device after the first, which
# is exactly what a parallel driver should do: ONE prep, then N concurrent `m`.
set -uo pipefail

DEV="${1:?usage: build-device.sh <device> <build-number> [--release <verified-commit>]}"
BN="${2:?usage: build-device.sh <device> <build-number> [--release <verified-commit>]}"
DO_RELEASE=0; VERIFIED="${4:-}"
[ "${3:-}" = "--release" ] && DO_RELEASE=1
# NWP-20261104-03 (Q094): a release names the commit the operator verified; without it, refuse before anything else.
if [ "$DO_RELEASE" = 1 ] && [ -z "$VERIFIED" ]; then
  echo "usage: build-device.sh <device> <build-number> [--release <verified-commit>]" >&2
  echo "    --release needs the merge commit you verified, read where you did the verifying: your own checkout of main," >&2
  echo "    or the merge commit of the PR you checked -- never from the build host's checkout you are about to sign" >&2
  echo "    (its HEAD is what the guard checks, so a commit read there passes the aborted pull it exists to refuse)" >&2
  exit 2
fi

TREE="${ENDOSPORE_TREE:-/mnt/build/graphene/grapheneos-2026110200}"
REPO="${ENDOSPORE_REPO:-/mnt/build/nowhere-phone}"
# NWP-20261125-02 (h55 #2): no build of a device past its GrapheneOS full-support date (devices/<device>/support-end); a --release also refuses a device with no file. Runs before the ring lookup and any write or prompt.
sh "$REPO/editions/endospore/build/support-end-guard.sh" "$REPO" "$DEV" "$(date -u +%F)" "$( [ "$DO_RELEASE" = 1 ] && echo release || echo dev )" || exit $?
# NWP-20261104-01 (Q006): the ring comes from ring-record.tsv, keyed on device and build kind -- never a guess. The old
# old beta-setup fallback for an unset ring shipped lynx 2026091901/02 with the wrong ring, silently. A NOWHERE_RING that disagrees with
# the record is refused unless NOWHERE_RING_OVERRIDE=1. Runs before anything is written or prompted.
KIND=dev; [ "$DO_RELEASE" = 1 ] && KIND=release
RING=$(sh "$REPO/editions/endospore/build/ring-for-build.sh" "$DEV" "$KIND") || exit $?
RING_HOW=record; [ -n "${NOWHERE_RING:-}" ] && [ "${NOWHERE_RING_OVERRIDE:-}" = 1 ] && RING_HOW=override
JOBS="${JOBS:-}"
LOG="${LOG:-/mnt/build/build-$DEV-$BN.log}"
# `user` is the shipping variant and the right default: it is the ENFORCING one, so a bug that only bites under
# enforcement (most of ours) shows up. lynx is the sole userdebug device -- it keeps adb and debug-only binaries,
# which is why it can host a fix that is dead on every release device (see nowhere_seed_home vs /system/bin/sqlite3).
# ...and that fact lived ONLY in the comment above, which is not a mechanism. Building lynx without
# VARIANT=userdebug silently produced a PRODUCTION image: `adb root` answers "adbd cannot run as root in
# production builds", su and sqlite3 are gone, and lynx stops being able to do the diagnostics it exists for.
# Done for real on 2026-08-15 and it cost a full reflash. The device's own nature decides the default now;
# an explicit VARIANT= still wins, so a deliberate `VARIANT=user bash build-device.sh lynx ...` (to reproduce
# an enforcing-only bug on the debug device) is unchanged.
case "$DEV" in
  lynx) VARIANT="${VARIANT:-userdebug}" ;;
  *)    VARIANT="${VARIANT:-user}" ;;
esac
# NWP-20261011-12: a release IS a user build. lynx defaults to userdebug (above), so `--release` on lynx without
# VARIANT=user would sign and ship the DEBUG tree -- adb root, su, sqlite3 -- and nothing after lunch can tell:
# release-keys are applied to either. Refuse here, before anything is written and before the passphrase prompt.
if [ "$DO_RELEASE" = 1 ] && [ "$VARIANT" != user ]; then
  echo "REFUSING --release: VARIANT=$VARIANT -- a release must be a user build. Sign one with:" >&2
  echo "    VARIANT=user OUT_DIR=out-$DEV-user $0 $DEV $BN --release <verified-commit>" >&2
  exit 1
fi
# NWP-20261104-03: --release signs only the commit the operator verified (Q094)
# 2026090110 and 2026090201 signed an old commit after the build host's pull aborted on a stray file; main moving
# between the build pass and --release signs code nobody verified. HEAD must BE the verified commit and no tracked
# file may be modified -- checked here, so the OTA stamp guard below reads the verified tree, before PREP and the prompt.
if [ "$DO_RELEASE" = 1 ]; then
  sh "$REPO/editions/endospore/build/verified-commit-guard.sh" "$REPO" "$VERIFIED" || exit $?
fi
# NWP-20261124-19 (#23, docs/product-decisions.md 2026-11-02): no release for a device past GrapheneOS's full support.
# A committed editions/endospore/support-ended/<device> marker refuses it here, before the OTA stamp guard, PREP and the
# passphrase prompt; there is no override. A dev build (no --release) of the same device is not a release and stays
# allowed, so the call sits inside --release only.
if [ "$DO_RELEASE" = 1 ]; then
  sh "$REPO/editions/endospore/build/support-guard.sh" "$DEV" || exit $?
fi
# NWP-20261101-06: a release stamp the field already has is UNREACHABLE over the air (the #732 hotfix of 2026-08-18 baked
# 0.5.4, which frankel already ran). ota-field-guard.sh reads every ring's published marker for this device and refuses a
# tree stamp that is not strictly above the highest, here -- before PREP, before anything is written, before the
# passphrase prompt. It needs the store conf and an agent binary; without either the check cannot run, so refuse.
if [ "$DO_RELEASE" = 1 ]; then
  OTA_AGENT="${NOWHERE_AGENT:-/tmp/agent_host}"
  if [ -z "${NOWHERE_OTA_STORE_CONF:-}" ] || [ ! -f "$NOWHERE_OTA_STORE_CONF" ] || [ ! -x "$OTA_AGENT" ]; then
    echo "REFUSING --release: the OTA version check needs NOWHERE_OTA_STORE_CONF (path to the store conf) and an agent" >&2
    echo "    binary (NOWHERE_AGENT, default /tmp/agent_host); one of them is missing. Without them a stamp the field" >&2
    echo "    already has cannot be told from a new one." >&2
    exit 1
  fi
  bash "$REPO/editions/endospore/build/ota-field-guard.sh" "$DEV" \
    "$(tr -d '[:space:]' < "$REPO/core/vendor-common/etc/nowhere-ota-version")" "$NOWHERE_OTA_STORE_CONF" "$OTA_AGENT" || exit $?
fi
# Release builds want target-files (+otatools) to feed generate-release. A DEV FLASH wants the partition images,
# and it must include the ones people forget: sepolicy lives on /system_ext and the default apps on /product, so
# a systemimage-only flash silently leaves BOTH stale.
TARGETS="${TARGETS:-target-files-package otatools-package}"
# PREP=0 skips the SHARED-TREE prep (agent, stage-vendor, default apps, source patches, inject-product) and goes
# straight to `m`. That is what makes the PROVEN parallel pattern expressible: prep writes ONE shared tree so it
# must run exactly once, but `m` is per-device (own OUT_DIR) and several can run at once. Measured 2026-08-10:
# shared prep 4s, then tegu+frankel+stallion CONCURRENTLY in 3h57m wall clock. Re-staging the shared tree while
# another device's `m` is READING it is the hazard this header warns about; PREP=0 removes any reason to.
# The os-ref gate below still runs either way -- it asserts a property of the tree rather than building it, and
# an m-only build wants it MORE (nothing in THIS process staged the file it is about to bake).
PREP="${PREP:-1}"

# ⚠ BEFORE `source build/envsetup.sh` -- that is where the `:-` default resolves. Setting it afterwards is
# too late and you silently inherit the out dir's pinned number.
export BUILD_NUMBER="$BN"
# DIA-20260818-01 (#740): the SAME trap, one line ABOVE the BUILD_NUMBER one, and we fixed only the number.
#   envsetup.sh:1258  export BUILD_DATETIME=${BUILD_DATETIME:-$(cat $OUT_DIR/build_date.txt || date -u +%s)}
#   envsetup.sh:1259  export BUILD_NUMBER=${BUILD_NUMBER:-$(cat $OUT_DIR/soong/build_number.txt || ...)}
# A warm out dir pins build_date.txt from the day it was created, so every Endospore build since 2026-07-28
# stamped ro.build.date.utc=1785232271 -- identical in 2026081608 and 2026081701, verified from both images.
# update_engine enforces post-timestamp monotonicity, so NO Endospore device could OTA to any other Endospore
# build: the payload never looks newer than what is installed. Proven on frankel 2026-08-17, twice, as a
# deterministic ERR-APPLY. It stayed latent because #23's OTA proof predates the pinning.
# Derived from the BN (which is a date + counter) rather than `date` so a rebuild of the SAME build number is
# still byte-reproducible, and a later BN always yields a strictly larger timestamp.
if [ -z "${BUILD_DATETIME:-}" ]; then
  _bd="${BN:0:8}"; _bseq="${BN:8}"
  if _epoch=$(date -u -d "${_bd:0:4}-${_bd:4:2}-${_bd:6:2} 00:00:00" +%s 2>/dev/null); then
    export BUILD_DATETIME=$((_epoch + 10#${_bseq:-0}))
  else
    export BUILD_DATETIME=$(date -u +%s)   # BN not date-shaped -> fall back to now, never to the pinned file
  fi
  unset _bd _bseq _epoch
fi
# Must precede lunch: it is what sets $OUT, which finalize.sh reads. Per-device by default so concurrent
# builds never share one out dir -- but overridable: lynx's warm tree is `out-lynx` (its userdebug dev tree),
# and a lynx RELEASE is built as `VARIANT=user OUT_DIR=out-lynx-user` so it never disturbs that tree
# (Chester, 2026-09-27).
export OUT_DIR="${OUT_DIR:-out-$DEV}"
export PATH="/usr/local/go/bin:$PATH"   # a non-login shell (tmux/ssh/systemd) does not get go from the profile

# NWP-20260901-33: keep scratch OFF the root disk.
#
# The build host has two filesystems and only one of them is big: / is 98 GB and also holds /tmp, while
# /mnt/build is 6.6 TB. The release tooling does all its work through Python's tempfile (releasetools'
# common.MakeTempDir/MakeTempFile call tempfile.mkdtemp()/mkstemp() with NO dir= argument), so it lands
# wherever TMPDIR points -- and unset, that is /tmp, i.e. the 98 GB disk. ONE signing pass unpacks a ~9 GB
# signed_target_files_* there.
#
# ⚠ WHAT THAT COST, 2026-09-01: three devices signed CONCURRENTLY at 2026090109. Three ~9 GB extractions plus
# 23 GB of stale scratch left from week-old builds took / to 9.0 GB free, and stallion -- which started last --
# died with `e2fsdroid: No space left on device while populating file system`. It had already been paid for
# once: 2026090105's frankel pass died the same way at the OTA packaging step.
#
# ⚠ AND THE ERROR DOES NOT SAY "DISK FULL". build_image.py answers the ENOSPC by printing, per partition,
# "The max image size for filesystem files is N bytes ... out of a total partition size of N bytes" -- which
# reads exactly like a partition overflow and is not one. The numbers it prints RULE the overflow OUT (every
# tree fit, 925 MB in a 1034 MB VENDOR), and four partitions failing at once was never four coincidences.
# Anyone who reads only that line will go looking for something to delete from the image. Hence this comment.
#
# Pointing TMPDIR at the big volume also puts scratch on the SAME filesystem as the output it feeds, which it
# was not before. Override to test something else; the guard below still applies.
export TMPDIR="${TMPDIR:-/mnt/build/tmp}"
mkdir -p "$TMPDIR" || { echo "cannot create TMPDIR=$TMPDIR"; exit 1; }

# Refuse a release pass that cannot possibly finish, rather than discovering it ~4 minutes in -- AFTER the
# operator has typed the key passphrase, which is the expensive part and cannot be replayed. 20 GiB is a
# little over twice the ~9 GB one pass was measured to need; a run on the 6.6 TB volume never trips it, and a
# TMPDIR forced back onto the root disk is exactly the mistake worth catching here. Build-only runs are left
# to warn: `m` is restartable and costs nobody a prompt.
# -1 = could not measure. That must NOT block: refusing on a failed measurement would be a new footgun in
# place of the old one, and this df runs against a directory mkdir -p just succeeded on.
TMPFREE_KB=$(df -Pk "$TMPDIR" 2>/dev/null | awk 'NR==2 {print $4}')
case "$TMPFREE_KB" in (*[!0-9]*|"") TMPFREE_GB=-1 ;; (*) TMPFREE_GB=$(( TMPFREE_KB / 1024 / 1024 )) ;; esac

exec > >(tee -a "$LOG") 2>&1        # a build whose output is only on a terminal is a build you cannot review
ts(){ date '+%F %T'; }
fail(){ echo "== [$(ts)] FAILED: $1 =="; exit 1; }

echo "== [$(ts)] $DEV BN=$BN OUT_DIR=$OUT_DIR ring=${RING:-none} ($RING_HOW) release=$DO_RELEASE =="
echo "   tree=$TREE repo=$REPO log=$LOG"
if [ "$TMPFREE_GB" -lt 0 ]; then
  echo "   TMPDIR=$TMPDIR (free space NOT MEASURED -- guard skipped)"
else
  echo "   TMPDIR=$TMPDIR (${TMPFREE_GB} GiB free)"
fi
if [ "$TMPFREE_GB" -ge 0 ] && [ "$TMPFREE_GB" -lt 20 ]; then
  if [ "$DO_RELEASE" = 1 ]; then
    echo "   ⚠ REFUSING: a --release pass needs ~9 GiB of scratch per device and TMPDIR has ${TMPFREE_GB} GiB."
    echo "     This is the 2026090109 failure (stallion, 'e2fsdroid: No space left on device'). Refusing"
    echo "     NOW costs seconds; failing later costs the passphrase prompt you already typed."
    echo "     Either free space on $TMPDIR's filesystem, or point TMPDIR at one with room:"
    echo "       export TMPDIR=/mnt/build/tmp"
    fail "TMPDIR has only ${TMPFREE_GB} GiB free"
  fi
  echo "   ⚠ only ${TMPFREE_GB} GiB free on TMPDIR -- fine for a build, too little to sign with."
fi

cd "$REPO" || fail "cd $REPO"
echo "   repo head: $(git log --oneline -1 2>/dev/null)"

if [ "$PREP" = 1 ]; then
echo "== [$(ts)] agent (arm64) =="
( cd "$REPO/core/agent" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o ../vendor-common/bin/nowhere_agent . ) \
  || fail "agent cross-compile"

echo "== [$(ts)] stage-vendor =="
NOWHERE_RING="$RING" bash "$REPO/editions/endospore/build/stage-vendor.sh" "$REPO" "$TREE/vendor/endospore" "$DEV" \
  || fail "stage-vendor"
else
echo "== [$(ts)] PREP=0: reusing the already-staged shared tree (parallel build) =="
fi
# #627: this device's channel must be staged, and the shared last-writer-wins path must be gone.
[ -f "$TREE/vendor/endospore/etc/os-ref-$DEV" ] || fail "no os-ref-$DEV staged -- the OTA channel would be wrong"
[ -e "$TREE/vendor/endospore/etc/os-ref" ] && fail "shared etc/os-ref present -- the parallel-build race is open"
# NWP-20261104-01: the stage must have baked exactly this build's ring. Outside the PREP block, so PREP=0 checks the shared tree
# too: a device whose record ring differs from the one the tree was staged with stops here (stage once per ring).
sh "$REPO/editions/endospore/build/assert-baked-ring.sh" "$TREE/vendor/endospore/etc" "$RING" "$REPO" \
  || fail "the staged ring conf does not match ring '$RING'"
echo "   os-ref-$DEV = $(cat "$TREE/vendor/endospore/etc/os-ref-$DEV")"

if [ "$PREP" = 1 ]; then
echo "== [$(ts)] default apps =="
( cd "$TREE/vendor/endospore/prebuilts" && JNI_APPS="OrganicMaps" bash fetch-default-apps.sh ) \
  || fail "fetch-default-apps"

echo "== [$(ts)] source patches =="
# The Diaspore-dir patches this script applies to the GrapheneOS tree (not all that tree takes: docs/framework-patches.md)
# live there because they were written there first. They are named EXPLICITLY rather than globbed: that directory
# also holds Trebuchet patches, and Trebuchet is the LineageOS launcher -- GrapheneOS uses Launcher3, so a
# glob would try to patch a launcher this tree does not have.
#
# ⚠ THEY WERE NOT APPLIED AT ALL UNTIL NWP-20260822-08. The loop globbed only the two endospore dirs, so
# every Endospore image ever produced by this script -- the script AGENTS.md calls "THE canonical per-device
# Endospore build" -- was missing #210 and #112 unless a human ran them by hand, which nothing prompted them
# to do. #210 in particular fails SILENTLY AND EXPENSIVELY: roamd stages the seed and logs "seedssaid staged
# 64 chars", the daemon logs "seed-ssaid -> OK", the chooser stays quiet, and SettingsProvider -- unpatched --
# mints a RANDOM userkey anyway, so every app's ANDROID_ID rotates on every login and device-bound logins drop.
# Device-proven absent on lynx 2026082104: SettingsProvider.apk carried 0 occurrences of "nowhere-ssaid-seed"
# while all three producers logged success.
# NWP-20260830-05: keystore-roam.sh (#210 part 2, the Keystore carry) WAS MISSING FROM THIS LIST and from
# every other automated path -- `grep -rn keystore-roam editions/ ci/` matched only the patch itself. It
# has only ever been applied BY HAND, which is precisely the failure this list exists to prevent and which
# the paragraph above describes for #210 part 1: a fresh tree, or any re-sync, silently drops it and the
# build ships an image whose apps sign out on every login, with every producer still logging success.
# Found while bumping its PATCH_VERSION in NWP-20260830-03 -- the revert-and-reapply it demands is exactly
# when a manual step gets forgotten.
# ⚠ Its staleness gate makes it a GOOD citizen here: already-current -> "skipped"; older -> a hard error
# telling the operator to revert keystore2/src/. Since a failed patch now fails the build, an out-of-date
# tree stops the build instead of shipping a half-patched keystore2.
# system-userdir-guard.sh (NWP-20261003-01): AtomicFile/ResilientAtomicFile refuse to re-create a removed user's
# /data/system/users/<n>, UserManagerService discards a leftover at user creation and at boot. Without it a reaped
# profile's settings come back as a cleartext orphan that survives reboots and, from GrapheneOS source (not yet seen
# on a device), is adopted by the next user given that id -- silent, like every patch here, so it is mandated.
# systemui-no-restart-doze.sh (NWP-20260825-03): tree-agnostic and idempotent; removes SystemUI's boot goToSleep. It lands in
# SystemUI.apk (/system_ext, so a dev flash needs system_ext). Mandated by NWP-20261019-03: a re-synced tree silently
# dropped every hand-applied patch before it, and this one's absence logs nothing.
GOS_MANDATED_PATCHES="sepolicy-app-media-manage.sh keyguard-roaming-noocclude.sh ssaid-userkey-seed.sh keystore-roam.sh sms-raw-no-sim-filter.sh system-userdir-guard.sh systemui-no-restart-doze.sh"
PATCH_LIST=""
for n in $GOS_MANDATED_PATCHES; do PATCH_LIST="$PATCH_LIST $REPO/editions/diaspore/build/patches/$n"; done
for p in $PATCH_LIST "$REPO"/editions/endospore/build/patches/*.sh "$REPO/editions/endospore/devices/$DEV/patches"/*.sh; do
  [ -e "$p" ] || fail "patch not found: $p"
  printf "   %-46s " "$(basename "$p")"
  # ⚠ A FAILED PATCH NOW FAILS THE BUILD. It used to print FAILED and carry on -- straight through signing and
  # web-packaging -- so a patch whose anchor drifted after an upstream sync would ship an image silently missing
  # the behaviour, which is the same "reports success, does nothing" shape as the miss above.
  bash "$p" "$TREE" >/tmp/bd-patch.$$ 2>&1 && echo ok || { echo FAILED; tail -5 /tmp/bd-patch.$$; rm -f /tmp/bd-patch.$$; fail "source patch failed: $(basename "$p")"; }
done
rm -f /tmp/bd-patch.$$

echo "== [$(ts)] inject-product =="
bash "$REPO/editions/endospore/build/inject-product.sh" "$TREE" "$DEV" || fail "inject-product"
fi

# PREP_ONLY=1 stops here, before `m`. With PREP=0 this is the other half of the parallel pattern: run
# PREP_ONLY once PER DEVICE first (cheap, idempotent, and it is what gives each device its own
# inject-product wiring under vendor/google_devices/<dev>/), THEN launch the concurrent PREP=0 builds. Without
# it a driver would have to re-implement the prep steps itself, which is the copy-paste drift this whole
# script exists to end.
if [ "${PREP_ONLY:-0}" = 1 ]; then
  echo "== [$(ts)] PREP_ONLY=1: shared tree staged for $DEV, stopping before m =="
  exit 0
fi

cd "$TREE" || fail "cd $TREE"
# Content-only changes otherwise ship stale sepolicy/chooser (diaspore-incremental-build-cache), and a NEW file under a
# directory Soong globs (an overlay, a Java source) is invisible until Soong re-analyses.
# ⚠ NWP-20261004-01: SOONG'S OWN NINJA FILE ON THIS TREE IS soong/build.<product>.ninja (build.lynx.ninja, split into
# build.lynx.<n>.ninja), NOT soong/build.ninja. This line removed only the latter, a file that does not exist here, so
# Soong never re-analysed: out-lynx/soong/build.lynx.ninja was last written 2026-10-02 20:55, and build 2026100402
# shipped WITHOUT the new framework overlay (config_allowAlarmsOnStoppedUsers) while every step reported success.
# The count is printed so a future rename shows up as "removed 0" instead of as a missing feature.
n_ninja=$(ls "$OUT_DIR"/soong/build.ninja "$OUT_DIR"/soong/build.*.ninja 2>/dev/null | wc -l)
rm -f "$OUT_DIR"/soong/build.ninja "$OUT_DIR"/soong/build.*.ninja "$OUT_DIR"/build-*.ninja "$OUT_DIR"/combined-*.ninja
echo "   forcing Soong re-analysis: removed $n_ninja Soong ninja file(s) from $OUT_DIR/soong"

# A CHANGED BUILD NUMBER DOES NOT INVALIDATE build.prop. AOSP bakes the number into the fingerprint by
# reading $OUT_DIR/soong/build_number.txt *inside the rule's command*, so the rule's ninja inputs are byte
# identical from one build number to the next and ninja skips the rule entirely.
#
# Measured on lynx 2026-08-11 with BUILD_NUMBER=2026081002: system, product, system_ext and both _dlkm
# build.props DID regenerate (those partitions had real content changes), but vendor/build.prop kept
# 2026081001 -- and vendor.img was then repacked AROUND that stale prop. ro.vendor.build.fingerprint is what
# the issue reporter and the OTA check read, so the image would have MISREPORTED ITSELF: the same
# seven-release 2026072800 mislabelling, arriving by a second route. The BUILD_NUMBER export near the top
# fixes the INPUT; this fixes the OUTPUT. The post-`m` assert catches it either way, but only after a whole
# build has already run, so purge up front whenever the number actually moves.
# Read the number from THIS DEVICE'S OWN vendor/build.prop, not from $OUT_DIR/soong/build_number.txt.
# build_number.txt is per-OUT_DIR while build.prop is per-DEVICE, and out/ holds BOTH lynx and stallion. So
# after a lynx build at 2026081002 stamps build_number.txt, a stallion build at the SAME number in the SAME
# out dir would compare 2026081002 against 2026081002, skip the purge, and repack stallion's vendor.img
# around ITS still-stale prop -- reintroducing the very bug this block exists to prevent, on the next device.
# Comparing against the artifact the post-`m` assert actually reads makes the check self-consistent.
PREV_BN="$(sed -n 's/^ro\.vendor\.build\.fingerprint=.*\/\([^:]*\):.*/\1/p' \
             "$OUT_DIR/target/product/$DEV/vendor/build.prop" 2>/dev/null | head -1)"
if [ -n "$PREV_BN" ] && [ "$PREV_BN" != "$BN" ]; then
  echo "   $DEV build.prop says $PREV_BN, building $BN: purging generated build.prop so every fingerprint regenerates"
  find "$OUT_DIR/target/product/$DEV" -maxdepth 3 -name build.prop -not -path "*/obj/*" -delete 2>/dev/null || true
elif [ -n "$PREV_BN" ]; then
  # NWP-20261017-37: warn only. A same-number rebuild is legitimate and must stay byte-reproducible, so
  # nothing is purged -- but the fingerprint will be identical to what is already on a flashed device.
  echo "WARNING: $DEV was already built as $BN: an image with this number flashed over existing /data keeps the old fingerprint, so PackageManager will not re-scan system apps (a new chooser component will not register). Wipe data on flash, or build a new number." >&2
fi

echo "== [$(ts)] m $TARGETS =="
source build/envsetup.sh >/dev/null 2>&1 || fail "envsetup"
echo "   BUILD_NUMBER after envsetup = $BUILD_NUMBER (must be $BN)"
[ "$BUILD_NUMBER" = "$BN" ] || fail "BUILD_NUMBER is '$BUILD_NUMBER', not '$BN' -- export it BEFORE envsetup"
lunch "$DEV-cur-$VARIANT" >/dev/null 2>&1 || fail "lunch $DEV-cur-$VARIANT"
echo "   lunch: $(get_build_var TARGET_PRODUCT)/$(get_build_var TARGET_BUILD_VARIANT)"
# #740: surface the timestamp the image will carry, so a re-pinned date is caught in the log rather
# than on a device that refuses the OTA weeks later.
echo "   build datetime: $BUILD_DATETIME ($(date -u -d @"$BUILD_DATETIME" 2>/dev/null))"
# NWP-20260914-07: prune $TREE/releases from Soong's finder BEFORE any `m` in this tree can walk it.
#
# WHY. script/generate-release.sh unzips a 516-file otatools bundle straight into
# $TREE/releases/<BN>/release-<dev>-<BN>/ -- INSIDE the source tree every concurrent build scans -- and only
# guards it THREE STATEMENTS LATER:
#
#     unzip releases/$BUILD_NUMBER/$DEVICE-otatools.zip -d $RELEASE_OUT
#     cd $RELEASE_OUT
#     # make soong ignore Android.bp from unpacked otatools to avoid breaking subsequent builds
#     touch .find-ignore
#
# That bundle carries two Android.bp files whose 47 module names duplicate
# build/make/tools/releasetools/Android.bp. Upstream's comment says "subsequent builds" -- it assumes
# SERIAL. Concurrency makes "subsequent" simultaneous, and the gap between the unzip and the touch is a real
# window: measured 2026-09-13, the finder fires ~7s into every `m` and that window is ~11-18s wide, opening
# ~3 minutes into a --release pass. A second device started ~3 minutes after the first lands its finder
# inside it. (The wrong-passphrase retry that night was 194 seconds -- dead centre.)
#
# IT IS NOT HYPOTHETICAL: out-tegu/.module_paths/files.db, written 7s into that night's tegu pass, contains
# "releases/2026091306/release-frankel-2026091306". tegu's build walked into frankel's release output. It
# was harmless only because frankel's own .find-ignore had existed for 19 minutes by then.
#
# ⚠ THE FIX BELONGS HERE, NOT IN generate-release.sh. That script lives in the GrapheneOS tree, which a
# `repo sync` restores -- editing it would need a row in docs/framework-patches.md and would be silently
# reverted the first time anyone syncs. This file is ours and travels with the repo.
#
# Pruning the PARENT is strictly more than the per-directory markers generate-release.sh already writes, and
# nothing under releases/ is a build input: finalize.sh writes it and generate-release.sh reads it, neither
# through Soong. Cheap, idempotent, and it closes the window for every device at once rather than relying on
# an operator remembering to stagger their signing passes.
mkdir -p "$TREE/releases" && touch "$TREE/releases/.find-ignore" \
  || echo "   ⚠ could not write $TREE/releases/.find-ignore -- concurrent --release passes are UNSAFE"
# shellcheck disable=SC2086 -- TARGETS is a deliberate word-split list of make targets
m ${JOBS:+-j$JOBS} $TARGETS || fail "m"

# Assert what the build ACTUALLY baked, HERE -- before signing. make-web-package.sh checks the same thing, but
# that runs after generate-release, so relying on it alone means finding out ~30 min of signing too late.
# Asserting the exported BUILD_NUMBER is not enough on its own: that is the INPUT. This is the OUTPUT.
# Read from the target-files when we built one, else from the staged product tree (a dev image build).
TFI="$OUT_DIR/target/product/$DEV/obj/PACKAGING/target_files_intermediates/$DEV-target_files.zip"
PRODOUT="$OUT_DIR/target/product/$DEV"
# ':.*' not ':user.*' -- lynx is the userdebug device and would silently extract nothing.
FPRE='s/^ro\.vendor\.build\.fingerprint=.*\/\([^:]*\):.*/\1/p'
echo "   built build_number.txt = $(cat "$OUT_DIR/soong/build_number.txt" 2>/dev/null)"
# READ WHICHEVER ARTIFACT THIS BUILD ACTUALLY PRODUCED -- `-f "$TFI"` alone is not that test.
#
# NWP-20260821-08. The old form preferred the target-files zip whenever one merely EXISTED, with no
# freshness check, so a DEV IMAGE build (TARGETS without target-files-package) compared against a zip left
# behind by an earlier release build and refused a perfectly good image: "image baked build number
# '2026082005', expected '2026082100'". Cost two false refusals on 2026-08-20/21, each looking exactly like
# the real seven-release mislabelling this guard exists to catch -- and a guard that cries wolf is a guard
# people start overriding.
#
# The MIRROR case is the dangerous one and is now caught too: build ONLY target-files, then flash the flat
# *.img, and the zip is fresh while the images are stale -- the guard passed and a stale image got flashed
# (the dev-flash TARGETS trap). Comparing the two artifacts' ages surfaces that instead of hiding it.
# WHICH FLAT PARTITION build.prop DID THIS BUILD ACTUALLY WRITE? The old form hardcoded vendor/build.prop
# as the proxy for "the flat images". But a dev image build writes only the partitions its TARGETS name --
# `TARGETS=systemimage` writes system/build.prop and NOTHING else -- so on such a build that proxy is simply
# ABSENT, the -f test below fell through to the zip, and the guard asserted against whatever release ran
# earlier that day. NWP-20260903-03: that false-refused a good lynx image ("image baked build number
# '2026090202', expected '2026090301'") whose own system/build.prop said 2026090301. Third time this guard
# has cried wolf, and its output was indistinguishable from the real mislabelling it exists to catch.
# Take the NEWEST partition prop that EXISTS: on a full build they are all written in the same run, and on a
# partial build only the built partitions are present -- which is exactly the set worth asserting on.
PROPF=""; PROPPART=""
for _part in vendor system system_ext product; do
  _f="$PRODOUT/$_part/build.prop"
  [ -f "$_f" ] || continue
  if [ -z "$PROPF" ] || [ "$_f" -nt "$PROPF" ]; then PROPF="$_f"; PROPPART="$_part"; fi
done
# ...and read the number from THAT partition rather than from vendor unconditionally. A systemimage build
# has no vendor prop at all, so a vendor-only reader returns EMPTY and the assert fails as
# "image baked build number ''" -- a second false refusal wearing the same clothes as the first.
bn_from_prop(){   # <build.prop> <partition> -- explicit key first, the fingerprint's 5th field as fallback
  local v
  v=$(sed -n "s/^ro\.$2\.build\.version\.incremental=//p" "$1" 2>/dev/null | head -1)
  [ -n "$v" ] || v=$(sed -n "s/^ro\.$2\.build\.fingerprint=.*\/\([^:]*\):.*/\1/p" "$1" 2>/dev/null | head -1)
  printf '%s' "$v"
}
SRC=""
if [ -f "$TFI" ] && [ -n "$PROPF" ]; then
  # Both exist -> the NEWER one is what this build produced; say which, and warn on the dangerous direction.
  if [ "$TFI" -nt "$PROPF" ]; then
    SRC=tfi
    echo "   ⚠ flat images are OLDER than the target-files zip -- if you are DEV-FLASHING *.img they are STALE;"
    echo "     extract IMAGES/ from the zip, or rebuild with the image targets."
  else
    SRC=prodout
    echo "   note: target-files zip predates the built images (a dev image build) -- asserting on the images."
  fi
elif [ -f "$TFI" ]; then
  SRC=tfi
elif [ -n "$PROPF" ]; then
  SRC=prodout
else
  fail "no target-files zip and no partition build.prop under $PRODOUT -- nothing to assert against; unverifiable is not the same as correct, so do not flash or sign this"
fi
if [ "$SRC" = tfi ]; then
  IMG_OSREF=$(unzip -p "$TFI" SYSTEM/etc/nowhere/os-ref 2>/dev/null | tr -d '\n')
  IMG_BN=$(unzip -p "$TFI" VENDOR/build.prop 2>/dev/null | sed -n "$FPRE" | head -1)
else
  IMG_OSREF=$(tr -d '\n' < "$PRODOUT/system/etc/nowhere/os-ref" 2>/dev/null)
  IMG_BN=$(bn_from_prop "$PROPF" "$PROPPART")
fi
if [ "$SRC" = prodout ]; then
  echo "   asserting against: $SRC ($PROPPART/build.prop)"
else
  echo "   asserting against: $SRC"
fi
echo "   image os-ref           = $IMG_OSREF  (want os-$DEV)"
echo "   image build number     = $IMG_BN  (want $BN)"
[ "$IMG_OSREF" = "os-$DEV" ] || fail "image os-ref is '$IMG_OSREF', expected 'os-$DEV' -- wrong OTA channel"
[ "$IMG_BN" = "$BN" ] || fail "image baked build number '$IMG_BN', expected '$BN' -- do not sign this"

# Assert the patches' OUTPUT, on the artifact the build-number assert just read (NWP-20261020-04). The patch loop above
# only proves each script exited 0; an anchor that still matches while the patch's own edit lands nowhere (or a TARGETS
# that skipped the partition) passes it. patch-markers.tsv names a literal each patch leaves in the built image.
# Outside the PREP block, so a PREP=0 run is checked too; before the DO_RELEASE branch, so a dev build shows a table
# error before any release does.
if [ "$SRC" = tfi ]; then
  python3 "$REPO/editions/endospore/build/check-patch-markers.py" --table "$REPO/editions/endospore/build/patch-markers.tsv" --zip "$TFI" \
    || fail "a framework patch's artifact literal is missing -- do not sign this"
else
  python3 "$REPO/editions/endospore/build/check-patch-markers.py" --table "$REPO/editions/endospore/build/patch-markers.tsv" --dir "$PRODOUT" \
    || fail "a framework patch's artifact literal is missing -- do not sign this"
fi

if [ "$DO_RELEASE" -eq 0 ]; then
  echo "== [$(ts)] $DEV BUILD DONE (no --release)."
  if [ "$VARIANT" = user ]; then
    echo "   Sign with (same tree):"
    echo "     OUT_DIR=$OUT_DIR VARIANT=user $0 $DEV $BN --release <verified-commit>        # prompts ONCE for the key passphrase"
  else
    echo "   This $VARIANT build CANNOT be signed as a release -- --release refuses a non-user variant."
    echo "   Build and sign a user tree with:"
    echo "     VARIANT=user OUT_DIR=out-$DEV-user $0 $DEV <next BN> --release <verified-commit>        # prompts ONCE for the key passphrase"
  fi
  exit 0
fi

# NWP-20261105-19: the signing keys live outside every tree ($NOWHERE_KEYS_HOME, default /mnt/build/keys/endospore), and
# GrapheneOS's script/generate-release.sh reads only keys/$DEV inside the tree. keys-home.sh links a tree that has no
# keys/ to that home, uses a tree's own keys/ unless a public half differs from the home's copy, and refuses a link
# elsewhere or a home inside a source tree; the two checks below then read the keys through it. It never creates a key,
# so a missing one stops here, before the prompt.
sh "$REPO/editions/endospore/build/keys-home.sh" "$TREE" "$DEV" || fail "signing keys for $DEV (keys-home.sh)"

# generate-release.sh signs $DEV-install-$BN.zip only behind `if [ -f keys/$DEV/id_ed25519 ]` -- an absent
# key is a SILENT skip and an unsigned CLI-install artifact, found a release later (2026081219: tegu and
# stallion shipped .sig files, frankel didn't, and nothing said so). script/ belongs to the GrapheneOS tree
# and is clobbered by repo sync, so the loud check lives here. A warning rather than a fail: the web
# installer verifies the MANIFEST signature, so the release is shippable without this sig -- but say so
# BEFORE ~30 minutes of signing, and again in the log people actually read.
if [ ! -f "$TREE/keys/$DEV/id_ed25519" ]; then
  echo "== [$(ts)] WARNING: keys/$DEV/id_ed25519 is MISSING =="
  echo "   generate-release will SILENTLY skip signing $DEV-install-$BN.zip (the CLI-install artifact)."
  echo "   Fix: sign it afterwards (below). gen-keys.sh $DEV also works, but ONLY where avb.pem already"
  echo "   exists -- it creates whatever is missing, and that includes a new AVB root key. See below."
  echo "     ssh-keygen -Y sign -n \"factory images\" -f keys/$DEV/id_ed25519 <release-dir>/$DEV-install-$BN.zip"
fi

# NWP-20260913-14: the OTHER per-device key -- and unlike id_ed25519 this one is a HARD abort.
# make-web-package.sh:175 does `[ -f "$AVB_PKMD" ] || exit 1`, and the call below turns that into a failed
# build. But that call runs AFTER generate-release.sh, so a missing avb_pkmd.bin is found ~30 minutes of
# signing too late, with the irreplaceable passphrase already typed. That is precisely the cost the
# id_ed25519 warning above exists to avoid, and the reason it lives here rather than in script/ -- so this
# check belongs here too: before finalize, before the prompt.
if [ ! -f "$TREE/keys/$DEV/avb_pkmd.bin" ]; then
  echo "== [$(ts)] keys/$DEV/avb_pkmd.bin is MISSING =="
  echo "   make-web-package cannot pin avb_key_sha256 and WILL fail this build -- but only after"
  echo "   generate-release has prompted for the passphrase and signed for ~30 min. Failing now instead."
  echo "   Restore it from the off-box key backup for $DEV."
  echo "   DO NOT reach for gen-keys.sh on a device that has already shipped: it creates whatever is"
  echo "   missing, and a missing avb.pem then means MINTING A NEW AVB ROOT KEY (its openssl genrsa), after"
  echo "   which every relocked handset rejects the images (docs/build-box-migration.md, section 6)."
  fail "avb_pkmd.bin missing for $DEV -- refusing to sign a release that cannot be packaged"
fi

# ⚠ `password` is deliberately NOT set. Unset => decrypt-keys prompts ONCE and reuses it for every key via
# -passin env:password. Setting it empty makes openssl prompt per key on /dev/tty and hang when detached.
# So --release MUST be run interactively (use tmux so a dropped connection does not kill it).
echo "== [$(ts)] finalize =="
bash script/finalize.sh || fail "finalize"

echo "== [$(ts)] generate-release -- PROMPTS ONCE FOR THE KEY PASSPHRASE =="
bash script/generate-release.sh "$DEV" "$BN" || fail "generate-release"

R="$TREE/releases/$BN/release-$DEV-$BN"
echo "== [$(ts)] make-web-package =="
# This also fails the build if the image's baked build number disagrees with $BN.
bash "$REPO/editions/endospore/build/make-web-package.sh" "$R" "$DEV" "$BN" || fail "make-web-package"

echo "== [$(ts)] VERIFY =="
TF="$R/$DEV-target_files.zip"; W="$R/$DEV-webfactory-$BN.zip"
echo "   os-ref (signed)   = $(unzip -p "$TF" SYSTEM/etc/nowhere/os-ref 2>/dev/null | tr -d '\n')  (want os-$DEV)"
echo "   build fingerprint = $(unzip -p "$TF" VENDOR/build.prop 2>/dev/null | grep -m1 '^ro.vendor.build.fingerprint=' | cut -d= -f2-)"
# A `user` build has no sqlite3, which is precisely why nowhere_seed_home exists -- assert BOTH halves.
echo "   nowhere_seed_home = $(unzip -l "$TF" SYSTEM/bin/nowhere_seed_home 2>/dev/null | grep -c 'SYSTEM/bin/nowhere_seed_home') (want 1)"
echo "   sqlite3           = $(unzip -l "$TF" SYSTEM/bin/sqlite3 2>/dev/null | grep -c 'SYSTEM/bin/sqlite3') (want 0)"
echo "   webfactory        = $(stat -c %s "$W" 2>/dev/null) bytes"
echo "   sha256            = $(sha256sum "$W" 2>/dev/null | cut -d' ' -f1)"
echo "== [$(ts)] $DEV RELEASE DONE -- $R =="
