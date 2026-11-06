#!/usr/bin/env bash
# test-release-variant.sh [<build-dir>] [--mutate] -- the release tooling must accept ONLY a user build.
#
# WHY THIS IS COMMITTED. lynx builds default to userdebug (build-device.sh, the 2026-08-15 reflash), and a
# userdebug tree is indistinguishable from a user tree to every step after `lunch`: release-keys are applied
# to either, so ro.build.tags=release-keys passes. Before NWP-20261011-12 nothing refused it --
# build-device.sh --release signed whatever VARIANT resolved to, its "Sign with" hint named the debug tree,
# make-web-package.sh's `:user.*` also matched `:userdebug`, and verify-release.sh never read the build type
# (and skipped husky and lynx by default). The 2026092701 release was guarded by a hand wrapper. Shipped,
# the result is adb root, su and sqlite3 on a production handset.
#
# Every block is extracted from the real scripts BY ANCHOR, never copied. If an anchor moves, extraction is
# empty and the suite exits 2 -- a test holding a stale copy would keep passing after the code changed.
#
#   bash test-release-variant.sh             # the behaviour cases
#   bash test-release-variant.sh --mutate    # ... plus 5 mutations (one per fix) that must each CONVICT the suite
#
# <build-dir> is the directory holding build-device.sh, make-web-package.sh and verify-release.sh (default:
# this script's own); --mutate points the suite at scratch copies of it. Pure logic -- no build, no tree,
# no zip, no network.
set -uo pipefail

MUTATE=no; DIR=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) DIR="$a" ;; esac; done
DIR="${DIR:-$(cd "$(dirname "$0")" && pwd)}"
BD="$DIR/build-device.sh"; WP="$DIR/make-web-package.sh"; VR="$DIR/verify-release.sh"
for f in "$BD" "$WP" "$VR"; do [ -f "$f" ] || { echo "no such script: $f" >&2; exit 2; }; done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }
has(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1 -- [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 -- [$3] present in: $2" ;; *) ok "$1" ;; esac; }
extract_failed(){ echo "EXTRACTION FAILED -- anchors moved in $1 ($2)" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- extraction -------------------------------------------------------------------------------------
# build-device.sh: the VARIANT resolution plus the --release user-build refusal, up to the verified-commit guard
# (NWP-20261104-03), which needs a git checkout and is covered by test-verified-commit.sh; the OTA stamp guard
# (NWP-20261101-06) follows it and is covered by test-ota-field-guard.sh.
VARBLOCK=$(sed -n '/^case "\$DEV" in/,/^# NWP-20261104-03: --release signs only the commit the operator verified/ p' "$BD" | sed '$d')
case "$VARBLOCK" in *'VARIANT="${VARIANT:-userdebug}"'*esac*) ;; *) extract_failed "$BD" "VARIANT case" ;; esac
case "$VARBLOCK" in *ota-field-guard*|*verified-commit-guard*) extract_failed "$BD" "the block runs into the OTA stamp or verified-commit guard" ;; esac
# build-device.sh: the no-release exit and its "Sign with" hint.
HINT=$(sed -n '/^if \[ "\$DO_RELEASE" -eq 0 \]; then/,/^fi/ p' "$BD")
case "$HINT" in *'exit 0'*) ;; *) extract_failed "$BD" "no-release hint" ;; esac
# make-web-package.sh: the IMG_BN read and the line that refuses an empty one.
BNREAD=$(grep '^IMG_BN="$(unzip -p "$TF" VENDOR/build.prop' "$WP")
BNGUARD=$(grep '^\[ -n "$IMG_BN" \]' "$WP")
[ -n "$BNREAD" ] || extract_failed "$WP" "IMG_BN read"
[ -n "$BNGUARD" ] || extract_failed "$WP" "IMG_BN guard"
# verify-release.sh: prop(), the DEVICES default, and every per-device check (1 .. the line before 2.).
PROPFN=$(sed -n '/^prop() {/,/^}/ p' "$VR")
case "$PROPFN" in *SYSTEM/build.prop*) ;; *) extract_failed "$VR" "prop()" ;; esac
DEVBLOCK=$(sed -n '/^DEVICES=("\$@")/,/^REPO_STAMP=/ p' "$VR" | sed '$d')
case "$DEVBLOCK" in *'${#DEVICES[@]}'*) ;; *) extract_failed "$VR" "DEVICES default" ;; esac
CHECK1=$(sed -n '/^  # 1\. THE artifact/,/^  # 2\. The baked OTA marker/ p' "$VR" | sed '$d')
case "$CHECK1" in *ro.build.tags*) ;; *) extract_failed "$VR" "checks 1/1b" ;; esac

