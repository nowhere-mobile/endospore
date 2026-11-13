#!/usr/bin/env bash
# test-od-fetch.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's half of the per-package fetch of parked app data
# (NWP-20261130-03): materializeapp fetches an unfetched package's data BEFORE it stages the APK, and a failed fetch
# stages nothing (the placeholder stays archived); od_unf_path always names the list, so a lost list refuses the seal.
#
# This suite EXECUTES the real extracted od_unf_path, od_fetch_data and materializeapp op under every shell found (the
# device's is mksh), with the agent, pw and restorecon stubbed, and pins the lines that hand the lists over:
#   M1  a listed package: fetch-oddata runs, then restore-app; reply OK
#   M2  a listed package whose fetch fails: no restore-app, no .appcode/<pkg>; reply ERR-FETCH
#   M3  the same with the cancel marker: reply ERR-CANCELLED
#   M4  a package on neither list: no fetch-oddata; restore-app runs
#   O1  odrestore, an INSTALLED listed package (nApps, Play, Aurora, sideload) whose fetch fails: the app is stopped
#       and suspended BEFORE fetch-oddata runs, the block is recorded, the reply is ERR-NOTREADY
#   O2  the same with the suspend refused: the app is disabled for the user instead
#   O3  all three refused (suspend, disable, archive): no fetch-oddata runs; the reply is ERR-NOTREADY
#   O4  odrestore of a package on neither list: no am or pm call
#   O5  the suspend exits 0 but its state line says false (the default dialer): the app is disabled instead
#   O6  the same with the disable's state line not disabled-user: nothing is recorded, no fetch-oddata, ERR-NOTREADY
#   O7  odrestore's fetch of a listed package runs with the login's cached security-key factor in its environment
#   O8  the same with no cached factor: the fetch still runs, with no factor set
#   O9  suspend and disable refused, archive accepted: mode a is recorded and the fetch runs (RF-011)
#   O10 a record exists already (odblock ran first): no second force-stop or suspend, the fetch runs (RF-011)
#   O11 the archive exits 0 but does not say Success: the app counts as not blocked (RF-011)
#   O12 the chooser's mark is confirmed: the app is force-stopped, no root suspension, no record, the fetch runs (RF-012)
#   O13 the chooser's mark is empty (written before its suspension): root suspends as before (RF-012)
#   O14 the chooser's mark of another package does not count (RF-012)
#   L1  the odblock op on a listed package: the app is stopped and suspended, no fetch, OK BLOCKED, the record stays (RF-011)
#   L2  a delayed dispatch and a failed fetch: odblock blocks, the later odrestore's fetch fails, and nothing lifts the
#       block, in that whole span the app stays suspended and recorded (RF-011)
#   L3  odblock with all three commands refused: ERR-NOBLOCK, no record, the WARN line (RF-011)
#   L4  odblock of a package on neither list: OK NONE, no am or pm call (RF-011)
#   L5  odblock with suspend and disable refused and archive accepted: OK BLOCKED, mode a (RF-011)
#   L9  odblock with the chooser's mark confirmed: no root suspension, OK BLOCKED, no record (RF-012)
#   L6  od_unblock_app of mode a: no pm call, the record goes (RF-011)
#   S1  od_block_installed: blocks a listed package with code, not one absent from the listing, not one with no code
#       path, and runs no pm listing when both lists are empty (RF-011)
#   B1  od_unblock_app lifts only the block this session recorded, by its mode, and drops its line
#   B2  the unsuspend exits non-zero although its state line says false: the record stays and the function returns 1
#   B3  the unsuspend times out: the record stays and the function returns 1
#   B4  the unsuspend exits 0 and its state line says true (another owner still holds the app): the record goes, returns 0,
#       and the log names the other owner (RF-012)
#   B8  the unsuspend exits 0 and prints no state line: the record stays and the function returns 1
#   B5  the enable fails by exit, by state line and by timeout: the record stays and the function returns 1 each time
#   B6  a package with both records whose enable fails: only the confirmed record goes
#   B7  a retry after a failure lifts the block and drops the record
#   Y1  the no-hold reply: a failed unblock answers ERR-NOTREADY and keeps the record; the retry answers OK NOSRC
#   Y2  the restored reply: a failed unblock answers ERR-NOTREADY and keeps the record; the retry answers OK <pkg>
#   Y3  a kept hold answers ERR-NOTREADY with no pm call and the record stays
#   Y4  no record: both OK replies stand with no pm call
#   N1  materializeapp with the CE list missing (DE empty): no fetch, no restore-app, no staged APK, ERR-FETCH
#   N2  the same with the DE list missing (CE empty)
#   N3  the same with a directory at a list's path
#   N4  a list that exists but cannot be read (cat fails): the same refusal
#   N5  the CE list names the package and the DE list is missing: no fetch, no restore-app, ERR-FETCH
#   N6  the CE data came back and the DE list is lost after it: the next tap is refused
#   N7  a readable empty list on both sides is not uncertain: restore-app runs, reply OK
#   N8  odrestore with a list missing: the installed app is blocked, no fetch, ERR-NOTREADY, the op stops
#   N9  the same with the DE list missing
#   N10 the same with the whole odfetch dir missing: ERR-NOTREADY, the op stops
#   N11 an unreadable list and od_listed: it counts as listed
#   U1  od_unf_path prints the path when the list exists AND when it does not; nothing for a bad uid
#   P1  the vault restore hands over the ce list, the #de restore the de list; no other restore names one
#   P2  _push names the ce list for vault and the de list for de
#   P3  odrestore blocks a listed app, then fetches, before its hold probe, and answers ERR-NOTREADY on a failure;
#       od_unblock_app decides both OK replies and nothing else
#   P4  the commit arm resets odfetch after the receipts park and creates both lists; nothing above it names odfetch
#   P5  cleanstorage removes odfetch after the per-uid records, below the data-tree loop
#   P6  the RO lane's allowlist admits odblock, and the out arm runs od_block_installed once (RF-011)
#   K1  a fetch writes the pending marker BEFORE fetch-oddata runs, and the marker stays after a good fetch (2b)
#   K2  a fetch that fails keeps the marker; K3 the marker goes at an OK reply and stays at ERR-NOTREADY (a kept hold, a
#       failed unblock); K4 a marker that cannot be written refuses the fetch; K5 a package on neither list writes none
#
#   bash test-od-fetch.sh            # the cases
#   bash test-od-fetch.sh --mutate   # ... plus mutants that must each CONVICT their case under EACH shell
#
# Pure logic -- no device. Every temp is made inside W, so a pass, a failed check or --mutate leaves nothing.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=()
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS+=("$s"); else echo "  skip  shell $s not installed"; fi
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
op_of() { awk -v a="  $2)" '$0 == a {f=1} f&&/^  [a-z0-9-]+\)$/&&$0 != a {exit} f{print}' "$1"; }

