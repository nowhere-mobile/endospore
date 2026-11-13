#!/usr/bin/env bash
# test-playrestart-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's playrestart arm, executed (NWP-20261201-10).
#
# WHY THIS IS COMMITTED. playrestart is a health notice's Fix. The decision of record (docs/product-decisions.md,
# 2026-11-08) says a check never signs a profile out, and the arm's whole job is one force-stop of Play services in the
# session's user. A dropped --user would stop the gate's copy, and every failure is silent.
#
# The arm is extracted BY ANCHOR (label to the first line that is exactly "    ;;") and run, with `am` stubbed, under
# bash, sh, dash and mksh where present. The stub records its argv and what its stdio points at.
#
#   bash test-playrestart-op.sh            # the cases
#   bash test-playrestart-op.sh --mutate   # ... plus mutations that must each CONVICT the suite
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
FDCHECK=no; [ -r "/proc/$$/fd/0" ] && FDCHECK=yes

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 A sh w d u
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  A=$(arm "$f" playrestart)
  case "$A" in *'force-stop'*|*'stop-user'*) ;; *) no "EXTRACTION FAILED -- the playrestart arm moved in $f"; return 2 ;; esac
  bash -n <<<"case x in
$A
esac" 2>/dev/null || { no "THE ARM DOES NOT PARSE in $f"; return 2; }

  # go <shell> <uid>: run the arm in a fresh shell over a fresh fake device; prints its directory.
  go() {
    local sh="$1" d; d=$(mktemp -d -p "$W")
    : > "$d/calls"
    cat > "$d/run.sh" <<RUN
umask 022
uid="\$1"; RES="$d/res"; LOG="$d/log"
am(){
  echo "\$*" >> "$d/calls"
  if [ -r /proc/\$\$/fd/0 ]; then
    echo "fd \$(readlink /proc/\$\$/fd/0) \$(readlink /proc/\$\$/fd/1) \$(readlink /proc/\$\$/fd/2)" >> "$d/fds"
  fi
  return 0
}
case playrestart in
$A
esac
RUN
    TMPDIR="$W" "$sh" "$d/run.sh" "$2" > "$d/out" 2>&1 </dev/null
    printf '%s\n' "$d"
  }
  for sh in $SHELLS; do
    w="[$sh]"
    d=$(go "$sh" 13)
    [ "$(cat "$d/res" 2>/dev/null)" = OK ] && ok "$w uid 13: OK" || no "$w uid 13 answered '$(cat "$d/res" 2>/dev/null)'"
    [ "$(cat "$d/calls")" = "force-stop --user 13 com.google.android.gms" ] && ok "$w uid 13: am called exactly force-stop --user 13 com.google.android.gms" || no "$w uid 13: am argv was: $(cat "$d/calls")"
    [ ! -e "$d/res.part" ] && ok "$w uid 13: the reply was renamed (no .part left)" || no "$w uid 13: \$RES.part left behind"
    [ "$(stat -c %a "$d/res" 2>/dev/null)" = 600 ] && ok "$w uid 13: RES is 0600" || no "$w uid 13: RES mode is $(stat -c %a "$d/res" 2>/dev/null)"
    [ "$(grep -c 'playrestart: force-stopped Play services in user 13 ' "$d/log" 2>/dev/null)" = 1 ] && ok "$w uid 13: one log line names the uid" || no "$w uid 13: log was: $(cat "$d/log" 2>/dev/null)"
    if [ "$FDCHECK" = yes ]; then
      [ "$(cat "$d/fds" 2>/dev/null)" = "fd /dev/null /dev/null /dev/null" ] && ok "$w uid 13: stdio on /dev/null (fd check)" || no "$w uid 13: stdio not on /dev/null: $(cat "$d/fds" 2>/dev/null)"
    fi
    rm -rf "$d"
    for u in "" 0 00 1x x -p "1 2"; do
      d=$(go "$sh" "$u")
      [ "$(cat "$d/res" 2>/dev/null)" = ERR-NOSESSION ] && ok "$w uid '$u': ERR-NOSESSION" || no "$w uid '$u' answered '$(cat "$d/res" 2>/dev/null)'"
      [ ! -s "$d/calls" ] && ok "$w uid '$u': no am call" || no "$w uid '$u' reached am: $(cat "$d/calls")"
      [ ! -e "$d/res.part" ] && ok "$w uid '$u': the reply was renamed" || no "$w uid '$u': \$RES.part left behind"
      rm -rf "$d"
    done
  done
  case "$A" in *'stop-user'*|*'remove-user'*|*'"$AGENT" out'*) no "[pin] the arm can stop a user or sign out" ;; *) ok "[pin] the arm holds no stop-user, remove-user or \"\$AGENT\" out" ;; esac
  case "$A" in *'> "$RES"'*) no "[pin] the arm writes \$RES in place (the poller returns at its first byte)" ;; *) ok "[pin] the arm never writes \$RES in place" ;; esac
  case "$A" in *'mv -f "$RES.part" "$RES"'*) ok "[pin] the reply reaches \$RES by rename" ;; *) no "[pin] no rename into \$RES" ;; esac
  case "$A" in *'am force-stop --user "$uid" com.google.android.gms </dev/null >/dev/null 2>&1'*) ok "[pin] the redirect text is present" ;; *) no "[pin] the redirect text is missing" ;; esac
  [ -n "$quiet" ] || echo "$p passed, $x failed"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT" quiet || { echo "CONTROL FAILED -- the unmutated script does not pass"; suite "$SUT"; exit 1; }
