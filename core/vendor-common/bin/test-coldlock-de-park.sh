#!/usr/bin/env bash
# test-coldlock-de-park.sh [<nowhere_roamd.sh>] [--mutate] -- a cold lock parks the session's accounts_de.db in the
# RAM tmpfs and the resume puts it back; neither may ever lose the file (NWP-20261005-23, the plaintext-email P0).
#
# WHY THIS IS COMMITTED. /data/system_de/<uid>/accounts_de.db holds the account names (the Google email) and is
# readable on a locked phone. de_park moves it out at the lock; de_unpark restores it at resume. Both sides are
# dangerous when wrong in OPPOSITE directions: a park without the AMS snapshot patch, or an unpark that reports
# success without the file, starts the user without its DE file -- AccountManagerService then deletes the CE
# accounts and the session signs out of everything. So the gate (patch literal + control literal in services.jar)
# and the copy-compare-then-remove order, with the read-back of that removal (NWP-20261127-09), are pinned here,
# against temp dirs.
#
# Every case and every mutant runs under EACH of bash, sh, dash and mksh found on PATH (deduped by realpath),
# labelled [<shell>]: the extracted functions execute IN the shell under test, as a script it runs, never in this
# suite's bash. mksh is the device's /system/bin/sh and evaluates some tests differently (a non-number in
# `[ x -lt N ]` reads as 0, silently), and an unpark that reports success without the file signs the session out.
#
#   bash test-coldlock-de-park.sh            # the cases
#   bash test-coldlock-de-park.sh --mutate   # ... plus mutations that must each CONVICT the suite
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

fn() { sed -n "/^$2() {\$/,/^}\$/p" "$1"; }

suite() {  # suite <roamd.sh> <quiet> <shell> -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" sh="$3" label p=0 x=0 code cf rc pre="" lg av
  label=$(basename "$sh")
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$label" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$label" "$1"; }
  code="$(fn "$f" _de_park_ok)
