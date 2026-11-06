#!/usr/bin/env bash
# test-evict-verdict.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's cold-lock eviction probe (NWP-20261004-01):
# ev_probe / ev_verdict, and the dropcaches and evictcheck ops that report them.
#
# WHY THIS IS COMMITTED. The probe's verdict now DECIDES something: the daemon's EVICT-RECHECK wipes a cold-locked
# session whose CE is still readable after vold gave up (when its last save landed). Both of the probe's checks fail
# OPEN -- a missing dd, a denied read, an ls the worker's domain may not run all print nothing, which is exactly
# what "evicted" prints -- so ev_verdict runs the same two primitives against user 0, whose CE is unlocked for as
# long as the phone is on, and answers "cannot tell" unless that control sees both. This suite pins that a blind
# probe can never read as "evicted", that a readable CE always reads as incomplete, and that the settle re-check only
# forgives a CE that really did clear.
#
# Blocks are extracted from nowhere_roamd.sh BY ANCHOR, never copied; if the anchors move, extraction fails loudly
# rather than a stale copy passing forever. `ls`, `dd` and `sleep` are stubbed as shell functions over a simulated
# CE per user; they answer only the paths and arguments roamd really uses and record anything else, so a probe
# pointed at the wrong path fails the suite instead of passing it. The ops' drop_caches write is redirected into the
# scratch dir: the CI runner may be root, and the suite must not drop the host's caches.
#
# Every case and every mutant runs under EACH of bash, sh, dash and mksh found on PATH (deduped by realpath),
# labelled [<shell>]: the stubs and the extracted code execute IN the shell under test, as a script it runs, never in
# this suite's bash. mksh is the device's /system/bin/sh and reads a non-number in `[ x -gt 0 ]` as 0 without an
# error -- exactly the `${_settle:-0}` test EVICT-RECHECK's wipe verdict relies on -- so a change correct in bash and
# wrong there must not pass.
#
#   bash test-evict-verdict.sh            # the behaviour cases
#   bash test-evict-verdict.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Shells: bash, plus sh/dash/mksh where they are a different interpreter (deduped by realpath).
SHELLS=""; SEEN=" "
for cand in bash sh dash mksh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "; SHELLS="$SHELLS $p"
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }

extract_fns() { sed -n '/^ev_probe() {$/,/^}$/p; /^ev_verdict() {$/,/^}$/p' "$1"; }
extract_op() { sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"; }

# The simulated device. State is one empty file per readable thing in $D:
#   u<N>.android     /data/user/<N>/android resolves
#   ce<N>            /data/system_ce/<N>/accounts_ce.db reads as plaintext SQLite
#   settle.u<N>      the first sleep evicts u<N>.android   (an eviction still in flight at the first probe)
#   settle.ce<N>     the first sleep evicts ce<N>
#   blind.ls         ls -d fails for every path            (a domain that may not run it)
#   blind.dd         dd prints nothing for every file      (a missing dd, a denied read)
STUBS='
ls() {
  [ "${1:-}" = -d ] && [ $# = 2 ] || { echo "ls $*" >> "$D/unexpected"; return 1; }
  [ -f "$D/blind.ls" ] && return 1
  case "$2" in
    /data/user/*/android) local u="${2#/data/user/}"; u="${u%/android}"; [ -f "$D/u$u.android" ] ;;
    *) echo "ls $*" >> "$D/unexpected"; return 1 ;;
  esac
}
dd() {
  local f="" a
  for a in "$@"; do
    case "$a" in if=*) f="${a#if=}" ;; bs=6|count=1) : ;; *) echo "dd $*" >> "$D/unexpected"; return 1 ;; esac
  done
  [ -f "$D/blind.dd" ] && return 1
  case "$f" in
    /data/system_ce/*/accounts_ce.db)
      local u="${f#/data/system_ce/}"; u="${u%/accounts_ce.db}"
      [ -f "$D/ce$u" ] && { printf SQLite; return 0; }
      return 1 ;;                                   # an evicted CE file: the open fails (ENOKEY)
    *) echo "dd $*" >> "$D/unexpected"; return 1 ;;
  esac
}
sleep() {
  echo "$1" >> "$D/slept"
  local s
  for s in "$D"/settle.*; do [ -f "$s" ] || continue; command rm -f "$D/${s##*/settle.}"*; done
  return 0
}
sync() { :; }
stop_mediad() { echo stop_mediad >> "$D/calls"; }
rm() { echo "rm $*" >> "$D/calls"; }
'
printf '%s\n' "$STUBS" > "$W/stubs.sh"

