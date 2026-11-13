#!/usr/bin/env bash
# test-mediarestart-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's mediarestart arm, executed (NWP-20261202-20).
#
# WHY THIS IS COMMITTED. mediarestart is a health notice's Fix for a session MediaProvider that stopped answering. It
# force-stops BOTH MediaProvider module names in the session's user, then holds the read-write lane for a settle, so
# the volume reset it causes (H_RESET) lands before the next seal starts. A dropped name, a dropped --user or a
# dropped settle is silent on a device: the wrong provider, the gate's provider, or a reset mid-seal.
#
# The arm is extracted BY ANCHOR (label to the first line that is exactly "    ;;") and run, with `am` and `sleep`
# stubbed, under bash, sh, dash and mksh where present. The stubs record their argv; `am` also records what its stdio
# points at, and `sleep` whether $RES was already published when the settle ran.
#
#   bash test-mediarestart-op.sh            # the cases
#   bash test-mediarestart-op.sh --mutate   # ... plus mutations that must each CONVICT the suite
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

M1="com.android.providers.media.module"
M2="com.google.android.providers.media.module"

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 A sh w d u
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  A=$(arm "$f" mediarestart)
  case "$A" in *'force-stop'*) ;; *) no "EXTRACTION FAILED -- the mediarestart arm moved in $f"; return 2 ;; esac
  bash -n <<<"case x in
$A
esac" 2>/dev/null || { no "THE ARM DOES NOT PARSE in $f"; return 2; }

  # go <shell> <uid>: run the arm in a fresh shell over a fresh fake device; prints its directory.
  go() {
    local sh="$1" d; d=$(mktemp -d -p "$W")
    : > "$d/calls"; : > "$d/sleeps"
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
sleep(){
  if [ -e "\$RES" ]; then echo "\$* res=yes" >> "$d/sleeps"; else echo "\$* res=no" >> "$d/sleeps"; fi
}
case mediarestart in
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
    [ "$(cat "$d/calls")" = "force-stop --user 13 $M1
force-stop --user 13 $M2" ] && ok "$w uid 13: am force-stopped both module names with --user 13" || no "$w uid 13: am argv was: $(cat "$d/calls")"
    [ "$(cat "$d/sleeps")" = "10 res=no" ] && ok "$w uid 13: one 10 s settle before the reply" || no "$w uid 13: settle was: '$(cat "$d/sleeps")'"
    [ ! -e "$d/res.part" ] && ok "$w uid 13: the reply was renamed (no .part left)" || no "$w uid 13: \$RES.part left behind"
    [ "$(stat -c %a "$d/res" 2>/dev/null)" = 600 ] && ok "$w uid 13: RES is 0600" || no "$w uid 13: RES mode is $(stat -c %a "$d/res" 2>/dev/null)"
    [ "$(grep -c 'mediarestart: stopped MediaProvider in user 13 ' "$d/log" 2>/dev/null)" = 1 ] && ok "$w uid 13: one log line names the uid" || no "$w uid 13: log was: $(cat "$d/log" 2>/dev/null)"
    if [ "$FDCHECK" = yes ]; then
      [ "$(cat "$d/fds" 2>/dev/null)" = "fd /dev/null /dev/null /dev/null
fd /dev/null /dev/null /dev/null" ] && ok "$w uid 13: stdio on /dev/null for both calls (fd check)" || no "$w uid 13: stdio not on /dev/null: $(cat "$d/fds" 2>/dev/null)"
    fi
    rm -rf "$d"
    for u in "" 0 07 00 a1 1x -p "1 2"; do
      d=$(go "$sh" "$u")
      [ "$(cat "$d/res" 2>/dev/null)" = ERR-NOSESSION ] && ok "$w uid '$u': ERR-NOSESSION" || no "$w uid '$u' answered '$(cat "$d/res" 2>/dev/null)'"
      [ ! -s "$d/calls" ] && ok "$w uid '$u': no am call" || no "$w uid '$u' reached am: $(cat "$d/calls")"
      [ ! -s "$d/sleeps" ] && ok "$w uid '$u': no settle" || no "$w uid '$u' slept: $(cat "$d/sleeps")"
      [ ! -e "$d/res.part" ] && ok "$w uid '$u': the reply was renamed" || no "$w uid '$u': \$RES.part left behind"
      [ "$(grep -c 'mediarestart: refused, no session user ' "$d/log" 2>/dev/null)" = 1 ] && ok "$w uid '$u': one refusal line" || no "$w uid '$u': log was: $(cat "$d/log" 2>/dev/null)"
      rm -rf "$d"
    done
  done
  case "$A" in *'stop-user'*|*'remove-user'*|*'"$AGENT" out'*) no "[pin] the arm can stop a user or sign out" ;; *) ok "[pin] the arm holds no stop-user, remove-user or \"\$AGENT\" out" ;; esac
  case "$A" in *'> "$RES"'*) no "[pin] the arm writes \$RES in place (the poller returns at its first byte)" ;; *) ok "[pin] the arm never writes \$RES in place" ;; esac
  case "$A" in *'mv -f "$RES.part" "$RES"'*) ok "[pin] the reply reaches \$RES by rename" ;; *) no "[pin] no rename into \$RES" ;; esac
  [ -n "$quiet" ] || echo "$p passed, $x failed"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT" quiet || { echo "CONTROL FAILED -- the unmutated script does not pass"; suite "$SUT"; exit 1; }
echo "control: passes"
T=$(mktemp -d -p "$W")
bad=0
AR='/^  mediarestart)$/,/^    ;;$/'
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
mutate "1 the AOSP module name dropped" "uid 13: am argv was" "$AR"'{/am force-stop --user "$uid" com\.android\.providers\.media\.module /d}'
mutate "2 the google module name dropped" "uid 13: am argv was" "$AR"'{/am force-stop --user "$uid" com\.google\.android\.providers\.media\.module /d}'
mutate "3 --user dropped" "uid 13: am argv was" "$AR"'s#am force-stop --user "$uid" #am force-stop #'
mutate "4 the settle removed" "uid 13: settle was" "$AR"'{/^ *sleep "$MR_SETTLE_S"$/d}'
mutate "5 the uid guard removed" "uid '' reached am" "$AR"'{/^      ""|0\*|\*\[!0-9\]\*)$/,/^        ;;$/d}'
mutate "6 the settle after the reply is published" "uid 13: settle was" "$AR"'{/^ *sleep "$MR_SETTLE_S"$/d;s#^\( *\)mv -f "$RES.part" "$RES" 2>>"$LOG"$#&\n\1sleep "${MR_SETTLE_S:-10}"#}'
mutate "7 uid 07 passes the guard" "uid '07' reached am" "$AR"'s#^      ""|0\*|#      ""|0|#'
mutate "8 the reply is written in place" "[pin] the arm writes \$RES in place (the poller returns at its first byte)" "$AR"'s#echo "OK" > "$RES.part"#echo "OK" > "$RES"#'
mutate "9 no log line" "uid 13: log was" "$AR"'{/echo "\[roamd\] mediarestart: /d}'
[ "$bad" = 0 ] && echo "== all mutations convicted" || { echo "== $bad mutation(s) not convicted"; exit 1; }
