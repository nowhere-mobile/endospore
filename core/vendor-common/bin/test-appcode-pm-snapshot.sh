#!/usr/bin/env bash
# test-appcode-pm-snapshot.sh [--mutate] -- NWP-20261130-16: an #apps stage reads PackageManager once, not once per
# package, and its "#apps staged" line names where its time goes.
#
# WHY THIS IS COMMITTED. Backlog row "A periodic seal's `#apps` stage spends about 85-124 s on frankel besides copying,
# which round 50's copy reuse does not remove". The line split only the copy, and every lookup ran its own
# `dumpsys package <pkg>`. The stage now takes one `dumpsys package packages` into a root-only file under $STATE, and
# live_code_dir / live_code_ver answer from it with the same three rules. The risk is data loss, not speed: a snapshot read
# as "not installed" drops an app's code from the seal, and a dump cut before its flags line reads an updated system app as
# sealable. So a package with no usable row falls back to its own dump, and a dump that exits non-zero makes no snapshot,
# whatever rows it printed first. Nothing fails when this regresses, so this suite pins it.
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with its helpers), every /data/ path pointed into a scratch
# root. `dumpsys` counts its calls in $T/dumpsys.calls, and serves $T/dumps/.all for `package packages` and $T/dumps/<pkg>
# for `package <pkg>`. `_ms` is a clock that ticks 7 at each read, so each span is above zero. `_apps_stage_prog` records
# the snapshot's mode and a copy of it during the stage. `$AGENT` records the stage at push time and exits 0.
#
#   bash test-appcode-pm-snapshot.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-pm-snapshot.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
#   ONLY="s1 s2" ROAMD=<file> bash test-appcode-pm-snapshot.sh   # a subset, e.g. against an older roamd
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
ONLY="${ONLY:-s1 s2 s3a s3b s3c s3d s3e s4a s4b s5 s6a s6b s6c s6d s7a s7b s7c s8a s8b s9 s10a s10b s11 s12 s13}"
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
want(){ case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

FUNCS=""
for fn in qn pw pkgname_ok appcode_pm_snapshot appcode_pm_row live_code_dir live_code_ver stage_apk_copy stage_live_apks stage_keep_mtimes appcode_stage_play_dormant appcode_inputs_fp appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in
    "$fn() {"*'}') FUNCS="$FUNCS$body
" ;;
    *) # This slice's helpers: an older roamd has none, and must still run (and fail) the cases.
       case "$fn" in appcode_pm_snapshot|appcode_pm_row) continue ;; esac
       echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;;
  esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# head_lines <T>: the shell prologue every run file shares (stubs, then the lifted functions).
head_lines(){
  printf '%s\n' "$PRINT_SHIM"
  printf 'umask 022\n'
  printf 'T=%s; LOG=$T/log; USERDIR=$T/user; STATE=$T/state; name=probe; pass=x; uid=12; skind=""; NOWHERE_CARRY_ESSENTIAL=1\n' "$1"
  cat <<'STUBS'
dumpsys(){
  echo "$*" >> "$T/dumpsys.calls"
  [ "$1" = package ] || return 0
  if [ "$2" = packages ]; then
    cat "$T/dumps/.all" 2>/dev/null
    [ ! -f "$T/dumps/.rc" ] || return "$(cat "$T/dumps/.rc")"
    return 0
  fi
  [ ! -f "$T/dumps/$2" ] || cat "$T/dumps/$2"
  return 0
}
_ms(){ local _t; _t=$(cat "$T/clock" 2>/dev/null); _t=$(( ${_t:-0} + 7 )); echo "$_t" > "$T/clock"; echo "$_t"; }
_apps_stage_prog(){
  if [ -f "$STATE/appcode-pm-snapshot" ]; then
    stat -c %a "$STATE/appcode-pm-snapshot" > "$T/mode"
    cat "$STATE/appcode-pm-snapshot" > "$T/snap.copy"
  fi
  return 0
}
agent_stub(){
  local last a
  for a; do last=$a; done
  (cd "$last" && find . -name '*.apk' | LC_ALL=C sort) > "$T/stage.txt"
  cat "$last/manifest.tsv" > "$T/man.txt" 2>/dev/null
  if [ -e "$STATE/appcode-pm-snapshot" ]; then echo y; else echo n; fi > "$T/atpush"
  return 0
}
STUBS
  printf 'AGENT=agent_stub\n'
  printf 'timeout(){ shift 3; "$@"; }\n'
  printf 'keystore_register_all(){ :; }\n'
}

