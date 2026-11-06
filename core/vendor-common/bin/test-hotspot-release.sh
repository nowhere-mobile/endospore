#!/usr/bin/env bash
# test-hotspot-release.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's SESSION HOTSPOT RELEASE (NWP-20261028-10), run for
# real against a stubbed `am` (the gate's HotspotReceiver) under every shell the runner has, rather than grepped.
#
# WHY THIS IS COMMITTED. A signed-in profile can share its connection only through the gate, and the hotspot and its
# passphrase must not outlive the session that set them (docs/product-decisions.md, 2026-10-19): roamd decides WHEN it
# stops -- the mdrelease arm (sign-out, cold lock, a gone user's marker), the reap and the boot sweep -- and the gate decides
# whether. Every way this goes wrong is silent: a call without the uid extra would ask the gate to release unconditionally
# or not at all; an empty reply read as RELEASED would log a stop that never happened; a boot token with a space would split
# the sweep's result line; a claim that sent a release would stop a hotspot the session just started.
# What this pins:
#   - the broadcast: ONE per call, explicit component, action, `--ei uid <n>` and no other extra;
#   - the verdict: only the data= of the `Broadcast completed:` line counts; no line, a failed am or a malformed reason is
#     ERR-HS noreply, never RELEASED;
#   - the callers: the mdrelease arm (never mdapply, its RES byte for byte md's), the reap, boot-sweep fix 15 (uid -1,
#     one space-free token);
#   - NO STATE: the block writes nothing under the device roots, only the log.
# `am` and `timeout` are executable stubs on PATH.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR, never copied; if an anchor moves, extraction fails loudly
# (exit 2) rather than a stale copy passing.
#
#   bash test-hotspot-release.sh            # the behaviour cases, under bash, sh, dash and mksh where present
#   bash test-hotspot-release.sh --mutate   # ... plus broken copies that must each be CONVICTED, under each shell
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

LAX=""   # set while a mutant is prepared: its deleted or moved lines must still extract, so an assertion convicts it
SHELLS=(); LABELS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p"); LABELS+=("$s")
done

BEGIN_HDR='# ---- NWP-20261028-10: SESSION HOTSPOT RELEASE (begin) ----------------------------------------------------------------'
END_HDR='# ---- NWP-20261028-10: SESSION HOTSPOT RELEASE (end) ------------------------------------------------------------------'
DR_END_HDR='# ---- NWP-20261028-07: SESSION-SCOPED DATA ROAMING (end) --------------------------------------------------------------'
MD_BEGIN_HDR='# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA (begin) ------------------------------------------------------------'
LBEGIN_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (begin) -------------------------------------------------------'
LEND_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (end) ---------------------------------------------------------'
OP_HDR='if [ "$op" = "mdapply" ] || [ "$op" = "mdrelease" ]; then'
CS_HDR='if [ "$op" = "cleanstorage" ]; then'
BOOT_HDR='  # --- fix 15: hotspot (NWP-20261028-10) ---'
BOOT_END='  _swept="$_swept hotspot=$_hs"'
FIX14_END='  _swept="$_swept dataroaming=$DR_BOOT"'
DR_REAP='  dr_release "$uid" reap   # NWP-20261028-07: the reap'"'"'s backstop for data roaming; another owner is left alone'
HS_REAP='  hs_release "$uid" reap   # NWP-20261028-10: the reap'"'"'s backstop for the hotspot; another session'"'"'s is left alone by the gate'
RECV='com.nowhere.chooser/.HotspotReceiver'
ACT='com.nowhere.chooser.action.HOTSPOT_RELEASE'

