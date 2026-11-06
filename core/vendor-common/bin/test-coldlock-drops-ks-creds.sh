#!/usr/bin/env bash
# test-coldlock-drops-ks-creds.sh [<nowhere_roamd.sh>] [--mutate] -- a committed cold lock drops the keystore-push
# stash, which holds the session's PLAINTEXT passphrase (NWP-20261005-17, P1).
#
# WHY THIS IS COMMITTED. Every roamd `out` writes $STATE/ks-logoff-creds (name, passphrase, uid) for cleanstorage's
# keystore push, and only `in` and cleanstorage removed it. A cold lock runs neither, so the passphrase sat in the
# tmpfs for the whole lock. The fix is one line in the btpark op, which the agent's teardown runs only once the lock
# has committed. It is silent when it regresses -- the lock still works, the file just stays -- so this pins it.
#
# The btpark/btresume block is extracted BY ANCHOR and run against temp files with the Bluetooth helpers stubbed.
# Each case writes the block, its variables and the stubs into a run file and executes that file in a CHILD of each
# shell found among bash, sh, dash and mksh (the device's /system/bin/sh), so the block's own `exit 0` ends the run
# file, never the suite. Each run file records the identity of the shell that ran it and the suite asserts it is the
# shell the case launched: no identity is a HARNESS error (exit 2), the wrong one that shell's FAIL. The W1 source pin
# runs once. A mutant is convicted only when every shell found has its own failing line (NWP-20261113-33).
#
# The B cases pin the arm's uid floor (NWP-20261116-13): the arm runs ahead of roamd's shared guard, so it refuses a
# uid under 10 or with a leading zero itself, before either Bluetooth helper runs, and still after the stash drop.
# The stubs record each call in the case dir, so a refused request must show that neither helper ran.
#
#   bash test-coldlock-drops-ks-creds.sh            # the cases
#   bash test-coldlock-drops-ks-creds.sh --mutate   # ... plus mutations that must each CONVICT the suite
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

ANCHOR='if [ "$op" = "btpark" ] || [ "$op" = "btresume" ]; then'

extract() { awk -v a="$ANCHOR" 'index($0,a)==1{on=1} on{print} on&&/^fi$/{exit}' "$1"; }

# run_calls <op> <uid> -> "<KEPT|GONE|NOTRUN|NOPARSE>|<RES>|<calls>": the stash after the block ran under suite's $s,
# what the block answered, and the Bluetooth stubs it called (sorted, comma-joined, or none). Reads $s and $blk from
# the calling suite.
run_calls() {
  local d st c
  d=$(mktemp -d -p "$W") || exit 2
  printf 'alice\nsecret\n10\n' > "$d/ks"
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'op=%s; uid=%s; KS_CREDS=%s; RES=%s; LOG=%s; BT_RESTORED=0\n' \
      "$(sq "$1")" "$(sq "$2")" "$(sq "$d/ks")" "$(sq "$d/res")" "$(sq "$d/log")"
    printf 'bt_seal_capture(){ echo bt_seal_capture >> %s; return 0; }; bt_reset(){ echo bt_reset >> %s; return 0; }\n' \
      "$(sq "$d/calls")" "$(sq "$d/calls")"
    printf '%s\n' "$blk"
  } > "$d/run.sh"
  if ! "$s" -n "$d/run.sh" >/dev/null 2>&1; then
    echo "$s" >> "$W/parse"; st=NOPARSE
  else
    runsh "$s" "$d/run.sh"
    if [ -e "$d/ks" ]; then st=KEPT; else st=GONE; fi
    notrun "$s" "$d" || st=NOTRUN
  fi
  c=none; [ -s "$d/calls" ] && c=$(sort -u "$d/calls" | paste -sd, -)
  printf '%s|%s|%s\n' "$st" "$(cat "$d/res" 2>/dev/null)" "$c"
  rm -rf "$d"
}
# run_full <op> <uid> -> "<KEPT|GONE|NOTRUN|NOPARSE>|<RES>": run_calls without the calls
run_full() { local o; o=$(run_calls "$@"); echo "${o%|*}"; }
# run <op> <uid> -> "KEPT" or "GONE" for the stash after the block ran
run() { local o; o=$(run_full "$@"); echo "${o%%|*}"; }

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" p=0 x=0 blk out
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }

  blk=$(extract "$f")
  case "$blk" in *'bt_seal_capture'*) ;; *) echo "EXTRACTION FAILED -- the btpark block moved in $f" >&2; return 2 ;; esac
  : > "$W/notrun"; : > "$W/harness"; : > "$W/parse"

  [ "$(run btpark 10)" = GONE ] && ok "C1 a committed lock's btpark drops the stash" || no "C1 the stash survived btpark"
  [ "$(run btpark '')" = GONE ] && ok "C2 a malformed btpark still drops it (before the uid check)" || no "C2 a bad uid skipped the drop"
  [ "$(run btresume 10)" = KEPT ] && ok "C3 btresume leaves it alone (only the lock drops it)" || no "C3 btresume removed the stash"
  out=$(run_full btresume 1x)
  [ "$out" = 'KEPT|ERR-UID' ] && ok "C4 a malformed btresume keeps the stash and answers ERR-UID" || no "C4 a malformed btresume got '$out'"
  out=$(run_calls btpark 10)
  [ "$out" = 'GONE|OK|bt_reset,bt_seal_capture' ] && ok "B1 btpark uid 10 runs both Bluetooth helpers (control)" || no "B1 btpark uid 10 got '$out'"
  out=$(run_calls btpark 0); out="${out#*|}"
  [ "$out" = 'ERR-UID|none' ] && ok "B2 btpark uid 0 answers ERR-UID and runs no Bluetooth helper" || no "B2 btpark uid 0 got '$out'"
  out=$(run_calls btresume 9); out="${out#*|}"
  [ "$out" = 'ERR-UID|none' ] && ok "B3 btresume uid 9 answers ERR-UID and runs no Bluetooth helper" || no "B3 btresume uid 9 got '$out'"
  out=$(run_full btpark 0)
  [ "$out" = 'GONE|ERR-UID' ] && ok "B4 btpark uid 0 still drops the stash, then answers ERR-UID" || no "B4 btpark uid 0 got '$out'"

  if [ -s "$W/parse" ]; then echo "HARNESS ERROR: a run file does not parse under $s" >&2; return 2; fi
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  # run_full runs inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

