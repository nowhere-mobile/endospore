#!/usr/bin/env bash
# test-appcode-empty-keepset.sh [--mutate] -- NWP-20261025-04: an EMPTIED keep-set still reaches the #apps push.
#
# WHY THIS IS COMMITTED. The chooser empties the keep-set by WRITING it (StoreInstaller.removeKeepLines,
# ProfileActivity.writeAppModes) and deletes the code list when nothing is kept, so after the last kept app is
# uninstalled or switched Off the logoff finds nowhere-appkeep PRESENT AND EMPTY and nowhere-appcode.list ABSENT.
# appcode_seal used to return at its top when both were empty, so #apps was never resealed: the head kept naming
# the app and the next sign-in installed it again (DECIDED 2026-09-06 uninstall, 2026-09-26 Off). It now returns
# there only when the keep-set FILE is absent; otherwise it seals an empty stage and the agent's shrink and
# presence guards decide it (core/agent/apps_empty_stage_test.go pins that side).
#
# appcode_seal is lifted WHOLE, by name, from roamd (with pw, qn, pkgname_ok, appcode_stage_play_dormant), every
# /data/ path pointed into a scratch root. `$AGENT` is a stub that records one line per call -- its arguments, the
# drop/keep/defer lists it was handed and a listing of the stage -- and exits with the code the case chooses;
# `timeout` and the helpers the function calls are stubs; `print` is shimmed where the shell has none.
#
#   bash test-appcode-empty-keepset.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-empty-keepset.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
export AGENT_DIR="${AGENT_DIR:-$(cd "$(dirname "$0")/../../agent" && pwd)}"
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

FUNCS=""
for fn in qn pw pkgname_ok appcode_stage_play_dormant stage_apk_copy appcode_seal _cause; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in "$fn() {"*'}') FUNCS="$FUNCS$body
" ;; *) echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;; esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }
REFUSED=$(grep -hoE '^const exitSealRefused = [0-9]+$' "${AGENT_DIR:-$(dirname "$0")/../../agent}/main.go" | awk '{print $4}')
[ "$REFUSED" = 4 ] || { echo "EXTRACTION FAILED: exitSealRefused is [$REFUSED], this suite's E5 assumes 4" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# seal_case <shell> <keepset: absent|empty|one> <off: yes|no> <agent rc>
# Sets RC (appcode_seal's return), NCALLS, CALLS (the stub's lines), LOGTXT.
seal_case(){
  local T; T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  local F="$T/user/com.nowhere.chooser/files"
  mkdir -p "$T/data/nowhere" "$F" "$T/apk/com.example.app" "$T/apk/com.android.vending"
  : > "$T/apk/com.example.app/base.apk"; : > "$T/apk/com.android.vending/base.apk"; : > "$T/apk/com.android.vending/split.apk"
  case "$2" in
    empty) : > "$F/nowhere-appkeep" ;;
    one)   printf 'com.example.app\tinstalled\n' > "$F/nowhere-appkeep" ;;
  esac
  [ "$3" = yes ] && printf 'com.android.vending\n' > "$F/nowhere-appoff.list"
  : > "$T/calls"
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'T=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=0\n' "$T"
    cat <<'STUBS'
