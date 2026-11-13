#!/usr/bin/env bash
# test-appcode-droplists.sh [--mutate] -- NWP-20261128-26: appcode_seal removes its drop lists on every return.
#
# WHY THIS IS COMMITTED. appcode_seal builds /data/nowhere/appcode-dropoff (the Off record's packages in the drop
# list), appcode-dropfilter (that list less the inferred orphans) and appcode-dropgone (the uninstalled subset) from
# the chooser's lists. They name the apps the profile switched Off or uninstalled, and /data/nowhere is outside every
# per-user key. Only the path that reached the push removed them. Four returns left them on /data across a sign-out
# and a power-off: the stage that cannot be created (1), the manifest that cannot be created (1), the manifest that
# took no line (1) and the staged-0 refusal that keeps the previous head (4). staging_boot sweeps the three names, but
# it keeps them while a session marker, reap credentials or a users/<n> record stands, so it is a backstop for a
# killed op only. Now each of the four returns removes the three lists.
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with qn, pw, pkgname_ok, appcode_stage_play_dormant,
# live_code_dir, stage_apk_copy, stage_live_apks and stage_keep_mtimes), every /data/ path pointed into a scratch root. `$AGENT` is a
# stub that records the push and whether NOWHERE_GONE_LIST is a non-empty file at push time. Every case plants an Off
# record of two apps (one of them also uninstalled) and a keep-code list naming a third app, so all three lists are
# built. POSITIVE CONTROL in every case: the log holds the "code-dropped pkg(s) were uninstalled" line.
#
#   D1 the staged-0 refusal (one kept installed app, no code dir): returns 4, no list left
#   D2 the stage cannot be created (a mkdir wrapper refuses the stage path): returns 1, no list left
#   D3 the manifest cannot be created (a directory planted at <stage>/manifest.tsv): returns 1, no list left
#   D4 a normal push: returns 0, the push sees a non-empty gone list, no list left (unchanged behaviour)
#   D5 the manifest takes no line (every write to it fails): returns 1, no list left
#
#   M1 the rm removed from the return-4 path (D1)        M2 from the stage-create path (D2)
#   M3 from the manifest-create path (D3)                M4 the gone list removed before the push ladder (D4)
#   M5 from the empty-manifest path (D5)
#
#   bash test-appcode-droplists.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-droplists.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
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
for fn in qn pw pkgname_ok appcode_stage_play_dormant live_code_dir stage_apk_copy stage_live_apks stage_keep_mtimes appcode_inputs_fp appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in "$fn() {"*'}') FUNCS="$FUNCS$body
" ;; *) echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;; esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

LISTS='appcode-dropoff appcode-dropfilter appcode-dropgone appcode-playstack appcode-playfilter appcode-defer appcode-stage'