# run_seal <shell> <T> [extra stub text] [posix]: one appcode_seal over the tree in T. Leaves $T/res (its status),
# $T/pmsnap (PM_SNAP after it), $T/log and $T/dumpsys.calls.
run_seal(){
  local s=$1 T=$2
  : > "$T/log"; : > "$T/dumpsys.calls"; : > "$T/stage.txt"; : > "$T/man.txt"; rm -f "$T/mode" "$T/snap.copy" "$T/atpush" "$T/clock"; echo 9 > "$T/res"
  { head_lines "$T"; printf '%s\n' "${3:-}"; printf '%s\n' "$FUNCS"; printf 'appcode_seal; echo "$?" > "$T/res"; echo "[${PM_SNAP:-}]" > "$T/pmsnap"\n'; } > "$T/run.sh"
  # As test-appcode-stage-whole.sh does for its manifest cases: bash runs them as `bash --posix`.
  case "$s:${4:-}" in bash:posix) timeout 60 bash --posix "$T/run.sh" ;; *) timeout 60 "$s" "$T/run.sh" ;; esac >/dev/null 2>&1
}

mk_tree(){
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  case "$T" in *'*'*|*'?'*|*'['*|*/./*|*/../*) echo "refusing to run: scratch root $T holds a pattern byte or a dot segment" >&2; exit 2 ;; esac
  F="$T/user/com.nowhere.chooser/files"
  mkdir -p "$T/data/nowhere" "$T/data/app" "$T/state" "$F/nowhere-appmeta" "$T/dumps" "$T/blk" || exit 2
  : > "$F/nowhere-appcode.list"; : > "$F/nowhere-appkeep"
}
# mk_pkg <pkg> <dir> <flags> <vc>: a live code dir with one APK, and the package's block. mk_all joins blocks into .all.
mk_pkg(){
  local p=$1 d=$2 fl=$3 vc=$4
  mkdir -p "$d" || exit 2
  printf '%s-bytes' "$p" > "$d/base.apk"
  {
    printf '  Package [%s] (1a2b):\n    userId=10001\n    codePath=%s\n' "$p" "$d"
    printf '    versionCode=%s minSdk=26 targetSdk=34\n    flags=[ %s ]\n    privateFlags=[ PRIVATE_FLAG_ACTIVITIES ]\n' "$vc" "$fl"
  } > "$T/blk/$p"
  { printf 'Packages:\n'; cat "$T/blk/$p"; } > "$T/dumps/$p"
}
mk_all(){ local p; { printf 'Packages:\n'; for p in "$@"; do cat "$T/blk/$p"; done; } > "$T/dumps/.all"; }
live(){ printf '%s' "$T/data/app/~~x==/$1-1=="; }
# list_stale <pkg> <mode> [vc]: a code-list line whose only path is the previous session's.
list_stale(){ printf '%s\t%s\t0\t%s\t%s\n' "$1" "${3:-7}" "$2" "$T/data/app/~~old==/$1-1==/base.apk" >> "$F/nowhere-appcode.list"; }
meta(){ mkdir -p "$F/nowhere-appmeta/$1" || exit 2; printf 'vc\t%s\n' "$2" > "$F/nowhere-appmeta/$1/meta"; }
# Eight lookups: five installed with stale paths (live_code_dir), two on-demand with stale paths (live_code_ver: com.od1's
# meta vc is the live vc, so it stages; com.od2's differs, so it takes the carry), one keep-set-only (live_code_dir).
ALLPKGS="com.a com.b com.c com.d com.e com.od1 com.od2 com.k"
fixture(){
  local p
  for p in $ALLPKGS; do mk_pkg "$p" "$(live "$p")" 'HAS_CODE ALLOW_CLEAR_USER_DATA' 7; done
  for p in com.a com.b com.c com.d com.e; do list_stale "$p" installed; printf '%s\tinstalled\n' "$p" >> "$F/nowhere-appkeep"; done
  for p in com.od1 com.od2; do list_stale "$p" ondemand; printf '%s\tondemand\n' "$p" >> "$F/nowhere-appkeep"; done
  meta com.od1 7; meta com.od2 6
  printf 'com.k\tinstalled\n' >> "$F/nowhere-appkeep"
  # shellcheck disable=SC2086
  mk_all $ALLPKGS
}
EXPECT_STAGE='./com.a/base.apk
./com.b/base.apk
./com.c/base.apk
./com.d/base.apk
./com.e/base.apk
./com.k/base.apk
./com.od1/base.apk'
stage(){ cat "$T/stage.txt"; }
calls(){ cat "$T/dumpsys.calls"; }
# wants <lines>: the dumpsys calls are exactly the snapshot, then one own dump per package named, in any order.
wants(){
  local got exp p
  got=$(LC_ALL=C sort "$T/dumpsys.calls")
  exp=$({ echo 'package packages'; for p in "$@"; do echo "package $p"; done; } | LC_ALL=C sort)
  [ "$got" = "$exp" ]
}
snapline(){ grep '#apps pm snapshot' "$T/log"; }
stagedline(){ grep '#apps staged' "$T/log"; }
# parts <line>: "<total> <copy> <lookups> <n> <carry> <lists> <other>", or empty when the line does not have its shape.
parts(){
  printf '%s\n' "$1" | sed -nE 's|^\[roamd\] #apps staged [0-9]+ pkg\(s\), [0-9]* KiB, in ([0-9]+)ms \(copy ([0-9]+)ms, [0-9]+ mtime kept-failed, [0-9]+ reused\) \(NWP-20261005-04, NWP-20261123-02, NWP-20261128-09\) \(lookups ([0-9]+)ms/([0-9]+), carry ([0-9]+)ms, lists ([0-9]+)ms, other (-?[0-9]+)ms\) .*$|\1 \2 \3 \4 \5 \6 \7|p'
}

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"
  if want s1; then
    mk_tree; fixture
    run_seal "$s" "$T"
    if wants && [ "$(stage)" = "$EXPECT_STAGE" ] && [ "$(cat "$T/res")" = 0 ]; then ok "$t s1 a stage of 8 lookups calls dumpsys once and stages the same 7 packages"
    else no "$t s1 calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')] res [$(cat "$T/res")]"; fi
    # shellcheck disable=SC2030,SC2031
    S1STAGE=$(stage); S1MAN=$(cat "$T/man.txt")
  fi
  if want s2; then
    mk_tree; fixture
    # shellcheck disable=SC2086
    mk_all com.b com.c com.d com.e com.od2 com.k
    run_seal "$s" "$T"
    if wants com.a com.od1 && [ "$(stage)" = "$EXPECT_STAGE" ]; then ok "$t s2 a package missing from the snapshot falls back to its own dump, in both lookups"
    else no "$t s2 calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')]"; fi
  fi
  # shellcheck disable=SC2086
  if want s3a; then
    mk_tree; fixture
    : > "$T/dumps/.all"
    run_seal "$s" "$T"
    if wants $ALLPKGS && [ "$(stage)" = "$EXPECT_STAGE" ] && has "$(snapline)" 'none, empty dump -- per-package lookups' && [ ! -e "$T/state/appcode-pm-snapshot" ]; then
      ok "$t s3a an empty snapshot falls back for every package and stages the same set"
    else no "$t s3a calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')] line [$(snapline)]"; fi
    if [ -z "${S1STAGE:-}" ] || { [ "$(stage)" = "$S1STAGE" ] && [ "$(cat "$T/man.txt")" = "${S1MAN:-}" ]; }; then
      if [ -n "$(snapline)" ]; then ok "$t s3a the fallback's stage and manifest equal the snapshot's"; else no "$t s3a no snapshot line"; fi
    else no "$t s3a the fallback's stage or manifest differs from the snapshot's"; fi
  fi
  # shellcheck disable=SC2086
  if want s3b; then
    mk_tree; fixture
    : > "$T/dumps/.all"; echo 1 > "$T/dumps/.rc"
    run_seal "$s" "$T"
    if wants $ALLPKGS && [ "$(stage)" = "$EXPECT_STAGE" ] && has "$(snapline)" 'none, dump failed -- per-package lookups' && [ ! -e "$T/state/appcode-pm-snapshot" ]; then ok "$t s3b a failed snapshot falls back for every package and stages the same set"
    else no "$t s3b calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')] line [$(snapline)]"; fi
  fi
  # shellcheck disable=SC2086
  if want s3c; then
    mk_tree; fixture
    mkdir "$T/state/appcode-pm-snapshot" || exit 2
    run_seal "$s" "$T"
    if wants $ALLPKGS && [ "$(stage)" = "$EXPECT_STAGE" ] && has "$(snapline)" 'none, cannot write -- per-package lookups'; then ok "$t s3c a snapshot that cannot be written falls back for every package"
    else no "$t s3c calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')] line [$(snapline)]"; fi
  fi
  # shellcheck disable=SC2086
  if want s3d; then
    # Every row complete, then a non-zero exit: only the status says this dump cannot be trusted.
    mk_tree; fixture
    echo 1 > "$T/dumps/.rc"
    run_seal "$s" "$T"
    if wants $ALLPKGS && [ "$(stage)" = "$EXPECT_STAGE" ] && has "$(snapline)" 'none, dump failed -- per-package lookups' && [ ! -e "$T/state/appcode-pm-snapshot" ] && [ ! -e "$T/snap.copy" ]; then
      ok "$t s3d a dump that prints every row and then fails makes no snapshot: every package reads its own dump"
    else no "$t s3d calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')] line [$(snapline)]"; fi
  fi
  # shellcheck disable=SC2086
  if want s3e; then
    # The status line's own text inside the dump does not vouch for it: only the stream's last line counts.
    mk_tree; fixture
    printf 'nowhere-dump-rc=0\n' >> "$T/dumps/.all"; echo 1 > "$T/dumps/.rc"
    run_seal "$s" "$T"
    if wants $ALLPKGS && [ "$(stage)" = "$EXPECT_STAGE" ] && has "$(snapline)" 'none, dump failed -- per-package lookups'; then ok "$t s3e a failed dump whose text holds a status of 0 still makes no snapshot"
    else no "$t s3e calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')] line [$(snapline)]"; fi
  fi
  if want s4a; then
    mk_tree; fixture
    mk_pkg com.upd "$(live com.upd)" 'SYSTEM HAS_CODE UPDATED_SYSTEM_APP' 7
    printf 'com.upd\tinstalled\n' >> "$F/nowhere-appkeep"
    # shellcheck disable=SC2086
    mk_all $ALLPKGS com.upd
    run_seal "$s" "$T"
    if wants && [ "$(stage)" = "$EXPECT_STAGE" ]; then ok "$t s4a a SYSTEM UPDATED_SYSTEM_APP row with a /data/app dir is not staged, with no dump of its own"
    else no "$t s4a calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')]"; fi
  fi
  if want s4b; then
    mk_tree; fixture
    mk_pkg com.sysapp "$T/system/app/Clock" 'HAS_CODE' 7
    printf 'com.sysapp\tinstalled\n' >> "$F/nowhere-appkeep"
    # shellcheck disable=SC2086
    mk_all $ALLPKGS com.sysapp
    run_seal "$s" "$T"
    if wants && [ "$(stage)" = "$EXPECT_STAGE" ]; then ok "$t s4b a codePath outside /data/app (its dir exists, no SYSTEM flag) is not staged"
    else no "$t s4b calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')]"; fi
  fi
  if want s5; then
    mk_tree
    mk_pkg com.n "$(live com.n)" 'HAS_CODE' 7
    mk_pkg com.m "$(live com.m)" 'HAS_CODE' 2147483648
    mk_pkg com.h "$T/data/app/~~1==/com.h-1==" 'HAS_CODE' 3
    mk_pkg com.nv "$(live com.nv)" 'HAS_CODE' 5; sed -i '/versionCode=/d' "$T/blk/com.nv" "$T/dumps/com.nv"
    mk_pkg com.s "$T/system/app/S" 'HAS_CODE' 5
    mk_pkg com.u "$(live com.u)" 'SYSTEM HAS_CODE UPDATED_SYSTEM_APP' 11
    mk_pkg com.g "$(live com.g)" 'HAS_CODE' 8; rm -rf "$(live com.g)"
    # An updated app's hidden second block: the first block decides, in the dump and in the snapshot.
    mkdir -p "$T/data/app/~~2==/com.h-2==" || exit 2
    H2=$(printf '\nHidden system packages:\n  Package [com.h] (9):\n    codePath=%s\n    versionCode=9 minSdk=26\n    flags=[ SYSTEM ]\n' "$T/data/app/~~2==/com.h-2==")
    printf '%s\n' "$H2" >> "$T/dumps/com.h"
    mk_all com.n com.m com.h com.nv com.s com.u com.g
    printf '%s\n' "$H2" >> "$T/dumps/.all"
    {
      head_lines "$T"; printf '%s\n' "$FUNCS"
      cat <<'BODY'
answers(){
  local p
  for p in com.n com.m com.h com.nv com.s com.u com.g; do
    live_code_ver "$p"
    echo "$p|$_lcv_dir|$_lcv_vc|$(live_code_dir "$p")"
  done
}
appcode_pm_snapshot
[ -n "${PM_SNAP:-}" ] && echo built > "$T/built"
answers > "$T/cached"
cp "$T/dumpsys.calls" "$T/calls.cached"
PM_SNAP=""
answers > "$T/dump"
BODY
    } > "$T/run.sh"
    : > "$T/dumpsys.calls"; : > "$T/log"
    timeout 60 "$s" "$T/run.sh" >/dev/null 2>&1
    EXP="com.n|$(live com.n)|7|$(live com.n)
com.m|$(live com.m)|2147483648|$(live com.m)
com.h|$T/data/app/~~1==/com.h-1==|3|$T/data/app/~~1==/com.h-1==
com.nv|$(live com.nv)||$(live com.nv)
com.s||5|
com.u||11|
com.g||8|"
    if [ -f "$T/built" ] && [ "$(cat "$T/cached" 2>/dev/null)" = "$(cat "$T/dump" 2>/dev/null)" ] && [ "$(cat "$T/cached" 2>/dev/null)" = "$EXP" ]; then
      ok "$t s5 the snapshot's answers equal the per-package dump's on the same text (dir, versionCode, the three rules)"
    else no "$t s5 built [$(cat "$T/built" 2>/dev/null)] cached [$(tr '\n' ' ' < "$T/cached" 2>/dev/null)] dump [$(tr '\n' ' ' < "$T/dump" 2>/dev/null)]"; fi
    # com.nv has no versionCode and com.g's dir is gone: those two read their own dumps, twice each, and only those.
    got=$(LC_ALL=C sort -u "$T/calls.cached" 2>/dev/null | tr '\n' '|')
    if [ "$got" = 'package com.g|package com.nv|package packages|' ]; then ok "$t s5 only a package with no usable row reads its own dump"
    else no "$t s5 calls with a snapshot: [$got]"; fi
  fi
  if want s6a; then
    mk_tree; fixture
    run_seal "$s" "$T"
    if [ -s "$T/snap.copy" ] && [ "$(cat "$T/atpush" 2>/dev/null)" = n ] && [ ! -e "$T/state/appcode-pm-snapshot" ] && [ "$(cat "$T/pmsnap")" = '[]' ] && [ "$(cat "$T/res")" = 0 ]; then
      ok "$t s6a the snapshot exists during a stage, and is gone at the push and after it"
    else no "$t s6a copy $( [ -s "$T/snap.copy" ] && echo seen || echo none) atpush [$(cat "$T/atpush" 2>/dev/null)] left [$(ls -A "$T/state" | tr '\n' ' ')] PM_SNAP [$(cat "$T/pmsnap")] res [$(cat "$T/res")]"; fi
  fi
  if want s6b; then
    # Staged 0 with an installed-mode app wanted: the refusal that keeps the previous head.
    mk_tree
    mk_pkg com.other "$(live com.other)" 'HAS_CODE' 7
    mk_all com.other
    printf 'com.none\tinstalled\n' > "$F/nowhere-appkeep"
    run_seal "$s" "$T"
    if [ -s "$T/snap.copy" ] && [ ! -e "$T/state/appcode-pm-snapshot" ] && [ "$(cat "$T/res")" = 4 ]; then ok "$t s6b the snapshot is gone after the refusal that returns 4"
    else no "$t s6b copy $( [ -s "$T/snap.copy" ] && echo seen || echo none) left [$(ls -A "$T/state" | tr '\n' ' ')] res [$(cat "$T/res")]"; fi
  fi
  if want s6c; then
    # A full /data: each append to the manifest fails, so the stage refuses and returns 1.
    mk_tree; fixture
    run_seal "$s" "$T" 'printf(){
  if [ /dev/stdout -ef "$T/data/nowhere/appcode-stage/manifest.tsv" ]; then return 1; fi
  command printf "$@"
}' posix
    if [ -s "$T/snap.copy" ] && [ ! -e "$T/state/appcode-pm-snapshot" ] && [ "$(cat "$T/res")" = 1 ] && grep -q 'took no line' "$T/log"; then ok "$t s6c the snapshot is gone after the empty-manifest refusal that returns 1"
    else no "$t s6c copy $( [ -s "$T/snap.copy" ] && echo seen || echo none) left [$(ls -A "$T/state" | tr '\n' ' ')] res [$(cat "$T/res")]"; fi
  fi
  if want s6d; then
    mk_tree; fixture
    run_seal "$s" "$T"
    if [ "$(cat "$T/mode" 2>/dev/null)" = 600 ]; then ok "$t s6d the snapshot is mode 0600 during the stage (the run file's umask is 022)"
    else no "$t s6d mode [$(cat "$T/mode" 2>/dev/null)]"; fi
  fi
  if want s7a; then
    mk_tree; fixture
    run_seal "$s" "$T"
    P=$(parts "$(stagedline)")
    if [ -z "$P" ]; then no "$t s7a the staged line does not have its shape: [$(stagedline)]"
    else
      read -r P_T P_C P_L P_N P_K P_S P_O <<<"$P"
      if [ "$P_T" = "$(( P_C + P_L + P_K + P_S + P_O ))" ] && [ "$P_O" -ge 0 ]; then ok "$t s7a the staged line's parts sum to its total, and the remainder is not negative ($P)"
      else no "$t s7a parts [$P] do not sum to the total"; fi
    fi
  fi
  if want s7b; then
    mk_tree; fixture
    run_seal "$s" "$T"
    P=$(parts "$(stagedline)")
    read -r P_T P_C P_L P_N P_K P_S P_O <<<"${P:-0 0 0 0 0 0 0}"
    if [ "$P_N" = 8 ] && [ "$P_L" -gt 0 ] && [ "$P_K" -gt 0 ] && [ "$P_S" -gt 0 ]; then ok "$t s7b lookups, carry and lists each measure above zero, and the count is the 8 calls"
    else no "$t s7b parts [$P]"; fi
  fi
  if want s7c; then
    mk_tree; fixture
    run_seal "$s" "$T"
    L1=$(stagedline); L2=$(snapline)
    if [ -n "$L1" ] && [ -n "$L2" ] && ! has "$L1$L2" 'com.' && ! has "$L1$L2" 'probe' && ! has "$L1$L2" '/data'; then ok "$t s7c the staged and snapshot lines carry no package name, profile name or path"
    else no "$t s7c lines [$L1] [$L2]"; fi
  fi
  for c in s8a s8b; do
    if want "$c"; then
      # The dump ends inside com.upd's block: it was cut before, or inside, the flags line that says SYSTEM.
      mk_tree; fixture
      mk_pkg com.upd "$(live com.upd)" 'SYSTEM HAS_CODE UPDATED_SYSTEM_APP' 7
      printf 'com.upd\tinstalled\n' >> "$F/nowhere-appkeep"
      # shellcheck disable=SC2086
      mk_all $ALLPKGS
      sed -n '1,4p' "$T/blk/com.upd" >> "$T/dumps/.all"   # through its versionCode line, so only the flags can refuse it
      [ "$c" = s8a ] || printf '    flags=[ SYS' >> "$T/dumps/.all"
      run_seal "$s" "$T"
      if wants com.upd && [ "$(stage)" = "$EXPECT_STAGE" ]; then ok "$t $c a block cut before its closed flags line makes no row: its own dump says SYSTEM, it is not staged"
      else no "$t $c calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')]"; fi
    fi
  done
  if want s9; then
    # A first block with no flags line, then a whole hidden block of the same name: only the first block may answer.
    mk_tree; fixture
    H1="$T/data/app/~~1==/com.hid-1=="; H2="$T/data/app/~~2==/com.hid-2=="
    mkdir -p "$H1" "$H2" || exit 2
    printf 'first' > "$H1/base.apk"; printf 'hidden' > "$H2/hidden.apk"
    printf 'com.hid\tinstalled\n' >> "$F/nowhere-appkeep"
    BL=$(printf '  Package [com.hid] (1):\n    codePath=%s\n    versionCode=7 minSdk=26\n\nHidden system packages:\n  Package [com.hid] (2):\n    codePath=%s\n    versionCode=9 minSdk=26\n    flags=[ HAS_CODE ]\n' "$H1" "$H2")
    printf 'Packages:\n%s\n' "$BL" > "$T/dumps/com.hid"
    # shellcheck disable=SC2086
    mk_all $ALLPKGS
    printf '%s\n' "$BL" >> "$T/dumps/.all"
    run_seal "$s" "$T"
    if wants com.hid && has "$(stage)" './com.hid/base.apk' && ! has "$(stage)" 'hidden.apk'; then ok "$t s9 an incomplete first block makes no row, and its hidden block does not stand in for it"
    else no "$t s9 calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')]"; fi
  fi
  for c in s10a s10b; do
    if want "$c"; then
      # com.a's row names a dir the stage finds gone: an update moved it (s10a) or an uninstall removed it (s10b).
      mk_tree; fixture
      sed -i "s|codePath=$(live com.a)|codePath=$T/data/app/~~gone==/com.a-1==|" "$T/dumps/.all"
      if [ "$c" = s10b ]; then
        rm -f "$T/dumps/com.a"; rm -rf "$(live com.a)"
        EXP=$(printf '%s\n' "$EXPECT_STAGE" | grep -v '/com\.a/')
      else EXP=$EXPECT_STAGE; fi
      run_seal "$s" "$T"
      if wants com.a && [ "$(stage)" = "$EXP" ]; then ok "$t $c a row whose dir is gone reads the package's own dump, and stages what that dump says"
      else no "$t $c calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')]"; fi
    fi
  done
  if want s11; then
    # A dump far over the kernel's 128 KiB argument limit, the size class of VLC's alone (NWP-20261113-01).
    mk_tree; fixture
    FILLER=$(mktemp -p "$W") || exit 2
    awk 'BEGIN { for (i = 0; i < 9000; i++) print "        android.intent.action.VIEW: filler-line-with-no-field-of-note" }' > "$FILLER"
    # shellcheck disable=SC2086
    { printf 'Packages:\n'; cat "$FILLER"; for p in $ALLPKGS; do cat "$T/blk/$p"; cat "$FILLER"; done; } > "$T/dumps/.all"
    SZ=$(stat -c %s "$T/dumps/.all")
    run_seal "$s" "$T" 'printf() { local pa; for pa in "$@"; do [ "${#pa}" -gt 131072 ] && { echo "printf: Argument list too long" >&2; return 1; }; done; command printf "$@"; }'
    if [ "$SZ" -gt 307200 ] && wants && [ "$(stage)" = "$EXPECT_STAGE" ] && has "$(snapline)" ': 8 package(s) in '; then ok "$t s11 a dump of $SZ bytes is streamed: 8 rows, one call, the same stage"
    else no "$t s11 size $SZ calls [$(calls | tr '\n' '|')] stage [$(stage | tr '\n' ' ')] line [$(snapline)]"; fi
  fi
  if want s12; then
    mk_tree; fixture
    run_seal "$s" "$T"
    ROW=$(grep "^com\.a$(printf '\t')" "$T/snap.copy" 2>/dev/null)
    if has "$(snapline)" '#apps pm snapshot: 8 package(s) in ' && has "$(snapline)" 'ms (NWP-20261130-16) ' && [ "$(grep -c . "$T/snap.copy" 2>/dev/null)" = 8 ] \
       && [ "$ROW" = "$(printf 'com.a\t%s\t0\t7\t' "$(live com.a)")" ]; then ok "$t s12 the log names the rows and the ms, and a row is <pkg> TAB <codePath> TAB <SYSTEM> TAB <versionCode> TAB <lastUpdateTime>"
    else no "$t s12 line [$(snapline)] row [$ROW]"; fi
  fi
done

if want s13; then
  # The file names every installed package, and a killed seal leaves it, so the reap removes it with the seal's other lists.
  AT=$(grep -n '^  rm -rf /data/nowhere/appcode-dormant 2>>"\$LOG"' "$ROAMD" | cut -d: -f1)
  case "$AT" in ''|*[!0-9]*) echo "EXTRACTION FAILED: the reap's appcode-dormant line moved" >&2; exit 2 ;; esac
  NEXT=$(sed -n "$((AT+1))p" "$ROAMD")
  if has "$NEXT" 'rm -f "$STATE/appcode-pm-snapshot"'; then ok "[text] s13 the reap removes a killed seal's snapshot"
  else no "[text] s13 the line after the reap's appcode-dormant line is [$NEXT]"; fi
fi

if [ "$MUTATE" = yes ]; then
  echo "mutants (each must FAIL its target case under EACH shell):"
  MT=$(mktemp -d -p "$W") || exit 2
  mut(){ # mut <label> <target case> <sed script> [text]
    local rc sh bad="" tags
    sed -e "$3" "$ROAMD" > "$MT/roamd.sh"
    if cmp -s "$ROAMD" "$MT/roamd.sh"; then no "MUTANT DID NOT APPLY: $1"; return; fi
    ROAMD="$MT/roamd.sh" ONLY="$2" bash "$0" > "$MT/out" 2>&1; rc=$?
    tags=$SHELLS; [ "${4:-}" != text ] || tags=text
    for sh in $tags; do grep -q "FAIL  \[$sh\] $2 " "$MT/out" || bad="$bad $sh"; done
    if grep -q 'EXTRACTION FAILED' "$MT/out"; then no "MUTANT BROKE EXTRACTION: $1"
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted by $2 ($(printf '%s' "$tags" | sed 's/^ //')): $1"
    else no "NOT CONVICTED by $2 (rc $rc, no FAIL line for:$bad): $1"; fi
  }
  FB_DIR='s/^    lout=\$(dumpsys package "\$1" 2>\/dev\/null | awk /    lout=$(: | awk /'
  FB_VER='s/^    lcv_out=\$(dumpsys package "\$1" 2>\/dev\/null | awk /    lcv_out=$(: | awk /'
  RM_SNAP='/^  \[ -z "\${PM_SNAP:-}" \] || rm -f "\$PM_SNAP"; PM_SNAP=""$/d'
  NOCLOSE='s/ \&\& f ~ \/flags=\\\[\.\*\\\]\/ \&\& / \&\& /'
  mut "M1a the fallback removed from live_code_dir" s2 "$FB_DIR"
  mut "M1b the fallback removed from live_code_ver" s2 "$FB_VER"
  mut "M2a the SYSTEM rule dropped from the snapshot row" s4a 's/(index(f, " SYSTEM ") > 0)/0/'
  mut "M2b the SYSTEM rule dropped from live_code_dir's cached path" s4a 's/^    lcd=\$_pms_dir; lflags=""; \[ "\$_pms_sys" = 0 \] || lflags=" SYSTEM "$/    lcd=$_pms_dir; lflags=""/'
  mut "M2c the SYSTEM rule dropped from live_code_ver's cached path" s5 's/; lcv_f=""; \[ "\$_pms_sys" = 0 \] || lcv_f=" SYSTEM "$/; lcv_f=""/'
  mut "M2d the /data/app rule dropped from the shared path" s4b '/^live_code_dir() {$/,/^}$/{/^  case "\$lcd" in \/data\/app\/\*) ;; \*) return 0 ;; esac$/d}'
  mut "M3a the snapshot file left behind (a stage that succeeds)" s6a "$RM_SNAP"
  mut "M3b the snapshot file left behind (the refusal that returns 4)" s6b "$RM_SNAP"
  mut "M3c the snapshot file left behind (the refusal that returns 1)" s6c "$RM_SNAP"
  mut "M4 an empty snapshot read as not installed" s3a '/^  if \[ -z "\$aps_why" \] && \[ ! -s "\$aps_f" \]; then aps_why="empty dump"; fi$/d; /^appcode_pm_row() {$/,/^}$/{/^  case "\$_pms_sys" in 0|1) ;; \*) return 1 ;; esac$/d; /^  case "\$_pms_vc" in .*esac$/d; s/^  \[ -n "\$_pms_dir" \] && \[ -d "\$_pms_dir" \]$/  _pms_sys=0; return 0/}'
  mut "M5a the lookups field dropped" s7a 's/ (lookups \${_acw_lms}ms\/\$_acw_lct, carry/ (carry/'
  mut "M5b the carry field dropped" s7a 's/, carry \${_acw_kms}ms, lists/, lists/'
  mut "M5c the lists field dropped" s7a 's/, lists \${_acw_sms}ms, other/, other/'
  mut "M5d the other field dropped" s7a 's/, other \${_stg_oth}ms)/)/'
  mut "M5e the remainder forgets the carry" s7a 's/^  _stg_oth=\$(( _stg_ms - _acw_cms - _acw_lms - _acw_kms - _acw_sms ))$/  _stg_oth=$(( _stg_ms - _acw_cms - _acw_lms - _acw_sms ))/'
  mut "M5f the code-list loop's lookups are not counted" s7b 's/^      _acw_t0=\$(_ms); cdir=\$(live_code_dir "\$pkg"); _acw_lms=\$((_acw_lms + \$(_ms) - _acw_t0)); _acw_lct=\$((_acw_lct+1))$/      _acw_t0=$(_ms); cdir=$(live_code_dir "$pkg"); _acw_lms=$((_acw_lms + $(_ms) - _acw_t0))/'
  mut "M6a a block with no flags line makes a row" s8a "$NOCLOSE"
  mut "M6b a block with a cut flags line makes a row" s8b "$NOCLOSE"
  mut "M7 the dir check removed from appcode_pm_row" s10a 's/^  \[ -n "\$_pms_dir" \] && \[ -d "\$_pms_dir" \]$/  [ -n "$_pms_dir" ]/'
  mut "M8 the umask removed" s6d 's/^  ( umask 077; { dumpsys package packages /  ( { dumpsys package packages /'
  mut "M9 a name is marked seen only when its row is written" s9 's/^      if (!(m in seen)) { seen\[m\] = 1; n = m }$/      if (!(m in seen)) n = m/; s/^      n = ""$/      if (n != "" \&\& f ~ \/flags=\/) seen[n] = 1; n = ""/'
  mut "M10 the dump held in a shell value" s11 's/^  ( umask 077; { dumpsys package packages 2>\/dev\/null; printf .* | awk /  ( umask 077; aps_d=$(dumpsys package packages 2>\/dev\/null); aps_s=$?; printf "%s\\n\\nnowhere-dump-rc=%s\\n" "$aps_d" "$aps_s" | awk /'
  mut "M12a dumpsys's status not checked" s3d 's/; if (l != "nowhere-dump-rc=0") exit 3 }/ }/'
  mut "M12b the awk's refusal read as a success" s3d 's/^  case "\$aps_rc" in 0) ;; 3) aps_why="dump failed" ;; \*) aps_why="cannot write" ;; esac$/  case "$aps_rc" in 0|3) ;; *) aps_why="cannot write" ;; esac/'
  mut "M12c the status line anywhere in the dump counts" s3e 's/^    { l = \$0 }$/    \/^nowhere-dump-rc=0$\/ { l = $0 }/'
  mut "M12d the status line not on a line of its own" s8b "s/printf '\\\\nnowhere-dump-rc=/printf 'nowhere-dump-rc=/"
  mut "M11 the reap line removed" s13 '/^  \[ -z "\${STATE:-}" \] || rm -f "\$STATE\/appcode-pm-snapshot" 2>>"\$LOG"/d' text
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
