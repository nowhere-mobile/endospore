#!/usr/bin/env bash
# test-usage-access-roam.sh [<nowhere_roamd.sh>] [<ProfileActivity.java>] [--mutate] -- Usage access roams as one more
# appop line (NWP-20261108-14, Q024 in docs/product-decisions.md, decided 2026-10-20).
#
# WHY THIS IS COMMITTED. A user who grants a launcher, a battery or a screen-time app Usage access lost it at every
# sign-in (a new Android user): capturePerms only recorded the members of ProfileActivity.SPECIAL_APPOP_PERMS and
# grant_perms_for only restored the ops on its own allowlist, and get_usage_stats was on neither. The two lists must
# agree, or a line is captured and dropped, or restored with nobody capturing it. Each way that breaks is silent:
#   U1 an `appop:android:get_usage_stats` line is restored, once, with `appops set ... allow`;
#   U2 the four ops that already roamed still are, once each;
#   U3 an op off the allowlist runs no `cmd appops` and falls through to no `pm grant` (a tampered or older sealed file);
#   U4 the members of SPECIAL_APPOP_PERMS (mapped by a fixed table below) equal grant_perms_for's alternatives exactly,
#      and both are the five expected ops. A Java member the table does not know fails (mutant M5).
# Every case runs under each shell found of bash, sh, dash, mksh (mksh is the device's /system/bin/sh).
#
#   bash test-usage-access-roam.sh            # the behaviour cases
#   bash test-usage-access-roam.sh --mutate   # ... plus mutations that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no; ARGS=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) ARGS+=("$a") ;; esac; done
SUT="${ARGS[0]:-$(dirname "$0")/nowhere_roamd.sh}"
JAVA="${ARGS[1]:-$(dirname "$0")/../../chooser/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
[ -f "$JAVA" ] || { echo "no such file: $JAVA" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS="bash sh"
for s in dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

UIDV=15
WANT="android:get_usage_stats android:manage_external_storage android:request_install_packages android:system_alert_window android:write_settings"

STUBS='
pm() {
  case "$1 $2" in
    "list packages") cat "$D/pkgs" ;;
    "grant --user")  echo "grant $4 $5"  >> "$D/calls"; return 0 ;;
    "revoke --user") echo "revoke $4 $5" >> "$D/calls"; return 0 ;;
    "set-permission-flags --user") shift 3; echo "flags $*" >> "$D/calls" ;;
    *) echo "pm $*" >> "$D/unexpected"; return 1 ;;
  esac
}
cmd() { echo "cmd $*" >> "$D/calls"; return 0; }
'

# prep_fn <roamd.sh> <out> -- extract grant_perms_for by anchor and point its nowhere-perms under $TROOT. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" raw
  raw=$(mktemp -p "$W") || return 2
  sed -n '/^grant_perms_for() {$/,/^}$/p' "$sut" > "$raw"
  if [ ! -s "$raw" ] || [ "$(head -1 "$raw")" != 'grant_perms_for() {' ] || [ "$(tail -1 "$raw")" != '}' ]; then
    echo "EXTRACTION FAILED: grant_perms_for() { ... } not found in $sut" >&2; return 2
  fi
  sed 's#PF="/data/user/#PF="$TROOT/data/user/#' "$raw" > "$out"
  if [ "$(grep -c 'PF="\$TROOT/data/user/' "$out")" != 1 ] || [ "$(grep -c '/data/user/' "$out")" != 1 ]; then
    echo "REWRITE FAILED: want exactly one PF=\"/data/user/ assignment in grant_perms_for of $sut" >&2; return 2
  fi
  if ! bash -n "$out" || ! sh -n "$out"; then
    echo "EXTRACTION FAILED: grant_perms_for does not parse ($sut)" >&2; return 2
  fi
  return 0
}