# harness <sut> <shell> <case> -> runs one execution case, prints "PASS <case>" or "FAIL <case>: why".
harness() {
  local sut="$1" sh="$2" c="$3" d
  d=$(mktemp -d -p "$W") || return 2
  mkdir -p "$d/state/odfetch.12" "$d/user/com.nowhere.chooser/files"
  : > "$d/state/odfetch.12/unfetched.ce"; : > "$d/state/odfetch.12/unfetched.de"
  cat > "$d/agent" <<'EOF'
#!/bin/sh
echo "$1" >> "$CALLS"
case "$1" in
  fetch-oddata) echo "hmac=${NOWHERE_FIDO2_HMAC:-}" > "$D/fetchenv"
    [ -e "$D/user/com.nowhere.chooser/files/.appcode/$5" ] && echo early > "$D/early"
    [ -e "$D/state/odfetch.12/pending.$5" ] && echo marked > "$D/premark"
    [ -n "${FETCH_UNLIST:-}" ] && : > "$D/state/odfetch.12/unfetched.ce"
    exit "${FETCHRC:-0}" ;;
  restore-app) mkdir -p "$6/$5"; exit 0 ;;
esac
EOF
  chmod +x "$d/agent"
  {
    echo 'LOG="$D/log"; RES="$D/res"; STATE="$D/state"; uid=12; name=prof; pass=x; AGENT="$D/agent"; USERDIR="$D/user"'
    echo 'pw() { echo x; }; restorecon() { :; }; pkgname_ok() { return 0; }; chown() { :; }; stat() { echo 0; }'
    anchor_of "$sut" '_ms() {' | head -1
    grep -m1 -E '^ODHOLD=' "$sut"
    anchor_of "$sut" 'od_unf_path() {'
    anchor_of "$sut" 'od_pending_path() {'
    anchor_of "$sut" 'od_list_state() {'
    anchor_of "$sut" 'od_fetch_data() {'
    anchor_of "$sut" 'od_pending_clear() {'
    anchor_of "$sut" 'od_listed() {'
    anchor_of "$sut" 'od_chooser_holds() {' | sed 's|/data/user/$uid/|$USERDIR/|'
    anchor_of "$sut" 'od_block_app() {'
    anchor_of "$sut" 'od_unblock_app() {'
    anchor_of "$sut" 'od_block_installed() {'
    # TIMEOUTV names the pm verb whose timeout expires: it exits 124 and the command prints nothing
    echo 'timeout() { shift 3; [ "$2" = "${TIMEOUTV:-}" ] && return 124; "$@"; }; am() { echo "am $1" >> "$CALLS"; }'
    # pm prints the state line the real command prints; SUSPST/DISST set what that line says (a zero exit can say false)
    echo 'pm() { echo "pm $1" >> "$CALLS"; case "$1" in suspend) [ -n "${SUSP_UNLIST:-}" ] && : > "$STATE/odfetch.12/unfetched.ce"; echo "Package $4 new suspended state: ${SUSPST:-true}"; return "${SUSPRC:-0}" ;; disable-user) echo "Package $4 new state: ${DISST:-disabled-user}"; return "${DISRC:-0}" ;; unsuspend) [ -n "${UNSUSP_NOLINE:-}" ] || echo "Package $4 new suspended state: ${UNSUSPST:-false}"; return "${UNSUSPRC:-0}" ;; enable) echo "Package $4 new state: ${ENST:-enabled}"; return "${ENRC:-0}" ;; archive) echo "${ARST:-Failure [refused]}"; return "${ARRC:-1}" ;; list) for _x in ${PMLIST:-}; do echo "package:$_x"; done ;; path) case " ${PMPATHS:-} " in *" $4 "*) echo "package:/x/base.apk" ;; esac ;; esac; return 0; }'
    echo 'run_odr() { srcunit="$1"; skind=""; case odrestore in odrestore)'
    awk '$0 == "  odrestore)" {f=1; next} f {print} f && /^    od_fetch_data "\$pkg" \|\|/ {exit}' "$sut"
    echo 'echo REACHED > "$D/reached" ;; esac; }'
    echo 'run_stage() { srcunit="$1"; case stageapp in'
    op_of "$sut" stageapp | sed 's|/data/nowhere/fetchapp|$D/fetchapp|g'
    echo 'esac; }'
    echo 'run_blockop() { srcunit="$1"; case odblock in'
    op_of "$sut" odblock
    echo 'esac; }'
    echo 'run_reply() { odsrc="$1"; odkept="$2"; pkg="$3"'
    awk '/^    if \[ "\$odsrc" = 0 \]; then$/{f=1} f{print} f&&/^    fi$/{exit}' "$sut"
    echo '}'
    echo 'run_mat() { srcunit="$1"; case materializeapp in'
    op_of "$sut" materializeapp
    echo 'esac; }'
  } > "$d/lib.sh"
  local out rc
  out=$(D="$d" CALLS="$d/calls" FETCHRC="${FETCHRC:-0}" SUSPRC="${SUSPRC:-0}" DISRC="${DISRC:-0}" SUSPST="${SUSPST:-true}" DISST="${DISST:-disabled-user}" "$sh" -c '. "$D/lib.sh"; '"$c" 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  return "$rc"
}

fails=0
check() { # check <sut> <label> <case-script>: under every shell
  local sut="$1" label="$2" body="$3" sh out
  for sh in "${SHELLS[@]}"; do
    if out=$(harness "$sut" "$sh" "$body"); then
      [ "$sut" = "$SUT" ] && echo "  ok    $label [$sh]"
    else
      [ "$sut" = "$SUT" ] && { echo "  FAIL  $label [$sh]: $out"; fails=$((fails+1)); }
      return 1
    fi
  done
  return 0
}

