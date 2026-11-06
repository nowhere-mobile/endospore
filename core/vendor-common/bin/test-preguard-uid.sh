#!/usr/bin/env bash
# test-preguard-uid.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's ops that take a uid but no name, and so run BEFORE the
# shared argument guard, each refuse a uid under 10 and a uid with a leading zero (NWP-20261125-25).
#
# WHY THIS IS COMMITTED. The shared guard (test-uid-floor.sh, NWP-20261116-13) states the rule: a session uid is all
# digits, has no leading zero and is 10 or more. Eight arms sit above it and carry their own uid check. `verify` (the
# cold-lock RESUME credential check) and `resumeclear` refused only an empty or non-numeric uid, so uid 0 sent
# `cmd lock_settings verify`/`clear` against user 0, the gate, whose keyguard is held disabled. They and six other arms
# (locapply/locrelease, mdapply/mdrelease, dtclaim/dtrelease, evictcheck, deunpark, cleanstorage) took `010`, which
# passes the `-ge 10` floor and names no user: a `locapply` for `010` recorded owner `010`, and the release for the real
# session (`10`) then read "another owner" and left network location on. The daemon never sends such a uid; the request
# file is the only boundary between the confined daemon and this root worker, so the worker checks it.
#
# Each arm's guard prefix is extracted BY ANCHOR: its header line, then every following line that is a
# `  case "$uid" in` line, a `  [ "$uid" -ge 10 ]` line, a `  #` comment, cleanstorage's `  _ud_ssc0=` line or its
# `  if [ "$uid" -lt 10 ]` REJECT line, up to the first line that is none of these. A missing anchor, or an extract with
# no case line or that does not end on a guard line, is a HARNESS error (exit 2), never a pass. The extract is followed by
# a line that answers PASSED. Each case runs in a CHILD of each shell found among bash, sh, dash and mksh (the device's
# /system/bin/sh), so the guard's own `exit 0` ends the run file, never the suite. Each run file records the identity of
# the shell that ran it: no identity is a harness error, the wrong one that shell's FAIL. A mutant is convicted only when
# it fails under EVERY shell found. mksh reads a non-number in [ -ge ] as 0, silently, so the numeric check stays first.
# 0100 is in the matrix beside 010: it passes the floor whether a shell reads it as octal or decimal, so only the
# leading-zero arm refuses it.
#
#   bash test-preguard-uid.sh            # the cases
#   bash test-preguard-uid.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
runsh(){ "$1" "$2" >/dev/null 2>&1; }
# idok <shell> <id file> -> 0 iff the file holds at least one line and every line is that shell's identity
idok(){
  local s="$1" f="$2" l n=0
  [ -s "$f" ] || return 1
  while IFS= read -r l; do
    n=$((n+1))
    case "$s" in
      bash) case "$l" in bash:*'|none') ;; *) return 1 ;; esac ;;
      dash) [ "$l" = 'posix|none' ] || return 1 ;;
      mksh) case "$l" in 'ksh:|'*) return 1 ;; ksh:?*'|builtin') ;; *) return 1 ;; esac ;;
      sh)   [ "$l" = "$REF_SH" ] || return 1 ;;
      *)    return 1 ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ]
}
# notrun <shell> <case dir>: a run file that recorded no identity never launched -- a HARNESS error (noted in
# $W/harness, which suite turns into exit 2), never a behavioural FAIL a mutant could be convicted by. One that recorded
# the WRONG shell is noted in $W/notrun for suite's per-shell FAIL line.
notrun() {
  [ -s "$2/shell.id" ] || { echo "$1" >> "$W/harness"; return 1; }
  idok "$1" "$2/shell.id" || { echo "$1" >> "$W/notrun"; return 1; }
}

