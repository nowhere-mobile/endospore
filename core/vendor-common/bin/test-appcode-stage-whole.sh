#!/usr/bin/env bash
# test-appcode-stage-whole.sh [--mutate] -- NWP-20261108-04: appcode_seal stages each APK set WHOLE or not at all.
#
# WHY THIS IS COMMITTED. appcode_seal copied each listed APK with `cp ... || continue` and appended its deferred
# line per APK; stage_live_apks did the same. A copy that failed part-way (ENOSPC: the stage is a plain copy of
# every kept app's APKs on /data, on EVERY seal) or came out short (the code dir replaced mid-copy) left a cut file
# in $STAGE/<pkg>/ and the set went on without that split. The package still counted as staged, so the "staged 0 ->
# keep the previous head" guard could not fire; the agent's #apps presence guard saw bytes; the push replaced the
# stored complete set with an incomplete one (the cut file sealed too, unnamed); and the next sign-in installed a
# base without its split. A copy is now WHOLE when cp exits 0 AND the copy's size equals the source's, and a
# package with any listed APK that is not whole stages NO APK: an installed one falls into the live re-resolve
# (itself all-or-nothing), an on-demand/auto one is left in the dormant shape so the deferred carry keeps the
# stored set. NOWHERE-721 fixed the same thing in stageapp.
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with qn, pw, appcode_stage_play_dormant,
# live_code_dir and stage_live_apks), every /data/ path pointed into a scratch root. `cp` is a function that, for a
# source listed in $T/cpfail, writes half the bytes and fails, for one in $T/cpshort writes half and succeeds, and
# passes every other call through. `$AGENT` is a stub that records, at push time, the stage listing, the manifest
# and the defer list, and copies the stage to $T/pushed (appcode_seal removes $STAGE right after the push), so W1
# and W2 compare the staged bytes with their sources. stage_live_apks alone is pinned in test-live-code-dir.sh (W6).
#
# NWP-20261121-14: W6 plants the defer list ($T/data/nowhere/appcode-defer, handed to the push as NOWHERE_DEFER_LIST)
# as a DIRECTORY with one entry, a target that cannot be written, and runs bash as `bash --posix` (a bare `: >` that
# fails ends a POSIX shell). appcode_seal's `( : > "$DEFER" )` must not end the seal: every APK and manifest line is
# still pushed, the push is handed the directory (no readable defer list), and the seal returns 0.
#
# NWP-20261123-10: the manifest's own truncation. A head of APKs with no manifest installs no app at the next sign-in,
# so a manifest that cannot be written refuses the seal. The stage is removed by `rm -rf "$STAGE"` before it is made,
# so a `mkdir` stub plants the target right after the stage's `mkdir -p`. M1 plants $STAGE/manifest.tsv as a
# directory (the truncation fails); M2 as a symlink to /dev/null (the truncation succeeds on a non-file, so only the
# `[ -f ]` test catches it); M3 lets the manifest be created and a `printf` stub fails every write whose stdout is
# the manifest (a full /data: the zero-byte create succeeds, each append fails). Each: no push, return 1, the
# NOT SEALED line, the stage gone; M3 also the defer list gone (it held com.c's lines). Bash runs as `--posix`.
#
#   bash test-appcode-stage-whole.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-stage-whole.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