M1='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( run_mat com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "fetch-oddata restore-app " ] || { echo "calls: $c"; exit 1; }; r=$(cat "$RES"); case "$r" in OK*) ;; *) echo "reply $r"; exit 1;; esac'
M2='echo com.example.od > "$STATE/odfetch.12/unfetched.de"; ( FETCHRC=1; export FETCHRC; run_mat com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ ! -e "$USERDIR/com.nowhere.chooser/files/.appcode/com.example.od" ] || { echo "apk staged"; exit 1; }; r=$(cat "$RES"); [ "$r" = ERR-FETCH ] || { echo "reply $r"; exit 1; }'
M3='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; : > "$STATE/od-cancel"; ( FETCHRC=1; export FETCHRC; run_mat com.example.od ); r=$(cat "$RES"); [ "$r" = ERR-CANCELLED ] || { echo "reply $r"; exit 1; }'
M4='( run_mat com.example.inst ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "restore-app " ] || { echo "calls: $c"; exit 1; }'
O1='echo com.example.od > "$STATE/odfetch.12/unfetched.de"; ( FETCHRC=1; export FETCHRC; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$RES")" = ERR-NOTREADY ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -e "$D/reached" ] || { echo "went on"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "s com.example.od" ] || { echo "blocked: $(cat "$STATE/odfetch.12/blocked.com.example.od")"; exit 1; }'
O2='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( FETCHRC=1 SUSPRC=1; export FETCHRC SUSPRC; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend pm disable-user fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "d com.example.od" ] || exit 1; [ "$(cat "$RES")" = ERR-NOTREADY ] || exit 1'
O3='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( SUSPRC=1 DISRC=1; export SUSPRC DISRC; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); case "$c" in *fetch-oddata*) echo "fetched unblocked: $c"; exit 1;; esac; [ "$(cat "$RES")" = ERR-NOTREADY ] || exit 1; [ ! -e "$D/reached" ] || exit 1'
O5='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( FETCHRC=1 SUSPST=false; export FETCHRC SUSPST; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend pm disable-user fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "d com.example.od" ] || { echo "blocked: $(cat "$STATE/odfetch.12/blocked.com.example.od")"; exit 1; }; [ "$(cat "$RES")" = ERR-NOTREADY ] || exit 1'
O6='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( SUSPST=false DISST=enabled; export SUSPST DISST; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); case "$c" in *fetch-oddata*) echo "fetched unblocked: $c"; exit 1;; esac; [ ! -s "$STATE/odfetch.12/blocked.com.example.od" ] || { echo "blocked: $(cat "$STATE/odfetch.12/blocked.com.example.od")"; exit 1; }; [ "$(cat "$RES")" = ERR-NOTREADY ] || exit 1; [ ! -e "$D/reached" ] || exit 1'
O4='( run_odr com.example.inst ); c=$(cat "$CALLS" 2>/dev/null); [ -z "$c" ] || { echo "calls: $c"; exit 1; }; [ -e "$D/reached" ] || { echo "stopped"; exit 1; }'
B1='echo "s com.example.a" > "$STATE/odfetch.12/blocked.com.example.a"; echo "d com.example.b" > "$STATE/odfetch.12/blocked.com.example.b"; od_unblock_app com.example.a; od_unblock_app com.example.c; od_unblock_app com.example.b; c=$(tr "
" " " < "$CALLS"); [ "$c" = "pm unsuspend pm enable " ] || { echo "calls: $c"; exit 1; }; [ ! -s "$STATE/odfetch.12/blocked.com.example.a" ] || { echo "left a: $(cat "$STATE/odfetch.12/blocked.com.example.a")"; exit 1; }; [ ! -s "$STATE/odfetch.12/blocked.com.example.b" ] || { echo "left b"; exit 1; }'
O7='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; printf deadbeef > "$STATE/.fido2hmac"; ( run_odr com.example.od ); [ "$(cat "$D/fetchenv")" = hmac=deadbeef ] || { echo "env: $(cat "$D/fetchenv")"; exit 1; }; [ -e "$D/reached" ] || { echo "stopped"; exit 1; }'
O8='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( run_odr com.example.od ); [ "$(cat "$D/fetchenv")" = hmac= ] || { echo "env: $(cat "$D/fetchenv")"; exit 1; }; [ -e "$D/reached" ] || { echo "stopped"; exit 1; }'
BR='B="$STATE/odfetch.12/blocked.com.example.a"; kept() { rc=$1; [ "$rc" = 1 ] || { echo "rc $rc"; exit 1; }; [ "$(cat "$B")" = "$2" ] || { echo "left: $(cat "$B")"; exit 1; }; }; '
B2="$BR"'echo "s com.example.a" > "$B"; ( UNSUSPRC=1; export UNSUSPRC; od_unblock_app com.example.a ); kept $? "s com.example.a"; [ "$(cat "$CALLS")" = "pm unsuspend" ] || exit 1'
B3="$BR"'echo "s com.example.a" > "$B"; ( TIMEOUTV=unsuspend; export TIMEOUTV; od_unblock_app com.example.a ); kept $? "s com.example.a"'
B4="$BR"'echo "s com.example.a" > "$B"; ( UNSUSPST=true; export UNSUSPST; od_unblock_app com.example.a ) || { echo "rc $?"; exit 1; }; [ ! -s "$B" ] || { echo "left: $(cat "$B")"; exit 1; }; grep -q "another owner still holds" "$LOG" || { echo "no log line"; exit 1; }'
B8="$BR"'echo "s com.example.a" > "$B"; ( UNSUSP_NOLINE=1; export UNSUSP_NOLINE; od_unblock_app com.example.a ); kept $? "s com.example.a"'
B5="$BR"'echo "d com.example.a" > "$B"; ( ENRC=1; export ENRC; od_unblock_app com.example.a ); kept $? "d com.example.a"; ( ENST=disabled-user; export ENST; od_unblock_app com.example.a ); kept $? "d com.example.a"; ( TIMEOUTV=enable; export TIMEOUTV; od_unblock_app com.example.a ); kept $? "d com.example.a"'
B6="$BR"'printf "%s\n" "s com.example.a" "d com.example.a" > "$B"; ( ENRC=1; export ENRC; od_unblock_app com.example.a ); kept $? "d com.example.a"'
B7="$BR"'echo "s com.example.a" > "$B"; ( UNSUSPRC=1; export UNSUSPRC; od_unblock_app com.example.a ); kept $? "s com.example.a"; od_unblock_app com.example.a || { echo "retry failed"; exit 1; }; [ ! -s "$B" ] || { echo "left: $(cat "$B")"; exit 1; }'
Y1='B="$STATE/odfetch.12/blocked.com.example.a"; echo "s com.example.a" > "$B"; ( UNSUSPRC=1; export UNSUSPRC; run_reply 0 0 com.example.a ); [ "$(cat "$RES")" = ERR-NOTREADY ] || { echo "reply $(cat "$RES")"; exit 1; }; [ "$(cat "$B")" = "s com.example.a" ] || { echo "left: $(cat "$B")"; exit 1; }; run_reply 0 0 com.example.a; [ "$(cat "$RES")" = "OK NOSRC" ] || { echo "retry $(cat "$RES")"; exit 1; }; [ ! -s "$B" ] || exit 1'
Y2='B="$STATE/odfetch.12/blocked.com.example.a"; echo "d com.example.a" > "$B"; ( ENST=disabled-user; export ENST; run_reply 1 0 com.example.a ); [ "$(cat "$RES")" = ERR-NOTREADY ] || { echo "reply $(cat "$RES")"; exit 1; }; [ "$(cat "$B")" = "d com.example.a" ] || { echo "left: $(cat "$B")"; exit 1; }; run_reply 1 0 com.example.a; [ "$(cat "$RES")" = "OK com.example.a" ] || { echo "retry $(cat "$RES")"; exit 1; }; [ ! -s "$B" ] || exit 1'
Y3='B="$STATE/odfetch.12/blocked.com.example.a"; echo "s com.example.a" > "$B"; run_reply 1 1 com.example.a; [ "$(cat "$RES")" = ERR-NOTREADY ] || { echo "reply $(cat "$RES")"; exit 1; }; [ "$(cat "$B")" = "s com.example.a" ] || exit 1; [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }'
Y4='run_reply 0 0 com.example.a; [ "$(cat "$RES")" = "OK NOSRC" ] || { echo "reply $(cat "$RES")"; exit 1; }; run_reply 1 0 com.example.a; [ "$(cat "$RES")" = "OK com.example.a" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }'
O9='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( SUSPRC=1 DISRC=1 ARRC=0 ARST=Success; export SUSPRC DISRC ARRC ARST; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend pm disable-user pm archive fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "a com.example.od" ] || { echo "blocked: $(cat "$STATE/odfetch.12/blocked.com.example.od")"; exit 1; }; [ -e "$D/reached" ] || { echo "stopped"; exit 1; }'
O10='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; echo "s com.example.od" > "$STATE/odfetch.12/blocked.com.example.od"; ( run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ -e "$D/reached" ] || { echo "stopped"; exit 1; }'
O11='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( SUSPRC=1 DISRC=1 ARRC=0 ARST="Failure [no launcher]"; export SUSPRC DISRC ARRC ARST; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); case "$c" in *fetch-oddata*) echo "fetched unblocked: $c"; exit 1;; esac; [ ! -s "$STATE/odfetch.12/blocked.com.example.od" ] || { echo "recorded: $(cat "$STATE/odfetch.12/blocked.com.example.od")"; exit 1; }; [ "$(cat "$RES")" = ERR-NOTREADY ] || exit 1'
L1='echo com.example.od > "$STATE/odfetch.12/unfetched.de"; ( run_blockop com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$RES")" = "OK BLOCKED" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "s com.example.od" ] || exit 1'
L2='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( run_blockop com.example.od ); rm -f "$RES"; ( FETCHRC=1; export FETCHRC; run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$RES")" = ERR-NOTREADY ] || { echo "reply $(cat "$RES")"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "s com.example.od" ] || { echo "record gone"; exit 1; }; case "$c" in *unsuspend*|*enable*) echo "lifted: $c"; exit 1;; esac; grep -qxF com.example.od "$STATE/odfetch.12/unfetched.ce" || { echo "unlisted"; exit 1; }'
L3='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( SUSPRC=1 DISRC=1; export SUSPRC DISRC; run_blockop com.example.od ); [ "$(cat "$RES")" = ERR-NOBLOCK ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -s "$STATE/odfetch.12/blocked.com.example.od" ] || exit 1; grep -q "WARN od-fetch com.example.od could not be blocked (suspend, disable and archive refused)" "$LOG" || { echo "no WARN: $(cat "$LOG")"; exit 1; }'
L4='( run_blockop com.example.inst ); [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ "$(cat "$RES")" = "OK NONE" ] || { echo "reply $(cat "$RES")"; exit 1; }'
L5='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( SUSPRC=1 DISRC=1 ARRC=0 ARST=Success; export SUSPRC DISRC ARRC ARST; run_blockop com.example.od ); [ "$(cat "$RES")" = "OK BLOCKED" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "a com.example.od" ] || exit 1'
L6='B="$STATE/odfetch.12/blocked.com.example.a"; echo "a com.example.a" > "$B"; od_unblock_app com.example.a || { echo "rc"; exit 1; }; [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ ! -s "$B" ] || { echo "left: $(cat "$B")"; exit 1; }'
S1='printf "%s\n" com.example.code com.example.nocode com.example.gone > "$STATE/odfetch.12/unfetched.ce"; ( PMLIST="com.example.code com.example.nocode" PMPATHS="com.example.code com.example.gone"; export PMLIST PMPATHS; od_block_installed ) || { echo "rc"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.code")" = "s com.example.code" ] || { echo "not blocked"; exit 1; }; [ ! -e "$STATE/odfetch.12/blocked.com.example.nocode" ] || { echo "blocked a package with no code"; exit 1; }; [ ! -e "$STATE/odfetch.12/blocked.com.example.gone" ] || { echo "blocked a package not installed"; exit 1; }; : > "$STATE/odfetch.12/unfetched.ce"; rm -f "$CALLS"; od_block_installed; [ ! -e "$CALLS" ] || { echo "listing with empty lists: $(cat "$CALLS")"; exit 1; }'
NR='refused() { c=$(cat "$CALLS" 2>/dev/null); case "$c" in *fetch-oddata*|*restore-app*) echo "calls: $c"; exit 1;; esac; [ ! -e "$USERDIR/com.nowhere.chooser/files/.appcode/com.example.od" ] || { echo "apk staged"; exit 1; }; [ "$(cat "$RES")" = ERR-FETCH ] || { echo "reply $(cat "$RES")"; exit 1; }; }; '
NB='blockedstop() { c=$(tr "\n" " " < "$CALLS"); case "$c" in "am force-stop pm suspend "*) ;; *) echo "calls: $c"; exit 1;; esac; case "$c" in *fetch-oddata*) echo "calls: $c"; exit 1;; esac; [ "$(cat "$RES")" = ERR-NOTREADY ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -e "$D/reached" ] || { echo "went on"; exit 1; }; }; '
N1="$NR"'rm -f "$STATE/odfetch.12/unfetched.ce"; ( run_mat com.example.od ); refused'
N2="$NR"'rm -f "$STATE/odfetch.12/unfetched.de"; ( run_mat com.example.od ); refused'
N3="$NR"'rm -f "$STATE/odfetch.12/unfetched.ce"; mkdir "$STATE/odfetch.12/unfetched.ce"; ( run_mat com.example.od ); refused'
N4="$NR"'( cat() { [ "$1" = "$STATE/odfetch.12/unfetched.de" ] && return 2; command cat "$@"; }; run_mat com.example.od ); refused'
N5="$NR"'echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; rm -f "$STATE/odfetch.12/unfetched.de"; ( run_mat com.example.od ); refused'
N6="$NR"'echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( run_mat com.example.od ); [ "$(tr "\n" " " < "$CALLS")" = "fetch-oddata restore-app " ] || { echo "first: $(cat "$CALLS")"; exit 1; }; : > "$STATE/odfetch.12/unfetched.ce"; rm -f "$STATE/odfetch.12/unfetched.de" "$RES" "$CALLS"; rm -rf "$USERDIR/com.nowhere.chooser/files/.appcode"; ( run_mat com.example.od ); refused'
N7='( run_mat com.example.od ); [ "$(tr "\n" " " < "$CALLS")" = "restore-app " ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; case "$(cat "$RES")" in OK*) ;; *) echo "reply $(cat "$RES")"; exit 1;; esac'
N8="$NB"'rm -f "$STATE/odfetch.12/unfetched.ce"; ( run_odr com.example.od ); blockedstop'
N9="$NB"'rm -f "$STATE/odfetch.12/unfetched.de"; ( run_odr com.example.od ); blockedstop'
N10="$NB"'rm -rf "$STATE/odfetch.12"; ( run_odr com.example.od ) 2>/dev/null; blockedstop'
N11='( cat() { [ "$1" = "$STATE/odfetch.12/unfetched.ce" ] && return 2; command cat "$@"; }; od_listed com.example.other ) || { echo "unreadable counted as not listed"; exit 1; }'
# stageapp fetches first (RF-011): T1 data before the APK, T2 a failed fetch stages nothing, T3 not listed, T4 a session with
# no odfetch dir, T5 a lost list refuses, T6 a delayed RESTORE-ODDATA finds the data on the phone and blocks nothing.
TS='P=com.example.od; AC="$USERDIR/com.nowhere.chooser/files/.appcode"; mkstage() { mkdir -p "$D/fetchapp/$P"; echo apk > "$D/fetchapp/$P/base.apk"; printf "%s\t1\n" "$P" > "$D/fetchapp/$P/manifest.line"; }; '
T1="$TS"'echo "$P" > "$STATE/odfetch.12/unfetched.ce"; mkstage; ( run_stage "$P" ); [ "$(tr "\n" " " < "$CALLS")" = "fetch-oddata " ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ ! -e "$D/early" ] || { echo "APK staged before the data"; exit 1; }; [ "$(cat "$RES")" = "OK $P" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ -f "$AC/$P/base.apk" ] || { echo "not staged"; exit 1; }; [ ! -e "$D/fetchapp/$P" ] || { echo "stage left"; exit 1; }'
T2="$TS"'echo "$P" > "$STATE/odfetch.12/unfetched.de"; mkstage; ( FETCHRC=1; export FETCHRC; run_stage "$P" ); [ "$(cat "$RES")" = ERR-STAGE ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -e "$AC/$P" ] || { echo "APK staged"; exit 1; }; [ ! -e "$AC/manifest.tsv" ] || { echo "manifest line"; exit 1; }; [ ! -e "$D/fetchapp/$P" ] || { echo "stage left"; exit 1; }; grep -qxF "$P" "$STATE/odfetch.12/unfetched.de" || { echo "unlisted"; exit 1; }; grep -q "stageapp $P FAILED (data fetch)" "$LOG" || { echo "no log"; exit 1; }'
T3="$TS"'mkstage; ( run_stage "$P" ); [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ "$(cat "$RES")" = "OK $P" ] || { echo "reply $(cat "$RES")"; exit 1; }'
T4="$TS"'rm -rf "$STATE/odfetch.12"; mkstage; ( run_stage "$P" ); [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ "$(cat "$RES")" = "OK $P" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ -f "$AC/$P/base.apk" ] || { echo "not staged"; exit 1; }'
T5="$TS"'rm -f "$STATE/odfetch.12/unfetched.de"; mkstage; ( run_stage "$P" ); [ "$(cat "$RES")" = ERR-STAGE ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -e "$AC/$P" ] || { echo "APK staged"; exit 1; }; [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }'
T6="$TS"'echo "$P" > "$STATE/odfetch.12/unfetched.ce"; mkstage; ( FETCH_UNLIST=1; export FETCH_UNLIST; run_stage "$P" ); [ "$(cat "$RES")" = "OK $P" ] || { echo "reply $(cat "$RES")"; exit 1; }; rm -f "$RES"; ( run_odr "$P" ); [ "$(tr "\n" " " < "$CALLS")" = "fetch-oddata " ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ -e "$D/reached" ] || { echo "stopped"; exit 1; }'
# a retry that lands after the restore's OK (RF-011): L7 this op set the block and the package left the lists, so it lifts its own; L8 a block it did not set stays
L7='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( SUSP_UNLIST=1; export SUSP_UNLIST; run_blockop com.example.od ); [ "$(tr "\n" " " < "$CALLS")" = "am force-stop pm suspend pm unsuspend " ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ "$(cat "$RES")" = "OK NONE" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -s "$STATE/odfetch.12/blocked.com.example.od" ] || { echo "record kept"; exit 1; }'
L8='B="$STATE/odfetch.12/blocked.com.example.od"; echo "s com.example.od" > "$B"; ( n=0; od_listed() { n=$((n+1)); [ "$n" = 1 ]; }; run_blockop com.example.od ); [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ "$(cat "$RES")" = "OK BLOCKED" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ "$(cat "$B")" = "s com.example.od" ] || { echo "record: $(cat "$B")"; exit 1; }'
U1='p=$(od_unf_path 12 ce); [ "$p" = "$STATE/odfetch.12/unfetched.ce" ] || { echo "exists: $p"; exit 1; }; rm -f "$STATE/odfetch.12/unfetched.de"; p=$(od_unf_path 12 de); [ "$p" = "$STATE/odfetch.12/unfetched.de" ] || { echo "missing: [$p]"; exit 1; }; p=$(od_unf_path x1 ce) && { echo "bad uid printed $p"; exit 1; }; [ -z "$p" ] || exit 1'