# prep <roamd.sh>: extract the pieces into a fresh dir ($R). 0, or 2 (the harness cannot run).
prep() {
  local f="$1" blk lblk boot oparm x need
  R=$(mktemp -d -p "$W") || return 2
  for x in "$BEGIN_HDR" "$END_HDR" "$DR_END_HDR" "$MD_BEGIN_HDR" "$LBEGIN_HDR" "$LEND_HDR" "$OP_HDR" "$CS_HDR" "$BOOT_HDR" \
           "$BOOT_END" "$FIX14_END" "$DR_REAP" "$HS_REAP"; do
    need=1; [ -n "$LAX" ] && [ "$x" = "$HS_REAP" ] && need=$(grep -cxF "$x" "$f")   # a mutant may delete the reap line
    [ "$(grep -cxF "$x" "$f")" = "$need" ] || { echo "EXTRACTION FAILED: anchor not found exactly once in $f: $x" >&2; return 2; }
  done
  blk=$(awk -v b="$BEGIN_HDR" -v e="$END_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$blk" in *'hs_release()'*) ;; *) echo "EXTRACTION FAILED: hs_release in the hotspot block" >&2; return 2 ;; esac
  lblk=$(awk -v b="$LBEGIN_HDR" -v e="$LEND_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$lblk" in *'loc_why()'*) ;; *) echo "EXTRACTION FAILED: loc_why" >&2; return 2 ;; esac
  [ "$(grep -c '^loc_why() {' <<< "$lblk")" = 1 ] || { echo "EXTRACTION FAILED: loc_why line" >&2; return 2; }
  oparm=$(awk -v h="$OP_HDR" '$0 == h {on = 1} on {print} on && $0 == "fi" {exit}' "$f")
  case "$oparm" in *'md_release '*'exit 0'*) ;; *) echo "EXTRACTION FAILED: the op arm" >&2; return 2 ;; esac
  boot=$(awk -v h="$BOOT_HDR" -v e="$BOOT_END" '$0 == h {on = 1} on {print} on && $0 == e {exit}' "$f")
  case "$boot" in *'hs_release '*' boot'*) ;; *) echo "EXTRACTION FAILED: the bootsweep category" >&2; return 2 ;; esac
  if grep -v '^[[:space:]]*#' <<< "$blk"$'\n'"$boot" | grep -qE '/system/|/data/'; then
    echo "EXTRACTION FAILED: a device path is in the live code" >&2; return 2
  fi
  grep '^loc_why() {' <<< "$lblk" > "$R/loc.sh"; printf '%s\n' "$blk" > "$R/hs.sh"; printf '%s\n' "$boot" > "$R/boot.sh"
  printf '%s\n' "$oparm" > "$R/oparm.sh"; printf '%s\n' "$HS_REAP" > "$R/reap.sh"
  bash -n "$R/loc.sh" && bash -n "$R/hs.sh" && bash -n "$R/boot.sh" && bash -n "$R/oparm.sh" \
    || { echo "EXTRACTION FAILED: an extracted piece does not parse" >&2; return 2; }
  mkdir "$R/bin" || return 2
  # The gate's receiver: one line per call (the whole argv) in $T/am-calls. $T/reply, if present, is the data= of the
  # `Broadcast completed:` line (a CR ends it, as on the device); absent, am prints no such line. $T/am-rc is its exit code.
  cat > "$R/bin/am" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T/am-calls"
echo "NOISE-AM" >&2
if [ -f "$T/reply" ]; then
  echo 'Broadcasting: Intent { act=com.nowhere.chooser.action.HOTSPOT_RELEASE }'
  printf 'Broadcast completed: result=-1, data="%s"\r\n' "$(cat "$T/reply")"
fi
[ -f "$T/am-rc" ] && exit "$(cat "$T/am-rc")"
exit 0
STUB
  cat > "$R/bin/timeout" <<'STUB'
#!/bin/sh
echo "$1 $2 $3" >> "$T/timeout-calls"
shift 3
exec "$@"
STUB
  chmod +x "$R/bin/am" "$R/bin/timeout"
  return 0
}

