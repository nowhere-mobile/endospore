#!/usr/bin/env bash
# test-settz-verdict.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's `settz` op reply (NWP-20261014-29, #122;
# NWP-20261112-25).
#
# WHY THIS IS COMMITTED. settz ran `cmd alarm set-timezone`, discarded its result, and published a bare OK, so a
# pin that never applied still read as applied. AlarmManager writes persist.sys.timezone synchronously and getprop is
# readable, so the override arm reads the pinned zone back. SettingsProvider writes the auto_time_zone row
# synchronously too, and `settings get` is captured from this context (loc_set and vpn_apply already do it), so both
# arms read that row back: `OK APPLIED` needs the zone AND a 0, `OK AUTO` needs a 1, anything else is `ERR-TZ`. Only
# the zone the detector picks under Automatic is asynchronous. `settings put` fails silently on a wedged
# SettingsProvider (nowhere_provision.sh); the `dead` put mode below is that wedge.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and written into a runner file after the
# stubs. cmd/settings/getprop are shell functions over a simulated property and a simulated settings row; they answer
# only the calls roamd really makes and record anything else. Every case runs under every shell found (bash, sh, dash,
# mksh -- the device's /system/bin/sh is mksh); SETTZ_SHELLS overrides.
#
#   bash test-settz-verdict.sh            # the behaviour cases
#   bash test-settz-verdict.sh --mutate   # ... plus mutations that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
if [ -n "${SETTZ_SHELLS:-}" ]; then SHELLS="$SETTZ_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }
SHX=""

extract() {  # extract <roamd.sh>
  sed -n '/^if \[ "\$op" = "settz" \]; then$/,/^fi$/p' "$1"
}

# The stubs, in POSIX sh: they run inside the runner under each shell. $D is the case dir; CMDMODE (works|dead) is
# whether `cmd alarm set-timezone` lands, PUTMODE (lands|dead) whether `settings put` lands.
STUBS=$(cat <<'STUB'
getprop() {
  case "$1" in
    persist.sys.timezone) cat "$D/prop" ;;
    ro.nowhere.default.timezone) echo "Europe/Default" ;;
    *) echo "getprop $*" >> "$D/unexpected" ;;
  esac
}
settings() {  # settings put global auto_time_zone <0|1>; settings get global auto_time_zone
  if [ "$1 $2 $3" = "put global auto_time_zone" ] && [ "$#" = 4 ]; then
    [ "$PUTMODE" = lands ] && echo "$4" > "$D/auto"
    return 0
  fi
  if [ "$1 $2 $3" = "get global auto_time_zone" ] && [ "$#" = 3 ]; then cat "$D/auto"; return 0; fi
  echo "settings $*" >> "$D/unexpected"; return 1
}
cmd() {  # cmd alarm set-timezone <zone>
  if [ "$1 $2" = "alarm set-timezone" ]; then
    [ "$CMDMODE" = works ] && echo "$3" > "$D/prop"
    return 0
  fi
  echo "cmd $*" >> "$D/unexpected"; return 1
}
STUB
)

# run_sim <block-file> <zone> <cmd: works|dead> <dir> [<put: lands|dead>] [<initial auto_time_zone row>]: one op run
# under $SHX over the stubs; leaves its files in <dir>. A zone-less run is the automatic arm.
run_sim() {
  local blk="$1" zone="$2" mode="${3:-works}" d="$4" put="${5:-lands}" init="${6:--}"
  echo "Etc/Old" > "$d/prop"; echo "$init" > "$d/auto"
  { printf '%s\n' "$STUBS"; cat "$blk"; } > "$d/run.sh"
  op=settz name="$zone" RES="$d/res" LOG="$d/log" D="$d" CMDMODE="$mode" PUTMODE="$put" \
    "$SHX" "$d/run.sh" </dev/null >/dev/null 2>&1
}

# run_op <block-file> <zone> [<cmd>] [<put>] [<init>] -> "<RES>|<auto_time_zone>|<prop after>|<unexpected calls>"
run_op() {
  local d
  d=$(mktemp -d -p "$W")
  run_sim "$1" "$2" "${3:-works}" "$d" "${4:-lands}" "${5:--}"
  printf '%s|%s|%s|%s\n' "$(cat "$d/res" 2>/dev/null)" "$(cat "$d/auto")" "$(cat "$d/prop")" "$(cat "$d/unexpected" 2>/dev/null)"
  rm -rf "$d"
}