# the chooser's confirmed hold leaves root's suspension out (RF-012)
CM='mkdir -p "$USERDIR/com.nowhere.chooser/files/nowhere-odbarrier"; M="$USERDIR/com.nowhere.chooser/files/nowhere-odbarrier"; echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; '
O12="$CM"'echo 1 > "$M/com.example.od"; ( run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ ! -e "$STATE/odfetch.12/blocked.com.example.od" ] || { echo "recorded"; exit 1; }; [ -e "$D/reached" ] || { echo "stopped"; exit 1; }; grep -q "held by the chooser" "$LOG" || { echo "no log line"; exit 1; }'
O13="$CM"': > "$M/com.example.od"; ( run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend fetch-oddata " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$STATE/odfetch.12/blocked.com.example.od")" = "s com.example.od" ] || { echo "no record"; exit 1; }'
O14="$CM"'echo 1 > "$M/com.example.other"; ( run_odr com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop pm suspend fetch-oddata " ] || { echo "calls: $c"; exit 1; }'
L9="$CM"'echo 1 > "$M/com.example.od"; ( run_blockop com.example.od ); c=$(tr "\n" " " < "$CALLS"); [ "$c" = "am force-stop " ] || { echo "calls: $c"; exit 1; }; [ "$(cat "$RES")" = "OK BLOCKED" ] || { echo "reply $(cat "$RES")"; exit 1; }; [ ! -e "$STATE/odfetch.12/blocked.com.example.od" ] || { echo "recorded"; exit 1; }'