FUNCS=""
for fn in qn pw pkgname_ok appcode_stage_play_dormant live_code_dir stage_apk_copy stage_live_apks stage_keep_mtimes appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in "$fn() {"*'}') FUNCS="$FUNCS$body
" ;; *) echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;; esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# seal_case <shell> <scenario: R1..R7>
# Sets CALLS (the stub's push line), NCALLS, LOGTXT, and BYTES_A / BYTES_C / BYTES_BLIVE (y when the pushed stage
# holds A's and C's listed APKs, and B's live-dir APKs, byte for byte). NWP-20261121-14: also DEFERKIND (what
# NOWHERE_DEFER_LIST named at push time: file, dir, unset or other), RES (appcode_seal's return) and DIRSIZE (y when
# R7's planted defer directory reads -s before the run).
seal_case(){
  local T F A B C D live_b live_d
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  F="$T/user/com.nowhere.chooser/files"
  A="$T/data/app/~~a==/com.a-1=="; B="$T/data/app/~~b0==/com.b-0=="; C="$T/data/app/~~c==/com.c-1=="
  mkdir -p "$T/data/nowhere" "$F/nowhere-appmeta/com.c" "$T/dumps" "$A" "$B" "$C"
  live_b="$T/data/app/~~b==/com.b-1=="; live_d="$T/data/app/~~d==/com.d-1=="
  mkdir -p "$live_b" "$live_d"
  printf 'icon-bytes' > "$F/nowhere-appmeta/com.c/icon"
  printf 'a-base-apk-bytes-0123456789-0123456789' > "$A/base.apk";   printf 'a-split-apk-bytes-0123456789-0123456789' > "$A/split.apk"
  printf 'b-base-apk-bytes-0123456789-0123456789' > "$B/base.apk";   printf 'b-one-apk-bytes-0123456789-0123456789' > "$B/split_one.apk"
  printf 'b-two-apk-bytes-0123456789-0123456789' > "$B/split_two.apk"
  printf 'c-base-apk-bytes-0123456789-0123456789' > "$C/base.apk";   printf 'c-split-apk-bytes-0123456789-0123456789' > "$C/split.apk"
  printf 'live-b-base-0123456789-0123456789' > "$live_b/base.apk"; printf 'live-b-one-0123456789-0123456789' > "$live_b/split_one.apk"
  printf 'live-b-two-0123456789-0123456789' > "$live_b/split_two.apk"
  printf 'live-d-base-0123456789-0123456789' > "$live_d/base.apk"; printf 'live-d-split-0123456789-0123456789' > "$live_d/split.apk"
  printf 'Packages:\n  Package [com.b] (1):\n    codePath=%s\n    flags=[ HAS_CODE ]\n' "$live_b" > "$T/dumps/com.b"
  printf 'Packages:\n  Package [com.d] (1):\n    codePath=%s\n    flags=[ HAS_CODE ]\n' "$live_d" > "$T/dumps/com.d"
  local t; t=$(printf '\t')
  : > "$T/cpfail"; : > "$T/cpshort"
  case "$2" in
    R1|R7|M1|M2|M3)
      printf 'com.a\t1\t0\tinstalled\t%s\t%s\ncom.c\t1\t0\tondemand\t%s\t%s\n' "$A/base.apk" "$A/split.apk" "$C/base.apk" "$C/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.a\tinstalled\ncom.c\tondemand\n' > "$F/nowhere-appkeep"
      # R7 (NWP-20261121-14): the defer list cannot be written -- it is a directory, with one entry so -s reads it.
      [ "$2" = R7 ] && { mkdir -p "$T/data/nowhere/appcode-defer"; : > "$T/data/nowhere/appcode-defer/x"; }
      # M1-M3 (NWP-20261123-10): what the mkdir / printf stubs plant on the manifest.
      case "$2" in M1) echo dir > "$T/plant" ;; M2) echo null > "$T/plant" ;; M3) echo noappend > "$T/plant" ;; esac ;;
    R2|R3|R4)
      printf 'com.a\t1\t0\tinstalled\t%s\t%s\ncom.b\t1\t0\tinstalled\t%s\t%s\t%s\ncom.c\t1\t0\tondemand\t%s\t%s\n' \
        "$A/base.apk" "$A/split.apk" "$B/base.apk" "$B/split_one.apk" "$B/split_two.apk" "$C/base.apk" "$C/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.a\tinstalled\ncom.b\tinstalled\ncom.c\tondemand\n' > "$F/nowhere-appkeep"
      local cf="$T/cpfail"; [ "$2" = R4 ] && cf="$T/cpshort"
      printf '%s\n%s\n' "$B/split_one.apk" "$C/split.apk" > "$cf"
      [ "$2" = R2 ] || printf '%s\n' "$live_b/split_one.apk" >> "$cf" ;;
    R6)
      printf 'com.a\t1\t0\tinstalled\t%s\t%s\ncom.c\t1\t0\tondemand\t%s\t%s\n' "$A/base.apk" "$A/split.apk" "$C/base.apk" "$C/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.a\tinstalled\ncom.c\tondemand\n' > "$F/nowhere-appkeep"
      rm -f "$C/split.apk" ;;
    R5)
      printf 'com.a\t1\t0\tinstalled\t%s\t%s\n' "$A/base.apk" "$A/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.a\tinstalled\ncom.d\tinstalled\n' > "$F/nowhere-appkeep"
      printf '%s\n' "$live_d/split.apk" > "$T/cpfail" ;;
  esac
  : > "$T/calls"
  DIRSIZE=$([ -s "$T/data/nowhere/appcode-defer" ] && echo y)
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'T=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=0\n' "$T"
    cat <<'STUBS'
