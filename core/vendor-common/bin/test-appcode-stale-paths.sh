#!/usr/bin/env bash
# test-appcode-stale-paths.sh [--mutate] -- NWP-20261119-02: appcode_seal re-resolves or carries a code-list package
# whose listed APK paths are all stale, keeps each _meta with the APK bytes it describes, and parses the list with
# shell builtins.
#
# WHY THIS IS COMMITTED. Backlog row "A periodic seal's `#apps` staging spends two to three minutes staging
# nothing". The chooser writes the code list only at sign-out, and every sign-in reinstalls each app into a fresh
# /data/app/~~<rand>~~ dir, so on a periodic seal every listed path is the previous session's. appcode_seal
# counted such a package as "did not copy whole" (frankel, every periodic seal: 69 of them, staged 0, 137-172 s),
# re-resolved only installed-mode packages live, copied each on-demand/auto package's _meta from the chooser even
# when no APK was staged (so a Play update in the session sealed a newer _meta beside the older carried APK, and
# the next unarchive was refused: INSTALL_FAILED_INVALID_APK), and parsed every field with
# `$(printf '%s' "$line" | cut -fN)`: two execs per field on the device, where printf is /system/bin/printf.
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with qn, pw, pkgname_ok, live_code_dir,
# live_code_ver and stage_live_apks), every /data/ path pointed into a scratch root. `dumpsys` reads
# $T/dumps/<pkg>; `cp` logs each APK source it copies and fails a source listed in $T/cpfail; `cut` is a counting
# wrapper first on PATH; `$AGENT` records the stage listing, the manifest and the defer list at push time.
# S7's oracle is the OLD printf|cut parse, kept here, bounded where it looped forever (a line with no TAB).
#
#   bash test-appcode-stale-paths.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-stale-paths.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
#   ONLY="S1 S4 S8" ROAMD=<file> bash test-appcode-stale-paths.sh   # a subset, e.g. against an older roamd
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
ONLY="${ONLY:-S1 S2 S3 S4 S5 S5b S6 S6b S7 S8 S9}"
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }
REALCUT=$(command -v cut) || { echo "no cut on this host" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
want(){ case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

FUNCS=""
for fn in qn pw pkgname_ok live_code_dir live_code_ver stage_apk_copy stage_live_apks stage_keep_mtimes appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in
    "$fn() {"*'}') FUNCS="$FUNCS$body
" ;;
    *) # live_code_ver is this slice's helper: an older roamd has none, and must still run (and fail) the cases
       [ "$fn" = live_code_ver ] && [ "${ALLOW_NO_HELPER:-0}" = 1 ] && continue
       echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;;
  esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

CUTBIN="$W/cutbin"; mkdir -p "$CUTBIN" || exit 2
printf '#!/bin/sh\n[ -n "${CUTLOG:-}" ] && echo x >> "$CUTLOG"\nexec %s "$@"\n' "$REALCUT" > "$CUTBIN/cut" && chmod 755 "$CUTBIN/cut" || exit 2

TB=$(printf '\t')