echo "control: passes"
T=$(mktemp -d -p "$W")
bad=0
AR='/^  playrestart)$/,/^    ;;$/'
# mutate <label> <assertion that must convict it> <sed>: the assertion must fail under each shell, or as the [pin].
mutate() {
  local label="$1" want="$2" out sh
  if ! sed "$3" "$SUT" > "$T/m.sh" 2>/dev/null; then echo "  BROKEN    $label (sed)"; bad=$((bad+1)); return; fi
  if cmp -s "$SUT" "$T/m.sh"; then echo "  INERT     $label"; bad=$((bad+1)); return; fi
  out=$(suite "$T/m.sh" 2>&1)
  case "$want" in
    '[pin]'*)
      case "$out" in *"FAIL  $want"*) echo "  convicted $label (by $want)" ;; *) echo "  SURVIVED  $label (wanted: $want)"; bad=$((bad+1)) ;; esac ;;
    *)
      for sh in $SHELLS; do
        case "$out" in *"FAIL  [$sh] $want"*) ;; *) echo "  SURVIVED  $label under $sh (wanted: $want)"; bad=$((bad+1)); return ;; esac
      done
      echo "  convicted $label (by $want, under:$SHELLS)" ;;
  esac
}
mutate "1 --user dropped" "uid 13: am argv was" "$AR"'s#am force-stop --user "$uid" #am force-stop #'
mutate "2 uid guard dropped" "uid '' reached am" "$AR"'{/^      ""|0\*|\*\[!0-9\]\*)$/,/^        ;;$/d}'
mutate "3 uid 00 passes the guard" "uid '00' reached am" "$AR"'s#^      ""|0\*|#      ""|0|#'
mutate "4 non-numeric uid passes the guard" "uid '1x' reached am" "$AR"'s#|\*\[!0-9\]\*)$#)#'
mutate "5 package becomes the Play Store" "uid 13: am argv was" "$AR"'s#com.google.android.gms </dev/null#com.android.vending </dev/null#'
mutate "6 am stop-user added" "[pin] the arm can stop a user or sign out" "$AR"'s#^\( *\)am force-stop#\1am stop-user "$uid"\n\1am force-stop#'
mutate "7 the reply is written in place" "[pin] the arm writes \$RES in place (the poller returns at its first byte)" "$AR"'s#echo "OK" > "$RES.part"#echo "OK" > "$RES"#'
mutate "8 the sign-out worker is added" "[pin] the arm can stop a user or sign out" "$AR"'s#^\( *\)echo "OK" > "$RES.part"#\1"$AGENT" out\n&#'
mutate "9 no log line" "uid 13: log was" "$AR"'{/echo "\[roamd\] playrestart: /d}'
[ "$bad" = 0 ] && echo "== all mutations convicted" || { echo "== $bad mutation(s) not convicted"; exit 1; }