cp(){
  local f
  case "$1" in -*) command cp "$@"; return ;; esac
  if grep -qxF "$1" "$T/cpfail" 2>/dev/null; then head -c $(( $(wc -c < "$1") / 2 )) "$1" > "$2"; return 1; fi
  if grep -qxF "$1" "$T/cpshort" 2>/dev/null; then head -c $(( $(wc -c < "$1") / 2 )) "$1" > "$2"; return 0; fi
  command cp "$@"
}
mkdir(){
  local last a
  command mkdir "$@" || return
  for a; do last=$a; done
  [ "$last" = "$T/data/nowhere/appcode-stage" ] || return 0
  case "$(cat "$T/plant" 2>/dev/null)" in
    dir) command mkdir "$last/manifest.tsv" ;;
    null) ln -s /dev/null "$last/manifest.tsv" ;;
  esac
  return 0
}
printf(){
  if [ -f "$T/plant" ] && [ "$(cat "$T/plant")" = noappend ] && [ /dev/stdout -ef "$T/data/nowhere/appcode-stage/manifest.tsv" ]; then return 1; fi
  command printf "$@"
}
dumpsys(){ [ "$1" = package ] && [ -f "$T/dumps/$2" ] && cat "$T/dumps/$2"; return 0; }
agent_stub(){
  local last a
  for a; do last=$a; done
  rm -rf "$T/pushed"; command cp -r "$last" "$T/pushed"
  echo "STAGE=$(cd "$last" && find . -type f | LC_ALL=C sort | tr '\n' ',') | MAN=$(tr '\t\n' ':,' < "$last/manifest.tsv") | DEFER=$(cat "${NOWHERE_DEFER_LIST:-/dev/null}" 2>/dev/null | tr '\n' ',')" >> "$T/calls"
  if [ -z "${NOWHERE_DEFER_LIST:-}" ]; then echo unset; elif [ -f "$NOWHERE_DEFER_LIST" ]; then echo file; elif [ -d "$NOWHERE_DEFER_LIST" ]; then echo dir; else echo other; fi > "$T/deferkind"
  return 0
}
STUBS
    printf 'AGENT=agent_stub\n'
    printf 'timeout(){ shift 3; "$@"; }\n'
    printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _ms(){ echo 0; }; _apps_stage_prog(){ :; }\n'
    printf '%s\n' "$FUNCS"
    printf 'appcode_seal; echo "$?" > "$T/res"\n'
  } > "$T/run.sh"
  case "$1:$2" in bash:R7|bash:M1|bash:M2|bash:M3) bash --posix "$T/run.sh" ;; *) "$1" "$T/run.sh" ;; esac >/dev/null 2>&1
  DEFERKIND=$(cat "$T/deferkind" 2>/dev/null); RES=$(cat "$T/res" 2>/dev/null)
  NCALLS=$(grep -c . "$T/calls"); CALLS=$(cat "$T/calls"); LOGTXT=$(cat "$T/log" 2>/dev/null)
  BYTES_A=$(cmp -s "$T/pushed/com.a/base.apk" "$A/base.apk" && cmp -s "$T/pushed/com.a/split.apk" "$A/split.apk" && echo y)
  BYTES_C=$(cmp -s "$T/pushed/com.c/base.apk" "$C/base.apk" && cmp -s "$T/pushed/com.c/split.apk" "$C/split.apk" && echo y)
  BYTES_BLIVE=$(for f in base split_one split_two; do cmp -s "$T/pushed/com.b/$f.apk" "$live_b/$f.apk" || exit 0; done; echo y)
  APKSRC="$T"
  STAGEGONE=$([ -e "$T/data/nowhere/appcode-stage" ] || [ -L "$T/data/nowhere/appcode-stage" ] || echo y)
  DEFERGONE=$([ -e "$T/data/nowhere/appcode-defer" ] || [ -L "$T/data/nowhere/appcode-defer" ] || echo y)
  rm -rf "$T"
}