# the pending marker the chooser's barrier reads (2b)
K1='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( run_mat com.example.od ); [ -e "$D/premark" ] || { echo "no marker before the fetch"; exit 1; }; [ -e "$STATE/odfetch.12/pending.com.example.od" ] || { echo "marker gone after a good fetch"; exit 1; }'
K2='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; ( FETCHRC=1; export FETCHRC; run_mat com.example.od ); [ -e "$STATE/odfetch.12/pending.com.example.od" ] || { echo "marker gone after a failed fetch"; exit 1; }'
K3='M="$STATE/odfetch.12/pending.com.example.od"; B="$STATE/odfetch.12/blocked.com.example.od"; : > "$M"; ( run_reply 0 0 com.example.od ); [ "$(cat "$RES")" = "OK NOSRC" ] && [ ! -e "$M" ] || { echo "no-hold OK kept the marker"; exit 1; }; : > "$M"; ( run_reply 1 0 com.example.od ); [ "$(cat "$RES")" = "OK com.example.od" ] && [ ! -e "$M" ] || { echo "restored OK kept the marker"; exit 1; }; : > "$M"; ( run_reply 1 2 com.example.od ); [ "$(cat "$RES")" = ERR-NOTREADY ] && [ -e "$M" ] || { echo "a kept hold lost the marker"; exit 1; }; echo "s com.example.od" > "$B"; ( UNSUSPRC=1; export UNSUSPRC; run_reply 0 0 com.example.od ); [ "$(cat "$RES")" = ERR-NOTREADY ] && [ -e "$M" ] || { echo "a failed unblock lost the marker"; exit 1; }'
K4='echo com.example.od > "$STATE/odfetch.12/unfetched.ce"; mkdir "$STATE/odfetch.12/pending.com.example.od"; ( run_mat com.example.od ); [ ! -e "$CALLS" ] || { echo "calls: $(cat "$CALLS")"; exit 1; }; [ "$(cat "$RES")" = ERR-FETCH ] || { echo "reply $(cat "$RES")"; exit 1; }'
K5='( run_mat com.example.inst ); [ ! -e "$STATE/odfetch.12/pending.com.example.inst" ] || { echo "marker for an unlisted package"; exit 1; }'

