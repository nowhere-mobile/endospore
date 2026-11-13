#!/usr/bin/env bash
# test-appcode-unchanged-skip.sh [--mutate] -- NWP-20261202-07: a periodic #apps seal whose inputs match the last landed
# seal skips its stage and push.
#
# WHY THIS IS COMMITTED. Backlog row "Every periodic seal spends 4-6 minutes staging `#apps` for an unchanged 743 KiB
# push, and holds the RW worker slot the whole time", and its sibling "A periodic seal's `#apps` stage spends about
# 85-124 s on frankel besides copying, which round 50's copy reuse does not remove". On frankel every periodic
# `#apps staged 49 pkg(s)` took 116-133 s, and the push after it reported `49 of 49 group(s) reused`. Now
# appcode_inputs_fp hashes everything the stage is built from (the lists, the meta dir's names, sizes and mtimes, and
# the PackageManager snapshot with each package's codePath, versionCode and lastUpdateTime), a landed periodic or
# manual seal records that hash in the pool's .landed, and the next periodic seal with the same hash returns at once,
# at most APPCODE_SKIP_MAX times in a row. Nothing fails when the skip regresses: the seal only gets slow again. When it
# skips WRONGLY, a changed app never reaches the store, so this suite also pins every input it must see, and who may
# never skip (a sign-out, Back up now, a failed dump, a failed push, a link, another uid's pool).
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with appcode_pm_snapshot, appcode_inputs_fp and the
# staging helpers), every /data/ path pointed into a scratch root. `dumpsys package packages` reads $T/dumps/.all and
# returns the status in $T/dumps/.rc when that file exists; `dumpsys package <pkg>` reads $T/dumps/<pkg>. `$AGENT`
# appends one line to $T/pushes per call, writes a NON-zero pushstat, and exits with $T/agent.rc when it exists.
#
#   bash test-appcode-unchanged-skip.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-unchanged-skip.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
#   ONLY="u1 u6" ROAMD=<file> bash test-appcode-unchanged-skip.sh   # a subset, e.g. against an older roamd
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
ONLY="${ONLY:-u1 u2a u2b u2c u2d u2e u3 u4a u4b u4c u5 u6 u7a u7b u8}"
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
    *) # This slice's helper: an older roamd has none, and must still run (and fail) the cases.
       [ "$fn" = appcode_inputs_fp ] && continue
       echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;;
  esac
