#!/usr/bin/env bash
# verify-release.sh <build-number> [device ...] -- run every §3 check against the SIGNED artifacts.
#
# WHY THIS EXISTS. docs/release-runbook.md §3 is six checks per device, written as prose, and every one of
# them is silent when wrong: a build that offers another device's OTA feed, a baked version already in the
# field (permanently unreachable over the air), a timestamp that makes update_engine refuse the payload as
# not-newer. They were run by hand, which means they were run from memory, which means the day someone is
# tired they are run partially. Two of them have already cost a release each.
#
# ⚠ AND THE FIRST TRAP IS WHICH FILE YOU CHECK. `--release` re-stages and re-runs `m` before signing, so
# THREE target_files.zip exist and only one ships:
#   out-<dev>/…/target_files_intermediates/<dev>-target_files.zip   what §1 built
#   releases/<BN>/<dev>-target_files.zip                            what --release rebuilt and fed to signing
#   releases/<BN>/release-<dev>-<BN>/<dev>-target_files.zip         THE SIGNED ARTIFACT -- the only one that matters
# This script reads the third and proves it is the third, by requiring ro.build.tags=release-keys: that is
# the only field distinguishing them by CONTENT rather than by path, and a path is easy to get wrong.
#
# Exit 0 only if every check passes for every device. Prints what it read, so a pass is auditable rather
# than merely green.
set -uo pipefail

