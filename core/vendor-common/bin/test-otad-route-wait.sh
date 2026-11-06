#!/usr/bin/env bash
# test-otad-route-wait.sh [<nowhere_otad.sh>] [--mutate] -- execute nowhere_otad.sh's default-route wait off-device
# (NWP-20261110-14, NWP-20261117-37).
#
# WHY THIS IS COMMITTED. Android's netd installs every network's routes, its default route included, in that
# network's own table (`table wlan0`, `table rmnet_data0`); the main table holds none. The wait used to ask
# `ip route show default` (main table only), so on a connected phone it ran all 20 passes and the ota-check started
# 40 s late, with no line in ota.log. The wait now reads `route show table all` for both families and counts only a
# line that BEGINS with `default `.
#
# netd's RouteController::Init also installs a v4 and a v6 default through its dummy (black-hole) network,
# `default dev dummy0 table dummy0`, at every start, whether or not a real network is up. The wait counted it, so
# it ended at its first pass on every device and a check right after a network change was never held. A default
# whose device is dummy0 now does not count; a default on any other device (a VPN's gatewayless `dev tun0`
# included) still does.
#
# The wait is extracted BY ANCHOR (from `i=0; while` to step 1's comment); a moved anchor is rc 2. `ip` and
# `sleep` are EXECUTABLES on a temp PATH, as on the device, answering per case from files; sleep counts its calls.
#
#   bash test-otad-route-wait.sh             # R1-R9 under each of bash, sh, dash, mksh found on PATH
#   bash test-otad-route-wait.sh --mutate    # ... plus 7 mutants, each convicted under each shell's own line
set -uo pipefail

MUTATE=no; OTAD=""
for a in "$@"; do
  case "$a" in --mutate) MUTATE=yes ;; *) OTAD="$a" ;; esac
done
OTAD="${OTAD:-$(dirname "$0")/nowhere_otad.sh}"
[ -f "$OTAD" ] || { echo "no such script: $OTAD" >&2; exit 2; }
SELF="$0"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

# From the wait's first line to the line before step 1's comment (the run-out line, if present, is inside it).
# BOTH anchors must exist, the start before the end: sed would otherwise run on to EOF and the harness would
# execute the OTA code that follows the wait.
START_RE='^i=0; while \[ \$i -lt 20 \]'; END_RE='^# 1\. Is a newer OS published'
_s=$(grep -n -m1 "$START_RE" "$OTAD" | cut -d: -f1)
_e=$(grep -n -m1 "$END_RE" "$OTAD" | cut -d: -f1)
case "$_s:$_e" in
  :*|*:|*[!0-9:]*) echo "EXTRACTION FAILED: a route-wait anchor is missing" >&2; exit 2 ;;
esac
[ "$_s" -lt "$_e" ] || { echo "EXTRACTION FAILED: the route-wait anchors are out of order" >&2; exit 2; }
WAIT=$(sed -n "${_s},$((_e-1))p" "$OTAD")
case "$WAIT" in
  *'ip route show'*'sleep 2'*'done'*) ;;
  *) echo "EXTRACTION FAILED: the route-wait anchors moved" >&2; exit 2 ;;
esac

SHELLS=bash
for s in sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -z "${ONLY_SH:-}" ] || SHELLS="$ONLY_SH"

# run_case <shell> <v4 table-all text> <v6 table-all text> <main-table text> <ip exit rc> -- sets SLEEPS, LOGTXT.
# The stub answers `route show table all` / `-6 route show table all` from files, plain `route show default` from
# the main-table file (what the old probe asked), and exits $5 after printing.
run_case(){
  local T; T=$(mktemp -d -p "$W") || exit 2; mkdir -p "$T/bin"
  printf '%s' "$2" > "$T/v4"; printf '%s' "$3" > "$T/v6"; printf '%s' "$4" > "$T/main"
  : > "$T/sleeps"; : > "$T/log"
  cat > "$T/bin/ip" <<STUB
#!/bin/sh
case "\$*" in
  "route show table all") cat '$T/v4' ;;
  "-6 route show table all") cat '$T/v6' ;;
  "route show default") cat '$T/main' ;;
esac
exit $5
STUB
  cat > "$T/bin/sleep" <<STUB
#!/bin/sh
echo "\$1" >> '$T/sleeps'
STUB
  chmod +x "$T/bin/ip" "$T/bin/sleep"
  printf '%s\n' "LOG='$T/log'" "$WAIT" > "$T/wait.sh"
  PATH="$T/bin:$PATH" "$1" "$T/wait.sh" >/dev/null 2>&1
  SLEEPS=$(wc -l < "$T/sleeps" | tr -d ' ')
  LOGTXT=$(cat "$T/log")
}

V4LINK='10.0.0.0/24 dev wlan0 proto kernel scope link src 10.0.0.5
'
V4DUMMY="default dev dummy0 table dummy0 proto static scope link
$V4LINK"
V6DUMMY='default dev dummy0 table dummy0 proto static metric 1024 pref medium
'
for SH in $SHELLS; do
  echo "== $SH =="
  run_case "$SH" 'default via 10.0.0.1 dev wlan0 table wlan0 proto static
10.0.0.0/24 dev wlan0 table wlan0 proto static scope link
' '' '' 0
  is "$SH R1 v4 default in table wlan0: no sleep" "$SLEEPS" 0
  is "$SH R1 no run-out line" "$LOGTXT" ""
  run_case "$SH" "$V4LINK" 'default via fe80::1 dev wlan0 table wlan0 proto ra metric 1024
' '' 0
  is "$SH R2 v6-only default: no sleep" "$SLEEPS" 0
  is "$SH R2 no run-out line" "$LOGTXT" ""
  run_case "$SH" "${V4LINK}unreachable default dev lo table 1000 metric 4278198272