# run_log <block-file> <zone> [<cmd>] [<put>] [<init>] -> the log the op wrote, and nothing else.
run_log() {
  local d
  d=$(mktemp -d -p "$W")
  run_sim "$1" "$2" "${3:-works}" "$d" "${4:-lands}" "${5:--}"
  cat "$d/log" 2>/dev/null
  rm -rf "$d"
}

# nozone <label> <log>: the log names neither the pinned zone nor the zone it replaced.
nozone() {
  case "$2" in *Europe/Paris*|*Etc/Old*) no "$1 names a zone: '$2'" ;; *) ok "$1 names no zone" ;; esac
}

suite() {  # suite <roamd.sh> [quiet] -> under $SHX: 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" b p=0 x=0 out lg
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$SHX" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$SHX" "$1"; }
  b=$(mktemp -p "$W")
  extract "$f" > "$b"
  if ! grep -q 'alarm set-timezone' "$b"; then
    echo "EXTRACTION FAILED: settz block missing in $f" >&2; rm -f "$b"; return 2
  fi
  if ! "$SHX" -n "$b"; then echo "EXTRACTION FAILED: settz block does not parse under $SHX in $f" >&2; rm -f "$b"; return 2; fi

  out=$(run_op "$b" Europe/Paris works)
  case "$out" in 'OK APPLIED|0|Europe/Paris|') ok "S1 override applied -> OK APPLIED, detector off" ;; *) no "S1 got '$out'" ;; esac
  out=$(run_op "$b" Europe/Paris dead)
  case "$out" in 'ERR-TZ|0|Etc/Old|') ok "S2 override NOT applied -> ERR-TZ" ;;
    *) no "S2 a pin that never applied was reported: got '$out'" ;; esac
  out=$(run_op "$b" "")
  case "$out" in 'OK AUTO|1|Europe/Default|') ok "S3 automatic -> OK AUTO, detector on, default seeded" ;; *) no "S3 got '$out'" ;; esac
  out=$(run_op "$b" "" dead)
  case "$out" in 'OK AUTO|1|Etc/Old|') ok "S4 the seed zone is asynchronous: OK AUTO needs only the row" ;; *) no "S4 got '$out'" ;; esac
  out=$(run_op "$b" Europe/Paris works)
  case "$out" in *'|') ok "S5 no unexpected calls" ;; *) no "S5 unexpected calls: '$out'" ;; esac

  # NWP-20261106-06: roam.log outlives the session and rides a later profile's report; the zone is coarse location.
  lg=$(run_log "$b" Europe/Paris works)
  case "$lg" in
    *'settz override APPLIED'*) nozone "S6 the applied line" "$lg" ;;
    *) no "S6 the applied log line is missing: '$lg'" ;;
  esac
  lg=$(run_log "$b" Europe/Paris dead)
  case "$lg" in
    *'NOT APPLIED'*) nozone "S7 the not-applied line" "$lg" ;;
    *) no "S7 the not-applied log line is missing: '$lg'" ;;
  esac
  lg=$(run_log "$b" "")
  case "$lg" in *Europe/Default*) ok "S8 automatic log still holds the image default (control)" ;; *) no "S8 got '$lg'" ;; esac

  # NWP-20261112-25: the auto_time_zone row is read back in both arms.
  out=$(run_op "$b" "" works lands 0)
  case "$out" in 'OK AUTO|1|Europe/Default|') ok "S9 automatic, the put lands -> OK AUTO" ;; *) no "S9 got '$out'" ;; esac
  out=$(run_op "$b" "" works dead 0)
  case "$out" in 'ERR-TZ|0|Europe/Default|') ok "S10 automatic, the put does not land -> ERR-TZ" ;;
    *) no "S10 an Automatic that never landed was reported: got '$out'" ;; esac
  lg=$(run_log "$b" "" works dead 0)
  case "$lg" in
    *'settz automatic (seed'*) no "S10 the success line was logged for a put that did not land: '$lg'" ;;
    *'[roamd] settz automatic NOT APPLIED (auto_time_zone read 0) '*) ok "S10 the NOT APPLIED line says the row read 0" ;;
    *) no "S10 the automatic NOT APPLIED line is missing: '$lg'" ;;
  esac
  out=$(run_op "$b" "" works dead null)
  case "$out" in 'ERR-TZ|null|Europe/Default|') ok "S11 automatic, the row reads null -> ERR-TZ" ;; *) no "S11 got '$out'" ;; esac
  lg=$(run_log "$b" "" works dead null)
  case "$lg" in *'settz automatic NOT APPLIED (auto_time_zone read ?) '*) ok "S11 an unreadable row logs '?'" ;;
    *) no "S11 got '$lg'" ;; esac
  out=$(run_op "$b" Europe/Paris works dead 1)
  case "$out" in 'ERR-TZ|1|Europe/Paris|') ok "S12 override, the zone lands but auto_time_zone stays 1 -> ERR-TZ" ;;
    *) no "S12 a pin the detector will move was reported: got '$out'" ;; esac
  lg=$(run_log "$b" Europe/Paris works dead 1)
  case "$lg" in *'settz override NOT APPLIED (auto_time_zone read 1, not 0) '*) ok "S12 the NOT APPLIED line says the row read 1" ;;
    *) no "S12 got '$lg'" ;; esac
  out=$(run_op "$b" Europe/Paris works lands 1)
  case "$out" in 'OK APPLIED|0|Europe/Paris|') ok "S13 override, both land -> OK APPLIED" ;; *) no "S13 got '$out'" ;; esac
  out=$(run_op "$b" Europe/Paris dead dead 1)
  case "$out" in 'ERR-TZ|1|Etc/Old|') ok "S14 override, neither lands -> ERR-TZ" ;; *) no "S14 got '$out'" ;; esac
  lg=$(run_log "$b" Europe/Paris dead dead 1)
  case "$lg" in *'NOT APPLIED (the pinned zone did not read back) '*) ok "S14 the zone's failure is the reason logged first" ;;
    *) no "S14 got '$lg'" ;; esac
  nozone "S15 the automatic NOT APPLIED log" "$(run_log "$b" "" works dead 0)"
  nozone "S15 the auto_time_zone NOT APPLIED log" "$(run_log "$b" Europe/Paris works dead 1)"
  nozone "S15 the both-land APPLIED log" "$(run_log "$b" Europe/Paris works lands 1)"
  nozone "S15 the neither-lands log" "$(run_log "$b" Europe/Paris dead dead 1)"

  rm -f "$b"
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$SHX" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "settz op verdict: $SUT (shells:$SHELLS)"
for SHX in $SHELLS; do
  suite "$SUT"; rc=$?
  [ "$rc" = 0 ] || FAILED=1
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell):"
  mtmp=$(mktemp -d -p "$W")
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r SHX
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    for SHX in $SHELLS; do
      suite "$mf" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-71s SURVIVED\n' "[$SHX] $label"; MFAIL=1 ;;
        1) printf '  ok    %-71s convicted\n' "[$SHX] $label" ;;
        *) printf '  ERR   %-71s harness error (rc=%s), not a conviction\n' "[$SHX] $label" "$r"; MFAIL=1 ;;
      esac
    done
  }
  mutate 'bare OK restored on the override arm'  's@^      echo "ERR-TZ" > "\$RES"$@      echo "OK" > "$RES"@'
  mutate 'the readback compares the wrong prop'  's@applied=\$\(getprop persist\.sys\.timezone\)@applied=$(getprop persist.sys.timezone.x)@'
  mutate 'the readback is dropped'               's@^    applied=\$\(getprop persist\.sys\.timezone\)$@    applied="$zone"@'
  mutate 'the applied arm answers a bare OK'     's@echo "OK APPLIED" > "\$RES"@echo "OK" > "$RES"@'
  mutate 'the zone is back in the APPLIED line'   's@settz override APPLIED@settz override $zone APPLIED@'
  mutate 'the zone is back in the NOT APPLIED line' 's@settz override NOT APPLIED \(the pinned zone did not read back\)@settz override $zone NOT APPLIED@'
  mutate 'the read-back zone is back in the log'  's@NOT APPLIED \(the pinned zone did not read back\)@NOT APPLIED (persist.sys.timezone='"'"'$applied'"'"')@'
  mutate 'the APPLIED log line is deleted'        '/echo "\[roamd\] settz override APPLIED/d'
  mutate 'automatic answers a bare OK'           's@echo "OK AUTO" > "\$RES"@echo "OK" > "$RES"@'
  mutate 'the automatic arm answers OK AUTO without the check' 's@^    if \[ "\$tzauto" = 1 \]; then$@    if true; then@'
  mutate 'the override arm drops the auto_time_zone condition' 's@ && \[ "\$tzauto" = 0 \]@@'
  mutate 'the override read-back compares against 1'           's@\[ "\$tzauto" = 0 \]@[ "$tzauto" = 1 ]@'
  mutate 'the automatic read-back compares against 0'          's@^    if \[ "\$tzauto" = 1 \]; then$@    if [ "$tzauto" = 0 ]; then@'
  mutate 'the auto_time_zone NOT APPLIED line names the zone'  's@\(auto_time_zone read \$\{tzauto:-\?\}, not 0\)@(auto_time_zone read ${tzauto:-?}, not 0, zone $zone)@'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