setup() {  # setup <dir> <token>... -- plant the simulated device
  local d="$1" t; shift
  for t in "$@"; do
    case "$t" in
      settle.u*) : > "$d/$t"; : > "$d/${t#settle.}.android" ;;
      settle.ce*) : > "$d/$t"; : > "$d/${t#settle.}" ;;
      *) : > "$d/$t" ;;
    esac
  done
}

# verdict <shell> <fns> <uid> <settle> <token>... -> "<verdict>|<slept,>|<unexpected>"
verdict() {
  local sh="$1" fns="$2" uidv="$3" settle="$4" d out; shift 4
  d=$(mktemp -d -p "$W"); setup "$d" "$@"
  { printf "D='%s'\n" "$d"; cat "$W/stubs.sh" "$fns"; printf "ev_verdict '%s' '%s'\n" "$uidv" "$settle"; } > "$d/run.sh"
  out=$("$sh" "$d/run.sh" 2>/dev/null)
  printf '%s|%s|%s\n' "$out" "$(cat "$d/slept" 2>/dev/null | tr '\n' ,)" "$(cat "$d/unexpected" 2>/dev/null)"
  command rm -rf "$d"
}

# op <shell> <fns> <block> <op> <uid> <token>... -> "<RES>|<drops>|<last log line>|<unexpected>"
op() {
  local sh="$1" fns="$2" blk="$3" opv="$4" uidv="$5" d; shift 5
  d=$(mktemp -d -p "$W"); setup "$d" "$@"
  {
    printf "D='%s' RES='%s/res' LOG='%s/log' op='%s' uid='%s'\n" "$d" "$d" "$d" "$opv" "$uidv"
    cat "$W/stubs.sh" "$fns"
    sed "s@/proc/sys/vm/drop_caches@$d/drop_caches@g" "$blk"
  } > "$d/run.sh"
  "$sh" "$d/run.sh" >/dev/null 2>&1
  printf '%s|%s|%s|%s\n' "$(cat "$d/res" 2>/dev/null)" "$(cat "$d/drop_caches" 2>/dev/null)" \
    "$(tail -1 "$d/log" 2>/dev/null)" "$(cat "$d/unexpected" 2>/dev/null)"
  command rm -rf "$d"
}

CTL="u0.android ce0"   # user 0's CE as it always is on a running phone: both readable