# run <fn> <shell> <perms-content> -- an empty package list, so the INTERNET default never touches a package. Sets D.
run() {
  local fn="$1" sh="$2" content="$3" pf
  D=$(mktemp -d -p "$W"); pf="$D/root/data/user/$UIDV/com.nowhere.chooser/files/nowhere-perms"
  mkdir -p "$D/state" "${pf%/*}"
  printf '%s' "$content" > "$pf"
  : > "$D/pkgs"
  {
    printf 'D=%s\nTROOT=%s\nSTATE=%s\nLOG=%s\n' "$D" "$D/root" "$D/state" "$D/log"
    printf '%s\n' "$STUBS"
    cat "$fn"
    printf 'grant_perms_for %s\n' "$UIDV"
  } > "$D/run.sh"
  "$sh" "$D/run.sh" >/dev/null 2>&1
  touch "$D/calls" "$D/log" "$D/unexpected"
}

count() { [ "$(grep -cxF -- "$2" "$D/calls")" = "$1" ] || why="$why want $1 x '$2', got $(grep -cxF -- "$2" "$D/calls");"; }
absent() { local hit; hit=$(grep -F -- "$1" "$D/calls"); [ -z "$hit" ] || why="$why unexpected: $(echo "$hit" | tr '\n' ';')"; }

# java_ops <ProfileActivity.java> -- the ops the SPECIAL_APPOP_PERMS members map to, sorted, one line; "UNKNOWN <m>" for a
# member the fixed table does not know, "EMPTY" for no members.
java_ops() {
  local blk m out="" op
  blk=$(awk '/SPECIAL_APPOP_PERMS = new/{on=1} on{print} on&&/\)\);[[:space:]]*$/{exit}' "$1" \
    | grep -o 'android\.Manifest\.permission\.[A-Z_]*' | sed 's/.*\.//')
  [ -n "$blk" ] || { echo EMPTY; return; }
  for m in $blk; do
    case "$m" in
      MANAGE_EXTERNAL_STORAGE) op=android:manage_external_storage ;;
      SYSTEM_ALERT_WINDOW) op=android:system_alert_window ;;
      WRITE_SETTINGS) op=android:write_settings ;;
      REQUEST_INSTALL_PACKAGES) op=android:request_install_packages ;;
      PACKAGE_USAGE_STATS) op=android:get_usage_stats ;;
      *) echo "UNKNOWN $m"; return ;;
    esac
    out="$out$op "
  done
  printf '%s\n' "$out" | tr ' ' '\n' | grep . | sort | tr '\n' ' '
}

# roamd_ops <extracted fn> -- the alternatives of the appop arm's allowlist, sorted, one line; "BAD" unless exactly one line.
roamd_ops() {
  local lines
  lines=$(grep -E '^ *android:[a-z_|:]*\)$' "$1")
  [ "$(printf '%s\n' "$lines" | grep -c .)" = 1 ] || { echo BAD; return; }
  printf '%s\n' "$lines" | tr -d ' )' | tr '|' '\n' | sort | tr '\n' ' '
}