# seal_case <shell> <case: D1..D5>
# Sets RES (appcode_seal's status), NCALLS (the stub's push count), GONE (y/n: the gone list was a non-empty file at
# push time), LOGTXT, and LEFT (each name of $LISTS that still exists under $T/data/nowhere).
seal_case(){
  local T F K f
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  case "$T" in *'*'*|*'?'*|*'['*|*/./*|*/../*) echo "refusing to run: scratch root $T holds a pattern byte or a dot segment" >&2; exit 2 ;; esac
  F="$T/user/com.nowhere.chooser/files"
  K="$T/data/app/~~k==/com.ex.k-1=="
  mkdir -p "$T/data/nowhere" "$F" "$T/dumps" "$K"
  printf 'k-base-apk-bytes-0123456789' > "$K/base.apk"
  printf 'com.ex.off\ncom.ex.gone\n' > "$F/nowhere-appdrop.list"
  printf 'com.ex.off\ncom.ex.gone\n' > "$F/nowhere-appoff.list"
  printf 'com.ex.gone\n' > "$F/nowhere-appgone.list"
  printf 'com.ex.orphan\n' > "$F/nowhere-appkeepcode.list"
  printf 'com.ex.k\tinstalled\n' > "$F/nowhere-appkeep"
  case "$2" in
    D4|D5) printf 'com.ex.k\t1\t0\tinstalled\t%s\n' "$K/base.apk" > "$F/nowhere-appcode.list" ;;
  esac
  : > "$T/calls"
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'T=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=0\n' "$T"
    cat <<'STUBS'
dumpsys(){ [ "$1" = package ] && [ -f "$T/dumps/$2" ] && cat "$T/dumps/$2"; return 0; }
agent_stub(){
  echo push >> "$T/calls"
  if [ -s "${NOWHERE_GONE_LIST:-}" ]; then echo y; else echo n; fi > "$T/gone"
  return 0
}
STUBS
    case "$2" in
      D2) cat <<'STUBS'
mkdir(){
  local last a
  for a; do last=$a; done
  [ "$last" = "$T/data/nowhere/appcode-stage" ] && return 1
  command mkdir "$@"
}
STUBS
      ;;
      D3) cat <<'STUBS'
mkdir(){
  local last a
  command mkdir "$@" || return
  for a; do last=$a; done
  [ "$last" = "$T/data/nowhere/appcode-stage" ] || return 0
  command mkdir "$last/manifest.tsv"
  return 0
}
STUBS
      ;;
      D5) cat <<'STUBS'
printf(){
  if [ /dev/stdout -ef "$T/data/nowhere/appcode-stage/manifest.tsv" ]; then return 1; fi
  command printf "$@"
}
STUBS
      ;;
    esac
    printf 'AGENT=agent_stub\n'
    printf 'timeout(){ shift 3; "$@"; }\n'
    printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _ms(){ echo 0; }; _apps_stage_prog(){ :; }\n'
    printf '%s\n' "$FUNCS"
    printf 'appcode_seal; echo "$?" > "$T/res"\n'
  } > "$T/run.sh"
  # As test-appcode-stage-whole.sh does for its manifest cases: bash runs them as `bash --posix`.
  case "$1:$2" in bash:D3|bash:D5) bash --posix "$T/run.sh" ;; *) "$1" "$T/run.sh" ;; esac >/dev/null 2>&1
  RES=$(cat "$T/res" 2>/dev/null)
  NCALLS=$(grep -c . "$T/calls"); GONE=$(cat "$T/gone" 2>/dev/null); LOGTXT=$(cat "$T/log" 2>/dev/null)
  LEFT=""
  for f in $LISTS; do
    if [ -e "$T/data/nowhere/$f" ] || [ -L "$T/data/nowhere/$f" ]; then LEFT="$LEFT $f"; fi
  done
  rm -rf "$T"
}

has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
CONTROL='code-dropped pkg(s) were uninstalled'

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"

  seal_case "$s" D1
  if ! has "$LOGTXT" "$CONTROL"; then no "$t D1 POSITIVE CONTROL: the fixture built no gone list -> log [$LOGTXT]"
  elif [ "$RES" = 4 ] && [ "$NCALLS" = 0 ] && has "$LOGTXT" '#apps SKIPPED: staged 0 apk' && [ -z "$LEFT" ]; then
    ok "$t D1 the staged-0 refusal returns 4 and leaves no drop list"
  else no "$t D1 staged-0 -> rc [$RES], $NCALLS push(es), left [$LEFT]"; fi

  seal_case "$s" D2
  if ! has "$LOGTXT" "$CONTROL"; then no "$t D2 POSITIVE CONTROL: the fixture built no gone list -> log [$LOGTXT]"
  elif [ "$RES" = 1 ] && [ "$NCALLS" = 0 ] && has "$LOGTXT" '#apps cannot create the stage -- NOT SEALED' && [ -z "$LEFT" ]; then
    ok "$t D2 a stage that cannot be created returns 1 and leaves no drop list"
  else no "$t D2 stage create -> rc [$RES], $NCALLS push(es), left [$LEFT]"; fi

  seal_case "$s" D3
  if ! has "$LOGTXT" "$CONTROL"; then no "$t D3 POSITIVE CONTROL: the fixture built no gone list -> log [$LOGTXT]"
  elif [ "$RES" = 1 ] && [ "$NCALLS" = 0 ] && has "$LOGTXT" "cannot create the stage's manifest -- NOT SEALED" && [ -z "$LEFT" ]; then
    ok "$t D3 a manifest that cannot be created returns 1 and leaves no drop list"
  else no "$t D3 manifest create -> rc [$RES], $NCALLS push(es), left [$LEFT]"; fi

  seal_case "$s" D4
  if ! has "$LOGTXT" "$CONTROL"; then no "$t D4 POSITIVE CONTROL: the fixture built no gone list -> log [$LOGTXT]"
  elif [ "$RES" = 0 ] && [ "$NCALLS" = 1 ] && [ "$GONE" = y ] && has "$LOGTXT" '#apps sealed' && [ -z "$LEFT" ]; then
    ok "$t D4 a normal push sees the gone list, returns 0 and leaves no drop list"
  else no "$t D4 push -> rc [$RES], $NCALLS push(es), gone list at push [$GONE], left [$LEFT]"; fi

  seal_case "$s" D5
  if ! has "$LOGTXT" "$CONTROL"; then no "$t D5 POSITIVE CONTROL: the fixture built no gone list -> log [$LOGTXT]"
  elif [ "$RES" = 1 ] && [ "$NCALLS" = 0 ] && has "$LOGTXT" "took no line -- NOT SEALED" && [ -z "$LEFT" ]; then
    ok "$t D5 a manifest that takes no line returns 1 and leaves no drop list"
  else no "$t D5 empty manifest -> rc [$RES], $NCALLS push(es), left [$LEFT]"; fi
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
  RMS='rm -f "\$DROPFILTER" "\$DROPOFF" "\$DROPGONE" 2>\/dev\/null'
  mut "M1 the rm removed from the return-4 path (D1)" '/SKIPPED: staged 0 apk/,/return 4/{/^    '"$RMS"'$/d;}'
  mut "M2 the rm removed from the stage-create path (D2)" '/#apps cannot create the stage -- NOT SEALED/s/'"$RMS"'; //'
  mut "M3 the rm removed from the manifest-create path (D3)" '/#apps cannot create the stage'"'"'s manifest -- NOT SEALED/s/'"$RMS"'; //'
  mut "M4 the gone list removed before the push ladder (D4)" 's/^  ret=124; try=0$/  rm -f "$DROPGONE"\n&/'
  mut "M5 the rm removed from the empty-manifest path (D5)" '/the stage'"'"'s manifest took no line -- NOT SEALED/s/'"$RMS"'; //'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