# The arms: <label>, <case id letter>, <ops>, and the exact header line (ARM_<label>).
ARMS="locapply mdapply dtclaim evictcheck deunpark verify resumeclear cleanstorage"
ARM_locapply='if [ "$op" = "locapply" ] || [ "$op" = "locrelease" ]; then'
ARM_mdapply='if [ "$op" = "mdapply" ] || [ "$op" = "mdrelease" ]; then'
ARM_dtclaim='if [ "$op" = "dtclaim" ] || [ "$op" = "dtrelease" ]; then'
ARM_evictcheck='if [ "$op" = "evictcheck" ]; then'
ARM_deunpark='if [ "$op" = "deunpark" ]; then'
ARM_verify='if [ "$op" = "verify" ]; then'
ARM_resumeclear='if [ "$op" = "resumeclear" ]; then'
ARM_cleanstorage='if [ "$op" = "cleanstorage" ]; then'
OPS_locapply="locapply locrelease"; OPS_mdapply="mdapply mdrelease"; OPS_dtclaim="dtclaim dtrelease"
OPS_evictcheck=evictcheck; OPS_deunpark=deunpark; OPS_verify=verify; OPS_resumeclear=resumeclear
OPS_cleanstorage=cleanstorage
ID_locapply=L; ID_mdapply=M; ID_dtclaim=T; ID_evictcheck=E; ID_deunpark=D; ID_verify=V; ID_resumeclear=R
ID_cleanstorage=C
header(){ eval "printf '%s' \"\$ARM_$1\""; }
armops(){ eval "printf '%s' \"\$OPS_$1\""; }
armid(){ eval "printf '%s' \"\$ID_$1\""; }

# extract <roamd.sh> <header> -> the arm's guard prefix; rc 2 if the header is not there exactly once, if no case line
# was kept, or if the last kept line is not a guard line (a comment or the _ud_ssc0 read)
extract() {
  local f="$1" h="$2" n
  n=$(grep -c -F -x -- "$h" "$f")
  [ "$n" = 1 ] || return 2
  awk -v h="$h" '
    !on { if ($0 == h) { print; on = 1 }; next }
    /^  case "\$uid" in / { print; kc = 1; last = "g"; next }
    /^  \[ "\$uid" -ge 10 \] / { print; last = "g"; next }
    /^  #/ { print; last = "c"; next }
    /^  _ud_ssc0=/ { print; last = "c"; next }
    /^  if \[ "\$uid" -lt 10 \]; then echo "\[roamd\] cleanstorage REJECT/ { print; last = "g"; next }
    { exit }
    END { if (!kc || last != "g") exit 2 }
  ' "$f"
}

# run_full <op> <uid> -> "<RES>|<mode of RES>", or NOTRUN / NOPARSE. Reads $s and $blk from the calling suite.
run_full() {
  local d
  d=$(mktemp -d -p "$W") || exit 2
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'op=%s; uid=%s; RES=%s; LOG=%s\n' "$(sq "$1")" "$(sq "$2")" "$(sq "$d/res")" "$(sq "$d/log")"
    printf '%s\n' 'getprop() { echo 7; }'
    printf '%s\n' "$blk"
    printf '%s\n' '  echo PASSED > "$RES"; exit 0' 'fi'
  } > "$d/run.sh"
  if ! "$s" -n "$d/run.sh" >/dev/null 2>&1; then
    echo "$s" >> "$W/parse"; echo NOPARSE
  else
    runsh "$s" "$d/run.sh"
    if notrun "$s" "$d"; then
      printf '%s|%s\n' "$(cat "$d/res" 2>/dev/null)" "$(stat -c %a "$d/res" 2>/dev/null)"
    else
      echo NOTRUN
    fi
  fi
  rm -rf "$d"
}

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" p=0 x=0 blk out arm o u id n
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  : > "$W/notrun"; : > "$W/harness"; : > "$W/parse"

  for arm in $ARMS; do
    blk=$(extract "$f" "$(header "$arm")") || {
      echo "EXTRACTION FAILED -- the $arm arm's header or guard prefix moved in $f" >&2; return 2; }
    id=$(armid "$arm"); n=0
    for o in $(armops "$arm"); do
      for u in 0 9 00 007 010 0100 1x ''; do
        n=$((n+1)); out=$(run_full "$o" "$u")
        [ "$out" = 'ERR-UID|600' ] && ok "$id$n $o uid '$u' is refused: ERR-UID, RES mode 600" \
          || no "$id$n $o uid '$u' got '$out', not ERR-UID|600"
      done
      for u in 10 123; do
        n=$((n+1)); out=$(run_full "$o" "$u")
        [ "${out%%|*}" = PASSED ] && ok "$id$n $o uid '$u' passes the guard (control)" \
          || no "$id$n $o uid '$u' got '$out', not PASSED"
      done
    done
  done

  if [ -s "$W/parse" ]; then echo "HARNESS ERROR: a run file does not parse under $s" >&2; return 2; fi
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  # run_full runs inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
FAILED=0; HARNESS=0
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  case "$rc" in 0) ;; 1) FAILED=1 ;; *) HARNESS=1 ;; esac
done
[ "$HARNESS" = 0 ] || { echo "HARNESS ERROR"; exit 2; }
[ "$FAILED" = 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED under every shell found)"
mtmp=$(mktemp -d -p "$W") || exit 2
# ere <text> -> <text> escaped for a sed -E address
ere(){ printf '%s' "$1" | sed -E 's/[][\.*^$|?+(){}\/]/\\&/g'; }
mut() { # mut <label> <sed -E program>
  local m="$mtmp/r.sh" s r alive="" err=""
  if ! sed -E -e "$2" "$SUT" > "$m"; then echo "  ERR       $1 -- the sed program failed"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  for s in $SHELLS; do
    suite "$m" "$s" quiet >/dev/null 2>&1; r=$?
    case "$r" in 0) alive="$alive $s" ;; 1) ;; *) err="$err $s" ;; esac
  done
  if [ -n "$alive" ]; then echo "  SURVIVED  $1 -- under:$alive"; return 1; fi
  if [ -n "$err" ]; then echo "  HARNESS ERROR (not a conviction) $1 -- under:$err"; return 1; fi
  echo "  convicted $1 -- under:$SHELLS"; return 0
}
fails=0
for arm in $ARMS; do
  # only the arm's first line, its uid case
  mut "the $arm arm's |0?* removed" "/^$(ere "$(header "$arm")")\$/{n;s@\\|0\\?\\*\\) echo \"ERR-UID\"@) echo \"ERR-UID\"@}" || fails=$((fails+1))
