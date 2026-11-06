#!/usr/bin/env bash
# test-uid-floor.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's shared argument guard refuses a uid under 10 and a uid
# with a leading zero (NWP-20261116-13).
#
# WHY THIS IS COMMITTED. Every op behind the guard (in, out, grant, seedssaid, sealdelta, ...) builds root paths from
# the uid. The guard refused only an empty or non-numeric uid, so uid 0 passed: an `in` would restore a vault into
# /data/user/0, the gate's own CE, which the reap never clears (cleanstorage refuses uid < 10 itself), and a seedssaid
# would drop user 0's settings_ssaid.xml. A uid with a leading zero (0123) passed too and named a path no user has.
# The rule is the one cleanstorage states: only secondary users (uid >= 10), never user 0's storage.
#
# The guard is extracted BY ANCHOR, from the ERR-ARGS line through `USERDIR="/data/user/$uid"`, and followed by a line
# that answers PASSED. Each case writes its variables and that region into a run file and executes the file in a CHILD
# of each shell found among bash, sh, dash and mksh (the device's /system/bin/sh), so the guard's own `exit 0` ends the
# run file, never the suite. Each run file records the identity of the shell that ran it: no identity is a HARNESS
# error (exit 2), the wrong one that shell's FAIL. A mutant is convicted only when every shell found has its own
# failing line. mksh reads a non-number in [ -ge ] as 0, silently, so the numeric check must stay first.
#
#   bash test-uid-floor.sh            # the cases
#   bash test-uid-floor.sh --mutate   # ... plus mutations that must each CONVICT the suite
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

START='[ -n "$op" ] && [ -n "$name" ] && [ -n "$uid" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }'
END='USERDIR="/data/user/$uid"'

# extract <roamd.sh> -> the guard region, START through the first END after it; rc 2 if an anchor is missing
extract() {
  local f="$1" a b
  a=$(grep -n -F -x "$START" "$f" | head -1 | cut -d: -f1)
  [ -n "$a" ] || return 2
  b=$(tail -n +"$a" "$f" | grep -n -F -x "$END" | head -1 | cut -d: -f1)
  [ -n "$b" ] || return 2
  sed -n "${a},$((a+b-1))p" "$f"
}

# run_full <uid> -> "<RES>|<mode of RES>|<log lines>", or NOTRUN / NOPARSE. Reads $s and $blk from the calling suite.
run_full() {
  local d
  d=$(mktemp -d -p "$W") || exit 2
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'op=in; name=x; uid=%s; RES=%s; LOG=%s\n' "$(sq "$1")" "$(sq "$d/res")" "$(sq "$d/log")"
    printf '%s\n' "$blk"
    printf '%s\n' 'echo PASSED > "$RES"'
  } > "$d/run.sh"
  if ! "$s" -n "$d/run.sh" >/dev/null 2>&1; then
    echo "$s" >> "$W/parse"; echo NOPARSE
  else
    runsh "$s" "$d/run.sh"
    if notrun "$s" "$d"; then
      printf '%s|%s|%s\n' "$(cat "$d/res" 2>/dev/null)" "$(stat -c %a "$d/res" 2>/dev/null)" \
        "$(grep -c 'refused' "$d/log" 2>/dev/null)"
    else
      echo NOTRUN
    fi
  fi
  rm -rf "$d"
}
# run <uid> -> what the guard answered in RES
run() { local o; o=$(run_full "$@"); echo "${o%%|*}"; }

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" p=0 x=0 blk out u c
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }

  blk=$(extract "$f") || { echo "EXTRACTION FAILED -- an anchor of the shared guard moved in $f" >&2; return 2; }
  : > "$W/notrun"; : > "$W/harness"; : > "$W/parse"

  [ "$(run '')" = ERR-ARGS ] && ok "U1 an empty uid answers ERR-ARGS" || no "U1 an empty uid did not answer ERR-ARGS"
  [ "$(run 1a)" = ERR-UID ] && ok "U2 a non-numeric uid answers ERR-UID" || no "U2 a non-numeric uid did not answer ERR-UID"
  for c in 'U3 0' 'U4 9' 'U5 0123' 'U6 00'; do
    u="${c#* }"
    out=$(run_full "$u")
    [ "$out" = 'ERR-UID|600|1' ] && ok "${c%% *} uid $u is refused: ERR-UID, one log line, RES mode 600" \
      || no "${c%% *} uid $u got '$out', not ERR-UID|600|1"
  done
  [ "$(run 10)" = PASSED ] && ok "U7 uid 10 passes the guard (control)" || no "U7 uid 10 did not pass the guard"
  [ "$(run 12345)" = PASSED ] && ok "U8 uid 12345 passes the guard (control)" || no "U8 uid 12345 did not pass the guard"

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