# run_seal <shell> <T> <carry-essential 0|1>: runs appcode_seal over the tree $T already holds. Sets CALLS, NCALLS,
# LOGTXT, MANTXT (the pushed manifest, TAB as ':'), DEFTXT, STAGETXT, CPLOG, NCUT, and (NWP-20261128-01) DSET (y when
# the push got a non-empty NOWHERE_APPS_DORMANT), DORMTXT (its file listing at push time), DMANTXT (its manifest.tsv,
# TAB as ':') and DGONE (y when $T/data/nowhere/appcode-dormant is gone after the seal).
run_seal(){
  local s=$1 T=$2 ce=$3
  : > "$T/calls"; : > "$T/cplog"; : > "$T/cutlog"; [ -f "$T/cpfail" ] || : > "$T/cpfail"
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'T=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=%s\n' "$T" "$ce"
    printf 'PATH=%s:$PATH; CUTLOG=$T/cutlog; export CUTLOG\n' "$CUTBIN"
    cat <<'STUBS'
cp(){
  case "$1" in -*) command cp "$@"; return ;; esac
  echo "$1" >> "$T/cplog"
  if grep -qxF "$1" "$T/cpfail" 2>/dev/null; then head -c $(( $(wc -c < "$1") / 2 )) "$1" > "$2"; return 1; fi
  command cp "$@"
}
dumpsys(){ [ "$1" = package ] && [ -f "$T/dumps/$2" ] && cat "$T/dumps/$2"; return 0; }
agent_stub(){
  local last a
  for a; do last=$a; done
  rm -rf "$T/pushed"; command cp -r "$last" "$T/pushed"
  (cd "$last" && find . -type f | LC_ALL=C sort) > "$T/stage.txt"
  tr '\t' ':' < "$last/manifest.tsv" > "$T/man.txt"
  cat "${NOWHERE_DEFER_LIST:-/dev/null}" > "$T/defer.txt" 2>/dev/null
  : > "$T/dormant.txt"; : > "$T/dman.txt"; rm -f "$T/dset"
  if [ -n "${NOWHERE_APPS_DORMANT:-}" ]; then
    echo set > "$T/dset"
    (cd "$NOWHERE_APPS_DORMANT" && find . -type f | LC_ALL=C sort) > "$T/dormant.txt"
    tr '\t' ':' < "$NOWHERE_APPS_DORMANT/manifest.tsv" > "$T/dman.txt"
  fi
  echo push >> "$T/calls"
  return 0
}
STUBS
    printf 'AGENT=agent_stub\n'
    printf 'timeout(){ shift 3; "$@"; }\n'
    printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _ms(){ echo 0; }; _apps_stage_prog(){ :; }; appcode_stage_play_dormant(){ :; }\n'
    printf '%s\n' "$FUNCS"
    printf 'appcode_seal; echo "$?" > "$T/res"\n'
  } > "$T/run.sh"
  : > "$T/stage.txt"; : > "$T/man.txt"; : > "$T/defer.txt"; : > "$T/dormant.txt"; : > "$T/dman.txt"; rm -f "$T/dset"
  timeout 60 "$s" "$T/run.sh" >/dev/null 2>&1
  NCALLS=$(grep -c . "$T/calls"); LOGTXT=$(cat "$T/log" 2>/dev/null)
  MANTXT=$(cat "$T/man.txt"); DEFTXT=$(cat "$T/defer.txt"); STAGETXT=$(cat "$T/stage.txt"); CPLOG=$(cat "$T/cplog")
  NCUT=$(grep -c . "$T/cutlog")
  DORMTXT=$(cat "$T/dormant.txt"); DMANTXT=$(cat "$T/dman.txt"); DSET=n; [ -f "$T/dset" ] && DSET=y
  DGONE=y; [ -e "$T/data/nowhere/appcode-dormant" ] && DGONE=n
}

# mk_tree: a fresh scratch root in T; F = the chooser's files dir, M = its nowhere-appmeta.
mk_tree(){
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  F="$T/user/com.nowhere.chooser/files"; M="$F/nowhere-appmeta"
  mkdir -p "$T/data/nowhere" "$T/data/app" "$M" "$T/dumps" || exit 2
}
# mk_live <pkg> <versionCode>: an installed live code dir with base + split, and its dump.
mk_live(){
  local L="$T/data/app/~~live==/$1-2=="
  mkdir -p "$L" || exit 2
  printf 'live-%s-base-0123456789' "$1" > "$L/base.apk"; printf 'live-%s-split-0123456789' "$1" > "$L/split.apk"
  printf 'Packages:\n  Package [%s] (1):\n    codePath=%s\n    versionCode=%s minSdk=26 targetSdk=34\n    flags=[ HAS_CODE ]\n' "$1" "$L" "$2" > "$T/dumps/$1"
  LIVE=$L
}
mk_meta(){ mkdir -p "$M/$1" && printf 'vc\t%s\nlabel\tx\n' "$2" > "$M/$1/meta"; }
stale(){ printf '%s/data/app/~~old==/%s-1==/%s.apk' "$T" "$1" "$2"; }
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
COUNT_LINE='package(s) whose APK set did not copy whole were left out of this stage -- their stored code is kept (NWP-20261108-04)'
sline(){ printf '#apps: %s staged from live code dirs, %s carried (stale list paths), %s carried (meta version differs) (NWP-20261119-02)' "$1" "$2" "$3"; }