suite() {  # suite <roamd.sh> <quiet> <shell> -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" sh="$3" fns ec dc p=0 x=0 out label
  label=$(basename "$sh")
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$label" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$label" "$1"; }
  fns=$(mktemp -p "$W"); ec=$(mktemp -p "$W"); dc=$(mktemp -p "$W")
  extract_fns "$f" > "$fns"; extract_op "$f" evictcheck > "$ec"; extract_op "$f" dropcaches > "$dc"
  if ! grep -q '^ev_verdict() {' "$fns" || ! grep -q '^ev_probe() {' "$fns" \
     || ! grep -q 'ev_verdict' "$ec" || ! grep -q 'ev_verdict' "$dc"; then
    echo "EXTRACTION FAILED: ev_probe/ev_verdict/evictcheck/dropcaches missing in $f" >&2
    command rm -f "$fns" "$ec" "$dc"; return 2
  fi
  if ! "$sh" -n "$W/stubs.sh" || ! "$sh" -n "$fns" || ! "$sh" -n "$ec" || ! "$sh" -n "$dc"; then
    echo "EXTRACTION FAILED: a block does not parse in $f under $label" >&2; command rm -f "$fns" "$ec" "$dc"; return 2
  fi

  # --- ev_verdict ---
  out=$(verdict "$sh" "$fns" 15 5 $CTL)
  case "$out" in "OK EVICTED||") ok "E1 control sees user 0, user 15 unreadable -> OK EVICTED, no settle wait" ;; *) no "E1 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 $CTL ce15)
  case "$out" in "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)|5,|") ok "E2 a plaintext accounts_ce.db -> INCOMPLETE, after one settle wait" ;;
    *) no "E2 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 $CTL u15.android ce15)
  case "$out" in "ERR-EVICT-INCOMPLETE /data/user/15/android /data/system_ce/15/accounts_ce.db(PLAINTEXT)|5,|") ok "E3 both readable -> INCOMPLETE naming both paths" ;;
    *) no "E3 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 $CTL settle.u15)
  case "$out" in "OK EVICTED settled|5,|") ok "E4 readable at the first probe, cleared by the re-check -> OK EVICTED settled" ;;
    *) no "E4 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 $CTL settle.u15 ce15)
  case "$out" in "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)|5,|") ok "E5 the re-check reports what SURVIVED it" ;;
    *) no "E5 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 0 $CTL ce15)
  case "$out" in "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)||") ok "E6 settle 0 -> one probe, no wait" ;;
    *) no "E6 got '$out'" ;; esac
  # ⚠ THE DEFECT CLASS: a probe that cannot see must never answer "evicted".
  out=$(verdict "$sh" "$fns" 15 5 $CTL blind.dd blind.ls)
  case "$out" in "ERR-EVICT-PROBE "*) ok "E7 fully blind (no ls, no dd) -> ERR-EVICT-PROBE, never OK" ;; *) no "E7 a BLIND probe got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 $CTL blind.dd)
  case "$out" in "ERR-EVICT-PROBE "*) ok "E8 dd blind (the accounts check cannot read) -> ERR-EVICT-PROBE" ;; *) no "E8 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 $CTL blind.ls)
  case "$out" in "ERR-EVICT-PROBE "*) ok "E9 ls blind (the directory check cannot resolve) -> ERR-EVICT-PROBE" ;; *) no "E9 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 $CTL blind.dd ce15)
  case "$out" in "ERR-EVICT-PROBE "*) ok "E10 blind with a readable target -> ERR-EVICT-PROBE (the control decides first)" ;; *) no "E10 got '$out'" ;; esac
  out=$(verdict "$sh" "$fns" 15 5 u0.android)
  case "$out" in "ERR-EVICT-PROBE "*) ok "E11 a control that sees only half of user 0 -> ERR-EVICT-PROBE" ;; *) no "E11 got '$out'" ;; esac

  # --- evictcheck ---
  out=$(op "$sh" "$fns" "$ec" evictcheck 15 $CTL ce15)
  case "$out" in "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)|3|"*"evictcheck user 15: ERR-EVICT-INCOMPLETE"*"|") ok "C1 evictcheck: drops caches, replies and logs the verdict" ;;
    *) no "C1 got '$out'" ;; esac
  out=$(op "$sh" "$fns" "$ec" evictcheck 15 $CTL)
  case "$out" in "OK EVICTED|3|"*) ok "C2 evictcheck on an evicted CE -> OK EVICTED" ;; *) no "C2 got '$out'" ;; esac
  out=$(op "$sh" "$fns" "$ec" evictcheck 9 $CTL u9.android ce9)
  case "$out" in "ERR-UID||"*) ok "C3 evictcheck refuses a uid below 10, before probing or dropping" ;; *) no "C3 got '$out'" ;; esac
  out=$(op "$sh" "$fns" "$ec" evictcheck 1x $CTL)
  case "$out" in "ERR-UID||"*) ok "C4 evictcheck refuses a non-numeric uid" ;; *) no "C4 got '$out'" ;; esac

  # --- dropcaches ---
  out=$(op "$sh" "$fns" "$dc" dropcaches 15 $CTL ce15)
  case "$out" in "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)|3|"*) ok "D1 dropcaches replies the verdict, not a bare OK" ;;
    *) no "D1 got '$out'" ;; esac
  out=$(op "$sh" "$fns" "$dc" dropcaches "" $CTL)
  case "$out" in "OK|3|"*) ok "D2 dropcaches without a uid still drops and replies OK" ;; *) no "D2 got '$out'" ;; esac
  out=$(op "$sh" "$fns" "$dc" dropcaches 15 $CTL blind.dd)
  case "$out" in *"EVICT-PROBE-BLIND user 15"*) ok "D3 a blind probe is LOGGED as blind, not as evict ok" ;; *) no "D3 got '$out'" ;; esac

  command rm -f "$fns" "$ec" "$dc"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed [%s]\n' "$p" "$x" "$label"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "cold-lock eviction probe: $SUT (shells:$SHELLS)"
