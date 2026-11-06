#!/usr/bin/env bash
# test-gate-alarm-arms.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's silence-alarm and alarmrelay arms, executed
# (NWP-20261017-28).
#
# WHY THIS IS COMMITTED. Both arms are the gate's only reach into the roamed session's alarm, and both fail SILENTLY.
# silence-alarm's first cut "logged silenced and the phone kept ringing" (NWP-20260913-07), so it now force-stops
# `--user "$uid" "$pkg"` and answers OK only when `pkg_live_pids "$pkg" "$uid"` finds no process of the app IN THE
# SESSION USER (ERR-LIVE otherwise; a user-0 copy of the same app does not count, NWP-20261110-16); a pkg that is
# empty, holds "/" or a space, or starts with "-" (an option into `am`) is refused ERR-PKG before any `am`. alarmrelay
# asks the cold-locking session for its next alarm with `am startservice --user "$uid" ... --ez alarm true`, stdio on
# /dev/null (DIA-56); with the Endospore overlay turning alarms off on stopped users that copy is the only ring there
# is (#151). A user-0 target, or a dropped `--ez alarm true`, is silent. Nothing executed either arm before this.
#
# Each arm is extracted BY ANCHOR (label to the first line that is exactly "    ;;") and run, with `am` and `pidof`
# stubbed, under bash, sh, dash and mksh where present. pkg_live_pids is extracted BY NAME and run for real, its
# `/proc/` rewritten to a fake root holding a status file (Uid line) for each stubbed pid. The stub records its argv and what its stdin/stdout/stderr point
# at (readlink /proc/$$/fd/N); where /proc is not readable the redirect text is pinned in the extracted arm instead,
# and the output says which check ran. The cases run under mksh too, the shell production runs.
#
#   bash test-gate-alarm-arms.sh            # the cases
#   bash test-gate-alarm-arms.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

arm() { awk -v l="  $2)" 'index($0,l)==1&&length($0)==length(l){on=1} on{print} on&&/^    ;;$/{exit}' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "  skip  shell $s not installed"; fi
done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
TAGS="$SHELLS"
FDCHECK=no; [ -r "/proc/$$/fd/0" ] && FDCHECK=yes

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 S A H sh w d pk
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  S=$(arm "$f" silence-alarm); A=$(arm "$f" alarmrelay); H=$(sed -n '/^pkg_live_pids() {$/,/^}$/p' "$f")
  case "$S" in *'am force-stop'*) ;; *) no "EXTRACTION FAILED -- the silence-alarm arm moved in $f"; return 2 ;; esac
  case "$A" in *'am startservice'*) ;; *) no "EXTRACTION FAILED -- the alarmrelay arm moved in $f"; return 2 ;; esac
  case "$H" in *'/proc/'*) ;; *) no "EXTRACTION FAILED -- pkg_live_pids() missing in $f"; return 2 ;; esac
  bash -n <<<"case x in