DRIVER='
STATE="$T/state"; LOG="$T/log"; RES="$T/res"
md_claim() { MD_VERDICT="OK APPLIED mobile_data=1"; }
md_release() { MD_VERDICT=$(cat "$T/md-verdict" 2>/dev/null || echo "OK BASELINE mobile_data=0"); }
dr_claim() { DR_SEEN=0; }
dr_release() { :; }
userdir_recheck() { :; }; userdir_pending_add() { :; }   # NWP-20261104-14: the users/<n> re-check is test-userdir-orphan.sh, not this suite
. "$R/loc.sh"; . "$R/hs.sh"
case "$MODE" in
  op) op="$OPV"; uid="$UIDV"; name="$NAMEV"; . "$R/oparm.sh"
      echo "the op arm fell through" >> "$T/unexpected" ;;
  boot) op=bootsweep; uid="12"; name=""; _swept=""; . "$R/boot.sh"
        printf "%s" "$_swept" > "$T/swept" ;;
  reap) op=cleanstorage; uid="$UIDV"; name=x; . "$R/reap.sh" ;;
esac'

# suite <roamd.sh> <shell path> <label> [quiet]: 0 all ok, 1 an assertion failed (the only verdict that convicts a
# mutant), 2 the harness could not run. prep must have run ($R).
suite() {
  local f="$1" SH="$2" LB="$3" quiet="${4:-}" PASS=0 FAIL=0 T out at x v n
  ok() { PASS=$((PASS+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$LB" "$1"; }
  no() { FAIL=$((FAIL+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$LB" "$1"; }

  mkdev() {
    T=$(mktemp -d -p "$W"); mkdir -p "$T/state" "$T/nowhere"
    : > "$T/state/seed"; : > "$T/nowhere/seed"
  }
  reply() { printf '%s' "$1" > "$T/reply"; }
  ncalls() { if [ -f "$T/am-calls" ]; then grep -c . "$T/am-calls" || true; else echo 0; fi; }
  lastcall() { tail -n 1 "$T/am-calls" 2>/dev/null; }
  drive() {  # drive <mode> <op> <uid> <name>
    env LC_ALL=C PATH="$R/bin:$PATH" T="$T" R="$R" MODE="$1" OPV="${2:-}" UIDV="${3:-}" NAMEV="${4:-}" "$SH" -c "$DRIVER" >/dev/null 2>>"$T/stderr"
  }
  op() { drive op "$1" "$2" "$3"; cat "$T/res" 2>/dev/null; rm -f "$T/res"; }
  boot() { drive boot; cat "$T/swept" 2>/dev/null; }
  reap() { drive reap "" "$1"; }
  logged() { if [ -f "$T/log" ]; then grep -c "$1" "$T/log" || true; else echo 0; fi; }
  snap() { find "$T/state" "$T/nowhere" | sort | tr '\n' ';'; }
  clean() {  # no harness error may hide behind a passing case
    if [ -s "$T/stderr" ] && grep -qE 'not found|unbound|[Ss]yntax error|bad substitution|parameter not set' "$T/stderr"; then
      no "$1: the harness reported $(head -n 1 "$T/stderr")"
    fi
    if [ -f "$T/log" ] && grep -q 'NOISE-' "$T/log"; then no "$1: am output reached the log"; fi
    if [ -s "$T/unexpected" ]; then no "$1: unexpected: $(tr '\n' ';' < "$T/unexpected")"; fi
    rm -rf "$T"
  }

  # --- placement ------------------------------------------------------------------------------------------------
  at=$(awk -v d="$DR_END_HDR" -v b="$BEGIN_HDR" -v e="$END_HDR" -v m="$MD_BEGIN_HDR" '$0 == d {dl = NR} $0 == b {bl = NR} $0 == e {el = NR} $0 == m {ml = NR}
    END {print (dl && bl == dl + 1 && el > bl && ml == el + 1) ? "ok" : "no"}' "$f")
  [ "$at" = ok ] && ok "P0 the block sits between data roaming's end and the mobile data block" || no "P0 the block is misplaced"

  # --- the mdrelease arm ----------------------------------------------------------------------------------------
  mkdev; reply 'OK RELEASED'
  out=$(op mdrelease 12 signout)
  want="broadcast --user 0 -n $RECV -a $ACT --ei uid 12"
  [ "$(ncalls)" = 1 ] && [ "$(lastcall)" = "$want" ] \
    && ok "H1 mdrelease for 12: one broadcast, the explicit component, the action and --ei uid 12, nothing else" \
    || no "H1 $(ncalls) call(s), last '$(lastcall)'"
  case "$(lastcall)" in *--es*) no "H1 an --es extra was sent" ;; *) ok "H1 no --es extra" ;; esac
  n=$(lastcall | grep -o -- '--ei' | grep -c .)
  [ "$n" = 1 ] && ok "H1 exactly one --ei" || no "H1 $n --ei extras"
  [ "$(cat "$T/timeout-calls" 2>/dev/null)" = "-k 2 15" ] && ok "H1 under timeout -k 2 15" || no "H1 timeout calls: $(cat "$T/timeout-calls" 2>/dev/null)"
  [ "$(logged '^\[roamd\] hotspot user 12 (signout): OK RELEASED ')" = 1 ] && ok "H1 one log line: uid, why, verdict" || no "H1 log: $(cat "$T/log" 2>/dev/null)"
  clean H1

  mkdev; reply 'OK KEPT'
  op mdrelease 12 signout >/dev/null
  [ "$(logged '^\[roamd\] hotspot user 12 (signout): OK KEPT ')" = 1 ] && [ "$(logged RELEASED)" = 0 ] \
    && ok "H2 a scripted OK KEPT is logged as KEPT" || no "H2 log: $(cat "$T/log" 2>/dev/null)"
  clean H2

  mkdev
  op mdrelease 12 signout >/dev/null
  [ "$(logged '(signout): ERR-HS noreply ')" = 1 ] && [ "$(logged RELEASED)" = 0 ] \
    && ok "H3 no output -> ERR-HS noreply, never RELEASED" || no "H3 log: $(cat "$T/log" 2>/dev/null)"
  clean H3a
  mkdev; reply 'OK RELEASED'; echo 124 > "$T/am-rc"
  op mdrelease 12 signout >/dev/null
  [ "$(logged '(signout): ERR-HS noreply ')" = 1 ] && [ "$(logged 'OK RELEASED')" = 0 ] \
    && ok "H3 a well-formed reply from an am that exited 124 -> ERR-HS noreply" || no "H3b log: $(cat "$T/log" 2>/dev/null)"
  clean H3b
  mkdev; reply 'ERR-HS bad reason'
  op mdrelease 12 signout >/dev/null
  [ "$(logged '(signout): ERR-HS noreply ')" = 1 ] && ok "H3 a reason with a space -> ERR-HS noreply" || no "H3c log: $(cat "$T/log" 2>/dev/null)"
  clean H3c
  mkdev; reply 'ERR-HS denied'
  op mdrelease 12 signout >/dev/null
  [ "$(logged '(signout): ERR-HS denied ')" = 1 ] && ok "H3 a one-word reason is kept: ERR-HS denied" || no "H3d log: $(cat "$T/log" 2>/dev/null)"
  clean H3d

  mkdev; reply 'OK RELEASED'
  op mdrelease 12 'Alice Smith' >/dev/null
  if [ "$(logged '(other): OK RELEASED ')" = 1 ] && ! grep -q 'Alice' "$T/log"; then ok "H9 a name in the reason slot is logged as other, never as itself"
  else no "H9 log: $(cat "$T/log" 2>/dev/null)"; fi
  clean H9

  # --- the claim sends nothing ---------------------------------------------------------------------------------
  mkdev; reply 'OK RELEASED'
  op mdapply 12 signin >/dev/null
  [ "$(ncalls)" = 0 ] && ok "H6 mdapply sends no hotspot broadcast" || no "H6 $(ncalls) broadcast(s): $(cat "$T/am-calls")"
  clean H6

  # --- the RES ----------------------------------------------------------------------------------------------------
  for v in 'OK BASELINE mobile_data=0' 'ERR-MD mobile_data=1'; do
    mkdev; reply 'ERR-HS denied'; echo "$v" > "$T/md-verdict"
    op mdrelease 12 signout >/dev/null
    printf '%s\n' "$v" > "$T/want-res"
    # op() removed res; run again keeping it
    drive op mdrelease 12 signout
    if cmp -s "$T/res" "$T/want-res"; then ok "H8 the mdrelease RES is byte for byte the mobile-data verdict ($v)"
    else no "H8 RES for '$v': '$(cat "$T/res" 2>/dev/null)'"; fi
    clean "H8 $v"
  done

  # --- the REAP ---------------------------------------------------------------------------------------------------
  at=$(awk -v cs="$CS_HDR" -v d="$DR_REAP" -v r="$HS_REAP" '$0 == cs {op = NR} $0 == d {dl = NR} $0 == r {rl = NR}
    op && !mm && /^  stop_mediad / {mm = NR} END {print op " " dl " " rl " " mm}' "$f")
  set -- $at
  if [ "$#" = 4 ] && [ "$1" -lt "$2" ] && [ "$3" = $(( $2 + 1 )) ] && [ "$3" -lt "$4" ]; then
    ok "H4 cleanstorage asks the gate once, right after data roaming's release and before stop_mediad"
  else no "H4 the reap's hs line is missing or misplaced (op/dr/hs/stop_mediad: $at)"; fi
  mkdev; reply 'OK KEPT'
  reap 13
  [ "$(ncalls)" = 1 ] && [ "$(lastcall)" = "broadcast --user 0 -n $RECV -a $ACT --ei uid 13" ] \
    && ok "H4 the reap of 13 sends --ei uid 13" || no "H4 $(ncalls) call(s), last '$(lastcall)'"
  [ "$(logged '^\[roamd\] hotspot user 13 (reap): OK KEPT ')" = 1 ] && ok "H4 ...and logs it as reap" || no "H4 log: $(cat "$T/log" 2>/dev/null)"
  clean H4

  # --- the BOOT SWEEP ---------------------------------------------------------------------------------------------
  at=$(awk -v f14="$FIX14_END" -v h="$BOOT_HDR" '/^if \[ "\$op" = "bootsweep" \]; then$/ {op = NR} $0 == f14 {p = NR} $0 == h {blk = NR}
    /echo "\[roamd\] bootsweep result:\$_swept/ {res = NR} END {print (op && p > op && blk == p + 1 && res > blk) ? "in" : "out"}' "$f")
  [ "$at" = in ] && ok "P2 fix 15 sits inside the bootsweep op, right after fix 14 and before the result line" || no "P2 the category is misplaced"
  mkdev; reply 'OK RELEASED'
  out=$(boot)
  [ "$out" = " hotspot=released" ] && [ "$(ncalls)" = 1 ] && [ "$(lastcall)" = "broadcast --user 0 -n $RECV -a $ACT --ei uid -1" ] \
    && ok "H5 the sweep sends --ei uid -1 (not its own uid) and reports hotspot=released" || no "H5a _swept '$out', last '$(lastcall)'"
  clean H5a
  mkdev; reply 'ERR-HS reset'
  out=$(boot)
  case "$out" in
    " hotspot=failed(reset)") ok "H5 ERR-HS reset -> hotspot=failed(reset), one token" ;;
    *) no "H5b _swept '$out'" ;;
  esac
  case "${out# }" in *' '*) no "H5 the token has a space: '$out'" ;; *) ok "H5 the token is space-free" ;; esac
  clean H5b
  mkdev
  out=$(boot)
  [ "$out" = " hotspot=failed(noreply)" ] && ok "H5 no reply -> hotspot=failed(noreply)" || no "H5c _swept '$out'"
  clean H5c

  # --- NO STATE ---------------------------------------------------------------------------------------------------
  mkdev; reply 'OK RELEASED'; before=$(snap)
  op mdrelease 12 signout >/dev/null; reap 13; boot >/dev/null
  rm -f "$T/res" "$T/swept"
  [ "$(snap)" = "$before" ] && ok "H7 nothing is written under the state or /data/nowhere stand-ins" || no "H7 before '$before' after '$(snap)'"
  x=$(ls -A "$T" | grep -vxE 'state|nowhere|am-calls|timeout-calls|log|reply|stderr' | tr '\n' ' ')
  [ -z "$x" ] && ok "H7 no other file appears in the test's root" || no "H7 stray: $x"
  clean H7
  x=$(grep -v '^[[:space:]]*#' "$R/hs.sh" | grep -n '>' | grep -vE '>> "\$LOG"|2>/dev/null|</dev/null' || true)
  [ -z "$x" ] && ok "H7 the block's only redirection is the log append" || no "H7 redirection in live code: $x"
  x=$(grep -v '^[[:space:]]*#' "$R/hs.sh" | grep -E '(^|[^A-Za-z_./-])(settings|cmd)([^A-Za-z_]|$)' || true)
  [ -z "$x" ] && ok "H7 the block calls no settings or cmd" || no "H7 live code: $x"

  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$LB" "$PASS" "$FAIL"
  [ "$FAIL" = 0 ] && return 0 || return 1
}

# runall <roamd.sh> [quiet] -> the worst verdict over the shells
runall() {
  local f="$1" q="${2:-}" i rc worst=0
  prep "$f" || return 2
  for i in "${!SHELLS[@]}"; do
    suite "$f" "${SHELLS[$i]}" "${LABELS[$i]}" "$q"; rc=$?
    [ "$rc" -gt "$worst" ] && worst=$rc
  done
  rm -rf "$R"
  return "$worst"
}

echo "== $SUT"
echo "shells: ${LABELS[*]}"
runall "$SUT"; rc=$?
if [ "$rc" != 0 ]; then echo "FAILED (rc=$rc)"; exit "$rc"; fi
[ "$MUTATE" = yes ] || exit 0

echo
echo "== mutations (each must be CONVICTED by an assertion under EACH shell; one that does not apply or breaks the harness is a failure)"
fails=0; nmut=0
mut() {  # mut <label> <perl -0pe program>
  local i rc m="$W/mutant.sh"
  nmut=$((nmut+1))
  if ! perl -0pe "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed"; fails=$((fails+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  LAX=1; prep "$m"; rc=$?; LAX=""
  [ "$rc" = 0 ] || { echo "  BROKEN    $1 -- the mutant could not be extracted"; fails=$((fails+1)); return; }
  for i in "${!SHELLS[@]}"; do
    suite "$m" "${SHELLS[$i]}" "${LABELS[$i]}" quiet >/dev/null 2>&1; rc=$?
    case "$rc" in
      1) echo "  convicted [${LABELS[$i]}] $1" ;;
      0) echo "  SURVIVED  [${LABELS[$i]}] $1"; fails=$((fails+1)) ;;
      *) echo "  BROKEN    [${LABELS[$i]}] $1 -- the harness could not run it (rc=$rc), which is not a conviction"; fails=$((fails+1)) ;;
    esac
  done
  rm -rf "$R"
}
mut "S1 the uid extra is dropped"                        's/ --ei uid "\$_u"//'
mut "S2 an empty reply is read as RELEASED"              's/(    \*\) HS_VERDICT=)"ERR-HS noreply"( ;;\n  esac)/$1"OK RELEASED"$2/'
mut "S3 the boot sweep passes its uid instead of -1"     's/hs_release -1 boot/hs_release "\$uid" boot/'
mut "S4 the op arm's call moved into mdapply"            's/^    hs_release "\$uid" "\$name"[^\n]*\n//m; s/(^    dr_claim "\$uid"[^\n]*\n)/$1    hs_release "\$uid" "\$name"\n/m'
mut "S5 the reap line is removed"                        's/^  hs_release "\$uid" reap   # NWP-20261028-10[^\n]*\n//m'
mut "S6 the boot token keeps a space"                    's/_hs="failed\(\$\{HS_VERDICT#ERR-HS \}\)"/_hs="failed(\$HS_VERDICT)"/'
[ "$fails" = 0 ] && echo "== all $nmut mutations convicted (shells: ${LABELS[*]})" || { echo "== $fails mutation outcome(s) not convicted"; exit 1; }