agent_stub(){
  local last a
  for a; do last=$a; done
  echo "ARGS $1 $2 $3 | DROP=${NOWHERE_DROP_LIST:-} | KEEP=${NOWHERE_KEEP_LIST:-} | MANBYTES=$(wc -c < "$last/manifest.tsv" | tr -d ' ') | DEFER=$(cat "${NOWHERE_DEFER_LIST:-/dev/null}" 2>/dev/null | tr '\n' ',') | STAGE=$(cd "$last" && find . -type f | sort | tr '\n' ',')" >> "$T/calls"
  return $AGENT_RC
}
STUBS
    printf 'AGENT=agent_stub; AGENT_RC=%s\n' "$4"
    printf 'timeout(){ shift 3; "$@"; }\n'
    printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _ms(){ echo 0; }; _apps_stage_prog(){ :; }\n'
    printf 'live_code_dir(){ [ -d "$T/apk/$1" ] && echo "$T/apk/$1"; return 0; }\n'
    printf 'stage_live_apks(){ cp "$1"/*.apk "$2"/ && (cd "$1" && ls *.apk | tr "\\n" " "); }\n'
    printf 'stage_keep_mtimes(){ :; }\n'
    printf '%s\n' "$FUNCS"
    printf 'appcode_seal; echo "$?" > "$T/res"\n'
  } > "$T/run.sh"
  "$1" "$T/run.sh" >/dev/null 2>&1
  RC=$(cat "$T/res" 2>/dev/null); NCALLS=$(grep -c . "$T/calls"); CALLS=$(cat "$T/calls"); LOGTXT=$(cat "$T/log" 2>/dev/null)
  rm -rf "$T"
}
cause_of(){
  local T; T=$(mktemp -d -p "$W") || exit 2
  printf '%s\n%s\n_cause "%s"\n' "$PRINT_SHIM" "$(printf '%s\n' "$FUNCS" | awk '$0=="_cause() {"{f=1} f{print} f&&/^\}$/{exit}')" "$2" > "$T/run.sh"
  "$1" "$T/run.sh" 2>&1; rm -rf "$T"
}

has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"
  seal_case "$s" empty no 0
  if [ "$RC" = 0 ] && [ "$NCALLS" = 1 ] && has "$CALLS" 'ARGS push s3 probe#apps ' && has "$CALLS" 'MANBYTES=0 ' \
     && has "$CALLS" 'STAGE=./manifest.tsv,' && ! has "$CALLS" 'STAGE=./manifest.tsv,./' && has "$LOGTXT" '#apps sealed (0 pkg)'; then
    ok "$t E1 empty keep-set file, no code list: one push of probe#apps with an empty manifest-only stage, sealed (0 pkg), rc 0"
  else no "$t E1 empty keep-set -> rc [$RC], $NCALLS call(s) [$CALLS], log has sealed(0 pkg): $(has "$LOGTXT" '#apps sealed (0 pkg)' && echo y || echo n)"; fi

  seal_case "$s" absent no 0
  [ "$RC" = 0 ] && [ "$NCALLS" = 0 ] && ok "$t E2 no keep-set file, no code list: no push, rc 0" \
    || no "$t E2 absent keep-set -> rc [$RC], $NCALLS call(s), want rc 0 and none"

  seal_case "$s" empty yes 0
  if [ "$RC" = 0 ] && [ "$NCALLS" = 1 ] && has "$CALLS" 'MANBYTES=0 ' && has "$CALLS" 'DEFER=com.android.vending/base.apk,com.android.vending/split.apk,' \
     && has "$CALLS" 'STAGE=./com.android.vending/base.apk,./com.android.vending/split.apk,./manifest.tsv,'; then
    ok "$t E3 empty keep-set, Off Play Store still installed: its APKs staged DEFERRED, a defer line each, no manifest line"
  else no "$t E3 empty keep-set + Off vending -> rc [$RC], $NCALLS call(s) [$CALLS]"; fi

  seal_case "$s" one no 0
  if [ "$RC" = 0 ] && [ "$NCALLS" = 1 ] && has "$CALLS" 'STAGE=./com.example.app/base.apk,./manifest.tsv,' && ! has "$CALLS" 'MANBYTES=0 ' \
     && has "$LOGTXT" '#apps sealed (1 pkg)'; then
    ok "$t E4 non-empty keep-set: one staged package, as before"
  else no "$t E4 one kept app -> rc [$RC], $NCALLS call(s) [$CALLS]"; fi

  seal_case "$s" empty no 4
  c=$(cause_of "$s" "$RC")
  if [ "$RC" = 4 ] && [ "$NCALLS" = 3 ] && [ "$c" = refused ]; then
    ok "$t E5 empty keep-set, the agent refuses (4): three tries, appcode_seal returns 4, which _cause reads as refused (PARTIAL:apps=refused)"
  else no "$t E5 agent exit 4 -> rc [$RC], $NCALLS call(s), cause [$c], want 4, 3, refused"; fi
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
    if [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted under every shell: $1"
    else no "NOT CONVICTED (rc $rc, shells with no FAIL line:$bad): $1"; fi
  }
  # NWP-20261128-09: the return removes the #apps reuse pool first; \1 keeps that tail in M1 and M2.
  COND='^  \[ -s "\$AL" \] || \[ -s "\$AK" \] || \[ -f "\$AK" \] || \({ rm -rf "\$POOL" 2>\/dev\/null; return 0; }\)$'
  mut "M1 the original early return restored"                   "s/$COND/  [ -s \"\$AL\" ] || [ -s \"\$AK\" ] || \\1/"
  mut "M2 -e on the code list instead of -f on the keep-set"    "s/$COND/  [ -s \"\$AL\" ] || [ -s \"\$AK\" ] || [ -e \"\$AL\" ] || \\1/"
  mut "M3 the file test dropped entirely"                       "s/$COND/  [ -s \"\$AL\" ] || [ -s \"\$AK\" ]/"
  mut "M4 the empty-keep-set branch returns before the helper"  's/^  appcode_stage_play_dormant "\$seen" "\$APPOFF" "\$CODEKEEP" "\$AK"$/  [ -s "$AK" ] || return 0\n&/'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
