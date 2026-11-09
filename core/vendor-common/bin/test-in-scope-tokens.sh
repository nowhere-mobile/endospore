#!/usr/bin/env bash
# test-in-scope-tokens.sh [<nowhere_roamd.sh>] [--mutate] -- a sign-in's `[roamd] IN ... -> user N (...)` line names a
# #de or #media restore that was skipped or failed, instead of always printing `(+de +media)` (NWP-20261113-15;
# backlog §A ⚠ A TRANSIENT DIAL FAILURE OFFERS THE USER A DESTRUCTIVE ROLLBACK).
#
# WHY THIS IS COMMITTED. The `in)` arm runs the #de and #media restores best-effort and dropped both exit statuses,
# then printed the fixed literal `(+de +media)`. On lynx 2026102201 (NWP-20261024-18) Wi-Fi was cut during the #media
# chunk download: roam.log read `ERR: fetch chunk 80 ...` and then `IN "odtest30" -> user 18 (+de +media)`, a sign-in
# called restored although #media had failed. The arm now keeps each status (_derc / _mdrc, or `skip` when the per-user
# dir is absent) and prints in_scope_tokens of them. This suite runs the REAL in_scope_tokens and the REAL two
# capture-and-tail segments of the arm under every shell found, and checks the landing line's source.
#
#   bash test-in-scope-tokens.sh              # the cases
#   bash test-in-scope-tokens.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

SHELLS=""
if [ -n "${IST_SHELLS:-}" ]; then SHELLS="$IST_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
fn_of() { awk -v a="$2() {" '$0 == a {f=1} f{print} f&&/^}$/{exit}' "$1"; }
codeonly() { grep -vE '^[[:space:]]*#' ; }
# seg_of <code> <var>: from `<indent><var>=skip` through the first `<indent>fi` after it (the capture line and the
# tail), at any indent: since NWP-20261124-05 the #media segment sits two spaces deeper than the #de one
seg_of() {
  printf '%s\n' "$1" | awk -v v="$2=skip" '
    !f && match($0, /^ +/) && substr($0, RLENGTH + 1) == v { f = 1; e = substr($0, 1, RLENGTH) "fi" }
    f { print } f && $0 == e { exit }'
}

LANDING='      print -r -- "[roamd] IN $(qn "$name") -> user $uid ($(in_scope_tokens "$_derc" "$_mdrc")) $(date)" >> "$LOG"'

suite() {  # suite <roamd.sh> <quiet|""> -> 0 all ok, 1 a check failed, 2 the harness could not extract
  local f="$1" quiet="${2:-}" p=0 x=0 FN IN CODE SDE SMD n sh s out
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }

  FN=$(fn_of "$f" in_scope_tokens)
  [ -n "$FN" ] || { echo "EXTRACTION FAILED: in_scope_tokens in $f" >&2; return 2; }
  IN=$(arm_of "$f" in)
  [ -n "$IN" ] || { echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2; }
  CODE=$(printf '%s\n' "$IN" | codeonly)
  SDE=$(seg_of "$CODE" _derc); SMD=$(seg_of "$CODE" _mdrc)
  [ -n "$SDE" ] || { echo "EXTRACTION FAILED: the #de capture segment (_derc=skip ... fi) in the in arm" >&2; return 2; }
  [ -n "$SMD" ] || { echo "EXTRACTION FAILED: the #media capture segment (_mdrc=skip ... fi) in the in arm" >&2; return 2; }
  printf '%s\n' "$FN" > "$W/fn.sh"
  printf '%s\n' "$SDE" > "$W/seg-de.sh"
  printf '%s\n' "$SMD" > "$W/seg-media.sh"

  # tok <shell> <derc> <mdrc>: what the real helper prints
  tok() { "$1" -c '. "$1"; in_scope_tokens "$2" "$3"' _ "$W/fn.sh" "$2" "$3" 2>&1; }
  # seg <shell> <de|media> <dir present 0|1> <agent rc>: runs the real segment; prints `<rc var>|<tail calls>`
  seg() {
    local root
    root=$(mktemp -d -p "$W")
    mkdir -p "$root/user_de" "$root/media"
    [ "$3" = 1 ] && mkdir -p "$root/user_de/11" "$root/media/11"
    cat > "$root/case.sh" <<CASE
ROOT="$root"; LOG="\$ROOT/log"; uid=11; name=prof; pass=pw; AGENT=agent_sim; SIM_RC=$4
DEDIR="\$ROOT/user_de/11"; MEDIADIR="\$ROOT/media/11"   # the segment starts after the arm's own two assignments
: > "\$ROOT/calls"
pw() { printf '%s\n' x; }
agent_sim() { echo "agent \$1 \$3" >> "\$ROOT/calls"; return "\$SIM_RC"; }
_ms() { echo 0; }
_tlog() { :; }
_ssum() { :; }
remap_per_pkg() { echo tail >> "\$ROOT/calls"; }
remap_media_db() { :; }   # NWP-20261124-01: the #de tail calls it before remap_per_pkg
insert_deferred_media() { :; }   # NWP-20261130-02: the #media tail calls it after restore_media_tail
restorecon() { :; }
restore_media_tail() { echo tail >> "\$ROOT/calls"; }
. "$W/seg-$2.sh"
if [ "$2" = de ]; then v="\$_derc"; else v="\$_mdrc"; fi
printf '%s|%s' "\$v" "\$(grep -c '^tail\$' "\$ROOT/calls")"
CASE
    "$1" "$root/case.sh" 2>&1
  }

  for sh in $SHELLS; do
    say "== $sh"
    out=$(tok "$sh" 0 0);       chk "T1 [$sh] (0,0) -> '+de +media', the old literal byte for byte (got '$out')" [ "$out" = "+de +media" ]
    out=$(tok "$sh" 0 5);       chk "T2 [$sh] (0,5) -> '+de !media(rc=5)' (got '$out')" [ "$out" = "+de !media(rc=5)" ]
    out=$(tok "$sh" 1 0);       chk "T3 [$sh] (1,0) -> '!de(rc=1) +media' (got '$out')" [ "$out" = "!de(rc=1) +media" ]
    out=$(tok "$sh" skip 0);    chk "T4 [$sh] (skip,0) -> '-de +media' (got '$out')" [ "$out" = "-de +media" ]
    out=$(tok "$sh" skip skip); chk "T5 [$sh] (skip,skip) -> '-de -media' (got '$out')" [ "$out" = "-de -media" ]
    for s in de media; do
      out=$(seg "$sh" "$s" 1 0); chk "S1 [$sh] #$s restore exit 0 -> rc 0, the tail runs once (got '$out')" [ "$out" = "0|1" ]
      out=$(seg "$sh" "$s" 1 5); chk "S2 [$sh] #$s restore exit 5 -> rc 5, no tail (got '$out')" [ "$out" = "5|0" ]
      out=$(seg "$sh" "$s" 0 0); chk "S3 [$sh] #$s dir absent -> skip, no restore and no tail (got '$out')" [ "$out" = "skip|0" ]
    done
  done

  # source checks over the arm, comments dropped
  n=$(printf '%s\n' "$CODE" | grep -cxF -- "$LANDING")
  chk "L1 the IN landing line prints in_scope_tokens of both statuses" [ "$n" = 1 ]
  n=$(printf '%s\n' "$CODE" | grep -F -- '[roamd] IN ' | grep -cF -- '(+de +media)')
  chk "L2 no IN line in the arm prints the literal (+de +media)" [ "$n" = 0 ]
  n=$(printf '%s\n' "$CODE" | grep -F -- '"${name}#de"' | grep -cE -- '^ +\[ -d "\$DEDIR" \] && \{ .*restore s3 "\$\{name\}#de" .*; _derc=\$\?; \}$')
  chk "L3 the #de restore sets _derc from \$?" [ "$n" = 1 ]
  n=$(printf '%s\n' "$CODE" | grep -F -- '"${name}#media"' | grep -cE -- '^ +\[ -d "\$MEDIADIR" \] && \{ .*restore s3 "\$\{name\}#media" .*; _mdrc=\$\?; \}$')
  chk "L4 the #media restore sets _mdrc from \$?" [ "$n" = 1 ]

  [ -z "$quiet" ] && printf '%s: passed %d, failed %d\n' "$f" "$p" "$x"
  [ "$x" = 0 ]
}