# pins <sut> <label>: static checks on the real script's hand-over lines.
pin() {
  local sut="$1" label="$2" in_op commit cs ok=1
  case "$label" in
    P1)
      grep -q 'NOWHERE_UNFETCHED_LIST="$(od_park_var ce)"' "$sut" && grep -q 'NOWHERE_UNFETCHED_LIST="$(od_park_var de)" "$AGENT" restore s3 "${name}#de"' "$sut" || ok=0
      [ "$(grep -c 'NOWHERE_UNFETCHED_LIST="$(od_park_var' "$sut")" = 2 ] || ok=0
      grep -E 'restore s3 "\$\{name\}#(media|apps|sys|keys)"' "$sut" | grep -q UNFETCHED && ok=0 ;;
    P2)
      grep -q 'vault) _unf=$(od_unf_path "$uid" ce)' "$sut" && grep -q 'de) _unf=$(od_unf_path "$uid" de)' "$sut" \
        && grep -q 'NOWHERE_UNFETCHED_LIST="$_unf"' "$sut" || ok=0 ;;
    P3)
      op_of "$sut" odrestore > "$W/op.txt"
      grep -q '^    od_fetch_data "$pkg" || { echo "ERR-NOTREADY" > "$RES"' "$W/op.txt" || ok=0
      [ "$(grep -n 'od_fetch_data' "$W/op.txt" | head -1 | cut -d: -f1)" -lt "$(grep -n '^    _hold=0' "$W/op.txt" | cut -d: -f1)" ] 2>/dev/null || ok=0
      # the unblock decides the two OK replies and runs nowhere else
      [ "$(grep -v '^ *#' "$W/op.txt" | grep -c 'od_unblock_app')" = 2 ] || ok=0
      [ "$(grep -c '^      if od_unblock_app "$pkg"; then od_pending_clear "$pkg"; echo "OK [^;]*; else echo "ERR-NOTREADY" > "$RES"; fi$' "$W/op.txt")" = 2 ] || ok=0 ;;
    P4)
      op_of "$sut" in > "$W/op.txt"
      commit=$(grep -n 'mv "$STATE/restore-receipts" "$PARK/"' "$W/op.txt" | head -1 | cut -d: -f1)
      in_op=$(grep -n 'odfetch' "$W/op.txt" | head -1 | cut -d: -f1)
      [ -n "$commit" ] && [ -n "$in_op" ] && [ "$in_op" -gt "$commit" ] || ok=0
      grep -q '( : > "$STATE/odfetch.$uid/unfetched.ce" ) && ( : > "$STATE/odfetch.$uid/unfetched.de" )' "$W/op.txt" || ok=0 ;;
    P5)
      awk '$0 == "if [ \"$op\" = \"cleanstorage\" ]; then" {f=1} f{print} f&&/^fi$/{exit}' "$sut" > "$W/op.txt"
      cs=$(grep -n 'NWP-20261128-36$' "$W/op.txt" | head -1 | cut -d: -f1)
      in_op=$(grep -n 'rm -rf "$STATE/odfetch.$uid"' "$W/op.txt" | head -1 | cut -d: -f1)
      [ -n "$cs" ] && [ -n "$in_op" ] && [ "$in_op" -gt "$cs" ] || ok=0 ;;
    P6)
      grep -qxF '    odblock) ;;' "$sut" || ok=0
      op_of "$sut" out > "$W/op.txt"
      [ "$(grep -c '^    od_block_installed' "$W/op.txt")" = 1 ] || ok=0 ;;
  esac
  [ "$ok" = 1 ] && { [ "$sut" = "$SUT" ] && echo "  ok    $label"; return 0; }
  [ "$sut" = "$SUT" ] && { echo "  FAIL  $label"; fails=$((fails+1)); }
  return 1
}

for c in T1 T2 T3 T4 T5 T6 L7 L8 M1 M2 M3 M4 O1 O2 O3 O4 O5 O6 O7 O8 O9 O10 O11 O12 O13 O14 L1 L2 L3 L4 L5 L6 L9 S1 B1 B2 B3 B4 B5 B6 B7 B8 Y1 Y2 Y3 Y4 N1 N2 N3 N4 N5 N6 N7 N8 N9 N10 N11 U1 K1 K2 K3 K4 K5; do check "$SUT" "$c" "${!c}"; done
for p in P1 P2 P3 P4 P5 P6; do pin "$SUT" "$p"; done
[ "$fails" = 0 ] || { echo "== $fails case(s) failed"; exit 1; }
echo "== all cases passed"
[ "$MUTATE" = yes ] || exit 0