done
for arm in verify resumeclear; do
  mut "the $arm arm's floor removed" "/^$(ere "$(header "$arm")")\$/,/^fi\$/{/^  \\[ \"\\\$uid\" -ge 10 \\] \\|\\| /d}" || fails=$((fails+1))
done

# harness-error probes: each must end the suite with exit 2 and HARNESS ERROR -- not exit 1 with FAIL lines, which a
# mutation run would count as a conviction
hprobe() {  # hprobe <label> <suite file> <roamd file>
  local rc out
  out=$(bash "$2" "$3" 2>&1); rc=$?
  case "$rc:$out" in 2:*'HARNESS ERROR'*) echo "  ok        $1 -- harness error, not a conviction"; return 0 ;; esac
  echo "  HARNESS ERROR NOT RAISED $1 (rc $rc)"; return 1
}
probe_anchor() {
  local m="$mtmp/r-anchor.sh"
  sed 's/^if \[ "\$op" = "evictcheck" \]; then$/if [ "$op" = "evictcheck2" ]; then/' "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     an anchor is missing -- the mutation changed nothing"; return 1; fi
  hprobe 'an anchor is missing' "$0" "$m"
}
probe_noguard() {
  local m="$mtmp/r-noguard.sh"
  sed -E '/^if \[ "\$op" = "deunpark" \]; then$/,/^fi$/{/^  (case "\$uid" in |\[ "\$uid" -ge 10 \] )/d}' "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     an arm keeps no guard line -- the mutation changed nothing"; return 1; fi
  hprobe 'an arm keeps no guard line' "$0" "$m"
}
probe_tail() {
  local m="$mtmp/r-tail.sh"
  sed '/^  if \[ "\$uid" -lt 10 \]; then echo "\[roamd\] cleanstorage REJECT/d' "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     an extract ends on a non-guard line -- the mutation changed nothing"; return 1; fi
  hprobe 'an extract ends on a non-guard line' "$0" "$m"
}
probe_launch() {
  local cp="$mtmp/suite-probe.sh"
  sed 's/^runsh(){ .*$/runsh(){ return 127; }/' "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  INERT     the child never launches -- the mutation changed nothing"; return 1; fi
  hprobe 'the child never launches' "$cp" "$SUT"
}
probe_anchor || fails=$((fails+1))
probe_noguard || fails=$((fails+1))
probe_tail || fails=$((fails+1))
probe_launch || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave ($fails)"; exit 1; }