$S
esac" 2>/dev/null && bash -n <<<"case x in
$A
esac" 2>/dev/null && bash -n <<<"$H" 2>/dev/null || { no "THE ARMS DO NOT PARSE in $f"; return 2; }

  # go <shell> <arm> <label> <pkg> <pidof output> [<app uid>]: run the arm in a fresh shell over a fresh fake device,
  # every stubbed pid's /proc/<pid>/status naming <app uid> (default 1010050, user 10); prints its directory.
  go() {
    local sh="$1" blk="$2" au="${6:-1010050}" d pid; d=$(mktemp -d -p "$W")
    : > "$d/calls"
    for pid in $5; do
      mkdir -p "$d/proc/$pid"
      printf 'Name:\tclock\nState:\tS (sleeping)\nUid:\t%s\t%s\t%s\t%s\n' "$au" "$au" "$au" "$au" > "$d/proc/$pid/status"
    done
    cat > "$d/run.sh" <<RUN
umask 022
uid=10; RES="$d/res"; LOG="$d/log"; srcunit="\$1"; PIDOF_OUT="\$2"
am(){
  echo "\$*" >> "$d/calls"
  if [ -r /proc/\$\$/fd/0 ]; then
    echo "fd \$(readlink /proc/\$\$/fd/0) \$(readlink /proc/\$\$/fd/1) \$(readlink /proc/\$\$/fd/2)" >> "$d/fds"
  fi
  return 0
}
pidof(){ [ -n "\$PIDOF_OUT" ] && echo "\$PIDOF_OUT"; return 0; }
$(sed "s#/proc/#$d/proc/#g" <<<"$H")
case $3 in
$blk
esac
RUN
    TMPDIR="$W" "$sh" "$d/run.sh" "$4" "$5" > "$d/out" 2>&1 </dev/null
    printf '%s\n' "$d"
  }
  for sh in $SHELLS; do
    w="[$sh]"
    # (a) nothing left running -> OK
    d=$(go "$sh" "$S" silence-alarm com.example.clock "")
    [ "$(cat "$d/res" 2>/dev/null)" = OK ] && ok "$w silence-alarm: pidof empty -> OK" || no "$w silence-alarm: pidof empty did not answer OK (got: $(cat "$d/res" 2>/dev/null))"
    [ "$(cat "$d/calls")" = "force-stop --user 10 com.example.clock" ] && ok "$w silence-alarm: am called exactly force-stop --user <uid> <pkg>" || no "$w silence-alarm: am argv was: $(cat "$d/calls")"
    case "$(cat "$d/log" 2>/dev/null)" in *'stopped'*) ok "$w silence-alarm: log says stopped" ;; *) no "$w silence-alarm: log lacks 'stopped'" ;; esac
    rm -rf "$d"
    # (b) still running -> ERR-LIVE naming the pids
    d=$(go "$sh" "$S" silence-alarm com.example.clock "123 456")
    [ "$(cat "$d/res" 2>/dev/null)" = ERR-LIVE ] && ok "$w silence-alarm: pidof '123 456' -> ERR-LIVE" || no "$w silence-alarm: live app did not answer ERR-LIVE (got: $(cat "$d/res" 2>/dev/null))"
    case "$(cat "$d/log" 2>/dev/null)" in *'123 456'*'NOT silenced'*) ok "$w silence-alarm: log names the pids and NOT silenced" ;; *) no "$w silence-alarm: log lacks the pids / 'NOT silenced'" ;; esac
    rm -rf "$d"
    # (b2) the only live process is user 0's copy of the app (uid 10045) -> the session user's app is gone: OK
    d=$(go "$sh" "$S" silence-alarm com.example.clock "777" 10045)
    [ "$(cat "$d/res" 2>/dev/null)" = OK ] && ok "$w silence-alarm: pid 777 in user 0 only -> OK (the session user's app is gone)" || no "$w silence-alarm: pid 777 in user 0 only did not answer OK (got: $(cat "$d/res" 2>/dev/null))"
    case "$(cat "$d/log" 2>/dev/null)" in *'stopped'*) ok "$w silence-alarm: pid 777 in user 0 only -> log says stopped" ;; *) no "$w silence-alarm: pid 777 in user 0 only -> log lacks 'stopped'" ;; esac
    rm -rf "$d"
    # (c) refused packages: ERR-PKG, no am, (d) RES 0600
    for pk in "" "a/b" "a b" "-p"; do
      d=$(go "$sh" "$S" silence-alarm "$pk" "")
      [ "$(cat "$d/res" 2>/dev/null)" = ERR-PKG ] && ok "$w silence-alarm: pkg '$pk' -> ERR-PKG" || no "$w silence-alarm: pkg '$pk' answered '$(cat "$d/res" 2>/dev/null)'"
      [ ! -s "$d/calls" ] && ok "$w silence-alarm: pkg '$pk' made no am call" || no "$w silence-alarm: pkg '$pk' reached am: $(cat "$d/calls")"
      [ "$(stat -c %a "$d/res" 2>/dev/null)" = 600 ] && ok "$w silence-alarm: RES is 0600 after refusing '$pk'" || no "$w silence-alarm: RES mode after refusing '$pk' is $(stat -c %a "$d/res" 2>/dev/null)"
      rm -rf "$d"
    done
    # (e) alarmrelay
    d=$(go "$sh" "$A" alarmrelay "" "")
    [ "$(cat "$d/res" 2>/dev/null)" = OK ] && ok "$w alarmrelay: OK" || no "$w alarmrelay: answered '$(cat "$d/res" 2>/dev/null)'"
    [ "$(cat "$d/calls")" = "startservice --user 10 -n com.nowhere.chooser/.CredentialService --ez alarm true" ] && ok "$w alarmrelay: am called exactly startservice --user <uid> -n .../.CredentialService --ez alarm true" || no "$w alarmrelay: am argv was: $(cat "$d/calls")"
    if [ "$FDCHECK" = yes ]; then
      [ "$(cat "$d/fds" 2>/dev/null)" = "fd /dev/null /dev/null /dev/null" ] && ok "$w alarmrelay: stdio on /dev/null (fd check)" || no "$w alarmrelay: stdio not on /dev/null (fd check): $(cat "$d/fds" 2>/dev/null)"
    fi
    rm -rf "$d"
  done
  # The redirect text, pinned where the fd check cannot run (and as a belt beside it).
  case "$A" in *'--ez alarm true </dev/null >/dev/null 2>&1'*) ok "[pin] alarmrelay: redirect text '</dev/null >/dev/null 2>&1' present (text pin)" ;; *) no "[pin] alarmrelay: redirect text '</dev/null >/dev/null 2>&1' missing (text pin)" ;; esac
  if [ -z "$quiet" ]; then echo "  info  stdio check: $([ "$FDCHECK" = yes ] && echo 'fd (readlink /proc/$$/fd) + text pin' || echo 'text pin only (/proc unavailable)'); shells: $SHELLS"; fi
  [ -n "$quiet" ] || echo "$p passed, $x failed"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT" quiet || { echo "CONTROL FAILED -- the unmutated script does not pass"; suite "$SUT"; exit 1; }