done
# The cap is a top-level assignment. An older roamd has none: the cases run without it, and fail.
SKIPMAX=$(grep -m1 '^APPCODE_SKIP_MAX=' "$ROAMD")
FUNCS=$(printf '%s\n%s\n' "$SKIPMAX" "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# head_lines <T> <skind>: the shell prologue every run file shares (stubs, then the lifted functions).
head_lines(){
  printf '%s\n' "$PRINT_SHIM"
  printf 'umask 022\n'
  printf 'T=%s; LOG=$T/log; USERDIR=$T/user; STATE=$T/state; name=probe; pass=x; uid=12; NOWHERE_CARRY_ESSENTIAL=1\n' "$1"
  printf 'skind=%s\n' "$2"
  cat <<'STUBS'
dumpsys(){
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
_apps_stage_prog(){ :; }
agent_stub(){
  echo push >> "$T/pushes"
  [ -z "${NOWHERE_PUSH_STAT:-}" ] || echo 'kib=5 up=1 local=0' > "$NOWHERE_PUSH_STAT"
  [ ! -f "$T/agent.rc" ] || return "$(cat "$T/agent.rc")"
  return 0
}
STUBS
  printf 'AGENT=agent_stub\n'
  printf 'timeout(){ shift 3; "$@"; }\n'
  printf 'keystore_register_all(){ :; }\n'
  printf '%s\n' "$FUNCS"
}

# seal <skind>: one appcode_seal (uid 12) over the tree in T, under shell $s. Leaves $T/res (its status), $T/pms
# (APPCODE_PUSH_MS), $T/pstat (the pushstat it left, or nothing), $T/log (this seal's log) and $T/npush (pushes so far).
seal(){
  : > "$T/log"; echo 9 > "$T/res"; rm -f "$T/state/pushstat.apps" "$T/pstat"
  { head_lines "$T" "$1"; printf 'appcode_seal; echo "$?" > "$T/res"; echo "${APPCODE_PUSH_MS:-}" > "$T/pms"\n'; } > "$T/run.sh"
  timeout 60 "$s" "$T/run.sh" >/dev/null 2>&1
  [ ! -f "$T/state/pushstat.apps" ] || cp "$T/state/pushstat.apps" "$T/pstat"
  grep -c . "$T/pushes" > "$T/npush" 2>/dev/null
}
npush(){ cat "$T/npush" 2>/dev/null; }
skipline(){ grep '#apps unchanged since the last landed seal' "$T/log" 2>/dev/null; }
landed(){ cat "$P/.landed" 2>/dev/null; }
# leftover: anything in $T/state but the pushstat and pw's passphrase files (the agent removes those, the stub does not):
# the snapshot and the fingerprint's work files must be gone.
leftover(){ (cd "$T/state" && find . -mindepth 1 ! -name pushstat.apps ! -name '.pw.roamd*' | LC_ALL=C sort); }

LUT_A='2026-11-09 08:00:01'; LUT_B='2026-11-09 08:00:02'
mk_blk(){ # mk_blk <pkg> <codePath> <lastUpdateTime>
  printf '  Package [%s] (1):\n    codePath=%s\n    versionCode=7 minSdk=26 targetSdk=34\n    flags=[ HAS_CODE ]\n    timeStamp=2026-11-01 00:00:00\n    lastUpdateTime=%s\n' "$1" "$2" "$3" > "$T/blk/$1"
  { printf 'Packages:\n'; cat "$T/blk/$1"; } > "$T/dumps/$1"
}
mk_all(){ { printf 'Packages:\n'; cat "$T/blk/com.a" "$T/blk/com.b"; } > "$T/dumps/.all"; }
mk_tree(){
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  F="$T/user/com.nowhere.chooser/files"; P="$T/data/nowhere/appcode-reuse"
  A="$T/data/app/~~a==/com.a-1=="; B="$T/data/app/~~b==/com.b-1=="
  mkdir -p "$T/data/nowhere" "$A" "$B" "$T/state" "$F/nowhere-appmeta/com.a" "$T/dumps" "$T/blk" || exit 2
  printf 'com.a-base-0123456789' > "$A/base.apk"; printf 'com.b-base-0123456789' > "$B/base.apk"
  touch -d '2026-11-01 00:00:00' "$A/base.apk" "$B/base.apk" || exit 2
  mk_blk com.a "$A" "$LUT_A"; mk_blk com.b "$B" "$LUT_B"; mk_all
  printf 'com.a\t7\t0\tinstalled\t%s\ncom.b\t7\t0\tinstalled\t%s\n' "$A/base.apk" "$B/base.apk" > "$F/nowhere-appcode.list"
  printf 'com.a\tinstalled\ncom.b\tinstalled\n' > "$F/nowhere-appkeep"
  : > "$F/nowhere-appoff.list"
  printf 'meta' > "$F/nowhere-appmeta/com.a/_meta"
  touch -d '2026-11-02 00:00:00' "$F/nowhere-appmeta/com.a/_meta" || exit 2
}

for s in $SHELLS; do
  t="[$s]"
  if want u1; then
    mk_tree; seal ""; L1=$(landed); seal ""
    if [ "$(npush)" = 1 ] && [ "$(cat "$T/res")" = 0 ] && [ "$(cat "$T/pstat" 2>/dev/null)" = 'kib=0 up=0 local=0' ] \
       && [ "$(cat "$T/pms")" = 0 ] && [ -f "$P/com.a/base.apk" ] && [ -f "$P/com.b/base.apk" ] \
       && has "$(skipline)" '(skip 1 of 5) -- stage and push skipped in ' && [ -z "$(leftover)" ] \
       && [ "${L1% *}" = "$(landed | cut -d' ' -f1)" ] && [ "${L1#* }" = 0 ] && [ "$(landed | cut -d' ' -f2)" = 1 ]; then
      ok "$t u1 the second of two periodic seals with the same inputs: no push, status 0, a zero pushstat, the pool's APKs kept, the skip line"
    else no "$t u1 pushes [$(npush)] res [$(cat "$T/res")] pstat [$(cat "$T/pstat" 2>/dev/null)] pms [$(cat "$T/pms")] landed [$L1 -> $(landed)] skip [$(skipline)] left [$(leftover | tr '\n' ' ')] pool [$(ls -A "$P" 2>/dev/null | tr '\n' ' ')]"; fi
  fi
  for c in u2a u2b u2c u2d u2e; do
    if want "$c"; then
      mk_tree; seal ""; L1=$(landed)
      case "$c" in
        u2a) what="a lastUpdateTime only"; mk_blk com.a "$A" '2026-11-09 09:30:00'; mk_all ;;
        u2b) what="a codePath"; A2="$T/data/app/~~a2==/com.a-2=="; mkdir -p "$A2" && cp -p "$A/base.apk" "$A2/base.apk" && rm -rf "$A" || exit 2
             mk_blk com.a "$A2" "$LUT_A"; mk_all ;;
        u2c) what="a keep-set mode (the code list unchanged)"; printf 'com.a\tinstalled\ncom.b\tondemand\n' > "$F/nowhere-appkeep" ;;
        u2d) what="the Off list"; printf 'com.z\n' > "$F/nowhere-appoff.list" ;;
        u2e) what="a _meta file's mtime"; touch -d '2026-11-03 00:00:00' "$F/nowhere-appmeta/com.a/_meta" || exit 2 ;;
      esac
      seal ""
      if [ -n "$L1" ] && [ "$(npush)" = 2 ] && [ -z "$(skipline)" ] && [ "$(cat "$T/res")" = 0 ]; then ok "$t $c $what changed between two periodic seals: the second stages and pushes"
      else no "$t $c ($what) landed after the first [$L1] pushes [$(npush)] skip [$(skipline)] res [$(cat "$T/res")]"; fi
    fi
  done
  if want u3; then
    mk_tree; echo 1 > "$T/agent.rc"; seal ""; L1=$(landed); N1=$(npush); rm -f "$T/agent.rc"; seal ""
    if [ -z "$L1" ] && [ "$N1" -ge 1 ] && [ "$(npush)" -gt "$N1" ] && [ -z "$(skipline)" ] && [ "$(landed | cut -d' ' -f2)" = 0 ]; then
      ok "$t u3 a failed push leaves no .landed, so the next seal pushes, and records its own"
    else no "$t u3 landed after the failed seal [$L1] pushes [$N1 -> $(npush)] skip [$(skipline)] landed [$(landed)]"; fi
  fi
  for c in u4a:manual u4b:logoff u4c:logoff-pinned; do
    k=${c#*:}; c=${c%%:*}
    if want "$c"; then
      mk_tree; seal ""; L1=$(landed); seal "$k"
      if [ -n "$L1" ] && [ "$(npush)" = 2 ] && [ -z "$(skipline)" ]; then ok "$t $c a $k seal after a landed periodic seal with the same inputs stages and pushes"
      else no "$t $c ($k) landed after the first [$L1] pushes [$(npush)] skip [$(skipline)]"; fi
    fi
  done
  if want u5; then
    mk_tree; echo 1 > "$T/dumps/.rc"; seal ""; L1=$(landed); seal ""
    if [ -z "$L1" ] && [ -z "$(landed)" ] && [ "$(npush)" = 2 ] && [ -z "$(skipline)" ] && [ -z "$(leftover)" ]; then
      ok "$t u5 a failed dump at both seals: both push, and neither writes .landed"
    else no "$t u5 landed [$L1 / $(landed)] pushes [$(npush)] skip [$(skipline)] left [$(leftover | tr '\n' ' ')]"; fi
  fi
  if want u6; then
    mk_tree; R=""; i=0
    while [ "$i" -lt 8 ]; do
      i=$((i + 1)); seal ""; R="$R $(npush)"
      [ "$i" = 6 ] && S6=$(skipline); [ "$i" = 8 ] && S8=$(skipline)
    done
    if [ "$R" = " 1 1 1 1 1 1 2 2" ] && has "$S6" '(skip 5 of 5)' && has "$S8" '(skip 1 of 5)'; then
      ok "$t u6 five skips in a row, then the sixth match stages and pushes, and the count starts again"
    else no "$t u6 pushes after each seal [$R] seal 6 [$S6] seal 8 [$S8]"; fi
  fi
  if want u7a; then
    mk_tree; seal ""; L1=$(landed)
    if [ -n "$L1" ]; then cp "$P/.landed" "$T/landed.copy" && rm -f "$P/.landed" && ln -s "$T/landed.copy" "$P/.landed" || exit 2; fi
    seal ""
    if [ -n "$L1" ] && [ "$(npush)" = 2 ] && [ -z "$(skipline)" ]; then ok "$t u7a a .landed that is a link to a matching file gives no skip"
    else no "$t u7a landed [$L1] pushes [$(npush)] skip [$(skipline)]"; fi
  fi
  if want u7b; then
    mk_tree; seal ""; L1=$(landed); [ ! -d "$P" ] || echo 13 > "$P/.uid"; seal ""
    if [ -n "$L1" ] && [ "$(npush)" = 2 ] && [ -z "$(skipline)" ]; then ok "$t u7b a pool of another uid with a matching .landed gives no skip"
    else no "$t u7b landed [$L1] pushes [$(npush)] skip [$(skipline)]"; fi
  fi
  if want u8; then
    mk_tree; seal ""; seal ""; SL=$(skipline)
    if [ -n "$SL" ] && ! has "$SL" 'com.' && ! has "$SL" 'probe' && ! has "$SL" "$T" && has "$SL" '(NWP-20261202-07)'; then
      ok "$t u8 the skip line is counts only: no package, no profile, no path"
    else no "$t u8 skip line [$SL]"; fi
  fi
done

if [ "$MUTATE" = yes ]; then
  echo "mutants (each must FAIL its target case under EACH shell):"
  MT=$(mktemp -d -p "$W") || exit 2
  mut(){ # mut <label> <target case> <sed script>
    local rc sh bad=""
    sed -e "$3" "$ROAMD" > "$MT/roamd.sh"
    if cmp -s "$ROAMD" "$MT/roamd.sh"; then no "MUTANT DID NOT APPLY: $1"; return; fi
    ROAMD="$MT/roamd.sh" ONLY="$2" bash "$0" > "$MT/out" 2>&1; rc=$?
    for sh in $SHELLS; do grep -q "FAIL  \[$sh\] $2 " "$MT/out" || bad="$bad $sh"; done
    if grep -q 'EXTRACTION FAILED' "$MT/out"; then no "MUTANT BROKE EXTRACTION: $1"
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted by $2 ($(printf '%s' "$SHELLS" | sed 's/^ //')): $1"
    else no "NOT CONVICTED by $2 (rc $rc, no FAIL line for:$bad): $1"; fi
  }
  mut "M1 the skip branch deleted (u1: no push on the second seal)" u1 \
    's/^  if \[ -z "\${skind:-}" \] \\$/  if false \&\& [ -z "${skind:-}" ] \\/'
  mut "M2 lastUpdateTime dropped from the snapshot's awk (u2a: the second seal pushes)" u2a \
    '/^    !t \&\& \/(^|\[ \\t\])lastUpdateTime=\/ { t = 1; /d'
  mut "M3 the keep-set left out of the fingerprint (u2c: the second seal pushes)" u2c \
    's/^  for aif_f in "\$AL" "\$AK" /  for aif_f in "$AL" /'
  mut "M4 .landed written whatever the push did (u3: no .landed after a failed push)" u3 \
    's/^              \[ "\$ret" = 0 \] \&\& \[ -n "\$_acw_fp" \] /              [ -n "$_acw_fp" ] /'
  mut "M5 the skind test deleted (u4a: a manual seal pushes)" u4a \
    's/^  if \[ -z "\${skind:-}" \] \\$/  if true \\/'
  mut "M6 an empty snapshot fingerprinted (u5: no .landed after a failed dump)" u5 \
    '/^  \[ -n "\${PM_SNAP:-}" \] \&\& \[ -f "\$PM_SNAP" \] \&\& \[ ! -L "\$PM_SNAP" \] || return 1$/d; s/LC_ALL=C sort "\$PM_SNAP" >> "\$aif_w"/LC_ALL=C sort "${PM_SNAP:-\/dev\/null}" >> "$aif_w"/'
  mut "M7 the skip cap deleted (u6: the sixth match pushes)" u6 \
    '/^     \&\& \[ "\$_acw_lk" -lt "\$APPCODE_SKIP_MAX" \] \\$/d'
  mut "M8 the link test on .landed deleted (u7a: no skip through a link)" u7a \
    's/^     \&\& \[ -f "\$POOL\/.landed" \] \&\& \[ ! -L "\$POOL\/.landed" \] \\$/     \&\& [ -f "$POOL\/.landed" ] \\/'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
