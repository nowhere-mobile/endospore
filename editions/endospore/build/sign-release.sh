#!/usr/bin/env bash
# sign-release.sh <BN> <verified-commit> <dev>[:<out-dir>]... -- sign every device of one release in ONE sitting (NWP-20261122-01).
#
# WHY. build-device.sh --release prompts once per device, only after that device's own `m`. So N devices cost N attended
# prompts spread over hours, and a wrong passphrase shows only after the first device's ~17 minutes of signing. Nothing
# checked for other processes of the signing user, which can read /dev/shm/release_keys.* and a child's environment
# mid-sitting. Decided 2026-10-30 ("every release is proved on a canary first ...", "thinking about all 17") and
# 2026-11-01 (h52 #4, "twenty-two answers to harvests 50, 51 and 52 ..."), docs/product-decisions.md.
#
# HOW. Build each device unattended first (`VARIANT=user OUT_DIR=<out> build-device.sh <dev> <BN>`). This script never
# runs `m`. It then, in this order:
#   1. preflights EVERY device before any prompt: the verified commit; per device the target-files' build number, user
#      build, os-ref, source commit, patch markers and release ring; the keys; GrapheneOS full support (support-guard.sh);
#      the OTA stamp; TMPDIR's free space; stale key dirs of this user in /dev/shm; decrypt-keys' password gate. Each
#      refusal names the device; nothing is signed;
#   2. refuses while another process of the signing user runs (sitting-guard.sh), and names each one;
#   3. reads the passphrase ONCE (`read -rs`, never echoed, never exported, an empty one refused);
#   4. proves it on every device's keys before signing anything;
#   5. signs each device in turn in a background child that alone receives the passphrase, and sweeps this user's key
#      dirs after each device and on EXIT, INT, TERM and HUP;
#   6. writes one bundle releases/<BN>/manifests-<BN>.tar for the local manifest-signing loop (docs/release-runbook.md §4).
#
# Run it INTERACTIVELY in tmux. Defaults as build-device.sh: ENDOSPORE_TREE, ENDOSPORE_REPO; an out dir defaults to
# out-<dev> and a relative one is relative to the tree. Knobs: TMPDIR (default /mnt/build/tmp), SIGN_MIN_TMP_GIB (20),
# SIGN_SHM_DIR (/dev/shm), NOWHERE_OTA_STORE_CONF and NOWHERE_AGENT (as build-device.sh --release).
#   exit 0  every device signed      exit 1  a refusal, or a device failed      exit 2  usage
# Pinned by test-sign-release.sh (--mutate).
set -uo pipefail

usage() {
  echo "usage: sign-release.sh <BN> <verified-commit> <dev>[:<out-dir>]..." >&2
  [ -z "${1:-}" ] || echo "    $1" >&2
  exit 2
}
[ "$#" -ge 3 ] || usage "name the build number, the verified commit and at least one device"
BN="$1"; VERIFIED="$2"; shift 2
case "$BN" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) usage "build number '$BN' is not 10 digits" ;; esac
DEVS=(); OUTS=()
for a in "$@"; do
  d="${a%%:*}"; o="out-$d"
  case "$a" in *:*) o="${a#*:}"; [ -n "$o" ] || usage "device '$d' names an empty out dir" ;; esac
  case "$d" in '' | *[!a-z0-9]*) usage "bad device '$d' -- use lowercase alphanumerics" ;; esac
  for e in "${DEVS[@]}"; do [ "$e" = "$d" ] && usage "device '$d' is named twice"; done
  DEVS+=("$d"); OUTS+=("$o")
done

TREE="${ENDOSPORE_TREE:-/mnt/build/graphene/grapheneos-2026110100}"
REPO="${ENDOSPORE_REPO:-/mnt/build/nowhere-phone}"
B="$REPO/editions/endospore/build"
SHM="${SIGN_SHM_DIR:-/dev/shm}"
MIN_GIB="${SIGN_MIN_TMP_GIB:-20}"
MY_UID=$(id -u)