$(fn "$f" de_park)
$(fn "$f" de_unpark)"
  case "$code" in *'_de_park_ok() {'*'de_park() {'*'de_unpark() {'*'restorecon'*) ;; *) echo "EXTRACTION FAILED -- the park functions moved in $f" >&2; return 2 ;; esac
  cf=$(mktemp -p "$W"); printf '%s\n' "$code" > "$cf"
  "$sh" -n "$cf" || { echo "EXTRACTION FAILED -- the park functions do not parse under $label" >&2; command rm -f "$cf"; return 2; }
  command rm -f "$cf"

  # env <jar-kind> -> a temp world: DE root with user 12's db (+wal), a park root, a jar.
  mk() {
    T=$(mktemp -d -p "$W"); mkdir -p "$T/de/12" "$T/st"
    printf 'SQLite format 3 email-shaped-row' > "$T/de/12/accounts_de.db"; printf 'wal' > "$T/de/12/accounts_de.db-wal"
    case "$1" in
      patched) printf 'xx onUserStopped yy stopped-user snapshot dropped (NWP-20261005-22) zz' > "$T/jar" ;;
      stock)   printf 'xx onUserStopped yy' > "$T/jar" ;;
      blind)   : > "$T/jar" ;;
    esac
  }
  run() { local a
    { printf "DE_SYS_ROOT='%s/de' DE_PARK_ROOT='%s/st/coldde' DE_JAR='%s/jar' LOG='%s/log'\n" "$T" "$T" "$T" "$T"
      printf 'chown(){ :; }\nrestorecon(){ :; }\n'; printf '%s\n' "$pre" "$code"
      for a in "$@"; do printf "'%s' " "$a"; done; echo; } > "$T/run.sh"
    "$sh" "$T/run.sh" >/dev/null 2>&1; }
  # refuse <path> -> pre = an rm that records its argv and removes every argument but exactly <path>. Whole-argument
  # compare: the -wal path has the db path as a prefix. __rm_ names only: local is dynamic, so _n would be de_park's.
  refuse() {
    pre="rm() {
  __rm_n=\$#; __rm_i=0
  while [ \"\$__rm_i\" -lt \"\$__rm_n\" ]; do
    __rm_a=\$1; shift; __rm_i=\$((__rm_i + 1))
    printf '%s\\n' \"\$__rm_a\" >> '$T/rm.argv'
    [ \"\$__rm_a\" = '$1' ] || set -- \"\$@\" \"\$__rm_a\"
  done
  command rm \"\$@\"
}"; }

  mk patched; run de_park 12; rc=$?
  if [ ! -e "$T/de/12/accounts_de.db" ] && [ -f "$T/st/coldde/12/accounts_de.db" ] && [ -f "$T/st/coldde/12/accounts_de.db-wal" ]; then
    ok "P1 with the patch, the db and its -wal leave DE for the park"; else no "P1 the park did not move both files"; fi
  lg=$(cat "$T/log" 2>/dev/null)
  case "$lg" in *'accounts_de parked in RAM (2 file(s))'*) [ "$rc" = 0 ] && ok "P1b a clean park returns 0 and logs parked in RAM (2 file(s))" || no "P1b a clean park rc=$rc" ;;
    *) no "P1b a clean park did not log parked in RAM (2 file(s))" ;; esac
  run de_unpark 12; rc=$?
  if [ "$rc" = 0 ] && grep -q email-shaped-row "$T/de/12/accounts_de.db" 2>/dev/null && [ -f "$T/de/12/accounts_de.db-wal" ] && [ ! -e "$T/st/coldde/12" ]; then
    ok "U1 unpark restores both files byte-for-byte and drops the parked copy"; else no "U1 unpark rc=$rc did not restore cleanly"; fi
  command rm -rf "$T"

  mk stock; run de_park 12
  [ -f "$T/de/12/accounts_de.db" ] && [ ! -e "$T/st/coldde/12" ] && ok "P2 without the patch the db STAYS (a removed file would come back empty)" || no "P2 parked on a stock image"
  command rm -rf "$T"
  mk blind; run de_park 12
  [ -f "$T/de/12/accounts_de.db" ] && [ ! -e "$T/st/coldde/12" ] && ok "P3 an unreadable jar (no control) also refuses" || no "P3 parked blind"
  # ...and SAYS so: the control exists to tell "cannot read the jar" from "the patch is absent".
  grep -q 'services.jar unreadable (control missing)' "$T/log" 2>/dev/null && ok "P4 the blind refusal is logged as blind, not as a stock image" || no "P4 a blind jar was reported as a missing patch"
  command rm -rf "$T"

  mk patched; run de_unpark 12; rc=$?
  [ "$rc" = 0 ] && [ -f "$T/de/12/accounts_de.db" ] && ok "U2 nothing parked: unpark is a no-op OK and touches nothing" || no "U2 rc=$rc"
  command rm -rf "$T"

  # A failed restore must report failure AND keep the parked copy.
  # A DIRECTORY at the target's name: rm -f cannot remove it, cp then copies INTO it, and the compare fails. Portable
  # (chmod does not stop Windows or root).
  mk patched; run de_park 12; mkdir "$T/de/12/accounts_de.db"; run de_unpark 12; rc=$?
  if [ "$rc" != 0 ] && [ -f "$T/st/coldde/12/accounts_de.db" ]; then ok "U3 a failed restore returns non-zero and keeps the parked copy"
  else no "U3 rc=$rc on a blocked restore, parked copy $( [ -f "$T/st/coldde/12/accounts_de.db" ] && echo kept || echo LOST)"; fi
  command rm -rf "$T"

  # A removal that fails (NWP-20261127-09): the park must SAY so, keep the RAM copy and return non-zero.
  mk patched; refuse "$T/de/12/accounts_de.db"; run de_park 12; rc=$?; pre=""
  lg=$(cat "$T/log" 2>/dev/null); av=$(cat "$T/rm.argv" 2>/dev/null)
  case "$av" in *"$T/de/12/accounts_de.db"*) ;; *) no "P5 the rm wrapper never ran (vacuous)" ;; esac
  [ "$rc" != 0 ] && ok "P5a a db that stays in DE fails the park" || no "P5a rc=0 with the db still in DE"
  [ -f "$T/de/12/accounts_de.db" ] && [ -f "$T/st/coldde/12/accounts_de.db" ] && cmp -s "$T/de/12/accounts_de.db" "$T/st/coldde/12/accounts_de.db" \
    && ok "P5b the RAM copy is kept and matches" || no "P5b the park was not kept"
  case "$lg" in *'could NOT be removed from DE'*) ok "P5c the survivor is logged" ;; *) no "P5c no could-NOT-be-removed line" ;; esac
  case "$lg" in *'accounts_de parked in RAM'*) no "P5d the success line logged over a surviving db" ;; *) ok "P5d no success line over a survivor" ;; esac
  command rm -rf "$T"

  # Only the -wal stays: the db is gone from DE, so the park is the ONLY copy of it -- the unpark must restore both.
  mk patched; refuse "$T/de/12/accounts_de.db-wal"; run de_park 12; rc=$?; pre=""
  lg=$(cat "$T/log" 2>/dev/null)
  if [ "$rc" != 0 ] && [ ! -e "$T/de/12/accounts_de.db" ] && [ -f "$T/st/coldde/12/accounts_de.db" ] && [ -f "$T/st/coldde/12/accounts_de.db-wal" ]; then
    ok "P6a a -wal that stays fails the park and the park holds both"; else no "P6a rc=$rc, or the park does not hold both"; fi
  case "$lg" in *'1 file(s) could NOT be removed'*) ok "P6b one survivor is counted" ;; *) no "P6b no 1 file(s) could NOT be removed line" ;; esac
  run de_unpark 12; rc=$?
  if [ "$rc" = 0 ] && grep -q email-shaped-row "$T/de/12/accounts_de.db" 2>/dev/null && [ "$(cat "$T/de/12/accounts_de.db-wal" 2>/dev/null)" = wal ]; then
    ok "P6c unpark restores both byte-for-byte"; else no "P6c unpark rc=$rc did not restore both (the park was lost)"; fi
  command rm -rf "$T"

  # Wiring: the lock parks, the reap clears, the resume op exists, and no sign-in deletes a park.
  grep -qxF '      de_park "$uid"   # NWP-20261005-23: the account names, out of DE for the lock (gated on the AMS patch)' "$f" \
    && ok "W1 dropcaches (the lock) parks" || no "W1 dropcaches no longer parks"
  grep -qxF '  rm -rf "$DE_PARK_ROOT/$uid" 2>> "$LOG"   # NWP-20261005-23: a reaped session'"'"'s parked account file goes with it' "$f" \
    && ok "W2 the reap removes the uid's park" || no "W2 cleanstorage does not clear the park"
  grep -qF 'if de_unpark "$uid"; then echo "OK" > "$RES"; else echo "ERR-UNPARK" > "$RES"; fi' "$f" \
    && ok "W3 deunpark answers OK only on a restore" || no "W3 the deunpark verdict changed"
  if grep -qE '^\[ "\$op" = "in" \].*DE_PARK_ROOT' "$f"; then no "W4 a sign-in deletes parked files (a failed sign-in's resume would lose its accounts)"
  else ok "W4 no sign-in deletes a park"; fi

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed [%s]\n' "$p" "$x" "$label"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT (shells:$SHELLS)"
rc=0
for sh in $SHELLS; do suite "$SUT" "" "$sh" || rc=1; done
[ "$rc" = 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED)"
mut() { # mut <label> <sed-expr>; convicted under EACH shell's own line
  local m r sh bad=0
  m=$(mktemp -p "$W")
  sed -e "$2" "$SUT" > "$m" || { echo "  ERROR     $1 -- the sed program failed"; command rm -f "$m"; return 1; }
  [ -s "$m" ] || { echo "  ERROR     $1 -- the mutant is empty"; command rm -f "$m"; return 1; }
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  for sh in $SHELLS; do
    suite "$m" quiet "$sh" >/dev/null 2>&1; r=$?
    case "$r" in
      1) echo "  convicted $1 [${sh##*/}]" ;;
      0) echo "  SURVIVED  $1 [${sh##*/}]"; bad=1 ;;
      *) echo "  BROKEN    $1 [${sh##*/}] (rc=$r), not a conviction"; bad=1 ;;
    esac
  done
  command rm -f "$m"; return $bad
}
fails=0
mut "M1 the patch gate always passes"          's/|| return 1  # the patch/|| :  # the patch/' || fails=$((fails+1))
mut "M2 the control check dropped"             's/|| return 2                                   # control/|| :  # control/' || fails=$((fails+1))
mut "M3 park removes without comparing"        's/cp -a "$_src\/$_f" "$_dst\/$_f" 2>>"$LOG" \&\& cmp -s "$_src\/$_f" "$_dst\/$_f" \\/true \\/' || fails=$((fails+1))
mut "M4 unpark reports success on failure"     's/|| { echo "\[roamd\] coldlock-de-unpark: FAILED to restore $_f, user $_u -- parked copy kept $(date)" >> "$LOG"; return 1; }/|| :/' || fails=$((fails+1))
mut "M5 the lock no longer parks"              '/      de_park "$uid"   # NWP-20261005-23/d' || fails=$((fails+1))
mut "M6 a sign-in wipes the parks"             's/^DE_PARK_ROOT="$STATE\/coldde"$/&\n[ "$op" = "in" ] \&\& rm -rf "$DE_PARK_ROOT"/' || fails=$((fails+1))
mut "M7 the removal is not read back"       's/then _k=$((_k + 1)); fi/then :; fi/' || fails=$((fails+1))
mut "M8 a failed removal returns 0"         's/(a copy is parked in RAM) $(date)" >> "$LOG"; return 1; }/(a copy is parked in RAM) $(date)" >> "$LOG"; return 0; }/' || fails=$((fails+1))
mut "M9 success logged before the read-back" '/^  rm -f "\$_src\/accounts_de.db" "\$_src\/accounts_de.db-wal"/a\  echo "[roamd] coldlock-de-park: user $_u accounts_de parked in RAM ($_n file(s)) $(date)" >> "$LOG"' || fails=$((fails+1))
mut "M10 the park is deleted on a failure"  's/(a copy is parked in RAM) $(date)" >> "$LOG"; return 1; }/(a copy is parked in RAM) $(date)" >> "$LOG"; rm -rf "$_dst"; return 1; }/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