pins() {  # pins <roamd.sh> -> 0 ok, 1 a pin failed; source pins, run once, whatever the shell
  local f="$1" p=0 x=0
  ok(){ p=$((p+1)); printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  %s\n' "$1"; }
  # The stash path the block deletes must be the one `out` writes.
  grep -qxF 'KS_CREDS="$STATE/ks-logoff-creds"' "$f" && ok "W1 KS_CREDS is the stash \`out\` writes" || no "W1 KS_CREDS changed"
  [ "$x" -eq 0 ]
}

echo "== $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
FAILED=0; HARNESS=0
pins "$SUT" || FAILED=1
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  case "$rc" in 0) ;; 1) FAILED=1 ;; *) HARNESS=1 ;; esac
done
[ "$HARNESS" = 0 ] || { echo "HARNESS ERROR"; exit 2; }
[ "$FAILED" = 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED under every shell found)"
mtmp=$(mktemp -d -p "$W") || exit 2
mut() { # mut <label> <sed-expr> [<case ids that must each fail under every shell>]
  local m="$mtmp/r.sh" s r out id alive="" err="" lost=""
  sed -e "$2" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  for s in $SHELLS; do
    out=$(suite "$m" "$s" 2>&1); r=$?
    case "$r" in
      0) alive="$alive $s" ;;
      1) case "$out" in *"FAIL  [$s]"*) ;; *) lost="$lost $s" ;; esac
         for id in ${3:-}; do case "$out" in *"FAIL  [$s] $id "*) ;; *) lost="$lost $s:$id" ;; esac; done ;;
      *) err="$err $s" ;;
    esac
  done
  if [ -n "$alive" ]; then echo "  SURVIVED  $1 -- under:$alive"; return 1; fi
  if [ -n "$err" ]; then echo "  HARNESS ERROR (not a conviction) $1 -- under:$err"; return 1; fi
  if [ -n "$lost" ]; then echo "  NOT CONVICTED $1 -- no failing line of its own under:$lost"; return 1; fi
  echo "  convicted $1 -- under:$SHELLS"; return 0
}
fails=0
mut "M1 the drop removed"                 '/keystore-push credentials dropped (NWP-20261005-17)/d' || fails=$((fails+1))
mut "M2 the drop on btresume instead"     's/\[ "\$op" = btpark \] && rm -f "\$KS_CREDS"/[ "$op" = btresume ] \&\& rm -f "$KS_CREDS"/' || fails=$((fails+1))
mut "M3 the drop after the uid check"     '/keystore-push credentials dropped (NWP-20261005-17)/{h;d};/bt \$op: bad uid/{G}' || fails=$((fails+1))
mut "M4 the drop's && turned into ||"     's/\[ "\$op" = btpark \] && rm -f "\$KS_CREDS"/[ "$op" = btpark ] || rm -f "$KS_CREDS"/' || fails=$((fails+1))
# NWP-20261116-13: the arm's uid floor
mut "F4 the uid floor deleted"            '/bt \$op: bad uid (\(leading zero\|under 10\))/d' 'B2 B3' || fails=$((fails+1))
# F5 copies the two floor lines out of the script under test and re-inserts them above the stash drop
F5=$(grep -F 'bt $op: bad uid (' "$SUT" | sed 's/\\/\\\\/g; s/$/\\/')
F5='/bt \$op: bad uid (\(leading zero\|under 10\))/d
/\[ "\$op" = btpark \] && rm -f "\$KS_CREDS"/i\
'"${F5%\\}"
mut "F5 the uid floor above the stash drop" "$F5" 'B4' || fails=$((fails+1))

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
  local fake=$'  FAIL  [dash] C1 the stash survived btpark\n  FAIL  [mksh] C1 the stash survived btpark\nHARNESS ERROR'
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
verdict_probe || fails=$((fails+1))
mutate_runner || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