# ---- the ONE handler: on EXIT, INT, TERM and HUP --------------------------------------------------------------------
# An inherited PW (or password) keeps its export flag through a plain assignment, and `read` would then put the
# passphrase in every child's environment: unset both first, so PW is a fresh unexported shell variable.
unset PW password
PW=""; CHILD=""; SWEPT=""; T=""; ARMED=""
own_key_dirs() {   # this uid's decrypted-key dirs in SHM; another uid's are never touched
  find "$SHM" -mindepth 1 -maxdepth 1 -user "$MY_UID" \( -name 'release_keys.*' -o -name 'decrypt_keys.*' \) -print 2>/dev/null
}
sweep_keys() {     # rm -rf, not a shred: accepted by name (h52 #4); /dev/shm is memory
  local d
  while IFS= read -r d; do [ -n "$d" ] && rm -rf -- "$d"; done <<< "$(own_key_dirs)"
}
sweep() {          # $1 exit code, $2 the signal's name (signal traps only)
  [ -n "$SWEPT" ] && return
  SWEPT=1
  if [ -n "$CHILD" ]; then
    kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
    wait "$CHILD" 2>/dev/null
    CHILD=""
  fi
  PW=""; unset PW
  [ -z "$ARMED" ] || sweep_keys
  [ -z "$T" ] || rm -rf -- "$T"
  [ -z "${2:-}" ] || echo "sign-release: $2: signing child ended, key dirs swept" >&2
  exit "$1"
}
trap 'sweep $?' EXIT
trap 'sweep 129 HUP' HUP
trap 'sweep 130 INT' INT
trap 'sweep 143 TERM' TERM

export TMPDIR="${TMPDIR:-/mnt/build/tmp}"
mkdir -p "$TMPDIR" || { echo "cannot create TMPDIR=$TMPDIR" >&2; exit 1; }
T=$(mktemp -d -p "$TMPDIR" sign-release.XXXXXXXX) || { echo "cannot make a temp dir in $TMPDIR" >&2; exit 1; }

REFUSED=0
refuse() { echo "REFUSING: $1" >&2; REFUSED=1; }

# ---- PREFLIGHT: every device, before any prompt ---------------------------------------------------------------------
# 2a: the verified commit, once (Q094). Its exit code passes through, as in build-device.sh.
sh "$B/verified-commit-guard.sh" "$REPO" "$VERIFIED" || exit $?
FULL=$(git -C "$REPO" rev-parse --verify "$VERIFIED^{commit}") || { echo "cannot resolve $VERIFIED in $REPO" >&2; exit 1; }

# 2d: the OTA stamp check needs the store conf and an agent; the text is build-device.sh's.
OTA_AGENT="${NOWHERE_AGENT:-/tmp/agent_host}"
OTA_OK=1
if [ -z "${NOWHERE_OTA_STORE_CONF:-}" ] || [ ! -f "$NOWHERE_OTA_STORE_CONF" ] || [ ! -x "$OTA_AGENT" ]; then
  echo "REFUSING --release: the OTA version check needs NOWHERE_OTA_STORE_CONF (path to the store conf) and an agent" >&2
  echo "    binary (NOWHERE_AGENT, default /tmp/agent_host); one of them is missing. Without them a stamp the field" >&2
  echo "    already has cannot be told from a new one." >&2
  REFUSED=1; OTA_OK=0
fi
STAMP=$(tr -d '[:space:]' < "$REPO/core/vendor-common/etc/nowhere-ota-version")