mfails=0
mutant() { # mutant <label> <case> <sed-expr>: the case must FAIL against the mutated copy
  local label="$1" c="$2" expr="$3" m
  m=$(mktemp -p "$W") || exit 2
  sed "$expr" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     $label"; mfails=$((mfails+1)); return; fi
  case "$c" in
    P*) if pin "$m" "$c"; then echo "  SURVIVED  $label"; mfails=$((mfails+1)); else echo "  convicted $label: $c"; fi ;;
    *) local sh conv=1
       for sh in "${SHELLS[@]}"; do
         if harness "$m" "$sh" "${!c}" >/dev/null; then conv=0; echo "  SURVIVED  $label [$sh]"; fi
       done
       [ "$conv" = 1 ] && echo "  convicted $label: $c [${SHELLS[*]}]" || mfails=$((mfails+1)) ;;
  esac
  rm -f "$m"
}
mutant "R1 a failed fetch still stages the APK" M2 's/^    if ! od_fetch_data "\$pkg"; then$/    if false; then/'
mutant "R2 materializeapp skips the fetch" M1 's/^    if ! od_fetch_data "\$pkg"; then$/    if false; then/'
mutant "R3 od_unf_path names only an existing list" U1 's|^  echo "\$STATE/odfetch.\$1/unfetched.\$2"$|  [ -f "$STATE/odfetch.$1/unfetched.$2" ] \&\& echo "$STATE/odfetch.$1/unfetched.$2"|'
mutant "R4 _push names the ce list for de" P2 's/de) _unf=$(od_unf_path "$uid" de)/de) _unf=$(od_unf_path "$uid" ce)/'
mutant "R5 odrestore ignores a failed fetch" P3 's/^    od_fetch_data "\$pkg" || { echo "ERR-NOTREADY"/    od_fetch_data "$pkg" || true || { echo "ERR-NOTREADY"/'
mutant "R6 the odfetch reset moves to the top of in" P4 's/^    _odoff=0   # NWP-20261130-03/    rm -rf "$STATE\/odfetch.$uid"; _odoff=0   # NWP-20261130-03/'
mutant "R7 the commit arm creates no unfetched.de" P4 's/ \&\& ( : > "\$STATE\/odfetch.\$uid\/unfetched.de" )//'
mutant "R8 the reap removes odfetch above the per-uid records" P5 's/^  \[ -n "\${STATE:-}" \] \&\& rm -rf "\$STATE\/odfetch.\$uid" 2>\/dev\/null$/  : odfetch moved/'
mutant "R9 odrestore fetches a listed installed app without blocking it" O1 's/^      od_block_app "\$pkg" || { echo "ERR-NOTREADY"/      true || { echo "ERR-NOTREADY"/'
mutant "R10 the block does not suspend" O1 's/^  _o=$(timeout -k 2 20 pm suspend --user/  false \&\& _o=$(timeout -k 2 20 pm suspend --user/'
mutant "R14 a zero-exit suspend counts although its state line says false" O5 's/\*"new suspended state: true"\*) _m=s/*) _m=s/'
mutant "R15 a zero-exit disable counts although its state line says it did not take" O6 's/\*"new state: disabled-user"\*) _m=d/*) _m=d/'
mutant "R11 an unblockable app is fetched anyway" O3 's/^      od_block_app "\$pkg" || { echo "ERR-NOTREADY" > "\$RES"; chmod 600 "\$RES"; exit 0; }$/      od_block_app "$pkg" || :/'
mutant "R12 the unblock lifts a block on ERR-NOTREADY too" P3 's/^      echo "ERR-NOTREADY" > "\$RES"$/      od_unblock_app "$pkg"; echo "ERR-NOTREADY" > "$RES"/'
mutant "R13 the unblock keeps the line" B1 's/^    grep -vxF -- "\$_m \$pkg" "\$_b" > "\$_b.tmp"/    cat "$_b" > "$_b.tmp"/'
mutant "R16 the fetch runs without the cached factor" O7 '/^od_fetch_data() {/,/^}/{/NOWHERE_FIDO2_HMAC/d}'
mutant "R17 a zero-exit unsuspend counts without a state line" B8 's/\*"new suspended state: "\*) _ok=1/*) _ok=1/'
mutant "R58 another owner's hold counts as root's block still on (RF-012)" B4 's/\*"new suspended state: "\*) _ok=1/*"new suspended state: false"*) _ok=1/'
mutant "R59 the other owner is not logged (RF-012)" B4 's/another owner still holds its suspension/unblocked/'
mutant "R60 root suspends over a confirmed chooser hold (RF-012)" O12 's/^  if od_chooser_holds "\$pkg"; then$/  if false; then/'
mutant "R61 an empty mark counts as a hold (RF-012)" O13 's/^  \[ -s "\(\/data\/user\/\$uid\/com.nowhere.chooser\/files\/nowhere-odbarrier\/\$1\)" \]$/  [ -e "\1" ]/'
mutant "R62 a confirmed hold skips the force-stop (RF-012)" O12 '/^od_block_app() {/,/^}/{/am force-stop/d}'
mutant "R63 odblock suspends over a confirmed chooser hold (RF-012)" L9 's/^  if od_chooser_holds "\$pkg"; then$/  if false; then/'
mutant "R64 any mark of the chooser counts for every package (RF-012)" O14 's/nowhere-odbarrier\/\$1" \]$/nowhere-odbarrier\/com.example.other" ]/'
mutant "R18 an unsuspend's exit status is ignored" B2 's/^      s) _o=$(timeout -k 2 20 pm unsuspend \(.*\)) \&\& case/      s) _o=$(timeout -k 2 20 pm unsuspend \1); case/'
mutant "R19 a timed-out unsuspend counts as lifted" B3 's/^      s) _o=$(timeout -k 2 20 pm unsuspend .*$/      s) _ok=1 ;;/'
mutant "R20 a zero-exit enable counts although its state line says disabled" B5 's/\*"new state: enabled"\*) _ok=1/*) _ok=1/'
mutant "R21 an enable's exit status is ignored" B5 's/^      d) _o=$(timeout -k 2 20 pm enable \(.*\)) \&\& case/      d) _o=$(timeout -k 2 20 pm enable \1); case/'
mutant "R22 a failed unblock drops its record" B2 's/^      _fail=1$/      _fail=1; _gone="$_gone $_m"/'
mutant "R23 a failed unblock returns success" B2 's/^  return "\$_fail"$/  return 0/'
mutant "R24 a retry cannot run because the record is dropped" B7 's/^      _fail=1$/      _fail=1; _gone="$_gone $_m"/'
mutant "R25 one failed record drops every record of the package" B6 's/grep -vxF -- "\$_m \$pkg" "\$_b"/grep -vxF -e "s $pkg" -e "d $pkg" "$_b"/'
mutant "R26 the no-hold reply is OK after a failed unblock" Y1 's/if od_unblock_app "\$pkg"; then od_pending_clear "\$pkg"; echo "OK NOSRC" > "\$RES"; else echo "ERR-NOTREADY" > "\$RES"; fi/od_unblock_app "$pkg"; od_pending_clear "$pkg"; echo "OK NOSRC" > "$RES"/'
mutant "R27 the restored reply is OK after a failed unblock" Y2 's/if od_unblock_app "\$pkg"; then od_pending_clear "\$pkg"; echo "OK \$pkg" > "\$RES"; else echo "ERR-NOTREADY" > "\$RES"; fi/od_unblock_app "$pkg"; od_pending_clear "$pkg"; echo "OK $pkg" > "$RES"/'
mutant "K-1 no pending marker before the fetch (2b)" K1 '/^  if ! _pm=\$(od_pending_path "\$uid" "\$pkg") || ! ( : > "\$_pm" ) 2>>"\$LOG"; then$/,/^  fi$/d'
mutant "K-2 a marker that cannot be written does not refuse the fetch (2b)" K4 's/^  if ! _pm=\$(od_pending_path "\$uid" "\$pkg") || ! ( : > "\$_pm" ) 2>>"\$LOG"; then$/  _pm=$(od_pending_path "$uid" "$pkg"); ( : > "$_pm" ) 2>>"$LOG"; if false; then/'
mutant "K-3 the no-hold OK keeps the marker (2b)" K3 's/then od_pending_clear "\$pkg"; echo "OK NOSRC"/then echo "OK NOSRC"/'
mutant "K-4 the restored OK keeps the marker (2b)" K3 's/then od_pending_clear "\$pkg"; echo "OK \$pkg"/then echo "OK $pkg"/'
mutant "K-5 a kept hold clears the marker (2b)" K3 's/^      echo "ERR-NOTREADY" > "\$RES"$/      od_pending_clear "$pkg"; echo "ERR-NOTREADY" > "$RES"/'
mutant "K-6 a failed unblock clears the marker (2b)" K3 's/if od_unblock_app "\$pkg"; then od_pending_clear "\$pkg"; echo "OK NOSRC"/od_pending_clear "$pkg"; if od_unblock_app "$pkg"; then echo "OK NOSRC"/'
mutant "K-7 a fetch of an unlisted package writes the marker (2b)" K5 's/^    1) return 0 ;;$/    1) : > "$(od_pending_path "$uid" "$pkg")"; return 0 ;;/'
mutant "R28 a list that cannot be read counts as not listing the package (RF-009)" N1 's/_c=$(cat "\$_l" 2>\/dev\/null) || return 2/_c=$(cat "$_l" 2>\/dev\/null) || continue/'
mutant "R29 uncertain state counts as nothing to fetch (RF-009)" N2 's/\(od-fetch \$pkg REFUSED.*\); return 1 ;;$/\1; return 0 ;;/'
mutant "R30 only the CE list is read (RF-009)" N2 's/^  for _l in "\$_ce" "\$_de"; do$/  for _l in "$_ce"; do/'
mutant "R31 only the DE list is read (RF-009)" N1 's/^  for _l in "\$_ce" "\$_de"; do$/  for _l in "$_de"; do/'
mutant "R32 a directory at a list path counts as empty (RF-009)" N3 's/_c=$(cat "\$_l" 2>\/dev\/null) || return 2/[ -d "$_l" ] \&\& continue; _c=$(cat "$_l" 2>\/dev\/null) || return 2/'
mutant "R33 a read failure counts as an empty list (RF-009)" N4 's/_c=$(cat "\$_l" 2>\/dev\/null) || return 2/_c=$(cat "$_l" 2>\/dev\/null) || _c=""/'
mutant "R34 uncertain state does not block an installed app (RF-009)" N8 's/^  \[ "\$?" != 1 \]$/  [ "$?" = 0 ]/'
mutant "R35 a named package on a list that was read skips the uncertain check (RF-009)" N5 's/^"\*) _r=0 ;; esac$/"*) return 0 ;; esac/'
mutant "R36 od_listed treats an unreadable list as not listed (RF-009)" N11 's/^  \[ "\$?" != 1 \]$/  [ "$?" = 0 ]/'
mutant "R37 a lost DE list after the CE recovery is ignored (RF-009)" N6 's/^  for _l in "\$_ce" "\$_de"; do$/  for _l in "$_ce"; do/'
mutant "R38 an empty list is uncertain (RF-009)" N7 's/^  return "\$_r"$/  [ -n "$_c" ] || return 2; return "$_r"/'
mutant "R39 the whole dir missing still lets odrestore go on (RF-009)" N10 's/^  _ce=$(od_unf_path "\$uid" ce) || return 2$/  [ -d "$STATE\/odfetch.$uid" ] || return 1; _ce=$(od_unf_path "$uid" ce) || return 2/'
mutant "R40 the archive tier is gone (RF-011)" O9 's/pm archive --user/pm noarchive --user/'
mutant "R41 a zero-exit archive counts without Success (RF-011)" O11 's/\*Success\*) _m=a/*) _m=a/'
mutant "R42 odblock blocks nothing (RF-011)" L1 's/^      if ! od_block_app "\$pkg"; then$/      if false; then/'
mutant "R43 odblock reports a refused block as blocked (RF-011)" L3 's/^        echo "ERR-NOBLOCK" > "\$RES"$/        echo "OK BLOCKED" > "$RES"/'
mutant "R44 odblock blocks a package on neither list (RF-011)" L4 '/^  odblock)$/,/^  alarmrelay)$/s/^    if od_listed "\$pkg"; then$/    if true; then/'
mutant "R45 a failed fetch lifts the barrier (RF-011)" L2 's/^    od_fetch_data "\$pkg" || { echo "ERR-NOTREADY"/    od_fetch_data "$pkg" || { od_unblock_app "$pkg"; echo "ERR-NOTREADY"/'
mutant "R46 the sweep blocks a package with no code (RF-011)" S1 's/^    \[ -n "\$(timeout -k 2 20 pm path.*continue$/    :/'
mutant "R47 the out arm does not run the sweep (RF-011)" P6 '/^    od_block_installed   # NWP-20261130-03/d'
mutant "R48 the RO lane refuses odblock (RF-011)" P6 '/^    odblock) ;;$/d'
mutant "R49 an existing record does not skip the block (RF-011)" O10 's/^  \[ -s "\$_b" \] \&\& return 0.*$/  :/'
mutant "R50 the sweep blocks a listed package absent from the listing (RF-011)" S1 's/^package:\$_p$/package:*/'
mutant "R52 stageapp does not fetch first (RF-011)" T1 's/^    if \[ -d "\$STATE\/odfetch.\$uid" \] \&\& ! od_fetch_data "\$pkg"; then$/    if false; then/'
mutant "R53 a failed fetch still stages the APK (RF-011)" T2 's/^\(    if \[ -d "\$STATE\/odfetch.\$uid" \] \&\& ! od_fetch_data "\$pkg"\); then$/\1 \&\& false; then/'
mutant "R54 a session with no odfetch dir is refused (RF-011)" T4 's/^    if \[ -d "\$STATE\/odfetch.\$uid" \] \&\& ! od_fetch_data "\$pkg"; then$/    if ! od_fetch_data "$pkg"; then/'
mutant "R55 a failed fetch leaves the stage behind (RF-011)" T2 's/^      rm -rf "\$STAGE"; echo "\[roamd\] stageapp \$pkg FAILED (data fetch)/      echo "[roamd] stageapp $pkg FAILED (data fetch)/'
mutant "R56 a late retry leaves its block on a restored app (RF-011)" L7 's/^      elif \[ "\$_had" = 0 \] \&\& ! od_listed "\$pkg"; then$/      elif false; then/'
mutant "R57 a late retry lifts a block it did not set (RF-011)" L8 's/^      elif \[ "\$_had" = 0 \] \&\& ! od_listed "\$pkg"; then$/      elif ! od_listed "$pkg"; then/'
mutant "R51 od_unblock_app keeps a mode a record (RF-011)" L6 's/^      a) _ok=1 ;;.*$/      a) _ok=0 ;;/'
[ "$mfails" = 0 ] && echo "== all mutations convicted" || { echo "== $mfails mutation(s) not convicted"; exit 1; }