# six on-demand/auto lines whose paths are the previous session's, none installed
six_stale(){
  local k m
  : > "$F/nowhere-appcode.list"; : > "$F/nowhere-appkeep"
  for k in 1 2 3 4 5 6; do
    m=ondemand; [ $((k % 2)) = 0 ] && m=auto
    printf 'com.p%s\t%s\t0\t%s\t%s\t%s\n' "$k" "$k" "$m" "$(stale com.p$k base)" "$(stale com.p$k split)" >> "$F/nowhere-appcode.list"
    printf 'com.p%s\t%s\n' "$k" "$m" >> "$F/nowhere-appkeep"
    mk_meta "com.p$k" "$k"
  done
}

# S7's ORACLE: the parse appcode_seal used before NWP-20261119-02, verbatim but for its bound (a tab-less line made
# `cut -f$i` repeat the line forever). Sets O_PKG O_MODE O_META O_GRP and O_APKS (one field per line).
old_parse(){
  local line=$1 i ap mode
  O_PKG=$(printf '%s' "$line" | cut -f1)
  mode=$(printf '%s' "$line" | cut -f4)
  case "$mode" in installed|ondemand|auto) i=5 ;; *) mode=installed; i=4 ;; esac
  O_MODE=$mode
  O_META="$(printf '%s' "$line" | cut -f1-3)$(printf '\t')$mode"
  O_APKS=""; O_GRP=""
  while :; do
    ap=$(printf '%s' "$line" | cut -f$i); i=$((i+1))
    [ -n "$ap" ] || break
    case "$ap" in group:*) O_GRP="$ap"; continue ;; esac
    O_APKS="$O_APKS$ap
"
    case "$line" in *"$TB"*) ;; *) break ;; esac
  done
}
pkg_ok(){ case "$1" in *.*) ;; *) return 1 ;; esac; case "$1" in *.|*..*|*._*|*.[0-9]*|*[!A-Za-z0-9._]*|[!A-Za-z]*) return 1 ;; esac; return 0; }

# S7's lines: no tab, empty fields, a trailing tab, an empty middle field, a group: token, 1..8 APK fields, a
# legacy line (a path in column 4), fewer than four fields, an empty package field.
s7_lines(){
  local A k j m flds
  A="$T/data/app/~~s7==/x-1=="
  mkdir -p "$A" || exit 2
  for j in 1 2 3 4 5 6 7 8; do printf 'apk-%s-0123456789' "$j" > "$A/a$j.apk"; done
  printf 'com.notab\n'
  printf 'com.notab.two\n'
  printf 'com.two\t1\n'
  printf 'com.three\t1\t0\n'
  printf 'com.four\t1\t0\tondemand\n'
  printf 'com.legacy\t1\t0\t%s\t%s\n' "$A/a1.apk" "$A/a2.apk"
  printf 'com.legacyone\t1\t0\t%s\n' "$A/a3.apk"
  printf 'com.trail\t1\t0\tauto\t%s\t\n' "$A/a1.apk"
  printf 'com.mid\t1\t0\tinstalled\t%s\t\t%s\n' "$A/a1.apk" "$A/a2.apk"
  printf 'com.grp\t1\t0\tondemand\t%s\t%s\tgroup:work\n' "$A/a1.apk" "$A/a2.apk"
  printf 'com.grpfirst\t1\t0\tinstalled\tgroup:home\t%s\n' "$A/a4.apk"
  printf 'com.empty\t\t\tondemand\t%s\n' "$A/a5.apk"
  printf 'com.badpath\t1\t0\tinstalled\t/sdcard/x.apk\t%s\n' "$A/a1.apk"
  printf 'com.emptymode\t1\t0\t\t%s\n' "$A/a1.apk"
  printf '\t1\t0\tondemand\t%s\n' "$A/a1.apk"
  for k in 1 2 3 4 5 6 7 8; do
    case $((k % 3)) in 0) m=installed ;; 1) m=ondemand ;; 2) m=auto ;; esac
    flds=""; for j in $(seq 1 "$k"); do flds="$flds$TB$A/a$j.apk"; done
    printf 'com.n%s\t%s\t1\t%s%s\n' "$(printf '%s' abcdefgh | "$REALCUT" -c"$k")" "$k" "$m" "$flds"
  done
}

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"
  if want S1; then
    mk_tree; six_stale; run_seal "$s" "$T" 1
    has "$LOGTXT" 'did not copy whole' && no "$t S1 stale on-demand/auto paths counted as 'did not copy whole': [$LOGTXT]" || ok "$t S1 no 'did not copy whole' line for six stale on-demand/auto packages"
    if [ "$NCALLS" = 1 ] && ! has "$STAGETXT" './com.p' && ! has "$MANTXT" 'com.p' && ! has "$DEFTXT" 'com.p'; then
      ok "$t S1 CARRY_ESSENTIAL=1: no stage dir, no manifest line, no deferred line for any of them (the agent carries them)"
    else no "$t S1 the six reached the stage: calls=$NCALLS stage [$STAGETXT] man [$MANTXT]"; fi
    has "$LOGTXT" "] OUT \"probe\" $(sline 0 6 0)" && ok "$t S1 log: 0 staged, 6 carried (stale list paths), 0 (meta version differs)" || no "$t S1 summary line missing: [$LOGTXT]"
    printf '%s\n' "$LOGTXT" | grep 'NWP-20261119-02' | grep -q 'com\.' && no "$t S1 the summary line names a package" || ok "$t S1 the summary line names no package"
    # NWP-20261128-01: the dormant shape of each carried package goes to the side dir the push names, and only there.
    good=y; exp=""
    for k in 1 2 3 4 5 6; do
      [ -f "$M/com.p$k/meta" ] || good=n
      exp="$exp./com.p$k/_meta/meta