has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
COUNT_LINE='package(s) whose APK set did not copy whole were left out of this stage -- their stored code is kept (NWP-20261108-04)'

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"
  seal_case "$s" R1
  if [ "$NCALLS" = 1 ] && has "$CALLS" 'STAGE=./com.a/base.apk,./com.a/split.apk,./com.c/_meta/icon,./com.c/base.apk,./com.c/split.apk,./manifest.tsv' \
     && has "$CALLS" 'com.a:1:0:installed:base.apk:split.apk,' && has "$CALLS" 'com.c:1:0:ondemand:base.apk:split.apk,' \
     && has "$CALLS" 'DEFER=com.c/base.apk,com.c/split.apk,' && [ "$BYTES_A" = y ] && [ "$BYTES_C" = y ] && [ "$RES" = 0 ]; then
    ok "$t W1 every APK whole: A staged and named (both splits), C staged with its two deferred lines, all byte-identical, returns 0"
  else no "$t W1 all whole -> $NCALLS call(s) [$CALLS] bytes A=[$BYTES_A] C=[$BYTES_C] res [$RES]"; fi
  has "$LOGTXT" 'did not copy whole' && no "$t W5a all whole: the log carries a discard line" || ok "$t W5a all whole: no discard line in the log"

  for sc in R2 R3 R4; do
    seal_case "$s" $sc
    stage=${CALLS%% | MAN=*}; man=${CALLS#* | MAN=}; man=${man%% | DEFER=*}; defer=${CALLS##* | DEFER=}
    has "$stage" './com.a/base.apk,./com.a/split.apk,' || no "$t $sc A (whole) lost from the stage: [$stage]"
    # W4: the on-demand package whose second APK did not copy whole
    if ! has "$stage" './com.c/base.apk' && ! has "$stage" './com.c/split.apk' && has "$stage" './com.c/_meta/icon' \
       && ! has "$defer" 'com.c/' && has "$man" 'com.c:1:0:ondemand,' && ! has "$man" 'com.c:1:0:ondemand:'; then
      ok "$t W4 $sc on-demand C, one copy not whole: no C/*.apk, no C deferred line, C/_meta kept, manifest line names none"
    else no "$t W4 $sc C -> stage [$stage] man [$man] defer [$defer]"; fi
    case $sc in
      R2) # B's code-list copy fails, the live dir copies whole: B is staged from the live dir
        if has "$stage" './com.b/base.apk,./com.b/split_one.apk,./com.b/split_two.apk,' && has "$man" 'com.b:1:0:installed:base.apk:split_one.apk:split_two.apk,' \
           && has "$LOGTXT" 'appcode re-resolved com.b' && [ "$BYTES_BLIVE" = y ]; then
          ok "$t W2 $sc B's list copy not whole: staged whole by the live re-resolve, all three named, the live-dir bytes"
        else no "$t W2 $sc B -> stage [$stage] man [$man] live bytes [$BYTES_BLIVE]"; fi
        if has "$LOGTXT" "#apps: 1 $COUNT_LINE"; then ok "$t W5 $sc log: 1 package left out (C), B was rescued"
        else no "$t W5 $sc log lacks '#apps: 1 $COUNT_LINE': [$LOGTXT]"; fi ;;
      R3|R4) # the live copy fails too (cut or failed, as the case)
        if ! has "$stage" './com.b/' && has "$man" 'com.b:1:0:installed,' && ! has "$man" 'com.b:1:0:installed:'; then
          ok "$t W2/W3 $sc B's list and live copies not whole: no B/*.apk staged, its manifest line names none"
        else no "$t W2/W3 $sc B -> stage [$stage] man [$man]"; fi
        cl=$(printf '%s\n' "$LOGTXT" | grep '#apps: 2 ' || true)
        if has "$cl" "#apps: 2 $COUNT_LINE" && ! has "$cl" 'com.' && has "$cl" '] OUT "probe" #apps'; then
          ok "$t W5 $sc log: 2 packages left out, no package name in the line"
        else no "$t W5 $sc count line -> [$cl]"; fi ;;
    esac
  done

  seal_case "$s" R6
  if ! has "$CALLS" './com.c/base.apk' && has "$CALLS" './com.c/_meta/icon' && has "$CALLS" './com.a/base.apk,./com.a/split.apk,' \
     && ! has "$CALLS" 'DEFER=com.c' && has "$LOGTXT" "#apps: 1 $COUNT_LINE"; then
    ok "$t R6 a listed source vanished (update): the set is discarded whole and the count line carries it"
  else no "$t R6 vanished source -> [$CALLS] log [$LOGTXT]"; fi

  seal_case "$s" R5
  if ! has "$CALLS" 'com.d' && has "$LOGTXT" "#apps: 1 $COUNT_LINE"; then
    ok "$t R5 keep-set sweep: D's live copy not whole -> D not staged, not in the manifest, counted"
  else no "$t R5 keep-set D -> [$CALLS] log [$LOGTXT]"; fi

  seal_case "$s" R7
  [ "$DIRSIZE" = y ] && ok "$t W6 precondition: the planted defer directory reads -s" || no "$t W6 precondition: the planted defer directory does not read -s"
  defer=${CALLS##* | DEFER=}
  if [ "$NCALLS" = 1 ] && has "$CALLS" 'STAGE=./com.a/base.apk,./com.a/split.apk,./com.c/_meta/icon,./com.c/base.apk,./com.c/split.apk,./manifest.tsv' \
     && has "$CALLS" 'com.a:1:0:installed:base.apk:split.apk,' && has "$CALLS" 'com.c:1:0:ondemand:base.apk:split.apk,' \
     && [ "$DEFERKIND" = dir ] && [ -z "$defer" ] && [ "$RES" = 0 ] && has "$LOGTXT" '#apps sealed (2 pkg)'; then
    ok "$t W6 a defer list that cannot be written (bash as --posix): the seal runs on, pushes every APK and manifest line, is handed the directory as NOWHERE_DEFER_LIST, and returns 0"
  else no "$t W6 defer list a directory -> $NCALLS call(s) [$CALLS] deferkind [$DEFERKIND] res [$RES] log [$LOGTXT]"; fi

  # NWP-20261123-10: a manifest that cannot be written refuses the seal.
  for sc in M1 M2; do
    seal_case "$s" $sc
    case $sc in M1) what="a directory" ;; *) what="a symlink to /dev/null" ;; esac
    if [ "$NCALLS" = 0 ] && [ "$RES" = 1 ] && has "$LOGTXT" "] OUT \"probe\" #apps cannot create the stage's manifest -- NOT SEALED" \
       && ! has "$LOGTXT" '#apps sealed' && [ "$STAGEGONE" = y ]; then
      ok "$t $sc the manifest is $what (bash as --posix): no push, returns 1, NOT SEALED logged, the stage removed"
    else no "$t $sc manifest $what -> $NCALLS call(s) [$CALLS] res [$RES] stage gone [$STAGEGONE] log [$LOGTXT]"; fi
  done
  seal_case "$s" M3
  if [ "$NCALLS" = 0 ] && [ "$RES" = 1 ] && has "$LOGTXT" "#apps staged 2 pkg(s) but the stage's manifest took no line -- NOT SEALED" \
     && ! has "$LOGTXT" '#apps sealed' && [ "$STAGEGONE" = y ] && [ "$DEFERGONE" = y ]; then
    ok "$t M3 the manifest takes no line (bash as --posix): no push, returns 1, NOT SEALED logged, the stage and the defer list removed"
  else no "$t M3 manifest takes no line -> $NCALLS call(s) [$CALLS] res [$RES] stage gone [$STAGEGONE] defer gone [$DEFERGONE] log [$LOGTXT]"; fi