echo "control: passes"
T=$(mktemp -d -p "$W")
bad=0
# mutate <name> <want tags> <sed-expr>: the copy must DIFFER from the original, the suite must then FAIL, and every
# tag in <want tags> must print its own FAIL line (every shell found, mksh included; a mutant only the text pin can
# catch names [pin]).
mutate() {
  local n="$1" want="$2" e="$3" m="$T/m.sh" rc res nb="" t
  sed -e "$e" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  MUTANT DID NOT APPLY  $n"; bad=1; return; fi
  res=$(suite "$m"); rc=$?
  for t in $want; do
    case "$res" in *"  FAIL  [$t]"*) ;; *) nb="$nb $t" ;; esac
  done
  if [ "$rc" = 1 ] && [ -z "$nb" ]; then echo "  convicted  $n"; else echo "  NOT CONVICTED (rc=$rc, no FAIL line under:${nb:- none})  $n"; bad=1; fi
}
SA='/^  silence-alarm)$/,/^    ;;$/'
AR='/^  alarmrelay)$/,/^    ;;$/'
mutate "1 live check replaced by an unconditional OK" "$TAGS" "$SA"'s#_salive=$(pkg_live_pids "$pkg" "$uid")#_salive=#'
mutate "2 silence-alarm force-stops --user 0" "$TAGS" "$SA"'s#am force-stop --user "$uid"#am force-stop --user 0#'
mutate "3 the -* case removed from the guard" "$TAGS" "$SA"'s#|\*" "\*|-\*)#|*" "*)#'
mutate "4 alarmrelay targets --user 0" "$TAGS" "$AR"'s#am startservice --user "$uid"#am startservice --user 0#'
mutate "5 --ez alarm true dropped" "$TAGS" "$AR"'s#--ez alarm true </dev/null#</dev/null#'
mutate "6 alarmrelay stdio redirect dropped ($([ "$FDCHECK" = yes ] && echo 'fd check' || echo 'text pin'))" "$([ "$FDCHECK" = yes ] && echo "$TAGS" || echo 'pin')" "$AR"'s#--ez alarm true </dev/null >/dev/null 2>&1#--ez alarm true#'
mutate "7 the live check asks user 0" "$TAGS" "$SA"'s#pkg_live_pids "$pkg" "$uid"#pkg_live_pids "$pkg" 0#'
[ "$bad" = 0 ] && echo "all mutants convicted" || { echo "MUTATION RUN FAILED"; exit 1; }