"
    done
    exp="$exp./manifest.tsv"
    [ "$good" = y ] || no "$t S1 fixture: a _meta source is missing under $M"
    if [ "$DSET" = y ] && [ "$DORMTXT" = "$exp" ]; then
      ok "$t S1 the push names the dormant dir, and it holds each carried package's _meta and a manifest.tsv, nothing else"
    else no "$t S1 dormant dir -> set [$DSET] files [$DORMTXT]"; fi
    good=y; nd=$(printf '%s\n' "$DMANTXT" | grep -c .)
    [ "$nd" = 6 ] || good=n
    for k in 1 2 3 4 5 6; do
      m=ondemand; [ $((k % 2)) = 0 ] && m=auto
      printf '%s\n' "$DMANTXT" | grep -qx "com.p$k:$k:0:$m" || good=n
    done
    [ "$good" = y ] && ok "$t S1 the dormant manifest holds one line per carried package, naming no APK" || no "$t S1 dormant manifest -> [$DMANTXT]"
    [ "$DGONE" = y ] && ok "$t S1 the dormant dir is gone after the seal" || no "$t S1 appcode-dormant left on /data after the seal"
  fi
  if want S2; then
    mk_tree; six_stale; run_seal "$s" "$T" 0
    has "$LOGTXT" 'did not copy whole' && no "$t S2 stale paths counted as 'did not copy whole' with the flag off: [$LOGTXT]" || ok "$t S2 flag off: no 'did not copy whole' line"
    good=y
    for k in 1 2 3 4 5 6; do
      m=ondemand; [ $((k % 2)) = 0 ] && m=auto
      has "$STAGETXT" "./com.p$k/_meta/meta" || good=n
      has "$STAGETXT" "./com.p$k/base.apk" && good=n
      printf '%s\n' "$MANTXT" | grep -qx "com.p$k:$k:0:$m" || good=n
    done
    [ "$good" = y ] && ok "$t S2 CARRY_ESSENTIAL=0: the dormant shape for each (dir + _meta + a line naming no APK)" || no "$t S2 flag off shape -> stage [$STAGETXT] man [$MANTXT]"
    has "$LOGTXT" "$(sline 0 6 0)" && ok "$t S2 log: 6 carried (stale list paths)" || no "$t S2 summary line missing: [$LOGTXT]"
  fi
  if want S3 || want S4; then
    for sc in S3 S4; do
      want "$sc" || continue
      mk_tree
      vc=42; [ "$sc" = S4 ] && vc=43
      mk_live com.s "$vc"; mk_meta com.s 42
      printf 'com.s\t42\t0\tondemand\t%s\t%s\n' "$(stale com.s base)" "$(stale com.s split)" > "$F/nowhere-appcode.list"
      printf 'com.s\tondemand\n' > "$F/nowhere-appkeep"
      run_seal "$s" "$T" 1
      if [ "$sc" = S3 ]; then
        if has "$STAGETXT" './com.s/_meta/meta' && has "$STAGETXT" './com.s/base.apk' && has "$STAGETXT" './com.s/split.apk' \
           && cmp -s "$T/pushed/com.s/base.apk" "$LIVE/base.apk" && cmp -s "$T/pushed/com.s/split.apk" "$LIVE/split.apk" \
           && [ "$DEFTXT" = "com.s/base.apk
com.s/split.apk" ] && printf '%s\n' "$MANTXT" | grep -qx 'com.s:42:0:ondemand:base.apk:split.apk'; then
          ok "$t S3 vc equal: the live APKs staged byte for byte, DEFERRED, with _meta and a manifest line naming them"
        else no "$t S3 vc equal -> stage [$STAGETXT] defer [$DEFTXT] man [$MANTXT]"; fi
        has "$LOGTXT" "$(sline 1 0 0)" && ok "$t S3 log: 1 staged from live code dirs" || no "$t S3 summary line: [$LOGTXT]"
      else
        if ! has "$STAGETXT" './com.s' && ! has "$DEFTXT" 'com.s' && ! has "$MANTXT" 'com.s'; then
          ok "$t S4 vc differs: nothing of it staged (no _meta beside bytes it does not describe)"
        else no "$t S4 vc differs -> stage [$STAGETXT] defer [$DEFTXT] man [$MANTXT]"; fi
        has "$LOGTXT" "$(sline 0 0 1)" && ok "$t S4 log: 1 carried (meta version differs)" || no "$t S4 summary line: [$LOGTXT]"
        has "$LOGTXT" 'did not copy whole' && no "$t S4 counted as 'did not copy whole'" || ok "$t S4 not counted as 'did not copy whole'"
      fi
    done
  fi
  if want S5; then
    mk_tree; mk_live com.i 9
    printf 'com.i\t9\t0\tinstalled\t%s\n' "$(stale com.i base)" > "$F/nowhere-appcode.list"
    printf 'com.i\tinstalled\n' > "$F/nowhere-appkeep"
    run_seal "$s" "$T" 1
    if printf '%s\n' "$MANTXT" | grep -qx 'com.i:9:0:installed:base.apk:split.apk' && cmp -s "$T/pushed/com.i/base.apk" "$LIVE/base.apk" \
       && ! has "$LOGTXT" 'did not copy whole' && has "$LOGTXT" "$(sline 1 0 0)"; then
      ok "$t S5 installed, stale paths, a live dir: staged from the live dir (as before), counted as staged"
    else no "$t S5 installed -> man [$MANTXT] log [$LOGTXT]"; fi
  fi
  if want S5b; then
    mk_tree
    printf 'com.i\t9\t0\tinstalled\t%s\n' "$(stale com.i base)" > "$F/nowhere-appcode.list"
    printf 'com.i\tinstalled\n' > "$F/nowhere-appkeep"
    run_seal "$s" "$T" 1
    has "$LOGTXT" 'did not copy whole' && no "$t S5b installed, stale paths, not installed: counted as 'did not copy whole'" || ok "$t S5b installed, stale paths, no live dir: not counted as 'did not copy whole'"
  fi
  if want S6; then
    mk_tree
    C="$T/data/app/~~c==/com.c-1=="; mkdir -p "$C"
    printf 'c-base-0123456789-0123456789' > "$C/base.apk"; printf 'c-split-0123456789-0123456789' > "$C/split.apk"
    mk_meta com.c 1
    printf 'com.c\t1\t0\tondemand\t%s\t%s\n' "$C/base.apk" "$C/split.apk" > "$F/nowhere-appcode.list"
    printf 'com.c\tondemand\n' > "$F/nowhere-appkeep"
    printf '%s\n' "$C/split.apk" > "$T/cpfail"
    run_seal "$s" "$T" 1
    if has "$LOGTXT" "#apps: 1 $COUNT_LINE" && ! has "$STAGETXT" './com.c/base.apk' && ! has "$LOGTXT" 'NWP-20261119-02'; then
      ok "$t S6 a cut copy is still counted 'did not copy whole' (and is not a stale-path carry)"
    else no "$t S6 cut copy -> stage [$STAGETXT] log [$LOGTXT]"; fi
  fi
  if want S6b; then
    mk_tree; mk_live com.s 42; mk_meta com.s 42
    printf 'com.s\t42\t0\tauto\t%s\n' "$(stale com.s base)" > "$F/nowhere-appcode.list"
    printf 'com.s\tauto\n' > "$F/nowhere-appkeep"
    printf '%s\n' "$LIVE/split.apk" > "$T/cpfail"
    run_seal "$s" "$T" 1
    if has "$LOGTXT" "#apps: 1 $COUNT_LINE" && ! has "$STAGETXT" './com.s' && ! has "$DEFTXT" 'com.s' && ! has "$MANTXT" 'com.s'; then
      ok "$t S6b stale paths, vc equal, the live copy cut: counted 'did not copy whole', carried, no _meta staged"
    else no "$t S6b live copy cut -> stage [$STAGETXT] defer [$DEFTXT] man [$MANTXT] log [$LOGTXT]"; fi
  fi
  if want S7; then
    mk_tree
    s7_lines > "$F/nowhere-appcode.list"
    : > "$F/nowhere-appkeep"
    run_seal "$s" "$T" 1
    # the expected observables, from the old parse: the manifest line (meta + the names when every APK field is a
    # whole copy + the group token), the copied sources in order, the deferred lines, the count of cut sets.
    exp_man=""; exp_cp=""; exp_def=""; exp_left=0
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      old_parse "$ln"
      [ -n "$O_PKG" ] || continue
      pkg_ok "$O_PKG" || continue
      nm=""; whole=y; nap=0
      while IFS= read -r ap; do
        [ -n "$ap" ] || continue
        nap=$((nap+1))
        case "$ap" in "$T"/data/app/*) ;; *) whole=n; continue ;; esac
        exp_cp="$exp_cp$ap
"
        nm="$nm:${ap##*/}"
      done <<EOF
