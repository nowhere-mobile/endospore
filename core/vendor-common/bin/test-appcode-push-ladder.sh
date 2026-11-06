#!/usr/bin/env bash
# test-appcode-push-ladder.sh [--mutate] -- NWP-20261128-25: appcode_seal does not retry a #apps push that a sign-out
# asked to stop.
#
# WHY THIS IS COMMITTED. The `out` op exports NOWHERE_SEAL_STOPPABLE=1 (h47 #1, NWP-20261117-01), so the #apps push
# exits 7 (exitSealStopped) when the login daemon has raised $STATE/.sealstop for a sign-out. The stop file stays
# until runWorkerHeld drops it before the sign-out's own out op (core/agent/seal_stop.go). appcode_seal's push ladder
# retried on every non-zero exit, so it started two more pushes, each read the #apps head again and stopped again at
# its first chunk, all on the sign-out's critical path. Then it logged "NOT SEALED ... app code from this session is
# NOT carried", although the sign-out's own seal saves that code a moment later. Now exit 7 ends the ladder at once,
# the log says the push stopped for a sign-out, and appcode_seal still returns 7 (the out op reads it as stopped).
# Every other exit keeps its three tries: 5 (unreachable), 124, 1 and 4 (a stale-publish refusal) can clear.
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with qn, pw, pkgname_ok, appcode_stage_play_dormant,
# live_code_dir, stage_apk_copy, stage_live_apks and stage_keep_mtimes), every /data/ path pointed into a scratch root, as
# test-appcode-list-guard.sh does. One kept installed app is staged from a planted /data/app dir, so the push is
# reached. `$AGENT` is a stub that appends one line to $T/calls per push and exits the code its case names (a
# space-separated sequence, one code per call; the last code repeats).
#
#   L1 exit 7: one push, status 7, the "stopped for a sign-out" line, no "NOT SEALED" line
#   L2 exit 5: three pushes, status 5 (unchanged)
#   L3 exit 4: three pushes, status 4 (a stale-publish refusal can clear)
#   L4 exit 1 then 0: two pushes, status 0, the "sealed" line
#   L5 exit 0: one push, status 0
#
#   bash test-appcode-push-ladder.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-push-ladder.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
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
case "$FUNCS" in *'"${name}#apps"'*) ;; *) echo "EXTRACTION FAILED: appcode_seal holds no #apps push" >&2; exit 2 ;; esac
case "$FUNCS" in *'for lim in '*) ;; *) echo "EXTRACTION FAILED: appcode_seal holds no push ladder (for lim in)" >&2; exit 2 ;; esac

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# ladder_case <shell> <exit codes, one per push call; the last repeats>
# Sets RES (appcode_seal's status), NCALLS (the number of push calls) and LOGTXT.
ladder_case(){
  local T F D c
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  # The rewritten guard reads `$T/data/app/*` unquoted in a case pattern, so $T must hold no pattern byte or dot segment.
  case "$T" in *'*'*|*'?'*|*'['*|*/./*|*/../*) echo "refusing to run: scratch root $T holds a pattern byte or a dot segment" >&2; exit 2 ;; esac
  F="$T/user/com.nowhere.chooser/files"
  D="$T/data/app/~~d==/com.d-1=="
  mkdir -p "$T/data/nowhere" "$F" "$T/dumps" "$T/state" "$D"
  printf 'd-base-apk-bytes-0123456789' > "$D/base.apk"
  printf 'com.d\t1\t0\tinstalled\t%s\n' "$D/base.apk" > "$F/nowhere-appcode.list"
  printf 'com.d\tinstalled\n' > "$F/nowhere-appkeep"
  : > "$T/seq"
  for c in $2; do printf '%s\n' "$c" >> "$T/seq"; done
  : > "$T/calls"
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'T=%s; LOG=$T/log; USERDIR=$T/user; STATE=$T/state; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=0\n' "$T"
    cat <<'STUBS'
dumpsys(){ [ "$1" = package ] && [ -f "$T/dumps/$2" ] && cat "$T/dumps/$2"; return 0; }
agent_stub(){
  local n rc
  echo push >> "$T/calls"
  n=$(grep -c . "$T/calls")
  rc=$(sed -n "${n}p" "$T/seq")
  [ -n "$rc" ] || rc=$(tail -n 1 "$T/seq")
  return "$rc"
}
STUBS
    printf 'AGENT=agent_stub\n'
    printf 'timeout(){ shift 3; "$@"; }\n'
    printf 'keystore_register_all(){ :; }; _ms(){ echo 0; }; _apps_stage_prog(){ :; }\n'
    printf '%s\n' "$FUNCS"
    printf 'appcode_seal; echo "$?" > "$T/res"\n'
  } > "$T/run.sh"
  "$1" "$T/run.sh" >/dev/null 2>&1
  RES=$(cat "$T/res" 2>/dev/null)
  NCALLS=$(grep -c . "$T/calls"); LOGTXT=$(cat "$T/log" 2>/dev/null)
  rm -rf "$T"
}

has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
STOP_LINE="#apps push stopped for a sign-out (rc=7) -- no head published, the sign-out's own seal saves this session's app code (h47 #1)"
LOST_LINE='NOT SEALED, head unchanged, app code from this session is NOT carried'
SEALED_LINE='#apps sealed (1 pkg)'

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"

  ladder_case "$s" 7
  if [ "$NCALLS" = 1 ]; then ok "$t L1 a push that exits 7 (stopped for a sign-out) is not retried: 1 push"
  else no "$t L1 exit 7 -> $NCALLS push call(s), want 1"; fi
  if [ "$RES" = 7 ]; then ok "$t L1 appcode_seal still returns 7, so the out op reads it as stopped"
  else no "$t L1 exit 7 -> status [$RES], want 7"; fi
  if has "$LOGTXT" "$STOP_LINE"; then ok "$t L1 the log says the push stopped for a sign-out"
  else no "$t L1 the stopped line is missing: log [$LOGTXT]"; fi
  if ! has "$LOGTXT" 'NOT SEALED'; then ok "$t L1 the log does not claim the app code is lost"
  else no "$t L1 the log holds a NOT SEALED line: [$LOGTXT]"; fi

  ladder_case "$s" 5
  if [ "$NCALLS" = 3 ] && [ "$RES" = 5 ] && has "$LOGTXT" "#apps push rc=5 after 3 attempts -- $LOST_LINE" && ! has "$LOGTXT" 'stopped for a sign-out'; then
    ok "$t L2 a push that exits 5 (unreachable) keeps its three tries, status 5, the NOT SEALED line"
  else no "$t L2 exit 5 -> $NCALLS push call(s), status [$RES], log [$LOGTXT]"; fi

  ladder_case "$s" 4
  if [ "$NCALLS" = 3 ] && [ "$RES" = 4 ]; then ok "$t L3 a push that exits 4 (a stale-publish refusal can clear) keeps its three tries, status 4"
  else no "$t L3 exit 4 -> $NCALLS push call(s), status [$RES]"; fi

  ladder_case "$s" "1 0"
  if [ "$NCALLS" = 2 ] && [ "$RES" = 0 ] && has "$LOGTXT" "$SEALED_LINE" && ! has "$LOGTXT" 'NOT SEALED'; then
    ok "$t L4 a push that exits 1 and then 0 is retried once and seals, status 0"
  else no "$t L4 exit 1 then 0 -> $NCALLS push call(s), status [$RES], log [$LOGTXT]"; fi

  ladder_case "$s" 0
  if [ "$NCALLS" = 1 ] && [ "$RES" = 0 ] && has "$LOGTXT" "$SEALED_LINE"; then ok "$t L5 a push that exits 0 runs once and seals"
  else no "$t L5 exit 0 -> $NCALLS push call(s), status [$RES], log [$LOGTXT]"; fi
done

if [ "$MUTATE" = yes ]; then
  echo "mutants (each must FAIL a line under EACH shell):"
  MT=$(mktemp -d -p "$W")
  mut(){ # mut <label> <sed script>
    local rc s out bad=""
    sed -e "$2" "$ROAMD" > "$MT/roamd.sh"
    if cmp -s "$ROAMD" "$MT/roamd.sh"; then no "MUTANT DID NOT APPLY: $1"; return; fi
    out=$(ROAMD="$MT/roamd.sh" bash "$0" 2>&1); rc=$?
    for s in $SHELLS; do has "$out" "FAIL  [$s]" || bad="$bad $s"; done
    if has "$out" 'EXTRACTION FAILED'; then no "MUTANT BROKE EXTRACTION: $1"
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted under every shell: $1"
    else no "NOT CONVICTED (rc $rc, shells with no FAIL line:$bad): $1"; fi
  }
  mut "M1 the [ \"\$ret\" = 7 ] && break line removed (L1)" '/^    \[ "\$ret" = 7 \] && break$/d'
  mut "M2 the break widened to every non-zero exit (L2/L3/L4)" 's/^    \[ "\$ret" = 7 \] && break$/    [ "$ret" = 0 ] || break/'
  mut "M3 the stopped log line reverted to the NOT SEALED one (L1)" 's/^  elif \[ "\$ret" = 7 \]; then$/  elif false; then/'
  mut "M4 return \"\$ret\" -> return 0 (L1 status)" 's/^  return "\$ret"$/  return 0/'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
