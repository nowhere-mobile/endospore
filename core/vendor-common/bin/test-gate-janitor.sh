#!/usr/bin/env bash
# test-gate-janitor.sh [<nowhere_gate.sh>] [--mutate] -- the boot janitor in nowhere_gate.sh, EXECUTED (NWP-20261019-15).
#
# WHY THIS IS COMMITTED. The janitor (the telephony scrub, DIA-20260808-01 / #135 B5 / #150) ran in no test: test-tel-scrub.sh
# pins its TEXT byte for byte and test-nowhere-db-fix.sh tests the tool, but nothing executed the script. Two defects hid there:
# the three FILE wipes (MMS attachment payloads, the cleartext MMS staging dir) sat inside the nowhere_db_fix guard although
# they never need the tool, and scrub_db threw away telscrub's exit status, so a denied or busy database left its deleted
# rows on disk with no line anywhere. This runs a re-rooted copy of the script with stubs on PATH:
#   T1  every planted database gets exactly one telscrub call with exactly its table list, in both bases; raw is in none
#   T2  an absent database gets no call
#   T3  app_parts/*, parts/* and cache/mms/* are emptied in both bases and the directories kept
#   T4  with the tool absent: one `telscrub SKIPPED` line, no telscrub call, and the file wipes STILL done
#   T5  one failing telscrub leaves exactly one `telscrub FAILED rc=<n>` line naming it, every other database is still
#       scrubbed; with every exit 0 there is no FAILED line
#   T6  today's boot order: set-home-activity before the first `am start`, `am start` retried until it succeeds,
#       locksettings and the user switcher asserted once each, and none of the four boot-step failure lines written
# The per-boot steps above the janitor report a failure (T7-T10, NWP-20261122-17):
#   T7  a failing HOME pin: one set-home-activity call, before the first `am start`, one `home pin FAILED rc=1` line,
#       and the launch loop and the janitor still run
#   T8  every `am start` failing: exactly 4 tries and one `gate launch FAILED` line
#   T9  a failing locksettings: one `keyguard disable FAILED rc=3` line
#   T10 the switcher reads back 1: one `user switcher NOT hidden` line
# /system/bin/nowhere_db_fix, /data/user/0 and /data/user_de/0 are rewritten to a scratch root (each rewrite counted:
# a miscount is REWRITE FAILED, exit 2; the FAILED line's /data/ prefix is stripped by the script, so under the
# rewrite the scratch root stays in the path). Each case runs under every POSIX shell found (bash, sh, dash, mksh).
#
#   bash test-gate-janitor.sh            # the cases
#   bash test-gate-janitor.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_gate.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Every installed name runs under ITS OWN name (sh may be bash or dash behind a symlink; argv[0] decides its mode), so
# no de-duplication by resolved path.
SHELLS=()
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  SHELLS+=("$p")
done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

MM="sms pdu part addr canonical_addresses threads pending_msgs sr_pending attachments drm words"
AN="SmsMmsDataLogs ServiceStateLogs CallDataLogs"
TP=com.android.providers.telephony; CP=com.android.providers.contacts; PH=com.android.phone
DBS="$TP/databases/mmssms.db $CP/databases/calllog.db $CP/databases/calllog_shadow.db $PH/databases/telephony_analytics.db"

# Code-line (non-comment) occurrences of each rewritten target: the tool path is named by the guard, the call and the SKIPPED
# line (3); a base path by the database loop and, since NWP-20261019-15, the file-wipe loop (2) -- or by the one shared loop
# of origin/main (1), which this suite must still be able to run against and convict. A mutant that drops /data/user_de/0
# from one loop leaves 1 or 2 as well.
N_TOOL="3"; N_CE="1 2"; N_DE="1 2"