# --- (a) build-device.sh refuses --release on a non-user variant --------------------------------------
# runrel <dev> <do_release> [<variant>] -> "<rc>|<resolved VARIANT>|<stderr>"
runrel(){
  local r="$T/rel.sh" rc
  { echo 'set -uo pipefail'
    printf 'DEV=%q; BN=2026101101; DO_RELEASE=%q\n' "$1" "$2"
    if [ -n "${3:-}" ]; then printf 'VARIANT=%q\n' "$3"; else echo 'unset VARIANT'; fi
    printf '%s\n' "$VARBLOCK"
    echo 'echo "$VARIANT"'; } > "$r"
  bash "$r" >"$T/rel.out" 2>"$T/rel.err"; rc=$?
  printf '%s|%s|%s' "$rc" "$(cat "$T/rel.out")" "$(cat "$T/rel.err")"
}
echo "== (a) build-device.sh: --release refuses a non-user VARIANT =="
R=$(runrel lynx 1)
is  "lynx --release (variant defaults to userdebug) refuses"  "${R%%|*}" "1"
has "the refusal names the user-tree command"                  "$R" "VARIANT=user OUT_DIR=out-lynx-user"
has "the refusal keeps the device, BN and --release"           "$R" "lynx 2026101101 --release"
R=$(runrel lynx 1 user)
is  "lynx --release VARIANT=user passes"                       "$R" "0|user|"
R=$(runrel lynx 0)
is  "lynx without --release passes and stays userdebug"        "$R" "0|userdebug|"
R=$(runrel tegu 1)
is  "tegu --release (user by default) passes"                  "$R" "0|user|"

# --- (a2) the end-of-build "Sign with" hint names a command that signs a USER tree --------------------
# runhint <variant> <out_dir> -> stdout of the extracted block
runhint(){
  local r="$T/hint.sh"
  { echo 'ts(){ :; }'
    printf 'DEV=lynx; BN=2026101101; DO_RELEASE=0; VARIANT=%q; OUT_DIR=%q\n' "$1" "$2"
    printf '%s\n' "$HINT"; } > "$r"
  bash "$r" 2>&1
}
echo "== (a2) build-device.sh: the Sign-with hint =="
R=$(runhint userdebug out-lynx)
has   "userdebug: names VARIANT=user OUT_DIR=out-lynx-user"     "$R" "VARIANT=user OUT_DIR=out-lynx-user"
has   "userdebug: the command is a --release"                  "$R" "lynx <next BN> --release"
has   "userdebug: says this build cannot be signed"            "$R" "CANNOT be signed"
hasnt "userdebug: never points the signer at the debug tree"   "$R" "OUT_DIR=out-lynx "
R=$(runhint user out-lynx-user)
has   "user: signs the same tree it just built"                "$R" "OUT_DIR=out-lynx-user VARIANT=user"
has   "user: keeps the device, BN and --release"               "$R" "lynx 2026101101 --release"
hasnt "user: no cannot-be-signed line"                         "$R" "CANNOT"

# --- (a3) the OUT_DIR comment names lynx's real warm tree ---------------------------------------------
echo "== (a3) build-device.sh: the OUT_DIR comment =="
is "comment says lynx's warm tree is out-lynx"  "$(grep -c "lynx's warm tree is \`out-lynx\`" "$BD")" "1"
is "the stale 'plain out' wording is gone"      "$(grep -c 'the plain `out`' "$BD")" "0"

# --- (b) make-web-package.sh reads a build number only from a :user/ fingerprint ----------------------
runbn(){
  local r="$T/bn.sh"
  { printf 'FP=%q; TF=dummy\n' "$1"
    echo 'unzip(){ printf "ro.vendor.build.fingerprint=%s\n" "$FP"; }'
    printf '%s\n' "$BNREAD"
    echo 'printf "%s" "$IMG_BN"'; } > "$r"
  bash "$r" 2>&1
}
echo "== (b) make-web-package.sh: the IMG_BN fingerprint pattern =="
is "a :user/ fingerprint yields its build number" \
   "$(runbn 'google/lynx/lynx:16/BP2A/2026092701:user/release-keys')" "2026092701"
is "a :userdebug/ fingerprint yields nothing" \
   "$(runbn 'google/lynx/lynx:16/BP2A/2026092701:userdebug/release-keys')" ""