throw default table 99
" 'fe80::/64 dev wlan0 proto kernel metric 256
unreachable default dev lo table 1000 metric 4278198272
' '' 0
  is "$SH R3 link routes and unreachable default: 20 sleeps" "$SLEEPS" 20
  case "$LOGTXT" in "[otad] no default route in any table after 40 s -- checking anyway "*) ok "$SH R3 run-out line" ;; *) no "$SH R3 run-out line [$LOGTXT]" ;; esac
  run_case "$SH" '' '' '' 1
  is "$SH R4 ip fails silently: 20 sleeps" "$SLEEPS" 20
  case "$LOGTXT" in "[otad] no default route in any table after 40 s -- checking anyway "*) ok "$SH R4 run-out line" ;; *) no "$SH R4 run-out line [$LOGTXT]" ;; esac
  run_case "$SH" 'default via 10.0.0.1 dev wlan0 proto dhcp
' '' 'default via 10.0.0.1 dev wlan0
' 0
  is "$SH R5 default in the main table: no sleep" "$SLEEPS" 0
  is "$SH R5 no run-out line" "$LOGTXT" ""
  run_case "$SH" "$V4DUMMY" "$V6DUMMY" '' 0
  is "$SH R6 only netd's dummy0 defaults: 20 sleeps" "$SLEEPS" 20
  case "$LOGTXT" in "[otad] no default route in any table after 40 s -- checking anyway "*) ok "$SH R6 run-out line" ;; *) no "$SH R6 run-out line [$LOGTXT]" ;; esac
  run_case "$SH" "${V4DUMMY}default via 10.0.0.1 dev wlan0 table wlan0 proto static
" "$V6DUMMY" '' 0
  is "$SH R7 dummy0 plus a v4 wlan0 default: no sleep" "$SLEEPS" 0
  is "$SH R7 no run-out line" "$LOGTXT" ""
  run_case "$SH" "$V4DUMMY" 'default via fe80::1 dev wlan0 table wlan0 proto ra metric 1024
' '' 0
  is "$SH R8 dummy0 v4 plus a v6 wlan0 default: no sleep" "$SLEEPS" 0
  is "$SH R8 no run-out line" "$LOGTXT" ""
  run_case "$SH" "${V4DUMMY}default dev tun0 table tun0 proto static scope link
" "$V6DUMMY" '' 0
  is "$SH R9 dummy0 plus a gatewayless tun0 default: no sleep" "$SLEEPS" 0
  is "$SH R9 no run-out line" "$LOGTXT" ""
done
echo "shells run: $SHELLS"

# A moved or missing anchor is rc 2 and runs nothing (the harmless line stands for the OTA code after the wait).
if [ -z "${ONLY_SH:-}" ]; then
  for _v in end-renamed start-renamed swapped; do
    _f=$(mktemp -p "$W") || exit 2
    case "$_v" in
      end-renamed)   sed 's/^# 1\. Is a newer OS published/# 1. Check for a newer OS/' "$OTAD" > "$_f" ;;
      start-renamed) sed 's/^i=0; while \[ \$i -lt 20 \]/j=0; while [ $j -lt 20 ]/' "$OTAD" > "$_f" ;;
      swapped)       { sed -n '/^# 1\. Is a newer OS published/p' "$OTAD"; cat "$OTAD"; } | sed '0,/^i=0; while/s//#&/' > "$_f" ;;
    esac
    ONLY_SH=bash bash "$SELF" "$_f" >/dev/null 2>&1; _rc=$?
    is "extraction anchors $_v: rc 2" "$_rc" 2
    rm -f "$_f"
  done
fi

echo "behaviour: $PASS passed, $FAIL failed"
[ "$MUTATE" = no ] && { [ "$FAIL" = 0 ]; exit; }
[ "$FAIL" = 0 ] || { echo "control (unmutated) failed -- mutations are meaningless" >&2; exit 1; }

M=0; BAD=0
mutate(){                      # mutate <label> <from> <to>
  local content new f rc out sh
  content=$(<"$OTAD"); new=${content/"$2"/"$3"}
  if [ "$content" = "$new" ]; then echo "  HARNESS FAIL  mutant $1 did not change the text"; BAD=$((BAD+1)); return; fi
  f=$(mktemp -p "$W") || exit 2; printf '%s\n' "$new" > "$f"
  for sh in $SHELLS; do
    out=$(ONLY_SH="$sh" bash "$SELF" "$f" 2>&1); rc=$?
    M=$((M+1))
    if [ "$rc" = 1 ]; then echo "  convicted  $1 [$sh]"; else echo "  SURVIVED   $1 [$sh] (rc=$rc)"; BAD=$((BAD+1)); fi
  done
  rm -f "$f"
}
mutate 'N1 back to ip route show default'  '{ ip route show table all; ip -6 route show table all; }' 'ip route show default'
mutate 'N2 the v6 query dropped'            '{ ip route show table all; ip -6 route show table all; }' '{ ip route show table all; }'
mutate 'N3 any line counts'                 '*"
default "*) break ;; esac' '*?*) break ;; esac'
mutate 'N4 the break removed'               '*"
default "*) break ;; esac' '*"
default "*) : ;; esac'
mutate 'N5 the run-out line removed'        '[ $i -lt 20 ] || echo "[otad] no default route in any table after 40 s -- checking anyway $(date)" >> "$LOG"' ':'
mutate 'N6 the dummy0 filter removed'        " | grep -v -E '^default (.* )?dev dummy0( |\$)'" ''
mutate 'N7 every gatewayless default dropped' "'^default (.* )?dev dummy0( |\$)'" "'^default dev '"
echo "mutants: $M run, $BAD not convicted"
[ "$BAD" = 0 ]