$O_APKS
EOF
      [ "$whole" = y ] || { nm=""; exp_left=$((exp_left+1)); }
      if [ "$whole" = y ]; then
        case "$O_MODE" in ondemand|auto) for b in $(printf '%s' "$nm" | tr ':' ' '); do exp_def="$exp_def$O_PKG/$b
"; done ;; esac
      fi
      exp_man="$exp_man$(printf '%s' "$O_META" | tr '\t' ':')$nm${O_GRP:+:$O_GRP}
"
    done < "$F/nowhere-appcode.list"
    got_left=$(printf '%s\n' "$LOGTXT" | sed -n 's/.*#apps: \([0-9]*\) package(s) whose APK set did not copy whole.*/\1/p')
    [ -n "$got_left" ] || got_left=0
    if [ "$MANTXT" = "${exp_man%
}" ]; then ok "$t S7 parser: every line's pkg, versionCode, sideloaded, mode, APK names and group match the old cut parse"
    else no "$t S7 manifest differs from the old parse: got [$MANTXT] want [${exp_man%
}]"; fi
    [ "$CPLOG" = "${exp_cp%
}" ] && ok "$t S7 parser: the APK fields copied, in order, match the old cut parse" || no "$t S7 copied APK fields: got [$CPLOG] want [${exp_cp%
}]"
    [ "$DEFTXT" = "${exp_def%
}" ] && ok "$t S7 parser: the deferred lines match" || no "$t S7 deferred: got [$DEFTXT] want [${exp_def%
}]"
    [ "$got_left" = "$exp_left" ] && ok "$t S7 parser: $exp_left cut set(s), as the old parse (a tab-less line is one APK field)" || no "$t S7 cut sets: got $got_left want $exp_left"
  fi
  if want S8; then
    for nl in 1 50; do
      mk_tree
      : > "$F/nowhere-appcode.list"
      for k in $(seq 1 "$nl"); do
        printf 'com.q%s\t%s\t0\tondemand\t%s\t%s\n' "$(printf '%05d' "$k" | tr 0-9 a-j)" "$k" "$(stale com.q base)" "$(stale com.q split)" >> "$F/nowhere-appcode.list"
      done
      run_seal "$s" "$T" 1
      [ "$nl" = 1 ] && c1=$NCUT || c50=$NCUT
    done
    if [ "$c50" -le 1 ] && [ "$c50" = "$c1" ] && [ "$NCALLS" = 1 ]; then
      ok "$t S8 a 50-line list makes $c50 cut call(s), as a 1-line list (the KiB total only): no cut per line"
    else no "$t S8 cut calls: 1 line -> $c1, 50 lines -> $c50 (push calls $NCALLS)"; fi
  fi
  if want S9; then
    # NWP-20261128-01: com.s is stale with no live dir, so the carry branch writes $DORMANT/com.s; com.i is an
    # installed-mode keep-set app with no live code dir, so want_installed=1, staged=0 and appcode_seal returns 4.
    mk_tree; mk_meta com.s 5
    printf 'com.s\t5\t0\tondemand\t%s\n' "$(stale com.s base)" > "$F/nowhere-appcode.list"
    printf 'com.s\tondemand\ncom.i\tinstalled\n' > "$F/nowhere-appkeep"
    run_seal "$s" "$T" 1
    RES=$(cat "$T/res" 2>/dev/null)
    if [ "$RES" = 4 ] && [ "$NCALLS" = 0 ] && [ "$DGONE" = y ]; then
      ok "$t S9 a staged-0 refusal (return 4, no push) leaves no appcode-dormant on /data"
    else no "$t S9 staged-0 refusal -> res [$RES] calls $NCALLS dormant gone [$DGONE]"; fi
  fi
