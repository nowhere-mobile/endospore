#!/usr/bin/env bash
# test-provision-steps.sh [<nowhere_provision.sh>] [--mutate] -- the five setup steps of nowhere_provision.sh
# log what they DID, not that they ran (NWP-20261110-18).
#
# WHY THIS IS COMMITTED. The script wrote a success line after five commands whose outcome it never read:
# `locksettings set-disabled true`, the two private-DNS puts, `pm disable-user org.lineageos.setupwizard` (a
# package Endospore does not have, so the line was false on every Pixel), `device_config put system_time ...`
# and `am start ...ChooserActivity`. provision.log is one of the three logs a gate-filed issue report carries
# (report_issue.go), so a false line is evidence an owner's report rests on: a wedged SettingsProvider leaves
# private DNS unapplied while the log says "private DNS = DoT dns.mullvad.net". The rule is the one the dropbox
# block states: assert the value, never the call.
#
# HOW. The WHOLE script runs in a child shell (every shell found of bash, sh, dash, mksh) with an owner record
# present, so the claim loop is skipped. Transform: every `/data/` is rewritten to `<scratch>/`. The commands are
# function stubs that append their argv to <scratch>/calls, return per-case statuses and answer `settings get`
# per case; `pm path org.lineageos.setupwizard` answers present or absent per case. Where /proc/self/fd is
# readable each stub also records where its stdin, stdout and stderr point, so the suite can prove every cmd keeps
# its stdio on /dev/null (the owner_ok note in the script says why); a text pin of the redirects runs everywhere.
#
#   bash test-provision-steps.sh            # the cases
#   bash test-provision-steps.sh --mutate   # ... plus five mutants that must each CONVICT under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_provision.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS="bash"
for s in sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
FDCHECK=no; [ -r /proc/self/fd/0 ] && FDCHECK=yes

OURS='<?xml version="1.0"?><device-owner package="com.nowhere.chooser" name="" component="com.nowhere.chooser/.AdminReceiver" />'
LOGCASE=""

# run_case <script> <shell> <dir> <rc_lock> <rc_dc> <rc_am> <wiz:0 present|1 absent> <rc_pmdis> <get_mode> <get_spec>
run_case() {
  local sut="$1" sh="$2" d="$3"
  mkdir -p "$d/system" "$d/nowhere"
  : > "$d/calls"; : > "$d/fds"
  printf '%s\n' "$OURS" > "$d/system/device_owner_2.xml"
  printf 'stdin\n' > "$d/stdin"
  sed "s#/data/#$d/#g" "$sut" > "$d/script.sh"
  cat > "$d/prelude.sh" <<PRE
D="$d"; RC_LOCK="$4"; RC_DC="$5"; RC_AM="$6"; WIZ="$7"; RC_PMDIS="$8"; GET_MODE="$9"; GET_SPEC="${10}"
trap 'wait' EXIT
getprop() {
  case "\${1:-}" in
    ro.build.type) echo user ;;
    ro.debuggable) echo 0 ;;
    *) echo "getprop \$*" >> "\$D/unexpected"; echo "" ;;
  esac
}
rec() {
  { readlink /proc/self/fd/7 /proc/self/fd/8 /proc/self/fd/9 2>/dev/null | tr '\n' ' '; echo "| \$*"; } 7<&0 8>&1 9>&2 >> "\$D/fds"
  echo "\$*" >> "\$D/calls"
}
locksettings() { rec "locksettings \$*"; return "\$RC_LOCK"; }
device_config() { rec "device_config \$*"; return "\$RC_DC"; }
am() { rec "am \$*"; return "\$RC_AM"; }
pm() {
  rec "pm \$*"
  case "\${1:-} \${2:-}" in
    "path org.lineageos.setupwizard") return "\$WIZ" ;;
    "disable-user "*) return "\$RC_PMDIS" ;;
  esac
  return 0
}
settings() {
  rec "settings \$*"
  case "\$1 \$2 \$3" in
    "get global private_dns_mode") echo "\$GET_MODE" ;;
    "get global private_dns_specifier") echo "\$GET_SPEC" ;;
    "get global dropbox_age_seconds") echo 7200 ;;
    "get global dropbox_max_files") echo 200 ;;
  esac
  return 0
}
dpm() { rec "dpm \$*"; return 0; }
setprop() { rec "setprop \$*"; }
restorecon() { rec "restorecon \$*"; }
sleep() { :; }
. "\$D/script.sh"
PRE
  "$sh" "$d/prelude.sh" < "$d/stdin" > "$d/out" 2>&1
  RC=$?
}