# setup <script> <root> <tool:yes|no> -> $root/gate.sh, stubs in $root/bin, planted files
setup() {
  local script="$1" root="$2" tool="$3" b n
  mkdir -p "$root/bin" "$root/sys/bin" "$root/data/user/0" "$root/data/user_de/0"
  for pair in "/system/bin/nowhere_db_fix:$N_TOOL" "/data/user/0:$N_CE" "/data/user_de/0:$N_DE"; do
    n=$(grep -v '^[[:space:]]*#' "$script" | grep -o "${pair%%:*}" | wc -l); n=$((n + 0))
    case " ${pair#*:} " in *" $n "*) ;; *) echo "REWRITE FAILED: ${pair%%:*} found $n times, expected ${pair#*:}" >&2; exit 2 ;; esac
  done
  sed -e "s@/system/bin/nowhere_db_fix@$root/sys/bin/nowhere_db_fix@g" \
      -e "s@/data/user_de/0@$root/data/user_de/0@g" \
      -e "s@/data/user/0@$root/data/user/0@g" "$script" > "$root/gate.sh"
  : > "$root/calls.log"
  for c in cmd am locksettings settings log sleep; do
    printf '#!/bin/sh\nprintf "%s:" >> "$CALLS"; for a in "$@"; do printf " %%s" "$a" >> "$CALLS"; done; echo >> "$CALLS"\n' "$c" > "$root/bin/$c"
  done
  # cmd exits CMD_RC, locksettings exits LOCK_RC, `settings get global user_switcher_enabled` prints SW_VALUE
  printf '#!/bin/sh\nprintf "cmd:" >> "$CALLS"; for a in "$@"; do printf " %%s" "$a" >> "$CALLS"; done; echo >> "$CALLS"\nexit "${CMD_RC:-0}"\n' > "$root/bin/cmd"
  printf '#!/bin/sh\nprintf "locksettings:" >> "$CALLS"; for a in "$@"; do printf " %%s" "$a" >> "$CALLS"; done; echo >> "$CALLS"\nexit "${LOCK_RC:-0}"\n' > "$root/bin/locksettings"
  printf '#!/bin/sh\nprintf "settings:" >> "$CALLS"; for a in "$@"; do printf " %%s" "$a" >> "$CALLS"; done; echo >> "$CALLS"\n[ "$1 $2 $3" = "get global user_switcher_enabled" ] && printf "%%s\\n" "${SW_VALUE-0}"\nexit 0\n' > "$root/bin/settings"
  # am fails its first AM_FAILS calls
  printf '#!/bin/sh\nprintf "am:" >> "$CALLS"; for a in "$@"; do printf " %%s" "$a" >> "$CALLS"; done; echo >> "$CALLS"\nn=$(cat "$ROOT/am.n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$ROOT/am.n"\n[ "$n" -gt "${AM_FAILS:-0}" ]\n' > "$root/bin/am"
  # nowhere_db_fix: records, exits FAILRC when the db path ends with FAILDB
  printf '#!/bin/sh\nprintf "telscrub-call:" >> "$CALLS"; for a in "$@"; do printf " %%s" "$a" >> "$CALLS"; done; echo >> "$CALLS"\ncase "$2" in *"$FAILDB") [ -n "$FAILDB" ] && exit "$FAILRC";; esac\nexit 0\n' > "$root/sys/bin/nowhere_db_fix"
  chmod +x "$root"/bin/* "$root/sys/bin/nowhere_db_fix"
  [ "$tool" = yes ] || rm -f "$root/sys/bin/nowhere_db_fix"
  for b in user/0 user_de/0; do
    for d in $DBS; do mkdir -p "$(dirname "$root/data/$b/$d")"; : > "$root/data/$b/$d"; done
    mkdir -p "$root/data/$b/$TP/app_parts" "$root/data/$b/$TP/parts" "$root/data/$b/com.nowhere.chooser/cache/mms"
    : > "$root/data/$b/$TP/app_parts/PART_1_x"; : > "$root/data/$b/$TP/parts/PART_2_y"
    : > "$root/data/$b/com.nowhere.chooser/cache/mms/stage.bin"; : > "$root/data/$b/com.nowhere.chooser/cache/keep"
  done
}

# run_gate <shell> <root> -- env: FAILDB FAILRC AM_FAILS CMD_RC LOCK_RC SW_VALUE
run_gate() {
  ROOT="$2" CALLS="$2/calls.log" PATH="$2/bin:$PATH" "$1" "$2/gate.sh" >/dev/null 2>&1
}

# check <label> <script> -- runs every case against $2 under every shell
check() {
  local script="$1" sh root n want db b nm
  for sh in "${SHELLS[@]}"; do
    nm=$(basename "$sh")
    # --- T1/T2/T3/T5(clean)/T6: tool present, everything exits 0
    root=$(mktemp -d -p "$W") || exit 2; setup "$script" "$root" yes
    # T2: one database absent in user_de/0
    rm -f "$root/data/user_de/0/$CP/databases/calllog_shadow.db"
    FAILDB="" FAILRC=0 AM_FAILS=2 run_gate "$sh" "$root"
    local log; log=$(cat "$root/calls.log")
    local t1=yes
    for b in user/0 user_de/0; do
      for db in $DBS; do
        case "$db" in *mmssms.db) want="$MM";; *telephony_analytics.db) want="$AN";; *) want="calls";; esac
        n=$(printf '%s\n' "$log" | grep -cxF "telscrub-call: telscrub $root/data/$b/$db $want")
        if [ "$b/$db" = "user_de/0/$CP/databases/calllog_shadow.db" ]; then
          [ "$n" -eq 0 ] || t1=no
        else
          [ "$n" -eq 1 ] || { t1=no; echo "    ($nm) $b/$db: $n calls" >&2; }
        fi
      done
    done
    n=$(printf '%s\n' "$log" | grep -c '^telscrub-call:')
    [ "$n" -eq 7 ] || t1=no
    calls=$(grep -E '^telscrub-call:' <<<"$log")
    if grep -qiw raw <<<"$calls"; then t1=no; fi
    [ "$t1" = yes ] && ok "T1/T2 [$nm] each present db scrubbed once with exactly its tables, no raw, the absent one untouched" \
                    || no "T1/T2 [$nm] table lists/calls wrong (7 expected calls, got $n)"
    local t3=yes
    for b in user/0 user_de/0; do
      for f in "$TP/app_parts/PART_1_x" "$TP/parts/PART_2_y" "com.nowhere.chooser/cache/mms/stage.bin"; do
        [ -e "$root/data/$b/$f" ] && t3=no
      done
      for d in "$TP/app_parts" "$TP/parts" "com.nowhere.chooser/cache/mms"; do [ -d "$root/data/$b/$d" ] || t3=no; done
      [ -e "$root/data/$b/com.nowhere.chooser/cache/keep" ] || t3=no
    done
    [ "$t3" = yes ] && ok "T3 [$nm] part stores and cache/mms emptied in both bases, directories (and cache/keep) kept" \
                    || no "T3 [$nm] a file wipe missed a base, or removed too much"
    n=$(printf '%s\n' "$log" | grep -c 'FAILED')
    [ "$n" -eq 0 ] && ok "T5 [$nm] all exit 0: no FAILED line" || no "T5 [$nm] FAILED line written with every exit status 0"
    # T6
    local first_am home t6=yes
    home=$(grep -n '^cmd: package set-home-activity --user 0 com.nowhere.chooser/com.nowhere.chooser.ChooserActivity$' <<<"$log"); home=${home%%:*}
    first_am=$(grep -n '^am: start' <<<"$log"); first_am=${first_am%%:*}
    [ -n "$home" ] && [ -n "$first_am" ] && [ "$home" -lt "$first_am" ] || t6=no
    [ "$(printf '%s\n' "$log" | grep -c '^am: start -n com.nowhere.chooser/.ChooserActivity$')" -eq 3 ] || t6=no
    [ "$(printf '%s\n' "$log" | grep -cx 'locksettings: set-disabled true')" -eq 1 ] || t6=no
    [ "$(printf '%s\n' "$log" | grep -cx 'settings: put global user_switcher_enabled 0')" -eq 1 ] || t6=no
    local fl
    for fl in 'home pin FAILED' 'gate launch FAILED' 'keyguard disable FAILED' 'user switcher NOT hidden'; do
      [ "$(printf '%s\n' "$log" | grep -cF "$fl")" -eq 0 ] || { t6=no; echo "    ($nm) clean run wrote: $fl" >&2; }
    done
    [ "$t6" = yes ] && ok "T6 [$nm] home pin before the launch, launch retried to success (3 calls), keyguard and switcher once, no failure line" \
                    || no "T6 [$nm] boot order/retry/re-assertions wrong, or a clean run wrote a failure line"
    rm -rf "$root"
    # --- T4: tool absent
    root=$(mktemp -d -p "$W") || exit 2; setup "$script" "$root" no
    FAILDB="" FAILRC=0 run_gate "$sh" "$root"
    log=$(cat "$root/calls.log"); local t4=yes
    [ "$(printf '%s\n' "$log" | grep -c '^log: .*telscrub SKIPPED')" -eq 1 ] || t4=no
    [ "$(printf '%s\n' "$log" | grep -c '^telscrub-call:')" -eq 0 ] || t4=no
    for b in user/0 user_de/0; do
      for f in "$TP/app_parts/PART_1_x" "$TP/parts/PART_2_y" "com.nowhere.chooser/cache/mms/stage.bin"; do
        [ -e "$root/data/$b/$f" ] && t4=no
      done
    done
    [ "$t4" = yes ] && ok "T4 [$nm] tool absent: one SKIPPED line, no telscrub call, file wipes still done in both bases" \
                    || no "T4 [$nm] tool-absent boot wrong (SKIPPED line / telscrub calls / file wipes)"
    rm -rf "$root"
    # --- T5: one failure
    root=$(mktemp -d -p "$W") || exit 2; setup "$script" "$root" yes
    FAILDB="$root/data/user/0/$CP/databases/calllog.db" FAILRC=6 run_gate "$sh" "$root"
    log=$(cat "$root/calls.log"); local t5=yes
    [ "$(printf '%s\n' "$log" | grep -c 'FAILED')" -eq 1 ] || t5=no
    [ "$(printf '%s\n' "$log" | grep -c '^log: -t nowhere_gate telscrub FAILED rc=6 on '"$root/data/user/0/$CP"'/databases/calllog.db -- ')" -eq 1 ] || t5=no
    [ "$(printf '%s\n' "$log" | grep -c '^telscrub-call:')" -eq 8 ] || t5=no
    grep -qxF "telscrub-call: telscrub $root/data/user_de/0/$CP/databases/calllog.db calls" <<<"$log" || t5=no
    grep -qxF "telscrub-call: telscrub $root/data/user_de/0/$PH/databases/telephony_analytics.db $AN" <<<"$log" || t5=no
    [ "$t5" = yes ] && ok "T5 [$nm] rc=6 on user/0 calllog.db: exactly one FAILED line naming it, every other db still scrubbed" \
                    || no "T5 [$nm] failure not reported once and by name, or it stopped the other scrubs"
    rm -rf "$root"
    # --- T7: the HOME pin fails
    root=$(mktemp -d -p "$W") || exit 2; setup "$script" "$root" yes
    FAILDB="" FAILRC=0 CMD_RC=1 run_gate "$sh" "$root"
    log=$(cat "$root/calls.log"); local t7=yes
    [ "$(printf '%s\n' "$log" | grep -cx 'cmd: package set-home-activity --user 0 com.nowhere.chooser/com.nowhere.chooser.ChooserActivity')" -eq 1 ] || t7=no
    home=$(grep -n '^cmd: package set-home-activity' <<<"$log"); home=${home%%:*}
    first_am=$(grep -n '^am: start' <<<"$log"); first_am=${first_am%%:*}
    [ -n "$home" ] && [ -n "$first_am" ] && [ "$home" -lt "$first_am" ] || t7=no
    [ "$(printf '%s\n' "$log" | grep -cxF 'log: -t nowhere_gate home pin FAILED rc=1 -- a gate crash now lands on launcher3 (#46)')" -eq 1 ] || t7=no
    [ "$(printf '%s\n' "$log" | grep -c '^telscrub-call:')" -eq 8 ] || t7=no
    [ "$t7" = yes ] && ok "T7 [$nm] pin rc=1: one pin call before the launch, one home pin FAILED line, launch and janitor still run" \
                    || no "T7 [$nm] failed HOME pin not reported once, or it stopped the launch or the janitor"
    rm -rf "$root"
    # --- T8: every launch fails
    root=$(mktemp -d -p "$W") || exit 2; setup "$script" "$root" yes
    FAILDB="" FAILRC=0 AM_FAILS=9 run_gate "$sh" "$root"
    log=$(cat "$root/calls.log"); local t8=yes
    [ "$(printf '%s\n' "$log" | grep -cx 'am: start -n com.nowhere.chooser/.ChooserActivity')" -eq 4 ] || t8=no
    [ "$(printf '%s\n' "$log" | grep -cxF "log: -t nowhere_gate gate launch FAILED after 4 tries -- the BootReceiver's launch is the only one left")" -eq 1 ] || t8=no
    [ "$t8" = yes ] && ok "T8 [$nm] every am start fails: 4 tries and one gate launch FAILED line" \
                    || no "T8 [$nm] launch failure: wrong try count or not reported once"
    rm -rf "$root"
    # --- T9: locksettings fails
    root=$(mktemp -d -p "$W") || exit 2; setup "$script" "$root" yes
    FAILDB="" FAILRC=0 LOCK_RC=3 run_gate "$sh" "$root"
    log=$(cat "$root/calls.log")
    [ "$(printf '%s\n' "$log" | grep -cxF 'log: -t nowhere_gate keyguard disable FAILED rc=3')" -eq 1 ] \
      && ok "T9 [$nm] locksettings rc=3: one keyguard disable FAILED rc=3 line" \
      || no "T9 [$nm] failed keyguard re-assert not reported once"
    rm -rf "$root"
    # --- T10: the switcher reads back 1
    root=$(mktemp -d -p "$W") || exit 2; setup "$script" "$root" yes
    FAILDB="" FAILRC=0 SW_VALUE=1 run_gate "$sh" "$root"
    log=$(cat "$root/calls.log")
    [ "$(printf '%s\n' "$log" | grep -cxF 'log: -t nowhere_gate user switcher NOT hidden -- user_switcher_enabled=1 want=0')" -eq 1 ] \
      && ok "T10 [$nm] switcher reads back 1: one user switcher NOT hidden line" \
      || no "T10 [$nm] switcher left visible not reported once"
    rm -rf "$root"
  done
}

echo "== the boot janitor, executed (${#SHELLS[@]} shell(s): ${SHELLS[*]}) =="
check "$SUT" 2>&1 | tee "$W/gj" >/dev/null; CRC=${PIPESTATUS[0]}; cat "$W/gj"
P=$(grep -c '^  ok' "$W/gj"); F=$(grep -c '^  FAIL' "$W/gj"); rm -f "$W/gj"
PASS=$P; FAIL=$F
[ "$PASS" -gt 0 ] || { echo "no case ran" >&2; exit 2; }
[ "$CRC" = 0 ] || { echo "the harness stopped before every case ran (rc=$CRC)" >&2; exit 2; }

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  # mutate <label> <sed|awk> <program> [<case>]: apply to a copy, require it changed, require a FAIL line (of <case>,
  # when one is named)
  mutate() {
    local label="$1" kind="$2" prog="$3" want="${4:-}" tmp out
    tmp=$(mktemp -d -p "$W") || exit 2
    if [ "$kind" = sed ]; then sed -e "$prog" "$SUT" > "$tmp/m.sh"; else awk "$prog" "$SUT" > "$tmp/m.sh"; fi
    if cmp -s "$SUT" "$tmp/m.sh"; then
      no "mutant did not apply: $label"; rm -rf "$tmp"; return
    fi
    out=$(bash "$0" "$tmp/m.sh" 2>&1); local rc=$?
    case "$out" in *"REWRITE FAILED"*) no "mutant broke the re-rooting, not the suite: $label"; rm -rf "$tmp"; return ;; esac
    if [ "$rc" -ne 0 ] && grep -q "^  FAIL  ${want}${want:+ }" <<<"$out"; then ok "convicted: $label${want:+ (by $want)}"; else no "NOT convicted: $label${want:+ (by $want)}"; fi
    rm -rf "$tmp"
  }
  mutate "telscrub's exit status ignored again" sed 's/^    _rc=\$?$/    _rc=0/'
  mutate "the FAILED line written on rc 0 too" sed 's/"\$_rc" -eq 0 \] || log/"$_rc" -ge 0 ] \&\& log/'
  mutate "the file wipes moved back under the tool guard" awk '
    /^for _base in/ && !seen { seen = 1; inloop = 1 }
    inloop { held = held $0 "\n"; if ($0 == "done") inloop = 0; next }
    { print }
    /^if \[ -x / && held != "" { printf "%s", held }
    '
  mutate "raw added to the mmssms.db list" sed 's/^      sms pdu part addr/      sms raw pdu part addr/'
  mutate "ServiceStateLogs dropped from the analytics list" sed 's/SmsMmsDataLogs ServiceStateLogs CallDataLogs/SmsMmsDataLogs CallDataLogs/'
  mutate "/data/user_de/0 dropped from the DATABASE loop" sed 's@^  for _base in /data/user/0 /data/user_de/0; do@  for _base in /data/user/0; do@'
  mutate "/data/user_de/0 dropped from the FILE-WIPE loop" sed 's@^for _base in /data/user/0 /data/user_de/0; do@for _base in /data/user/0; do@'
  mutate "set-home-activity moved after the launch loop" awk '
    /^cmd package set-home-activity/ { held = $0; next }
    { print }
    /^done$/ && held != "" && !put { print held; put = 1 }
    '
  # NWP-20261122-17: the per-boot steps' failure lines, each convicted by its named case
  mutate "M1 the HOME pin's status ignored" sed 's/ || _hrc=\$?$//' "T7"
  mutate "M2 the home pin FAILED line written on rc 0 too" sed 's/\[ "\$_hrc" -eq 0 \] || log/[ "$_hrc" -ge 0 ] \&\& log/' "T6"
  mutate "M3 the launch-failure line dropped" sed '/gate launch FAILED after 4 tries/d' "T8"
  mutate "M4 the keyguard rc ignored" sed 's/ || _krc=\$?$//' "T9"
  mutate "M5 the switcher read-back dropped" sed 's/^_sw=\$(settings get global user_switcher_enabled .*$/_sw=0/' "T10"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