mutate_to() {  # mutate_to <mutant> <out file> -- one textual replace of $SUT, written to <out file>
  python3 - "$1" "$SUT" "$2" <<'PY'
import sys
m, src, dst = sys.argv[1:]
s = open(src).read()
R = {
  'M1': ('if [ "$_ist_s" = de ]; then _ist_rc="$1"; else _ist_rc="$2"; fi',
         'if [ "$_ist_s" = de ]; then _ist_rc="$1"; else _ist_rc=0; fi'),
  'M2': ('skip) _ist_out="${_ist_out:+$_ist_out }-$_ist_s" ;;',
         'skip) _ist_out="${_ist_out:+$_ist_out }+$_ist_s" ;;'),
  'M3': ('-> user $uid ($(in_scope_tokens "$_derc" "$_mdrc"))',
         '-> user $uid (+de +media)'),
  'M4': ('"$MEDIADIR" >> "$LOG" 2>&1; _mdrc=$?; }',
         '"$MEDIADIR" >> "$LOG" 2>&1; }'),
}
a, b = R[m]
open(dst, 'w').write(s.replace(a, b, 1))
PY
}

run_mutants() {
  local m c sh rc bad=0 desc
  for m in M1 M2 M3 M4; do
    case "$m" in
      M1) desc="the helper prints +media for any rc" ;;
      M2) desc="the helper prints +de for skip" ;;
      M3) desc="the landing line goes back to the literal (+de +media)" ;;
      M4) desc="the #media rc is not captured" ;;
    esac
    c=$(mktemp -p "$W")
    mutate_to "$m" "$c"
    if cmp -s "$c" "$SUT"; then echo "  FAIL  $m did not apply: $desc"; bad=1; rm -f "$c"; continue; fi
    for sh in $SHELLS; do
      IST_SHELLS="$sh" bash "$SELF" "$c" >/dev/null 2>&1; rc=$?
      if [ "$rc" = 1 ]; then echo "  ok    $m CONVICTED under $sh: $desc"
      else echo "  FAIL  $m rc=$rc under $sh (want 1): $desc"; bad=1; fi
    done
    rm -f "$c"
  done
  return $bad
}

[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }
suite "$SUT" ""; rc=$?
[ "$rc" = 0 ] || exit "$rc"
if [ "$MUTATE" = yes ]; then
  run_mutants || exit 1
  echo "all mutants convicted"
fi
exit 0