# suite <script> <quiet|""> <shells...> -> 0 all ok, 1 a case failed, 2 harness error
suite() {
  local sut="$1" quiet="$2" p=0 x=0 sh d log calls shs
  shift 2; shs="$*"
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  chk() { if [ "$2" = 0 ]; then ok "$1"; else no "$1"; fi; }
  has() { grep -F -q -e "$1" "$log" 2>/dev/null; }
  n_calls() { local n; n=$(grep -F -c -e "$1" "$calls" 2>/dev/null); echo "${n:-0}"; }
  # cs <label> <rc_lock> <rc_dc> <rc_am> <wiz> <rc_pmdis> <mode> <spec>
  cs() {
    d=$(mktemp -d -p "$W"); log="$d/nowhere/provision.log"; calls="$d/calls"
    run_case "$sut" "$sh" "$d" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  }
  for sh in $shs; do
    local t="[$sh]"
    # P1 all calls succeed and read back
    cs P1 0 0 0 0 0 hostname dns.mullvad.net
    chk "$t P1 script ran to its end, no unexpected getprop" "$([ "$RC" = 0 ] && [ ! -e "$d/unexpected" ] && [ -f "$log" ] && echo 0 || echo 1)"
    chk "$t P1 five rc=0 / DNS lines, no WARN" "$(has 'keyguard disable rc=0' && has 'private DNS = DoT dns.mullvad.net' && has 'setupwizard disable rc=0' && has 'geolocation tz detection default rc=0' && has 'launched gate to clear stopped-state rc=0' && ! has WARN && echo 0 || echo 1)"
    chk "$t P1 the old unchecked wording is gone" "$(! has 'keyguard disabled (' && ! has 'setupwizard disabled on user 0' && ! has 'defaulted ON' && echo 0 || echo 1)"
    # P2 locksettings fails
    cs P2 1 0 0 0 0 hostname dns.mullvad.net
    chk "$t P2 locksettings rc 1 -> keyguard disable rc=1" "$(has 'keyguard disable rc=1' && ! has 'keyguard disable rc=0' && echo 0 || echo 1)"
    # P3 DNS read-back empty
    cs P3 0 0 0 0 0 "" ""
    chk "$t P3 empty read-back -> WARN naming both values, no DoT line" "$(has 'WARN private DNS NOT applied -- mode= want=hostname, specifier= want=dns.mullvad.net' && ! has 'private DNS = DoT' && echo 0 || echo 1)"
    cs P3b 0 0 0 0 0 hostname ""
    chk "$t P3b mode right, specifier empty -> WARN, no DoT line" "$(has 'WARN private DNS NOT applied -- mode=hostname want=hostname, specifier= want=dns.mullvad.net' && ! has 'private DNS = DoT' && echo 0 || echo 1)"
    # P4 wizard absent
    cs P4 0 0 0 1 0 hostname dns.mullvad.net
    chk "$t P4 wizard absent -> the 'no LineageOS setup wizard' line" "$(has 'no LineageOS setup wizard on this build -- nothing to disable' && ! has 'setupwizard disable rc=' && echo 0 || echo 1)"
    chk "$t P4 ... and NO pm disable-user call" "$([ "$(n_calls 'pm disable-user')" = 0 ] && echo 0 || echo 1)"
    # P5 wizard present
    cs P5 0 0 0 0 3 hostname dns.mullvad.net
    chk "$t P5 present -> exactly one pm disable-user --user 0 org.lineageos.setupwizard, rc logged" "$([ "$(n_calls 'pm disable-user --user 0 org.lineageos.setupwizard')" = 1 ] && has 'setupwizard disable rc=3' && ! has 'no LineageOS setup wizard' && echo 0 || echo 1)"
    # P6 device_config 2, am 1
    cs P6 0 2 1 0 0 hostname dns.mullvad.net
    chk "$t P6 device_config rc 2 and am rc 1 both logged" "$(has 'geolocation tz detection default rc=2' && has 'launched gate to clear stopped-state rc=1' && echo 0 || echo 1)"
    # P7 stdio
    cs P7 0 0 0 0 0 hostname dns.mullvad.net
    chk "$t P7 every wrapped command was called" "$([ "$(n_calls 'locksettings set-disabled true')" = 1 ] && [ "$(n_calls 'pm path org.lineageos.setupwizard')" = 1 ] && [ "$(n_calls 'device_config put system_time')" = 1 ] && [ "$(n_calls 'settings get global private_dns_mode')" = 1 ] && [ "$(n_calls 'settings get global private_dns_specifier')" = 1 ] && echo 0 || echo 1)"
    if [ "$FDCHECK" = yes ]; then
      local bad=0 line f1 f2 f3 rest cmd
      while IFS= read -r line; do
        rest="${line%% | *}"; cmd="${line#* | }"
        case "$cmd" in "pm path com.nowhere.chooser") continue ;; esac
        set -- $rest; f1="${1:-}"; f2="${2:-}"; f3="${3:-}"
        case "$cmd" in
          "settings get "*) [ "$f1" = /dev/null ] && [ "$f3" = /dev/null ] || bad=$((bad+1)) ;;
          *) [ "$f1" = /dev/null ] && [ "$f2" = /dev/null ] && [ "$f3" = /dev/null ] || bad=$((bad+1)) ;;
        esac
      done < "$d/fds"
      chk "$t P7 every cmd's stdio is /dev/null (read from /proc, $bad off)" "$([ "$bad" = 0 ] && [ -s "$d/fds" ] && echo 0 || echo 1)"
    fi
  done
  # P7 text pin, shell-independent
  local pin=0 l
  for l in \
    'locksettings set-disabled true </dev/null >/dev/null 2>&1' \
    '  pm disable-user --user 0 org.lineageos.setupwizard </dev/null >/dev/null 2>&1' \
    'if pm path org.lineageos.setupwizard </dev/null >/dev/null 2>&1; then' \
    'am start -n com.nowhere.chooser/.ChooserActivity </dev/null >/dev/null 2>&1' \
    '_dnsmode=$(settings get global private_dns_mode </dev/null 2>/dev/null)' \
    '_dnsspec=$(settings get global private_dns_specifier </dev/null 2>/dev/null)'; do
    grep -F -x -q -e "$l" "$sut" || pin=$((pin+1))
  done
  grep -F -q 'device_config put system_time location_time_zone_detection_setting_enabled_default true </dev/null >/dev/null 2>&1' "$sut" || pin=$((pin+1))
  chk "P7 text pin: every cmd keeps </dev/null (and 2>&1 or 2>/dev/null) ($pin missing)" "$([ "$pin" = 0 ] && echo 0 || echo 1)"
  # every step line goes to the log file, not stdout
  local nolog
  nolog=$(grep -F -e '[provision] keyguard disable' -e '[provision] private DNS' -e '[provision] WARN private DNS' \
    -e '[provision] setupwizard disable' -e '[provision] no LineageOS setup wizard' \
    -e '[provision] geolocation tz' -e '[provision] launched gate' "$sut" | grep -F -v -c '>> "$LOG"')
  chk "P7 text pin: every step line ends >> \"\$LOG\" ($nolog do not)" "$([ "$nolog" = 0 ] && echo 0 || echo 1)"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "provisioning step log lines: $SUT (shells: $SHELLS, fd check: $FDCHECK)"