done

if [ "$MUTATE" = yes ]; then
  echo "mutants (each must FAIL its target case under EACH shell):"
  MT=$(mktemp -d -p "$W")
  mut(){ # mut <label> <target case> <sed script>
    local rc s bad=""
    sed -e "$3" "$ROAMD" > "$MT/roamd.sh"
    if cmp -s "$ROAMD" "$MT/roamd.sh"; then no "MUTANT DID NOT APPLY: $1"; return; fi
    ROAMD="$MT/roamd.sh" ONLY="$2" bash "$0" > "$MT/out" 2>&1; rc=$?
    for s in $SHELLS; do grep -q "FAIL  \[$s\] $2 " "$MT/out" || bad="$bad $s"; done
    if grep -q 'EXTRACTION FAILED' "$MT/out"; then no "MUTANT BROKE EXTRACTION: $1"
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted by $2 under every shell: $1"
    else no "NOT CONVICTED by $2 (rc $rc, shells with no FAIL line:$bad): $1"; fi
  }
  mut "M1 a STALE package counted as CUT (never classified stale)" S1 \
    's/^    if \[ "\$_acw_n" -gt 0 \] && \[ "\$_acw_gone" -eq "\$_acw_n" \]; then$/    if [ "$_acw_n" -lt 0 ]; then/'
  mut "M2 the vc comparison removed (live code staged whatever the meta's vc)" S4 \
    's/^        if \[ "\$_mvc" = "\$_lcv_vc" \]; then _acw_why=s; else _acw_why=k; fi$/        _acw_why=s/'
  mut "M3 the carry shape ignores NOWHERE_CARRY_ESSENTIAL" S2 \
    's/^        if \[ "\$NOWHERE_CARRY_ESSENTIAL" = 1 \]; then$/        if :; then/'
  mut "M4 the no-tab rule dropped (a tab-less line read as one field, no mode, no APK)" S7 \
    's/^      \*) pkg=\$line; meta=\$line; _pl_f4=\$line; _pl_k=4; _pl_more=0; _pl_r="" ;;$/      *) pkg=$line; meta=$line; _pl_f4=""; _pl_k=1; _pl_more=0; _pl_r="" ;;/'
  mut "M5 a \$(printf|cut) restored for one field (mode)" S8 \
    's/^    mode=\$_pl_f4$/    mode=$(printf '"'%s'"' "$line" | cut -f4)/'
  mut "M6 the stale reset of the cut flag removed (an uninstalled installed-mode app counted as cut)" S5b \
    '/^      _acw_cut=0   # stale, not cut: only a failed live copy below makes it cut$/d'
  mut "M7 the dormant write removed (the carry branch writes nothing to \$DORMANT)" S1 \
    's/^          if mkdir -p "\$DORMANT\/\$pkg" 2>>"\$LOG"; then$/          if false; then/'
  mut "M8 the staged-0 refusal keeps appcode-dormant (\"\$DORMANT\" removed from its cleanup)" S9 \
    's/^    rm -rf "\$STAGE" "\$POOL" "\$DORMANT"; rm -f "\$DEFER"$/    rm -rf "$STAGE" "$POOL"; rm -f "$DEFER"/'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