echo "== mutations (each must be CONVICTED under every shell found, by the cases named)"
mtmp=$(mktemp -d -p "$W") || exit 2
mut() { # mut <label> <sed-expr> <case ids that must each fail under every shell>
  local m="$mtmp/r.sh" s r out id alive="" err="" lost=""
  sed -e "$2" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  for s in $SHELLS; do
    out=$(suite "$m" "$s" 2>&1); r=$?
    case "$r" in
      0) alive="$alive $s" ;;
      1) for id in $3; do case "$out" in *"FAIL  [$s] $id "*) ;; *) lost="$lost $s:$id" ;; esac; done ;;
      *) err="$err $s" ;;
    esac
  done
  if [ -n "$alive" ]; then echo "  SURVIVED  $1 -- under:$alive"; return 1; fi
  if [ -n "$err" ]; then echo "  HARNESS ERROR (not a conviction) $1 -- under:$err"; return 1; fi
  if [ -n "$lost" ]; then echo "  NOT CONVICTED $1 -- no failing line of the named case under:$lost"; return 1; fi
  echo "  convicted $1 -- by $3 under:$SHELLS"; return 0
}
fails=0
mut "F1 the -ge 10 floor deleted"      '/uid \$uid refused (under 10/d' 'U3 U4' || fails=$((fails+1))
mut "F2 the floor lowered to -ge 1"    '/uid \$uid refused (under 10/s/\[ "\$uid" -ge 10 \]/[ "$uid" -ge 1 ]/' 'U4' || fails=$((fails+1))
mut "F3 the leading-zero refusal deleted" '/uid \$uid refused (leading zero)/d' 'U5' || fails=$((fails+1))

# the runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash shell
mutate_runner() {
  local s want="" cp="$mtmp/suite-runner.sh" out rc
  sed 's/^runsh(){ "\$1" "\$2"/runsh(){ bash "$2"/' "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  INERT     the runner always runs bash -- the mutation changed nothing"; return 1; fi
  for s in $SHELLS; do
    case "$s" in
      bash) ;;
      sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
      *) want="$want $s" ;;
    esac
  done
  [ -n "$want" ] || { echo "  n/a       the runner always runs bash -- no non-bash shell on this host (CI has dash and mksh)"; return 0; }
  out=$(bash "$cp" "$SUT" 2>&1); rc=$?
  runner_verdict "$rc" "$out" "$want"
}
# runner_verdict <rc> <output> <shells> -> 0 iff the mutated suite FAILED (exit 1, never 2: a harness error is not a
# conviction, whatever FAIL lines came before it) with a failing line of its own under each of <shells>
runner_verdict() {
  local rc="$1" out="$2" want="$3" s bad=""
  if [ "$rc" != 1 ]; then echo "  NOT CONVICTED the runner always runs bash -- the suite exited $rc, not 1"; return 1; fi
  for s in $want; do case "$out" in *"FAIL  [$s]"*) ;; *) bad="$bad $s" ;; esac; done
  if [ -z "$bad" ]; then echo "  convicted the runner always runs bash -- under:$want"; return 0; fi
  echo "  SURVIVED  the runner always runs bash -- under:$bad"; return 1
}
# runner_verdict must refuse a harness error that printed every shell's FAIL line, and accept exit 1 with them
verdict_probe() {
  local fake=$'  FAIL  [dash] U3 uid 0 got PASSED\n  FAIL  [mksh] U3 uid 0 got PASSED\nHARNESS ERROR'
  if runner_verdict 2 "$fake" "dash mksh" >/dev/null; then
    echo "  CONVICTED ON A HARNESS ERROR  runner_verdict took exit 2 with FAIL lines"; return 1
  fi
  if ! runner_verdict 1 "${fake%HARNESS ERROR}FAILED" "dash mksh" >/dev/null; then
    echo "  REFUSED A REAL FAILURE  runner_verdict refused exit 1 with every shell's FAIL line"; return 1
  fi
  echo "  ok        runner_verdict: exit 2 with FAIL lines is not a conviction, exit 1 with them is"
}
# harness-error probe: a child that never launches must end the suite with exit 2 and HARNESS ERROR -- not exit 1 with
# FAIL lines, which a mutation run would count as a conviction
probe() {  # probe <label> <sed program over this suite>
  local cp="$mtmp/suite-probe.sh" rc out
  sed "$2" "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  out=$(bash "$cp" "$SUT" 2>&1); rc=$?
  case "$rc:$out" in 2:*'HARNESS ERROR'*) echo "  ok        $1 -- harness error, not a conviction"; return 0 ;; esac
  echo "  HARNESS ERROR NOT RAISED $1 (rc $rc)"; return 1
}
probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/' || fails=$((fails+1))
# an anchor that moved must end the suite with exit 2, never a pass or a FAIL a mutant could be convicted by
anchor_probe() {
  local m="$mtmp/r-anchor.sh" rc out
  sed 's/^USERDIR="\/data\/user\/\$uid"$/USERDIR="\/data\/user\/${uid}"/' "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     the end anchor moved -- the mutation changed nothing"; return 1; fi
  out=$(bash "$0" "$m" 2>&1); rc=$?
  case "$rc:$out" in 2:*'EXTRACTION FAILED'*) echo "  ok        the end anchor moved -- harness error, not a conviction"; return 0 ;; esac
  echo "  HARNESS ERROR NOT RAISED the end anchor moved (rc $rc)"; return 1
}
anchor_probe || fails=$((fails+1))
verdict_probe || fails=$((fails+1))
mutate_runner || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