BN="${1:?usage: verify-release.sh <build-number> [device ...]}"
shift
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVICES=("$@")
# NWP-20261011-12: default to every Endospore device that has a device dir. A hardcoded list silently skipped
# husky and lynx. A partial release names its devices.
[ ${#DEVICES[@]} -gt 0 ] || mapfile -t DEVICES < <(ls "$HERE/../devices" | LC_ALL=C sort)

REPO_STAMP="$(tr -d '[:space:]' < "$HERE/../../../core/vendor-common/etc/nowhere-ota-version" 2>/dev/null)"
TREE="${TREE:-/mnt/build/graphene/grapheneos-2026110200}"

# ro.build.date.utc must be epoch(the BN's DATE) + NN. That is what makes update_engine's post-timestamp
# monotonicity check pass; when it derived from a warm out dir instead, EVERY Endospore device failed to OTA
# to EVERY Endospore build as a deterministic ERR-APPLY.
BN_DATE="${BN:0:8}"
BN_NN="${BN:8:2}"
WANT_UTC=$(( $(date -u -d "${BN_DATE:0:4}-${BN_DATE:4:2}-${BN_DATE:6:2}" +%s) + 10#$BN_NN ))

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '    ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '    FAIL  %s\n' "$1"; }

prop() { # prop <target_files.zip> <key>
  unzip -p "$1" SYSTEM/build.prop 2>/dev/null | sed -n "s/^$2=//p" | head -1 | tr -d '[:space:]'
}

echo "verify-release BN=$BN  repo marker=$REPO_STAMP  want ro.build.date.utc=$WANT_UTC"
for DEV in "${DEVICES[@]}"; do
  echo "== $DEV =="
  REL="$TREE/releases/$BN/release-$DEV-$BN"
  TF="$REL/$DEV-target_files.zip"
  if [ ! -f "$TF" ]; then
    no "$DEV: no SIGNED target_files at $TF -- signing has not run, or ran elsewhere"
    continue
  fi

  # 1. THE artifact, not one of its two lookalikes.
  tags=$(prop "$TF" ro.build.tags)
  [ "$tags" = "release-keys" ] && ok "signed artifact (ro.build.tags=release-keys)" \
    || no "ro.build.tags=$tags, want release-keys -- this is an UNSIGNED lookalike, not what ships"
  # 1b. NWP-20261011-12: release-keys are applied to a userdebug tree just as readily; the type is the only tell.
  btype=$(prop "$TF" ro.system.build.type); [ -n "$btype" ] || btype=$(prop "$TF" ro.build.type)
  [ "$btype" = "user" ] && ok "build type = user" \
    || no "build type is '$btype', want user -- a debug image (adb root, su, sqlite3) must not ship as a release"

  # 2. The baked OTA marker: what the device will believe it is running.
  stamp=$(unzip -p "$TF" SYSTEM/etc/nowhere-ota-version 2>/dev/null | tr -d '[:space:]')
  [ -n "$stamp" ] && ok "baked marker = $stamp" || no "no SYSTEM/etc/nowhere-ota-version in the artifact"
  [ "$stamp" = "$REPO_STAMP" ] && ok "marker matches the repo ($REPO_STAMP)" \
    || no "baked $stamp but the repo says $REPO_STAMP -- the tree moved since this build, or this artifact was not built from this tree; e4-ota-publish.sh only notes this (the image is authoritative), so confirm this is the image you mean to ship"
  # 2b. NWP-20261006-12: its notes -- what the gate shows as "what's in this version". A release must carry them,
  # byte for byte the repo's file for its stamp; e4-ota-publish.sh refuses otherwise, so fail here first.
  notes_src="$HERE/../../../core/vendor-common/etc/ota-notes/$stamp"
  if [ ! -f "$notes_src" ]; then
    no "no OTA notes in the repo for $stamp (core/vendor-common/etc/ota-notes/$stamp) -- draft and commit them, then rebuild"
  elif unzip -p "$TF" SYSTEM/etc/nowhere-ota-notes 2>/dev/null | cmp -s - "$notes_src"; then
    ok "baked OTA notes match core/vendor-common/etc/ota-notes/$stamp"
  else
    no "SYSTEM/etc/nowhere-ota-notes is missing or differs from the repo's notes for $stamp -- rebuild"
  fi

  # 3. The build number, in the image rather than in the filename.
  inc=$(prop "$TF" ro.build.version.incremental)
  [ "$inc" = "$BN" ] && ok "ro.build.version.incremental = $BN" \
    || no "incremental=$inc, want $BN -- a warm out dir pinned the build number"

  # 4. The OTA timestamp monotonicity input.
  utc=$(prop "$TF" ro.build.date.utc)
  [ "$utc" = "$WANT_UTC" ] && ok "ro.build.date.utc = $utc (epoch($BN_DATE)+$BN_NN)" \
    || no "ro.build.date.utc=$utc, want $WANT_UTC -- update_engine will refuse the payload as not-newer"

  # 5. The OTA feed this image will ask. Wrong here = it offers ANOTHER DEVICE's updates, silently.
  # ⚠ SYSTEM/etc/nowhere/os-ref -- INSIDE nowhere/. The sibling marker is SYSTEM/etc/nowhere-ota-version,
  # NOT inside it. Two files, opposite locations, and getting os-ref wrong reads as an EMPTY value, which
  # looks like a broken build rather than a broken check. (Done exactly that, 2026-09-05.)
  osref=$(unzip -p "$TF" SYSTEM/etc/nowhere/os-ref 2>/dev/null | tr -d '[:space:]')
  [ "$osref" = "os-$DEV" ] && ok "os-ref = os-$DEV" \
    || no "os-ref=$osref, want os-$DEV -- this image would follow another device's OTA feed"

  # 6. NWP-20260905-03: the OTA wakelock rules are IN the policy this image ships.
  # This check exists because that fix shipped INERT once: it was written against the wrong domain, it logged
  # its own refusal into ota.log on every run, and nothing read it for two days. A sepolicy grant is exactly
  # the kind of change that is silent when absent -- no build break, no missing symbol -- so the release gate
  # is the right place to insist on it. Read from the SIGNED artifact, not the tree.
  cil=$(unzip -p "$TF" SYSTEM_EXT/etc/selinux/system_ext_sepolicy.cil 2>/dev/null)
  wl=$(printf '%s' "$cil" | grep -c 'endospore_priv sysfs_wake_lock')
  bs=$(printf '%s' "$cil" | grep -c 'endospore_priv self (capability2 (block_suspend))')
  ss=$(printf '%s' "$cil" | grep -c 'endospore_priv sysfs_suspend_stats')
  if [ "$wl" -ge 1 ] && [ "$bs" -ge 1 ] && [ "$ss" -ge 1 ]; then
    ok "policy carries the OTA wakelock grant (wake_lock $wl, block_suspend $bs, suspend_stats $ss)"
  else
    no "policy is MISSING the OTA wakelock grant (wake_lock=$wl block_suspend=$bs suspend_stats=$ss) -- the apply will stall with the screen off and ota.log will say '/sys/power/wake_lock refused' (NWP-20260905-03)"
  fi
  # The control: a rule we know is present, so a zero above means the policy, not a broken grep.
  if [ "$(printf '%s' "$cil" | grep -c 'endospore_priv sysfs_typec')" -ge 1 ]; then
    ok "control: the policy grep works (sysfs_typec found)"
  else
    no "control FAILED -- could not read the policy out of the artifact, so the check above proves nothing"
  fi

  # 7. The shipping set exists. The web installer takes the WEBFACTORY zip, not the factory one.
  for f in "$DEV-factory-$BN.zip" "$DEV-webfactory-$BN.zip" "$DEV-ota_update-$BN.zip" "$DEV-manifest-$BN.json"; do
    [ -s "$REL/$f" ] && ok "$f ($(du -h "$REL/$f" | cut -f1))" || no "missing or empty: $f"
  done

  # 8. NWP-20261104-08 (Q094 (c)): which commit this image was built from, read out of the signed artifact.
  # stage-vendor.sh writes it when it stages; endospore.mk bakes it to /system/etc/nowhere/source-commit. Only a
  # clean 40-hex commit passes: `+modified` (a tracked file differed from HEAD), `unknown` (no git checkout), empty
  # and an abbreviation each fail with their own line. NOWHERE_VERIFIED_COMMIT, when set, is the FULL commit the
  # operator verified and must equal it byte for byte.
  src=$(unzip -p "$TF" SYSTEM/etc/nowhere/source-commit 2>/dev/null); src_rc=$?
  if [ "$src_rc" -ne 0 ]; then
    no "no SYSTEM/etc/nowhere/source-commit in the artifact -- the tree was staged before NWP-20261104-08; re-stage and rebuild"
  elif [ -z "$src" ]; then
    no "SYSTEM/etc/nowhere/source-commit is empty -- the stage wrote no commit; re-stage and rebuild"
  elif [[ "$src" =~ ^[0-9a-f]{40}$ ]]; then
    ok "source commit = $src"
    if [ -n "${NOWHERE_VERIFIED_COMMIT:-}" ]; then
      [ "$src" = "$NOWHERE_VERIFIED_COMMIT" ] && ok "source commit = NOWHERE_VERIFIED_COMMIT" \
        || no "source commit $src != NOWHERE_VERIFIED_COMMIT $NOWHERE_VERIFIED_COMMIT -- this image was not built from the commit you verified"
    else
      printf '    note  %s\n' "NOWHERE_VERIFIED_COMMIT unset -- the source commit above was not compared with the commit you verified"
    fi
  elif [ "$src" = "unknown" ]; then
    no "source commit is 'unknown' -- staged from a tree that is not a git checkout; stage from the verified checkout"
  elif [[ "$src" == *+modified ]]; then
    no "source commit $src -- staged from a tree with modified tracked files, not a commit; stage from a clean checkout"
  else
    no "source commit '$src' is not a 40-character lowercase hex commit"
  fi

  # 9. NWP-20261104-26 (h56 #3, NWP-20261103-18): the bundled screen reader keeps GrapheneOS's signature, so the App
  # Store's update of it installs. Until GrapheneOS 2026101600 its module was signed at build and re-signed with our
  # release key, and the store's update was refused as a signature mismatch (frankel 0.5.51). A tree move back to a
  # module like that would ship the same refusal with no build break, so the signing table is checked here.
  certs=$(unzip -p "$TF" META/apkcerts.txt 2>/dev/null)
  nc=$(printf '%s\n' "$certs" | grep -c '^name="')
  if [ "$nc" -ge 1 ]; then
    ok "control: META/apkcerts.txt read ($nc entries)"
  else
    no "control FAILED -- no META/apkcerts.txt entries in the artifact, so the screen-reader check below proves nothing"
  fi
  if printf '%s\n' "$certs" | grep -F 'name="talkback.apk"' | grep -cF 'certificate="PRESIGNED"' >/dev/null; then
    ok "screen reader keeps GrapheneOS's signature (talkback.apk PRESIGNED)"
  else
    no "talkback.apk is not PRESIGNED in META/apkcerts.txt -- our release key re-signs the screen reader and the App Store's update of it will be refused (h56 #3)"
  fi
done

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