# ':.*' not ':user.*', byte for byte build-device.sh's FPRE.
FPRE='s/^ro\.vendor\.build\.fingerprint=.*\/\([^:]*\):.*/\1/p'
check_image() {    # <dev> <out>: 2b, on the target-files zip build-device.sh left
  local DEV="$1" OUT="$2" ABS TFI IMG_BN IMG_TYPE IMG_OSREF IMG_COMMIT RING D
  case "$OUT" in /*) ABS="$OUT" ;; *) ABS="$TREE/$OUT" ;; esac
  TFI="$ABS/target/product/$DEV/obj/PACKAGING/target_files_intermediates/$DEV-target_files.zip"
  if [ ! -f "$TFI" ]; then
    refuse "$DEV: no target-files at $TFI -- build it first: VARIANT=user OUT_DIR=$OUT build-device.sh $DEV $BN"
    return
  fi
  IMG_BN=$(unzip -p "$TFI" VENDOR/build.prop 2>/dev/null | sed -n "$FPRE" | head -1)
  [ "$IMG_BN" = "$BN" ] || refuse "$DEV: image baked build number '$IMG_BN', not $BN"
  IMG_TYPE=$(unzip -p "$TFI" SYSTEM/build.prop 2>/dev/null | sed -n 's/^ro\.build\.type=//p' | head -1)
  [ "$IMG_TYPE" = user ] || refuse "$DEV: image is a '$IMG_TYPE' build, not user"
  IMG_OSREF=$(unzip -p "$TFI" SYSTEM/etc/nowhere/os-ref 2>/dev/null | tr -d '\n')
  [ "$IMG_OSREF" = "os-$DEV" ] || refuse "$DEV: image os-ref is '$IMG_OSREF', not os-$DEV"
  IMG_COMMIT=$(unzip -p "$TFI" SYSTEM/etc/nowhere/source-commit 2>/dev/null | tr -d '\n')
  [ "$IMG_COMMIT" = "$FULL" ] || refuse "$DEV: image was staged from '$IMG_COMMIT', not the verified commit $FULL"
  python3 "$B/check-patch-markers.py" --table "$B/patch-markers.tsv" --zip "$TFI" >&2 || refuse "$DEV: a framework patch's artifact literal is missing"
  # The sitting signs the RECORD's release ring, whatever NOWHERE_RING the operator's shell holds.
  if ! RING=$(env -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE sh "$B/ring-for-build.sh" "$DEV" release); then
    refuse "$DEV: ring-for-build.sh has no release ring"
    return
  fi
  D=$(mktemp -d -p "$T" ring.XXXXXXXX) || { refuse "$DEV: cannot make a temp dir"; return; }
  # assert-baked-ring.sh takes a DIRECTORY; its no-ring control needs an os-ref-* there. No conf in the image, no file.
  printf '%s\n' "$IMG_OSREF" > "$D/os-ref-$DEV"
  if unzip -l "$TFI" SYSTEM/etc/nowhere/nowhere.conf >/dev/null 2>&1; then
    unzip -p "$TFI" SYSTEM/etc/nowhere/nowhere.conf > "$D/nowhere.conf" 2>/dev/null
  fi
  if ! sh "$B/assert-baked-ring.sh" "$D" "$RING" "$REPO" >&2; then
    refuse "$DEV: the image does not bake its release ring '$RING'"
    echo "    $DEV: rebuild with NOWHERE_RING=$RING NOWHERE_RING_OVERRIDE=1 VARIANT=user OUT_DIR=$OUT build-device.sh $DEV $BN" >&2
  fi
}
check_keys() {     # <dev>: 2c, the key files build-device.sh checks before its own prompt
  local DEV="$1" K="$TREE/keys/$1" f
  f=$(compgen -G "$K/*.pk8" || true)
  [ -n "$f" ] || refuse "$DEV: keys/$DEV/*.pk8 is MISSING"
  [ -f "$K/avb.pem" ] || refuse "$DEV: keys/$DEV/avb.pem is MISSING"
  [ -f "$K/avb_pkmd.bin" ] || refuse "$DEV: keys/$DEV/avb_pkmd.bin is MISSING -- restore it from the off-box key backup, never gen-keys.sh"
  if [ ! -f "$K/id_ed25519" ]; then
    echo "WARNING: keys/$DEV/id_ed25519 is MISSING -- generate-release will SILENTLY skip signing $DEV-install-$BN.zip" >&2
  fi
}
check_tmp() {      # 2e: unlike build-device.sh, an unmeasurable df REFUSES: the sitting is the expensive part
  local kb gib
  kb=$(df -Pk "$TMPDIR" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$kb" in
    *[!0-9]* | "") refuse "could not measure the free space of TMPDIR $TMPDIR" ;;
    *) gib=$(( kb / 1024 / 1024 ))
       [ "$gib" -ge "$MIN_GIB" ] || refuse "TMPDIR $TMPDIR has $gib GiB free, the sitting needs $MIN_GIB (about 9 GiB per device pass)" ;;
  esac
}
check_stale_key_dirs() {   # 2f: a key dir left by a sitting that died without its sweep
  local s
  s=$(own_key_dirs)
  [ -z "$s" ] || refuse "stale key dir(s) of this user in $SHM: $(printf '%s' "$s" | tr '\n' ' ')-- a sitting died without its sweep; remove them"
}
check_upstream_gate() {    # 2g: what this script relies on in the GrapheneOS tree's script/
  local a b
  a=$(cat "$TREE/script/decrypt-keys" 2>/dev/null); b=$(cat "$TREE/script/generate-release.sh" 2>/dev/null)
  case "$a" in *"-v password"*) ;; *) refuse "an upstream sync changed the password gate or the key dir; re-read them before signing (script/decrypt-keys has no '-v password')"; return ;; esac
  case "$b" in *"/dev/shm/release_keys."*) ;; *) refuse "an upstream sync changed the password gate or the key dir; re-read them before signing (script/generate-release.sh has no '/dev/shm/release_keys.')" ;; esac
}

case "$MIN_GIB" in '' | *[!0-9]*) usage "SIGN_MIN_TMP_GIB '$MIN_GIB' is not a number" ;; esac
for i in "${!DEVS[@]}"; do
  check_image "${DEVS[$i]}" "${OUTS[$i]}"
  check_keys "${DEVS[$i]}"
  sh "$B/support-guard.sh" "${DEVS[$i]}" || refuse "${DEVS[$i]}: past GrapheneOS's full support"
  if [ "$OTA_OK" = 1 ]; then
    bash "$B/ota-field-guard.sh" "${DEVS[$i]}" "$STAMP" "$NOWHERE_OTA_STORE_CONF" "$OTA_AGENT" >&2 || refuse "${DEVS[$i]}: the OTA stamp $STAMP is not above the field's"
  fi
done
check_tmp
check_stale_key_dirs
check_upstream_gate
if [ "$REFUSED" = 1 ]; then
  echo "sign-release: preflight refused -- nothing was signed, no passphrase was asked for" >&2
  exit 1
fi
echo "sign-release: preflight passed for ${DEVS[*]} at $BN (commit $FULL)"

# ---- the same-user refusal ------------------------------------------------------------------------------------------
sh "$B/sitting-guard.sh" "$$" || exit 1
# From here every key dir of this uid is the sitting's own (the guard just proved no other process of it runs), so the
# handler sweeps them. Before, a preflight refusal leaves a stale dir for the operator to read and remove.
ARMED=1

# ---- ONE prompt ---------------------------------------------------------------------------------------------------
# PW is never exported: it reaches a process only as a one-command prefix (the openssl proofs and generate-release).
printf 'passphrase for the release keys (one prompt for %d device(s)): ' "${#DEVS[@]}" >&2
IFS= read -rs PW
echo >&2
[ -n "$PW" ] || { echo "empty passphrase -- refusing (an empty-but-defined password makes decrypt-keys prompt per key on /dev/tty)" >&2; exit 1; }

# ---- PROVE it on every key, before anything is signed ----------------------------------------------------------------
prove_keys() {
  local DEV k hdr
  for DEV in "${DEVS[@]}"; do
    for k in "$TREE/keys/$DEV"/*.pk8; do
      password="$PW" openssl pkcs8 -inform DER -in "$k" -passin env:password -out /dev/null </dev/null >/dev/null 2>&1 \
        || { echo "the passphrase does not open $k -- nothing was signed" >&2; return 1; }
    done
    k="$TREE/keys/$DEV/avb.pem"
    hdr=$(head -1 "$k" 2>/dev/null)
    case "$hdr" in
      *ENCRYPTED*)
        password="$PW" openssl pkey -in "$k" -noout -passin env:password </dev/null >/dev/null 2>&1 \
          || { echo "the passphrase does not open $k -- nothing was signed" >&2; return 1; } ;;
    esac
  done
}
prove_keys || exit 1
echo "sign-release: the passphrase opens every key of ${DEVS[*]}"

# ---- SIGN, one device at a time -----------------------------------------------------------------------------------
# TWIN: build-device.sh's tail after its avb_pkmd.bin check (finalize, generate-release, make-web-package, VERIFY). Read
# a change to one against the other. Two differences on purpose: `password` is given to generate-release (one prompt
# here, not one per device), and nothing here runs `m` or re-stages.
sign_one() {       # <dev> <out>, in a subshell
  local DEV="$1" OUT="$2" R TF WF
  cd "$TREE" || { echo "$DEV: cd $TREE FAILED" >&2; exit 1; }
  # As given, like build-device.sh's OUT_DIR: a relative out dir is relative to the tree, which is the cwd here.
  export OUT_DIR="$OUT" BUILD_NUMBER="$BN"
  # As build-device.sh (#740): derive BUILD_DATETIME from the BN, so a warm out dir's build_date.txt never wins.
  if [ -z "${BUILD_DATETIME:-}" ]; then
    local _bd="${BN:0:8}" _bseq="${BN:8}" _epoch
    if _epoch=$(date -u -d "${_bd:0:4}-${_bd:4:2}-${_bd:6:2} 00:00:00" +%s 2>/dev/null); then
      export BUILD_DATETIME=$((_epoch + 10#${_bseq:-0}))
    else
      export BUILD_DATETIME=$(date -u +%s)
    fi
  fi
  source build/envsetup.sh >/dev/null 2>&1 || { echo "$DEV: envsetup FAILED" >&2; exit 1; }
  [ "$BUILD_NUMBER" = "$BN" ] || { echo "$DEV: BUILD_NUMBER is '$BUILD_NUMBER' after envsetup, not '$BN' -- FAILED" >&2; exit 1; }
  lunch "$DEV-cur-user" >/dev/null 2>&1 || { echo "$DEV: lunch $DEV-cur-user FAILED" >&2; exit 1; }
  echo "== $DEV: finalize (BUILD_DATETIME $BUILD_DATETIME) =="
  bash script/finalize.sh || { echo "$DEV: finalize FAILED" >&2; exit 1; }
  echo "== $DEV: generate-release =="
  password="$PW" bash script/generate-release.sh "$DEV" "$BN" || { echo "$DEV: generate-release FAILED" >&2; exit 1; }
  R="$TREE/releases/$BN/release-$DEV-$BN"
  echo "== $DEV: make-web-package =="
  bash "$B/make-web-package.sh" "$R" "$DEV" "$BN" || { echo "$DEV: make-web-package FAILED" >&2; exit 1; }
  echo "== $DEV: VERIFY =="
  TF="$R/$DEV-target_files.zip"; WF="$R/$DEV-webfactory-$BN.zip"
  echo "   os-ref (signed)   = $(unzip -p "$TF" SYSTEM/etc/nowhere/os-ref 2>/dev/null | tr -d '\n')  (want os-$DEV)"
  echo "   build fingerprint = $(unzip -p "$TF" VENDOR/build.prop 2>/dev/null | grep -m1 '^ro.vendor.build.fingerprint=' | cut -d= -f2-)"
  echo "   nowhere_seed_home = $(unzip -l "$TF" SYSTEM/bin/nowhere_seed_home 2>/dev/null | grep -c 'SYSTEM/bin/nowhere_seed_home') (want 1)"
  echo "   sqlite3           = $(unzip -l "$TF" SYSTEM/bin/sqlite3 2>/dev/null | grep -c 'SYSTEM/bin/sqlite3') (want 0)"
  echo "   webfactory        = $(stat -c %s "$WF" 2>/dev/null) bytes"
  echo "   sha256            = $(sha256sum "$WF" 2>/dev/null | cut -d' ' -f1)"
  echo "== $DEV RELEASE DONE -- $R =="
}
SIGNED=(); FAILED=()
for i in "${!DEVS[@]}"; do
  DEV="${DEVS[$i]}"
  # In the background and waited on, in its own process group: a signal reaches the trap at once, and the trap's
  # TERM reaches generate-release and its openssl too, not only this subshell.
  set -m
  ( trap - EXIT INT TERM HUP; sign_one "$DEV" "${OUTS[$i]}" ) </dev/null &
  CHILD=$!
  set +m
  wait "$CHILD"; rc=$?
  CHILD=""
  sweep_keys
  if [ "$rc" = 0 ]; then SIGNED+=("$DEV"); else FAILED+=("$DEV"); echo "sign-release: $DEV FAILED (exit $rc); the next device runs" >&2; fi
done
PW=""; unset PW

# ---- BUNDLE and summary ---------------------------------------------------------------------------------------------
if [ "${#SIGNED[@]}" -gt 0 ]; then
  TARF="$TREE/releases/$BN/manifests-$BN.tar"
  TARGS=()
  for DEV in "${SIGNED[@]}"; do TARGS+=(-C "$TREE/releases/$BN/release-$DEV-$BN" "$DEV-manifest-$BN.json"); done
  if tar -cf "$TARF" "${TARGS[@]}"; then
    echo "manifest bundle: $TARF"
    echo "copy it to the operator machine and sign every manifest in one loop (docs/release-runbook.md §4):"
    echo "    tar -xf manifests-$BN.tar && for m in *-manifest-$BN.json; do <the local release tool, the edition's release key> \"\$m\"; done"
  else
    echo "sign-release: could not write $TARF" >&2
    FAILED+=("bundle")
  fi
fi
for DEV in "${SIGNED[@]}"; do echo "  $DEV signed"; done
for DEV in "${FAILED[@]}"; do echo "  $DEV FAILED"; done
[ "${#FAILED[@]}" -eq 0 ] || exit 1
exit 0