done

if [ "$MUTATE" = yes ]; then
  echo "mutants (each must FAIL a line under EACH shell):"
  MT=$(mktemp -d -p "$W")
  mut(){ # mut <label> <sed script>
    local rc s bad=""
    sed -e "$2" "$ROAMD" > "$MT/roamd.sh"
    if cmp -s "$ROAMD" "$MT/roamd.sh"; then no "MUTANT DID NOT APPLY: $1"; return; fi
    ROAMD="$MT/roamd.sh" bash "$0" > "$MT/out" 2>&1; rc=$?
    for s in $SHELLS; do grep -q "FAIL  \[$s\]" "$MT/out" || bad="$bad $s"; done
    if grep -q 'EXTRACTION FAILED' "$MT/out"; then no "MUTANT BROKE EXTRACTION: $1"
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted under every shell: $1"
    else no "NOT CONVICTED (rc $rc, shells with no FAIL line:$bad): $1"; fi
  }
  mut "A1 the inner loop back to || continue per file (a partial set is kept)" 's/^    if \[ "\$_acw_w" -eq "\$_acw_n" \]; then$/    if :; then/'
  mut "A2 the size check dropped from the copy (stage_apk_copy, NWP-20261128-09)" '/^stage_apk_copy() {$/,/^}$/s/ && sac_sz=\$(stat -c %s "\$1" 2>\/dev\/null) && \[ "\$sac_sz" = "\$(stat -c %s "\$2" 2>\/dev\/null)" \]//'
  mut "A3 deferred lines appended per APK again" 's/^        _acw_w=\$((_acw_w+1))$/&\n        case "$mode" in ondemand|auto) printf "%s\/%s\\n" "$pkg" "$bn" >> "$DEFER";; esac/;/for _acw_bn in \$names; do printf/d'
  mut "A4 stage_live_apks keeps its partial copies" '/^stage_live_apks() {$/,/^}$/{/^      rm -f "\$2"\/\*\.apk$/d;s/^      return 1$/      continue/}'
  mut "A5 the discard removes the whole dir instead of its *.apk" 's|^      rm -f "\$d"/\*\.apk$|      rm -rf "$d"|'
  mut "A7 a vanished listed source is skipped without marking the set cut" 's/^      \[ -f "\$ap" \] || { _acw_cut=1; continue; }$/      [ -f "$ap" ] || continue/'
  mut "A6 the count line removed" '/did not copy whole were left out/d'
  mut "A8 a code-list copy's bytes differ from its source (same size)" 's|^      if stage_apk_copy "\$ap" "\$d/\$bn"; then$|      if stage_apk_copy "$ap" "$d/$bn" \&\& { printf X \| dd of="$d/$bn" conv=notrunc 2>/dev/null; }; then|'
  mut "A10 the defer list's truncation bare again (NWP-20261121-14)" 's/^  ( : > "\$DEFER" )$/  : > "$DEFER"/'
  mut "A11 the manifest refusal dropped: the bare truncation again (NWP-20261123-10)" '/#apps cannot create the stage'"'"'s manifest -- NOT SEALED/d;s/^  MAN="\$STAGE\/manifest.tsv"$/  MAN="$STAGE\/manifest.tsv"; ( : > "$MAN" )/'
  mut "A12 the manifest refusal returns 0 (NWP-20261123-10)" '/#apps cannot create the stage'"'"'s manifest -- NOT SEALED/s/return 1; }$/return 0; }/'
  mut "A13 the [ -f \"\$MAN\" ] test dropped (NWP-20261123-10)" 's/ \&\& \[ -f "\$MAN" \]//'
  mut "A14 the empty-manifest check dropped (NWP-20261123-10)" '/the stage'"'"'s manifest took no line -- NOT SEALED/d'
  mut "A15 the manifest refusal leaves the stage (NWP-20261123-10)" '/#apps cannot create the stage'"'"'s manifest -- NOT SEALED/s/rm -rf "\$STAGE" "\$POOL" "\$DORMANT" 2>\/dev\/null; //'
  mut "A16 the empty-manifest refusal leaves the defer list (NWP-20261123-10)" '/the stage'"'"'s manifest took no line -- NOT SEALED/s/rm -f "\$DEFER"; //'
  mut "A9 a live-dir copy's bytes differ from its source (same size)" 's|^    if stage_apk_copy "\$sla_ap" "\$2/\$sla_bn"; then$|    if stage_apk_copy "$sla_ap" "$2/$sla_bn" \&\& { printf X \| dd of="$2/$sla_bn" conv=notrunc 2>/dev/null; }; then|'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