is "an :eng/ fingerprint yields nothing" \
   "$(runbn 'google/lynx/lynx:16/BP2A/2026092701:eng/test-keys')" ""
{ echo "IMG_BN=''; TF=dummy"; printf '%s\n' "$BNGUARD"; echo 'exit 0'; } > "$T/guard.sh"
bash "$T/guard.sh" >"$T/guard.out" 2>&1; rc=$?
is  "an empty IMG_BN refuses"                   "$rc" "1"
has "the refusal names a non-user build"        "$(cat "$T/guard.out")" "non-user"

# --- (c) verify-release.sh checks the build type ------------------------------------------------------
# runtype <build.prop contents> -> the ok/no verdicts for checks 1 + 1b
runtype(){
  local r="$T/type.sh"
  printf '%s\n' "$1" > "$T/build.prop"
  { printf 'PROPFILE=%q; TF=dummy\n' "$T/build.prop"
    echo 'ok(){ echo "OK:$1"; }; no(){ echo "NO:$1"; }'
    echo 'unzip(){ cat "$PROPFILE"; }'
    printf '%s\n' "$PROPFN" "$CHECK1"; } > "$r"
  bash "$r" 2>&1
}
echo "== (c) verify-release.sh: the build type =="
R=$(runtype $'ro.build.tags=release-keys\nro.system.build.type=userdebug\nro.build.type=userdebug')
has   "userdebug fails"                         "$R" "NO:build type is 'userdebug'"
hasnt "userdebug never reads as user"           "$R" "OK:build type"
R=$(runtype $'ro.build.tags=release-keys\nro.system.build.type=user\nro.build.type=user')
has   "user passes"                             "$R" "OK:build type = user"
R=$(runtype $'ro.build.tags=release-keys\nro.build.type=user')
has   "ro.build.type alone is read as the fallback" "$R" "OK:build type = user"
R=$(runtype 'ro.build.tags=release-keys')
has   "no build type at all fails (unverifiable is not correct)" "$R" "NO:build type is ''"

# --- (c2) verify-release.sh defaults to every device dir -----------------------------------------------
rundev(){
  local r="$T/dev.sh"
  { printf 'HERE=%q\n' "$DIR"; echo 'set -- "$@"'
    printf '%s\n' "$DEVBLOCK"; echo 'echo "${DEVICES[*]}"'; } > "$r"
  bash "$r" "$@" 2>&1
}
echo "== (c2) verify-release.sh: the default device list =="
WANT=$(ls "$DIR/../devices" | LC_ALL=C sort | tr '\n' ' '); WANT=${WANT% }
[ -n "$WANT" ] || extract_failed "$DIR/../devices" "no device dirs"
is "no args: every device dir, sorted"          "$(rundev)" "$WANT"
is "explicit devices still win"                 "$(rundev tegu)" "tegu"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  # A mutation that never applied would make the suite exit non-zero and read as "convicted" -- a false
  # green in the one place whose job is detecting false greens. So prove each one applied first.
  # The device dirs are linked beside the copy, so (c2) reads the real listing.
  mutate(){ # mutate <label> <file-basename> <sed-script>
    rm -rf "$M/build" "$M/devices"; mkdir -p "$M/build"
    cp "$BD" "$WP" "$VR" "$M/build/"; ln -s "$DIR/../devices" "$M/devices"
    if ! sed -i "$3" "$M/build/$2" 2>"$M/err"; then
      no "MUTATION BROKEN (sed failed), verdict meaningless: $1 -- $(cat "$M/err")"; return; fi
    if cmp -s "$DIR/$2" "$M/build/$2"; then
      no "MUTATION INERT (matched nothing), verdict meaningless: $1"; return; fi
    if bash "$0" "$M/build" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi; }
  mutate "--release refusal removed" build-device.sh \
    '/^if \[ "\$DO_RELEASE" = 1 \] && \[ "\$VARIANT" != user \]; then/,/^fi/d'
  mutate "Sign-with hint back to the bare debug-tree line" build-device.sh \
    '/^  if \[ "\$VARIANT" = user \]; then/,/^  fi/c\  echo "     $0 $DEV $BN --release"'
  mutate "make-web-package :user.* restored" make-web-package.sh \
    's@:user\\/\.\*/@:user.*/@'
  mutate "verify-release build-type check removed" verify-release.sh \
    '/^  # 1b\./,/want user -- a debug image/d'
  mutate "verify-release hardcoded 3-device default restored" verify-release.sh \
    's%^\[ \${#DEVICES\[@\]} -gt 0 \] || .*%[ ${#DEVICES[@]} -gt 0 ] || DEVICES=(frankel stallion tegu)%'
  rm -rf "$M"
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