for sh in $SHELLS; do
  suite "$SUT" "" "$sh" || FAILED=1
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mutate() {  # <label> <sed program>; convicted under EACH shell's own line
    local label="$1" prog="$2" mf r sh
    mf=$(mktemp -p "$W")
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; command rm -f "$mf"; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; command rm -f "$mf"; return; fi
    for sh in $SHELLS; do
      suite "$mf" quiet "$sh" >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-64s SURVIVED [%s]\n' "$label" "${sh##*/}"; MFAIL=1 ;;
        1) printf '  ok    %-64s convicted [%s]\n' "$label" "${sh##*/}" ;;
        *) printf '  ERR   %-64s harness error (rc=%s), not a conviction [%s]\n' "$label" "$r" "${sh##*/}"; MFAIL=1 ;;
      esac
    done
    command rm -f "$mf"
  }
  mutate 'no control: a blind probe reads as evicted'       's@^    \*\) echo "ERR-EVICT-PROBE .*; return 0 ;;$@    *) : ;;@'
  mutate 'the control checks only the directory'            's@\*"/data/user/0/android"\*"/data/system_ce/0/accounts_ce.db\(PLAINTEXT\)"\*\)@*"/data/user/0/android"*)@'
  mutate 'the control probes the target user'               's@_ctl=\$\(ev_probe 0\)@_ctl=$(ev_probe "$_uid")@'
  mutate 'the accounts_ce.db check is dropped'              's@= "SQLite" \]; then@= "never" ]; then@'
  mutate 'the directory check is dropped'                   's@^  ls -d "/data/user/\$1/android" .*$@  :@'
  mutate 'the settle re-check is skipped'                   's@^    _ev2=\$\(ev_probe "\$_uid"\)$@    :@'
  mutate 'a readable CE after the settle reads as evicted'  's@^  if \[ -n "\$_ev2" \]; then echo "ERR-EVICT-INCOMPLETE\$_ev2"$@  if false; then :@'
  mutate 'evictcheck does not drop caches'                  '/^if \[ "\$op" = "evictcheck" \]; then$/,/^fi$/ s@^  echo 3 > /proc/sys/vm/drop_caches.*$@  :@'
  mutate 'evictcheck accepts a uid below 10'                's@^  \[ "\$uid" -ge 10 \] \|\| \{ echo "ERR-UID".*$@  :@'
  mutate 'dropcaches replies a bare OK again'               's@^  echo "\$\{_ev:-OK\}" > "\$RES"; chmod 600 "\$RES"; exit 0$@  echo "OK" > "$RES"; chmod 600 "$RES"; exit 0@'
  mutate 'dropcaches logs a blind probe as evict ok'        's@^        ERR-EVICT-PROBE\*\)$@        ERR-EVICT-PROBE-NEVER*)@'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
fi

exit "${FAILED:-0}"