suite "$SUT" "" $SHELLS; rc=$?
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  command -v perl >/dev/null || { echo "perl is required for --mutate" >&2; exit 2; }
  echo
  echo "mutations (each must CONVICT under each shell):"
  mutate() {  # <label> <perl program>
    local label="$1" prog="$2" mf sh r
    mf=$(mktemp -p "$W")
    if ! perl -0pe "$prog" "$SUT" > "$mf"; then printf '  ERR   %-52s perl program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-52s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    for sh in $SHELLS; do
      suite "$mf" quiet "$sh" >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-52s [%s] SURVIVED\n' "$label" "$sh"; MFAIL=1 ;;
        1) printf '  ok    %-52s [%s] convicted\n' "$label" "$sh" ;;
        *) printf '  ERR   %-52s [%s] harness error (rc=%s)\n' "$label" "$sh" "$r"; MFAIL=1 ;;
      esac
    done
    rm -f "$mf"
  }
  mutate 'M1 the DNS line is unconditional' 's@^if \[ "\$_dnsmode" = hostname \].*?\nelse\n.*?\nfi\n@echo "[provision] private DNS = DoT dns.mullvad.net (no-log) \$(date)" >> "\$LOG"\n@ms'
  mutate 'M2 the read-back compares only the mode' 's@ && \[ "\$_dnsspec" = dns\.mullvad\.net \]@@'
  mutate 'M3 the wizard is disabled without the probe' 's@^if pm path org\.lineageos\.setupwizard [^\n]*; then$@if true; then@m'
  mutate 'M4 the keyguard rc is a literal 0' 's@(locksettings set-disabled true </dev/null >/dev/null 2>&1\n_rc=)\$\?@${1}0@'
  mutate 'M5 a cmd drops its </dev/null' 's@locksettings set-disabled true </dev/null @locksettings set-disabled true @'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS CONVICTED" || { echo "PROBLEM: a mutation survived"; FAILED=1; }
fi

exit "${FAILED:-0}"