# suite <roamd.sh> <ProfileActivity.java> <failfile> [quiet] -- appends every failing case line to <failfile>.
# 0 all ok, 1 a case failed, 2 the harness could not run
suite() {
  local f="$1" j="$2" ff="$3" quiet="${4:-}" fn p=0 x=0 sh NL why op ops jo ro want
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); printf '  FAIL  %s\n' "$1" >> "$ff"; [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  verdict() { if [ -z "$why" ]; then ok "$1 [$sh]"; else no "$1 [$sh] --$why"; fi; }
  fn=$(mktemp -p "$W") || return 2
  prep_fn "$f" "$fn" || return 2
  NL=$'\n'
  want=$(printf '%s\n' $WANT | sort | tr '\n' ' ')
  jo=$(java_ops "$j"); ro=$(roamd_ops "$fn")

  for sh in $SHELLS; do
    why=""; run "$fn" "$sh" "com.a appop:android:get_usage_stats${NL}"
    count 1 "cmd appops set --user $UIDV com.a android:get_usage_stats allow"
    verdict "U1 usage access is restored once"

    why=""; ops=""
    for op in android:manage_external_storage android:system_alert_window android:write_settings android:request_install_packages; do
      ops="${ops}com.a appop:$op${NL}"
    done
    run "$fn" "$sh" "$ops"
    for op in android:manage_external_storage android:system_alert_window android:write_settings android:request_install_packages; do
      count 1 "cmd appops set --user $UIDV com.a $op allow"
    done
    verdict "U2 the four ops that already roamed still are, once each"

    why=""; run "$fn" "$sh" "com.a appop:android:get_accounts${NL}"
    absent "cmd appops"; absent "grant com.a"
    verdict "U3 an off-list op runs no appops and no pm grant"

    why=""
    [ "$jo" = "$want " ] || [ "$jo" = "$want" ] || why="$why Java set is '$jo', want '$want';"
    [ "$ro" = "$want " ] || [ "$ro" = "$want" ] || why="$why roamd arm is '$ro', want '$want';"
    [ "$jo" = "$ro" ] || why="$why Java '$jo' != roamd '$ro';"
    verdict "U4 SPECIAL_APPOP_PERMS equals the roamd arm's alternatives (the five ops)"
  done
  [ "$x" = 0 ] || return 1
  return 0
}

FF=$(mktemp -p "$W") || exit 2
suite "$SUT" "$JAVA" "$FF"; rc=$?
[ "$rc" = 2 ] && exit 2
if [ "$rc" = 0 ]; then echo "usage access roam: all cases passed"; else echo "usage access roam: cases FAILED"; fi
[ "$MUTATE" = yes ] || exit "$rc"
[ "$rc" = 0 ] || { echo "refusing to mutate a failing suite" >&2; exit 1; }

echo "--- mutants"
bad=0
# mutate <label> <file: roamd|java> <sed program>
mutate() {
  local label="$1" which="$2" prog="$3" r j ff s hit
  r=$(mktemp -p "$W"); j=$(mktemp -p "$W"); ff=$(mktemp -p "$W")
  cp "$SUT" "$r"; cp "$JAVA" "$j"
  if [ "$which" = roamd ]; then sed -i "$prog" "$r"; cmp -s "$r" "$SUT" && { echo "  MUTANT DID NOT APPLY: $label"; bad=1; return; }
  else sed -i "$prog" "$j"; cmp -s "$j" "$JAVA" && { echo "  MUTANT DID NOT APPLY: $label"; bad=1; return; }; fi
  suite "$r" "$j" "$ff" quiet; rc=$?
  [ "$rc" = 1 ] || { echo "  SURVIVED $label (rc $rc)"; bad=1; return; }
  for s in $SHELLS; do
    hit=$(grep -F "[$s]" "$ff")
    [ -n "$hit" ] || { echo "  SURVIVED $label under $s"; bad=1; return; }
  done
  echo "  CONVICTED $label"
}
mutate 'M1 the roamd alternative is removed' roamd 's/|android:get_usage_stats)$/)/'
mutate 'M2 the Java member is removed' java '/android\.Manifest\.permission\.PACKAGE_USAGE_STATS/d;s/REQUEST_INSTALL_PACKAGES,$/REQUEST_INSTALL_PACKAGES));/'
mutate 'M3 the arm continue is removed' roamd '/^      appop:\*)$/,/^        continue;;$/{/^        continue;;$/s/continue;;/:;;/}'
mutate 'M4 an extra op on the roamd side only' roamd 's/|android:get_usage_stats)$/|android:get_usage_stats|android:get_accounts)/'
mutate 'M5 an unknown member on the Java side only' java 's/PACKAGE_USAGE_STATS));/PACKAGE_USAGE_STATS, android.Manifest.permission.BIND_ACCESSIBILITY_SERVICE));/'
[ "$bad" = 0 ] || exit 1
echo "usage access roam: every mutant convicted"
